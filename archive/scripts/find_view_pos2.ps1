# Scan Y positions for best camera view of touchscreen.
# Opens camera and CNC port ONCE at startup to avoid USB re-enumeration
# killing the COM port.

param([string]$CamName = "Global Shutter")

# ── WinRT helpers ───────────────────────────────────────────────────────────
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

# ── Open camera first (before touching the CNC port) ───────────────────────
Write-Host "=== Opening camera ==="
$devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) `
    ([Windows.Devices.Enumeration.DeviceInformationCollection])

$cam = $devs | Where-Object { $_.Name -match $CamName } | Select-Object -First 1
if (-not $cam) { $cam = $devs | Select-Object -First 1 }
Write-Host "Using camera: $($cam.Name)"

$cfg = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfg.VideoDeviceId = $cam.Id
$cfg.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mc = [Windows.Media.Capture.MediaCapture]::new()
Await ($mc.InitializeAsync($cfg)) $null
Write-Host "Camera ready."

function GrabFrame([string]$path) {
    $dir  = [System.IO.Path]::GetDirectoryName($path)
    $name = [System.IO.Path]::GetFileName($path)
    $sf   = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($dir)) ([Windows.Storage.StorageFolder])
    $f    = Await ($sf.CreateFileAsync($name, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    $enc  = [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg()
    Await ($mc.CapturePhotoToStorageFileAsync($enc, $f)) $null
    Write-Host "  Captured: $path ($([int](Get-Item $path).Length/1024) KB)"
}

# ── CNC helpers ─────────────────────────────────────────────────────────────
function WaitForIdle($port, $timeoutSec = 20) {
    Start-Sleep -Milliseconds 400
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?'); Start-Sleep -Milliseconds 250
        $r = $port.ReadExisting()
        if ($r -match 'Alarm') { Write-Host "  [ALARM]"; return $false }
        if ($r -match 'Idle')  {
            $pos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
            Write-Host "  [Idle] MPos=$pos"
            return $true
        }
    }
    Write-Host "  [timeout]"; return $false
}

# ── Open CNC port (camera already initialised, no more USB enumeration) ─────
Write-Host "`n=== Opening CNC port ==="
$port = New-Object System.IO.Ports.SerialPort 'COM13', 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.WriteLine(''); Start-Sleep -Milliseconds 600; $port.ReadExisting() | Out-Null
$port.WriteLine('G21'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
$port.WriteLine('G90'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
$port.WriteLine('G54'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null

$port.Write('?'); Start-Sleep -Milliseconds 400
Write-Host "CNC status: $($port.ReadExisting().Trim())"

# ── Scan Y positions ─────────────────────────────────────────────────────────
foreach ($y in @(0, -15, -30, -45, -60, -75, -90)) {
    Write-Host "`n--- Y = $y ---"
    $port.WriteLine("G0 Y$y")
    Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
    WaitForIdle $port | Out-Null
    Start-Sleep -Milliseconds 600   # let vibration settle

    $label = [string]$y -replace '-','neg'
    GrabFrame "C:\Claude\hmi430\scan_y${label}.jpg"
}

# ── Return home and close ────────────────────────────────────────────────────
Write-Host "`n=== Returning home ==="
$port.WriteLine('G0 X0 Y0 Z0'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
WaitForIdle $port | Out-Null
$port.Close()
$mc.Dispose()
Write-Host "Done."
