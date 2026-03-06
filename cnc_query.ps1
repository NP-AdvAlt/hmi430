# Query GRBL settings and current state

$port = New-Object System.IO.Ports.SerialPort 'COM13', 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000
$port.Open()
Start-Sleep -Milliseconds 800
$port.WriteLine('')
Start-Sleep -Milliseconds 600
$port.ReadExisting() | Out-Null

# Current status
$port.Write('?')
Start-Sleep -Milliseconds 400
Write-Host "=== Status ==="
Write-Host $port.ReadExisting()

# All settings
Write-Host "`n=== Settings ($$) ==="
$port.WriteLine('$$')
Start-Sleep -Milliseconds 800
Write-Host $port.ReadExisting()

# G28 stored home
Write-Host "`n=== G28 stored position ==="
$port.WriteLine('$#')
Start-Sleep -Milliseconds 800
Write-Host $port.ReadExisting()

$port.Close()
