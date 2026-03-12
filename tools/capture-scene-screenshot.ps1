param(
    [string]$Scene = "cornell",
    [int]$TtlFrames = 240,
    [string]$OutputPath = "artifacts/screenshots/cornell_shadow_only.png",
    [string]$WindowTitle = "Zig 3D CPU Rasterizer",
    [int]$WaitForFrame = 0
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$exe = "zig-out/bin/zig-windows-app.exe"
if (-not (Test-Path $exe)) {
    & zig build -Doptimize=ReleaseFast | Out-Null
}

$outDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$oldScene = $env:ZIG_SCENE
$oldTtl = $env:ZIG_RENDER_TTL_FRAMES
$env:ZIG_SCENE = $Scene
$env:ZIG_RENDER_TTL_FRAMES = [string]$TtlFrames

$proc = Start-Process -FilePath $exe -PassThru
try {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
public static class Win32Capture {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
}
"@
    Add-Type -AssemblyName System.Drawing

    $handle = [IntPtr]::Zero
    for ($i = 0; $i -lt 240; $i++) {
        Start-Sleep -Milliseconds 50
        $matches = New-Object System.Collections.Generic.List[System.IntPtr]
        $enum = [Win32Capture+EnumWindowsProc]{
            param([IntPtr]$hWnd, [IntPtr]$lParam)
            if (-not [Win32Capture]::IsWindowVisible($hWnd)) { return $true }
            $len = [Win32Capture]::GetWindowTextLength($hWnd)
            if ($len -le 0) { return $true }
            [uint32]$windowProcId = 0
            [void][Win32Capture]::GetWindowThreadProcessId($hWnd, [ref]$windowProcId)
            if ($windowProcId -ne [uint32]$proc.Id) { return $true }
            $sb = New-Object System.Text.StringBuilder ($len + 1)
            [void][Win32Capture]::GetWindowText($hWnd, $sb, $sb.Capacity)
            $title = $sb.ToString()
            if ($title -like "*$WindowTitle*") {
                $matches.Add($hWnd) | Out-Null
            }
            return $true
        }
        [void][Win32Capture]::EnumWindows($enum, [IntPtr]::Zero)
        if ($matches.Count -gt 0) {
            $handle = $matches[0]
            break
        }
    }
    if ($handle -eq [IntPtr]::Zero) {
        throw "Could not find renderer window titled '$WindowTitle'."
    }

    $rect = New-Object RECT
    [void][Win32Capture]::GetWindowRect($handle, [ref]$rect)
    $width = [Math]::Max(1, $rect.Right - $rect.Left)
    $height = [Math]::Max(1, $rect.Bottom - $rect.Top)

    [void][Win32Capture]::ShowWindow($handle, 9)
    [void][Win32Capture]::SetForegroundWindow($handle)
    if ($WaitForFrame -gt 0) {
        # Conservative warm-up assumption (10 FPS floor) to ensure at least N frames elapsed.
        $warmupSeconds = [Math]::Ceiling($WaitForFrame / 10.0)
        Start-Sleep -Seconds $warmupSeconds
    } else {
        Start-Sleep -Milliseconds 120
    }

    $bmp = New-Object System.Drawing.Bitmap($width, $height)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $gfx.GetHdc()
    $printed = [Win32Capture]::PrintWindow($handle, $hdc, 0)
    $gfx.ReleaseHdc($hdc)
    if (-not $printed) {
        $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size($width, $height)))
    }
    $bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $gfx.Dispose()
    $bmp.Dispose()

    Write-Output "SCREENSHOT_PATH=$OutputPath"
    Write-Output "WINDOW_RECT=$($rect.Left),$($rect.Top),$($rect.Right),$($rect.Bottom)"
}
finally {
    if ($proc -and -not $proc.HasExited) {
        Wait-Process -Id $proc.Id -Timeout 20 -ErrorAction SilentlyContinue
    }
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force
    }

    if ($null -eq $oldScene) {
        Remove-Item Env:ZIG_SCENE -ErrorAction SilentlyContinue
    } else {
        $env:ZIG_SCENE = $oldScene
    }
    if ($null -eq $oldTtl) {
        Remove-Item Env:ZIG_RENDER_TTL_FRAMES -ErrorAction SilentlyContinue
    } else {
        $env:ZIG_RENDER_TTL_FRAMES = $oldTtl
    }
}
