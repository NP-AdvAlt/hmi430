# hmi_press_test.ps1
# Press CFG and SET buttons on HMI430, capture before/after images

Add-Type -AssemblyName System.Drawing
$null = [System.Reflection.Assembly]::Load("System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
$null = [Windows.Devices.Enumeration.DeviceInformation,  Windows.Devices.Enumeration,   ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCapture,              Windows.Media.Capture,         ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.MediaCaptureInitializationSettings, Windows.Media.Capture, ContentType=WindowsRuntime]
$null = [Windows.Media.Capture.StreamingCaptureMode,      Windows.Media.Capture,         ContentType=WindowsRuntime]
$null = [Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media.MediaProperties, ContentType=WindowsRuntime]
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

function GrabTop([string]$label) {
    $path = "C:\Claude\hmi430\${label}_top.jpg"
    $sf = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync("C:\Claude")) ([Windows.Storage.StorageFolder])
    $f  = Await ($sf.CreateFileAsync("${label}_top.jpg", [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    Await ($mcTop.CapturePhotoToStorageFileAsync(
        [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f)) $null
    $img = [System.Drawing.Image]::FromFile($path)
    $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone)
    $img.Save($path); $img.Dispose()
    Write-Host "  Captured: $path"
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

function ViewAndCapture($port, [string]$label) {
    Send $port 'G0 Z0' -wait
    Send $port 'G0 X0 Y-51.5' -wait
    Start-Sleep -Milliseconds 1500   # let screen settle
    GrabTop $label
}

function PressButton($port, [double]$x, [double]$y, [string]$name) {
    Write-Host "Pressing $name at X=$x Y=$y..."
    Send $port 'G0 Z0' -wait
    Send $port "G0 X${x} Y${y}" -wait
    Send $port 'G0 Z-14' -wait
    Start-Sleep -Milliseconds 300
    Send $port 'G0 Z0' -wait
    Write-Host "  Released."
}

# ── Open camera FIRST (before CNC, avoids USB re-enum killing COM port) ──
Write-Host "Opening overhead camera..."
$devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) `
    ([Windows.Devices.Enumeration.DeviceInformationCollection])
$camTop = $devs | Where-Object { $_.Name -match 'Global Shutter' } | Select-Object -First 1
Write-Host "  $($camTop.Name)"
$cfgTop = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfgTop.VideoDeviceId = $camTop.Id
$cfgTop.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mcTop = [Windows.Media.Capture.MediaCapture]::new()
Await ($mcTop.InitializeAsync($cfgTop)) $null
Start-Sleep -Milliseconds 3000

# ── Connect to CNC ──
Write-Host "Connecting to CNC..."
$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.ReadExisting() | Out-Null
$port.WriteLine(''); Start-Sleep -Milliseconds 400; $port.ReadExisting() | Out-Null
Send $port 'G21'; Send $port 'G90'; Send $port 'G54'

# ── Baseline capture ──
Write-Host "`nCapturing baseline..."
ViewAndCapture $port "press_00_before"

# ── Press CFG (X=127, Y=-32) ──
Write-Host ""
PressButton $port 127 (-32) "CFG"
Write-Host "Capturing after CFG press..."
ViewAndCapture $port "press_01_cfg"

# ── Press SET (X=56, Y=-32) ──
Write-Host ""
PressButton $port 56 (-32) "SET"
Write-Host "Capturing after SET press..."
ViewAndCapture $port "press_02_set"

# ── Done ──
Send $port 'G0 Z0' -wait
Send $port 'G0 X0 Y0' -wait
$port.Close()
$mcTop.Dispose()
Write-Host "`nDone."
Write-Host "  press_00_before_top.jpg  - baseline"
Write-Host "  press_01_cfg_top.jpg     - after CFG press"
Write-Host "  press_02_set_top.jpg     - after SET press"
