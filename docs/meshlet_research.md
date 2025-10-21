# Meshlet Research Notes

## Goals
- Establish practical meshlet sizes for CPU rasterization.
- Identify bounding volume options and culling costs.
- Summarize data layouts compatible with future GPU mesh shader pipelines.

## Meshlet Sizing
- Typical GPU guidance (NVidia/AMD) suggests keeping meshlets under 64 vertices and 126 triangles to fit register/shared memory limits.
- For CPU workload, cache-friendly chunks of 32–64 vertices strike a balance between reuse and per-job overhead.
- Larger meshlets (128+ verts) reduce total meshlet count but increase worst-case overdraw and clipping complexity.
- Plan: start with targets of 64 vertices / 126 primitives, allow configurable caps per asset.

### CPU Cache Budget
- Assume a per-core L2 cache budget of ~512 KiB (modern desktop CPUs range 256 KiB – 1 MiB).
- Scratch data per meshlet job:
  - Transformed positions/attributes: `64 verts × (position + normal + uv ≈ 32 bytes)` ≈ 2 KiB.
  - Primitive data: `126 tris × 12 bytes` ≈ 1.5 KiB.
  - Tile binning output / temporary buffers: budget another 2–4 KiB.
- Total working set per job ≈ 8 KiB, leaving plenty of headroom for the thread’s code and other data within L2.
- Guideline: cap meshlets at 4 KiB of vertex attribute reads and <8 KiB total working set so multiple meshlet jobs can coexist in L2 without evicting each other.

## Bounding Volumes
- Bounding spheres offer fast scalar culling (distance compare) and fit well with uniform scaling.
- AABBs provide tighter fits for elongated meshlets at marginal extra cost.
- Hybrid approach: sphere for quick reject, optional AABB for secondary test if precision needed.
- For CPU task stage we can store both center/radius and min/max vectors; memory cost acceptable for few kilobytes total.

## Data Layout
- Store per-mesh arrays:
  - `mesh_vertices`: shared vertex positions/attributes.
  - `meshlets`: array of descriptors `{ vertex_offset, vertex_count, primitive_offset, primitive_count, bounds }`.
  - `meshlet_vertices`: tightly packed indices into `mesh_vertices` (8- or 16-bit when possible).
  - `meshlet_primitives`: groups of 3 local vertex indices (packed 10-bit or fallback 16-bit).
- Keep meshlet data contiguous to improve sequential streaming for task jobs.
- Precompute per-meshlet cone or normal average if we later add backface cone culling.

## Culling Strategy
- Primary frustum test using bounding sphere; fallback to AABB for borderline cases.
- Optional backface cone test: use meshlet normal cone (dot > threshold) to skip meshlets fully facing away.
- Near-plane handling: treat meshlets intersecting the near plane as visible and rely on per-primitive clipping.

## Job Scheduling Considerations
- Each meshlet job should allocate scratch space for transformed vertices (~64 entries) from a per-thread pool to avoid repeated allocations.
- Visible meshlets can be pushed into a lock-free queue; worker threads pop and process in depth-sorted order if required.
- Maintain statistics (culled, processed, emitted triangles) for telemetry.

## Open Questions
- How to handle LOD transitions? Potentially swap meshlet sets based on distance buckets.
- Can we reuse meshlet generation between CPU and GPU pipelines? Aim for a shared binary format.
- Need to evaluate impact on current tile-based rasterizer; may keep tiles for compositing but feed with meshlet output primitives.
