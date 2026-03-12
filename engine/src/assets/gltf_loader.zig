//! Gltf Loader module.
//! Asset loading/parsing utilities for textures and model formats.

const std = @import("std");
const math = @import("../core/math.zig");
const MeshModule = @import("../render/core/mesh.zig");

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mesh = MeshModule.Mesh;
const Triangle = MeshModule.Triangle;

const glb_magic = 0x46546C67;
const glb_version = 2;
const glb_json_chunk_type = 0x4E4F534A;
const glb_bin_chunk_type = 0x004E4942;
const max_asset_file_bytes: usize = 512 * 1024 * 1024;

const Document = struct {
    scene: ?usize = null,
    scenes: []const Scene = &.{},
    nodes: []const Node = &.{},
    meshes: []const GltfMesh = &.{},
    materials: []const Material = &.{},
    accessors: []const Accessor = &.{},
    bufferViews: []const BufferView = &.{},
    buffers: []const Buffer = &.{},
};

const Scene = struct {
    nodes: []const usize = &.{},
};

const Node = struct {
    mesh: ?usize = null,
    children: []const usize = &.{},
    matrix: ?[16]f32 = null,
    rotation: ?[4]f32 = null,
    scale: ?[3]f32 = null,
    translation: ?[3]f32 = null,
};

const GltfMesh = struct {
    primitives: []const Primitive = &.{},
};

const Primitive = struct {
    attributes: Attributes,
    indices: ?usize = null,
    material: ?usize = null,
    mode: ?u32 = null,
};

const Attributes = struct {
    POSITION: usize,
    TEXCOORD_0: ?usize = null,
};

const Material = struct {
    pbrMetallicRoughness: ?PbrMetallicRoughness = null,
};

const TextureInfo = struct {
    index: usize,
};

const PbrMetallicRoughness = struct {
    baseColorFactor: ?[4]f32 = null,
    baseColorTexture: ?TextureInfo = null,
};

const Accessor = struct {
    bufferView: usize,
    byteOffset: usize = 0,
    componentType: u32,
    count: usize,
    type: []const u8,
};

const BufferView = struct {
    buffer: usize,
    byteOffset: usize = 0,
    byteLength: usize,
    byteStride: ?usize = null,
};

const Buffer = struct {
    byteLength: usize,
    uri: ?[]const u8 = null,
};

const MaterialInfo = struct {
    base_color: u32,
    texture_index: u16,
};

const ColumnMajorMat4 = [16]f32;

const ParsedAsset = struct {
    parsed: std.json.Parsed(Document),
    buffers: [][]u8,

    /// deinit releases resources owned by Gltf Loader.
    fn deinit(self: *ParsedAsset, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        freeBuffers(allocator, self.buffers);
    }
};

