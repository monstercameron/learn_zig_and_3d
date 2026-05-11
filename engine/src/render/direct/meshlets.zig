const std = @import("std");
const math = @import("../../core/math.zig");
const job_system = @import("job_system");
const MeshModule = @import("../core/mesh.zig");
const meshlet_builder = @import("../core/meshlets/meshlet_builder.zig");
const direct_batch = @import("batch.zig");

const Job = job_system.Job;
const JobSystem = job_system.JobSystem;
pub const Mesh = MeshModule.Mesh;
pub const Meshlet = MeshModule.Meshlet;

pub const MeshletInstance = struct {
    transform: math.Mat4 = math.Mat4.identity(),
    material_override: ?direct_batch.SurfaceMaterial = null,
};

pub const VisibleMeshlets = struct {
    allocator: std.mem.Allocator,
    indices: std.ArrayListUnmanaged(usize) = .{},

    pub fn init(allocator: std.mem.Allocator) VisibleMeshlets {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VisibleMeshlets) void {
        self.indices.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *VisibleMeshlets) void {
        self.indices.clearRetainingCapacity();
    }

    pub fn ensureCapacity(self: *VisibleMeshlets, count: usize) !void {
        try self.indices.ensureTotalCapacity(self.allocator, count);
    }
};

pub fn ensureMeshlets(mesh: *Mesh, allocator: std.mem.Allocator) !void {
    if (mesh.meshlets.len != 0) return;
    try meshlet_builder.buildMeshlets(allocator, mesh, .{});
}

pub fn cullVisibleMeshlets(
    out_visible: *VisibleMeshlets,
    mesh: *const Mesh,
    instance: MeshletInstance,
    camera: direct_batch.Camera,
) !void {
    out_visible.clearRetainingCapacity();
    try out_visible.ensureCapacity(mesh.meshlets.len);
    const basis = @import("../camera/controller.zig").computeViewBasis(camera.yaw, camera.pitch);
    const tan_v = std.math.tan(std.math.degreesToRadians(camera.fov_deg) * 0.5);
    const tan_h = camera.aspect * tan_v;
    const sec_v = @sqrt(1.0 + tan_v * tan_v);
    const sec_h = @sqrt(1.0 + tan_h * tan_h);
    const frustum = FrustumScalars{
        .basis = basis,
        .tan_v = tan_v,
        .tan_h = tan_h,
        .sec_v = sec_v,
        .sec_h = sec_h,
    };
    out_visible.indices.items.len = mesh.meshlets.len;
    var write_index: usize = 0;
    for (mesh.meshlets, 0..) |*meshlet, meshlet_index| {
        if (meshletVisibleFast(meshlet, instance.transform, camera.position, frustum)) {
            out_visible.indices.items[write_index] = meshlet_index;
            write_index += 1;
        }
    }
    out_visible.indices.items.len = write_index;
}

