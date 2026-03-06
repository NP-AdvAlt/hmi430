# Fix: split across $N0 and $N1 to avoid modal group conflict

$port = New-Object System.IO.Ports.SerialPort 'COM13', 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000
$port.Open()
Start-Sleep -Milliseconds 800
$port.WriteLine('')
Start-Sleep -Milliseconds 600
$port.ReadExisting() | Out-Null

# N0: set modes and re-zero G54 at current position (physical home)
Write-Host "> setting N0"
$port.WriteLine('$N0=G21G90G54G10L20P1X0Y0Z0')
Start-Sleep -Milliseconds 500
Write-Host $port.ReadExisting()

# N1: store G28 at current position (same physical home)
Write-Host "> setting N1"
$port.WriteLine('$N1=G28.1')
Start-Sleep -Milliseconds 500
Write-Host $port.ReadExisting()

Write-Host "=== Verifying ==="
$port.WriteLine('$N')
Start-Sleep -Milliseconds 500
Write-Host $port.ReadExisting()

$port.Close()
