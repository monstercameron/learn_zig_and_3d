//! Smoke Test module.
//! Test module for regression or smoke validation.

const std = @import("std");
const taa_kernel = @import("taa_kernel");
const hybrid_shadow_candidate_kernel = @import("hybrid_shadow_candidate_kernel");
const hybrid_shadow_resolve_kernel = @import("hybrid_shadow_resolve_kernel");
const render_main = @import("render_main");
const scene_main = @import("scene_main");

test "default camera controls debounce held mode toggle" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .scripts = &.{.{ .module_name = "scene.default.camera_controls" }},
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{},
    });

    const camera_entity = blk: {
        for (runtime.components.cameras.items, 0..) |maybe_camera, index| {
            if (maybe_camera == null) continue;
            break :blk scene_main.EntityId.init(@intCast(index), runtime.world.generations.items[index]);
        }
        return error.TestUnexpectedResult;
    };
    defer {
        const detached = runtime.detachScriptFromEntity(camera_entity, "scene.default.camera_controls") catch unreachable;
        std.testing.expect(detached) catch unreachable;
    }

    var script_input = scene_main.ScriptInputState{};
    script_input.setKey(.v, true);
    runtime.setExecutionInputs(false, false, script_input);
    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 1, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 1), runtime.rendererCommands().len);
    try std.testing.expectEqual(scene_main.Command{ .set_camera_mode = .toggle }, runtime.rendererCommands()[0]);
    runtime.clearRendererCommands();

    script_input = scene_main.ScriptInputState{};
    script_input.setKey(.v, true);
    runtime.setExecutionInputs(false, false, script_input);
    snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 2, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 0), runtime.rendererCommands().len);

    runtime.setExecutionInputs(false, false, .{});
    snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 3, 1.0 / 60.0);
    snapshot.deinit();
    runtime.clearRendererCommands();

    script_input = scene_main.ScriptInputState{};
    script_input.setKey(.v, true);
    runtime.setExecutionInputs(false, false, script_input);
    snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 4, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 1), runtime.rendererCommands().len);
    try std.testing.expectEqual(scene_main.Command{ .set_camera_mode = .toggle }, runtime.rendererCommands()[0]);
}

test "default camera controls apply mouse look in first-person mode without right button" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .scripts = &.{.{ .module_name = "scene.default.camera_controls" }},
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{},
    });

    const camera_index = blk: {
        for (runtime.components.cameras.items, 0..) |maybe_camera, index| {
            if (maybe_camera == null) continue;
            break :blk index;
        }
        return error.TestUnexpectedResult;
    };
    const camera_entity = scene_main.EntityId.init(@intCast(camera_index), runtime.world.generations.items[camera_index]);
    defer {
        const detached = runtime.detachScriptFromEntity(camera_entity, "scene.default.camera_controls") catch unreachable;
        std.testing.expect(detached) catch unreachable;
    }

    var script_input = scene_main.ScriptInputState{};
    script_input.first_person_active = true;
    script_input.look_delta = .{ .x = 24.0, .y = 0.0 };
    runtime.setExecutionInputs(false, false, script_input);
    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 1, 1.0 / 60.0);
    snapshot.deinit();

    const yaw_after_first_person_frame = runtime.components.cameras.items[camera_index].?.yaw;
    try std.testing.expect(yaw_after_first_person_frame > 0.0);

    script_input = scene_main.ScriptInputState{};
    script_input.look_delta = .{ .x = 24.0, .y = 0.0 };
    runtime.setExecutionInputs(false, false, script_input);
    snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 2, 1.0 / 60.0);
    snapshot.deinit();

    const yaw_after_editor_frame = runtime.components.cameras.items[camera_index].?.yaw;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), yaw_after_editor_frame, 1e-6);

    script_input = scene_main.ScriptInputState{};
    script_input.setMouseButton(.right, true);
    script_input.look_delta = .{ .x = 24.0, .y = 0.0 };
    runtime.setExecutionInputs(false, false, script_input);
    snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 3, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expect(runtime.components.cameras.items[camera_index].?.yaw > yaw_after_editor_frame);
}

test "default renderer controls reserve bare k for gameplay and use ctrl plus l for positive nudge" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .scripts = &.{.{ .module_name = "scene.default.renderer_controls" }},
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{},
    });

    var script_input = scene_main.ScriptInputState{};
    script_input.setKey(.k, true);
    runtime.setExecutionInputs(false, false, script_input);
    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 1, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 0), runtime.rendererCommands().len);

    script_input = scene_main.ScriptInputState{};
    script_input.setKey(.ctrl, true);
    script_input.setKey(.l, true);
    runtime.setExecutionInputs(false, false, script_input);
    snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 2, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 1), runtime.rendererCommands().len);
    try std.testing.expectEqual(scene_main.Command{ .nudge_active_gizmo = .{ .delta = 0.2 } }, runtime.rendererCommands()[0]);
}

