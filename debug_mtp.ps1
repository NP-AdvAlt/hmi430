$shell = New-Object -ComObject Shell.Application
$device = $shell.NameSpace(17).Items() |
          Where-Object { $_.Name -match 'AV430' } | Select-Object -First 1
Write-Host "Device: $($device.Name) at $($device.Path)"

$ns = $shell.NameSpace($device.Path)
Write-Host "Device namespace: $ns"
$items = $ns.Items()
Write-Host "Items count: $($items.Count)"
foreach ($item in $items) {
    Write-Host "  [$($item.Name)]  Path=$($item.Path)"
}

$storage = $items | Where-Object { $_.Name -match 'Internal Storage' } | Select-Object -First 1
Write-Host "Storage: $($storage.Name) at $($storage.Path)"

$ns2 = $shell.NameSpace($storage.Path)
Write-Host "Storage namespace: $ns2"
$items2 = $ns2.Items()
Write-Host "Storage items count: $($items2.Count)"
foreach ($item in $items2) {
    Write-Host "  [$($item.Name)]"
}
