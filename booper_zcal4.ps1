# Z calibration pass 4: precise first-contact finder
# Range Z=-8 to Z=-14 in 0.5mm steps (max 3mm spring compression - safe)

param(
    [int]$XPos       = 80,
    [int]$YPos       = -60,
    [decimal]$StartZ = -8.0,
    [decimal]$EndZ   = -14.0,
    [decimal]$StepMm = 0.5,
    [int]$SettleMs   = 1500
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

function GrabTop([string]$label) {
    $path = "C:\Claude\hmi430\zcal4_${label}_top.jpg"
    $dir  = [System.IO.Path]::GetDirectoryName($path)
    $name = [System.IO.Path]::GetFileName($path)
    $sf   = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($dir)) ([Windows.Storage.StorageFolder])
    $f    = Await ($sf.CreateFileAsync($name, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    Await ($mcTop.CapturePhotoToStorageFileAsync(
        [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f)) $null
    $img = [System.Drawing.Image]::FromFile($path)
    $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone)
    $img.Save($path); $img.Dispose()
    Write-Host "    top:   $([System.IO.Path]::GetFileName($path)) ($([int](Get-Item $path).Length/1024) KB)"
}

function GrabFront([string]$label) {
    $path = "C:\Claude\hmi430\zcal4_${label}_front.jpg"
    $dir  = [System.IO.Path]::GetDirectoryName($path)
    $name = [System.IO.Path]::GetFileName($path)
    $sf   = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($dir)) ([Windows.Storage.StorageFolder])
    $f    = Await ($sf.CreateFileAsync($name, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    Await ($mcFront.CapturePhotoToStorageFileAsync(
        [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f)) $null
    Write-Host "    front: $([System.IO.Path]::GetFileName($path)) ($([int](Get-Item $path).Length/1024) KB)"
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

function WaitForIdle($port, $timeoutSec = 30) {
    Start-Sleep -Milliseconds 400
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?'); Start-Sleep -Milliseconds 250
        $r = $port.ReadExisting()
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

# ── Open cameras ──────────────────────────────────────────────────────────────
Write-Host "=== Opening cameras ==="
$devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) `
    ([Windows.Devices.Enumeration.DeviceInformationCollection])
$camTop = $devs | Where-Object { $_.Name -match 'Global Shutter' } | Select-Object -First 1
Write-Host "  Top: $($camTop.Name)"
$cfgTop = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfgTop.VideoDeviceId = $camTop.Id
$cfgTop.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mcTop = [Windows.Media.Capture.MediaCapture]::new()
Await ($mcTop.InitializeAsync($cfgTop)) $null
Start-Sleep -Milliseconds 3000

$devs2 = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) `
    ([Windows.Devices.Enumeration.DeviceInformationCollection])
$camFront = $devs2 | Where-Object { $_.Name -match 'Brio' } | Select-Object -First 1
Write-Host "  Front: $($camFront.Name)"
$cfgFront = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfgFront.VideoDeviceId = $camFront.Id
$cfgFront.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mcFront = [Windows.Media.Capture.MediaCapture]::new()
Await ($mcFront.InitializeAsync($cfgFront)) $null
Start-Sleep -Milliseconds 2000

# ── Open CNC and move into position ──────────────────────────────────────────
$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.WriteLine(''); Start-Sleep -Milliseconds 600; $port.ReadExisting() | Out-Null
Send $port 'G21'; Send $port 'G90'; Send $port 'G54'
$port.Write('?'); Start-Sleep -Milliseconds 400
Write-Host "CNC: $($port.ReadExisting().Trim())"

Write-Host "`n=== Moving to X=$XPos Y=$YPos ==="
Send $port 'G0 Z0' -wait
Send $port "G0 X$XPos Y$YPos" -wait

Write-Host "`n=== Booting HMI ==="
Send $port 'M3 S1000'
Write-Host "Waiting 45s for full boot..."
Start-Sleep -Milliseconds 45000

# Reference frame at safe Z
Write-Host "`n--- Reference (Z=0) ---"
GrabTop  "ref"
GrabFront "ref"

# ── Descent ───────────────────────────────────────────────────────────────────
Write-Host "`n=== Descent: Z=$StartZ to Z=$EndZ, step=${StepMm}mm ==="
Write-Host "Hard stop at Z=$EndZ (3mm max compression - safe)"
$z = $StartZ
while ($z -ge $EndZ) {
    $label = ("$z" -replace '\.','p') -replace '-','neg'
    Write-Host "`n--- Z = $z ---"
    Send $port "G0 Z$z" -wait
    Start-Sleep -Milliseconds $SettleMs
    GrabTop   $label
    GrabFront $label
    $z = [Math]::Round($z - $StepMm, 1)
}

# ── Retract and home ──────────────────────────────────────────────────────────
Write-Host "`n=== Retracting ==="
Send $port 'G0 Z0' -wait
Send $port 'G0 X0 Y0' -wait
Send $port 'M5'
$port.Close()
$mcTop.Dispose()
$mcFront.Dispose()
Write-Host "`nDone. Look for first UI response in zcal4_*_top.jpg"
