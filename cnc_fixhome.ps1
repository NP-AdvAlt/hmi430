# Fix home: Y needs to be at 100 (table toward user), not 0

function WaitForIdle {
    param($port, $label = '', $timeoutSec = 30)
    Start-Sleep -Milliseconds 400
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?')
        Start-Sleep -Milliseconds 250
        $r = $port.ReadExisting()
        if ($r -match 'Alarm') { Write-Host "  [ALARM] $r"; return $false }
        if ($r -match 'Idle') {
            $pos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
            Write-Host "  [Idle] $label  MPos=$pos"
            return $true
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

$port = New-Object System.IO.Ports.SerialPort 'COM13', 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000
$port.Open()
Start-Sleep -Milliseconds 800
$port.WriteLine('')
Start-Sleep -Milliseconds 600
$port.ReadExisting() | Out-Null

$port.Write('?')
Start-Sleep -Milliseconds 400
Write-Host "=== Current state: $($port.ReadExisting().Trim())"

# Move Y to full travel (table all the way toward user)
Write-Host "`n=== Moving Y to 100mm (table toward user) ==="
Send $port 'G90'
Send $port 'G0 Y100' -wait

# Re-zero G54 work coordinates at this new home position
# Machine is now at X=0, Y=100, Z=45 -> define as work (0,0,0)
Write-Host "`n=== Re-zeroing G54 at new home position ==="
Send $port 'G10 L20 P1 X0 Y0 Z0'
Send $port 'G54'

# Update G28 stored home
Write-Host "`n=== Updating G28 stored home ==="
Send $port 'G28.1'

# Verify
$port.Write('?')
Start-Sleep -Milliseconds 400
Write-Host "`n=== Status (WPos should read 0,0,0): $($port.ReadExisting().Trim())"

$port.WriteLine('$#')
Start-Sleep -Milliseconds 600
Write-Host $port.ReadExisting()

$port.Close()

Write-Host @"
=== HOME UPDATED ===
  Machine home: X=0, Y=100, Z=45  (gantry left, table toward user, head retracted)
  Work origin:  (0, 0, 0)
  G54 offset:   X:0  Y:100  Z:45

  From home, axis directions:
    X+ --> gantry right (0 to 160mm)
    Y- --> table away from user (0 to -100mm work coords)
    Z- --> head down toward work surface (0 to -45mm work coords)

  To return home at any time: G28
"@
