const std = @import("std");
const math = @import("../../core/math.zig");
const camera_controller = @import("../camera/controller.zig");
const direct_draw_list = @import("draw_list.zig");
const direct_packets = @import("packets.zig");
const direct_primitives = @import("primitives.zig");
const job_system = @import("job_system");
const Job = job_system.Job;
const JobSystem = job_system.JobSystem;

pub const max_polygon_points = 8;
pub const near_plane: f32 = 0.1;

pub const Camera = struct {
    position: math.Vec3,
    yaw: f32,
    pitch: f32,
    fov_deg: f32,
    /// Horizontal aspect (width / height). Defaulted to 16/9 so older
    /// call sites that don't fill it in don't break; the frustum-cull
    /// path reads it for side-plane tests.
    aspect: f32 = 16.0 / 9.0,
};

pub const WorldLine = struct {
    start: math.Vec3,
    end: math.Vec3,
};

pub const WorldTriangle = struct {
    a: math.Vec3,
    b: math.Vec3,
    c: math.Vec3,
};

pub const WorldPolygon = struct {
    point_count: u8,
    points: [max_polygon_points]math.Vec3,

    pub fn fromSlice(points: []const math.Vec3) !WorldPolygon {
        if (points.len == 0 or points.len > max_polygon_points) return error.InvalidPolygonPointCount;
        var copied = [_]math.Vec3{math.Vec3.new(0.0, 0.0, 0.0)} ** max_polygon_points;
        for (points, 0..) |point, index| copied[index] = point;
        return .{
            .point_count = @intCast(points.len),
            .points = copied,
        };
    }

    pub fn slice(self: *const WorldPolygon) []const math.Vec3 {
        return self.points[0..self.point_count];
    }
};

pub const WorldCircle = struct {
    center: math.Vec3,
    radius: f32,
};

pub const StrokeMaterial = direct_packets.StrokeMaterial;
pub const SurfaceMaterial = direct_packets.SurfaceMaterial;

pub const DrawPacket = union(enum) {
    line: struct {
        line: WorldLine,
        material: StrokeMaterial,
    },
    triangle: struct {
        triangle: WorldTriangle,
        material: SurfaceMaterial,
        vertex_normals: ?[3]math.Vec3 = null,
        gouraud_colors: ?[3]u32 = null,
    },
    polygon: struct {
        polygon: WorldPolygon,
        material: SurfaceMaterial,
    },
    circle: struct {
        circle: WorldCircle,
        material: SurfaceMaterial,
    },
};

pub const PrimitiveBatch = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(DrawPacket) = .{},

    pub fn init(allocator: std.mem.Allocator) PrimitiveBatch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PrimitiveBatch) void {
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *PrimitiveBatch) void {
        self.commands.clearRetainingCapacity();
    }

    pub fn ensureCommandCapacity(self: *PrimitiveBatch, count: usize) !void {
        try self.commands.ensureTotalCapacity(self.allocator, count);
    }

    pub fn items(self: *const PrimitiveBatch) []const DrawPacket {
        return self.commands.items;
    }

    pub fn append(self: *PrimitiveBatch, command: DrawPacket) !void {
        try self.commands.append(self.allocator, command);
    }

    pub fn appendAssumeCapacity(self: *PrimitiveBatch, command: DrawPacket) void {
        self.commands.appendAssumeCapacity(command);
    }

    pub fn appendLine(self: *PrimitiveBatch, line: WorldLine, material: StrokeMaterial) !void {
        try self.append(.{ .line = .{ .line = line, .material = material } });
    }

    pub fn appendTriangle(self: *PrimitiveBatch, triangle: WorldTriangle, material: SurfaceMaterial) !void {
        try self.append(.{ .triangle = .{ .triangle = triangle, .material = material } });
    }

    pub fn appendTriangleAssumeCapacity(self: *PrimitiveBatch, triangle: WorldTriangle, material: SurfaceMaterial) void {
        self.appendAssumeCapacity(.{ .triangle = .{ .triangle = triangle, .material = material } });
    }

    pub fn appendTriangleLit(self: *PrimitiveBatch, triangle: WorldTriangle, material: SurfaceMaterial, vertex_normals: [3]math.Vec3) !void {
        try self.append(.{ .triangle = .{
            .triangle = triangle,
            .material = material,
            .vertex_normals = vertex_normals,
        } });
    }

    pub fn appendTriangleLitAssumeCapacity(self: *PrimitiveBatch, triangle: WorldTriangle, material: SurfaceMaterial, vertex_normals: [3]math.Vec3) void {
        self.appendAssumeCapacity(.{ .triangle = .{
            .triangle = triangle,
            .material = material,
            .vertex_normals = vertex_normals,
        } });
    }

    pub fn appendPolygon(self: *PrimitiveBatch, points: []const math.Vec3, material: SurfaceMaterial) !void {
        try self.append(.{ .polygon = .{
            .polygon = try WorldPolygon.fromSlice(points),
            .material = material,
        } });
    }

    pub fn appendCircle(self: *PrimitiveBatch, circle: WorldCircle, material: SurfaceMaterial) !void {
        try self.append(.{ .circle = .{ .circle = circle, .material = material } });
    }
};

