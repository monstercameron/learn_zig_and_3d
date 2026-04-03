# Render Core Redesign

This note documents the render-core restructuring that moved frame orchestration out of the monolithic renderer and into explicit graph, planning, and execution layers.

## Goals

- make the graph and frame plan explicit and cacheable
- move frame and post execution loops out of `renderer.zig`
- replace metadata-only pass ordering with resource-aware pass declarations
- keep hot-path overhead low enough that the new structure is not worse than the old one
- improve test coverage for orchestration and wiring, not just pass implementations

## New Modules

- `engine/src/render/main.zig`
  Exposes the render-core surface used by tests and future tooling.

- `engine/src/render/pipeline/pass_graph.zig`
  Declares pass order, phases, output targets, and explicit resource reads/writes.

- `engine/src/render/graph/frame_graph.zig`
  Compiles the enabled post-pass subset, validates resource availability, and caches compiled pass data.

- `engine/src/render/graph/frame_plan.zig`
  Compiles the per-frame stage list for shadow build, scene raster, post processing, and present.

- `engine/src/render/frame_pipeline.zig`
  Builds feature masks, available-resource masks, and cached graph/plan inputs.

- `engine/src/render/frame_executor.zig`
  Owns the runtime loops for frame stages and post-pass execution.

- `engine/src/render/frame_hooks.zig`
  Builds typed renderer-facing dispatch tables that connect executor control flow to renderer operations.

## What Changed

### 1. Graph Metadata Became Real Contract Data

Post passes now declare:

- phase
- output target
- resource reads
- resource writes

This lets the frame graph reject invalid combinations before execution instead of relying on handwritten assumptions in the renderer.

### 2. Execution Loops Left `renderer.zig`

The renderer no longer owns the main post-pass loop or frame-stage loop. It now provides typed operations such as:

- `stageBuildShadowMaps`
- `stageRenderScene`
- `stageOverlayAndPresent`
- `runPostProcessStage`
- individual pass entry points used by hook dispatch

The executor owns the actual iteration and output-commit flow.

### 3. Buffer Routing Is Centralized

Scratch-target output commits are centralized instead of being spread across pass bodies. Pass implementations no longer perform the old ad hoc front-buffer swaps after execution.

### 4. Hot-Path Setup Was Tightened

- cached graph and plan reuse avoids rebuilding orchestration state when inputs have not changed
- post-phase timing is skipped unless the render overlay, profiler, or configured capture frame needs it
- post setup now reuses the already computed per-frame shadow-map light count

## Tests Added

The redesign added coverage for:

- frame graph compilation and validation
- cached graph and cached plan reuse
- executor stage ordering
- post-pass dispatch ordering
- renderer-style hook wiring through the executor

The current tests prove orchestration behavior more directly than the earlier state, where most regressions were only caught by compilation or manual runtime testing.

## Current Boundaries

This redesign cleans up orchestration, not the whole renderer.

Still intentionally left in `renderer.zig`:

- most pass implementations
- shadow-build implementation details
- tiled raster implementation details
- present-stage implementation details

Still not solved:

- the direct raster backend remains a stub

## Next Logical Step

Move stage and pass implementations out of `renderer.zig` into backend- or pass-specific modules so the renderer becomes mostly state, backend ownership, and high-level coordination glue.
