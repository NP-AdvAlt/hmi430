# CNC Circle with Z oscillation
# Machine travel: X=0-160, Y=0-100, Z=0-45
# Center: X=80, Y=50, Z=22.5
# Circle: 30mm radius centered at (80,50)
# Z: oscillates 22.5 +/-10mm (12.5 to 32.5) over one revolution

function WaitForIdle {
    param($port, $label = '', $timeoutSec = 45)
    Start-Sleep -Milliseconds 400   # let motion begin before polling
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?')
        Start-Sleep -Milliseconds 250
        $r = $port.ReadExisting()
        if ($r -match 'Idle') {
            $pos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
            Write-Host "  [Idle] $label  pos=$pos"
            return $true
        }
        if ($r -match 'Alarm') {
            Write-Host "  [ALARM] $r"
            return $false
        }
        if ($r -match 'Run|Jog') {
            $pos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
            Write-Host "  [Run]  pos=$pos"
        }
    }
    Write-Host "  WARNING: timed out waiting for Idle"
    return $false
}

function Send {
    param($port, $cmd, [switch]$wait)
    Write-Host "> $cmd"
    $port.WriteLine($cmd)
    Start-Sleep -Milliseconds 150
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

# Initial status
$port.Write('?')
Start-Sleep -Milliseconds 400
Write-Host "=== Initial status: $($port.ReadExisting().Trim())"

# --- Setup ---
Send $port 'G21'          # millimetres
Send $port 'G90'          # absolute positioning

# --- Move to centre of travel range ---
Write-Host "`n=== Moving to centre of range (X80, Y50, Z22.5) ==="
Send $port 'G0 X80 Y50 Z22.5' -wait

# --- Move to circle start (rightmost point) ---
Write-Host "`n=== Moving to circle start point (X110, Y50) ==="
Send $port 'G0 X110 Y50' -wait

# --- Draw circle with helical Z ---
# The circle is split into 4 quarter-arcs (G2 = CW when viewed from above).
# I,J are offsets from current position to arc centre (X80,Y50).
#
# Q1: (110,50) -> (80,20)   I=-30 J=0   Z drops  22.5 -> 12.5  (0deg  -> 270deg)
# Q2: (80, 20) -> (50,50)   I=0   J=30  Z rises  12.5 -> 22.5  (270deg-> 180deg)
# Q3: (50, 50) -> (80,80)   I=30  J=0   Z rises  22.5 -> 32.5  (180deg-> 90deg)
# Q4: (80, 80) -> (110,50)  I=0   J=-30 Z drops  32.5 -> 22.5  (90deg -> 0deg)

Write-Host "`n=== Starting helical circle (F400 mm/min) ==="

Write-Host "--- Q1: right -> bottom, Z 22.5->12.5 ---"
Send $port 'G2 X80 Y20 I-30 J0 Z12.5 F400' -wait

Write-Host "--- Q2: bottom -> left,  Z 12.5->22.5 ---"
Send $port 'G2 X50 Y50 I0 J30 Z22.5 F400' -wait

Write-Host "--- Q3: left -> top,     Z 22.5->32.5 ---"
Send $port 'G2 X80 Y80 I30 J0 Z32.5 F400' -wait

Write-Host "--- Q4: top -> right,    Z 32.5->22.5 ---"
Send $port 'G2 X110 Y50 I0 J-30 Z22.5 F400' -wait

# --- Return to centre ---
Write-Host "`n=== Returning to centre ==="
Send $port 'G0 X80 Y50 Z22.5' -wait

# Final status
$port.Write('?')
Start-Sleep -Milliseconds 400
Write-Host "`n=== Final status: $($port.ReadExisting().Trim())"

$port.Close()
Write-Host "=== Done! ==="
