<#
.SYNOPSIS
  End-to-end test harness: create test data, run TitleToTags, verify titles/tags, then cleanup.

USAGE
  pwsh ./e2e_test.ps1 -OrganizationUrl 'https://dev.azure.com/yourOrg' -Project 'YourProject'

#>

param(
    [Parameter(Mandatory = $true)][string]$OrganizationUrl,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $false)][string]$PatEnvVarName = 'TEST_PAT',
    [Parameter(Mandatory = $false)][string]$MetadataFile = '.testdata/testdata.json',
    [switch]$WhatIf
)

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Import module helpers
# Use ScriptDir consistently
$modulePath = Join-Path -Path $ScriptDir -ChildPath 'TitleToTags.psm1'
if (-not (Test-Path $modulePath)) { Write-Error "Module not found at $modulePath"; exit 1 }
Import-Module -Name $modulePath -Force

# Load shared test patterns (optional; used by verification logic)
. (Join-Path -Path $ScriptDir -ChildPath 'testdata_patterns.ps1')
 $titlePatterns = Get-TestDataPatterns

# Helper to run a script and abort on failure (unless we continue deliberately)
function Invoke-ChildScript {
    param([string]$Path, [object]$ArgList)

    if (-not (Test-Path $Path)) { Throw "Child script not found: $Path" }

    if ($null -eq $ArgList) { $ArgList = @{} }

    try {
        # Run the child script in a separate pwsh process so we can reliably capture
        # stdout/stderr and the exit code even if the child throws a terminating error.
        # Build the pwsh argument list (pwsh options first, then -File <script> followed by script params)
        $pwshArgs = @('-NoProfile','-NoLogo','-File',$Path)

        if ($ArgList -is [hashtable]) {
            Write-Host "Running: $Path with named params: $($ArgList.Keys -join ', ')"
            # Build a single command string so parameters that contain spaces are preserved
            $parts = @()
            foreach ($k in $ArgList.Keys) {
                $v = $ArgList[$k]
                if ($v -is [System.Management.Automation.SwitchParameter]) {
                    if ($v.IsPresent) { $parts += "-$k" }
                }
                else {
                    # Escape single quotes in the value by doubling them
                    $safe = $v.ToString() -replace "'","''"
                    $parts += "-$k '$safe'"
                }
            }
            $cmd = "& '$Path' $($parts -join ' ')"
        }
        elseif ($ArgList -ne $null) {
            $arr = @($ArgList)
            Write-Host "Running: $Path $($arr -join ' ')"
            $argsSafe = $arr | ForEach-Object { $_.ToString() -replace "'","''" }
            $cmd = "& '$Path' $($argsSafe -join ' ')"
        }
        else {
            $cmd = "& '$Path'"
        }

        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()
        $proc = Start-Process -FilePath pwsh -ArgumentList @('-NoProfile','-NoLogo','-Command',$cmd) -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -NoNewWindow -Wait -PassThru
    $childOutput = @()
    if (Test-Path $stdoutFile) { $childOutput += Get-Content $stdoutFile -ErrorAction SilentlyContinue }
    if (Test-Path $stderrFile) { $childOutput += Get-Content $stderrFile -ErrorAction SilentlyContinue }
    if ($childOutput) { foreach ($line in $childOutput) { Write-Host $line } }
    if ($proc) { $ret = $proc.ExitCode } else { $ret = 2 }
    Remove-Item $stdoutFile,$stderrFile -ErrorAction SilentlyContinue
    return $ret
    }
    catch {
        Write-Warning "Child script invocation failed: $($_.Exception.Message)"
        return 2
    }
}

# 1) Create test data
Write-Output "==> Step 1: Creating test data"
$createArgs = @{
    OrganizationUrl = $OrganizationUrl
    Project = $Project
    PatEnvVarName = $PatEnvVarName
    OutputFile = $MetadataFile
}
if ($WhatIf) { $createArgs.WhatIf = $true }
$createCode = Invoke-ChildScript -Path (Join-Path $ScriptDir 'create_testdata.ps1') -ArgList $createArgs
if ($createCode -ne 0) { Write-Error "create_testdata.ps1 failed (exit $createCode)"; exit 2 }

