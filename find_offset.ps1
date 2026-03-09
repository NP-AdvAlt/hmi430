# find_offset.ps1
# Press a grid around btn17 (screen center, predicted CNC 91.01,-48.02).
# After each press, compare screenshot to previous to detect newly-lit squares.
# First hit reveals the actual CNC-to-screen offset.
# All presses in one HMI power-on session — no reboots needed.
#
# Usage: powershell -ExecutionPolicy Bypass -File find_offset.ps1

. "$PSScriptRoot\mtp_screenshot.ps1"
Add-Type -AssemblyName System.Drawing

# Reference button: btn17 at screen center
$btnCx = 242; $btnCy = 154   # screen center of btn17
$predX = 91.01; $predY = -48.02  # predicted CNC position

# Scan grid: 7x7 at 2mm steps (±6mm), sorted center-out
$raw = @()
for ($dy = -6; $dy -le 6; $dy += 2) {
    for ($dx = -6; $dx -le 6; $dx += 2) {
        $raw += [PSCustomObject]@{
            dx   = $dx; dy = $dy
            cncX = [Math]::Round($predX + $dx, 2)
            cncY = [Math]::Round($predY + $dy, 2)
            dist = [Math]::Sqrt($dx*$dx + $dy*$dy)
        }
    }
}
$scanPoints = $raw | Sort-Object dist   # center-outward
Write-Host "Scan: $($scanPoints.Count) points, ±6mm at 2mm steps, center-out"
Write-Host "Target: btn17 screen($btnCx,$btnCy)  predCNC($predX,$predY)"
Write-Host ""

# Helper: sample brightness at a screen point (5px radius)
function Get-Bright($bmp, [int]$cx, [int]$cy) {
    $t = 0.0; $n = 0
    for ($px = $cx-5; $px -lt $cx+5; $px++) {
        for ($py = $cy-5; $py -lt $cy+5; $py++) {
            $p = $bmp.GetPixel($px, $py)
            $t += 0.299*$p.R + 0.587*$p.G + 0.114*$p.B; $n++
        }
    }
    return $t/$n
}

# CNC setup
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
$port.ReadTimeout = 3000; $port.Open(); Start-Sleep -Milliseconds 500

function Send-Gcode { param([string]$cmd,[int]$waitMs=200)
    $port.WriteLine($cmd); Start-Sleep -Milliseconds $waitMs
    try { while ($port.BytesToRead -gt 0) { $port.ReadLine() | Out-Null } } catch {} }
function Wait-Idle {
    $d = [DateTime]::Now.AddSeconds(30)
    while ([DateTime]::Now -lt $d) {
        $port.Write("?"); Start-Sleep -Milliseconds 100
        try { $r = $port.ReadLine(); if ($r -match 'Idle') { return } } catch {}
    }
}

$touchZ = -14; $hoverZ = -4; $safeZ = 0
$outDir = "C:\Claude\hmi430\screen_captures\scan"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$results = [System.Collections.Generic.List[PSObject]]::new()

