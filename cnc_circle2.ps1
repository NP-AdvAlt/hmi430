# cnc_circle2.ps1 - Helical circle in work coordinate system (G54)
#
# Work coordinates (home = 0,0,0):
#   X: 0=left  ... 160=right
#   Y: 0=toward user  ... -100=away from user
#   Z: 0=head retracted ... -45=head at lowest
#
# Circle: 30mm radius centred at work (80, -50, -22.5)
# Start:  work (110, -50, -22.5)  -- rightmost point
#
# Quarter arcs (G2 = CW viewed from above):
#   Q1: (110,-50) -> (80,-80)   I=-30 J=0   Z -22.5 -> -32.5  (head drops)
#   Q2: (80,-80)  -> (50,-50)   I=0   J=30  Z -32.5 -> -22.5  (head rises)
#   Q3: (50,-50)  -> (80,-20)   I=30  J=0   Z -22.5 -> -12.5  (head rises)
#   Q4: (80,-20)  -> (110,-50)  I=0   J=-30 Z -12.5 -> -22.5  (head drops)

function WaitForIdle {
    param($port, $label = '', $timeoutSec = 45)
    Start-Sleep -Milliseconds 400
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?')
        Start-Sleep -Milliseconds 250
        $r = $port.ReadExisting()
        if ($r -match 'Alarm') { Write-Host "  [ALARM] $r"; return $false }
        if ($r -match 'Idle') {
            $wpos = [regex]::Match($r, 'WPos:([0-9.\-,]+)').Groups[1].Value
            $mpos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
            if ($wpos) { Write-Host "  [Idle] $label  WPos=$wpos" }
            else        { Write-Host "  [Idle] $label  MPos=$mpos" }
            return $true
        }
        if ($r -match 'Run|Jog') {
            $wpos = [regex]::Match($r, 'WPos:([0-9.\-,]+)').Groups[1].Value
            $mpos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
            if ($wpos) { Write-Host "  [Run]  WPos=$wpos" }
            else        { Write-Host "  [Run]  MPos=$mpos" }
        }
    }
    Write-Host "  WARNING: timed out"; return $false
}

function Send {
    param($port, $cmd, [switch]$wait)
    Write-Host "> $cmd"
    $port.WriteLine($cmd)
    Start-Sleep -Milliseconds 200
    $ack = $port.ReadExisting()
    if ($ack) { Write-Host "< $($ack.Trim())" }
    if ($wait) { WaitForIdle $port $cmd | Out-Null }
}

# --- Open port ---
$port = New-Object System.IO.Ports.SerialPort 'COM13', 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000
$port.Open()
Start-Sleep -Milliseconds 800
$port.WriteLine('')
Start-Sleep -Milliseconds 600
$port.ReadExisting() | Out-Null

$port.Write('?')
Start-Sleep -Milliseconds 400
Write-Host "=== Initial status: $($port.ReadExisting().Trim())"

# Ensure correct modes
Send $port 'G21'    # mm
Send $port 'G90'    # absolute
Send $port 'G54'    # work coordinate system

# --- Move to centre of travel range ---
Write-Host "`n=== Moving to centre of range (work X80, Y-50, Z-22.5) ==="
Send $port 'G0 Z-22.5' -wait         # move Z first
Send $port 'G0 X80 Y-50' -wait       # then XY

# --- Move to circle start point ---
Write-Host "`n=== Moving to circle start (X110, Y-50) ==="
Send $port 'G0 X110 Y-50' -wait

# --- Helical circle ---
Write-Host "`n=== Starting helical circle (F400 mm/min) ==="

Write-Host "--- Q1: right -> bottom,  Z -22.5 -> -32.5 (head drops) ---"
Send $port 'G2 X80 Y-80 I-30 J0 Z-32.5 F400' -wait

Write-Host "--- Q2: bottom -> left,   Z -32.5 -> -22.5 (head rises) ---"
Send $port 'G2 X50 Y-50 I0 J30 Z-22.5 F400' -wait

Write-Host "--- Q3: left -> top,      Z -22.5 -> -12.5 (head rises) ---"
Send $port 'G2 X80 Y-20 I30 J0 Z-12.5 F400' -wait

Write-Host "--- Q4: top -> right,     Z -12.5 -> -22.5 (head drops) ---"
Send $port 'G2 X110 Y-50 I0 J-30 Z-22.5 F400' -wait

# --- Return to home ---
Write-Host "`n=== Returning to home (G28) ==="
Send $port 'G28' -wait

$port.Write('?')
Start-Sleep -Milliseconds 400
Write-Host "`n=== Final status: $($port.ReadExisting().Trim())"

$port.Close()
Write-Host "=== Done! ==="