/// Parallel variant — splits the meshlet array across worker chunks,
/// each chunk produces its own visible-index list, merged via
/// appendSlice. Used when the job_system is available and there are
/// enough meshlets to amortise the overhead (~256 meshlets).
pub fn cullVisibleMeshletsParallel(
    out_visible: *VisibleMeshlets,
    mesh: *const Mesh,
    instance: MeshletInstance,
    camera: direct_batch.Camera,
    job_sys: ?*JobSystem,
) !void {
    const PARALLEL_THRESHOLD: usize = 256;
    if (job_sys == null or mesh.meshlets.len < PARALLEL_THRESHOLD or job_sys.?.worker_count <= 1) {
        return cullVisibleMeshlets(out_visible, mesh, instance, camera);
    }
    out_visible.clearRetainingCapacity();
    try out_visible.ensureCapacity(mesh.meshlets.len);

    const basis = @import("../camera/controller.zig").computeViewBasis(camera.yaw, camera.pitch);
    const tan_v = std.math.tan(std.math.degreesToRadians(camera.fov_deg) * 0.5);
    const tan_h = camera.aspect * tan_v;
    const sec_v = @sqrt(1.0 + tan_v * tan_v);
    const sec_h = @sqrt(1.0 + tan_h * tan_h);
    const frustum = FrustumScalars{
        .basis = basis,
        .tan_v = tan_v,
        .tan_h = tan_h,
        .sec_v = sec_v,
        .sec_h = sec_h,
    };

    const js = job_sys.?;
    const worker_count = @as(usize, js.worker_count);
    const chunk_count = @min(@min(worker_count + 1, 32), mesh.meshlets.len);
    const base_size = mesh.meshlets.len / chunk_count;
    const remainder = mesh.meshlets.len % chunk_count;

    // Each worker writes to its own scratch slice; merge at end.
    var scratch: [32 * 1024]usize = undefined;
    var scratch_offsets: [33]usize = undefined; // chunk_count + 1
    scratch_offsets[0] = 0;
    var contexts: [32]MeshletCullCtx = undefined;
    var jobs: [32]Job = undefined;

    var cursor: usize = 0;
    for (0..chunk_count) |chunk_index| {
        const size = base_size + (if (chunk_index < remainder) @as(usize, 1) else 0);
        const end = cursor + size;
        // Reserve scratch range; max indices we can produce equals size.
        const out_start = scratch_offsets[chunk_index];
        // We over-reserve by `size`; will compact later when we know
        // the actual valid count per chunk.
        scratch_offsets[chunk_index + 1] = out_start + size;
        if (scratch_offsets[chunk_index + 1] > scratch.len) {
            // Bail to serial path if the mesh has more meshlets than
            // our stack scratch can hold.
            return cullVisibleMeshlets(out_visible, mesh, instance, camera);
        }
        contexts[chunk_index] = .{
            .meshlets = mesh.meshlets[cursor..end],
            .index_offset = cursor,
            .transform = instance.transform,
            .camera_pos = camera.position,
            .frustum = frustum,
            .out_slice = scratch[out_start..scratch_offsets[chunk_index + 1]],
            .written = 0,
        };
        cursor = end;
    }

    var parent = Job.init(noopMeshletJob, @ptrFromInt(1), null);
    var main_chunk: usize = 0;
    var dispatched: usize = 0;
    for (0..chunk_count) |chunk_index| {
        if (dispatched == 0) {
            main_chunk = chunk_index;
        } else {
            jobs[dispatched - 1] = Job.init(meshletCullJob, @ptrCast(&contexts[chunk_index]), &parent);
            if (!js.submitJobWithClass(&jobs[dispatched - 1], .high)) {
                meshletCullJob(@ptrCast(&contexts[chunk_index]));
            }
        }
        dispatched += 1;
    }
    meshletCullJob(@ptrCast(&contexts[main_chunk]));
    parent.complete();
    js.waitFor(&parent);

    // Compact: append each chunk's written prefix into the output.
    out_visible.indices.items.len = 0;
    for (0..chunk_count) |chunk_index| {
        const ctx = &contexts[chunk_index];
        try out_visible.indices.appendSlice(out_visible.allocator, ctx.out_slice[0..ctx.written]);
    }
}

const MeshletCullCtx = struct {
    meshlets: []const Meshlet align(64),
    index_offset: usize,
    transform: math.Mat4,
    camera_pos: math.Vec3,
    frustum: FrustumScalars,
    out_slice: []usize,
    written: usize,
};

fn meshletCullJob(ctx_ptr: *anyopaque) void {
    const ctx: *MeshletCullCtx = @ptrCast(@alignCast(ctx_ptr));
    var w: usize = 0;
    for (ctx.meshlets, 0..) |*meshlet, local_index| {
        if (meshletVisibleFast(meshlet, ctx.transform, ctx.camera_pos, ctx.frustum)) {
            ctx.out_slice[w] = ctx.index_offset + local_index;
            w += 1;
        }
    }
    ctx.written = w;
}

const FrustumScalars = struct {
    basis: @import("../camera/controller.zig").ViewBasis,
    tan_v: f32,
    tan_h: f32,
    sec_v: f32,
    sec_h: f32,
};

inline fn meshletVisibleFast(
    meshlet: *const Meshlet,
    transform: math.Mat4,
    camera_pos: math.Vec3,
    frustum: FrustumScalars,
) bool {
    const center_world = transform.mulVec3(meshlet.bounds_center);
    const relative = math.Vec3.sub(center_world, camera_pos);
    const cx = math.Vec3.dot(relative, frustum.basis.right);
    const cy = math.Vec3.dot(relative, frustum.basis.up);
    const cz = math.Vec3.dot(relative, frustum.basis.forward);
    const r = meshlet.bounds_radius;
    if (cz + r <= direct_batch.near_plane) return false;
    if (cx - frustum.tan_h * cz > r * frustum.sec_h) return false;
    if (-cx - frustum.tan_h * cz > r * frustum.sec_h) return false;
    if (cy - frustum.tan_v * cz > r * frustum.sec_v) return false;
    if (-cy - frustum.tan_v * cz > r * frustum.sec_v) return false;
    return true;
}

