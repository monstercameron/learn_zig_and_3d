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

// These are the raw virtual-key codes from the Windows API.
// We define them here so we don't have magic numbers scattered around the code.
pub const VirtualKeys = struct {
    pub const left: u32 = 0x25;
    pub const up: u32 = 0x26;
    pub const right: u32 = 0x27;
    pub const down: u32 = 0x28;
    pub const space: u32 = 0x20;
    pub const a: u32 = 0x41;
    pub const d: u32 = 0x44;
    pub const e: u32 = 0x45;
    pub const left_control: u32 = 0xA2;
    pub const q: u32 = 0x51;
    pub const s: u32 = 0x53;
    pub const w: u32 = 0x57;
};

// Each key we care about is assigned a unique bit in our state mask.
// These must be powers of 2.
// JS Analogy: `const KeyBits = { left: 1, right: 2, up: 4, ... };`
pub const KeyBits = struct {
    pub const left: u32 = 1; // 2^0
    pub const right: u32 = 2; // 2^1
    pub const up: u32 = 4; // 2^2
    pub const down: u32 = 8; // 2^3
    pub const w: u32 = 16; // 2^4
    pub const a: u32 = 32; // 2^5
    pub const s: u32 = 64; // 2^6
    pub const d: u32 = 128; // 2^7
    pub const q: u32 = 256; // 2^8
    pub const e: u32 = 512; // 2^9
    pub const space: u32 = 1024; // 2^10
    pub const ctrl: u32 = 2048; // 2^11
};

// A simple struct to link a Windows virtual key code to our internal key bit.
pub const KeyBinding = struct {
    virtual_key: u32,
    bit: u32,
};

// The master list of all key bindings we are tracking.
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
    .{ .virtual_key = VirtualKeys.space, .bit = KeyBits.space },
    .{ .virtual_key = VirtualKeys.left_control, .bit = KeyBits.ctrl },
};

/// A simple event object returned by `updateKeyState` to describe what happened.
pub const KeyEvent = struct {
    bit: u32, // Which key bit was affected.
    pressed: bool, // The new state of the key (true for down, false for up).
    changed: bool, // Did the state actually change? (e.g., to prevent repeated events).
};

/// This function updates the keyboard state bitmask based on a key event.
/// - `keys_pressed`: A pointer to the integer holding the current keyboard state.
/// - `key_code`: The raw virtual-key code from the OS.
/// - `is_down`: Whether the key was pressed down or released.
/// Returns a `KeyEvent` if the key is one that we are tracking, otherwise `null`.
pub fn updateKeyState(keys_pressed: *u32, key_code: u32, is_down: bool) ?KeyEvent {
    // Find the binding for the incoming key code.
    for (key_bindings) |binding| {
        if (binding.virtual_key == key_code) {
            const mask = binding.bit;
            const was_set = (keys_pressed.* & mask) != 0;

            if (is_down) {
                // Key is pressed down. Set the corresponding bit in the state integer.
                // JS Analogy: `keys_pressed |= mask` is like `keys_pressed = keys_pressed | mask`.
                keys_pressed.* |= mask;
                return KeyEvent{ .bit = mask, .pressed = true, .changed = !was_set };
            } else {
                // Key is released. Clear the corresponding bit.
                // `~mask` inverts the bits (e.g., `...00100` becomes `...11011`).
                // The `&` operation then clears just the one bit we care about.
                keys_pressed.* &= ~mask;
                return KeyEvent{ .bit = mask, .pressed = false, .changed = was_set };
            }
        }
    }

    // If the key code wasn't in our bindings, we don't care about it.
    return null;
}
