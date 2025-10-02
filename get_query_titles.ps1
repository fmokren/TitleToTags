<#
.SYNOPSIS
    Get work item titles from an Azure DevOps query URL via REST.

.DESCRIPTION
    Given a dev.azure.com query URL (including tempQueryId or id), this script
    fetches the saved query (with WIQL), runs it, and prints the work item titles.

.EXAMPLE
    pwsh ./get_query_titles.ps1 -QueryUrl 'https://dev.azure.com/Org/Project/_queries/query/?tempQueryId=...' \
        -PatEnvVarName 'ADO_PAT'

    Ensure the PAT is exported in your shell, e.g. on macOS/zsh:
      export ADO_PAT=yourPAT

#>

param(
    [Parameter(Mandatory=$false)] [string]$QueryUrl,
    [Parameter(Mandatory=$false)] [string]$QueryId,
    [Parameter(Mandatory=$false)] [string]$Wiql,
    [Parameter(Mandatory=$false)] [string]$Organization,
    [Parameter(Mandatory=$false)] [string]$Project,
    [Parameter(Mandatory=$false)] [string]$PatEnvVarName = 'ADO_PAT'
)

# Short-circuit: if the user provided WIQL directly, use it. If they provided a QueryId, use it.
if (-not $Wiql -and -not $QueryId -and -not $QueryUrl) {
    Write-Error "You must provide one of -QueryUrl, -QueryId, or -Wiql."
    exit 1
}

Set-StrictMode -Version Latest

# Get PAT from environment
$pat = [Environment]::GetEnvironmentVariable($PatEnvVarName)
if (-not $pat) {
    Write-Error "PAT not found in environment variable '$PatEnvVarName'. Set it and re-run."
    exit 1
}
$auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{ Authorization = $auth; Accept = 'application/json' }

# If WIQL supplied directly, skip fetching
if ($Wiql) {
    $wiql = $Wiql
}
else {
    # If QueryId provided, we still need org/project. If QueryUrl provided parse org/project from URL
    if ($QueryId) 
    { 
        $queryId = $QueryId
        $org = $Organization
        $project = $Project 
    }
    elseif ($QueryUrl) {
        try { $uri = [uri]$QueryUrl } catch { Write-Error "Invalid QueryUrl: $_"; exit 1 }
        $pathSegments = $uri.AbsolutePath.Trim('/') -split '/'
        if ($pathSegments.Length -lt 2) { Write-Error "Unable to parse organization and project from URL path '$($uri.AbsolutePath)'"; exit 1 }
        $org = $pathSegments[0]
        $project = $pathSegments[1]
    }
    else {
        # QueryId provided without QueryUrl: user must provide Organization and Project via params
        if (-not $Organization -or -not $Project) {
            Write-Error "When using -QueryId or -Wiql without -QueryUrl you must pass -Organization and -Project parameters."
            exit 1
        }
        $org = $Organization
        $project = $Project
    }
}

