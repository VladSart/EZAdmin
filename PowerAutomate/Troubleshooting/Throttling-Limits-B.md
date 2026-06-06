# Power Automate Throttling & Limits — Hotfix Runbook (Mode B: Ops)
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

Run these in the browser console or via Graph/PowerShell to identify the throttle type fast.

| Check | Command/Location | If X → Do Y |
|-------|-----------------|--------------|
| **1. What error appears?** | Flow run history → failed action | `429 Too Many Requests` → connector throttle (Fix 1–3); `Flow run limit` → plan limit (Fix 4); `Action limit` → daily action quota (Fix 4) |
| **2. Which connector is throttled?** | Failed action name in run history | SP/O365 connector → Fix 1; HTTP/premium connector → Fix 2; Power Platform itself → Fix 4 |
| **3. Is this one flow or many?** | PA Admin Center → Environments → Flows | One flow → fix that flow's concurrency or retries; Many flows same connector → shared connector throttle (Fix 3) |
| **4. What plan is the owner on?** | M365 Admin → Users → Licenses | Free/Per-user Plan 1 → request limit low, upgrade or reassign (Fix 4) |
| **5. Are retries making it worse?** | Flow definition → Settings → Retry policy | Default retry = 4 tries × exponential back-off — under heavy throttle this amplifies the problem → Fix 5 |

**Interpretation table**

| Symptom | Most Likely Cause |
|---------|------------------|
| Single flow fails every few minutes, same action | Connector per-flow throttle (SharePoint 600 req/min) |
| Burst of flows triggered simultaneously all fail | Concurrent runs exhausting connector quota |
| Flow fails only between 9–11am | Business-hours traffic spike — connector shared quota |
| `FlowRunQuotaExceeded` in run history | Plan-level run limit hit (e.g. 750 runs/month on Per-User P1) |
| Retry storm: flow keeps retrying and throttling harder | Retry policy set too aggressive |
| Flow works in dev tenant but not prod | Different plan/connector tier between environments |

---

## Dependency Cascade

<details><summary>What must be true for a flow to run without throttling</summary>

```
Flow trigger fires
  └─ Flow engine picks up run
       └─ Plan limit allows new run
            ├─ [Free/P1] 750 runs/month
            ├─ [Per-User P2] 4,500 runs/month
            └─ [Per-Flow] 15,000 runs/month
  └─ Connector capacity available
       ├─ SharePoint: 600 requests/min per connection
       ├─ Exchange/Outlook: 300 requests/min per connection
       ├─ MS Graph (HTTP): depends on Graph throttling policies
       └─ Premium connectors: per-connector SLA
  └─ Environment capacity not exhausted
       ├─ Environment API call limit (request capacity units)
       └─ Dataverse/CDS limits if used
  └─ Action completes within timeout
       └─ 30-day max run duration, 30s per action (soft)
```

Real throttle signals:
- `429 TooManyRequests` from connector
- `FlowRunQuotaExceeded` from platform
- `ActionThrottled` in run telemetry

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Read the exact error**
```
Flow run history → failed run → expand the failed action → copy the "error" JSON blob
```
Expected good: action succeeds with `statusCode: 200`  
Bad: `"code": "429"` / `"message": "Rate limit is exceeded"` → connector throttle  
Bad: `"code": "FlowRunQuotaExceeded"` → plan run limit  

---

