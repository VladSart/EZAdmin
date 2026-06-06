# Power Automate Throttling & Limits — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Power Automate cloud flow throttling (per-user, per-flow, per-connector)
- Power Platform request limits (daily API call quotas)
- SharePoint, Exchange, and Graph API connector throttling
- Retry logic, exponential backoff, and queue depth management
- Licensed vs. unlicensed flow throttle tiers

**Does not cover:**
- Power Automate Desktop (RPA) — different throttle model
- On-premises data gateway throughput limits
- Power Apps per-app plan limits (separate quota pool)

**Assumptions:**
- You have Power Platform Admin Center access
- The affected flows are cloud flows (automated, scheduled, or instant)
- Tenant is on a Microsoft commercial cloud (GCC/DoD limits differ)

---

## How It Works

<details><summary>Full throttling architecture</summary>

Power Automate throttling operates at **four distinct layers**, each with independent quotas. A flow can be blocked at any layer simultaneously.

### Layer 1 — Power Platform Request Limits (Daily Entitlement)
Every user or service principal consuming Power Automate has a daily API request entitlement:

```
User License Tier           Daily Request Entitlement
──────────────────────────────────────────────────────
Office 365 / M365 (basic)   6,000  requests/day
Power Automate per-user     40,000 requests/day
Power Automate per-flow     250,000 requests/day (per flow license)
Power Apps per-user         40,000 requests/day
Dynamics 365 Enterprise     40,000 requests/day
```

A "request" = any API call made by a connector action — including internal pagination, polling, and retry attempts. A loop iterating 1,000 SharePoint items = 1,000+ requests.

When a user's entitlement is exhausted, ALL flows running under that user's context are throttled until midnight UTC resets the counter.

### Layer 2 — Flow-Level Concurrency & Throughput
Each individual flow has:
- **Concurrency control** — max parallel instances (1–50, default off = unlimited but bounded by runtime)
- **Action throughput** — soft limit of 100,000 action runs per 5-minute window per flow
- **Trigger polling** — recurrence triggers have minimum intervals enforced by license tier

### Layer 3 — Connector-Level Throttling
Each connector enforces its own rate limits independent of Power Automate:

```
Connector           Throttle Scope      Limit
─────────────────────────────────────────────────────────
SharePoint          Per connection      600 requests/60s
Exchange/Outlook    Per connection      300 requests/60s  
Microsoft Graph     Per tenant          ~10,000 req/10s (varies by endpoint)
HTTP (generic)      Per flow run        Dependent on target API
Dataverse           Per environment     6,000 requests/5min (default entitlement)
SQL Server          Per connection      Connection pool limits
```

When a connector is throttled, it returns HTTP 429 (Too Many Requests) with a `Retry-After` header. Power Automate's runtime will automatically retry if the flow is configured to do so — but retries consume additional request quota.

### Layer 4 — Tenant & Environment Policy
Power Platform admins can impose additional caps:
- Environment-level request caps (lower than default entitlements)
- DLP policies that block certain connector combinations (causes immediate failure, not throttle)
- Managed Environments with enhanced governance that logs and enforces usage

### The Retry Cascade Problem

This is the most common cause of sustained throttling that operators cannot explain:

```
Flow trigger fires
    │
    ├─► Action A calls SharePoint (429 received)
    │       │
    │       └─► Power Automate retries after Retry-After interval
    │               │
    │               └─► Retry itself is a new API request (consumes quota)
    │                       │
    │                       └─► If loop is present, all iterations retry
    │                               └─► Quota burns 5x–100x faster than expected
```

A flow that normally uses 200 requests/run can consume 5,000+ requests/run when it hits throttling and retries without proper error handling.

</details>

---

## Dependency Stack

