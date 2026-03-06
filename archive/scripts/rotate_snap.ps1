Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile('C:\Claude\hmi430\quicksnap_top.jpg')
$img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone)
$img.Save('C:\Claude\hmi430\quicksnap_top.jpg')
$img.Dispose()
Write-Host "Done"
