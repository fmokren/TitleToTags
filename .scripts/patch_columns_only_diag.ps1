param(
    [Parameter(Mandatory=$false)][string]$MetaFile = '.testdata/testdata.json'
)

$meta = Get-Content -Raw $MetaFile | ConvertFrom-Json
if (-not $meta.SavedQueryId) { Write-Error 'No SavedQueryId in metadata'; exit 1 }
$pat = $env:TEST_PAT
if (-not $pat) { Write-Error 'TEST_PAT not set'; exit 1 }
$org = 'https://dev.azure.com/frederic0962'
$project = 'ADOTestProject'
$id = $meta.SavedQueryId

$uri = ($org + '/' + $project + '/_apis/wit/queries/' + $id + '?api-version=7.1-preview.2')
Write-Output "PATCH $uri"

# Try setting columns with explicit name and visible attributes
$columns = @(
    @{ referenceName = 'System.Id'; name = 'ID'; visible = $true },
    @{ referenceName = 'System.Title'; name = 'Title'; visible = $true },
    @{ referenceName = 'System.Tags'; name = 'Tags'; visible = $true }
)

$payload = @{ columns = $columns }
$json = $payload | ConvertTo-Json -Depth 8

Add-Type -AssemblyName System.Net.Http
$client = [System.Net.Http.HttpClient]::new()
$client.DefaultRequestHeaders.Add('User-Agent','TitleToTagsDiag/1.0')
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Basic',$auth)

try {
    $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
    $task = $client.SendAsync((New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Patch, $uri) -Property @{ Content = $content }))
    $task.Wait()
    $resp = $task.Result
    $status = [int]$resp.StatusCode
    Write-Output "Status: $status $($resp.ReasonPhrase)"
    if ($resp.Content) {
        $read = $resp.Content.ReadAsStringAsync(); $read.Wait(); $body = $read.Result; Write-Output "Response body:\n$body"
    }
}
catch {
    Write-Error "Exception during PATCH: $($_.Exception.Message)"
}
finally { $client.Dispose() }
