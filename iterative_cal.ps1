# iterative_cal.ps1 -- Iterative CNC-to-screen calibration
# 1. Build and flash dense 12px button grid (white, turns black on press)
# 2. Press at a target CNC position with booper DOWN
# 3. Take MTP screenshot WHILE pressing to see black spot
# 4. Find center of black region in screenshot
# 5. Compare expected vs actual screen pixel -> compute offset
# 6. Adjust mapping and repeat at different positions
#
# Usage: powershell -ExecutionPolicy Bypass -File iterative_cal.ps1

. "$PSScriptRoot\mtp_screenshot.ps1"
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$nodeExe  = 'C:\Claude\hmi430\node\node-v22.14.0-win-x64\node.exe'
$buildJs  = 'C:\Claude\hmi430\splat_build.js'
$buildBd  = 'C:\Claude\hmi430\_build.b1d'
$binPath  = 'C:\Claude\hmi430\_build.b1n'
$mtpExe   = 'C:\Claude\hmi430\MtpCopy.exe'
$outDir   = 'C:\Claude\hmi430\screen_captures\iter_cal'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$CELL_W = 80; $CELL_H = 54   # 6x5 grid (30 buttons, all with valid ids)
$COLS = 6; $ROWS = 5

# ---------------------------------------------------------------------------
# Initial mapping (corrected for 180-degree flip from first calibration run)
# CNC_X = xOrigin + screenX * xScale
# CNC_Y = yOrigin - screenY * yScale
# ---------------------------------------------------------------------------
# Edge calibration (165-probe binary search, 2026-03-11)
# Max residual: 3.1px X, 5.2px Y (top-left corner edge effect)
$xOrigin = 43.5461; $xScale = 0.198095
$yOrigin = -23.1126; $yScale = 0.199934

$touchZ = -14.0; $hoverZ = -4.0; $safeZ = 0.0

# Safety limits
$X_MIN = 5.0;   $X_MAX = 155.0
$Y_MIN = -90.0; $Y_MAX = -5.0

# Target screen positions to press (pixel coords in MTP screenshot space)
# Aim near button centers in 6x5 grid (80x54px cells)
# Button centers: col*80+40, row*54+27
$targets = @(
    @{ name = 'center';       sx = 240; sy = 135 },
    @{ name = 'top-left';     sx = 40;  sy = 27 },
    @{ name = 'top-right';    sx = 440; sy = 27 },
    @{ name = 'bottom-left';  sx = 40;  sy = 243 },
    @{ name = 'bottom-right'; sx = 440; sy = 243 },
    @{ name = 'center-check'; sx = 240; sy = 135 }
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function FindCH340($retries = 10, $delayMs = 1500) {
    for ($i = 0; $i -lt $retries; $i++) {
        $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'CH340' }
        if ($dev) {
            $com = $dev.FriendlyName -replace '.*\((.+)\).*','$1'
            Write-Host "CH340 on $com"; return $com
        }
        Start-Sleep -Milliseconds $delayMs
    }
    throw 'CH340 not found'
}

function Send($port, $cmd, [switch]$wait) {
    $port.WriteLine($cmd); Start-Sleep -Milliseconds 200
    $port.ReadExisting() | Out-Null
    if ($wait) { WaitIdle $port | Out-Null }
}

function WaitIdle($port, $timeoutSec = 45) {
    Start-Sleep -Milliseconds 400
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?'); Start-Sleep -Milliseconds 250
        $r = $port.ReadExisting()
        if ($r -match 'Idle') {
            $pos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
            Write-Host "  [Idle] MPos=$pos"; return $true
        }
    }
    Write-Host '  [timeout]'; return $false
}

function ScreenToCnc([double]$sx, [double]$sy) {
    $cx = $xOrigin + $sx * $xScale
    $cy = $yOrigin - $sy * $yScale
    return @{ x = [Math]::Round($cx, 2); y = [Math]::Round($cy, 2) }
}

