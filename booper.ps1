# booper.ps1 - HMI430 Touchscreen Booper Module
# Dot-source this to get functions for pressing screen pixel coordinates.
#
# Usage:
#   . "C:\Claude\hmi430\booper.ps1"
#   $port = Open-Booper -PowerHMI
#   Press-Screen $port 240 136
#   $img = Press-ScreenAndCapture $port 100 50 -OutDir "C:\Claude\captures"
#   Close-Booper $port -PowerOff
#
# Calibrated 2026-03-11 via edge-finding + nudge verification.
# Verified: hits 4x4px (0.8mm) targets at arbitrary screen positions.

. "$PSScriptRoot\mtp_screenshot.ps1"

# ---------------------------------------------------------------------------
# Calibration constants
# ---------------------------------------------------------------------------
$script:BPR_xOrigin = 43.5461
$script:BPR_xScale  = 0.198095
$script:BPR_yOrigin = -23.1126
$script:BPR_yScale  = 0.199934

$script:BPR_touchZ = -14.0
$script:BPR_safeZ  = 0.0

$script:BPR_X_MIN = 5.0;  $script:BPR_X_MAX = 155.0
$script:BPR_Y_MIN = -90.0; $script:BPR_Y_MAX = -5.0

# ---------------------------------------------------------------------------
# Internal helpers (prefixed BPR_ to avoid namespace collisions)
# ---------------------------------------------------------------------------
function BPR_FindCH340 {
    param([int]$Retries = 10, [int]$DelayMs = 1500)
    for ($i = 0; $i -lt $Retries; $i++) {
        $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'CH340' }
        if ($dev) {
            $com = $dev.FriendlyName -replace '.*\((.+)\).*','$1'
            Write-Host "[Booper] CH340 on $com"
            return $com
        }
        Start-Sleep -Milliseconds $DelayMs
    }
    throw '[Booper] CH340 not found. Is the CNC powered on and connected via USB?'
}

function BPR_Send {
    param($Port, [string]$Cmd, [switch]$Wait)
    $Port.WriteLine($Cmd)
    Start-Sleep -Milliseconds 200
    $Port.ReadExisting() | Out-Null
    if ($Wait) { BPR_WaitIdle $Port | Out-Null }
}

function BPR_WaitIdle {
    param($Port, [int]$TimeoutSec = 45)
    Start-Sleep -Milliseconds 400
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $Port.Write('?')
        Start-Sleep -Milliseconds 250
        $r = $Port.ReadExisting()
        if ($r -match 'Alarm') {
            Write-Host '  [ALARM]'
            return $false
        }
        if ($r -match 'Idle') {
            $pos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
            Write-Host "  [Idle] MPos=$pos"
            return $true
        }
    }
    Write-Host '  [timeout]'
    return $false
}

function BPR_ScreenToCnc {
    param([double]$ScreenX, [double]$ScreenY)
    return @{
        X = [Math]::Round($script:BPR_xOrigin + $ScreenX * $script:BPR_xScale, 3)
        Y = [Math]::Round($script:BPR_yOrigin - $ScreenY * $script:BPR_yScale, 3)
    }
}

