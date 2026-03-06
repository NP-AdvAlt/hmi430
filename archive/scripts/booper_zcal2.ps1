# Dual-camera Z calibration with HMI touch detection
# Boots HMI, waits for screen to go dark, descends in 0.5mm steps.
# Screen lighting up on contact = precise touch point.
# Top camera (Global Shutter): rotated 180 deg. Front camera (Brio): as-is.

param(
    [int]$XPos       = 80,
    [int]$YPos       = -60,
    [decimal]$StartZ = -17.0,
    [decimal]$EndZ   = -22.0,
    [decimal]$StepMm = 0.5
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

# GrabTop and GrabFront use script-scope $mcTop / $mcFront directly
# (WinRT objects lose type info when passed as function params)
function GrabTop([string]$label) {
    $path = "C:\Claude\hmi430\zcal2_${label}_top.jpg"
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
    $path = "C:\Claude\hmi430\zcal2_${label}_front.jpg"
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

# ── Step 1: Open top camera (Global Shutter) ──────────────────────────────────
Write-Host "=== Opening top camera (Global Shutter) ==="
$devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) `
    ([Windows.Devices.Enumeration.DeviceInformationCollection])
$camTop = $devs | Where-Object { $_.Name -match 'Global Shutter' } | Select-Object -First 1
if (-not $camTop) { throw "Global Shutter camera not found" }
Write-Host "  $($camTop.Name)"
$cfgTop = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfgTop.VideoDeviceId = $camTop.Id
$cfgTop.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mcTop = [Windows.Media.Capture.MediaCapture]::new()
Await ($mcTop.InitializeAsync($cfgTop)) $null
Write-Host "  Top camera ready. Settling..."
Start-Sleep -Milliseconds 3000

# ── Step 2: Open front camera (Brio) ─────────────────────────────────────────
Write-Host "=== Opening front camera (Brio) ==="
$devs2 = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) `
    ([Windows.Devices.Enumeration.DeviceInformationCollection])
$camFront = $devs2 | Where-Object { $_.Name -match 'Brio' } | Select-Object -First 1
if (-not $camFront) { throw "Brio camera not found" }
Write-Host "  $($camFront.Name)"
$cfgFront = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfgFront.VideoDeviceId = $camFront.Id
$cfgFront.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mcFront = [Windows.Media.Capture.MediaCapture]::new()
Await ($mcFront.InitializeAsync($cfgFront)) $null
Write-Host "  Front camera ready. Settling..."
Start-Sleep -Milliseconds 2000

# ── Step 3: Open CNC ─────────────────────────────────────────────────────────
$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.WriteLine(''); Start-Sleep -Milliseconds 600; $port.ReadExisting() | Out-Null
Send $port 'G21'; Send $port 'G90'; Send $port 'G54'
$port.Write('?'); Start-Sleep -Milliseconds 400
Write-Host "CNC: $($port.ReadExisting().Trim())"

# ── Step 4: Move to press position at safe Z ──────────────────────────────────
Write-Host "`n=== Moving to press position: X=$XPos Y=$YPos ==="
Send $port 'G0 Z0' -wait
Send $port "G0 X$XPos Y$YPos" -wait

# ── Step 5: Boot HMI and wait for screen to go dark ──────────────────────────
Write-Host "`n=== Booting HMI (M3 S1000) ==="
Send $port 'M3 S1000'
Write-Host "HMI powering on. Taking boot frames every 15s for 90s..."

for ($i = 1; $i -le 6; $i++) {
    Start-Sleep -Milliseconds 15000
    Write-Host "`n  [Boot $i/6] t=$($i*15)s"
    GrabTop   "boot_${i}"
    GrabFront "boot_${i}"
}
Write-Host "`nBoot monitoring complete. Screen should now be dark."

# ── Step 6: Z descent in 0.5mm steps ─────────────────────────────────────────
Write-Host "`n=== Z calibration descent ($StartZ to $EndZ in ${StepMm}mm steps) ==="
$z = $StartZ
while ($z -ge $EndZ) {
    $label = ("$z" -replace '\.','p') -replace '-','neg'
    Write-Host "`n--- Z = $z ---"
    Send $port "G0 Z$z" -wait
    Start-Sleep -Milliseconds 800
    GrabTop   $label
    GrabFront $label
    $z = [Math]::Round($z - $StepMm, 1)
}

# ── Step 7: Retract and home ──────────────────────────────────────────────────
Write-Host "`n=== Retracting and returning home ==="
Send $port 'G0 Z0' -wait
Send $port 'G0 X0 Y0' -wait
Send $port 'M5'
$port.Close()
$mcTop.Dispose()
$mcFront.Dispose()
Write-Host "`nDone. Review zcal2_*_top.jpg and zcal2_*_front.jpg"
Write-Host "Look for the step where the screen lights up = contact depth."
