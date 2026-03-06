# Copy files from AV430 Internal Storage to local folder

$dest = "C:\Claude\hmi430\hmi_assets"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$shell = New-Object -ComObject Shell.Application
$thispc = $shell.NameSpace(17)
$destFolder = $shell.NameSpace($dest)

foreach ($item in $thispc.Items()) {
    if ($item.Name -match 'AV430') {
        $storage = $item.GetFolder.Items() | Where-Object { $_.Name -eq 'Internal Storage' }
        $files = $storage.GetFolder.Items()
        Write-Host "Copying $($files.Count) files to $dest ..."
        foreach ($f in $files) {
            Write-Host "  $($f.Name)"
            $destFolder.CopyHere($f, 4)   # 4 = no progress dialog
        }
        break
    }
}

# Wait for copies to finish then report
Start-Sleep -Milliseconds 3000
Write-Host ""
Write-Host "=== Files in $dest ==="
Get-ChildItem $dest | Select-Object Name, Length | Format-Table -AutoSize

# Check PNG dimensions
Add-Type -AssemblyName System.Drawing
foreach ($png in Get-ChildItem $dest -Filter '*.png') {
    $img = [System.Drawing.Image]::FromFile($png.FullName)
    Write-Host "$($png.Name): $($img.Width) x $($img.Height) px"
    $img.Dispose()
}