# ---------------------------------------------------------------------------
# Public: Open-Booper
# ---------------------------------------------------------------------------
function Open-Booper {
    <#
    .SYNOPSIS
        Opens CNC serial port and initializes GRBL for booper use.
    .PARAMETER PowerHMI
        Send M3 S1000 to power on the HMI touchscreen and wait for boot.
    .PARAMETER BootWaitSec
        Seconds to wait for HMI boot (default 20). Only used with -PowerHMI.
    #>
    param(
        [switch]$PowerHMI,
        [int]$BootWaitSec = 20
    )

    $com = BPR_FindCH340
    $port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
    $port.ReadTimeout = 3000
    $port.Open()
    Start-Sleep -Milliseconds 800
    $port.WriteLine('')
    Start-Sleep -Milliseconds 600
    $port.ReadExisting() | Out-Null

    # Check for ALARM state
    $port.Write('?')
    Start-Sleep -Milliseconds 400
    $status = $port.ReadExisting()
    if ($status -match 'Alarm') {
        Write-Host '[Booper] ALARM detected -- auto-recovering...'
        Home-Booper $port
        Write-Host '[Booper] WARNING: Z calibration may have shifted after recovery home.'
        Write-Host '[Booper] Consider running booper_zcal4.ps1 to verify press depth.'
    }

    BPR_Send $port 'G21'
    BPR_Send $port 'G90'
    BPR_Send $port 'G54'

    if ($PowerHMI) {
        Write-Host '[Booper] Powering on HMI (M3 S1000)...'
        BPR_Send $port 'M3 S1000'
        Write-Host "[Booper] Waiting ${BootWaitSec}s for HMI boot..."
        Start-Sleep -Seconds $BootWaitSec
    }

    Write-Host '[Booper] Ready'
    return $port
}

# ---------------------------------------------------------------------------
# Public: Home-Booper
# ---------------------------------------------------------------------------
function Home-Booper {
    <#
    .SYNOPSIS
        Recovery home -- runs each axis against its physical stop and re-zeros.
        No limit switches; steppers stall safely at stops.
    .NOTES
        After homing, Z press depth (-14.0) may have shifted due to stepper slip.
        Re-run booper_zcal4.ps1 to verify before trusting precise presses.
    #>
    param([System.IO.Ports.SerialPort]$Port)

    Write-Host '[Booper] Recovery homing (running against physical stops)...'

    # Unlock if in alarm
    $Port.WriteLine('$X')
    Start-Sleep -Milliseconds 500
    $Port.ReadExisting() | Out-Null

    # Disable soft limits for recovery
    $Port.WriteLine('$20=0')
    Start-Sleep -Milliseconds 300
    $Port.ReadExisting() | Out-Null

    # Retract Z fully
    Write-Host '  Retracting Z...'
    $Port.WriteLine('G91 G1 Z60 F100')
    BPR_WaitIdle $Port 60 | Out-Null

    # Home X (left stop)
    Write-Host '  Homing X...'
    $Port.WriteLine('G1 X-200 F300')
    BPR_WaitIdle $Port 60 | Out-Null

    # Home Y (toward user)
    Write-Host '  Homing Y...'
    $Port.WriteLine('G1 Y120 F300')
    BPR_WaitIdle $Port 60 | Out-Null

    # Re-zero G54 at home position
    $Port.WriteLine('G90 G54')
    Start-Sleep -Milliseconds 200
    $Port.WriteLine('G10 L20 P1 X0 Y0 Z0')
    Start-Sleep -Milliseconds 200
    $Port.WriteLine('G28.1')
    Start-Sleep -Milliseconds 200
    $Port.ReadExisting() | Out-Null

    Write-Host '[Booper] Homed at (0, 0, 0)'
}

# ---------------------------------------------------------------------------
# Public: Press-Screen
# ---------------------------------------------------------------------------
function Press-Screen {
    <#
    .SYNOPSIS
        Press the HMI screen at a pixel coordinate. Retracts Z before and after.
    .PARAMETER Port
        Serial port from Open-Booper.
    .PARAMETER ScreenX
        Horizontal pixel (0 = left, 480 = right).
    .PARAMETER ScreenY
        Vertical pixel (0 = top, 272 = bottom).
    .OUTPUTS
        Hashtable with CNC X/Y that was used.
    #>
    param(
        [System.IO.Ports.SerialPort]$Port,
        [double]$ScreenX,
        [double]$ScreenY
    )

    $cnc = BPR_ScreenToCnc $ScreenX $ScreenY

    if ($cnc.X -lt $script:BPR_X_MIN -or $cnc.X -gt $script:BPR_X_MAX -or
        $cnc.Y -lt $script:BPR_Y_MIN -or $cnc.Y -gt $script:BPR_Y_MAX) {
        throw "[Booper] Screen($ScreenX, $ScreenY) -> CNC($($cnc.X), $($cnc.Y)) OUT OF BOUNDS"
    }

    Write-Host "[Booper] Press ($ScreenX, $ScreenY) -> CNC($($cnc.X), $($cnc.Y))"

    BPR_Send $Port "G0 Z$($script:BPR_safeZ)" -Wait
    BPR_Send $Port "G0 X$($cnc.X) Y$($cnc.Y)" -Wait
    BPR_Send $Port "G0 Z$($script:BPR_touchZ)" -Wait
    Start-Sleep -Milliseconds 500
    BPR_Send $Port "G0 Z$($script:BPR_safeZ)" -Wait

    return $cnc
}

