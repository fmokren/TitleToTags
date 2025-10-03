param(
    [Parameter(Mandatory=$false)][string]$MetaFile = '.testdata/testdata.json'
)

Set-StrictMode -Version Latest
$meta = Get-Content -Raw $MetaFile | ConvertFrom-Json
if (-not $meta.SavedQueryId) { Write-Error 'No SavedQueryId in metadata'; exit 1 }
$pat = $env:TEST_PAT
if (-not $pat) { Write-Error 'TEST_PAT not set'; exit 1 }
$headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")) }
$org = 'https://dev.azure.com/frederic0962'
$project = 'ADOTestProject'
$id = $meta.SavedQueryId

$uri = ($org + '/' + $project + '/_apis/wit/queries/' + $id + '?api-version=7.1-preview.2')
Write-Output "PATCH $uri"

$columns = @(
    @{ referenceName = 'System.Id' },
    @{ referenceName = 'System.Title' },
    @{ referenceName = 'System.Tags' }
)
$uBody = @{ id = $id; name = $meta.SavedQueryName; wiql = "Select [System.Id] From WorkItems Where [System.TeamProject] = '$project' And [System.Tags] Contains '$($meta.Token)' Order By [System.Id]"; isPublic = $true; columns = $columns } | ConvertTo-Json -Depth 8
$wiqlToSet = "Select [System.Id], [System.Title], [System.Tags] From WorkItems Where [System.TeamProject] = '$project' And [System.Tags] Contains '$($meta.Token)' Order By [System.Id'"
$uBody = @{ id = $id; name = $meta.SavedQueryName; wiql = $wiqlToSet; isPublic = $true; columns = $columns } | ConvertTo-Json -Depth 8

try {
    $resp = Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $uBody -ContentType 'application/json' -ErrorAction Stop
    Write-Output "PATCH response:"
    $resp | ConvertTo-Json -Depth 8
}
catch {
    Write-Warning "PATCH failed: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        try { $body = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult(); Write-Output "Response body:\n$body" } catch { Write-Warning "Could not read response body." }
    }
}

# Fetch the query resource to inspect
try {
    $get = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
    Write-Output "GET after PATCH:"
    $get | ConvertTo-Json -Depth 8
    if ($get._links -and $get._links.html -and $get._links.html.href) { Write-Output "Open this URL in browser to inspect UI: $($get._links.html.href)" }
}
catch {
    Write-Warning "Failed to GET query after PATCH: $($_.Exception.Message)"
}
