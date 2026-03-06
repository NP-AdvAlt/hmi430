# calibrate_zones.ps1
# CNC booper presses all 9 HMI430 touch zones, then takes an MTP screenshot
# and checks which zones turned white (pressed). Writes calibration_log.csv.
#
# Prerequisites:
#   - CNC homed (run cnc_sethome.ps1 or home manually)
#   - HMI430 powered on and displaying the touch grid (ui_test.spt firmware)
#   - HMI430 USB connected (MTP accessible in Windows Explorer)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File calibrate_zones.ps1

. "$PSScriptRoot\mtp_screenshot.ps1"
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# CNC setup
# ---------------------------------------------------------------------------
$port = $null
$comPort = $null

# Auto-detect CH340 CNC port
$cnc = Get-PnpDevice | Where-Object { $_.FriendlyName -match 'CH340' -and $_.Status -eq 'OK' } | Select-Object -First 1
if ($cnc) {
    if ($cnc.FriendlyName -match 'COM(\d+)') { $comPort = "COM$($Matches[1])" }
}
if (-not $comPort) {
    # Fallback: try common ports
    foreach ($p in @('COM13','COM12','COM11','COM14')) {
        if ([System.IO.Ports.SerialPort]::GetPortNames() -contains $p) { $comPort = $p; break }
    }
}
if (-not $comPort) { throw "CNC COM port not found. Is CH340 connected?" }
Write-Host "CNC port: $comPort"

$port = [System.IO.Ports.SerialPort]::new($comPort, 115200)
$port.ReadTimeout = 3000
$port.Open()
Start-Sleep -Milliseconds 500

function Send-Gcode {
    param([string]$cmd, [int]$waitMs = 200)
    $port.WriteLine($cmd)
    Start-Sleep -Milliseconds $waitMs
    # Drain any response
    try { while ($port.BytesToRead -gt 0) { $port.ReadLine() | Out-Null } } catch {}
}

function Wait-Idle {
    # Poll ?-status until Idle
    $deadline = [DateTime]::Now.AddSeconds(30)
    while ([DateTime]::Now -lt $deadline) {
        $port.Write("?")
        Start-Sleep -Milliseconds 100
        try {
            $resp = $port.ReadLine()
            if ($resp -match 'Idle') { return }
        } catch {}
    }
    Write-Warning "Machine did not reach Idle state within 30s"
}

# ---------------------------------------------------------------------------
# Zone definitions
# CNC coordinates: zone centers, from config.spt (col x row)
# Col 0 -> CNC X 107-138 (center 122.5), Col 1 -> X 76-107 (91.5), Col 2 -> X 45-76 (60.5)
# Row 0 -> CNC Y -77/-60  (center -68.5), Row 1 -> Y -60/-43 (-51.5), Row 2 -> Y -43/-26 (-34.5)
# ---------------------------------------------------------------------------
$zones = @(
    @{col=0; row=0; x=122.5; y=-68.5},
    @{col=1; row=0; x=91.5;  y=-68.5},
    @{col=2; row=0; x=60.5;  y=-68.5},
    @{col=0; row=1; x=122.5; y=-51.5},
    @{col=1; row=1; x=91.5;  y=-51.5},
    @{col=2; row=1; x=60.5;  y=-51.5},
    @{col=0; row=2; x=122.5; y=-34.5},
    @{col=1; row=2; x=91.5;  y=-34.5},
    @{col=2; row=2; x=60.5;  y=-34.5}
)

$touchZ   = -14    # press depth (touch registered here)
$hoverZ   = -4     # retract 10mm between moves
$safeZ    = 0      # full retract for XY travel

$outDir = "C:\Claude\hmi430\screen_captures\latest"

