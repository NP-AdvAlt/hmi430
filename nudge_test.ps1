# nudge_test.ps1 -- Find exact offset for 4x4px buttons by nudging
# Starts at mapped center, spirals outward in 0.1mm steps until hit

. "$PSScriptRoot\mtp_screenshot.ps1"
Add-Type -AssemblyName System.Drawing

$nodeExe  = 'C:\Claude\hmi430\node\node-v22.14.0-win-x64\node.exe'
$genJs    = 'C:\Claude\hmi430\gen_test_buttons.js'
$buildJs  = 'C:\Claude\hmi430\splat_build.js'
$buildBd  = 'C:\Claude\hmi430\_build.b1d'
$binPath  = 'C:\Claude\hmi430\_build.b1n'
$mtpExe   = 'C:\Claude\hmi430\MtpCopy.exe'
$outDir   = 'C:\Claude\hmi430\screen_captures\nudge_test'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Get-ChildItem $outDir -Filter '*.png' | Remove-Item -Force

# Edge-calibrated mapping
$xOrigin = 43.5461; $xScale = 0.198095
$yOrigin = -22.9126; $yScale = 0.199934

$touchZ = -14.0; $safeZ = 0.0

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

$probeN = 0

function PressAndCheck([double]$cncX, [double]$cncY, [double]$btnCx, [double]$btnCy, [string]$label) {
    $script:probeN++
    $n = $script:probeN
    Send $port "G0 Z$safeZ" -wait
    Send $port "G0 X$([Math]::Round($cncX,3)) Y$([Math]::Round($cncY,3))" -wait
    Send $port "G0 Z$touchZ" -wait
    Start-Sleep -Milliseconds 400

    $shotPath = Get-MtpScreenshot -OutDir $outDir
    $dest = Join-Path $outDir "${label}_$n.png"
    if (Test-Path $dest) { Remove-Item $dest -Force }
    Move-Item $shotPath $dest

    Send $port "G0 Z$safeZ" -wait

    $pressed = IsButtonPressed $dest $btnCx $btnCy
    $status = if ($pressed) { 'HIT' } else { 'miss' }
    Write-Host "    #$n CNC($([Math]::Round($cncX,2)),$([Math]::Round($cncY,2))) -> $status"
    return $pressed
}

# Spiral search: try center, then offsets in expanding rings
# Steps are 0.1mm (~0.5px). Spiral order: center, +-X, +-Y, then diagonals, expanding
function SpiralSearch([double]$baseCncX, [double]$baseCncY, [double]$btnCx, [double]$btnCy, [string]$label) {
    $step = 0.1  # mm per step (~0.5px)
    # Try center first
    if (PressAndCheck $baseCncX $baseCncY $btnCx $btnCy $label) {
        return @{ dxMm = 0.0; dyMm = 0.0 }
    }
    # Spiral outward
    for ($ring = 1; $ring -le 12; $ring++) {
        $d = $ring * $step
        # Try all positions on this ring (cardinal + diagonal)
        $offsets = @(
            @{ dx = $d;  dy = 0 },
            @{ dx = -$d; dy = 0 },
            @{ dx = 0;   dy = $d },
            @{ dx = 0;   dy = -$d },
            @{ dx = $d;  dy = $d },
            @{ dx = $d;  dy = -$d },
            @{ dx = -$d; dy = $d },
            @{ dx = -$d; dy = -$d }
        )
        foreach ($o in $offsets) {
            $testX = $baseCncX + $o.dx
            $testY = $baseCncY + $o.dy
            if (PressAndCheck $testX $testY $btnCx $btnCy $label) {
                return @{ dxMm = $o.dx; dyMm = $o.dy }
            }
        }
    }
    return $null
}

# --- Build and flash ---
Write-Host '=== Generating 4x4px test buttons ==='
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

# --- Search for button 0 ---
try {
    Send $port 'G0 Z0' -wait

    $btn0cx = 100.0; $btn0cy = 100.0
    $base0X = $xOrigin + $btn0cx * $xScale
    $base0Y = $yOrigin - $btn0cy * $yScale

    Write-Host "`n=== Button 0: near-TL center=($btn0cx,$btn0cy) ==="
    Write-Host "  Base CNC: ($([Math]::Round($base0X,3)), $([Math]::Round($base0Y,3)))"
    $hit0 = SpiralSearch $base0X $base0Y $btn0cx $btn0cy 'btn0'

    if ($hit0) {
        $dxPx = [Math]::Round($hit0.dxMm / $xScale, 1)
        $dyPx = [Math]::Round(-$hit0.dyMm / $yScale, 1)  # CNC Y is inverted
        Write-Host "  FOUND at offset: dX=$($hit0.dxMm)mm ($($dxPx)px), dY=$($hit0.dyMm)mm ($($dyPx)px)"

        # Apply correction to mapping for button 1
        $corrX = $hit0.dxMm
        $corrY = $hit0.dyMm
        Write-Host "  Applying correction ($corrX, $corrY) mm for button 1..."
    } else {
        Write-Host '  NOT FOUND within search radius'
        $corrX = 0.0; $corrY = 0.0
    }

    # --- Search for button 1 with correction ---
    $btn1cx = 410.0; $btn1cy = 202.0
    $base1X = $xOrigin + $btn1cx * $xScale + $corrX
    $base1Y = $yOrigin - $btn1cy * $yScale + $corrY

    Write-Host "`n=== Button 1: near-BR center=($btn1cx,$btn1cy) ==="
    Write-Host "  Base CNC (corrected): ($([Math]::Round($base1X,3)), $([Math]::Round($base1Y,3)))"
    $hit1 = SpiralSearch $base1X $base1Y $btn1cx $btn1cy 'btn1'

    if ($hit1) {
        $dxPx = [Math]::Round($hit1.dxMm / $xScale, 1)
        $dyPx = [Math]::Round(-$hit1.dyMm / $yScale, 1)
        Write-Host "  FOUND at offset: dX=$($hit1.dxMm)mm ($($dxPx)px), dY=$($hit1.dyMm)mm ($($dyPx)px)"
    } else {
        Write-Host '  NOT FOUND within search radius'
    }

    # --- Summary ---
    Write-Host "`n===== SUMMARY ====="
    Write-Host "Button 0 (100,100): offset = $($hit0.dxMm)mm, $($hit0.dyMm)mm"
    Write-Host "Button 1 (410,202): offset = $($hit1.dxMm)mm, $($hit1.dyMm)mm (after btn0 correction)"
    Write-Host "Total probes: $probeN"

    if ($hit0) {
        $newXOrigin = [Math]::Round($xOrigin + $hit0.dxMm, 4)
        $newYOrigin = [Math]::Round($yOrigin + $hit0.dyMm, 4)
        Write-Host "`nSuggested updated mapping:"
        Write-Host "  xOrigin = $newXOrigin (was $xOrigin)"
        Write-Host "  yOrigin = $newYOrigin (was $yOrigin)"
    }

} finally {
    Write-Host "`n=== Cleanup ==="
    try { Send $port 'G0 Z0' -wait } catch {}
    try { Send $port 'G0 X0 Y0' -wait } catch {}
    Send $port 'M5'
    $port.Close()
}
