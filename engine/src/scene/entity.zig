//! Entity module.
//! Scene-system module for entity data, graph dependencies, extraction, and streaming/residency.

const std = @import("std");

pub const invalid_index = std.math.maxInt(u32);

pub const EntityId = packed struct(u64) {
    index: u32,
    generation: u32,

    /// init initializes Entity state and returns the configured value.
    pub fn init(index: u32, generation: u32) EntityId {
        return .{ .index = index, .generation = generation };
    }

    /// Returns the invalid sentinel value for this handle/id type.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn invalid() EntityId {
        return .{ .index = invalid_index, .generation = 0 };
    }

    /// Returns whether i sv al id.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn isValid(self: EntityId) bool {
        return self.index != invalid_index and self.generation != 0;
    }

    /// Returns whether the two values are equal.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn eql(self: EntityId, other: EntityId) bool {
        return self.index == other.index and self.generation == other.generation;
    }
};

pub const AssetHandle = packed struct(u64) {
    slot: u32,
    generation: u32,

    /// init initializes Entity state and returns the configured value.
    pub fn init(slot: u32, generation: u32) AssetHandle {
        return .{ .slot = slot, .generation = generation };
    }

    /// Returns the invalid sentinel value for this handle/id type.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn invalid() AssetHandle {
        return .{ .slot = invalid_index, .generation = 0 };
    }

    /// Returns whether i sv al id.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn isValid(self: AssetHandle) bool {
        return self.slot != invalid_index and self.generation != 0;
    }

    /// Returns whether the two values are equal.
    /// Keeps scene/component bookkeeping centralized so call sites do not duplicate ownership or lifetime rules.
    pub fn eql(self: AssetHandle, other: AssetHandle) bool {
        return self.slot == other.slot and self.generation == other.generation;
    }
};

pub const SceneNodeId = packed struct(u64) {
    value: u64,

    /// init initializes Entity state and returns the configured value.
    pub fn init(value: u64) SceneNodeId {
        return .{ .value = value };
    }
};
