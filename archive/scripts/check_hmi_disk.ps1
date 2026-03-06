# Check for new drives and all interfaces of the NXP HMI device

Write-Host "=== Logical Drives ==="
Get-PSDrive -PSProvider FileSystem | Select-Object Name, Root, Description, @{N='FreeGB';E={[math]::Round($_.Free/1GB,2)}}, @{N='UsedGB';E={[math]::Round(($_.Used)/1GB,2)}} | Format-Table -AutoSize

Write-Host "=== All USB VID_1FC9 interfaces ==="
Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceID -match 'VID_1FC9' } |
    Select-Object FriendlyName, DeviceID, Status |
    Format-List

Write-Host "=== USB Mass Storage / Disk devices ==="
Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.Class -match 'DiskDrive|USB|WPD|Volume' -and $_.Status -eq 'OK' } |
    Select-Object FriendlyName, Class, DeviceID |
    Format-Table -AutoSize
