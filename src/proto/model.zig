//! What a model is, and what it costs.
//!
//! Prices are data, not knowledge: they drift, they differ per account, and a
//! harness that hardcodes them silently reports the wrong number forever. The
//! table ships with defaults and the config overrides any entry (Phase 6). An
//! unknown model has a zero price and renders tokens without a cost, which is
//! honest — a guess would not be.

const std = @import("std");

const stream = @import("stream.zig");

pub const ProviderId = enum { anthropic, openai_compat, mock };

/// US dollars per million tokens.
///
/// Four numbers because prompt caching is priced on three of them. A single
/// input price would make the cache invisible in exactly the version that turns
/// caching on, which is the one place the number has to be right to be worth
/// printing.
pub const Price = struct {
    input_per_mtok: f64 = 0,
    output_per_mtok: f64 = 0,
    cache_read_per_mtok: f64 = 0,
    cache_write_per_mtok: f64 = 0,
};

pub const Model = struct {
    id: []const u8,
    provider: ProviderId,
    context_window: u32,
    price: Price = .{},

    /// Dollars for one request's usage.
    ///
    /// f64 throughout: these are cents-to-dollars numbers being displayed once,
    /// never accumulated into a ledger. Fixed-point micro-dollars would buy
    /// precision that nothing in v0.2 spends.
    pub fn cost(self: Model, usage: stream.Usage) f64 {
        const per_mtok = 1_000_000.0;

        const input: f64 = @floatFromInt(usage.input_tokens);
        const output: f64 = @floatFromInt(usage.output_tokens);
        const cache_read: f64 = @floatFromInt(usage.cache_read_tokens);
        const cache_write: f64 = @floatFromInt(usage.cache_creation_tokens);

        return (input * self.price.input_per_mtok +
            output * self.price.output_per_mtok +
            cache_read * self.price.cache_read_per_mtok +
            cache_write * self.price.cache_write_per_mtok) / per_mtok;
    }
};

test "cost prices cached input apart from fresh input" {
    const m: Model = .{
        .id = "test-model",
        .provider = .anthropic,
        .context_window = 200_000,
        .price = .{
            .input_per_mtok = 3.0,
            .output_per_mtok = 15.0,
            .cache_read_per_mtok = 0.3,
            .cache_write_per_mtok = 3.75,
        },
    };
    const usage: stream.Usage = .{
        .input_tokens = 1_000_000,
        .output_tokens = 1_000_000,
        .cache_read_tokens = 1_000_000,
        .cache_creation_tokens = 1_000_000,
    };

    // 3.0 + 15.0 + 0.3 + 3.75
    try std.testing.expectApproxEqAbs(@as(f64, 22.05), m.cost(usage), 1e-9);
}

test "a cache read costs a tenth of the same tokens read fresh" {
    const m: Model = .{
        .id = "test-model",
        .provider = .anthropic,
        .context_window = 200_000,
        .price = .{ .input_per_mtok = 3.0, .cache_read_per_mtok = 0.3 },
    };

    const fresh = m.cost(.{ .input_tokens = 500_000 });
    const cached = m.cost(.{ .cache_read_tokens = 500_000 });

    // The whole reason the fields are separate: this ratio is the feature
    // automatic prompt caching is bought for, and it has to be visible.
    try std.testing.expectApproxEqAbs(fresh / 10.0, cached, 1e-12);
}

test "a zero-price model costs nothing rather than guessing" {
    const m: Model = .{
        .id = "local-llama",
        .provider = .openai_compat,
        .context_window = 8192,
    };
    try std.testing.expectEqual(@as(f64, 0), m.cost(.{ .input_tokens = 500 }));
}
