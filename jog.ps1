# Keyboard jog controller
#
# Controls:
#   Left/Right arrows  = X- / X+           (range 0 to +160)
#   Up/Down arrows     = Y- / Y+           (range 0 to -100, Up moves away from user)
#   Page Up/Down       = Z+ / Z-           (range 0 to -20,  PgUp retracts)
#   + / -              = step size up / down
#   X / Y / Z          = zero that axis at current position
#   1 / 2 / 3          = return X / Y / Z to zero
#   C                  = capture corner (up to 2, for screen calibration)
#   Q or Escape        = quit

param([int]$Feed = 600)

function FindCH340 {
    $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
           Where-Object { $_.FriendlyName -match 'CH340' }
    return $dev.FriendlyName -replace '.*\((.+)\).*','$1'
}

function ReadG54($port) {
    $port.WriteLine('$#'); Start-Sleep -Milliseconds 600
    $hash = $port.ReadExisting()
    $g54 = [regex]::Match($hash, '\[G54:([0-9.\-,]+)\]').Groups[1].Value
    if (-not $g54) { return '0,0,0' }
    return $g54
}

function GetWorkPos($port, $g54) {
    $port.Write('?'); Start-Sleep -Milliseconds 200
    $r = $port.ReadExisting()
    $mpos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
    if (-not $mpos) { return $null }
    $mp = $mpos -split ','; $wc = $g54 -split ','
    return [pscustomobject]@{
        X = [math]::Round([double]$mp[0]-[double]$wc[0], 2)
        Y = [math]::Round([double]$mp[1]-[double]$wc[1], 2)
        Z = [math]::Round([double]$mp[2]-[double]$wc[2], 2)
    }
}

function WaitIdle($port, $timeoutMs = 8000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?'); Start-Sleep -Milliseconds 80
        if ($port.ReadExisting() -match 'Idle') { return }
    }
}

function SendJog($port, $axis, $dist, $feed) {
    $cmd = "G91 G1 ${axis}${dist} F${feed}"
    $port.WriteLine($cmd)
    Start-Sleep -Milliseconds 300
    $resp = $port.ReadExisting().Trim() -replace "`r`n",' '
    if ($resp -notmatch 'ok') {
        $script:msg = "[$cmd] -> [$resp]"
        return
    }
    WaitIdle $port
}

function SendCmd($port, $cmd) {
    $port.WriteLine($cmd); Start-Sleep -Milliseconds 300
    $port.ReadExisting() | Out-Null
    WaitIdle $port 15000
}

function DrawUI($pos, $step, $corners, $msg) {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  CNC KEYBOARD JOG" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    if ($pos) {
        Write-Host ("  Position:  X={0,8:F2}  Y={1,8:F2}  Z={2,8:F2}" -f $pos.X, $pos.Y, $pos.Z) -ForegroundColor Yellow
    }
    Write-Host ("  Step:      {0} mm" -f $step) -ForegroundColor Green
    Write-Host ""
    Write-Host "  Left/Right    = X- / X+     (0 to +160)" -ForegroundColor Gray
    Write-Host "  Up/Down       = Y- / Y+     (0 to -100)" -ForegroundColor Gray
    Write-Host "  PgUp/PgDn     = Z+ / Z-     (0 to  -20)" -ForegroundColor Gray
    Write-Host "  + / -         = step size" -ForegroundColor Gray
    Write-Host "  X / Y / Z     = zero axis here" -ForegroundColor White
    Write-Host "  1 / 2 / 3     = return X / Y / Z to zero" -ForegroundColor White
    Write-Host "  C             = capture corner" -ForegroundColor White
    Write-Host "  Q / Esc       = quit" -ForegroundColor Gray
    Write-Host ""

    for ($i = 0; $i -lt $corners.Count; $i++) {
        $c = $corners[$i]
        Write-Host ("  Corner {0}: X={1,7:F2}  Y={2,7:F2}  Z={3,7:F2}" -f ($i+1), $c.X, $c.Y, $c.Z) -ForegroundColor Magenta
    }
    if ($corners.Count -lt 2) {
        for ($i = $corners.Count; $i -lt 2; $i++) {
            Write-Host ("  Corner {0}: (not captured)" -f ($i+1)) -ForegroundColor DarkGray
        }
    }
    if ($msg) {
        Write-Host ""
        Write-Host "  >> $msg" -ForegroundColor Cyan
    }
}