/// Loads data into runtime state using the configured source path/input.
/// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Mesh {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try readFileToEndAllocBounded(allocator, &file, max_asset_file_bytes);
    defer allocator.free(contents);

    var asset = try parseAsset(allocator, path, contents);
    defer asset.deinit(allocator);
    const document = asset.parsed.value;

    var vertices = std.ArrayList(Vec3){};
    defer vertices.deinit(allocator);
    var tex_coords = std.ArrayList(Vec2){};
    defer tex_coords.deinit(allocator);
    var triangles = std.ArrayList(Triangle){};
    defer triangles.deinit(allocator);

    // Pre-allocate based on accessor hints to avoid repeated reallocations
    // during appendAccessorPositions / appendAccessorTriangles.
    {
        var est_verts: usize = 0;
        var est_tris: usize = 0;
        for (document.meshes) |gltf_mesh| {
            for (gltf_mesh.primitives) |prim| {
                const pos_acc = try getAccessor(document, prim.attributes.POSITION);
                est_verts += pos_acc.count;
                if (prim.indices) |idx_acc_index| {
                    const idx_acc = try getAccessor(document, idx_acc_index);
                    est_tris += idx_acc.count / 3;
                } else {
                    est_tris += pos_acc.count / 3;
                }
            }
        }
        if (est_verts > 0) {
            try vertices.ensureTotalCapacity(allocator, est_verts);
            try tex_coords.ensureTotalCapacity(allocator, est_verts);
        }
        if (est_tris > 0) {
            try triangles.ensureTotalCapacity(allocator, est_tris);
        }
    }

    if (document.scenes.len == 0) {
        try appendNodes(allocator, &vertices, &tex_coords, &triangles, document, asset.buffers, identityMatrix(), null);
    } else {
        const scene_index = document.scene orelse 0;
        if (scene_index >= document.scenes.len) return error.InvalidSceneIndex;
        const scene = document.scenes[scene_index];
        if (scene.nodes.len == 0) {
            try appendNodes(allocator, &vertices, &tex_coords, &triangles, document, asset.buffers, identityMatrix(), null);
        } else {
            for (scene.nodes) |node_index| {
                try appendNode(allocator, &vertices, &tex_coords, &triangles, document, asset.buffers, node_index, identityMatrix());
            }
        }
    }

    if (vertices.items.len == 0 or triangles.items.len == 0) return error.EmptyMesh;
    if (tex_coords.items.len != vertices.items.len) return error.InvalidTexCoordCount;

    const vertex_slice = try vertices.toOwnedSlice(allocator);
    errdefer allocator.free(vertex_slice);
    const texcoord_slice = try tex_coords.toOwnedSlice(allocator);
    errdefer allocator.free(texcoord_slice);
    const triangle_slice = try triangles.toOwnedSlice(allocator);
    errdefer allocator.free(triangle_slice);

    var mesh = Mesh{
        .vertices = vertex_slice,
        .triangles = triangle_slice,
        .normals = try allocator.alloc(Vec3, triangle_slice.len),
        .tex_coords = texcoord_slice,
        .meshlets = &[_]MeshModule.Meshlet{},
        .meshlet_vertices = &[_]usize{},
        .meshlet_primitives = &[_]MeshModule.MeshletPrimitive{},
        .allocator = allocator,
    };
    errdefer mesh.deinit();
    mesh.recalculateNormals();
    return mesh;
}

/// Parses p ar se as se t into typed runtime values.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn parseAsset(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !ParsedAsset {
    if (contents.len >= 12 and readU32le(contents[0..4]) == glb_magic) {
        return parseGlbAsset(allocator, path, contents);
    }
    return parseGltfAsset(allocator, path, contents);
}

/// Parses p ar se gl tf as se t into typed runtime values.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn parseGltfAsset(allocator: std.mem.Allocator, path: []const u8, json_bytes: []const u8) !ParsedAsset {
    const parsed = try std.json.parseFromSlice(Document, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();

    const buffers = try loadExternalBuffers(allocator, path, parsed.value.buffers);
    errdefer freeBuffers(allocator, buffers);
    return .{
        .parsed = parsed,
        .buffers = buffers,
    };
}

