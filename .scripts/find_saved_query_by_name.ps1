param(
    [Parameter(Mandatory=$false)][string]$Project = 'ADOTestProject',
    [Parameter(Mandatory=$false)][string]$Name = ''
)
$pat = $env:TEST_PAT
if (-not $pat) { Write-Error 'TEST_PAT not set'; exit 1 }
$headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")) }
$uri = "https://dev.azure.com/frederic0962/$Project/_apis/wit/queries?`$depth=2&api-version=7.1-preview.2"
Write-Output "GET $uri"
try {
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
}
catch {
    Write-Error "Failed to list queries: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        try { $stream = $_.Exception.Response.GetResponseStream(); $reader = New-Object System.IO.StreamReader($stream); $body = $reader.ReadToEnd(); Write-Error "Response body:\n$body" } catch { Write-Warning "Could not read response body: $_" }
    }
    exit 2
}

function Recurse-Queries($node) {
    if ($null -ne $node) {
        if ($node -is [System.Collections.IEnumerable]) {
            foreach ($child in $node) { Recurse-Queries $child }
        }
        else {
            if ($node.name) { Write-Output "Query: $($node.name) (id: $($node.id))" }
            if ($node.hasChildren -and $node.children) { Recurse-Queries $node.children }
        }
    }
}

Recurse-Queries $resp

if ($Name) {
    $foundMatches = @()
    function Search-Node($node) {
        if ($null -eq $node) { return }
        if ($node -is [System.Collections.IEnumerable]) { foreach ($n in $node) { Search-Node $n } }
        else {
            if ($node.name -and $node.name -eq $Name) { $foundMatches += $node }
            if ($node.children) { Search-Node $node.children }
        }
    }
    Search-Node $resp
    if ($foundMatches.Count -eq 0) { Write-Output "No saved query named '$Name' found." }
    else { $foundMatches | ForEach-Object { $_ | ConvertTo-Json -Depth 6 } }
}
