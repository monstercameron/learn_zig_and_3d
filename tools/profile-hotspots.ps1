param(
    [string]$InputPath = "profile.json",
    [switch]$Capture,
    [string]$Scene = "mixed_shadows_static",
    [int]$ProfileFrame = 120,
    [int]$TtlFrames = 150,
    [string]$RunCommand = "zig build run -Doptimize=ReleaseFast",
    [string[]]$FocusZones = @("renderTileJob", "meshletShadowTile", "meshletShadowTrace", "meshletShadowApply"),
    [int]$Top = 20,
    [string]$OutDir = "artifacts/perf",
    [bool]$WriteSummary = $true,
    [double]$MeshletShadowTileP99P50Target = 2.5,
    [switch]$FailOnGuardrail
)

$ErrorActionPreference = "Stop"

function Get-PercentileValue {
    param(
        [double[]]$SortedValues,
        [double]$Percentile
    )

    if (-not $SortedValues -or $SortedValues.Count -eq 0) {
        return 0.0
    }

    $index = [int][Math]::Floor(($SortedValues.Count - 1) * $Percentile)
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $SortedValues.Count) { $index = $SortedValues.Count - 1 }
    return [double]$SortedValues[$index]
}

function Get-Ratio {
    param(
        [double]$Numerator,
        [double]$Denominator
    )

    if ($Denominator -le 0.0) { return 0.0 }
    return $Numerator / $Denominator
}

function Format-Number {
    param(
        [double]$Value,
        [int]$Digits = 2
    )
    return [Math]::Round($Value, $Digits)
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return "" }
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

if ($Capture.IsPresent) {
    $previousScene = $env:ZIG_SCENE
    $previousProfileFrame = $env:ZIG_RENDER_PROFILE_FRAME
    $previousTtlFrames = $env:ZIG_RENDER_TTL_FRAMES
    $env:ZIG_SCENE = $Scene
    $env:ZIG_RENDER_PROFILE_FRAME = [string]$ProfileFrame
    $env:ZIG_RENDER_TTL_FRAMES = [string]$TtlFrames
    Write-Host "Capturing profile with scene=$Scene frame=$ProfileFrame ttl_frames=$TtlFrames"
    $null = & cmd /c "$RunCommand 2>&1"
    if ($LASTEXITCODE -ne 0) {
        throw "Capture command failed with exit code ${LASTEXITCODE}: $RunCommand"
    }
    $env:ZIG_SCENE = $previousScene
    $env:ZIG_RENDER_PROFILE_FRAME = $previousProfileFrame
    $env:ZIG_RENDER_TTL_FRAMES = $previousTtlFrames
}

if (-not (Test-Path $InputPath)) {
    throw "Input trace file not found: $InputPath"
}

$events = Get-Content -Path $InputPath -Raw | ConvertFrom-Json
if ($null -eq $events) {
    throw "Trace parse failed for $InputPath"
}

$durationEvents = @($events | Where-Object {
    $null -ne $_.name -and
    $null -ne $_.dur -and
    $_.ph -eq "X"
})

if ($durationEvents.Count -eq 0) {
    throw "No duration events found in $InputPath"
}

$totalDurationUs = ($durationEvents | Measure-Object -Property dur -Sum).Sum

$rows = New-Object System.Collections.Generic.List[object]
foreach ($group in ($durationEvents | Group-Object -Property name)) {
    $durations = @($group.Group | ForEach-Object { [double]$_.dur } | Sort-Object)
    if ($durations.Count -eq 0) { continue }

    $sumUs = ($durations | Measure-Object -Sum).Sum
    $count = $durations.Count
    $avgUs = $sumUs / $count
    $p50Us = Get-PercentileValue -SortedValues $durations -Percentile 0.50
    $p90Us = Get-PercentileValue -SortedValues $durations -Percentile 0.90
    $p99Us = Get-PercentileValue -SortedValues $durations -Percentile 0.99
    $maxUs = [double]$durations[-1]
    $sharePct = if ($totalDurationUs -gt 0.0) { ($sumUs / $totalDurationUs) * 100.0 } else { 0.0 }

    $rows.Add([pscustomobject]@{
            Name = $group.Name
            Count = $count
            TotalMs = Format-Number -Value ($sumUs / 1000.0) -Digits 3
            AvgUs = Format-Number -Value $avgUs -Digits 2
            P50Us = Format-Number -Value $p50Us -Digits 2
            P90Us = Format-Number -Value $p90Us -Digits 2
            P99Us = Format-Number -Value $p99Us -Digits 2
            MaxUs = Format-Number -Value $maxUs -Digits 2
            P99OverP50 = Format-Number -Value (Get-Ratio -Numerator $p99Us -Denominator $p50Us) -Digits 3
            MaxOverP50 = Format-Number -Value (Get-Ratio -Numerator $maxUs -Denominator $p50Us) -Digits 3
            SharePct = Format-Number -Value $sharePct -Digits 2
        })
}

