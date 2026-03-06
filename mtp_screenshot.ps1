# mtp_screenshot.ps1 - Copy sshot*.png from HMI430 Internal Storage via MTP
# Copying the file triggers the device firmware to capture the current screen.
# Returns the local file path of the saved screenshot.
#
# Usage:
#   . .\mtp_screenshot.ps1
#   $path = Get-MtpScreenshot -OutDir "C:\Claude\hmi430\screen_captures\latest"

function Get-MtpScreenshot {
    param(
        [Parameter(Mandatory)][string]$OutDir
    )

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

    # CopyHere triggers the device to write the current screen to the file during transfer
    $target = $shell.NameSpace((Resolve-Path $OutDir).Path)
    $target.CopyHere($sshot)

    # Wait for file to appear (copy is asynchronous)
    $outPath = Join-Path $OutDir $sshot.Name
    $deadline = [DateTime]::Now.AddSeconds(20)
    while (-not (Test-Path $outPath) -and [DateTime]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 300
    }
    if (-not (Test-Path $outPath)) { throw "Screenshot copy timed out after 20s." }

    return $outPath
}
