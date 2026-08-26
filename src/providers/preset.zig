//! Six servers, one table.
//!
//! A preset is a base URL, a path, an auth shape and the name of the
//! environment variable a key comes from. Everything else about talking to
//! these services is identical, which is the entire argument for
//! `openai-compat` being one implementation rather than six.
//!
//! Quirk notes are dated comments. A quirk without a date is a quirk nobody can
//! decide is stale.

const std = @import("std");

pub const Shape = enum {
    /// The Anthropic Messages API.
    anthropic,
    /// The OpenAI chat-completions shape, and the five servers that speak it.
    openai,
};

pub const Auth = enum {
    /// `x-api-key`, plus the dated version header Anthropic wants.
    x_api_key,
    /// `Authorization: Bearer …`.
    bearer,
    /// None sent at all. Not an empty bearer — a header that means nothing is
    /// worse than no header, because it looks deliberate.
    none,
};

pub const Preset = struct {
    name: []const u8,
    shape: Shape,
    base_url: []const u8,
    path: []const u8,
    auth: Auth,
    /// The environment variable a key is read from. Empty when `auth` is
    /// `.none`, and the missing-key message is built from it, so a preset that
    /// needs a key and names no variable is a preset that cannot tell a user
    /// what to do.
    env_var: []const u8,
    /// True when `base_url` points at this machine. The plaintext policy in the
    /// transport allows `http://` only to loopback, and this flag is the table's
    /// half of that agreement — a test asserts the two never disagree.
    loopback: bool,
};

pub const table = [_]Preset{
    .{
        .name = "anthropic",
        .shape = .anthropic,
        .base_url = "https://api.anthropic.com",
        .path = "/v1/messages",
        .auth = .x_api_key,
        .env_var = "ANTHROPIC_API_KEY",
        .loopback = false,
    },
    .{
        .name = "openai",
        .shape = .openai,
        .base_url = "https://api.openai.com",
        .path = "/v1/chat/completions",
        .auth = .bearer,
        .env_var = "OPENAI_API_KEY",
        .loopback = false,
    },
    .{
        .name = "openrouter",
        .shape = .openai,
        .base_url = "https://openrouter.ai/api",
        .path = "/v1/chat/completions",
        .auth = .bearer,
        .env_var = "OPENROUTER_API_KEY",
        .loopback = false,
    },
    .{
        .name = "groq",
        .shape = .openai,
        .base_url = "https://api.groq.com/openai",
        .path = "/v1/chat/completions",
        .auth = .bearer,
        .env_var = "GROQ_API_KEY",
        .loopback = false,
    },
    .{
        .name = "ollama",
        .shape = .openai,
        .base_url = "http://127.0.0.1:11434",
        .path = "/v1/chat/completions",
        // 2026-08: Ollama accepts any Authorization header, including none.
        // Sending an empty bearer would be a header that means nothing.
        .auth = .none,
        .env_var = "",
        .loopback = true,
    },
    .{
        .name = "lmstudio",
        .shape = .openai,
        .base_url = "http://127.0.0.1:1234",
        .path = "/v1/chat/completions",
        // 2026-08: LM Studio's server ignores auth entirely.
        .auth = .none,
        .env_var = "",
        .loopback = true,
    },
    .{
        .name = "vllm",
        .shape = .openai,
        // 2026-08: vLLM is self-hosted, so there is no canonical host. The
        // loopback default is a guess that is right on a developer's machine and
        // wrong everywhere else, which is what the config override is for.
        .base_url = "http://127.0.0.1:8000",
        .path = "/v1/chat/completions",
        .auth = .bearer,
        .env_var = "VLLM_API_KEY",
        .loopback = true,
    },
};

/// The preset with this name, or null.
///
/// Null rather than a default: silently falling back to one provider when a user
/// typed another's name wrong would send a key to the wrong host.
pub fn find(name: []const u8) ?Preset {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Writes the full endpoint URL into `out`.
pub fn url(entry: Preset, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "{s}{s}", .{ entry.base_url, entry.path }) catch entry.base_url;
}

const testing = std.testing;

test "every preset resolves by name" {
    for (table) |entry| try testing.expect(find(entry.name) != null);
}

test "an unknown preset is null rather than a default" {
    // Silently falling back to OpenAI would send a key to the wrong host.
    try testing.expect(find("openai-but-typo") == null);
    try testing.expect(find("") == null);
}

test "the plaintext presets are the loopback ones" {
    // The transport's plaintext policy and this table have to agree, or a user
    // gets a refusal from a preset tug shipped.
    for (table) |entry| {
        const plaintext = std.mem.startsWith(u8, entry.base_url, "http://");
        try testing.expectEqual(plaintext, entry.loopback);
    }
}

test "the transport agrees that every loopback preset is loopback" {
    // Two implementations of "is this the local machine" would eventually
    // disagree. This is the test that notices on the day they do.
    const http = @import("transport/http.zig");
    var buffer: [128]u8 = undefined;
    for (table) |entry| {
        try testing.expectEqual(entry.loopback, http.isLoopback(url(entry, &buffer)));
    }
}

test "every preset that needs a key names the variable it comes from" {
    for (table) |entry| {
        switch (entry.auth) {
            .none => try testing.expectEqual(@as(usize, 0), entry.env_var.len),
            .x_api_key, .bearer => try testing.expect(entry.env_var.len > 0),
        }
    }
}

test "every preset builds a URL that parses" {
    var buffer: [128]u8 = undefined;
    for (table) |entry| {
        const full = url(entry, &buffer);
        const uri = try std.Uri.parse(full);
        try testing.expect(uri.host != null);
        try testing.expect(std.mem.endsWith(u8, full, entry.path));
    }
}

test "names are unique" {
    // A duplicate would make `find` return whichever came first, silently.
    for (table, 0..) |entry, i| {
        for (table[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, entry.name, other.name));
        }
    }
}
