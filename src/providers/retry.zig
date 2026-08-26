//! Retries, and the line they never cross — `DR-019`.
//!
//! Pure policy plus one wrapper. `classOf` and `delayMs` are functions of their
//! arguments and nothing else; `Retrying` is a `tugcore.Provider` that opens a
//! fresh stream per attempt and stops the moment a stream has produced content.
//!
//! **The line, stated where it is enforced:** a request that has yielded zero
//! content events may be retried; after the first `text_delta`, never. Retrying
//! after content means either discarding what the user has already read or
//! splicing two model responses together and calling it one — and the second is
//! worse, because nobody can see it happened.
//!
//! The clock is injected. The engine sleeps and reads time, and neither belongs
//! to it: a test passes a fake and the elapsed-budget case runs instantly rather
//! than taking four real seconds.

const std = @import("std");

const core = @import("tugcore");
const proto = @import("tugproto");

pub const Class = enum {
    /// Try again after a wait.
    retry,
    /// Report it. Waiting will not help, or the provider declined to say when.
    give_up,
};

pub const Policy = struct {
    /// A pathological-loop stop. The elapsed budget is the one a human notices.
    max_attempts: u32 = 4,
    /// Checked *before* sleeping, so the budget bounds the wait rather than
    /// being discovered after it.
    max_elapsed_ms: u32 = 20_000,
    base_ms: u32 = 500,
    /// Bounds tug's guessing. It does not bound a provider's instruction.
    cap_ms: u32 = 8_000,
};

/// Whether a failure of this kind is worth another attempt.
///
/// `has_retry_after` is the whole of the rate-limit decision: a 429 that says
/// when is an instruction to wait, and a 429 that says nothing is a provider
/// declining to say when. Guessing there is how a client becomes part of the
/// incident it is reacting to.
pub fn classOf(kind: proto.ErrKind, has_retry_after: bool) Class {
    return switch (kind) {
        .transport, .server => .retry,
        .rate_limit => if (has_retry_after) .retry else .give_up,
        .auth, .decode => .give_up,
    };
}

/// How long to wait before attempt `attempt` + 1.
///
/// Full jitter: `random(0, min(cap, base << attempt))`. Not equal jitter and not
/// none — the failure this prevents is every tug on a team retrying in lockstep
/// after one provider blip, and full jitter flattens that best.
///
/// A server-supplied wait wins outright, even past the cap: backing off less
/// than you were told is how a client gets rate-limited again one second later.
pub fn delayMs(policy: Policy, attempt: u32, retry_after_ms: ?u32, random: std.Random) u32 {
    if (retry_after_ms) |told| return told;

    // Shifting past the width of the type is undefined, and `attempt` is bounded
    // by `max_attempts` in practice — but this function is public and a caller
    // is not the place to put that invariant.
    const shift: u5 = @intCast(@min(attempt, 20));
    const ceiling = @min(policy.cap_ms, policy.base_ms <<| shift);
    if (ceiling == 0) return 0;
    return random.uintLessThan(u32, ceiling + 1);
}

/// What a frontend needs to render one attempt.
pub const Notice = struct {
    attempt: u32,
    of: u32,
    delay_ms: u32,
    kind: proto.ErrKind,
};

/// One line, and both numbers in it are the ones a waiting user wants.
pub fn formatNotice(notice: Notice, out: []u8) []const u8 {
    const seconds = @as(f64, @floatFromInt(notice.delay_ms)) / 1000.0;
    return std.fmt.bufPrint(out, "retrying in {d:.1} s - {s} (attempt {d} of {d})", .{
        seconds,
        reason(notice.kind),
        notice.attempt,
        notice.of,
    }) catch "retrying";
}

fn reason(kind: proto.ErrKind) []const u8 {
    return switch (kind) {
        .auth => "auth error",
        .rate_limit => "rate limited",
        .server => "server error",
        .transport => "connection problem",
        .decode => "decode error",
    };
}

/// The clock and the sleep, injected.
pub const Clock = struct {
    context: ?*anyopaque = null,
    nowMs: *const fn (context: ?*anyopaque) i64,
    /// Returns false when the wait was interrupted — which is how `Esc` aborts a
    /// retry wait without this file knowing what `Esc` is.
    sleepMs: *const fn (context: ?*anyopaque, ms: u32) bool,
};

