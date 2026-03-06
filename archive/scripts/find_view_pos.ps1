# Move bed to different Y positions and capture frames to find best camera view of screen

function WaitForIdle {
    param($port, $timeoutSec = 20)
    Start-Sleep -Milliseconds 400
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?'); Start-Sleep -Milliseconds 250
        $r = $port.ReadExisting()
        if ($r -match 'Idle') { return $true }
    }
    return $false
}

function MoveY {
    param($port, $y)
    Write-Host "Moving to Y=$y"
    $port.WriteLine("G0 Y$y")
    Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
    WaitForIdle $port | Out-Null
}

function GrabFrame {
    param([string]$path, [string]$prefer = "Global Shutter")
    $null = [System.Reflection.Assembly]::Load("System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    $null = [Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType=WindowsRuntime]
    $null = [Windows.Media.Capture.MediaCaptureInitializationSettings, Windows.Media.Capture, ContentType=WindowsRuntime]
    $null = [Windows.Media.Capture.StreamingCaptureMode, Windows.Media.Capture, ContentType=WindowsRuntime]
    $null = [Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media.MediaProperties, ContentType=WindowsRuntime]
    $null = [Windows.Storage.StorageFolder, Windows.Storage, ContentType=WindowsRuntime]
    $null = [Windows.Storage.CreationCollisionOption, Windows.Storage, ContentType=WindowsRuntime]

    function Await($op, [Type]$T) {
        if ($T) { $m = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1; $task = $m.MakeGenericMethod($T).Invoke($null,@($op)) }
        else     { $m = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1; $task = $m.Invoke($null,@($op)) }
        $task.GetAwaiter().GetResult()
    }

    $devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync([Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
    $cam  = ($devs | Where-Object { $_.Name -match $prefer } | Select-Object -First 1)
    if (-not $cam) { $cam = $devs | Select-Object -First 1 }

    $cfg = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
    $cfg.VideoDeviceId = $cam.Id
    $cfg.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
    $mc = [Windows.Media.Capture.MediaCapture]::new()
    Await ($mc.InitializeAsync($cfg)) $null

    $sf = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync([System.IO.Path]::GetDirectoryName($path))) ([Windows.Storage.StorageFolder])
    $f  = Await ($sf.CreateFileAsync([System.IO.Path]::GetFileName($path), [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    Await ($mc.CapturePhotoToStorageFileAsync([Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f)) $null
    $mc.Dispose()
}

# Open CNC
$port = New-Object System.IO.Ports.SerialPort 'COM13', 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.WriteLine(''); Start-Sleep -Milliseconds 600; $port.ReadExisting() | Out-Null
$port.WriteLine('G21'); Start-Sleep -Milliseconds 300; $port.ReadExisting() | Out-Null
$port.WriteLine('G90'); Start-Sleep -Milliseconds 300; $port.ReadExisting() | Out-Null
$port.WriteLine('G54'); Start-Sleep -Milliseconds 300; $port.ReadExisting() | Out-Null

# Sample Y positions: 0 (home/toward user) to -80 (well away from user)
foreach ($y in @(0, -20, -40, -60, -80)) {
    MoveY $port $y
    Start-Sleep -Milliseconds 500   # let vibration settle
    $outPath = "C:\Claude\hmi430\view_y${y}.jpg".Replace('-','neg')
    GrabFrame $outPath
    Write-Host "  Saved: $outPath"
}

# Return home
$port.WriteLine('G0 X0 Y0 Z0'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
WaitForIdle $port | Out-Null
$port.Close()
Write-Host "Done - review images to find best view position"
