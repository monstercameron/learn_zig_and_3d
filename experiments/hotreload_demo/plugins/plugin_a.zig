const std = @import("std");
const iface = @import("iface");

const State = struct {
    run_count: u32 = 0,
};

var g_host: *const iface.HostAPI = undefined;
var g_state = State{};

fn run(ctx: *anyopaque) void {
    _ = ctx; // state pointer equals &g_state
    g_state.run_count += 1;
    var buffer: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buffer, "[plugin-a] run #{d}", .{g_state.run_count}) catch return;
    g_host.print(g_host.user_data, msg);
}

fn shutdown(ctx: *anyopaque) void {
    _ = ctx;
    g_host.print(g_host.user_data, "[plugin-a] shutdown");
}

pub export fn plugin_entry callconv(.c)(out_api: *iface.PluginAPI, host_api: *const iface.HostAPI) ?*anyopaque {
    g_host = host_api;
    out_api.* = iface.PluginAPI{
        .run = run,
        .shutdown = shutdown,
    };
    return &g_state;
}
