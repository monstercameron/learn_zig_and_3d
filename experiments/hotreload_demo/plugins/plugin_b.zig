const std = @import("std");
const iface = @import("iface");

const State = struct {
    accumulated: f32 = 0.0,
};

var g_host: *const iface.HostAPI = undefined;
var g_state = State{};

fn run(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
    g_state.accumulated += 0.5;
    var buffer: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buffer, "[plugin-b] accumulated={d:.1}", .{g_state.accumulated}) catch return;
    g_host.print(g_host.user_data, msg.ptr, msg.len);
}

fn shutdown(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
    const msg = "[plugin-b] shutdown";
    g_host.print(g_host.user_data, msg.ptr, msg.len);
}

pub export fn plugin_entry(out_api: *iface.PluginAPI, host_api: *const iface.HostAPI) callconv(.c) ?*anyopaque {
    g_host = host_api;
    out_api.* = iface.PluginAPI{
        .run = run,
        .shutdown = shutdown,
    };
    return &g_state;
}
