const std = @import("std");
const math = @import("../core/math.zig");
const MeshModule = @import("core/mesh.zig");
const direct_batch = @import("direct_batch.zig");

pub const Mesh = MeshModule.Mesh;
pub const Triangle = MeshModule.Triangle;

pub const MeshInstance = struct {
    transform: math.Mat4 = math.Mat4.identity(),
    material_override: ?direct_batch.SurfaceMaterial = null,
};

pub fn appendMeshTriangles(
    batch: *direct_batch.PrimitiveBatch,
    mesh: *const Mesh,
    instance: MeshInstance,
) !void {
    for (mesh.triangles) |triangle| {
        try batch.appendTriangle(.{
            .a = instance.transform.mulVec3(mesh.vertices[triangle.v0]),
            .b = instance.transform.mulVec3(mesh.vertices[triangle.v1]),
            .c = instance.transform.mulVec3(mesh.vertices[triangle.v2]),
        }, resolveTriangleMaterial(triangle, instance.material_override));
    }
}

fn resolveTriangleMaterial(
    triangle: Triangle,
    material_override: ?direct_batch.SurfaceMaterial,
) direct_batch.SurfaceMaterial {
    return material_override orelse .{
        .fill_color = triangle.base_color,
        .outline_color = 0xFFFFFFFF,
        .depth = 1.0,
    };
}

test "append mesh triangles emits one packet per triangle" {
    var mesh = try Mesh.triangle(std.testing.allocator);
    defer mesh.deinit();
    var batch = direct_batch.PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();

    try appendMeshTriangles(&batch, &mesh, .{
        .transform = math.Mat4.translate(0.0, 0.0, 3.0),
        .material_override = .{ .fill_color = 0xFFCC8844, .outline_color = 0xFFFFFFFF, .depth = 1.0 },
    });

    try std.testing.expectEqual(@as(usize, 1), batch.items().len);
    try std.testing.expect(batch.items()[0] == .triangle);
}
