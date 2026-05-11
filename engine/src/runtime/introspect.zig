//! Runtime introspection — structured snapshots the agent can read.
//!
//! Two surfaces:
//!
//! 1. **Hooks**: code paths can register a `FrameHook` callback that the
//!    engine fires at well-known events (frame_end today; later
//!    pass_complete, stage_complete, scene_changed, alloc, etc.).
//!
//! 2. **Snapshots**: each event carries a structured payload that can be
//!    emitted as JSON for an external agent to read. The payload schema
//!    is stable so tooling can rely on field names.
//!
//! Env-controlled. By default the introspection module is silent — no
//! overhead, no output. To enable:
//!
//! - `ZIG_INTROSPECT=1`           — register the default JSON-line emitter
//! - `ZIG_INTROSPECT_OUTPUT=path` — write JSON to `path` instead of stderr
//!                                  (default: stderr, prefix "INTROSPECT ")
//!
//! Future surface additions:
//!
//! - `PassEvent` per render-pass with name + duration_ns
//! - `StageEvent` per frame-plan stage
//! - `AllocEvent` from a wrapped allocator counting bytes
//! - `JobEvent` from the job system (queue depth, worker active)

const std = @import("std");

pub const SceneSnapshot = struct {
    triangle_count: usize = 0,
    meshlet_count: usize = 0,
    vertex_count: usize = 0,
    light_count: usize = 0,
    shadow_map_lights: usize = 0,
    touched_tiles: usize = 0,
    active_tile_count: usize = 0,
    triangles_rasterized: usize = 0,
    covered_pixels: usize = 0,
};

pub const PacingSnapshot = struct {
    mode: []const u8 = "unknown",
    target_ms: f32 = 0,
    last_frame_ms: f32 = 0,
    deadline_error_ms: f32 = 0,
    present_ms: f32 = 0,
};

pub const PassSample = struct {
    name: []const u8,
    last_ns: i128,
    sampled_ms_per_frame: f32,
};

pub const JobSystemSnapshot = struct {
    worker_count: usize = 0,
};

pub const MemorySnapshot = struct {
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    bytes_in_use: u64 = 0,
    peak_bytes: u64 = 0,
};

pub const FrameSnapshot = struct {
    frame_index: u64,
    timestamp_ns: i128,
    frame_ns: i128,

    backbuffer_width: i32,
    backbuffer_height: i32,

    scene: SceneSnapshot,
    pacing: PacingSnapshot,
    job_system: JobSystemSnapshot,
    memory: MemorySnapshot,

    passes: []const PassSample,
};

pub const FrameHook = *const fn (snapshot: *const FrameSnapshot) void;

const max_hooks: usize = 8;
var hook_buffer: [max_hooks]FrameHook = undefined;
var hook_count: usize = 0;
var initialized: bool = false;
var enabled_cached: bool = false;
var output_path_buf: [256]u8 = undefined;
var output_path_len: usize = 0;

/// Returns true if introspection is enabled via the ZIG_INTROSPECT env
/// var. Cached on first call.
pub fn isEnabled() bool {
    if (initialized) return enabled_cached;
    initialized = true;
    enabled_cached = std.process.hasEnvVarConstant("ZIG_INTROSPECT");
    if (enabled_cached) {
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "ZIG_INTROSPECT_OUTPUT")) |path| {
            defer std.heap.page_allocator.free(path);
            const copy_len = @min(path.len, output_path_buf.len);
            @memcpy(output_path_buf[0..copy_len], path[0..copy_len]);
            output_path_len = copy_len;
        } else |_| {
            output_path_len = 0;
        }
    }
    return enabled_cached;
}

/// Register a callback the engine fires at frame end. Silent if the
/// hook table is full.
pub fn registerFrameHook(hook: FrameHook) void {
    if (hook_count >= max_hooks) return;
    hook_buffer[hook_count] = hook;
    hook_count += 1;
}

/// Engine-side: call this once per frame at finalize time. No-op if
/// nothing registered.
pub fn emitFrame(snapshot: *const FrameSnapshot) void {
    var i: usize = 0;
    while (i < hook_count) : (i += 1) {
        hook_buffer[i](snapshot);
    }
}

