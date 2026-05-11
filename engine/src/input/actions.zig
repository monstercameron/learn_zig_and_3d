const std = @import("std");
const platform_input = @import("platform_input");

pub const InputContext = enum {
    gameplay,
    editor,
};

pub const InputAction = enum(u8) {
    confirm,
    secondary_trigger,
    move_forward,
    move_backward,
    move_left,
    move_right,
    move_up,
    move_down,
    turn_left,
    turn_right,
    turn_up,
    turn_down,
    jump,
    toggle_camera_mode,
    fov_decrease,
    fov_increase,
    toggle_scene_item_gizmo,
    toggle_light_gizmo,
    gizmo_axis_x,
    gizmo_axis_y,
    gizmo_axis_z,
    cycle_light_selection,
    nudge_negative,
    nudge_positive,
    toggle_overlay,
    toggle_shadow_debug,
    advance_shadow_debug,

    pub fn mask(self: InputAction) u64 {
        return @as(u64, 1) << @as(u6, @intCast(@intFromEnum(self)));
    }
};

pub const ActionState = struct {
    current_bits: u64 = 0,
    pressed_bits: u64 = 0,
    released_bits: u64 = 0,

    pub fn isDown(self: ActionState, action: InputAction) bool {
        return (self.current_bits & action.mask()) != 0;
    }

    pub fn wasPressed(self: ActionState, action: InputAction) bool {
        return (self.pressed_bits & action.mask()) != 0;
    }

    pub fn wasReleased(self: ActionState, action: InputAction) bool {
        return (self.released_bits & action.mask()) != 0;
    }

    pub fn axis(self: ActionState, negative: InputAction, positive: InputAction) f32 {
        const negative_down = self.isDown(negative);
        const positive_down = self.isDown(positive);
        if (negative_down == positive_down) return 0.0;
        return if (positive_down) 1.0 else -1.0;
    }

    pub fn setHeld(self: *ActionState, action: InputAction) void {
        self.current_bits |= action.mask();
    }

    pub fn setPressed(self: *ActionState, action: InputAction) void {
        self.pressed_bits |= action.mask();
    }

    pub fn setReleased(self: *ActionState, action: InputAction) void {
        self.released_bits |= action.mask();
    }
};

pub const BindingTrigger = enum {
    hold,
    press,
};

pub const BindingSource = union(enum) {
    key: platform_input.Key,
    mouse_button: platform_input.MouseButton,
    key_chord: struct {
        modifier: platform_input.Key,
        key: platform_input.Key,
    },
};

pub const InputBinding = struct {
    action: InputAction,
    source: BindingSource,
    trigger: BindingTrigger = .hold,
};

pub const BindingMap = struct {
    bindings: []const InputBinding,

    pub fn resolve(self: BindingMap, keyboard: platform_input.KeyboardState, mouse: platform_input.MouseState) ActionState {
        var actions = ActionState{};
        for (self.bindings) |binding| {
            applyBinding(&actions, binding, keyboard, mouse);
        }
        return actions;
    }
};

const common_bindings = [_]InputBinding{
    .{ .action = .confirm, .source = .{ .key = .enter } },
    .{ .action = .secondary_trigger, .source = .{ .key = .k } },
    .{ .action = .toggle_camera_mode, .source = .{ .key = .v }, .trigger = .press },
    .{ .action = .fov_decrease, .source = .{ .key = .q }, .trigger = .press },
    .{ .action = .fov_increase, .source = .{ .key = .e }, .trigger = .press },
    .{ .action = .toggle_overlay, .source = .{ .key = .p }, .trigger = .press },
    .{ .action = .toggle_shadow_debug, .source = .{ .key = .h }, .trigger = .press },
    .{ .action = .advance_shadow_debug, .source = .{ .key = .n }, .trigger = .press },
};

const gameplay_bindings = [_]InputBinding{
    .{ .action = .move_forward, .source = .{ .key = .w } },
    .{ .action = .move_backward, .source = .{ .key = .s } },
    .{ .action = .move_left, .source = .{ .key = .a } },
    .{ .action = .move_right, .source = .{ .key = .d } },
    .{ .action = .jump, .source = .{ .key = .space } },
};

const editor_bindings = [_]InputBinding{
    .{ .action = .move_forward, .source = .{ .key = .w } },
    .{ .action = .move_backward, .source = .{ .key = .s } },
    .{ .action = .move_left, .source = .{ .key = .a } },
    .{ .action = .move_right, .source = .{ .key = .d } },
    .{ .action = .move_up, .source = .{ .key = .space } },
    .{ .action = .move_down, .source = .{ .key = .ctrl } },
    .{ .action = .turn_left, .source = .{ .key = .left } },
    .{ .action = .turn_right, .source = .{ .key = .right } },
    .{ .action = .turn_up, .source = .{ .key = .up } },
    .{ .action = .turn_down, .source = .{ .key = .down } },
    .{ .action = .toggle_scene_item_gizmo, .source = .{ .key = .m }, .trigger = .press },
    .{ .action = .toggle_light_gizmo, .source = .{ .key = .g }, .trigger = .press },
    .{ .action = .gizmo_axis_x, .source = .{ .key = .x }, .trigger = .press },
    .{ .action = .gizmo_axis_y, .source = .{ .key = .y }, .trigger = .press },
    .{ .action = .gizmo_axis_z, .source = .{ .key = .z }, .trigger = .press },
    .{ .action = .cycle_light_selection, .source = .{ .key = .l }, .trigger = .press },
    .{ .action = .nudge_negative, .source = .{ .key_chord = .{ .modifier = .ctrl, .key = .j } }, .trigger = .press },
    .{ .action = .nudge_positive, .source = .{ .key_chord = .{ .modifier = .ctrl, .key = .l } }, .trigger = .press },
};