const LifecycleRecorder = struct {
    var attach_count: u32 = 0;
    var begin_play_count: u32 = 0;
    var enable_count: u32 = 0;
    var disable_count: u32 = 0;
    var selected_count: u32 = 0;
    var deselected_count: u32 = 0;
    var update_count: u32 = 0;
    var fixed_update_count: u32 = 0;
    var late_update_count: u32 = 0;
    var asset_ready_count: u32 = 0;
    var asset_lost_count: u32 = 0;
    var zone_enter_count: u32 = 0;
    var zone_exit_count: u32 = 0;
    var end_play_count: u32 = 0;
    var detach_count: u32 = 0;

    fn reset() void {
        attach_count = 0;
        begin_play_count = 0;
        enable_count = 0;
        disable_count = 0;
        selected_count = 0;
        deselected_count = 0;
        update_count = 0;
        fixed_update_count = 0;
        late_update_count = 0;
        asset_ready_count = 0;
        asset_lost_count = 0;
        zone_enter_count = 0;
        zone_exit_count = 0;
        end_play_count = 0;
        detach_count = 0;
    }

    fn onEvent(ctx: *scene_main.ScriptCallbackContext) void {
        switch (ctx.event) {
            .attach => attach_count += 1,
            .begin_play => begin_play_count += 1,
            .enable => enable_count += 1,
            .disable => disable_count += 1,
            .selected => selected_count += 1,
            .deselected => deselected_count += 1,
            .update => update_count += 1,
            .fixed_update => fixed_update_count += 1,
            .late_update => late_update_count += 1,
            .asset_ready => asset_ready_count += 1,
            .asset_lost => asset_lost_count += 1,
            .zone_enter => zone_enter_count += 1,
            .zone_exit => zone_exit_count += 1,
            .end_play => end_play_count += 1,
            .detach => detach_count += 1,
            else => {},
        }
    }
};

test "smoke: test harness boots" {
    try std.testing.expect(true);
}

test "taa kernel resolvePixel blends history and current" {
    const current: u32 = 0xFF204060;
    const history: u32 = 0xFF6080A0;
    const params = taa_kernel.TemporalResolveParams{ .history_weight = 0.5 };
    const out = taa_kernel.resolvePixel(current, history, params);

    try std.testing.expectEqual(@as(u32, 0xFF406080), out);
}

test "hybrid shadow candidate kernel advances generation and wraps" {
    var marks = [_]u32{ 1, 2, 3 };
    const next1 = hybrid_shadow_candidate_kernel.nextMark(7, marks[0..]);
    try std.testing.expectEqual(@as(u32, 8), next1);

    const wrapped = hybrid_shadow_candidate_kernel.nextMark(std.math.maxInt(u32), marks[0..]);
    try std.testing.expectEqual(@as(u32, 1), wrapped);
    try std.testing.expectEqual(@as(u32, 0), marks[0]);
    try std.testing.expectEqual(@as(u32, 0), marks[1]);
    try std.testing.expectEqual(@as(u32, 0), marks[2]);
}

test "hybrid shadow resolve kernel blends with clamped factor" {
    const blended_a = hybrid_shadow_resolve_kernel.blendCoverage(0.25, 0.75, 0.0);
    const blended_b = hybrid_shadow_resolve_kernel.blendCoverage(0.25, 0.75, 1.0);
    const blended_c = hybrid_shadow_resolve_kernel.blendCoverage(0.25, 0.75, 0.5);

    try std.testing.expectApproxEqAbs(@as(f32, 0.75), blended_a, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), blended_b, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), blended_c, 1e-6);
}

test "frame graph compiles enabled passes with explicit resources" {
    var graph = try render_main.frame_graph.compileEnabledPasses(
        std.testing.allocator,
        render_main.pass_graph.passBit(.skybox) | render_main.pass_graph.passBit(.ssao) | render_main.pass_graph.passBit(.bloom),
        render_main.pass_graph.resourceMask(&.{ .scene_color, .scene_depth, .scene_normals }),
    );
    defer graph.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), graph.passes.len);
    try std.testing.expectEqual(render_main.pass_graph.RenderPassId.skybox, graph.passes[0].id);
    try std.testing.expectEqual(render_main.pass_graph.RenderPassId.ssao, graph.passes[1].id);
    try std.testing.expectEqual(render_main.pass_graph.RenderPassId.bloom, graph.passes[2].id);
}

test "frame graph rejects history dependent pass without history resource" {
    try std.testing.expectError(
        error.HistoryRequestedWithoutResource,
        render_main.frame_graph.compileEnabledPasses(
            std.testing.allocator,
            render_main.pass_graph.passBit(.motion_blur),
            render_main.pass_graph.resourceMask(&.{ .scene_color, .scene_depth }),
        ),
    );
}

