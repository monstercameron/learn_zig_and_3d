const builtin = @import("builtin");
const window_module = @import("window.zig");
const types = @import("types.zig");

pub const CursorStyle = types.CursorStyle;
pub const MouseButton = types.MouseButton;
pub const PlatformEvent = types.PlatformEvent;

const impl = switch (builtin.os.tag) {
    .windows => @import("windows/loop_win32.zig"),
    .linux => @import("linux/loop_linux.zig"),
    .macos => @import("macos/loop_macos.zig"),
    else => @import("linux/loop_linux.zig"),
};

pub fn registerRawMouseInput(hwnd: window_module.NativeHandle) !void {
    return impl.registerRawMouseInput(hwnd);
}

pub fn setCursor(style: CursorStyle) void {
    impl.setCursor(style);
}

pub fn windowHasFocus(hwnd: window_module.NativeHandle) bool {
    return impl.windowHasFocus(hwnd);
}

pub fn setMouseCapture(hwnd: window_module.NativeHandle, enabled: bool) void {
    impl.setMouseCapture(hwnd, enabled);
}

pub fn centerCursorInWindow(hwnd: window_module.NativeHandle) void {
    impl.centerCursorInWindow(hwnd);
}

pub fn pumpEvents(ctx: anytype, comptime Hooks: type) bool {
    return impl.pumpEvents(ctx, Hooks);
}