/// Parses p ar se gl ba ss et into typed runtime values.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn parseGlbAsset(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !ParsedAsset {
    if (contents.len < 20) return error.InvalidGlbHeader;
    if (readU32le(contents[4..8]) != glb_version) return error.UnsupportedGlbVersion;
    if (readU32le(contents[8..12]) > contents.len) return error.InvalidGlbLength;

    var offset: usize = 12;
    var json_chunk: []const u8 = &.{};
    var bin_chunk: []const u8 = &.{};

    while (offset + 8 <= contents.len) {
        const chunk_length: usize = @intCast(readU32le(contents[offset .. offset + 4]));
        const chunk_type = readU32le(contents[offset + 4 .. offset + 8]);
        offset += 8;
        if (offset + chunk_length > contents.len) return error.InvalidGlbChunk;
        const chunk_data = contents[offset .. offset + chunk_length];
        offset += chunk_length;

        switch (chunk_type) {
            glb_json_chunk_type => json_chunk = chunk_data,
            glb_bin_chunk_type => {
                if (bin_chunk.len == 0) bin_chunk = chunk_data;
            },
            else => {},
        }
    }

    if (json_chunk.len == 0) return error.MissingGlbJsonChunk;
    const parsed = try std.json.parseFromSlice(Document, allocator, json_chunk, .{
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();

    const buffers = try allocator.alloc([]u8, parsed.value.buffers.len);
    errdefer allocator.free(buffers);
    for (buffers) |*buffer| buffer.* = &[_]u8{};
    errdefer {
        for (buffers) |buffer| {
            if (buffer.len != 0) allocator.free(buffer);
        }
    }

    const base_dir = std.fs.path.dirname(path) orelse ".";
    for (parsed.value.buffers, 0..) |buffer_def, idx| {
        if (buffer_def.uri) |uri| {
            const decoded_uri = try decodeUri(allocator, uri);
            defer allocator.free(decoded_uri);
            const resolved_path = try std.fs.path.join(allocator, &.{ base_dir, decoded_uri });
            defer allocator.free(resolved_path);
            var file = try std.fs.cwd().openFile(resolved_path, .{});
            defer file.close();
            if (buffer_def.byteLength > max_asset_file_bytes) return error.FileTooLarge;
            buffers[idx] = try file.readToEndAlloc(allocator, buffer_def.byteLength);
        } else if (idx == 0 and bin_chunk.len != 0) {
            buffers[idx] = try allocator.dupe(u8, bin_chunk);
        } else {
            return error.MissingBufferData;
        }
    }

    return .{
        .parsed = parsed,
        .buffers = buffers,
    };
}

/// Loads l oa de xt er na lb uf fe rs from external or cached data sources.
/// Validates inputs and applies fallback/default rules before exposing results to callers.
fn loadExternalBuffers(allocator: std.mem.Allocator, gltf_path: []const u8, buffer_defs: []const Buffer) ![][]u8 {
    const buffers = try allocator.alloc([]u8, buffer_defs.len);
    errdefer allocator.free(buffers);
    for (buffers) |*buffer| buffer.* = &[_]u8{};
    errdefer {
        for (buffers) |buffer| {
            if (buffer.len != 0) allocator.free(buffer);
        }
    }

    const base_dir = std.fs.path.dirname(gltf_path) orelse ".";
    for (buffer_defs, 0..) |buffer_def, idx| {
        const uri = buffer_def.uri orelse return error.MissingBufferUri;
        const decoded_uri = try decodeUri(allocator, uri);
        defer allocator.free(decoded_uri);
        const resolved_path = try std.fs.path.join(allocator, &.{ base_dir, decoded_uri });
        defer allocator.free(resolved_path);

        var file = try std.fs.cwd().openFile(resolved_path, .{});
        defer file.close();
        if (buffer_def.byteLength > max_asset_file_bytes) return error.FileTooLarge;
        buffers[idx] = try file.readToEndAlloc(allocator, buffer_def.byteLength);
    }
    return buffers;
}

fn readFileToEndAllocBounded(allocator: std.mem.Allocator, file: *std.fs.File, max_bytes: usize) ![]u8 {
    const stat = try file.stat();
    if (stat.size > max_bytes) return error.FileTooLarge;
    const read_limit: usize = @intCast(stat.size);
    return file.readToEndAlloc(allocator, read_limit);
}

fn freeBuffers(allocator: std.mem.Allocator, buffers: [][]u8) void {
    for (buffers) |buffer| allocator.free(buffer);
    allocator.free(buffers);
}

fn decodeUri(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var decoded = std.ArrayList(u8){};
    errdefer decoded.deinit(allocator);

    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        const ch = encoded[index];
        if (ch == '%' and index + 2 < encoded.len) {
            const hi = try hexNibble(encoded[index + 1]);
            const lo = try hexNibble(encoded[index + 2]);
            try decoded.append(allocator, (hi << 4) | lo);
            index += 2;
            continue;
        }
        try decoded.append(allocator, ch);
    }

    return decoded.toOwnedSlice(allocator);
}

fn hexNibble(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidPercentEncoding,
    };
}

fn appendNodes(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayList(Vec3),
    tex_coords: *std.ArrayList(Vec2),
    triangles: *std.ArrayList(Triangle),
    document: Document,
    buffers: [][]u8,
    parent_transform: ColumnMajorMat4,
    maybe_nodes: ?[]const usize,
) !void {
    if (maybe_nodes) |nodes| {
        for (nodes) |node_index| {
            try appendNode(allocator, vertices, tex_coords, triangles, document, buffers, node_index, parent_transform);
        }
        return;
    }

    for (document.nodes, 0..) |_, node_index| {
        try appendNode(allocator, vertices, tex_coords, triangles, document, buffers, node_index, parent_transform);
    }
}

fn appendNode(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayList(Vec3),
    tex_coords: *std.ArrayList(Vec2),
    triangles: *std.ArrayList(Triangle),
    document: Document,
    buffers: [][]u8,
    node_index: usize,
    parent_transform: ColumnMajorMat4,
) !void {
    if (node_index >= document.nodes.len) return error.InvalidNodeIndex;
    const node = document.nodes[node_index];
    const local_transform = nodeTransform(node);
    const world_transform = multiplyMatrix(parent_transform, local_transform);

    if (node.mesh) |mesh_index| {
        try appendMesh(allocator, vertices, tex_coords, triangles, document, buffers, mesh_index, world_transform);
    }
    for (node.children) |child_index| {
        try appendNode(allocator, vertices, tex_coords, triangles, document, buffers, child_index, world_transform);
    }
}

