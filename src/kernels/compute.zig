const std = @import("std");

pub const Vec2u = struct { x: u32, y: u32 };

pub const TextureFormat = enum { rgba8, r8, r32f, rgba32f };

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
        .r8 => @as(f32, @floatFromInt(self.data[i])),
        .r32f => @as(*const f32, @ptrCast(&self.data[i])).*,
        .rgba8, .rgba32f => @panic("use loadRGBA for rgba formats"),
    };
}

pub fn loadRGBA(self: *const Texture2D, x: u32, y: u32) [4]f32 {
    const i = self.idx(x, y);
    return switch (self.format) {
        .rgba8 => .{
            @as(f32, @floatFromInt(self.data[i+0])) / 255.0,
            @as(f32, @floatFromInt(self.data[i+1])) / 255.0,
            @as(f32, @floatFromInt(self.data[i+2])) / 255.0,
            @as(f32, @floatFromInt(self.data[i+3])) / 255.0,
        },
        .rgba32f => .{
            @as(*const f32, @ptrCast(&self.data[i+ 0])).*,
            @as(*const f32, @ptrCast(&self.data[i+ 4])).*,
            @as(*const f32, @ptrCast(&self.data[i+ 8])).*,
            @as(*const f32, @ptrCast(&self.data[i+12])).*,
        },
        else => @panic("use loadR for R formats"),
    };
}

pub fn storeR(self: *RWTexture2D, x: u32, y: u32, v: f32) void {
    const i = self.idx(x, y);
    switch (self.format) {
        .r8 => self.data[i] = @as(u8, @intFromFloat( @max(0, @min(255, v)))),
        .r32f => @as(*f32, @ptrCast(&self.data[i])).* = v,
        else => @panic("storeR expects R format"),
    }
}

pub fn storeRGBA(self: *RWTexture2D, x: u32, y: u32, rgba: [4]f32) void {
    const i = self.idx(x, y);
    switch (self.format) {
        .rgba8 => {
            self.data[i+0] = @as(u8, @intFromFloat( @max(0, @min(255, rgba[0]*255.0))));
            self.data[i+1] = @as(u8, @intFromFloat( @max(0, @min(255, rgba[1]*255.0))));
            self.data[i+2] = @as(u8, @intFromFloat( @max(0, @min(255, rgba[2]*255.0))));
            self.data[i+3] = @as(u8, @intFromFloat( @max(0, @min(255, rgba[3]*255.0))));
        },
        .rgba32f => {
            @as(*f32, @ptrCast(&self.data[i+ 0])).* = rgba[0];
            @as(*f32, @ptrCast(&self.data[i+ 4])).* = rgba[1];
            @as(*f32, @ptrCast(&self.data[i+ 8])).* = rgba[2];
            @as(*f32, @ptrCast(&self.data[i+12])).* = rgba[3];
        },
        else => @panic("storeRGBA expects RGBA format"),
    }
}

pub const ComputeContext = struct {
    // Thread group configuration (like [numthreads(x,y,1)])
    group_size: Vec2u,

    // Dispatch geometry
    num_groups: Vec2u, // grid in groups
    image_size: Vec2u, // pixels; helpful for bounds

    // Resources (extend as needed)
    ro_textures: []const *const Texture2D,
    rw_textures: []const *RWTexture2D,
    push_constants: ?[]const u8,

    // Thread indices (populated per invocation)
    group_id: Vec2u,   // which group we are in
    local_id: Vec2u,   // thread id inside the group
    global_id: Vec2u,  // pixel coord

    // Optional: pointer to group shared memory (user-defined blob)
    shared_mem: ?[]u8,
};