# ---------------------------------------------------------------------------
# Public: Press-ScreenAndCapture
# ---------------------------------------------------------------------------
function Press-ScreenAndCapture {
    <#
    .SYNOPSIS
        Press the HMI screen and take an MTP screenshot while the booper is down.
        HMI must be powered on (M3 S1000) for MTP to work.
    .PARAMETER Port
        Serial port from Open-Booper.
    .PARAMETER ScreenX
        Horizontal pixel (0-479).
    .PARAMETER ScreenY
        Vertical pixel (0-271).
    .PARAMETER OutDir
        Directory to save the screenshot.
    .PARAMETER Label
        Filename prefix for the screenshot (default: "capture").
    .OUTPUTS
        Path to the saved screenshot PNG.
    #>
    param(
        [System.IO.Ports.SerialPort]$Port,
        [double]$ScreenX,
        [double]$ScreenY,
        [Parameter(Mandatory)][string]$OutDir,
        [string]$Label = 'capture'
    )

    $cnc = BPR_ScreenToCnc $ScreenX $ScreenY

    if ($cnc.X -lt $script:BPR_X_MIN -or $cnc.X -gt $script:BPR_X_MAX -or
        $cnc.Y -lt $script:BPR_Y_MIN -or $cnc.Y -gt $script:BPR_Y_MAX) {
        throw "[Booper] Screen($ScreenX, $ScreenY) -> CNC($($cnc.X), $($cnc.Y)) OUT OF BOUNDS"
    }

    Write-Host "[Booper] Press+capture ($ScreenX, $ScreenY) -> CNC($($cnc.X), $($cnc.Y))"

    BPR_Send $Port "G0 Z$($script:BPR_safeZ)" -Wait
    BPR_Send $Port "G0 X$($cnc.X) Y$($cnc.Y)" -Wait
    BPR_Send $Port "G0 Z$($script:BPR_touchZ)" -Wait
    Start-Sleep -Milliseconds 500

    # Screenshot while booper is pressing
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $shotPath = Get-MtpScreenshot -OutDir $OutDir
    $dest = Join-Path $OutDir "$Label.png"
    if (Test-Path $dest) { Remove-Item $dest -Force }
    Move-Item $shotPath $dest
    Write-Host "[Booper] Screenshot: $dest"

    BPR_Send $Port "G0 Z$($script:BPR_safeZ)" -Wait

    return $dest
}

# ---------------------------------------------------------------------------
# Public: Close-Booper
# ---------------------------------------------------------------------------
function Close-Booper {
    <#
    .SYNOPSIS
        Retract booper, return to home, optionally power off HMI, close port.
    .PARAMETER PowerOff
        Send M5 to power off the HMI before closing.
    #>
    param(
        [System.IO.Ports.SerialPort]$Port,
        [switch]$PowerOff
    )

    Write-Host '[Booper] Closing...'
    try { BPR_Send $Port "G0 Z$($script:BPR_safeZ)" -Wait } catch {}
    try { BPR_Send $Port 'G0 X0 Y0' -Wait } catch {}
    if ($PowerOff) {
        BPR_Send $Port 'M5'
        Write-Host '[Booper] HMI powered off'
    }
    $Port.Close()
    Write-Host '[Booper] Done'
}
