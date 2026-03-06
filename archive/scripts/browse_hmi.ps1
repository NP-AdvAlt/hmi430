# Browse AV430 HMI device via Windows Shell (WPD/MTP)

$shell = New-Object -ComObject Shell.Application
$devices = $shell.NameSpace(0x11)  # My Computer / This PC

Write-Host "=== Portable Devices ==="
foreach ($item in $devices.Items()) {
    if ($item.Name -match 'AV430|HMI|430') {
        Write-Host "Found: $($item.Name) [$($item.Path)]"
        Write-Host ""
        Write-Host "=== Top-level folders/files ==="
        $folder = $shell.NameSpace($item.Path)
        if ($folder) {
            foreach ($child in $folder.Items()) {
                Write-Host "  $($child.Name)  [$($child.Path)]"
                # Go one level deeper
                $sub = $shell.NameSpace($child.Path)
                if ($sub) {
                    foreach ($f in $sub.Items()) {
                        Write-Host "    $($f.Name)  [$($f.Path)]"
                    }
                }
            }
        }
    }
}
