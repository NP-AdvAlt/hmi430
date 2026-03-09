# mtp_screenshot.ps1 - Copy sshot*.png from HMI430 Internal Storage via MTP
# Copying the file triggers the device firmware to capture the current screen.
# Returns the local file path of the saved screenshot.
#
# Usage:
#   . .\mtp_screenshot.ps1
#   $path = Get-MtpScreenshot -OutDir "C:\Claude\hmi430\screen_captures\latest"

function Wait-MtpDevice {
    param([int]$TimeoutSec = 60)
    # Use Get-PnpDevice (non-hanging) to wait for WPD/MTP device before touching Shell.Application
    $deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
    while ([DateTime]::Now -lt $deadline) {
        $d = Get-PnpDevice -Class WPD -ErrorAction SilentlyContinue |
             Where-Object { $_.Status -eq 'OK' } | Select-Object -First 1
        if ($d) {
            Start-Sleep -Milliseconds 2000   # brief settle after PnP reports ready
            return $true
        }
        Start-Sleep -Milliseconds 2000
    }
    return $false
}

function Get-MtpScreenshot {
    param(
        [Parameter(Mandatory)][string]$OutDir
    )

    # Wait for device to be enumerated before Shell.Application can see it
    if (-not (Wait-MtpDevice -TimeoutSec 60)) {
        throw "HMI430 MTP device did not appear in 60s. Check USB connection."
    }

    $shell = New-Object -ComObject Shell.Application

    # Find HMI430 MTP device under "This PC" (namespace 17)
    $device = $shell.NameSpace(17).Items() |
              Where-Object { $_.Name -match 'AegisTec|SPLat|HMI|AV430' } |
              Select-Object -First 1
    if (-not $device) { throw "HMI430 MTP device not found. Check USB connection." }

    # Navigate to Internal Storage using GetFolder (required for MTP virtual paths)
    $devFolder = $device.GetFolder
    if (-not $devFolder) { throw "Cannot open device folder." }

    $storage = $devFolder.Items() |
               Where-Object { $_.Name -match 'Internal Storage' } |
               Select-Object -First 1
    if (-not $storage) { throw "Internal Storage not found on device." }

    $storageFolder = $storage.GetFolder
    if (-not $storageFolder) { throw "Cannot open Internal Storage folder." }

    # Find the screenshot file (sshot000.png, sshot001.png, etc.)
    $sshot = $storageFolder.Items() |
             Where-Object { $_.Name -match '^sshot\d+\.png$' } |
             Select-Object -First 1
    if (-not $sshot) { throw "No sshot*.png found in Internal Storage. Device may not be ready." }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    # Remove stale copy if present (so we wait for a fresh one)
    $outPath = Join-Path $OutDir $sshot.Name
    if (Test-Path $outPath) { Remove-Item $outPath -Force }

    # CopyHere triggers the device to write the current screen to the file during transfer
    # Flags: 0x4 (no progress dialog) | 0x10 (yes to all confirmations)
    $target = $shell.NameSpace((Resolve-Path $OutDir).Path)
    $target.CopyHere($sshot, 0x14)

    # Wait for file to appear (copy is asynchronous)
    $deadline = [DateTime]::Now.AddSeconds(20)
    while (-not (Test-Path $outPath) -and [DateTime]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 300
    }
    if (-not (Test-Path $outPath)) { throw "Screenshot copy timed out after 20s." }

    return $outPath
}
