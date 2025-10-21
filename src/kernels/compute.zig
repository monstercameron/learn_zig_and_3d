const std = @import("std");

pub const Vec2u = struct { x: u32, y: u32 };

pub const TextureFormat = enum { rgba8, r8, r32f, rgba32f };

fn readF32Le(data: []const u8, offset: usize) f32 {
    const slice = data[offset .. offset + @sizeOf(u32)];
    return @bitCast(f32, std.mem.readIntLittle(u32, slice));
}

fn writeF32Le(data: []u8, offset: usize, value: f32) void {
    const slice = data[offset .. offset + @sizeOf(u32)];
    std.mem.writeIntLittle(u32, slice, @bitCast(u32, value));
}

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

    pub inline fn idx(self: *const Texture2D, x: u32, y: u32) usize {
        return @as(usize, y) * @as(usize, self.stride_bytes) + @as(usize, x) * switch (self.format) {
            .r8 => 1, .r32f => 4, .rgba8 => 4, .rgba32f => 16
        };
    }
};

pub const RWTexture2D = Texture2D;

pub fn loadR(self: *const Texture2D, x: u32, y: u32) f32 {
    const i = self.idx(x, y);
    return switch (self.format) {
        .r8 => @as(f32, @floatFromInt(self.data[i])) / 255.0,
        .r32f => readF32Le(self.data, i),
        .rgba8, .rgba32f => @panic("use loadRGBA for rgba formats"),
    };
}

pub fn loadRGBA(self: *const Texture2D, x: u32, y: u32) [4]f32 {
    const i = self.idx(x, y);
    return switch (self.format) {
        .rgba8 => .{
            @as(f32, @floatFromInt(self.data[i + 0])) / 255.0,
            @as(f32, @floatFromInt(self.data[i + 1])) / 255.0,
            @as(f32, @floatFromInt(self.data[i + 2])) / 255.0,
            @as(f32, @floatFromInt(self.data[i + 3])) / 255.0,
        },
        .rgba32f => .{
            readF32Le(self.data, i + 0),
            readF32Le(self.data, i + 4),
            readF32Le(self.data, i + 8),
            readF32Le(self.data, i + 12),
        },
        else => @panic("use loadR for R formats"),
    };
}

pub fn storeR(self: *RWTexture2D, x: u32, y: u32, v: f32) void {
    const i = self.idx(x, y);
    switch (self.format) {
        .r8 => self.data[i] = clampToByte(v),
        .r32f => writeF32Le(self.data, i, v),
        else => @panic("storeR expects R format"),
    }
}

pub fn storeRGBA(self: *RWTexture2D, x: u32, y: u32, rgba: [4]f32) void {
    const i = self.idx(x, y);
    switch (self.format) {
        .rgba8 => {
            self.data[i + 0] = clampToByte(rgba[0]);
            self.data[i + 1] = clampToByte(rgba[1]);
            self.data[i + 2] = clampToByte(rgba[2]);
            self.data[i + 3] = clampToByte(rgba[3]);
        },
        .rgba32f => {
            writeF32Le(self.data, i + 0, rgba[0]);
            writeF32Le(self.data, i + 4, rgba[1]);
            writeF32Le(self.data, i + 8, rgba[2]);
            writeF32Le(self.data, i + 12, rgba[3]);
        },
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
    const count = bytes.len / @sizeOf(T);
    const ptr_u8 = @as([*]const u8, bytes.ptr);
    const aligned_ptr = @alignCast(@alignOf(T), ptr_u8);
    return @as([*]const T, @ptrCast(aligned_ptr))[0..count];
}

fn bytesToSlice(comptime T: type, bytes: []u8) []T {
    const count = bytes.len / @sizeOf(T);
    const ptr_u8 = @as([*]u8, bytes.ptr);
    const aligned_ptr = @alignCast(@alignOf(T), ptr_u8);
    return @as([*]T, @ptrCast(aligned_ptr))[0..count];
}

pub fn bufferLen(comptime T: type, buffer: *const StorageBuffer) usize {
    const stride = elementStride(T, buffer);
    std.debug.assert(stride == @sizeOf(T));
    return buffer.data.len / stride;
}

pub fn asConstSlice(comptime T: type, buffer: *const StorageBuffer) []const T {
    const stride = elementStride(T, buffer);
    std.debug.assert(stride == @sizeOf(T));
    std.debug.assert(buffer.data.len % stride == 0);
    return bytesToConstSlice(T, buffer.data);
}

pub fn asSlice(comptime T: type, buffer: *StorageBuffer) []T {
    const stride = elementStride(T, buffer);
    std.debug.assert(stride == @sizeOf(T));
    std.debug.assert(buffer.data.len % stride == 0);
    return bytesToSlice(T, buffer.data);
}

pub fn loadFromBuffer(comptime T: type, buffer: *const StorageBuffer, index: usize) T {
    const slice = asConstSlice(T, buffer);
    std.debug.assert(index < slice.len);
    return slice[index];
}

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
    group_id: Vec2u = .{ .x = 0, .y = 0 },   // which group we are in
    local_id: Vec2u = .{ .x = 0, .y = 0 },   // thread id inside the group
    global_id: Vec2u = .{ .x = 0, .y = 0 },  // pixel coord

    // Optional: pointer to group shared memory (user-defined blob)
    shared_mem: ?[]u8 = null,
};
