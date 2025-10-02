Import-Module $PSScriptRoot\TitleToTags.psm1 -Force
$r = Process-TitleToTags -Title '[abc] Bug title [#123]'
$r | ConvertTo-Json -Depth 4
Write-Output ''
