# touch_test.ps1 -- Verify mapping by hitting two 4x4px buttons
# Button 0: center (100, 100), Button 1: center (410, 202)

. "$PSScriptRoot\mtp_screenshot.ps1"
Add-Type -AssemblyName System.Drawing

$nodeExe  = 'C:\Claude\hmi430\node\node-v22.14.0-win-x64\node.exe'
$genJs    = 'C:\Claude\hmi430\gen_test_buttons.js'
$buildJs  = 'C:\Claude\hmi430\splat_build.js'
$buildBd  = 'C:\Claude\hmi430\_build.b1d'
$binPath  = 'C:\Claude\hmi430\_build.b1n'
$mtpExe   = 'C:\Claude\hmi430\MtpCopy.exe'
$outDir   = 'C:\Claude\hmi430\screen_captures\touch_test'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Edge-calibrated mapping (2026-03-11)
$xOrigin = 43.5461; $xScale = 0.198095
$yOrigin = -22.9126; $yScale = 0.199934

$touchZ = -14.0; $safeZ = 0.0

# Buttons to test
$buttons = @(
    @{ name='near-TL'; cx=100.0; cy=100.0 },
    @{ name='near-BR'; cx=410.0; cy=202.0 }
)

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

function IsButtonPressed([string]$imgPath, [double]$cx, [double]$cy) {
    $bmp = [System.Drawing.Bitmap]::new($imgPath)
    # Sample a tiny 3x3 patch at button center
    $sum = 0.0; $n = 0
    for ($dx = -1; $dx -le 1; $dx++) {
        for ($dy = -1; $dy -le 1; $dy++) {
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

# --- Build and flash ---
Write-Host '=== Generating test button firmware ==='
& $nodeExe $genJs 2>&1 | Write-Host

Write-Host '=== Building ==='
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

Write-Host '=== Flashing ==='
$flashDeadline = [DateTime]::Now.AddSeconds(90)
$flashed = $false
while ([DateTime]::Now -lt $flashDeadline -and -not $flashed) {
    $flashOut = & $mtpExe $binPath 2>&1 | Out-String
    if ($flashOut -match 'SUCCESS') { $flashed = $true; break }
    Write-Host '  retrying in 5s...'
    Start-Sleep -Seconds 5
}
if (-not $flashed) { throw 'Flash timed out' }
Write-Host 'Flash OK'
Write-Host 'Waiting 5s for reboot...'
Start-Sleep -Seconds 5

# --- Test each button ---
try {
    Send $port 'G0 Z0' -wait

    foreach ($btn in $buttons) {
        $name = $btn.name
        $cx = $btn.cx; $cy = $btn.cy
        $cncX = [Math]::Round($xOrigin + $cx * $xScale, 3)
        $cncY = [Math]::Round($yOrigin - $cy * $yScale, 3)

        Write-Host "`n=== Testing $name -- screen($cx,$cy) -> CNC($cncX,$cncY) ==="

        # Move and press
        Send $port "G0 Z$safeZ" -wait
        Send $port "G0 X$cncX Y$cncY" -wait
        Send $port "G0 Z$touchZ" -wait
        Start-Sleep -Milliseconds 500

        # Screenshot while pressing
        Write-Host '  Screenshot (booper down)...'
        $shotPath = Get-MtpScreenshot -OutDir $outDir
        $dest = Join-Path $outDir "$name.png"
        if (Test-Path $dest) { Remove-Item $dest -Force }
        Move-Item $shotPath $dest
        Write-Host "  Saved: $dest"

        # Retract
        Send $port "G0 Z$safeZ" -wait

        # Check if button was pressed
        $pressed = IsButtonPressed $dest $cx $cy
        if ($pressed) {
            Write-Host "  >>> HIT -- button turned black <<<"
        } else {
            Write-Host "  >>> MISS -- button stayed white <<<"
        }
    }

} finally {
    Write-Host "`n=== Cleanup ==="
    try { Send $port 'G0 Z0' -wait } catch {}
    try { Send $port 'G0 X0 Y0' -wait } catch {}
    Send $port 'M5'
    $port.Close()
}
