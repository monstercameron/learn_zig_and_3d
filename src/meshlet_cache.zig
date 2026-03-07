//! # Meshlet Cache
//!
//! Serializes meshlet data to disk so subsequent runs can avoid regenerating them.
//! Cache files live under `./cache` and are named after the source OBJ with a
//! wyhash-based suffix to avoid collisions when models share the same filename.

const std = @import("std");
const math = @import("math.zig");
const MeshModule = @import("mesh.zig");
const Mesh = MeshModule.Mesh;
const Meshlet = MeshModule.Meshlet;
const MeshletPrimitive = MeshModule.MeshletPrimitive;

const cache_magic = "MSHL";
const cache_version: u32 = 4;

const CacheError = error{
    InvalidCacheData,
    VersionMismatch,
    CountMismatch,
    FingerprintMismatch,
    IndexOutOfRange,
    Overflow,
};

const CacheReader = struct {
    data: []const u8,
    index: usize = 0,

    fn readBytes(self: *CacheReader, len: usize) CacheError![]const u8 {
        if (self.index + len > self.data.len) return error.InvalidCacheData;
        const slice = self.data[self.index .. self.index + len];
        self.index += len;
        return slice;
    }

    fn readU32(self: *CacheReader) CacheError!u32 {
        const bytes = try self.readBytes(4);
        return (@as(u32, @intCast(bytes[0]))) |
            (@as(u32, @intCast(bytes[1])) << 8) |
            (@as(u32, @intCast(bytes[2])) << 16) |
            (@as(u32, @intCast(bytes[3])) << 24);
    }

    fn readF32(self: *CacheReader) CacheError!f32 {
        const bits = try self.readU32();
        const fb = FloatBits{ .bits = bits };
        return fb.value;
    }

    fn readU64(self: *CacheReader) CacheError!u64 {
        const lo = try self.readU32();
        const hi = try self.readU32();
        return (@as(u64, hi) << 32) | @as(u64, lo);
    }
};

const FloatBits = packed union {
    bits: u32,
    value: f32,
};

fn appendU32(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = .{
        @as(u8, @intCast(value & 0xFF)),
        @as(u8, @intCast((value >> 8) & 0xFF)),
        @as(u8, @intCast((value >> 16) & 0xFF)),
        @as(u8, @intCast((value >> 24) & 0xFF)),
    };
    try list.appendSlice(allocator, bytes[0..]);
}

fn appendF32(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: f32) !void {
    const fb = FloatBits{ .value = value };
    try appendU32(list, allocator, fb.bits);
}

fn appendU64(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u64) !void {
    try appendU32(list, allocator, @as(u32, @intCast(value & 0xFFFF_FFFF)));
    try appendU32(list, allocator, @as(u32, @intCast(value >> 32)));
}

fn updateU64(hasher: *std.hash.Wyhash, value: u64) void {
    hasher.update(std.mem.asBytes(&value));
}

fn updateF32(hasher: *std.hash.Wyhash, value: f32) void {
    const fb = FloatBits{ .value = value };
    const bits = fb.bits;
    hasher.update(std.mem.asBytes(&bits));
}

fn meshFingerprint(mesh: *const Mesh) u64 {
    var hasher = std.hash.Wyhash.init(0);

    for (mesh.vertices) |vertex| {
        updateF32(&hasher, vertex.x);
        updateF32(&hasher, vertex.y);
        updateF32(&hasher, vertex.z);
    }

    for (mesh.triangles) |tri| {
        updateU64(&hasher, @as(u64, @intCast(tri.v0)));
        updateU64(&hasher, @as(u64, @intCast(tri.v1)));
        updateU64(&hasher, @as(u64, @intCast(tri.v2)));
    }

    return hasher.final();
}

fn cacheFileName(source_path: []const u8, buffer: []u8) ![]u8 {
    const basename = std.fs.path.basename(source_path);
    const dot_index = std.mem.lastIndexOfScalar(u8, basename, '.');
    const stem = if (dot_index) |idx| basename[0..idx] else basename;
    const hash_value = std.hash.Wyhash.hash(0, source_path);
    return std.fmt.bufPrint(buffer, "{s}-{x}.meshlets", .{ stem, hash_value });
}

fn cacheFilePath(source_path: []const u8, buffer: []u8) ![]u8 {
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    var file_buf: [128]u8 = undefined;
    const file_name = try cacheFileName(source_path, file_buf[0..]);
    return std.fs.path.join(fba.allocator(), &[_][]const u8{ "cache", file_name });
}

pub fn loadCachedMeshlets(allocator: std.mem.Allocator, mesh: *Mesh, source_path: []const u8) !bool {
    return loadInternal(allocator, mesh, source_path) catch |err| switch (err) {
        error.FileNotFound => false,
        error.InvalidCacheData => false,
        error.VersionMismatch => false,
        error.CountMismatch => false,
        error.FingerprintMismatch => false,
        error.IndexOutOfRange => false,
        error.Overflow => false,
        else => return err,
    };
}

