const std = @import("std");
const compute = @import("compute.zig");
const ComputeContext = compute.ComputeContext;
const loadR = compute.loadR;
const loadRGBA = compute.loadRGBA;
const storeRGBA = compute.storeRGBA;

pub const DeferredLightingPC = extern struct {
    light_direction: [3]f32,
    light_color: [3]f32,
    ambient_intensity: f32,
    camera_position: [3]f32,
    inverse_projection: [16]f32, // To reconstruct position
    shininess: f32,
    specular_strength: f32,
};

pub const DeferredLightingKernel = struct {
    pub const group_size_x: u32 = 8;
    pub const group_size_y: u32 = 8;
    pub const SharedSize: usize = 0;

    fn getPC(ctx: *const ComputeContext) *const DeferredLightingPC {
        return @ptrCast(*const DeferredLightingPC, ctx.push_constants.?.ptr);
    }

    pub fn main(ctx: *ComputeContext) void {
        const albedo_tex = ctx.ro_textures[0]; // Albedo (RGBA32F)
        const normal_tex = ctx.ro_textures[1]; // Normals (RGBA32F)
        const depth_tex = ctx.ro_textures[2]; // Depth (R32F)
        const dst = ctx.rw_textures[0]; // Lit color output (RGBA32F)
        const pc = getPC(ctx);

        const x = ctx.global_id.x;
        const y = ctx.global_id.y;

        const albedo = loadRGBA(albedo_tex, x, y);
        const normal_packed = loadRGBA(normal_tex, x, y);
        const depth = loadR(depth_tex, x, y);

        // Unpack normal from [0,1] range to [-1,1] range
        const normal_x = normal_packed[0] * 2.0 - 1.0;
        const normal_y = normal_packed[1] * 2.0 - 1.0;
        const normal_z = normal_packed[2] * 2.0 - 1.0;
        const normal_vec = std.math.normalize(std.math.Vec3.new(normal_x, normal_y, normal_z));

        const light_dir_vec = std.math.normalize(std.math.Vec3.new(pc.light_direction[0], pc.light_direction[1], pc.light_direction[2]));

        // Diffuse lighting (Lambertian)
        const NdotL = @max(0.0, std.math.dot(normal_vec, light_dir_vec));
        const diffuse_r = albedo[0] * pc.light_color[0] * NdotL;
        const diffuse_g = albedo[1] * pc.light_color[1] * NdotL;
        const diffuse_b = albedo[2] * pc.light_color[2] * NdotL;

        // Specular highlight (Blinn-Phong)
        // Note: For full accuracy we'd reconstruct world space from depth,
        // but here we estimate view_dir directly opposite to camera_pos for a placeholder
        const view_dir = std.math.normalize(std.math.Vec3.new(pc.camera_position[0] - (@as(f32, @floatFromInt(x)) / 1000.0), // very rough placeholder
            pc.camera_position[1] - (@as(f32, @floatFromInt(y)) / 1000.0), pc.camera_position[2] - depth));
        const half_vec = std.math.normalize(std.math.Vec3.new(
            view_dir.x + light_dir_vec.x,
            view_dir.y + light_dir_vec.y,
            view_dir.z + light_dir_vec.z,
        ));
        const NdotH = @max(0.0, std.math.dot(normal_vec, half_vec));
        const spec_factor = std.math.pow(f32, NdotH, pc.shininess) * pc.specular_strength;
        const spec_r = pc.light_color[0] * spec_factor;
        const spec_g = pc.light_color[1] * spec_factor;
        const spec_b = pc.light_color[2] * spec_factor;

        // Ambient lighting
        const ambient_r = albedo[0] * pc.ambient_intensity;
        const ambient_g = albedo[1] * pc.ambient_intensity;
        const ambient_b = albedo[2] * pc.ambient_intensity;

        const final_r = diffuse_r + ambient_r + spec_r;
        const final_g = diffuse_g + ambient_g + spec_g;
        const final_b = diffuse_b + ambient_b + spec_b;

        storeRGBA(dst, x, y, .{ final_r, final_g, final_b, albedo[3] });
    }
};
