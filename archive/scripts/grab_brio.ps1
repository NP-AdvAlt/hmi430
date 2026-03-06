# Quick Brio camera capture
$null = [System.Reflection.Assembly]::Load(
    "System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
$null = [Windows.Devices.Enumeration.DeviceInformation,   Windows.Devices.Enumeration,    ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCapture,               Windows.Media.Capture,          ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCaptureInitializationSettings, Windows.Media.Capture,  ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.StreamingCaptureMode,       Windows.Media.Capture,          ContentType=WindowsRuntime]
$null = [Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media.MediaProperties, ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFolder,                    Windows.Storage,                ContentType=WindowsRuntime]
$null = [Windows.Storage.CreationCollisionOption,          Windows.Storage,                ContentType=WindowsRuntime]

function Await($op, [Type]$T) {
    if ($T) {
        $m = [System.WindowsRuntimeSystemExtensions].GetMethods() |
             Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } |
             Select-Object -First 1
        $task = $m.MakeGenericMethod($T).Invoke($null, @($op))
    } else {
        $m = [System.WindowsRuntimeSystemExtensions].GetMethods() |
             Where-Object { $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } |
             Select-Object -First 1
        $task = $m.Invoke($null, @($op))
    }
    $task.GetAwaiter().GetResult()
}

$devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) `
    ([Windows.Devices.Enumeration.DeviceInformationCollection])
$cam = $devs | Where-Object { $_.Name -match 'Brio' } | Select-Object -First 1
Write-Host "Camera: $($cam.Name)"
$cfg = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfg.VideoDeviceId = $cam.Id
$cfg.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mcFront = [Windows.Media.Capture.MediaCapture]::new()
Await ($mcFront.InitializeAsync($cfg)) $null
Start-Sleep -Milliseconds 2000

$path = "C:\Claude\hmi430\brio_now.jpg"
$sf = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync("C:\Claude")) ([Windows.Storage.StorageFolder])
$f  = Await ($sf.CreateFileAsync("brio_now.jpg", [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
Await ($mcFront.CapturePhotoToStorageFileAsync(
    [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f)) $null
$mcFront.Dispose()
Write-Host "Saved: $path ($([int](Get-Item $path).Length/1024) KB)"
