//! Compute module.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

const std = @import("std");

pub const Vec2u = struct { x: u32, y: u32 };

pub const TextureFormat = enum { rgba8, bgra8, r8, r32f, rgba32f };

/// Runs r ea df32 le.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn readF32Le(data: []const u8, offset: usize) f32 {
    const slice = data[offset .. offset + @sizeOf(u32)];
    return @bitCast(std.mem.bytesToValue(u32, slice));
}

/// Runs w ri te f32 le.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn writeF32Le(data: []u8, offset: usize, value: f32) void {
    const slice = data[offset .. offset + @sizeOf(u32)];
    std.mem.bytesAsValue(u32, slice).* = @bitCast(value);
}

/// Clamps to byte to the valid domain used by downstream code.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
fn clampToByte(v: f32) u8 {
    const scaled = std.math.clamp(v, 0.0, 1.0) * 255.0;
    return @as(u8, @intFromFloat(std.math.round(scaled)));
}

pub const Texture2D = struct {
    width: u32,
    height: u32,
    stride_bytes: u32, // bytes per row
    format: TextureFormat,
    // tightly packed for rgba8/r32f/rgba32f; adjust as you like
    data: []u8,

    /// Returns the current linear dispatch index for this compute invocation.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub inline fn idx(self: *const Texture2D, x: u32, y: u32) usize {
        const pixel_stride: usize = switch (self.format) {
            .r8 => 1,
            .r32f => 4,
            .rgba8, .bgra8 => 4,
            .rgba32f => 16,
        };
        return @as(usize, y) * @as(usize, self.stride_bytes) + @as(usize, x) * pixel_stride;
    }
};

pub const RWTexture2D = Texture2D;

/// Returns the byte offset for a packed `r32f` texel.
pub inline fn idxR32F(self: *const Texture2D, x: u32, y: u32) usize {
    return @as(usize, y) * @as(usize, self.stride_bytes) + @as(usize, x) * 4;
}

/// Returns the byte offset for a packed `rgba32f` texel.
pub inline fn idxRGBA32F(self: *const Texture2D, x: u32, y: u32) usize {
    return @as(usize, y) * @as(usize, self.stride_bytes) + @as(usize, x) * 16;
}

/// Returns the byte offset for a packed `rgba8`/`bgra8` texel.
pub inline fn idxRGBA8(self: *const Texture2D, x: u32, y: u32) usize {
    return @as(usize, y) * @as(usize, self.stride_bytes) + @as(usize, x) * 4;
}

/// Loads one `r32f` texel without per-call format switching.
pub inline fn loadR32F(self: *const Texture2D, x: u32, y: u32) f32 {
    std.debug.assert(self.format == .r32f);
    return readF32Le(self.data, idxR32F(self, x, y));
}

/// Stores one `r32f` texel without per-call format switching.
pub inline fn storeR32F(self: *RWTexture2D, x: u32, y: u32, value: f32) void {
    std.debug.assert(self.format == .r32f);
    writeF32Le(self.data, idxR32F(self, x, y), value);
}

/// Loads one `rgba32f` texel without per-call format switching.
pub inline fn loadRGBA32F(self: *const Texture2D, x: u32, y: u32) [4]f32 {
    std.debug.assert(self.format == .rgba32f);
    const i = idxRGBA32F(self, x, y);
    return .{
        readF32Le(self.data, i + 0),
        readF32Le(self.data, i + 4),
        readF32Le(self.data, i + 8),
        readF32Le(self.data, i + 12),
    };
}

/// Stores one `rgba32f` texel without per-call format switching.
pub inline fn storeRGBA32F(self: *RWTexture2D, x: u32, y: u32, rgba: [4]f32) void {
    std.debug.assert(self.format == .rgba32f);
    const i = idxRGBA32F(self, x, y);
    writeF32Le(self.data, i + 0, rgba[0]);
    writeF32Le(self.data, i + 4, rgba[1]);
    writeF32Le(self.data, i + 8, rgba[2]);
    writeF32Le(self.data, i + 12, rgba[3]);
}

/// Loads one `rgba8` texel without per-call format switching.
pub inline fn loadRGBA8(self: *const Texture2D, x: u32, y: u32) [4]f32 {
    std.debug.assert(self.format == .rgba8);
    const i = idxRGBA8(self, x, y);
    return .{
        @as(f32, @floatFromInt(self.data[i + 0])) / 255.0,
        @as(f32, @floatFromInt(self.data[i + 1])) / 255.0,
        @as(f32, @floatFromInt(self.data[i + 2])) / 255.0,
        @as(f32, @floatFromInt(self.data[i + 3])) / 255.0,
    };
}

/// Stores one `rgba8` texel without per-call format switching.
pub inline fn storeRGBA8(self: *RWTexture2D, x: u32, y: u32, rgba: [4]f32) void {
    std.debug.assert(self.format == .rgba8);
    const i = idxRGBA8(self, x, y);
    self.data[i + 0] = clampToByte(rgba[0]);
    self.data[i + 1] = clampToByte(rgba[1]);
    self.data[i + 2] = clampToByte(rgba[2]);
    self.data[i + 3] = clampToByte(rgba[3]);
}

/// Loads l oa dr from external or cached data sources.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn loadR(self: *const Texture2D, x: u32, y: u32) f32 {
    return switch (self.format) {
        .r8 => @as(f32, @floatFromInt(self.data[self.idx(x, y)])) / 255.0,
        .r32f => loadR32F(self, x, y),
        .rgba8, .bgra8, .rgba32f => @panic("use loadRGBA for color formats"),
    };
}