# Load metadata
if (-not (Test-Path $MetadataFile)) { Write-Error "Metadata file missing: $MetadataFile"; exit 3 }
$meta = Get-Content -Path $MetadataFile -Raw | ConvertFrom-Json
if (-not $meta.Token) { Write-Error "Metadata token missing in $MetadataFile"; exit 4 }
$token = $meta.Token

# 2) Run the TitleToTags processor using saved query id if available
Write-Output "==> Step 2: Running TitleToTags"
$ttArgs = @{
    OrganizationUrl = $OrganizationUrl
    Project = $Project
    PatEnvVarName = $PatEnvVarName
}
if ($meta.SavedQueryId) {
    $ttArgs.SavedQueryId = $meta.SavedQueryId
}
elseif ($meta.Items -and $meta.Items.Count -gt 0) {
    # If we have per-item metadata, build a WIQL that selects exactly those IDs. This
    # avoids races with other test runs or items that happen to share the token.
    $idsList = ($meta.Items | ForEach-Object { $_.Id }) -join ','
    $ttArgs.Wiql = "Select [System.Id] From WorkItems Where [System.TeamProject] = '$Project' And [System.Id] In ($idsList) Order By [System.Id]"
    Write-Verbose "Passing explicit WIQL to TitleToTags for IDs: $idsList"
}
else {
    # Prefer an explicit WIQL to avoid saved-query resolution differences in different orgs
    Write-Warning "SavedQueryId not present; passing explicit WIQL using token so TitleToTags can find created items."
    # Query by Tags (we tag created items with the token) so TitleToTags finds them reliably
    $ttArgs.Wiql = "Select [System.Id] From WorkItems Where [System.TeamProject] = '$Project' And [System.WorkItemType] = 'Bug' And [System.Tags] Contains '$token' Order By [System.Id]"
}

# If we provided an explicit WIQL (no saved query) wait briefly for the work items
# to become queryable. This reduces intermittent races against ADO's indexing.
if (-not $meta.SavedQueryId -and $ttArgs.Wiql) {
    $pat = [Environment]::GetEnvironmentVariable($PatEnvVarName)
    if (-not $pat) { Write-Warning "PAT not found; skipping WIQL polling." }
    else {
        $headers = Get-AuthHeader -pat $pat
        $checkWiql = "Select [System.Id] From WorkItems Where [System.TeamProject] = '$Project' And [System.WorkItemType] = 'Bug' And [System.Tags] Contains '$token'"
        $maxAttempts = 6
        $attempt = 0
        $found = $false
        while ($attempt -lt $maxAttempts -and -not $found) {
            $attempt++
            try {
                $ids = Invoke-WiqlQuery -OrganizationUrl $OrganizationUrl -Project $Project -wiql $checkWiql -Headers $headers
                if ($ids -and $ids.Count -gt 0) { $found = $true; break }
            }
            catch {
                Write-Verbose "WIQL check attempt $attempt failed: $($_.Exception.Message)"
            }
            if (-not $found) { Start-Sleep -Seconds 5 }
        }
        if (-not $found) { Write-Warning "WIQL polling did not observe created work items after $($maxAttempts * 5) seconds; proceeding anyway." }
        else { Write-Verbose "WIQL polling observed $($ids.Count) work items (attempt $attempt)." }
    }
}
if ($WhatIf) { $ttArgs.WhatIf = $true }
$ttCode = Invoke-ChildScript -Path (Join-Path $ScriptDir 'TitleToTags.ps1') -ArgList $ttArgs
if ($ttCode -ne 0) { Write-Warning "TitleToTags returned non-zero exit code ($ttCode). Proceeding to verification anyway." }

# 3) Verify titles and tags
Write-Output "==> Step 3: Verification"
$pat = [Environment]::GetEnvironmentVariable($PatEnvVarName)
if (-not $pat) { Write-Error "PAT not found in environment variable $PatEnvVarName"; exit 5 }
$headers = Get-AuthHeader -pat $pat

