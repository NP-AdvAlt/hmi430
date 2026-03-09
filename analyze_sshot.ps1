Add-Type -AssemblyName System.Drawing
$bmp = [System.Drawing.Bitmap]::new("C:\Claude\hmi430\screen_captures\latest\sshot002.png")

function Get-Bright($bmp, $cx, $cy, $r=5) {
    $t=0.0; $n=0
    for ($px=$cx-$r; $px -lt $cx+$r; $px++) {
        for ($py=$cy-$r; $py -lt $cy+$r; $py++) {
            if ($px -ge 0 -and $px -lt 480 -and $py -ge 0 -and $py -lt 272) {
                $p=$bmp.GetPixel($px,$py); $t+=0.299*$p.R+0.587*$p.G+0.114*$p.B; $n++
            }
        }
    }
    if ($n -gt 0) { return [Math]::Round($t/$n,1) } else { return 0.0 }
}

$hits = @()
foreach ($gr in 0..5) {
    foreach ($gc in 0..9) {
        if (($gc + $gr) % 2 -ne 0) { continue }
        $btnId = ($gr * 5) + [int]($gc / 2)
        $cx = 22 + $gc * 44
        $cy = 22 + $gr * 44
        $b = Get-Bright $bmp $cx $cy
        if ($b -gt 150) {
            $hits += "  HIT btn$btnId gc=$gc gr=$gr screen($cx,$cy)  brightness=$b"
        }
    }
}

$bmp.Dispose()

if ($hits.Count -eq 0) { Write-Host "No hits found (all gray)" }
else { Write-Host "Hits in sshot002.png:"; $hits | ForEach-Object { Write-Host $_ } }
