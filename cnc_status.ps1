$port = New-Object System.IO.Ports.SerialPort 'COM13', 115200, 'None', 8, 'One'
$port.ReadTimeout = 2000
$port.Open()
Start-Sleep -Milliseconds 800

# Wake GRBL
$port.WriteLine('')
Start-Sleep -Milliseconds 600
$port.ReadExisting() | Out-Null

# Query status
$port.Write('?')
Start-Sleep -Milliseconds 500
$r = $port.ReadExisting()
Write-Host "Status: $r"

$port.Close()