/// Loads l oa dr gb a from external or cached data sources.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn loadRGBA(self: *const Texture2D, x: u32, y: u32) [4]f32 {
    const i = self.idx(x, y);
    return switch (self.format) {
        .rgba8 => loadRGBA8(self, x, y),
        .bgra8 => .{
            @as(f32, @floatFromInt(self.data[i + 2])) / 255.0,
            @as(f32, @floatFromInt(self.data[i + 1])) / 255.0,
            @as(f32, @floatFromInt(self.data[i + 0])) / 255.0,
            @as(f32, @floatFromInt(self.data[i + 3])) / 255.0,
        },
        .rgba32f => loadRGBA32F(self, x, y),
        else => @panic("use loadR for R formats"),
    };
}

/// Moves data for store r.
/// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
pub fn storeR(self: *RWTexture2D, x: u32, y: u32, v: f32) void {
    const i = self.idx(x, y);
    switch (self.format) {
        .r8 => self.data[i] = clampToByte(v),
        .r32f => storeR32F(self, x, y, v),
        else => @panic("storeR expects R format"),
    }
}

/// Moves data for store rgba.
/// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
pub fn storeRGBA(self: *RWTexture2D, x: u32, y: u32, rgba: [4]f32) void {
    const i = self.idx(x, y);
    switch (self.format) {
        .rgba8 => storeRGBA8(self, x, y, rgba),
        .bgra8 => {
            self.data[i + 0] = clampToByte(rgba[2]);
            self.data[i + 1] = clampToByte(rgba[1]);
            self.data[i + 2] = clampToByte(rgba[0]);
            self.data[i + 3] = clampToByte(rgba[3]);
        },
        .rgba32f => storeRGBA32F(self, x, y, rgba),
        else => @panic("storeRGBA expects RGBA format"),
    }
}

pub const StorageBuffer = struct {
    data: []u8,
    stride_bytes: usize = 0,
};

fn elementStride(comptime T: type, buffer: *const StorageBuffer) usize {
    const default_stride = @sizeOf(T);
    if (buffer.stride_bytes == 0) return default_stride;
    std.debug.assert(buffer.stride_bytes == default_stride);
    return buffer.stride_bytes;
}

fn bytesToConstSlice(comptime T: type, bytes: []const u8) []const T {
    return std.mem.bytesAsSlice(T, bytes);
}

fn bytesToSlice(comptime T: type, bytes: []u8) []T {
    return std.mem.bytesAsSlice(T, bytes);
}

/// Returns buffer len.
/// Uses comptime parameters to specialize code paths at compile time instead of branching at runtime.
pub fn bufferLen(comptime T: type, buffer: *const StorageBuffer) usize {
    const stride = elementStride(T, buffer);
    std.debug.assert(stride == @sizeOf(T));
    return buffer.data.len / stride;
}

/// Performs as const slice.
/// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
pub fn asConstSlice(comptime T: type, buffer: *const StorageBuffer) []const T {
    const stride = elementStride(T, buffer);
    std.debug.assert(stride == @sizeOf(T));
    std.debug.assert(buffer.data.len % stride == 0);
    return bytesToConstSlice(T, buffer.data);
}

/// Performs as slice.
/// Processes the provided slices directly to avoid per-call allocations and keep memory access predictable.
pub fn asSlice(comptime T: type, buffer: *StorageBuffer) []T {
    const stride = elementStride(T, buffer);
    std.debug.assert(stride == @sizeOf(T));
    std.debug.assert(buffer.data.len % stride == 0);
    return bytesToSlice(T, buffer.data);
}

/// Loads l oa df ro mb uf fe r from external or cached data sources.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn loadFromBuffer(comptime T: type, buffer: *const StorageBuffer, index: usize) T {
    const slice = asConstSlice(T, buffer);
    std.debug.assert(index < slice.len);
    return slice[index];
}

/// Moves data for store to buffer.
/// Uses comptime parameters to specialize code paths at compile time instead of branching at runtime.
pub fn storeToBuffer(comptime T: type, buffer: *StorageBuffer, index: usize, value: T) void {
    const slice = asSlice(T, buffer);
    std.debug.assert(index < slice.len);
    slice[index] = value;
}

pub const ComputeContext = struct {
    // Thread group configuration (like [numthreads(x,y,1)])
    group_size: Vec2u,

    // Dispatch geometry
    num_groups: Vec2u, // grid in groups
    image_size: Vec2u, // pixels; helpful for bounds

    // Resources (extend as needed)
    ro_textures: []const *const Texture2D = &.{},
    rw_textures: []const *RWTexture2D = &.{},
    ro_buffers: ?[]const *const StorageBuffer = null,
    rw_buffers: ?[]const *StorageBuffer = null,
    push_constants: ?[]const u8 = null,

    // Thread indices (populated per invocation)
    group_id: Vec2u = .{ .x = 0, .y = 0 }, // which group we are in
    local_id: Vec2u = .{ .x = 0, .y = 0 }, // thread id inside the group
    global_id: Vec2u = .{ .x = 0, .y = 0 }, // pixel coord

    // Optional: pointer to group shared memory (user-defined blob)
    shared_mem: ?[]u8 = null,
};
