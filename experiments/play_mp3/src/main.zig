const std = @import("std");
const audio = @import("audio/audio.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.debug.print("Initializing audio engine...\n", .{});
    try audio.init(allocator);
    defer audio.deinit();

    const file_path = "resources\\music\\udio.mp3";
    std.debug.print("Loading MP3: {s}...\n", .{file_path});
    
    const sound = try audio.loadMp3(allocator, file_path) catch |err| {
        std.debug.print("Failed to load MP3: {any}\n", .{err});
        return;
    };
    defer audio.unload(allocator, sound);

    std.debug.print("Playing sound...\n", .{});
    _ = try audio.play(sound, .{ .volume = 0.7 });

    std.debug.print("Playing for 20 seconds...\n", .{});
    std.time.sleep(20 * std.time.ns_per_s);

    std.debug.print("Experiment finished.\n", .{});
}
