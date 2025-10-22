const std = @import("std");

pub const VERSION: u32 = 1;

pub const HostPrintFn = *const fn (ctx: ?*anyopaque, message: []const u8) callconv(.c) void;

pub const PluginRunFn = *const fn (ctx: *anyopaque) callconv(.c) void;
pub const PluginShutdownFn = *const fn (ctx: *anyopaque) callconv(.c) void;

pub const HostAPI = struct {
    /// Optional opaque pointer supplied by the host.
    user_data: ?*anyopaque = null,
    /// Print a UTF-8 message to the host console/log.
    print: HostPrintFn,
};

pub const PluginAPI = struct {
    /// Execute the plugin logic. The opaque context pointer is provided by the plugin.
    run: PluginRunFn,
    /// Allow the plugin to release any resources prior to unload.
    shutdown: PluginShutdownFn,
};

/// The required entry point signature that every plugin must export as `plugin_entry`.
pub const PluginEntry = *const fn (out_api: *PluginAPI, host_api: *const HostAPI) callconv(.c) ?*anyopaque;

pub fn versionString() []const u8 {
    return "hotreload_demo_plugin_v1";
}