if ($meta.Items -and $meta.Items.Count -gt 0) {
    # We have per-item metadata from create_testdata; validate each created ID against expectations
    $failures = @()
    foreach ($entry in $meta.Items) {
        $id = $entry.Id
        $resp = Get-WorkItemsByIds -OrganizationUrl $OrganizationUrl -Ids @($id) -Headers $headers
        if (-not $resp -or $resp.Count -eq 0) {
            $failures += "WorkItem ${id}: could not fetch work item for verification"
            continue
        }
        $it = $resp[0]
        $wiId = $it.fields.'System.Id'
        $title = $it.fields.'System.Title'
        $tags = $it.fields.'System.Tags'

        # 1) Title should not contain bracketed tokens
        if ($title -match '\[[^\]]+\]') { $failures += "WorkItem $($wiId): Title still contains bracketed tokens: '$title'" }

        # 2) Tags should not contain bracket syntax
        if ($tags -and ($tags -match '\[[^\]]+\]')) { $failures += "WorkItem $($wiId): Tags contain bracket syntax: '$tags'" }

        # 3) Must contain the test token tag
        if (-not ($tags -and ($tags -match [regex]::Escape($token)))) { $failures += "WorkItem $($wiId): Missing token tag '$token' in tags: '$tags'" }

        # 4) Check expected tags from metadata (order-insensitive)
        $expected = @()
        if ($entry.ExpectedTags) { $expected += $entry.ExpectedTags }
        $actualTags = @()
        if ($tags) { $actualTags = @($tags -split ';|,') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } }

        # Remove the test token from actual tags (it is added at creation time)
        $tokenNormalized = $token.ToLower()
        $actualTagsExclToken = @($actualTags | Where-Object { $_ -and ($_.ToLower() -ne $tokenNormalized) })

        if ($actualTagsExclToken.Count -ne $expected.Count) {
            $failures += "WorkItem $($wiId): expected $($expected.Count) tags but found $($actualTagsExclToken.Count) (excluding token): expected='$($expected -join ',')' actual='$($actualTags -join ',')'"
        }

        # For robustness we treat expected tags as substrings: each expected tag must appear inside at least one actual tag (case-insensitive)
        foreach ($t in $expected) {
            $found = $false
            foreach ($a in $actualTagsExclToken) {
                if ($a -and $a.ToLower().Contains($t.ToLower())) { $found = $true; break }
            }
            if (-not $found) { $failures += "WorkItem $($wiId): missing expected tag '$t' (actual tags: '$($actualTags -join ',')')" }
        }

        # The title should be the same as the expected title.
        if ($title -ne $entry.ExpectedTitle) { $failures += "WorkItem $($wiId): normalized title '$title' does not match expected title '$($entry.ExpectedTitle)'" }
    }

    if ($failures.Count -eq 0) {
        Write-Output "Verification PASSED: all $($meta.Items.Count) created work items match expectations."
        $verificationPassed = $true
    }
    else {
        Write-Output "Verification FAILED with $($failures.Count) problem(s):"
        $failures | ForEach-Object { Write-Output " - $_" }
        $verificationPassed = $false
    }
}

else {
    # Fallback: query by token and perform a lightweight validation
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

            if ($title -match '\[[^\]]+\]') { $failures += "WorkItem $($wiId): Title still contains bracketed tokens: '$title'" }
            if ($tags -and ($tags -match '\[[^\]]+\]')) { $failures += "WorkItem $($wiId): Tags contain bracket syntax: '$tags'" }
            if (-not ($tags -and ($tags -match [regex]::Escape($token)))) { $failures += "WorkItem $($wiId): Missing token tag '$token' in tags: '$tags'" }
        }

        if ($failures.Count -eq 0) { $verificationPassed = $true } else { $verificationPassed = $false }
    }
}

# 4) Cleanup test data
Write-Output "==> Step 4: Cleaning up test data"
$cleanupArgs = @{
    OrganizationUrl = $OrganizationUrl
    Project = $Project
    PatEnvVarName = $PatEnvVarName
    MetadataFile = $MetadataFile
}
if ($WhatIf) { $cleanupArgs.WhatIf = $true }
$cleanCode = Invoke-ChildScript -Path (Join-Path $ScriptDir 'cleanup_testdata.ps1') -ArgList $cleanupArgs
if ($cleanCode -ne 0) { Write-Warning "cleanup_testdata.ps1 returned code $cleanCode" }

if ($verificationPassed) { exit 0 } else { exit 6 }