const platform_types = @import("../types.zig");

pub const NativeHandle = ?*anyopaque;

pub const Window = struct {
    hwnd: NativeHandle = null,

    pub fn init(_: platform_types.WindowDesc) !Window {
        return error.UnsupportedPlatform;
    }

    pub fn deinit(_: *Window) void {}

    pub fn setTitle(_: *const Window, _: []const u8) void {}
};
