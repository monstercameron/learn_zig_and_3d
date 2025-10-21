const std = @import("std");
const iface = @import("iface");

const PluginHandle = struct {
    lib: std.DynLib,
    api: iface.PluginAPI,
    ctx: *anyopaque,
};

fn hostPrint(ctx: ?*anyopaque, message: []const u8) void {
    _ = ctx;
    std.debug.print("{s}\n", .{message});
}

fn loadPlugin(
    allocator: std.mem.Allocator,
    path: []const u8,
    host_api: *const iface.HostAPI,
) !PluginHandle {
    var zpath = try allocator.alloc(u8, path.len + 1);
    defer allocator.free(zpath);
    std.mem.copy(u8, zpath[0..path.len], path);
    zpath[path.len] = 0;
    const zslice = std.mem.sliceTo(zpath, 0);

    var lib = try std.DynLib.open(zslice);
    errdefer lib.close();

    const entry = lib.lookup(iface.PluginEntry, "plugin_entry") orelse return error.MissingPluginEntry;

    var api: iface.PluginAPI = undefined;
    const ctx = entry(&api, host_api) orelse return error.PluginReturnedNullContext;

    return PluginHandle{
        .lib = lib,
        .api = api,
        .ctx = ctx,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip executable name

    var handles = std.ArrayListUnmanaged(PluginHandle){};
    defer {
        for (handles.items) |*handle| {
            handle.api.shutdown(handle.ctx);
            handle.lib.close();
        }
        handles.deinit(allocator);
    }

    var host_api = iface.HostAPI{
        .user_data = null,
        .print = hostPrint,
    };

    var plugin_count: usize = 0;
    while (args.next()) |path| {
        const handle = try loadPlugin(allocator, path, &host_api);
        try handles.append(allocator, handle);
        plugin_count += 1;
        std.debug.print("Loaded plugin: {s}\n", .{path});
    }

    if (plugin_count == 0) {
        std.debug.print("Usage: hotreload_demo <plugin-path> [more ...]\n", .{});
        return;
    }

    std.debug.print("Executing {d} plugin(s)...\n", .{plugin_count});
    for (handles.items) |handle| {
        handle.api.run(handle.ctx);
    }
}
