Get-Process | Where-Object { $_.Name -match 'node|powershell' } | Select-Object Name, Id, CPU | Format-Table
