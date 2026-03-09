Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'COM|CH340|Serial|USB' } | Select-Object FriendlyName, Status | Format-Table -AutoSize
