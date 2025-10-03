<#
.SYNOPSIS
  Clean up test work items and saved query created by create_testdata.ps1

USAGE
  pwsh ./cleanup_testdata.ps1 -OrganizationUrl 'https://dev.azure.com/yourOrg' -Project 'YourProject' -MetadataFile .testdata/testdata.json

#>

param(
    [Parameter(Mandatory=$true)] [string]$OrganizationUrl,
    [Parameter(Mandatory=$true)] [string]$Project,
    [Parameter(Mandatory=$false)] [string]$PatEnvVarName = 'TEST_PAT',
    [Parameter(Mandatory=$false)] [string]$MetadataFile = '.testdata/testdata.json',
    [switch]$WhatIf,
    [switch]$KeepQuery
)

Set-StrictMode -Version Latest

# Dot-source module helpers
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'TitleToTags.psm1'
if (-not (Test-Path $modulePath)) { Write-Error "Module not found at $modulePath"; exit 1 }
Import-Module -Name $modulePath -Force

$pat = [Environment]::GetEnvironmentVariable($PatEnvVarName)
if (-not $pat) { Write-Error "PAT not found in environment variable $PatEnvVarName. Set it and re-run."; exit 1 }
$headers = Get-AuthHeader -pat $pat

if (-not (Test-Path $MetadataFile)) { Write-Error "Metadata file not found: $MetadataFile"; exit 1 }
$meta = Get-Content -Path $MetadataFile -Raw | ConvertFrom-Json

if ($meta.SavedQueryId -and -not $KeepQuery) {
    # Query ADO to confirm the saved query exists before attempting delete


    $qUri = "${OrganizationUrl}/${Project}/_apis/wit/queries/$($meta.SavedQueryId)?api-version=7.1-preview.2"

    Write-Output "Checking for saved query id: $($meta.SavedQueryId)"
    try {
        $resp = Invoke-RestMethod -Method Get -Uri $qUri -Headers $headers
        Write-Output "  Found saved query: $($resp.name)"
    }
    catch {
        Write-Warning "Saved query not found or failed to fetch: $_"
        $resp = $null
    }
    
    if (-not $resp) { Write-Output "No saved query to delete." }
    else {

        Write-Output "Deleting saved query id: $($meta.SavedQueryId)"
        if ($WhatIf) { Write-Output "WhatIf: DELETE $qUri" }
        else {
            try { Invoke-RestMethod -Method Delete -Uri $qUri -Headers $headers; Write-Output '  Deleted saved query' }
            catch { Write-Warning "Failed to delete saved query: $_" }
        }
    }
}

# Clean up created work items by querying all the bugs with the tag equal to token
if (-not $meta.Token) { Write-Error "No Token found in metadata file. Cannot identify work items to delete."; exit 1 }
$wiql = "Select [System.Id] From WorkItems Where [System.WorkItemType] = 'Bug' And [System.Tags] Contains '$($meta.Token)'"
Write-Output "Finding work items with tag '$($meta.Token)' to delete..."
$ids = Invoke-WiqlQuery -OrganizationUrl $OrganizationUrl -Project $Project -wiql $wiql -Headers $headers       

if ($ids -and $ids.Count -gt 0) {
    foreach ($id in $ids) {
        $wiUri = "${OrganizationUrl}/_apis/wit/workitems/${id}?api-version=7.1-preview.3"
        Write-Output "Deleting work item $id"
        if ($WhatIf) { Write-Output "WhatIf: DELETE $wiUri"; continue }
        try {
            # Azure DevOps doesn't fully 'delete' work items via REST easily; use Delete to remove permanently if available.
            Invoke-RestMethod -Method Delete -Uri $wiUri -Headers $headers
            Write-Output "  Deleted $id"
        }
        catch {
            Write-Warning "Failed to delete $id directly: $_ - attempting to set State to Removed"
            try {
                $ops = @(@{ op = 'add'; path = '/fields/System.State'; value = 'Removed' })
                $body = $ops | ConvertTo-Json -Depth 4
                Invoke-RestMethod -Method Patch -Uri $wiUri -Headers $headers -ContentType 'application/json-patch+json' -Body $body
                Write-Output "  Marked $id as Removed"
            }
            catch { Write-Warning "Also failed to mark removed: $_" }
        }
    }
}

Write-Output "Cleanup complete. Consider deleting $MetadataFile if no longer needed."
