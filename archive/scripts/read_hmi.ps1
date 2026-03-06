# Read data from HMI430 on COM11
# Tries 115200 first, prints whatever comes in for 10 seconds

$baud = 115200
Write-Host "Opening COM11 at $baud baud..."

$port = New-Object System.IO.Ports.SerialPort 'COM11', $baud, 'None', 8, 'One'
$port.ReadTimeout = 2000
$port.Open()

Write-Host "Listening for 10 seconds. Press Ctrl+C to stop early."
Write-Host "----------------------------------------"

$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline) {
    try {
        $data = $port.ReadExisting()
        if ($data) {
            Write-Host $data -NoNewline
        }
    } catch { }
    Start-Sleep -Milliseconds 100
}

Write-Host ""
Write-Host "----------------------------------------"
$port.Close()
Write-Host "Done."
