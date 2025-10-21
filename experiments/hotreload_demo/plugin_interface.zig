const std = @import("std");

pub const VERSION: u32 = 1;

pub const HostAPI = struct {
    /// Optional opaque pointer supplied by the host.
    user_data: ?*anyopaque = null,
    /// Print a UTF-8 message to the host console/log.
    print: *const fn (ctx: ?*anyopaque, message: []const u8) void,
};

pub const PluginAPI = struct {
    /// Execute the plugin logic. The opaque context pointer is provided by the plugin.
    run: *const fn (ctx: *anyopaque) void,
    /// Allow the plugin to release any resources prior to unload.
    shutdown: *const fn (ctx: *anyopaque) void,
};

/// The required entry point signature that every plugin must export as `plugin_entry`.
pub const PluginEntry = *const fn (out_api: *PluginAPI, host_api: *const HostAPI) ?*anyopaque;

pub fn versionString() []const u8 {
    return "hotreload_demo_plugin_v1";
}
