# Test if any usable Python is available
$paths = @(
    "C:\Python313\python.exe",
    "C:\Python312\python.exe",
    "C:\Python311\python.exe",
    "C:\Python310\python.exe",
    "C:\Python39\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe"
)
foreach ($p in $paths) {
    if (Test-Path $p) {
        Write-Host "Found: $p"
        & $p --version
    }
}

# Also try uv, pipx, conda
foreach ($tool in @("uv","conda","mamba","pipx")) {
    $found = Get-Command $tool -ErrorAction SilentlyContinue
    if ($found) { Write-Host "$tool found at $($found.Source)" }
}
