//! tugproto — the wire vocabulary.
//!
//! Every type that crosses a boundary lives here: stream events, the event
//! catalog, and later the tool schemas, plugin RPC envelopes and `--json`
//! output shapes. One source of truth, so the TypeScript types can be generated
//! from it rather than hand-written and left to rot.
//!
//! This module depends on nothing but `std`, and on no part of `std` that a
//! freestanding target lacks.

pub const stream = @import("stream.zig");
pub const events = @import("events.zig");
pub const request = @import("request.zig");
pub const model = @import("model.zig");

pub const StreamEvent = stream.StreamEvent;
pub const ToolCallDelta = stream.ToolCallDelta;
pub const Usage = stream.Usage;
pub const Stop = stream.Stop;
pub const StopReason = stream.StopReason;
pub const Err = stream.Err;
pub const ErrKind = stream.ErrKind;
pub const Event = events.Event;
pub const Payload = events.Payload;
pub const Role = request.Role;
pub const Content = request.Content;
pub const Message = request.Message;
pub const Request = request.Request;
pub const ProviderId = model.ProviderId;
pub const Price = model.Price;
pub const Model = model.Model;

test {
    @import("std").testing.refAllDecls(@This());
}
