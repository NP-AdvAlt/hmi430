# flash_on_reconnect.ps1
# Watches for the AV430 WPD device to appear and immediately flashes _build.b1n.
# Run this BEFORE unplugging USB, then unplug and replug the USB cable.

$mtpExe  = "C:\Claude\hmi430\MtpCopy.exe"
$binPath = "C:\Claude\hmi430\_build.b1n"

Write-Host "Watching for AV430 device..."
Write-Host ">>> UNPLUG the USB cable now, then plug it back in. <<<"
Write-Host ""

# Wait for device to disappear first (so we know it's unplugged)
$deadline = [DateTime]::Now.AddSeconds(60)
while ([DateTime]::Now -lt $deadline) {
    $d = Get-PnpDevice -Class WPD -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' }
    if (-not $d) { Write-Host "Device disconnected. Waiting for reconnect..."; break }
    Start-Sleep -Milliseconds 500
}

# Now wait for it to reappear and try to flash immediately
$deadline = [DateTime]::Now.AddSeconds(60)
$flashed = $false
while ([DateTime]::Now -lt $deadline -and -not $flashed) {
    $d = Get-PnpDevice -Class WPD -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' }
    if ($d) {
        Write-Host "Device appeared: $($d.FriendlyName)"
        # Try flash immediately and a few times in quick succession
        for ($i = 1; $i -le 8; $i++) {
            $r = & $mtpExe $binPath 2>&1 | Out-String
            if ($r -match 'SUCCESS') {
                Write-Host "Flashed on attempt $i!"
                $flashed = $true
                break
            }
            Write-Host "  Attempt $i - waiting... ($($r.Trim() -split "`n" | Select-Object -Last 1))"
            Start-Sleep -Milliseconds 800
        }
        if (-not $flashed) {
            Write-Host "Could not flash in 8 attempts after reconnect."
        }
    }
    Start-Sleep -Milliseconds 200
}

if ($flashed) {
    Write-Host ""
    Write-Host "Flash complete. Device is rebooting with new firmware."
    Write-Host "Wait ~15s then the checkerboard UI should appear."
} else {
    Write-Host "Timed out waiting for device or flash window."
}
