//! Asset Registry module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");
const handles = @import("entity.zig");

pub const AssetHandle = handles.AssetHandle;

pub const AssetKind = enum(u8) {
    mesh,
    texture,
    hdri,
    script_module,
    material,
};

pub const AssetState = enum(u8) {
    unloaded,
    queued,
    loading,
    resident,
    failed,
    evict_pending,
    offloading,
};

pub const AssetRecord = struct {
    kind: AssetKind,
    generation: u32,
    state: AssetState = .unloaded,
    ref_count: u32 = 0,
    pin_count: u32 = 0,
    last_used_frame: u64 = 0,
    residency_priority: u8 = 0,
    debug_name: []u8,
};

pub const AssetRegistry = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(?AssetRecord) = .{},
    free_list: std.ArrayList(u32) = .{},

    /// init initializes Asset Registry state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator) AssetRegistry {
        return .{ .allocator = allocator };
    }

    /// deinit releases resources owned by Asset Registry.
    pub fn deinit(self: *AssetRegistry) void {
        for (self.records.items) |maybe_record| {
            if (maybe_record) |record| self.allocator.free(record.debug_name);
        }
        self.records.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
    }

    /// Updates registry/attachment state for register.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn register(self: *AssetRegistry, kind: AssetKind, debug_name: []const u8) !AssetHandle {
        const name_copy = try self.allocator.dupe(u8, debug_name);
        errdefer self.allocator.free(name_copy);

        if (self.free_list.items.len != 0) {
            const slot = self.free_list.pop().?;
            const index: usize = @intCast(slot);
            const next_generation = if (self.records.items[index]) |record| record.generation +% 1 else 1;
            self.records.items[index] = AssetRecord{
                .kind = kind,
                .generation = if (next_generation == 0) 1 else next_generation,
                .debug_name = name_copy,
            };
            return AssetHandle.init(slot, self.records.items[index].?.generation);
        }

        const slot: u32 = @intCast(self.records.items.len);
        try self.records.append(self.allocator, AssetRecord{
            .kind = kind,
            .generation = 1,
            .debug_name = name_copy,
        });
        return AssetHandle.init(slot, 1);
    }

    /// Returns whether i sl iv e.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn isLive(self: *const AssetRegistry, handle: AssetHandle) bool {
        if (!handle.isValid()) return false;
        const index: usize = @intCast(handle.slot);
        if (index >= self.records.items.len) return false;
        const record = self.records.items[index] orelse return false;
        return record.generation == handle.generation;
    }

    /// get returns state derived from Asset Registry.
    pub fn get(self: *AssetRegistry, handle: AssetHandle) ?*AssetRecord {
        if (!self.isLive(handle)) return null;
        return &self.records.items[@intCast(handle.slot)].?;
    }

    /// getConst returns state derived from Asset Registry.
    pub fn getConst(self: *const AssetRegistry, handle: AssetHandle) ?*const AssetRecord {
        if (!self.isLive(handle)) return null;
        return &self.records.items[@intCast(handle.slot)].?;
    }

    /// Sets s et st at e.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn setState(self: *AssetRegistry, handle: AssetHandle, state: AssetState) bool {
        const record = self.get(handle) orelse return false;
        record.state = state;
        return true;
    }

    /// Performs retain.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn retain(self: *AssetRegistry, handle: AssetHandle) bool {
        const record = self.get(handle) orelse return false;
        record.ref_count += 1;
        return true;
    }

    /// Performs release.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn release(self: *AssetRegistry, handle: AssetHandle) bool {
        const record = self.get(handle) orelse return false;
        if (record.ref_count != 0) record.ref_count -= 1;
        return true;
    }

    /// Updates registry/attachment state for pin.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn pin(self: *AssetRegistry, handle: AssetHandle) bool {
        const record = self.get(handle) orelse return false;
        record.pin_count += 1;
        return true;
    }

    /// Updates registry/attachment state for unpin.
    /// Keeps invariants on `self` centralized so callers do not duplicate state transitions.
    pub fn unpin(self: *AssetRegistry, handle: AssetHandle) bool {
        const record = self.get(handle) orelse return false;
        if (record.pin_count != 0) record.pin_count -= 1;
        return true;
    }

    /// destroy destroys or reclaims Asset Registry resources.
    pub fn destroy(self: *AssetRegistry, handle: AssetHandle) bool {
        if (!self.isLive(handle)) return false;
        const index: usize = @intCast(handle.slot);
        const record = self.records.items[index].?;
        if (record.pin_count != 0) return false;
        self.allocator.free(record.debug_name);
        self.records.items[index] = null;
        self.free_list.append(self.allocator, handle.slot) catch return false;
        return true;
    }

    pub fn debugDump(self: *const AssetRegistry, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8){};
        errdefer buffer.deinit(allocator);
        const writer = buffer.writer(allocator);
        try writer.print("assets={d}\n", .{self.records.items.len - self.free_list.items.len});
        for (self.records.items, 0..) |maybe_record, index| {
            const record = maybe_record orelse continue;
            try writer.print(
                "asset[{d}] kind={s} generation={d} state={s} refs={d} pins={d} last_used={d} priority={d} name={s}\n",
                .{
                    index,
                    @tagName(record.kind),
                    record.generation,
                    @tagName(record.state),
                    record.ref_count,
                    record.pin_count,
                    record.last_used_frame,
                    record.residency_priority,
                    record.debug_name,
                },
            );
        }
        return buffer.toOwnedSlice(allocator);
    }
};