fn loadInternal(allocator: std.mem.Allocator, mesh: *Mesh, source_path: []const u8) !bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try cacheFilePath(source_path, path_buf[0..]);

    var file = std.fs.cwd().openFile(cache_path, .{}) catch |err| return err;
    defer file.close();

    const file_stat = try file.stat();
    const file_size = std.math.cast(usize, file_stat.size) orelse return error.InvalidCacheData;
    if (file_size < cache_magic.len) return error.InvalidCacheData;

    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    const read_len = try file.readAll(buffer);
    if (read_len != buffer.len) return error.InvalidCacheData;

    var cursor = CacheReader{ .data = buffer };
    const magic_bytes = try cursor.readBytes(cache_magic.len);
    if (!std.mem.eql(u8, magic_bytes, cache_magic)) return error.InvalidCacheData;

    const version = try cursor.readU32();
    if (version != cache_version) return error.VersionMismatch;

    const cached_vertex_count = try cursor.readU32();
    const cached_triangle_count = try cursor.readU32();
    const cached_fingerprint = try cursor.readU64();
    const meshlet_count_u32 = try cursor.readU32();
    const packed_vertex_count_u32 = try cursor.readU32();
    const packed_primitive_count_u32 = try cursor.readU32();

    const cached_vertex_count_usize = @as(usize, @intCast(cached_vertex_count));
    const cached_triangle_count_usize = @as(usize, @intCast(cached_triangle_count));

    if (cached_vertex_count_usize != mesh.vertices.len or cached_triangle_count_usize != mesh.triangles.len) {
        return error.CountMismatch;
    }
    if (cached_fingerprint != meshFingerprint(mesh)) return error.FingerprintMismatch;

    const meshlet_count = @as(usize, @intCast(meshlet_count_u32));
    const packed_vertex_count = @as(usize, @intCast(packed_vertex_count_u32));
    const packed_primitive_count = @as(usize, @intCast(packed_primitive_count_u32));
    mesh.clearMeshlets();

    var meshlets = try allocator.alloc(Meshlet, meshlet_count);
    errdefer allocator.free(meshlets);
    var meshlet_vertices = try allocator.alloc(usize, packed_vertex_count);
    errdefer allocator.free(meshlet_vertices);
    var meshlet_primitives = try allocator.alloc(MeshletPrimitive, packed_primitive_count);
    errdefer allocator.free(meshlet_primitives);

    var built: usize = 0;
    var vertex_cursor: usize = 0;
    var primitive_cursor: usize = 0;
    while (built < meshlet_count) : (built += 1) {
        const vertex_count_u32 = try cursor.readU32();
        const primitive_count_u32 = try cursor.readU32();

        const vertex_count = @as(usize, @intCast(vertex_count_u32));
        const primitive_count = @as(usize, @intCast(primitive_count_u32));
        if (vertex_count > meshlet_vertices.len - vertex_cursor) return error.InvalidCacheData;
        if (primitive_count > meshlet_primitives.len - primitive_cursor) return error.InvalidCacheData;

        var center = math.Vec3.new(0, 0, 0);
        center.x = try cursor.readF32();
        center.y = try cursor.readF32();
        center.z = try cursor.readF32();
        const radius = try cursor.readF32();
        var normal_cone_axis = math.Vec3.new(0, 0, 0);
        normal_cone_axis.x = try cursor.readF32();
        normal_cone_axis.y = try cursor.readF32();
        normal_cone_axis.z = try cursor.readF32();
        const normal_cone_cutoff = try cursor.readF32();
        var aabb_min = math.Vec3.new(0, 0, 0);
        aabb_min.x = try cursor.readF32();
        aabb_min.y = try cursor.readF32();
        aabb_min.z = try cursor.readF32();
        var aabb_max = math.Vec3.new(0, 0, 0);
        aabb_max.x = try cursor.readF32();
        aabb_max.y = try cursor.readF32();
        aabb_max.z = try cursor.readF32();

        var vi: usize = 0;
        while (vi < vertex_count) : (vi += 1) {
            const idx_u32 = try cursor.readU32();
            const idx = @as(usize, @intCast(idx_u32));
            if (idx >= mesh.vertices.len) return error.IndexOutOfRange;
            if (vertex_cursor + vi >= meshlet_vertices.len) return error.InvalidCacheData;
            meshlet_vertices[vertex_cursor + vi] = idx;
        }

        var ti: usize = 0;
        while (ti < primitive_count) : (ti += 1) {
            const triangle_index_u32 = try cursor.readU32();
            const local_v0_u32 = try cursor.readU32();
            const local_v1_u32 = try cursor.readU32();
            const local_v2_u32 = try cursor.readU32();

            const triangle_index = @as(usize, @intCast(triangle_index_u32));
            if (triangle_index >= mesh.triangles.len) return error.IndexOutOfRange;
            if (local_v0_u32 >= vertex_count or local_v1_u32 >= vertex_count or local_v2_u32 >= vertex_count) {
                return error.IndexOutOfRange;
            }
            if (primitive_cursor + ti >= meshlet_primitives.len) return error.InvalidCacheData;
            meshlet_primitives[primitive_cursor + ti] = MeshletPrimitive{
                .triangle_index = triangle_index,
                .local_v0 = @intCast(local_v0_u32),
                .local_v1 = @intCast(local_v1_u32),
                .local_v2 = @intCast(local_v2_u32),
            };
        }

        meshlets[built] = Meshlet{
            .vertex_offset = vertex_cursor,
            .vertex_count = vertex_count,
            .primitive_offset = primitive_cursor,
            .primitive_count = primitive_count,
            .bounds_center = center,
            .bounds_radius = radius,
            .normal_cone_axis = normal_cone_axis,
            .normal_cone_cutoff = normal_cone_cutoff,
            .aabb_min = aabb_min,
            .aabb_max = aabb_max,
        };
        vertex_cursor += vertex_count;
        primitive_cursor += primitive_count;
    }

    if (vertex_cursor != meshlet_vertices.len or primitive_cursor != meshlet_primitives.len) {
        return error.CountMismatch;
    }
    if (cursor.index != cursor.data.len) return error.InvalidCacheData;
    mesh.meshlets = meshlets;
    mesh.meshlet_vertices = meshlet_vertices;
    mesh.meshlet_primitives = meshlet_primitives;
    return true;
}

