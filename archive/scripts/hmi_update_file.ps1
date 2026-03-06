# Check device contents, delete old advalt.png, copy new one

$shell = New-Object -ComObject Shell.Application
$thispc = $shell.NameSpace(17)

$storage = $null
foreach ($item in $thispc.Items()) {
    if ($item.Name -match 'AV430') {
        $storage = ($item.GetFolder.Items() | Where-Object { $_.Name -eq 'Internal Storage' }).GetFolder
        break
    }
}
if (-not $storage) { Write-Host "ERROR: device not found"; exit 1 }

Write-Host "=== Current device files ==="
foreach ($f in $storage.Items()) {
    Write-Host "  $($f.Name)  $($f.Size) bytes"
}

# Delete advalt.png from device (move to recycle bin / device delete)
Write-Host ""
Write-Host "Deleting advalt.png from device..."
foreach ($f in $storage.Items()) {
    if ($f.Name -eq 'advalt.png') {
        $f.InvokeVerb("delete")
        Write-Host "  Deleted."
        break
    }
}
Start-Sleep -Milliseconds 2000

# Copy new grid file
Write-Host "Copying new advalt.png..."
$storage.CopyHere("C:\Claude\hmi430\hmi_assets\advalt.png", 20)  # 20 = no progress + no confirm
Start-Sleep -Milliseconds 3000

Write-Host ""
Write-Host "=== Device files after update ==="
foreach ($f in $storage.Items()) {
    Write-Host "  $($f.Name)"
}
Write-Host "Done."
