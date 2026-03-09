$nodeExe = "C:\Claude\hmi430\node\node-v22.14.0-win-x64\node.exe"
$buildJs = "C:\Claude\hmi430\splat_build.js"
$buildBd = "C:\Claude\hmi430\_build.b1d"
$r = & $nodeExe $buildJs $buildBd 2>&1 | Out-String
if ($r -match 'BUILD SUCCESS') { Write-Host "Build OK" } else { Write-Host "Build failed"; Write-Host $r }
