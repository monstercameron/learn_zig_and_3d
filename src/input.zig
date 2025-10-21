pub const VirtualKeys = struct {
    pub const left: u32 = 0x25;
    pub const up: u32 = 0x26;
    pub const right: u32 = 0x27;
    pub const down: u32 = 0x28;
    pub const a: u32 = 0x41;
    pub const d: u32 = 0x44;
    pub const e: u32 = 0x45;
    pub const q: u32 = 0x51;
    pub const s: u32 = 0x53;
    pub const w: u32 = 0x57;
};

pub const KeyBits = struct {
    pub const left: u32 = 1;
    pub const right: u32 = 2;
    pub const up: u32 = 4;
    pub const down: u32 = 8;
    pub const w: u32 = 16;
    pub const a: u32 = 32;
    pub const s: u32 = 64;
    pub const d: u32 = 128;
    pub const q: u32 = 256;
    pub const e: u32 = 512;
};

pub const KeyBinding = struct {
    virtual_key: u32,
    bit: u32,
};

pub const key_bindings = [_]KeyBinding{
    .{ .virtual_key = VirtualKeys.left, .bit = KeyBits.left },
    .{ .virtual_key = VirtualKeys.right, .bit = KeyBits.right },
    .{ .virtual_key = VirtualKeys.up, .bit = KeyBits.up },
    .{ .virtual_key = VirtualKeys.down, .bit = KeyBits.down },
    .{ .virtual_key = VirtualKeys.w, .bit = KeyBits.w },
    .{ .virtual_key = VirtualKeys.a, .bit = KeyBits.a },
    .{ .virtual_key = VirtualKeys.s, .bit = KeyBits.s },
    .{ .virtual_key = VirtualKeys.d, .bit = KeyBits.d },
    .{ .virtual_key = VirtualKeys.q, .bit = KeyBits.q },
    .{ .virtual_key = VirtualKeys.e, .bit = KeyBits.e },
};

pub const KeyEvent = struct {
    bit: u32,
    pressed: bool,
    changed: bool,
};

pub fn updateKeyState(keys_pressed: *u32, key_code: u32, is_down: bool) ?KeyEvent {
    for (key_bindings) |binding| {
        if (binding.virtual_key == key_code) {
            const mask = binding.bit;
            const was_set = (keys_pressed.* & mask) != 0;
            if (is_down) {
                keys_pressed.* |= mask;
                return KeyEvent{ .bit = mask, .pressed = true, .changed = !was_set };
            } else {
                keys_pressed.* &= ~mask;
                return KeyEvent{ .bit = mask, .pressed = false, .changed = was_set };
            }
        }
    }

    return null;
}
