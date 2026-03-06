$shell = New-Object -ComObject Shell.Application
$items = $shell.NameSpace(17).Items()
foreach ($item in $items) {
    Write-Host "Device: [$($item.Name)]  Path: $($item.Path)"
}
