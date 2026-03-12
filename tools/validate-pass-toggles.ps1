param(
    [string]$Scene = "mixed_shadows_static",
    [int]$ProfileFrame = 51,
    [int]$TtlFrames = 52
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$engineIniPath = Join-Path $repoRoot "assets/configs/engine.ini"
$renderPassesPath = Join-Path $repoRoot "assets/configs/render_passes.json"

if (-not (Test-Path $engineIniPath)) {
    throw "engine.ini not found at $engineIniPath"
}
if (-not (Test-Path $renderPassesPath)) {
    throw "render_passes.json not found at $renderPassesPath"
}

$originalIni = Get-Content -Path $engineIniPath -Raw
$originalRenderPasses = Get-Content -Path $renderPassesPath -Raw

function Write-Utf8NoBom([string]$path, [string]$content) {
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
}

function Set-IniKeyValue([string]$iniText, [string]$sectionName, [string]$keyName, [string]$valueText) {
    $lines = $iniText -split "`r?`n", -1
    $currentSection = ""

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed.StartsWith("[") -and $trimmed.EndsWith("]")) {
            $currentSection = $trimmed.TrimStart("[").TrimEnd("]")
            continue
        }
        if ($currentSection -ne $sectionName) { continue }
        if ($trimmed -match ("^{0}\s*=" -f [Regex]::Escape($keyName))) {
            $lines[$i] = "$keyName = $valueText"
        }
    }

    return ($lines -join "`r`n")
}

function Set-PassState([bool]$renderPassShadows, [bool]$iniPassShadows, [bool]$iniShadowEnabled) {
    $iniText = $originalIni
    $iniText = Set-IniKeyValue -iniText $iniText -sectionName "passes" -keyName "shadows" -valueText ($iniPassShadows.ToString().ToLowerInvariant())
    $iniText = Set-IniKeyValue -iniText $iniText -sectionName "shadows" -keyName "enabled" -valueText ($iniShadowEnabled.ToString().ToLowerInvariant())
    Write-Utf8NoBom -path $engineIniPath -content $iniText

    $renderPassesText = $originalRenderPasses -replace '(?m)("shadows"\s*:\s*)(true|false)', ('$1' + $renderPassShadows.ToString().ToLowerInvariant())
    Write-Utf8NoBom -path $renderPassesPath -content $renderPassesText
}

function Invoke-Case([string]$caseName, [bool]$renderPassShadows, [bool]$iniPassShadows, [bool]$iniShadowEnabled, [bool]$expectShadowPass) {
    Set-PassState -renderPassShadows $renderPassShadows -iniPassShadows $iniPassShadows -iniShadowEnabled $iniShadowEnabled

    $env:ZIG_SCENE = $Scene
    $env:ZIG_RENDER_TTL_FRAMES = [string]$TtlFrames
    $env:ZIG_RENDER_PROFILE_FRAME = [string]$ProfileFrame

    $output = & cmd /c "zig build run -Doptimize=ReleaseFast 2>&1"
    $text = ($output | Out-String)

    if ($expectShadowPass) {
        if ($text -notmatch 'shadow_map_resolve_total:') {
            Write-Host $text
            throw "[$caseName] expected shadow_map_resolve_total but it was missing."
        }
        if ($text -notmatch 'light_work .*shadow_map_lights=1') {
            Write-Host $text
            throw "[$caseName] expected shadow_map_lights=1."
        }
    } else {
        if ($text -match 'shadow_map_resolve_total:') {
            Write-Host $text
            throw "[$caseName] expected no shadow_map_resolve_total but it was present."
        }
        if ($text -notmatch 'light_work .*shadow_map_lights=0') {
            Write-Host $text
            throw "[$caseName] expected shadow_map_lights=0."
        }
    }
}

try {
    # Case A: render_passes enables shadows, engine.ini disables them.
    # Expectation: engine.ini wins (shadows disabled at runtime).
    Invoke-Case `
        -caseName "ini-overrides-renderpasses-disable" `
        -renderPassShadows $true `
        -iniPassShadows $false `
        -iniShadowEnabled $false `
        -expectShadowPass $false

    # Case B: render_passes disables shadows, engine.ini enables them.
    # Expectation: engine.ini wins (shadows enabled at runtime).
    Invoke-Case `
        -caseName "ini-overrides-renderpasses-enable" `
        -renderPassShadows $false `
        -iniPassShadows $true `
        -iniShadowEnabled $true `
        -expectShadowPass $true

    Write-Host "Pass toggle validation passed."
} finally {
    Write-Utf8NoBom -path $engineIniPath -content $originalIni
    Write-Utf8NoBom -path $renderPassesPath -content $originalRenderPasses
}
