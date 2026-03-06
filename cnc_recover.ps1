# Recovery homing: run axes against physical stops to find true home
# Z retracted to upper stop first, then X to left stop, then Y to user-facing stop

function FindCH340($retries = 10, $delayMs = 1500) {
    for ($i = 0; $i -lt $retries; $i++) {
        $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'CH340' }
        if ($dev) {
            $com = $dev.FriendlyName -replace '.*\((.+)\).*','$1'
            Write-Host "CH340 on $com"; return $com
        }
        Write-Host "  waiting for CH340... ($($i+1)/$retries)"
        Start-Sleep -Milliseconds $delayMs
    }
    throw "CH340 not found"
}

function WaitForIdle($port, $timeoutSec = 60) {
    Start-Sleep -Milliseconds 500
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?'); Start-Sleep -Milliseconds 300
        $r = $port.ReadExisting()
        if ($r -match 'Alarm') {
            Write-Host "  [ALARM] Clearing..."
            $port.WriteLine('$X'); Start-Sleep -Milliseconds 400; $port.ReadExisting() | Out-Null
        }
        if ($r -match 'Idle') { return $true }
        if ($r -match 'Run')  { Write-Host "  running..." }
    }
    Write-Host "  [timeout]"; return $false
}

$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800
$port.WriteLine(''); Start-Sleep -Milliseconds 600; $port.ReadExisting() | Out-Null

$port.Write('?'); Start-Sleep -Milliseconds 400
$status = $port.ReadExisting().Trim()
Write-Host "Status: $status"
if ($status -match 'Alarm') {
    $port.WriteLine('$X'); Start-Sleep -Milliseconds 400; $port.ReadExisting() | Out-Null
}

# Disable soft limits so we can run past virtual boundaries to physical stops
$port.WriteLine('$20=0'); Start-Sleep -Milliseconds 400; $port.ReadExisting() | Out-Null
Write-Host "Soft limits disabled."

# Step 1: Run Z to upper physical stop (fully retract head)
Write-Host "`n=== Step 1: Retracting Z to upper stop ==="
Write-Host "(running slowly against physical stop - stepper will stall)"
$port.WriteLine('G91 G1 Z60 F100'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
WaitForIdle $port | Out-Null

# Step 2: Run X to left physical stop (gantry left)
Write-Host "`n=== Step 2: Moving X to left physical stop ==="
$port.WriteLine('G1 X-200 F300'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
WaitForIdle $port | Out-Null

# Step 3: Run Y to home stop (table toward user)
Write-Host "`n=== Step 3: Moving Y to home stop (table toward user) ==="
$port.WriteLine('G1 Y120 F300'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
WaitForIdle $port | Out-Null

# Step 4: We are now at physical home. Zero G54 here and restore soft limits.
Write-Host "`n=== Step 4: Zeroing home position ==="
$port.WriteLine('G90'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
$port.WriteLine('G54'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
$port.WriteLine('G10 L20 P1 X0 Y0 Z0'); Start-Sleep -Milliseconds 400; $port.ReadExisting() | Out-Null
$port.WriteLine('G28.1'); Start-Sleep -Milliseconds 400; $port.ReadExisting() | Out-Null
$port.WriteLine('$20=1'); Start-Sleep -Milliseconds 400; $port.ReadExisting() | Out-Null

$port.Write('?'); Start-Sleep -Milliseconds 400
Write-Host "Final: $($port.ReadExisting().Trim())"
Write-Host "`nDone. Machine is at true home (0,0,0) - gantry left, table toward user, head up."
$port.Close()
