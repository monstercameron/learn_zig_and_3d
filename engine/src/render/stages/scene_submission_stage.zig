const std = @import("std");
const direct_mesh = @import("../direct_mesh.zig");
const math = @import("../../core/math.zig");
const direct_batch = @import("../direct_batch.zig");
const direct_meshlets = @import("../direct_meshlets.zig");
const direct_scene_packets = @import("../direct_scene_packets.zig");

pub const Result = struct {
    packet_count: usize,
};

pub const SceneKind = enum {
    triangle,
    suzanne_showcase,
    perf_showcase,
    primitive_showcase,
};

pub fn execute(
    packets: *direct_scene_packets.PacketList,
    showcase_mesh: *direct_meshlets.Mesh,
    suzanne_mesh: *const direct_mesh.Mesh,
    kind: SceneKind,
) !Result {
    packets.clearRetainingCapacity();
    try packets.ensureCapacity(switch (kind) {
        .triangle => 1,
        .suzanne_showcase => 1,
        .perf_showcase => 4,
        .primitive_showcase => 5,
    });

    switch (kind) {
        .triangle => {
            try packets.append(.{
                .source = .{ .triangle = .{
                    .triangle = .{
                        .a = math.Vec3.new(0.0, 0.75, 0.0),
                        .b = math.Vec3.new(-0.6, -0.4, 0.0),
                        .c = math.Vec3.new(0.6, -0.4, 0.0),
                    },
                    .material = .{ .fill_color = 0xFFFF8A3D, .outline_color = null, .depth = null },
                } },
            });
            return .{ .packet_count = packets.items().len };
        },
        .suzanne_showcase => {
            try packets.append(.{
                .transform = math.Mat4.identity(),
                .source = .{ .mesh = .{
                    .mesh = suzanne_mesh,
                    .material_override = .{
                        .fill_color = 0xFFD8C3A5,
                        .outline_color = null,
                        .depth = 1.0,
                    },
                } },
            });
            return .{ .packet_count = packets.items().len };
        },
        .perf_showcase => {
            try packets.append(.{
                .source = .{ .line = .{
                    .line = .{
                        .start = math.Vec3.new(-1.35, 0.75, 0.0),
                        .end = math.Vec3.new(-0.65, 0.15, 0.0),
                    },
                    .material = .{ .color = 0xFF7FDBFF },
                } },
            });
            try packets.append(.{
                .source = .{ .triangle = .{
                    .triangle = .{
                        .a = math.Vec3.new(-0.1, 0.92, 0.0),
                        .b = math.Vec3.new(-0.72, -0.08, 0.0),
                        .c = math.Vec3.new(0.46, -0.08, 0.0),
                    },
                    .material = .{ .fill_color = 0xFFFF8A3D, .outline_color = null, .depth = 1.0 },
                } },
            });

            const perf_polygon_points = [_]math.Vec3{
                math.Vec3.new(0.85, 0.85, 0.0),
                math.Vec3.new(1.45, 1.02, 0.0),
                math.Vec3.new(1.75, 0.45, 0.0),
                math.Vec3.new(1.35, -0.02, 0.0),
                math.Vec3.new(0.78, 0.24, 0.0),
            };
            try packets.append(.{
                .source = .{ .polygon = .{
                    .polygon = try direct_batch.WorldPolygon.fromSlice(perf_polygon_points[0..]),
                    .material = .{ .fill_color = 0xFF38D39F, .outline_color = null, .depth = 1.0 },
                } },
            });

            try packets.append(.{
                .source = .{ .circle = .{
                    .circle = .{
                        .center = math.Vec3.new(1.15, -0.72, 0.0),
                        .radius = 0.42,
                    },
                    .material = .{ .fill_color = 0xFFB95CFF, .outline_color = null, .depth = 1.0 },
                } },
            });
            return .{ .packet_count = packets.items().len };
        },
        .primitive_showcase => {},
    }

    try packets.append(.{
        .source = .{ .line = .{
            .line = .{
                .start = math.Vec3.new(-2.4, 1.4, 0.0),
                .end = math.Vec3.new(-1.1, 0.2, 0.0),
            },
            .material = .{ .color = 0xFF7FDBFF },
        } },
    });
    try packets.append(.{
        .source = .{ .triangle = .{
            .triangle = .{
                .a = math.Vec3.new(0.0, 1.35, 0.0),
                .b = math.Vec3.new(-1.0, -0.25, 0.0),
                .c = math.Vec3.new(1.0, -0.25, 0.0),
            },
            .material = .{ .fill_color = 0xFFFF8A3D, .outline_color = 0xFFFFFFFF, .depth = 1.0 },
        } },
    });

    const polygon_points = [_]math.Vec3{
        math.Vec3.new(1.2, 1.3, 0.0),
        math.Vec3.new(1.9, 1.55, 0.0),
        math.Vec3.new(2.45, 1.05, 0.0),
        math.Vec3.new(2.25, 0.25, 0.0),
        math.Vec3.new(1.45, 0.05, 0.0),
        math.Vec3.new(0.95, 0.65, 0.0),
    };
    try packets.append(.{
        .source = .{ .polygon = .{
            .polygon = try direct_batch.WorldPolygon.fromSlice(polygon_points[0..]),
            .material = .{ .fill_color = 0xFF38D39F, .outline_color = 0xFFFFFFFF, .depth = 1.0 },
        } },
    });

    try packets.append(.{
        .source = .{ .circle = .{
            .circle = .{
                .center = math.Vec3.new(1.65, -1.15, 0.0),
                .radius = 0.72,
            },
            .material = .{ .fill_color = 0xFFB95CFF, .outline_color = 0xFFFFFFFF, .depth = 1.0 },
        } },
    });

    try packets.append(.{
        .transform = math.Mat4.multiply(
            math.Mat4.translate(0.0, 0.0, 5.5),
            math.Mat4.scale(0.8, 0.8, 0.8),
        ),
        .source = .{ .meshlets = .{
            .mesh = showcase_mesh,
            .material_override = .{ .fill_color = 0xFFD9D3C7, .outline_color = null, .depth = 1.0 },
        } },
    });

    return .{ .packet_count = packets.items().len };
}

