//! Where an API key comes from — `DR-024`.
//!
//! Four sources, first hit wins: the flag, the preset's environment variable,
//! config `key`, config `key_cmd`. The order is by immediacy rather than by
//! preference — a flag is what the user typed just now and a config file is what
//! they set months ago — and the documentation's preference between the last two
//! is the opposite of their order here, which is deliberate and explained in the
//! decision record.
//!
//! The spawner is injected, so every test in this file runs with no subprocess.
//! The real one is a thin wrapper over `std.process.run` at the bottom, behind
//! the same kind of seam the transport uses and for the same reason.

const std = @import("std");

const providers = @import("tugproviders");

/// The longest key this will hold. Every provider's is well under a hundred
/// characters; a `key_cmd` printing more than this is printing something that is
/// not a key.
pub const max_key_bytes = 512;

/// The longest `key_cmd` failure message kept. Enough for a real `gpg` complaint
/// and not enough for a stack trace.
pub const max_problem_bytes = 512;

pub const Origin = enum {
    none,
    flag,
    environment,
    config_key,
    config_key_cmd,
};

pub const Sources = struct {
    /// `--key`, or empty.
    flag: []const u8 = "",
    /// Already looked up from the preset's variable by the caller, which is the
    /// only thing that knows which preset was asked for.
    environment: []const u8 = "",
    config_key: []const u8 = "",
    config_key_cmd: []const u8 = "",
};

pub const Resolution = struct {
    key: []const u8 = "",
    origin: Origin = .none,
    /// Set when a `key_cmd` was configured and did not produce a key. Not an
    /// error return: a missing key is an absence the frontend turns into an
    /// export line, and only a *failing* command is worth a sentence of its own.
    problem: ?[]const u8 = null,
};

pub const Spawner = struct {
    context: ?*anyopaque = null,
    /// Runs a command line and reports what happened.
    ///
    /// Returns false when the command could not be run or exited nonzero, with
    /// `stderr` filled in as far as it fits. `stdout` is the key, untrimmed.
    run: *const fn (
        context: ?*anyopaque,
        command: []const u8,
        stdout: []u8,
        stderr: []u8,
        lengths: *Lengths,
    ) bool,

    pub const Lengths = struct { stdout: usize = 0, stderr: usize = 0 };
};

/// Holds the resolved key for the lifetime of the process.
///
/// Cached, not re-resolved: spawning `pass` per turn means a GPG passphrase
/// prompt per turn, and a harness that interrupts an answer to ask for a
/// passphrase has broken the thing it was for.
pub const Resolver = struct {
    spawner: Spawner,

    key_storage: [max_key_bytes]u8 = undefined,
    problem_storage: [max_problem_bytes]u8 = undefined,
    resolved: ?Resolution = null,

    pub fn resolve(self: *Resolver, sources: Sources) Resolution {
        if (self.resolved) |cached| return cached;

        const answer = self.compute(sources);
        self.resolved = answer;
        return answer;
    }

    fn compute(self: *Resolver, sources: Sources) Resolution {
        if (sources.flag.len > 0) return self.keep(sources.flag, .flag);
        if (sources.environment.len > 0) return self.keep(sources.environment, .environment);
        if (sources.config_key.len > 0) return self.keep(sources.config_key, .config_key);
        if (sources.config_key_cmd.len == 0) return .{};

        var stdout: [max_key_bytes]u8 = undefined;
        var stderr: [max_problem_bytes]u8 = undefined;
        var lengths: Spawner.Lengths = .{};

        if (!self.spawner.run(
            self.spawner.context,
            sources.config_key_cmd,
            &stdout,
            &stderr,
            &lengths,
        )) {
            // The command's own words, scrubbed. A secret store's error message
            // is exactly the kind of place a key gets printed by accident.
            const said = std.mem.trim(u8, stderr[0..lengths.stderr], " \t\r\n");
            const scrubbed = providers.redact.keys(said, &self.problem_storage);
            return .{ .problem = if (scrubbed.len > 0) scrubbed else "key_cmd failed and said nothing" };
        }

        // Every secret store prints a trailing newline. A key with one on the
        // end fails authentication with a message about the key being wrong,
        // which sends the user looking in exactly the wrong place.
        const printed = std.mem.trim(u8, stdout[0..lengths.stdout], " \t\r\n");
        if (printed.len == 0) return .{ .problem = "key_cmd succeeded and printed nothing" };

        return self.keep(printed, .config_key_cmd);
    }

    /// Copies a key into storage this type owns.
    ///
    /// The flag and the environment borrow from `argv` and the environment block
    /// respectively, both of which outlive the process — but `key_cmd`'s output
    /// lives in a stack buffer inside `compute`, and one code path that copies
    /// while three do not is the shape a use-after-free hides in.
    fn keep(self: *Resolver, key: []const u8, origin: Origin) Resolution {
        const take = @min(key.len, self.key_storage.len);
        @memcpy(self.key_storage[0..take], key[0..take]);
        return .{ .key = self.key_storage[0..take], .origin = origin };
    }
};

