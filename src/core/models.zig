//! What a model is, what it costs, and which one won.
//!
//! Prices are data, not knowledge. They drift, they differ per account, and a
//! harness that hardcodes them reports the wrong number forever without ever
//! being wrong loudly. The table ships defaults and the config overrides any
//! entry; a model tug has never heard of still works and simply has no price.
//!
//! Freestanding, like everything in `tugcore`. No allocator: overrides are
//! written into a fixed table the caller owns, which is the same arrangement the
//! config already uses for keybindings.

const std = @import("std");

const proto = @import("tugproto");
const config_mod = @import("config/schema.zig");

pub const Layer = config_mod.Layer;

/// How many model entries a config may add or override.
///
/// Generous: a user pinning prices for a whole provider's line-up uses a
/// handful. A file with more than this gets one note, like the keybinding table
/// it is modelled on.
pub const max_overrides = 32;

/// How many aliases a config may define.
pub const max_aliases = 32;

/// The models tug knows about, with the prices they had when this was written.
///
/// **Dated, and expected to be wrong eventually.** Prices are per million
/// tokens, in US dollars, as published in August 2026. A user whose account has
/// different rates pins them in config; that is not a workaround, it is the
/// designed path.
pub const table = [_]proto.Model{
    .{
        .id = "claude-opus-4-5",
        .provider = .anthropic,
        .context_window = 200_000,
        .price = .{
            .input_per_mtok = 5.0,
            .output_per_mtok = 25.0,
            .cache_read_per_mtok = 0.5,
            .cache_write_per_mtok = 6.25,
        },
    },
    .{
        .id = "claude-sonnet-4-5",
        .provider = .anthropic,
        .context_window = 200_000,
        .price = .{
            .input_per_mtok = 3.0,
            .output_per_mtok = 15.0,
            .cache_read_per_mtok = 0.3,
            .cache_write_per_mtok = 3.75,
        },
    },
    .{
        .id = "claude-haiku-4-5",
        .provider = .anthropic,
        .context_window = 200_000,
        .price = .{
            .input_per_mtok = 1.0,
            .output_per_mtok = 5.0,
            .cache_read_per_mtok = 0.1,
            .cache_write_per_mtok = 1.25,
        },
    },
    .{
        .id = "gpt-4.1",
        .provider = .openai_compat,
        .context_window = 1_047_576,
        .price = .{
            .input_per_mtok = 2.0,
            .output_per_mtok = 8.0,
            .cache_read_per_mtok = 0.5,
        },
    },
    .{
        .id = "gpt-4.1-mini",
        .provider = .openai_compat,
        .context_window = 1_047_576,
        .price = .{
            .input_per_mtok = 0.4,
            .output_per_mtok = 1.6,
            .cache_read_per_mtok = 0.1,
        },
    },
    .{
        // Self-hosted, so the price is genuinely zero rather than unknown: the
        // electricity is the user's and tug is not going to guess at it.
        .id = "llama3.1",
        .provider = .openai_compat,
        .context_window = 131_072,
    },
};

/// The default alias set. Short names people actually type.
pub const aliases = [_]Alias{
    .{ .name = "opus", .id = "claude-opus-4-5" },
    .{ .name = "sonnet", .id = "claude-sonnet-4-5" },
    .{ .name = "haiku", .id = "claude-haiku-4-5" },
};

pub const Alias = struct {
    name: []const u8,
    id: []const u8,
};

/// A model as resolved, with everything a usage line needs to be honest.
pub const Resolution = struct {
    model: proto.Model,
    /// Which layer chose this model. `default` means the preset's.
    origin: Layer = .default,
    /// False when nothing knows this model's price. The usage line then renders
    /// tokens and omits the cost, which is honest; a guess would not be.
    priced: bool = false,
    /// True when the name the user typed was an alias.
    aliased: bool = false,
};