const Projector = struct {
    camera: Camera,
    width: i32,
    height: i32,
    basis: camera_controller.ViewBasis,
    projection: camera_controller.ProjectionScalars,

    fn init(camera: Camera, width: i32, height: i32) Projector {
        return .{
            .camera = camera,
            .width = width,
            .height = height,
            .basis = camera_controller.computeViewBasis(camera.yaw, camera.pitch),
            .projection = camera_controller.computeProjectionScalars(width, height, camera.fov_deg),
        };
    }

    fn project(self: *const Projector, point: math.Vec3) ?direct_primitives.Point2i {
        const relative = math.Vec3.sub(point, self.camera.position);
        const camera_x = math.Vec3.dot(relative, self.basis.right);
        const camera_y = math.Vec3.dot(relative, self.basis.up);
        const camera_z = math.Vec3.dot(relative, self.basis.forward);
        if (camera_z <= near_plane) return null;

        const ndc_x = (camera_x / camera_z) * self.projection.x_scale;
        const ndc_y = (camera_y / camera_z) * self.projection.y_scale;
        return .{
            .x = @intFromFloat(self.projection.center_x + ndc_x * self.projection.center_x),
            .y = @intFromFloat(self.projection.center_y - ndc_y * self.projection.center_y),
        };
    }

    fn cameraDepth(self: *const Projector, point: math.Vec3) ?f32 {
        const relative = math.Vec3.sub(point, self.camera.position);
        const camera_z = math.Vec3.dot(relative, self.basis.forward);
        if (camera_z <= near_plane) return null;
        return camera_z;
    }

    fn lineDepth(self: *const Projector, line: WorldLine) ?f32 {
        const start_z = self.cameraDepth(line.start) orelse return null;
        const end_z = self.cameraDepth(line.end) orelse return null;
        return (start_z + end_z) * 0.5;
    }

    fn triangleDepth(self: *const Projector, triangle: WorldTriangle) ?f32 {
        const a_z = self.cameraDepth(triangle.a) orelse return null;
        const b_z = self.cameraDepth(triangle.b) orelse return null;
        const c_z = self.cameraDepth(triangle.c) orelse return null;
        return (a_z + b_z + c_z) / 3.0;
    }

    fn triangleVertexDepths(self: *const Projector, triangle: WorldTriangle) ?[3]f32 {
        return .{
            self.cameraDepth(triangle.a) orelse return null,
            self.cameraDepth(triangle.b) orelse return null,
            self.cameraDepth(triangle.c) orelse return null,
        };
    }

    fn polygonDepth(self: *const Projector, points: []const math.Vec3) ?f32 {
        if (points.len == 0) return null;
        var sum: f32 = 0.0;
        for (points) |point| {
            sum += self.cameraDepth(point) orelse return null;
        }
        return sum / @as(f32, @floatFromInt(points.len));
    }

    fn circleDepth(self: *const Projector, circle: WorldCircle) ?f32 {
        return self.cameraDepth(circle.center);
    }

    /// Projects N points without bailing on near-plane failure. Each
    /// vertex is annotated with a valid bit so callers can per-triangle
    /// cull at the granularity of the caller's choice. The SIMD body
    /// scales via `std.simd.suggestVectorLength` so the same code runs
    /// 4-wide on SSE2/NEON, 8-wide on AVX2/SVE, 16-wide on AVX-512.
    fn projectPointsMasked(
        self: *const Projector,
        points: []const math.Vec3,
        out: []direct_primitives.Point2i,
        valid: []bool,
    ) void {
        std.debug.assert(out.len >= points.len);
        std.debug.assert(valid.len >= points.len);
        const lanes = comptime std.simd.suggestVectorLength(f32) orelse 0;
        if (lanes < 4) {
            for (points, 0..) |point, index| {
                if (self.project(point)) |p| {
                    out[index] = p;
                    valid[index] = true;
                } else {
                    valid[index] = false;
                }
            }
            return;
        }

        const Vec = @Vector(lanes, f32);
        const pos_x: Vec = @splat(self.camera.position.x);
        const pos_y: Vec = @splat(self.camera.position.y);
        const pos_z: Vec = @splat(self.camera.position.z);
        const right_x: Vec = @splat(self.basis.right.x);
        const right_y: Vec = @splat(self.basis.right.y);
        const right_z: Vec = @splat(self.basis.right.z);
        const up_x: Vec = @splat(self.basis.up.x);
        const up_y: Vec = @splat(self.basis.up.y);
        const up_z: Vec = @splat(self.basis.up.z);
        const forward_x: Vec = @splat(self.basis.forward.x);
        const forward_y: Vec = @splat(self.basis.forward.y);
        const forward_z: Vec = @splat(self.basis.forward.z);
        const x_scale: Vec = @splat(self.projection.x_scale);
        const y_scale: Vec = @splat(self.projection.y_scale);
        const center_x: Vec = @splat(self.projection.center_x);
        const center_y: Vec = @splat(self.projection.center_y);
        const near_v: Vec = @splat(near_plane);

        var index: usize = 0;
        while (index + lanes <= points.len) : (index += lanes) {
            var xs: [lanes]f32 = undefined;
            var ys: [lanes]f32 = undefined;
            var zs: [lanes]f32 = undefined;
            inline for (0..lanes) |lane| {
                const point = points[index + lane];
                xs[lane] = point.x;
                ys[lane] = point.y;
                zs[lane] = point.z;
            }
            const rel_x: Vec = @as(Vec, @bitCast(xs)) - pos_x;
            const rel_y: Vec = @as(Vec, @bitCast(ys)) - pos_y;
            const rel_z: Vec = @as(Vec, @bitCast(zs)) - pos_z;
            const camera_x = rel_x * right_x + rel_y * right_y + rel_z * right_z;
            const camera_y = rel_x * up_x + rel_y * up_y + rel_z * up_z;
            const camera_z = rel_x * forward_x + rel_y * forward_y + rel_z * forward_z;
            const valid_v = camera_z > near_v;
            // Clamp camera_z away from zero for the divide so masked-off
            // lanes don't produce NaN/Inf that could trap.
            const safe_z = @select(f32, valid_v, camera_z, @as(Vec, @splat(1.0)));
            const inv_z = @as(Vec, @splat(1.0)) / safe_z;
            const ndc_x = (camera_x * inv_z) * x_scale;
            const ndc_y = (camera_y * inv_z) * y_scale;
            const screen_x = center_x + ndc_x * center_x;
            const screen_y = center_y - ndc_y * center_y;
            inline for (0..lanes) |lane| {
                valid[index + lane] = valid_v[lane];
                out[index + lane] = .{
                    .x = @intFromFloat(screen_x[lane]),
                    .y = @intFromFloat(screen_y[lane]),
                };
            }
        }

        while (index < points.len) : (index += 1) {
            if (self.project(points[index])) |p| {
                out[index] = p;
                valid[index] = true;
            } else {
                valid[index] = false;
            }
        }
    }

    fn projectPoints(self: *const Projector, points: []const math.Vec3, out: []direct_primitives.Point2i) bool {
        std.debug.assert(out.len >= points.len);
        const lanes = comptime std.simd.suggestVectorLength(f32) orelse 0;
        if (lanes < 4 or points.len < 4) {
            for (points, 0..) |point, index| {
                out[index] = self.project(point) orelse return false;
            }
            return true;
        }

        const Vec = @Vector(lanes, f32);
        const pos_x: Vec = @splat(self.camera.position.x);
        const pos_y: Vec = @splat(self.camera.position.y);
        const pos_z: Vec = @splat(self.camera.position.z);
        const right_x: Vec = @splat(self.basis.right.x);
        const right_y: Vec = @splat(self.basis.right.y);
        const right_z: Vec = @splat(self.basis.right.z);
        const up_x: Vec = @splat(self.basis.up.x);
        const up_y: Vec = @splat(self.basis.up.y);
        const up_z: Vec = @splat(self.basis.up.z);
        const forward_x: Vec = @splat(self.basis.forward.x);
        const forward_y: Vec = @splat(self.basis.forward.y);
        const forward_z: Vec = @splat(self.basis.forward.z);
        const x_scale: Vec = @splat(self.projection.x_scale);
        const y_scale: Vec = @splat(self.projection.y_scale);
        const center_x: Vec = @splat(self.projection.center_x);
        const center_y: Vec = @splat(self.projection.center_y);

        var index: usize = 0;
        while (index + lanes <= points.len) : (index += lanes) {
            var xs: [lanes]f32 = undefined;
            var ys: [lanes]f32 = undefined;
            var zs: [lanes]f32 = undefined;
            inline for (0..lanes) |lane| {
                const point = points[index + lane];
                xs[lane] = point.x;
                ys[lane] = point.y;
                zs[lane] = point.z;
            }

            const rel_x: Vec = @as(Vec, @bitCast(xs)) - pos_x;
            const rel_y: Vec = @as(Vec, @bitCast(ys)) - pos_y;
            const rel_z: Vec = @as(Vec, @bitCast(zs)) - pos_z;
            const camera_x = rel_x * right_x + rel_y * right_y + rel_z * right_z;
            const camera_y = rel_x * up_x + rel_y * up_y + rel_z * up_z;
            const camera_z = rel_x * forward_x + rel_y * forward_y + rel_z * forward_z;
            inline for (0..lanes) |lane| {
                if (camera_z[lane] <= near_plane) return false;
            }
            const inv_z = @as(Vec, @splat(1.0)) / camera_z;
            const ndc_x = (camera_x * inv_z) * x_scale;
            const ndc_y = (camera_y * inv_z) * y_scale;
            const screen_x = center_x + ndc_x * center_x;
            const screen_y = center_y - ndc_y * center_y;

            inline for (0..lanes) |lane| {
                out[index + lane] = .{
                    .x = @intFromFloat(screen_x[lane]),
                    .y = @intFromFloat(screen_y[lane]),
                };
            }
        }

        while (index < points.len) : (index += 1) {
            out[index] = self.project(points[index]) orelse return false;
        }
        return true;
    }

    fn projectCircleRadius(self: *const Projector, center: math.Vec3, radius: f32) ?i32 {
        const relative = math.Vec3.sub(center, self.camera.position);
        const camera_z = math.Vec3.dot(relative, self.basis.forward);
        if (camera_z <= near_plane) return null;
        const radius_px = @as(i32, @intFromFloat(@abs((radius / camera_z) * self.projection.x_scale * self.projection.center_x)));
        if (radius_px <= 0) return null;
        return radius_px;
    }

    fn projectLine(self: *const Projector, start: math.Vec3, end: math.Vec3, out: *[2]direct_primitives.Point2i) bool {
        const points = [_]math.Vec3{ start, end };
        return self.projectSmallPoints(points[0..], out[0..], 2);
    }

    fn projectTriangle(self: *const Projector, a: math.Vec3, b: math.Vec3, c: math.Vec3, out: *[3]direct_primitives.Point2i) bool {
        const points = [_]math.Vec3{ a, b, c };
        return self.projectSmallPoints(points[0..], out[0..], 3);
    }

    fn projectSmallPoints(self: *const Projector, points: []const math.Vec3, out: []direct_primitives.Point2i, comptime count: usize) bool {
        std.debug.assert(points.len == count);
        std.debug.assert(out.len >= count);

        if (comptime count == 0) return true;
        if (comptime count >= 4) return self.projectPoints(points, out);

        const Vec = @Vector(4, f32);
        const pos_x: Vec = .{ self.camera.position.x, self.camera.position.x, self.camera.position.x, self.camera.position.x };
        const pos_y: Vec = .{ self.camera.position.y, self.camera.position.y, self.camera.position.y, self.camera.position.y };
        const pos_z: Vec = .{ self.camera.position.z, self.camera.position.z, self.camera.position.z, self.camera.position.z };
        const right_x: Vec = @splat(self.basis.right.x);
        const right_y: Vec = @splat(self.basis.right.y);
        const right_z: Vec = @splat(self.basis.right.z);
        const up_x: Vec = @splat(self.basis.up.x);
        const up_y: Vec = @splat(self.basis.up.y);
        const up_z: Vec = @splat(self.basis.up.z);
        const forward_x: Vec = @splat(self.basis.forward.x);
        const forward_y: Vec = @splat(self.basis.forward.y);
        const forward_z: Vec = @splat(self.basis.forward.z);
        const x_scale: Vec = @splat(self.projection.x_scale);
        const y_scale: Vec = @splat(self.projection.y_scale);
        const center_x: Vec = @splat(self.projection.center_x);
        const center_y: Vec = @splat(self.projection.center_y);

        var xs = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
        var ys = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
        var zs = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
        inline for (0..count) |index| {
            xs[index] = points[index].x;
            ys[index] = points[index].y;
            zs[index] = points[index].z;
        }

        const rel_x: Vec = @as(Vec, @bitCast(xs)) - pos_x;
        const rel_y: Vec = @as(Vec, @bitCast(ys)) - pos_y;
        const rel_z: Vec = @as(Vec, @bitCast(zs)) - pos_z;
        const camera_x = rel_x * right_x + rel_y * right_y + rel_z * right_z;
        const camera_y = rel_x * up_x + rel_y * up_y + rel_z * up_z;
        const camera_z = rel_x * forward_x + rel_y * forward_y + rel_z * forward_z;

        inline for (0..count) |index| {
            if (camera_z[index] <= near_plane) return false;
        }

        const inv_z = @as(Vec, @splat(1.0)) / camera_z;
        const screen_x = center_x + (camera_x * inv_z) * x_scale * center_x;
        const screen_y = center_y - (camera_y * inv_z) * y_scale * center_y;

        inline for (0..count) |index| {
            out[index] = .{
                .x = @intFromFloat(screen_x[index]),
                .y = @intFromFloat(screen_y[index]),
            };
        }
        return true;
    }
};

