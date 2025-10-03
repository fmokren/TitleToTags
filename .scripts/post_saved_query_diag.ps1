param(
    [Parameter(Mandatory=$true)][string]$OrganizationUrl,
    [Parameter(Mandatory=$true)][string]$Project,
    [Parameter(Mandatory=$true)][string]$SavedQueryName,
    [Parameter(Mandatory=$true)][string]$Wiql,
    [Parameter(Mandatory=$false)][string]$PatEnvVarName = 'TEST_PAT'
)

Set-StrictMode -Version Latest

$pat = [Environment]::GetEnvironmentVariable($PatEnvVarName)
if (-not $pat) { Write-Error "PAT not set in env var $PatEnvVarName"; exit 1 }

# Build JSON payload
$columns = @(
    @{ referenceName = 'System.Id' },
    @{ referenceName = 'System.Title' },
    @{ referenceName = 'System.Tags' }
)
$payload = @{ name = $SavedQueryName; wiql = $Wiql; isPublic = $true; columns = $columns }
$json = $payload | ConvertTo-Json -Depth 8

# Prepare HttpClient
Add-Type -AssemblyName System.Net.Http
$client = [System.Net.Http.HttpClient]::new()
$client.DefaultRequestHeaders.Accept.Clear()
$client.DefaultRequestHeaders.Add('User-Agent','TitleToTagsDiag/1.0')
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Basic',$auth)

$uri = "${OrganizationUrl}/${Project}/_apis/wit/queries/My%20Queries?api-version=7.1-preview.2"
Write-Output "POST $uri"
Write-Output "Payload:"
Write-Output $json

# Send request synchronously and capture everything
try {
    $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
    $task = $client.PostAsync($uri,$content)
    $task.Wait()
    $resp = $task.Result
    $status = [int]$resp.StatusCode
    Write-Output "Status: $status $($resp.ReasonPhrase)"

    if ($resp.Content -ne $null) {
        $read = $resp.Content.ReadAsStringAsync()
        $read.Wait()
        $body = $read.Result
        Write-Output "Response body:\n$body"
    }
    else {
        Write-Output "No response content."
    }
}
catch {
    Write-Error "Exception during POST: $($_.Exception.Message)"
    if ($_.Exception.InnerException) { Write-Error "Inner: $($_.Exception.InnerException.Message)" }
    exit 2
}
finally {
    $client.Dispose()
}
