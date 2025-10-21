const std = @import("std");
const compute = @import("compute.zig");
const math = @import("../math.zig");
const meshlet = @import("meshlet_primitives.zig");

const MeshletCullPC = extern struct {
    camera_position: math.Vec3,
    _pad0: f32 = 0.0,
    basis_right: math.Vec3,
    _pad1: f32 = 0.0,
    basis_up: math.Vec3,
    _pad2: f32 = 0.0,
    basis_forward: math.Vec3,
    _pad3: f32 = 0.0,
    projection_scale_x: f32,
    projection_scale_y: f32,
    near_plane: f32,
    near_epsilon: f32,
    meshlet_count: u32,
    margin_scale: f32,
    margin_constant: f32,
    _pad4: f32 = 0.0,
};

fn loadPushConstants(ctx: *const compute.ComputeContext) ?*const MeshletCullPC {
    const raw = ctx.push_constants orelse return null;
    if (raw.len < @sizeOf(MeshletCullPC)) return null;
    const ptr = @as([*]const u8, raw.ptr);
    const aligned = @alignCast(@alignOf(MeshletCullPC), ptr);
    return @as(*const MeshletCullPC, @ptrCast(aligned));
}

fn meshletVisible(desc: meshlet.MeshletDescriptor, pc: *const MeshletCullPC) bool {
    const relative_center = math.Vec3.sub(desc.bounds_center, pc.camera_position);
    const center_cam = math.Vec3.new(
        math.Vec3.dot(relative_center, pc.basis_right),
        math.Vec3.dot(relative_center, pc.basis_up),
        math.Vec3.dot(relative_center, pc.basis_forward),
    );

    const radius = desc.bounds_radius;
    const sphere_radius = radius + radius * pc.margin_scale + pc.margin_constant;

    if (center_cam.z + sphere_radius <= pc.near_plane - pc.near_epsilon) return false;
    if (center_cam.z <= 0.0 and center_cam.z + sphere_radius <= 0.0) return false;

    const tan_half_fov_x = if (pc.projection_scale_x != 0.0) 1.0 / pc.projection_scale_x else std.math.inf(f32);
    const tan_half_fov_y = if (pc.projection_scale_y != 0.0) 1.0 / pc.projection_scale_y else std.math.inf(f32);

    const horizon_limit = (center_cam.z + sphere_radius) * tan_half_fov_x + sphere_radius;
    if (center_cam.x > horizon_limit or center_cam.x < -horizon_limit) return false;

    const vertical_limit = (center_cam.z + sphere_radius) * tan_half_fov_y + sphere_radius;
    if (center_cam.y > vertical_limit or center_cam.y < -vertical_limit) return false;

    return true;
}

pub const MeshletVisibilityKernel = struct {
    pub const group_size_x: u32 = 64;
    pub const group_size_y: u32 = 1;
    pub const SharedSize: usize = 0;

    pub fn main(ctx: *compute.ComputeContext) void {
        const pc = loadPushConstants(ctx) orelse return;
        const meshlet_index = ctx.global_id.x;
        if (meshlet_index >= pc.meshlet_count) return;

        const ro_buffers = ctx.ro_buffers orelse return;
        if (ro_buffers.len == 0) return;
        const descriptors = compute.asConstSlice(meshlet.MeshletDescriptor, ro_buffers[0]);
        if (meshlet_index >= descriptors.len) return;

        const visible = meshletVisible(descriptors[meshlet_index], pc);

        const rw_buffers = ctx.rw_buffers orelse return;
        if (rw_buffers.len == 0) return;
        var visibility = compute.asSlice(meshlet.MeshletVisibility, rw_buffers[0]);
        if (meshlet_index >= visibility.len) return;
        visibility[meshlet_index].visible = if (visible) 1 else 0;
    }
};