pub fn storeMeshlets(mesh: *const Mesh, source_path: []const u8) !void {
    if (mesh.meshlets.len == 0) return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try cacheFilePath(source_path, path_buf[0..]);
    try std.fs.cwd().makePath("cache");

    var file = try std.fs.cwd().createFile(cache_path, .{ .truncate = true });
    defer file.close();

    const alloc = mesh.allocator;
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(alloc);

    try list.appendSlice(alloc, cache_magic);
    try appendU32(&list, alloc, cache_version);

    try appendU32(&list, alloc, try ensureU32(mesh.vertices.len));
    try appendU32(&list, alloc, try ensureU32(mesh.triangles.len));
    try appendU64(&list, alloc, meshFingerprint(mesh));
    try appendU32(&list, alloc, try ensureU32(mesh.meshlets.len));
    try appendU32(&list, alloc, try ensureU32(mesh.meshlet_vertices.len));
    try appendU32(&list, alloc, try ensureU32(mesh.meshlet_primitives.len));

    for (mesh.meshlets) |meshlet| {
        try appendU32(&list, alloc, try ensureU32(meshlet.vertex_count));
        try appendU32(&list, alloc, try ensureU32(meshlet.primitive_count));
        try appendF32(&list, alloc, meshlet.bounds_center.x);
        try appendF32(&list, alloc, meshlet.bounds_center.y);
        try appendF32(&list, alloc, meshlet.bounds_center.z);
        try appendF32(&list, alloc, meshlet.bounds_radius);
        try appendF32(&list, alloc, meshlet.normal_cone_axis.x);
        try appendF32(&list, alloc, meshlet.normal_cone_axis.y);
        try appendF32(&list, alloc, meshlet.normal_cone_axis.z);
        try appendF32(&list, alloc, meshlet.normal_cone_cutoff);
        try appendF32(&list, alloc, meshlet.aabb_min.x);
        try appendF32(&list, alloc, meshlet.aabb_min.y);
        try appendF32(&list, alloc, meshlet.aabb_min.z);
        try appendF32(&list, alloc, meshlet.aabb_max.x);
        try appendF32(&list, alloc, meshlet.aabb_max.y);
        try appendF32(&list, alloc, meshlet.aabb_max.z);

        for (mesh.meshletVertexSlice(&meshlet)) |idx| {
            try appendU32(&list, alloc, try ensureU32(idx));
        }
        for (mesh.meshletPrimitiveSlice(&meshlet)) |primitive| {
            try appendU32(&list, alloc, try ensureU32(primitive.triangle_index));
            try appendU32(&list, alloc, primitive.local_v0);
            try appendU32(&list, alloc, primitive.local_v1);
            try appendU32(&list, alloc, primitive.local_v2);
        }
    }

    try file.writeAll(list.items);
}

fn ensureU32(value: usize) CacheError!u32 {
    if (value > std.math.maxInt(u32)) return error.Overflow;
    return @as(u32, @intCast(value));
}