**Step 2 — Check the connector's throttle limits**
Navigate to: [Power Platform connector reference](https://learn.microsoft.com/en-us/connectors/connector-reference/)  
Search the specific connector → **Throttling limits** section.  
Note: `Calls per connection per 60 seconds` (most common limit).

---

**Step 3 — Check flow concurrency settings**
```
Flow → Edit → Settings (gear icon) → Concurrency Control
```
- If **Degree of Parallelism** is high (>10) and the flow loops over items: reduce to 1–5.
- If **Run after** is set to run on failure/timeout: ensure retries aren't triggering re-runs.

---

**Step 4 — Check run history volume**
```
PA Admin Center → Environments → <env> → Analytics → Runs
```
Look for: spikes in run starts that correlate with throttle errors.

---

**Step 5 — Check plan limits via admin PowerShell**
```powershell
# Requires Power Platform admin module
Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser -Force
Connect-AzAccount

# List environments and capacity
Get-AdminPowerAppEnvironment | Select-Object DisplayName, EnvironmentName, @{N='APICapacity';E={$_.Internal.properties.addons}}
```
Expected: shows available API request capacity units.  
If near zero → Fix 4 (add capacity / upgrade plan).

---

**Step 6 — Confirm connector is the bottleneck vs. the platform**

| Error location | Meaning |
|----------------|---------|
| Error inside the action (e.g., "SharePoint" action shows 429) | Connector-level throttle |
| Error at the flow engine level before any action runs | Platform / plan limit |
| Error only in loops with many iterations | Per-connection rate limit hit inside loop |

---

## Common Fix Paths

<details><summary>Fix 1 — Add retry delay in loops (SharePoint / O365 connectors)</summary>

**Problem:** Loop iterates too fast, exhausting 600 req/min SP limit.

**Fix:**
1. Open the flow → find the Apply to each / For each action
2. Inside the loop, add a **Delay** action as the last step
3. Set to **3–5 seconds** (adjust based on item count and allowed time)

Or use **Concurrency Control** on the Apply to each:
```
Apply to each → Settings → Concurrency Control → ON → Degree: 1
```

**Effect:** Serialises processing, reduces req/min well below threshold.  
**Rollback:** Remove the Delay action or re-enable concurrency if throughput becomes a problem.

</details>

---

<details><summary>Fix 2 — Use HTTP with retry and back-off (premium)</summary>

**Problem:** HTTP action hitting external API that throttles with 429 + Retry-After header.

**Fix — enable smart retry policy:**
```
HTTP action → Settings → Retry policy
  Type: Exponential Interval
  Count: 4
  Interval: PT5S  (5 seconds base)
  Minimum interval: PT5S
  Maximum interval: PT1M
```

**Advanced:** Parse `Retry-After` header and feed into a Delay action before next call:
```
Parse the HTTP response headers
Add condition: if status code = 429
  → Extract headers('Retry-After') → convert to integer
  → Delay action: @{body('Parse_Retry_Header')} seconds
  → Re-run the HTTP action
```

**Rollback:** Revert retry policy to "Default" if latency becomes unacceptable.

</details>

---

<details><summary>Fix 3 — Stagger flow triggers to avoid burst (shared connector quota)</summary>

**Problem:** Many flows fire simultaneously (e.g., all triggered by the same SharePoint event), all hammering the same connector.

**Fix A — Stagger recurrence triggers:**
```
Change recurrence from: every 5 minutes (all flows)
To: offset start times by 30–60 seconds each
  Flow 1: 00:00, 00:05, 00:10...
  Flow 2: 00:01, 00:06, 00:11...
  Flow 3: 00:02, 00:07, 00:12...
```

**Fix B — Introduce a queue pattern:**
- Flow 1 writes to a SharePoint list or Service Bus queue when triggered
- Flow 2 polls the queue on a longer interval and processes one item at a time

**Fix C — Per-flow plan (isolates quota):**
- Assign the flow a **Per-Flow** licence (15,000 runs/month, dedicated connector quota)
- In PA Admin Center: Environment → Flows → Assign Per-Flow plan

</details>

---

<details><summary>Fix 4 — Upgrade plan or add API capacity (run limit hit)</summary>

**Problem:** `FlowRunQuotaExceeded` — flow owner's plan is exhausted.

**Check current usage:**
```
PA Admin Center → Analytics → Maker activity → filter by user
```

**Options:**

| Action | When to use |
|--------|-------------|
| Upgrade user to **Per-User Plan 2** (4,500 runs/month) | Flow owner is regularly hitting P1 limit |
| Assign **Per-Flow plan** to the flow (15,000 runs/month) | High-volume automation that must run reliably |
| Purchase **Power Platform API capacity add-on** (50,000 req/day per unit) | Org-wide capacity exhaustion |
| Reduce trigger frequency | Over-triggered flows that don't need to run so often |
| Archive completed runs to reduce run count | Flows that process historical data in one burst |

**Assign Per-Flow licence in PowerShell:**
```powershell
# Find the flow ID
Get-AdminFlow -EnvironmentName <envGUID> | Where-Object { $_.DisplayName -like "*<flowName>*" } | Select-Object FlowName, DisplayName

# Set plan (requires licence already purchased in M365 admin)
Set-AdminFlowOwnerRole -EnvironmentName <envGUID> -FlowName <flowGUID> -RoleName CanEdit -PrincipalType User -PrincipalObjectId <userObjectId>
```
> Note: Licence assignment is done in M365 Admin Center → Billing → Licences → assign to user, then set the Per-Flow plan in PA Admin.

</details>

---

<details><summary>Fix 5 — Disable aggressive retry policy causing retry storm</summary>

**Problem:** Default retry policy retries 4 times with exponential back-off, but under sustained throttling, retries hit the throttled connector again and again, making the problem worse.

**Fix — disable or lengthen retries for the throttled action:**
```
Throttled action → Settings → Retry policy
  Type: None (for non-critical flows that can skip failed items)
  OR
  Type: Fixed Interval → Count: 2 → Interval: PT30S
```

**Add error handling instead:**
- Wrap the action in a **Scope**
- Add a parallel branch with **Run after: Has failed**
- Log the failure to a SharePoint list or send an alert email
- Continue processing remaining items rather than retrying

**Rollback:** Revert to Default retry policy if reliability degrades.

</details>

---

## Escalation Evidence

```
POWER AUTOMATE THROTTLING — ESCALATION TICKET
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Tenant ID:          ___________________________________
Environment:        ___________________________________
Flow Name:          ___________________________________
Flow ID (GUID):     ___________________________________
Flow Owner (UPN):   ___________________________________
Owner's PA Plan:    [ ] Free  [ ] Per-User P1  [ ] Per-User P2  [ ] Per-Flow
First Occurrence:   ___________________________________
Frequency:          ___________________________________

Error code:         ___________________________________
Error message (full):
___________________________________________________________________
___________________________________________________________________

Throttled connector/action: ___________________________________
Connector throttle limit:   ___ requests per minute (from connector reference)
Approximate actual rate:    ___ requests per minute (from run history)

Concurrency setting:        ___________________________________
Retry policy:               ___________________________________

Steps taken:
[ ] Reduced loop concurrency to: ___
[ ] Added delay of: ___
[ ] Changed retry policy to: ___
[ ] Checked plan limits — current usage: ___/month
[ ] Checked API capacity units remaining: ___

Result after fix attempt: ___________________________________

Attach:
- Run history screenshot showing 429/throttle errors
- Flow definition export (JSON) — Flow → Save As → Export Package
- Error JSON from failed action
```

---

## 🎓 Learning Pointers

- **Power Automate throttling is per-connection, not per-flow.** If 10 flows share the same SharePoint connection and all run simultaneously, they share one 600 req/min pool. Use different service accounts for high-volume flows to get separate connection quotas. [Connector throttling limits](https://learn.microsoft.com/en-us/connectors/sharepointonline/#limits)

- **The Per-Flow plan changes the economics significantly.** At 15,000 runs/month vs 750 (P1) or 4,500 (P2), it's the right answer for any business-critical automation. Assign it in M365 Admin → Billing, not in PA Admin Center. [Power Automate licensing guide](https://learn.microsoft.com/en-us/power-platform/admin/power-automate-licensing/types)

- **Apply to each parallelism = 1 is your first lever.** Setting degree of parallelism to 1 (serial processing) is the fastest way to stop a throttle storm. It slows throughput but guarantees you never exceed per-minute connector limits. Re-enable and tune once flows are stable.

- **`429` errors are retried by default — this can cause cascading failures.** Under sustained throttle, default exponential back-off means a flow can run for hours retrying. Set `Retry policy: None` on non-critical actions and handle errors explicitly with a scope + error branch.

- **Power Platform request capacity is a tenant-level pool.** All licensed users draw from it. Monitor in [Power Platform admin analytics](https://aka.ms/PowerPlatformAdminAnalytics) — if the org is near the daily limit, all flows slow down, not just one user's.

- **Use the PA connector reference to look up limits before building.** Every connector documents its throttling policy. Build around those limits from day one rather than hitting them in production. [Full connector reference](https://learn.microsoft.com/en-us/connectors/connector-reference/)
