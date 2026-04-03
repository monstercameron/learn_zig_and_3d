//! Scene loader and authoring compatibility module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const scene_math = @import("math.zig");
const components = @import("components.zig");
const camera_state = @import("camera_state.zig");

pub const SceneIndexEntry = struct {
    key: []const u8,
    file: []const u8,
};

pub const SceneIndexFile = struct {
    defaultScene: []const u8,
    loadingScene: ?[]const u8 = null,
    loadingFrames: ?u32 = null,
    scenes: []SceneIndexEntry,
};

pub const SceneTextureSlotEntry = struct {
    slot: u32,
    path: []const u8,
};

pub const SceneScriptConfigEntry = struct {
    module: []const u8,
};

pub const SceneAssetConfigEntry = struct {
    type: []const u8,
    id: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    modelType: []const u8 = "",
    modelPath: []const u8 = "",
    fallbackModelPath: ?[]const u8 = null,
    applyCornellPalette: bool = false,
    smoothNormals: ?bool = null,
    position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    rotationDeg: [3]f32 = .{ 0.0, 0.0, 0.0 },
    scale: [3]f32 = .{ 1.0, 1.0, 1.0 },
    textures: []SceneTextureSlotEntry = &[_]SceneTextureSlotEntry{},
    scripts: []SceneScriptConfigEntry = &[_]SceneScriptConfigEntry{},
    path: ?[]const u8 = null,
    runtimeName: ?[]const u8 = null,
    cameraPosition: ?[3]f32 = null,
    cameraOrientation: ?[2]f32 = null,
    cameraFovDeg: ?f32 = null,
    cameraName: ?[]const u8 = null,
    lightColor: ?[3]f32 = null,
    lightDistance: ?f32 = null,
    lightShadowMode: ?[]const u8 = null,
    lightShadowUpdateInterval: ?u32 = null,
    lightShadowMapSize: ?u32 = null,
    glowRadius: ?f32 = null,
    glowIntensity: ?f32 = null,
    physicsMotion: ?[]const u8 = null,
    physicsShape: ?[]const u8 = null,
    physicsMass: ?f32 = null,
    physicsRestitution: ?f32 = null,
};

pub const SceneFile = struct {
    key: []const u8,
    assets: []SceneAssetConfigEntry,
};

pub const RuntimeKind = enum {
    static,
    gun_physics,
    scene_physics,
};

pub const ModelType = enum {
    gltf,
    obj,
};

pub const TextureSlotDefinition = struct {
    slot: usize,
    path: []const u8,
};

pub const ScriptAttachmentDefinition = struct {
    module_name: []const u8,
};

pub const AssetDefinition = struct {
    authored_id: ?[]const u8,
    parent_authored_id: ?[]const u8,
    scripts: []ScriptAttachmentDefinition,
    model_type: ModelType,
    model_path: []const u8,
    fallback_model_path: ?[]const u8,
    apply_cornell_palette: bool,
    smooth_normals: ?bool,
    position: scene_math.Vec3,
    rotation_deg: scene_math.Vec3,
    scale: scene_math.Vec3,
    texture_slots: []TextureSlotDefinition,
    physics_motion: ?components.PhysicsMotion,
    physics_shape: ?[]const u8,
    physics_mass: ?f32,
    physics_restitution: ?f32,
};

pub const LightDefinition = struct {
    authored_id: ?[]const u8,
    parent_authored_id: ?[]const u8,
    scripts: []ScriptAttachmentDefinition,
    direction: scene_math.Vec3,
    distance: f32,
    shadow_mode: components.LightShadowMode,
    shadow_update_interval_frames: u32,
    shadow_map_size: usize,
    color: scene_math.Vec3,
    glow_radius: f32,
    glow_intensity: f32,
};

pub const SceneDescription = struct {
    key: []const u8,
    camera_authored_id: ?[]const u8,
    camera_parent_authored_id: ?[]const u8,
    camera_scripts: []ScriptAttachmentDefinition,
    assets: []AssetDefinition,
    lights: []LightDefinition,
    runtime: RuntimeKind,
    hdri_path: ?[]const u8,
    camera_position: scene_math.Vec3,
    camera_orientation_pitch: f32,
    camera_orientation_yaw: f32,
    camera_fov_deg: f32,

    pub fn deinit(self: *SceneDescription, allocator: std.mem.Allocator) void {
        for (self.assets) |asset| {
            allocator.free(asset.texture_slots);
            allocator.free(asset.scripts);
        }
        for (self.lights) |light| allocator.free(light.scripts);
        allocator.free(self.camera_scripts);
        allocator.free(self.assets);
        allocator.free(self.lights);
        self.camera_scripts = &.{};
        self.assets = &.{};
        self.lights = &.{};
    }

    pub fn textureSlotCount(self: SceneDescription) usize {
        var count: usize = 0;
        for (self.assets) |asset| count += asset.texture_slots.len;
        return count;
    }
};

