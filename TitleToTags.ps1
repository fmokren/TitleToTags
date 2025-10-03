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

  # Determine whether tags or title changed. Even if no tags were extracted, we may
  # need to update the title (for example to remove empty brackets like '[]' or '[ ]').
  $titleChanged = ($processed.Title -ne $title)

  # Build new tags list. Normalize processed.Tags to an array so property access is safe
  $tagsString = $null
  $toAdd = @()
  if ($processed.Tags) {
    # Ensure we treat Tags as an array even when a single string was returned
    $rawTags = @($processed.Tags)

  # Trim and drop empty tokens. Wrap in @() so result is always an array even for one item.
  $toAdd = @($rawTags | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' })

    if ($toAdd.Count -gt 0) {
      $existing = @()
      if ($existingTags) {
        # Azure DevOps uses semicolon-delimited tags; split on ';' and trim
        $existing = $existingTags -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
      }

      $merged = @($existing) + @($toAdd)
      $merged = $merged | ForEach-Object { $_ } | Select-Object -Unique

      $tagsString = ($merged -join '; ')
    }
  }

  if (-not $titleChanged -and (-not $tagsString)) {
    Write-Verbose "No bracketed tokens found and title unchanged for $id. Skipping."
    continue
  }

  if ($toAdd.Count -gt 0) { Write-Output "  New tags: $($toAdd -join ', ')" }
  if ($tagsString) { Write-Output "  Resulting tags: $tagsString" }
  Write-Output "  New title: $($processed.Title)"

  Update-WorkItem -Id $id -NewTitle $processed.Title -TagsString $tagsString -OrganizationUrl $OrganizationUrl -Headers $headers -WhatIf:$WhatIf
}
