# scan_offset.ps1
# Press a 5x5 raster around 4 widely-spaced predicted button positions.
# After all presses, one MTP screenshot reveals which buttons registered.
# The match between scan CNC positions and registered screen positions gives
# the actual CNC-to-screen calibration offset.
#
# Scan targets (predicted screen -> CNC):
#   btn1:  (110,22)  -> (116.64,-72.86)  top-left region
#   btn7:  (242,66)  -> ( 91.01,-64.58)  top-center
#   btn22: (198,198) -> ( 99.56,-39.74)  center
#   btn28: (330,242) -> ( 73.93,-31.46)  bottom-right region
#
# Scan: 5x5 grid at 2mm steps = 25 positions per target = 100 presses total
# One screenshot at end; check all 30 buttons for brightness > 200
#
# Usage: powershell -ExecutionPolicy Bypass -File scan_offset.ps1

. "$PSScriptRoot\mtp_screenshot.ps1"
Add-Type -AssemblyName System.Drawing

# CNC coordinate mapping
$xOrigin = 138.0; $xScale = 93.0 / 479.0
$yOrigin = -77.0; $yScale = 51.0 / 271.0

# All 30 checkerboard target buttons (for post-scan brightness check)
$allButtons = @()
$btnId = 0
foreach ($gr in 0..5) {
    foreach ($gc in 0..9) {
        if (($gc + $gr) % 2 -eq 0) {
            $cx = 22 + $gc * 44; $cy = 22 + $gr * 44
            $allButtons += @{ id=$btnId; cx=$cx; cy=$cy
                              tlX=(22+$gc*44-11); tlY=(22+$gr*44-11)
                              predCncX=[Math]::Round($xOrigin-$cx*$xScale,2)
                              predCncY=[Math]::Round($yOrigin+$cy*$yScale,2) }
            $btnId++
        }
    }
}

# Scan anchors: 4 widely-spaced buttons to detect any tilt/scale in offset
$anchors = @(
    @{ name="btn1-topleft";   predX=116.64; predY=-72.86; scBtnId=1  },
    @{ name="btn7-topright";  predX= 56.84; predY=-64.58; scBtnId=9  },
    @{ name="btn20-botleft";  predX=133.73; predY=-39.74; scBtnId=20 },
    @{ name="btn29-botright"; predX= 56.84; predY=-31.46; scBtnId=29 }
)

# Build full scan list: 5x5 around each anchor, 2mm steps (±4mm)
$step = 2.0; $range = 4
$scanList = @()
foreach ($anc in $anchors) {
    for ($dy = -$range; $dy -le $range; $dy += $step) {
        for ($dx = -$range; $dx -le $range; $dx += $step) {
            $scanList += @{
                anchor   = $anc.name
                scBtnId  = $anc.scBtnId
                dx       = $dx; dy = $dy
                cncX     = [Math]::Round($anc.predX + $dx, 2)
                cncY     = [Math]::Round($anc.predY + $dy, 2)
            }
        }
    }
}
Write-Host "Total scan presses: $($scanList.Count)"

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

try {
    Write-Host "Powering on HMI430..."
    Send-Gcode "M3 S1000" 500
    Write-Host "Waiting 12s for boot..."
    Start-Sleep -Seconds 12

    Send-Gcode "G0 Z$safeZ" 1000; Wait-Idle

    $i = 0
    foreach ($pt in $scanList) {
        $i++
        if ($i % 10 -eq 0 -or $i -eq 1) {
            Write-Host "  [$i/$($scanList.Count)] $($pt.anchor) CNC($($pt.cncX),$($pt.cncY)) offset($($pt.dx),$($pt.dy))"
        }
        Send-Gcode "G0 X$($pt.cncX) Y$($pt.cncY)" 1000; Wait-Idle
        Send-Gcode "G0 Z$touchZ" 500; Wait-Idle
        Start-Sleep -Milliseconds 250
        Send-Gcode "G0 Z$hoverZ" 400; Wait-Idle
        Start-Sleep -Milliseconds 200
    }

    Send-Gcode "G0 Z$safeZ" 1000; Wait-Idle

    Write-Host ""
    Write-Host "Taking MTP screenshot..."
    $shotPath = Get-MtpScreenshot -OutDir $outDir
    Write-Host "Screenshot: $shotPath"

    Send-Gcode "M5" 300

} finally {
    if ($port -and $port.IsOpen) { $port.Close() }
}

# ---------------------------------------------------------------------------
# Analyse: which buttons turned white?
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Analysing buttons..."
$bmp = [System.Drawing.Bitmap]::new($shotPath)

$hits = @()
foreach ($btn in $allButtons) {
    $total = 0.0; $n = 0
    for ($px = ($btn.cx - 5); $px -lt ($btn.cx + 5); $px++) {
        for ($py = ($btn.cy - 5); $py -lt ($btn.cy + 5); $py++) {
            $p = $bmp.GetPixel($px, $py)
            $total += 0.299*$p.R + 0.587*$p.G + 0.114*$p.B; $n++
        }
    }
    $bright = [Math]::Round($total/$n, 1)
    if ($bright -gt 200) {
        $hits += $btn
        Write-Host "  HIT  btn$($btn.id) screen($($btn.cx),$($btn.cy))  predCNC($($btn.predCncX),$($btn.predCncY))  bright=$bright"
    }
}
$bmp.Dispose()

if ($hits.Count -eq 0) {
    Write-Host "  No buttons turned white. Offset > 4mm or Z not reaching screen."
    Write-Host "  Try increasing scan range or re-verify Z calibration."
} else {
    Write-Host ""
    Write-Host "--- OFFSET ANALYSIS ---"
    Write-Host "Buttons hit: $($hits.Count)"
    foreach ($btn in $hits) {
        # Find which scan points were nearest to this button's predicted CNC position
        $nearest = $scanList | Sort-Object {
            [Math]::Sqrt([Math]::Pow($_.cncX - $btn.predCncX,2) + [Math]::Pow($_.cncY - $btn.predCncY,2))
        } | Select-Object -First 3
        Write-Host "  btn$($btn.id) screen($($btn.cx),$($btn.cy)) | nearest scan points:"
        foreach ($pt in $nearest) {
            $dist = [Math]::Round([Math]::Sqrt([Math]::Pow($pt.cncX - $btn.predCncX,2) + [Math]::Pow($pt.cncY - $btn.predCncY,2)),2)
            Write-Host "    $($pt.anchor) offset($($pt.dx),$($pt.dy)) CNC($($pt.cncX),$($pt.cncY)) dist=${dist}mm"
        }
    }
    Write-Host ""
    Write-Host "Tip: if hit buttons cluster around an anchor's scan offset (dx,dy),"
    Write-Host "that offset is the correction to add to calibrate_zones.ps1 xOrigin/yOrigin."
}
