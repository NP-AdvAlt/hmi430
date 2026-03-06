# press_test.ps1 - Press center button (zone 1,1), read serial output, capture screen
# Zone (1,1) center: X=91.5, Y=-51.5 (same Y as view position)
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

$outDir = "C:\Claude\hmi430\screen_captures"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Open camera FIRST
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
Start-Sleep -Milliseconds 2000

# Open AV430 serial (COM11) to listen for touch output
Write-Host "Opening AV430 serial on COM11..."
$av430 = New-Object System.IO.Ports.SerialPort 'COM11', 9600, 'None', 8, 'One'
$av430.ReadTimeout = 100
try { $av430.Open() } catch { Write-Warning "Could not open COM11: $_" }

# Connect CNC
Write-Host "Connecting CNC..."
$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.ReadExisting() | Out-Null
$port.WriteLine(''); Start-Sleep -Milliseconds 400; $port.ReadExisting() | Out-Null
Send $port 'G21'; Send $port 'G90'; Send $port 'G54'
Send $port 'M3 S1000'          # HMI power on

# Move to press position: zone(1,1) center = X=91.5, Y=-51.5
Write-Host "Moving to press position (zone 1,1: X=91.5 Y=-51.5)..."
Send $port 'G0 Z0' -wait
Send $port 'G0 X91.5 Y-51.5' -wait
Start-Sleep -Milliseconds 500

# Flush any stale COM11 data
if ($av430.IsOpen) { $av430.ReadExisting() | Out-Null }

# Press
Write-Host "Pressing..."
Send $port 'G0 Z-14' -wait
Start-Sleep -Milliseconds 300

# Retract
Send $port 'G0 Z0' -wait
Write-Host "Retracted."

# Read serial output (multiple attempts over 2s)
$received = ""
if ($av430.IsOpen) {
    Write-Host "Reading COM11..."
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline) {
        try { $received += $av430.ReadExisting() } catch {}
        Start-Sleep -Milliseconds 100
    }
}

# Move to view position for capture
Write-Host "Moving to view position..."
Send $port 'G0 X0' -wait
$port.Close()
Start-Sleep -Milliseconds 1000

# Capture
Write-Host "Capturing screen..."
$sf = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($outDir)) ([Windows.Storage.StorageFolder])
$f = Await ($sf.CreateFileAsync("press_result.jpg", [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
Await ($mc.CapturePhotoToStorageFileAsync(
    [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f)) $null
$img = [System.Drawing.Image]::FromFile("$outDir\press_result.jpg")
$img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone)
$img.Save("$outDir\press_result.jpg"); $img.Dispose()

$mc.Dispose()
if ($av430.IsOpen) { $av430.Close() }

Write-Host ""
Write-Host "=== Results ==="
if ($received -ne "") {
    Write-Host "COM11 received: '$received'"
} else {
    Write-Host "COM11: no data received"
}
Write-Host "Screen captured: $outDir\press_result.jpg"
