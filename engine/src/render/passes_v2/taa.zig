//! Temporal antialiasing (v2). Blends the current frame with a
//! history buffer using a stable mix. Cheap minimal implementation:
//! no reprojection (TAA-without-jitter), just a fixed exponential
//! lowpass between current and history. Works well when the camera
//! doesn't move; ghosts otherwise.
//!
//! Drivers should disable this pass on cache-miss frames where the
//! geometry changed significantly. The descriptor declares it
//! non-idempotent for safety.

const std = @import("std");
const v2 = @import("mod.zig");

pub const descriptor: v2.Descriptor = .{
    .name = "taa",
    .idempotent = false,
    .requires_scratch = false,
    .reads_gbuffer = true,
    .summary = "Temporal AA via history-buffer lowpass blend.",
};

pub const Config = struct {
    /// 0..1; weight of the history frame in the blend. 0 = no TAA,
    /// 1 = pure history (frozen frame).
    history_weight: f32 = 0.82,
    /// Whether the history is valid this frame. Set to false on the
    /// first frame after a camera teleport or scene reload.
    history_valid: bool = true,
};

/// Blends `history` into `inputs.out_color` (which starts as
/// `inputs.in_color`) using `history_weight`. History buffer must
/// match the inputs' pixel count.
pub fn execute(inputs: v2.Inputs, history: []u32, config: Config) v2.Result {
    var result: v2.Result = .{};
    if (!config.history_valid or config.history_weight <= 0.0) return result;
    if (inputs.in_color.len == 0 or inputs.in_color.len != inputs.out_color.len) return result;
    if (history.len != inputs.in_color.len) return result;

    const k = std.math.clamp(config.history_weight, 0.0, 1.0);
    const inv = 1.0 - k;
    var modified: usize = 0;
    var idx: usize = 0;
    while (idx < inputs.in_color.len) : (idx += 1) {
        const cur = inputs.in_color[idx];
        const hist = history[idx];
        const cr: f32 = @floatFromInt((cur >> 16) & 0xFF);
        const cg: f32 = @floatFromInt((cur >> 8) & 0xFF);
        const cb: f32 = @floatFromInt(cur & 0xFF);
        const hr: f32 = @floatFromInt((hist >> 16) & 0xFF);
        const hg: f32 = @floatFromInt((hist >> 8) & 0xFF);
        const hb: f32 = @floatFromInt(hist & 0xFF);
        const or_: u32 = @intFromFloat(std.math.clamp(cr * inv + hr * k, 0.0, 255.0));
        const og: u32 = @intFromFloat(std.math.clamp(cg * inv + hg * k, 0.0, 255.0));
        const ob: u32 = @intFromFloat(std.math.clamp(cb * inv + hb * k, 0.0, 255.0));
        inputs.out_color[idx] = (cur & 0xFF000000) | (or_ << 16) | (og << 8) | ob;
        if (inputs.out_color[idx] != cur) modified += 1;
    }
    result.pixels_modified = modified;
    return result;
}
