//! # Input Handling Module
//!
//! This module translates raw keyboard input from the OS into a simple, stateful system.
//! It uses a bitmask to keep track of which keys are currently pressed down. This is a
//! common pattern in games and real-time applications because it allows you to easily
//! check for multiple key presses at once (e.g., "is W and Shift being held down?").
//!
//! ## JavaScript Analogy
//!
//! Imagine you want to track the state of several keys. You might do this:
//!
//! ```javascript
//! const keyState = {
//!   w: false,
//!   a: false,
//!   s: false,
//!   d: false,
//! };
//!
//! window.addEventListener('keydown', (e) => {
//!   if (e.key in keyState) keyState[e.key] = true;
//! });
//!
//! window.addEventListener('keyup', (e) => {
//!   if (e.key in keyState) keyState[e.key] = false;
//! });
//!
//! // In your game loop, you can then check the state:
//! if (keyState.w) { /* move forward */ }
//! ```
//! This file implements a more memory-efficient version of that using a single integer
//! (a bitmask) instead of an object.

const std = @import("std");

pub const Key = enum(u8) {
    left,
    right,
    up,
    down,
    w,
    a,
    s,
    d,
    q,
    e,
    space,
    ctrl,
    enter,
    k,
    v,
    m,
    g,
    x,
    y,
    z,
    l,
    j,
    p,
    h,
    n,

    pub fn mask(self: Key) u32 {
        return @as(u32, 1) << @as(u5, @intCast(@intFromEnum(self)));
    }

    pub fn virtualKey(self: Key) u32 {
        return switch (self) {
            .enter => 0x0D,
            .g => 0x47,
            .h => 0x48,
            .j => 0x4A,
            .k => 0x4B,
            .l => 0x4C,
            .m => 0x4D,
            .n => 0x4E,
            .p => 0x50,
            .v => 0x56,
            .x => 0x58,
            .y => 0x59,
            .z => 0x5A,
            .left => 0x25,
            .up => 0x26,
            .right => 0x27,
            .down => 0x28,
            .space => 0x20,
            .a => 0x41,
            .d => 0x44,
            .e => 0x45,
            .ctrl => 0xA2,
            .q => 0x51,
            .s => 0x53,
            .w => 0x57,
        };
    }
};

pub const VirtualKeys = struct {
    pub const enter: u32 = Key.enter.virtualKey();
    pub const g: u32 = Key.g.virtualKey();
    pub const h: u32 = Key.h.virtualKey();
    pub const j: u32 = Key.j.virtualKey();
    pub const k: u32 = Key.k.virtualKey();
    pub const l: u32 = Key.l.virtualKey();
    pub const m: u32 = Key.m.virtualKey();
    pub const n: u32 = Key.n.virtualKey();
    pub const p: u32 = Key.p.virtualKey();
    pub const v: u32 = Key.v.virtualKey();
    pub const x: u32 = Key.x.virtualKey();
    pub const y: u32 = Key.y.virtualKey();
    pub const z: u32 = Key.z.virtualKey();
    pub const left: u32 = Key.left.virtualKey();
    pub const up: u32 = Key.up.virtualKey();
    pub const right: u32 = Key.right.virtualKey();
    pub const down: u32 = Key.down.virtualKey();
    pub const space: u32 = Key.space.virtualKey();
    pub const a: u32 = Key.a.virtualKey();
    pub const d: u32 = Key.d.virtualKey();
    pub const e: u32 = Key.e.virtualKey();
    pub const left_control: u32 = Key.ctrl.virtualKey();
    pub const q: u32 = Key.q.virtualKey();
    pub const s: u32 = Key.s.virtualKey();
    pub const w: u32 = Key.w.virtualKey();
};

pub const KeyBits = struct {
    pub const left: u32 = Key.left.mask();
    pub const right: u32 = Key.right.mask();
    pub const up: u32 = Key.up.mask();
    pub const down: u32 = Key.down.mask();
    pub const w: u32 = Key.w.mask();
    pub const a: u32 = Key.a.mask();
    pub const s: u32 = Key.s.mask();
    pub const d: u32 = Key.d.mask();
    pub const q: u32 = Key.q.mask();
    pub const e: u32 = Key.e.mask();
    pub const space: u32 = Key.space.mask();
    pub const ctrl: u32 = Key.ctrl.mask();
    pub const enter: u32 = Key.enter.mask();
    pub const k: u32 = Key.k.mask();
    pub const v: u32 = Key.v.mask();
    pub const m: u32 = Key.m.mask();
    pub const g: u32 = Key.g.mask();
    pub const x: u32 = Key.x.mask();
    pub const y: u32 = Key.y.mask();
    pub const z: u32 = Key.z.mask();
    pub const l: u32 = Key.l.mask();
    pub const j: u32 = Key.j.mask();
    pub const p: u32 = Key.p.mask();
    pub const h: u32 = Key.h.mask();
    pub const n: u32 = Key.n.mask();
};

