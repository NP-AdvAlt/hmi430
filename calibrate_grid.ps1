# calibrate_grid.ps1
# Calibration run using the 6x5 grid firmware (ui_test.spt, 30 buttons).
# Builds and flashes firmware, then presses each button one at a time.
# Takes a baseline screenshot before the first press, then one screenshot
# after each press (before moving to the next button).
#
# Z strategy:
#   Z=0   : full retract — required when moving outside screen area
#   Z=-4  : hover        — used between buttons (all within screen area)
#   Z=-14 : touch depth
#
# Does NOT call $H. Machine must already be homed to 0,0,0.
# All CNC moves are bounds-checked before execution.
#
# Usage: powershell -ExecutionPolicy Bypass -File calibrate_grid.ps1

. "$PSScriptRoot\mtp_screenshot.ps1"
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$nodeExe = "C:\Claude\hmi430\node\node-v22.14.0-win-x64\node.exe"
$buildJs  = "C:\Claude\hmi430\splat_build.js"
$buildBd  = "C:\Claude\hmi430\_build.b1d"
$binPath  = "C:\Claude\hmi430\_build.b1n"
$mtpExe   = "C:\Claude\hmi430\MtpCopy.exe"
$outDir   = "C:\Claude\hmi430\screen_captures\grid_cal"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ---------------------------------------------------------------------------
# Calibration constants (confirmed: yOrigin=-81 from offset_scan)
# ---------------------------------------------------------------------------
$xOrigin = 138.0;  $xScale = 93.0 / 479.0    # CNC_X = xOrigin - screenX * xScale
$yOrigin = -81.0;  $yScale = 51.0 / 271.0    # CNC_Y = yOrigin + screenY * yScale

# Hard safety limits for every CNC move
$X_MIN = 0.0;   $X_MAX = 155.0
$Y_MIN = -95.0; $Y_MAX = 0.0

$touchZ = -14.0; $hoverZ = -4.0; $safeZ = 0.0

# ---------------------------------------------------------------------------
# Button layout from ui_test.spt
# 6 columns (width 80px each): left edges at x=0,80,160,240,320,400
# 5 rows (heights 54,55,54,55,54): top edges at y=0,54,109,163,218
# Button centers:
# ---------------------------------------------------------------------------
$colCenters = @(40, 120, 200, 280, 360, 440)
$rowCenters = @(27, 81, 136, 190, 245)

