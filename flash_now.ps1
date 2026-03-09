# Flash current _build.b1n by power cycling device and catching bootloader window
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
$port.ReadTimeout = 2000
$port.Open()
Start-Sleep -Milliseconds 500

try {
    Write-Host "Power cycling device..."
    $port.WriteLine("M5")
    Start-Sleep -Seconds 3
    $port.WriteLine("M3 S1000")
    Start-Sleep -Milliseconds 500  # small delay then immediately flash

    Write-Host "Attempting flash (catching bootloader window)..."
    $mtpExe = "C:\Claude\hmi430\MtpCopy.exe"
    $binPath = "C:\Claude\hmi430\_build.b1n"

    # Try flash multiple times during the boot window
    $flashed = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        Write-Host "  Attempt $attempt..."
        $r = & $mtpExe $binPath 2>&1 | Out-String
        if ($r -match 'SUCCESS') {
            Write-Host "  Flash succeeded on attempt $attempt"
            $flashed = $true
            break
        } else {
            Write-Host "  Failed: $($r.Trim() -split "`n" | Where-Object { $_ -match 'ERROR|not found' } | Select-Object -First 1)"
            Start-Sleep -Milliseconds 1000
        }
    }

    if (-not $flashed) {
        Write-Host ""
        Write-Host "Could not flash. Device MTP folders:"
        $shell = New-Object -ComObject Shell.Application
        $device = $shell.NameSpace(17).Items() | Where-Object { $_.Name -match 'AegisTec|SPLat|HMI|AV430' } | Select-Object -First 1
        if ($device) {
            $device.GetFolder.Items() | ForEach-Object { Write-Host "  $($_.Name)" }
        } else {
            Write-Host "  Device not found in Shell.Application"
        }
    }
} finally {
    if ($port -and $port.IsOpen) { $port.Close() }
}