/// Default hook: emit the snapshot as a single JSON line to stderr (or
/// the file path from ZIG_INTROSPECT_OUTPUT). Registered when
/// `installDefaultJsonEmitter()` is called by the runtime bootstrap.
pub fn jsonLineEmitter(snapshot: *const FrameSnapshot) void {
    if (output_path_len > 0) {
        writeToFile(output_path_buf[0..output_path_len], snapshot) catch {};
    } else {
        const stderr = std.fs.File.stderr();
        var stderr_writer = stderr.writer(&.{});
        stderr_writer.interface.print("INTROSPECT ", .{}) catch return;
        writeFrameJson(snapshot, &stderr_writer.interface) catch return;
        stderr_writer.interface.print("\n", .{}) catch return;
        stderr_writer.interface.flush() catch return;
    }
}

fn writeToFile(path: []const u8, snapshot: *const FrameSnapshot) !void {
    const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return error.OpenFailed;
    defer file.close();
    try file.seekFromEnd(0);
    var file_writer = file.writer(&.{});
    try writeFrameJson(snapshot, &file_writer.interface);
    try file_writer.interface.print("\n", .{});
    try file_writer.interface.flush();
}

/// Stable JSON schema. Field order is preserved for diff-friendly
/// output. Keep this lockstep with the FrameSnapshot fields.
pub fn writeFrameJson(snapshot: *const FrameSnapshot, w: anytype) !void {
    try w.print(
        \\{{"frame":{},"timestamp_ns":{},"frame_ns":{},"width":{},"height":{}
    , .{
        snapshot.frame_index,
        snapshot.timestamp_ns,
        snapshot.frame_ns,
        snapshot.backbuffer_width,
        snapshot.backbuffer_height,
    });
    try writeSceneJson(snapshot.scene, w);
    try writePacingJson(snapshot.pacing, w);
    try writeJobsJson(snapshot.job_system, w);
    try writeMemoryJson(snapshot.memory, w);
    try writePassesJson(snapshot.passes, w);
    try w.print("}}", .{});
}

fn writeSceneJson(s: SceneSnapshot, w: anytype) !void {
    try w.print(
        \\,"scene":{{"tris":{},"meshlets":{},"verts":{},"lights":{},"shadow_map_lights":{},"touched_tiles":{},"active_tiles":{},"rasterized":{},"covered_pixels":{}}}
    , .{ s.triangle_count, s.meshlet_count, s.vertex_count, s.light_count, s.shadow_map_lights, s.touched_tiles, s.active_tile_count, s.triangles_rasterized, s.covered_pixels });
}

fn writePacingJson(p: PacingSnapshot, w: anytype) !void {
    try w.print(
        \\,"pacing":{{"mode":"{s}","target_ms":{d:.3},"last_ms":{d:.3},"deadline_err_ms":{d:.3},"present_ms":{d:.3}}}
    , .{ p.mode, p.target_ms, p.last_frame_ms, p.deadline_error_ms, p.present_ms });
}

fn writeJobsJson(j: JobSystemSnapshot, w: anytype) !void {
    try w.print(
        \\,"jobs":{{"workers":{}}}
    , .{j.worker_count});
}

fn writeMemoryJson(m: MemorySnapshot, w: anytype) !void {
    try w.print(
        \\,"mem":{{"allocs":{},"frees":{},"bytes_in_use":{},"peak_bytes":{}}}
    , .{ m.alloc_count, m.free_count, m.bytes_in_use, m.peak_bytes });
}

fn writePassesJson(passes: []const PassSample, w: anytype) !void {
    try w.print(",\"passes\":[", .{});
    for (passes, 0..) |pass, idx| {
        if (idx != 0) try w.print(",", .{});
        try w.print(
            \\{{"name":"{s}","last_ns":{},"avg_ms":{d:.4}}}
        , .{ pass.name, pass.last_ns, pass.sampled_ms_per_frame });
    }
    try w.print("]", .{});
}

/// Bootstrap helper: call once at engine startup to wire the default
/// JSON-line emitter when ZIG_INTROSPECT is set. Idempotent.
pub fn installDefaultJsonEmitter() void {
    if (!isEnabled()) return;
    registerFrameHook(jsonLineEmitter);
}