test "cached frame graph reuses compiled plan and frame plan selects backend stage" {
    var graph_cache = render_main.frame_graph.CachedGraph{};
    try graph_cache.compileIfNeeded(
        render_main.pass_graph.passBit(.skybox) | render_main.pass_graph.passBit(.ssao),
        render_main.pass_graph.resourceMask(&.{ .scene_color, .scene_depth, .scene_normals }),
    );
    const first_pass_count = graph_cache.pass_count;
    try graph_cache.compileIfNeeded(
        render_main.pass_graph.passBit(.skybox) | render_main.pass_graph.passBit(.ssao),
        render_main.pass_graph.resourceMask(&.{ .scene_color, .scene_depth, .scene_normals }),
    );
    try std.testing.expect(graph_cache.valid);
    try std.testing.expectEqual(first_pass_count, graph_cache.pass_count);

    var plan_cache = render_main.frame_plan.CachedPlan{};
    plan_cache.compileIfNeeded(.{
        .include_shadow_build = true,
        .backend = .tiled,
        .include_post_process = true,
        .include_present = true,
    });
    const compiled = plan_cache.compiled();
    try std.testing.expectEqual(@as(usize, 4), compiled.stages.len);
    try std.testing.expectEqual(render_main.frame_plan.FrameStageId.shadow_build, compiled.stages[0]);
    try std.testing.expectEqual(render_main.frame_plan.FrameStageId.scene_raster_tiled, compiled.stages[1]);
}

test "scene runtime entity generations change after destroy" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    const first = try runtime.createEntity();
    runtime.destroyEntity(first);
    const second = try runtime.createEntity();

    try std.testing.expect(!first.eql(second));
    try std.testing.expect(second.generation != first.generation);
}

test "scene world debug dump reports slot state" {
    var world = scene_main.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.createEntity();
    try std.testing.expect(world.setEnabled(entity, false));

    const dump = try world.debugDump(std.testing.allocator);
    defer std.testing.allocator.free(dump);

    try std.testing.expect(std.mem.indexOf(u8, dump, "slots=1 live=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "entity[0] generation=1 alive=true enabled=false") != null);
}

test "scene hierarchy rejects reparent cycles" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -8.0, .y = -8.0, .z = -8.0 },
        .max = .{ .x = 8.0, .y = 8.0, .z = 8.0 },
    });
    defer runtime.deinit();

    const parent = try runtime.createEntity();
    const child = try runtime.createEntity();
    try runtime.hierarchy.attachChild(&runtime.world, parent, child);

    try std.testing.expectError(error.HierarchyCycleDetected, runtime.hierarchy.attachChild(&runtime.world, child, parent));
}

test "asset registry pins block destruction" {
    var registry = scene_main.AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const handle = try registry.register(.mesh, "unit.mesh");
    try std.testing.expect(registry.pin(handle));
    try std.testing.expect(!registry.destroy(handle));
    try std.testing.expect(registry.unpin(handle));
    try std.testing.expect(registry.destroy(handle));
}

test "residency manager promotes nearby cells" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -32.0, .y = -32.0, .z = -32.0 },
        .max = .{ .x = 32.0, .y = 32.0, .z = 32.0 },
    });
    defer runtime.deinit();

    const entity = try runtime.createEntity();
    _ = try runtime.residency.registerStaticEntity(entity, .{ .x = 1.0, .y = 1.0, .z = 1.0 });
    try runtime.residency.updateCamera(.{ .x = 0.0, .y = 0.0, .z = 0.0 }, 10.0, 20.0, 1);

    const cell_id = runtime.residency.tree.entity_cells.items[@intCast(entity.index)].?;
    try std.testing.expectEqual(scene_main.CellState.resident, runtime.residency.cells.items[@intCast(cell_id)].state);
}

test "dependency graph produces dependency-first order" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -8.0, .y = -8.0, .z = -8.0 },
        .max = .{ .x = 8.0, .y = 8.0, .z = 8.0 },
    });
    defer runtime.deinit();

    const root = try runtime.createEntity();
    const child = try runtime.createEntity();
    const leaf = try runtime.createEntity();

    try runtime.dependencies.addEdge(.{ .source = root, .target = .{ .entity = child }, .kind = .logic });
    try runtime.dependencies.addEdge(.{ .source = child, .target = .{ .entity = leaf }, .kind = .logic });

    var ordered = try runtime.dependencies.topologicalOrder(std.testing.allocator, &runtime.world);
    defer ordered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), ordered.items.len);
    try std.testing.expect(ordered.items[0].eql(leaf));
    try std.testing.expect(ordered.items[1].eql(child));
    try std.testing.expect(ordered.items[2].eql(root));
}

test "dependency graph can query direct dependencies" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -8.0, .y = -8.0, .z = -8.0 },
        .max = .{ .x = 8.0, .y = 8.0, .z = 8.0 },
    });
    defer runtime.deinit();

    const entity = try runtime.createEntity();
    const other = try runtime.createEntity();
    try runtime.dependencies.addEdge(.{ .source = entity, .target = .{ .entity = other }, .kind = .activation });

    var direct = try runtime.dependencies.collectDirectDependencies(std.testing.allocator, entity);
    defer direct.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), direct.items.len);
    try std.testing.expect(direct.items[0].source.eql(entity));
}