fn appendMesh(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayList(Vec3),
    tex_coords: *std.ArrayList(Vec2),
    triangles: *std.ArrayList(Triangle),
    document: Document,
    buffers: [][]u8,
    mesh_index: usize,
    world_transform: ColumnMajorMat4,
) !void {
    if (mesh_index >= document.meshes.len) return error.InvalidMeshIndex;
    const mesh = document.meshes[mesh_index];
    for (mesh.primitives) |primitive| {
        if (primitive.mode) |mode| {
            if (mode != 4) continue;
        }
        try appendPrimitive(allocator, vertices, tex_coords, triangles, document, buffers, primitive, world_transform);
    }
}

fn appendPrimitive(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayList(Vec3),
    tex_coords: *std.ArrayList(Vec2),
    triangles: *std.ArrayList(Triangle),
    document: Document,
    buffers: [][]u8,
    primitive: Primitive,
    world_transform: ColumnMajorMat4,
) !void {
    const position_accessor_index = primitive.attributes.POSITION;
    const position_accessor = try getAccessor(document, position_accessor_index);
    if (!std.mem.eql(u8, position_accessor.type, "VEC3") or position_accessor.componentType != 5126) {
        return error.UnsupportedPositionAccessor;
    }

    const base_vertex = vertices.items.len;
    try appendAccessorPositions(allocator, vertices, document, buffers, position_accessor_index, world_transform);

    if (primitive.attributes.TEXCOORD_0) |uv_accessor_index| {
        try appendAccessorTexCoords(allocator, tex_coords, document, buffers, uv_accessor_index, position_accessor.count);
    } else {
        try appendDefaultTexCoords(allocator, tex_coords, position_accessor.count);
    }

    const material_info = materialInfoForPrimitive(document, primitive);
    if (primitive.indices) |indices_accessor_index| {
        try appendAccessorTriangles(
            allocator,
            triangles,
            document,
            buffers,
            indices_accessor_index,
            base_vertex,
            material_info,
        );
        return;
    }

    if (position_accessor.count % 3 != 0) return error.InvalidPrimitiveTopology;
    var index: usize = 0;
    while (index < position_accessor.count) : (index += 3) {
        try triangles.append(
            allocator,
            makeTriangle(
                base_vertex + index,
                base_vertex + index + 1,
                base_vertex + index + 2,
                material_info,
            ),
        );
    }
}

fn appendAccessorPositions(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayList(Vec3),
    document: Document,
    buffers: [][]u8,
    accessor_index: usize,
    world_transform: ColumnMajorMat4,
) !void {
    const accessor = try getAccessor(document, accessor_index);
    if (accessor.count == 0) return;
    const buffer_view = try getBufferView(document, accessor.bufferView);
    const buffer = try getBuffer(buffers, buffer_view.buffer);
    const elem_size: usize = 12;
    const stride = buffer_view.byteStride orelse elem_size;
    const start = buffer_view.byteOffset + accessor.byteOffset;
    const needed = start + stride * (accessor.count - 1) + elem_size;
    if (needed > buffer.len) return error.BufferViewOutOfBounds;

    var idx: usize = 0;
    const batch = 4;
    // Process vertices in batches of 4 using SIMD matrix multiply.
    while (idx + batch <= accessor.count) : (idx += batch) {
        var px: [batch]f32 = undefined;
        var py: [batch]f32 = undefined;
        var pz: [batch]f32 = undefined;
        inline for (0..batch) |b| {
            const bi = start + (idx + b) * stride;
            px[b] = readF32(buffer[bi..][0..4]);
            py[b] = readF32(buffer[bi + 4 ..][0..4]);
            pz[b] = readF32(buffer[bi + 8 ..][0..4]);
        }
        const results = transformPointBatch(batch, world_transform, &px, &py, &pz);
        try vertices.appendSlice(allocator, &results);
    }
    // Scalar tail
    while (idx < accessor.count) : (idx += 1) {
        const byte_index = start + idx * stride;
        const x = readF32(buffer[byte_index..][0..4]);
        const y = readF32(buffer[byte_index + 4 ..][0..4]);
        const z = readF32(buffer[byte_index + 8 ..][0..4]);
        try vertices.append(allocator, transformPoint(world_transform, Vec3.new(x, y, z)));
    }
}