pub const MouseButton = enum(u8) {
    left,
    right,
    middle,
    x1,
    x2,

    pub fn mask(self: MouseButton) u8 {
        return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(self)));
    }
};

pub const MousePoint = struct {
    x: i32,
    y: i32,
};

pub const MouseDelta = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub fn isZero(self: MouseDelta) bool {
        return self.x == 0 and self.y == 0;
    }
};

pub const MouseButtonEvent = struct {
    button: MouseButton,
    pressed: bool,
    changed: bool,
};

pub const MouseMoveEvent = struct {
    position: MousePoint,
    delta: MouseDelta,
};

pub const MouseState = struct {
    current_buttons: u8 = 0,
    pressed_buttons: u8 = 0,
    released_buttons: u8 = 0,
    position: ?MousePoint = null,
    move_delta: MouseDelta = .{},
    raw_delta: MouseDelta = .{},

    pub fn beginFrame(self: *MouseState) void {
        self.pressed_buttons = 0;
        self.released_buttons = 0;
        self.move_delta = .{};
        self.raw_delta = .{};
    }

    pub fn clear(self: *MouseState) void {
        self.current_buttons = 0;
        self.position = null;
        self.beginFrame();
    }

    pub fn isDown(self: MouseState, button: MouseButton) bool {
        return (self.current_buttons & button.mask()) != 0;
    }

    pub fn wasPressed(self: MouseState, button: MouseButton) bool {
        return (self.pressed_buttons & button.mask()) != 0;
    }

    pub fn wasReleased(self: MouseState, button: MouseButton) bool {
        return (self.released_buttons & button.mask()) != 0;
    }

    pub fn isHeld(self: MouseState, button: MouseButton) bool {
        return self.isDown(button) and !self.wasPressed(button);
    }

    pub fn setButton(self: *MouseState, button: MouseButton, is_down: bool) MouseButtonEvent {
        const was_set = self.isDown(button);
        if (is_down) {
            self.current_buttons |= button.mask();
            if (!was_set) self.pressed_buttons |= button.mask();
        } else {
            self.current_buttons &= ~button.mask();
            if (was_set) self.released_buttons |= button.mask();
        }
        return .{ .button = button, .pressed = is_down, .changed = was_set != is_down };
    }

    pub fn setPosition(self: *MouseState, x: i32, y: i32) MouseMoveEvent {
        const next = MousePoint{ .x = x, .y = y };
        const delta = if (self.position) |prev|
            MouseDelta{ .x = x - prev.x, .y = y - prev.y }
        else
            MouseDelta{};
        self.position = next;
        self.move_delta.x += delta.x;
        self.move_delta.y += delta.y;
        return .{ .position = next, .delta = delta };
    }

    pub fn addRawDelta(self: *MouseState, delta_x: i32, delta_y: i32) MouseDelta {
        self.raw_delta.x += delta_x;
        self.raw_delta.y += delta_y;
        return .{ .x = delta_x, .y = delta_y };
    }
};

pub const KeyboardState = struct {
    current_bits: u32 = 0,
    pressed_bits: u32 = 0,
    released_bits: u32 = 0,

    pub fn beginFrame(self: *KeyboardState) void {
        self.pressed_bits = 0;
        self.released_bits = 0;
    }

    pub fn clear(self: *KeyboardState) void {
        self.current_bits = 0;
        self.beginFrame();
    }

    pub fn isDown(self: KeyboardState, key: Key) bool {
        return (self.current_bits & key.mask()) != 0;
    }

    pub fn wasPressed(self: KeyboardState, key: Key) bool {
        return (self.pressed_bits & key.mask()) != 0;
    }

    pub fn wasReleased(self: KeyboardState, key: Key) bool {
        return (self.released_bits & key.mask()) != 0;
    }

    pub fn isHeld(self: KeyboardState, key: Key) bool {
        return self.isDown(key) and !self.wasPressed(key);
    }

    pub fn setKey(self: *KeyboardState, key: Key, is_down: bool) KeyEvent {
        const was_set = self.isDown(key);
        if (is_down) {
            self.current_bits |= key.mask();
            if (!was_set) self.pressed_bits |= key.mask();
        } else {
            self.current_bits &= ~key.mask();
            if (was_set) self.released_bits |= key.mask();
        }
        return .{ .key = key, .pressed = is_down, .changed = was_set != is_down };
    }

    pub fn applyVirtualKey(self: *KeyboardState, key_code: u32, is_down: bool) ?KeyEvent {
        const key = keyFromVirtualKey(key_code) orelse return null;
        return self.setKey(key, is_down);
    }
};

