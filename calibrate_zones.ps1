# calibrate_zones.ps1
# CNC booper presses all 30 checkerboard touch targets (22x22px, 44px pitch),
# takes an MTP screenshot, checks brightness of target AND non-target squares.
# Writes calibration_log.csv with screen pixel coords and CNC coords.
#
# Grid: 10 cols x 6 rows at 44px pitch; target squares where (gc+gr) % 2 == 0
# CNC mapping (from config.spt):
#   CNC_X = 138 - screenX * (93/479)
#   CNC_Y = -77 + screenY * (51/271)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File calibrate_zones.ps1

. "$PSScriptRoot\mtp_screenshot.ps1"
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# CNC coordinate mapping constants
# ---------------------------------------------------------------------------
$xOrigin  = 138.0;  $xScale = 93.0 / 479.0    # CNC_X = xOrigin - screenX * xScale
$yOrigin  = -81.0;  $yScale = 51.0 / 271.0    # CNC_Y = yOrigin + screenY * yScale  (-4mm Y correction from offset scan)

# ---------------------------------------------------------------------------
# Build zone table: 30 target squares (gc+gr even) + 30 non-target squares
# ---------------------------------------------------------------------------
$targets    = [System.Collections.Generic.List[hashtable]]::new()
$nonTargets = [System.Collections.Generic.List[hashtable]]::new()
$btnId = 0

foreach ($gr in 0..5) {
    foreach ($gc in 0..9) {
        $cx = 22 + $gc * 44    # screen center X
        $cy = 22 + $gr * 44    # screen center Y
        $cncX = [Math]::Round($xOrigin - $cx * $xScale, 2)
        $cncY = [Math]::Round($yOrigin + $cy * $yScale, 2)
        $entry = @{ gridCol=$gc; gridRow=$gr; screenX=$cx; screenY=$cy; cncX=$cncX; cncY=$cncY }
        if (($gc + $gr) % 2 -eq 0) {
            $entry['btnId'] = $btnId
            $targets.Add($entry)
            $btnId++
        } else {
            $nonTargets.Add($entry)
        }
    }
}

Write-Host "Press targets:  $($targets.Count)"
Write-Host "Non-targets:    $($nonTargets.Count)"
Write-Host ""

# ---------------------------------------------------------------------------
# CNC setup
# ---------------------------------------------------------------------------
$comPort = $null
$cnc = Get-PnpDevice | Where-Object { $_.FriendlyName -match 'CH340' -and $_.Status -eq 'OK' } | Select-Object -First 1
if ($cnc -and ($cnc.FriendlyName -match 'COM(\d+)')) { $comPort = "COM$($Matches[1])" }
if (-not $comPort) {
    foreach ($p in @('COM13','COM12','COM15','COM11','COM14')) {
        if ([System.IO.Ports.SerialPort]::GetPortNames() -contains $p) { $comPort = $p; break }
    }
}
if (-not $comPort) { throw "CNC COM port not found." }
Write-Host "CNC port: $comPort"

$port = [System.IO.Ports.SerialPort]::new($comPort, 115200)
$port.ReadTimeout = 3000
$port.Open()
Start-Sleep -Milliseconds 500

function Send-Gcode {
    param([string]$cmd, [int]$waitMs = 200)
    $port.WriteLine($cmd)
    Start-Sleep -Milliseconds $waitMs
    try { while ($port.BytesToRead -gt 0) { $port.ReadLine() | Out-Null } } catch {}
}

function Wait-Idle {
    $deadline = [DateTime]::Now.AddSeconds(30)
    while ([DateTime]::Now -lt $deadline) {
        $port.Write("?")
        Start-Sleep -Milliseconds 100
        try { $resp = $port.ReadLine(); if ($resp -match 'Idle') { return } } catch {}
    }
    Write-Warning "Machine did not reach Idle within 30s"
}

$touchZ = -14; $hoverZ = -4; $safeZ = 0
$outDir = "C:\Claude\hmi430\screen_captures\latest"

