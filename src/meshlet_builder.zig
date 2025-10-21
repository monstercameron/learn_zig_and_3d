//! # Meshlet Builder
//!
//! Generates meshlets for a mesh using a very small, CPU-friendly representation.
//! The initial implementation keeps things simple by grouping every triangle into its
//! own meshlet, guaranteeing we stay within the target vertex/primitive budgets while
//! laying the groundwork for richer packing heuristics later.

const std = @import("std");
const math = @import("math.zig");
const MeshModule = @import("mesh.zig");
const Mesh = MeshModule.Mesh;
const Meshlet = MeshModule.Meshlet;

pub const BuildConfig = struct {
    /// Upper bound for unique vertices per meshlet. Currently unused by the naive packer
    /// but retained to keep the signature stable as heuristics improve.
    max_vertices_per_meshlet: u32 = 64,
    /// Upper bound for triangle primitives per meshlet. A value of 126 mirrors common GPU limits.
    max_triangles_per_meshlet: u32 = 126,

    fn validate(self: BuildConfig) void {
        std.debug.assert(self.max_vertices_per_meshlet >= 3);
        std.debug.assert(self.max_triangles_per_meshlet >= 1);
    }
};

/// Populates `mesh.meshlets` with a naive one-triangle-per-meshlet partition.
/// This is intentionally conservative so we can start wiring the runtime without
/// immediately investing in sophisticated clustering.
pub fn buildMeshlets(allocator: std.mem.Allocator, mesh: *Mesh, config: BuildConfig) !void {
    config.validate();
    mesh.clearMeshlets();

    const triangle_count = mesh.triangles.len;
    if (triangle_count == 0) {
        mesh.meshlets = &[_]Meshlet{};
        return;
    }

    var meshlets = try allocator.alloc(Meshlet, triangle_count);
    var built_count: usize = 0;
    errdefer {
        var cleanup_index: usize = 0;
        while (cleanup_index < built_count) : (cleanup_index += 1) {
            meshlets[cleanup_index].deinit(allocator);
        }
        allocator.free(meshlets);
    }

    var tri_index: usize = 0;
    while (tri_index < triangle_count) : (tri_index += 1) {
        const tri = mesh.triangles[tri_index];

        const triangle_indices = try allocator.alloc(usize, 1);
        triangle_indices[0] = tri_index;

        const vertex_indices = allocator.alloc(usize, 3) catch |err| {
            allocator.free(triangle_indices);
            return err;
        };
        vertex_indices[0] = tri.v0;
        vertex_indices[1] = tri.v1;
        vertex_indices[2] = tri.v2;

        const v0 = mesh.vertices[tri.v0];
        const v1 = mesh.vertices[tri.v1];
        const v2 = mesh.vertices[tri.v2];
        const center = math.Vec3.scale(math.Vec3.add(math.Vec3.add(v0, v1), v2), 1.0 / 3.0);

        var radius: f32 = 0.0;
        const candidates = [_]math.Vec3{ v0, v1, v2 };
        for (candidates) |vertex| {
            const offset = math.Vec3.sub(vertex, center);
            radius = @max(radius, math.Vec3.length(offset));
        }

        meshlets[tri_index] = Meshlet{
            .vertex_indices = vertex_indices,
            .triangle_indices = triangle_indices,
            .bounds_center = center,
            .bounds_radius = radius,
        };

        built_count += 1;
    }

    mesh.meshlets = meshlets;
}