pub fn appendVisibleMeshletsToBatch(
    batch: *direct_batch.PrimitiveBatch,
    mesh: *const Mesh,
    visible: *const VisibleMeshlets,
    instance: MeshletInstance,
) !void {
    for (visible.indices.items) |meshlet_index| {
        try appendMeshlet(batch, mesh, &mesh.meshlets[meshlet_index], instance);
    }
}

pub fn appendVisibleMeshletsToBatchParallel(
    batch: *direct_batch.PrimitiveBatch,
    mesh: *const Mesh,
    visible: *const VisibleMeshlets,
    instance: MeshletInstance,
    allocator: std.mem.Allocator,
    job_sys: ?*JobSystem,
) !void {
    if (job_sys == null or visible.indices.items.len <= 1) {
        return appendVisibleMeshletsToBatch(batch, mesh, visible, instance);
    }

    // Direct-write parallel scheme: workers fill pre-reserved slots in
    // the main batch instead of producing per-chunk batches that need
    // a 300 MB serial memcpy merge. Each chunk owns a contiguous range
    // [start_index .. start_index+chunk_total_tris) in batch.commands.
    const chunk_count = @min(visible.indices.items.len, @as(usize, @intCast(job_sys.?.worker_count + 1)));
    const chunk_size = std.math.divCeil(usize, visible.indices.items.len, chunk_count) catch 1;

    // Per-chunk triangle counts (prefix-summed to give write offsets).
    var chunk_tri_counts: [128]usize = undefined;
    if (chunk_count > chunk_tri_counts.len) return appendVisibleMeshletsToBatch(batch, mesh, visible, instance);

    var total_tris: usize = 0;
    for (0..chunk_count) |chunk_index| {
        const start = chunk_index * chunk_size;
        if (start >= visible.indices.items.len) {
            chunk_tri_counts[chunk_index] = 0;
            continue;
        }
        const end = @min(start + chunk_size, visible.indices.items.len);
        const tris = estimateVisiblePrimitiveCount(mesh, visible.indices.items[start..end]);
        chunk_tri_counts[chunk_index] = tris;
        total_tris += tris;
    }

    // Pre-reserve the destination and bump items.len up-front; each
    // worker writes by index, never touching `len` (which we know
    // exactly).
    const base_index = batch.commands.items.len;
    try batch.commands.ensureUnusedCapacity(batch.allocator, total_tris);
    batch.commands.items.len = base_index + total_tris;

    const chunk_contexts = try allocator.alloc(DirectMeshletChunkContext, chunk_count);
    defer allocator.free(chunk_contexts);
    const jobs = try allocator.alloc(Job, if (chunk_count > 0) chunk_count - 1 else 0);
    defer allocator.free(jobs);

    var parent = Job.init(noopMeshletJob, @ptrFromInt(1), null);
    var main_chunk: usize = 0;
    var active_chunks: usize = 0;
    var write_cursor = base_index;
    const identity_transform = isIdentityTransformLocal(instance.transform);

    for (0..chunk_count) |chunk_index| {
        const start = chunk_index * chunk_size;
        if (start >= visible.indices.items.len) break;
        const end = @min(start + chunk_size, visible.indices.items.len);
        const tris = chunk_tri_counts[chunk_index];
        chunk_contexts[chunk_index] = .{
            .out_slice = batch.commands.items[write_cursor .. write_cursor + tris],
            .mesh = mesh,
            .visible_indices = visible.indices.items[start..end],
            .instance = instance,
            .identity_transform = identity_transform,
        };
        write_cursor += tris;
        if (active_chunks == 0) {
            main_chunk = chunk_index;
            active_chunks += 1;
            continue;
        }
        jobs[active_chunks - 1] = Job.init(meshletChunkDirectJob, @ptrCast(&chunk_contexts[chunk_index]), &parent);
        if (!job_sys.?.submitJobWithClass(&jobs[active_chunks - 1], .high)) {
            meshletChunkDirectJob(@ptrCast(&chunk_contexts[chunk_index]));
        }
        active_chunks += 1;
    }

    meshletChunkDirectJob(@ptrCast(&chunk_contexts[main_chunk]));
    parent.complete();
    job_sys.?.waitFor(&parent);
}

