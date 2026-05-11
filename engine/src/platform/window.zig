const builtin = @import("builtin");
const types = @import("types.zig");

pub const WindowDesc = types.WindowDesc;

const impl = switch (builtin.os.tag) {
    .windows => @import("windows/window_win32.zig"),
    .linux => @import("linux/window_linux.zig"),
    .macos => @import("macos/window_macos.zig"),
    else => @import("linux/window_linux.zig"),
};

pub const NativeHandle = impl.NativeHandle;
pub const Window = impl.Window;