try {
    # ---------------------------------------------------------------------------
    # Power on HMI and wait for boot
    # ---------------------------------------------------------------------------
    Write-Host "Powering on HMI430..."
    Send-Gcode "M3 S1000" 500
    Write-Host "Waiting 12s for HMI430 to boot..."
    Start-Sleep -Seconds 12

    # ---------------------------------------------------------------------------
    # Full retract at start
    # ---------------------------------------------------------------------------
    Write-Host "Retracting to Z=0..."
    Send-Gcode "G0 Z$safeZ" 1000
    Wait-Idle

    # Move to first zone XY, then hover
    $first = $zones[0]
    Write-Host "Moving to first zone XY ($($first.x), $($first.y))..."
    Send-Gcode "G0 X$($first.x) Y$($first.y)" 1500
    Wait-Idle
    Send-Gcode "G0 Z$hoverZ" 800
    Wait-Idle

    # ---------------------------------------------------------------------------
    # Press each zone in order
    # ---------------------------------------------------------------------------
    foreach ($z in $zones) {
        Write-Host "  Zone ($($z.col),$($z.row))  X=$($z.x) Y=$($z.y)"

        # Move XY while at hover height
        Send-Gcode "G0 X$($z.x) Y$($z.y)" 1200
        Wait-Idle

        # Touch
        Send-Gcode "G0 Z$touchZ" 600
        Wait-Idle
        Start-Sleep -Milliseconds 300      # hold briefly for display to register

        # Retract 10mm only
        Send-Gcode "G0 Z$hoverZ" 500
        Wait-Idle
        Start-Sleep -Milliseconds 500      # wait for display update
    }

    # ---------------------------------------------------------------------------
    # Full retract at end
    # ---------------------------------------------------------------------------
    Write-Host "Full retract..."
    Send-Gcode "G0 Z$safeZ" 1000
    Wait-Idle

    # ---------------------------------------------------------------------------
    # MTP screenshot (device must still be powered on)
    # ---------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Taking MTP screenshot..."
    $shotPath = Get-MtpScreenshot -OutDir $outDir
    Write-Host "Screenshot saved: $shotPath"

    # Power off after screenshot
    Write-Host "Powering off HMI430..."
    Send-Gcode "M5" 300

} finally {
    if ($port -and $port.IsOpen) { $port.Close() }
}

# ---------------------------------------------------------------------------
# Brightness analysis — detect which zones turned white
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Analysing zones..."

function Test-ZonePressed {
    param($bmp, [int]$col, [int]$row)
    $x = $col * 160
    $y = if ($row -eq 2) { 182 } else { $row * 91 }
    $h = if ($row -eq 2) { 90  } else { 91 }
    $cx = $x + 80
    $cy = $y + [int]($h / 2)
    $total = 0.0; $n = 0
    for ($px = ($cx - 10); $px -lt ($cx + 10); $px++) {
        for ($py = ($cy - 10); $py -lt ($cy + 10); $py++) {
            $p = $bmp.GetPixel($px, $py)
            $total += 0.299 * $p.R + 0.587 * $p.G + 0.114 * $p.B
            $n++
        }
    }
    $avg = $total / $n
    return [PSCustomObject]@{ Pressed = ($avg -gt 200); AvgBrightness = [Math]::Round($avg, 1) }
}

$bmp = [System.Drawing.Bitmap]::new($shotPath)
$results = @()
$pass = 0; $fail = 0

foreach ($z in $zones) {
    $r = Test-ZonePressed -bmp $bmp -col $z.col -row $z.row
    $status = if ($r.Pressed) { "PASS"; $pass++ } else { "FAIL"; $fail++ }
    Write-Host "  $status  zone($($z.col),$($z.row))  X=$($z.x) Y=$($z.y)  brightness=$($r.AvgBrightness)"
    $results += [PSCustomObject]@{
        col           = $z.col
        row           = $z.row
        cncX          = $z.x
        cncY          = $z.y
        pressed       = $r.Pressed
        avgBrightness = $r.AvgBrightness
    }
}
$bmp.Dispose()

# ---------------------------------------------------------------------------
# Write CSV log
# ---------------------------------------------------------------------------
$csvPath = Join-Path $outDir "calibration_log.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host ""
Write-Host "Result: $pass/9 PASS  (log: $csvPath)"
