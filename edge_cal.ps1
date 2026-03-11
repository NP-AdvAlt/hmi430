# edge_cal.ps1 -- Precise edge-finding calibration
# Binary search for exact button edge transitions on 5 small buttons.
# Each edge gives a (CNC_position, screen_pixel) data point.
# Linear regression on all edges produces a precise mapping.
#
# Usage: powershell -ExecutionPolicy Bypass -File edge_cal.ps1

. "$PSScriptRoot\mtp_screenshot.ps1"
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$nodeExe  = 'C:\Claude\hmi430\node\node-v22.14.0-win-x64\node.exe'
$genJs    = 'C:\Claude\hmi430\gen_edge_buttons.js'
$buildJs  = 'C:\Claude\hmi430\splat_build.js'
$buildBd  = 'C:\Claude\hmi430\_build.b1d'
$binPath  = 'C:\Claude\hmi430\_build.b1n'
$mtpExe   = 'C:\Claude\hmi430\MtpCopy.exe'
$outDir   = 'C:\Claude\hmi430\screen_captures\edge_cal'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Clean old probes
Get-ChildItem $outDir -Filter 'probe_*.png' | Remove-Item -Force

# ---------------------------------------------------------------------------
# Current mapping (edge calibration 2026-03-11)
# ---------------------------------------------------------------------------
$xOrigin = 43.5461; $xScale = 0.198095
$yOrigin = -23.1126; $yScale = 0.199934

$touchZ = -14.0; $safeZ = 0.0

# Safety limits
$X_MIN = 5.0;   $X_MAX = 155.0
$Y_MIN = -90.0; $Y_MAX = -5.0

# Button definitions (must match gen_edge_buttons.js)
# 120x80px -- big enough to absorb mapping error for initial hit
$buttons = @(
    @{ id=0; name='center';       bx=180; by=96;  bw=120; bh=80 },
    @{ id=1; name='top-left';     bx=10;  by=10;  bw=120; bh=80 },
    @{ id=2; name='top-right';    bx=350; by=10;  bw=120; bh=80 },
    @{ id=3; name='bottom-left';  bx=10;  by=182; bw=120; bh=80 },
    @{ id=4; name='bottom-right'; bx=350; by=182; bw=120; bh=80 }
)
foreach ($b in $buttons) {
    $b['cx'] = $b.bx + $b.bw / 2.0
    $b['cy'] = $b.by + $b.bh / 2.0
}

# Margin beyond button edge for initial miss point (pixels)
$MISS_MARGIN = 30
# Binary search stops when interval < this (mm) -- 0.1mm is about 0.5px
$PRECISION_MM = 0.1
$MAX_ITERATIONS = 8

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

function ScreenToCncX([double]$sx) { return $xOrigin + $sx * $xScale }
function ScreenToCncY([double]$sy) { return $yOrigin - $sy * $yScale }

function IsButtonPressed([string]$imgPath, [double]$cx, [double]$cy) {
    # Sample 11x11 patch at button center, return true if dark
    $bmp = [System.Drawing.Bitmap]::new($imgPath)
    $sum = 0.0; $n = 0
    for ($dx = -5; $dx -le 5; $dx++) {
        for ($dy = -5; $dy -le 5; $dy++) {
            $px = [int]$cx + $dx; $py = [int]$cy + $dy
            if ($px -ge 0 -and $px -lt 480 -and $py -ge 0 -and $py -lt 272) {
                $p = $bmp.GetPixel($px, $py)
                $sum += 0.299 * $p.R + 0.587 * $p.G + 0.114 * $p.B
                $n++
            }
        }
    }
    $bmp.Dispose()
    $avg = if ($n -gt 0) { $sum / $n } else { 255.0 }
    return $avg -lt 128
}

$probeCount = 0

