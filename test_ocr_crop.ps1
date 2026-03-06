# test_ocr_crop.ps1 — Run OCR with per-button crop on existing captured images
# Tests without running CNC — useful for tuning crop coordinates

Add-Type -AssemblyName System.Drawing
$null = [System.Reflection.Assembly]::Load("System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
$null = [Windows.Media.Ocr.OcrEngine,                     Windows.Media.Ocr,             ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder,          Windows.Graphics.Imaging,      ContentType=WindowsRuntime]
$null = [Windows.Storage.FileAccessMode,                  Windows.Storage.Streams,       ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFile,                     Windows.Storage,               ContentType=WindowsRuntime]

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

$imgDir = "C:\Claude\hmi430\screen_captures\latest"
$cropDir = "C:\Claude\hmi430\screen_captures\latest\crops"
New-Item -ItemType Directory -Force -Path $cropDir | Out-Null

# Screen region in 3x image (5760x3240 for 1920x1080 camera)
# Tune these if crops look off
$screenLeft = 700; $screenTop = 300
$btnW = 1447; $btnH = 867

$pass = 0; $fail = 0

foreach ($row in 0..2) {
    foreach ($col in 0..2) {
        $expected = "P:$col,$row"
        $fpath = Join-Path $imgDir "zone_${col}_${row}.jpg"
        if (-not (Test-Path $fpath)) {
            Write-Host "  SKIP zone_${col}_${row}.jpg (not found)" -ForegroundColor Yellow
            continue
        }

        # 3x scale + invert
        $src = [System.Drawing.Bitmap]::new($fpath)
        $w3 = $src.Width * 3; $h3 = $src.Height * 3
        $dst = [System.Drawing.Bitmap]::new($w3, $h3, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($dst)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
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
        $g.DrawImage($src, [System.Drawing.Rectangle]::new(0,0,$w3,$h3), 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $g.Dispose(); $ia.Dispose(); $src.Dispose()

        # Crop to button
        $cropX = [Math]::Max(0, [Math]::Min($screenLeft + $col * $btnW, $w3 - $btnW))
        $cropY = [Math]::Max(0, [Math]::Min($screenTop  + $row * $btnH, $h3 - $btnH))
        $crop = [System.Drawing.Bitmap]::new($btnW, $btnH)
        $gc = [System.Drawing.Graphics]::FromImage($crop)
        $gc.DrawImage($dst, [System.Drawing.Rectangle]::new(0, 0, $btnW, $btnH),
            [System.Drawing.Rectangle]::new($cropX, $cropY, $btnW, $btnH),
            [System.Drawing.GraphicsUnit]::Pixel)
        $gc.Dispose(); $dst.Dispose()

        # Save crop for visual inspection
        $cropPath = Join-Path $cropDir "crop_${col}_${row}.png"
        $crop.Save($cropPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $crop.Dispose()

        # OCR
        $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'ocr_crop_test.png')
        $tmpBmp = [System.Drawing.Bitmap]::new($cropPath)
        $tmpBmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
        $tmpBmp.Dispose()

        $text = ""
        try {
            $sf = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
            $stream = Await ($sf.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
            $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
            $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
            $stream.Dispose()
            $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
            $result = Await ($eng.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
            $bitmap.Dispose()
            $text = $result.Text
        } catch { $text = "(OCR error: $_)" }

        $colPat = switch ($col) { 0 {'[0oO@Q]'} 1 {'[1li!|]'} 2 {'2'} }
        $rowPat = switch ($row) { 0 {'[0oO@Q]'} 1 {'[1li!|]'} 2 {'2'} }
        $ok = $text -imatch "P.{0,2}${colPat}.{0,2}${rowPat}"
        if ($ok) {
            Write-Host "  PASS zone($col,$row) — '$($text.Trim())'" -ForegroundColor Green
            $pass++
        } else {
            Write-Host "  FAIL zone($col,$row) — expected '$expected', got: '$($text.Trim())'" -ForegroundColor Red
            $fail++
        }
    }
}

Write-Host ""
Write-Host "Result: $pass/9 PASS  (crops saved to $cropDir)" -ForegroundColor Cyan
