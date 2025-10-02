TitleToTags
=================

PowerShell script to read Azure DevOps bugs, extract bracketed substrings from titles, add them as tags, and remove them from the title.

Prerequisites
- PowerShell 7+ (pwsh)
- ADO Personal Access Token (PAT) with Work Item read/write scope. Store it in environment variable ADO_PAT.

Usage

```powershell
$env:ADO_PAT = 'your_pat_here'
pwsh ./TitleToTags.ps1 -OrganizationUrl 'https://dev.azure.com/yourOrg' -Project 'YourProject' -WhatIf
```

Remove -WhatIf to perform updates.

Saved query usage

You can reference a saved query by id or by path. Examples:

```powershell
# By saved query id
pwsh ./TitleToTags.ps1 -OrganizationUrl 'https://dev.azure.com/yourOrg' -Project 'YourProject' -SavedQueryId 'f1a2b3c4-...' -WhatIf

# By path within the project e.g. '\Shared Queries\My Bugs'
pwsh ./TitleToTags.ps1 -OrganizationUrl 'https://dev.azure.com/yourOrg' -Project 'YourProject' -SavedQueryPath '\Shared Queries\My Bugs' -WhatIf
```

Tests

Install Pester (if you don't have it) and run:

```powershell
Install-Module -Name Pester -Scope CurrentUser -Force
Invoke-Pester -Path ./tests

Creating and cleaning test data

Two helper scripts are included to create sample Test Case work items and a saved query, and to clean them up afterwards.

1. Create sample data

```powershell
$env:ADO_PAT = 'your_pat_here'
pwsh ./create_testdata.ps1 -OrganizationUrl 'https://dev.azure.com/yourOrg' -Project 'YourProject' -Count 5
```

This creates Bug work items whose Title starts with a generated token and writes metadata to `.testdata/testdata.json` (token, created IDs, saved query id).

2. Cleanup

```powershell
pwsh ./cleanup_testdata.ps1 -OrganizationUrl 'https://dev.azure.com/yourOrg' -Project 'YourProject' -MetadataFile .testdata/testdata.json
```

Both scripts have a `-WhatIf` flag so you can preview the actions before they are executed.

```