```
[Flow Run Trigger]
        │
        ▼
[Power Platform Runtime]
        │
        ├── Checks daily request entitlement (per-user or per-flow license)
        │
        ▼
[Connector Execution Layer]
        │
        ├── Connector-level throttle (SharePoint 429, Graph 429, etc.)
        │
        ▼
[Azure Service Bus / Flow Queue]
        │
        ├── Queued runs waiting for throttle window to clear
        │
        ▼
[Target API / Service]
        │
        ├── SharePoint REST
        ├── Exchange EWS / REST
        ├── Microsoft Graph
        └── Third-party APIs
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Flow run failed — "429 Too Many Requests" in action | Connector-level throttle | Check action details for `Retry-After` value; check run history frequency |
| Flow stuck in "Queued" state for >30 min | Request entitlement exhausted for the owner | Check Power Platform Admin Center → Capacity → Request usage |
| All flows for a specific user suddenly fail | Per-user daily limit hit | Check license assignment; check if a runaway loop consumed quota |
| Flow runs succeed but actions are slow / delayed | Background throttle with auto-retry absorbing delays | Enable detailed logging; check action durations vs. normal baseline |
| Flow fails every day at the same time | Scheduled heavy flow collides with quota reset boundary | Stagger trigger times; move to per-flow license |
| "Action failed after max retries" | Connector sustained throttle + retry budget exceeded | Increase retry policy or implement manual delay |
| Throttling only affects one environment | Environment-level capacity cap configured | Admin Center → Environments → Capacity settings |
| Flow works in dev, throttled in prod | Different license context (dev uses per-user, prod uses shared service account with base license) | Check connection owner license in each environment |

---

## Validation Steps

**Step 1 — Identify the throttle layer**
```
Power Platform Admin Center → Analytics → Power Automate
→ Filter by environment and date range
→ Look for "Throttled requests" metric
```
Expected (healthy): throttled requests = 0 or <1% of total  
Bad: >5% throttled = systemic quota pressure

**Step 2 — Check per-user request consumption**
```
Power Platform Admin Center → Capacity → Microsoft Power Platform requests
→ Find the user/service account running the affected flows
→ Review daily consumption chart
```
Expected: usage <80% of entitlement  
Bad: usage hitting 100% = throttle starts at that point in the day

**Step 3 — Inspect the flow run history**
```
Power Automate portal → My Flows → [Flow Name] → Run History
→ Click a failed run
→ Expand the throttled action
→ Read "Error Details" — note the Retry-After value (seconds)
```

**Step 4 — Check connection owner license**
```powershell
# Requires Power Platform admin or Power Shell with PAC CLI
pac admin list-flow-connections --environment <environmentId>
```
Or in portal: Flow → Settings → Connections → verify each connection's owner has an appropriate license.

**Step 5 — Review loop scope for runaway iteration**

In the flow designer, find any Apply to each / Do Until loops:
- What is the input array size?
- Are there API calls inside the loop?
- Is there a Delay action or Concurrency limit on the loop?

A loop with 10,000 items and a SharePoint Get Item inside = 10,000 connector calls per run.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Immediate (Is this throttle or something else?)

1. Open the failed flow run and expand the failed action.
2. Confirm the error code is **429** (throttle) vs **401** (auth) vs **500** (service error).
3. Note the action name and the connector it uses.
4. Check if the run succeeded on the retry that Power Automate automatically attempted.

### Phase 2 — Scope (How widespread is this?)

1. Check run history for the past 7 days — is this isolated or recurring?
2. Check if other flows owned by the same user are also failing.
3. Check if the issue is time-of-day correlated (quota exhaustion) or random (connector-level spike).

### Phase 3 — Root Cause (Why is quota being consumed?)

1. In Power Platform Admin Center, pull the request usage report for the connection owner.
2. Identify which flow(s) are consuming the most requests.
3. Drill into the top consumer — look for loops without concurrency limits.
4. Check if retries are compounding the consumption (retries burn quota too).

### Phase 4 — Resolution (Fix the immediate issue)

1. If daily quota exhausted: wait for midnight UTC reset, or reassign flows to a licensed service account.
2. If connector throttle: add a **Delay** action before/after the throttled call.
3. If loop is oversized: implement pagination with top/skip, add concurrency limits, or batch-process.
4. For sustained load: upgrade to **per-flow license** (250,000 requests/day) for the affected flow.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Add retry policy with backoff to a throttled action</summary>

1. Open the flow in edit mode.
2. Click the **…** menu on the throttled action.
3. Select **Settings**.
4. Under **Networking**, set:
   - Retry Policy: **Exponential interval**
   - Count: **4**
   - Interval: **PT5S** (5 seconds initial)
   - Maximum Interval: **PT1H** (cap at 1 hour)
   - Minimum Interval: **PT5S**
5. Save and re-test.

**Why exponential:** each retry waits exponentially longer, reducing the burst pressure on the connector. Linear retries can re-trigger the 429 repeatedly.

**Rollback:** set Retry Policy back to Default (3 retries, 20s interval) if the extended retry causes flow run durations to breach SLA.

</details>

<details><summary>Playbook 2 — Add concurrency limit to Apply to each loop</summary>

1. In the flow designer, click the **Apply to each** action header.
2. Click **Settings** (gear icon).
3. Enable **Concurrency Control**.
4. Set degree of parallelism to **1** (sequential) or a low value (5–10 for moderate loads).
5. Add a **Delay** action inside the loop body: `PT1S` (1 second) minimum between iterations.

**Trade-off:** sequential processing dramatically increases run time. For 10,000 items, 1 second delay = ~3 hours minimum. Balance throughput vs. quota consumption.

**Rollback:** disable concurrency control. Note this may re-trigger throttling.

</details>

<details><summary>Playbook 3 — Move flow to per-flow license (250k requests/day)</summary>

1. In Power Platform Admin Center → **Environments** → select environment.
2. Go to **Resources** → **Flows**.
3. Find the flow, click **…** → **Assign license plan**.
4. Select **Per Flow Plan** (requires available per-flow licenses in tenant).
5. Confirm assignment — takes effect within 15 minutes.

**Cost note:** per-flow plan costs ~$10/flow/month (verify current pricing). Cost-effective when a single flow exceeds the per-user 40k daily limit.

**Rollback:** reassign back to per-user. The flow reverts to the owner's user license entitlement.

</details>

<details><summary>Playbook 4 — Implement request batching for SharePoint bulk operations</summary>

Instead of calling SharePoint Get Items individually in a loop, use the **Send an HTTP request to SharePoint** action with `$batch` endpoint:

```
Method: POST
URI: _api/$batch
Headers:
  Content-Type: multipart/mixed; boundary=batch_<GUID>
  Accept: application/json;odata=verbose
