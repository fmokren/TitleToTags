param(
    [Parameter(Mandatory=$true)][string]$SavedQueryId,
    [Parameter(Mandatory=$false)][string]$Project = 'ADOTestProject'
)

$pat = $env:TEST_PAT
if (-not $pat) { Write-Error 'TEST_PAT not set'; exit 1 }
$headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")) }
$uri = "https://dev.azure.com/frederic0962/$Project/_apis/wit/queries/$SavedQueryId?api-version=7.1-preview.2"
Write-Output "GET $uri"
try {
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
    $resp | ConvertTo-Json -Depth 8
}
catch {
    Write-Error "Failed to GET saved query: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        try { $stream = $_.Exception.Response.GetResponseStream(); $reader = New-Object System.IO.StreamReader($stream); $body = $reader.ReadToEnd(); Write-Error "Response body:\n$body" } catch { Write-Warning "Could not read response body: $_" }
    }
    exit 2
}
