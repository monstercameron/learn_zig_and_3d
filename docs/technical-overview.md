# Technical Overview

This document describes the current shape of the repository, not the original prototype pitch. The app is still a CPU-first Zig renderer, but it now includes meshlet work generation, runtime SIMD dispatch, a shadow system, profiling hooks, and a larger post-processing stack than the older docs implied.

## Overview

The current runtime is built around these ideas:

- CPU-driven rendering with explicit control over memory layout and frame scheduling
- a custom job system for tile work, meshlet work, and other parallel tasks
- dual render backends: a tiled path and a direct path
- runtime CPU feature detection so one build can scale across different x86 machines
- built-in profiling for exact frame-pass timing and Chrome trace capture
- Win32 as the primary runtime target

## What Boots At Startup

The current app startup path in `src/main.zig` is straightforward:

- load `assets/configs/default.settings.json`
- create the Win32 window and renderer backbuffer
- detect CPU features and choose the preferred SIMD backend
- try to load the GLB revolver scene from `assets/models/gun/rovelver1.0.0.glb`
- fall back to `assets/models/teapot.obj` if the GLB path fails
- optionally load HDRI data for the skybox path

The repository also contains scene-level JSON such as `assets/levels/default.level.json`, but that is not the primary startup path today.

## Core Systems

These files define most of the runtime behavior:

- `src/main.zig`: app bootstrap, logging, asset selection, physics wiring, and the main loop
- `src/renderer.zig`: camera update, frame orchestration, mesh work generation, raster selection, shadows, and post-processing
- `src/job_system.zig`: worker scheduling and shared frame jobs
- `src/tile_renderer.zig`: tile-local raster, shading inputs, and tile composition
- `src/shadow_system.zig`: shadow acceleration structures and packet tracing support
- `src/mesh.zig`, `src/meshlet_builder.zig`, `src/meshlet_cache.zig`: meshlet generation, storage, and persistence
- `src/cpu_features.zig`: runtime ISA detection and backend selection
- `src/profiler.zig`: Chrome trace-compatible profiling capture

## Frame Shape

At a high level, each frame does this:

1. Update camera state, input-driven movement, and light state.
2. Recompute cached frame view state only when inputs actually changed.
3. Generate mesh work from the active mesh and camera.
4. Build shadow data when the configured shadow path is enabled.
5. Render through either the tiled or direct path.
6. Run the enabled post-processing passes.
7. Record pass timings and optionally dump a profile capture.

The detailed pass order lives in `rendering-pipeline.md`.

## Configuration And Assets

The main runtime configuration file is `assets/configs/default.settings.json`.

It currently controls:

- window size and vsync
- render resolution scaling and frame cap
- camera defaults
- debug overlays
- post-processing toggles and tuning values
- shadow, hybrid shadow, SSAO, TAA, bloom, fog, and color-grade options

Most assets live under `assets/`:

- `assets/models/`: GLB, OBJ, and related textures
- `assets/hdri/`: environment data
- `assets/configs/`: runtime settings
- `assets/levels/`: scene description experiments and supporting data

## Current Constraints

The docs should reflect these realities:

- the project is Windows-first and not yet a polished cross-platform engine
- there is still a large amount of experimental rendering code in the main path
- the renderer mixes stable systems and in-progress feature spikes
- some longer-term docs describe intended architecture rather than fully landed behavior

For planned work rather than current behavior, use `project-roadmap.md` instead of treating this document as a feature promise.