/// Opens one attempt.
///
/// A factory rather than a stream, because a stream that has failed has a
/// consumed response inside it. Attempt two needs a new request on a new
/// connection, and only the caller knows how to build one.
pub const Factory = struct {
    context: ?*anyopaque = null,
    /// Null when the factory itself could not open an attempt. That is not a
    /// retry case: a transport that cannot be constructed will not construct on
    /// the third try either.
    open: *const fn (context: ?*anyopaque, attempt: u32) ?core.Provider,
};

/// A provider that retries the one underneath it, within the rules above.
pub const Retrying = struct {
    factory: Factory,
    policy: Policy,
    random: std.Random,
    clock: Clock,

    /// Called before each wait, so a frontend can say what is happening. Null in
    /// tests and in `--json`, where a dim notice has nowhere to go.
    onNotice: ?*const fn (context: ?*anyopaque, notice: Notice) void = null,
    notice_context: ?*anyopaque = null,

    /// The idempotency line, as one bool.
    yielded_content: bool = false,
    attempt: u32 = 0,
    /// A separate bool rather than `started_ms == 0` as a sentinel. A monotonic
    /// clock is allowed to read zero, and treating that as "not started yet"
    /// re-baselines the elapsed budget on every attempt — which is a retry loop
    /// with no elapsed budget at all, discovered by the test for it.
    started: bool = false,
    started_ms: i64 = 0,
    current: ?core.Provider = null,
    /// Held so the failure that ended the last attempt can be re-emitted when
    /// the retries run out. Borrowed from the stream that produced it, which
    /// outlives this by construction — the factory owns both.
    last_error: ?proto.Err = null,
    done: bool = false,

    pub fn provider(self: *Retrying) core.Provider {
        return .{ .context = self, .next = nextErased };
    }

    fn nextErased(context: ?*anyopaque) ?proto.StreamEvent {
        const self: *Retrying = @ptrCast(@alignCast(context.?));
        return self.next();
    }

    pub fn next(self: *Retrying) ?proto.StreamEvent {
        while (true) {
            if (self.done) return null;

            const current = self.current orelse {
                if (!self.started) {
                    self.started = true;
                    self.started_ms = self.clock.nowMs(self.clock.context);
                }
                self.current = self.factory.open(self.factory.context, self.attempt) orelse {
                    self.done = true;
                    return self.last_error_event();
                };
                continue;
            };

            const event = current.nextEvent() orelse {
                // The stream ended. If it ended on an error the retry rules
                // decide; if it ended cleanly, so does this.
                if (self.last_error) |failure| {
                    if (self.shouldRetry(failure)) continue;
                }
                self.done = true;
                return self.last_error_event();
            };

            switch (event) {
                .err => |failure| {
                    // Held rather than emitted: an error is only the user's
                    // business once tug has decided not to try again.
                    self.last_error = failure;
                    continue;
                },
                // The line. Anything the model actually produced closes the door
                // on retrying this request.
                .text_delta, .tool_call_delta => self.yielded_content = true,
                else => {},
            }
            return event;
        }
    }

    /// Decides, waits, and reopens. Returns false when the answer is no.
    fn shouldRetry(self: *Retrying, failure: proto.Err) bool {
        if (self.yielded_content) return false;
        if (classOf(failure.kind, failure.retry_after_ms != null) == .give_up) return false;
        if (self.attempt + 1 >= self.policy.max_attempts) return false;

        const delay = delayMs(self.policy, self.attempt, failure.retry_after_ms, self.random);

        // Checked before sleeping, so the budget bounds the wait rather than
        // being discovered after it.
        const elapsed = self.clock.nowMs(self.clock.context) - self.started_ms;
        if (elapsed + delay > self.policy.max_elapsed_ms) return false;

        if (self.onNotice) |notify| notify(self.notice_context, .{
            .attempt = self.attempt + 2,
            .of = self.policy.max_attempts,
            .delay_ms = delay,
            .kind = failure.kind,
        });

        if (!self.clock.sleepMs(self.clock.context, delay)) return false;

        self.attempt += 1;
        self.current = null;
        self.last_error = null;
        return true;
    }

    fn last_error_event(self: *Retrying) ?proto.StreamEvent {
        const failure = self.last_error orelse return null;
        self.last_error = null;
        return .{ .err = failure };
    }
};

const testing = std.testing;