test "render snapshot carries active camera and light settings" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -32.0, .y = -32.0, .z = -32.0 },
        .max = .{ .x = 32.0, .y = 32.0, .z = 32.0 },
    });
    defer runtime.deinit();

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 1.0, .y = 2.0, .z = 3.0 },
            .pitch = 0.25,
            .yaw = 1.5,
            .fov_deg = 72.0,
        },
        .lights = &.{.{
            .direction = .{ .x = 0.0, .y = -1.0, .z = 0.0 },
            .distance = 14.0,
            .color = .{ .x = 0.8, .y = 0.7, .z = 0.6 },
            .glow_radius = 2.5,
            .glow_intensity = 1.25,
            .shadow_mode = .shadow_map,
            .shadow_update_interval_frames = 3,
            .shadow_map_size = 1024,
        }},
        .assets = &.{},
    });

    var snapshot = try runtime.updateFrame(.{ .x = 4.0, .y = 5.0, .z = 6.0 }, 0.4, 1.8, 32.0, 48.0, 12, 1.0 / 60.0);
    defer snapshot.deinit();

    try std.testing.expect(snapshot.active_camera != null);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), snapshot.active_camera.?.position.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), snapshot.active_camera.?.position.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), snapshot.active_camera.?.position.z, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), snapshot.active_camera.?.pitch, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.8), snapshot.active_camera.?.yaw, 1e-6);

    try std.testing.expectEqual(@as(usize, 1), snapshot.lights.items.len);
    const light = snapshot.lights.items[0];
    try std.testing.expectEqual(scene_main.components.LightShadowMode.shadow_map, light.shadow_mode);
    try std.testing.expectEqual(@as(u32, 3), light.shadow_update_interval_frames);
    try std.testing.expectEqual(@as(usize, 1024), light.shadow_map_size);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), light.glow_radius, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), light.glow_intensity, 1e-6);
}

test "scene loader rejects duplicate authored ids" {
    var assets = [_]scene_main.SceneAssetConfigEntry{
        .{
            .type = "camera",
            .id = "shared.id",
            .cameraPosition = .{ 0.0, 1.0, 2.0 },
            .cameraOrientation = .{ 0.0, 0.0 },
        },
        .{
            .type = "model",
            .id = "shared.id",
            .modelType = "gltf",
            .modelPath = "assets/models/teapot.glb",
        },
    };
    const scene_file = scene_main.SceneFile{
        .key = "duplicate_ids",
        .assets = assets[0..],
    };

    try std.testing.expectError(error.DuplicateSceneEntityId, scene_main.buildSceneDescription(std.testing.allocator, scene_file, true, true, 1024));
}

test "scene runtime registers authored ids for lookup" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .authored_id = "camera.main",
            .position = .{ .x = 0.0, .y = 2.0, .z = -4.0 },
            .pitch = 0.1,
            .yaw = 0.2,
            .fov_deg = 60.0,
        },
        .lights = &.{.{
            .authored_id = "light.key",
            .direction = .{ .x = 0.0, .y = -1.0, .z = 0.0 },
            .distance = 10.0,
            .color = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        }},
        .assets = &.{.{
            .authored_id = "prop.teapot",
            .model_path = "assets/models/teapot.glb",
            .position = .{ .x = 1.0, .y = 0.0, .z = 0.0 },
            .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        }},
    });

    const camera = runtime.lookupEntityByAuthoredId("camera.main");
    const light = runtime.lookupEntityByAuthoredId("light.key");
    const prop = runtime.lookupEntityByAuthoredId("prop.teapot");

    try std.testing.expect(camera != null);
    try std.testing.expect(light != null);
    try std.testing.expect(prop != null);
    try std.testing.expect(runtime.world.isAlive(camera.?));
    try std.testing.expect(runtime.world.isAlive(light.?));
    try std.testing.expect(runtime.world.isAlive(prop.?));
}

test "scene runtime applyDeferred destroys full entity state" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    const entity = try runtime.createEntity();
    const index: usize = @intCast(entity.index);
    runtime.components.scene_nodes.items[index] = .{
        .authored_id = "cleanup.target",
        .node_id = scene_main.SceneNodeId.init(1234),
    };
    try runtime.authored_entity_lookup.put(std.testing.allocator, "cleanup.target", entity);
    runtime.components.selectables.items[index] = .{};

    try runtime.commands.queueDestroy(entity);
    runtime.applyDeferred();

    try std.testing.expect(!runtime.world.isAlive(entity));
    try std.testing.expect(runtime.lookupEntityByAuthoredId("cleanup.target") == null);
    try std.testing.expect(runtime.components.scene_nodes.items[index] == null);
    try std.testing.expect(runtime.components.selectables.items[index] == null);
}

