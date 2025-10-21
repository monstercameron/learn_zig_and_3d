const std = @import("std");
const engine = @import("audio/engine.zig");

// The global audio engine instance.
var g_audio_engine: ?engine.AudioEngine = null;

/// A handle to a loaded sound resource. Contains the raw, decoded audio data.
pub const Sound = struct {
    samples: []f32,
    sample_rate: u32,
    channels: u16,

    pub fn frameCount(self: Sound) usize {
        if (self.channels == 0) return 0;
        return self.samples.len / self.channels;
    }
};

/// A handle to a single instance of a sound being played.
pub const PlaybackHandle = struct {
    id: u64,
};

/// Parameters to modify how a sound is played.
pub const PlaybackParams = struct {
    volume: f32 = 1.0,
    looping: bool = false,
    pitch: f32 = 1.0,
    speed: f32 = 1.0,
    reverse: bool = false,
};

// --- Engine Management ---

/// Initializes the audio engine. Must be called once at application startup.
pub fn init(allocator: std.mem.Allocator) !void {
    if (g_audio_engine != null) return; // Already initialized
    g_audio_engine = try engine.AudioEngine.init(allocator);
}

/// Shuts down the audio engine. Must be called once at shutdown.
pub fn deinit() void {
    if (g_audio_engine) |*audio_engine| {
        audio_engine.deinit();
        g_audio_engine = null;
    }
}

/// Starts the audio engine's backend thread. Must be called after init.
pub fn start() !void {
    if (g_audio_engine) |*audio_engine| {
        return audio_engine.start();
    }
    return error.AudioEngineNotInitialized;
}

/// Sets the master volume for all sounds (0.0 to 1.0).
pub fn setMasterVolume(volume: f32) void {
    if (g_audio_engine) |*audio_engine| {
        audio_engine.setMasterVolume(volume);
    }
}


// --- Sound Loading & Unloading (Memory Management) ---

pub fn loadWav(allocator: std.mem.Allocator, file_path: []const u8) !*Sound {
    if (g_audio_engine) |*audio_engine| {
        return audio_engine.loadWav(file_path);
    }
    return error.AudioEngineNotInitialized;
}

pub fn loadMp3(allocator: std.mem.Allocator, file_path: []const u8) !*Sound {
    if (g_audio_engine) |*audio_engine| {
        return audio_engine.loadMp3(file_path);
    }
    return error.AudioEngineNotInitialized;
}

pub fn unload(sound: *Sound) void {
     if (g_audio_engine) |*audio_engine| {
        audio_engine.unload(sound);
    }
}


// --- Playback Control ---

pub fn play(sound: *const Sound, params: PlaybackParams) !PlaybackHandle {
    if (g_audio_engine) |*audio_engine| {
        return audio_engine.play(sound, params);
    }
    return error.AudioEngineNotInitialized;
}

pub fn stop(handle: PlaybackHandle) void {
    if (g_audio_engine) |*audio_engine| {
        audio_engine.stop(handle);
    }
}

pub fn pause(handle: PlaybackHandle) void {
    if (g_audio_engine) |*audio_engine| {
        audio_engine.pause(handle);
    }
}

pub fn resume(handle: PlaybackHandle) void {
    if (g_audio_engine) |*audio_engine| {
        audio_engine.resume(handle);
    }
}

// --- Dynamic Playback Modification ---

pub fn setVolume(handle: PlaybackHandle, volume: f32) void {
    if (g_audio_engine) |*audio_engine| {
        audio_engine.setVolume(handle, volume);
    }
}

pub fn setPitch(handle: PlaybackHandle, pitch: f32) void {
    if (g_audio_engine) |*audio_engine| {
        audio_engine.setPitch(handle, pitch);
    }
}

pub fn setSpeed(handle: PlaybackHandle, speed: f32) void {
    if (g_audio_engine) |*audio_engine| {
        audio_engine.setSpeed(handle, speed);
    }
}