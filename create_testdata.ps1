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


# Create a collection of title patterns to exercise different bracket scenarios.  Each entry
# corresponds to a distinct test case.  The ordering here intentionally covers:
#   1) No bracketed substrings
#   2) A single bracketed substring at the start
#   3) A single bracketed substring at the end
#   4) Two bracketed substrings within the title
#   5) Title composed exclusively of bracketed substrings
#   6) Mixed content with brackets at start and elsewhere
#   7) Adjacent bracketed substrings without separators
$titlePatterns = @(
    # 0. No bracketed substrings at all
    'No bracketed substrings in this title',
    # 1. Single bracketed substring at the start
    '[Single] bracketed substring at start of title',
    # 2. Single bracketed substring at the end
    'Title with bracketed substring at end [End]',
    # 3. Two bracketed substrings separated by text
    'Title with two bracketed substrings [One] [Two] at end',
    # 4. Only bracketed substrings; no other words
    '[All][Brackets][Only]',
    # 5. Bracket at the start and another later in the title
    '[First] Title begins with bracketed substring and also has [Second]',
    # 6. Two adjacent bracketed substrings at the start with no separator
    '[First][Second]Title begins with adjacent bracketed substrings'
    # 7. Title with a single bracketed substring at the beginning but the following text is lowercase
    '[start] title begins with lowercase text'
    # 8. Title with nested brackets (should be treated as literal)
    '[Outer [Inner]] Title with nested brackets'
    # 9. Title with empty brackets (should be ignored)
    'Title with empty brackets [] should ignore them'
    # 10. Title with brackets but no content (should be ignored)
    'Title with empty brackets [ ] should ignore them'
    # 11. Title with multiple spaces between words and brackets
    'Title   with    multiple   spaces  [Tag]  should   normalize'
)

$created = @()
for ($i = 1; $i -le $titlePatterns.Count; $i++) {
    # Pick a pattern for this iteration.  Cycle through the patterns if more items are requested
    $patternIndex = ($i - 1) % $titlePatterns.Count
    $pattern = $titlePatterns[$patternIndex]
    # Compose the full title.  Prefix with the token to allow easy selection and append a case number
    $title = $pattern
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
