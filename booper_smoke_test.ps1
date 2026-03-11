# Smoke test: use booper module to press the two 4x4px test buttons
# (assumes gen_test_buttons.js firmware is already flashed)

. "C:\Claude\hmi430\booper.ps1"

$outDir = 'C:\Claude\hmi430\screen_captures\smoke_test'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$port = Open-Booper -PowerHMI

# Press near top-left (100, 100) and capture
$img1 = Press-ScreenAndCapture $port 100 100 -OutDir $outDir -Label 'btn0_hit'
Write-Host "Button 0 screenshot: $img1"

# Press near bottom-right (410, 202) and capture
$img2 = Press-ScreenAndCapture $port 410 202 -OutDir $outDir -Label 'btn1_hit'
Write-Host "Button 1 screenshot: $img2"

Close-Booper $port -PowerOff

Write-Host 'Smoke test complete. Check screenshots.'