/// A config's additions to the built-in table.
///
/// Held by the caller, like `config.Config`'s binding storage, because `tugcore`
/// allocates nothing.
pub const Registry = struct {
    override_storage: [max_overrides]Override = undefined,
    override_count: usize = 0,
    alias_storage: [max_aliases]Alias = undefined,
    alias_count: usize = 0,

    pub const Override = struct {
        id: []const u8,
        price: proto.Price,
        /// Which of the four numbers the config actually named. An override that
        /// reset the untouched fields to zero would silently stop charging for
        /// output, and the config file would look correct.
        set: Fields = .{},
        context_window: ?u32 = null,

        pub const Fields = struct {
            input: bool = false,
            output: bool = false,
            cache_read: bool = false,
            cache_write: bool = false,
        };
    };

    pub fn overrides(self: *const Registry) []const Override {
        return self.override_storage[0..self.override_count];
    }

    pub fn userAliases(self: *const Registry) []const Alias {
        return self.alias_storage[0..self.alias_count];
    }

    /// Records one price override. Returns false when the table is full.
    pub fn addOverride(self: *Registry, entry: Override) bool {
        // An id given twice is the later one winning, which is what layering
        // means everywhere else in the config.
        for (self.override_storage[0..self.override_count]) |*existing| {
            if (std.mem.eql(u8, existing.id, entry.id)) {
                if (entry.set.input) {
                    existing.price.input_per_mtok = entry.price.input_per_mtok;
                    existing.set.input = true;
                }
                if (entry.set.output) {
                    existing.price.output_per_mtok = entry.price.output_per_mtok;
                    existing.set.output = true;
                }
                if (entry.set.cache_read) {
                    existing.price.cache_read_per_mtok = entry.price.cache_read_per_mtok;
                    existing.set.cache_read = true;
                }
                if (entry.set.cache_write) {
                    existing.price.cache_write_per_mtok = entry.price.cache_write_per_mtok;
                    existing.set.cache_write = true;
                }
                if (entry.context_window) |window| existing.context_window = window;
                return true;
            }
        }

        if (self.override_count == self.override_storage.len) return false;
        self.override_storage[self.override_count] = entry;
        self.override_count += 1;
        return true;
    }

    pub fn addAlias(self: *Registry, entry: Alias) bool {
        for (self.alias_storage[0..self.alias_count]) |*existing| {
            if (std.mem.eql(u8, existing.name, entry.name)) {
                existing.id = entry.id;
                return true;
            }
        }
        if (self.alias_count == self.alias_storage.len) return false;
        self.alias_storage[self.alias_count] = entry;
        self.alias_count += 1;
        return true;
    }
};

/// The built-in entry for an id, or null.
pub fn find(id: []const u8) ?proto.Model {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

/// Expands an alias to an id, or returns the input unchanged.
///
/// User aliases first: a config that defines `sonnet` meant it, and a built-in
/// silently winning would make the config file a lie.
pub fn expand(registry: *const Registry, name: []const u8) struct { id: []const u8, aliased: bool } {
    for (registry.userAliases()) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return .{ .id = entry.id, .aliased = true };
    }
    for (aliases) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return .{ .id = entry.id, .aliased = true };
    }
    return .{ .id = name, .aliased = false };
}

/// Resolves a name to a model, applying aliases and price overrides.
pub fn resolve(registry: *const Registry, name: []const u8, origin: Layer) Resolution {
    const expanded = expand(registry, name);

    var answer: Resolution = .{
        .model = find(expanded.id) orelse .{
            // Unknown, and that is allowed. A model tug has never heard of still
            // streams; it simply has no price and no context window to report.
            .id = expanded.id,
            .provider = .openai_compat,
            .context_window = 0,
        },
        .origin = origin,
        .aliased = expanded.aliased,
    };
    answer.priced = find(expanded.id) != null and !isFree(answer.model.price);

    for (registry.overrides()) |entry| {
        if (!std.mem.eql(u8, entry.id, expanded.id)) continue;

        // Only the numbers the config named. Resetting the rest to zero would
        // silently stop charging for output, and the file would look right.
        if (entry.set.input) answer.model.price.input_per_mtok = entry.price.input_per_mtok;
        if (entry.set.output) answer.model.price.output_per_mtok = entry.price.output_per_mtok;
        if (entry.set.cache_read) answer.model.price.cache_read_per_mtok = entry.price.cache_read_per_mtok;
        if (entry.set.cache_write) answer.model.price.cache_write_per_mtok = entry.price.cache_write_per_mtok;
        if (entry.context_window) |window| answer.model.context_window = window;

        answer.priced = !isFree(answer.model.price);
    }

    return answer;
}

fn isFree(price: proto.Price) bool {
    return price.input_per_mtok == 0 and
        price.output_per_mtok == 0 and
        price.cache_read_per_mtok == 0 and
        price.cache_write_per_mtok == 0;
}

const testing = std.testing;

test "every model in the table has an id, a provider and a context window" {
    for (table) |entry| {
        try testing.expect(entry.id.len > 0);
        try testing.expect(entry.context_window > 0);
    }
}

test "ids are unique" {
    for (table, 0..) |entry, i| {
        for (table[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, entry.id, other.id));
        }
    }
}

test "every built-in alias names a model that exists" {
    // An alias to a model tug does not know would resolve to an unpriced
    // unknown, which is a silent way to make `sonnet` stop meaning anything.
    for (aliases) |entry| {
        try testing.expect(find(entry.id) != null);
    }
}