/// The real spawner, as a value the caller owns.
///
/// Split on whitespace rather than run through a shell: `key_cmd` is a command,
/// not a script, and handing it to `sh -c` would make every quoting question in
/// the config file a security question as well.
pub const SystemSpawner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    /// The most arguments a `key_cmd` may have. `pass show a/b/c` is three.
    pub const max_args = 16;

    pub fn spawner(self: *SystemSpawner) Spawner {
        return .{ .context = self, .run = runErased };
    }

    fn runErased(
        context: ?*anyopaque,
        command: []const u8,
        stdout: []u8,
        stderr: []u8,
        lengths: *Spawner.Lengths,
    ) bool {
        const self: *SystemSpawner = @ptrCast(@alignCast(context.?));

        var argv: [max_args][]const u8 = undefined;
        var count: usize = 0;
        var words = std.mem.tokenizeAny(u8, command, " \t");
        while (words.next()) |word| {
            if (count == argv.len) return false;
            argv[count] = word;
            count += 1;
        }
        if (count == 0) return false;

        const result = std.process.run(self.gpa, self.io, .{
            .argv = argv[0..count],
            .stdout_limit = .limited(stdout.len),
            .stderr_limit = .limited(stderr.len),
        }) catch |err| {
            lengths.stderr = (std.fmt.bufPrint(stderr, "{t}", .{err}) catch "").len;
            return false;
        };
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);

        lengths.stdout = @min(result.stdout.len, stdout.len);
        @memcpy(stdout[0..lengths.stdout], result.stdout[0..lengths.stdout]);
        lengths.stderr = @min(result.stderr.len, stderr.len);
        @memcpy(stderr[0..lengths.stderr], result.stderr[0..lengths.stderr]);

        return switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

const testing = std.testing;
const canary = providers.canary;

/// A spawner that answers from a script instead of a process.
const Fake = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    ok: bool = true,
    calls: usize = 0,
    saw: []const u8 = "",

    fn runErased(
        context: ?*anyopaque,
        command: []const u8,
        stdout: []u8,
        stderr: []u8,
        lengths: *Spawner.Lengths,
    ) bool {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.saw = command;

        lengths.stdout = @min(self.stdout.len, stdout.len);
        @memcpy(stdout[0..lengths.stdout], self.stdout[0..lengths.stdout]);
        lengths.stderr = @min(self.stderr.len, stderr.len);
        @memcpy(stderr[0..lengths.stderr], self.stderr[0..lengths.stderr]);
        return self.ok;
    }

    fn resolver(self: *Fake) Resolver {
        return .{ .spawner = .{ .context = self, .run = runErased } };
    }
};

