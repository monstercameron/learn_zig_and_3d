//! Script Host module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const handles = @import("entity.zig");
const AssetRegistry = @import("asset_registry.zig").AssetRegistry;
const World = @import("world.zig").World;
const Commands = @import("world.zig").Commands;

pub const EntityId = handles.EntityId;
pub const AssetHandle = handles.AssetHandle;
pub const abi_version: u32 = 1;

pub const ScriptEvent = union(enum) {
    attach,
    detach,
    enable,
    disable,
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
    world: *const World,
    commands: *Commands,
    entity: EntityId,
    user_data: ?*anyopaque,
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
    pub fn attachScript(self: *ScriptHost, world: *World, commands: *Commands, entity: EntityId, module: AssetHandle) !void {
        try self.instances.append(self.allocator, .{
            .module = module,
            .entity = entity,
        });
        if (self.findModule(module)) |module_record| {
            if (module_record.vtable.on_create) |on_create| {
                var ctx = ScriptCallbackContext{
                    .world = world,
                    .commands = commands,
                    .entity = entity,
                    .user_data = null,
                    .event = .attach,
                };
                on_create(&ctx);
            }
            self.dispatchImmediate(module_record, world, commands, entity, null, .attach);
        }
    }

    /// destroyInstancesForEntity destroys or reclaims Script Host resources.
    pub fn destroyInstancesForEntity(self: *ScriptHost, world: *World, commands: *Commands, entity: EntityId) void {
        var write_index: usize = 0;
        for (self.instances.items) |instance| {
            if (instance.entity.eql(entity)) {
                if (self.findModule(instance.module)) |module_record| {
                    if (instance.began_play) self.dispatchImmediate(module_record, world, commands, entity, instance.user_data, .end_play);
                    self.dispatchImmediate(module_record, world, commands, entity, instance.user_data, .detach);
                    if (module_record.vtable.on_destroy) |on_destroy| {
                        var ctx = ScriptCallbackContext{
                            .world = world,
                            .commands = commands,
                            .entity = entity,
                            .user_data = instance.user_data,
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

    /// dispatchQueued dispatches Script Host jobs across workers.
    pub fn dispatchQueued(self: *ScriptHost, world: *World, commands: *Commands) void {
        for (self.queued_events.items) |queued| {
            for (self.instances.items) |instance| {
                if (!instance.entity.eql(queued.entity)) continue;
                if (!shouldDispatchQueuedEvent(instance, queued.event)) continue;
                const module_record = self.findModule(instance.module) orelse continue;
                var ctx = ScriptCallbackContext{
                    .world = world,
                    .commands = commands,
                    .entity = queued.entity,
                    .user_data = instance.user_data,
                    .event = queued.event,
                };
                module_record.vtable.on_event(&ctx);
            }
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
        commands: *Commands,
        entity: EntityId,
        user_data: ?*anyopaque,
        event: ScriptEvent,
    ) void {
        _ = self;
        var ctx = ScriptCallbackContext{
            .world = world,
            .commands = commands,
            .entity = entity,
            .user_data = user_data,
            .event = event,
        };
        module_record.vtable.on_event(&ctx);
    }
};

fn shouldDispatchQueuedEvent(instance: ScriptInstance, event: ScriptEvent) bool {
    return switch (event) {
        .update, .fixed_update, .late_update => instance.enabled,
        else => true,
    };
}
