<#
.SYNOPSIS
  End-to-end test harness: create test data, run TitleToTags, verify titles/tags, then cleanup.

USAGE
  pwsh ./e2e_test.ps1 -OrganizationUrl 'https://dev.azure.com/yourOrg' -Project 'YourProject'

#>

param(
    [Parameter(Mandatory=$true)][string]$OrganizationUrl,
    [Parameter(Mandatory=$true)][string]$Project,
    [Parameter(Mandatory=$false)][string]$PatEnvVarName = 'ADO_PAT',
    [Parameter(Mandatory=$false)][string]$MetadataFile = '.testdata/testdata.json',
    [switch]$WhatIf
)

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Import module helpers
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'TitleToTags.psm1'
if (-not (Test-Path $modulePath)) { Write-Error "Module not found at $modulePath"; exit 1 }
Import-Module -Name $modulePath -Force

# Helper to run a script and abort on failure (unless we continue deliberately)
function Invoke-ChildScript {
    param([string]$Path, [array]$ArgList)
    Write-Output "Running: $Path $($ArgList -join ' ')"
    & $Path @ArgList
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Warning "$Path exited with code $code"
    }
    return $code
}

# 1) Create test data
Write-Output "==> Step 1: Creating test data"
$createArgs = @(
    '-OrganizationUrl', $OrganizationUrl,
    '-Project', $Project,
    '-PatEnvVarName', $PatEnvVarName,
    '-OutputFile', $MetadataFile
)
if ($WhatIf) { $createArgs += '-WhatIf' }
$createCode = Invoke-ChildScript -Path (Join-Path $ScriptDir 'create_testdata.ps1') -ArgList $createArgs
if ($createCode -ne 0) { Write-Error "create_testdata.ps1 failed (exit $createCode)"; exit 2 }

# Load metadata
if (-not (Test-Path $MetadataFile)) { Write-Error "Metadata file missing: $MetadataFile"; exit 3 }
$meta = Get-Content -Path $MetadataFile -Raw | ConvertFrom-Json
if (-not $meta.Token) { Write-Error "Metadata token missing in $MetadataFile"; exit 4 }
$token = $meta.Token

# 2) Run the TitleToTags processor using saved query id if available
Write-Output "==> Step 2: Running TitleToTags"
$ttArgs = @(
    '-OrganizationUrl', $OrganizationUrl,
    '-Project', $Project,
    '-PatEnvVarName', $PatEnvVarName
)
if ($meta.SavedQueryId) { $ttArgs += @('-SavedQueryId', $meta.SavedQueryId) }
elseif ($meta.SavedQueryName) { $ttArgs += @('-SavedQueryPath', "My Queries/$($meta.SavedQueryName)") }
else { Write-Warning "No saved query info found in metadata; TitleToTags will run default WIQL." }
if ($WhatIf) { $ttArgs += '-WhatIf' }
$ttCode = Invoke-ChildScript -Path (Join-Path $ScriptDir 'TitleToTags.ps1') -ArgList $ttArgs
if ($ttCode -ne 0) { Write-Warning "TitleToTags returned non-zero exit code ($ttCode). Proceeding to verification anyway." }

# 3) Verify titles and tags
Write-Output "==> Step 3: Verification"
$pat = [Environment]::GetEnvironmentVariable($PatEnvVarName)
if (-not $pat) { Write-Error "PAT not found in environment variable $PatEnvVarName"; exit 5 }
$headers = Get-AuthHeader -pat $pat

$wiql = "Select [System.Id] From WorkItems Where [System.WorkItemType] = 'Bug' And [System.Tags] Contains '$token'"
$ids = Invoke-WiqlQuery -OrganizationUrl $OrganizationUrl -Project $Project -wiql $wiql -Headers $headers

if (-not $ids -or $ids.Count -eq 0) {
    Write-Warning "No work items found for token '$token' — verification cannot proceed."
    $verificationPassed = $false
}
else {
    $items = Get-WorkItemsByIds -OrganizationUrl $OrganizationUrl -Ids $ids -Headers $headers
    $failures = @()
    foreach ($it in $items) {
        $wiId = $it.fields.'System.Id'
        $title = $it.fields.'System.Title'
        $tags = $it.fields.'System.Tags'

        # 1) Title should not contain bracketed tokens
        if ($title -match '\[[^\]]+\]') { $failures += "WorkItem ${wiId}: Title still contains bracketed tokens: '$title'" }

        # 2) Tags should not contain bracket syntax
        if ($tags -and ($tags -match '\[[^\]]+\]')) { $failures += "WorkItem ${wiId}: Tags contain bracket syntax: '$tags'" }

        # 3) Must contain the test token tag
        if (-not ($tags -and ($tags -match [regex]::Escape($token)))) { $failures += "WorkItem ${wiId}: Missing token tag '$token' in tags: '$tags'" }
    }

    if ($failures.Count -eq 0) {
        Write-Output "Verification PASSED: all $($items.Count) work items have cleaned titles and expected tags."
        $verificationPassed = $true
    }
    else {
        Write-Output "Verification FAILED with $($failures.Count) problem(s):"
        $failures | ForEach-Object { Write-Output " - $_" }
        $verificationPassed = $false
    }
}

# 4) Cleanup test data
Write-Output "==> Step 4: Cleaning up test data"
$cleanupArgs = @(
    '-OrganizationUrl', $OrganizationUrl,
    '-Project', $Project,
    '-PatEnvVarName', $PatEnvVarName,
    '-MetadataFile', $MetadataFile
)
if ($WhatIf) { $cleanupArgs += '-WhatIf' }
$cleanCode = Run-Script -Path (Join-Path $PSScriptRoot 'cleanup_testdata.ps1') -Args $cleanupArgs
if ($cleanCode -ne 0) { Write-Warning "cleanup_testdata.ps1 returned code $cleanCode" }

if ($verificationPassed) { exit 0 } else { exit 6 }