const DirectMeshletChunkContext = struct {
    out_slice: []direct_batch.DrawPacket align(64),
    mesh: *const Mesh,
    visible_indices: []const usize,
    instance: MeshletInstance,
    identity_transform: bool,
};

fn meshletChunkDirectJob(ctx_ptr: *anyopaque) void {
    const ctx: *DirectMeshletChunkContext = @ptrCast(@alignCast(ctx_ptr));
    var write_index: usize = 0;
    for (ctx.visible_indices) |meshlet_index| {
        appendMeshletDirect(
            ctx.out_slice,
            &write_index,
            ctx.mesh,
            &ctx.mesh.meshlets[meshlet_index],
            ctx.instance,
            ctx.identity_transform,
        );
    }
}

fn appendMeshletDirect(
    out_slice: []direct_batch.DrawPacket,
    write_index: *usize,
    mesh: *const Mesh,
    meshlet: *const Meshlet,
    instance: MeshletInstance,
    identity: bool,
) void {
    for (mesh.meshletPrimitiveSlice(meshlet)) |primitive| {
        const va = mesh.vertices[mesh.meshletGlobalVertexIndex(meshlet, primitive.local_v0)];
        const vb = mesh.vertices[mesh.meshletGlobalVertexIndex(meshlet, primitive.local_v1)];
        const vc = mesh.vertices[mesh.meshletGlobalVertexIndex(meshlet, primitive.local_v2)];
        const a = if (identity) va else instance.transform.mulVec3(va);
        const b = if (identity) vb else instance.transform.mulVec3(vb);
        const c = if (identity) vc else instance.transform.mulVec3(vc);
        const tri = mesh.triangles[primitive.triangle_index];
        const material = instance.material_override orelse direct_batch.SurfaceMaterial{
            .fill_color = tri.base_color,
            .outline_color = 0xFF101820,
            .depth = 1.0,
        };
        out_slice[write_index.*] = .{ .triangle = .{
            .triangle = .{ .a = a, .b = b, .c = c },
            .material = material,
        } };
        write_index.* += 1;
    }
}

inline fn isIdentityTransformLocal(transform: math.Mat4) bool {
    return std.mem.eql(f32, transform.data[0..], math.Mat4.identity().data[0..]);
}

fn estimateVisiblePrimitiveCount(mesh: *const Mesh, visible_indices: []const usize) usize {
    var count: usize = 0;
    for (visible_indices) |meshlet_index| {
        count += mesh.meshletPrimitiveSlice(&mesh.meshlets[meshlet_index]).len;
    }
    return count;
}

fn meshletVisible(meshlet: *const Meshlet, transform: math.Mat4, camera: direct_batch.Camera) bool {
    // 6-plane view-frustum sphere reject. Reduces the per-frame
    // projection cost from "every triangle" to "every triangle whose
    // meshlet bounding sphere actually intersects the view volume" —
    // huge for million-triangle scenes (acura/wolf) where most
    // meshlets are off-screen on any given frame (ROADMAP §H7 next
    // step). We work in camera space so plane tests are cheap.
    const center_world = transform.mulVec3(meshlet.bounds_center);
    const relative = math.Vec3.sub(center_world, camera.position);
    const basis = @import("../camera/controller.zig").computeViewBasis(camera.yaw, camera.pitch);
    const cx = math.Vec3.dot(relative, basis.right);
    const cy = math.Vec3.dot(relative, basis.up);
    const cz = math.Vec3.dot(relative, basis.forward);
    const r = meshlet.bounds_radius;

    // Near plane reject (only the near-side test bounds depth; we don't
    // reject for "too far" since the project pipeline already handles
    // perspective-clipped depths).
    if (cz + r <= direct_batch.near_plane) return false;

    const tan_v = std.math.tan(std.math.degreesToRadians(camera.fov_deg) * 0.5);
    const tan_h = camera.aspect * tan_v;
    // For each side plane, signed distance from point to plane (plane
    // passing through origin, normal pointing into the frustum) is
    // (tan * cz ± component) / sqrt(1 + tan²). Sphere is fully outside
    // when that distance is more negative than -r.
    const sec_v = @sqrt(1.0 + tan_v * tan_v);
    const sec_h = @sqrt(1.0 + tan_h * tan_h);
    if (cx - tan_h * cz > r * sec_h) return false; // right side
    if (-cx - tan_h * cz > r * sec_h) return false; // left side
    if (cy - tan_v * cz > r * sec_v) return false; // top
    if (-cy - tan_v * cz > r * sec_v) return false; // bottom
    return true;
}

