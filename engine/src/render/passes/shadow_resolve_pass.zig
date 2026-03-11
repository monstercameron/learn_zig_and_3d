const math = @import("../../core/math.zig");
const shadow_resolve_kernel = @import("../kernels/shadow_resolve_kernel.zig");

pub fn JobContext(comptime ConfigType: type, comptime ShadowMapType: type) type {
    return struct {
        pixels: []u32,
        camera_buffer: []const math.Vec3,
        width: usize,
        start_row: usize,
        end_row: usize,
        config: ConfigType,
        shadow: *const ShadowMapType,

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