test "the retry classes are exactly the documented ones" {
    try testing.expectEqual(Class.retry, classOf(.transport, false));
    try testing.expectEqual(Class.retry, classOf(.server, false));
    try testing.expectEqual(Class.retry, classOf(.rate_limit, true));
    // A 429 with no instruction is a provider declining to say when.
    try testing.expectEqual(Class.give_up, classOf(.rate_limit, false));
    try testing.expectEqual(Class.give_up, classOf(.auth, false));
    try testing.expectEqual(Class.give_up, classOf(.auth, true));
    try testing.expectEqual(Class.give_up, classOf(.decode, false));
}

test "backoff grows, and never past the cap" {
    var prng: std.Random.DefaultPrng = .init(7);
    const policy: Policy = .{ .base_ms = 500, .cap_ms = 8_000 };

    for (0..12) |attempt| {
        const n: u32 = @intCast(attempt);
        const delay = delayMs(policy, n, null, prng.random());
        try testing.expect(delay <= policy.cap_ms);

        const shift: u5 = @intCast(@min(n, 20));
        try testing.expect(delay <= @min(policy.cap_ms, policy.base_ms <<| shift));
    }
}

test "a huge attempt number does not shift past the type" {
    // `delayMs` is public and its caller is not where that invariant belongs.
    var prng: std.Random.DefaultPrng = .init(7);
    try testing.expect(delayMs(.{}, 1_000_000, null, prng.random()) <= 8_000);
}

test "a server's retry-after wins over the backoff curve" {
    var prng: std.Random.DefaultPrng = .init(7);
    try testing.expectEqual(@as(u32, 30_000), delayMs(.{}, 0, 30_000, prng.random()));
}

test "a retry-after past the cap is still honoured" {
    // The cap bounds tug's guessing, not the provider's instruction.
    var prng: std.Random.DefaultPrng = .init(7);
    try testing.expectEqual(@as(u32, 120_000), delayMs(.{ .cap_ms = 8_000 }, 0, 120_000, prng.random()));
}

test "the same seed gives the same delays" {
    // A retry sequence inside a golden has to be reproducible or the golden is
    // noise.
    var first: std.Random.DefaultPrng = .init(99);
    var second: std.Random.DefaultPrng = .init(99);
    for (0..5) |attempt| {
        const n: u32 = @intCast(attempt);
        try testing.expectEqual(
            delayMs(.{}, n, null, first.random()),
            delayMs(.{}, n, null, second.random()),
        );
    }
}

test "a retry notice says how long and why" {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "retrying in 1.8 s - server error (attempt 2 of 4)",
        formatNotice(.{ .attempt = 2, .of = 4, .delay_ms = 1_800, .kind = .server }, &buffer),
    );
}

test "a sub-second wait is not rendered as 0.0 s" {
    var buffer: [128]u8 = undefined;
    const line = formatNotice(.{ .attempt = 2, .of = 4, .delay_ms = 400, .kind = .transport }, &buffer);
    try testing.expect(std.mem.indexOf(u8, line, "0.4 s") != null);
}

// --- the engine, driven by a scripted factory -----------------------------

/// One attempt's worth of scripted events.
const Script = struct {
    events: []const proto.StreamEvent,
    sent: usize = 0,

    fn nextErased(context: ?*anyopaque) ?proto.StreamEvent {
        const self: *Script = @ptrCast(@alignCast(context.?));
        if (self.sent == self.events.len) return null;
        defer self.sent += 1;
        return self.events[self.sent];
    }
};

const Fake = struct {
    script: []const proto.StreamEvent,
    attempts: usize = 0,
    current: Script = undefined,

    now: i64 = 0,
    /// Advanced by `sleepMs`, so the elapsed budget is exercised without a
    /// single real millisecond passing.
    per_attempt_ms: i64 = 0,
    interrupt_after: ?usize = null,
    notices: usize = 0,

    fn openErased(context: ?*anyopaque, attempt: u32) ?core.Provider {
        _ = attempt;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.attempts += 1;
        self.now += self.per_attempt_ms;
        self.current = .{ .events = self.script };
        return .{ .context = &self.current, .next = Script.nextErased };
    }

    fn nowErased(context: ?*anyopaque) i64 {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        return self.now;
    }

    fn sleepErased(context: ?*anyopaque, ms: u32) bool {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        if (self.interrupt_after) |after| {
            if (self.attempts > after) return false;
        }
        self.now += ms;
        return true;
    }

    fn noticeErased(context: ?*anyopaque, notice: Notice) void {
        _ = notice;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.notices += 1;
    }

    fn retrying(self: *Fake, prng: *std.Random.DefaultPrng, policy: Policy) Retrying {
        return .{
            .factory = .{ .context = self, .open = openErased },
            .policy = policy,
            .random = prng.random(),
            .clock = .{ .context = self, .nowMs = nowErased, .sleepMs = sleepErased },
            .onNotice = noticeErased,
            .notice_context = self,
        };
    }
};

