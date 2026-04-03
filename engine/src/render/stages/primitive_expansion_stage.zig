const std = @import("std");
const job_system = @import("job_system");
const direct_batch = @import("../direct_batch.zig");
const direct_mesh = @import("../direct_mesh.zig");
const direct_meshlets = @import("../direct_meshlets.zig");
const visible_scene = @import("../visible_scene.zig");

const JobSystem = job_system.JobSystem;

pub const Result = struct {
    primitive_count: usize,
};

pub fn execute(
    scene: *const visible_scene.VisibleScene,
    batch: *direct_batch.PrimitiveBatch,
    job_sys: ?*JobSystem,
) !Result {
    batch.clearRetainingCapacity();
    if (scene.items().len == 0) return .{ .primitive_count = 0 };

    if (scene.items().len == 1 and scene.items()[0] == .mesh) {
        const payload = scene.items()[0].mesh;
        try batch.ensureCommandCapacity(payload.mesh.triangles.len);
        try direct_mesh.appendMeshTriangles(batch, payload.mesh, .{
            .transform = payload.transform,
            .material_override = payload.material_override,
        });
        return .{ .primitive_count = batch.items().len };
    }

    try batch.ensureCommandCapacity(estimatePrimitiveCapacity(scene));
    for (scene.items()) |packet| {
        switch (packet) {
            .primitive => |visible_packet| switch (visible_packet.source) {
                .line => |payload| {
                    try batch.appendLine(.{
                        .start = visible_packet.transform.mulVec3(payload.line.start),
                        .end = visible_packet.transform.mulVec3(payload.line.end),
                    }, payload.material);
                },
                .triangle => |payload| {
                    try batch.appendTriangle(.{
                        .a = visible_packet.transform.mulVec3(payload.triangle.a),
                        .b = visible_packet.transform.mulVec3(payload.triangle.b),
                        .c = visible_packet.transform.mulVec3(payload.triangle.c),
                    }, payload.material);
                },
                .polygon => |payload| {
                    var transformed: [direct_batch.max_polygon_points]@import("../../core/math.zig").Vec3 = undefined;
                    const points = payload.polygon.slice();
                    for (points, 0..) |point, index| {
                        transformed[index] = visible_packet.transform.mulVec3(point);
                    }
                    try batch.appendPolygon(transformed[0..points.len], payload.material);
                },
                .circle => |payload| {
                    try batch.appendCircle(.{
                        .center = visible_packet.transform.mulVec3(payload.circle.center),
                        .radius = payload.circle.radius,
                    }, payload.material);
                },
            },
            .mesh => |payload| {
                try direct_mesh.appendMeshTriangles(batch, payload.mesh, .{
                    .transform = payload.transform,
                    .material_override = payload.material_override,
                });
            },
            .meshlets => |payload| {
                var visible = direct_meshlets.VisibleMeshlets.init(batch.allocator);
                defer visible.deinit();
                try visible.indices.appendSlice(batch.allocator, scene.meshlet_indices.items[payload.visible_offset .. payload.visible_offset + payload.visible_count]);
                if (job_sys) |js| {
                    try direct_meshlets.appendVisibleMeshletsToBatchParallel(batch, payload.mesh, &visible, .{
                        .transform = payload.transform,
                        .material_override = payload.material_override,
                    }, batch.allocator, js);
                } else {
                    try direct_meshlets.appendVisibleMeshletsToBatch(batch, payload.mesh, &visible, .{
                        .transform = payload.transform,
                        .material_override = payload.material_override,
                    });
                }
            },
        }
    }
    return .{ .primitive_count = batch.items().len };
}

fn estimatePrimitiveCapacity(scene: *const visible_scene.VisibleScene) usize {
    var count: usize = 0;
    for (scene.items()) |packet| {
        switch (packet) {
            .primitive => count += 1,
            .mesh => |payload| count += payload.mesh.triangles.len,
            .meshlets => |payload| {
                for (scene.meshlet_indices.items[payload.visible_offset .. payload.visible_offset + payload.visible_count]) |meshlet_index| {
                    count += payload.mesh.meshletPrimitiveSlice(&payload.mesh.meshlets[meshlet_index]).len;
                }
            },
        }
    }
    return count;
}

test "primitive expansion stage expands meshlet-visible packets into primitive batch" {
    var scene = visible_scene.VisibleScene.init(std.testing.allocator);
    defer scene.deinit();
    var mesh = try direct_meshlets.Mesh.cube(std.testing.allocator);
    defer mesh.deinit();
    try direct_meshlets.ensureMeshlets(&mesh, std.testing.allocator);
    try scene.meshlet_indices.append(std.testing.allocator, 0);
    try scene.append(.{ .meshlets = .{
        .transform = @import("../../core/math.zig").Mat4.translate(0.0, 0.0, 4.0),
        .mesh = &mesh,
        .material_override = null,
        .visible_offset = 0,
        .visible_count = 1,
    } });

    var batch = direct_batch.PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    const result = try execute(&scene, &batch, null);

    try std.testing.expect(result.primitive_count > 0);
    try std.testing.expect(batch.items().len > 0);
}
