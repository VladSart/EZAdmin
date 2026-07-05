# Microsoft Graph API Batch Operations — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run these in order. Each takes under 60 seconds.

```powershell
# 1. Confirm Graph module connectivity and current scopes
Get-MgContext | Select-Object Account, TenantId, Scopes

# 2. Confirm the $batch endpoint is reachable and auth token is valid
Connect-MgGraph -Scopes "User.Read.All" -ErrorAction Stop
$test = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/`$batch" -Method POST -Body (@{
    requests = @(@{ id = "1"; method = "GET"; url = "/me" })
} | ConvertTo-Json -Depth 5)
$test.responses | Select-Object id, status

# 3. Check for 429 (throttled) responses in a recent batch
$test.responses | Where-Object { $_.status -eq 429 } | Select-Object id, status, headers

# 4. Check batch request count — Graph hard-caps at 20 per batch
# (if you constructed a batch with more than 20 sub-requests, it will reject the whole batch)

# 5. Check for a malformed dependsOn chain (circular or missing referenced id)
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| `Get-MgContext` returns nothing | Not connected / session expired | → Fix 1 |
| Batch call itself returns HTTP 400 "Invalid batch payload" | Malformed JSON, >20 requests, or bad `dependsOn` reference | → Fix 2 |
| Individual sub-request status = 429 | That resource/endpoint throttled — batching doesn't bypass quota | → Fix 3 |
| Individual sub-request status = 403 | Token/app lacks the specific scope for that sub-request's endpoint | → Fix 4 |
| Individual sub-request status = 404 | URL malformed relative to base (`/v1.0` or `/beta` prefix duplicated, or wrong resource id) | → Fix 5 |
| Batch succeeds but `@odata.nextLink` present on a sub-response | Only first page returned per batch item — batch does NOT auto-paginate | → Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for a Graph batch call to succeed</summary>

```
Microsoft Entra ID App Registration / Delegated Session
    ├── Valid access token (not expired, correct audience: graph.microsoft.com)
    ├── Token contains ALL scopes required by EVERY sub-request in the batch
    │     (a single missing scope fails only that sub-request, not the whole batch)
    └── Consent granted (admin consent for app-only; user consent for delegated)
          │
          ▼
Batch Envelope (POST https://graph.microsoft.com/v1.0/$batch)
    ├── ≤ 20 sub-requests per batch call (hard limit)
    ├── Each sub-request has a unique "id"
    ├── "url" is relative (e.g. "/users/{id}"), NOT a full URL
    ├── "dependsOn" (if used) references a valid id in the SAME batch,
    │     and dependent requests execute only after their dependency completes
    └── Content-Type: application/json on the envelope itself
          │
          ▼
Per-Resource Throttling (independent per sub-request)
    ├── Each sub-request is throttled against its OWN resource's limits
    ├── Batching reduces round-trip latency, NOT your quota
    └── A 429 on one sub-request does not fail the others in the batch
          │
          ▼
Response Assembly
    ├── Each sub-response has its own "id", "status", "body"
    ├── Order of responses is NOT guaranteed to match request order — always
    │     correlate by "id", never by array position
    └── Pagination: @odata.nextLink in a sub-response body must be followed
          with a SEPARATE subsequent call (not part of the original batch)
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the batch envelope itself is well-formed**
```powershell
$body = @{
    requests = @(
        @{ id = "1"; method = "GET"; url = "/me" },
        @{ id = "2"; method = "GET"; url = "/users?`$top=5" }
    )
} | ConvertTo-Json -Depth 5
Write-Host $body
```
Expected: valid JSON, `requests` is an array, every item has `id`, `method`, `url` (relative path only — no `https://graph.microsoft.com` prefix).