pub fn bindingsForContext(context: InputContext) BindingMap {
    return .{
        .bindings = switch (context) {
            .gameplay => &gameplay_bindings,
            .editor => &editor_bindings,
        },
    };
}

pub fn resolveActions(context: InputContext, keyboard: platform_input.KeyboardState, mouse: platform_input.MouseState) ActionState {
    const common_map = BindingMap{ .bindings = &common_bindings };
    var actions = common_map.resolve(keyboard, mouse);
    const context_map = bindingsForContext(context);
    mergeStates(&actions, context_map.resolve(keyboard, mouse));
    if (context == .editor and keyboard.isDown(.ctrl)) {
        clearAction(&actions, .cycle_light_selection);
    }
    return actions;
}

fn mergeStates(target: *ActionState, next: ActionState) void {
    target.current_bits |= next.current_bits;
    target.pressed_bits |= next.pressed_bits;
    target.released_bits |= next.released_bits;
}

fn clearAction(actions: *ActionState, action: InputAction) void {
    const mask = ~action.mask();
    actions.current_bits &= mask;
    actions.pressed_bits &= mask;
    actions.released_bits &= mask;
}

fn applyBinding(actions: *ActionState, binding: InputBinding, keyboard: platform_input.KeyboardState, mouse: platform_input.MouseState) void {
    switch (binding.source) {
        .key => |key| applyKeyBinding(actions, binding.action, binding.trigger, keyboard, key),
        .mouse_button => |button| applyMouseBinding(actions, binding.action, binding.trigger, mouse, button),
        .key_chord => |chord| applyChordBinding(actions, binding.action, binding.trigger, keyboard, chord.modifier, chord.key),
    }
}

fn applyKeyBinding(actions: *ActionState, action: InputAction, trigger: BindingTrigger, keyboard: platform_input.KeyboardState, key: platform_input.Key) void {
    if (keyboard.isDown(key)) actions.setHeld(action);
    switch (trigger) {
        .hold => {
            if (keyboard.wasPressed(key)) actions.setPressed(action);
            if (keyboard.wasReleased(key)) actions.setReleased(action);
        },
        .press => if (keyboard.wasPressed(key)) actions.setPressed(action),
    }
}

fn applyMouseBinding(actions: *ActionState, action: InputAction, trigger: BindingTrigger, mouse: platform_input.MouseState, button: platform_input.MouseButton) void {
    if (mouse.isDown(button)) actions.setHeld(action);
    switch (trigger) {
        .hold => {
            if (mouse.wasPressed(button)) actions.setPressed(action);
            if (mouse.wasReleased(button)) actions.setReleased(action);
        },
        .press => if (mouse.wasPressed(button)) actions.setPressed(action),
    }
}

fn applyChordBinding(actions: *ActionState, action: InputAction, trigger: BindingTrigger, keyboard: platform_input.KeyboardState, modifier: platform_input.Key, key: platform_input.Key) void {
    const active = keyboard.isDown(modifier) and keyboard.isDown(key);
    if (active) actions.setHeld(action);
    switch (trigger) {
        .hold => {
            if (keyboard.isDown(modifier) and keyboard.wasPressed(key)) actions.setPressed(action);
            if (keyboard.wasReleased(key) or keyboard.wasReleased(modifier)) actions.setReleased(action);
        },
        .press => if (keyboard.isDown(modifier) and keyboard.wasPressed(key)) actions.setPressed(action),
    }
}

test "resolve gameplay actions maps movement and jump" {
    var keyboard = platform_input.KeyboardState{};
    _ = keyboard.setKey(.w, true);
    _ = keyboard.setKey(.d, true);
    _ = keyboard.setKey(.space, true);
    const actions = resolveActions(.gameplay, keyboard, .{});

    try std.testing.expect(actions.isDown(.move_forward));
    try std.testing.expect(actions.isDown(.move_right));
    try std.testing.expect(actions.isDown(.jump));
    try std.testing.expect(!actions.isDown(.move_up));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), actions.axis(.move_left, .move_right), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), actions.axis(.move_backward, .move_forward), 0.0001);
}

test "resolve editor actions maps gizmo and nudge chords" {
    var keyboard = platform_input.KeyboardState{};
    _ = keyboard.setKey(.ctrl, true);
    _ = keyboard.setKey(.j, true);
    _ = keyboard.setKey(.m, true);
    _ = keyboard.setKey(.left, true);
    _ = keyboard.setKey(.space, true);
    const actions = resolveActions(.editor, keyboard, .{});

    try std.testing.expect(actions.wasPressed(.nudge_negative));
    try std.testing.expect(actions.wasPressed(.toggle_scene_item_gizmo));
    try std.testing.expect(actions.isDown(.turn_left));
    try std.testing.expect(actions.isDown(.move_up));
    try std.testing.expect(actions.isDown(.move_down));
    try std.testing.expect(!actions.wasPressed(.cycle_light_selection));
}

test "resolve editor actions keeps light cycle separate from ctrl chord" {
    var keyboard = platform_input.KeyboardState{};
    _ = keyboard.setKey(.l, true);
    const actions = resolveActions(.editor, keyboard, .{});

    try std.testing.expect(actions.wasPressed(.cycle_light_selection));
    try std.testing.expect(!actions.wasPressed(.nudge_positive));
}

test "action axis cancels opposing inputs" {
    var actions = ActionState{};
    actions.setHeld(.turn_left);
    actions.setHeld(.turn_right);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), actions.axis(.turn_left, .turn_right), 0.0001);
}