fn drain(engine: *Retrying) usize {
    var count: usize = 0;
    const p = engine.provider();
    while (p.nextEvent()) |_| count += 1;
    return count;
}

test "a stream that failed before any text is retried" {
    var prng: std.Random.DefaultPrng = .init(3);
    var fake: Fake = .{ .script = &.{
        .{ .err = .{ .kind = .transport, .message = "connection reset" } },
    } };
    var engine = fake.retrying(&prng, .{ .max_attempts = 3, .max_elapsed_ms = 1_000_000 });

    _ = drain(&engine);
    try testing.expectEqual(@as(usize, 3), fake.attempts);
    try testing.expectEqual(@as(usize, 2), fake.notices);
}

test "a stream that yielded text is never retried" {
    // The line, as a test. Two deltas and then a cut connection: one attempt.
    var prng: std.Random.DefaultPrng = .init(3);
    var fake: Fake = .{ .script = &.{
        .{ .text_delta = "A tugboat" },
        .{ .text_delta = " is rated" },
        .{ .err = .{ .kind = .transport, .message = "connection reset" } },
    } };
    var engine = fake.retrying(&prng, .{ .max_attempts = 5, .max_elapsed_ms = 1_000_000 });

    const events = drain(&engine);
    try testing.expectEqual(@as(usize, 1), fake.attempts);
    // Two deltas and the error: partial output is the user's, and so is the
    // explanation of why it stopped.
    try testing.expectEqual(@as(usize, 3), events);
}

test "a tool call counts as content too" {
    // A model that asked for a tool has produced output, even though no text
    // reached the screen. Retrying would ask a second model for a second call.
    var prng: std.Random.DefaultPrng = .init(3);
    var fake: Fake = .{ .script = &.{
        .{ .tool_call_delta = .{ .id = "toolu_01", .name = "read" } },
        .{ .err = .{ .kind = .server, .message = "gone" } },
    } };
    var engine = fake.retrying(&prng, .{ .max_attempts = 5, .max_elapsed_ms = 1_000_000 });

    _ = drain(&engine);
    try testing.expectEqual(@as(usize, 1), fake.attempts);
}

test "usage before a failure does not close the door" {
    // A `usage` event is tug's bookkeeping, not the model's output. Treating it
    // as content would make the Anthropic shape unretryable in every case,
    // because `message_start` arrives before anything else.
    var prng: std.Random.DefaultPrng = .init(3);
    var fake: Fake = .{ .script = &.{
        .{ .usage = .{ .input_tokens = 24 } },
        .{ .err = .{ .kind = .server, .message = "gone" } },
    } };
    var engine = fake.retrying(&prng, .{ .max_attempts = 3, .max_elapsed_ms = 1_000_000 });

    _ = drain(&engine);
    try testing.expectEqual(@as(usize, 3), fake.attempts);
}

test "an auth failure is not retried, however many attempts are allowed" {
    var prng: std.Random.DefaultPrng = .init(3);
    var fake: Fake = .{ .script = &.{
        .{ .err = .{ .kind = .auth, .message = "invalid x-api-key" } },
    } };
    var engine = fake.retrying(&prng, .{ .max_attempts = 20, .max_elapsed_ms = 1_000_000 });

    _ = drain(&engine);
    try testing.expectEqual(@as(usize, 1), fake.attempts);
    try testing.expectEqual(@as(usize, 0), fake.notices);
}

test "a rate limit with no instruction is not retried" {
    var prng: std.Random.DefaultPrng = .init(3);
    var fake: Fake = .{ .script = &.{
        .{ .err = .{ .kind = .rate_limit, .message = "slow down" } },
    } };
    var engine = fake.retrying(&prng, .{ .max_attempts = 20, .max_elapsed_ms = 1_000_000 });

    _ = drain(&engine);
    try testing.expectEqual(@as(usize, 1), fake.attempts);
}

