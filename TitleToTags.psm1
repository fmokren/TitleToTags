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

    # Only extract bracketed tokens if they appear as consecutive groups at the
    # start of the title (ignoring leading whitespace). Nested brackets inside a
    # leading group are supported; tokens are returned in outer->inner order for
    # each group, and groups are returned left-to-right.
    $tokens = New-Object System.Collections.ArrayList
    $outChars = New-Object System.Text.StringBuilder

    if ($null -eq $title) { $title = '' }
    $s = [string]$title
    $n = $s.Length
    $i = 0

    # Skip leading whitespace when deciding whether brackets are at the beginning
    while ($i -lt $n -and [char]::IsWhiteSpace($s[$i])) { $i++ }

    $parsedLeading = $false
    if ($i -lt $n -and $s[$i] -eq '[') {
        $parsedLeading = $true
        while ($i -lt $n -and $s[$i] -eq '[') {
            # Parse a single bracket group (supports nested brackets).
            $groupTokens = New-Object System.Collections.ArrayList
            $stack = New-Object System.Collections.Stack
            $stack.Push('')
            # advance past '['
            $j = $i + 1
            while ($j -lt $n -and $stack.Count -gt 0) {
                $ch = $s[$j]
                if ($ch -eq '[') {
                    $stack.Push('')
                    $j++
                }
                elseif ($ch -eq ']') {
                    $buf = $stack.Pop()
                    if ($buf -ne $null) { $buf = $buf.ToString().Trim() }
                    if ($buf -and $buf.Length -gt 0) { [void]$groupTokens.Add($buf) }
                    $j++
                }
                else {
                    $top = $stack.Pop()
                    $top += $ch
                    $stack.Push($top)
                    $j++
                }
            }

            if ($stack.Count -gt 0) {
                # Unclosed bracket found – treat entire title as literal (no extraction)
                $parsedLeading = $false
                break
            }

            # groupTokens were collected in closing order (inner-first); reverse to
            # produce outer->inner order for this group
            if ($groupTokens.Count -gt 1) { [array]::Reverse($groupTokens) }
            foreach ($t in $groupTokens) { [void]$tokens.Add($t) }

            # Advance i to the character after this group
            $i = $j
            # Skip any whitespace between adjacent leading groups
            while ($i -lt $n -and [char]::IsWhiteSpace($s[$i])) { $i++ }
            # Continue if next char is another '['; otherwise stop parsing leading groups
        }
    }

    if (-not $parsedLeading) {
        # We did not parse leading bracket groups; output the original title intact
        $outChars.Append($s) | Out-Null
    }
    else {
        # Append the remainder of the string starting at current index
        if ($i -lt $n) {
            $outChars.Append($s.Substring($i)) | Out-Null
        }
    }

    # Normalize title by collapsing spaces and trimming
    $newTitle = ($outChars.ToString() -replace '\s{2,}', ' ').Trim().TrimStart(':').Trim()
    if ($newTitle.Length -gt 0) {
        $newTitle = $newTitle.Substring(0,1).ToUpper() + $newTitle.Substring(1)
    }
    else {
        $newTitle = "Untitled Work Item"
    }

    # Normalize tokens into a simple string array (trimmed, non-empty)
    $tagsArray = @()
    if ($tokens -and $tokens.Count -gt 0) {
        $tagsArray = $tokens | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' }
        $tagsArray = @($tagsArray)
    }

    return [pscustomobject]@{ Title = $newTitle; Tags = $tagsArray }
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

Export-ModuleMember -Function Get-AuthHeader,Invoke-WiqlQuery,Get-WorkItemsByIds,Convert-TitleToTags,Update-WorkItem,Get-WiqlFromSavedQuery
