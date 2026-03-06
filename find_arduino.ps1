Get-PnpDevice | Where-Object { $_.FriendlyName -match 'Arduino|CH340|CP210|FTDI|USB Serial|COM' } | Select-Object FriendlyName, Status, InstanceId | Format-List
