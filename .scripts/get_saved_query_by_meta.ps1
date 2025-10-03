param(
    [Parameter(Mandatory=$false)][string]$MetaFile = '.testdata/testdata.json'
)

$meta = Get-Content -Raw $MetaFile | ConvertFrom-Json
if (-not $meta.SavedQueryId) { Write-Error 'No SavedQueryId in metadata'; exit 1 }
$pat = $env:TEST_PAT
if (-not $pat) { Write-Error 'TEST_PAT not set'; exit 1 }
$headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")) }
$uri = "https://dev.azure.com/frederic0962/ADOTestProject/_apis/wit/queries/$($meta.SavedQueryId)?api-version=7.1-preview.2"
Write-Output "GET $uri"
$resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
$resp | ConvertTo-Json -Depth 8
