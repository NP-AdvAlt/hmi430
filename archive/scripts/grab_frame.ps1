# Capture a single frame from the Global Shutter Camera using WinRT MediaCapture
# Falls back to Brio 101 if GSC not found

param(
    [string]$OutputPath = "C:\Claude\hmi430\frame.jpg",
    [string]$PreferCamera = "Global Shutter"
)

# Load WinRT support
[Windows.Media.Capture.MediaCapture,Windows.Media.Capture,ContentType=WindowsRuntime] | Out-Null
[Windows.Media.Capture.MediaCaptureInitializationSettings,Windows.Media.Capture,ContentType=WindowsRuntime] | Out-Null
[Windows.Devices.Enumeration.DeviceInformation,Windows.Devices.Enumeration,ContentType=WindowsRuntime] | Out-Null
[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime] | Out-Null
[Windows.Media.MediaProperties.ImageEncodingProperties,Windows.Media.MediaProperties,ContentType=WindowsRuntime] | Out-Null

# Helper to await WinRT async operations
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethod("AsTask", [Type[]]@([System.Runtime.InteropServices.WindowsRuntime.IAsyncAction]))
$asTaskResult = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.IsGenericMethod } |
    Select-Object -First 1

function Await($op, $resultType) {
    if ($resultType) {
        $method = $asTaskResult.MakeGenericMethod($resultType)
        $task = $method.Invoke($null, @($op))
    } else {
        $task = $asTask.Invoke($null, @($op))
    }
    $task.GetAwaiter().GetResult()
}

try {
    # Enumerate video capture devices
    $selector = [Windows.Devices.Enumeration.DeviceClass]::VideoCapture
    $devicesOp = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector)
    $devices = Await $devicesOp ([Windows.Devices.Enumeration.DeviceInformationCollection])

    Write-Host "Available cameras:"
    $devices | ForEach-Object { Write-Host "  - $($_.Name)  id=$($_.Id)" }

    # Pick preferred camera
    $cam = $devices | Where-Object { $_.Name -match $PreferCamera } | Select-Object -First 1
    if (-not $cam) {
        Write-Host "Preferred camera '$PreferCamera' not found, using first available"
        $cam = $devices | Select-Object -First 1
    }
    if (-not $cam) { throw "No cameras found" }
    Write-Host "Using: $($cam.Name)"

    # Initialise capture
    $settings = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
    $settings.VideoDeviceId = $cam.Id
    $settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video

    $capture = [Windows.Media.Capture.MediaCapture]::new()
    Await ($capture.InitializeAsync($settings)) $null

    # Capture photo to file
    $imgProps = [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg()

    # Create output file
    $folder = [System.IO.Path]::GetDirectoryName($OutputPath)
    $filename = [System.IO.Path]::GetFileName($OutputPath)
    $sfOp = [Windows.Storage.StorageFolder]::GetFolderFromPathAsync($folder)
    $sf = Await $sfOp ([Windows.Storage.StorageFolder])
    $fileOp = $sf.CreateFileAsync($filename, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)
    $file = Await $fileOp ([Windows.Storage.StorageFile])

    Await ($capture.CapturePhotoToStorageFileAsync($imgProps, $file)) $null

    $capture.Dispose()
    Write-Host "Frame saved to: $OutputPath"
    Write-Host "File size: $((Get-Item $OutputPath).Length) bytes"

} catch {
    Write-Host "Error: $_"
}
