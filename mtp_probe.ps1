$shell = New-Object -ComObject Shell.Application
$thisPc = $shell.NameSpace(17)
Write-Host "=== This PC devices ==="
foreach ($item in $thisPc.Items()) {
    Write-Host "  [$($item.Name)]  path=$($item.Path)"
    if ($item.Name -match 'AegisTec|SPLat|HMI|AV430') {
        Write-Host "  --> HMI device found, listing folders:"
        $devFolder = $item.GetFolder
        foreach ($sub in $devFolder.Items()) {
            Write-Host "      $($sub.Name)"
            $subFolder = $sub.GetFolder
            if ($subFolder) {
                foreach ($f in $subFolder.Items()) {
                    Write-Host "          $($f.Name)"
                }
            }
        }
    }
}