**2. Send the batch and inspect per-request status codes individually**
```powershell
$response = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/`$batch" -Method POST -Body $body
$response.responses | Select-Object id, status | Format-Table
```
Expected: each `id` present with `status` 200 (or 201/204 for writes). Do not assume overall HTTP 200 on the batch call means every sub-request succeeded — check each one.

**3. If a specific sub-request failed, inspect its body for the real error**
```powershell
($response.responses | Where-Object { $_.id -eq "2" }).body.error
```
Expected: `error.code` and `error.message` explain the actual failure (e.g. `Authorization_RequestDenied`, `Request_ResourceNotFound`).

**4. Check for throttling headers on any 429**
```powershell
($response.responses | Where-Object { $_.status -eq 429 }).headers.'Retry-After'
```
Expected: a `Retry-After` value in seconds — honor it before retrying that specific sub-request.

**5. If using `dependsOn`, verify execution order manually**
```powershell
# dependsOn only guarantees ORDER, not that the dependency succeeded before
# the dependent request runs unless it FAILS the batch validation up front.
# Check that a dependent request's status isn't a downstream failure caused
# by its dependency having failed.
```

---
## Common Fix Paths

<details><summary>Fix 1 — Reconnect and re-scope the Graph session</summary>

```powershell
Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes "User.Read.All","Group.Read.All","Device.Read.All"
Get-MgContext | Select-Object Account, Scopes
```
Add every scope required by every sub-request you intend to batch — a batch call authenticates once for the whole envelope, not per sub-request.

**Rollback:** N/A — reconnecting is non-destructive.

</details>

<details><summary>Fix 2 — Fix a malformed batch payload</summary>

Common causes and fixes:
```powershell
# Cause: more than 20 sub-requests in one batch
# Fix: chunk into groups of 20
$allRequests = 1..47 | ForEach-Object { @{ id = "$_"; method = "GET"; url = "/users/user$_@contoso.com" } }
$chunks = for ($i = 0; $i -lt $allRequests.Count; $i += 20) {
    ,($allRequests[$i..[Math]::Min($i+19, $allRequests.Count-1)])
}
foreach ($chunk in $chunks) {
    $body = @{ requests = $chunk } | ConvertTo-Json -Depth 5
    Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/`$batch" -Method POST -Body $body
}

# Cause: "url" includes the full https:// prefix instead of a relative path
# Fix: url must be "/users/{id}", never "https://graph.microsoft.com/v1.0/users/{id}"

# Cause: dependsOn references an id not present in this batch
# Fix: every dependsOn value must match an "id" defined in the SAME requests array
```

**Rollback:** N/A — payload correction only.

</details>

<details><summary>Fix 3 — Handle 429 throttling within a batch (retry only the throttled items)</summary>

```powershell
function Invoke-GraphBatchWithRetry {
    param([array]$Requests, [int]$MaxRetries = 3)
    $pending = $Requests
    $results = @()
    $attempt = 0
    while ($pending.Count -gt 0 -and $attempt -le $MaxRetries) {
        $body = @{ requests = $pending } | ConvertTo-Json -Depth 5
        $resp = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/`$batch" -Method POST -Body $body
        $throttled = @()
        foreach ($r in $resp.responses) {
            if ($r.status -eq 429) {
                $retryAfter = [int]($r.headers.'Retry-After' | Select-Object -First 1)
                if (-not $retryAfter) { $retryAfter = 5 }
                $throttled += ($pending | Where-Object { $_.id -eq $r.id })
                Start-Sleep -Seconds $retryAfter
            } else {
                $results += $r
            }
        }
        $pending = $throttled
        $attempt++
    }
    return $results
}
```
This is exactly the pattern implemented in `EntraID/Scripts/Invoke-GraphBatchQuery.ps1` — use that script directly rather than re-implementing for routine operational use.

**Rollback:** N/A — retry logic only, no state changes.

</details>

<details><summary>Fix 4 — Diagnose and fix a 403 on a specific sub-request</summary>

```powershell
# Identify exactly which scope the failing endpoint requires
($response.responses | Where-Object { $_.status -eq 403 }).body.error.message

# Common mappings:
#   /users/*                        -> User.Read.All or User.ReadWrite.All
#   /devices/*                      -> Device.Read.All
#   /deviceManagement/managedDevices -> DeviceManagementManagedDevices.Read.All
#   /groups/*/members                -> Group.Read.All or GroupMember.Read.All
#   /auditLogs/signIns               -> AuditLog.Read.All

# Reconnect with the missing scope added
Connect-MgGraph -Scopes "User.Read.All","DeviceManagementManagedDevices.Read.All"
```
If using an app registration (app-only auth), the scope must be granted as an **Application** permission with **admin consent**, not just requested at connect time — check Entra admin center > App registrations > API permissions.

**Rollback:** N/A — permission grants are additive; remove unused permissions later via Entra admin center if over-scoped.

</details>

<details><summary>Fix 5 — Fix a 404 caused by malformed relative URL</summary>

```powershell
# WRONG — duplicated version prefix
url = "/v1.0/users/alice@contoso.com"   # batch already targets v1.0, this becomes /v1.0/v1.0/...

