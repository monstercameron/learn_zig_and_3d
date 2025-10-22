const std = @import("std");

/// Defines the severity of a log message.
pub const LogLevel = enum(u8) {
    debug,
    info,
    warn,
    @"error",
    none, // Special level to disable logging for a namespace.

    pub fn shouldLog(self: LogLevel, min_level: LogLevel) bool {
        return @intFromEnum(self) >= @intFromEnum(min_level);
    }

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .@"error" => "ERROR",
            .none => "NONE",
        };
    }
};

const LogManager = struct {
    allocator: std.mem.Allocator,
    global_level: LogLevel,
    namespace_levels: std.StringHashMap(LogLevel),

    fn init(allocator: std.mem.Allocator) LogManager {
        return .{
            .allocator = allocator,
            .global_level = .info,
            .namespace_levels = std.StringHashMap(LogLevel).init(allocator),
        };
    }

    fn deinit(self: *LogManager) void {
        // Free the keys (namespace strings) we duplicated
        var it = self.namespace_levels.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.namespace_levels.deinit();
        self.* = undefined;
    }

    fn getEffectiveLevel(self: *const LogManager, namespace: []const u8) LogLevel {
        return self.namespace_levels.get(namespace) orelse self.global_level;
    }

    fn log(self: *LogManager, level: LogLevel, namespace: []const u8, subsystem: ?[]const u8, comptime format: []const u8, args: anytype) void {
        const effective_level = self.getEffectiveLevel(namespace);
        if (!level.shouldLog(effective_level)) {
            return;
        }

        const sub_label = subsystem orelse "general";
        std.debug.print("[{s}] [{s}] [{s}] " ++ format ++ "\n", .{
            namespace,
            level.toString(),
            sub_label,
        } ++ args);
    }
};

var g_log_manager: ?LogManager = null;

// --- Public Configuration API ---

pub fn init(allocator: std.mem.Allocator) void {
    if (g_log_manager == null) g_log_manager = LogManager.init(allocator);
}

pub fn deinit() void {
    if (g_log_manager) |*manager| {
        manager.deinit();
        g_log_manager = null;
    }
}

pub fn setLevel(level: LogLevel) void {
    if (g_log_manager) |*manager| manager.global_level = level;
}

pub fn setLevelFor(namespace: []const u8, level: LogLevel) !void {
    if (g_log_manager) |*manager| {
        try manager.namespace_levels.put(try manager.allocator.dupe(u8, namespace), level);
    }
}

// --- Public Logging API ---

pub const Logger = struct {
    namespace: []const u8,

    pub inline fn debug(self: Logger, comptime format: []const u8, args: anytype) void {
        if (g_log_manager) |*manager| manager.log(.debug, self.namespace, null, format, args);
    }

    pub inline fn info(self: Logger, comptime format: []const u8, args: anytype) void {
        if (g_log_manager) |*manager| manager.log(.info, self.namespace, null, format, args);
    }

    pub inline fn warn(self: Logger, comptime format: []const u8, args: anytype) void {
        if (g_log_manager) |*manager| manager.log(.warn, self.namespace, null, format, args);
    }

    pub inline fn @"error"(self: Logger, comptime format: []const u8, args: anytype) void {
        if (g_log_manager) |*manager| manager.log(.@"error", self.namespace, null, format, args);
    }

    pub inline fn debugSub(self: Logger, subsystem: []const u8, comptime format: []const u8, args: anytype) void {
        if (g_log_manager) |*manager| manager.log(.debug, self.namespace, subsystem, format, args);
    }

    pub inline fn infoSub(self: Logger, subsystem: []const u8, comptime format: []const u8, args: anytype) void {
        if (g_log_manager) |*manager| manager.log(.info, self.namespace, subsystem, format, args);
    }

    pub inline fn warnSub(self: Logger, subsystem: []const u8, comptime format: []const u8, args: anytype) void {
        if (g_log_manager) |*manager| manager.log(.warn, self.namespace, subsystem, format, args);
    }

    pub inline fn errorSub(self: Logger, subsystem: []const u8, comptime format: []const u8, args: anytype) void {
        if (g_log_manager) |*manager| manager.log(.@"error", self.namespace, subsystem, format, args);
    }
};

pub fn get(namespace: []const u8) Logger {
    return Logger{ .namespace = namespace };
}