pub fn compileToDrawList(
    batch: *const PrimitiveBatch,
    draw_list: *direct_draw_list.DrawList,
    camera: Camera,
    width: i32,
    height: i32,
) !void {
    return compileToDrawListParallel(batch, draw_list, camera, width, height, null, null);
}

/// Parallel variant — same output as `compileToDrawList`, but spreads
/// per-triangle projection/cull work across the supplied job system
/// when the input is large enough to amortize the chunk merge. Scratch
/// draw lists are caller-owned so the renderer can reuse them across
/// frames (avoids per-frame ArrayList allocation).
pub fn compileToDrawListParallel(
    batch: *const PrimitiveBatch,
    draw_list: *direct_draw_list.DrawList,
    camera: Camera,
    width: i32,
    height: i32,
    job_sys: ?*JobSystem,
    chunk_draw_lists: ?[]direct_draw_list.DrawList,
) !void {
    draw_list.clearRetainingCapacity();
    if (width <= 0 or height <= 0) return;
    const commands = batch.items();
    if (commands.len == 0) return;

    var polygon_point_count: usize = 0;
    var triangles_only = true;
    for (commands) |command| switch (command) {
        .triangle => {},
        .polygon => |payload| {
            triangles_only = false;
            polygon_point_count += payload.polygon.point_count;
        },
        else => triangles_only = false,
    };
    try draw_list.ensureCommandCapacity(commands.len);
    try draw_list.ensurePolygonPointCapacity(polygon_point_count);

    const projector = Projector.init(camera, width, height);
    if (triangles_only) {
        // Parallel split is worth it once the triangle count crosses a
        // threshold — for tiny inputs the chunk-merge overhead wins.
        // 8k triangles is roughly where the serial loop reaches ~1ms
        // on this CPU.
        const parallel_threshold: usize = 8 * 1024;
        if (job_sys != null and chunk_draw_lists != null and commands.len >= parallel_threshold and chunk_draw_lists.?.len >= 2) {
            try compileTrianglesOnlyParallel(commands, draw_list, projector, job_sys.?, chunk_draw_lists.?);
            return;
        }
        try compileTrianglesOnlyToDrawList(commands, draw_list, projector);
        return;
    }

    for (commands, 0..) |command, packet_index| {
        switch (command) {
            .line => |payload| {
                var projected: [2]direct_primitives.Point2i = undefined;
                if (!projector.projectLine(payload.line.start, payload.line.end, &projected)) continue;
                const resolved_depth = if (payload.material.depth != null) projector.lineDepth(payload.line) else null;
                var resolved_material = payload.material;
                resolved_material.depth = resolved_depth;
                try draw_list.append(.{
                    .sort_key = makeLineSortKey(resolved_depth, packet_index),
                    .layer = .geometry,
                    .flags = .{ .depth_test = false, .depth_write = false },
                    .material = .{ .stroke = resolved_material },
                    .payload = .{ .line = .{ .start = projected[0], .end = projected[1] } },
                });
            },
            .triangle => |payload| {
                // Early backface reject (see compileTrianglesOnlyToDrawList).
                if (payload.material.cull_backfaces and !worldTriangleFrontFacing(payload.triangle, projector.camera.position)) continue;
                var projected: [3]direct_primitives.Point2i = undefined;
                if (!projector.projectTriangle(payload.triangle.a, payload.triangle.b, payload.triangle.c, &projected)) continue;
                if (signedArea2(projected[0], projected[1], projected[2]) == 0) continue;
                const resolved_vertex_depths = if (payload.material.depth != null) projector.triangleVertexDepths(payload.triangle) else null;
                const resolved_depth = if (resolved_vertex_depths) |depths|
                    (depths[0] + depths[1] + depths[2]) / 3.0
                else
                    null;
                const resolved_material = surfaceWithResolvedDepth(payload.material, resolved_depth);
                const gouraud_setup = if (resolved_vertex_depths == null)
                    if (payload.gouraud_colors) |vertex_colors|
                        direct_primitives.prepareGouraudTriangle(.{ .a = projected[0], .b = projected[1], .c = projected[2] }, vertex_colors)
                    else
                        null
                else
                    null;
                // Camera-space face normal for the G-buffer normal target.
                // Lit triangles get the average of vertex_normals (already
                // smooth-shaded); unlit ones get the geometric face normal
                // from the world triangle, both transformed into camera
                // space via the projector basis.
                const face_normal_camera = computeCameraSpaceFaceNormal(
                    payload.triangle,
                    payload.vertex_normals,
                    &projector.basis,
                );
                try draw_list.append(.{
                    .sort_key = makeTriangleSortKey(resolved_depth, packet_index),
                    .layer = .geometry,
                    .flags = .{},
                    .material = .{ .surface = resolved_material },
                    .payload = .{ .triangle = .{
                        .triangle = .{ .a = projected[0], .b = projected[1], .c = projected[2] },
                        .vertex_colors = payload.gouraud_colors,
                        .vertex_depths = resolved_vertex_depths,
                        .gouraud_setup = gouraud_setup,
                        .face_normal = face_normal_camera,
                    } },
                });
            },
            .polygon => |payload| {
                var projected: [max_polygon_points]direct_primitives.Point2i = undefined;
                const visible_count = payload.polygon.slice().len;
                if (!projector.projectPoints(payload.polygon.slice(), projected[0..visible_count])) continue;
                if (payload.material.cull_backfaces and !worldPolygonFrontFacing(payload.polygon.slice(), projector.camera.position)) continue;
                if (projectedPolygonSignedArea2(projected[0..visible_count]) == 0) continue;
                if (visible_count >= 3) {
                    const resolved_depth = if (payload.material.depth != null) projector.polygonDepth(payload.polygon.slice()) else null;
                    const resolved_material = surfaceWithResolvedDepth(payload.material, resolved_depth);
                    const start = draw_list.polygon_points.items.len;
                    try draw_list.polygon_points.appendSlice(draw_list.allocator, projected[0..visible_count]);
                    try draw_list.append(.{
                        .sort_key = makeSurfaceSortKey(resolved_depth, packet_index),
                        .layer = .geometry,
                        .flags = .{},
                        .material = .{ .surface = resolved_material },
                        .payload = .{ .polygon = .{
                            .points = draw_list.polygon_points.items[start .. start + visible_count],
                        } },
                    });
                }
            },
            .circle => |payload| {
                const center = projector.project(payload.circle.center) orelse continue;
                const radius = projector.projectCircleRadius(payload.circle.center, payload.circle.radius) orelse continue;
                const resolved_depth = if (payload.material.depth != null) projector.circleDepth(payload.circle) else null;
                const resolved_material = surfaceWithResolvedDepth(payload.material, resolved_depth);
                try draw_list.append(.{
                    .sort_key = makeSurfaceSortKey(resolved_depth, packet_index),
                    .layer = .geometry,
                    .flags = .{},
                    .material = .{ .surface = resolved_material },
                    .payload = .{ .circle = .{ .center = center, .radius = radius } },
                });
            },
        }
    }
}

