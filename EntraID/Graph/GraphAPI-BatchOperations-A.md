# Microsoft Graph API Batch Operations — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**In scope:**
- The Microsoft Graph `$batch` endpoint (`POST https://graph.microsoft.com/{version}/$batch`) for combining up to 20 requests into a single HTTP call
- Both `v1.0` and `beta` batch usage, and the operational differences between them
- Throttling behaviour specific to batched requests (per-sub-request evaluation, `Retry-After` handling)
- Pagination interaction with batch (`@odata.nextLink` behaviour inside batched responses)
- `dependsOn` sequencing for write operations that must execute in order within a single batch
- Both delegated (user-context) and application (app-only) authentication models as they affect batch scope requirements
- The companion script `EntraID/Scripts/Invoke-GraphBatchQuery.ps1`, which implements the retry/pagination patterns described here

**Out of scope:**
- Graph SDK-specific batching abstractions in other languages (Python, .NET, Java clients) — this focuses on the raw REST `$batch` contract and PowerShell usage via `Invoke-MgGraphRequest`/`Invoke-RestMethod`
- Change notifications / webhooks (subscriptions API) — a different mechanism for bulk data retrieval over time
- Delta query (`/delta`) — complementary to batching for incremental sync scenarios, covered conceptually here but not in depth

**Assumptions:**
- You have a registered Entra ID app (or are using an interactive Microsoft.Graph PowerShell session) with the ability to request the scopes needed for your target endpoints
- You understand basic Graph REST conventions (resource paths, `$select`, `$filter`, `$top`)
- Your use case involves enough individual requests (typically 5+) that per-request round-trip latency is a measurable cost worth optimizing

---
## How It Works

<details><summary>Full architecture — the batch contract, throttling model, and execution semantics</summary>

### The Batch Envelope

A batch call is a single HTTP POST containing an array of logically independent sub-requests:

```
POST https://graph.microsoft.com/v1.0/$batch
Content-Type: application/json
Authorization: Bearer <token>

{
  "requests": [
    {
      "id": "1",
      "method": "GET",
      "url": "/users/alice@contoso.com?$select=displayName,accountEnabled"
    },
    {
      "id": "2",
      "method": "GET",
      "url": "/users/bob@contoso.com?$select=displayName,accountEnabled",
      "dependsOn": ["1"]
    }
  ]
}
```

Key contract rules:
- Maximum **20 sub-requests** per batch call (hard limit — Graph rejects the entire batch if exceeded)
- Each sub-request's `url` is **relative** to the batch's own version (`v1.0` or `beta`) — never include the full `https://graph.microsoft.com/...` prefix
- Each sub-request needs a unique `id` (string) used to correlate the response
- `dependsOn` is optional and controls **execution order only** — it does not gate execution on the dependency's success unless your response-handling code checks that explicitly
- The batch call itself authenticates **once** — the token's scopes must cover every sub-request's endpoint, or those specific sub-requests fail with 403 while others in the same batch may succeed

### The Response Envelope

```json
{
  "responses": [
    {
      "id": "2",
      "status": 200,
      "headers": { "Content-Type": "application/json" },
      "body": { "displayName": "Bob Jones", "accountEnabled": true }
    },
    {
      "id": "1",
      "status": 200,
      "headers": { "Content-Type": "application/json" },
      "body": { "displayName": "Alice Smith", "accountEnabled": true }
    }
  ]
}
```

Critical detail: **response order is not guaranteed to match request order.** Always correlate by `id`. This is the single most common bug in hand-rolled batch consumers — code that assumes `responses[0]` maps to `requests[0]` will silently misattribute data once request timing varies.

### Throttling Model: Per-Sub-Request, Not Per-Batch

Each sub-request inside the envelope is evaluated against Microsoft Graph's throttling engine **independently**, as if it had been sent standalone:

```
Batch Call (1 HTTP round trip)
  ├── Sub-request 1 → evaluated against /users endpoint limits → 200 OK
  ├── Sub-request 2 → evaluated against /users endpoint limits → 429 (throttled)
  └── Sub-request 3 → evaluated against /groups endpoint limits → 200 OK

Result: partial success. The batch HTTP status is 200 (envelope delivered),
but individual sub-responses carry their own status codes, including 429.
```