$topRows = @($rows | Sort-Object -Property TotalMs -Descending | Select-Object -First $Top)
$focusRows = foreach ($zone in $FocusZones) {
    $row = $rows | Where-Object { $_.Name -eq $zone } | Select-Object -First 1
    if ($null -ne $row) {
        $row
    } else {
        [pscustomobject]@{
            Name = $zone
            Count = 0
            TotalMs = 0.0
            AvgUs = 0.0
            P50Us = 0.0
            P90Us = 0.0
            P99Us = 0.0
            MaxUs = 0.0
            P99OverP50 = 0.0
            MaxOverP50 = 0.0
            SharePct = 0.0
        }
    }
}

$meshletShadowTileRow = $focusRows | Where-Object { $_.Name -eq "meshletShadowTile" } | Select-Object -First 1
$meshletShadowTileGuardrailStatus = "NO_DATA"
$meshletShadowTileP99P50 = 0.0
if ($null -ne $meshletShadowTileRow -and $meshletShadowTileRow.Count -gt 0) {
    $meshletShadowTileP99P50 = [double]$meshletShadowTileRow.P99OverP50
    if ($meshletShadowTileP99P50 -le $MeshletShadowTileP99P50Target) {
        $meshletShadowTileGuardrailStatus = "PASS"
    } else {
        $meshletShadowTileGuardrailStatus = "FAIL"
    }
}

Write-Host ""
Write-Host "Top zones by total duration:"
$topRows | Format-Table Name, Count, TotalMs, AvgUs, P50Us, P90Us, P99Us, MaxUs, SharePct -AutoSize

Write-Host ""
Write-Host "Focus zones (imbalance metrics included):"
$focusRows | Format-Table Name, Count, TotalMs, P50Us, P99Us, MaxUs, P99OverP50, MaxOverP50 -AutoSize

Write-Host ""
Write-Host ("Guardrail meshletShadowTile p99/p50 <= {0}: {1} (actual={2})" -f `
    (Format-Number -Value $MeshletShadowTileP99P50Target -Digits 3), `
    $meshletShadowTileGuardrailStatus, `
    (Format-Number -Value $meshletShadowTileP99P50 -Digits 3))

if ($FailOnGuardrail.IsPresent -and $meshletShadowTileGuardrailStatus -eq "FAIL") {
    throw ("Guardrail failed: meshletShadowTile p99/p50={0} exceeds target {1}" -f `
        (Format-Number -Value $meshletShadowTileP99P50 -Digits 3), `
        (Format-Number -Value $MeshletShadowTileP99P50Target -Digits 3))
}

if ($WriteSummary) {
    if (-not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir | Out-Null
    }

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $engineIniPath = Join-Path $repoRoot "assets/configs/engine.ini"
    $renderPassesPath = Join-Path $repoRoot "assets/configs/render_passes.json"
    $timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $summaryPath = Join-Path $OutDir "hotspots-$timestamp.md"
    $traceCopyPath = Join-Path $OutDir "profile-$timestamp.json"

    $engineIniHash = Get-FileSha256 -Path $engineIniPath
    $renderPassesHash = Get-FileSha256 -Path $renderPassesPath

    Copy-Item -Path $InputPath -Destination $traceCopyPath -Force

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Hotspot Snapshot")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("- generated_at: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"))
    [void]$sb.AppendLine("- scene: $Scene")
    [void]$sb.AppendLine("- profile_frame: $ProfileFrame")
    [void]$sb.AppendLine("- input_trace: $InputPath")
    [void]$sb.AppendLine("- copied_trace: $traceCopyPath")
    [void]$sb.AppendLine("- engine_ini_sha256: $engineIniHash")
    [void]$sb.AppendLine("- render_passes_sha256: $renderPassesHash")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Focus Zones")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| name | count | total_ms | p50_us | p90_us | p99_us | max_us | p99_over_p50 | max_over_p50 |")
    [void]$sb.AppendLine("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    foreach ($row in $focusRows) {
        [void]$sb.AppendLine("| $($row.Name) | $($row.Count) | $($row.TotalMs) | $($row.P50Us) | $($row.P90Us) | $($row.P99Us) | $($row.MaxUs) | $($row.P99OverP50) | $($row.MaxOverP50) |")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Guardrails")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("- meshletShadowTile p99/p50 target: <= $(Format-Number -Value $MeshletShadowTileP99P50Target -Digits 3)")
    [void]$sb.AppendLine("- meshletShadowTile p99/p50 actual: $(Format-Number -Value $meshletShadowTileP99P50 -Digits 3)")
    [void]$sb.AppendLine("- meshletShadowTile imbalance status: $meshletShadowTileGuardrailStatus")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Top Zones")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| name | count | total_ms | avg_us | p50_us | p90_us | p99_us | max_us | share_pct |")
    [void]$sb.AppendLine("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    foreach ($row in $topRows) {
        [void]$sb.AppendLine("| $($row.Name) | $($row.Count) | $($row.TotalMs) | $($row.AvgUs) | $($row.P50Us) | $($row.P90Us) | $($row.P99Us) | $($row.MaxUs) | $($row.SharePct) |")
    }

    Set-Content -Path $summaryPath -Value $sb.ToString() -NoNewline
    Write-Host ""
    Write-Host "Wrote hotspot summary: $summaryPath"
    Write-Host "Copied trace: $traceCopyPath"
}
