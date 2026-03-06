# test_ocr4.ps1 - OCR at native 1920x1080 (within 4MP OCR limit)
# Combined matrix: invert + grayscale + threshold at native size
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
$eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()

# Combined: invert + grayscale + threshold at 50%
# Dark bg (~0.2) -> inverted 0.8 -> above thresh -> WHITE
# Light text (~0.85) -> inverted 0.15 -> below thresh -> BLACK
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
        # Apply combined matrix at native size (no scaling)
        $dst = [System.Drawing.Bitmap]::new($src.Width, $src.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($dst)
        $ia = [System.Drawing.Imaging.ImageAttributes]::new()
        $ia.SetColorMatrix([System.Drawing.Imaging.ColorMatrix]::new($mat))
        $g.DrawImage($src, [System.Drawing.Rectangle]::new(0,0,$src.Width,$src.Height), 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $g.Dispose(); $ia.Dispose(); $src.Dispose()

        $dbg = Join-Path $imgDir "zone_${col}_${row}_nat.png"
        $dst.Save($dbg, [System.Drawing.Imaging.ImageFormat]::Png)
        $tmp = "$env:TEMP\ocr4test.png"
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
Write-Host "Result: $pass/9 PASS"
