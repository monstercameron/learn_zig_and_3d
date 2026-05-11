//! Runtime glue for `iq_scanner`. Reads `ZIG_IQ_SCAN=1` (or sets a
//! frame-specific filter) and provides a single `tryScan()` entry point
//! that:
//!
//!   1. Captures a snapshot of `target.color` *before* a pass runs.
//!   2. Calls the pass.
//!   3. Captures *after*, runs the scanner, prints one JSON line to
//!      stderr/stdout. Claude Code parses it.
//!
//! Off by default — when the env var isn't set, `tryScan` is a thin
//! pass-through with no allocation cost.

const std = @import("std");
const iq_scanner = @import("iq_scanner.zig");

var enabled_initialized: bool = false;
var enabled_cached: bool = false;
var scratch_pixels: []u32 = &.{};
var scratch_owner: ?std.mem.Allocator = null;

pub fn isEnabled() bool {
    if (enabled_initialized) return enabled_cached;
    enabled_initialized = true;
    enabled_cached = std.process.hasEnvVarConstant("ZIG_IQ_SCAN");
    return enabled_cached;
}

/// Allocate/reuse a scratch buffer of `total` u32 pixels. Cheap on the
/// hot path: only grows.
fn ensureScratch(allocator: std.mem.Allocator, total: usize) ![]u32 {
    if (scratch_pixels.len >= total) return scratch_pixels[0..total];
    if (scratch_owner) |a| a.free(scratch_pixels);
    scratch_pixels = try allocator.alloc(u32, total);
    scratch_owner = allocator;
    return scratch_pixels;
}

/// Snapshot `pixels` into the scratch buffer. Cheap memcpy.
pub fn snapshot(allocator: std.mem.Allocator, pixels: []const u32) ![]const u32 {
    const scratch = try ensureScratch(allocator, pixels.len);
    @memcpy(scratch[0..pixels.len], pixels);
    return scratch[0..pixels.len];
}

/// Compare `before` to current `after_pixels` and emit one JSON line
/// to stderr. The scanner is silent if `ZIG_IQ_SCAN` is unset.
pub fn reportPass(
    pass_name: []const u8,
    width: i32,
    height: i32,
    before_pixels: []const u32,
    after_pixels: []const u32,
    depth: ?[]const f32,
) void {
    if (!isEnabled()) return;
    const snap: iq_scanner.Snapshot = .{
        .pixels = before_pixels,
        .depth = depth,
        .width = width,
        .height = height,
    };
    const r = iq_scanner.compare(snap, after_pixels, pass_name);
    const stderr = std.fs.File.stderr();
    var writer = stderr.writer(&.{});
    writer.interface.print("IQ_SCAN ", .{}) catch return;
    r.writeJsonLine(&writer.interface) catch return;
    writer.interface.flush() catch return;
}
