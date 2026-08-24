//! The loop.
//!
//! Wait, decode, drain, publish, render. Nothing else happens here, and nothing
//! else is allowed to: every subsystem tug grows hangs off one of those five
//! verbs, and the moment a sixth appears the loop stops being reviewable.
//!
//! It blocks in exactly one place — `waiting.wait` — and the timeout it passes
//! there is the whole of the CPU budget. With nothing dirty and no half-decoded
//! sequence in hand that timeout is null, which is `poll` with no deadline,
//! which is a process consuming nothing at all.
//!
//! Two deadlines feed that timeout: the render deadline from the scheduler, and
//! the escape deadline the decoder needs to tell a lone `Esc` from the start of
//! a sequence. `waitBudget` takes the nearer. That is still one time concept —
//! the scope guard forbids a timer wheel, not arithmetic.

const std = @import("std");

const core = @import("tugcore");
const proto = @import("tugproto");

const backend = @import("../term/backend.zig");
const decoder_mod = @import("../input/decoder.zig");
const key = @import("../input/key.zig");
const queue_mod = @import("queue.zig");
const waiting = @import("wait.zig");

pub const Flow = enum { keep_going, stop };

pub const Handlers = struct {
    context: ?*anyopaque = null,
    /// A decoded key or paste. Returning `.stop` ends the loop.
    onInput: *const fn (context: ?*anyopaque, event: key.InputEvent) Flow,
    /// Draw. Called only when the scheduler says a paint is due, so this is
    /// where the frame budget is actually spent.
    onRender: *const fn (context: ?*anyopaque) anyerror!void,
};

pub const Urgency = enum { urgent, normal };

/// How a drained payload affects the frame budget.
///
/// Endings paint now; everything else paints within the budget. A stream that
/// finishes 8 ms before the screen says so reads as lag, where the same 8 ms
/// mid-stream is invisible.
pub fn urgency(event: proto.Event) Urgency {
    return switch (event) {
        .stream_end, .turn_end, .err, .shutdown => .urgent,
        .session_start, .input_submit, .request_start, .stream_delta => .normal,
        .tool_request, .tool_decision, .tool_result => .normal,
    };
}

/// The wait budget: the render deadline, shortened by the escape deadline when
/// the decoder is holding an incomplete sequence. Null means block indefinitely.
pub fn waitBudget(render_ms: ?u32, escape_deadline_ms: ?u64, now_ms: u64) ?u32 {
    const escape: ?u32 = if (escape_deadline_ms) |deadline|
        (if (now_ms >= deadline) 0 else @intCast(deadline - now_ms))
    else
        null;

    if (render_ms) |render| return if (escape) |esc| @min(render, esc) else render;
    return escape;
}

pub const Loop = struct {
    io: std.Io,
    terminal: *backend.Backend,
    waker: *waiting.Waker,
    queue: *queue_mod.Queue,
    bus: *core.Bus,
    decoder: *decoder_mod.Decoder,
    scheduler: *core.Scheduler,
    handlers: Handlers,

    pub fn run(self: *Loop) !void {
        var read_buffer: [1024]u8 = undefined;
        var terminal_reader = self.terminal.reader(self.io, &read_buffer);

        // When this is non-null the decoder is mid-sequence and silence has a
        // meaning: it resolves a lone ESC into the Escape key.
        var escape_deadline: ?u64 = null;

        while (true) {
            var now = waiting.nowMs(self.io);
            const timeout = waitBudget(self.scheduler.timeoutMs(now), escape_deadline, now);

            const ready = try waiting.wait(
                self.terminal.handle(),
                self.waker.readHandle(),
                timeout,
            );
            now = waiting.nowMs(self.io);

            if (ready.input) {
                const chunk = terminal_reader.interface.peekGreedy(1) catch return;
                if (chunk.len == 0) return;

                self.decoder.feed(chunk);
                terminal_reader.interface.toss(chunk.len);

                while (self.decoder.next()) |event| {
                    if (self.handlers.onInput(self.handlers.context, event) == .stop) return;
                    self.scheduler.markDirty();
                }

                // Whatever the decoder is still holding started arriving now, so
                // the escape timer restarts from this read rather than from the
                // first byte of a sequence that is still growing.
                escape_deadline = if (self.decoder.pending() > 0)
                    now + decoder_mod.escape_timeout_ms
                else
                    null;
            }

            if (ready.wake) {
                self.waker.drain();

                // An empty wake is a resize: SIGWINCH rings the same doorbell
                // and carries no payload. Resizes repaint now, not in 8 ms.
                if (self.drainQueue() == 0) self.scheduler.markUrgent();
            }

            if (!ready.input and !ready.wake and self.decoder.pending() > 0) {
                if (self.decoder.flushPending()) |event| {
                    if (self.handlers.onInput(self.handlers.context, event) == .stop) return;
                    self.scheduler.markDirty();
                }
                escape_deadline = null;
            }

            if (self.scheduler.due(now)) {
                try self.handlers.onRender(self.handlers.context);
                self.scheduler.painted(now);
            }
        }
    }

    /// Drains the queue onto the bus, deciding each payload's urgency on the
    /// way past.
    ///
    /// This is `Queue.drainInto` plus the scheduling decision, which the queue
    /// has no business knowing about. `drainInto` stays for callers that only
    /// want the events.
    fn drainQueue(self: *Loop) usize {
        // The buffer a popped payload's bytes are copied into (`DR-010`). One
        // slot's worth, reused across the drain: each payload is published and
        // forgotten before the next `pop` overwrites it, which is exactly the
        // lifetime the bus documents for a borrowed slice.
        var out: [queue_mod.max_payload_bytes]u8 = undefined;
        var delivered: usize = 0;
        while (self.queue.pop(self.io, &out)) |payload| {
            switch (urgency(payload.event())) {
                .urgent => self.scheduler.markUrgent(),
                .normal => self.scheduler.markDirty(),
            }
            self.bus.publish(payload);
            delivered += 1;
        }
        return delivered;
    }
};

const testing = std.testing;

test "an idle loop with an idle decoder blocks indefinitely" {
    try testing.expectEqual(@as(?u32, null), waitBudget(null, null, 1000));
}

test "a pending escape sequence caps an indefinite wait" {
    try testing.expectEqual(@as(?u32, 30), waitBudget(null, 1030, 1000));
    try testing.expectEqual(@as(?u32, 0), waitBudget(null, 1030, 1030));
    try testing.expectEqual(@as(?u32, 0), waitBudget(null, 1030, 9999));
}

test "the shorter of the two deadlines wins" {
    try testing.expectEqual(@as(?u32, 8), waitBudget(8, 1030, 1000));
    try testing.expectEqual(@as(?u32, 5), waitBudget(8, 1005, 1000));
}

test "endings and turn boundaries paint immediately" {
    try testing.expectEqual(Urgency.urgent, urgency(.stream_end));
    try testing.expectEqual(Urgency.urgent, urgency(.turn_end));
    try testing.expectEqual(Urgency.urgent, urgency(.err));
    try testing.expectEqual(Urgency.urgent, urgency(.shutdown));
    try testing.expectEqual(Urgency.normal, urgency(.stream_delta));
    try testing.expectEqual(Urgency.normal, urgency(.session_start));
}
