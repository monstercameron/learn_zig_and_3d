//! # Wavefront .obj File Loader
//! 
//! This module is responsible for parsing 3D models from the Wavefront .obj file format.
//! The .obj format is a simple, text-based format that defines the geometry of a 3D model.
//! 
//! ## The Challenge: De-indexing Vertex Data
//! 
//! A key challenge with the .obj format is that it uses separate indices for vertex
//! positions, texture coordinates (UVs), and normals. For example:
//! 
//! ```
//! # List of all vertex positions
//! v 1.0 1.0 0.0
//! v 1.0 0.0 0.0
//! 
//! # List of all texture coordinates
//! vt 0.5 0.5
//! vt 0.5 0.0
//! 
//! # A face is defined by indexing into the above lists
//! # f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3
//! f 1/1/1 2/2/1 ...
//! ```
//! 
//! Modern graphics hardware (and our `Mesh` struct) expects a single, unified index.
//! Each vertex must have a unique combination of position, UV, and normal.
//! This loader's main job is to "de-index" the .obj data, creating a final list of
//! vertices where we might duplicate position data if it's used with different UVs or normals.

const std = @import("std");
const math = @import("math.zig");
const Mesh = @import("mesh.zig").Mesh;
const Triangle = @import("mesh.zig").Triangle;
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;