fn compileTrianglesOnlyToDrawList(
    commands: []const DrawPacket,
    draw_list: *direct_draw_list.DrawList,
    projector: Projector,
) !void {
    for (commands, 0..) |command, packet_index| {
        const payload = command.triangle;
        // Early backface reject — operates on world-space coordinates,
        // skipping the projection entirely for ~half the triangles in
        // a closed mesh (acura: ~1.56M triangles → ~780k saved).
        if (payload.material.cull_backfaces and !worldTriangleFrontFacing(payload.triangle, projector.camera.position)) continue;
        var projected: [3]direct_primitives.Point2i = undefined;
        if (!projector.projectTriangle(payload.triangle.a, payload.triangle.b, payload.triangle.c, &projected)) continue;
        if (signedArea2(projected[0], projected[1], projected[2]) == 0) continue;
        const resolved_vertex_depths = if (payload.material.depth != null) projector.triangleVertexDepths(payload.triangle) else null;
        const resolved_depth = if (resolved_vertex_depths) |depths|
            (depths[0] + depths[1] + depths[2]) / 3.0
        else
            null;
        const projected_triangle: direct_primitives.Triangle2i = .{ .a = projected[0], .b = projected[1], .c = projected[2] };
        const gouraud_setup = if (resolved_vertex_depths == null)
            if (payload.gouraud_colors) |vertex_colors|
                direct_primitives.prepareGouraudTriangle(projected_triangle, vertex_colors)
            else
                null
        else
            null;
        // Only compute the camera-space face normal when the deferred
        // pipeline will consume it. Forward shading has no use for it
        // and the trig dot products are non-trivial work to skip.
        const face_normal_camera: ?math.Vec3 = if (@import("../../core/app_config.zig").DEFERRED_SHADING_ENABLED)
            computeCameraSpaceFaceNormal(payload.triangle, payload.vertex_normals, &projector.basis)
        else
            null;
        draw_list.appendProjectedTriangleAssumeCapacity(
            makeTriangleSortKey(resolved_depth, packet_index),
            surfaceWithResolvedDepth(payload.material, resolved_depth),
            projected_triangle,
            payload.gouraud_colors,
            resolved_vertex_depths,
            gouraud_setup,
            face_normal_camera,
        );
    }
}