# ── Connect ───────────────────────────────────────────────────────────────────
$com = FindCH340
Write-Host "Connecting to $com..."
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 2000; $port.Open()
Start-Sleep -Milliseconds 1000; $port.ReadExisting() | Out-Null
$port.WriteLine(''); Start-Sleep -Milliseconds 400; $port.ReadExisting() | Out-Null
$port.WriteLine('G21'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
$port.WriteLine('G90'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
$port.WriteLine('G54'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
$port.WriteLine('$20=0'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null

$g54     = ReadG54 $port
$steps   = @(0.1, 0.5, 1.0, 5.0, 10.0, 50.0)
$stepIdx = 2   # default 1.0 mm
$corners = @()
$msg     = "Soft limits OFF. Jog freely. X:0-+160  Y:0--100  Z:0--20"

try {
    while ($true) {
        $pos = GetWorkPos $port $g54
        DrawUI $pos $steps[$stepIdx] $corners $msg
        $msg = ""

        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'RightArrow' { SendJog $port 'X'  $steps[$stepIdx] $Feed }
            'LeftArrow'  { SendJog $port 'X' (-$steps[$stepIdx]) $Feed }
            'UpArrow'    { SendJog $port 'Y' (-$steps[$stepIdx]) $Feed }
            'DownArrow'  { SendJog $port 'Y'  ($steps[$stepIdx]) $Feed }
            'PageUp'     { SendJog $port 'Z'  ($steps[$stepIdx]) $Feed }
            'PageDown'   { SendJog $port 'Z' (-$steps[$stepIdx]) $Feed }

            'OemPlus'    { if ($stepIdx -lt $steps.Count-1) { $stepIdx++ } }
            'Add'        { if ($stepIdx -lt $steps.Count-1) { $stepIdx++ } }
            'OemMinus'   { if ($stepIdx -gt 0) { $stepIdx-- } }
            'Subtract'   { if ($stepIdx -gt 0) { $stepIdx-- } }

            'X' {
                $port.WriteLine('G10 L20 P1 X0')
                Start-Sleep -Milliseconds 300; $port.ReadExisting() | Out-Null
                $g54 = ReadG54 $port
                $msg = "X zeroed here."
            }
            'Y' {
                $port.WriteLine('G10 L20 P1 Y0')
                Start-Sleep -Milliseconds 300; $port.ReadExisting() | Out-Null
                $g54 = ReadG54 $port
                $msg = "Y zeroed here."
            }
            'Z' {
                $port.WriteLine('G10 L20 P1 Z0')
                Start-Sleep -Milliseconds 300; $port.ReadExisting() | Out-Null
                $g54 = ReadG54 $port
                $msg = "Z zeroed here."
            }

            'D1' { SendCmd $port 'G90 G0 X0'; $msg = "Moved X to zero." }
            'D2' { SendCmd $port 'G90 G0 Y0'; $msg = "Moved Y to zero." }
            'D3' { SendCmd $port 'G90 G0 Z0'; $msg = "Moved Z to zero." }

            'C' {
                $p = GetWorkPos $port $g54
                if ($corners.Count -lt 2) {
                    $corners += $p
                    $msg = "Corner $($corners.Count) captured: X=$($p.X) Y=$($p.Y)"
                } else {
                    $msg = "Both corners captured. Press Q for results."
                }
            }

            { $_ -eq 'Q' -or $_ -eq 'Escape' } { Clear-Host; break }
        }

        if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape') { break }
    }
} finally {
    $port.WriteLine('$20=1'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
    $port.Close()
    Write-Host "Soft limits re-enabled."
}

# ── Results ───────────────────────────────────────────────────────────────────
if ($corners.Count -eq 2) {
    $tl = $corners[0]; $br = $corners[1]
    $screenW = [math]::Round([math]::Abs($br.X - $tl.X), 1)
    $screenH = [math]::Round([math]::Abs($br.Y - $tl.Y), 1)
    $minX = [math]::Min($tl.X, $br.X); $maxX = [math]::Max($tl.X, $br.X)
    $minY = [math]::Min($tl.Y, $br.Y); $maxY = [math]::Max($tl.Y, $br.Y)
    $ix = [math]::Round($screenW * 0.12, 1)
    $iy = [math]::Round($screenH * 0.12, 1)

    Write-Host "========================================"  -ForegroundColor Cyan
    Write-Host " CALIBRATION RESULTS"                      -ForegroundColor Cyan
    Write-Host "========================================"  -ForegroundColor Cyan
    Write-Host "Corner 1: X=$($tl.X)  Y=$($tl.Y)"
    Write-Host "Corner 2: X=$($br.X)  Y=$($br.Y)"
    Write-Host "Screen:   ${screenW} x ${screenH} mm"
    Write-Host "Center:   X=$(($tl.X+$br.X)/2.0)  Y=$(($tl.Y+$br.Y)/2.0)"
    Write-Host ""
    Write-Host "Button positions:" -ForegroundColor Yellow
    Write-Host ("  Config   (bottom-left):  X={0}  Y={1}" -f ($minX+$ix), ($minY+$iy))
    Write-Host ("  Settings (bottom-right): X={0}  Y={1}" -f ($maxX-$ix), ($minY+$iy))
} elseif ($corners.Count -eq 1) {
    Write-Host "1 corner captured: X=$($corners[0].X)  Y=$($corners[0].Y)"
} else {
    Write-Host "No corners captured."
}