function PressAndCheck([double]$cncX, [double]$cncY, [double]$btnCx, [double]$btnCy) {
    $script:probeCount++
    $n = $script:probeCount

    if ($cncX -lt $X_MIN -or $cncX -gt $X_MAX -or $cncY -lt $Y_MIN -or $cncY -gt $Y_MAX) {
        Write-Host "    #$n CNC($([Math]::Round($cncX,2)),$([Math]::Round($cncY,2))) OUT OF BOUNDS"
        return $false
    }

    Send $port "G0 Z$safeZ" -wait
    Send $port "G0 X$([Math]::Round($cncX, 3)) Y$([Math]::Round($cncY, 3))" -wait
    Send $port "G0 Z$touchZ" -wait
    Start-Sleep -Milliseconds 400

    $shotPath = Get-MtpScreenshot -OutDir $outDir
    $dest = Join-Path $outDir "probe_$n.png"
    if (Test-Path $dest) { Remove-Item $dest -Force }
    Move-Item $shotPath $dest

    Send $port "G0 Z$safeZ" -wait

    $pressed = IsButtonPressed $dest $btnCx $btnCy
    $status = if ($pressed) { 'HIT' } else { 'miss' }
    Write-Host "    #$n CNC($([Math]::Round($cncX,2)),$([Math]::Round($cncY,2))) -> $status"
    return $pressed
}

function FindEdgeCnc([double]$hitCnc, [double]$missCnc, [double]$fixedCnc,
                     [string]$axis, [double]$btnCx, [double]$btnCy) {
    # Binary search between a known hit and known miss on one CNC axis
    for ($i = 0; $i -lt $MAX_ITERATIONS; $i++) {
        if ([Math]::Abs($missCnc - $hitCnc) -lt $PRECISION_MM) { break }
        $mid = ($hitCnc + $missCnc) / 2.0

        if ($axis -eq 'X') {
            $pressed = PressAndCheck $mid $fixedCnc $btnCx $btnCy
        } else {
            $pressed = PressAndCheck $fixedCnc $mid $btnCx $btnCy
        }

        if ($pressed) { $hitCnc = $mid } else { $missCnc = $mid }
    }
    return ($hitCnc + $missCnc) / 2.0
}

# ---------------------------------------------------------------------------
# Build and flash
# ---------------------------------------------------------------------------
Write-Host '=== Generating edge button firmware ==='
$genOut = & $nodeExe $genJs 2>&1 | Out-String
Write-Host $genOut

Write-Host '=== Building firmware ==='
$buildOut = & $nodeExe $buildJs $buildBd 2>&1 | Out-String
if ($buildOut -notmatch 'BUILD SUCCESS') { throw "Build failed:`n$buildOut" }
Write-Host 'Build OK'

$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.WriteLine(''); Start-Sleep -Milliseconds 600
$port.ReadExisting() | Out-Null
Send $port 'G21'; Send $port 'G90'; Send $port 'G54'

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

Write-Host 'Waiting 5s for HMI reboot...'
Start-Sleep -Seconds 5

# ---------------------------------------------------------------------------
# Edge-finding calibration
# ---------------------------------------------------------------------------
$xData = @()   # Each entry: @{ cncX; screenX }
$yData = @()   # Each entry: @{ cncY; screenY }
$btnResults = @()

