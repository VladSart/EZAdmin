<#
.SYNOPSIS
    Execute Microsoft Graph API batch requests to retrieve large datasets efficiently.

.DESCRIPTION
    Wraps the Microsoft Graph $batch endpoint to execute up to 20 requests per batch call.
    Dramatically reduces latency and throttling risk when querying multiple resources or
    paginating large result sets (e.g. all devices, all users, all group members).

    Supports:
      - Arbitrary GET requests batched together
      - Automatic retry on 429 (throttle) responses within a batch
      - Result aggregation across all batch pages
      - Output as PSCustomObject array or raw JSON (for pipeline use)

    Common use cases:
      - Pull device compliance + signin risk + group membership in one round trip
      - Enumerate all members of 50+ groups simultaneously
      - Check multiple user properties in parallel instead of serial foreach loops

.PARAMETER Requests
    Array of hashtables, each with:
      - id     : unique string identifier for this request (used to match responses)
      - method : HTTP method (GET, POST, PATCH, DELETE)
      - url    : Graph API relative URL (e.g. "/users/<UPN>/memberOf")
      - body   : (optional) hashtable for POST/PATCH body
      - headers: (optional) hashtable of additional headers

.PARAMETER BatchSize
    Number of requests per batch call. Default 20 (Graph max). Reduce to 5-10 if
    hitting complex requests that individually return large payloads.

.PARAMETER AccessToken
    Bearer token for Microsoft Graph. If not supplied, attempts to acquire one using
    Connect-MgGraph (Microsoft.Graph module must be connected).

.PARAMETER RetryOnThrottle
    If set, automatically waits and retries batch items that return HTTP 429.
    Default: true.

.PARAMETER MaxRetries
    Maximum retry attempts per throttled request. Default 3.

.PARAMETER RawOutput
    If set, returns raw response objects instead of flattening value arrays.
    Useful when callers need response metadata (status codes, headers).

.EXAMPLE
    # Pull display name + accountEnabled + assignedLicenses for 5 users in one batch
    $reqs = @(
        @{ id="u1"; method="GET"; url="/users/alice@contoso.com?`$select=displayName,accountEnabled,assignedLicenses" },
        @{ id="u2"; method="GET"; url="/users/bob@contoso.com?`$select=displayName,accountEnabled,assignedLicenses" },
        @{ id="u3"; method="GET"; url="/users/carol@contoso.com?`$select=displayName,accountEnabled,assignedLicenses" }
    )
    Connect-MgGraph -Scopes "User.Read.All"
    $results = Invoke-GraphBatchQuery -Requests $reqs
    $results | Format-Table id, displayName, accountEnabled

.EXAMPLE
    # Check group membership for 20 groups simultaneously
    $groupIds = Get-MgGroup -All | Select-Object -First 20 -ExpandProperty Id
    $reqs = $groupIds | ForEach-Object { @{ id=$_; method="GET"; url="/groups/$_/members?`$select=id,displayName,userPrincipalName" } }
    $results = Invoke-GraphBatchQuery -Requests $reqs
    foreach ($r in $results) { Write-Host "Group $($r.id): $($r.value.Count) members" }

.EXAMPLE
    # Get all Intune managed devices with compliance state — handles pagination automatically
    $allDevices = Invoke-GraphBatchQuery -SinglePagedUrl "/deviceManagement/managedDevices?`$select=id,deviceName,complianceState,lastSyncDateTime&`$top=999"
    $allDevices | Export-Csv "$env:USERPROFILE\Desktop\AllDevices.csv" -NoTypeInformation

.NOTES
    Requires: Microsoft.Graph PowerShell module OR an access token with appropriate scopes.
    Scopes needed depend on which endpoints you call. Common:
      - User.Read.All        — /users
      - Device.Read.All      — /devices
      - DeviceManagementManagedDevices.Read.All — /deviceManagement/managedDevices
      - Group.Read.All       — /groups
      - AuditLog.Read.All    — /auditLogs/signIns

    Rate limits: Graph enforces per-tenant and per-resource throttling. The $batch endpoint
    shares the same limits as individual requests — batching reduces latency but does not
    increase your quota. Use -BatchSize 5 for complex queries or on busy tenants.

    Pagination: $batch does NOT handle @odata.nextLink automatically across batch items.
    Use the -SinglePagedUrl parameter (a separate helper mode) for paginated resource enumeration.

    Safe to run: This script performs only READ operations (GET) by default.
    POST/PATCH/DELETE are supported via -Requests parameter but caller must construct them.
