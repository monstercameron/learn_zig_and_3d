param(
    [int]$Frame = 120,
    [int]$Iterations = 5,
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string]$Optimize = 'ReleaseFast',
    [switch]$BuildProfile = $true,
    [string]$OutputJson = '',
    [double]$RendererTtlSeconds = 3.0
)

$ErrorActionPreference = 'Stop'

if ($Iterations -lt 1) {
    throw 'Iterations must be at least 1.'
}

if ($BuildProfile) {
    & zig build "-Doptimize=$Optimize" '-Dprofile=true'
    if ($LASTEXITCODE -ne 0) {
        throw "zig build failed with exit code $LASTEXITCODE"
    }
}

$exePath = Join-Path $PSScriptRoot '..\zig-out\bin\zig-windows-app.exe'
$exePath = [System.IO.Path]::GetFullPath($exePath)
if (-not (Test-Path $exePath)) {
    throw "Executable not found: $exePath"
}

$pattern = '\[frame_profile\]\s+([^:]+):\s+([0-9.]+)\s+ms'
$runs = @()
$attempt = 0
$maxAttempts = [math]::Max($Iterations * 3, $Iterations)

while ($runs.Count -lt $Iterations -and $attempt -lt $maxAttempts) {
    $attempt += 1
    $run = $runs.Count + 1
    Write-Host "run $run/$Iterations frame=$Frame optimize=$Optimize attempt=$attempt/$maxAttempts"

    $env:ZIG_RENDER_PROFILE_FRAME = "$Frame"
    $env:ZIG_RENDER_TTL_SECONDS = $RendererTtlSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    try {
        $cmdLine = '"' + $exePath + '" 2>&1'
        $output = & cmd /c $cmdLine | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "Renderer exited with code $LASTEXITCODE on run $run"
        }
    }
    finally {
        Remove-Item Env:ZIG_RENDER_PROFILE_FRAME -ErrorAction SilentlyContinue
        Remove-Item Env:ZIG_RENDER_TTL_SECONDS -ErrorAction SilentlyContinue
    }

    $passMap = [ordered]@{}
    $matches = [regex]::Matches($output, $pattern)
    foreach ($match in $matches) {
        $name = $match.Groups[1].Value.Trim()
        if ($name -like 'frame=*' -or $name -like '*exact pass timings follow*') {
            continue
        }
        $value = [double]$match.Groups[2].Value
        $passMap[$name] = $value
    }

    if ($passMap.Count -eq 0) {
        Write-Warning "No frame_profile timings were found on attempt $attempt"
        continue
    }

    $runs += [pscustomobject]@{
        run = $run
        passes = [pscustomobject]$passMap
        raw = $output
    }
}

if ($runs.Count -lt $Iterations) {
    throw "Only collected $($runs.Count) successful profiled run(s) after $maxAttempts attempts"
}

$allPassNames = $runs |
    ForEach-Object { $_.passes.PSObject.Properties.Name } |
    Sort-Object -Unique

$summary = foreach ($name in $allPassNames) {
    $values = @(
        $runs |
            ForEach-Object {
                $prop = $_.passes.PSObject.Properties[$name]
                if ($null -ne $prop) { [double]$prop.Value }
            }
    )

    if ($values.Count -eq 0) {
        continue
    }

    $avg = ($values | Measure-Object -Average).Average
    $min = ($values | Measure-Object -Minimum).Minimum
    $max = ($values | Measure-Object -Maximum).Maximum
    $variance = 0.0
    foreach ($value in $values) {
        $delta = $value - $avg
        $variance += $delta * $delta
    }
    $stddev = [math]::Sqrt($variance / $values.Count)

    [pscustomobject]@{
        pass = $name
        avg_ms = [math]::Round($avg, 3)
        min_ms = [math]::Round($min, 3)
        max_ms = [math]::Round($max, 3)
        stddev_ms = [math]::Round($stddev, 3)
        runs = $values.Count
    }
}

$summary = $summary | Sort-Object avg_ms -Descending
Write-Host "captured $($runs.Count) successful profiled runs"
$summary |
    Format-Table pass, avg_ms, min_ms, max_ms, stddev_ms, runs -AutoSize |
    Out-String -Width 220 |
    Write-Host

if ($OutputJson -ne '') {
    $payload = [pscustomobject]@{
        frame = $Frame
        iterations = $Iterations
        optimize = $Optimize
        summary = $summary
        runs = $runs
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputJson -Encoding utf8
    Write-Host "wrote $OutputJson"
}