fn appendAccessorTexCoords(
    allocator: std.mem.Allocator,
    tex_coords: *std.ArrayList(Vec2),
    document: Document,
    buffers: [][]u8,
    accessor_index: usize,
    expected_count: usize,
) !void {
    const accessor = try getAccessor(document, accessor_index);
    if (!std.mem.eql(u8, accessor.type, "VEC2") or accessor.componentType != 5126) {
        return error.UnsupportedTexCoordAccessor;
    }
    if (accessor.count != expected_count) return error.MismatchedTexCoordCount;
    if (accessor.count == 0) return;

    const buffer_view = try getBufferView(document, accessor.bufferView);
    const buffer = try getBuffer(buffers, buffer_view.buffer);
    const elem_size: usize = 8;
    const stride = buffer_view.byteStride orelse elem_size;
    const start = buffer_view.byteOffset + accessor.byteOffset;
    const needed = start + stride * (accessor.count - 1) + elem_size;
    if (needed > buffer.len) return error.BufferViewOutOfBounds;

    var idx: usize = 0;
    while (idx < accessor.count) : (idx += 1) {
        const byte_index = start + idx * stride;
        const u = readF32(buffer[byte_index..][0..4]);
        const v = readF32(buffer[byte_index + 4 ..][0..4]);
        try tex_coords.append(allocator, Vec2.new(u, 1.0 - v));
    }
}

fn appendDefaultTexCoords(allocator: std.mem.Allocator, tex_coords: *std.ArrayList(Vec2), count: usize) !void {
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        try tex_coords.append(allocator, Vec2.new(0.0, 0.0));
    }
}

fn appendAccessorTriangles(
    allocator: std.mem.Allocator,
    triangles: *std.ArrayList(Triangle),
    document: Document,
    buffers: [][]u8,
    accessor_index: usize,
    base_vertex: usize,
    material_info: MaterialInfo,
) !void {
    const accessor = try getAccessor(document, accessor_index);
    if (!std.mem.eql(u8, accessor.type, "SCALAR")) return error.UnsupportedIndexAccessor;
    if (accessor.count == 0) return;

    const component_size = switch (accessor.componentType) {
        5121 => @as(usize, 1),
        5123 => 2,
        5125 => 4,
        else => return error.UnsupportedIndexAccessor,
    };
    const buffer_view = try getBufferView(document, accessor.bufferView);
    const buffer = try getBuffer(buffers, buffer_view.buffer);
    const stride = buffer_view.byteStride orelse component_size;
    const start = buffer_view.byteOffset + accessor.byteOffset;
    const needed = start + stride * (accessor.count - 1) + component_size;
    if (needed > buffer.len) return error.BufferViewOutOfBounds;
    if (accessor.count % 3 != 0) return error.InvalidPrimitiveTopology;

    var idx: usize = 0;
    while (idx < accessor.count) : (idx += 3) {
        const idx0 = try readIndex(buffer, start + idx * stride, accessor.componentType);
        const idx1 = try readIndex(buffer, start + (idx + 1) * stride, accessor.componentType);
        const idx2 = try readIndex(buffer, start + (idx + 2) * stride, accessor.componentType);
        try triangles.append(
            allocator,
            makeTriangle(base_vertex + idx0, base_vertex + idx1, base_vertex + idx2, material_info),
        );
    }
}

fn makeTriangle(v0: usize, v1: usize, v2: usize, material_info: MaterialInfo) Triangle {
    var triangle = Triangle.newWithColor(v0, v1, v2, material_info.base_color);
    triangle.texture_index = material_info.texture_index;
    return triangle;
}

fn materialInfoForPrimitive(document: Document, primitive: Primitive) MaterialInfo {
    if (primitive.material) |material_index| {
        if (material_index < document.materials.len) {
            const material = document.materials[material_index];
            const factor = if (material.pbrMetallicRoughness) |pbr|
                (pbr.baseColorFactor orelse [4]f32{ 1.0, 1.0, 1.0, 1.0 })
            else
                [4]f32{ 1.0, 1.0, 1.0, 1.0 };
            const maybe_texture_index: ?usize = if (material.pbrMetallicRoughness) |pbr|
                if (pbr.baseColorTexture) |base_color_tex| base_color_tex.index else null
            else
                null;
            return .{
                .base_color = packColorFactor(factor),
                // Prefer glTF baseColor texture index; fall back to material index for legacy scene slots.
                .texture_index = if (maybe_texture_index) |texture_index|
                    if (texture_index <= std.math.maxInt(u16))
                        @intCast(texture_index)
                    else
                        Triangle.no_texture_index
                else if (material_index <= std.math.maxInt(u16))
                    @intCast(material_index)
                else
                    Triangle.no_texture_index,
            };
        }
    }

    return .{
        .base_color = 0xFFFFFFFF,
        .texture_index = Triangle.no_texture_index,
    };
}

