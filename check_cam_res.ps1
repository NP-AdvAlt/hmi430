# check_cam_res.ps1 - List all available photo resolutions for the camera
$null = [System.Reflection.Assembly]::Load("System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
$null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCaptureInitializationSettings, Windows.Media.Capture, ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.StreamingCaptureMode, Windows.Media.Capture, ContentType=WindowsRuntime]
$null = [Windows.Media.MediaProperties.VideoEncodingProperties, Windows.Media.MediaProperties, ContentType=WindowsRuntime]

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
$cam = $devs | Where-Object { $_.Name -match 'Global Shutter' } | Select-Object -First 1
if (-not $cam) { Write-Error "Camera not found"; exit 1 }
Write-Host "Camera: $($cam.Name)"

$cfg = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfg.VideoDeviceId = $cam.Id
$cfg.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mc = [Windows.Media.Capture.MediaCapture]::new()
Await ($mc.InitializeAsync($cfg)) $null

# List photo stream resolutions
$photoProps = $mc.VideoDeviceController.GetAvailableMediaStreamProperties(
    [Windows.Media.Capture.MediaStreamType]::Photo)
Write-Host "`nPhoto stream resolutions:"
$photoProps | ForEach-Object {
    $vp = $_ -as [Windows.Media.MediaProperties.VideoEncodingProperties]
    if ($vp) {
        Write-Host "  $($vp.Width) x $($vp.Height)  subtype=$($vp.Subtype)"
    } else {
        Write-Host "  [non-video] $($_.GetType().Name)"
    }
}

# List video stream resolutions
$videoProps = $mc.VideoDeviceController.GetAvailableMediaStreamProperties(
    [Windows.Media.Capture.MediaStreamType]::VideoRecord)
Write-Host "`nVideo record resolutions:"
$videoProps | ForEach-Object {
    $vp = $_ -as [Windows.Media.MediaProperties.VideoEncodingProperties]
    if ($vp) {
        Write-Host "  $($vp.Width) x $($vp.Height) @ $([math]::Round($vp.FrameRate,1))fps  subtype=$($vp.Subtype)"
    }
}

$mc.Dispose()
