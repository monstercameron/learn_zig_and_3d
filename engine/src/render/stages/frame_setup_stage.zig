const std = @import("std");
const math = @import("../../core/math.zig");
const TileRenderer = @import("../core/tile_renderer.zig");
const direct_primitives = @import("../direct_primitives.zig");
const frame_resources = @import("../frame_resources.zig");

pub const Config = struct {
    clear_color: u32 = 0xFF0B1220,
    clear_depth: ?f32 = std.math.inf(f32),
    clear_auxiliary: bool = true,
};

pub const Result = struct {
    width: i32,
    height: i32,
    color_pixel_count: usize,
};

pub fn execute(resources: frame_resources.FrameResources, config: Config) Result {
    direct_primitives.clear(resources.target, .{
        .color = config.clear_color,
        .depth = config.clear_depth,
    });
    if (config.clear_auxiliary) {
        @memset(resources.aux.scene_camera, math.Vec3.new(0.0, 0.0, 0.0));
        @memset(resources.aux.scene_normal, math.Vec3.new(0.0, 0.0, 0.0));
        @memset(resources.aux.scene_surface, TileRenderer.SurfaceHandle.invalid());
    }

    return .{
        .width = resources.target.width,
        .height = resources.target.height,
        .color_pixel_count = resources.target.color.len,
    };
}

test "frame setup clears color, depth, and aux buffers" {
    var color = [_]u32{0xFFFFFFFF} ** 16;
    var depth = [_]f32{1.0} ** 16;
    var scene_camera = [_]math.Vec3{math.Vec3.new(1.0, 2.0, 3.0)} ** 16;
    var scene_normal = [_]math.Vec3{math.Vec3.new(4.0, 5.0, 6.0)} ** 16;
    var scene_surface = [_]TileRenderer.SurfaceHandle{TileRenderer.SurfaceHandle.init(1, 2, math.Vec3.new(0.0, 0.0, 1.0))} ** 16;

    const result = execute(.{
        .target = .{
            .width = 4,
            .height = 4,
            .color = color[0..],
            .depth = depth[0..],
        },
        .aux = .{
            .scene_camera = scene_camera[0..],
            .scene_normal = scene_normal[0..],
            .scene_surface = scene_surface[0..],
        },
    }, .{
        .clear_color = 0xFF112233,
        .clear_depth = 42.0,
    });

    try std.testing.expectEqual(@as(i32, 4), result.width);
    try std.testing.expectEqual(@as(i32, 4), result.height);
    try std.testing.expectEqual(@as(usize, 16), result.color_pixel_count);
    for (color) |pixel| try std.testing.expectEqual(@as(u32, 0xFF112233), pixel);
    for (depth) |z| try std.testing.expectEqual(@as(f32, 42.0), z);
    for (scene_camera) |v| try std.testing.expectEqual(math.Vec3.new(0.0, 0.0, 0.0), v);
    for (scene_normal) |v| try std.testing.expectEqual(math.Vec3.new(0.0, 0.0, 0.0), v);
    for (scene_surface) |handle| try std.testing.expect(!handle.isValid());
}

test "frame setup can skip auxiliary clears" {
    var color = [_]u32{0xFFFFFFFF} ** 4;
    var depth = [_]f32{1.0} ** 4;
    var scene_camera = [_]math.Vec3{math.Vec3.new(1.0, 2.0, 3.0)} ** 4;
    var scene_normal = [_]math.Vec3{math.Vec3.new(4.0, 5.0, 6.0)} ** 4;
    var scene_surface = [_]TileRenderer.SurfaceHandle{TileRenderer.SurfaceHandle.init(1, 2, math.Vec3.new(0.0, 0.0, 1.0))} ** 4;

    _ = execute(.{
        .target = .{
            .width = 2,
            .height = 2,
            .color = color[0..],
            .depth = depth[0..],
        },
        .aux = .{
            .scene_camera = scene_camera[0..],
            .scene_normal = scene_normal[0..],
            .scene_surface = scene_surface[0..],
        },
    }, .{
        .clear_color = 0xFF445566,
        .clear_depth = null,
        .clear_auxiliary = false,
    });

    for (color) |pixel| try std.testing.expectEqual(@as(u32, 0xFF445566), pixel);
    for (depth) |z| try std.testing.expectEqual(@as(f32, 1.0), z);
    for (scene_camera) |v| try std.testing.expectEqual(math.Vec3.new(1.0, 2.0, 3.0), v);
    for (scene_normal) |v| try std.testing.expectEqual(math.Vec3.new(4.0, 5.0, 6.0), v);
    for (scene_surface) |handle| try std.testing.expect(handle.isValid());
}
