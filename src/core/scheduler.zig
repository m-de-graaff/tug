//! The render scheduler: when to paint, and how long it is safe to sleep.
//!
//! Two jobs, and they are the same job seen from either end. `markDirty` says
//! something changed; `timeoutMs` says how long the loop may block before that
//! change has to be on screen. With nothing dirty there is no deadline at all,
//! and the loop blocks indefinitely — which is the whole of the 0 % idle CPU
//! budget, expressed as a null.
//!
//! **The clock is a parameter, not a dependency.** Every method that needs the
//! time takes it. That is the injection: the tests below pass literal
//! milliseconds and never sleep, and the loop passes a monotonic reading. An
//! interface with one implementation would add a vtable and change nothing
//! about what is testable.

const std = @import("std");

/// ~8 ms between paints caps output at 125 frames per second no matter how fast
/// events arrive. Above that the terminal is the bottleneck and the extra
/// writes buy nothing but flicker.
pub const default_frame_ms: u32 = 8;

pub const Scheduler = struct {
    min_frame_ms: u32 = default_frame_ms,
    dirty: bool = false,
    urgent: bool = false,
    last_paint_ms: u64 = 0,
    painted_once: bool = false,

    /// Something changed and should be on screen within the frame budget.
    pub fn markDirty(self: *Scheduler) void {
        self.dirty = true;
    }

    /// Something changed that has to be on screen now: a stream ending, a turn
    /// boundary, a resize. Endings that wait out a frame interval feel laggy in
    /// a way mid-stream frames do not.
    pub fn markUrgent(self: *Scheduler) void {
        self.dirty = true;
        self.urgent = true;
    }

    /// How long the caller may block. Null means indefinitely.
    pub fn timeoutMs(self: *const Scheduler, now_ms: u64) ?u32 {
        if (!self.dirty) return null;
        if (self.urgent or !self.painted_once) return 0;

        // A clock that went backwards counts as "long enough ago". Saturating
        // the subtraction to zero instead would re-arm the full interval on
        // every call until the clock caught up, which is a spin rather than a
        // wait. The loop's clock is monotonic, so this is belt and braces.
        if (now_ms < self.last_paint_ms) return 0;

        const elapsed = now_ms - self.last_paint_ms;
        if (elapsed >= self.min_frame_ms) return 0;
        return self.min_frame_ms - @as(u32, @intCast(elapsed));
    }

    /// Whether a paint is owed at `now_ms`.
    pub fn due(self: *const Scheduler, now_ms: u64) bool {
        return self.timeoutMs(now_ms) == @as(?u32, 0);
    }

    /// Records that a paint happened, which starts the next frame interval.
    pub fn painted(self: *Scheduler, now_ms: u64) void {
        self.dirty = false;
        self.urgent = false;
        self.last_paint_ms = now_ms;
        self.painted_once = true;
    }
};

const testing = std.testing;

test "an idle scheduler blocks indefinitely" {
    const scheduler: Scheduler = .{};
    try testing.expectEqual(@as(?u32, null), scheduler.timeoutMs(1000));
    try testing.expect(!scheduler.due(1000));
}

test "the first paint is due immediately" {
    var scheduler: Scheduler = .{};
    scheduler.markDirty();
    try testing.expectEqual(@as(?u32, 0), scheduler.timeoutMs(1000));
    try testing.expect(scheduler.due(1000));
}

test "a second paint waits out the frame interval" {
    var scheduler: Scheduler = .{};
    scheduler.markDirty();
    scheduler.painted(1000);

    scheduler.markDirty();
    try testing.expectEqual(@as(?u32, 8), scheduler.timeoutMs(1000));
    try testing.expect(!scheduler.due(1000));

    try testing.expectEqual(@as(?u32, 3), scheduler.timeoutMs(1005));
    try testing.expect(!scheduler.due(1005));

    try testing.expectEqual(@as(?u32, 0), scheduler.timeoutMs(1008));
    try testing.expect(scheduler.due(1008));
}

test "urgent bypasses the frame interval" {
    var scheduler: Scheduler = .{};
    scheduler.painted(1000);
    scheduler.markUrgent();
    try testing.expectEqual(@as(?u32, 0), scheduler.timeoutMs(1000));
    try testing.expect(scheduler.due(1000));
}

test "painting clears dirty and urgent together" {
    var scheduler: Scheduler = .{};
    scheduler.markUrgent();
    scheduler.painted(1000);
    try testing.expect(!scheduler.dirty);
    try testing.expect(!scheduler.urgent);
    try testing.expectEqual(@as(?u32, null), scheduler.timeoutMs(1000));
}

test "a clock that goes backwards does not underflow the timeout" {
    var scheduler: Scheduler = .{};
    scheduler.painted(1000);
    scheduler.markDirty();
    // Saturating: a clock that went backwards means "long enough ago", not a
    // panic in ReleaseSafe.
    try testing.expectEqual(@as(?u32, 0), scheduler.timeoutMs(900));
}

test "a burst of marks between paints still costs one paint" {
    var scheduler: Scheduler = .{};
    scheduler.painted(1000);
    for (0..1000) |_| scheduler.markDirty();

    try testing.expect(!scheduler.due(1004));
    try testing.expect(scheduler.due(1008));
    scheduler.painted(1008);
    try testing.expect(!scheduler.due(1008));
    try testing.expectEqual(@as(?u32, null), scheduler.timeoutMs(2000));
}
