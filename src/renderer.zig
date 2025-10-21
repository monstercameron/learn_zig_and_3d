//! # The Main Renderer Module
//!
//! This module is the heart and brain of the entire rendering engine. It orchestrates
//! the entire 3D pipeline, from handling user input to update the camera, transforming
//! 3D vertices, dispatching work to the job system, and finally presenting the
//! rendered image to the screen.
//!
//! ## JavaScript Analogy
//!
//! Think of this as the main class in a rendering library like `three.js` (e.g., `WebGLRenderer`)
//! combined with the scene update and render loop logic. It holds the application state
//! and contains the main `render()` method that gets called every frame.
//!
//! ```javascript
//! class App {
//!   constructor() {
//!     this.renderer = new THREE.WebGLRenderer();
//!     this.scene = new THREE.Scene();
//!     this.camera = new THREE.PerspectiveCamera(...);
//!     this.state = { rotation: 0, lightPosition: ... };
//!   }
//!
//!   render() {
//!     // This is what our `render3DMeshWithPump` function does:
//!     this.updateStateFromInput();
//!     this.renderer.render(this.scene, this.camera);
//!   }
//! }
//! ```

const std = @import("std");
const windows = std.os.windows;
const math = @import("math.zig");
const MeshModule = @import("mesh.zig");
const Mesh = MeshModule.Mesh;
const Meshlet = MeshModule.Meshlet;
const config = @import("app_config.zig");
const input = @import("input.zig");
const lighting = @import("lighting.zig");
const scanline = @import("scanline.zig");
const texture = @import("texture.zig");
const WorkTypes = @import("mesh_work_types.zig");
const TrianglePacket = WorkTypes.TrianglePacket;
const TriangleFlags = WorkTypes.TriangleFlags;
const MeshletPacket = WorkTypes.MeshletPacket;

const NEAR_CLIP: f32 = 0.01;
const NEAR_EPSILON: f32 = 1e-4;
const INVALID_PROJECTED_COORD: i32 = -1000;

const GroundReason = struct {
    pub const near_plane: u8 = 1 << 0;
    pub const backface: u8 = 1 << 1;
    pub const cross_near: u8 = 1 << 2;
};

const GroundDebugState = struct {
    last_mask: u8 = 0,
    frames_since_log: u32 = 0,
};

// HGDIOBJ: A "handle" (like an ID) to a Windows graphics object.
const HGDIOBJ = *anyopaque;

// SRCCOPY: A Windows constant that tells BitBlt to do a direct pixel copy.
const SRCCOPY = 0x00CC0020;

// ========== WINDOWS API DECLARATIONS ==========
// These are external function definitions for the Windows Graphics Device Interface (GDI).
// JS Analogy: This is like the low-level native browser code that the Canvas API calls.
extern "user32" fn GetDC(hWnd: windows.HWND) ?windows.HDC;
extern "user32" fn ReleaseDC(hWnd: windows.HWND, hDC: windows.HDC) i32;
extern "gdi32" fn CreateCompatibleDC(hdc: ?windows.HDC) ?windows.HDC;
extern "gdi32" fn SelectObject(hdc: windows.HDC, hgdiobj: HGDIOBJ) HGDIOBJ;
extern "gdi32" fn BitBlt(hdcDest: windows.HDC, nXDest: i32, nYDest: i32, nWidth: i32, nHeight: i32, hdcSrc: windows.HDC, nXSrc: i32, nYSrc: i32, dwRop: u32) bool;
extern "gdi32" fn DeleteDC(hdc: windows.HDC) bool;
extern "user32" fn SetWindowTextW(hWnd: windows.HWND, lpString: [*:0]const u16) bool;
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;

// ========== MODULE IMPORTS ==========
const Bitmap = @import("bitmap.zig").Bitmap;
const TileRenderer = @import("tile_renderer.zig");
const TileGrid = TileRenderer.TileGrid;
const TileBuffer = TileRenderer.TileBuffer;
const BinningStage = @import("binning_stage.zig");
const JobSystem = @import("job_system.zig").JobSystem;
const Job = @import("job_system.zig").Job;