# Parse query string parameters without System.Web (works cross-platform) only when QueryUrl provided
$qs = @{}
if ($QueryUrl) {
    if ($uri.Query) {
        $pairs = $uri.Query.TrimStart('?') -split '&' | Where-Object { $_ -ne '' }
        foreach ($p in $pairs) {
            if ($p -match '=') {
                $parts = $p.Split('=',2)
                $k = $parts[0]
                $v = [Uri]::UnescapeDataString($parts[1])
                $qs[$k] = $v
            }
            else {
                $qs[$p] = ''
            }
        }
    }

    # Try common param names for a query id (tempQueryId is used in the UI link)
    $queryId = $QueryId ?? $qs['tempQueryId'] ?? $qs['id'] ?? $qs['queryId']
        # If not present in parsed query string, try to extract from the raw URL with regex
        if (-not $queryId -and $QueryUrl) {
            $m = [Text.RegularExpressions.Regex]::Match($QueryUrl, '(?:tempQueryId|id|queryId)=([^&\s]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) { $queryId = [Uri]::UnescapeDataString($m.Groups[1].Value) }
            else {
                # fallback: look for a GUID in the path under /queries or /query
                $m2 = [Text.RegularExpressions.Regex]::Match($QueryUrl, '/queries?/([0-9a-fA-F\-]{36})')
                if ($m2.Success) { $queryId = $m2.Groups[1].Value }
            }
        }

        if (-not $queryId) {
            Write-Error "No query id found in the URL. Provide a URL containing 'tempQueryId' or 'id', or pass -QueryId." 
            Write-Error "Original QueryUrl: $QueryUrl"
            exit 1
        }
}

$apiVersion = '7.1-preview.2'

# Try multiple ways to fetch the query resource. The browser UI sometimes uses a temporary query id
# (tempQueryId) which may not resolve with the direct queries/{id} path. Try both forms and handle
# responses that may return an object or a 'value' array.
$tried = @()
$qresp = $null
$tryUris = @(
    "https://dev.azure.com/$org/$project/_apis/wit/queries/${queryId}?api-version=$apiVersion&%24expand=wiql",
    "https://dev.azure.com/$org/$project/_apis/wit/queries?tempQueryId=${queryId}&api-version=$apiVersion&%24expand=wiql"
)

foreach ($u in $tryUris) {
    $tried += $u
    try {
        $resp = Invoke-RestMethod -Method Get -Uri $u -Headers $headers -ErrorAction Stop
        if ($resp) { $qresp = $resp; break }
    }
    catch {
        # If 404, keep trying other forms; otherwise capture and show body for debugging
        $err = $_
        if ($err.Exception -and $err.Exception.Response) {
            try {
                $respObj = $err.Exception.Response
                $body = $null
                # Some platforms return System.Net.WebResponse with GetResponseStream(), others return HttpResponseMessage
                if ($respObj -is [System.Net.WebResponse]) {
                    $stream = $respObj.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                }
                elseif ($respObj -is [System.Net.Http.HttpResponseMessage]) {
                    $body = $respObj.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                }
                else {
                    # Fallback: try to call Content.ReadAsStringAsync if present
                    if ($respObj.PSObject.Properties['Content']) {
                        try { $body = $respObj.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch {}
                    }
                }

                Write-Verbose "Request to $u failed: $($err.Exception.Message)"
                if ($body) { Write-Verbose "Response body: $body" }
            }
            catch {
                Write-Verbose "Failed to read response body for $($u): $($_)"
            }
        }
        else {
            Write-Verbose "Request to $u failed: $($err.Exception.Message)"
        }
        continue
    }
}

if (-not $qresp) {
    Write-Verbose "Failed to fetch query resource via direct queries API; will continue to recursive list and HTML fallbacks."
    Write-Verbose "Tried URIs:`n$($tried -join "`n")"
}

# Normalise possible response shapes: single object with wiql, or a 'value' array
Write-Verbose "Fetched query resource: $($qresp | ConvertTo-Json -Depth 6)"
# Safely check for 'wiql' property to avoid PropertyNotFoundException on some response shapes
$wiql = $null
if ($qresp -and $qresp.PSObject.Properties.Match('wiql').Count -gt 0) { $wiql = $qresp.wiql }
elseif ($qresp -and $qresp.value -and $qresp.value.Count -gt 0 -and $qresp.value[0].PSObject.Properties.Match('wiql').Count -gt 0) {
    $wiql = $qresp.value[0].wiql
}

# If we still don't have WIQL, attempt a deeper query list traversal to find a node with the matching id
if (-not $wiql) {
    Write-Verbose "WIQL not found in initial query resource; attempting recursive query-list lookup (depth=5)."
    $listUri = "https://dev.azure.com/$org/$project/_apis/wit/queries?api-version=$apiVersion&%24depth=5"
    try {
        $listResp = Invoke-RestMethod -Method Get -Uri $listUri -Headers $headers -ErrorAction Stop
    }
    catch {
        Write-Verbose "Failed to list queries for recursive lookup (will try HTML fallback): $($_.Exception.Message)"
        $listResp = $null
    }

    # Recursive search function: looks for node with matching id and returns it
    function Find-QueryNode($node, $idToFind) {
        if (-not $node) { return $null }
        if ($node.id -and ($node.id -ieq $idToFind)) { return $node }
        if ($node.children) {
            foreach ($child in $node.children) {
                $found = Find-QueryNode $child $idToFind
                if ($found) { return $found }
            }
        }
        return $null
    }

    $foundNode = $null
    if ($listResp.value) {
        foreach ($root in $listResp.value) {
            $foundNode = Find-QueryNode $root $queryId
            if ($foundNode) { break }
        }
    }

    if ($foundNode -and $foundNode.PSObject.Properties.Match('wiql').Count -gt 0) {
        $wiql = $foundNode.wiql
        Write-Verbose "Found WIQL in recursive lookup for id $queryId"
    }
    else {
        Write-Verbose "Unable to locate WIQL for query id $queryId after recursive lookup; will attempt HTML fallback."
        Write-Verbose "Top-level query-list response: $($listResp | ConvertTo-Json -Depth 6)"
        # do not exit here; allow later HTML-scrape fallback to run
    }
}
if (-not $wiql) {
    Write-Verbose "The query resource did not contain a 'wiql' property. Attempting HTML scrape of the QueryUrl as a fallback."
        try {
            $page = Invoke-WebRequest -Method Get -Uri $QueryUrl -Headers $headers -ErrorAction Stop
            $html = $page.Content
            # Try to extract an embedded JSON property containing the WIQL (handles various property names).
            $patterns = @(
                '"wiql"\s*:\s*"(?<w>(?:\\.|[^"\\])*)"',
                '"queryText"\s*:\s*"(?<w>(?:\\.|[^"\\])*)"',
                '"wiqlText"\s*:\s*"(?<w>(?:\\.|[^"\\])*)"',
                '"query"\s*:\s*\{(?<obj>.*?)\}',
                '"workItemQuery"\s*:\s*\{(?<obj>.*?)\}'
            )
            $found = $false
            foreach ($pat in $patterns) {
                $m = [Text.RegularExpressions.Regex]::Match($html, $pat, [Text.RegularExpressions.RegexOptions]::Singleline)
                if ($m.Success) {
                    if ($m.Groups['w'] -and $m.Groups['w'].Value) {
                        $wiqlEsc = $m.Groups['w'].Value
                        # Build a tiny JSON wrapper to leverage ConvertFrom-Json to unescape properly
                        $jsonWrap = "{`"w`":`"$wiqlEsc`"}"
                        try {
                            $obj = $jsonWrap | ConvertFrom-Json -ErrorAction Stop
                            $wiql = $obj.w
                        }
                        catch {
                            # fallback to basic unescape
                            $wiql = $wiqlEsc.Replace('\"','"')
                        }
                        $found = $true
                        break
                    }
                    elseif ($m.Groups['obj'] -and $m.Groups['obj'].Value) {
                        $objText = '{' + $m.Groups['obj'].Value + '}'
                        try {
                            $parsed = $objText | ConvertFrom-Json -ErrorAction Stop
                            if ($parsed.wiql) { $wiql = $parsed.wiql; $found = $true; break }
                            if ($parsed.queryText) { $wiql = $parsed.queryText; $found = $true; break }
                        }
                        catch {
                            # ignore parse errors and continue
                        }
                    }
                }
            }
            if ($found -and $wiql) {
                Write-Verbose "Extracted WIQL via HTML scrape."
            }
            else {
                Write-Verbose "HTML scrape did not find a 'wiql' property. Dumping small portion for inspection..."
                $snippet = if ($html.Length -gt 2000) { $html.Substring(0,2000) } else { $html }
                Write-Verbose $snippet
                Write-Error "Unable to locate WIQL for query id $queryId. Raw response: $($qresp | ConvertTo-Json -Depth 4)"
                exit 1
            }
        }
        catch {
            $msg = $_.Exception.Message
            Write-Error "Failed to fetch/parse QueryUrl HTML for WIQL fallback: $msg"
            if ($msg -match '401|Unauthorized|403|Forbidden') {
                Write-Error "The QueryUrl appears to require browser authentication (cookies/SSO)."
                Write-Error "Options: 1) Run the script with -Wiql or -QueryId and -Organization/-Project, 2) provide a PAT with sufficient scope in env var, or 3) run interactively in a session that has cookies (not implemented)."
            }
            Write-Verbose "Raw query resource: $($qresp | ConvertTo-Json -Depth 4)"
            exit 1
        }
    }