try {
    Send $port 'G0 Z0' -wait

    foreach ($btn in $buttons) {
        $name = $btn.name
        $cx = $btn.cx; $cy = $btn.cy
        $centerCncX = ScreenToCncX $cx
        $centerCncY = ScreenToCncY $cy

        Write-Host "`n========== $name -- screen($cx,$cy) -> CNC($([Math]::Round($centerCncX,2)),$([Math]::Round($centerCncY,2))) =========="

        # Verify center hit
        Write-Host '  Verifying center...'
        $hit = PressAndCheck $centerCncX $centerCncY $cx $cy
        if (-not $hit) {
            Write-Host "  FAILED to hit $name center -- SKIPPING"
            continue
        }

        # --- RIGHT edge ---
        Write-Host '  >> Right edge (X+)'
        $rightEdgeSx = $btn.bx + $btn.bw   # first pixel OUTSIDE button
        $rightMissCnc = ScreenToCncX ($rightEdgeSx + $MISS_MARGIN)
        $rightCnc = FindEdgeCnc $centerCncX $rightMissCnc $centerCncY 'X' $cx $cy
        $xData += @{ cncX = $rightCnc; screenX = [double]$rightEdgeSx }

        # --- LEFT edge ---
        Write-Host '  >> Left edge (X-)'
        $leftEdgeSx = $btn.bx              # first pixel INSIDE button
        $leftMissCnc = ScreenToCncX ($leftEdgeSx - $MISS_MARGIN)
        $leftCnc = FindEdgeCnc $centerCncX $leftMissCnc $centerCncY 'X' $cx $cy
        $xData += @{ cncX = $leftCnc; screenX = [double]$leftEdgeSx }

        # --- BOTTOM edge ---
        Write-Host '  >> Bottom edge (Y+)'
        $bottomEdgeSy = $btn.by + $btn.bh  # first pixel OUTSIDE button
        $bottomMissCnc = ScreenToCncY ($bottomEdgeSy + $MISS_MARGIN)
        $bottomCnc = FindEdgeCnc $centerCncY $bottomMissCnc $centerCncX 'Y' $cx $cy
        $yData += @{ cncY = $bottomCnc; screenY = [double]$bottomEdgeSy }

        # --- TOP edge ---
        Write-Host '  >> Top edge (Y-)'
        $topEdgeSy = $btn.by              # first pixel INSIDE button
        $topMissCnc = ScreenToCncY ($topEdgeSy - $MISS_MARGIN)
        $topCnc = FindEdgeCnc $centerCncY $topMissCnc $centerCncX 'Y' $cx $cy
        $yData += @{ cncY = $topCnc; screenY = [double]$topEdgeSy }

        # Report per-button results
        $measW = ($rightCnc - $leftCnc) / $xScale
        $measH = ($topCnc - $bottomCnc) / $yScale   # top CNC > bottom CNC, both negative
        $trueCx = ($leftCnc + $rightCnc) / 2.0
        $trueCy = ($topCnc + $bottomCnc) / 2.0
        $trueSx = ($trueCx - $xOrigin) / $xScale
        $trueSy = ($yOrigin - $trueCy) / $yScale

        Write-Host "  Edges (CNC): L=$([Math]::Round($leftCnc,3)) R=$([Math]::Round($rightCnc,3)) T=$([Math]::Round($topCnc,3)) B=$([Math]::Round($bottomCnc,3))"
        Write-Host "  Measured size: $([Math]::Round($measW,1)) x $([Math]::Round($measH,1)) px (expected $($btn.bw)x$($btn.bh))"
        Write-Host "  True center (approx): ($([Math]::Round($trueSx,1)),$([Math]::Round($trueSy,1))) expected ($cx,$cy)"

        $btnResults += [PSCustomObject]@{
            name=$name; expCx=$cx; expCy=$cy
            trueSx=[Math]::Round($trueSx,1); trueSy=[Math]::Round($trueSy,1)
            measW=[Math]::Round($measW,1); measH=[Math]::Round($measH,1)
            leftCnc=[Math]::Round($leftCnc,3); rightCnc=[Math]::Round($rightCnc,3)
            topCnc=[Math]::Round($topCnc,3); bottomCnc=[Math]::Round($bottomCnc,3)
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
# Linear regression: CNC = origin + screenPixel * scale
# ---------------------------------------------------------------------------
Write-Host "`n===== LINEAR REGRESSION ====="

# X axis: CNC_X = newXOrigin + screenX * newXScale
$nx = $xData.Count
if ($nx -ge 2) {
    $sumSx = 0.0; $sumCx = 0.0; $sumSxCx = 0.0; $sumSx2 = 0.0
    foreach ($d in $xData) {
        $sumSx   += $d.screenX
        $sumCx   += $d.cncX
        $sumSxCx += $d.screenX * $d.cncX
        $sumSx2  += $d.screenX * $d.screenX
    }
    $newXScale  = ($nx * $sumSxCx - $sumSx * $sumCx) / ($nx * $sumSx2 - $sumSx * $sumSx)
    $newXOrigin = ($sumCx - $newXScale * $sumSx) / $nx
} else {
    Write-Host 'Not enough X data for regression'
    $newXOrigin = $xOrigin; $newXScale = $xScale
}

# Y axis: CNC_Y = newYOrigin - screenY * newYScale
# Rewrite as CNC_Y = a + b * screenY where b = -yScale
$ny = $yData.Count
if ($ny -ge 2) {
    $sumSy = 0.0; $sumCy = 0.0; $sumSyCy = 0.0; $sumSy2 = 0.0
    foreach ($d in $yData) {
        $sumSy   += $d.screenY
        $sumCy   += $d.cncY
        $sumSyCy += $d.screenY * $d.cncY
        $sumSy2  += $d.screenY * $d.screenY
    }
    $negYScale  = ($ny * $sumSyCy - $sumSy * $sumCy) / ($ny * $sumSy2 - $sumSy * $sumSy)
    $newYOrigin = ($sumCy - $negYScale * $sumSy) / $ny
    $newYScale  = -$negYScale
} else {
    Write-Host 'Not enough Y data for regression'
    $newYOrigin = $yOrigin; $newYScale = $yScale
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
Write-Host "`nX data ($nx points):"
foreach ($d in $xData) {
    Write-Host "  screenX=$($d.screenX) -> cncX=$([Math]::Round($d.cncX, 3))"
}
Write-Host "Y data ($ny points):"
foreach ($d in $yData) {
    Write-Host "  screenY=$($d.screenY) -> cncY=$([Math]::Round($d.cncY, 3))"
}

Write-Host "`n===== CALIBRATION RESULTS ====="
Write-Host "Old: CNC_X = $xOrigin + screenX * $xScale"
Write-Host "     CNC_Y = $yOrigin - screenY * $yScale"
Write-Host "New: CNC_X = $([Math]::Round($newXOrigin, 4)) + screenX * $([Math]::Round($newXScale, 6))"
Write-Host "     CNC_Y = $([Math]::Round($newYOrigin, 4)) - screenY * $([Math]::Round($newYScale, 6))"

# Residuals with new mapping
Write-Host "`nResiduals (new mapping):"
$maxResX = 0.0; $maxResY = 0.0
foreach ($d in $xData) {
    $pred = $newXOrigin + $d.screenX * $newXScale
    $res = $d.cncX - $pred
    $resPx = $res / $newXScale
    if ([Math]::Abs($res) -gt $maxResX) { $maxResX = [Math]::Abs($res) }
    Write-Host "  X: sx=$($d.screenX) cnc=$([Math]::Round($d.cncX,3)) pred=$([Math]::Round($pred,3)) res=$([Math]::Round($res,3))mm ($([Math]::Round($resPx,1))px)"
}
foreach ($d in $yData) {
    $pred = $newYOrigin - $d.screenY * $newYScale
    $res = $d.cncY - $pred
    $resPx = $res / $newYScale
    if ([Math]::Abs($res) -gt $maxResY) { $maxResY = [Math]::Abs($res) }
    Write-Host "  Y: sy=$($d.screenY) cnc=$([Math]::Round($d.cncY,3)) pred=$([Math]::Round($pred,3)) res=$([Math]::Round($res,3))mm ($([Math]::Round($resPx,1))px)"
}
Write-Host "Max residual: X=$([Math]::Round($maxResX,3))mm ($([Math]::Round($maxResX/$newXScale,1))px), Y=$([Math]::Round($maxResY,3))mm ($([Math]::Round($maxResY/$newYScale,1))px)"
Write-Host "Total probes: $probeCount"

# Save results
$btnResults | Format-Table -AutoSize
$csv = Join-Path $outDir 'edge_cal.csv'
$btnResults | Export-Csv $csv -NoTypeInformation
Write-Host "Log: $csv"
