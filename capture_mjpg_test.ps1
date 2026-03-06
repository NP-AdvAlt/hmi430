# capture_mjpg_test.ps1 - Capture one image in MJPG mode, compare file size to old NV12
$null = [System.Reflection.Assembly]::Load("System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
$null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCaptureInitializationSettings, Windows.Media.Capture, ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.StreamingCaptureMode, Windows.Media.Capture, ContentType=WindowsRuntime]
$null = [Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media.MediaProperties, ContentType=WindowsRuntime]
$null = [Windows.Media.MediaProperties.VideoEncodingProperties, Windows.Media.MediaProperties, ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFolder, Windows.Storage, ContentType=WindowsRuntime]
$null = [Windows.Storage.CreationCollisionOption, Windows.Storage, ContentType=WindowsRuntime]
Add-Type -AssemblyName System.Drawing

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

$outDir = "C:\Claude\hmi430\screen_captures\latest"
$devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) `
    ([Windows.Devices.Enumeration.DeviceInformationCollection])
$cam = $devs | Where-Object { $_.Name -match 'Global Shutter' } | Select-Object -First 1
if (-not $cam) { Write-Error "Camera not found"; exit 1 }

$cfg = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfg.VideoDeviceId = $cam.Id
$cfg.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mc = [Windows.Media.Capture.MediaCapture]::new()
Await ($mc.InitializeAsync($cfg)) $null
Start-Sleep -Milliseconds 2000

# Capture baseline (NV12 default)
$sf = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($outDir)) ([Windows.Storage.StorageFolder])
$f1 = Await ($sf.CreateFileAsync("test_nv12.jpg", [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
Await ($mc.CapturePhotoToStorageFileAsync([Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f1)) $null
$sz1 = (Get-Item "$outDir\test_nv12.jpg").Length
Write-Host "NV12 (default): $([math]::Round($sz1/1024))KB"

# Switch to MJPG
$allModes = $mc.VideoDeviceController.GetAvailableMediaStreamProperties([Windows.Media.Capture.MediaStreamType]::VideoRecord)
$mjpgMode = $allModes |
    ForEach-Object { $_ -as [Windows.Media.MediaProperties.VideoEncodingProperties] } |
    Where-Object { $_ -ne $null -and $_.Subtype -eq 'MJPG' } |
    Sort-Object { $_.Width * $_.Height } -Descending |
    Select-Object -First 1
if ($mjpgMode) {
    Await ($mc.VideoDeviceController.SetMediaStreamPropertiesAsync(
        [Windows.Media.Capture.MediaStreamType]::VideoRecord, $mjpgMode)) $null
    Write-Host "Switched to: $($mjpgMode.Width)x$($mjpgMode.Height) MJPG"
    Start-Sleep -Milliseconds 1000
}

$f2 = Await ($sf.CreateFileAsync("test_mjpg.jpg", [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
Await ($mc.CapturePhotoToStorageFileAsync([Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f2)) $null
$sz2 = (Get-Item "$outDir\test_mjpg.jpg").Length
Write-Host "MJPG: $([math]::Round($sz2/1024))KB"

# Rotate both for viewing
foreach ($fn in @("test_nv12.jpg","test_mjpg.jpg")) {
    $fp = "$outDir\$fn"
    $img = [System.Drawing.Image]::FromFile($fp)
    $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone)
    $img.Save($fp); $img.Dispose()
}

$mc.Dispose()
Write-Host "Saved to $outDir"
