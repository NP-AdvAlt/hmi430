# XY alignment scan - moves booper across screen range, captures top camera
# No pressing (Z=0). Use images to map booper position to screen coordinates.

param(
    [string]$Axis    = 'X',       # 'X' or 'Y'
    [int]$FixedY     = -60,       # Y position when scanning X
    [int]$FixedX     = 80,        # X position when scanning Y
    [int]$Start      = 40,
    [int]$End        = 150,
    [int]$Step       = 10
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
    $path = "C:\Claude\hmi430\xyscan_${label}.jpg"
    $sf = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync("C:\Claude")) ([Windows.Storage.StorageFolder])
    $f  = Await ($sf.CreateFileAsync("xyscan_${label}.jpg", [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    Await ($mcTop.CapturePhotoToStorageFileAsync(
        [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f)) $null
    $img = [System.Drawing.Image]::FromFile($path)
    $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone)
    $img.Save($path); $img.Dispose()
    Write-Host "  $path ($([int](Get-Item $path).Length/1024) KB)"
}

function FindCH340($retries = 10, $delayMs = 1500) {
    for ($i = 0; $i -lt $retries; $i++) {
        $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'CH340' }
        if ($dev) { $com = $dev.FriendlyName -replace '.*\((.+)\).*','$1'; Write-Host "CH340 on $com"; return $com }
        Write-Host "  waiting... ($($i+1)/$retries)"; Start-Sleep -Milliseconds $delayMs
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
    $port.WriteLine($cmd); Start-Sleep -Milliseconds 200; $port.ReadExisting() | Out-Null
    if ($wait) { WaitForIdle $port | Out-Null }
}

# Open top camera only
Write-Host "=== Opening top camera ==="
$devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
$camTop = $devs | Where-Object { $_.Name -match 'Global Shutter' } | Select-Object -First 1
Write-Host "  $($camTop.Name)"
$cfgTop = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfgTop.VideoDeviceId = $camTop.Id
$cfgTop.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mcTop = [Windows.Media.Capture.MediaCapture]::new()
Await ($mcTop.InitializeAsync($cfgTop)) $null
Start-Sleep -Milliseconds 3000

# Open CNC
$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.WriteLine(''); Start-Sleep -Milliseconds 600; $port.ReadExisting() | Out-Null
Send $port 'G21'; Send $port 'G90'; Send $port 'G54'

# Scan
Write-Host "`n=== Scanning $Axis from $Start to $End step $Step (Z=0, no press) ==="
Send $port 'G0 Z0' -wait

$pos = $Start
$scanning = $true
while ($scanning) {
    if ($Axis -eq 'X') {
        $label = "x${pos}_y${FixedY}"
        Write-Host "`n--- X=$pos Y=$FixedY ---"
        Send $port "G0 X$pos Y$FixedY" -wait
    } else {
        $label = "x${FixedX}_y${pos}"
        Write-Host "`n--- X=$FixedX Y=$pos ---"
        Send $port "G0 X$FixedX Y$pos" -wait
    }
    Start-Sleep -Milliseconds 600
    GrabTop $label
    if ($Start -le $End) { $pos += $Step; if ($pos -gt $End) { $scanning = $false } }
    else                  { $pos -= $Step; if ($pos -lt $End) { $scanning = $false } }
}

# Return home, leave HMI on
Send $port 'G0 Z0' -wait
Send $port 'G0 X0 Y0' -wait
$port.Close()
$mcTop.Dispose()
Write-Host "`nScan done. HMI still on. Review xyscan_*.jpg"