const ChunkCompileCtx = struct {
    commands: []const DrawPacket align(64),
    base_index: usize,
    chunk_draw_list: *direct_draw_list.DrawList,
    projector: Projector,
};

fn compileChunkJob(ctx_ptr: *anyopaque) void {
    const ctx: *ChunkCompileCtx = @ptrCast(@alignCast(ctx_ptr));
    compileTrianglesOnlyToDrawListShifted(ctx.commands, ctx.base_index, ctx.chunk_draw_list, ctx.projector) catch {};
}

fn noopCompileJob(_: *anyopaque) void {}

fn compileTrianglesOnlyParallel(
    commands: []const DrawPacket,
    draw_list: *direct_draw_list.DrawList,
    projector: Projector,
    job_sys: *JobSystem,
    chunk_draw_lists: []direct_draw_list.DrawList,
) !void {
    const worker_count = @max(@as(usize, job_sys.worker_count), 1);
    const chunk_count = @min(@min(worker_count + 1, chunk_draw_lists.len), commands.len);
    const base_chunk = commands.len / chunk_count;
    const remainder = commands.len % chunk_count;

    var contexts: [64]ChunkCompileCtx = undefined;
    var jobs: [64]Job = undefined;
    var parent_job = Job.init(noopCompileJob, @ptrFromInt(1), null);

    var main_chunk: usize = 0;
    var dispatched: usize = 0;
    var cursor: usize = 0;

    for (0..chunk_count) |chunk_index| {
        const size = base_chunk + (if (chunk_index < remainder) @as(usize, 1) else 0);
        const end = cursor + size;
        chunk_draw_lists[chunk_index].clearRetainingCapacity();
        try chunk_draw_lists[chunk_index].ensureCommandCapacity(size);
        contexts[chunk_index] = .{
            .commands = commands[cursor..end],
            .base_index = cursor,
            .chunk_draw_list = &chunk_draw_lists[chunk_index],
            .projector = projector,
        };
        if (dispatched == 0) {
            main_chunk = chunk_index;
        } else {
            jobs[dispatched - 1] = Job.init(compileChunkJob, @ptrCast(&contexts[chunk_index]), &parent_job);
            if (!job_sys.submitJobWithClass(&jobs[dispatched - 1], .high)) {
                compileChunkJob(@ptrCast(&contexts[chunk_index]));
            }
        }
        dispatched += 1;
        cursor = end;
    }

    compileChunkJob(@ptrCast(&contexts[main_chunk]));
    parent_job.complete();
    job_sys.waitFor(&parent_job);

    // Concatenate chunk outputs into the caller's draw_list in their
    // ORIGINAL order so depth sort keys remain stable. The chunks were
    // dispatched contiguously over `commands`, so concatenating them in
    // chunk_index order preserves submission order — same result as
    // the serial path would produce.
    for (0..chunk_count) |chunk_index| {
        const chunk = &chunk_draw_lists[chunk_index];
        try draw_list.commands.appendSlice(draw_list.allocator, chunk.commands.items);
        try draw_list.command_bounds.appendSlice(draw_list.allocator, chunk.command_bounds.items);
        try draw_list.prepared_gouraud.appendSlice(draw_list.allocator, chunk.prepared_gouraud.items);
    }
}

