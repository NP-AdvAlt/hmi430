# take_screenshot.ps1 - Take a single MTP screenshot without pressing anything
param([string]$OutDir = "C:\Claude\hmi430\screen_captures\latest")
. "$PSScriptRoot\mtp_screenshot.ps1"
$path = Get-MtpScreenshot -OutDir $OutDir
Write-Host "Saved: $path"
