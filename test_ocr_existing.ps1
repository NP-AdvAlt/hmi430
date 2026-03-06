# test_ocr_existing.ps1 - Test OCR directly on existing crop5_0_0.png
# This isolates whether the OCR pipeline works on a known-good image
$null = [System.Reflection.Assembly]::Load("System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
$null = [Windows.Media.Ocr.OcrEngine,             Windows.Media.Ocr,        ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder,  Windows.Graphics.Imaging, ContentType=WindowsRuntime]
$null = [Windows.Storage.FileAccessMode,          Windows.Storage.Streams,  ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFile,             Windows.Storage,          ContentType=WindowsRuntime]
Add-Type -AssemblyName System.Drawing

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

$eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
Write-Host "OCR engine: $($eng.RecognizerLanguage.DisplayName)"

# Test 1: load crop5_0_0.png directly (known good file)
$testFile = "C:\Claude\hmi430\screen_captures\latest\crops5\crop5_0_0.png"
Write-Host "Testing: $testFile"
$imgInfo = [System.Drawing.Bitmap]::new($testFile)
Write-Host "Image size: $($imgInfo.Width) x $($imgInfo.Height), Format: $($imgInfo.PixelFormat)"
$imgInfo.Dispose()

try {
    $sf = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($testFile)) ([Windows.Storage.StorageFile])
    $stream = Await ($sf.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    Write-Host "Decoded: $($dec.PixelWidth) x $($dec.PixelHeight), DpiX=$($dec.DpiX)"
    $bmp = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    Write-Host "SoftwareBitmap: $($bmp.PixelWidth) x $($bmp.PixelHeight), Format=$($bmp.BitmapPixelFormat)"
    $stream.Dispose()
    $res = Await ($eng.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
    $bmp.Dispose()
    Write-Host "OCR result: [$($res.Text)]"
    Write-Host "Line count: $($res.Lines.Count)"
    foreach ($line in $res.Lines) {
        Write-Host "  Line: [$($line.Text)]"
    }
} catch {
    Write-Host "ERROR: $_"
}

# Test 2: same pipeline but convert to JPEG first (remove alpha)
Write-Host ""
Write-Host "Test 2: Convert to JPEG first (no alpha channel)"
$jpegPath = "$env:TEMP\ocr_test.jpg"
$src = [System.Drawing.Bitmap]::new($testFile)
# Convert to 24bpp RGB (no alpha) and save as JPEG
$rgb = [System.Drawing.Bitmap]::new($src.Width, $src.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($rgb)
$g.Clear([System.Drawing.Color]::White)
$g.DrawImage($src, 0, 0, $src.Width, $src.Height)
$g.Dispose(); $src.Dispose()
$encParams = [System.Drawing.Imaging.EncoderParameters]::new(1)
$encParams.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [long]95)
$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
$rgb.Save($jpegPath, $jpegCodec, $encParams)
$rgb.Dispose()

try {
    $sf = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($jpegPath)) ([Windows.Storage.StorageFile])
    $stream = Await ($sf.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bmp = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    Write-Host "SoftwareBitmap: $($bmp.PixelWidth) x $($bmp.PixelHeight), Format=$($bmp.BitmapPixelFormat)"
    $stream.Dispose()
    $res = Await ($eng.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
    $bmp.Dispose()
    Write-Host "OCR result: [$($res.Text)]"
} catch {
    Write-Host "ERROR: $_"
}
