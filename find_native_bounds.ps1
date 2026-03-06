# find_native_bounds.ps1 - Find screen bounds in native 1920x1080 image by brightness scan
Add-Type -AssemblyName System.Drawing

$img = [System.Drawing.Bitmap]::new("C:\Claude\hmi430\screen_captures\latest\zone_0_0.jpg")
Write-Host "Native image: $($img.Width) x $($img.Height)"

# The screen (after RotateFlip) has a bright gray region vs dark PCB border
# Scan horizontal strip at y=30% and y=70%
$step = 5  # sample every 5 pixels
$sampleY1 = [int]($img.Height * 0.30)
$sampleY2 = [int]($img.Height * 0.70)
$sampleX1 = [int]($img.Width * 0.30)
$sampleX2 = [int]($img.Width * 0.70)

# Column brightness at two Y positions
Write-Host "`nColumn brightness (every 50px):"
for ($x = 0; $x -lt $img.Width; $x += 50) {
    $px1 = $img.GetPixel($x, $sampleY1)
    $b1 = [int](0.299*$px1.R + 0.587*$px1.G + 0.114*$px1.B)
    $px2 = $img.GetPixel($x, $sampleY2)
    $b2 = [int](0.299*$px2.R + 0.587*$px2.G + 0.114*$px2.B)
    Write-Host "  x=${x}: y30=$b1  y70=$b2"
}

# Row brightness at two X positions
Write-Host "`nRow brightness (every 30px):"
for ($y = 0; $y -lt $img.Height; $y += 30) {
    $px1 = $img.GetPixel($sampleX1, $y)
    $b1 = [int](0.299*$px1.R + 0.587*$px1.G + 0.114*$px1.B)
    $px2 = $img.GetPixel($sampleX2, $y)
    $b2 = [int](0.299*$px2.R + 0.587*$px2.G + 0.114*$px2.B)
    Write-Host "  y=${y}: x30=$b1  x70=$b2"
}

$img.Dispose()
