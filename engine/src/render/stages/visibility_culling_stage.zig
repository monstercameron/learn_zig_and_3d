const std = @import("std");
const direct_batch = @import("../direct_batch.zig");
const direct_meshlets = @import("../direct_meshlets.zig");
const direct_scene_packets = @import("../direct_scene_packets.zig");
const visible_scene = @import("../visible_scene.zig");

pub const Result = struct {
    visible_packet_count: usize,
    visible_meshlet_count: usize,
};

pub fn execute(
    packets: *const direct_scene_packets.PacketList,
    out_visible: *visible_scene.VisibleScene,
    scratch_visible_meshlets: *direct_meshlets.VisibleMeshlets,
    camera: direct_batch.Camera,
) !Result {
    out_visible.clearRetainingCapacity();
    try out_visible.ensurePacketCapacity(packets.items().len);
    var meshlet_capacity: usize = 0;
    for (packets.items()) |packet| {
        if (packet.source == .meshlets) {
            meshlet_capacity += packet.source.meshlets.mesh.meshlets.len;
        }
    }
    try out_visible.ensureMeshletIndexCapacity(meshlet_capacity);
    var visible_meshlet_count: usize = 0;

    for (packets.items()) |packet| {
        switch (packet.source) {
            .line => |payload| try out_visible.append(.{ .primitive = .{
                .layer = packet.layer,
                .flags = packet.flags,
                .transform = packet.transform,
                .source = .{ .line = .{
                    .line = payload.line,
                    .material = payload.material,
                } },
            } }),
            .triangle => |payload| try out_visible.append(.{ .primitive = .{
                .layer = packet.layer,
                .flags = packet.flags,
                .transform = packet.transform,
                .source = .{ .triangle = .{
                    .triangle = payload.triangle,
                    .material = payload.material,
                } },
            } }),
            .polygon => |payload| try out_visible.append(.{ .primitive = .{
                .layer = packet.layer,
                .flags = packet.flags,
                .transform = packet.transform,
                .source = .{ .polygon = .{
                    .polygon = payload.polygon,
                    .material = payload.material,
                } },
            } }),
            .circle => |payload| try out_visible.append(.{ .primitive = .{
                .layer = packet.layer,
                .flags = packet.flags,
                .transform = packet.transform,
                .source = .{ .circle = .{
                    .circle = payload.circle,
                    .material = payload.material,
                } },
            } }),
            .mesh => |payload| try out_visible.append(.{ .mesh = .{
                .layer = packet.layer,
                .flags = packet.flags,
                .transform = packet.transform,
                .mesh = payload.mesh,
                .material_override = payload.material_override,
            } }),
            .meshlets => |payload| {
                try direct_meshlets.ensureMeshlets(payload.mesh, out_visible.allocator);
                try scratch_visible_meshlets.ensureCapacity(payload.mesh.meshlets.len);
                try direct_meshlets.cullVisibleMeshlets(scratch_visible_meshlets, payload.mesh, .{
                    .transform = packet.transform,
                    .material_override = payload.material_override,
                }, camera);
                const start = out_visible.meshlet_indices.items.len;
                try out_visible.meshlet_indices.appendSlice(out_visible.allocator, scratch_visible_meshlets.indices.items);
                try out_visible.append(.{ .meshlets = .{
                    .layer = packet.layer,
                    .flags = packet.flags,
                    .transform = packet.transform,
                    .mesh = payload.mesh,
                    .material_override = payload.material_override,
                    .visible_offset = start,
                    .visible_count = scratch_visible_meshlets.indices.items.len,
                } });
                visible_meshlet_count += scratch_visible_meshlets.indices.items.len;
            },
        }
    }

    return .{
        .visible_packet_count = out_visible.items().len,
        .visible_meshlet_count = visible_meshlet_count,
    };
}

test "visibility stage preserves visible primitive packets and culls meshlets" {
    var packets = direct_scene_packets.PacketList.init(std.testing.allocator);
    defer packets.deinit();
    var mesh = try direct_meshlets.Mesh.cube(std.testing.allocator);
    defer mesh.deinit();
    try direct_meshlets.ensureMeshlets(&mesh, std.testing.allocator);
    try packets.append(.{
        .source = .{ .line = .{
            .line = .{
                .start = @import("../../core/math.zig").Vec3.new(0.0, 0.0, 3.0),
                .end = @import("../../core/math.zig").Vec3.new(1.0, 0.0, 3.0),
            },
            .material = .{ .color = 0xFFFFFFFF },
        } },
    });
    try packets.append(.{
        .transform = @import("../../core/math.zig").Mat4.translate(0.0, 0.0, 4.0),
        .source = .{ .meshlets = .{ .mesh = &mesh } },
    });

    var out_visible = visible_scene.VisibleScene.init(std.testing.allocator);
    defer out_visible.deinit();
    var scratch = direct_meshlets.VisibleMeshlets.init(std.testing.allocator);
    defer scratch.deinit();

    const result = try execute(&packets, &out_visible, &scratch, .{
        .position = @import("../../core/math.zig").Vec3.new(0.0, 0.0, -3.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 60.0,
    });

    try std.testing.expectEqual(@as(usize, 2), result.visible_packet_count);
    try std.testing.expect(result.visible_meshlet_count > 0);
}