This means batching does **not** increase your effective quota — Graph enforces limits per-tenant, per-app, and per-resource-type regardless of how requests are packaged. What batching saves is **network round-trip latency**: 20 sequential calls at (say) 150ms each = 3 seconds of pure network overhead; one batch call with the same 20 sub-requests = ~150-300ms of overhead for the envelope itself, with server-side processing still happening per-item.

A throttled sub-request includes a `Retry-After` header **within that sub-response's own `headers` object** (not at the top-level HTTP response), specifying seconds to wait before retrying just that item.

### dependsOn: Sequencing, Not Transactionality

`dependsOn` exists primarily for **write** scenarios where sub-request B needs sub-request A to have executed first — for example, creating a group (A) then adding a member to it using the new group's id (B). Graph resolves `dependsOn` chains by executing dependencies before dependents within the same batch call.

Important nuance: if A fails, Graph does **not** automatically skip B. Your client-side code must inspect A's status and decide whether to trust or discard B's result. Batches are not atomic transactions — there is no rollback semantic. Design write-batches assuming partial success is the normal case, not the exception.

### Pagination Does Not Auto-Follow Inside a Batch

If a sub-request targets a collection endpoint (e.g. `/users` or `/groups/{id}/members`) that returns more results than fit in one page, the sub-response body includes `@odata.nextLink` exactly as an unbatched call would. Graph does **not** automatically issue follow-up requests for that link as part of the same batch. Two practical patterns exist:

```
Pattern A — Enumerate large single collections OUTSIDE of $batch:
  Just call the resource directly with a loop following @odata.nextLink.
  This is what "SinglePagedUrl" mode in Invoke-GraphBatchQuery.ps1 does —
  it isn't really "batching," it's straightforward pagination, but it's
  bundled into the same script because both solve "get me all of X."

Pattern B — Batch MANY DIFFERENT resources, each individually small:
  e.g. get memberOf for 20 different users in one batch call.
  Each sub-request returns a small, complete result — no pagination needed
  per item. This is the scenario batching is actually built for.
```

Conflating these two patterns — trying to batch a single huge paginated collection — is a frequent design mistake. Batching parallelizes *different* resources; it does not parallelize pages of the *same* resource in one call.

### v1.0 vs beta Batch Endpoints

`$batch` exists at both `https://graph.microsoft.com/v1.0/$batch` and `https://graph.microsoft.com/beta/$batch`. Sub-request `url` values are resolved relative to whichever version endpoint you posted to — you cannot mix a `v1.0` sub-request URL inside a `beta` batch call by prefixing it differently; the whole batch operates against one API version's resource models. If you need endpoints that only exist in `beta` (e.g. certain reports or preview features) alongside `v1.0`-only endpoints, you need two separate batch calls.

</details>

---
## Dependency Stack