fn compileTrianglesOnlyToDrawListShifted(
    commands: []const DrawPacket,
    base_index: usize,
    draw_list: *direct_draw_list.DrawList,
    projector: Projector,
) !void {
    // Batched projection: process TRI_BATCH triangles per iteration =
    // 3*TRI_BATCH vertices in one SIMD-friendly buffer, then per-
    // triangle finalize. TRI_BATCH is sized to the target's native
    // SIMD width (4/8/16 lanes) so 3 SIMD iterations cover the batch
    // with no scalar tail inside projectPointsMasked.
    const TRI_BATCH: usize = @import("../../core/cpu_features.zig").SIMD_F32_LANES;
    var batch_pts: [TRI_BATCH * 3]math.Vec3 = undefined;
    var batch_screen: [TRI_BATCH * 3]direct_primitives.Point2i = undefined;
    var batch_valid: [TRI_BATCH * 3]bool = undefined;

    var i: usize = 0;
    while (i + TRI_BATCH <= commands.len) : (i += TRI_BATCH) {
        // 1. Backface cull and gather vertices.
        var tri_alive: [TRI_BATCH]bool = undefined;
        inline for (0..TRI_BATCH) |t| {
            const payload = commands[i + t].triangle;
            const passes_backface = !payload.material.cull_backfaces or
                worldTriangleFrontFacing(payload.triangle, projector.camera.position);
            tri_alive[t] = passes_backface;
            batch_pts[t * 3 + 0] = payload.triangle.a;
            batch_pts[t * 3 + 1] = payload.triangle.b;
            batch_pts[t * 3 + 2] = payload.triangle.c;
        }

        // 2. SIMD-project all 3*TRI_BATCH vertices in one call.
        projector.projectPointsMasked(&batch_pts, &batch_screen, &batch_valid);

        // 3. Per-triangle finalize: needs all 3 vertices valid + non-
        //    degenerate + then write the packet. Runtime for so we
        //    can `continue` (inline-for requires comptime control flow).
        var t: usize = 0;
        while (t < TRI_BATCH) : (t += 1) {
            if (!tri_alive[t]) continue;
            if (!batch_valid[t * 3 + 0] or !batch_valid[t * 3 + 1] or !batch_valid[t * 3 + 2]) continue;
            const projected_triangle: direct_primitives.Triangle2i = .{
                .a = batch_screen[t * 3 + 0],
                .b = batch_screen[t * 3 + 1],
                .c = batch_screen[t * 3 + 2],
            };
            if (signedArea2(projected_triangle.a, projected_triangle.b, projected_triangle.c) == 0) continue;
            const payload = commands[i + t].triangle;
            const packet_index = base_index + i + t;
            const resolved_vertex_depths = if (payload.material.depth != null)
                projector.triangleVertexDepths(payload.triangle)
            else
                null;
            const resolved_depth = if (resolved_vertex_depths) |depths|
                (depths[0] + depths[1] + depths[2]) / 3.0
            else
                null;
            const gouraud_setup = if (resolved_vertex_depths == null)
                if (payload.gouraud_colors) |vertex_colors|
                    direct_primitives.prepareGouraudTriangle(projected_triangle, vertex_colors)
                else
                    null
            else
                null;
            const face_normal_camera: ?math.Vec3 = if (@import("../../core/app_config.zig").DEFERRED_SHADING_ENABLED)
                computeCameraSpaceFaceNormal(payload.triangle, payload.vertex_normals, &projector.basis)
            else
                null;
            draw_list.appendProjectedTriangleAssumeCapacity(
                makeTriangleSortKey(resolved_depth, packet_index),
                surfaceWithResolvedDepth(payload.material, resolved_depth),
                projected_triangle,
                payload.gouraud_colors,
                resolved_vertex_depths,
                gouraud_setup,
                face_normal_camera,
            );
        }
    }

    // Scalar tail for the remaining 0..TRI_BATCH-1 triangles.
    while (i < commands.len) : (i += 1) {
        const command = commands[i];
        const packet_index = base_index + i;
        const payload = command.triangle;
        if (payload.material.cull_backfaces and !worldTriangleFrontFacing(payload.triangle, projector.camera.position)) continue;
        var projected: [3]direct_primitives.Point2i = undefined;
        if (!projector.projectTriangle(payload.triangle.a, payload.triangle.b, payload.triangle.c, &projected)) continue;
        if (signedArea2(projected[0], projected[1], projected[2]) == 0) continue;
        const resolved_vertex_depths = if (payload.material.depth != null) projector.triangleVertexDepths(payload.triangle) else null;
        const resolved_depth = if (resolved_vertex_depths) |depths|
            (depths[0] + depths[1] + depths[2]) / 3.0
        else
            null;
        const projected_triangle: direct_primitives.Triangle2i = .{ .a = projected[0], .b = projected[1], .c = projected[2] };
        const gouraud_setup = if (resolved_vertex_depths == null)
            if (payload.gouraud_colors) |vertex_colors|
                direct_primitives.prepareGouraudTriangle(projected_triangle, vertex_colors)
            else
                null
        else
            null;
        const face_normal_camera: ?math.Vec3 = if (@import("../../core/app_config.zig").DEFERRED_SHADING_ENABLED)
            computeCameraSpaceFaceNormal(payload.triangle, payload.vertex_normals, &projector.basis)
        else
            null;
        draw_list.appendProjectedTriangleAssumeCapacity(
            makeTriangleSortKey(resolved_depth, packet_index),
            surfaceWithResolvedDepth(payload.material, resolved_depth),
            projected_triangle,
            payload.gouraud_colors,
            resolved_vertex_depths,
            gouraud_setup,
            face_normal_camera,
        );
    }
}

