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

const cache_magic = "MSHL";
const cache_version: u32 = 1;

const CacheError = error{
    InvalidCacheData,
    VersionMismatch,
    CountMismatch,
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
    const meshlet_count_u32 = try cursor.readU32();

    const cached_vertex_count_usize = @as(usize, @intCast(cached_vertex_count));
    const cached_triangle_count_usize = @as(usize, @intCast(cached_triangle_count));

    if (cached_vertex_count_usize != mesh.vertices.len or cached_triangle_count_usize != mesh.triangles.len) {
        return error.CountMismatch;
    }

    const meshlet_count = @as(usize, @intCast(meshlet_count_u32));
    mesh.clearMeshlets();

    var meshlets = try allocator.alloc(Meshlet, meshlet_count);
    var built: usize = 0;
    errdefer {
        var cleanup_index: usize = 0;
        while (cleanup_index < built) : (cleanup_index += 1) {
            meshlets[cleanup_index].deinit(allocator);
        }
        allocator.free(meshlets);
    }

    while (built < meshlet_count) : (built += 1) {
        const vertex_count_u32 = try cursor.readU32();
        const triangle_count_u32 = try cursor.readU32();

        const vertex_count = @as(usize, @intCast(vertex_count_u32));
        const triangle_count = @as(usize, @intCast(triangle_count_u32));

        var center = math.Vec3.new(0, 0, 0);
        center.x = try cursor.readF32();
        center.y = try cursor.readF32();
        center.z = try cursor.readF32();
        const radius = try cursor.readF32();

        const vertex_indices = try allocator.alloc(usize, vertex_count);
        var vi: usize = 0;
        while (vi < vertex_count) : (vi += 1) {
            const idx_u32 = try cursor.readU32();
            const idx = @as(usize, @intCast(idx_u32));
            if (idx >= mesh.vertices.len) {
                allocator.free(vertex_indices);
                return error.IndexOutOfRange;
            }
            vertex_indices[vi] = idx;
        }

        const triangle_indices = allocator.alloc(usize, triangle_count) catch |alloc_err| {
            allocator.free(vertex_indices);
            return alloc_err;
        };
        var ti: usize = 0;
        while (ti < triangle_count) : (ti += 1) {
            const idx_u32 = try cursor.readU32();
            const idx = @as(usize, @intCast(idx_u32));
            if (idx >= mesh.triangles.len) {
                allocator.free(vertex_indices);
                allocator.free(triangle_indices);
                return error.IndexOutOfRange;
            }
            triangle_indices[ti] = idx;
        }

        meshlets[built] = Meshlet{
            .vertex_indices = vertex_indices,
            .triangle_indices = triangle_indices,
            .bounds_center = center,
            .bounds_radius = radius,
        };
    }

    mesh.meshlets = meshlets;
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
    try appendU32(&list, alloc, try ensureU32(mesh.meshlets.len));

    for (mesh.meshlets) |meshlet| {
        try appendU32(&list, alloc, try ensureU32(meshlet.vertex_indices.len));
        try appendU32(&list, alloc, try ensureU32(meshlet.triangle_indices.len));
        try appendF32(&list, alloc, meshlet.bounds_center.x);
        try appendF32(&list, alloc, meshlet.bounds_center.y);
        try appendF32(&list, alloc, meshlet.bounds_center.z);
        try appendF32(&list, alloc, meshlet.bounds_radius);

        for (meshlet.vertex_indices) |idx| {
            try appendU32(&list, alloc, try ensureU32(idx));
        }
        for (meshlet.triangle_indices) |idx| {
            try appendU32(&list, alloc, try ensureU32(idx));
        }
    }

    try file.writeAll(list.items);
}

fn ensureU32(value: usize) CacheError!u32 {
    if (value > std.math.maxInt(u32)) return error.Overflow;
    return @as(u32, @intCast(value));
}
