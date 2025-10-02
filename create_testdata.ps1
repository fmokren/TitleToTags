<#
.SYNOPSIS
    Create Bug work items in Azure DevOps and a saved query that selects them.

USAGE
  Set ADO_PAT env var (or pass a different env var name) and run:
    pwsh ./create_testdata.ps1 -OrganizationUrl 'https://dev.azure.com/yourOrg' -Project 'YourProject' -Count 5

#>

param(
    [Parameter(Mandatory=$true)] [string]$OrganizationUrl,
    [Parameter(Mandatory=$true)] [string]$Project,
    [Parameter(Mandatory=$false)] [int]$Count = 5,
    [Parameter(Mandatory=$false)] [string]$PatEnvVarName = 'ADO_PAT',
    [Parameter(Mandatory=$false)] [string]$OutputFile = '.testdata/testdata.json',
    [Parameter(Mandatory=$false)] [string]$SavedQueryName,
    [Parameter(Mandatory=$false)] [string]$AreaPath = 'ADOTestProject',
    [Parameter(Mandatory=$false)] [string]$IterationPath = 'ADOTestProject',
    [switch]$WhatIf
)

Set-StrictMode -Version Latest

# Dot-source module helpers
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'TitleToTags.psm1'
if (-not (Test-Path $modulePath)) { Write-Error "Module not found at $modulePath"; exit 1 }
Import-Module -Name $modulePath -Force

$pat = [Environment]::GetEnvironmentVariable($PatEnvVarName)
if (-not $pat) { Write-Error "PAT not found in environment variable $PatEnvVarName. Set it and re-run."; exit 1 }
$headers = Get-AuthHeader -pat $pat

# Ensure output dir
$outDir = Split-Path -Path $OutputFile -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$token = "TitleToTagsTest"
if (-not $SavedQueryName) { $SavedQueryName = "TitleToTags Test Data $($token)" }

$created = @()
for ($i = 1; $i -le $Count; $i++) {
    $title = "${token} - Bug #$i"
    # Build the work item create URI using an encoded work item type (avoid embedding raw control characters)
    $type = '$Bug'
    $encodedType = [uri]::EscapeDataString($type)
    $uri = "${OrganizationUrl}/${Project}/_apis/wit/workitems/${type}?api-version=7.1-preview.3"

    $ops = @()
    $ops += @{ op = 'add'; path = '/fields/System.Title'; value = $title }
    $ops += @{ op = 'add'; path = '/fields/System.Tags'; value = $token }
    if ($AreaPath) { $ops += @{ op = 'add'; path = '/fields/System.AreaPath'; value = $AreaPath } }
    if ($IterationPath) { $ops += @{ op = 'add'; path = '/fields/System.IterationPath'; value = $IterationPath } }

    $body = $ops | ConvertTo-Json -Depth 4
    Write-Output "Creating Test Case: $title"
    Write-Verbose "POST $uri"
    Write-Verbose "Body: $body"
    if ($WhatIf) { Write-Output "WhatIf: POST $uri with $body"; continue }

    try {
        # Use Invoke-WebRequest to capture raw content and headers when server returns non-JSON (like HTML error pages)
        $webResp = Invoke-WebRequest -Method Post -Uri $uri -Headers $headers -ContentType 'application/json-patch+json' -Body $body -ErrorAction Stop

        $contentType = $null
        if ($webResp.Headers -and $webResp.Headers.'Content-Type') { $contentType = $webResp.Headers.'Content-Type' }
        elseif ($webResp.ContentType) { $contentType = $webResp.ContentType }

        $content = $webResp.Content
        if ($contentType -and $contentType -match 'json') {
            try {
                $respObj = $content | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $respObj.id) {
                    $created += $respObj.id
                    Write-Output "  Created ID: $($respObj.id)"
                    Write-Verbose "Full response: $($respObj | ConvertTo-Json -Depth 6)"
                }
                else {
                    Write-Warning "Create returned JSON but no 'id' field. Response: $content"
                }
            }
            catch {
                Write-Warning "Failed to parse JSON response: $($_)"
                Write-Warning "Response content: $content"
            }
        }
        else {
            # Print HTML or other non-JSON responses directly for inspection
            Write-Output "--- Non-JSON response (content-type: $contentType) ---"
            Write-Output $content
            Write-Output "--- End of response ---"
        }
    }
    catch {
        # Generic catch: try to show as much information as possible
        Write-Warning "Failed to create item: $($_.Exception.Message)"
        if ($_.Exception -and $_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $respBody = $reader.ReadToEnd()
                # Print the response body to stdout for debugging (HTML etc.)
                Write-Output "--- Exception response body ---"
                Write-Output $respBody
                Write-Output "--- End of exception response ---"
            }
            catch {
                Write-Warning "Failed to read response body: $_"
            }
        }
        else {
            Write-Warning "Full exception: $($_ | Out-String)"
        }
    }
}

if ($created.Count -eq 0) { Write-Warning 'No work items created; aborting saved query creation.'; exit 0 }

# Build WIQL to find these created items
$wiql = "Select [System.Id] From WorkItems Where [System.TeamProject] = '$Project' And [System.WorkItemType] = 'Bug' And [System.Title] Contains '$token'"

# Create saved query
$queryUri = "${OrganizationUrl}/${Project}/_apis/wit/queries/My%20Queries?api-version=7.1-preview.2"
$qBody = @{ name = $SavedQueryName; wiql = $wiql; isPublic = $true } | ConvertTo-Json
Write-Output "Creating saved query: $SavedQueryName"
if ($WhatIf) { Write-Output "WhatIf: POST $queryUri with $qBody" }
else {
    try {
        $qresp = Invoke-RestMethod -Method Post -Uri $queryUri -Headers $headers -Body $qBody -ContentType 'application/json' -ErrorAction Stop
        $queryId = $qresp.id
        Write-Output "  Saved query id: $queryId"
    }
    catch {
        Write-Warning "Failed to create saved query: $($_.Exception.Message)"
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $respBody = $reader.ReadToEnd()
                Write-Warning "Response body: $respBody"
            }
            catch {
                Write-Warning "Failed to read response body: $_"
            }
        }
        $queryId = $null
    }
}

# Save metadata for cleanup
$meta = @{ Token = $token; SavedQueryId = $queryId; SavedQueryName = $SavedQueryName }
$meta | ConvertTo-Json | Out-File -FilePath $OutputFile -Encoding utf8
Write-Output "Wrote metadata to $OutputFile"