# Run the WIQL to get matching work item ids
$wiqlUri = "https://dev.azure.com/$org/$project/_apis/wit/wiql?api-version=$apiVersion"
if ([string]::IsNullOrWhiteSpace($wiql)) {
    Write-Error "WIQL is empty or could not be located for query id $queryId. Aborting."
    Write-Error "Provide a saved query id that exposes WIQL via the REST API or pass WIQL directly."
    exit 1
}
$body = @{ query = $wiql } | ConvertTo-Json
try {
    $wiqlResp = Invoke-RestMethod -Method Post -Uri $wiqlUri -Headers $headers -Body $body -ContentType 'application/json' -ErrorAction Stop
}
catch {
    Write-Error "Failed to run WIQL: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        try {
            $respObj = $_.Exception.Response
            $respBody = $null
            if ($respObj -is [System.Net.WebResponse]) {
                $stream = $respObj.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $respBody = $reader.ReadToEnd()
            }
            elseif ($respObj -is [System.Net.Http.HttpResponseMessage]) {
                $respBody = $respObj.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
            if ($respBody) { Write-Verbose "WIQL POST response body: $respBody" }
        }
        catch {
            Write-Verbose "Failed to read WIQL POST response body: $_"
        }
    }
    exit 1
}

# Extract ids (WIQL returns workItems array of objects {id, url})
$ids = @()
if ($wiqlResp.workItems) {
    $ids = $wiqlResp.workItems | ForEach-Object { $_.id }
}

if (-not $ids -or $ids.Count -eq 0) {
    Write-Output "Query returned no work items."
    exit 0
}

# Fetch work items in batch, requesting only System.Title
$idsParam = [string]::Join(',', $ids)
$workApiVersion = '7.1-preview.3'
$workUri = "https://dev.azure.com/$org/_apis/wit/workitems?ids=$idsParam&api-version=$workApiVersion&%24fields=System.Title"

try {
    $workResp = Invoke-RestMethod -Method Get -Uri $workUri -Headers $headers -ErrorAction Stop
}
catch {
    Write-Error "Failed to fetch work items: $($_.Exception.Message)"
    exit 1
}

# Print titles only, one per line
if ($workResp.value) {
    foreach ($wi in $workResp.value) {
        $title = $wi.fields.'System.Title'
        if ($title) { Write-Output $title }
    }
}
else {
    Write-Warning "Unexpected work items response: $($workResp | ConvertTo-Json -Depth 4)"
}