pub fn buildSceneDescription(
    allocator: std.mem.Allocator,
    scene_file: SceneFile,
    meshlet_shadows_enabled: bool,
    post_shadows_enabled: bool,
    default_shadow_map_size: usize,
) !SceneDescription {
    var runtime: RuntimeKind = .static;
    var hdri_path: ?[]const u8 = null;
    var camera_position = scene_math.Vec3.new(0.0, 2.0, -6.5);
    var camera_orientation_pitch: f32 = 0.0;
    var camera_orientation_yaw: f32 = 0.0;
    var camera_fov_deg: f32 = camera_state.default_fov_deg;
    var camera_authored_id: ?[]const u8 = null;
    var camera_parent_authored_id: ?[]const u8 = null;
    var camera_scripts: []ScriptAttachmentDefinition = &.{};
    var authored_ids = std.StringHashMapUnmanaged(void){};
    defer authored_ids.deinit(allocator);

    var model_count: usize = 0;
    var light_count: usize = 0;
    for (scene_file.assets) |asset| {
        const authored_id = asset.id orelse if (std.ascii.eqlIgnoreCase(asset.type, "camera")) asset.cameraName else null;
        if (authored_id) |id| {
            const entry = try authored_ids.getOrPut(allocator, id);
            if (entry.found_existing) return error.DuplicateSceneEntityId;
        }
        if (std.ascii.eqlIgnoreCase(asset.type, "model")) {
            model_count += 1;
        } else if (std.ascii.eqlIgnoreCase(asset.type, "runtime")) {
            if (asset.runtimeName) |runtime_name| {
                if (std.ascii.eqlIgnoreCase(runtime_name, "gun_physics")) runtime = .gun_physics;
                if (std.ascii.eqlIgnoreCase(runtime_name, "scene_physics")) runtime = .scene_physics;
            }
        } else if (std.ascii.eqlIgnoreCase(asset.type, "hdri")) {
            hdri_path = asset.path;
        } else if (std.ascii.eqlIgnoreCase(asset.type, "camera")) {
            if (asset.cameraPosition) |pos| {
                camera_position = scene_math.Vec3.new(pos[0], pos[1], pos[2]);
            }
            if (asset.cameraOrientation) |angles| {
                const deg_to_rad = std.math.pi / 180.0;
                camera_orientation_pitch = angles[0] * deg_to_rad;
                camera_orientation_yaw = angles[1] * deg_to_rad;
            }
            if (asset.cameraFovDeg) |fov_deg| {
                camera_fov_deg = fov_deg;
            }
            camera_authored_id = authored_id;
            camera_parent_authored_id = asset.parent;
            camera_scripts = try dupScriptAttachments(allocator, asset.scripts);
        } else if (std.ascii.eqlIgnoreCase(asset.type, "light")) {
            light_count += 1;
        }
    }

    const assets = try allocator.alloc(AssetDefinition, model_count);
    errdefer allocator.free(assets);
    const lights = try allocator.alloc(LightDefinition, light_count);
    errdefer allocator.free(lights);
    errdefer allocator.free(camera_scripts);

    var model_index: usize = 0;
    var light_index: usize = 0;
    errdefer {
        for (assets[0..model_index]) |asset| {
            allocator.free(asset.texture_slots);
            allocator.free(asset.scripts);
        }
        for (lights[0..light_index]) |light| allocator.free(light.scripts);
    }

    for (scene_file.assets) |asset| {
        if (std.ascii.eqlIgnoreCase(asset.type, "light")) {
            const pos = scene_math.Vec3.new(asset.position[0], asset.position[1], asset.position[2]);
            const pos_len = vecLength(pos);
            const dist = asset.lightDistance orelse @max(0.01, pos_len);
            const color_arr = asset.lightColor orelse [3]f32{ 1.0, 1.0, 1.0 };
            const direction = if (pos_len > 1e-6) scene_math.Vec3.scale(pos, 1.0 / pos_len) else scene_math.Vec3.new(0.0, 1.0, 0.0);
            lights[light_index] = .{
                .authored_id = asset.id,
                .parent_authored_id = asset.parent,
                .scripts = try dupScriptAttachments(allocator, asset.scripts),
                .direction = direction,
                .distance = dist,
                .shadow_mode = parseSceneLightShadowMode(asset.lightShadowMode, meshlet_shadows_enabled, post_shadows_enabled),
                .shadow_update_interval_frames = @max(@as(u32, 1), asset.lightShadowUpdateInterval orelse 1),
                .shadow_map_size = @max(@as(usize, 64), @as(usize, asset.lightShadowMapSize orelse @intCast(default_shadow_map_size))),
                .color = scene_math.Vec3.new(color_arr[0], color_arr[1], color_arr[2]),
                .glow_radius = asset.glowRadius orelse 0.0,
                .glow_intensity = asset.glowIntensity orelse 0.0,
            };
            light_index += 1;
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(asset.type, "model")) continue;

        const model_type = if (std.ascii.eqlIgnoreCase(asset.modelType, "gltf"))
            ModelType.gltf
        else if (std.ascii.eqlIgnoreCase(asset.modelType, "obj"))
            ModelType.obj
        else
            return error.InvalidSceneModelType;

        const texture_slots = try allocator.alloc(TextureSlotDefinition, asset.textures.len);
        for (asset.textures, 0..) |slot, texture_index| {
            texture_slots[texture_index] = .{
                .slot = @intCast(slot.slot),
                .path = slot.path,
            };
        }

        assets[model_index] = .{
            .authored_id = asset.id,
            .parent_authored_id = asset.parent,
            .scripts = try dupScriptAttachments(allocator, asset.scripts),
            .model_type = model_type,
            .model_path = asset.modelPath,
            .fallback_model_path = asset.fallbackModelPath,
            .apply_cornell_palette = asset.applyCornellPalette,
            .smooth_normals = asset.smoothNormals,
            .position = scene_math.Vec3.new(asset.position[0], asset.position[1], asset.position[2]),
            .rotation_deg = scene_math.Vec3.new(asset.rotationDeg[0], asset.rotationDeg[1], asset.rotationDeg[2]),
            .scale = scene_math.Vec3.new(asset.scale[0], asset.scale[1], asset.scale[2]),
            .texture_slots = texture_slots,
            .physics_motion = parsePhysicsMotion(asset.physicsMotion),
            .physics_shape = asset.physicsShape,
            .physics_mass = asset.physicsMass,
            .physics_restitution = asset.physicsRestitution,
        };
        model_index += 1;
    }

    return .{
        .key = scene_file.key,
        .camera_authored_id = camera_authored_id,
        .camera_parent_authored_id = camera_parent_authored_id,
        .camera_scripts = camera_scripts,
        .assets = assets,
        .lights = lights,
        .runtime = runtime,
        .hdri_path = hdri_path,
        .camera_position = camera_position,
        .camera_orientation_pitch = camera_orientation_pitch,
        .camera_orientation_yaw = camera_orientation_yaw,
        .camera_fov_deg = camera_fov_deg,
    };
}