/// A simple event object returned by `updateKeyState` to describe what happened.
pub const KeyEvent = struct {
    key: Key, // Which key was affected.
    pressed: bool, // The new state of the key (true for down, false for up).
    changed: bool, // Did the state actually change? (e.g., to prevent repeated events).
};

pub fn keyFromVirtualKey(key_code: u32) ?Key {
    return switch (key_code) {
        0x0D => .enter,
        0x47 => .g,
        0x48 => .h,
        0x4A => .j,
        0x4B => .k,
        0x4C => .l,
        0x4D => .m,
        0x4E => .n,
        0x50 => .p,
        0x56 => .v,
        0x58 => .x,
        0x59 => .y,
        0x5A => .z,
        0x25 => .left,
        0x26 => .up,
        0x27 => .right,
        0x28 => .down,
        0x20 => .space,
        0x41 => .a,
        0x44 => .d,
        0x45 => .e,
        0xA2 => .ctrl,
        0xA3 => .ctrl,
        0x51 => .q,
        0x53 => .s,
        0x57 => .w,
        else => null,
    };
}

/// This function updates the keyboard state bitmask based on a key event.
/// - `keys_pressed`: A pointer to the typed keyboard state.
/// - `key_code`: The raw virtual-key code from the OS.
/// - `is_down`: Whether the key was pressed down or released.
/// Returns a `KeyEvent` if the key is one that we are tracking, otherwise `null`.
pub fn updateKeyState(keys_pressed: *KeyboardState, key_code: u32, is_down: bool) ?KeyEvent {
    return keys_pressed.applyVirtualKey(key_code, is_down);
}

test "keyboard state exposes typed down and edge queries" {
    var keyboard = KeyboardState{};

    keyboard.beginFrame();
    const press_v = updateKeyState(&keyboard, VirtualKeys.v, true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Key.v, press_v.key);
    try std.testing.expect(press_v.pressed);
    try std.testing.expect(press_v.changed);
    try std.testing.expect(keyboard.isDown(.v));
    try std.testing.expect(keyboard.wasPressed(.v));
    try std.testing.expect(!keyboard.wasReleased(.v));
    try std.testing.expect(!keyboard.isHeld(.v));

    keyboard.beginFrame();
    const repeat_v = updateKeyState(&keyboard, VirtualKeys.v, true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Key.v, repeat_v.key);
    try std.testing.expect(repeat_v.pressed);
    try std.testing.expect(!repeat_v.changed);
    try std.testing.expect(!keyboard.wasPressed(.v));
    try std.testing.expect(!keyboard.wasReleased(.v));
    try std.testing.expect(keyboard.isHeld(.v));

    keyboard.beginFrame();
    const release_v = updateKeyState(&keyboard, VirtualKeys.v, false) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Key.v, release_v.key);
    try std.testing.expect(!release_v.pressed);
    try std.testing.expect(release_v.changed);
    try std.testing.expect(!keyboard.isDown(.v));
    try std.testing.expect(keyboard.wasReleased(.v));
    try std.testing.expect(!keyboard.isHeld(.v));
}

test "keyboard state captures rapid click press and release in one frame" {
    var keyboard = KeyboardState{};

    keyboard.beginFrame();
    _ = updateKeyState(&keyboard, VirtualKeys.v, true) orelse return error.TestUnexpectedResult;
    _ = updateKeyState(&keyboard, VirtualKeys.v, false) orelse return error.TestUnexpectedResult;

    try std.testing.expect(keyboard.wasPressed(.v));
    try std.testing.expect(keyboard.wasReleased(.v));
    try std.testing.expect(!keyboard.isDown(.v));
    try std.testing.expect(!keyboard.isHeld(.v));
}