test "the flag beats everything else" {
    var fake: Fake = .{ .stdout = "from-command" };
    var resolver = fake.resolver();

    const answer = resolver.resolve(.{
        .flag = "from-flag",
        .environment = "from-env",
        .config_key = "from-config",
        .config_key_cmd = "pass show anthropic",
    });

    try testing.expectEqualStrings("from-flag", answer.key);
    try testing.expectEqual(Origin.flag, answer.origin);
    // And nothing was spawned. Resolving the flag by running a command first
    // would prompt for a passphrase the user did not need to give.
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

test "the environment beats both config sources" {
    var fake: Fake = .{ .stdout = "from-command" };
    var resolver = fake.resolver();

    const answer = resolver.resolve(.{
        .environment = "from-env",
        .config_key = "from-config",
        .config_key_cmd = "pass show anthropic",
    });

    try testing.expectEqualStrings("from-env", answer.key);
    try testing.expectEqual(Origin.environment, answer.origin);
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

test "config key beats key_cmd, whatever the docs prefer" {
    // The order is by immediacy, not by preference: a literal key in a file is
    // more specific than an instruction for fetching one, and a user who wrote
    // both meant the one they typed.
    var fake: Fake = .{ .stdout = "from-command" };
    var resolver = fake.resolver();

    const answer = resolver.resolve(.{
        .config_key = "from-config",
        .config_key_cmd = "pass show anthropic",
    });

    try testing.expectEqualStrings("from-config", answer.key);
    try testing.expectEqual(Origin.config_key, answer.origin);
}

test "key_cmd's stdout is trimmed of the newline every secret store prints" {
    var fake: Fake = .{ .stdout = "sk-ant-from-pass\n" };
    var resolver = fake.resolver();

    const answer = resolver.resolve(.{ .config_key_cmd = "pass show anthropic" });

    try testing.expectEqualStrings("sk-ant-from-pass", answer.key);
    try testing.expectEqual(Origin.config_key_cmd, answer.origin);
    try testing.expectEqualStrings("pass show anthropic", fake.saw);
}

test "key_cmd runs once, however many times the key is asked for" {
    var fake: Fake = .{ .stdout = "sk-ant-from-pass\n" };
    var resolver = fake.resolver();

    const sources: Sources = .{ .config_key_cmd = "pass show anthropic" };
    for (0..5) |_| {
        try testing.expectEqualStrings("sk-ant-from-pass", resolver.resolve(sources).key);
    }
    // Once. Per turn would mean a passphrase prompt per turn.
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "a failing key_cmd surfaces its stderr" {
    var fake: Fake = .{ .ok = false, .stderr = "gpg: decryption failed: No secret key\n" };
    var resolver = fake.resolver();

    const answer = resolver.resolve(.{ .config_key_cmd = "pass show anthropic" });

    try testing.expectEqual(@as(usize, 0), answer.key.len);
    try testing.expect(std.mem.indexOf(u8, answer.problem.?, "gpg: decryption failed") != null);
}

test "a failing key_cmd that leaks a key does not leak it onward" {
    // A secret store's error message is exactly the kind of place a key gets
    // printed by accident.
    var fake: Fake = .{
        .ok = false,
        .stderr = "could not decrypt entry for " ++ canary.key ++ "\n",
    };
    var resolver = fake.resolver();

    const answer = resolver.resolve(.{ .config_key_cmd = "pass show anthropic" });

    try testing.expect(!canary.contains(answer.problem.?));
    try testing.expect(std.mem.indexOf(u8, answer.problem.?, "could not decrypt") != null);
}

test "a key_cmd that succeeds and prints nothing is a problem, not a key" {
    var fake: Fake = .{ .stdout = "  \n" };
    var resolver = fake.resolver();

    const answer = resolver.resolve(.{ .config_key_cmd = "pass show anthropic" });
    try testing.expectEqual(@as(usize, 0), answer.key.len);
    try testing.expect(answer.problem != null);
}

test "a failing key_cmd that says nothing still says something" {
    var fake: Fake = .{ .ok = false };
    var resolver = fake.resolver();

    const answer = resolver.resolve(.{ .config_key_cmd = "pass show anthropic" });
    try testing.expect(answer.problem.?.len > 0);
}

test "no source at all is an absence, not an error" {
    // The missing-key message with the export line is the frontend's job: it is
    // the only thing that knows which preset was asked for.
    var fake: Fake = .{};
    var resolver = fake.resolver();

    const answer = resolver.resolve(.{});
    try testing.expectEqual(@as(usize, 0), answer.key.len);
    try testing.expectEqual(Origin.none, answer.origin);
    try testing.expect(answer.problem == null);
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

test "a key longer than the buffer is truncated rather than overflowing it" {
    const long = "sk-" ++ ("x" ** (max_key_bytes * 2));
    var fake: Fake = .{ .stdout = long };
    var resolver = fake.resolver();

    const answer = resolver.resolve(.{ .config_key_cmd = "cat /dev/urandom" });
    try testing.expect(answer.key.len <= max_key_bytes);
}

test "the resolved key survives the buffer the command printed into" {
    // `key_cmd`'s output lives in a stack buffer inside `compute`. If `keep` did
    // not copy, this key would be a dangling slice the moment `resolve` returned
    // — and it would usually still read correctly, which is what makes it worth
    // a test rather than a comment.
    var fake: Fake = .{ .stdout = "sk-ant-from-pass\n" };
    var resolver = fake.resolver();

    const answer = resolver.resolve(.{ .config_key_cmd = "pass show anthropic" });

    var noise: [4096]u8 = undefined;
    @memset(&noise, 0xAA);
    std.mem.doNotOptimizeAway(&noise);

    try testing.expectEqualStrings("sk-ant-from-pass", answer.key);
}