test "scene runtime exposes renderable entities in bootstrap order" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -5.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{
            .{
                .authored_id = "prop.first",
                .model_path = "assets/models/first.glb",
                .position = .{ .x = -1.0, .y = 0.0, .z = 0.0 },
                .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
            },
            .{
                .authored_id = "prop.second",
                .model_path = "assets/models/second.glb",
                .position = .{ .x = 1.0, .y = 0.0, .z = 0.0 },
                .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
            },
        },
    });

    const first = runtime.renderableEntityAt(0);
    const second = runtime.renderableEntityAt(1);

    try std.testing.expect(first != null);
    try std.testing.expect(second != null);
    try std.testing.expect(first.?.eql(runtime.lookupEntityByAuthoredId("prop.first").?));
    try std.testing.expect(second.?.eql(runtime.lookupEntityByAuthoredId("prop.second").?));
}

test "scene runtime propagates parent transforms into child world transforms" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -32.0, .y = -32.0, .z = -32.0 },
        .max = .{ .x = 32.0, .y = 32.0, .z = 32.0 },
    });
    defer runtime.deinit();

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -5.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{
            .{
                .authored_id = "root.parent",
                .model_path = "assets/models/root.glb",
                .position = .{ .x = 10.0, .y = 0.0, .z = 0.0 },
                .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .scale = .{ .x = 2.0, .y = 2.0, .z = 2.0 },
            },
            .{
                .authored_id = "child.prop",
                .parent_authored_id = "root.parent",
                .model_path = "assets/models/child.glb",
                .position = .{ .x = 1.5, .y = 2.0, .z = -0.5 },
                .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
            },
        },
    });

    const child = runtime.lookupEntityByAuthoredId("child.prop").?;
    const initial_transform = runtime.worldTransform(child).?;
    try std.testing.expectApproxEqAbs(@as(f32, 13.0), initial_transform.position.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), initial_transform.position.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), initial_transform.position.z, 1e-4);

    const parent = runtime.lookupEntityByAuthoredId("root.parent").?;
    try std.testing.expect(runtime.translateEntity(parent, .{ .x = -4.0, .y = 1.0, .z = 3.0 }));

    const moved_transform = runtime.worldTransform(child).?;
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), moved_transform.position.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), moved_transform.position.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), moved_transform.position.z, 1e-4);
}

test "scene runtime applyDeferred propagates enable state to subtree" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -32.0, .y = -32.0, .z = -32.0 },
        .max = .{ .x = 32.0, .y = 32.0, .z = 32.0 },
    });
    defer runtime.deinit();

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -5.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{
            .{
                .authored_id = "root.parent",
                .model_path = "assets/models/root.glb",
                .position = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
            },
            .{
                .authored_id = "child.prop",
                .parent_authored_id = "root.parent",
                .model_path = "assets/models/child.glb",
                .position = .{ .x = 1.0, .y = 0.0, .z = 0.0 },
                .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
            },
        },
    });

    const parent = runtime.lookupEntityByAuthoredId("root.parent").?;
    const child = runtime.lookupEntityByAuthoredId("child.prop").?;

    try runtime.commands.queueSetEnabled(parent, false);
    runtime.applyDeferred();

    try std.testing.expect(!runtime.world.isEnabled(parent));
    try std.testing.expect(!runtime.world.isEnabled(child));
    try std.testing.expect(!runtime.components.activation_states.items[@intCast(parent.index)].?.enabled);
    try std.testing.expect(!runtime.components.activation_states.items[@intCast(child.index)].?.enabled);

    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -5.0 }, 0.0, 0.0, 32.0, 64.0, 1, 1.0 / 60.0);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 0), snapshot.renderables.items.len);
}

test "scene runtime initializes activation state for new entities" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -8.0, .y = -8.0, .z = -8.0 },
        .max = .{ .x = 8.0, .y = 8.0, .z = 8.0 },
    });
    defer runtime.deinit();

    const entity = try runtime.createEntity();
    try std.testing.expect(runtime.components.activation_states.items[@intCast(entity.index)] != null);
    try std.testing.expect(runtime.components.activation_states.items[@intCast(entity.index)].?.enabled);
}

test "scene runtime translates child in parent-aware local space" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -32.0, .y = -32.0, .z = -32.0 },
        .max = .{ .x = 32.0, .y = 32.0, .z = 32.0 },
    });
    defer runtime.deinit();

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -5.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{
            .{
                .authored_id = "root.parent",
                .model_path = "assets/models/root.glb",
                .position = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .scale = .{ .x = 2.0, .y = 2.0, .z = 2.0 },
            },
            .{
                .authored_id = "child.prop",
                .parent_authored_id = "root.parent",
                .model_path = "assets/models/child.glb",
                .position = .{ .x = 1.0, .y = 0.0, .z = 0.0 },
                .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
            },
        },
    });

    const child = runtime.lookupEntityByAuthoredId("child.prop").?;
    try std.testing.expect(runtime.translateEntity(child, .{ .x = 2.0, .y = 0.0, .z = 0.0 }));

    const child_local = runtime.components.local_transforms.items[@intCast(child.index)].?;
    const child_world = runtime.worldTransform(child).?;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), child_local.position.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), child_world.position.x, 1e-4);
}

