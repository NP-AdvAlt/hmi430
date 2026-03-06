# test_ocr3.ps1 - Test OCR with combined invert+grayscale+threshold on full image
# No crop needed - regex finds specific P:col,row pattern among all button labels
$null = [System.Reflection.Assembly]::Load("System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
$null = [Windows.Media.Ocr.OcrEngine,             Windows.Media.Ocr,       ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder,  Windows.Graphics.Imaging,ContentType=WindowsRuntime]
$null = [Windows.Storage.FileAccessMode,          Windows.Storage.Streams, ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFile,             Windows.Storage,         ContentType=WindowsRuntime]
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
$pass = 0; $fail = 0

# Combined matrix: 3x scale implied by DrawImage dest rect; per-pixel: invert + grayscale + threshold at 50%
# Dark button bg (~0.2 gray) -> after invert 0.8 -> above threshold -> WHITE  (good: background is white)
# White text (~0.9 gray)     -> after invert 0.1 -> below threshold -> BLACK  (good: text is black)
# Formula: gray_inverted = -(0.299*R + 0.587*G + 0.114*B) + 1.0
#          threshold at 0.5: output = gray_inverted * 10 - 5
#          = -2.99*R - 5.87*G - 1.14*B + 10 - 5 = -2.99*R - 5.87*G - 1.14*B + 5
$mat = [float[][]]@(
    [float[]]@(-2.99, -2.99, -2.99, 0, 0),
    [float[]]@(-5.87, -5.87, -5.87, 0, 0),
    [float[]]@(-1.14, -1.14, -1.14, 0, 0),
    [float[]]@(0,     0,     0,     1, 0),
    [float[]]@(5,     5,     5,     0, 1)
)

foreach ($row in 0..2) {
    foreach ($col in 0..2) {
        $fpath = Join-Path $imgDir "zone_${col}_${row}.jpg"
        if (-not (Test-Path $fpath)) { Write-Host "SKIP zone_${col}_${row}"; continue }

        $src = [System.Drawing.Bitmap]::new($fpath)
        $w3 = $src.Width * 3; $h3 = $src.Height * 3
        $dst = [System.Drawing.Bitmap]::new($w3, $h3, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($dst)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $ia = [System.Drawing.Imaging.ImageAttributes]::new()
        $ia.SetColorMatrix([System.Drawing.Imaging.ColorMatrix]::new($mat))
        $g.DrawImage($src, [System.Drawing.Rectangle]::new(0,0,$w3,$h3), 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $g.Dispose(); $ia.Dispose(); $src.Dispose()

        # Save debug image
        $dbg = Join-Path $imgDir "zone_${col}_${row}_bin.png"
        $dst.Save($dbg, [System.Drawing.Imaging.ImageFormat]::Png)

        $tmp = "$env:TEMP\ocr3test.png"
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
        if ($ok) { Write-Host "PASS zone($col,$row)  got:[$text]"; $pass++ }
        else      { Write-Host "FAIL zone($col,$row)  got:[$text]"; $fail++ }
    }
}
Write-Host ""
Write-Host "Result: $pass/9 PASS"
