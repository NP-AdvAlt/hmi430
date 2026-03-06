$token = Get-Content "$env:USERPROFILE\.claude\github_token" -Raw
$token = $token.Trim()
$body = @{
    name = "hmi430"
    description = "HMI430 touch calibration project - SPLat firmware + CNC booper + MTP screenshot verification"
    private = $false
} | ConvertTo-Json
$resp = Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Method Post `
    -Headers @{ Authorization = "token $token"; "Content-Type" = "application/json" } `
    -Body $body
Write-Host "Created: $($resp.html_url)"
Write-Host "SSH:     $($resp.ssh_url)"
