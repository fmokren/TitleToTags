<#
.SYNOPSIS
    Create Bug work items in Azure DevOps and a saved query that selects them.

USAGE
  Set ADO_PAT env var (or pass a different env var name) and run:
    pwsh ./create_testdata.ps1 -OrganizationUrl 'https://dev.azure.com/yourOrg' -Project 'YourProject' -Count 5

#>

param(
    [Parameter(Mandatory = $true)] [string]$OrganizationUrl,
    [Parameter(Mandatory = $true)] [string]$Project,
    [Parameter(Mandatory = $false)] [string]$PatEnvVarName = 'ADO_PAT',
    [Parameter(Mandatory = $false)] [string]$OutputFile = '.testdata/testdata.json',
    [Parameter(Mandatory = $false)] [string]$SavedQueryName,
    [Parameter(Mandatory = $false)] [string]$AreaPath = 'ADOTestProject',
    [Parameter(Mandatory = $false)] [string]$IterationPath = 'ADOTestProject',
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

# Shared token used to tag created work items so tests can find them
$token = "TitleToTagsTest"
if (-not $SavedQueryName) { $SavedQueryName = "TitleToTags Test Data $($token)" }


# Load shared title patterns (function Get-TestDataPatterns)
. (Join-Path -Path $PSScriptRoot -ChildPath 'testdata_patterns.ps1')
$titlePatterns = Get-TestDataPatterns


# Track created items along with the pattern used so verification can assert per-item expectations
$createdItems = @()
for ($i = 1; $i -le $titlePatterns.Count; $i++) {
    # Pick a pattern for this iteration.  Cycle through the patterns if more items are requested
    $patternIndex = ($i - 1) % $titlePatterns.Count
    $title = $titlePatterns[$patternIndex].Title
   
    # Build the work item create URI using an encoded work item type (avoid embedding raw control characters)
    $type = '$Bug'
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
                    # Capture created id and associate with the pattern used
                    $entry = [PSCustomObject]@{
                        Id            = $respObj.id
                        PatternIndex  = $patternIndex
                        PatternTitle  = $titlePatterns[$patternIndex].Title
                        ExpectedTags  = $titlePatterns[$patternIndex].ExpectedTags
                        ExpectedTitle = $titlePatterns[$patternIndex].ExpectedTitle
                    }
                    $createdItems += $entry
                    Write-Output "  Created ID: $($respObj.id) (pattern #$patternIndex)"
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

if ($createdItems.Count -eq 0) { Write-Warning 'No work items created; aborting saved query creation.'; exit 0 }

# Build WIQL to find these created items
$wiql = "Select [System.Id] From WorkItems Where [System.TeamProject] = '$Project' And [System.WorkItemType] = 'Bug' And [System.Tags] Contains '$token'"

# Create saved query (include explicit columns so the query displays the fields we want)
$queryUri = "${OrganizationUrl}/${Project}/_apis/wit/queries/My%20Queries?api-version=7.1-preview.2"

# Columns to display in the saved query
$columns = @(
    @{ referenceName = 'System.Id' },
    @{ referenceName = 'System.Title' },
    @{ referenceName = 'System.Tags' }
)

$qBody = @{ name = $SavedQueryName; wiql = $wiql; isPublic = $true; columns = $columns } | ConvertTo-Json -Depth 4
# Initialize queryId so we always have a defined value even if create/update fails
$queryId = $null

# First check if a query with this name already exists; if so, then get the query id and add to the metadata
# so cleanup can delete it. If it exists, we will attempt to update it instead of creating a duplicate.
try {
    $listUri = "${OrganizationUrl}/${Project}/_apis/wit/queries/My%20Queries/${SavedQueryName}?`$depth=2&api-version=7.1-preview.2"
    $searchResponse = Invoke-RestMethod -Method Get -Uri $listUri -Headers $headers -ErrorAction Stop

    if ($searchResponse -and $searchResponse.id) 
    {
        $queryId = $searchResponse.id
    }
}
catch {
    Write-Warning "Failed to update existing saved query: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        try { $body = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult(); Write-Warning "Response body: $body" } catch { }
    }
}
    
if ($null -eq $queryId) {
    Write-Output "Creating saved query: $SavedQueryName"
    if ($WhatIf) { Write-Output "WhatIf: POST $queryUri with $qBody" }
    else {
        try {
            # Use Invoke-WebRequest so we can always access raw response content on failure
            $webResp = Invoke-WebRequest -Method Post -Uri $queryUri -Headers $headers -Body $qBody -ContentType 'application/json' -ErrorAction Stop
            $respContent = $webResp.Content
            if ($webResp.StatusCode -ge 200 -and $webResp.StatusCode -lt 300) {
                try {
                    $qresp = $respContent | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $qresp.id) {
                        $queryId = $qresp.id
                        Write-Output "  Saved query id: $queryId"
                    }
                    else {
                        Write-Warning "Saved query response JSON did not include 'id'. Response: $respContent"
                        $queryId = $null
                    }
                }
                catch {
                    Write-Warning "Saved query created but response was not valid JSON: $($_.Exception.Message)"
                    Write-Output "Response content:\n$respContent"
                    $queryId = $null
                }
            }
            else {
                Write-Warning "Saved query POST returned status $($webResp.StatusCode): $($webResp.StatusDescription)"
                Write-Output "Response content:\n$respContent"
                $queryId = $null
            }
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Warning "Failed to create saved query: $errMsg"
            # Try to read the response body if available
            if ($_.Exception.Response) {
                try {
                    $resp = $_.Exception.Response
                    if ($resp -and $resp.Content) {
                        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        Write-Warning "Response body: $body"
                    }
                }
                catch {
                    Write-Warning "Failed to read exception response body: $_"
                }
            }

            # If the error indicates a duplicate name, attempt to find the existing query and update it
            if ($errMsg -match 'TF237018' -or $errMsg -match 'same name') {
                Write-Output "Detected duplicate-name error; attempting to find existing saved query named '$SavedQueryName' and update it."
                try {
                    $listUri = "${OrganizationUrl}/${Project}/_apis/wit/queries?`$depth=2&api-version=7.1-preview.2"
                    $listResp = Invoke-RestMethod -Method Get -Uri $listUri -Headers $headers -ErrorAction Stop

                    # Recursive search for node by name
                    function Find-QueryNode($node, $name) {
                        if ($null -eq $node) { return $null }
                        if ($node -is [System.Collections.IEnumerable]) {
                            foreach ($n in $node) {
                                $found = Find-QueryNode $n $name
                                if ($found) { return $found }
                            }
                            return $null
                        }
                        else {
                            if ($node.name -and $node.name -eq $name) { return $node }
                            if ($node.children) { return Find-QueryNode $node.children $name }
                            return $null
                        }
                    }

                    $existing = Find-QueryNode $listResp $SavedQueryName
                    if ($existing -and $existing.id) {
                        $existingId = $existing.id
                        Write-Output "Found existing query id: $existingId. Attempting to update its WIQL and columns."

                        $updateUri = "${OrganizationUrl}/${Project}/_apis/wit/queries/$existingId?api-version=7.1-preview.2"
                        $uBody = @{ id = $existingId; name = $SavedQueryName; wiql = $wiql; isPublic = $true; columns = $columns } | ConvertTo-Json -Depth 6
                        try {
                            $updateResp = Invoke-RestMethod -Method Patch -Uri $updateUri -Headers $headers -Body $uBody -ContentType 'application/json' -ErrorAction Stop
                            if ($null -ne $updateResp.id) {
                                $queryId = $updateResp.id
                                Write-Output "  Updated saved query id: $queryId"
                            }
                            else {
                                Write-Warning "Update returned but no id found in response. Response: $($updateResp | ConvertTo-Json -Depth 6)"
                            }
                        }
                        catch {
                            Write-Warning "Failed to update existing saved query: $($_.Exception.Message)"
                            if ($_.Exception.Response) {
                                try { $body = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult(); Write-Warning "Response body: $body" } catch { }
                            }
                        }
                    }
                    else {
                        Write-Warning "Could not locate existing saved query named '$SavedQueryName' to update."
                    }
                }
                catch {
                    Write-Warning "Failed to list or search saved queries: $($_.Exception.Message)"
                }
            }

            $queryId = $queryId
        }
    }
}

# Save metadata for cleanup
# Save metadata for cleanup and verification; include per-item mapping
$meta = @{ Token = $token; SavedQueryId = $queryId; SavedQueryName = $SavedQueryName; Items = $createdItems }
$meta | ConvertTo-Json -Depth 6 | Out-File -FilePath $OutputFile -Encoding utf8
Write-Output "Wrote metadata to $OutputFile"
