//! Applies shadow-map occlusion to lit scene pixels.
//! Reconstructs/uses per-pixel positions, samples shadow depth, and darkens by configured strength.
//! Runs as row stripes and delegates SIMD-heavy scaling to shadow resolve kernels.


const math = @import("../../core/math.zig");
const shadow_resolve_kernel = @import("../kernels/shadow_resolve_kernel.zig");

/// Builds the typed job-context wrapper used by this pass/kernel dispatch.
/// Uses comptime parameters to specialize code paths at compile time instead of branching at runtime.
pub fn JobContext(comptime ConfigType: type, comptime ShadowMapType: type) type {
    return struct {
        pixels: []u32,
        camera_buffer: []const math.Vec3,
        width: usize,
        start_row: usize,
        end_row: usize,
        config: ConfigType,
        shadow: *const ShadowMapType,

        /// Runs this module step with the currently bound configuration.
        /// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
        pub fn run(ctx_ptr: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
            runRows(
                ctx.pixels,
                ctx.camera_buffer,
                ctx.width,
                ctx.start_row,
                ctx.end_row,
                ctx.config,
                ctx.shadow,
            );
        }

        /// Runs rows direct.
        /// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
        pub fn runRowsDirect(
            pixels: []u32,
            camera_buffer: []const math.Vec3,
            width: usize,
            start_row: usize,
            end_row: usize,
            config_value: ConfigType,
            shadow: *const ShadowMapType,
        ) void {
            runRows(pixels, camera_buffer, width, start_row, end_row, config_value, shadow);
        }
    };
}

/// Runs this pass over a `[start_row, end_row)` span.
/// Used by frame-pass orchestration where deterministic ordering and cache-friendly iteration matter for pacing.
pub fn runRows(
    pixels: []u32,
    camera_buffer: anytype,
    width: usize,
    start_row: usize,
    end_row: usize,
    config_value: anytype,
    shadow: anytype,
) void {
    shadow_resolve_kernel.runRows(
        pixels,
        camera_buffer,
        width,
        start_row,
        end_row,
        config_value,
        shadow,
    );
}
