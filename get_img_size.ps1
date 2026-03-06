Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Bitmap]::new("C:\Claude\hmi430\screen_captures\latest\zone_0_0_ocr.png")
Write-Host "Size: $($img.Width) x $($img.Height)"
$img.Dispose()
