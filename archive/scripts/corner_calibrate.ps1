# Manual corner calibration - releases COM port for jog pendant between reads
# User jogs booper tip to each screen corner, presses Enter, script reads coords

function FindCH340($retries = 10, $delayMs = 1500) {
    for ($i = 0; $i -lt $retries; $i++) {
        $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'CH340' }
        if ($dev) { $com = $dev.FriendlyName -replace '.*\((.+)\).*','$1'; return $com }
        Start-Sleep -Milliseconds $delayMs
    }
    throw "CH340 not found"
}

function ReadWorkPos($com) {
    $p = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
    $p.ReadTimeout = 3000; $p.Open()
    try {
        Start-Sleep -Milliseconds 1000; $p.ReadExisting() | Out-Null
        # Wake GRBL then request offsets
        $p.WriteLine(''); Start-Sleep -Milliseconds 400; $p.ReadExisting() | Out-Null
        $p.WriteLine('$#'); Start-Sleep -Milliseconds 800
        $hash = $p.ReadExisting()
        $g54 = [regex]::Match($hash, '\[G54:([0-9.\-,]+)\]').Groups[1].Value
        if (-not $g54) { throw "Could not read G54. Raw: $hash" }

        # Get current machine position
        $p.Write('?'); Start-Sleep -Milliseconds 400
        $r = $p.ReadExisting()
        $mpos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
        if (-not $mpos) { throw "Could not read MPos. Raw: $r" }

        $mp = $mpos -split ','; $wc = $g54 -split ','
        return [pscustomobject]@{
            X = [math]::Round([double]$mp[0] - [double]$wc[0], 2)
            Y = [math]::Round([double]$mp[1] - [double]$wc[1], 2)
            Z = [math]::Round([double]$mp[2] - [double]$wc[2], 2)
        }
    } finally {
        $p.Close()   # always release port — pendant needs it
    }
}

$com = FindCH340
Write-Host "CH340 on $com"
Write-Host ""
Write-Host "========================================"
Write-Host " SCREEN CORNER CALIBRATION"
Write-Host "========================================"
Write-Host ""
Write-Host "Step 1: Jog the booper tip to the"
Write-Host "        TOP-LEFT corner of the screen."
Write-Host "        Lower Z until tip just touches glass."
Write-Host ""
Write-Host "Press Enter when in position..."
$null = Read-Host

$topLeft = ReadWorkPos $com
Write-Host "TOP-LEFT captured: X=$($topLeft.X)  Y=$($topLeft.Y)  Z=$($topLeft.Z)"
Write-Host ""
Write-Host "Step 2: Jog to the BOTTOM-RIGHT corner."
Write-Host "        Same light touch on glass."
Write-Host ""
Write-Host "Press Enter when in position..."
$null = Read-Host

$botRight = ReadWorkPos $com
Write-Host "BOTTOM-RIGHT captured: X=$($botRight.X)  Y=$($botRight.Y)  Z=$($botRight.Z)"
Write-Host ""

# Calculate extents
$screenW = [math]::Round([math]::Abs($botRight.X - $topLeft.X), 1)
$screenH = [math]::Round([math]::Abs($botRight.Y - $topLeft.Y), 1)
$centerX = [math]::Round(($topLeft.X + $botRight.X) / 2.0, 1)
$centerY = [math]::Round(($topLeft.Y + $botRight.Y) / 2.0, 1)

# Determine which corner has min/max X and Y
$minX = [math]::Min($topLeft.X, $botRight.X)
$maxX = [math]::Max($topLeft.X, $botRight.X)
$minY = [math]::Min($topLeft.Y, $botRight.Y)
$maxY = [math]::Max($topLeft.Y, $botRight.Y)

# Inset 12% from edges for button centres
$insetX = [math]::Round($screenW * 0.12, 1)
$insetY = [math]::Round($screenH * 0.12, 1)

# Config = bottom-left, Settings = bottom-right (real-world orientation)
# "Bottom" in real world = low Y (more negative). "Left" = low X.
$configX   = [math]::Round($minX + $insetX, 1)
$configY   = [math]::Round($minY + $insetY, 1)
$settingsX = [math]::Round($maxX - $insetX, 1)
$settingsY = [math]::Round($minY + $insetY, 1)

Write-Host "========================================"
Write-Host " RESULTS"
Write-Host "========================================"
Write-Host "Top-left:    X=$($topLeft.X)  Y=$($topLeft.Y)"
Write-Host "Bottom-right:X=$($botRight.X)  Y=$($botRight.Y)"
Write-Host "Screen size: ${screenW}mm x ${screenH}mm"
Write-Host "Center:      X=$centerX  Y=$centerY"
Write-Host ""
Write-Host "Estimated button positions:"
Write-Host "  Config   (bottom-left):  X=$configX  Y=$configY"
Write-Host "  Settings (bottom-right): X=$settingsX  Y=$settingsY"
Write-Host ""
Write-Host "Press Z: -14.0"
