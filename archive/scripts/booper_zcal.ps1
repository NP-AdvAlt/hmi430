# Booper Z calibration: slowly lower head to find touchscreen contact depth
# Captures a frame at each Z step (rotated 180 deg for correct viewing)
# Review frames to find the Z where booper first contacts the screen

param(
    [int]$XPos   = 80,    # X position over screen (adjust if needed)
    [int]$YPos   = -60,   # Y view/press position
    [int]$StartZ = -5,    # Z to start lowering from (mm, work coords)
    [int]$EndZ   = -22,   # Z hard safety limit — DO NOT go deeper, spring bottoms out
    [int]$StepMm = 2      # mm per step
)

Add-Type -AssemblyName System.Drawing

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

function GrabFrame([string]$path) {
    $dir  = [System.IO.Path]::GetDirectoryName($path)
    $name = [System.IO.Path]::GetFileName($path)
    $sf   = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($dir)) ([Windows.Storage.StorageFolder])
    $f    = Await ($sf.CreateFileAsync($name, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    Await ($mc.CapturePhotoToStorageFileAsync(
        [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f)) $null
}

function GrabRotated([string]$path) {
    GrabFrame $path
    # Rotate 180 deg in-place so screen text reads correctly
    $img = [System.Drawing.Image]::FromFile($path)
    $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone)
    $img.Save($path)
    $img.Dispose()
    Write-Host "  photo: $([System.IO.Path]::GetFileName($path)) ($([int](Get-Item $path).Length/1024) KB)"
}

function FindCH340($retries = 10, $delayMs = 1500) {
    for ($i = 0; $i -lt $retries; $i++) {
        $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'CH340' }
        if ($dev) {
            $com = $dev.FriendlyName -replace '.*\((.+)\).*','$1'
            Write-Host "CH340 on $com"; return $com
        }
        Write-Host "  waiting for CH340... ($($i+1)/$retries)"
        Start-Sleep -Milliseconds $delayMs
    }
    throw "CH340 not found"
}

function WaitForIdle($port, $timeoutSec = 20) {
    Start-Sleep -Milliseconds 400
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?'); Start-Sleep -Milliseconds 250
        $r = $port.ReadExisting()
        if ($r -match 'Alarm') { Write-Host "  [ALARM]"; return $false }
        if ($r -match 'Idle') {
            $pos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
            Write-Host "  [Idle] MPos=$pos"; return $true
        }
    }
    Write-Host "  [timeout]"; return $false
}

function Send($port, $cmd, [switch]$wait) {
    $port.WriteLine($cmd); Start-Sleep -Milliseconds 200
    $port.ReadExisting() | Out-Null
    if ($wait) { WaitForIdle $port | Out-Null }
}

# Step 1: Open camera
Write-Host "=== Opening camera ==="
$devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) `
    ([Windows.Devices.Enumeration.DeviceInformationCollection])
$cam = $devs | Where-Object { $_.Name -match 'Global Shutter' } | Select-Object -First 1
if (-not $cam) { $cam = $devs | Select-Object -First 1 }
Write-Host "Camera: $($cam.Name)"
$cfg = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfg.VideoDeviceId = $cam.Id
$cfg.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mc = [Windows.Media.Capture.MediaCapture]::new()
Await ($mc.InitializeAsync($cfg)) $null
Write-Host "Camera ready. Settling USB..."
Start-Sleep -Milliseconds 3000

# Step 2: Open CNC
$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.WriteLine(''); Start-Sleep -Milliseconds 600; $port.ReadExisting() | Out-Null
Send $port 'G21'; Send $port 'G90'; Send $port 'G54'

$port.Write('?'); Start-Sleep -Milliseconds 400
Write-Host "CNC: $($port.ReadExisting().Trim())"

# Step 3: Move to press position (Z at safe height first)
Write-Host "`n=== Moving to press position: X=$XPos Y=$YPos ==="
Send $port "G0 Z0" -wait          # retract Z fully first
Send $port "G0 X$XPos Y$YPos" -wait

# Capture reference frame at top (Z=0)
Write-Host "`n--- Reference frame at Z=0 ---"
GrabRotated "C:\Claude\hmi430\zcal_z000.jpg"

# Step 4: Lower in steps, capture frame at each
$z = $StartZ
while ($z -ge $EndZ) {
    $label = [string]$z -replace '-','neg'
    Write-Host "`n--- Lowering to Z=$z ---"
    Send $port "G0 Z$z" -wait
    Start-Sleep -Milliseconds 600   # settle
    GrabRotated "C:\Claude\hmi430\zcal_z${label}.jpg"
    $z -= $StepMm
}

# Step 5: Return home safely
Write-Host "`n=== Returning home ==="
Send $port "G0 Z0" -wait
Send $port "G0 X0 Y0" -wait
Send $port "M5"

$port.Close()
$mc.Dispose()
Write-Host "`nZ calibration frames saved to C:\Claude\hmi430\zcal_*.jpg"
Write-Host "Review frames to find first contact depth."
Write-Host "Screen text should appear right-side up (rotated 180 deg applied)."