test "scene runtime updates residency when entities move" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -32.0, .y = -32.0, .z = -32.0 },
        .max = .{ .x = 32.0, .y = 32.0, .z = 32.0 },
    });
    defer runtime.deinit();

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{.{
            .authored_id = "prop.mover",
            .model_path = "assets/models/mover.glb",
            .position = .{ .x = -20.0, .y = 0.0, .z = 0.0 },
            .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        }},
    });

    const entity = runtime.lookupEntityByAuthoredId("prop.mover").?;
    const before = runtime.residency.tree.entity_cells.items[@intCast(entity.index)].?;
    try std.testing.expect(runtime.translateEntity(entity, .{ .x = 40.0, .y = 0.0, .z = 0.0 }));
    const after = runtime.residency.tree.entity_cells.items[@intCast(entity.index)].?;

    try std.testing.expect(before != after);
}

test "scene loader preserves authored script attachments" {
    var camera_scripts = [_]scene_main.SceneScriptConfigEntry{
        .{ .module = "builtin.noop" },
    };
    var model_scripts = [_]scene_main.SceneScriptConfigEntry{
        .{ .module = "builtin.noop" },
    };
    var assets = [_]scene_main.SceneAssetConfigEntry{
        .{
            .type = "camera",
            .id = "camera.main",
            .cameraPosition = .{ 0.0, 1.0, -4.0 },
            .cameraOrientation = .{ 0.0, 0.0 },
            .scripts = camera_scripts[0..],
        },
        .{
            .type = "model",
            .id = "prop.scripted",
            .modelType = "gltf",
            .modelPath = "assets/models/scripted.glb",
            .scripts = model_scripts[0..],
        },
    };
    const scene_file = scene_main.SceneFile{
        .key = "scripted_scene",
        .assets = assets[0..],
    };

    var scene_desc = try scene_main.buildSceneDescription(std.testing.allocator, scene_file, true, true, 1024);
    defer scene_desc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), scene_desc.camera_scripts.len);
    try std.testing.expectEqualStrings("builtin.noop", scene_desc.camera_scripts[0].module_name);
    try std.testing.expectEqual(@as(usize, 1), scene_desc.assets[0].scripts.len);
    try std.testing.expectEqualStrings("builtin.noop", scene_desc.assets[0].scripts[0].module_name);
}

test "scene loader preserves authored parent ids" {
    var assets = [_]scene_main.SceneAssetConfigEntry{
        .{
            .type = "model",
            .id = "root.parent",
            .modelType = "gltf",
            .modelPath = "assets/models/root.glb",
        },
        .{
            .type = "model",
            .id = "child.prop",
            .parent = "root.parent",
            .modelType = "gltf",
            .modelPath = "assets/models/child.glb",
        },
    };
    const scene_file = scene_main.SceneFile{
        .key = "parented_scene",
        .assets = assets[0..],
    };

    var scene_desc = try scene_main.buildSceneDescription(std.testing.allocator, scene_file, true, true, 1024);
    defer scene_desc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), scene_desc.assets.len);
    try std.testing.expect(scene_desc.assets[0].parent_authored_id == null);
    try std.testing.expectEqualStrings("root.parent", scene_desc.assets[1].parent_authored_id.?);
}

test "scene runtime attaches authored scripts during bootstrap" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
            .scripts = &.{.{ .module_name = "builtin.noop" }},
        },
        .lights = &.{},
        .assets = &.{.{
            .authored_id = "prop.scripted",
            .scripts = &.{.{ .module_name = "builtin.noop" }},
            .model_path = "assets/models/scripted.glb",
            .position = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        }},
    });

    const entity = runtime.lookupEntityByAuthoredId("prop.scripted").?;
    const component = runtime.components.scripts.items[@intCast(entity.index)].?;

    try std.testing.expectEqual(@as(u8, 1), component.count);
    try std.testing.expect(component.modules[0].isValid());
    try std.testing.expectEqual(@as(usize, 2), runtime.scripts.instances.items.len);
}

test "scene script lifecycle emits attach begin-play and detach events" {
    LifecycleRecorder.reset();

    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    _ = try runtime.scripts.registerNativeModule(&runtime.assets, "test.lifecycle", .{
        .on_event = LifecycleRecorder.onEvent,
    });

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{.{
            .authored_id = "prop.lifecycle",
            .scripts = &.{.{ .module_name = "test.lifecycle" }},
            .model_path = "assets/models/scripted.glb",
            .position = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        }},
    });

    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.attach_count);

    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 1, 1.0 / 60.0);
    snapshot.deinit();
    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.begin_play_count);

    const entity = runtime.lookupEntityByAuthoredId("prop.lifecycle").?;
    runtime.destroyEntity(entity);

    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.end_play_count);
    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.detach_count);
}