/// The `Renderer` struct holds the entire state of the rendering engine.
/// It manages the window connection, the pixel buffer, the rendering pipeline, and application state.
pub const Renderer = struct {
    // Core rendering resources
    hwnd: windows.HWND, // Handle to the window we are drawing to.
    bitmap: Bitmap, // The main pixel buffer we draw into (our "canvas").
    hdc: ?windows.HDC, // The window's "device context" for drawing.
    hdc_mem: ?windows.HDC, // An in-memory device context for faster drawing operations.
    allocator: std.mem.Allocator,

    // Camera and object state
    rotation_angle: f32, // Camera yaw (left/right rotation).
    rotation_x: f32, // Camera pitch (up/down rotation).
    camera_position: math.Vec3, // Camera world position.
    camera_move_speed: f32, // Units per second for keyboard movement.
    mouse_sensitivity: f32, // Mouse look sensitivity factor.
    pending_mouse_delta: math.Vec2, // Accumulated mouse delta since last frame.
    mouse_initialized: bool, // Tracks whether the initial mouse position has been captured.
    mouse_last_pos: windows.POINT, // Last mouse position in client coordinates.

    // Light state
    light_orbit_x: f32,
    light_orbit_y: f32,
    light_distance: f32,

    // Input and timing state
    keys_pressed: u32, // Bitmask of currently pressed keys.
    camera_fov_deg: f32,
    frame_count: u32,
    last_time: i128,
    last_frame_time: i128,
    current_fps: u32,
    target_frame_time_ns: i128,
    pending_fov_delta: f32,

    // Tiled rendering resources
    tile_grid: ?TileGrid, // The grid layout of tiles on the screen.
    tile_buffers: ?[]TileBuffer, // A buffer for each tile to be rendered into in parallel.
    job_system: ?*JobSystem, // The multi-threaded job system.
    tile_jobs_buffer: ?[]TileRenderJob,
    job_buffer: ?[]Job,
    job_completion_buffer: ?[]bool,
    mesh_work_cache: MeshWorkCache = MeshWorkCache.init(),

    // Rendering options and data
    texture: ?*const texture.Texture, // The currently active texture.
    show_tile_borders: bool = false,
    show_wireframe: bool = false,
    show_light_orb: bool = true,
    cull_light_orb: bool = true,
    use_tiled_rendering: bool = true,

    ground_debug: GroundDebugState = .{},

    // Unused state from previous versions
    last_brightness_min: f32,
    last_brightness_max: f32,
    last_brightness_avg: f32,
    last_reported_fov_deg: f32,
    light_marker_visible_last_frame: bool,

    /// Initializes the renderer, creating all necessary resources.
    /// JS Analogy: The `constructor` for our main rendering class.
    pub fn init(hwnd: windows.HWND, width: i32, height: i32, allocator: std.mem.Allocator) !Renderer {
        const hdc = GetDC(hwnd) orelse return error.DCNotFound;
        const hdc_mem = CreateCompatibleDC(hdc) orelse {
            _ = ReleaseDC(hwnd, hdc);
            return error.MemoryDCCreationFailed;
        };

        const bitmap = try Bitmap.init(width, height);
        const current_time = std.time.nanoTimestamp();
        const tile_grid = try TileGrid.init(width, height, allocator);

        const tile_buffers = try allocator.alloc(TileBuffer, tile_grid.tiles.len);
        errdefer allocator.free(tile_buffers);
        for (tile_buffers, tile_grid.tiles) |*buf, *tile| {
            buf.* = try TileBuffer.init(tile.width, tile.height, allocator);
        }

        const tile_count = tile_grid.tiles.len;
        const tile_jobs_buffer = try allocator.alloc(TileRenderJob, tile_count);
        errdefer allocator.free(tile_jobs_buffer);
        const job_buffer = try allocator.alloc(Job, tile_count);
        errdefer allocator.free(job_buffer);
        const job_completion_buffer = try allocator.alloc(bool, tile_count);
        errdefer allocator.free(job_completion_buffer);
        @memset(job_completion_buffer, false);

        const job_system = try JobSystem.init(allocator);

        return Renderer{
            .hwnd = hwnd,
            .bitmap = bitmap,
            .hdc = hdc,
            .hdc_mem = hdc_mem,
            .allocator = allocator,
            .rotation_angle = 0,
            .rotation_x = 0,
            .camera_position = math.Vec3.new(0.0, 1.5, -5.0),
            .camera_move_speed = 6.0,
            .mouse_sensitivity = 0.0025,
            .pending_mouse_delta = math.Vec2.new(0.0, 0.0),
            .mouse_initialized = false,
            .mouse_last_pos = .{ .x = 0, .y = 0 },
            .light_orbit_x = 0.0,
            .light_orbit_y = 0.0,
            .light_distance = config.LIGHT_DISTANCE_INITIAL,
            .camera_fov_deg = config.CAMERA_FOV_INITIAL,
            .keys_pressed = 0,
            .frame_count = 0,
            .last_time = current_time,
            .last_frame_time = current_time,
            .current_fps = 0,
            .target_frame_time_ns = config.targetFrameTimeNs(),
            .last_brightness_min = 0,
            .last_brightness_max = 0,
            .last_brightness_avg = 0,
            .last_reported_fov_deg = config.CAMERA_FOV_INITIAL,
            .light_marker_visible_last_frame = true,
            .pending_fov_delta = 0.0,
            .tile_grid = tile_grid,
            .tile_buffers = tile_buffers,
            .texture = null,
            .use_tiled_rendering = true,
            .job_system = job_system,
            .tile_jobs_buffer = tile_jobs_buffer,
            .job_buffer = job_buffer,
            .job_completion_buffer = job_completion_buffer,
        };
    }

    /// Cleans up all renderer resources in the reverse order of creation.
    pub fn deinit(self: *Renderer) void {
        self.mesh_work_cache.deinit(self.allocator);
        if (self.job_system) |js| js.deinit();
        if (self.job_buffer) |jobs| self.allocator.free(jobs);
        if (self.tile_jobs_buffer) |tile_jobs| self.allocator.free(tile_jobs);
        if (self.job_completion_buffer) |completion| self.allocator.free(completion);
        if (self.tile_buffers) |buffers| {
            for (buffers) |*buf| buf.deinit();
            self.allocator.free(buffers);
        }
        if (self.tile_grid) |*grid| grid.deinit();
        self.bitmap.deinit();
        if (self.hdc_mem) |hdc_mem| _ = DeleteDC(hdc_mem);
        if (self.hdc) |hdc| _ = ReleaseDC(self.hwnd, hdc);
    }

    // ========== TILE RENDER JOB ==========

    const ProjectionParams = struct {
        center_x: f32,
        center_y: f32,
        x_scale: f32,
        y_scale: f32,
        near_plane: f32,
    };

    /// This struct is the "context object" for a single tile rendering job.
    /// It packages up all the data a worker thread needs to render one tile.
    /// JS Analogy: The data object you would `postMessage` to a Web Worker.
    const TileRenderJob = struct {
        tile: *const TileRenderer.Tile,
        tile_buffer: *TileBuffer,
        tri_list: *const BinningStage.TileTriangleList,
        packets: []const TrianglePacket,
        draw_wireframe: bool,
        texture: ?*const texture.Texture,
        projection: ProjectionParams,

        const max_clipped_vertices: usize = 5;
        const wire_color: u32 = 0xFFFFFFFF;

        const ClipVertex = struct {
            position: math.Vec3,
            uv: math.Vec2,
        };

        fn interpolateClipVertex(a: ClipVertex, b: ClipVertex, near_plane: f32) ClipVertex {
            const denom = b.position.z - a.position.z;
            const t_raw = if (@abs(denom) < 1e-6) 0.0 else (near_plane - a.position.z) / denom;
            const t = std.math.clamp(t_raw, 0.0, 1.0);
            const direction = math.Vec3.sub(b.position, a.position);
            const position = math.Vec3.add(a.position, math.Vec3.scale(direction, t));
            const uv_delta = math.Vec2.sub(b.uv, a.uv);
            const uv = math.Vec2.add(a.uv, math.Vec2.scale(uv_delta, t));
            return ClipVertex{ .position = position, .uv = uv };
        }

        fn clipPolygonToNearPlane(vertices: []ClipVertex, near_plane: f32, output: *[max_clipped_vertices]ClipVertex) usize {
            if (vertices.len == 0) return 0;

            var out_count: usize = 0;
            var prev = vertices[vertices.len - 1];
            var prev_inside = prev.position.z >= near_plane - NEAR_EPSILON;

            for (vertices) |curr| {
                const curr_inside = curr.position.z >= near_plane - NEAR_EPSILON;
                if (curr_inside) {
                    if (!prev_inside and out_count < max_clipped_vertices) {
                        output[out_count] = interpolateClipVertex(prev, curr, near_plane);
                        out_count += 1;
                    }
                    if (out_count < max_clipped_vertices) {
                        output[out_count] = curr;
                        out_count += 1;
                    }
                } else if (prev_inside and out_count < max_clipped_vertices) {
                    output[out_count] = interpolateClipVertex(prev, curr, near_plane);
                    out_count += 1;
                }

                prev = curr;
                prev_inside = curr_inside;
            }

            return out_count;
        }

        fn projectToScreen(self: *const TileRenderJob, position: math.Vec3) [2]i32 {
            const clamped_z = if (position.z < self.projection.near_plane + NEAR_EPSILON)
                self.projection.near_plane + NEAR_EPSILON
            else
                position.z;
            const inv_z = 1.0 / clamped_z;
            const ndc_x = position.x * inv_z * self.projection.x_scale;
            const ndc_y = position.y * inv_z * self.projection.y_scale;
            const screen_x = ndc_x * self.projection.center_x + self.projection.center_x;
            const screen_y = -ndc_y * self.projection.center_y + self.projection.center_y;
            return .{
                @as(i32, @intFromFloat(screen_x)),
                @as(i32, @intFromFloat(screen_y)),
            };
        }

        fn isDegenerate(p0: [2]i32, p1: [2]i32, p2: [2]i32) bool {
            const ax = @as(i64, p1[0]) - @as(i64, p0[0]);
            const ay = @as(i64, p1[1]) - @as(i64, p0[1]);
            const bx = @as(i64, p2[0]) - @as(i64, p0[0]);
            const by = @as(i64, p2[1]) - @as(i64, p0[1]);
            const cross = ax * by - ay * bx;
            return cross == 0;
        }

        fn rasterizeFan(job: *TileRenderJob, vertices: []ClipVertex, base_color: u32, intensity: f32) void {
            if (vertices.len < 3) return;

            var screen_pts: [max_clipped_vertices][2]i32 = undefined;
            var depths: [max_clipped_vertices]f32 = undefined;
            for (vertices, 0..) |v, idx| {
                screen_pts[idx] = job.projectToScreen(v.position);
                depths[idx] = v.position.z;
            }

            var tri_idx: usize = 1;
            while (tri_idx < vertices.len - 1) : (tri_idx += 1) {
                const p0 = screen_pts[0];
                const p1 = screen_pts[tri_idx];
                const p2 = screen_pts[tri_idx + 1];
                if (isDegenerate(p0, p1, p2)) continue;

                const shading = TileRenderer.ShadingParams{
                    .base_color = base_color,
                    .texture = job.texture,
                    .uv0 = vertices[0].uv,
                    .uv1 = vertices[tri_idx].uv,
                    .uv2 = vertices[tri_idx + 1].uv,
                    .intensity = intensity,
                };
                const depth_values = [3]f32{
                    depths[0],
                    depths[tri_idx],
                    depths[tri_idx + 1],
                };
                TileRenderer.rasterizeTriangleToTile(job.tile, job.tile_buffer, p0, p1, p2, depth_values, shading);
            }
        }

        fn renderTileJob(ctx: *anyopaque) void {
            const job: *TileRenderJob = @ptrCast(@alignCast(ctx));
            const near_plane = job.projection.near_plane;

            for (job.tri_list.triangles.items) |tri_idx| {
                if (tri_idx >= job.packets.len) continue;
                const packet = job.packets[tri_idx];
                if (packet.flags.cull_fill) continue;

                const camera_positions = packet.camera;
                const front0 = camera_positions[0].z >= near_plane - NEAR_EPSILON;
                const front1 = camera_positions[1].z >= near_plane - NEAR_EPSILON;
                const front2 = camera_positions[2].z >= near_plane - NEAR_EPSILON;
                if (!front0 and !front1 and !front2) continue;

                var clip_input = [_]ClipVertex{
                    ClipVertex{ .position = camera_positions[0], .uv = packet.uv[0] },
                    ClipVertex{ .position = camera_positions[1], .uv = packet.uv[1] },
                    ClipVertex{ .position = camera_positions[2], .uv = packet.uv[2] },
                };

                var clipped: [max_clipped_vertices]ClipVertex = undefined;
                const clipped_count = clipPolygonToNearPlane(clip_input[0..], near_plane, &clipped);
                if (clipped_count < 3) continue;

                rasterizeFan(job, clipped[0..clipped_count], packet.base_color, packet.intensity);

                if (job.draw_wireframe and !packet.flags.cull_wire) {
                    const p0 = job.projectToScreen(camera_positions[0]);
                    const p1 = job.projectToScreen(camera_positions[1]);
                    const p2 = job.projectToScreen(camera_positions[2]);
                    TileRenderer.drawLineToTile(job.tile, job.tile_buffer, p0, p1, wire_color);
                    TileRenderer.drawLineToTile(job.tile, job.tile_buffer, p1, p2, wire_color);
                    TileRenderer.drawLineToTile(job.tile, job.tile_buffer, p2, p0, wire_color);
                }
            }
        }
    };

    const VertexState = enum(u8) {
        uninitialized,
        working,
        ready,
    };

    fn resetVertexStates(states: []std.atomic.Value(VertexState)) void {
        for (states) |*state| {
            state.store(.uninitialized, .release);
        }
    }

    fn ensureVertex(
        idx: usize,
        states: []std.atomic.Value(VertexState),
        mesh_vertices: []const math.Vec3,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        vertex_cache: []math.Vec3,
        projected_slice: [][2]i32,
        projection_params: ProjectionParams,
    ) void {
        while (true) {
            const state = states[idx].load(.acquire);
            switch (state) {
                .ready => return,
                .uninitialized => {
                    if (states[idx].cmpxchgStrong(.uninitialized, .working, .acq_rel, .acquire) == null) {
                        const vertex = mesh_vertices[idx];
                        const relative = math.Vec3.sub(vertex, camera_position);
                        const camera_space = math.Vec3.new(
                            math.Vec3.dot(relative, basis_right),
                            math.Vec3.dot(relative, basis_up),
                            math.Vec3.dot(relative, basis_forward),
                        );
                        vertex_cache[idx] = camera_space;

                        if (camera_space.z <= NEAR_CLIP) {
                            projected_slice[idx] = .{ INVALID_PROJECTED_COORD, INVALID_PROJECTED_COORD };
                        } else {
                            const inv_z = 1.0 / camera_space.z;
                            const ndc_x = camera_space.x * inv_z * projection_params.x_scale;
                            const ndc_y = camera_space.y * inv_z * projection_params.y_scale;
                            const screen_x = ndc_x * projection_params.center_x + projection_params.center_x;
                            const screen_y = -ndc_y * projection_params.center_y + projection_params.center_y;
                            projected_slice[idx][0] = @as(i32, @intFromFloat(screen_x));
                            projected_slice[idx][1] = @as(i32, @intFromFloat(screen_y));
                        }

                        states[idx].store(.ready, .release);
                        return;
                    }
                },
                .working => std.atomic.spinLoopHint(),
            }
        }
    }

    fn transformNormalFromBasis(basis_right: math.Vec3, basis_up: math.Vec3, basis_forward: math.Vec3, normal: math.Vec3) math.Vec3 {
        const transformed = math.Vec3.new(
            math.Vec3.dot(normal, basis_right),
            math.Vec3.dot(normal, basis_up),
            math.Vec3.dot(normal, basis_forward),
        );
        const len = math.Vec3.length(transformed);
        if (len < 1e-6) return math.Vec3.new(0.0, 0.0, 1.0);
        return math.Vec3.scale(transformed, 1.0 / len);
    }

    fn emitTriangleToWork(
        writer: *MeshWorkWriter,
        mesh: *const Mesh,
        tri_idx: usize,
        tri: MeshModule.Triangle,
        states: []std.atomic.Value(VertexState),
        mesh_vertices: []const math.Vec3,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        vertex_cache: []math.Vec3,
        projected_slice: [][2]i32,
        projection_params: ProjectionParams,
        light_dir: math.Vec3,
        output_cursor: ?*usize,
    ) !void {
        ensureVertex(tri.v0, states, mesh_vertices, camera_position, basis_right, basis_up, basis_forward, vertex_cache, projected_slice, projection_params);
        ensureVertex(tri.v1, states, mesh_vertices, camera_position, basis_right, basis_up, basis_forward, vertex_cache, projected_slice, projection_params);
        ensureVertex(tri.v2, states, mesh_vertices, camera_position, basis_right, basis_up, basis_forward, vertex_cache, projected_slice, projection_params);

        const p0_cam = vertex_cache[tri.v0];
        const p1_cam = vertex_cache[tri.v1];
        const p2_cam = vertex_cache[tri.v2];

        const front0 = p0_cam.z >= projection_params.near_plane - NEAR_EPSILON;
        const front1 = p1_cam.z >= projection_params.near_plane - NEAR_EPSILON;
        const front2 = p2_cam.z >= projection_params.near_plane - NEAR_EPSILON;
        if (!front0 and !front1 and !front2) return;

        const crosses_near = (front0 or front1 or front2) and !(front0 and front1 and front2);

        var screen0 = projected_slice[tri.v0];
        var screen1 = projected_slice[tri.v1];
        var screen2 = projected_slice[tri.v2];
        if (screen0[0] == INVALID_PROJECTED_COORD or screen0[1] == INVALID_PROJECTED_COORD) screen0 = projectCameraPosition(p0_cam, projection_params);
        if (screen1[0] == INVALID_PROJECTED_COORD or screen1[1] == INVALID_PROJECTED_COORD) screen1 = projectCameraPosition(p1_cam, projection_params);
        if (screen2[0] == INVALID_PROJECTED_COORD or screen2[1] == INVALID_PROJECTED_COORD) screen2 = projectCameraPosition(p2_cam, projection_params);

        const uv = [3]math.Vec2{
            if (tri.v0 < mesh.tex_coords.len) mesh.tex_coords[tri.v0] else math.Vec2.new(0.0, 0.0),
            if (tri.v1 < mesh.tex_coords.len) mesh.tex_coords[tri.v1] else math.Vec2.new(0.0, 0.0),
            if (tri.v2 < mesh.tex_coords.len) mesh.tex_coords[tri.v2] else math.Vec2.new(0.0, 0.0),
        };

        var normal_cam = math.Vec3.new(0.0, 0.0, 1.0);
        if (tri_idx < mesh.normals.len) {
            normal_cam = transformNormalFromBasis(basis_right, basis_up, basis_forward, mesh.normals[tri_idx]);
        } else {
            const edge0 = math.Vec3.sub(p1_cam, p0_cam);
            const edge1 = math.Vec3.sub(p2_cam, p0_cam);
            const fallback = math.Vec3.cross(edge0, edge1);
            const len = math.Vec3.length(fallback);
            if (len > 1e-6) normal_cam = math.Vec3.scale(fallback, 1.0 / len);
        }

        var backface = false;
        if (!crosses_near) {
            var centroid = math.Vec3.add(math.Vec3.add(p0_cam, p1_cam), p2_cam);
            centroid = math.Vec3.scale(centroid, 1.0 / 3.0);
            const view_dir = math.Vec3.scale(centroid, -1.0);
            const view_len = math.Vec3.length(view_dir);
            if (view_len > 1e-6) {
                const view_vector = math.Vec3.scale(view_dir, 1.0 / view_len);
                if (math.Vec3.dot(normal_cam, view_vector) < -1e-4) backface = true;
            }
        }
        if (backface) return;

        const brightness = math.Vec3.dot(normal_cam, light_dir);
        const intensity = lighting.computeIntensity(brightness);

        const flags = TriangleFlags{
            .cull_fill = tri.cull_flags.cull_fill,
            .cull_wire = tri.cull_flags.cull_wireframe,
            .backface = backface,
            .reserved = 0,
        };

        const write_index = blk: {
            if (output_cursor) |cursor| {
                const idx = cursor.*;
                cursor.* = idx + 1;
                break :blk idx;
            } else {
                break :blk try writer.reserveIndex();
            }
        };

        try writer.writeAtIndex(
            write_index,
            tri_idx,
            screen0,
            screen1,
            screen2,
            p0_cam,
            p1_cam,
            p2_cam,
            uv,
            tri.base_color,
            intensity,
            flags,
        );
    }

    fn projectCameraPosition(position: math.Vec3, projection: ProjectionParams) [2]i32 {
        const clamped_z = if (position.z < projection.near_plane + NEAR_EPSILON)
            projection.near_plane + NEAR_EPSILON
        else
            position.z;
        const inv_z = 1.0 / clamped_z;
        const ndc_x = position.x * inv_z * projection.x_scale;
        const ndc_y = position.y * inv_z * projection.y_scale;
        const screen_x = ndc_x * projection.center_x + projection.center_x;
        const screen_y = -ndc_y * projection.center_y + projection.center_y;
        return .{
            @as(i32, @intFromFloat(screen_x)),
            @as(i32, @intFromFloat(screen_y)),
        };
    }

    const MESHLETS_PER_CULL_JOB: usize = 32;

    const MeshletCullJob = struct {
        renderer: *Renderer,
        meshlets: []const Meshlet,
        visibility: []bool,
        start_index: usize,
        end_index: usize,
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,

        fn process(job: *MeshletCullJob) void {
            var idx = job.start_index;
            while (idx < job.end_index) : (idx += 1) {
                const meshlet_ptr = &job.meshlets[idx];
                const visible = job.renderer.meshletVisible(
                    meshlet_ptr,
                    job.camera_position,
                    job.basis_right,
                    job.basis_up,
                    job.basis_forward,
                    job.projection,
                );
                job.visibility[idx] = visible;
            }
        }

        fn run(ctx: *anyopaque) void {
            const job: *MeshletCullJob = @ptrCast(@alignCast(ctx));
            job.process();
        }
    };

    const MeshletTaskJob = struct {
        mesh: *const Mesh,
        meshlet: *const Meshlet,
        mesh_work: *MeshWork,
        projected: [][2]i32,
        transformed_vertices: []math.Vec3,
        vertex_ready: []std.atomic.Value(VertexState),
        camera_position: math.Vec3,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
        light_dir: math.Vec3,
        output_start: usize,

        fn process(job: *MeshletTaskJob) void {
            var writer = MeshWorkWriter.init(job.mesh_work);
            const mesh_vertices = job.mesh.vertices;
            var cursor = job.output_start;
            for (job.meshlet.triangle_indices) |tri_idx| {
                const tri = job.mesh.triangles[tri_idx];
                emitTriangleToWork(
                    &writer,
                    job.mesh,
                    tri_idx,
                    tri,
                    job.vertex_ready,
                    mesh_vertices,
                    job.camera_position,
                    job.basis_right,
                    job.basis_up,
                    job.basis_forward,
                    job.transformed_vertices,
                    job.projected,
                    job.projection,
                    job.light_dir,
                    &cursor,
                ) catch |err| {
                    std.log.err("Meshlet emit failed: {}", .{err});
                };
            }
        }

        fn run(ctx: *anyopaque) void {
            const job: *MeshletTaskJob = @ptrCast(@alignCast(ctx));
            job.process();
        }
    };

    const MeshWork = struct {
        triangles: []TrianglePacket,
        meshlet_packets: []MeshletPacket,
        triangle_len: usize,
        triangle_reserved: usize,
        meshlet_len: usize,
        meshlet_reserved: usize,
        next_triangle: std.atomic.Value(usize),

        fn init() MeshWork {
            return MeshWork{
                .triangles = &[_]TrianglePacket{},
                .meshlet_packets = &[_]MeshletPacket{},
                .triangle_len = 0,
                .triangle_reserved = 0,
                .meshlet_len = 0,
                .meshlet_reserved = 0,
                .next_triangle = std.atomic.Value(usize).init(0),
            };
        }

        fn deinit(self: *MeshWork, allocator: std.mem.Allocator) void {
            if (self.triangles.len != 0) allocator.free(self.triangles);
            if (self.meshlet_packets.len != 0) allocator.free(self.meshlet_packets);
            self.* = MeshWork.init();
        }

        fn clear(self: *MeshWork) void {
            self.triangle_len = 0;
            self.triangle_reserved = 0;
            self.meshlet_len = 0;
            self.meshlet_reserved = 0;
            self.next_triangle.store(0, .release);
        }

        fn ensureTriangleCapacity(self: *MeshWork, allocator: std.mem.Allocator, capacity: usize) !void {
            if (capacity == 0) return;

            if (self.triangles.len < capacity) {
                if (self.triangles.len == 0) {
                    self.triangles = try allocator.alloc(TrianglePacket, capacity);
                } else {
                    self.triangles = try allocator.realloc(self.triangles, capacity);
                }
            }
        }

        fn ensureMeshletCapacity(self: *MeshWork, allocator: std.mem.Allocator, capacity: usize) !void {
            if (capacity == 0) return;

            if (self.meshlet_packets.len < capacity) {
                if (self.meshlet_packets.len == 0) {
                    self.meshlet_packets = try allocator.alloc(MeshletPacket, capacity);
                } else {
                    self.meshlet_packets = try allocator.realloc(self.meshlet_packets, capacity);
                }
            }
        }

        fn beginWrite(self: *MeshWork, allocator: std.mem.Allocator, meshlet_capacity: usize, triangle_capacity: usize) !void {
            self.clear();
            if (meshlet_capacity == 0 and triangle_capacity == 0) return;
            if (meshlet_capacity != 0) try self.ensureMeshletCapacity(allocator, meshlet_capacity);
            if (triangle_capacity != 0) try self.ensureTriangleCapacity(allocator, triangle_capacity);
            self.meshlet_reserved = meshlet_capacity;
            self.triangle_reserved = triangle_capacity;
            self.triangle_len = 0;
            self.meshlet_len = meshlet_capacity;
            self.next_triangle.store(0, .release);
        }

        fn finalize(self: *MeshWork, meshlet_count: usize) void {
            const produced = self.next_triangle.load(.acquire);
            const limit = if (self.triangle_reserved == 0) self.triangles.len else self.triangle_reserved;
            self.triangle_len = if (produced > limit) limit else produced;
            self.meshlet_len = meshlet_count;
        }

        fn triangleSlice(self: *const MeshWork) []const TrianglePacket {
            return self.triangles[0..self.triangle_len];
        }

        fn meshletSlice(self: *const MeshWork) []const MeshletPacket {
            return self.meshlet_packets[0..self.meshlet_len];
        }
    };

    const MeshWorkWriter = struct {
        work: *MeshWork,

        fn init(work: *MeshWork) MeshWorkWriter {
            return MeshWorkWriter{ .work = work };
        }

        fn reserveIndex(self: *MeshWorkWriter) !usize {
            const idx = self.work.next_triangle.fetchAdd(1, .acq_rel);
            if (idx >= self.work.triangles.len) {
                return error.MeshWorkOverflow;
            }
            return idx;
        }

        fn writeAtIndex(
            self: *MeshWorkWriter,
            idx: usize,
            tri_idx: usize,
            screen0: [2]i32,
            screen1: [2]i32,
            screen2: [2]i32,
            p0: math.Vec3,
            p1: math.Vec3,
            p2: math.Vec3,
            uv: [3]math.Vec2,
            base_color: u32,
            intensity: f32,
            flags: TriangleFlags,
        ) !void {
            if (idx >= self.work.triangles.len) {
                return error.MeshWorkOverflow;
            }
            self.work.triangles[idx] = TrianglePacket{
                .screen = .{ screen0, screen1, screen2 },
                .camera = .{ p0, p1, p2 },
                .uv = uv,
                .base_color = base_color,
                .intensity = intensity,
                .flags = flags,
                .triangle_id = tri_idx,
            };
        }
    };

    const MeshWorkCache = struct {
        projected: [][2]i32,
        transformed_vertices: []math.Vec3,
        vertex_ready: []std.atomic.Value(VertexState),
        work: MeshWork,
        mesh: ?*const Mesh,
        camera_position: math.Vec3,
        right: math.Vec3,
        up: math.Vec3,
        forward: math.Vec3,
        light_dir: math.Vec3,
        projection: ProjectionParams,
        valid: bool,

        fn init() MeshWorkCache {
            return MeshWorkCache{
                .projected = &[_][2]i32{},
                .transformed_vertices = &[_]math.Vec3{},
                .vertex_ready = &[_]std.atomic.Value(VertexState){},
                .work = MeshWork.init(),
                .mesh = null,
                .camera_position = math.Vec3.new(0.0, 0.0, 0.0),
                .right = math.Vec3.new(0.0, 0.0, 0.0),
                .up = math.Vec3.new(0.0, 0.0, 0.0),
                .forward = math.Vec3.new(0.0, 0.0, 0.0),
                .light_dir = math.Vec3.new(0.0, 0.0, 0.0),
                .projection = ProjectionParams{
                    .center_x = 0.0,
                    .center_y = 0.0,
                    .x_scale = 0.0,
                    .y_scale = 0.0,
                    .near_plane = NEAR_CLIP,
                },
                .valid = false,
            };
        }

        fn deinit(self: *MeshWorkCache, allocator: std.mem.Allocator) void {
            self.work.deinit(allocator);
            if (self.projected.len != 0) allocator.free(self.projected);
            if (self.transformed_vertices.len != 0) allocator.free(self.transformed_vertices);
            if (self.vertex_ready.len != 0) allocator.free(self.vertex_ready);
            self.projected = &[_][2]i32{};
            self.transformed_vertices = &[_]math.Vec3{};
            self.vertex_ready = &[_]std.atomic.Value(VertexState){};
            self.mesh = null;
            self.light_dir = math.Vec3.new(0.0, 0.0, 0.0);
            self.valid = false;
        }

        fn ensureCapacity(self: *MeshWorkCache, allocator: std.mem.Allocator, vertex_count: usize) !void {
            if (self.projected.len != vertex_count) {
                if (self.projected.len != 0) allocator.free(self.projected);
                self.projected = if (vertex_count == 0)
                    &[_][2]i32{}
                else
                    try allocator.alloc([2]i32, vertex_count);
                self.valid = false;
            }
            if (self.transformed_vertices.len != vertex_count) {
                if (self.transformed_vertices.len != 0) allocator.free(self.transformed_vertices);
                self.transformed_vertices = if (vertex_count == 0)
                    &[_]math.Vec3{}
                else
                    try allocator.alloc(math.Vec3, vertex_count);
                self.valid = false;
            }
            if (self.vertex_ready.len != vertex_count) {
                if (self.vertex_ready.len != 0) allocator.free(self.vertex_ready);
                self.vertex_ready = if (vertex_count == 0)
                    &[_]std.atomic.Value(VertexState){}
                else blk: {
                    const states = try allocator.alloc(std.atomic.Value(VertexState), vertex_count);
                    for (states) |*state| state.* = std.atomic.Value(VertexState).init(.uninitialized);
                    break :blk states;
                };
                self.valid = false;
            }
        }

        fn approxEqVec3(a: math.Vec3, b: math.Vec3, epsilon: f32) bool {
            return @abs(a.x - b.x) <= epsilon and @abs(a.y - b.y) <= epsilon and @abs(a.z - b.z) <= epsilon;
        }

        fn approxEqProjection(a: ProjectionParams, b: ProjectionParams, epsilon: f32) bool {
            return @abs(a.center_x - b.center_x) <= epsilon and
                @abs(a.center_y - b.center_y) <= epsilon and
                @abs(a.x_scale - b.x_scale) <= epsilon and
                @abs(a.y_scale - b.y_scale) <= epsilon and
                @abs(a.near_plane - b.near_plane) <= epsilon;
        }

        fn needsUpdate(
            self: *const MeshWorkCache,
            mesh: *const Mesh,
            camera_position: math.Vec3,
            right: math.Vec3,
            up: math.Vec3,
            forward: math.Vec3,
            light_dir: math.Vec3,
            projection: ProjectionParams,
        ) bool {
            const epsilon: f32 = 1e-5;
            if (!self.valid) return true;
            if (self.mesh != mesh) return true;
            if (!approxEqVec3(self.camera_position, camera_position, epsilon)) return true;
            if (!approxEqVec3(self.right, right, epsilon)) return true;
            if (!approxEqVec3(self.up, up, epsilon)) return true;
            if (!approxEqVec3(self.forward, forward, epsilon)) return true;
            if (!approxEqVec3(self.light_dir, light_dir, epsilon)) return true;
            if (!approxEqProjection(self.projection, projection, epsilon)) return true;
            return false;
        }

        fn invalidate(self: *MeshWorkCache) void {
            self.valid = false;
        }

        fn beginUpdate(self: *MeshWorkCache) void {
            self.valid = false;
            self.work.clear();
        }

        fn finalizeUpdate(
            self: *MeshWorkCache,
            mesh: *const Mesh,
            camera_position: math.Vec3,
            right: math.Vec3,
            up: math.Vec3,
            forward: math.Vec3,
            light_dir: math.Vec3,
            projection: ProjectionParams,
        ) void {
            self.mesh = mesh;
            self.camera_position = camera_position;
            self.right = right;
            self.up = up;
            self.forward = forward;
            self.light_dir = light_dir;
            self.projection = projection;
            self.valid = true;
        }
    };

    pub fn handleKeyInput(self: *Renderer, key: u32, is_down: bool) void {
        _ = input.updateKeyState(&self.keys_pressed, key, is_down);
    }

    pub fn handleMouseMove(self: *Renderer, x: i32, y: i32) void {
        const current = windows.POINT{ .x = x, .y = y };
        if (!self.mouse_initialized) {
            self.mouse_last_pos = current;
            self.mouse_initialized = true;
            return;
        }

        const dx = @as(f32, @floatFromInt(current.x - self.mouse_last_pos.x));
        const dy = @as(f32, @floatFromInt(current.y - self.mouse_last_pos.y));
        self.pending_mouse_delta = math.Vec2.new(self.pending_mouse_delta.x + dx, self.pending_mouse_delta.y + dy);
        self.mouse_last_pos = current;
    }

    pub fn setCameraPosition(self: *Renderer, position: math.Vec3) void {
        self.camera_position = position;
    }

    pub fn setCameraOrientation(self: *Renderer, pitch: f32, yaw: f32) void {
        self.rotation_x = std.math.clamp(pitch, -1.5, 1.5);
        self.rotation_angle = yaw;
    }

    fn consumeMouseDelta(self: *Renderer) math.Vec2 {
        const delta = self.pending_mouse_delta;
        self.pending_mouse_delta = math.Vec2.new(0.0, 0.0);
        return delta;
    }

    pub fn shouldRenderFrame(self: *Renderer) bool {
        _ = self;
        return true;
    }

    pub fn handleCharInput(self: *Renderer, char_code: u32) void {
        switch (char_code) {
            'q', 'Q' => self.pending_fov_delta -= config.CAMERA_FOV_STEP,
            'e', 'E' => self.pending_fov_delta += config.CAMERA_FOV_STEP,
            else => {},
        }
    }

    pub fn setTexture(self: *Renderer, tex: *const texture.Texture) void {
        self.texture = tex;
    }

    /// The main render loop function for a single frame.
    pub fn render3DMesh(self: *Renderer, mesh: *const Mesh) !void {
        try self.render3DMeshWithPump(mesh, null);
    }

    /// The main render loop function, with an added callback to process OS messages.
    /// This is the heart of the engine, executing the full 3D pipeline each frame.
    pub fn render3DMeshWithPump(self: *Renderer, mesh: *const Mesh, pump: ?*const fn (*Renderer) bool) !void {
        @memset(self.bitmap.pixels, 0xFF000000);

        const delta_seconds = self.beginFrame();

        const rotation_speed = 2.0;
        if ((self.keys_pressed & input.KeyBits.left) != 0) self.rotation_angle -= rotation_speed * delta_seconds;
        if ((self.keys_pressed & input.KeyBits.right) != 0) self.rotation_angle += rotation_speed * delta_seconds;
        if ((self.keys_pressed & input.KeyBits.up) != 0) self.rotation_x -= rotation_speed * delta_seconds;
        if ((self.keys_pressed & input.KeyBits.down) != 0) self.rotation_x += rotation_speed * delta_seconds;

        const mouse_delta = self.consumeMouseDelta();
        self.rotation_angle += mouse_delta.x * self.mouse_sensitivity;
        self.rotation_x -= mouse_delta.y * self.mouse_sensitivity;
        self.rotation_x = std.math.clamp(self.rotation_x, -1.5, 1.5);

        const fov_delta = self.consumePendingFovDelta();
        if (fov_delta != 0.0) self.adjustCameraFov(fov_delta);

        const auto_orbit_speed = 0.5;
        self.light_orbit_x += auto_orbit_speed * delta_seconds;
        const light_orbit = math.Mat4.multiply(math.Mat4.rotateY(self.light_orbit_y), math.Mat4.rotateX(self.light_orbit_x));
        const light_pos_world = light_orbit.mulVec3(math.Vec3.new(0.0, 0.0, self.light_distance));
        const light_dir_world = math.Vec3.normalize(light_pos_world);

        const yaw = self.rotation_angle;
        const pitch = self.rotation_x;
        const cos_pitch = @cos(pitch);
        const sin_pitch = @sin(pitch);
        const cos_yaw = @cos(yaw);
        const sin_yaw = @sin(yaw);

        var forward = math.Vec3.new(sin_yaw * cos_pitch, sin_pitch, cos_yaw * cos_pitch);
        forward = math.Vec3.normalize(forward);

        const world_up = math.Vec3.new(0.0, 1.0, 0.0);
        var right = math.Vec3.cross(world_up, forward);
        const right_len = math.Vec3.length(right);
        if (right_len < 0.0001) {
            right = math.Vec3.new(1.0, 0.0, 0.0);
        } else {
            right = math.Vec3.scale(right, 1.0 / right_len);
        }

        var up = math.Vec3.cross(forward, right);
        up = math.Vec3.normalize(up);

        var forward_flat = math.Vec3.new(forward.x, 0.0, forward.z);
        const forward_flat_len = math.Vec3.length(forward_flat);
        if (forward_flat_len > 0.0001) {
            forward_flat = math.Vec3.scale(forward_flat, 1.0 / forward_flat_len);
        } else {
            forward_flat = math.Vec3.new(0.0, 0.0, 0.0);
        }

        var right_flat = math.Vec3.new(right.x, 0.0, right.z);
        const right_flat_len = math.Vec3.length(right_flat);
        if (right_flat_len > 0.0001) {
            right_flat = math.Vec3.scale(right_flat, 1.0 / right_flat_len);
        } else {
            right_flat = math.Vec3.new(0.0, 0.0, 0.0);
        }

        var movement_dir = math.Vec3.new(0.0, 0.0, 0.0);
        if ((self.keys_pressed & input.KeyBits.w) != 0) movement_dir = math.Vec3.add(movement_dir, forward_flat);
        if ((self.keys_pressed & input.KeyBits.s) != 0) movement_dir = math.Vec3.sub(movement_dir, forward_flat);
        if ((self.keys_pressed & input.KeyBits.d) != 0) movement_dir = math.Vec3.add(movement_dir, right_flat);
        if ((self.keys_pressed & input.KeyBits.a) != 0) movement_dir = math.Vec3.sub(movement_dir, right_flat);
        if ((self.keys_pressed & input.KeyBits.space) != 0) movement_dir = math.Vec3.add(movement_dir, world_up);
        if ((self.keys_pressed & input.KeyBits.ctrl) != 0) movement_dir = math.Vec3.sub(movement_dir, world_up);

        const movement_mag = math.Vec3.length(movement_dir);
        if (movement_mag > 0.0001) {
            const normalized_move = math.Vec3.scale(movement_dir, 1.0 / movement_mag);
            const move_step = math.Vec3.scale(normalized_move, self.camera_move_speed * delta_seconds);
            self.camera_position = math.Vec3.add(self.camera_position, move_step);
        }

        var view_rotation = math.Mat4.identity();
        view_rotation.data[0] = right.x;
        view_rotation.data[1] = right.y;
        view_rotation.data[2] = right.z;
        view_rotation.data[4] = up.x;
        view_rotation.data[5] = up.y;
        view_rotation.data[6] = up.z;
        view_rotation.data[8] = forward.x;
        view_rotation.data[9] = forward.y;
        view_rotation.data[10] = forward.z;

        const light_relative = math.Vec3.sub(light_pos_world, self.camera_position);
        const light_camera = math.Vec3.new(
            math.Vec3.dot(light_relative, right),
            math.Vec3.dot(light_relative, up),
            math.Vec3.dot(light_relative, forward),
        );

        const light_dir = math.Vec3.normalize(math.Vec3.new(
            math.Vec3.dot(light_dir_world, right),
            math.Vec3.dot(light_dir_world, up),
            math.Vec3.dot(light_dir_world, forward),
        ));

        const width_f = @as(f32, @floatFromInt(self.bitmap.width));
        const height_f = @as(f32, @floatFromInt(self.bitmap.height));
        const aspect_ratio = if (height_f > 0.0) width_f / height_f else 1.0;
        const fov_rad = self.camera_fov_deg * (std.math.pi / 180.0);
        const half_fov = fov_rad * 0.5;
        const tan_half_fov = std.math.tan(half_fov);
        const y_scale = if (tan_half_fov > 0.0) 1.0 / tan_half_fov else 1.0;
        const x_scale = y_scale / aspect_ratio;
        const center_x = width_f * 0.5;
        const center_y = height_f * 0.5;

        const projection = ProjectionParams{
            .center_x = center_x,
            .center_y = center_y,
            .x_scale = x_scale,
            .y_scale = y_scale,
            .near_plane = NEAR_CLIP,
        };

        var cache = &self.mesh_work_cache;
        try cache.ensureCapacity(self.allocator, mesh.vertices.len);

        const needs_update = cache.needsUpdate(
            mesh,
            self.camera_position,
            right,
            up,
            forward,
            light_dir,
            projection,
        );
        if (needs_update) {
            cache.beginUpdate();
            try self.generateMeshWork(
                mesh,
                cache.projected,
                cache.transformed_vertices,
                cache.vertex_ready,
                right,
                up,
                forward,
                projection,
                &cache.work,
                light_dir,
            );
            cache.finalizeUpdate(mesh, self.camera_position, right, up, forward, light_dir, projection);
        }

        if (cache.transformed_vertices.len == mesh.vertices.len) {
            self.debugGroundPlane(mesh, cache.transformed_vertices, view_rotation);
        }

        const mesh_work = &cache.work;

        if (self.use_tiled_rendering and self.tile_grid != null and self.tile_buffers != null) {
            try self.renderTiled(mesh, view_rotation, light_dir, pump, projection, mesh_work);
        } else {
            try self.renderDirect(mesh, view_rotation, light_dir, projection, mesh_work);
        }

        if (self.show_light_orb) {
            const light_camera_z = light_camera.z;
            if (light_camera_z > NEAR_CLIP) {
                self.drawLightMarker(light_camera, light_camera_z, center_x, center_y, x_scale, y_scale);
            }
        }

        self.drawBitmap();

        self.frame_count += 1;
        const current_time = std.time.nanoTimestamp();
        self.finalizeFrame(current_time);
    }

    fn beginFrame(self: *Renderer) f32 {
        const now = std.time.nanoTimestamp();
        var delta_ns = now - self.last_frame_time;
        if (delta_ns < 0) delta_ns = 0;
        self.last_frame_time = now;

        const delta_ns_f = @as(f64, @floatFromInt(delta_ns));
        var delta_seconds = @as(f32, @floatCast(delta_ns_f / 1_000_000_000.0));
        if (delta_seconds > 0.1) delta_seconds = 0.1;
        if (delta_seconds <= 0.0) delta_seconds = 1.0 / 120.0;
        return delta_seconds;
    }

    fn consumePendingFovDelta(self: *Renderer) f32 {
        const delta = self.pending_fov_delta;
        self.pending_fov_delta = 0.0;
        return delta;
    }

    fn adjustCameraFov(self: *Renderer, delta: f32) void {
        const new_fov = std.math.clamp(self.camera_fov_deg + delta, config.CAMERA_FOV_MIN, config.CAMERA_FOV_MAX);
        if (!std.math.approxEqAbs(f32, new_fov, self.camera_fov_deg, 0.0001)) {
            self.camera_fov_deg = new_fov;
            self.last_reported_fov_deg = new_fov;
        }
    }

    fn finalizeFrame(self: *Renderer, current_time: i128) void {
        const elapsed_ns = current_time - self.last_time;
        if (elapsed_ns < 1_000_000_000 or self.frame_count == 0) return;

        const elapsed_us = @divTrunc(elapsed_ns, 1000);
        if (elapsed_us == 0) return;
        self.current_fps = @as(u32, @intCast((self.frame_count * 1_000_000) / @as(u32, @intCast(elapsed_us))));

        const frame_count_f = @as(f32, @floatFromInt(self.frame_count));
        const elapsed_ms = @as(f32, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        const avg_frame_time_ms = if (frame_count_f > 0.0) elapsed_ms / frame_count_f else 0.0;

        self.frame_count = 0;
        self.last_time = current_time;
        self.updateWindowTitle(avg_frame_time_ms);
    }

    fn updateWindowTitle(self: *Renderer, avg_frame_time_ms: f32) void {
        var title_buffer: [256]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buffer, "{s} | FPS: {} | Frame: {d:.2}ms", .{
            config.WINDOW_TITLE,
            self.current_fps,
            avg_frame_time_ms,
        }) catch config.WINDOW_TITLE;

        var title_wide: [256:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch 0;
        title_wide[title_len] = 0;
        _ = SetWindowTextW(self.hwnd, &title_wide);
    }

    fn debugGroundPlane(self: *Renderer, mesh: *const Mesh, transformed_vertices: []math.Vec3, transform: math.Mat4) void {
        if (mesh.triangles.len < 2 or transformed_vertices.len < mesh.vertices.len) return;

        const tri_limit = @min(mesh.triangles.len, @as(usize, 2));
        var mask: u8 = 0;

        const TriDebug = struct {
            index: usize,
            mask: u8,
            z: [3]f32,
            dot: ?f32,
            front: [3]bool,
            crosses: bool,
        };

        var tri_debug: [2]TriDebug = undefined;
        var tri_debug_count: usize = 0;

        var tri_idx: usize = 0;
        while (tri_idx < tri_limit) : (tri_idx += 1) {
            const tri = mesh.triangles[tri_idx];
            const p0 = transformed_vertices[tri.v0];
            const p1 = transformed_vertices[tri.v1];
            const p2 = transformed_vertices[tri.v2];

            const front0 = p0.z >= NEAR_CLIP - NEAR_EPSILON;
            const front1 = p1.z >= NEAR_CLIP - NEAR_EPSILON;
            const front2 = p2.z >= NEAR_CLIP - NEAR_EPSILON;

            var tri_mask: u8 = 0;

            if (!front0 or !front1 or !front2) {
                tri_mask |= GroundReason.near_plane;
            }

            const crosses_near = (front0 or front1 or front2) and !(front0 and front1 and front2);
            if (crosses_near) tri_mask |= GroundReason.cross_near;
            var dot_value: ?f32 = null;

            if (!crosses_near) {
                const normal = mesh.normals[tri_idx];
                const normal_transformed_raw = math.Vec3.new(
                    transform.data[0] * normal.x + transform.data[1] * normal.y + transform.data[2] * normal.z,
                    transform.data[4] * normal.x + transform.data[5] * normal.y + transform.data[6] * normal.z,
                    transform.data[8] * normal.x + transform.data[9] * normal.y + transform.data[10] * normal.z,
                );
                const normal_transformed = normal_transformed_raw.normalize();

                const centroid = math.Vec3.scale(math.Vec3.add(math.Vec3.add(p0, p1), p2), 1.0 / 3.0);
                const view_dir = math.Vec3.scale(centroid, -1.0);
                const view_dir_len = math.Vec3.length(view_dir);
                if (view_dir_len > 1e-6) {
                    const view_vector = math.Vec3.scale(view_dir, 1.0 / view_dir_len);
                    const view_dot = normal_transformed.dot(view_vector);
                    dot_value = view_dot;
                    if (view_dot < -1e-4) tri_mask |= GroundReason.backface;
                }
            }

            if (tri_mask != 0 and tri_debug_count < tri_debug.len) {
                tri_debug[tri_debug_count] = TriDebug{
                    .index = tri_idx,
                    .mask = tri_mask,
                    .z = .{ p0.z, p1.z, p2.z },
                    .dot = dot_value,
                    .front = .{ front0, front1, front2 },
                    .crosses = crosses_near,
                };
                tri_debug_count += 1;
            }

            mask |= tri_mask;
        }

        self.ground_debug.frames_since_log += 1;
        const first_frame = self.frame_count == 0;
        const should_log = first_frame or mask != self.ground_debug.last_mask or (mask != 0 and self.ground_debug.frames_since_log >= 60);
        if (!should_log) return;

        self.ground_debug.frames_since_log = 0;
        self.ground_debug.last_mask = mask;

        if (mask == 0) {
            std.debug.print("Ground plane visible (frame {})\n", .{self.frame_count});
            return;
        }

        for (tri_debug[0..tri_debug_count]) |info| {
            if (info.dot) |d| {
                std.debug.print(
                    "Ground tri {} issue mask {b:0>3} z[{d:.3},{d:.3},{d:.3}] front[{},{},{}] crosses={} dot={d:.4}\n",
                    .{
                        info.index,
                        info.mask,
                        info.z[0],
                        info.z[1],
                        info.z[2],
                        info.front[0],
                        info.front[1],
                        info.front[2],
                        info.crosses,
                        d,
                    },
                );
            } else {
                std.debug.print(
                    "Ground tri {} issue mask {b:0>3} z[{d:.3},{d:.3},{d:.3}] front[{},{},{}] crosses={} dot=n/a\n",
                    .{
                        info.index,
                        info.mask,
                        info.z[0],
                        info.z[1],
                        info.z[2],
                        info.front[0],
                        info.front[1],
                        info.front[2],
                        info.crosses,
                    },
                );
            }
        }
    }

    fn drawLightMarker(
        self: *Renderer,
        light_pos: math.Vec3,
        light_camera_z: f32,
        center_x: f32,
        center_y: f32,
        x_scale: f32,
        y_scale: f32,
    ) void {
        if (light_camera_z <= NEAR_CLIP) return;

        const ndc_x = (light_pos.x / light_camera_z) * x_scale;
        const ndc_y = (light_pos.y / light_camera_z) * y_scale;
        const screen_x = ndc_x * center_x + center_x;
        const screen_y = -ndc_y * center_y + center_y;

        const light_x = @as(i32, @intFromFloat(screen_x));
        const light_y = @as(i32, @intFromFloat(screen_y));
        const radius: i32 = 4;
        const color: u32 = 0xFF00FFFF;

        var py = light_y - radius;
        while (py <= light_y + radius) : (py += 1) {
            if (py < 0 or py >= self.bitmap.height) continue;
            var px = light_x - radius;
            while (px <= light_x + radius) : (px += 1) {
                if (px < 0 or px >= self.bitmap.width) continue;
                const dx = @as(f32, @floatFromInt(px - light_x));
                const dy = @as(f32, @floatFromInt(py - light_y));
                if ((dx * dx + dy * dy) > @as(f32, @floatFromInt(radius * radius))) continue;
                const idx = @as(usize, @intCast(py)) * @as(usize, @intCast(self.bitmap.width)) + @as(usize, @intCast(px));
                if (idx < self.bitmap.pixels.len) self.bitmap.pixels[idx] = color;
            }
        }
    }

    fn drawBitmap(self: *Renderer) void {
        if (self.hdc) |hdc| {
            if (self.hdc_mem) |hdc_mem| {
                const old_bitmap = SelectObject(hdc_mem, self.bitmap.hbitmap);
                defer _ = SelectObject(hdc_mem, old_bitmap);
                _ = BitBlt(
                    hdc,
                    0,
                    0,
                    self.bitmap.width,
                    self.bitmap.height,
                    hdc_mem,
                    0,
                    0,
                    SRCCOPY,
                );
            }
        }
    }

    fn meshletVisible(
        self: *const Renderer,
        meshlet: *const Meshlet,
        camera_position: math.Vec3,
        right: math.Vec3,
        up: math.Vec3,
        forward: math.Vec3,
        projection: ProjectionParams,
    ) bool {
        _ = self;
        const relative_center = math.Vec3.sub(meshlet.bounds_center, camera_position);
        const center_cam = math.Vec3.new(
            math.Vec3.dot(relative_center, right),
            math.Vec3.dot(relative_center, up),
            math.Vec3.dot(relative_center, forward),
        );

        const radius = meshlet.bounds_radius;
        const safety_margin = radius * 0.5 + 1.0; // generous guard against over-eager clipping near the screen edges
        const sphere_radius = radius + safety_margin;

        if (center_cam.z + sphere_radius <= projection.near_plane - NEAR_EPSILON) return false;

        return true;
    }

    /// Renders the scene using the parallel, tile-based pipeline.
    fn renderTiled(
        self: *Renderer,
        mesh: *const Mesh,
        transform: math.Mat4,
        light_dir: math.Vec3,
        pump: ?*const fn (*Renderer) bool,
        projection: ProjectionParams,
        mesh_work: *const MeshWork,
    ) !void {
        _ = mesh;
        _ = transform;
        _ = light_dir;
        const grid = self.tile_grid.?;
        const tile_buffers = self.tile_buffers.?;
        for (tile_buffers) |*buf| buf.clear();

        const triangles = mesh_work.triangleSlice();

        if (triangles.len == 0) {
            for (grid.tiles, 0..) |*tile, tile_idx| {
                TileRenderer.compositeTileToScreen(tile, &tile_buffers[tile_idx], &self.bitmap);
            }
            return;
        }
        const tile_lists = try BinningStage.binTrianglesToTiles(triangles, &grid, self.allocator);
        defer BinningStage.freeTileTriangleLists(tile_lists, self.allocator);

        const tile_jobs = self.tile_jobs_buffer.?;
        const jobs = self.job_buffer.?;
        var job_completion = self.job_completion_buffer.?;
        std.debug.assert(tile_jobs.len == grid.tiles.len);
        std.debug.assert(jobs.len == grid.tiles.len);
        std.debug.assert(job_completion.len == grid.tiles.len);
        @memset(job_completion, false);

        if (self.job_system) |js| {
            var pump_ok = true;
            var submitted_jobs: usize = 0;
            for (grid.tiles, 0..) |*tile, tile_idx| {
                if (pump_ok) {
                    if (pump) |p| {
                        if ((tile_idx & 7) == 0 and !p(self)) {
                            pump_ok = false;
                        }
                    }
                }

                tile_jobs[tile_idx] = TileRenderJob{
                    .tile = tile,
                    .tile_buffer = &tile_buffers[tile_idx],
                    .tri_list = &tile_lists[tile_idx],
                    .packets = triangles,
                    .draw_wireframe = self.show_wireframe,
                    .texture = self.texture,
                    .projection = projection,
                };
                jobs[tile_idx] = Job.init(TileRenderJob.renderTileJob, @ptrCast(&tile_jobs[tile_idx]), null);
                if (!js.submitJobAuto(&jobs[tile_idx])) {
                    std.log.err("Tile {} failed to submit to job system", .{tile_idx});
                    jobs[tile_idx].execute();
                    job_completion[tile_idx] = true;
                }
                submitted_jobs = tile_idx + 1;
            }

            if (submitted_jobs != 0) {
                var remaining: usize = 0;
                var idx_count: usize = 0;
                while (idx_count < submitted_jobs) : (idx_count += 1) {
                    if (!job_completion[idx_count]) remaining += 1;
                }

                while (remaining > 0) {
                    var progress = false;
                    for (jobs[0..submitted_jobs], 0..) |*job, idx| {
                        if (job_completion[idx]) continue;
                        if (job.isComplete()) {
                            job_completion[idx] = true;
                            remaining -= 1;
                            progress = true;
                        }
                    }
                    if (pump_ok) {
                        if (pump) |p| {
                            if (!p(self)) {
                                pump_ok = false;
                            }
                        }
                    }
                    if (!progress) std.Thread.yield() catch {};
                }
            }

            if (!pump_ok) {
                while (js.pendingJobs() != 0) {
                    std.Thread.yield() catch {};
                }
                return error.RenderInterrupted;
            }
        } else {
            for (grid.tiles, 0..) |*tile, tile_idx| {
                if (pump) |p| {
                    if ((tile_idx & 7) == 0 and !p(self)) return error.RenderInterrupted;
                }
                tile_jobs[tile_idx] = TileRenderJob{
                    .tile = tile,
                    .tile_buffer = &tile_buffers[tile_idx],
                    .tri_list = &tile_lists[tile_idx],
                    .packets = triangles,
                    .draw_wireframe = self.show_wireframe,
                    .texture = self.texture,
                    .projection = projection,
                };
                TileRenderJob.renderTileJob(@ptrCast(&tile_jobs[tile_idx]));
            }
        }

        // 4. Compositing: Copy the pixels from each completed tile buffer to the main screen bitmap.
        for (grid.tiles, 0..) |*tile, tile_idx| {
            TileRenderer.compositeTileToScreen(tile, &tile_buffers[tile_idx], &self.bitmap);
        }
    }

    fn generateMeshWork(
        self: *Renderer,
        mesh: *const Mesh,
        projected: [][2]i32,
        transformed_vertices: []math.Vec3,
        vertex_ready: []std.atomic.Value(VertexState),
        right: math.Vec3,
        up: math.Vec3,
        forward: math.Vec3,
        projection: ProjectionParams,
        work: *MeshWork,
        light_dir: math.Vec3,
    ) !void {
        std.debug.assert(mesh.vertices.len == vertex_ready.len);
        std.debug.assert(mesh.vertices.len == projected.len);
        std.debug.assert(mesh.vertices.len == transformed_vertices.len);

        work.clear();

        if (mesh.vertices.len == 0 or mesh.triangles.len == 0) {
            for (projected) |*p| {
                p.* = .{ INVALID_PROJECTED_COORD, INVALID_PROJECTED_COORD };
            }
            return;
        }

        for (projected) |*p| {
            p.* = .{ INVALID_PROJECTED_COORD, INVALID_PROJECTED_COORD };
        }

        resetVertexStates(vertex_ready);

        const mesh_vertices = mesh.vertices;

        if (mesh.meshlets.len == 0) {
            const mesh_mut: *Mesh = @constCast(mesh);
            mesh_mut.generateMeshlets(64, 126) catch |err| {
                std.log.err("generateMeshlets failed: {}", .{err});
            };
            self.mesh_work_cache.invalidate();
        }

        if (mesh.meshlets.len == 0) {
            const reserve = mesh.triangles.len;
            const packet_count: usize = if (reserve == 0) 0 else 1;
            try work.beginWrite(self.allocator, packet_count, reserve);
            var writer = MeshWorkWriter.init(work);
            for (mesh.triangles, 0..) |tri, tri_idx| {
                try emitTriangleToWork(
                    &writer,
                    mesh,
                    tri_idx,
                    tri,
                    vertex_ready,
                    mesh_vertices,
                    self.camera_position,
                    right,
                    up,
                    forward,
                    transformed_vertices,
                    projected,
                    projection,
                    light_dir,
                    null,
                );
            }
            if (reserve != 0) {
                work.meshlet_packets[0] = MeshletPacket{
                    .triangle_start = 0,
                    .triangle_count = reserve,
                    .meshlet_index = 0,
                };
                work.next_triangle.store(reserve, .release);
                work.finalize(packet_count);
            } else {
                work.finalize(0);
            }
            return;
        }

        const meshlets = mesh.meshlets;
        const meshlet_count = meshlets.len;
        var visibility = try self.allocator.alloc(bool, meshlet_count);
        defer self.allocator.free(visibility);
        if (meshlet_count != 0) @memset(visibility, false);

        var visible_meshlet_count: usize = 0;
        var visible_triangle_budget: usize = 0;

        if (self.job_system) |js| {
            if (meshlet_count != 0) {
                const job_count = (meshlet_count + MESHLETS_PER_CULL_JOB - 1) / MESHLETS_PER_CULL_JOB;
                var cull_jobs = try self.allocator.alloc(MeshletCullJob, job_count);
                defer self.allocator.free(cull_jobs);
                var jobs = try self.allocator.alloc(Job, job_count);
                defer self.allocator.free(jobs);
                var job_completion = try self.allocator.alloc(bool, job_count);
                defer self.allocator.free(job_completion);
                @memset(job_completion, false);

                var job_idx: usize = 0;
                while (job_idx < job_count) : (job_idx += 1) {
                    const start = job_idx * MESHLETS_PER_CULL_JOB;
                    const end = @min(start + MESHLETS_PER_CULL_JOB, meshlet_count);
                    cull_jobs[job_idx] = MeshletCullJob{
                        .renderer = self,
                        .meshlets = meshlets,
                        .visibility = visibility,
                        .start_index = start,
                        .end_index = end,
                        .camera_position = self.camera_position,
                        .basis_right = right,
                        .basis_up = up,
                        .basis_forward = forward,
                        .projection = projection,
                    };
                    jobs[job_idx] = Job.init(MeshletCullJob.run, @ptrCast(&cull_jobs[job_idx]), null);
                    if (!js.submitJobAuto(&jobs[job_idx])) {
                        cull_jobs[job_idx].process();
                        job_completion[job_idx] = true;
                    }
                }

                var remaining = job_count;
                while (remaining > 0) {
                    var progress = false;
                    for (jobs, 0..) |*job_entry, idx| {
                        if (job_completion[idx]) continue;
                        if (job_entry.isComplete()) {
                            job_completion[idx] = true;
                            remaining -= 1;
                            progress = true;
                        }
                    }
                    if (!progress) std.Thread.yield() catch {};
                }
            }
        } else {
            var meshlet_idx: usize = 0;
            while (meshlet_idx < meshlet_count) : (meshlet_idx += 1) {
                const meshlet_ptr = &meshlets[meshlet_idx];
                const visible = self.meshletVisible(meshlet_ptr, self.camera_position, right, up, forward, projection);
                visibility[meshlet_idx] = visible;
            }
        }

        visible_meshlet_count = 0;
        visible_triangle_budget = 0;
        var visibility_index: usize = 0;
        while (visibility_index < meshlet_count) : (visibility_index += 1) {
            if (!visibility[visibility_index]) continue;
            visible_meshlet_count += 1;
            visible_triangle_budget += meshlets[visibility_index].triangle_indices.len;
        }

        if (visible_triangle_budget == 0) {
            work.clear();
            return;
        }

        var visible_indices: []usize = &[_]usize{};
        var meshlet_offsets: []usize = &[_]usize{};
        defer {
            if (visible_indices.len != 0) self.allocator.free(visible_indices);
            if (meshlet_offsets.len != 0) self.allocator.free(meshlet_offsets);
        }
        if (visible_meshlet_count > 0) {
            visible_indices = try self.allocator.alloc(usize, visible_meshlet_count);
            meshlet_offsets = try self.allocator.alloc(usize, visible_meshlet_count);

            var fill: usize = 0;
            var running: usize = 0;
            var idx: usize = 0;
            while (idx < meshlet_count) : (idx += 1) {
                if (!visibility[idx]) continue;
                visible_indices[fill] = idx;
                meshlet_offsets[fill] = running;
                running += meshlets[idx].triangle_indices.len;
                fill += 1;
            }
            if (fill != visible_meshlet_count) {
                std.log.err("Visible meshlet fill mismatch: fill {} expected {}", .{ fill, visible_meshlet_count });
            }
            if (running != visible_triangle_budget) {
                std.log.err("Visible triangle budget mismatch: running {} expected {}", .{ running, visible_triangle_budget });
            }
        }

        try work.beginWrite(self.allocator, visible_meshlet_count, visible_triangle_budget);

        if (visible_meshlet_count > 0) {
            for (visible_indices, 0..) |meshlet_index, packet_idx| {
                const triangle_start = meshlet_offsets[packet_idx];
                const triangle_count = meshlets[meshlet_index].triangle_indices.len;
                work.meshlet_packets[packet_idx] = MeshletPacket{
                    .triangle_start = triangle_start,
                    .triangle_count = triangle_count,
                    .meshlet_index = meshlet_index,
                };
            }
        }

        if (self.job_system) |js| {
            if (visible_meshlet_count == 0) {
                work.finalize(0);
                return;
            }

            var meshlet_jobs = try self.allocator.alloc(MeshletTaskJob, visible_meshlet_count);
            defer self.allocator.free(meshlet_jobs);
            var jobs = try self.allocator.alloc(Job, visible_meshlet_count);
            defer self.allocator.free(jobs);
            var job_completion = try self.allocator.alloc(bool, visible_meshlet_count);
            defer self.allocator.free(job_completion);
            @memset(job_completion, false);

            var job_idx: usize = 0;
            while (job_idx < visible_meshlet_count) : (job_idx += 1) {
                const meshlet_index = visible_indices[job_idx];
                if (meshlet_index >= meshlet_count) {
                    std.log.err("Visible meshlet index {} out of range (count {})", .{ meshlet_index, meshlet_count });
                    continue;
                }
                const meshlet_ptr = &meshlets[meshlet_index];
                meshlet_jobs[job_idx] = MeshletTaskJob{
                    .mesh = mesh,
                    .meshlet = meshlet_ptr,
                    .mesh_work = work,
                    .projected = projected,
                    .transformed_vertices = transformed_vertices,
                    .vertex_ready = vertex_ready,
                    .camera_position = self.camera_position,
                    .basis_right = right,
                    .basis_up = up,
                    .basis_forward = forward,
                    .projection = projection,
                    .light_dir = light_dir,
                    .output_start = meshlet_offsets[job_idx],
                };
                jobs[job_idx] = Job.init(MeshletTaskJob.run, @ptrCast(&meshlet_jobs[job_idx]), null);
                if (!js.submitJobAuto(&jobs[job_idx])) {
                    std.log.err("Meshlet job {} failed to submit", .{job_idx});
                    meshlet_jobs[job_idx].process();
                    job_completion[job_idx] = true;
                }
            }

            var remaining = visible_meshlet_count;
            while (remaining > 0) {
                var progress = false;
                for (jobs, 0..) |*job_entry, idx| {
                    if (job_completion[idx]) continue;
                    if (job_entry.isComplete()) {
                        job_completion[idx] = true;
                        remaining -= 1;
                        progress = true;
                    }
                }
                if (!progress) std.Thread.yield() catch {};
            }

            work.next_triangle.store(visible_triangle_budget, .release);
        } else {
            var writer = MeshWorkWriter.init(work);
            var cursor: usize = 0;
            var visible_idx: usize = 0;
            while (visible_idx < visible_meshlet_count) : (visible_idx += 1) {
                const meshlet_index = visible_indices[visible_idx];
                if (meshlet_index >= meshlet_count) {
                    std.log.err("Sequential meshlet index {} out of range (count {})", .{ meshlet_index, meshlet_count });
                    continue;
                }
                const meshlet_ptr = &meshlets[meshlet_index];
                for (meshlet_ptr.triangle_indices) |tri_idx| {
                    const tri = mesh.triangles[tri_idx];
                    emitTriangleToWork(
                        &writer,
                        mesh,
                        tri_idx,
                        tri,
                        vertex_ready,
                        mesh_vertices,
                        self.camera_position,
                        right,
                        up,
                        forward,
                        transformed_vertices,
                        projected,
                        projection,
                        light_dir,
                        &cursor,
                    ) catch |err| {
                        std.log.err("Meshlet emit failed: {}", .{err});
                    };
                }
            }

            work.next_triangle.store(cursor, .release);
        }

        work.finalize(visible_meshlet_count);
    }

    fn renderDirect(
        self: *Renderer,
        mesh: *const Mesh,
        transform: math.Mat4,
        light_dir: math.Vec3,
        projection: ProjectionParams,
        mesh_work: *const MeshWork,
    ) !void {
        _ = self;
        _ = mesh;
        _ = transform;
        _ = light_dir;
        _ = projection;
        _ = mesh_work;
    }

    fn drawShadedTriangle(self: *Renderer, p0: [2]i32, p1: [2]i32, p2: [2]i32, shading: TileRenderer.ShadingParams) void {
        _ = self;
        _ = p0;
        _ = p1;
        _ = p2;
        _ = shading;
    }

    fn drawLineColored(self: *Renderer, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
        _ = self;
        _ = x0;
        _ = y0;
        _ = x1;
        _ = y1;
        _ = color;
    }
};
