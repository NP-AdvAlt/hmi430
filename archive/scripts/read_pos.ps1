$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'CH340' }
$com = $dev.FriendlyName -replace '.*\((.+)\).*','$1'
$p = New-Object System.IO.Ports.SerialPort $com, 115200, 'None', 8, 'One'
$p.ReadTimeout = 3000; $p.Open()
try {
    Start-Sleep -Milliseconds 800; $p.ReadExisting() | Out-Null
    $p.WriteLine(''); Start-Sleep -Milliseconds 300; $p.ReadExisting() | Out-Null
    $p.WriteLine('$#'); Start-Sleep -Milliseconds 600
    $hash = $p.ReadExisting()
    $p.Write('?'); Start-Sleep -Milliseconds 400
    $status = $p.ReadExisting()
    Write-Host "Status: $($status.Trim())"
    Write-Host "Offsets: $($hash.Trim())"
    $g54  = [regex]::Match($hash,   '\[G54:([0-9.\-,]+)\]').Groups[1].Value
    $mpos = [regex]::Match($status, 'MPos:([0-9.\-,]+)').Groups[1].Value
    if ($g54 -and $mpos) {
        $mp = $mpos -split ','; $wc = $g54 -split ','
        $wx = [math]::Round([double]$mp[0]-[double]$wc[0],3)
        $wy = [math]::Round([double]$mp[1]-[double]$wc[1],3)
        $wz = [math]::Round([double]$mp[2]-[double]$wc[2],3)
        Write-Host "Work position: X=$wx  Y=$wy  Z=$wz"
    }
} finally { $p.Close() }
