//! Script Host module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const platform_input = @import("platform_input");
const input_actions = @import("input_actions");
const job_system = @import("job_system");
const handles = @import("entity.zig");
const AssetRegistry = @import("asset_registry.zig").AssetRegistry;
const ComponentStore = @import("components.zig").ComponentStore;
const World = @import("world.zig").World;
const Commands = @import("world.zig").Commands;

pub const EntityId = handles.EntityId;
pub const AssetHandle = handles.AssetHandle;
pub const abi_version: u32 = 1;

pub const ScriptLookDelta = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
};

pub const ScriptInputState = struct {
    first_person_active: bool = false,
    keyboard: platform_input.KeyboardState = .{},
    mouse: platform_input.MouseState = .{},
    actions: input_actions.ActionState = .{},
    look_delta: ScriptLookDelta = .{},

    pub fn setKey(self: *ScriptInputState, key: platform_input.Key, is_down: bool) void {
        _ = self.keyboard.setKey(key, is_down);
    }

    pub fn setMouseButton(self: *ScriptInputState, button: platform_input.MouseButton, is_down: bool) void {
        _ = self.mouse.setButton(button, is_down);
    }
};

pub const empty_input_state = ScriptInputState{};

pub const ScriptEvent = union(enum) {
    attach,
    detach,
    enable,
    disable,
    k_pressed,
    selected,
    deselected,
    begin_play,
    end_play,
    update: f32,
    fixed_update: f32,
    late_update: f32,
    parent_changed,
    transform_changed,
    asset_ready: AssetHandle,
    asset_lost: AssetHandle,
    zone_enter: EntityId,
    zone_exit: EntityId,
    destroy_requested,
};

pub const ScriptCallbackContext = struct {
    allocator: std.mem.Allocator,
    world: *const World,
    components: *const ComponentStore,
    commands: *Commands,
    entity: EntityId,
    user_data: ?*anyopaque,
    user_data_slot: *?*anyopaque,
    input: *const ScriptInputState,
    event: ScriptEvent,
};

pub const ScriptModuleVTable = struct {
    abi_version: u32 = abi_version,
    on_create: ?*const fn (ctx: *ScriptCallbackContext) void = null,
    on_destroy: ?*const fn (ctx: *ScriptCallbackContext) void = null,
    on_event: *const fn (ctx: *ScriptCallbackContext) void,
};

pub const ScriptModuleRecord = struct {
    handle: AssetHandle,
    name: []u8,
    vtable: ScriptModuleVTable,
};

pub const ScriptInstance = struct {
    module: AssetHandle,
    entity: EntityId,
    enabled: bool = true,
    user_data: ?*anyopaque = null,
    began_play: bool = false,
};

pub const QueuedScriptEvent = struct {
    entity: EntityId,
    event: ScriptEvent,
};

