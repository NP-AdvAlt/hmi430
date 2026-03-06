# test_all_zones.ps1 — Press all 9 touch zones, verify each via camera OCR
# Reports PASS/FAIL for each zone and overall accuracy
#
# Zone grid (CNC work coords):
#   Col: 0=X107-138  1=X76-107  2=X45-76
#   Row: 0=Y-77/-60  1=Y-60/-43  2=Y-43/-26
# Center of each zone:
#   Col0=122.5  Col1=91.5  Col2=60.5
#   Row0=-68.5  Row1=-51.5  Row2=-34.5

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
$null = [Windows.Media.Ocr.OcrEngine,                     Windows.Media.Ocr,             ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder,          Windows.Graphics.Imaging,      ContentType=WindowsRuntime]
$null = [Windows.Storage.FileAccessMode,                  Windows.Storage.Streams,       ContentType=WindowsRuntime]

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

function ReadScreenText($imagePath, $col, $row) {
    # Preprocess: scale up 3x + invert colors (black-on-white reads better with OCR)
    $src = [System.Drawing.Bitmap]::new($imagePath)
    $w = $src.Width * 3; $h = $src.Height * 3
    $dst = [System.Drawing.Bitmap]::new($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    # Color matrix: invert RGB, keep alpha, add white offset
    $matrix = [float[][]]@(
        [float[]]@(-1, 0, 0, 0, 0),
        [float[]]@(0, -1, 0, 0, 0),
        [float[]]@(0, 0, -1, 0, 0),
        [float[]]@(0, 0, 0, 1, 0),
        [float[]]@(1, 1, 1, 0, 1)
    )
    $cm = [System.Drawing.Imaging.ColorMatrix]::new($matrix)
    $ia = [System.Drawing.Imaging.ImageAttributes]::new()
    $ia.SetColorMatrix($cm)
    $g.DrawImage($src, [System.Drawing.Rectangle]::new(0,0,$w,$h), 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
    $g.Dispose(); $ia.Dispose(); $src.Dispose()

    # Crop to button area, applying binarize matrix to eliminate LCD texture noise.
    # Screen region in 3x image (calibrated from captured images):
    #   x: ~120 to ~5643  (screen fills ~96% of 5760px width)
    #   y: ~380 to ~2948  (screen fills ~79% of 3240/3600px height)
    # Each button: ~1841 x 856 px in the 3x image
    $screenLeft = 120; $screenTop = 380
    $btnW = 1841; $btnH = 856
    $cropX = [Math]::Max(0, [Math]::Min($screenLeft + $col * $btnW, $w - $btnW))
    $cropY = [Math]::Max(0, [Math]::Min($screenTop  + $row * $btnH, $h - $btnH))
    # Binarize while cropping: scale contrast 10x centered at 65% gray threshold
    # Text (dark after invert ~0.2-0.4) -> black; background (~0.7-0.8) -> white
    $binMatrix = [float[][]]@(
        [float[]]@(10, 0, 0, 0, 0),
        [float[]]@(0, 10, 0, 0, 0),
        [float[]]@(0, 0, 10, 0, 0),
        [float[]]@(0, 0, 0,  1, 0),
        [float[]]@(-6.5, -6.5, -6.5, 0, 1)
    )
    $binIa = [System.Drawing.Imaging.ImageAttributes]::new()
    $binIa.SetColorMatrix([System.Drawing.Imaging.ColorMatrix]::new($binMatrix))
    $crop = [System.Drawing.Bitmap]::new($btnW, $btnH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gc = [System.Drawing.Graphics]::FromImage($crop)
    $gc.DrawImage($dst, [System.Drawing.Rectangle]::new(0, 0, $btnW, $btnH),
        $cropX, $cropY, $btnW, $btnH, [System.Drawing.GraphicsUnit]::Pixel, $binIa)
    $gc.Dispose(); $binIa.Dispose(); $dst.Dispose()

    $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'ocr_prep.png')
    $crop.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
    # Save debug crop alongside source image
    $dbg = $imagePath -replace '\.jpg$', '_ocr.png'
    $crop.Save($dbg, [System.Drawing.Imaging.ImageFormat]::Png)
    $crop.Dispose()

    # Run Windows OCR on cropped image
    $sf = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
    $stream = Await ($sf.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $stream.Dispose()
    $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    $result = Await ($eng.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    $bitmap.Dispose()
    return $result.Text
}

$outDir = "C:\Claude\hmi430\screen_captures\latest"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Zone layout: [col, row, X_cnc, Y_cnc]
$zones = @(
    @(0, 0, 122.5, -68.5),
    @(1, 0, 91.5,  -68.5),
    @(2, 0, 60.5,  -68.5),
    @(0, 1, 122.5, -51.5),
    @(1, 1, 91.5,  -51.5),
    @(2, 1, 60.5,  -51.5),
    @(0, 2, 122.5, -34.5),
    @(1, 2, 91.5,  -34.5),
    @(2, 2, 60.5,  -34.5)
)

# --- Setup ---
Write-Host "=== Zone Grid Test ===" -ForegroundColor Cyan
Write-Host "Opening camera..."
$devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) `
    ([Windows.Devices.Enumeration.DeviceInformationCollection])
$cam = $devs | Where-Object { $_.Name -match 'Global Shutter' } | Select-Object -First 1
if (-not $cam) { Write-Error "Camera not found"; exit 1 }
$cfg = [Windows.Media.Capture.MediaCaptureInitializationSettings]::new()
$cfg.VideoDeviceId = $cam.Id
$cfg.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
$mc = [Windows.Media.Capture.MediaCapture]::new()
Await ($mc.InitializeAsync($cfg)) $null
Start-Sleep -Milliseconds 2000
# Switch video stream to MJPG for sharp captures (NV12 default causes heavy artifacts)
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

Write-Host "Connecting CNC..."
$com = FindCH340
$port = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000; $port.Open()
Start-Sleep -Milliseconds 800; $port.ReadExisting() | Out-Null
$port.WriteLine(''); Start-Sleep -Milliseconds 400; $port.ReadExisting() | Out-Null
Send $port 'G21'; Send $port 'G90'; Send $port 'G54'

# Power cycle HMI so buttons start with original labels (no residual P: text)
Write-Host "Power cycling HMI for clean state..."
Send $port 'M5'
Start-Sleep -Milliseconds 3000
Send $port 'M3 S1000'
Write-Host "Waiting 15s for HMI boot..."
Start-Sleep -Milliseconds 15000

Send $port 'G0 Z0' -wait

$sf = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($outDir)) ([Windows.Storage.StorageFolder])

$results = @()
$pass = 0; $fail = 0

# --- Test each zone ---
foreach ($zone in $zones) {
    $col = $zone[0]; $row = $zone[1]
    $cx = $zone[2]; $cy = $zone[3]
    $expected = "P:$col,$row"

    Write-Host ""
    Write-Host "Zone ($col,$row) at X=$cx Y=$cy..." -NoNewline

    # Move to press position
    Send $port "G0 X$cx Y$cy" -wait
    Start-Sleep -Milliseconds 300

    # Press
    Send $port 'G0 Z-14' -wait
    Start-Sleep -Milliseconds 200

    # Retract
    Send $port 'G0 Z0' -wait

    # Move to fixed view position (Y=-60 shows full screen regardless of press Y)
    Send $port 'G0 X0 Y-60' -wait
    Start-Sleep -Milliseconds 800

    # Capture
    $fname = "zone_${col}_${row}.jpg"
    $fpath = Join-Path $outDir $fname
    $f = Await ($sf.CreateFileAsync($fname, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    Await ($mc.CapturePhotoToStorageFileAsync(
        [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $f)) $null
    $img = [System.Drawing.Image]::FromFile($fpath)
    $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone)
    $img.Save($fpath); $img.Dispose()

    # OCR
    $text = ""
    try { $text = ReadScreenText $fpath $col $row } catch { $text = "(OCR error: $_)" }

    # OCR-tolerant match: allow common garbles (0/o/O, 1/l/i, comma/period, colon/semicolon/space)
    $colPat = switch ($col) { 0 {'[0oO@Q]'} 1 {'[1li!|]'} 2 {'2'} }
    $rowPat = switch ($row) { 0 {'[0oO@Q]'} 1 {'[1li!|]'} 2 {'2'} }
    $ok = $text -imatch "P.{0,2}${colPat}.{0,2}${rowPat}"
    if ($ok) {
        Write-Host " PASS ($expected found)" -ForegroundColor Green
        $pass++
    } else {
        Write-Host " FAIL (expected '$expected', got: '$($text.Trim())')" -ForegroundColor Red
        $fail++
    }
    $results += [PSCustomObject]@{ Zone="($col,$row)"; Expected=$expected; Detected=$text.Trim(); Pass=$ok }

    # Move back to Y needed for next zone (keep in Y range)
    # For next iteration, no need to reset — zones are visited in order
}

# Retract and park
Send $port 'G0 Z0' -wait
Send $port 'G0 X0 Y0' -wait
$port.Close()
$mc.Dispose()

# --- Summary ---
Write-Host ""
Write-Host "==============================" -ForegroundColor Cyan
Write-Host "  Results: $pass/9 zones PASS" -ForegroundColor $(if ($pass -eq 9) { 'Green' } else { 'Yellow' })
Write-Host "==============================" -ForegroundColor Cyan
$results | Format-Table Zone, Expected, Pass -AutoSize