# CORRECT
url = "/users/alice@contoso.com"

# WRONG — using $ without escaping in PowerShell double-quoted strings
url = "/users?$select=displayName"      # PowerShell tries to interpolate $select as a variable

# CORRECT — escape the dollar sign
url = "/users?`$select=displayName"
```

**Rollback:** N/A — URL correction only.

</details>

<details><summary>Fix 6 — Handle pagination for a sub-request that returned @odata.nextLink</summary>

```powershell
# Batch does NOT auto-follow @odata.nextLink. If a sub-response includes it,
# issue a follow-up request for that specific nextLink (can be its own
# single-item batch, or a plain GET):
$nextLink = ($response.responses | Where-Object { $_.id -eq "2" }).body.'@odata.nextLink'
if ($nextLink) {
    $page2 = Invoke-MgGraphRequest -Uri $nextLink -Method GET
}

# For full enumeration of a large paginated resource, use the
# -SinglePagedUrl mode of Invoke-GraphBatchQuery.ps1 instead of trying to
# paginate inside a $batch envelope.
```

**Rollback:** N/A — read-only follow-up call.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Microsoft Graph Batch Operations
=====================================================
Date/Time (UTC)        : [                    ]
Reported by            : [                    ]
App/Script involved     : [                    ]
Auth type (delegated/app-only) : [                ]
Tenant ID              : [                    ]

Symptoms
--------
[ ] Whole batch call rejected (HTTP 400)
[ ] Specific sub-request(s) returning 403
[ ] Specific sub-request(s) returning 429 (throttled)
[ ] Specific sub-request(s) returning 404
[ ] Pagination not returning full result set
[ ] Other: [                            ]

Triage results
--------------
Get-MgContext scopes granted : [                    ]
Batch envelope request count : [        ] (must be ≤20)
Failing sub-request id(s)    : [                    ]
Failing status code(s)       : [                    ]
Error message from body      : [                    ]

Evidence collected
------------------
[ ] Full batch request JSON payload (redact any secrets/tokens)
[ ] Full batch response JSON (all sub-response ids and statuses)
[ ] Get-MgContext output
[ ] App registration API permissions screenshot (if app-only auth)

Escalation path: Entra ID > Enterprise Applications > Graph API support ticket with above evidence pack.
```

---
## 🎓 Learning Pointers

- **Batching reduces round trips, not your throttle budget.** Each sub-request inside a `$batch` call is still evaluated against that resource's own per-tenant/per-app rate limit. If you were going to get throttled making 20 individual calls, you can still get throttled making the same 20 calls in one batch — you've just saved the network latency of 19 extra round trips. [MS Docs: Combine multiple requests with JSON batching](https://learn.microsoft.com/en-graph/json-batching)

- **Correlate responses by `id`, never by array position.** Graph does not guarantee that `responses[0]` corresponds to `requests[0]`. Every response includes the `id` you assigned — always match on that field explicitly, especially in scripts that fan out large batches.

- **20 requests per batch is a hard ceiling, not a soft recommendation.** Exceeding it fails the entire batch call, not just the excess items. Always chunk larger request sets client-side (see Fix 2) rather than trusting Graph to reject only the overflow.

- **A single missing scope fails only the sub-request that needs it.** This is a common source of confusing partial failures — nine of ten sub-requests succeed, one comes back 403. Check the specific error message per failing `id` rather than assuming the whole batch's auth is broken. [MS Docs: Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference)

- **`dependsOn` controls execution order, not error handling.** If request B `dependsOn` request A and A fails, B still executes unless you've explicitly coded your client to check A's status first — Graph does not automatically skip dependents of a failed request. [MS Docs: JSON batching with dependencies](https://learn.microsoft.com/en-us/graph/json-batching#dependency-among-requests)

- **Pagination inside a batch is a common miss.** A batched GET against a collection endpoint returns only the first page — the same as an unbatched call would. If you need every page of a large collection (all devices, all users), use single-request pagination with `@odata.nextLink`, not a batch of individual page requests, since you don't know the next link URLs in advance.
