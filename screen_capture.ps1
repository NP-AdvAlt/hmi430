# screen_capture.ps1 - Move CNC to view position, capture N frames
# Saves to CaptureDir/capture_1.jpg .. capture_N.jpg, rotated 180deg
param(
    [string]$CaptureDir = "C:\Claude\hmi430\screen_captures\latest",
    [int]$NumCaptures = 8,
    [int]$IntervalSec = 1
)

Add-Type -AssemblyName System.Drawing
$null = [System.Reflection.Assembly]::Load("System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
$null = [Windows.Devices.Enumeration.DeviceInformation,  Windows.Devices.Enumeration,   ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCapture,              Windows.Media.Capture,         ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCaptureInitializationSettings, Windows.Media.Capture, ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.StreamingCaptureMode,      Windows.Media.Capture,         ContentType=WindowsRuntime]
$null = [Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media.MediaProperties, ContentType=WindowsRuntime]
$null = [Windows.Media.MediaProperties.VideoEncodingProperties, Windows.Media.MediaProperties, ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFolder,                   Windows.Storage,               ContentType=WindowsRuntime]
$null = [Windows.Storage.CreationCollisionOption,         Windows.Storage,               ContentType=WindowsRuntime]

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

function FindCH340 {
    for ($i = 0; $i -lt 10; $i++) {
        $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'CH340' }
        if ($dev) { return $dev.FriendlyName -replace '.*\((.+)\).*','$1' }
        Start-Sleep -Milliseconds 1500
    }
    throw "CH340 not found"
}

function WaitForIdle($port, $timeoutSec = 30) {
    Start-Sleep -Milliseconds 400
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?'); Start-Sleep -Milliseconds 250
        $r = $port.ReadExisting()
        if ($r -match 'Idle') { return $true }
    }
    return $false
}

function Send($port, $cmd, [switch]$wait) {
    $port.WriteLine($cmd); Start-Sleep -Milliseconds 200
    $port.ReadExisting() | Out-Null
    if ($wait) { WaitForIdle $port | Out-Null }
}

New-Item -ItemType Directory -Force -Path $CaptureDir | Out-Null

# Open camera FIRST (before CNC serial to avoid USB re-enumeration killing COM port)
Write-Host "Opening camera..."
$devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) `
    ([Windows.Devices.Enumeration.DeviceInformationCollection])
$cam = $devs | Where-Object { $_.Name -match 'Global Shutter' } | Select-Object -First 1
if (-not $cam) { Write-Error "Global Shutter Camera not found"; exit 1 }
$cfg = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfg.VideoDeviceId = $cam.Id
$cfg.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mc = [Windows.Media.Capture.MediaCapture]::new()
Await ($mc.InitializeAsync($cfg)) $null
Start-Sleep -Milliseconds 2000   # let camera settle
# Switch to MJPG for sharp captures (NV12 default causes heavy compression artifacts)
$allModes = $mc.VideoDeviceController.GetAvailableMediaStreamProperties(
    [Windows.Media.Capture.MediaStreamType]::VideoRecord)
$mjpgMode = $allModes |
    ForEach-Object { $_ -as [Windows.Media.MediaProperties.VideoEncodingProperties] } |
    Where-Object { $_ -ne $null -and $_.Subtype -eq 'MJPG' } |
    Sort-Object { $_.Width * $_.Height } -Descending |
    Select-Object -First 1
if ($mjpgMode) {
    Await ($mc.VideoDeviceController.SetMediaStreamPropertiesAsync(
        [Windows.Media.Capture.MediaStreamType]::VideoRecord, $mjpgMode)) $null
    Write-Host "Camera: $($mjpgMode.Width)x$($mjpgMode.Height) MJPG"
}

# Connect CNC: power on HMI and move to view position
Write-Host "Positioning CNC for screen view..."
$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.ReadExisting() | Out-Null
$port.WriteLine(''); Start-Sleep -Milliseconds 400; $port.ReadExisting() | Out-Null
Send $port 'G21'; Send $port 'G90'; Send $port 'G54'
Send $port 'M3 S1000'              # HMI screen power on
Send $port 'G0 Z0' -wait
Send $port 'G0 X0 Y-60' -wait
$port.Close()
Start-Sleep -Milliseconds 1500    # let screen settle after move

# Capture N frames
Write-Host "Capturing $NumCaptures frames..."
$sf = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($CaptureDir)) ([Windows.Storage.StorageFolder])
for ($i = 1; $i -le $NumCaptures; $i++) {
    $fname = "capture_${i}.jpg"
    $fpath = Join-Path $CaptureDir $fname
    $f = Await ($sf.CreateFileAsync($fname, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    Await ($mc.CapturePhotoToStorageFileAsync(
        [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f)) $null
    $img = [System.Drawing.Image]::FromFile($fpath)
    $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone)
    $img.Save($fpath); $img.Dispose()
    Write-Host "  >> Frame $i/${NumCaptures}: $fname"
    if ($i -lt $NumCaptures) { Start-Sleep -Seconds $IntervalSec }
}

$mc.Dispose()
