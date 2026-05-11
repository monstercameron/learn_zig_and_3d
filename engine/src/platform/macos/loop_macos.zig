const platform_types = @import("../types.zig");
const window_module = @import("../window.zig");

pub fn registerRawMouseInput(_: window_module.NativeHandle) !void {}

pub fn setCursor(_: platform_types.CursorStyle) void {}

pub fn windowHasFocus(_: window_module.NativeHandle) bool {
    return false;
}

pub fn setMouseCapture(_: window_module.NativeHandle, _: bool) void {}

pub fn centerCursorInWindow(_: window_module.NativeHandle) void {}

pub fn pumpEvents(_: anytype, comptime _: type) bool {
    return true;
}
