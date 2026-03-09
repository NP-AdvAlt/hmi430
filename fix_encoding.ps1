$path = 'C:\Claude\hmi430\calibrate_adaptive.ps1'
$content = Get-Content $path -Raw
# Replace all non-ASCII chars with their positions
$matches = [regex]::Matches($content, '[^\x00-\x7F]')
foreach ($m in $matches) {
    Write-Host ("pos {0}: U+{1:X4} char=[{2}]" -f $m.Index, [int][char]$m.Value, $m.Value)
}
Write-Host "Total non-ASCII: $($matches.Count)"
# Replace em dashes and other non-ASCII with plain equivalents
$fixed = $content -replace '\u2014', '--'   # em dash
$fixed = $fixed   -replace '\u2013', '-'    # en dash
$fixed = $fixed   -replace '[^\x00-\x7F]', '?'  # catch-all
[System.IO.File]::WriteAllText($path, $fixed, [System.Text.Encoding]::ASCII)
Write-Host "Fixed and saved."
