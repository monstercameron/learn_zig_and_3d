const math = @import("../../core/math.zig");
const shadow_raster_kernel = @import("../kernels/shadow_raster_kernel.zig");

pub fn rasterizeShadowMeshRange(mesh: anytype, shadow: anytype, start_row: usize, end_row: usize, light_dir_world: math.Vec3, max_shadow_meshlet_vertices: usize) void {
    if (!shadow.active) return;

    const basis = shadow.basis_right;
    const basis_up = shadow.basis_up;
    const basis_forward = shadow.basis_forward;

    for (mesh.meshlets) |*meshlet| {
        const meshlet_vertices = mesh.meshletVertexSlice(meshlet);
        if (meshlet_vertices.len > max_shadow_meshlet_vertices) continue;

        var local_light_vertices: [64]math.Vec3 = undefined;
        for (meshlet_vertices, 0..) |global_idx, local_idx| {
            const world = mesh.vertices[global_idx];
            local_light_vertices[local_idx] = math.Vec3.new(
                math.Vec3.dot(world, basis),
                math.Vec3.dot(world, basis_up),
                math.Vec3.dot(world, basis_forward),
            );
        }

        for (mesh.meshletPrimitiveSlice(meshlet)) |primitive| {
            const tri_idx = primitive.triangle_index;
            if (tri_idx >= mesh.normals.len) continue;

            const normal = mesh.normals[tri_idx];
            if (math.Vec3.dot(normal, light_dir_world) <= 0.0) continue;

            const p0 = local_light_vertices[@as(usize, primitive.local_v0)];
            const p1 = local_light_vertices[@as(usize, primitive.local_v1)];
            const p2 = local_light_vertices[@as(usize, primitive.local_v2)];
            shadow_raster_kernel.rasterizeTriangleRows(shadow, start_row, end_row, p0, p1, p2);
        }
    }
}
