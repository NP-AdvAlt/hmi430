# Access AV430 via WPD COM API

$source = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
[System.Reflection.Assembly]::LoadFile((Join-Path $source 'System.dll')) | Out-Null

# Use Shell.Application with GetFolder on This PC (0x11 = CSIDL_DRIVES)
$shell = New-Object -ComObject Shell.Application
$thispc = $shell.NameSpace(17)  # 17 = This PC

Write-Host "=== All items in This PC ==="
foreach ($item in $thispc.Items()) {
    Write-Host "  [$($item.Type)] $($item.Name)  ->  $($item.Path)"
}

Write-Host ""
Write-Host "=== Looking for AV430 ==="
foreach ($item in $thispc.Items()) {
    if ($item.Name -match 'AV430|HMI') {
        Write-Host "Device: $($item.Name)"
        $devFolder = $shell.NameSpace($item.Path)
        if ($devFolder) {
            foreach ($sub in $devFolder.Items()) {
                Write-Host "  $($sub.Name)  [$($sub.Type)]  path=$($sub.Path)"
                $subFolder = $shell.NameSpace($sub.Path)
                if ($subFolder) {
                    foreach ($f in $subFolder.Items()) {
                        Write-Host "    $($f.Name)  size=$($f.Size)"
                    }
                } else {
                    Write-Host "    (could not open subfolder)"
                }
            }
        }
    }
}