try {
    Write-Host "Powering on HMI430..."
    Send-Gcode "M3 S1000" 500
    Write-Host "Waiting 12s for boot..."
    Start-Sleep -Seconds 12

    Send-Gcode "G0 Z$safeZ" 1000; Wait-Idle

    # --- Baseline screenshot (all gray) ---
    Write-Host "Taking baseline screenshot..."
    $baseFile = Get-MtpScreenshot -OutDir $outDir
    $baseBmp  = [System.Drawing.Bitmap]::new($baseFile)
    $prevBright = Get-Bright $baseBmp $btnCx $btnCy
    $baseBmp.Dispose()
    Write-Host "Baseline btn17 brightness: $([Math]::Round($prevBright,1))  (gray≈97, white=255)"
    Write-Host ""

    # Move to first scan position and hover
    $first = $scanPoints[0]
    Send-Gcode "G0 X$($first.cncX) Y$($first.cncY)" 1200; Wait-Idle
    Send-Gcode "G0 Z$hoverZ" 800; Wait-Idle

    $i = 0
    $foundAt = $null

    foreach ($pt in $scanPoints) {
        $i++
        Write-Host "  [$i/$($scanPoints.Count)] offset($($pt.dx),$($pt.dy))mm  CNC($($pt.cncX),$($pt.cncY))"

        # Move XY at hover, then press
        Send-Gcode "G0 X$($pt.cncX) Y$($pt.cncY)" 1000; Wait-Idle
        Send-Gcode "G0 Z$touchZ" 500; Wait-Idle
        Start-Sleep -Milliseconds 300
        Send-Gcode "G0 Z$hoverZ" 400; Wait-Idle
        Start-Sleep -Milliseconds 300

        # Screenshot and compare
        $sfile = Get-MtpScreenshot -OutDir $outDir
        $bmp   = [System.Drawing.Bitmap]::new($sfile)
        $bright = Get-Bright $bmp $btnCx $btnCy
        $bmp.Dispose()

        $delta = $bright - $prevBright
        Write-Host "    btn17 brightness: $([Math]::Round($bright,1))  (delta: $([Math]::Round($delta,1)))"

        $results.Add([PSCustomObject]@{
            step   = $i; dx=$pt.dx; dy=$pt.dy
            cncX   = $pt.cncX; cncY = $pt.cncY
            bright = [Math]::Round($bright,1)
        })

        if ($bright -gt 200 -and -not $foundAt) {
            $foundAt = $pt
            Write-Host ""
            Write-Host "*** HIT at offset($($pt.dx),$($pt.dy))mm  CNC($($pt.cncX),$($pt.cncY)) ***"
            Write-Host "    Predicted was: ($predX, $predY)"
            Write-Host "    Offset: dX=$($pt.dx)mm  dY=$($pt.dy)mm"
            # Continue scanning to map the full response area
        }

        $prevBright = $bright
    }

    Send-Gcode "G0 Z$safeZ" 1000; Wait-Idle
    Send-Gcode "M5" 300

} finally {
    if ($port -and $port.IsOpen) { $port.Close() }
}

# ---------------------------------------------------------------------------
# Results summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== SCAN RESULTS ==="
$hits = $results | Where-Object { $_.bright -gt 200 }
if (-not $foundAt) {
    Write-Host "No hit found in ±6mm scan."
    Write-Host "Possible causes: offset >6mm, or Z not reaching screen."
    Write-Host "Brightest point was:"
    $results | Sort-Object bright -Descending | Select-Object -First 3 |
        ForEach-Object { Write-Host "  offset($($_.dx),$($_.dy)) bright=$($_.bright)" }
} else {
    Write-Host "First hit: offset($($foundAt.dx), $($foundAt.dy)) mm"
    Write-Host ""

    # Compute centroid of all hits (average offset = best estimate of true center)
    if ($hits.Count -gt 1) {
        $avgDx = ($hits | Measure-Object dx -Average).Average
        $avgDy = ($hits | Measure-Object dy -Average).Average
        Write-Host "All hits: $($hits.Count)  avg offset: dX=$([Math]::Round($avgDx,2)) dY=$([Math]::Round($avgDy,2))"
        Write-Host ""
        Write-Host "=== APPLY THIS CORRECTION ==="
        Write-Host "In calibrate_zones.ps1, change:"
        Write-Host "  `$xOrigin = $([Math]::Round(138.0 + $avgDx * (93.0/479.0) * (479.0/93.0), 2))"
        Write-Host "  No wait — add these offsets directly to CNC coords:"
        Write-Host "  `$xOffset = $([Math]::Round($avgDx,2))   # mm to ADD to all CNC X"
        Write-Host "  `$yOffset = $([Math]::Round($avgDy,2))   # mm to ADD to all CNC Y"
    } else {
        Write-Host "Single hit. Offset: dX=$($foundAt.dx) dY=$($foundAt.dy)"
        Write-Host ""
        Write-Host "=== APPLY THIS CORRECTION ==="
        Write-Host "  `$xOffset = $($foundAt.dx)   # mm to ADD to all CNC X"
        Write-Host "  `$yOffset = $($foundAt.dy)   # mm to ADD to all CNC Y"
    }
}

$csvPath = Join-Path $outDir "offset_scan.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host ""
Write-Host "Full scan log: $csvPath"
