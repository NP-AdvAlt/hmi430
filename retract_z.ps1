# Retract Z axis only - move to Z=0 (fully up)
function FindCH340($retries = 10, $delayMs = 1500) {
    for ($i = 0; $i -lt $retries; $i++) {
        $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'CH340' }
        if ($dev) {
            $com = $dev.FriendlyName -replace '.*\((.+)\).*','$1'
            Write-Host "CH340 on $com"; return $com
        }
        Start-Sleep -Milliseconds $delayMs
    }
    throw "CH340 not found"
}

$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.WriteLine(''); Start-Sleep -Milliseconds 600; $port.ReadExisting() | Out-Null

$port.Write('?'); Start-Sleep -Milliseconds 400
Write-Host "Current: $($port.ReadExisting().Trim())"

Write-Host "Retracting Z to 0..."
$port.WriteLine('G90 G0 Z0'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null

$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    $port.Write('?'); Start-Sleep -Milliseconds 300
    $r = $port.ReadExisting()
    if ($r -match 'Idle') {
        $pos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
        Write-Host "[Idle] MPos=$pos"; break
    }
}
$port.Close()
Write-Host "Z retracted."