test "a rate limit with an instruction waits exactly that long" {
    var prng: std.Random.DefaultPrng = .init(3);
    var fake: Fake = .{ .script = &.{
        .{ .err = .{ .kind = .rate_limit, .message = "slow down", .retry_after_ms = 2_000 } },
    } };
    var engine = fake.retrying(&prng, .{ .max_attempts = 2, .max_elapsed_ms = 1_000_000 });

    _ = drain(&engine);
    try testing.expectEqual(@as(usize, 2), fake.attempts);
    // One wait, and it was the one the provider asked for rather than the curve.
    try testing.expectEqual(@as(i64, 2_000), fake.now);
}

test "the elapsed budget stops a loop the attempt count would not" {
    var prng: std.Random.DefaultPrng = .init(3);
    var fake: Fake = .{
        .script = &.{
            .{ .err = .{ .kind = .rate_limit, .message = "slow", .retry_after_ms = 1_000 } },
        },
        .per_attempt_ms = 0,
    };
    var engine = fake.retrying(&prng, .{ .max_attempts = 20, .max_elapsed_ms = 2_500 });

    _ = drain(&engine);
    // Two waits of a second fit inside 2.5 s; the third does not, and it is
    // refused before it is slept rather than after.
    try testing.expectEqual(@as(usize, 3), fake.attempts);
    try testing.expectEqual(@as(i64, 2_000), fake.now);
}

test "an interrupted wait ends the retries immediately" {
    // What `Esc` does, without this file knowing what `Esc` is.
    var prng: std.Random.DefaultPrng = .init(3);
    var fake: Fake = .{
        .script = &.{
            .{ .err = .{ .kind = .server, .message = "gone" } },
        },
        // Interrupted during the first wait, which is the case that matters:
        // a user pressing Esc does not wait for a second attempt to start.
        .interrupt_after = 0,
    };
    var engine = fake.retrying(&prng, .{ .max_attempts = 10, .max_elapsed_ms = 1_000_000 });

    _ = drain(&engine);
    try testing.expectEqual(@as(usize, 1), fake.attempts);
}

test "the error survives to the caller when the retries run out" {
    var prng: std.Random.DefaultPrng = .init(3);
    var fake: Fake = .{ .script = &.{
        .{ .err = .{ .kind = .server, .message = "Internal server error" } },
    } };
    var engine = fake.retrying(&prng, .{ .max_attempts = 2, .max_elapsed_ms = 1_000_000 });

    const p = engine.provider();
    const event = p.nextEvent().?;
    try testing.expectEqualStrings("Internal server error", event.err.message);
    try testing.expect(p.nextEvent() == null);
}

test "a clean stream is passed through untouched" {
    var prng: std.Random.DefaultPrng = .init(3);
    var fake: Fake = .{ .script = &.{
        .{ .text_delta = "hello" },
        .{ .stop = .{ .reason = .end_turn } },
    } };
    var engine = fake.retrying(&prng, .{});

    const p = engine.provider();
    try testing.expectEqualStrings("hello", p.nextEvent().?.text_delta);
    try testing.expectEqual(proto.StopReason.end_turn, p.nextEvent().?.stop.reason);
    try testing.expect(p.nextEvent() == null);
    try testing.expectEqual(@as(usize, 1), fake.attempts);
    try testing.expectEqual(@as(usize, 0), fake.notices);
}

test "a factory that cannot open an attempt is not retried" {
    // A transport that could not be constructed will not construct on the third
    // try either.
    const Refusing = struct {
        fn openErased(context: ?*anyopaque, attempt: u32) ?core.Provider {
            _ = attempt;
            const calls: *usize = @ptrCast(@alignCast(context.?));
            calls.* += 1;
            return null;
        }
        fn nowErased(_: ?*anyopaque) i64 {
            return 0;
        }
        fn sleepErased(_: ?*anyopaque, _: u32) bool {
            return true;
        }
    };

    var calls: usize = 0;
    var prng: std.Random.DefaultPrng = .init(3);
    var engine: Retrying = .{
        .factory = .{ .context = &calls, .open = Refusing.openErased },
        .policy = .{ .max_attempts = 5 },
        .random = prng.random(),
        .clock = .{ .nowMs = Refusing.nowErased, .sleepMs = Refusing.sleepErased },
    };

    try testing.expect(engine.provider().nextEvent() == null);
    try testing.expectEqual(@as(usize, 1), calls);
}
