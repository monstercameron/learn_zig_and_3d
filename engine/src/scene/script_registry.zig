//! Native scene script registry.

const asset_registry = @import("asset_registry.zig");
const script_host = @import("script_host.zig");
const default_camera_controls_script = @import("scripts/default_camera_controls.zig");
const default_renderer_controls_script = @import("scripts/default_renderer_controls.zig");
const monkey_breathe_rotate_script = @import("scripts/monkey_breathe_rotate.zig");
const shadow_single_model_jump_box_script = @import("scripts/shadow_single_model_jump_box.zig");
const shadow_single_model_player_camera_script = @import("scripts/shadow_single_model_player_camera.zig");

pub const NativeScriptModule = struct {
    name: []const u8,
    vtable: script_host.ScriptModuleVTable,
};

const native_modules = [_]NativeScriptModule{
    .{
        .name = "builtin.noop",
        .vtable = .{ .on_event = noopScriptEvent },
    },
    .{
        .name = default_camera_controls_script.module_name,
        .vtable = default_camera_controls_script.vtable,
    },
    .{
        .name = default_renderer_controls_script.module_name,
        .vtable = default_renderer_controls_script.vtable,
    },
    .{
        .name = monkey_breathe_rotate_script.module_name,
        .vtable = monkey_breathe_rotate_script.vtable,
    },
    .{
        .name = shadow_single_model_jump_box_script.module_name,
        .vtable = shadow_single_model_jump_box_script.vtable,
    },
    .{
        .name = shadow_single_model_player_camera_script.module_name,
        .vtable = shadow_single_model_player_camera_script.vtable,
    },
};

pub fn registerNativeModules(host: *script_host.ScriptHost, assets: *asset_registry.AssetRegistry) !void {
    for (native_modules) |module| {
        if (host.lookupModuleByName(module.name) != null) continue;
        _ = try host.registerNativeModule(assets, module.name, module.vtable);
    }
}

fn noopScriptEvent(ctx: *script_host.ScriptCallbackContext) void {
    _ = ctx;
}