#>

[CmdletBinding(DefaultParameterSetName = "BatchRequests")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "BatchRequests")]
    [hashtable[]]$Requests,

    [Parameter(Mandatory = $true, ParameterSetName = "SinglePaged")]
    [string]$SinglePagedUrl,

    [Parameter(ParameterSetName = "BatchRequests")]
    [ValidateRange(1, 20)]
    [int]$BatchSize = 20,

    [string]$AccessToken,

    [switch]$RetryOnThrottle = $true,

    [ValidateRange(1, 10)]
    [int]$MaxRetries = 3,

    [switch]$RawOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region --- Helpers ---

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "RETRY" { "Magenta" }
        default { "Cyan" }
    }
    Write-Verbose "[$Status] $Message"
    # Always write to host so caller can see progress
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-GraphToken {
    # Returns Authorization header value
    if ($script:AccessToken) {
        return "Bearer $($script:AccessToken)"
    }
    # Try to get token from connected Microsoft.Graph session
    try {
        $ctx = Get-MgContext -ErrorAction Stop
        if (-not $ctx) { throw "Not connected" }
        # Acquire token from existing context
        $tokenResult = Get-MgContextGrantedPermission -ErrorAction SilentlyContinue
        # Use the internal token retrieval
        $tokenInfo = [Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance.AuthContext.GetTokenAsync(
            [Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance.AuthContext.Scopes,
            [System.Threading.CancellationToken]::None
        ).GetAwaiter().GetResult()
        return "Bearer $($tokenInfo.AccessToken)"
    }
    catch {
        throw "No access token provided and no active Microsoft.Graph session. Run Connect-MgGraph first or supply -AccessToken."
    }
}

function Invoke-GraphRequest {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [object]$Body,
        [hashtable]$Headers = @{}
    )
    $authHeader = Get-GraphToken
    $defaultHeaders = @{
        "Authorization" = $authHeader
        "Content-Type"  = "application/json"
        "ConsistencyLevel" = "eventual"
    }
    foreach ($k in $Headers.Keys) { $defaultHeaders[$k] = $Headers[$k] }

    $params = @{
        Uri             = $Uri
        Method          = $Method
        Headers         = $defaultHeaders
        ErrorAction     = "Stop"
    }
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    return Invoke-RestMethod @params
}

#endregion

#region --- Single Paged URL mode (pagination helper) ---

if ($PSCmdlet.ParameterSetName -eq "SinglePaged") {
    Write-Status "Single-paged mode: enumerating all pages for '$SinglePagedUrl'" "INFO"
    $baseUri = "https://graph.microsoft.com/v1.0"
    $nextLink = "$baseUri$SinglePagedUrl"
    $allValues = [System.Collections.Generic.List[object]]::new()
    $pageCount = 0

    while ($nextLink) {
        $pageCount++
        Write-Status "Fetching page $pageCount..." "INFO"
        $response = Invoke-GraphRequest -Uri $nextLink -Method "GET"
        if ($response.value) {
            $allValues.AddRange($response.value)
        }
        $nextLink = $response.'@odata.nextLink'
        if ($nextLink) { Start-Sleep -Milliseconds 100 }  # mild throttle prevention
    }

    Write-Status "Retrieved $($allValues.Count) total records across $pageCount pages." "OK"
    return $allValues.ToArray()
}

#endregion

#region --- Batch mode ---

$baseUri = "https://graph.microsoft.com/v1.0/`$batch"
$allResponses = [System.Collections.Generic.List[object]]::new()
$pendingRequests = [System.Collections.Generic.List[hashtable]]::new()
$pendingRequests.AddRange($Requests)
$totalRequests = $Requests.Count
$completedCount = 0

Write-Status "Starting batch execution: $totalRequests total requests, batch size $BatchSize" "INFO"

while ($pendingRequests.Count -gt 0) {
    $batchWindow = $pendingRequests | Select-Object -First $BatchSize
    $pendingRequests.RemoveRange(0, [Math]::Min($BatchSize, $pendingRequests.Count))

    # Build batch body
    $batchBody = @{
        requests = @(
            $batchWindow | ForEach-Object {
                $req = @{
                    id     = $_.id
                    method = $_.method.ToUpper()
                    url    = $_.url
                }
                if ($_.body)    { $req.body    = $_.body }
                if ($_.headers) { $req.headers = $_.headers }
                $req
            }
        )
    }

    # Retry loop for this batch window
    $retryItems = $batchWindow
    $attempt = 0

    while ($retryItems.Count -gt 0 -and $attempt -le $MaxRetries) {
        if ($attempt -gt 0) {
            Write-Status "Retry attempt $attempt for $($retryItems.Count) throttled requests..." "RETRY"
            # Rebuild body with only retry items
            $batchBody = @{
                requests = @(
                    $retryItems | ForEach-Object {
                        $req = @{
                            id     = $_.id
                            method = $_.method.ToUpper()
                            url    = $_.url
                        }
                        if ($_.body)    { $req.body    = $_.body }
                        if ($_.headers) { $req.headers = $_.headers }
                        $req
                    }
                )
            }
        }

        try {
            $batchResponse = Invoke-GraphRequest -Uri $baseUri -Method "POST" -Body $batchBody
        }
        catch {
            Write-Status "Batch POST failed: $($_.Exception.Message)" "ERROR"
            break
        }

        $throttledItems = [System.Collections.Generic.List[hashtable]]::new()
        $retryDelaySeconds = 10  # default; override with Retry-After if available

        foreach ($resp in $batchResponse.responses) {
            if ($resp.status -eq 429) {
                if ($RetryOnThrottle) {
                    # Check for Retry-After header in response
                    if ($resp.headers.'Retry-After') {
                        $retryDelaySeconds = [int]$resp.headers.'Retry-After' + 1
                    }
                    $originalReq = $retryItems | Where-Object { $_.id -eq $resp.id } | Select-Object -First 1
                    if ($originalReq) { $throttledItems.Add($originalReq) }
                    Write-Status "Request '$($resp.id)' throttled (429). Will retry." "WARN"
                } else {
                    Write-Status "Request '$($resp.id)' throttled (429). RetryOnThrottle disabled — skipping." "WARN"
                    $allResponses.Add($resp)
                }
            }
            elseif ($resp.status -ge 400) {
                Write-Status "Request '$($resp.id)' failed with HTTP $($resp.status): $($resp.body.error.message)" "ERROR"
                $allResponses.Add($resp)
            }
            else {
                $allResponses.Add($resp)
                $completedCount++
            }
        }

        $retryItems = $throttledItems
        $attempt++

        if ($retryItems.Count -gt 0 -and $attempt -le $MaxRetries) {
            Write-Status "Waiting $retryDelaySeconds seconds before retry..." "RETRY"
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }

    if ($retryItems.Count -gt 0 -and $attempt -gt $MaxRetries) {
        Write-Status "$($retryItems.Count) requests exceeded max retries. Adding as failed." "ERROR"
        foreach ($item in $retryItems) {
            $allResponses.Add(@{
                id     = $item.id
                status = 429
                body   = @{ error = @{ message = "Max retries ($MaxRetries) exceeded" } }
            })
        }
    }

    Write-Status "Batch progress: $completedCount / $totalRequests completed" "INFO"
}

#endregion

#region --- Output formatting ---

if ($RawOutput) {
    Write-Status "Returning raw response objects." "OK"
    return $allResponses.ToArray()
}

# Flatten: for each response, either return the body directly (single resource)
# or the .value array (collection endpoint)
$flatOutput = [System.Collections.Generic.List[object]]::new()
foreach ($resp in $allResponses) {
    if ($resp.status -ge 400) {
        # Include error responses so caller can inspect failures
        $flatOutput.Add([PSCustomObject]@{
            _requestId   = $resp.id
            _httpStatus  = $resp.status
            _error       = $resp.body.error.message
        })
        continue
    }
    $body = $resp.body
    if ($body.value -is [array]) {
        foreach ($item in $body.value) {
            # Attach request id so caller can correlate
            if ($item -is [PSCustomObject]) {
                $item | Add-Member -NotePropertyName "_requestId" -NotePropertyValue $resp.id -Force
            }
            $flatOutput.Add($item)
        }
    }
    elseif ($body) {
        if ($body -is [PSCustomObject]) {
            $body | Add-Member -NotePropertyName "_requestId" -NotePropertyValue $resp.id -Force
        }
        $flatOutput.Add($body)
    }
}

Write-Status "Done. Returning $($flatOutput.Count) total result objects." "OK"
return $flatOutput.ToArray()

#endregion
