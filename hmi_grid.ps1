# 1. Rename advalt.png -> advalt_orig.png on device
# 2. Generate a CNC coordinate grid PNG
# 3. Copy new advalt.png to device

Add-Type -AssemblyName System.Drawing

$assetDir = "C:\Claude\hmi430\hmi_assets"

# --- Step 1: Copy original to device as advalt_orig.png ---
# Local backup already exists from pull. Rename local copy, then push.
Copy-Item "$assetDir\advalt.png" "$assetDir\advalt_orig.png" -Force
Write-Host "Backup saved locally as advalt_orig.png"

# --- Step 2: Generate grid image ---
$W = 480; $H = 272

# CNC calibration bounds
$cncXmin = 45.0;  $cncXmax = 138.0   # X=45 -> right edge of image, X=138 -> left edge
$cncYtop = -77.0; $cncYbot =  -26.0  # Y=-77 -> top of image, Y=-26 -> bottom

# Coordinate mapping
function PX([double]$cx) { [int](($cncXmax - $cx) / ($cncXmax - $cncXmin) * ($W - 1)) }
function PY([double]$cy) { [int](($cy       - $cncYtop) / ($cncYbot - $cncYtop) * ($H - 1)) }

$bmp = New-Object System.Drawing.Bitmap $W, $H
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
$g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

# Background
$g.Clear([System.Drawing.Color]::FromArgb(15, 15, 30))

# Pens / brushes
$gridPen   = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(50, 80, 140)), 1
$edgePen   = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(80, 120, 200)), 1
$labelBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 220, 255))
$dimBrush   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(100, 140, 200))
$configBrush   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 120, 60))
$settingsBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 220, 120))
$tickPen   = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(180, 220, 255)), 1

$fontSmall  = New-Object System.Drawing.Font("Arial", 8,  [System.Drawing.FontStyle]::Regular)
$fontMed    = New-Object System.Drawing.Font("Arial", 9,  [System.Drawing.FontStyle]::Bold)
$fontTitle  = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)

# Screen border
$g.DrawRectangle($edgePen, 0, 0, $W-1, $H-1)

# Vertical grid lines (CNC X, every 10mm)
for ($cx = 50; $cx -le 130; $cx += 10) {
    $px = PX $cx
    $g.DrawLine($gridPen, $px, 0, $px, $H - 1)
    # Label at top
    $label = "X$cx"
    $sz = $g.MeasureString($label, $fontSmall)
    $g.DrawString($label, $fontSmall, $labelBrush, ($px - $sz.Width/2), 3)
    # Tick at bottom
    $g.DrawLine($tickPen, $px, $H-8, $px, $H-1)
}

# Horizontal grid lines (CNC Y, every 10mm)
for ($cy = -70; $cy -le -30; $cy += 10) {
    $py = PY $cy
    $g.DrawLine($gridPen, 0, $py, $W - 1, $py)
    # Label at right edge
    $label = "Y$cy"
    $sz = $g.MeasureString($label, $fontSmall)
    $g.DrawString($label, $fontSmall, $labelBrush, ($W - $sz.Width - 3), ($py - $sz.Height/2))
    # Tick at left
    $g.DrawLine($tickPen, 0, $py, 7, $py)
}

# Crosshair dots at every grid intersection
$dotBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 160, 220))
for ($cx = 50; $cx -le 130; $cx += 10) {
    for ($cy = -70; $cy -le -30; $cy += 10) {
        $px = PX $cx; $py = PY $cy
        $g.FillEllipse($dotBrush, $px-2, $py-2, 4, 4)
    }
}

# Center marker
$cxC = ($cncXmin + $cncXmax) / 2.0   # 91.5
$cyC = ($cncYtop + $cncYbot)  / 2.0  # -51.5
$cpx = PX $cxC; $cpy = PY $cyC
$centerPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Yellow), 1
$g.DrawLine($centerPen, $cpx-8, $cpy,   $cpx+8, $cpy)
$g.DrawLine($centerPen, $cpx,   $cpy-8, $cpx,   $cpy+8)
$g.DrawEllipse($centerPen, $cpx-4, $cpy-4, 8, 8)
$g.DrawString("CTR", $fontSmall, (New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Yellow)), $cpx+6, $cpy-8)

# Config button marker  (X=127, Y=-32)
$cfgPx = PX 127; $cfgPy = PY (-32)
$g.FillEllipse($configBrush, $cfgPx-5, $cfgPy-5, 10, 10)
$g.DrawString("CFG", $fontSmall, $configBrush, $cfgPx+6, $cfgPy-8)

# Settings button marker (X=56, Y=-32)
$setPx = PX 56; $setPy = PY (-32)
$g.FillEllipse($settingsBrush, $setPx-5, $setPy-5, 10, 10)
$g.DrawString("SET", $fontSmall, $settingsBrush, $setPx+6, $setPy-8)

# Title
$title = "CNC COORD GRID  X:45-138  Y:-26 to -77"
$g.DrawString($title, $fontTitle, $dimBrush, 5, ($H - 18))

# Dispose graphics
$g.Dispose()

# Save new advalt.png
$outPath = "$assetDir\advalt.png"
$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "Grid image saved: $outPath"

# --- Step 3: Copy files to device ---
$shell = New-Object -ComObject Shell.Application
$thispc = $shell.NameSpace(17)

$storage = $null
foreach ($item in $thispc.Items()) {
    if ($item.Name -match 'AV430') {
        $storage = ($item.GetFolder.Items() | Where-Object { $_.Name -eq 'Internal Storage' }).GetFolder
        break
    }
}

if (-not $storage) { Write-Host "ERROR: AV430 Internal Storage not found"; exit 1 }

Write-Host "Copying advalt_orig.png to device..."
$storage.CopyHere("$assetDir\advalt_orig.png", 4)
Start-Sleep -Milliseconds 2000

Write-Host "Copying new advalt.png (grid) to device..."
$storage.CopyHere("$assetDir\advalt.png", 4)
Start-Sleep -Milliseconds 2000

Write-Host "Done. Power-cycle the HMI430 to display the grid."
