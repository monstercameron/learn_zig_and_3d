const std = @import("std");
const math = @import("core/math.zig");
const mesh_module = @import("render/core/mesh.zig");
const gltf_loader = @import("assets/gltf_loader.zig");
const obj_loader = @import("assets/obj_loader.zig");
const scene_runtime = @import("scene_main");
const log = @import("core/log.zig");

const LoadedSceneAsset = scene_runtime.LoadedSceneAsset;

const app_logger = log.get("app.main");

pub fn loadGltfMeshAsset(allocator: std.mem.Allocator, asset: LoadedSceneAsset) !mesh_module.Mesh {
    if (gltf_loader.load(allocator, asset.model_path)) |mesh| {
        var resolved_mesh = mesh;
        applyRequestedNormalMode(&resolved_mesh, asset.smooth_normals);
        applyRequestedTrianglePalette(&resolved_mesh, asset.triangle_palette);
        if (asset.base_color) |base_color| applyRequestedBaseColor(&resolved_mesh, base_color.x, base_color.y, base_color.z);
        applyRequestedLighting(&resolved_mesh, asset.lit);
        app_logger.infoSub("assets", "loaded gltf asset from {s}", .{asset.model_path});
        return resolved_mesh;
    } else |err| {
        app_logger.warn("scene gltf load failed for {s}: {s}", .{ asset.model_path, @errorName(err) });
    }
    if (asset.fallback_model_path) |fallback_path| {
        var fallback_mesh = try obj_loader.load(allocator, fallback_path);
        applyRequestedNormalMode(&fallback_mesh, asset.smooth_normals);
        applyRequestedTrianglePalette(&fallback_mesh, asset.triangle_palette);
        if (asset.base_color) |base_color| applyRequestedBaseColor(&fallback_mesh, base_color.x, base_color.y, base_color.z);
        applyRequestedLighting(&fallback_mesh, asset.lit);
        app_logger.infoSub("assets", "loaded fallback obj from {s}", .{fallback_path});
        return fallback_mesh;
    }
    return error.SceneModelLoadFailed;
}

pub fn loadObjMeshAsset(allocator: std.mem.Allocator, asset: LoadedSceneAsset) !mesh_module.Mesh {
    var mesh = try obj_loader.load(allocator, asset.model_path);
    if (asset.apply_cornell_palette) applyCornellColors(&mesh);
    applyRequestedNormalMode(&mesh, asset.smooth_normals);
    applyRequestedTrianglePalette(&mesh, asset.triangle_palette);
    if (asset.base_color) |base_color| applyRequestedBaseColor(&mesh, base_color.x, base_color.y, base_color.z);
    applyRequestedLighting(&mesh, asset.lit);
    app_logger.infoSub("assets", "loaded obj asset from {s}", .{asset.model_path});
    return mesh;
}

fn applyRequestedNormalMode(mesh: *mesh_module.Mesh, smooth_normals: ?bool) void {
    const requested = smooth_normals orelse return;
    mesh.recalculateNormals();
    for (mesh.triangles) |*tri| tri.flat_shaded = !requested;
    if (requested) {
        mesh.recalculateVertexNormals();
    } else {
        mesh.recalculateFlatVertexNormals();
    }
}

fn applyRequestedTrianglePalette(mesh: *mesh_module.Mesh, triangle_palette: ?[]const u8) void {
    const palette = triangle_palette orelse return;
    if (std.ascii.eqlIgnoreCase(palette, "internal_tricolor")) {
        applyInteriorTricolorPalette(mesh);
        return;
    }
    app_logger.warn("unknown triangle palette: {s}", .{palette});
}

fn applyRequestedBaseColor(mesh: *mesh_module.Mesh, r: f32, g: f32, b: f32) void {
    const packed_color = packRgbColor(r, g, b);
    for (mesh.triangles) |*tri| tri.base_color = packed_color;
}

fn applyRequestedLighting(mesh: *mesh_module.Mesh, lit: ?bool) void {
    const enabled = lit orelse return;
    for (mesh.triangles) |*tri| tri.lit = enabled;
}

fn packRgbColor(r: f32, g: f32, b: f32) u32 {
    const to_u8 = struct {
        fn convert(value: f32) u32 {
            return @intFromFloat(std.math.clamp(value, 0.0, 1.0) * 255.0 + 0.5);
        }
    }.convert;
    return 0xFF000000 |
        (to_u8(r) << 16) |
        (to_u8(g) << 8) |
        to_u8(b);
}