test "an alias resolves to the id it names" {
    const registry: Registry = .{};
    const answer = resolve(&registry, "sonnet", .flag);

    try testing.expectEqualStrings("claude-sonnet-4-5", answer.model.id);
    try testing.expect(answer.aliased);
    try testing.expect(answer.priced);
    try testing.expectEqual(Layer.flag, answer.origin);
}

test "a user alias beats a built-in one" {
    // A config that defines `sonnet` meant it, and a built-in silently winning
    // would make the file a lie.
    var registry: Registry = .{};
    try testing.expect(registry.addAlias(.{ .name = "sonnet", .id = "claude-haiku-4-5" }));

    try testing.expectEqualStrings("claude-haiku-4-5", resolve(&registry, "sonnet", .user).model.id);
}

test "an unknown model resolves to itself with no price" {
    const registry: Registry = .{};
    const answer = resolve(&registry, "some-new-model", .flag);

    try testing.expectEqualStrings("some-new-model", answer.model.id);
    try testing.expect(!answer.priced);
    try testing.expectEqual(@as(f64, 0), answer.model.cost(.{ .input_tokens = 1_000_000 }));
}

test "a self-hosted model is unpriced rather than free-looking" {
    // llama3.1 through Ollama costs electricity, not dollars. `priced = false`
    // is what makes the usage line omit a cost instead of printing $0.00, which
    // would read as a claim rather than an absence.
    const registry: Registry = .{};
    try testing.expect(!resolve(&registry, "llama3.1", .default).priced);
}

test "a price override replaces exactly the numbers it names" {
    var registry: Registry = .{};
    try testing.expect(registry.addOverride(.{
        .id = "claude-sonnet-4-5",
        .price = .{ .input_per_mtok = 1.5 },
        .set = .{ .input = true },
    }));

    const answer = resolve(&registry, "claude-sonnet-4-5", .user);
    try testing.expectEqual(@as(f64, 1.5), answer.model.price.input_per_mtok);
    // Untouched, and this is the whole point: an override that zeroed these
    // would silently stop charging for output and the file would look correct.
    try testing.expectEqual(@as(f64, 15.0), answer.model.price.output_per_mtok);
    try testing.expectEqual(@as(f64, 0.3), answer.model.price.cache_read_per_mtok);
}

test "an override can price a model tug has never heard of" {
    var registry: Registry = .{};
    try testing.expect(registry.addOverride(.{
        .id = "some-new-model",
        .price = .{ .input_per_mtok = 2.0, .output_per_mtok = 6.0 },
        .set = .{ .input = true, .output = true },
        .context_window = 128_000,
    }));

    const answer = resolve(&registry, "some-new-model", .project);
    try testing.expect(answer.priced);
    try testing.expectEqual(@as(u32, 128_000), answer.model.context_window);
    try testing.expectApproxEqAbs(@as(f64, 8.0), answer.model.cost(.{
        .input_tokens = 1_000_000,
        .output_tokens = 1_000_000,
    }), 1e-9);
}

test "the same id overridden twice layers rather than duplicating" {
    var registry: Registry = .{};
    _ = registry.addOverride(.{
        .id = "claude-sonnet-4-5",
        .price = .{ .input_per_mtok = 1.0 },
        .set = .{ .input = true },
    });
    _ = registry.addOverride(.{
        .id = "claude-sonnet-4-5",
        .price = .{ .output_per_mtok = 9.0 },
        .set = .{ .output = true },
    });

    try testing.expectEqual(@as(usize, 1), registry.overrides().len);
    const answer = resolve(&registry, "claude-sonnet-4-5", .user);
    try testing.expectEqual(@as(f64, 1.0), answer.model.price.input_per_mtok);
    try testing.expectEqual(@as(f64, 9.0), answer.model.price.output_per_mtok);
}

test "a full override table refuses rather than overwriting" {
    var registry: Registry = .{};
    var ids: [max_overrides + 1][8]u8 = undefined;
    for (0..max_overrides) |i| {
        const id = std.fmt.bufPrint(&ids[i], "m{d}", .{i}) catch unreachable;
        try testing.expect(registry.addOverride(.{ .id = id, .price = .{} }));
    }
    const last = std.fmt.bufPrint(&ids[max_overrides], "m{d}", .{max_overrides}) catch unreachable;
    try testing.expect(!registry.addOverride(.{ .id = last, .price = .{} }));
}

test "a name that is not an alias passes through unchanged" {
    const registry: Registry = .{};
    const expanded = expand(&registry, "claude-sonnet-4-5");
    try testing.expectEqualStrings("claude-sonnet-4-5", expanded.id);
    try testing.expect(!expanded.aliased);
}