Body: [BATCH REQUEST BODY]
```

A single `$batch` call can bundle up to **100 SharePoint requests**, reducing 100 individual connector calls to 1. This is the most impactful optimisation for SharePoint-heavy flows.

See: [SharePoint REST API batch operations](https://learn.microsoft.com/en-us/sharepoint/dev/sp-add-ins/make-batch-requests-with-the-rest-apis)

**Rollback:** replace batch action with individual actions. More verbose but easier to debug.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Power Automate throttling evidence for escalation to Microsoft Support
.DESCRIPTION
    Gathers flow run history, license info, and environment capacity data.
    Run from Power Shell with Power Platform admin credentials.
    Requires: Install-Module -Name Microsoft.PowerApps.Administration.PowerShell
.NOTES
    Output saved to ./PowerAutomate-ThrottleEvidence-<date>.txt
#>

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$outputFile = ".\PowerAutomate-ThrottleEvidence-$timestamp.txt"

"=== Power Automate Throttle Evidence Pack ===" | Out-File $outputFile
"Generated: $(Get-Date)" | Out-File $outputFile -Append
"" | Out-File $outputFile -Append

# Import module
try {
    Import-Module Microsoft.PowerApps.Administration.PowerShell -ErrorAction Stop
} catch {
    "ERROR: Microsoft.PowerApps.Administration.PowerShell not installed." | Out-File $outputFile -Append
    "Run: Install-Module Microsoft.PowerApps.Administration.PowerShell" | Out-File $outputFile -Append
    exit 1
}

# Authenticate
Add-PowerAppsAccount

# List environments
"=== ENVIRONMENTS ===" | Out-File $outputFile -Append
Get-AdminPowerAppEnvironment | Select-Object DisplayName, EnvironmentName, Location, SkuName |
    Format-Table -AutoSize | Out-File $outputFile -Append

# List flows with run failures in the last 24h (per environment)
"=== FLOWS WITH RECENT FAILURES ===" | Out-File $outputFile -Append
$envs = Get-AdminPowerAppEnvironment
foreach ($env in $envs) {
    "Environment: $($env.DisplayName)" | Out-File $outputFile -Append
    Get-AdminFlow -EnvironmentName $env.EnvironmentName |
        Where-Object { $_.Properties.lastModifiedTime -gt (Get-Date).AddDays(-7) } |
        Select-Object DisplayName, @{N='Owner';E={$_.Properties.creator.userId}},
                      @{N='State';E={$_.Properties.state}} |
        Format-Table -AutoSize | Out-File $outputFile -Append
}

"" | Out-File $outputFile -Append
"=== NOTES FOR SUPPORT ===" | Out-File $outputFile -Append
"1. Attach this file to the support ticket." | Out-File $outputFile -Append
"2. Also export run history from Power Automate portal (Run History → Export)." | Out-File $outputFile -Append
"3. Note the exact UTC time throttling began." | Out-File $outputFile -Append
"4. Confirm the license assigned to the flow connection owner." | Out-File $outputFile -Append

Write-Host "Evidence saved to: $outputFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Method |
|------|--------|
| Check daily request usage | Admin Center → Capacity → Microsoft Power Platform requests |
| Find which flow is consuming quota | Admin Center → Analytics → Power Automate → Top flows by requests |
| Check connector throttle detail | Flow run → Expand action → Error Details (look for 429 + Retry-After) |
| Assign per-flow license | Admin Center → Environments → Resources → Flows → Assign license |
| Set retry policy on action | Flow designer → Action → … → Settings → Networking → Retry policy |
| Add loop delay | Inside Apply to each → Add action → Delay → PT1S |
| Set loop concurrency | Apply to each → Settings → Concurrency control → Enable |
| Check DLP policy blocking a connector | Admin Center → Policies → Data policies → check connector classification |
| Export run history | Power Automate portal → My Flows → [Flow] → Run history → Export |
| Check environment request cap | Admin Center → Environments → [Env] → Settings → Capacity |

---

## 🎓 Learning Pointers

- **The per-user quota resets at midnight UTC** — not midnight local time. This catches teams off-guard when flows start failing at 7 PM EST (midnight UTC). Structure heavy scheduled flows to run after the UTC reset, not before it. [Power Platform request limits](https://learn.microsoft.com/en-us/power-platform/admin/api-request-limits-allocations)

- **Retry attempts count against quota** — this is the most underappreciated aspect of throttling. A flow with exponential retry can consume 5× its normal quota during a throttle event, accelerating the exhaustion spiral. Always implement delays and caps on retry counts. [Power Automate retry policy](https://learn.microsoft.com/en-us/power-automate/retry-policy)

- **Per-flow licenses are flow-scoped, not user-scoped** — if you assign a per-flow plan to Flow A, only Flow A benefits. Flow B owned by the same user still draws from the user's entitlement. This matters for planning when one user owns many flows. [Per-flow plan](https://learn.microsoft.com/en-us/power-platform/admin/power-automate-licensing/types)

- **The SharePoint connector throttles at the connection level, not the tenant level** — two flows sharing the same SharePoint connection can exhaust the connection's 600 req/60s allowance together. For high-volume SharePoint flows, create dedicated service account connections to isolate quota pools.

- **Apply to Each concurrency is off by default but not unlimited** — the Power Automate runtime does bound parallelism internally. Setting explicit concurrency gives you predictable, debuggable behaviour and prevents runaway quota consumption on large arrays. [Configure concurrency](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-workflow-actions-triggers#concurrency-looping-and-debatching-limits)

- **The Flow Analytics page in Admin Center shows throttled requests 48 hours behind** — if you're investigating a live throttle event, the portal run history (not admin center) gives real-time data. Use Admin Center for trend analysis, not incident response. [Power Automate analytics](https://learn.microsoft.com/en-us/power-automate/analytics-flow)
