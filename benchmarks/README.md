# Benchmarks

This subproject contains focused microbenchmarks for math kernels, meshlet work, lighting paths, and render-job behavior.

## Purpose

- measure hot code paths without the full renderer loop
- compare scalar and SIMD variants
- validate optimization ideas before landing them in the main app

## Commands

From the repository root:

```powershell
zig build benchmarks
zig build run-benchmarks
```

From this folder directly:

```powershell
zig build
zig build run
```

Focused raster triangle microbench from repository root:

```powershell
zig run -O ReleaseFast rasterize-triangle-microbench.zig
```

Phase 15 hotspot microbench suite from repository root:

```powershell
zig run -O ReleaseFast phase15-microbench.zig
zig run -O ReleaseFast phase15-microbench.zig -- trace
zig run -O ReleaseFast phase15-microbench.zig -- shadow_apply_threshold
```

## Layout

- `build.zig`: benchmark build entry point
- `src/main.zig`: benchmark driver
- `src/bench_*.zig`: individual benchmark cases
