param(
    [string]$Scene = "mixed_shadows",
    [int]$ProfileFrame = 51,
    [int]$TtlFrames = 52
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$engineIniPath = Join-Path $repoRoot "assets/configs/engine.ini"

if (-not (Test-Path $engineIniPath)) {
    throw "engine.ini not found at $engineIniPath"
}

$originalIni = Get-Content -Path $engineIniPath -Raw
$patchedIni = $originalIni `
    -replace '(?m)^shadows\s*=\s*false\s*$', 'shadows = true' `
    -replace '(?ms)(\[shadows\]\s*\r?\n)enabled\s*=\s*false', '$1enabled = true'

try {
    Set-Content -Path $engineIniPath -Value $patchedIni -NoNewline

    $env:ZIG_SCENE = $Scene
    $env:ZIG_RENDER_TTL_FRAMES = [string]$TtlFrames
    $env:ZIG_RENDER_PROFILE_FRAME = [string]$ProfileFrame

    $output = & cmd /c "zig build run -Doptimize=ReleaseFast 2>&1"
    $text = ($output | Out-String)

    $requiredPatterns = @(
        'shadow_map_build_total:|shadow_map_reused=',
        'shadow_map_resolve_total:',
        'light_work .*shadow_map_lights=1 .*meshlet_shadow_lights=1 .*shadow_budget=',
        'shadow_light 0 build='
    )

    foreach ($pattern in $requiredPatterns) {
        if ($text -notmatch $pattern) {
            Write-Host $text
            throw "Missing expected profile pattern: $pattern"
        }
    }

    Write-Host "Mixed shadow validation passed."
} finally {
    Set-Content -Path $engineIniPath -Value $originalIni -NoNewline
}