pub fn appendMesh(allocator: std.mem.Allocator, target: *mesh_module.Mesh, source: *const mesh_module.Mesh) !void {
    const old_vertex_count = target.vertices.len;
    const old_triangle_count = target.triangles.len;
    const new_vertex_count = old_vertex_count + source.vertices.len;
    const new_triangle_count = old_triangle_count + source.triangles.len;

    const new_vertices = try allocator.alloc(math.Vec3, new_vertex_count);
    errdefer allocator.free(new_vertices);
    const new_tex_coords = try allocator.alloc(math.Vec2, new_vertex_count);
    errdefer allocator.free(new_tex_coords);
    const new_triangles = try allocator.alloc(mesh_module.Triangle, new_triangle_count);
    errdefer allocator.free(new_triangles);
    const new_normals = try allocator.alloc(math.Vec3, new_triangle_count);
    errdefer allocator.free(new_normals);
    const new_vertex_normals = try allocator.alloc(math.Vec3, new_vertex_count);
    errdefer allocator.free(new_vertex_normals);

    std.mem.copyForwards(math.Vec3, new_vertices[0..old_vertex_count], target.vertices);
    std.mem.copyForwards(math.Vec2, new_tex_coords[0..old_vertex_count], target.tex_coords);
    std.mem.copyForwards(mesh_module.Triangle, new_triangles[0..old_triangle_count], target.triangles);
    std.mem.copyForwards(math.Vec3, new_normals[0..old_triangle_count], target.normals);
    std.mem.copyForwards(math.Vec3, new_vertex_normals[0..old_vertex_count], target.vertex_normals);

    std.mem.copyForwards(math.Vec3, new_vertices[old_vertex_count..], source.vertices);
    std.mem.copyForwards(math.Vec2, new_tex_coords[old_vertex_count..], source.tex_coords);
    std.mem.copyForwards(math.Vec3, new_vertex_normals[old_vertex_count..], source.vertex_normals);
    for (source.triangles, 0..) |tri, i| {
        var shifted = tri;
        shifted.v0 += old_vertex_count;
        shifted.v1 += old_vertex_count;
        shifted.v2 += old_vertex_count;
        new_triangles[old_triangle_count + i] = shifted;
    }
    std.mem.copyForwards(math.Vec3, new_normals[old_triangle_count..], source.normals);

    allocator.free(target.vertices);
    allocator.free(target.tex_coords);
    allocator.free(target.triangles);
    allocator.free(target.normals);
    allocator.free(target.vertex_normals);
    target.vertices = new_vertices;
    target.tex_coords = new_tex_coords;
    target.triangles = new_triangles;
    target.normals = new_normals;
    target.vertex_normals = new_vertex_normals;
    target.clearMeshlets();
}

pub fn transformPoint(v: math.Vec3, position: math.Vec3, rotation_deg: math.Vec3, scale: math.Vec3) math.Vec3 {
    const scaled = math.Vec3.new(v.x * scale.x, v.y * scale.y, v.z * scale.z);
    const rotated = rotateVector(scaled, rotation_deg);
    return math.Vec3.add(rotated, position);
}

pub fn rotateVector(v: math.Vec3, rotation_deg: math.Vec3) math.Vec3 {
    const rad_scale = std.math.pi / 180.0;
    const rx = rotation_deg.x * rad_scale;
    const ry = rotation_deg.y * rad_scale;
    const rz = rotation_deg.z * rad_scale;

    const sx = @sin(rx);
    const cx = @cos(rx);
    const sy = @sin(ry);
    const cy = @cos(ry);
    const sz = @sin(rz);
    const cz = @cos(rz);

    const x1 = v.x;
    const y1 = v.y * cx - v.z * sx;
    const z1 = v.y * sx + v.z * cx;

    const x2 = x1 * cy + z1 * sy;
    const y2 = y1;
    const z2 = -x1 * sy + z1 * cy;

    return math.Vec3.new(
        x2 * cz - y2 * sz,
        x2 * sz + y2 * cz,
        z2,
    );
}