pub const ScriptHost = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(ScriptModuleRecord) = .{},
    instances: std.ArrayList(ScriptInstance) = .{},
    queued_events: std.ArrayList(QueuedScriptEvent) = .{},

    /// init initializes Script Host state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator) ScriptHost {
        return .{ .allocator = allocator };
    }

    /// deinit releases resources owned by Script Host.
    pub fn deinit(self: *ScriptHost) void {
        for (self.modules.items) |module| self.allocator.free(module.name);
        self.modules.deinit(self.allocator);
        self.instances.deinit(self.allocator);
        self.queued_events.deinit(self.allocator);
    }

    /// Registers r eg is te rn at iv em od ul e with the owning system.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn registerNativeModule(self: *ScriptHost, registry: *AssetRegistry, name: []const u8, vtable: ScriptModuleVTable) !AssetHandle {
        if (vtable.abi_version != abi_version) return error.IncompatibleScriptModuleAbi;
        const handle = try registry.register(.script_module, name);
        _ = registry.setState(handle, .resident);
        _ = registry.retain(handle);
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.modules.append(self.allocator, .{
            .handle = handle,
            .name = name_copy,
            .vtable = vtable,
        });
        return handle;
    }

    pub fn lookupModuleByName(self: *const ScriptHost, name: []const u8) ?AssetHandle {
        for (self.modules.items) |module| {
            if (std.mem.eql(u8, module.name, name)) return module.handle;
        }
        return null;
    }

    /// Updates registry/attachment state for attach script.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn attachScript(self: *ScriptHost, world: *World, components: *const ComponentStore, commands: *Commands, entity: EntityId, module: AssetHandle) !void {
        try self.instances.append(self.allocator, .{
            .module = module,
            .entity = entity,
        });
        const instance = &self.instances.items[self.instances.items.len - 1];
        if (self.findModule(module)) |module_record| {
            if (module_record.vtable.on_create) |on_create| {
                var ctx = ScriptCallbackContext{
                    .allocator = self.allocator,
                    .world = world,
                    .components = components,
                    .commands = commands,
                    .entity = entity,
                    .user_data = instance.user_data,
                    .user_data_slot = &instance.user_data,
                    .input = &empty_input_state,
                    .event = .attach,
                };
                on_create(&ctx);
            }
            self.dispatchImmediate(module_record, world, components, &empty_input_state, commands, entity, &instance.user_data, .attach);
        }
    }

    pub fn detachScript(self: *ScriptHost, world: *World, components: *const ComponentStore, commands: *Commands, entity: EntityId, module: AssetHandle) bool {
        var removed = false;
        var write_index: usize = 0;
        for (self.instances.items) |instance| {
            const matches = instance.entity.eql(entity) and instance.module.eql(module);
            if (matches) {
                removed = true;
                var user_data = instance.user_data;
                if (self.findModule(instance.module)) |module_record| {
                    if (instance.began_play) self.dispatchImmediate(module_record, world, components, &empty_input_state, commands, entity, &user_data, .end_play);
                    self.dispatchImmediate(module_record, world, components, &empty_input_state, commands, entity, &user_data, .detach);
                    if (module_record.vtable.on_destroy) |on_destroy| {
                        var ctx = ScriptCallbackContext{
                            .allocator = self.allocator,
                            .world = world,
                            .components = components,
                            .commands = commands,
                            .entity = entity,
                            .user_data = user_data,
                            .user_data_slot = &user_data,
                            .input = &empty_input_state,
                            .event = .detach,
                        };
                        on_destroy(&ctx);
                    }
                }
                continue;
            }
            self.instances.items[write_index] = instance;
            write_index += 1;
        }
        self.instances.items.len = write_index;
        return removed;
    }

    /// destroyInstancesForEntity destroys or reclaims Script Host resources.
    pub fn destroyInstancesForEntity(self: *ScriptHost, world: *World, components: *const ComponentStore, commands: *Commands, entity: EntityId) void {
        var write_index: usize = 0;
        for (self.instances.items) |instance| {
            if (instance.entity.eql(entity)) {
                var user_data = instance.user_data;
                if (self.findModule(instance.module)) |module_record| {
                    if (instance.began_play) self.dispatchImmediate(module_record, world, components, &empty_input_state, commands, entity, &user_data, .end_play);
                    self.dispatchImmediate(module_record, world, components, &empty_input_state, commands, entity, &user_data, .detach);
                    if (module_record.vtable.on_destroy) |on_destroy| {
                        var ctx = ScriptCallbackContext{
                            .allocator = self.allocator,
                            .world = world,
                            .components = components,
                            .commands = commands,
                            .entity = entity,
                            .user_data = user_data,
                            .user_data_slot = &user_data,
                            .input = &empty_input_state,
                            .event = .detach,
                        };
                        on_destroy(&ctx);
                    }
                }
                continue;
            }
            self.instances.items[write_index] = instance;
            write_index += 1;
        }
        self.instances.items.len = write_index;
    }

    /// Queues a deferred request/event for processing at a safe synchronization point.
    /// It appends a request for deferred processing so mutation happens at a safe sync point.
    pub fn queueEvent(self: *ScriptHost, entity: EntityId, event: ScriptEvent) !void {
        try self.queued_events.append(self.allocator, .{ .entity = entity, .event = event });
    }

    /// dispatchQueued processes queued script events, using the job system for larger dispatch batches.
    pub fn dispatchQueued(
        self: *ScriptHost,
        job_sys: *job_system.JobSystem,
        world: *World,
        components: *const ComponentStore,
        input: *const ScriptInputState,
        commands: *Commands,
    ) void {
        for (self.queued_events.items) |queued| {
            self.dispatchQueuedEvent(job_sys, world, components, input, commands, queued);
        }
        self.queued_events.clearRetainingCapacity();
    }

    /// Queues a deferred request/event for processing at a safe synchronization point.
    /// It appends a request for deferred processing so mutation happens at a safe sync point.
    pub fn queueBeginPlayForPending(self: *ScriptHost, world: *const World) !void {
        for (self.instances.items) |*instance| {
            if (instance.began_play or !instance.enabled or !world.isAlive(instance.entity)) continue;
            try self.queueEvent(instance.entity, .begin_play);
            instance.began_play = true;
        }
    }

    pub fn queueBeginPlayForEntity(self: *ScriptHost, world: *const World, entity: EntityId) !void {
        for (self.instances.items) |*instance| {
            if (!instance.entity.eql(entity) or instance.began_play or !instance.enabled or !world.isAlive(entity)) continue;
            try self.queueEvent(entity, .begin_play);
            instance.began_play = true;
        }
    }

    /// Queues a deferred request/event for processing at a safe synchronization point.
    /// It appends a request for deferred processing so mutation happens at a safe sync point.
    pub fn queueUpdateForAll(self: *ScriptHost, world: *const World, delta_seconds: f32) !void {
        for (self.instances.items) |instance| {
            if (!instance.enabled or !world.isAlive(instance.entity)) continue;
            try self.queueEvent(instance.entity, .{ .update = delta_seconds });
        }
    }

    /// Queues a deferred request/event for processing at a safe synchronization point.
    /// It appends a request for deferred processing so mutation happens at a safe sync point.
    pub fn queueFixedUpdateForAll(self: *ScriptHost, world: *const World, delta_seconds: f32, step_count: u32) !void {
        if (step_count == 0) return;
        var step_index: u32 = 0;
        while (step_index < step_count) : (step_index += 1) {
            for (self.instances.items) |instance| {
                if (!instance.enabled or !world.isAlive(instance.entity)) continue;
                try self.queueEvent(instance.entity, .{ .fixed_update = delta_seconds });
            }
        }
    }

    /// Queues a deferred request/event for processing at a safe synchronization point.
    /// It appends a request for deferred processing so mutation happens at a safe sync point.
    pub fn queueLateUpdateForAll(self: *ScriptHost, world: *const World, delta_seconds: f32) !void {
        for (self.instances.items) |instance| {
            if (!instance.enabled or !world.isAlive(instance.entity)) continue;
            try self.queueEvent(instance.entity, .{ .late_update = delta_seconds });
        }
    }

    /// Queues a K-key press input event for active script instances.
    pub fn queueKPressedForAll(self: *ScriptHost, world: *const World) !void {
        for (self.instances.items) |instance| {
            if (!instance.enabled or !world.isAlive(instance.entity)) continue;
            try self.queueEvent(instance.entity, .k_pressed);
        }
    }

    pub fn setEntityEnabled(self: *ScriptHost, world: *const World, entity: EntityId, enabled: bool) !void {
        for (self.instances.items) |*instance| {
            if (!instance.entity.eql(entity) or instance.enabled == enabled) continue;
            instance.enabled = enabled;
            if (enabled) {
                try self.queueEvent(entity, .enable);
                if (!instance.began_play and world.isAlive(entity)) {
                    try self.queueEvent(entity, .begin_play);
                    instance.began_play = true;
                }
            } else {
                try self.queueEvent(entity, .disable);
                if (instance.began_play) {
                    try self.queueEvent(entity, .end_play);
                    instance.began_play = false;
                }
            }
        }
    }

    fn findModule(self: *const ScriptHost, handle: AssetHandle) ?*const ScriptModuleRecord {
        for (self.modules.items) |*module| {
            if (module.handle.eql(handle)) return module;
        }
        return null;
    }

    fn dispatchImmediate(
        self: *ScriptHost,
        module_record: *const ScriptModuleRecord,
        world: *World,
        components: *const ComponentStore,
        input: *const ScriptInputState,
        commands: *Commands,
        entity: EntityId,
        user_data_slot: *?*anyopaque,
        event: ScriptEvent,
    ) void {
        var ctx = ScriptCallbackContext{
            .allocator = self.allocator,
            .world = world,
            .components = components,
            .commands = commands,
            .entity = entity,
            .user_data = user_data_slot.*,
            .user_data_slot = user_data_slot,
            .input = input,
            .event = event,
        };
        module_record.vtable.on_event(&ctx);
    }

    fn dispatchQueuedEvent(
        self: *ScriptHost,
        job_sys: *job_system.JobSystem,
        world: *World,
        components: *const ComponentStore,
        input: *const ScriptInputState,
        commands: *Commands,
        queued: QueuedScriptEvent,
    ) void {
        const match_count = self.countMatchingInstances(queued);
        if (match_count == 0) return;

        const chunk_size = preferredDispatchChunkSize(job_sys.worker_count, match_count);
        if (match_count <= chunk_size or job_sys.worker_count <= 1) {
            self.dispatchQueuedEventSync(world, components, input, commands, queued);
            return;
        }

        const max_chunk_count = (match_count + chunk_size - 1) / chunk_size;
        const match_indices = self.allocator.alloc(usize, match_count) catch {
            self.dispatchQueuedEventSync(world, components, input, commands, queued);
            return;
        };
        defer self.allocator.free(match_indices);
        const jobs = self.allocator.alloc(job_system.Job, max_chunk_count) catch {
            self.dispatchQueuedEventSync(world, components, input, commands, queued);
            return;
        };
        defer self.allocator.free(jobs);
        const work_items = self.allocator.alloc(ScriptDispatchJob, max_chunk_count) catch {
            self.dispatchQueuedEventSync(world, components, input, commands, queued);
            return;
        };
        defer self.allocator.free(work_items);
        var match_write: usize = 0;
        const ordered_commands = self.allocator.alloc(Commands, match_count) catch {
            self.dispatchQueuedEventSync(world, components, input, commands, queued);
            return;
        };
        defer {
            for (ordered_commands[0..match_write]) |*local| local.deinit();
            self.allocator.free(ordered_commands);
        }

        for (self.instances.items, 0..) |instance, instance_index| {
            if (!instance.entity.eql(queued.entity)) continue;
            if (!shouldDispatchQueuedEvent(instance, queued.event)) continue;
            if (self.findModule(instance.module) == null) continue;
            match_indices[match_write] = instance_index;
            match_write += 1;
        }

        if (match_write == 0) return;
        for (ordered_commands[0..match_write]) |*local| {
            local.* = Commands.init(self.allocator);
        }

        var parent_job = job_system.Job.init(noopScriptDispatchJob, @ptrFromInt(1), null);
        parent_job.setClass(.high);
        var job_count: usize = 0;
        var start_index: usize = 0;
        while (start_index < match_write) : (start_index += chunk_size) {
            const end_index = @min(match_write, start_index + chunk_size);
            work_items[job_count] = .{
                .host = self,
                .world = world,
                .components = components,
                .input = input,
                .queued = queued,
                .match_indices = match_indices[start_index..end_index],
                .command_buffers = ordered_commands[start_index..end_index],
            };
            jobs[job_count] = job_system.Job.init(runScriptDispatchJob, @ptrCast(&work_items[job_count]), &parent_job);
            jobs[job_count].setClass(.high);
            if (!job_sys.submitJobWithClass(&jobs[job_count], .high)) {
                runScriptDispatchJob(@ptrCast(&work_items[job_count]));
            }
            job_count += 1;
        }

        parent_job.complete();
        job_sys.waitFor(&parent_job);

        for (ordered_commands[0..match_write]) |*local| {
            commands.appendFrom(local) catch {};
        }
    }

    fn dispatchQueuedEventSync(
        self: *ScriptHost,
        world: *World,
        components: *const ComponentStore,
        input: *const ScriptInputState,
        commands: *Commands,
        queued: QueuedScriptEvent,
    ) void {
        for (self.instances.items) |*instance| {
            if (!instance.entity.eql(queued.entity)) continue;
            if (!shouldDispatchQueuedEvent(instance.*, queued.event)) continue;
            const module_record = self.findModule(instance.module) orelse continue;
            self.dispatchImmediate(module_record, world, components, input, commands, queued.entity, &instance.user_data, queued.event);
        }
    }

    fn countMatchingInstances(self: *const ScriptHost, queued: QueuedScriptEvent) usize {
        var count: usize = 0;
        for (self.instances.items) |instance| {
            if (!instance.entity.eql(queued.entity)) continue;
            if (!shouldDispatchQueuedEvent(instance, queued.event)) continue;
            if (self.findModule(instance.module) == null) continue;
            count += 1;
        }
        return count;
    }
};

