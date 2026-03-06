Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.Class -match 'Ports|USB' } |
    Select-Object FriendlyName, Status |
    Format-Table -AutoSize
