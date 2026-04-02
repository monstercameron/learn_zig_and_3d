const std = @import("std");
const math = @import("../core/math.zig");
const job_system = @import("job_system");
const MeshModule = @import("core/mesh.zig");
const meshlet_builder = @import("core/meshlets/meshlet_builder.zig");
const direct_batch = @import("direct_batch.zig");

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
    for (mesh.meshlets, 0..) |*meshlet, meshlet_index| {
        if (meshletVisible(meshlet, instance.transform, camera)) {
            try out_visible.indices.append(out_visible.allocator, meshlet_index);
        }
    }
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

    const chunk_count = @min(visible.indices.items.len, @as(usize, @intCast(job_sys.?.worker_count + 1)));
    const chunk_batches = try allocator.alloc(direct_batch.PrimitiveBatch, chunk_count);
    defer {
        for (chunk_batches) |*chunk_batch| chunk_batch.deinit();
        allocator.free(chunk_batches);
    }
    const chunk_contexts = try allocator.alloc(MeshletChunkContext, chunk_count);
    defer allocator.free(chunk_contexts);
    const jobs = try allocator.alloc(Job, if (chunk_count > 0) chunk_count - 1 else 0);
    defer allocator.free(jobs);

    for (chunk_batches) |*chunk_batch| chunk_batch.* = direct_batch.PrimitiveBatch.init(allocator);

    const chunk_size = std.math.divCeil(usize, visible.indices.items.len, chunk_count) catch 1;
    var parent = Job.init(noopMeshletJob, @ptrFromInt(1), null);
    var main_chunk: usize = 0;
    var active_chunks: usize = 0;

    for (0..chunk_count) |chunk_index| {
        const start = chunk_index * chunk_size;
        if (start >= visible.indices.items.len) break;
        const end = @min(start + chunk_size, visible.indices.items.len);
        chunk_contexts[chunk_index] = .{
            .batch = &chunk_batches[chunk_index],
            .mesh = mesh,
            .visible_indices = visible.indices.items[start..end],
            .instance = instance,
        };
        if (active_chunks == 0) {
            main_chunk = chunk_index;
            active_chunks += 1;
            continue;
        }
        jobs[active_chunks - 1] = Job.init(meshletChunkJob, @ptrCast(&chunk_contexts[chunk_index]), &parent);
        if (!job_sys.?.submitJobWithClass(&jobs[active_chunks - 1], .high)) {
            meshletChunkJob(@ptrCast(&chunk_contexts[chunk_index]));
        }
        active_chunks += 1;
    }

    meshletChunkJob(@ptrCast(&chunk_contexts[main_chunk]));
    parent.complete();
    job_sys.?.waitFor(&parent);

    for (chunk_batches[0..active_chunks]) |*chunk_batch| {
        for (chunk_batch.items()) |packet| {
            try batch.append(packet);
        }
    }
}

fn meshletVisible(meshlet: *const Meshlet, transform: math.Mat4, camera: direct_batch.Camera) bool {
    const center = transform.mulVec3(meshlet.bounds_center);
    const relative = math.Vec3.sub(center, camera.position);
    const basis = @import("camera_controller.zig").computeViewBasis(camera.yaw, camera.pitch);
    const camera_z = math.Vec3.dot(relative, basis.forward);
    if (camera_z + meshlet.bounds_radius <= direct_batch.near_plane) return false;
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