test "scene script lifecycle emits disable end-play enable and begin-play transitions" {
    LifecycleRecorder.reset();

    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    _ = try runtime.scripts.registerNativeModule(&runtime.assets, "test.lifecycle", .{
        .on_event = LifecycleRecorder.onEvent,
    });

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{.{
            .authored_id = "prop.lifecycle",
            .scripts = &.{.{ .module_name = "test.lifecycle" }},
            .model_path = "assets/models/scripted.glb",
            .position = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        }},
    });

    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 1, 1.0 / 60.0);
    snapshot.deinit();

    const entity = runtime.lookupEntityByAuthoredId("prop.lifecycle").?;
    try runtime.commands.queueSetEnabled(entity, false);
    runtime.applyDeferred();
    runtime.scripts.dispatchQueued(&runtime.world, &runtime.components, &scene_main.ScriptInputState{}, &runtime.commands);

    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.disable_count);
    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.end_play_count);

    try runtime.commands.queueSetEnabled(entity, true);
    runtime.applyDeferred();
    runtime.scripts.dispatchQueued(&runtime.world, &runtime.components, &scene_main.ScriptInputState{}, &runtime.commands);

    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.enable_count);
    try std.testing.expectEqual(@as(u32, 2), LifecycleRecorder.begin_play_count);
}

test "scene runtime attachScriptToEntity queues begin-play once after startup" {
    LifecycleRecorder.reset();

    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    _ = try runtime.scripts.registerNativeModule(&runtime.assets, "test.lifecycle", .{
        .on_event = LifecycleRecorder.onEvent,
    });

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{},
    });

    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 1, 1.0 / 60.0);
    snapshot.deinit();

    const entity = try runtime.createEntity();
    try std.testing.expect(try runtime.attachScriptToEntity(entity, "test.lifecycle"));
    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.attach_count);
    try std.testing.expectEqual(@as(u32, 0), LifecycleRecorder.begin_play_count);

    runtime.scripts.dispatchQueued(&runtime.world, &runtime.components, &scene_main.ScriptInputState{}, &runtime.commands);
    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.begin_play_count);

    runtime.scripts.dispatchQueued(&runtime.world, &runtime.components, &scene_main.ScriptInputState{}, &runtime.commands);
    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.begin_play_count);

    snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 2, 1.0 / 60.0);
    snapshot.deinit();
    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.begin_play_count);
}

test "scene script lifecycle emits update fixed-update and late-update events" {
    LifecycleRecorder.reset();

    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    _ = try runtime.scripts.registerNativeModule(&runtime.assets, "test.lifecycle", .{
        .on_event = LifecycleRecorder.onEvent,
    });

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{.{
            .authored_id = "prop.lifecycle",
            .scripts = &.{.{ .module_name = "test.lifecycle" }},
            .model_path = "assets/models/scripted.glb",
            .position = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        }},
    });

    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 1, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.update_count);
    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.fixed_update_count);
    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.late_update_count);
}

test "scene runtime emits selection lifecycle events" {
    LifecycleRecorder.reset();

    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    _ = try runtime.scripts.registerNativeModule(&runtime.assets, "test.lifecycle", .{
        .on_event = LifecycleRecorder.onEvent,
    });

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{.{
            .authored_id = "prop.lifecycle",
            .scripts = &.{.{ .module_name = "test.lifecycle" }},
            .model_path = "assets/models/scripted.glb",
            .position = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        }},
    });

    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 1, 1.0 / 60.0);
    snapshot.deinit();

    const entity = runtime.lookupEntityByAuthoredId("prop.lifecycle").?;
    try runtime.setSelectedEntity(entity);

    snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 2, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.selected_count);
    try std.testing.expect(runtime.components.selectables.items[@intCast(entity.index)].?.selected);

    try runtime.setSelectedEntity(null);

    snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 3, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.deselected_count);
    try std.testing.expect(!runtime.components.selectables.items[@intCast(entity.index)].?.selected);
}

test "scene script lifecycle emits asset ready and lost events" {
    LifecycleRecorder.reset();

    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    _ = try runtime.scripts.registerNativeModule(&runtime.assets, "test.lifecycle", .{
        .on_event = LifecycleRecorder.onEvent,
    });

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{.{
            .authored_id = "prop.lifecycle",
            .scripts = &.{.{ .module_name = "test.lifecycle" }},
            .model_path = "assets/models/scripted.glb",
            .position = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        }},
    });

    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 1, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.asset_ready_count);

    const entity = runtime.lookupEntityByAuthoredId("prop.lifecycle").?;
    const mesh_handle = runtime.components.renderables.items[@intCast(entity.index)].?.mesh;
    try std.testing.expect(try runtime.setAssetState(mesh_handle, .evict_pending));
    runtime.scripts.dispatchQueued(&runtime.world, &runtime.components, &scene_main.ScriptInputState{}, &runtime.commands);

    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.asset_lost_count);
}