```
Entra ID App Registration / Delegated User Session
    ├── OAuth 2.0 token acquisition (client credentials or auth code flow)
    ├── Token audience = https://graph.microsoft.com
    └── Token scopes cover the UNION of all sub-request endpoints
          │
          ▼
HTTP Transport Layer
    ├── Single POST to /{version}/$batch
    ├── Content-Type: application/json
    └── Authorization: Bearer <token> (applies to entire envelope)
          │
          ▼
Graph Batch Processing Engine
    ├── Validates envelope structure (≤20 requests, valid JSON, unique ids)
    ├── Resolves dependsOn execution order
    ├── Dispatches each sub-request to its target resource provider
    │     (Users, Groups, Devices, DeviceManagement, AuditLogs, etc. —
    │      each backed by a different internal service with its own
    │      throttling counters)
    └── Aggregates sub-responses into single response envelope
          │
          ▼
Per-Resource-Provider Throttling
    ├── Users/Groups directory service — its own rate limit bucket
    ├── Intune Device Management service — separate rate limit bucket
    ├── Audit Logs / Sign-in logs service — separate, often more restrictive,
    │     rate limit bucket
    └── Each bucket independently can return 429 with its own Retry-After
          │
          ▼
Client-Side Response Handling
    ├── Correlate by id (not array position)
    ├── Handle partial success (some 200s, some 429s, some 403s in one call)
    ├── Retry ONLY the failed/throttled sub-requests, not the whole batch
    └── Follow @odata.nextLink separately for any paginated sub-response
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Entire batch call returns HTTP 400 | Malformed envelope: >20 requests, invalid JSON, duplicate ids, or unresolvable `dependsOn` reference | Validate JSON structure and request count client-side before sending |
| Batch call succeeds (200) but individual sub-response missing/malformed | Sub-request `url` included full `https://graph.microsoft.com` prefix (should be relative) | Inspect the exact `url` string used for that sub-request |
| Some sub-requests 200, others 403 | Missing scope for that specific sub-request's resource type | Check `body.error.message` on the failing sub-response; compare against token scopes |
| Some sub-requests 200, others 429 | Per-resource throttling on a specific backend service (often Intune device management or audit logs, which throttle more aggressively than directory endpoints) | Check `headers.Retry-After` on the 429 sub-response |
| Batch reliably succeeds for small batches, fails for large ones | Sub-requests individually returning large payloads causing overall response size/timeout issues | Reduce `BatchSize` (5-10) for complex/heavy sub-requests |
| Write batch partially applies (some creates succeed, dependent creates fail) | `dependsOn` chain where an early write failed, but dependents still executed against stale/missing data | Check status of every id in the dependency chain, not just the final one |
| Same resource collection query returns different result counts across batch reruns | Underlying data changed between calls (batch has no read-consistency guarantee across calls) | Not a bug — expected for live directory data; use a single snapshot query if consistency across items matters |
| `@odata.nextLink` present but ignored, incomplete result set retrieved | Assumed batch auto-paginates — it does not | Explicitly follow `nextLink` with a separate request per Pattern A above |
| Beta-only field missing when using v1.0 batch endpoint | Sub-request targeted a `beta`-only property while posted to `/v1.0/$batch` | Move that sub-request (and any others needing beta fields) to a separate `/beta/$batch` call |
| Throttling on `admin/windows/updates` beta calls (used by Windows Autopatch/driver-ring scripting — see `Intune/Troubleshooting/Autopatch-A.md`) behaves unpredictably vs. expectations | Confirmed via Microsoft's own [service-specific throttling limits reference](https://learn.microsoft.com/en-us/graph/throttling-limits): this endpoint family has **no published, named service-specific limit row** (unlike Intune, Identity/Access, or Exchange endpoints, which do). It falls back to the general per-app/per-tenant global limit only — do not assume it shares Intune's device-management quota just because it's device-management-adjacent | Treat `Retry-After` on the sub-response as authoritative and empirically observed rather than looking for a documented fixed quota to plan capacity against; re-check the throttling-limits reference periodically since Microsoft adds named rows over time as endpoints mature out of beta |
| Intermittent full-batch failures under load | Token expired mid-batch construction (long-running script holding a stale token) | Check token expiry against `Get-MgContext`; refresh before constructing large batch runs |

---
## Validation Steps

**Step 1 — Confirm Graph module/session and scopes**
```powershell
Get-MgContext | Select-Object Account, TenantId, Scopes, AuthType
```
Expected: `Scopes` includes every permission required by every endpoint you intend to batch.

**Step 2 — Send a minimal single-item batch as a smoke test**
```powershell
$smokeTest = @{ requests = @(@{ id = "1"; method = "GET"; url = "/me" }) } | ConvertTo-Json -Depth 5
$resp = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/`$batch" -Method POST -Body $smokeTest
$resp.responses | Select-Object id, status
```
Expected: `status = 200`. If this fails, the problem is auth/connectivity, not your batch construction.

**Step 3 — Validate request count before sending a real batch**
```powershell
function Test-BatchSize {
    param([array]$Requests)
    if ($Requests.Count -gt 20) {
        Write-Warning "Batch has $($Requests.Count) requests — exceeds 20-request limit. Must chunk."
        return $false
    }
    return $true
}
```

**Step 4 — Send the real batch and separate successes from failures**
```powershell
$resp = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/`$batch" -Method POST -Body $batchBody
$success = $resp.responses | Where-Object { $_.status -lt 300 }
$throttled = $resp.responses | Where-Object { $_.status -eq 429 }
$failed = $resp.responses | Where-Object { $_.status -ge 400 -and $_.status -ne 429 }

"Success: $($success.Count) | Throttled: $($throttled.Count) | Failed: $($failed.Count)"
```

**Step 5 — Inspect any failure's actual error body (not just status code)**
```powershell
$failed | ForEach-Object {
    [PSCustomObject]@{ id = $_.id; status = $_.status; error = $_.body.error.message }
} | Format-Table -Wrap
```

