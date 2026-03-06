Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'COM11' } |
    Select-Object FriendlyName, DeviceID, Manufacturer, Service |
    Format-List