pub fn parseSceneLightShadowMode(raw_mode: ?[]const u8, meshlet_shadows_enabled: bool, post_shadows_enabled: bool) components.LightShadowMode {
    if (raw_mode) |mode| {
        if (std.ascii.eqlIgnoreCase(mode, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(mode, "shadow_map")) return .shadow_map;
        if (std.ascii.eqlIgnoreCase(mode, "meshlet_ray")) return .meshlet_ray;
        if (std.ascii.eqlIgnoreCase(mode, "meshlet")) return .meshlet_ray;
    }
    if (meshlet_shadows_enabled) return .meshlet_ray;
    if (post_shadows_enabled) return .shadow_map;
    return .none;
}

fn parsePhysicsMotion(raw_motion: ?[]const u8) ?components.PhysicsMotion {
    if (raw_motion) |motion| {
        if (std.ascii.eqlIgnoreCase(motion, "static")) return .static;
        if (std.ascii.eqlIgnoreCase(motion, "dynamic")) return .dynamic;
        if (std.ascii.eqlIgnoreCase(motion, "kinematic")) return .kinematic;
    }
    return null;
}

fn dupScriptAttachments(allocator: std.mem.Allocator, entries: []const SceneScriptConfigEntry) ![]ScriptAttachmentDefinition {
    const scripts = try allocator.alloc(ScriptAttachmentDefinition, entries.len);
    for (entries, 0..) |entry, index| {
        scripts[index] = .{ .module_name = entry.module };
    }
    return scripts;
}

fn vecLength(vec: scene_math.Vec3) f32 {
    return @sqrt((vec.x * vec.x) + (vec.y * vec.y) + (vec.z * vec.z));
}
