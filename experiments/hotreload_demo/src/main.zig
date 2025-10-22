const std = @import("std");
const builtin = @import("builtin");
const iface = @import("iface");
const ascii = std.ascii;

const PluginHandle = struct {
    lib: std.DynLib,
    api: iface.PluginAPI,
    ctx: *anyopaque,

    fn deinit(self: *PluginHandle) void {
        self.api.shutdown(self.ctx);
        self.lib.close();
    }
};

fn bumpPluginBuildId(allocator: std.mem.Allocator, source_path: []const u8) !u32 {
    var file = try std.fs.cwd().openFile(source_path, .{ .mode = .read_write });
    defer file.close();

    const stat = try file.stat();
    const size = std.math.cast(usize, stat.size) orelse return error.SourceTooLarge;

    var buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);

    const read_len = try file.readAll(buffer);
    const contents = buffer[0..read_len];

    const marker = "const BuildId: u32 = ";
    const marker_index = std.mem.indexOf(u8, contents, marker) orelse return error.MarkerNotFound;

    const digits_index = marker_index + marker.len;
    var digits_end = digits_index;
    while (digits_end < contents.len and ascii.isDigit(contents[digits_end])) {
        digits_end += 1;
    }
    if (digits_end == digits_index) return error.MarkerNotFound;

    const number_slice = contents[digits_index..digits_end];
    const current_value = try std.fmt.parseInt(u32, number_slice, 10);
    const new_value = current_value + 1;

    const replacement = try std.fmt.allocPrint(allocator, "{d}", .{new_value});
    defer allocator.free(replacement);

    var updated = std.ArrayListUnmanaged(u8){};
    defer updated.deinit(allocator);
    try updated.appendSlice(allocator, contents[0..digits_index]);
    try updated.appendSlice(allocator, replacement);
    try updated.appendSlice(allocator, contents[digits_end..]);

    try file.seekTo(0);
    try file.writeAll(updated.items);
    try file.setEndPos(updated.items.len);

    return new_value;
}

fn rebuildPluginStep(allocator: std.mem.Allocator) !void {
    var argv_storage: [4][]const u8 = undefined;
    var argv: []const []const u8 = undefined;
    var command_buf: ?[]u8 = null;
    defer if (command_buf) |buf| allocator.free(buf);

    if (builtin.os.tag == .windows) {
        command_buf = try std.fmt.allocPrint(allocator, "{s}", .{"zig build"});
        argv_storage = [_][]const u8{ "powershell", "-NoProfile", "-Command", command_buf.? };
        argv = argv_storage[0..4];
    } else {
        argv_storage = [_][]const u8{ "zig", "build", "", "" };
        argv = argv_storage[0..2];
    }

    var child = std.process.Child.init(argv, allocator);
    child.cwd = null; // inherit the caller's working directory
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const term = try child.wait();
    if (@hasDecl(@TypeOf(child), "deinit")) {
        child.deinit();
    }
    switch (term) {
        .Exited => |code| if (code != 0) return error.RebuildFailed,
        else => return error.RebuildFailed,
    }
}

fn sleepInterval(poll_ns: u64) void {
    if (builtin.os.tag == .windows) {
        const ms_rounded = @divFloor(poll_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        const clamped = @min(ms_rounded, @as(u64, std.math.maxInt(u32)));
        const ms_u32 = std.math.cast(u32, clamped) orelse std.math.maxInt(u32);
        std.os.windows.kernel32.Sleep(ms_u32);
    } else {
        std.time.sleep(poll_ns);
    }
}

fn reloadPluginWithRetry(
    allocator: std.mem.Allocator,
    path: []const u8,
    host_api: *const iface.HostAPI,
    attempts: usize,
    delay_ns: u64,
) !PluginHandle {
    var attempt: usize = 0;
    while (attempt < attempts) : (attempt += 1) {
        const handle = loadPlugin(allocator, path, host_api) catch |err| {
            if (attempt + 1 == attempts) return err;
            sleepInterval(delay_ns);
            continue;
        };
        return handle;
    }
    unreachable;
}

fn hostPrint(ctx: ?*anyopaque, message_ptr: [*]const u8, message_len: usize) callconv(.c) void {
    _ = ctx;
    const message = message_ptr[0..message_len];
    std.debug.print("{s}\n", .{message});
}

fn loadPlugin(
    allocator: std.mem.Allocator,
    path: []const u8,
    host_api: *const iface.HostAPI,
) !PluginHandle {
    var zpath = try allocator.alloc(u8, path.len + 1);
    defer allocator.free(zpath);
    std.mem.copyForwards(u8, zpath[0..path.len], path);
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

    const plugin1_path = args.next() orelse {
        std.debug.print("Usage: hotreload_demo <plugin-a> <plugin-b>\n", .{});
        return;
    };
    const plugin2_path = args.next() orelse {
        std.debug.print("Usage: hotreload_demo <plugin-a> <plugin-b>\n", .{});
        return;
    };

    var host_api = iface.HostAPI{
        .user_data = null,
        .print = hostPrint,
    };

    std.debug.print("Loading plugin #1: {s}\n", .{plugin1_path});
    var plugin1 = try loadPlugin(allocator, plugin1_path, &host_api);
    var plugin1_loaded = true;
    defer if (plugin1_loaded) plugin1.deinit();
    const plugin1_source = "plugins/plugin_a.zig";

    std.debug.print("Running plugin #1...\n", .{});
    plugin1.api.run(plugin1.ctx);

    std.debug.print("Loading plugin #2: {s}\n", .{plugin2_path});
    var plugin2 = try loadPlugin(allocator, plugin2_path, &host_api);
    defer plugin2.deinit();

    std.debug.print("Running plugin #2...\n", .{});
    plugin2.api.run(plugin2.ctx);

    std.debug.print("\nUnloading plugin #1 so it can be rebuilt...\n", .{});
    plugin1.deinit();
    plugin1_loaded = false;

    std.debug.print("Patching {s} (increment BuildId)...\n", .{plugin1_source});
    const new_build_id = try bumpPluginBuildId(allocator, plugin1_source);
    std.debug.print("New BuildId: {d}\n", .{new_build_id});

    std.debug.print("Invoking `zig build`...\n", .{});
    try rebuildPluginStep(allocator);

    std.debug.print("Build finished; attempting to reload plugin #1...\n", .{});
    plugin1 = try reloadPluginWithRetry(allocator, plugin1_path, &host_api, 8, 100 * std.time.ns_per_ms);
    plugin1_loaded = true;

    std.debug.print("Running plugin #1 after reload (BuildId={d})...\n", .{new_build_id});
    plugin1.api.run(plugin1.ctx);
}
