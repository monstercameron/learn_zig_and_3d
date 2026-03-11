# Performance Profiling

This repository has three useful profiling paths that work together:

1. Exact per-pass timings from the renderer.
2. Native call-stack sampling from `tools/native-stack-sampler.py`.
3. Chrome trace capture through `profile.json`.

Use the pass timings to find the slow stage, the stack sampler to find the hot code inside that stage, and the trace file when you need a broader frame view.

## 1. Build For Profiling

For call-stack sampling, keep frame pointers enabled:

```powershell
zig build -Dprofile=true
```

For realistic numbers in optimized builds:

```powershell
zig build -Doptimize=ReleaseFast -Dprofile=true
```

`Debug` is still useful when you want easy-to-read behavior and worst-case hotspot visibility.

## 2. Exact Frame Timings

The renderer can print exact timings for a specific frame by setting `ZIG_RENDER_PROFILE_FRAME`.

Example:

```powershell
$env:ZIG_RENDER_PROFILE_FRAME = '120'
zig-out\bin\zig-windows-app.exe
```

At the selected frame, the renderer logs lines like:

```text
[renderer.core] [INFO] [frame_profile] meshlet_tiled: 2.446 ms
[renderer.core] [INFO] [frame_profile] hybrid_shadow: 75.012 ms
[renderer.core] [INFO] [frame_profile] ssao: 2.678 ms
```

For hybrid shadows, it also prints detailed sub-metrics:

```text
hybrid_shadow detail accel=... candidate=... clear=... execute=... jobs=... active_tiles=...
```

That breakdown is the fastest way to decide whether the problem is:

- acceleration structure work
- candidate building
- cache clearing
- actual shadow execution

Clear the variable after use if needed:

```powershell
Remove-Item Env:ZIG_RENDER_PROFILE_FRAME
```

## 3. Native Call-Stack Sampling

Use the local sampler in `tools/native-stack-sampler.py`.

Sample a running process:

```powershell
python tools\native-stack-sampler.py <pid> 1
```

Launch, warm up, sample for one second, then terminate automatically:

```powershell
python tools\native-stack-sampler.py --launch zig-out\bin\zig-windows-app.exe 12 1
```

When launched through the local profiling tools, the renderer also gets a wall-clock TTL through `ZIG_RENDER_TTL_SECONDS` so it closes itself automatically instead of leaving a window open.

You can also enforce frame-count auto-close:

```powershell
$env:ZIG_RENDER_TTL_FRAMES = '180'
zig build run -Doptimize=ReleaseFast
```

If `ZIG_RENDER_PROFILE_FRAME` is set and no TTL is provided, the app now auto-exits at roughly `profile_frame + 30` frames.

Recommended combined workflow:

```powershell
zig build -Dprofile=true
$env:ZIG_RENDER_PROFILE_FRAME = '120'
python tools\native-stack-sampler.py --launch zig-out\bin\zig-windows-app.exe 12 1
```

That gives you:

- `TOP LEAF FRAMES`
- `TOP INCLUSIVE FRAMES`
- `TOP STACKS`
- exact renderer pass timings for frame `120`

## 4. How To Read Results

Use the reports in this order:

1. Find the dominant pass from `frame_profile`.
2. Check pass-specific detail fields if available.
3. Look at `TOP STACKS` and `TOP INCLUSIVE FRAMES`.
4. Ignore tiny passes until the dominant pass is under control.

Example interpretation:

- If `hybrid_shadow` is `75 ms` and everything else is under `3 ms`, do not optimize bloom or fog.
- If `hybrid_shadow candidate` is small but `execute` is huge, the problem is per-sample shadow work, not setup.
- If `meshlet_tiled` rises, inspect raster, interpolation, overdraw, and tile binning.

## 5. Recommended Review Routine

For any serious performance review:

1. Run one `Debug` capture to identify the dominant system quickly.
2. Run one `ReleaseFast` capture to see whether the same hotspot still matters in optimized code.
3. Make one change at a time.
4. Re-run the same frame and same sampler duration.
5. Record before/after numbers for the exact pass you changed.

## 6. Visual Validation

If a change affects image quality, capture a screenshot before and after profiling. Performance-only changes are not enough if they break shadow edges, SSAO, textures, or model loading.

## 7. Chrome Trace Capture

The engine also has a built-in Chrome trace-compatible profiler. It writes `profile.json`, which you can open in `chrome://tracing` or [Perfetto](https://ui.perfetto.dev/).

To generate the Chrome Trace, compile and run with the environment variable `ZIG_RENDER_PROFILE_FRAME` set:

```powershell
$env:ZIG_RENDER_PROFILE_FRAME = '120'
zig build run -Doptimize=ReleaseFast
```

This capture starts just before the requested frame and writes `profile.json` in the workspace root.

Use `profiler.zone("YourFunctionName")` around specific functions or blocks when you need finer-grained trace visibility.

## 8. Flame Graphs From `profile.json`

You can generate folded stacks (and optionally an SVG flame graph) directly from the trace file:

```powershell
python tools\trace-to-flamegraph.py --input profile.json --out artifacts\flame\frame120
```

This writes:

- `artifacts\flame\frame120.folded`
- `artifacts\flame\frame120.html` (interactive canvas flame graph)
- `artifacts\flame\frame120.svg` (if `flamegraph.pl` is available)

If `flamegraph.pl` is not on `PATH`, pass it explicitly:

```powershell
python tools\trace-to-flamegraph.py --input profile.json --out artifacts\flame\frame120 --flamegraph-pl C:\tools\FlameGraph\flamegraph.pl
```

If you only want folded stacks (for other viewers/tools):

```powershell
python tools\trace-to-flamegraph.py --input profile.json --out artifacts\flame\frame120 --no-svg
```