function FindBlackButton([string]$imgPath) {
    # Find which button is dark (pressed) in the 6x5 white-background grid screenshot
    # Returns the center pixel of the darkest button
    $bmp = [System.Drawing.Bitmap]::new($imgPath)
    $bestId = -1; $bestBright = 999.0
    for ($r = 0; $r -lt $ROWS; $r++) {
        for ($c = 0; $c -lt $COLS; $c++) {
            $bx = $c * $CELL_W + [Math]::Floor($CELL_W / 2)
            $by = $r * $CELL_H + [Math]::Floor($CELL_H / 2)
            # Sample 12x12 patch at button center
            $sum = 0.0; $n = 0
            for ($dx = -6; $dx -lt 6; $dx++) {
                for ($dy = -6; $dy -lt 6; $dy++) {
                    $px = $bx + $dx; $py = $by + $dy
                    if ($px -ge 0 -and $px -lt 480 -and $py -ge 0 -and $py -lt 272) {
                        $p = $bmp.GetPixel($px, $py)
                        $sum += 0.299 * $p.R + 0.587 * $p.G + 0.114 * $p.B
                        $n++
                    }
                }
            }
            $avg = if ($n -gt 0) { $sum / $n } else { 255.0 }
            $id = $r * $COLS + $c
            if ($avg -lt $bestBright) {
                $bestBright = $avg; $bestId = $id
            }
        }
    }
    $bmp.Dispose()
    if ($bestBright -gt 128) { return $null }  # no dark button found
    $hitCol = $bestId % $COLS
    $hitRow = [Math]::Floor($bestId / $COLS)
    return @{
        id = $bestId
        col = $hitCol
        row = $hitRow
        x = [Math]::Round($hitCol * $CELL_W + $CELL_W / 2.0, 1)
        y = [Math]::Round($hitRow * $CELL_H + $CELL_H / 2.0, 1)
        bright = [Math]::Round($bestBright, 1)
    }
}

# ---------------------------------------------------------------------------
# Build and flash
# ---------------------------------------------------------------------------
Write-Host '=== Building firmware ==='
$buildOut = & $nodeExe $buildJs $buildBd 2>&1 | Out-String
if ($buildOut -notmatch 'BUILD SUCCESS') { throw "Build failed:`n$buildOut" }
Write-Host 'Build OK'

# Open CNC
$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.WriteLine(''); Start-Sleep -Milliseconds 600
$port.ReadExisting() | Out-Null
Send $port 'G21'; Send $port 'G90'; Send $port 'G54'

# Power on HMI for flash
Write-Host "`n=== Powering on HMI ==="
Send $port 'M3 S1000'
Write-Host 'Waiting 20s for boot + MTP...'
Start-Sleep -Seconds 20

Write-Host '=== Flashing firmware ==='
$flashDeadline = [DateTime]::Now.AddSeconds(90)
$flashed = $false
while ([DateTime]::Now -lt $flashDeadline -and -not $flashed) {
    $flashOut = & $mtpExe $binPath 2>&1 | Out-String
    if ($flashOut -match 'SUCCESS') { $flashed = $true; break }
    Write-Host '  MTP not ready, retrying in 5s...'
    Start-Sleep -Seconds 5
}
if (-not $flashed) { throw 'Flash timed out' }
Write-Host 'Flash OK'

# HMI reboots after flash - wait for it
Write-Host 'Waiting 5s for HMI reboot after flash...'
Start-Sleep -Seconds 5

# ---------------------------------------------------------------------------
# Calibration loop
# ---------------------------------------------------------------------------
$log = @()

