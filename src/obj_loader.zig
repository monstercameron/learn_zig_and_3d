const std = @import("std");
const math = @import("math.zig");
const Mesh = @import("mesh.zig").Mesh;
const Triangle = @import("mesh.zig").Triangle;
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Mesh {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    var positions = std.ArrayList(Vec3){};
    defer positions.deinit(allocator);

    var bounds_min = Vec3.new(0.0, 0.0, 0.0);
    var bounds_max = Vec3.new(0.0, 0.0, 0.0);
    var has_bounds = false;
    var mesh_center = Vec3.new(0.0, 0.0, 0.0);

    var texcoords = std.ArrayList(Vec2){};
    defer texcoords.deinit(allocator);

    var normals = std.ArrayList(Vec3){};
    defer normals.deinit(allocator);

    var final_vertices = std.ArrayList(Vec3){};
    defer final_vertices.deinit(allocator);

    var final_texcoords = std.ArrayList(Vec2){};
    defer final_texcoords.deinit(allocator);

    var triangles = std.ArrayList(Triangle){};
    defer triangles.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

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

            if (!has_bounds) {
                bounds_min = pos;
                bounds_max = pos;
                has_bounds = true;
            } else {
                bounds_min = Vec3.new(@min(bounds_min.x, pos.x), @min(bounds_min.y, pos.y), @min(bounds_min.z, pos.z));
                bounds_max = Vec3.new(@max(bounds_max.x, pos.x), @max(bounds_max.y, pos.y), @max(bounds_max.z, pos.z));
            }

            mesh_center = Vec3.scale(Vec3.add(bounds_min, bounds_max), 0.5);
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
            const v = Vec2.new(values[0], 1.0 - values[1]);
            try texcoords.append(allocator, v);
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
        } else if (std.mem.startsWith(u8, line, "f ")) {
            var parts = std.mem.tokenizeScalar(u8, line[2..], ' ');
            var face_indices = std.ArrayList(usize){};
            defer face_indices.deinit(allocator);

            var face_normals = std.ArrayList(Vec3){};
            defer face_normals.deinit(allocator);

            while (parts.next()) |part| {
                if (part.len == 0) continue;
                var sub_parts = std.mem.splitScalar(u8, part, '/');
                const v_str = sub_parts.next() orelse return error.InvalidFace;
                const vt_str = sub_parts.next();
                const vn_str = sub_parts.next();

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

                try final_vertices.append(allocator, pos);
                try final_texcoords.append(allocator, uv);
                try face_indices.append(allocator, final_vertices.items.len - 1);
                try face_normals.append(allocator, normal_vec);
            }

            if (face_indices.items.len < 3) return error.InvalidFace;
            if (!has_bounds) return error.EmptyMesh;

            // Triangulate the face using a fan
            var i: usize = 2;
            while (i < face_indices.items.len) : (i += 1) {
                const idx0 = face_indices.items[0];
                var idx1 = face_indices.items[i - 1];
                var idx2 = face_indices.items[i];

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
                        if (count > 0) {
                            reference = Vec3.scale(sum, 1.0 / @as(f32, @floatFromInt(count)));
                        }
                    }

                    if (Vec3.length(reference) > threshold and Vec3.dot(tri_normal, reference) < 0) {
                        std.mem.swap(usize, &idx1, &idx2);
                    }
                } else {
                    const v0 = final_vertices.items[idx0];
                    const v1 = final_vertices.items[idx1];
                    const v2 = final_vertices.items[idx2];
                    const tri_normal = Vec3.cross(Vec3.sub(v1, v0), Vec3.sub(v2, v0));
                    const normal_len = Vec3.length(tri_normal);
                    if (normal_len > 0.0001) {
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

    const vertex_slice = try allocator.alloc(Vec3, final_vertices.items.len);
    std.mem.copyForwards(Vec3, vertex_slice, final_vertices.items);

    const texcoord_slice = try allocator.alloc(Vec2, final_texcoords.items.len);
    std.mem.copyForwards(Vec2, texcoord_slice, final_texcoords.items);

    const triangle_slice = try allocator.alloc(Triangle, triangles.items.len);
    std.mem.copyForwards(Triangle, triangle_slice, triangles.items);

    var mesh = Mesh{
        .vertices = vertex_slice,
        .triangles = triangle_slice,
        .normals = try allocator.alloc(Vec3, triangle_slice.len),
        .tex_coords = texcoord_slice,
        .allocator = allocator,
    };

    mesh.recalculateNormals();

    return mesh;
}
