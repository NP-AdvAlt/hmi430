# Deep browse of AV430 Internal Storage and System Firmware

$shell = New-Object -ComObject Shell.Application
$internalPath = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}\\\?\usb#vid_1fc9&pid_807c&mi_02#6&39d1721c&0&0002#{6ac27878-a6fa-4155-ba85-f98f491d4f33}\SID-{10001,SimpleHMI,8388608}'
$firmwarePath  = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}\\\?\usb#vid_1fc9&pid_807c&mi_02#6&39d1721c&0&0002#{6ac27878-a6fa-4155-ba85-f98f491d4f33}\SID-{10002,SimpleHMI,4294967295}'

function BrowseFolder($label, $path, $depth = 0) {
    $indent = '  ' * $depth
    $folder = $shell.NameSpace($path)
    if (-not $folder) { Write-Host "${indent}(could not open)"; return }
    $items = $folder.Items()
    if ($items.Count -eq 0) {
        Write-Host "${indent}(empty)"
        return
    }
    foreach ($item in $items) {
        $size = if ($item.Size -gt 0) { "  [$([math]::Round($item.Size/1KB,1)) KB]" } else { "" }
        Write-Host "${indent}$($item.Name)$size"
        if ($item.IsFolder -and $depth -lt 3) {
            BrowseFolder $item.Name $item.Path ($depth + 1)
        }
    }
}

Write-Host "=== Internal Storage (8MB) ==="
BrowseFolder 'Internal Storage' $internalPath

Write-Host ""
Write-Host "=== System Firmware ==="
BrowseFolder 'System Firmware' $firmwarePath
