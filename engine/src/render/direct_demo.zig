const std = @import("std");
const math = @import("../core/math.zig");
const TileRenderer = @import("core/tile_renderer.zig");
const direct_batch = @import("direct_batch.zig");
const direct_primitives = @import("direct_primitives.zig");
const direct_draw_list = @import("direct_draw_list.zig");

pub const AuxiliaryBuffers = struct {
    scene_camera: []math.Vec3,
    scene_normal: []math.Vec3,
    scene_surface: []TileRenderer.SurfaceHandle,
};

pub const FrameResources = struct {
    target: direct_primitives.FrameTarget,
    aux: AuxiliaryBuffers,
};

pub const FrameTimings = struct {
    clear_ns: i128 = 0,
    build_batch_ns: i128 = 0,
    compile_draw_list_ns: i128 = 0,
    raster_ns: i128 = 0,
    present_ns: i128 = 0,
};

pub fn clearFrame(
    resources: FrameResources,
    clear: direct_primitives.ClearConfig,
) void {
    direct_primitives.clear(resources.target, clear);
    @memset(resources.aux.scene_camera, math.Vec3.new(0.0, 0.0, 0.0));
    @memset(resources.aux.scene_normal, math.Vec3.new(0.0, 0.0, 0.0));
    @memset(resources.aux.scene_surface, TileRenderer.SurfaceHandle.invalid());
}

pub fn buildPrimitiveShowcase(
    batch: *direct_batch.PrimitiveBatch,
) !void {
    batch.clearRetainingCapacity();

    try batch.appendLine(.{
        .start = math.Vec3.new(-2.4, 1.4, 0.0),
        .end = math.Vec3.new(-1.1, 0.2, 0.0),
    }, .{ .color = 0xFF7FDBFF });

    try batch.appendTriangle(.{
        .a = math.Vec3.new(0.0, 1.35, 0.0),
        .b = math.Vec3.new(-1.0, -0.25, 0.0),
        .c = math.Vec3.new(1.0, -0.25, 0.0),
    }, .{ .fill_color = 0xFFFF8A3D, .outline_color = 0xFFFFFFFF, .depth = 1.0 });

    const polygon_points = [_]math.Vec3{
        math.Vec3.new(1.2, 1.3, 0.0),
        math.Vec3.new(1.9, 1.55, 0.0),
        math.Vec3.new(2.45, 1.05, 0.0),
        math.Vec3.new(2.25, 0.25, 0.0),
        math.Vec3.new(1.45, 0.05, 0.0),
        math.Vec3.new(0.95, 0.65, 0.0),
    };
    try batch.appendPolygon(polygon_points[0..], .{ .fill_color = 0xFF38D39F, .outline_color = 0xFFFFFFFF, .depth = 1.0 });

    try batch.appendCircle(.{
        .center = math.Vec3.new(1.65, -1.15, 0.0),
        .radius = 0.72,
    }, .{ .fill_color = 0xFFB95CFF, .outline_color = 0xFFFFFFFF, .depth = 1.0 });
}

pub fn rasterize(resources: FrameResources, draw_list: *const direct_draw_list.DrawList) void {
    direct_primitives.drawMany(resources.target, draw_list.items());
}

test "primitive showcase builds expected command mix" {
    var batch = direct_batch.PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();

    try buildPrimitiveShowcase(&batch);

    try std.testing.expectEqual(@as(usize, 4), batch.items().len);
    try std.testing.expect(batch.items()[0] == .line);
    try std.testing.expect(batch.items()[1] == .triangle);
    try std.testing.expect(batch.items()[2] == .polygon);
    try std.testing.expect(batch.items()[3] == .circle);
}
