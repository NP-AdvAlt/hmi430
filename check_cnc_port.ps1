Write-Host "=== Available COM ports ==="
[System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object

Write-Host "`n=== PnP devices with COM or CH340 ==="
Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'CH340|USB Serial|COM|Arduino|Unknown' } |
    Select-Object FriendlyName, Status | Format-Table -AutoSize

Write-Host "`n=== All USB Serial / WPD devices ==="
Get-PnpDevice -PresentOnly | Where-Object { $_.Class -eq 'Ports' -or $_.Class -eq 'USB' } |
    Select-Object FriendlyName, Class, Status | Format-Table -AutoSize
