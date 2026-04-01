pub const WindowDesc = struct {
    title: []const u8,
    width: i32,
    height: i32,
    visible: bool = true,
};

pub const CursorStyle = enum {
    arrow,
    grab,
    grabbing,
    hidden,
};

pub const MouseButton = enum {
    left,
    right,
};

pub const PlatformEvent = union(enum) {
    key: struct {
        code: u32,
        is_down: bool,
    },
    char: u32,
    focus_changed: bool,
    raw_mouse_delta: struct {
        x: i32,
        y: i32,
    },
    mouse_move: struct {
        x: i32,
        y: i32,
        left_down: bool,
        right_down: bool,
    },
    mouse_button: struct {
        button: MouseButton,
        pressed: bool,
        x: i32,
        y: i32,
    },
    resized: struct {
        width: i32,
        height: i32,
    },
    minimized,
    restored,
    close_requested,
    quit,
};