**Step 6 — Check for unfollowed pagination on any successful collection sub-response**
```powershell
$success | Where-Object { $_.body.'@odata.nextLink' } | Select-Object id, @{N='nextLink';E={$_.body.'@odata.nextLink'}}
```
Any results here mean you retrieved only a partial collection for that sub-request.

**Step 7 — Confirm token has not expired mid-run (for long-lived scripts)**
```powershell
$ctx = Get-MgContext
# Microsoft.Graph module auto-refreshes tokens transparently when connected interactively;
# for app-only/client-credential flows in long-running scripts, explicitly track token
# acquisition time and refresh proactively before it expires (typically 60-90 min lifetime).
```

---
## Troubleshooting Steps (by phase)

### Phase 1 — Envelope Construction Errors

Batch call rejected outright (HTTP 400):
1. Count sub-requests — must be ≤20; if more, split into sequential batch calls
2. Verify every `id` is unique within the envelope
3. Verify every `url` is relative (starts with `/`, no `https://graph.microsoft.com` prefix)
4. Verify any `dependsOn` value references an `id` that exists elsewhere in the same `requests` array
5. Verify the JSON itself is valid — in PowerShell, escape literal `$` characters in OData query strings (e.g. `` `$select `` inside double-quoted strings) or use single-quoted strings to avoid variable interpolation

### Phase 2 — Authentication/Scope Failures on Sub-Requests

Batch succeeds overall, specific sub-requests return 403:
1. Read the exact `body.error.message` for the failing sub-request — it typically names the missing permission
2. Cross-reference the failing endpoint against the [Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference) to find the exact scope name
3. For delegated auth: reconnect with the added scope (`Connect-MgGraph -Scopes ...`) — this may trigger a new consent prompt
4. For app-only auth: add the **Application** permission type (not Delegated) in the app registration, then grant admin consent — this does not require reconnecting the running session, but a new token must be acquired after consent

### Phase 3 — Throttling on Specific Resource Types

Some sub-requests 429, others succeed:
1. Identify which resource type is being throttled (Users, Groups, DeviceManagement, AuditLogs each have independent, differently-sized quotas — audit/reporting endpoints are typically the most restrictive)
2. Read `headers.Retry-After` on the specific 429 sub-response and wait at least that long before retrying only that item
3. If throttling recurs frequently for a given resource type, reduce concurrent batch frequency or `BatchSize` for that resource specifically, rather than a blanket reduction across all batch usage
4. Consider whether the workload is a good candidate for delta query instead of repeated full batch pulls (delta queries are cheaper for incremental sync of large, frequently-changing collections)

### Phase 4 — Pagination Gaps

Collection sub-request returns fewer records than expected:
1. Check for `@odata.nextLink` in that specific sub-response body
2. Do not attempt to add a second batch sub-request for the next page manually with a guessed URL — always use the exact `nextLink` value returned, as it contains an opaque continuation token
3. For known-large collections (all devices, all users in a large tenant), prefer explicit sequential pagination outside of `$batch` — see `Invoke-GraphBatchQuery.ps1 -SinglePagedUrl`

### Phase 5 — Write-Batch Partial Failures

A `dependsOn` chain partially applied (e.g. group created, member-add failed):
1. Check the status of every `id` in the chain in order, not just the last one
2. If an early write in the chain failed, treat all downstream dependents as suspect even if they returned 200 — they may have operated against incomplete data
3. Design write-batches to be idempotent where possible (e.g. check-then-create patterns) so a partial-failure retry doesn't create duplicates
4. For critical multi-step writes where partial application is unacceptable, consider NOT using `dependsOn` batching and instead performing sequential calls with explicit application-level rollback logic — batch has no transactional guarantee

---
## Remediation Playbooks

<details><summary>Playbook 1 — Build a resilient batch wrapper with automatic chunking and retry</summary>

**Scenario:** Need to query 200+ individual resources (e.g. compliance state for 200 devices) reliably, handling chunking, throttling, and partial failures without manual intervention.

**Step 1 — Chunk requests into ≤20-item batches**
```powershell
function Split-IntoBatches {
    param([array]$Items, [int]$Size = 20)
    for ($i = 0; $i -lt $Items.Count; $i += $Size) {
        ,@($Items[$i..[Math]::Min($i + $Size - 1, $Items.Count - 1)])
    }
}
$deviceIds = (Get-MgDeviceManagementManagedDevice -All).Id
$requests = $deviceIds | ForEach-Object {
    @{ id = $_; method = "GET"; url = "/deviceManagement/managedDevices/$_?`$select=complianceState,lastSyncDateTime" }
}
$batches = Split-IntoBatches -Items $requests -Size 20
```

**Step 2 — Execute each batch with retry-on-429 built in (reuse existing script)**
```powershell
$allResults = @()
foreach ($batch in $batches) {
    $result = & "$PSScriptRoot\..\Scripts\Invoke-GraphBatchQuery.ps1" -Requests $batch
    $allResults += $result
    Start-Sleep -Milliseconds 200   # light pacing between batch calls
}
```

**Step 3 — Validate completeness**
```powershell
"Requested: $($deviceIds.Count) | Retrieved: $($allResults.Count)"
if ($allResults.Count -lt $deviceIds.Count) {
    Write-Warning "Some devices missing from results — check for persistent 429/403 on those ids"
}
```

**Rollback:** N/A — read-only operation.

</details>

<details><summary>Playbook 2 — Diagnose which resource type is causing recurring 429s at scale</summary>

**Scenario:** A nightly reporting script batching several thousand requests across users, groups, and devices is intermittently failing with throttling, but it's unclear which resource type is the bottleneck.

**Step 1 — Tag sub-requests by resource type for correlation**
```powershell
$requests = @()
$requests += $userIds | ForEach-Object { @{ id = "user_$_"; method = "GET"; url = "/users/$_" } }
$requests += $groupIds | ForEach-Object { @{ id = "group_$_"; method = "GET"; url = "/groups/$_" } }
$requests += $deviceIds | ForEach-Object { @{ id = "device_$_"; method = "GET"; url = "/deviceManagement/managedDevices/$_" } }
```

**Step 2 — After execution, aggregate 429s by prefix**
```powershell
$throttled429 = $allResponses | Where-Object { $_.status -eq 429 }
$throttled429 | ForEach-Object { ($_.id -split '_')[0] } | Group-Object | Sort-Object Count -Descending
```

**Step 3 — Isolate and slow down only the offending resource type**
```powershell
# Example: if "device_" ids dominate the 429 count, reduce batch size and add
# pacing specifically for deviceManagement calls, leave user/group batching as-is.
```

**Rollback:** N/A — diagnostic and pacing adjustment only.

</details>

<details><summary>Playbook 3 — Recover from a partially-applied write batch (dependsOn chain)</summary>

**Scenario:** A batch created a security group and attempted to add 5 members in the same batch using `dependsOn`. The group creation succeeded but 2 of the 5 member-add sub-requests failed with 404 (referenced user id had a typo).

**Step 1 — Identify exactly what succeeded**
```powershell
$groupCreateResult = $response.responses | Where-Object { $_.id -eq "createGroup" }
$memberAddResults = $response.responses | Where-Object { $_.id -like "addMember_*" }
$memberAddResults | Select-Object id, status
```

**Step 2 — Confirm the group actually exists before doing anything else**
```powershell
$groupId = $groupCreateResult.body.id
Get-MgGroup -GroupId $groupId | Select-Object DisplayName, Id
```

**Step 3 — Retry only the failed member-adds with corrected data**
```powershell
$failedAdds = $memberAddResults | Where-Object { $_.status -ge 400 }
foreach ($f in $failedAdds) {
    # Correct the underlying user id/typo, then retry individually (not as part of
    # the original batch — that batch has already executed and cannot be replayed)
    New-MgGroupMember -GroupId $groupId -DirectoryObjectId "<corrected-user-id>"
}
```

**Rollback:** If the group itself needs to be removed due to bad input: `Remove-MgGroup -GroupId $groupId` (irreversible — confirm no dependent members/apps reference it first).

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Graph Batch Operation Evidence Collector
.NOTES     Run in the same PowerShell session immediately after a failed/problematic batch call
#>

$reportPath = "C:\Temp\GraphBatch_Evidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

# 1. Session context
Get-MgContext | Format-List | Out-File "$reportPath\01_Context.txt"

# 2. Last batch request payload (assumes $lastBatchBody variable holds it)
if ($lastBatchBody) {
    $lastBatchBody | Out-File "$reportPath\02_RequestPayload.json"
}

# 3. Last batch response payload (assumes $lastBatchResponse variable holds it)
if ($lastBatchResponse) {
    $lastBatchResponse | ConvertTo-Json -Depth 10 | Out-File "$reportPath\03_ResponsePayload.json"

    # 4. Status code breakdown
    $lastBatchResponse.responses | Group-Object status | Select-Object Name, Count |
        Out-File "$reportPath\04_StatusBreakdown.txt"

    # 5. Failed/throttled sub-request detail
    $lastBatchResponse.responses | Where-Object { $_.status -ge 400 } |
        Select-Object id, status, @{N='error';E={$_.body.error.message}} |
        Format-Table -Wrap | Out-File "$reportPath\05_Failures.txt"
}

# 6. Module version (batch behaviour can vary across SDK versions)
Get-Module Microsoft.Graph.Authentication -ListAvailable |
    Select-Object Name, Version | Out-File "$reportPath\06_ModuleVersion.txt"

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check current Graph session/scopes | `Get-MgContext \| Select-Object Account, Scopes` |
| Minimal batch smoke test | `Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/`$batch" -Method POST -Body $body` |
| Chunk >20 requests into batches of 20 | See Playbook 1, Step 1 |
| Correlate response to request | Match on `id`, never array index |
| Check for throttled sub-requests | `$resp.responses \| Where-Object { $_.status -eq 429 }` |
| Read Retry-After for a throttled item | `($resp.responses \| ? id -eq "X").headers.'Retry-After'` |
| Read error detail for a failed sub-request | `($resp.responses \| ? id -eq "X").body.error.message` |
| Check for unfollowed pagination | `$resp.responses \| ? { $_.body.'@odata.nextLink' }` |
| Reconnect with additional scopes | `Connect-MgGraph -Scopes "User.Read.All","Group.Read.All"` |
| Use existing repo helper for batch + retry | `EntraID/Scripts/Invoke-GraphBatchQuery.ps1 -Requests $reqs` |
| Use existing repo helper for full pagination | `EntraID/Scripts/Invoke-GraphBatchQuery.ps1 -SinglePagedUrl "/deviceManagement/managedDevices?`$top=999"` |
| Switch to beta endpoint | `https://graph.microsoft.com/beta/`$batch` (separate call from v1.0) |

---
## 🎓 Learning Pointers

- **Batching optimizes latency, not quota.** Every sub-request is throttled as if it were sent individually against its own resource's rate limit bucket. The value of batching is collapsing N network round trips into one HTTP call — plan capacity and retry logic accordingly, don't assume batching lets you exceed normal limits. [MS Docs: Combine multiple requests with JSON batching](https://learn.microsoft.com/en-us/graph/json-batching)

- **Different resource types throttle at very different rates.** Reporting/audit endpoints (`/auditLogs/signIns`, `/reports/*`) are typically far more restrictive than directory endpoints (`/users`, `/groups`). When designing a mixed batch, tag sub-request ids by resource type so you can diagnose which specific backend is the bottleneck when 429s appear (see Playbook 2). [MS Docs: Microsoft Graph throttling guidance](https://learn.microsoft.com/en-us/graph/throttling)

- **`dependsOn` sequences execution — it does not create a transaction.** A failed dependency does not automatically prevent its dependents from running. Any write-batch using `dependsOn` must explicitly check each step's status in application code and treat downstream results as suspect if an earlier step failed. Design for partial application as the default expectation. [MS Docs: JSON batching with dependencies](https://learn.microsoft.com/en-us/graph/json-batching#dependency-among-requests)

- **Response order is unspecified — correlate by id, always.** This is the most common latent bug in hand-rolled batch consumers: it works in testing (small batches often happen to return in order) and fails unpredictably in production under load. Never index into the `responses` array positionally.

- **Batching does not paginate for you.** A batched request against a large collection endpoint returns exactly one page, same as an unbatched call. True bulk enumeration of a single large collection should use straightforward `@odata.nextLink` pagination outside of `$batch`; batching is for parallelizing many *different*, individually small requests. Conflating the two is the second most common design mistake after response-order assumptions.

- **v1.0 and beta batches are separate universes.** You cannot mix `v1.0`-relative and `beta`-relative sub-request URLs in a single batch call — the version is set by which endpoint you POST the envelope to. If your workload needs both stable and preview fields, split into two batch calls against the two different `$batch` endpoints. [MS Docs: Version differences](https://learn.microsoft.com/en-us/graph/versioning-and-support)
