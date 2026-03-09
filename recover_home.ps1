# recover_home.ps1
# After power cycle: clear alarm, retract Z, full home cycle, verify position.

$comPort = $null
$cnc = Get-PnpDevice | Where-Object { $_.FriendlyName -match 'CH340' -and $_.Status -eq 'OK' } | Select-Object -First 1
if ($cnc -and ($cnc.FriendlyName -match 'COM(\d+)')) { $comPort = "COM$($Matches[1])" }
if (-not $comPort) {
    foreach ($p in @('COM13','COM15','COM12','COM11','COM14')) {
        if ([System.IO.Ports.SerialPort]::GetPortNames() -contains $p) { $comPort = $p; break }
    }
}
if (-not $comPort) { throw "CNC COM port not found." }
Write-Host "CNC: $comPort"

$port = [System.IO.Ports.SerialPort]::new($comPort, 115200)
$port.ReadTimeout = 3000
$port.Open()
Start-Sleep -Milliseconds 2000   # let GRBL finish startup messages

function Send-Raw([string]$cmd) {
    $port.WriteLine($cmd)
    Start-Sleep -Milliseconds 300
    $out = ""
    try { while ($port.BytesToRead -gt 0) { $out += $port.ReadLine() + " | " } } catch {}
    if ($out) { Write-Host "  << $($out.Trim())" }
}

function Get-Status {
    $port.Write("?")
    Start-Sleep -Milliseconds 150
    try { return $port.ReadLine() } catch { return "" }
}

function Wait-Idle([int]$timeoutSec = 60) {
    $deadline = [DateTime]::Now.AddSeconds($timeoutSec)
    while ([DateTime]::Now -lt $deadline) {
        $s = Get-Status
        if ($s -match 'Idle') { return "Idle" }
        if ($s -match 'Alarm') { return "Alarm" }
        Start-Sleep -Milliseconds 200
    }
    return "Timeout"
}

try {
    # Read initial state
    $s = Get-Status
    Write-Host "Initial state: $s"

    # Step 1: Clear alarm
    Write-Host ""
    Write-Host "Step 1: Clearing alarm..."
    Send-Raw '$X'
    Start-Sleep -Milliseconds 500
    $s = Get-Status
    Write-Host "After clear: $s"

    # Step 2: Retract Z in relative mode before anything else
    Write-Host ""
    Write-Host "Step 2: Retracting Z (relative +20mm toward home)..."
    Send-Raw "G91"           # relative mode
    Send-Raw "G0 Z20"        # jog Z toward home (positive = retract)
    Start-Sleep -Milliseconds 3000
    $s = Wait-Idle 20
    Write-Host "After Z retract: $s"
    Send-Raw "G90"           # back to absolute mode

    # Step 3: Full homing cycle
    Write-Host ""
    Write-Host "Step 3: Homing cycle..."
    Send-Raw '$H'
    Start-Sleep -Milliseconds 1000
    $s = Wait-Idle 90
    Write-Host "Homing result: $s"

    if ($s -ne "Idle") {
        Write-Host "WARNING: Homing did not complete cleanly. Check machine."
    } else {
        # Step 4: Re-establish work coordinates
        Write-Host ""
        Write-Host "Step 4: Setting work origin at home position..."
        Send-Raw "G21"
        Send-Raw "G90"
        Send-Raw "G54"
        Send-Raw "G10 L20 P1 X0 Y0 Z0"
        Send-Raw "G0 Z0"
        $s = Wait-Idle 15
        Write-Host ""
        Write-Host "Machine homed and ready. Work origin = current position."
        $port.Write("?")
        Start-Sleep -Milliseconds 200
        try { Write-Host "Position: $($port.ReadLine())" } catch {}
    }
} finally {
    if ($port -and $port.IsOpen) { $port.Close() }
}
