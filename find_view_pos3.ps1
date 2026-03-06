# Robust version: auto-detects CH340 port after camera init disrupts USB

# ── WinRT setup ──────────────────────────────────────────────────────────────
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
    Write-Host "  photo: $path ($([int](Get-Item $path).Length/1024) KB)"
}

function FindCH340Port($retries = 10, $delayMs = 1500) {
    for ($i = 0; $i -lt $retries; $i++) {
        $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'CH340' }
        if ($dev) {
            $com = $dev.FriendlyName -replace '.*\((.+)\).*','$1'
            Write-Host "Found CH340 on $com"
            return $com
        }
        Write-Host "  CH340 not found yet, waiting... ($($i+1)/$retries)"
        Start-Sleep -Milliseconds $delayMs
    }
    throw "CH340 not found after $retries retries"
}

function OpenCNCPort($com) {
    $p = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
    $p.ReadTimeout = 3000; $p.Open()
    Start-Sleep -Milliseconds 800; $p.WriteLine(''); Start-Sleep -Milliseconds 600; $p.ReadExisting() | Out-Null
    foreach ($cmd in @('G21','G90','G54')) {
        $p.WriteLine($cmd); Start-Sleep -Milliseconds 200; $p.ReadExisting() | Out-Null
    }
    return $p
}

function WaitForIdle($port, $timeoutSec = 20) {
    Start-Sleep -Milliseconds 400
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?'); Start-Sleep -Milliseconds 250
        $r = $port.ReadExisting()
        if ($r -match 'Alarm') { Write-Host "  [ALARM]"; return $false }
        if ($r -match 'Idle')  {
            $pos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
            Write-Host "  [Idle] MPos=$pos"; return $true
        }
    }
    Write-Host "  [timeout]"; return $false
}

# ── Step 1: open camera (this may kick the CH340 off USB) ───────────────────
Write-Host "=== Initialising camera ==="
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
Write-Host "Camera ready. Waiting for USB to settle..."
Start-Sleep -Milliseconds 3000   # give USB time to re-enumerate

# ── Step 2: find CH340 (may have re-appeared on a different COM port) ────────
$comPort = FindCH340Port
$port = OpenCNCPort $comPort
$port.Write('?'); Start-Sleep -Milliseconds 400
Write-Host "CNC: $($port.ReadExisting().Trim())"

# ── Step 3: scan Y positions ─────────────────────────────────────────────────
foreach ($y in @(0, -15, -30, -45, -60, -75, -90)) {
    Write-Host "`n--- Moving to Y=$y ---"
    $port.WriteLine("G0 Y$y")
    Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
    WaitForIdle $port | Out-Null
    Start-Sleep -Milliseconds 600

    $label = [string]$y -replace '-','neg'
    GrabFrame "C:\Claude\hmi430\scan2_y${label}.jpg"
}

# ── Return home ───────────────────────────────────────────────────────────────
Write-Host "`n=== Home ==="
$port.WriteLine('G0 X0 Y0 Z0'); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
WaitForIdle $port | Out-Null
$port.Close()
$mc.Dispose()
Write-Host "Done."