/// Loads a mesh from a .obj file path.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Mesh {
    // Read the entire file into memory.
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    // Temporary lists to store the raw data from the .obj file.
    // JS Analogy: `const positions = []; const texcoords = []; const normals = [];`
    var positions = std.ArrayList(Vec3){};
    defer positions.deinit(allocator);
    var texcoords = std.ArrayList(Vec2){};
    defer texcoords.deinit(allocator);
    var normals = std.ArrayList(Vec3){};
    defer normals.deinit(allocator);

    // Lists to build the final, de-indexed mesh data.
    var final_vertices = std.ArrayList(Vec3){};
    defer final_vertices.deinit(allocator);
    var final_texcoords = std.ArrayList(Vec2){};
    defer final_texcoords.deinit(allocator);
    var triangles = std.ArrayList(Triangle){};
    defer triangles.deinit(allocator);

    // Keep track of the mesh bounds to calculate its center.
    var bounds_min = Vec3.new(0.0, 0.0, 0.0);
    var bounds_max = Vec3.new(0.0, 0.0, 0.0);
    var has_bounds = false;
    var mesh_center = Vec3.new(0.0, 0.0, 0.0);

    // Process the file line by line.
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue; // Skip empty lines and comments.

        // --- Parse Vertex Position --- (e.g., "v 1.0 2.0 3.0")
        if (std.mem.startsWith(u8, line, "v ")) {
            var parts = std.mem.tokenizeScalar(u8, line[2..], ' ');
            var values: [3]f32 = undefined;
            var idx: usize = 0;
            while (parts.next()) |part| {
                if (part.len == 0) continue;
                if (idx >= 3) break;
                values[idx] = try std.fmt.parseFloat(f32, part);
                idx += 1;
            }
            if (idx != 3) return error.InvalidVertex;
            const pos = Vec3.new(values[0], values[1], values[2]);
            try positions.append(allocator, pos);

            // Update the mesh bounding box.
            if (!has_bounds) {
                bounds_min = pos;
                bounds_max = pos;
                has_bounds = true;
            } else {
                bounds_min = Vec3.new(@min(bounds_min.x, pos.x), @min(bounds_min.y, pos.y), @min(bounds_min.z, pos.z));
                bounds_max = Vec3.new(@max(bounds_max.x, pos.x), @max(bounds_max.y, pos.y), @max(bounds_max.z, pos.z));
            }
            mesh_center = Vec3.scale(Vec3.add(bounds_min, bounds_max), 0.5);
        
        // --- Parse Texture Coordinate --- (e.g., "vt 0.5 0.5")
        } else if (std.mem.startsWith(u8, line, "vt ")) {
            var parts = std.mem.tokenizeScalar(u8, line[3..], ' ');
            var values: [2]f32 = undefined;
            var idx: usize = 0;
            while (parts.next()) |part| {
                if (part.len == 0) continue;
                if (idx >= 2) break;
                values[idx] = try std.fmt.parseFloat(f32, part);
                idx += 1;
            }
            if (idx != 2) return error.InvalidTexCoord;
            // The .obj format often has (0,0) at the bottom-left, while many graphics APIs
            // expect (0,0) at the top-left. We flip the V coordinate (1.0 - v) to compensate.
            const v = Vec2.new(values[0], 1.0 - values[1]);
            try texcoords.append(allocator, v);

        // --- Parse Vertex Normal --- (e.g., "vn 0.0 1.0 0.0")
        } else if (std.mem.startsWith(u8, line, "vn ")) {
            var parts = std.mem.tokenizeScalar(u8, line[3..], ' ');
            var values: [3]f32 = undefined;
            var idx: usize = 0;
            while (parts.next()) |part| {
                if (part.len == 0) continue;
                if (idx >= 3) break;
                values[idx] = try std.fmt.parseFloat(f32, part);
                idx += 1;
            }
            if (idx != 3) return error.InvalidNormal;
            const normal = Vec3.normalize(Vec3.new(values[0], values[1], values[2]));
            try normals.append(allocator, normal);

        // --- Parse Face --- (e.g., "f 1/1/1 2/2/1 3/3/1")
        } else if (std.mem.startsWith(u8, line, "f ")) {
            var parts = std.mem.tokenizeScalar(u8, line[2..], ' ');
            var face_indices = std.ArrayList(usize){};
            defer face_indices.deinit(allocator);
            var face_normals = std.ArrayList(Vec3){};
            defer face_normals.deinit(allocator);

            // First, parse all vertices in the face definition.
            while (parts.next()) |part| {
                if (part.len == 0) continue;
                var sub_parts = std.mem.splitScalar(u8, part, '/');
                const v_str = sub_parts.next() orelse return error.InvalidFace;
                const vt_str = sub_parts.next();
                const vn_str = sub_parts.next();

                // .obj indices are 1-based, so we subtract 1.
                const v_index = try std.fmt.parseInt(i32, v_str, 10);
                if (v_index <= 0) return error.VertexIndexOutOfRange;
                const v_usize = @as(usize, @intCast(v_index - 1));
                if (v_usize >= positions.items.len) return error.VertexIndexOutOfRange;

                const pos = positions.items[v_usize];

                var uv = Vec2.new(0.0, 0.0);
                if (vt_str) |uv_token| {
                    if (uv_token.len > 0) {
                        const vt_index = try std.fmt.parseInt(i32, uv_token, 10);
                        if (vt_index <= 0) return error.TexCoordIndexOutOfRange;
                        const vt_usize = @as(usize, @intCast(vt_index - 1));
                        if (vt_usize >= texcoords.items.len) return error.TexCoordIndexOutOfRange;
                        uv = texcoords.items[vt_usize];
                    }
                }

                var normal_vec = Vec3.new(0.0, 0.0, 0.0);
                if (vn_str) |n_token| {
                    if (n_token.len > 0) {
                        const vn_index = try std.fmt.parseInt(i32, n_token, 10);
                        if (vn_index <= 0) return error.NormalIndexOutOfRange;
                        const vn_usize = @as(usize, @intCast(vn_index - 1));
                        if (vn_usize >= normals.items.len) return error.NormalIndexOutOfRange;
                        normal_vec = normals.items[vn_usize];
                    }
                }

                // This is the de-indexing step. We create a new, unique vertex in our final
                // list for each `v/vt/vn` combination.
                try final_vertices.append(allocator, pos);
                try final_texcoords.append(allocator, uv);
                try face_indices.append(allocator, final_vertices.items.len - 1);
                try face_normals.append(allocator, normal_vec);
            }

            if (face_indices.items.len < 3) return error.InvalidFace;
            if (!has_bounds) return error.EmptyMesh;

            // Triangulate the face if it's a polygon (has more than 3 vertices).
            // This uses a simple "fan" triangulation from the first vertex.
            var i: usize = 2;
            while (i < face_indices.items.len) : (i += 1) {
                const idx0 = face_indices.items[0];
                var idx1 = face_indices.items[i - 1];
                var idx2 = face_indices.items[i];

                // This block attempts to preserve the original winding order of the face.
                // It compares the normal of the new triangle with the average normal of the face.
                // If they point in opposite directions, it swaps two vertices to flip the winding.
                if (face_normals.items.len == face_indices.items.len) {
                    const v0 = final_vertices.items[idx0];
                    const v1 = final_vertices.items[idx1];
                    const v2 = final_vertices.items[idx2];
                    const tri_normal = Vec3.cross(Vec3.sub(v1, v0), Vec3.sub(v2, v0));

                    var reference = Vec3.new(0.0, 0.0, 0.0);
                    const threshold: f32 = 0.0001;
                    for (face_normals.items) |candidate| {
                        if (Vec3.length(candidate) > threshold) {
                            reference = candidate;
                            break;
                        }
                    }
                    if (Vec3.length(reference) <= threshold) {
                        var sum = Vec3.new(0.0, 0.0, 0.0);
                        var count: usize = 0;
                        for (face_normals.items) |candidate| {
                            if (Vec3.length(candidate) > threshold) {
                                sum = Vec3.add(sum, candidate);
                                count += 1;
                            }
                        }
                        if (count > 0) reference = Vec3.scale(sum, 1.0 / @as(f32, @floatFromInt(count)));
                    }
                    if (Vec3.length(reference) > threshold and Vec3.dot(tri_normal, reference) < 0) {
                        std.mem.swap(usize, &idx1, &idx2);
                    }
                } else {
                    const v0 = final_vertices.items[idx0];
                    const v1 = final_vertices.items[idx1];
                    const v2 = final_vertices.items[idx2];
                    const tri_normal = Vec3.cross(Vec3.sub(v1, v0), Vec3.sub(v2, v0));
                    if (Vec3.length(tri_normal) > 0.0001) {
                        const tri_center = Vec3.scale(Vec3.add(Vec3.add(v0, v1), v2), 1.0 / 3.0);
                        const outward = Vec3.sub(tri_center, mesh_center);
                        if (Vec3.length(outward) > 0.0001 and Vec3.dot(tri_normal, outward) < 0.0) {
                            std.mem.swap(usize, &idx1, &idx2);
                        }
                    }
                }

                try triangles.append(allocator, Triangle.new(idx0, idx1, idx2));
            }
        }
    }

    if (final_vertices.items.len == 0 or triangles.items.len == 0) return error.EmptyMesh;

    // Convert the ArrayLists to final slices for the Mesh struct.
    const vertex_slice = try final_vertices.toOwnedSlice(allocator);
    const texcoord_slice = try final_texcoords.toOwnedSlice(allocator);
    const triangle_slice = try triangles.toOwnedSlice(allocator);

    var mesh = Mesh{
        .vertices = vertex_slice,
        .triangles = triangle_slice,
        .normals = try allocator.alloc(Vec3, triangle_slice.len), // Will be calculated next.
        .tex_coords = texcoord_slice,
        .allocator = allocator,
    };

    // Now that we have the final triangles, calculate the face normals.
    mesh.recalculateNormals();

    return mesh;
}