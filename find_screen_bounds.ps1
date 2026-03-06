# find_screen_bounds.ps1 - Scan a captured image to find exact screen region boundaries
# Outputs the crop parameters to use in ReadScreenText
Add-Type -AssemblyName System.Drawing

$imgPath = "C:\Claude\hmi430\screen_captures\latest\zone_0_0.jpg"
$src = [System.Drawing.Bitmap]::new($imgPath)
$w3 = $src.Width * 3; $h3 = $src.Height * 3
$dst = [System.Drawing.Bitmap]::new($w3, $h3, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($dst)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$invM = [float[][]]@([float[]]@(-1,0,0,0,0),[float[]]@(0,-1,0,0,0),[float[]]@(0,0,-1,0,0),[float[]]@(0,0,0,1,0),[float[]]@(1,1,1,0,1))
$ia = [System.Drawing.Imaging.ImageAttributes]::new(); $ia.SetColorMatrix([System.Drawing.Imaging.ColorMatrix]::new($invM))
$g.DrawImage($src, [System.Drawing.Rectangle]::new(0,0,$w3,$h3), 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
$g.Dispose(); $ia.Dispose(); $src.Dispose()
Write-Host "Image size: $w3 x $h3"

# Sample brightness along horizontal strip at 30% of height (middle of row 0)
$sampleY = [int]($h3 * 0.30)
$step = 20  # sample every 20 pixels for speed

# Column scan: find where brightness jumps high (screen region, bright after inversion)
$colBrightness = @()
for ($x = 0; $x -lt $w3; $x += $step) {
    $px = $dst.GetPixel($x, $sampleY)
    $gray = [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
    $colBrightness += $gray
}

# Row scan: find vertical boundaries at 50% of width
$sampleX = [int]($w3 * 0.50)
$rowBrightness = @()
for ($y = 0; $y -lt $h3; $y += $step) {
    $px = $dst.GetPixel($sampleX, $y)
    $gray = [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
    $rowBrightness += $gray
}
$dst.Dispose()

# Print raw brightness profile (sample every 10 steps = 200px)
Write-Host "`nColumn brightness at y=$sampleY (every 200px):"
$i = 0
foreach ($b in $colBrightness) {
    if ($i % 10 -eq 0) { Write-Host "  x=$($i*$step): $b" }
    $i++
}

Write-Host "`nRow brightness at x=$sampleX (every 200px):"
$j = 0
foreach ($b in $rowBrightness) {
    if ($j % 10 -eq 0) { Write-Host "  y=$($j*$step): $b" }
    $j++
}

# Find screen edges: look for sustained brightness > 100
$threshold = 100
$leftEdge = -1; $rightEdge = -1
for ($i = 0; $i -lt $colBrightness.Count; $i++) {
    if ($colBrightness[$i] -gt $threshold -and $leftEdge -lt 0) { $leftEdge = $i * $step }
    if ($colBrightness[$i] -gt $threshold) { $rightEdge = ($i+1) * $step }
}
$topEdge = -1; $botEdge = -1
for ($j = 0; $j -lt $rowBrightness.Count; $j++) {
    if ($rowBrightness[$j] -gt $threshold -and $topEdge -lt 0) { $topEdge = $j * $step }
    if ($rowBrightness[$j] -gt $threshold) { $botEdge = ($j+1) * $step }
}

Write-Host "`nDetected screen bounds:"
Write-Host "  Left:  $leftEdge   Right: $rightEdge  (width=$($rightEdge-$leftEdge))"
Write-Host "  Top:   $topEdge    Bot:   $botEdge     (height=$($botEdge-$topEdge))"
$btnW = [int](($rightEdge-$leftEdge)/3)
$btnH = [int](($botEdge-$topEdge)/3)
Write-Host "`nSuggested crop params:"
Write-Host "  screenLeft=$leftEdge  screenTop=$topEdge  btnW=$btnW  btnH=$btnH"
