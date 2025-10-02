Set-StrictMode -Version Latest

function Get-AuthHeader {
    param([string]$pat)
    $token = ":$pat"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($token)
    $base64 = [System.Convert]::ToBase64String($bytes)
    return @{ Authorization = "Basic $base64" }
}

function Invoke-WiqlQuery {
    param(
        [string]$OrganizationUrl,
        [string]$Project,
        [string]$wiql,
        [hashtable]$Headers
    )

    $uri = "${OrganizationUrl}/${Project}/_apis/wit/wiql?api-version=7.1-preview.2"
    $body = @{ query = $wiql } | ConvertTo-Json
    Write-Verbose "Running WIQL against $uri"
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $Headers -Body $body -ContentType 'application/json'
    return $resp.workItems | ForEach-Object { $_.id }
}

function Get-WiqlFromSavedQuery {
    param(
        [string]$OrganizationUrl,
        [string]$Project,
        [string]$SavedQueryId,
        [string]$SavedQueryPath,
        [hashtable]$Headers
    )

    if (-not $SavedQueryId -and -not $SavedQueryPath) {
        throw "Either SavedQueryId or SavedQueryPath must be provided."
    }

    if ($SavedQueryId) {
        $uri = "${OrganizationUrl}/${Project}/_apis/wit/queries/${SavedQueryId}?api-version=7.1-preview.2&%24expand=wiql"
        Write-Verbose "Fetching saved query by id: $SavedQueryId"
        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers
    }
    else {
        $encoded = [uri]::EscapeDataString($SavedQueryPath)
        $uri = "${OrganizationUrl}/${Project}/_apis/wit/queries?path=${encoded}&api-version=7.1-preview.2"
        Write-Verbose "Fetching saved query by path: $SavedQueryPath"
        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers
    }

    # Try common response shapes to find WIQL
    if ($null -ne $resp.wiql) { return $resp.wiql }
    if ($null -ne $resp.query -and $null -ne $resp.query.wiql) { return $resp.query.wiql }
    if ($null -ne $resp.value -and $resp.value.Count -gt 0) {
        $found = $resp.value | Where-Object { $_.wiql } | Select-Object -First 1
        if ($found) { return $found.wiql }
    }

    throw "Could not extract WIQL from saved query response. Response keys: $($resp | Get-Member -MemberType NoteProperty | ForEach-Object Name -join ', ')"
}

function Get-WorkItemsByIds {
    param(
        [string]$OrganizationUrl,
        [array]$Ids,
        [hashtable]$Headers
    )

    if (-not $Ids -or $Ids.Count -eq 0) { return @() }

    $batches = [System.Collections.ArrayList]::new()
    $max = 200
    for ($i=0; $i -lt $Ids.Count; $i += $max) {
        $slice = $Ids[$i..([math]::Min($i+$max-1, $Ids.Count-1))]
        $batches.Add($slice) > $null
    }

    $result = @()
    foreach ($batch in $batches) {
        $idList = ($batch -join ',')
        $fields = 'System.Id,System.Title,System.Tags'
        $uri = "${OrganizationUrl}/_apis/wit/workitems?ids=${idList}&fields=${fields}&api-version=7.1-preview.3"
        Write-Verbose "Fetching work items: $idList"
        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers
        $result += $resp.value
    }
    return $result
}

function Convert-TitleToTags {
    param(
        [string]$title
    )

    # Match bracketed tokens like [foo], [a b], [#123]
    $pattern = '\[([^\]]+)\]'
    $regexMatches = [regex]::Matches($title, $pattern)
    $tags = @()
    foreach ($m in $regexMatches) { $tags += $m.Groups[1].Value }

    # Remove the bracketed substrings from the title
    $newTitle = [regex]::Replace($title, $pattern, '')
    # Collapse multiple spaces and trim
    $newTitle = ($newTitle -replace '\s{2,}', ' ').Trim().TrimStart(':').Trim()

    if ($newTitle.Length -gt 0) {
        $newTitle = $newTitle.Substring(0,1).ToUpper() + $newTitle.Substring(1)
    }
    else {
        $newTitle = "Untitled Work Item"
    }

    return [pscustomobject]@{ Title = $newTitle; Tags = $tags }
}

function Update-WorkItem {
    param(
        [int]$Id,
        [string]$NewTitle,
        [string]$TagsString,
        [string]$OrganizationUrl,
        [hashtable]$Headers,
        [switch]$WhatIf
    )

    $uri = "${OrganizationUrl}/_apis/wit/workitems/${Id}?api-version=7.1-preview.3"

    $ops = @()
    if ($null -ne $NewTitle) {
        $ops += @{ op = 'add'; path = '/fields/System.Title'; value = $NewTitle }
    }
    if ($null -ne $TagsString) {
        $ops += @{ op = 'add'; path = '/fields/System.Tags'; value = $TagsString }
    }

    $body = $ops | ConvertTo-Json -Depth 4
    Write-Verbose ("Updating work item $Id title='$($NewTitle)' tags='$($TagsString)'")

    if ($WhatIf) {
        Write-Output "WhatIf: would PATCH $uri with: $body"
        return $true
    }

    $resp = Invoke-RestMethod -Method Patch -Uri $uri -Headers $Headers -ContentType 'application/json-patch+json' -Body $body
    return $resp
}

function Process-TitleToTags {
    param(
        [Parameter(Mandatory=$true)][string]$Title
    )

    # Reuse Convert-TitleToTags for parsing; normalize output to ensure Tags is an array
    $res = Convert-TitleToTags -title $Title
    if ($null -eq $res) { return [pscustomobject]@{ Title = $Title; Tags = @() } }
    if (-not $res.PSObject.Properties.Match('Tags').Count) { $res | Add-Member -NotePropertyName Tags -NotePropertyValue @() }
    if ($res.Tags -eq $null) { $res.Tags = @() }
    return $res
}

Export-ModuleMember -Function Get-AuthHeader,Invoke-WiqlQuery,Get-WorkItemsByIds,Convert-TitleToTags,Process-TitleToTags,Update-WorkItem,Get-WiqlFromSavedQuery
