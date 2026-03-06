function SendAndWait($port, $cmd, $waitMs = 800) {
    Write-Host "> $cmd"
    $port.WriteLine($cmd)
    Start-Sleep -Milliseconds $waitMs
    $r = $port.ReadExisting()
    Write-Host "< $r"
    return $r
}

$port = New-Object System.IO.Ports.SerialPort 'COM13', 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000
$port.Open()
Start-Sleep -Milliseconds 800

# Wake
$port.WriteLine('')
Start-Sleep -Milliseconds 600
$port.ReadExisting() | Out-Null

# Check status
$port.Write('?')
Start-Sleep -Milliseconds 400
Write-Host "Status before: $($port.ReadExisting())"

# Set relative positioning mode
SendAndWait $port 'G91' 600

# Move X +1mm at 500mm/min (gentle)
SendAndWait $port 'G0 X1 F500' 1500

# Move X -1mm back
SendAndWait $port 'G0 X-1 F500' 1500

# Restore absolute positioning mode
SendAndWait $port 'G90' 600

# Final status
$port.Write('?')
Start-Sleep -Milliseconds 400
Write-Host "Status after: $($port.ReadExisting())"

$port.Close()
Write-Host "Done."
