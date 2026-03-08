# Meshlet-First Packet Shadowing Spec

This file is a design sketch for a future-facing shadow path. It describes the intended packet-oriented meshlet shadowing model and the supporting data structures, not a promise that the entire flow is active in the renderer today.

## Overview

The core idea is to keep shadowing aligned with the meshlet-first direction of the renderer:

- use meshlets as the coarse shadow work unit
- keep BVH traversal packet-friendly
- stage tile-local shading work in batches instead of tracing one pixel at a time
- preserve early-out opportunities when a full packet becomes occluded

## 1. Data Structures

```zig
const math = @import("math.zig");

// --- BVH & Meshlet Structures ---

pub const AABB = struct {
    min: math.Vec3,
    max: math.Vec3,
};

pub const BoundingSphere = struct {
    center: math.Vec3,
    radius: f32,
};

pub const TLASNode = struct {
    aabb: AABB,
    // If leaf, points to an Instance. If internal, points to child nodes.
    left_child_or_instance: u32,
    right_child_or_count: u32,
    is_leaf: bool,
};

pub const BLASNode = struct {
    aabb: AABB,
    // If leaf, points to a Meshlet. If internal, points to child nodes.
    left_child_or_meshlet: u32,
    right_child_or_count: u32,
    is_leaf: bool,
};

// Augmented Meshlet for shadowing
pub const ShadowMeshlet = struct {
    bound_sphere: BoundingSphere,
    bound_aabb: AABB,
    triangle_offset: u32,
    triangle_count: u16,
    // Optional: micro-BVH root for this meshlet's triangles
    micro_bvh_offset: u32, 
};

// Tightly packed triangles for fast SIMD intersection
pub const ShadowTriangle = struct {
    v0: math.Vec3,
    edge1: math.Vec3,
    edge2: math.Vec3,
};
```

## 2. Frame Graph And Job Flow

1.  **Main Rasterization**: Generate G-Buffer (Depth, Normals, Albedo, etc.) as usual.
2.  **TLAS Update Job**: Rebuild or refit the Top-Level Acceleration Structure over all visible/shadow-casting instances.
3.  **Light Setup Job**: 
    *   Compute light matrices.
    *   (Optional for Sun) Bin meshlets into a 2D light-space grid for fast directional light culling.
4.  **Tile Lighting & Shadowing Jobs** (The core integration):
    *   Run per-tile (e.g., 8x8 or 16x16 pixels).
    *   **Staging**: Convert the tile's active G-Buffer pixels (AoS) into an SoA scratchpad for SIMD processing.
    *   **Directional Light**: Traverse light-space meshlet bins -> packet intersect -> resolve shadow factor.
    *   **Point/Spot Lights**: Tile light culling -> TLAS -> BLAS -> Micro-BVH -> packet intersect -> resolve.
    *   **Accumulation**: Apply shadowed lighting to the tile.

## 3. Tile Job Pseudocode

```zig
fn processTileShadows(tile: *Tile, tlas: *TLAS, directional_light: Light) void {
    // 1. Stage AoS PixelData to SoA for this tile
    var ray_origins_x: [TILE_SIZE]f32 = undefined;
    var ray_origins_y: [TILE_SIZE]f32 = undefined;
    var ray_origins_z: [TILE_SIZE]f32 = undefined;
    // ... setup rays ...

    // 2. Coarse Tile Culling against Light
    if (!lightIntersectsTile(directional_light, tile.aabb)) return;

    // 3. Traverse TLAS with the Ray Packet (or tile bounding box)
    var candidate_instances = traverseTLAS(tlas, tile.aabb, directional_light.dir);

    for (candidate_instances) |instance| {
        // 4. Transform ray packet to Instance Local Space
        const local_rays = transformRays(ray_packet, instance.inverse_transform);
        
        // 5. Traverse BLAS for this component
        var candidate_meshlets = traverseBLAS(instance.blas, local_rays);

        for (candidate_meshlets) |meshlet| {
            // 6. Meshlet Conservative Rejection (Cone/AABB)
            if (rejectMeshlet(meshlet, local_rays)) continue;

            // 7. Micro-BVH / Triangle Packet Any-Hit
            intersectMicroBVH(meshlet.micro_bvh, local_rays);
            
            if (allRaysOccluded(local_rays)) break; // Early out!
        }
    }

    // 8. Write shadow factors back or accumulate
    accumulateLighting(tile, ray_packet.shadow_factors);
}
```

## Notes

- This spec is most useful when working on `src/shadow_system.zig`, meshlet shadow traversal, or packet-oriented lighting experiments.
- If the live renderer diverges from this document, the code is authoritative and this file should be updated rather than treated as ground truth.
