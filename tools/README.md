# Tools

This folder contains scripts used to profile and sample renderer behavior.

## Included Tools

- `native-stack-sampler.py`: launches or attaches to the renderer and captures native sampling data

## Usage Notes

- Prefer running profiling builds with `-Dprofile=true` when native call stacks matter.
- Keep generated output such as `profile.json` or temporary logs out of source control.