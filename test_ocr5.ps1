# test_ocr5.ps1 - Per-button crop + 4x scale + invert+gray+threshold
# Keeps each processed image ~2.3MP (within OCR 4MP limit), text ~80px tall
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

$imgDir = "C:\Claude\hmi430\screen_captures\latest"
$cropDir = "C:\Claude\hmi430\screen_captures\latest\crops5"
New-Item -ItemType Directory -Force -Path $cropDir | Out-Null
$eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()

# Button position in native 1920x1080 image
# Screen region: left=154 top=65, each button 467x317 px
# These are approximate - adjust if crops look off
$screenLeft = 154; $screenTop = 65; $btnW = 467; $btnH = 317; $scale = 4

# Combined matrix: invert + grayscale + threshold at 50%
$mat = [float[][]]@(
    [float[]]@(-2.99, -2.99, -2.99, 0, 0),
    [float[]]@(-5.87, -5.87, -5.87, 0, 0),
    [float[]]@(-1.14, -1.14, -1.14, 0, 0),
    [float[]]@(0,     0,     0,     1, 0),
    [float[]]@(5,     5,     5,     0, 1)
)

$pass = 0; $fail = 0
foreach ($row in 0..2) {
    foreach ($col in 0..2) {
        $fpath = Join-Path $imgDir "zone_${col}_${row}.jpg"
        if (-not (Test-Path $fpath)) { Write-Host "SKIP zone_${col}_${row}"; continue }

        $src = [System.Drawing.Bitmap]::new($fpath)
        $srcX = [Math]::Max(0, [Math]::Min($screenLeft + $col*$btnW, $src.Width  - $btnW))
        $srcY = [Math]::Max(0, [Math]::Min($screenTop  + $row*$btnH, $src.Height - $btnH))
        $dstW = $btnW * $scale; $dstH = $btnH * $scale

        $dst = [System.Drawing.Bitmap]::new($dstW, $dstH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($dst)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $ia = [System.Drawing.Imaging.ImageAttributes]::new()
        $ia.SetColorMatrix([System.Drawing.Imaging.ColorMatrix]::new($mat))
        # Crop native button region, scale 4x, apply combined matrix in one step
        $g.DrawImage($src, [System.Drawing.Rectangle]::new(0,0,$dstW,$dstH),
            $srcX, $srcY, $btnW, $btnH, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $g.Dispose(); $ia.Dispose(); $src.Dispose()

        $cropPath = Join-Path $cropDir "crop5_${col}_${row}.png"
        $dst.Save($cropPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $tmp = "$env:TEMP\ocr5test.png"
        $dst.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
        $dst.Dispose()

        $text = ""
        try {
            $sf = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
            $stream = Await ($sf.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
            $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
            $bmp = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
            $stream.Dispose()
            $res = Await ($eng.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
            $bmp.Dispose()
            $text = $res.Text
        } catch { $text = "ERR:$_" }

        $colPat = switch ($col) { 0 {'[0oO@Q]'} 1 {'[1li!|]'} 2 {'2'} }
        $rowPat = switch ($row) { 0 {'[0oO@Q]'} 1 {'[1li!|]'} 2 {'2'} }
        $ok = $text -imatch "P.{0,2}${colPat}.{0,2}${rowPat}"
        if ($ok) { Write-Host "PASS zone($col,$row)  [$text]"; $pass++ }
        else      { Write-Host "FAIL zone($col,$row)  [$text]"; $fail++ }
    }
}
Write-Host ""
Write-Host "Result: $pass/9 PASS  (crops in $cropDir)"