try {
    # Power on and boot
    Write-Host "Powering on HMI430..."
    Send-Gcode "M3 S1000" 500
    Write-Host "Waiting 12s for HMI430 boot..."
    Start-Sleep -Seconds 12

    # Full retract, move to first target
    Send-Gcode "G0 Z$safeZ" 1000
    Wait-Idle
    $first = $targets[0]
    Send-Gcode "G0 X$($first.cncX) Y$($first.cncY)" 1500
    Wait-Idle
    Send-Gcode "G0 Z$hoverZ" 800
    Wait-Idle

    # Press each target
    $i = 0
    foreach ($z in $targets) {
        $i++
        Write-Host "  [$i/30] btn$($z.btnId)  gc=$($z.gridCol) gr=$($z.gridRow)  px=($($z.screenX),$($z.screenY))  CNC=($($z.cncX),$($z.cncY))"
        Send-Gcode "G0 X$($z.cncX) Y$($z.cncY)" 1200
        Wait-Idle
        Send-Gcode "G0 Z$touchZ" 600
        Wait-Idle
        Start-Sleep -Milliseconds 300
        Send-Gcode "G0 Z$hoverZ" 500
        Wait-Idle
        Start-Sleep -Milliseconds 400
    }

    # Full retract
    Send-Gcode "G0 Z$safeZ" 1000
    Wait-Idle

    # Screenshot while HMI is still on
    Write-Host ""
    Write-Host "Taking MTP screenshot..."
    $shotPath = Get-MtpScreenshot -OutDir $outDir
    Write-Host "Screenshot: $shotPath"

    Send-Gcode "M5" 300    # power off after screenshot

} finally {
    if ($port -and $port.IsOpen) { $port.Close() }
}

# ---------------------------------------------------------------------------
# Brightness analysis
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Analysing..."

function Get-AvgBrightness {
    param($bmp, [int]$cx, [int]$cy, [int]$radius = 5)
    $total = 0.0; $n = 0
    for ($px = ($cx - $radius); $px -lt ($cx + $radius); $px++) {
        for ($py = ($cy - $radius); $py -lt ($cy + $radius); $py++) {
            $p = $bmp.GetPixel($px, $py)
            $total += 0.299 * $p.R + 0.587 * $p.G + 0.114 * $p.B
            $n++
        }
    }
    return [Math]::Round($total / $n, 1)
}

$bmp = [System.Drawing.Bitmap]::new($shotPath)
$results = [System.Collections.Generic.List[PSObject]]::new()
$tPass = 0; $tFail = 0; $ntFail = 0

Write-Host ""
Write-Host "--- TARGET SQUARES (should be WHITE > 200) ---"
foreach ($z in $targets) {
    $bright = Get-AvgBrightness -bmp $bmp -cx $z.screenX -cy $z.screenY
    $ok = $bright -gt 200
    if ($ok) { $tPass++ } else { $tFail++ }
    $flag = if ($ok) { "PASS" } else { "FAIL" }
    Write-Host "  $flag  btn$($z.btnId) gc=$($z.gridCol) gr=$($z.gridRow) px=($($z.screenX),$($z.screenY)) bright=$bright"
    $results.Add([PSCustomObject]@{
        type       = "target"
        btnId      = $z.btnId
        gridCol    = $z.gridCol
        gridRow    = $z.gridRow
        screenX    = $z.screenX
        screenY    = $z.screenY
        cncX       = $z.cncX
        cncY       = $z.cncY
        brightness = $bright
        pass       = $ok
    })
}

Write-Host ""
Write-Host "--- NON-TARGET SQUARES (should be DARK < 100) ---"
foreach ($z in $nonTargets) {
    $bright = Get-AvgBrightness -bmp $bmp -cx $z.screenX -cy $z.screenY
    $ok = $bright -lt 100
    if (-not $ok) { $ntFail++; Write-Host "  BLEED  gc=$($z.gridCol) gr=$($z.gridRow) px=($($z.screenX),$($z.screenY)) bright=$bright" }
    $results.Add([PSCustomObject]@{
        type       = "non-target"
        btnId      = -1
        gridCol    = $z.gridCol
        gridRow    = $z.gridRow
        screenX    = $z.screenX
        screenY    = $z.screenY
        cncX       = $z.cncX
        cncY       = $z.cncY
        brightness = $bright
        pass       = $ok
    })
}
$bmp.Dispose()

# ---------------------------------------------------------------------------
# CSV + summary
# ---------------------------------------------------------------------------
$csvPath = Join-Path $outDir "calibration_log.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host ""
Write-Host "Targets:     $tPass/30 PASS  ($tFail FAIL)"
Write-Host "Bleed check: $(30 - $ntFail)/30 clean  ($ntFail non-target squares lit)"
Write-Host "Log:         $csvPath"
