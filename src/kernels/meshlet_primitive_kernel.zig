const std = @import("std");
const compute = @import("compute.zig");
const math = @import("../math.zig");
const lighting = @import("../lighting.zig");
const meshlet = @import("meshlet_primitives.zig");

const PrimitiveFlags = meshlet.PrimitiveFlags;

const MeshletPrimitivePC = extern struct {
    camera_position: math.Vec3,
    _pad0: f32 = 0.0,
    basis_right: math.Vec3,
    _pad1: f32 = 0.0,
    basis_up: math.Vec3,
    _pad2: f32 = 0.0,
    basis_forward: math.Vec3,
    _pad3: f32 = 0.0,
    light_dir: math.Vec3,
    _pad4: f32 = 0.0,
    projection_center_x: f32,
    projection_center_y: f32,
    projection_scale_x: f32,
    projection_scale_y: f32,
    near_plane: f32,
    near_epsilon: f32,
    meshlet_count: u32,
    total_primitive_count: u32,
};

const TransformResult = struct {
    camera: math.Vec3,
    screen: [2]i32,
    front: bool,
};

fn loadPushConstants(ctx: *const compute.ComputeContext) ?*const MeshletPrimitivePC {
    const raw = ctx.push_constants orelse return null;
    if (raw.len < @sizeOf(MeshletPrimitivePC)) return null;
    const ptr = @as([*]const u8, raw.ptr);
    const aligned = @alignCast(@alignOf(MeshletPrimitivePC), ptr);
    return @as(*const MeshletPrimitivePC, @ptrCast(aligned));
}

fn transformVertex(pc: *const MeshletPrimitivePC, world_pos: math.Vec3) TransformResult {
    const relative = math.Vec3.sub(world_pos, pc.camera_position);
    const camera = math.Vec3.new(
        math.Vec3.dot(relative, pc.basis_right),
        math.Vec3.dot(relative, pc.basis_up),
        math.Vec3.dot(relative, pc.basis_forward),
    );

    var screen = [2]i32{ 0, 0 };
    if (camera.z > pc.near_epsilon) {
        const inv_z = 1.0 / camera.z;
        const ndc_x = camera.x * inv_z * pc.projection_scale_x;
        const ndc_y = camera.y * inv_z * pc.projection_scale_y;
        const sx = ndc_x * pc.projection_center_x + pc.projection_center_x;
        const sy = -ndc_y * pc.projection_center_y + pc.projection_center_y;
        screen = .{
            @as(i32, @intFromFloat(sx)),
            @as(i32, @intFromFloat(sy)),
        };
    }

    const front = camera.z >= pc.near_plane - pc.near_epsilon;
    return TransformResult{ .camera = camera, .screen = screen, .front = front };
}

fn computeNormalCamera(pc: *const MeshletPrimitivePC, normals: []const math.Vec3, triangle_index: usize, camera_positions: [3]math.Vec3) math.Vec3 {
    if (triangle_index < normals.len) {
        const n = normals[triangle_index];
        const transformed = math.Vec3.new(
            math.Vec3.dot(n, pc.basis_right),
            math.Vec3.dot(n, pc.basis_up),
            math.Vec3.dot(n, pc.basis_forward),
        );
        return math.Vec3.normalize(transformed);
    }

    const edge0 = math.Vec3.sub(camera_positions[1], camera_positions[0]);
    const edge1 = math.Vec3.sub(camera_positions[2], camera_positions[0]);
    return math.Vec3.normalize(math.Vec3.cross(edge0, edge1));
}

fn isBackface(normal_cam: math.Vec3, positions: [3]math.Vec3) bool {
    var centroid = math.Vec3.new(0.0, 0.0, 0.0);
    inline for (positions) |p| {
        centroid = math.Vec3.add(centroid, p);
    }
    centroid = math.Vec3.scale(centroid, 1.0 / 3.0);

    const view_dir = math.Vec3.scale(centroid, -1.0);
    const view_len = math.Vec3.length(view_dir);
    if (view_len < 1e-6) return false;

    const view_vector = math.Vec3.scale(view_dir, 1.0 / view_len);
    const view_dot = math.Vec3.dot(normal_cam, view_vector);
    return view_dot < -1e-4;
}

