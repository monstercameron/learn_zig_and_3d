//! Physics Utils module.
//! Physics helper utilities for scene simulation and rigid-body integration.

const std = @import("std");
const zphysics = @import("zphysics");

pub const BPLayerInterface = extern struct {
    interface: zphysics.BroadPhaseLayerInterface = .init(@This()),

    /// getNumBroadPhaseLayers returns state derived from Physics Utils.
    pub fn getNumBroadPhaseLayers(self: *const zphysics.BroadPhaseLayerInterface) callconv(.c) u32 {
        _ = self;
        return 2;
    }

    /// getBroadPhaseLayer returns state derived from Physics Utils.
    pub fn getBroadPhaseLayer(self: *const zphysics.BroadPhaseLayerInterface, in_layer: zphysics.ObjectLayer) callconv(.c) zphysics.BroadPhaseLayer {
        _ = self;
        return if (in_layer == 0) 0 else 1;
    }
};

pub const ObjectVsBroadPhaseLayerFilterImpl = extern struct {
    filter: zphysics.ObjectVsBroadPhaseLayerFilter = .init(@This()),
    /// Returns whether s ho ul dc ol li de.
    /// Applies physics state changes in one place so simulation invariants remain coherent across frame steps.
    pub fn shouldCollide(self: *const zphysics.ObjectVsBroadPhaseLayerFilter, layer1: zphysics.ObjectLayer, layer2: zphysics.BroadPhaseLayer) callconv(.c) bool {
        _ = self;
        return if (layer1 == 0) layer2 != 0 else true;
    }
};

pub const ObjectLayerPairFilterImpl = extern struct {
    filter: zphysics.ObjectLayerPairFilter = .init(@This()),
    /// Returns whether s ho ul dc ol li de.
    /// Applies physics state changes in one place so simulation invariants remain coherent across frame steps.
    pub fn shouldCollide(self: *const zphysics.ObjectLayerPairFilter, layer1: zphysics.ObjectLayer, layer2: zphysics.ObjectLayer) callconv(.c) bool {
        _ = self;
        return if (layer1 == 0) layer2 != 0 else true;
    }
};

pub const object_layers = struct {
    pub const non_moving: zphysics.ObjectLayer = 0;
    pub const moving: zphysics.ObjectLayer = 1;
};

pub const PhysicsWorld = struct {
    system: *zphysics.PhysicsSystem,
    bpa: BPLayerInterface,
    ovb: ObjectVsBroadPhaseLayerFilterImpl,
    olp: ObjectLayerPairFilterImpl,

    /// init initializes Physics Utils state and returns the configured value.
    pub fn init(allocator: std.mem.Allocator) !*PhysicsWorld {
        var pw = try allocator.create(PhysicsWorld);
        pw.bpa = .{};
        pw.ovb = .{};
        pw.olp = .{};

        pw.system = try zphysics.PhysicsSystem.create(
            &pw.bpa.interface,
            &pw.ovb.filter,
            &pw.olp.filter,
            .{
                .max_bodies = 1024,
                .num_body_mutexes = 0,
                .max_body_pairs = 1024,
                .max_contact_constraints = 1024,
            },
        );

        return pw;
    }

    /// deinit releases resources owned by Physics Utils.
    pub fn deinit(self: *PhysicsWorld, allocator: std.mem.Allocator) void {
        zphysics.PhysicsSystem.destroy(self.system);
        allocator.destroy(self);
    }
};