$buttons = @()
$id = 0
foreach ($row in 0..4) {
    foreach ($col in 0..5) {
        $cx = $colCenters[$col]
        $cy = $rowCenters[$row]
        $buttons += [PSCustomObject]@{
            id   = $id
            col  = $col
            row  = $row
            cx   = $cx
            cy   = $cy
            cncX = [Math]::Round($xOrigin - $cx * $xScale, 2)
            cncY = [Math]::Round($yOrigin + $cy * $yScale, 2)
        }
        $id++
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Assert-SafeCoords([double]$x, [double]$y, [string]$label = "") {
    if ($x -lt $X_MIN -or $x -gt $X_MAX) {
        throw "BOUNDS CHECK FAILED$( if($label){" ($label)"}): X=$x outside [$X_MIN, $X_MAX]"
    }
    if ($y -lt $Y_MIN -or $y -gt $Y_MAX) {
        throw "BOUNDS CHECK FAILED$( if($label){" ($label)"}): Y=$y outside [$Y_MIN, $Y_MAX]"
    }
}

function Get-AllBrightness($bmp) {
    # Returns hashtable: button.id -> average brightness at button center (12x12 sample)
    $result = @{}
    foreach ($b in $buttons) {
        $t = 0.0; $n = 0
        for ($px = ($b.cx - 6); $px -lt ($b.cx + 6); $px++) {
            for ($py = ($b.cy - 6); $py -lt ($b.cy + 6); $py++) {
                if ($px -ge 0 -and $px -lt 480 -and $py -ge 0 -and $py -lt 272) {
                    $p = $bmp.GetPixel($px, $py)
                    $t += 0.299 * $p.R + 0.587 * $p.G + 0.114 * $p.B
                    $n++
                }
            }
        }
        $result[$b.id] = if ($n -gt 0) { [Math]::Round($t / $n, 1) } else { 0.0 }
    }
    return $result
}

function Take-Screenshot([string]$name) {
    $raw  = Get-MtpScreenshot -OutDir $outDir
    $dest = Join-Path $outDir "$name.png"
    if (Test-Path $dest) { Remove-Item $dest -Force }
    Move-Item $raw $dest
    return $dest
}

# ---------------------------------------------------------------------------
# Verify all button CNC positions before touching anything
# ---------------------------------------------------------------------------
Write-Host "=== Pre-flight bounds check ==="
foreach ($b in $buttons) {
    Assert-SafeCoords $b.cncX $b.cncY "btn$($b.id)"
}
Write-Host "All 30 button positions within safe bounds."
Write-Host "  X range: $( ($buttons | Measure-Object cncX -Minimum).Minimum ) – $( ($buttons | Measure-Object cncX -Maximum).Maximum ) mm"
Write-Host "  Y range: $( ($buttons | Measure-Object cncY -Minimum).Minimum ) – $( ($buttons | Measure-Object cncY -Maximum).Maximum ) mm"

# ---------------------------------------------------------------------------
# Build and flash firmware
# ---------------------------------------------------------------------------
Write-Host "`n=== Building firmware ==="
$buildOut = & $nodeExe $buildJs $buildBd 2>&1 | Out-String
if ($buildOut -notmatch 'BUILD SUCCESS') { throw "Build failed:`n$buildOut" }
Write-Host "Build OK"

Write-Host "=== Flashing firmware ==="
$flashDeadline = [DateTime]::Now.AddSeconds(90)
$flashed = $false
while ([DateTime]::Now -lt $flashDeadline -and -not $flashed) {
    $flashOut = & $mtpExe $binPath 2>&1 | Out-String
    if ($flashOut -match 'SUCCESS') { $flashed = $true; break }
    if ($flashOut -notmatch 'System Firmware.*not found') { throw "Flash failed:`n$flashOut" }
    Write-Host "  System Firmware not ready, retrying in 5s..."
    Start-Sleep -Seconds 5
}
if (-not $flashed) { throw "Flash timed out after 90s" }
Write-Host "Flash OK"

# ---------------------------------------------------------------------------
# CNC connection
# ---------------------------------------------------------------------------
$comPort = $null
$cnc = Get-PnpDevice | Where-Object { $_.FriendlyName -match 'CH340' -and $_.Status -eq 'OK' } | Select-Object -First 1
if ($cnc -and ($cnc.FriendlyName -match 'COM(\d+)')) { $comPort = "COM$($Matches[1])" }
# NOTE: No fallback to other ports — wrong port causes CNC commands to hit HMI or other devices.
# CH340 must be detected explicitly. If not found, check USB connection and power.
if (-not $comPort) { throw "CNC CH340 not found. Check USB cable and power, then re-run." }
Write-Host "`nCNC: $comPort"

$port = [System.IO.Ports.SerialPort]::new($comPort, 115200)
$port.ReadTimeout = 5000
$port.Open()
Start-Sleep -Milliseconds 500

function Send-Gcode([string]$cmd, [int]$waitMs = 200) {
    $port.WriteLine($cmd)
    Start-Sleep -Milliseconds $waitMs
    try { while ($port.BytesToRead -gt 0) { $port.ReadLine() | Out-Null } } catch {}
}

function Wait-Idle([int]$timeoutSec = 45) {
    $d = [DateTime]::Now.AddSeconds($timeoutSec)
    while ([DateTime]::Now -lt $d) {
        $port.Write("?")
        Start-Sleep -Milliseconds 150
        try { $r = $port.ReadLine(); if ($r -match 'Idle') { return } } catch {}
    }
    Write-Warning "Wait-Idle timed out after ${timeoutSec}s"
}

# ---------------------------------------------------------------------------
# Main run
# ---------------------------------------------------------------------------
$log = [System.Collections.Generic.List[PSObject]]::new()
$prevBrightness = @{}

try {
    # Power on HMI and wait for boot + MTP enumeration
    Write-Host "`n=== Powering on HMI430 ==="
    Send-Gcode "M3 S1000" 500
    Write-Host "Waiting 20s for boot and MTP device enumeration..."
    Start-Sleep -Seconds 20

    # Confirm mode and ensure full retract (machine starts at 0,0,0 = safe)
    Send-Gcode "G21 G90 G54" 300
    Send-Gcode "G0 Z$safeZ" 800
    Wait-Idle

    # Move to first button position at full retract (coming from outside screen area)
    $first = $buttons[0]
    Write-Host "Moving to first button at full retract..."
    Send-Gcode "G0 X$($first.cncX) Y$($first.cncY)" 1500
    Wait-Idle

    # Lower to hover — now we're over the screen area, stay at hover between presses
    Send-Gcode "G0 Z$hoverZ" 800
    Wait-Idle

    # Baseline screenshot (before any press)
    Write-Host "`n--- Baseline screenshot (no buttons pressed) ---"
    $basePath = Take-Screenshot "shot_000_baseline"
    Write-Host "Saved: $basePath"
    $bmp = [System.Drawing.Bitmap]::new($basePath)
    $prevBrightness = Get-AllBrightness $bmp
    $bmp.Dispose()
    $baseWhite = ($prevBrightness.GetEnumerator() | Where-Object { $_.Value -gt 200 }).Count
    Write-Host "Baseline: $baseWhite buttons already white (should be 0)"

    # Press each button in order
    $shotNum = 1
    foreach ($b in $buttons) {
        Write-Host "`n--- btn$($b.id) [col=$($b.col) row=$($b.row)] screen($($b.cx),$($b.cy)) CNC($($b.cncX),$($b.cncY)) ---"

        # Move to button at hover height (already over screen area — no full retract needed)
        Assert-SafeCoords $b.cncX $b.cncY "btn$($b.id)"
        Send-Gcode "G0 X$($b.cncX) Y$($b.cncY)" 1000
        Wait-Idle

        # Press: touch, pause, retract to hover
        Send-Gcode "G0 Z$touchZ" 500
        Wait-Idle
        Start-Sleep -Milliseconds 300
        Send-Gcode "G0 Z$hoverZ" 400
        Wait-Idle
        Start-Sleep -Milliseconds 500   # let screen update before screenshot

        # Screenshot
        $shotName = "shot_{0:D3}_btn{1}" -f $shotNum, $b.id
        $shotPath = Take-Screenshot $shotName
        $shotNum++

        # Analyse: compare to previous screenshot to find newly-white buttons
        $bmp = [System.Drawing.Bitmap]::new($shotPath)
        $brights = Get-AllBrightness $bmp
        $bmp.Dispose()

        $newHits = @($brights.Keys | Where-Object { $brights[$_] -gt 200 -and $prevBrightness[$_] -le 200 } | Sort-Object)
        $allWhite = @($brights.Keys | Where-Object { $brights[$_] -gt 200 } | Sort-Object)

        if ($newHits.Count -eq 0) {
            Write-Host "  MISS — no new button registered"
        } elseif ($newHits.Count -eq 1 -and $newHits[0] -eq $b.id) {
            Write-Host "  HIT  — btn$($b.id) correct"
        } elseif ($newHits.Count -eq 1) {
            $off = $buttons[$newHits[0]]
            $dCol = $off.col - $b.col;  $dRow = $off.row - $b.row
            Write-Host "  WRONG — expected btn$($b.id) but got btn$($newHits[0]) (col offset $dCol, row offset $dRow)"
        } else {
            Write-Host "  MULTI — $($newHits.Count) new buttons: $($newHits -join ', ')"
        }

        $log.Add([PSCustomObject]@{
            btnId    = $b.id
            col      = $b.col
            row      = $b.row
            screenX  = $b.cx
            screenY  = $b.cy
            cncX     = $b.cncX
            cncY     = $b.cncY
            newHits  = ($newHits -join ';')
            correct  = ($newHits.Count -eq 1 -and $newHits[0] -eq $b.id)
            missed   = ($newHits.Count -eq 0)
            allWhite = ($allWhite -join ';')
            shot     = (Split-Path $shotPath -Leaf)
        })

        $prevBrightness = $brights
    }

} finally {
    # Full retract before moving off screen area, then return home
    Write-Host "`n=== Retracting and returning home ==="
    try { Send-Gcode "G0 Z$safeZ" 800; Wait-Idle } catch { Write-Warning "Z retract failed: $_" }
    try { Send-Gcode "G0 X0 Y0" 1500; Wait-Idle } catch { Write-Warning "Home move failed: $_" }
    Send-Gcode "M5" 300    # HMI power off
    if ($port -and $port.IsOpen) { $port.Close() }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n===== CALIBRATION RESULTS ====="
$correct = ($log | Where-Object {  $_.correct }).Count
$missed  = ($log | Where-Object {  $_.missed  }).Count
$wrong   = ($log | Where-Object { -not $_.correct -and -not $_.missed }).Count

Write-Host "Correct: $correct / 30"
Write-Host "Missed:  $missed  / 30"
Write-Host "Wrong:   $wrong   / 30"
Write-Host ""

if ($wrong -gt 0) {
    Write-Host "--- Wrong presses (offset analysis) ---"
    foreach ($entry in ($log | Where-Object { -not $_.correct -and -not $_.missed })) {
        $hitIds = $entry.newHits -split ';' | Where-Object { $_ -ne '' }
        foreach ($hid in $hitIds) {
            $hb = $buttons[[int]$hid]
            $dSx = $hb.cx - $entry.screenX;  $dSy = $hb.cy - $entry.screenY
            $dMmX = [Math]::Round($dSx * $xScale, 1)
            $dMmY = [Math]::Round($dSy * $yScale, 1)
            Write-Host ("  btn{0} -> btn{1}  screen err: dX={2}px dY={3}px  CNC err: dX={4}mm dY={5}mm" -f $entry.btnId, $hid, $dSx, $dSy, $dMmX, $dMmY)
        }
    }
}

$log | Format-Table btnId, col, row, cncX, cncY, newHits, correct, missed -AutoSize

$csv = Join-Path $outDir "calibration_result.csv"
$log | Export-Csv $csv -NoTypeInformation
Write-Host "Screenshots: $outDir"
Write-Host "Log:         $csv"