fn applyCornellColors(mesh: *mesh_module.Mesh) void {
    const white: u32 = 0xFFE6E6E6;
    const red: u32 = 0xFFD84B4B;
    const green: u32 = 0xFF6AD36A;

    if (mesh.vertices.len == 0) return;
    var bounds_min = mesh.vertices[0];
    var bounds_max = mesh.vertices[0];
    for (mesh.vertices[1..]) |v| {
        bounds_min = math.Vec3.min(bounds_min, v);
        bounds_max = math.Vec3.max(bounds_max, v);
    }
    const span_x = @max(bounds_max.x - bounds_min.x, 1e-3);
    const left_limit = bounds_min.x + span_x * 0.2;
    const right_limit = bounds_max.x - span_x * 0.2;

    for (mesh.triangles, 0..) |*tri, i| {
        const v0 = mesh.vertices[tri.v0];
        const v1 = mesh.vertices[tri.v1];
        const v2 = mesh.vertices[tri.v2];
        const center = math.Vec3.scale(math.Vec3.add(math.Vec3.add(v0, v1), v2), 1.0 / 3.0);
        const normal = if (i < mesh.normals.len) mesh.normals[i] else math.Vec3.cross(math.Vec3.sub(v1, v0), math.Vec3.sub(v2, v0)).normalize();
        const abs_x = @abs(normal.x);
        const abs_y = @abs(normal.y);
        const abs_z = @abs(normal.z);
        tri.base_color = if (abs_x > abs_y and abs_x > abs_z and center.x <= left_limit)
            red
        else if (abs_x > abs_y and abs_x > abs_z and center.x >= right_limit)
            green
        else
            white;
        tri.double_sided = true;
    }
}

fn applyInteriorTricolorPalette(mesh: *mesh_module.Mesh) void {
    const palette = [_]u32{
        0xFFE0584A,
        0xFF48B2E8,
        0xFFF2C14E,
    };
    for (mesh.triangles, 0..) |*tri, i| {
        tri.base_color = palette[i % palette.len];
        tri.double_sided = false;
    }
}

pub fn levelAppendGroundPlane(mesh: *mesh_module.Mesh, allocator: std.mem.Allocator) !void {
    const plane_extent: f32 = 40.0;
    const plane_y: f32 = -1.0;
    const start_vertex = mesh.vertices.len;
    const start_triangle = mesh.triangles.len;

    const new_vertices = try allocator.alloc(math.Vec3, mesh.vertices.len + 4);
    errdefer allocator.free(new_vertices);
    const new_tex_coords = try allocator.alloc(math.Vec2, mesh.tex_coords.len + 4);
    errdefer allocator.free(new_tex_coords);
    const new_triangles = try allocator.alloc(mesh_module.Triangle, mesh.triangles.len + 2);
    errdefer allocator.free(new_triangles);
    const new_normals = try allocator.alloc(math.Vec3, mesh.normals.len + 2);
    errdefer allocator.free(new_normals);

    std.mem.copyForwards(math.Vec3, new_vertices[0..mesh.vertices.len], mesh.vertices);
    std.mem.copyForwards(math.Vec2, new_tex_coords[0..mesh.tex_coords.len], mesh.tex_coords);
    std.mem.copyForwards(mesh_module.Triangle, new_triangles[0..mesh.triangles.len], mesh.triangles);
    std.mem.copyForwards(math.Vec3, new_normals[0..mesh.normals.len], mesh.normals);

    new_vertices[start_vertex + 0] = math.Vec3.new(-plane_extent, plane_y, -plane_extent);
    new_vertices[start_vertex + 1] = math.Vec3.new(plane_extent, plane_y, -plane_extent);
    new_vertices[start_vertex + 2] = math.Vec3.new(plane_extent, plane_y, plane_extent);
    new_vertices[start_vertex + 3] = math.Vec3.new(-plane_extent, plane_y, plane_extent);

    new_tex_coords[start_vertex + 0] = math.Vec2.new(0.0, 0.0);
    new_tex_coords[start_vertex + 1] = math.Vec2.new(1.0, 0.0);
    new_tex_coords[start_vertex + 2] = math.Vec2.new(1.0, 1.0);
    new_tex_coords[start_vertex + 3] = math.Vec2.new(0.0, 1.0);

    new_triangles[start_triangle + 0] = mesh_module.Triangle.newWithColor(start_vertex + 0, start_vertex + 2, start_vertex + 1, 0xFF4A4A4A);
    new_triangles[start_triangle + 1] = mesh_module.Triangle.newWithColor(start_vertex + 0, start_vertex + 3, start_vertex + 2, 0xFF4A4A4A);
    new_normals[start_triangle + 0] = math.Vec3.new(0.0, 1.0, 0.0);
    new_normals[start_triangle + 1] = math.Vec3.new(0.0, 1.0, 0.0);

    allocator.free(mesh.vertices);
    allocator.free(mesh.tex_coords);
    allocator.free(mesh.triangles);
    allocator.free(mesh.normals);
    mesh.vertices = new_vertices;
    mesh.tex_coords = new_tex_coords;
    mesh.triangles = new_triangles;
    mesh.normals = new_normals;
    mesh.clearMeshlets();
}