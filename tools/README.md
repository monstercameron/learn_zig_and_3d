# Tools

This folder contains scripts used to profile and sample renderer behavior.

## Included Tools

- `native-stack-sampler.py`: launches or attaches to the renderer and captures native sampling data
- `trace-to-flamegraph.py`: converts `profile.json` Chrome trace output to folded stacks and optional flame graph SVG

## Usage Notes

- Prefer running profiling builds with `-Dprofile=true` when native call stacks matter.
- Keep generated output such as `profile.json` or temporary logs out of source control.