/// Processes pack color factor.
/// Keeps pack color factor as the single implementation point so call-site behavior stays consistent.
fn packColorFactor(factor: [4]f32) u32 {
    const r = channelFromFactor(factor[0]);
    const g = channelFromFactor(factor[1]);
    const b = channelFromFactor(factor[2]);
    const a = channelFromFactor(factor[3]);
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

fn channelFromFactor(value: f32) u8 {
    const clamped = std.math.clamp(value, 0.0, 1.0);
    return @intFromFloat(clamped * 255.0 + 0.5);
}

/// Reads index.
/// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
fn readIndex(buffer: []const u8, offset: usize, component_type: u32) !usize {
    return switch (component_type) {
        5121 => @intCast(buffer[offset]),
        5123 => @intCast(std.mem.readInt(u16, @ptrCast(buffer[offset..].ptr), .little)),
        5125 => @intCast(std.mem.readInt(u32, @ptrCast(buffer[offset..].ptr), .little)),
        else => error.UnsupportedIndexAccessor,
    };
}

/// Reads f32.
/// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
fn readF32(bytes: []const u8) f32 {
    return @bitCast(std.mem.readInt(u32, @ptrCast(bytes.ptr), .little));
}

/// Reads u32le.
/// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
fn readU32le(bytes: []const u8) u32 {
    return std.mem.readInt(u32, @ptrCast(bytes.ptr), .little);
}

/// getAccessor returns state derived from Gltf Loader.
fn getAccessor(document: Document, accessor_index: usize) !Accessor {
    if (accessor_index >= document.accessors.len) return error.InvalidAccessorIndex;
    return document.accessors[accessor_index];
}

/// getBufferView returns state derived from Gltf Loader.
fn getBufferView(document: Document, buffer_view_index: usize) !BufferView {
    if (buffer_view_index >= document.bufferViews.len) return error.InvalidBufferViewIndex;
    return document.bufferViews[buffer_view_index];
}

/// getBuffer returns state derived from Gltf Loader.
fn getBuffer(buffers: [][]u8, buffer_index: usize) ![]const u8 {
    if (buffer_index >= buffers.len) return error.InvalidBufferIndex;
    return buffers[buffer_index];
}

fn nodeTransform(node: Node) ColumnMajorMat4 {
    if (node.matrix) |matrix| return matrix;

    const translation_values = node.translation orelse [3]f32{ 0.0, 0.0, 0.0 };
    const scale_values = node.scale orelse [3]f32{ 1.0, 1.0, 1.0 };
    const rotation_values = node.rotation orelse [4]f32{ 0.0, 0.0, 0.0, 1.0 };
    return composeTrs(
        Vec3.new(translation_values[0], translation_values[1], translation_values[2]),
        rotation_values,
        Vec3.new(scale_values[0], scale_values[1], scale_values[2]),
    );
}

fn composeTrs(translation: Vec3, rotation: [4]f32, scale: Vec3) ColumnMajorMat4 {
    const x = rotation[0];
    const y = rotation[1];
    const z = rotation[2];
    const w = rotation[3];

    const xx = x * x;
    const yy = y * y;
    const zz = z * z;
    const xy = x * y;
    const xz = x * z;
    const yz = y * z;
    const wx = w * x;
    const wy = w * y;
    const wz = w * z;

    return .{
        (1.0 - 2.0 * (yy + zz)) * scale.x,
        (2.0 * (xy + wz)) * scale.x,
        (2.0 * (xz - wy)) * scale.x,
        0.0,
        (2.0 * (xy - wz)) * scale.y,
        (1.0 - 2.0 * (xx + zz)) * scale.y,
        (2.0 * (yz + wx)) * scale.y,
        0.0,
        (2.0 * (xz + wy)) * scale.z,
        (2.0 * (yz - wx)) * scale.z,
        (1.0 - 2.0 * (xx + yy)) * scale.z,
        0.0,
        translation.x,
        translation.y,
        translation.z,
        1.0,
    };
}

fn identityMatrix() ColumnMajorMat4 {
    return .{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
}

fn multiplyMatrix(a: ColumnMajorMat4, b: ColumnMajorMat4) ColumnMajorMat4 {
    var out: ColumnMajorMat4 = undefined;
    var col: usize = 0;
    while (col < 4) : (col += 1) {
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            out[col * 4 + row] =
                a[0 * 4 + row] * b[col * 4 + 0] +
                a[1 * 4 + row] * b[col * 4 + 1] +
                a[2 * 4 + row] * b[col * 4 + 2] +
                a[3 * 4 + row] * b[col * 4 + 3];
        }
    }
    return out;
}

fn transformPoint(matrix: ColumnMajorMat4, point: Vec3) Vec3 {
    const x = matrix[0] * point.x + matrix[4] * point.y + matrix[8] * point.z + matrix[12];
    const y = matrix[1] * point.x + matrix[5] * point.y + matrix[9] * point.z + matrix[13];
    const z = matrix[2] * point.x + matrix[6] * point.y + matrix[10] * point.z + matrix[14];
    const w = matrix[3] * point.x + matrix[7] * point.y + matrix[11] * point.z + matrix[15];
    if (@abs(w) <= 1e-6 or @abs(w - 1.0) <= 1e-6) return Vec3.new(x, y, z);
    const inv_w = 1.0 / w;
    return Vec3.new(x * inv_w, y * inv_w, z * inv_w);
}

/// SIMD batch transform: processes `lanes` points through a 4x4 column-major matrix simultaneously.
fn transformPointBatch(comptime lanes: comptime_int, matrix: ColumnMajorMat4, px: *const [lanes]f32, py: *const [lanes]f32, pz: *const [lanes]f32) [lanes]Vec3 {
    const V = @Vector(lanes, f32);
    const vx: V = px.*;
    const vy: V = py.*;
    const vz: V = pz.*;

    const rx = @as(V, @splat(matrix[0])) * vx + @as(V, @splat(matrix[4])) * vy + @as(V, @splat(matrix[8])) * vz + @as(V, @splat(matrix[12]));
    const ry = @as(V, @splat(matrix[1])) * vx + @as(V, @splat(matrix[5])) * vy + @as(V, @splat(matrix[9])) * vz + @as(V, @splat(matrix[13]));
    const rz = @as(V, @splat(matrix[2])) * vx + @as(V, @splat(matrix[6])) * vy + @as(V, @splat(matrix[10])) * vz + @as(V, @splat(matrix[14]));
    const rw = @as(V, @splat(matrix[3])) * vx + @as(V, @splat(matrix[7])) * vy + @as(V, @splat(matrix[11])) * vz + @as(V, @splat(matrix[15]));

    const eps: V = @splat(1e-6);
    const one: V = @splat(1.0);
    const abs_w = @abs(rw);
    const dist_one = @abs(rw - one);
    const needs_divide = (abs_w > eps) & (dist_one > eps);
    const inv_w = one / @select(f32, needs_divide, rw, one);
    const ox = @select(f32, needs_divide, rx * inv_w, rx);
    const oy = @select(f32, needs_divide, ry * inv_w, ry);
    const oz = @select(f32, needs_divide, rz * inv_w, rz);

    const ox_arr: [lanes]f32 = ox;
    const oy_arr: [lanes]f32 = oy;
    const oz_arr: [lanes]f32 = oz;

    var result: [lanes]Vec3 = undefined;
    inline for (0..lanes) |i| {
        result[i] = Vec3.new(ox_arr[i], oy_arr[i], oz_arr[i]);
    }
    return result;
}

test "decodeUri decodes percent escapes" {
    const allocator = std.testing.allocator;
    const decoded = try decodeUri(allocator, "I%20phone%2018%20pro.bin");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("I phone 18 pro.bin", decoded);
}

test "composeTrs applies translation" {
    const matrix = composeTrs(Vec3.new(1.0, 2.0, 3.0), .{ 0.0, 0.0, 0.0, 1.0 }, Vec3.new(1.0, 1.0, 1.0));
    const point = transformPoint(matrix, Vec3.new(4.0, 5.0, 6.0));
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), point.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), point.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), point.z, 0.0001);
}