inline fn surfaceWithResolvedDepth(material: SurfaceMaterial, resolved_depth: ?f32) SurfaceMaterial {
    var resolved = material;
    resolved.depth = if (material.depth != null) resolved_depth else null;
    return resolved;
}

inline fn makeSortKey(command: DrawPacket, packet_index: usize) u64 {
    const depth_component: u32 = switch (command) {
        .line => |payload| encodeDepth(payload.material.depth),
        .triangle => |payload| encodeDepth(payload.material.depth),
        .polygon => |payload| encodeDepth(payload.material.depth),
        .circle => |payload| encodeDepth(payload.material.depth),
    };
    return (@as(u64, depth_component) << 32) | @as(u64, @intCast(packet_index));
}

inline fn makeTriangleSortKey(depth: ?f32, packet_index: usize) u64 {
    return (@as(u64, encodeDepth(depth)) << 32) | @as(u64, @intCast(packet_index));
}

inline fn makeLineSortKey(depth: ?f32, packet_index: usize) u64 {
    return (@as(u64, encodeDepth(depth)) << 32) | @as(u64, @intCast(packet_index));
}

inline fn makeSurfaceSortKey(depth: ?f32, packet_index: usize) u64 {
    return (@as(u64, encodeDepth(depth)) << 32) | @as(u64, @intCast(packet_index));
}

inline fn computeCameraSpaceFaceNormal(
    triangle: WorldTriangle,
    vertex_normals: ?[3]math.Vec3,
    basis: *const camera_controller.ViewBasis,
) math.Vec3 {
    const world_normal = if (vertex_normals) |vn| blk: {
        // Use the average vertex normal so the G-buffer carries the
        // shading-time direction (smooth-shaded surfaces).
        const sum = math.Vec3.add(math.Vec3.add(vn[0], vn[1]), vn[2]);
        const len_sq = math.Vec3.dot(sum, sum);
        if (len_sq <= 1e-8) break :blk geometricFaceNormal(triangle);
        break :blk math.Vec3.scale(sum, 1.0 / @sqrt(len_sq));
    } else geometricFaceNormal(triangle);
    // basis is right/up/forward in world space; produce camera-space
    // normal as (n·right, n·up, n·forward).
    return .{
        .x = math.Vec3.dot(world_normal, basis.right),
        .y = math.Vec3.dot(world_normal, basis.up),
        .z = math.Vec3.dot(world_normal, basis.forward),
    };
}

inline fn geometricFaceNormal(triangle: WorldTriangle) math.Vec3 {
    const edge_ab = math.Vec3.sub(triangle.b, triangle.a);
    const edge_ac = math.Vec3.sub(triangle.c, triangle.a);
    const n = math.Vec3.cross(edge_ab, edge_ac);
    const len_sq = math.Vec3.dot(n, n);
    if (len_sq <= 1e-8) return math.Vec3.new(0.0, 0.0, 1.0);
    return math.Vec3.scale(n, 1.0 / @sqrt(len_sq));
}

inline fn worldTriangleFrontFacing(triangle: WorldTriangle, camera_position: math.Vec3) bool {
    // 4-lane SIMD packed-Vec3 (xyz0). Compiler emits one vsubps, one
    // shuffle pair for cross, one vmulps + vhaddps for dot. Same code
    // SSE/AVX/AVX-512/NEON/SVE — width fixed at 4 since this is a
    // 3-element op.
    const V4 = @Vector(4, f32);
    const a: V4 = .{ triangle.a.x, triangle.a.y, triangle.a.z, 0.0 };
    const b: V4 = .{ triangle.b.x, triangle.b.y, triangle.b.z, 0.0 };
    const c: V4 = .{ triangle.c.x, triangle.c.y, triangle.c.z, 0.0 };
    const cp: V4 = .{ camera_position.x, camera_position.y, camera_position.z, 0.0 };
    const e1 = b - a;
    const e2 = c - a;
    // cross(e1, e2): n.x = e1.y*e2.z - e1.z*e2.y, etc. Done via two
    // shuffled multiplies.
    const e1_yzx: V4 = .{ e1[1], e1[2], e1[0], 0.0 };
    const e2_yzx: V4 = .{ e2[1], e2[2], e2[0], 0.0 };
    const n_zxy = e1 * e2_yzx - e2 * e1_yzx;
    const n: V4 = .{ n_zxy[1], n_zxy[2], n_zxy[0], 0.0 };
    const view = cp - a;
    const dot = @reduce(.Add, n * view);
    return dot > 1e-5;
}

fn worldPolygonFrontFacing(points: []const math.Vec3, camera_position: math.Vec3) bool {
    if (points.len < 3) return false;
    return worldTriangleFrontFacing(.{
        .a = points[0],
        .b = points[1],
        .c = points[2],
    }, camera_position);
}

