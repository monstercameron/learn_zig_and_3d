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
    if (mesh.triangles.len == 0) return;

    const identity_transform = isIdentityTransform(instance.transform);
    const vertices = mesh.vertices;
    const vertex_normals = mesh.vertex_normals;
    const triangles = mesh.triangles;
    try batch.ensureCommandCapacity(batch.items().len + triangles.len);

    if (instance.material_override) |material_override| {
        if (identity_transform) {
            for (triangles, 0..) |triangle, tri_index| {
                const lighting_normals = resolveTriangleNormals(mesh, triangle, tri_index, vertex_normals);
                batch.appendTriangleLitAssumeCapacity(.{
                    .a = vertices[triangle.v0],
                    .b = vertices[triangle.v1],
                    .c = vertices[triangle.v2],
                }, material_override, lighting_normals);
            }
            return;
        }

        for (triangles, 0..) |triangle, tri_index| {
            const lighting_normals = resolveTriangleNormals(mesh, triangle, tri_index, vertex_normals);
            batch.appendTriangleLitAssumeCapacity(.{
                .a = instance.transform.mulVec3(vertices[triangle.v0]),
                .b = instance.transform.mulVec3(vertices[triangle.v1]),
                .c = instance.transform.mulVec3(vertices[triangle.v2]),
            }, material_override, lighting_normals);
        }
        return;
    }

    for (triangles, 0..) |triangle, tri_index| {
        const world_triangle: direct_batch.WorldTriangle = .{
            .a = if (identity_transform) vertices[triangle.v0] else instance.transform.mulVec3(vertices[triangle.v0]),
            .b = if (identity_transform) vertices[triangle.v1] else instance.transform.mulVec3(vertices[triangle.v1]),
            .c = if (identity_transform) vertices[triangle.v2] else instance.transform.mulVec3(vertices[triangle.v2]),
        };
        batch.appendTriangleLitAssumeCapacity(world_triangle, resolveTriangleMaterial(triangle, null), resolveTriangleNormals(mesh, triangle, tri_index, vertex_normals));
    }
}

inline fn resolveTriangleNormals(
    mesh: *const Mesh,
    triangle: Triangle,
    tri_index: usize,
    vertex_normals: []const math.Vec3,
) [3]math.Vec3 {
    if (triangle.flat_shaded and tri_index < mesh.normals.len) {
        const face_normal = mesh.normals[tri_index];
        return .{ face_normal, face_normal, face_normal };
    }
    return .{
        vertex_normals[triangle.v0],
        vertex_normals[triangle.v1],
        vertex_normals[triangle.v2],
    };
}

inline fn isIdentityTransform(transform: math.Mat4) bool {
    return std.mem.eql(f32, transform.data[0..], math.Mat4.identity().data[0..]);
}

fn resolveTriangleMaterial(
    triangle: Triangle,
    material_override: ?direct_batch.SurfaceMaterial,
) direct_batch.SurfaceMaterial {
    return material_override orelse .{
        .fill_color = triangle.base_color,
        .outline_color = null,
        .depth = 1.0,
        .cull_backfaces = !triangle.double_sided,
    };
}

test "append mesh triangles emits one packet per triangle" {
    var mesh = try Mesh.triangle(std.testing.allocator);
    defer mesh.deinit();
    var batch = direct_batch.PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();

    try appendMeshTriangles(&batch, &mesh, .{
        .transform = math.Mat4.translate(0.0, 0.0, 3.0),
        .material_override = .{ .fill_color = 0xFFCC8844, .outline_color = null, .depth = 1.0 },
    });

    try std.testing.expectEqual(@as(usize, 1), batch.items().len);
    try std.testing.expect(batch.items()[0] == .triangle);
}