test "keyboard state keeps multiple keys independent" {
    var keyboard = KeyboardState{};

    keyboard.beginFrame();
    _ = updateKeyState(&keyboard, VirtualKeys.w, true) orelse return error.TestUnexpectedResult;
    _ = updateKeyState(&keyboard, VirtualKeys.d, true) orelse return error.TestUnexpectedResult;
    _ = updateKeyState(&keyboard, VirtualKeys.w, false) orelse return error.TestUnexpectedResult;

    try std.testing.expect(keyboard.wasPressed(.w));
    try std.testing.expect(keyboard.wasReleased(.w));
    try std.testing.expect(!keyboard.isDown(.w));
    try std.testing.expect(keyboard.wasPressed(.d));
    try std.testing.expect(!keyboard.wasReleased(.d));
    try std.testing.expect(keyboard.isDown(.d));
}

test "keyboard state reports hold across frames without cross-key bleed" {
    var keyboard = KeyboardState{};

    keyboard.beginFrame();
    _ = updateKeyState(&keyboard, VirtualKeys.a, true) orelse return error.TestUnexpectedResult;
    _ = updateKeyState(&keyboard, VirtualKeys.space, true) orelse return error.TestUnexpectedResult;

    keyboard.beginFrame();
    _ = updateKeyState(&keyboard, VirtualKeys.space, false) orelse return error.TestUnexpectedResult;

    try std.testing.expect(keyboard.isHeld(.a));
    try std.testing.expect(keyboard.isDown(.a));
    try std.testing.expect(!keyboard.wasPressed(.a));
    try std.testing.expect(!keyboard.wasReleased(.a));
    try std.testing.expect(!keyboard.isDown(.space));
    try std.testing.expect(keyboard.wasReleased(.space));
}

test "keyboard state maps both control keys to ctrl" {
    var keyboard = KeyboardState{};

    keyboard.beginFrame();
    const press_right_ctrl = updateKeyState(&keyboard, 0xA3, true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Key.ctrl, press_right_ctrl.key);
    try std.testing.expect(keyboard.isDown(.ctrl));
}

test "mouse state exposes press release hold and movement" {
    var mouse = MouseState{};

    mouse.beginFrame();
    const first_move = mouse.setPosition(100, 120);
    try std.testing.expectEqual(@as(i32, 100), first_move.position.x);
    try std.testing.expectEqual(@as(i32, 120), first_move.position.y);
    try std.testing.expect(first_move.delta.isZero());

    const press_left = mouse.setButton(.left, true);
    try std.testing.expect(press_left.pressed);
    try std.testing.expect(press_left.changed);
    try std.testing.expect(mouse.wasPressed(.left));
    try std.testing.expect(mouse.isDown(.left));
    try std.testing.expect(!mouse.isHeld(.left));

    const second_move = mouse.setPosition(110, 126);
    try std.testing.expectEqual(@as(i32, 10), second_move.delta.x);
    try std.testing.expectEqual(@as(i32, 6), second_move.delta.y);
    try std.testing.expectEqual(@as(i32, 10), mouse.move_delta.x);
    try std.testing.expectEqual(@as(i32, 6), mouse.move_delta.y);

    _ = mouse.addRawDelta(4, -3);
    try std.testing.expectEqual(@as(i32, 4), mouse.raw_delta.x);
    try std.testing.expectEqual(@as(i32, -3), mouse.raw_delta.y);

    mouse.beginFrame();
    try std.testing.expect(mouse.isHeld(.left));
    try std.testing.expect(!mouse.wasPressed(.left));
    try std.testing.expect(!mouse.wasReleased(.left));

    const release_left = mouse.setButton(.left, false);
    try std.testing.expect(!release_left.pressed);
    try std.testing.expect(release_left.changed);
    try std.testing.expect(mouse.wasReleased(.left));
    try std.testing.expect(!mouse.isDown(.left));
}

test "mouse state captures rapid click and independent buttons" {
    var mouse = MouseState{};

    mouse.beginFrame();
    _ = mouse.setButton(.left, true);
    _ = mouse.setButton(.right, true);
    _ = mouse.setButton(.left, false);

    try std.testing.expect(mouse.wasPressed(.left));
    try std.testing.expect(mouse.wasReleased(.left));
    try std.testing.expect(!mouse.isDown(.left));
    try std.testing.expect(mouse.wasPressed(.right));
    try std.testing.expect(!mouse.wasReleased(.right));
    try std.testing.expect(mouse.isDown(.right));
}
