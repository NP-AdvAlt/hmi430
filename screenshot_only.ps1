# Power on HMI, wait for boot, take screenshot, power off
. "$PSScriptRoot\mtp_screenshot.ps1"

$comPort = $null
$cnc = Get-PnpDevice | Where-Object { $_.FriendlyName -match 'CH340' -and $_.Status -eq 'OK' } | Select-Object -First 1
if ($cnc -and ($cnc.FriendlyName -match 'COM(\d+)')) { $comPort = "COM$($Matches[1])" }
if (-not $comPort) {
    foreach ($p in @('COM13','COM12','COM15','COM11','COM14')) {
        if ([System.IO.Ports.SerialPort]::GetPortNames() -contains $p) { $comPort = $p; break }
    }
}

$port = [System.IO.Ports.SerialPort]::new($comPort, 115200)
$port.Open(); Start-Sleep -Milliseconds 500
$port.WriteLine("M3 S1000"); Start-Sleep -Milliseconds 500
Write-Host "Waiting 12s for boot..."
Start-Sleep -Seconds 12

$outDir = "C:\Claude\hmi430\screen_captures\latest"
$path = Get-MtpScreenshot -OutDir $outDir
Write-Host "Screenshot: $path"

$port.WriteLine("M5")
$port.Close()