pub const MeshletPrimitiveKernel = struct {
    pub const group_size_x: u32 = 1;
    pub const group_size_y: u32 = 1;
    pub const SharedSize: usize = 0;

    pub fn main(ctx: *compute.ComputeContext) void {
        const pc = loadPushConstants(ctx) orelse return;
        const meshlet_index = ctx.global_id.x;
        if (meshlet_index >= pc.meshlet_count) return;

        const ro_buffers = ctx.ro_buffers orelse return;
        if (ro_buffers.len < 7) return;
        const descriptors = compute.asConstSlice(meshlet.MeshletDescriptor, ro_buffers[0]);
        if (meshlet_index >= descriptors.len) return;

        const triangle_indices = compute.asConstSlice(u32, ro_buffers[1]);
        const triangles = compute.asConstSlice(meshlet.MeshTriangle, ro_buffers[2]);
        const vertex_positions = compute.asConstSlice(math.Vec3, ro_buffers[3]);
        const triangle_normals = compute.asConstSlice(math.Vec3, ro_buffers[4]);
        const vertex_uvs = compute.asConstSlice(math.Vec2, ro_buffers[5]);
        const visibility = compute.asConstSlice(meshlet.MeshletVisibility, ro_buffers[6]);
        if (meshlet_index >= visibility.len) return;
        if (visibility[meshlet_index].visible == 0) return;

        const rw_buffers = ctx.rw_buffers orelse return;
        if (rw_buffers.len < 2) return;
        var primitives = compute.asSlice(meshlet.MeshletPrimitive, rw_buffers[0]);
        var work_ranges = compute.asSlice(meshlet.MeshletWorkRange, rw_buffers[1]);
        if (meshlet_index >= work_ranges.len) return;

        const desc = descriptors[meshlet_index];
        var work_range = work_ranges[meshlet_index];
        var emitted: u32 = 0;

        var tri_local: u32 = 0;
        while (tri_local < desc.triangle_count) : (tri_local += 1) {
            const tri_idx_offset = @as(usize, desc.triangle_offset + tri_local);
            if (tri_idx_offset >= triangle_indices.len) break;
            const global_tri_index = @as(usize, triangle_indices[tri_idx_offset]);
            if (global_tri_index >= triangles.len) break;

            const tri = triangles[global_tri_index];
            if (tri.cull_fill != 0) continue;

            var camera_positions: [3]math.Vec3 = undefined;
            var projected: [3][2]i32 = undefined;
            var uv_values: [3]math.Vec2 = undefined;
            var any_front = false;
            var all_front = true;

            const vertex_ids = [_]u32{ tri.v0, tri.v1, tri.v2 };
            inline for (vertex_ids, 0..) |vertex_idx_u32, corner| {
                const vertex_idx = @as(usize, vertex_idx_u32);
                if (vertex_idx >= vertex_positions.len) {
                    camera_positions[corner] = math.Vec3.new(0.0, 0.0, 0.0);
                    projected[corner] = .{ 0, 0 };
                    uv_values[corner] = math.Vec2.new(0.0, 0.0);
                    all_front = false;
                    continue;
                }

                const world_pos = vertex_positions[vertex_idx];
                const transformed = transformVertex(pc, world_pos);
                camera_positions[corner] = transformed.camera;
                projected[corner] = transformed.screen;
                if (transformed.front) {
                    any_front = true;
                } else {
                    all_front = false;
                }

                if (vertex_idx < vertex_uvs.len) {
                    uv_values[corner] = vertex_uvs[vertex_idx];
                } else {
                    uv_values[corner] = math.Vec2.new(0.0, 0.0);
                }
            }

            if (!any_front) continue;

            var flags: u32 = PrimitiveFlags.none;
            if (!all_front) {
                flags |= PrimitiveFlags.near_plane;
                flags |= PrimitiveFlags.clipped;
            }

            const normal_cam = computeNormalCamera(pc, triangle_normals, global_tri_index, camera_positions);
            if ((flags & PrimitiveFlags.near_plane) == 0 and isBackface(normal_cam, camera_positions)) {
                continue;
            }

            const primitive_index = @as(usize, work_range.primitive_offset + emitted);
            if (primitive_index >= primitives.len or primitive_index >= pc.total_primitive_count) break;

            const brightness = math.Vec3.dot(normal_cam, pc.light_dir);
            const intensity = lighting.computeIntensity(brightness);

            primitives[primitive_index] = meshlet.MeshletPrimitive{
                .meshlet_index = meshlet_index,
                .triangle_index = @as(u32, @intCast(global_tri_index)),
                .flags = flags,
                .reserved = 0,
                .camera_positions = camera_positions,
                .projected = projected,
                .uvs = uv_values,
                .base_color = tri.base_color,
                .intensity = intensity,
                .normal_camera = normal_cam,
            };

            emitted += 1;
        }

        work_range.primitive_count = emitted;
        work_ranges[meshlet_index] = work_range;
    }
};
