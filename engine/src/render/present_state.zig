const std = @import("std");

pub const State = struct {
    width: i32,
    height: i32,
    minimized: bool = false,

    pub fn init(width: i32, height: i32) State {
        return .{
            .width = @max(width, 1),
            .height = @max(height, 1),
            .minimized = false,
        };
    }

    pub fn applyResize(self: *State, width: i32, height: i32) void {
        if (width <= 0 or height <= 0) return;
        self.width = width;
        self.height = height;
    }

    pub fn setMinimized(self: *State, minimized: bool) void {
        self.minimized = minimized;
    }

    pub fn canPresent(self: *const State) bool {
        return !self.minimized and self.width > 0 and self.height > 0;
    }
};

test "present state ignores invalid resize and tracks minimize" {
    var state = State.init(1280, 720);
    try std.testing.expect(state.canPresent());

    state.applyResize(0, 200);
    try std.testing.expectEqual(@as(i32, 1280), state.width);

    state.applyResize(640, 360);
    try std.testing.expectEqual(@as(i32, 640), state.width);
    try std.testing.expectEqual(@as(i32, 360), state.height);

    state.setMinimized(true);
    try std.testing.expect(!state.canPresent());
}
