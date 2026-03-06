# Try common baud rates on COM11

$bauds = @(9600, 19200, 38400, 57600, 115200, 4800, 2400)

foreach ($baud in $bauds) {
    Write-Host "Trying $baud baud..." -NoNewline
    try {
        $port = New-Object System.IO.Ports.SerialPort 'COM11', $baud, 'None', 8, 'One'
        $port.ReadTimeout = 1000
        $port.Open()
        Start-Sleep -Milliseconds 1500
        $data = $port.ReadExisting()
        $port.Close()
        if ($data) {
            Write-Host " GOT DATA:"
            Write-Host ($data | Format-Hex | Out-String)
            break
        } else {
            Write-Host " nothing"
        }
    } catch {
        Write-Host " error: $_"
    }
}
Write-Host "Scan complete."
