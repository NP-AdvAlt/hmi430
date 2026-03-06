# test_ocr2.ps1 - Quick OCR test with corrected crop coords + binarize on existing images
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

$imgDir  = "C:\Claude\hmi430\screen_captures\latest"
$cropDir = "C:\Claude\hmi430\screen_captures\latest\crops2"
New-Item -ItemType Directory -Force -Path $cropDir | Out-Null

$screenLeft=120; $screenTop=380; $btnW=1841; $btnH=856
$eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
$pass = 0; $fail = 0

foreach ($row in 0..2) {
    foreach ($col in 0..2) {
        $fpath = Join-Path $imgDir "zone_${col}_${row}.jpg"
        if (-not (Test-Path $fpath)) { Write-Host "SKIP zone_${col}_${row}"; continue }

        $src = [System.Drawing.Bitmap]::new($fpath)
        $w3 = $src.Width * 3; $h3 = $src.Height * 3
        $dst = [System.Drawing.Bitmap]::new($w3, $h3, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($dst)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $invM = [float[][]]@([float[]]@(-1,0,0,0,0),[float[]]@(0,-1,0,0,0),[float[]]@(0,0,-1,0,0),[float[]]@(0,0,0,1,0),[float[]]@(1,1,1,0,1))
        $ia = [System.Drawing.Imaging.ImageAttributes]::new(); $ia.SetColorMatrix([System.Drawing.Imaging.ColorMatrix]::new($invM))
        $g.DrawImage($src, [System.Drawing.Rectangle]::new(0,0,$w3,$h3), 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $g.Dispose(); $ia.Dispose(); $src.Dispose()

        $cropX = [Math]::Max(0, [Math]::Min($screenLeft + $col*$btnW, $w3-$btnW))
        $cropY = [Math]::Max(0, [Math]::Min($screenTop  + $row*$btnH, $h3-$btnH))
        $binM = [float[][]]@([float[]]@(10,0,0,0,0),[float[]]@(0,10,0,0,0),[float[]]@(0,0,10,0,0),[float[]]@(0,0,0,1,0),[float[]]@(-6.5,-6.5,-6.5,0,1))
        $bia = [System.Drawing.Imaging.ImageAttributes]::new(); $bia.SetColorMatrix([System.Drawing.Imaging.ColorMatrix]::new($binM))
        $crop = [System.Drawing.Bitmap]::new($btnW, $btnH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $gc = [System.Drawing.Graphics]::FromImage($crop)
        $gc.DrawImage($dst, [System.Drawing.Rectangle]::new(0,0,$btnW,$btnH), $cropX,$cropY,$btnW,$btnH, [System.Drawing.GraphicsUnit]::Pixel, $bia)
        $gc.Dispose(); $bia.Dispose(); $dst.Dispose()

        $cropPath = Join-Path $cropDir "crop2_${col}_${row}.png"
        $crop.Save($cropPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $crop.Dispose()

        $tmp = "$env:TEMP\ocr2test.png"
        [System.IO.File]::Copy($cropPath, $tmp, $true)

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
        $status = if ($ok) { "PASS"; $pass++ } else { "FAIL"; $fail++ }
        Write-Host "$status zone($col,$row)  got:[$text]"
    }
}
Write-Host ""
Write-Host "Result: $pass/9 PASS  (crops in $cropDir)"