test "scene runtime tracks script and physics phase asset pins" {
    LifecycleRecorder.reset();

    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    _ = try runtime.scripts.registerNativeModule(&runtime.assets, "test.lifecycle", .{
        .on_event = LifecycleRecorder.onEvent,
    });

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{.{
            .authored_id = "prop.lifecycle",
            .scripts = &.{.{ .module_name = "test.lifecycle" }},
            .model_path = "assets/models/scripted.glb",
            .position = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
            .physics_motion = .dynamic,
            .physics_mass = 1.0,
        }},
    });

    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 32.0, 64.0, 1, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expect(runtime.stats.script_phase_pins > 0);
    try std.testing.expect(runtime.stats.physics_phase_pins > 0);
}

test "scene script host rejects incompatible abi versions" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -16.0, .y = -16.0, .z = -16.0 },
        .max = .{ .x = 16.0, .y = 16.0, .z = 16.0 },
    });
    defer runtime.deinit();

    try std.testing.expectError(error.IncompatibleScriptModuleAbi, runtime.scripts.registerNativeModule(&runtime.assets, "test.bad_abi", .{
        .abi_version = scene_main.ScriptHostAbiVersion + 1,
        .on_event = LifecycleRecorder.onEvent,
    }));
}

test "scene runtime dependency debug dump reports edges for entity" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -8.0, .y = -8.0, .z = -8.0 },
        .max = .{ .x = 8.0, .y = 8.0, .z = 8.0 },
    });
    defer runtime.deinit();

    const source = try runtime.createEntity();
    const target = try runtime.createEntity();
    const asset = try runtime.assets.register(.mesh, "debug.mesh");
    try runtime.dependencies.addEdge(.{ .source = source, .target = .{ .entity = target }, .kind = .logic });
    try runtime.dependencies.addEdge(.{ .source = source, .target = .{ .asset = asset }, .kind = .asset });

    const dump = try runtime.debugDumpDependenciesForEntity(std.testing.allocator, source);
    defer std.testing.allocator.free(dump);

    try std.testing.expect(std.mem.indexOf(u8, dump, "out kind=logic") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "out kind=asset") != null);
}

test "scene runtime asset residency debug dump reports pin counts and state" {
    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -8.0, .y = -8.0, .z = -8.0 },
        .max = .{ .x = 8.0, .y = 8.0, .z = 8.0 },
    });
    defer runtime.deinit();

    const asset = try runtime.assets.register(.mesh, "debug.mesh");
    _ = try runtime.setAssetState(asset, .resident);
    try std.testing.expect(runtime.assets.pin(asset));

    const dump = try runtime.debugDumpAssetResidency(std.testing.allocator);
    defer std.testing.allocator.free(dump);

    try std.testing.expect(std.mem.indexOf(u8, dump, "state=resident") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "pins=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "name=debug.mesh") != null);
}

test "scene script lifecycle emits residency zone enter and exit events" {
    LifecycleRecorder.reset();

    var runtime = try scene_main.SceneRuntime.init(std.testing.allocator, .{
        .min = .{ .x = -64.0, .y = -64.0, .z = -64.0 },
        .max = .{ .x = 64.0, .y = 64.0, .z = 64.0 },
    });
    defer runtime.deinit();

    _ = try runtime.scripts.registerNativeModule(&runtime.assets, "test.lifecycle", .{
        .on_event = LifecycleRecorder.onEvent,
    });

    try runtime.bootstrapFromDescription(.{
        .camera = .{
            .position = .{ .x = 0.0, .y = 1.0, .z = -4.0 },
            .pitch = 0.0,
            .yaw = 0.0,
            .fov_deg = 60.0,
        },
        .lights = &.{},
        .assets = &.{.{
            .authored_id = "prop.zone",
            .scripts = &.{.{ .module_name = "test.lifecycle" }},
            .model_path = "assets/models/scripted.glb",
            .position = .{ .x = 40.0, .y = 0.0, .z = 0.0 },
            .rotation_deg = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        }},
    });

    var snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 8.0, 12.0, 1, 1.0 / 60.0);
    snapshot.deinit();

    try std.testing.expectEqual(@as(u32, 0), LifecycleRecorder.zone_enter_count);
    try std.testing.expectEqual(@as(u32, 0), LifecycleRecorder.zone_exit_count);

    snapshot = try runtime.updateFrame(.{ .x = 40.0, .y = 1.0, .z = 0.0 }, 0.0, 0.0, 8.0, 12.0, 2, 1.0 / 60.0);
    snapshot.deinit();
    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.zone_enter_count);

    snapshot = try runtime.updateFrame(.{ .x = 0.0, .y = 1.0, .z = -4.0 }, 0.0, 0.0, 8.0, 12.0, 3, 1.0 / 60.0);
    snapshot.deinit();
    try std.testing.expectEqual(@as(u32, 1), LifecycleRecorder.zone_exit_count);
}
