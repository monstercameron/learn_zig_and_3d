const std = @import("std");
const iface = @import("iface");

const State = struct {
    run_count: u32 = 0,
};

const BuildId: u32 = 4;

var g_host: *const iface.HostAPI = undefined;
var g_state = State{};

fn run(ctx: *anyopaque) callconv(.c) void {
    _ = ctx; // state pointer equals &g_state
    g_state.run_count += 1;
    var buffer: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buffer, "[plugin-a] build={d} run #{d}", .{ BuildId, g_state.run_count }) catch return;
    g_host.print(g_host.user_data, msg.ptr, msg.len);
}

fn shutdown(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
    const msg = "[plugin-a] shutdown";
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
