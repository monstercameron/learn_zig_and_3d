# Documentation

This folder is the long-form companion to the repository README. It keeps the architecture notes, profiling workflow, research writeups, and the current roadmap in one place.

## Core Docs

- `technical-overview.md`: current engine shape, major systems, and runtime responsibilities
- `rendering-pipeline.md`: frame flow from camera update through mesh work, raster, and post-processing
- `current-features-api-usage.md`: feature-to-function map with concrete usage patterns and call sites
- `performance-profiling.md`: exact frame timing, native sampling, and Chrome trace workflow
- `project-roadmap.md`: active backlog, follow-up work, and longer-horizon renderer tasks

## Research And Specs

- `meshlet-research-notes.md`: meshlet sizing, data layout, and culling notes
- `meshlet-shadowing-spec.md`: design sketch for packet-based meshlet shadow traversal

## Suggested Reading Order

1. Start with `../README.md` for the repo-level overview and current build commands.
2. Read `technical-overview.md` to understand the runtime shape of the app.
3. Read `rendering-pipeline.md` before changing frame execution or render passes.
4. Read `current-features-api-usage.md` for a function-level map of existing runtime features.
5. Read `performance-profiling.md` before doing optimization work.
6. Use `project-roadmap.md` to see what is already planned or intentionally deferred.
