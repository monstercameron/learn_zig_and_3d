//! # Meshlet Builder
//!
//! Generates meshlets for a mesh using a small, CPU-friendly representation.
//! Meshlets are filled greedily until a vertex or primitive budget is about to be
//! exceeded, matching the runtime regeneration fallback.

const std = @import("std");
const log = @import("log.zig");
const MeshModule = @import("mesh.zig");
const Mesh = MeshModule.Mesh;

const logger = log.get("meshlet.builder");

pub const BuildConfig = struct {
    /// Upper bound for unique vertices per meshlet.
    max_vertices_per_meshlet: u32 = 64,
    /// Upper bound for triangle primitives per meshlet. A value of 126 mirrors common GPU limits.
    max_triangles_per_meshlet: u32 = 126,

    fn validate(self: BuildConfig) void {
        std.debug.assert(self.max_vertices_per_meshlet >= 3);
        std.debug.assert(self.max_triangles_per_meshlet >= 1);
    }
};

/// Populates `mesh.meshlets` using the same greedy packing strategy as the
/// runtime `Mesh.generateMeshlets` helper. Triangles are appended to the current
/// meshlet until the vertex or primitive budget would be exceeded, at which
/// point a new meshlet is started. This keeps the loader/cache path in sync with
/// the runtime regeneration fallback while respecting the supplied limits.
pub fn buildMeshlets(allocator: std.mem.Allocator, mesh: *Mesh, config: BuildConfig) !void {
    _ = allocator; // Mesh owns its allocator; keep the signature stable for now.
    config.validate();

    const max_vertices = @as(usize, @intCast(config.max_vertices_per_meshlet));
    const max_triangles = @as(usize, @intCast(config.max_triangles_per_meshlet));
    try mesh.generateMeshlets(max_vertices, max_triangles);

    const meshlets = mesh.meshlets;
    const meshlet_count = meshlets.len;
    if (meshlet_count == 0) {
        logger.info(
            "meshlet build produced 0 meshlets (triangles={})",
            .{mesh.triangles.len},
        );
        return;
    }

    var total_triangles: usize = 0;
    var min_triangles: usize = std.math.maxInt(usize);
    var max_triangles_seen: usize = 0;
    var total_vertices: usize = 0;
    var min_vertices: usize = std.math.maxInt(usize);
    var max_vertices_seen: usize = 0;

    for (meshlets) |meshlet| {
        const tri_count = meshlet.triangle_indices.len;
        const vert_count = meshlet.vertex_indices.len;

        total_triangles += tri_count;
        total_vertices += vert_count;

        if (tri_count < min_triangles) min_triangles = tri_count;
        if (tri_count > max_triangles_seen) max_triangles_seen = tri_count;
        if (vert_count < min_vertices) min_vertices = vert_count;
        if (vert_count > max_vertices_seen) max_vertices_seen = vert_count;
    }

    const avg_triangles = @as(f64, @floatFromInt(total_triangles)) / @as(f64, @floatFromInt(meshlet_count));
    const avg_vertices = @as(f64, @floatFromInt(total_vertices)) / @as(f64, @floatFromInt(meshlet_count));

    logger.info(
        "meshlets built count={} total_tris={} avg_tris={d:.2} tri_range=[{}, {}] avg_verts={d:.2} vert_range=[{}, {}] limits(v={}, t={})",
        .{
            meshlet_count,
            total_triangles,
            avg_triangles,
            min_triangles,
            max_triangles_seen,
            avg_vertices,
            min_vertices,
            max_vertices_seen,
            max_vertices,
            max_triangles,
        },
    );
}