pub fn executeMeshScene(
    packets: *direct_scene_packets.PacketList,
    mesh: *const direct_mesh.Mesh,
    transform: math.Mat4,
    material_override: ?direct_batch.SurfaceMaterial,
) !Result {
    packets.clearRetainingCapacity();
    if (mesh.triangles.len == 0) return .{ .packet_count = 0 };
    try packets.ensureCapacity(1);
    packets.appendAssumeCapacity(.{
        .transform = transform,
        .source = .{ .mesh = .{
            .mesh = mesh,
            .material_override = material_override,
        } },
    });
    return .{ .packet_count = packets.items().len };
}

test "scene submission stage builds expected showcase packets" {
    var packets = direct_scene_packets.PacketList.init(std.testing.allocator);
    defer packets.deinit();
    var mesh = try direct_meshlets.Mesh.cube(std.testing.allocator);
    defer mesh.deinit();
    try direct_meshlets.ensureMeshlets(&mesh, std.testing.allocator);
    var suzanne = try direct_mesh.Mesh.triangle(std.testing.allocator);
    defer suzanne.deinit();

    const result = try execute(&packets, &mesh, &suzanne, .primitive_showcase);

    try std.testing.expectEqual(@as(usize, 5), result.packet_count);
    try std.testing.expectEqual(@as(usize, 5), packets.items().len);
}

test "scene submission stage builds expected perf showcase packets" {
    var packets = direct_scene_packets.PacketList.init(std.testing.allocator);
    defer packets.deinit();
    var mesh = try direct_meshlets.Mesh.cube(std.testing.allocator);
    defer mesh.deinit();
    try direct_meshlets.ensureMeshlets(&mesh, std.testing.allocator);
    var suzanne = try direct_mesh.Mesh.triangle(std.testing.allocator);
    defer suzanne.deinit();

    const result = try execute(&packets, &mesh, &suzanne, .perf_showcase);

    try std.testing.expectEqual(@as(usize, 4), result.packet_count);
    try std.testing.expectEqual(@as(usize, 4), packets.items().len);
}

test "scene submission stage can build a single triangle scene" {
    var packets = direct_scene_packets.PacketList.init(std.testing.allocator);
    defer packets.deinit();
    var mesh = try direct_meshlets.Mesh.cube(std.testing.allocator);
    defer mesh.deinit();
    try direct_meshlets.ensureMeshlets(&mesh, std.testing.allocator);
    var suzanne = try direct_mesh.Mesh.triangle(std.testing.allocator);
    defer suzanne.deinit();

    const result = try execute(&packets, &mesh, &suzanne, .triangle);

    try std.testing.expectEqual(@as(usize, 1), result.packet_count);
    try std.testing.expectEqual(@as(usize, 1), packets.items().len);
    try std.testing.expect(packets.items()[0].source == .triangle);
}

test "scene submission stage can build a suzanne mesh scene" {
    var packets = direct_scene_packets.PacketList.init(std.testing.allocator);
    defer packets.deinit();
    var mesh = try direct_meshlets.Mesh.cube(std.testing.allocator);
    defer mesh.deinit();
    try direct_meshlets.ensureMeshlets(&mesh, std.testing.allocator);
    var suzanne = try direct_mesh.Mesh.triangle(std.testing.allocator);
    defer suzanne.deinit();

    const result = try execute(&packets, &mesh, &suzanne, .suzanne_showcase);

    try std.testing.expectEqual(@as(usize, 1), result.packet_count);
    try std.testing.expectEqual(@as(usize, 1), packets.items().len);
    try std.testing.expect(packets.items()[0].source == .mesh);
}