fn projectedPolygonSignedArea2(points: []const direct_primitives.Point2i) i64 {
    if (points.len < 3) return 0;
    var area2: i64 = 0;
    const lanes = comptime std.simd.suggestVectorLength(i64) orelse 0;
    const edge_count = points.len - 1;
    if (lanes >= 4 and edge_count >= lanes) {
        const Vec = @Vector(lanes, i64);
        var index: usize = 0;
        var cur_xs: [lanes]i64 = undefined;
        var cur_ys: [lanes]i64 = undefined;
        var next_xs: [lanes]i64 = undefined;
        var next_ys: [lanes]i64 = undefined;

        while (index + lanes <= edge_count) : (index += lanes) {
            inline for (0..lanes) |lane| {
                const current = points[index + lane];
                const next = points[index + lane + 1];
                cur_xs[lane] = current.x;
                cur_ys[lane] = current.y;
                next_xs[lane] = next.x;
                next_ys[lane] = next.y;
            }
            const cur_x: Vec = @as(Vec, @bitCast(cur_xs));
            const cur_y: Vec = @as(Vec, @bitCast(cur_ys));
            const next_x: Vec = @as(Vec, @bitCast(next_xs));
            const next_y: Vec = @as(Vec, @bitCast(next_ys));
            const cross = cur_x * next_y - next_x * cur_y;
            inline for (0..lanes) |lane| area2 += cross[lane];
        }

        for (index..edge_count) |tail_index| {
            const point = points[tail_index];
            const next = points[tail_index + 1];
            area2 += @as(i64, point.x) * @as(i64, next.y) - @as(i64, next.x) * @as(i64, point.y);
        }
        const last = points[points.len - 1];
        const first = points[0];
        area2 += @as(i64, last.x) * @as(i64, first.y) - @as(i64, first.x) * @as(i64, last.y);
        return area2;
    }

    for (0..edge_count) |index| {
        const point = points[index];
        const next = points[index + 1];
        area2 += @as(i64, point.x) * @as(i64, next.y) - @as(i64, next.x) * @as(i64, point.y);
    }
    const last = points[points.len - 1];
    const first = points[0];
    area2 += @as(i64, last.x) * @as(i64, first.y) - @as(i64, first.x) * @as(i64, last.y);
    return area2;
}

inline fn signedArea2(a: direct_primitives.Point2i, b: direct_primitives.Point2i, c: direct_primitives.Point2i) i64 {
    return (@as(i64, b.x) - @as(i64, a.x)) * (@as(i64, c.y) - @as(i64, a.y)) -
        (@as(i64, b.y) - @as(i64, a.y)) * (@as(i64, c.x) - @as(i64, a.x));
}

inline fn encodeDepth(depth: ?f32) u32 {
    if (depth == null) return 0;
    const scaled = std.math.clamp(depth.?, 0.0, 65535.0) * 1024.0;
    return @intFromFloat(scaled);
}

test "compile world triangle into draw list" {
    var batch = PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    var draw_list = direct_draw_list.DrawList.init(std.testing.allocator);
    defer draw_list.deinit();

    try batch.appendTriangle(.{
        .a = math.Vec3.new(0.0, 0.5, 0.0),
        .b = math.Vec3.new(-0.5, -0.5, 0.0),
        .c = math.Vec3.new(0.5, -0.5, 0.0),
    }, .{ .fill_color = 0xFFFFFFFF });

    try compileToDrawList(&batch, &draw_list, .{
        .position = math.Vec3.new(0.0, 0.0, -3.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 60.0,
    }, 1280, 720);

    try std.testing.expectEqual(@as(usize, 1), draw_list.items().len);
    try std.testing.expect(draw_list.items()[0].payload == .triangle);
}

test "compile culls backfacing world triangle for depth geometry" {
    var batch = PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    var draw_list = direct_draw_list.DrawList.init(std.testing.allocator);
    defer draw_list.deinit();

    try batch.appendTriangle(.{
        .a = math.Vec3.new(0.0, 0.5, 0.0),
        .b = math.Vec3.new(-0.5, -0.5, 0.0),
        .c = math.Vec3.new(0.5, -0.5, 0.0),
    }, .{ .fill_color = 0xFFFFFFFF, .depth = 1.0 });

    try compileToDrawList(&batch, &draw_list, .{
        .position = math.Vec3.new(0.0, 0.0, -3.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 60.0,
    }, 1280, 720);

    try std.testing.expectEqual(@as(usize, 0), draw_list.items().len);
}

test "compile keeps frontfacing world triangle for depth geometry" {
    var batch = PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    var draw_list = direct_draw_list.DrawList.init(std.testing.allocator);
    defer draw_list.deinit();

    try batch.appendTriangle(.{
        .a = math.Vec3.new(0.0, 0.5, 0.0),
        .b = math.Vec3.new(0.5, -0.5, 0.0),
        .c = math.Vec3.new(-0.5, -0.5, 0.0),
    }, .{ .fill_color = 0xFFFFFFFF, .depth = 1.0 });

    try compileToDrawList(&batch, &draw_list, .{
        .position = math.Vec3.new(0.0, 0.0, -3.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 60.0,
    }, 1280, 720);

    try std.testing.expectEqual(@as(usize, 1), draw_list.items().len);
}

test "compile keeps depthless triangle regardless of world facing" {
    var batch = PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    var draw_list = direct_draw_list.DrawList.init(std.testing.allocator);
    defer draw_list.deinit();

    try batch.appendTriangle(.{
        .a = math.Vec3.new(0.0, 0.5, 0.0),
        .b = math.Vec3.new(0.5, -0.5, 0.0),
        .c = math.Vec3.new(-0.5, -0.5, 0.0),
    }, .{ .fill_color = 0xFFFFFFFF, .depth = null });

    try compileToDrawList(&batch, &draw_list, .{
        .position = math.Vec3.new(0.0, 0.0, -3.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 60.0,
    }, 1280, 720);

    try std.testing.expectEqual(@as(usize, 1), draw_list.items().len);
}

test "compile resolves geometric depth for mesh triangles" {
    var batch = PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    var draw_list = direct_draw_list.DrawList.init(std.testing.allocator);
    defer draw_list.deinit();

    try batch.appendTriangle(.{
        .a = math.Vec3.new(-0.5, 0.5, 2.0),
        .b = math.Vec3.new(0.5, 0.5, 2.0),
        .c = math.Vec3.new(0.0, -0.5, 2.0),
    }, .{ .fill_color = 0xFFFFFFFF, .depth = 1.0 });
    try batch.appendTriangle(.{
        .a = math.Vec3.new(-0.5, 0.5, 5.0),
        .b = math.Vec3.new(0.5, 0.5, 5.0),
        .c = math.Vec3.new(0.0, -0.5, 5.0),
    }, .{ .fill_color = 0xFFFFFFFF, .depth = 1.0 });

    try compileToDrawList(&batch, &draw_list, .{
        .position = math.Vec3.new(0.0, 0.0, 0.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 60.0,
    }, 1280, 720);

    try std.testing.expectEqual(@as(usize, 2), draw_list.items().len);
    const near_depth = draw_list.items()[0].material.surface.depth.?;
    const far_depth = draw_list.items()[1].material.surface.depth.?;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), near_depth, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), far_depth, 0.0001);
}