try {
    Send $port 'G0 Z0' -wait

    foreach ($t in $targets) {
        $name = $t.name
        $sx = $t.sx; $sy = $t.sy
        $cnc = ScreenToCnc $sx $sy

        Write-Host "`n=== Press: $name -- screen($sx, $sy) -> CNC($($cnc.x), $($cnc.y)) ==="

        # Bounds check
        if ($cnc.x -lt $X_MIN -or $cnc.x -gt $X_MAX -or $cnc.y -lt $Y_MIN -or $cnc.y -gt $Y_MAX) {
            Write-Host "  SKIP -- out of bounds (X=$($cnc.x), Y=$($cnc.y))"
            continue
        }

        # Move to position at safe Z
        Send $port "G0 Z$safeZ" -wait
        Send $port "G0 X$($cnc.x) Y$($cnc.y)" -wait

        # Press down and HOLD
        Send $port "G0 Z$touchZ" -wait
        Start-Sleep -Milliseconds 500

        # Take screenshot WHILE booper is pressing
        Write-Host '  Taking MTP screenshot (booper down)...'
        $shotPath = Get-MtpScreenshot -OutDir $outDir
        $dest = Join-Path $outDir "$name.png"
        if (Test-Path $dest) { Remove-Item $dest -Force }
        Move-Item $shotPath $dest
        Write-Host "  Saved: $dest"

        # Retract
        Send $port "G0 Z$safeZ" -wait

        # Analyze: find which button is dark
        $hit = FindBlackButton $dest
        if (-not $hit) {
            Write-Host '  MISS -- no dark button found in screenshot'
            $log += [PSCustomObject]@{
                name=$name; targetSx=$sx; targetSy=$sy; cncX=$cnc.x; cncY=$cnc.y
                hitSx=''; hitSy=''; errPx=''; errPy=''; errMmX=''; errMmY=''
            }
            continue
        }

        $errPx = [Math]::Round($hit.x - $sx, 1)
        $errPy = [Math]::Round($hit.y - $sy, 1)
        $errMmX = [Math]::Round($errPx * $xScale, 2)
        $errMmY = [Math]::Round($errPy * $yScale, 2)

        Write-Host "  HIT btn$($hit.id) [col=$($hit.col) row=$($hit.row)] center=($($hit.x), $($hit.y)) bright=$($hit.bright)"
        Write-Host "  Error: dX=${errPx}px (${errMmX}mm), dY=${errPy}px (${errMmY}mm)"

        $log += [PSCustomObject]@{
            name=$name; targetSx=$sx; targetSy=$sy; cncX=$cnc.x; cncY=$cnc.y
            hitSx=$hit.x; hitSy=$hit.y; errPx=$errPx; errPy=$errPy
            errMmX=$errMmX; errMmY=$errMmY
        }

        # After first press (center), adjust mapping if error is significant
        if ($name -eq 'center' -and $hit) {
            if ([Math]::Abs($errPx) -gt 5 -or [Math]::Abs($errPy) -gt 5) {
                # Adjust origins to correct the offset
                # If hit was at higher screen X than expected, xOrigin needs to decrease
                $xOrigin = [Math]::Round($xOrigin - $errPx * $xScale, 3)
                $yOrigin = [Math]::Round($yOrigin + $errPy * $yScale, 3)
                Write-Host "  ** ADJUSTED: xOrigin=$xOrigin, yOrigin=$yOrigin **"
            } else {
                Write-Host '  Center is accurate -- no adjustment needed'
            }
        }
    }

} finally {
    Write-Host "`n=== Cleanup ==="
    try { Send $port 'G0 Z0' -wait } catch {}
    try { Send $port 'G0 X0 Y0' -wait } catch {}
    Send $port 'M5'
    $port.Close()
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n===== CALIBRATION RESULTS ====="
Write-Host "Final mapping: CNC_X = $xOrigin + screenX * $([Math]::Round($xScale, 6))"
Write-Host "               CNC_Y = $yOrigin - screenY * $([Math]::Round($yScale, 6))"
Write-Host ''
$log | Format-Table name, targetSx, targetSy, cncX, cncY, hitSx, hitSy, errPx, errPy, errMmX, errMmY -AutoSize
$csv = Join-Path $outDir 'iterative_cal.csv'
$log | Export-Csv $csv -NoTypeInformation
Write-Host "Log: $csv"
