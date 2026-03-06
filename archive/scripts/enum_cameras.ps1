# List all video capture devices visible to DirectShow / Windows
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# Method 1: PnP devices
Write-Host "=== Camera devices (PnP) ==="
Get-PnpDevice -PresentOnly | Where-Object { $_.Class -eq 'Camera' -or $_.Class -eq 'Image' } |
    Select-Object Status, FriendlyName, InstanceId | Format-Table -AutoSize

# Method 2: DirectShow enumeration via WMI
Write-Host "=== Video capture devices (WMI) ==="
Get-WmiObject Win32_PnPEntity | Where-Object {
    $_.PNPClass -eq 'Camera' -or $_.Name -match 'camera|webcam|capture|video'
} | Select-Object Name, PNPClass | Format-Table -AutoSize
