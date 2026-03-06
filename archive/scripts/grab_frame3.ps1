# Camera capture using proper WinRT assembly loading for Windows PowerShell 5.1

param([string]$Out = "C:\Claude\hmi430\frame.jpg", [string]$Prefer = "Global Shutter")

# Load the WinRT interop assembly
$null = [System.Reflection.Assembly]::Load(
    "System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")

# Load WinRT types
$null = [Windows.Devices.Enumeration.DeviceInformation,   Windows.Devices.Enumeration, ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCapture,              Windows.Media.Capture,        ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCaptureInitializationSettings, Windows.Media.Capture, ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.StreamingCaptureMode,      Windows.Media.Capture,        ContentType=WindowsRuntime]
$null = [Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media.MediaProperties, ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFolder,                   Windows.Storage,              ContentType=WindowsRuntime]
$null = [Windows.Storage.CreationCollisionOption,         Windows.Storage,              ContentType=WindowsRuntime]

# Generic async helper
function Await {
    param($op, [Type]$ResultType)
    if ($ResultType) {
        $m = [System.WindowsRuntimeSystemExtensions].GetMethods() |
             Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } |
             Select-Object -First 1
        $task = $m.MakeGenericMethod($ResultType).Invoke($null, @($op))
    } else {
        $m = [System.WindowsRuntimeSystemExtensions].GetMethods() |
             Where-Object { $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } |
             Select-Object -First 1
        $task = $m.Invoke($null, @($op))
    }
    $task.GetAwaiter().GetResult()
}

try {
    # Find cameras
    $devOp = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
        [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)
    $devs = Await $devOp ([Windows.Devices.Enumeration.DeviceInformationCollection])

    Write-Host "Cameras found:"
    $devs | ForEach-Object { Write-Host "  $($_.Name)" }

    $cam = $devs | Where-Object { $_.Name -match $Prefer } | Select-Object -First 1
    if (-not $cam) { $cam = $devs | Select-Object -First 1 }
    if (-not $cam) { throw "No cameras available" }
    Write-Host "Using: $($cam.Name)"

    # Init capture
    $cfg = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
    $cfg.VideoDeviceId = $cam.Id
    $cfg.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video

    $mc = [Windows.Media.Capture.MediaCapture]::new()
    Await ($mc.InitializeAsync($cfg)) $null

    # Output file
    $dir  = [System.IO.Path]::GetDirectoryName($Out)
    $name = [System.IO.Path]::GetFileName($Out)
    $sfOp = [Windows.Storage.StorageFolder]::GetFolderFromPathAsync($dir)
    $sf   = Await $sfOp ([Windows.Storage.StorageFolder])
    $fOp  = $sf.CreateFileAsync($name, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)
    $f    = Await $fOp ([Windows.Storage.StorageFile])

    $enc  = [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg()
    Await ($mc.CapturePhotoToStorageFileAsync($enc, $f)) $null
    $mc.Dispose()

    $size = (Get-Item $Out).Length
    Write-Host "Saved to $Out  ($size bytes)"

} catch {
    Write-Host "ERROR: $_"
    Write-Host $_.ScriptStackTrace
}
