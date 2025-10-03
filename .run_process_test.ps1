$importPath = Join-Path $PSScriptRoot 'TitleToTags.psm1'
Import-Module $importPath -Force
$r = Convert-TitleToTags -Title '[abc] Bug title [#123]'
$r | ConvertTo-Json -Depth 4
Write-Output ''