const ScriptDispatchJob = struct {
    host: *ScriptHost,
    world: *World,
    components: *const ComponentStore,
    input: *const ScriptInputState,
    queued: QueuedScriptEvent,
    match_indices: []const usize,
    command_buffers: []Commands,
};

fn preferredDispatchChunkSize(worker_count: u32, match_count: usize) usize {
    const desired_jobs = @max(@as(usize, 1), @as(usize, @intCast(worker_count)) * 2);
    return @max(@as(usize, 1), (match_count + desired_jobs - 1) / desired_jobs);
}

fn runScriptDispatchJob(ctx: *anyopaque) void {
    const job: *ScriptDispatchJob = @ptrCast(@alignCast(ctx));
    for (job.match_indices, 0..) |instance_index, local_index| {
        const instance = &job.host.instances.items[instance_index];
        const module_record = job.host.findModule(instance.module) orelse continue;
        job.host.dispatchImmediate(
            module_record,
            job.world,
            job.components,
            job.input,
            &job.command_buffers[local_index],
            job.queued.entity,
            &instance.user_data,
            job.queued.event,
        );
    }
}

fn noopScriptDispatchJob(_: *anyopaque) void {}

fn shouldDispatchQueuedEvent(instance: ScriptInstance, event: ScriptEvent) bool {
    return switch (event) {
        .update, .fixed_update, .late_update => instance.enabled,
        else => true,
    };
}