fn appendMeshlet(
    batch: *direct_batch.PrimitiveBatch,
    mesh: *const Mesh,
    meshlet: *const Meshlet,
    instance: MeshletInstance,
) !void {
    for (mesh.meshletPrimitiveSlice(meshlet)) |primitive| {
        const a = instance.transform.mulVec3(mesh.vertices[mesh.meshletGlobalVertexIndex(meshlet, primitive.local_v0)]);
        const b = instance.transform.mulVec3(mesh.vertices[mesh.meshletGlobalVertexIndex(meshlet, primitive.local_v1)]);
        const c = instance.transform.mulVec3(mesh.vertices[mesh.meshletGlobalVertexIndex(meshlet, primitive.local_v2)]);
        const tri = mesh.triangles[primitive.triangle_index];
        try batch.appendTriangle(.{ .a = a, .b = b, .c = c }, instance.material_override orelse .{
            .fill_color = tri.base_color,
            .outline_color = 0xFF101820,
            .depth = 1.0,
        });
    }
}

const MeshletChunkContext = struct {
    batch: *direct_batch.PrimitiveBatch,
    mesh: *const Mesh,
    visible_indices: []const usize,
    instance: MeshletInstance,
};

fn noopMeshletJob(_: *anyopaque) void {}

fn meshletChunkJob(ctx_ptr: *anyopaque) void {
    const ctx: *MeshletChunkContext = @ptrCast(@alignCast(ctx_ptr));
    for (ctx.visible_indices) |meshlet_index| {
        appendMeshlet(ctx.batch, ctx.mesh, &ctx.mesh.meshlets[meshlet_index], ctx.instance) catch {};
    }
}

test "meshlet culling returns visible indices for front-facing cube" {
    var mesh = try Mesh.cube(std.testing.allocator);
    defer mesh.deinit();
    try ensureMeshlets(&mesh, std.testing.allocator);

    var visible = VisibleMeshlets.init(std.testing.allocator);
    defer visible.deinit();
    try cullVisibleMeshlets(&visible, &mesh, .{
        .transform = math.Mat4.translate(0.0, 0.0, 4.0),
    }, .{
        .position = math.Vec3.new(0.0, 0.0, -3.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 60.0,
    });

    try std.testing.expect(visible.indices.items.len > 0);
}

test "meshlet parallel append matches serial packet count" {
    var mesh = try Mesh.cube(std.testing.allocator);
    defer mesh.deinit();
    try ensureMeshlets(&mesh, std.testing.allocator);
    var visible = VisibleMeshlets.init(std.testing.allocator);
    defer visible.deinit();
    try cullVisibleMeshlets(&visible, &mesh, .{
        .transform = math.Mat4.translate(0.0, 0.0, 4.0),
    }, .{
        .position = math.Vec3.new(0.0, 0.0, -3.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .fov_deg = 60.0,
    });

    var serial = direct_batch.PrimitiveBatch.init(std.testing.allocator);
    defer serial.deinit();
    var parallel = direct_batch.PrimitiveBatch.init(std.testing.allocator);
    defer parallel.deinit();
    var js = try JobSystem.init(std.testing.allocator);
    defer js.deinit();

    try appendVisibleMeshletsToBatch(&serial, &mesh, &visible, .{
        .transform = math.Mat4.translate(0.0, 0.0, 4.0),
    });
    try appendVisibleMeshletsToBatchParallel(&parallel, &mesh, &visible, .{
        .transform = math.Mat4.translate(0.0, 0.0, 4.0),
    }, std.testing.allocator, js);

    try std.testing.expectEqual(serial.items().len, parallel.items().len);
}
