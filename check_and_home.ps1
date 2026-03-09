# Check GRBL settings and attempt homing
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
Start-Sleep -Milliseconds 1000

function Send-Recv([string]$cmd, [int]$waitMs = 500) {
    $port.WriteLine($cmd)
    Start-Sleep -Milliseconds $waitMs
    $lines = @()
    try { while ($port.BytesToRead -gt 0) { $lines += $port.ReadLine() } } catch {}
    return $lines
}

function Get-Status {
    $port.Write("?")
    Start-Sleep -Milliseconds 150
    try { return $port.ReadLine() } catch { return "" }
}

function Wait-Idle([int]$timeoutSec = 90) {
    $deadline = [DateTime]::Now.AddSeconds($timeoutSec)
    while ([DateTime]::Now -lt $deadline) {
        $s = Get-Status
        if ($s -match 'Idle') { return "Idle" }
        if ($s -match 'Alarm') { return "Alarm:$s" }
        Start-Sleep -Milliseconds 300
    }
    return "Timeout"
}

try {
    Write-Host "Current state: $(Get-Status)"
    Write-Host ""

    # Check key settings
    Write-Host "=== Key GRBL settings ==="
    $settings = Send-Recv '$$' 2000
    foreach ($line in $settings) {
        if ($line -match '^\$2[012345]=' -or $line -match '^\$[0-9]+=') {
            if ($line -match '^\$(22|23|24|25|26|27)=') { Write-Host "  $line" }
        }
    }

    # Check $22 specifically (homing enable)
    $s22 = $settings | Where-Object { $_ -match '^\$22=' }
    Write-Host "  Homing enable ($22): $s22"
    Write-Host ""

    # Clear alarm
    Write-Host "Clearing alarm..."
    Send-Recv '$X' 300 | Out-Null

    # Enable homing if needed
    if ($s22 -match '=0') {
        Write-Host "Homing was disabled! Enabling..."
        Send-Recv '$22=1' 300 | Out-Null
    }

    # Home the machine
    Write-Host "Running homing cycle (\$H)..."
    $r = Send-Recv '$H' 500
    Write-Host "  $($r -join ' | ')"

    $result = Wait-Idle 90
    Write-Host "Homing result: $result"

    if ($result -eq "Idle") {
        Write-Host ""
        Write-Host "Setting work origin at home position..."
        Send-Recv 'G21' 200 | Out-Null
        Send-Recv 'G90' 200 | Out-Null
        Send-Recv 'G54' 200 | Out-Null
        Send-Recv 'G10 L20 P1 X0 Y0 Z0' 300 | Out-Null
        Write-Host "Done. Machine homed and work origin set."
        Write-Host "Final: $(Get-Status)"
    } else {
        Write-Host "Homing failed. Check limit switches and try manually."
        Write-Host "Final: $(Get-Status)"
    }
} finally {
    if ($port -and $port.IsOpen) { $port.Close() }
}
