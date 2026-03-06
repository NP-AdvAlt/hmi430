# Access AV430 using GetFolder on the item directly

$shell = New-Object -ComObject Shell.Application
$thispc = $shell.NameSpace(17)

foreach ($item in $thispc.Items()) {
    if ($item.Name -match 'AV430') {
        Write-Host "Device: $($item.Name)  [Type: $($item.Type)]"
        $devFolder = $item.GetFolder
        if ($devFolder) {
            foreach ($sub in $devFolder.Items()) {
                Write-Host "  Storage: $($sub.Name)  [Type: $($sub.Type)]"
                $subF = $sub.GetFolder
                if ($subF) {
                    $files = $subF.Items()
                    Write-Host "    Files: $($files.Count)"
                    foreach ($f in $files) {
                        Write-Host "      $($f.Name)  $($f.Size) bytes"
                    }
                } else {
                    Write-Host "    GetFolder returned null"
                    # Try CopyHere to list (just enumerate)
                    Write-Host "    sub.IsFolder = $($sub.IsFolder)"
                    Write-Host "    sub.IsBrowsable = $($sub.IsBrowsable)"
                }
            }
        } else {
            Write-Host "  GetFolder returned null on device"
        }
    }
}
