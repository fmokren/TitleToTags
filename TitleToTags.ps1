<#
.SYNOPSIS
  Connects to Azure DevOps, finds bugs via WIQL (or a saved query), extracts bracketed tokens from titles,
  adds them as tags, removes the bracketed substrings from the title, and updates the work item.

USAGE
  - Set environment variable ADO_PAT to a Personal Access Token with Work Items (read/write) scope.
  - Run: pwsh ./TitleToTags.ps1 -OrganizationUrl "https://dev.azure.com/yourOrg" -Project "YourProject"

#>

param(
    [Parameter(Mandatory=$true)]
    [string]$OrganizationUrl,

    [Parameter(Mandatory=$true)]
    [string]$Project,

    [Parameter(Mandatory=$false)]
    [string]$Wiql = "Select [System.Id] From WorkItems Where [System.Work Item Type] = 'Bug' And [System.State] <> 'Closed'",

    [Parameter(Mandatory=$false)]
    [string]$SavedQueryId,

    [Parameter(Mandatory=$false)]
    [string]$SavedQueryPath,

    [Parameter(Mandatory=$false)]
    [string]$PatEnvVarName = 'ADO_PAT',

    [switch]$WhatIf
)

Set-StrictMode -Version Latest

# Dot-source the module
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'TitleToTags.psm1'
if (-not (Test-Path $modulePath)) { Write-Error "Module not found at $modulePath"; exit 1 }
Import-Module -Name $modulePath -Force

# Main
$pat = [Environment]::GetEnvironmentVariable($PatEnvVarName)
if (-not $pat) { Write-Error "PAT not found in environment variable $PatEnvVarName. Set it and re-run."; exit 1 }

$headers = Get-AuthHeader -pat $pat

if ($SavedQueryId -or $SavedQueryPath) {
  Write-Output "Resolving WIQL from saved query..."
  try {
    $Wiql = Get-WiqlFromSavedQuery -OrganizationUrl $OrganizationUrl -Project $Project -SavedQueryId $SavedQueryId -SavedQueryPath $SavedQueryPath -Headers $headers
  }
  catch {
    Write-Error "Failed to resolve saved query: $_"
    exit 1
  }
}

Write-Output "Running query to find bugs..."
$ids = Invoke-WiqlQuery -OrganizationUrl $OrganizationUrl -Project $Project -wiql $Wiql -Headers $headers

if (-not @($ids)) { Write-Output "No work items found."; exit 0 }

$items = Get-WorkItemsByIds -OrganizationUrl $OrganizationUrl -Ids $ids -Headers $headers

foreach ($it in $items) {
    $id = $it.fields.'System.Id'
    $title = $it.fields.'System.Title'
    $existingTags = $it.fields.'System.Tags'

    Write-Output "Processing #$($id): $($title)"
    $processed = Process-TitleToTags -title $title

    if ($processed.Tags.Count -eq 0) {
        Write-Verbose "No bracketed tokens found for $id. Skipping."
        continue
    }

    # Build new tags list
    $existing = @()
    if ($existingTags) {
        # Azure DevOps uses semicolon-delimited tags; split on ';' and trim
        $existing = $existingTags -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    }
    $toAdd = $processed.Tags | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    $merged = @($existing) + @($toAdd)
    $merged = $merged | ForEach-Object { $_ } | Select-Object -Unique

    $tagsString = ($merged -join '; ')

    Write-Output "  New tags: $($toAdd -join ', ')"
    Write-Output "  Resulting tags: $tagsString"
    Write-Output "  New title: $($processed.Title)"

    Update-WorkItem -Id $id -NewTitle $processed.Title -TagsString $tagsString -OrganizationUrl $OrganizationUrl -Headers $headers -WhatIf:$WhatIf
}
