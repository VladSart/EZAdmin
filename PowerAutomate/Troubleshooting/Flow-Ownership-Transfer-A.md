# Power Automate Flow Ownership Transfer — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**In scope:**
- Cloud flows (automated, instant, scheduled) built in Power Automate, owned by an individual licensed user
- Ownership, co-ownership, and connection-identity models as they affect offboarding/succession planning
- Environment admin and tenant admin tooling for discovering and reassigning flow ownership at scale

**Out of scope:**
- Power Automate Desktop (RPA) flows — different licensing and execution model (runs under a machine/gateway identity, not covered here)
- Power Apps canvas/model-driven app ownership — related but separate object type, separate cmdlets
- Dataverse plugin/workflow ownership — different execution engine entirely

**Assumes:**
- Environment Admin or Power Platform Tenant Admin role
- `Microsoft.PowerApps.Administration.PowerShell` and `Microsoft.PowerApps.PowerShell` modules installed
- Familiarity with the organization's offboarding process timing (i.e., when accounts get disabled relative to when this cleanup happens)

---
## How It Works

<details><summary>Full architecture — ownership vs. connection identity, and why they're separate</summary>

### Two distinct object relationships

Power Automate cloud flows have **two separate concepts of "who's attached to this flow"**, and conflating them is the root cause of nearly every ownership-transfer failure:

**1. Flow ownership (an authorization/edit-rights relationship)**
- Stored as a role assignment on the flow object itself (`Owner` at creation, additional `CanEdit` co-owners addable later)
- Controls: who can see the flow in their "My flows" list, edit its definition, view run history, enable/disable it, delete it
- Managed via `Get-AdminFlowOwnerRole` / `Set-AdminFlowOwnerRole` / `Remove-AdminFlowOwnerRole`, or the Share panel in the portal UI
- **Does not** affect what identity the flow's actions execute as at runtime

**2. Connection identity (an authentication/execution relationship)**
- Each action inside a flow (SharePoint "Create item," Outlook "Send an email," HTTP "Invoke Graph API," etc.) references a **connection object**, which is itself bound to a specific signed-in identity (OAuth token, service principal, or API key) at the time the action was configured
- Connections are tenant/environment-scoped objects, separate from the flow, but a given flow's actions point at specific connection instances
- **This** is what actually executes at runtime — when the flow runs, each action authenticates using whatever identity its bound connection represents, regardless of who "owns" the flow

### Why this split exists

Microsoft's model allows a flow to be collaboratively owned/edited by a team while still executing under a single well-known service identity (the intended pattern for production automations) — analogous to how a scheduled task can be "owned" by an admin group but "run as" a dedicated service account. The failure mode arises when organizations skip the service-account pattern and simply let each flow inherit the personal identity of whoever built it, which is the overwhelmingly common real-world default because it requires zero extra setup at creation time.

### What happens when the owning identity is disabled

```
Account disabled in Entra ID
      │
      ▼
Existing OAuth refresh tokens for that identity become invalid
      │
      ▼
Any connection bound to that identity fails on next token refresh attempt
      │
      ▼
Flow run reaches the action using that connection → fails (401/403, "connection requires attention")
      │
      ▼
Power Automate retries per the flow's configured retry policy (default: 4 retries,
exponential backoff, ~1 min / 5 min / 60 min / 4 hr spacing for most connectors)
      │
      ▼
After retries exhaust, or if the trigger connection itself fails (not just an action),
Microsoft may flag the flow as suspended (Enabled → False) —
particularly common for flows whose TRIGGER (not just an action) depends on the
disabled identity, since a dead trigger can't even attempt a run
```

Note the asymmetry: a flow whose **trigger** connection dies (e.g., "when an item is created" on the departed user's personally-connected SharePoint) stops running entirely and silently — no failed-run alert fires because no run ever starts. A flow whose trigger is healthy but an **action** connection dies at least produces visible failed-run history. This is why "no recent runs at all" during triage is often a worse sign than "recent failed runs."

### Ownership transfer at the environment level

Environment Admins and Tenant Admins can see and manage flows across all users via `Get-AdminFlow`, independent of whether they're personally shared on it — this is what makes bulk offboarding sweeps possible. But `Set-AdminFlowOwnerRole` only grants the *ownership/edit* relationship; it has no awareness of, or effect on, the connections referenced inside the flow's JSON definition. Re-pointing connections requires either manual portal interaction per-action, or (for advanced scenarios) exporting the flow's package, editing the connection references in the package manifest, and reimporting — which is itself an admin-level operation with its own risk profile (see Remediation Playbook 3).

</details>

---
## Dependency Stack

```
Layer 4:  Flow trigger + action success            — depends on Layer 3 being valid
Layer 3:  Connection object's bound identity token  — depends on Layer 2 being enabled
Layer 2:  Entra ID account (enabled/licensed)        — depends on Layer 1 for who admins this
Layer 1:  Flow ownership/co-ownership role           — grants edit rights, NOT runtime identity
Layer 0:  Environment/tenant admin visibility        — required to discover & remediate at scale
```

Layer 1 (ownership) and Layer 3 (connection identity) are the two layers people conflate. Fixing Layer 1 without touching Layer 3 gives you edit access to a flow that still fails at runtime.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Flow shows zero runs at all since a specific date, no error surfaced anywhere | Trigger connection died (departed user's identity), flow can't even start | `Get-AdminFlow` `Enabled`/`State`; confirm trigger action's connection owner |
| Flow shows failed runs with 401/403 on one specific action | An action (not the trigger) connection died | Portal: open the failed run, identify which action step failed |
| Co-owner was added, but flow still fails identically | Ownership was transferred but connections were never re-authenticated | Portal: each action → "Change connection" → check bound identity |
| Flow works for weeks after offboarding, then suddenly fails | Departed user's disabled-but-not-deleted account had a long-lived refresh token that finally expired, or a delayed deprovisioning/hard-delete job ran | Check Entra ID sign-in logs for the account; check token lifetime policies |
| New owner can edit the flow but gets a licensing error trying to save/enable it | Flow uses a premium connector (HTTP, SQL, Dataverse, on-prem gateway) and new owner lacks Power Automate Premium | Check connector types used in flow vs. new owner's license SKU |
| Flow is "owned" by a departed user per `Get-AdminFlow`, but was actually built collaboratively and everyone assumed someone else had ownership | No co-owner was ever added at build time — a governance gap, not a technical one | Audit `Get-AdminFlowOwnerRole` across all business-critical flows proactively, not reactively |
| Bulk sweep script finds flows in unexpected environments | Users often build flows in the "Default" environment rather than a managed one, especially before Managed Environments/DLP was enforced | Run discovery across `Get-AdminPowerAppEnvironment` with no environment filter |

---
## Validation Steps

1. **Enumerate true ownership across all environments — don't trust a single-environment check.**
   ```powershell
   Get-AdminPowerAppEnvironment | ForEach-Object {
       Get-AdminFlow -EnvironmentName $_.EnvironmentName | Where-Object { $_.CreatedBy.userPrincipalName -eq "<UPN>" }
   }
   ```
   Good: complete list across every environment the tenant has, including "Default."
   Bad: only checked the environment the ticket mentioned — Default environment flows are the most commonly missed.

2. **For each flow, distinguish trigger-connection health from action-connection health.**
   Open run history in the portal; a flow with zero runs since a given date needs trigger-connection investigation, not action-level debugging.
   Good: clear determination of which layer (trigger vs. action) is broken.
   Bad: assuming "no runs" means "nothing to fix" — it usually means the opposite, a silently dead trigger.

3. **Confirm the new/successor owner's license covers every connector the flow uses.**
   Compare connector types in the flow (visible per-action in the designer) against the new owner's Power Automate license SKU (seeded M365 vs. Power Automate Premium per-user/per-flow plans).
   Good: match confirmed before cutover.
   Bad: transfer completed, then flow fails to save/enable with a licensing error discovered only after the old account is already deleted (no more fallback).

4. **Confirm whether the flow's trigger uses the departing user's personal content as a data source, not just as an auth mechanism.**
   E.g., "When a new email arrives" on their personal mailbox, or "When a file is created" in their personal OneDrive — reconnecting as someone else changes *what data the flow watches*, which may not be the intended behavior at all and needs a design conversation, not a mechanical fix.
   Good: identified early, flagged to the business owner.
   Bad: silently reconnected to a different mailbox/OneDrive, changing flow behavior without anyone realizing.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Discover before disabling.** Ideally this entire process runs *before* the account is disabled, as part of the offboarding checklist — while the departing user's connections are still valid and can be tested/observed working, making it far easier to confirm what "healthy" looks like before changing anything. If you're reading this after the account is already disabled, move to Phase 2 with the expectation that some connections are already dead and can't be tested interactively.

**Phase 2 — Bulk discovery across environments.** Run the full sweep (see Remediation Playbook 1) across every environment, not just the obvious one. Record results before touching anything — this becomes your evidence pack baseline.

**Phase 3 — Triage by blast radius.** Prioritize flows with (a) no existing co-owner, (b) business-critical naming/description, (c) premium connector usage requiring licensing coordination, (d) trigger (not just action) dependency on the departing identity.

**Phase 4 — Assign co-ownership.** Use `Set-AdminFlowOwnerRole` for every flow in scope. This step is low-risk and reversible — do it broadly rather than trying to be surgical about who "really" needs it.

**Phase 5 — Re-authenticate connections per flow.** This is the labor-intensive, non-scriptable-at-scale step. Prioritize by Phase 3 triage order. For high-volume environments, consider the package export/reimport approach (Playbook 3) but only with a tested rollback plan, since reimporting can reset trigger state/history.

**Phase 6 — Validate and monitor.** After reconnection, manually trigger a test run (or wait for the natural trigger) and confirm success before considering the flow "migrated." Monitor run history for the following 24–48 hours — some failures (e.g., long-lived token expiry) only surface after the old token's natural expiry window passes, not immediately.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full tenant-wide discovery sweep (run this first, always)</summary>

```powershell
$upn = "<departing.user@contoso.com>"
$results = @()

Get-AdminPowerAppEnvironment | ForEach-Object {
    $envName = $_.EnvironmentName
    $envDisplay = $_.DisplayName
    Get-AdminFlow -EnvironmentName $envName -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.CreatedBy.userPrincipalName -eq $upn -or $_.CreatedBy.email -eq $upn) {
            $coOwners = Get-AdminFlowOwnerRole -EnvironmentName $envName -FlowName $_.FlowName -ErrorAction SilentlyContinue
            $results += [PSCustomObject]@{
                Environment   = $envDisplay
                FlowName      = $_.DisplayName
                FlowId        = $_.FlowName
                Enabled       = $_.Enabled
                HasCoOwner    = ($coOwners | Where-Object { $_.RoleType -eq "CanEdit" }).Count -gt 0
            }
        }
    }
}
$results | Format-Table -AutoSize
$results | Export-Csv "C:\Evidence\FlowOwnership-$upn-$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
```
No rollback needed — read-only discovery.

</details>

<details><summary>Playbook 2 — Standard transfer (ownership + manual connection reconnection)</summary>

```powershell
foreach ($flow in $results) {
    Set-AdminFlowOwnerRole -EnvironmentName $flow.Environment -FlowName $flow.FlowId -RoleName "CanEdit" -PrincipalType "User" -PrincipalObjectId "<newOwnerObjectId>"
}
```
Follow with manual portal-based reconnection per flow (no supported API for this). **Rollback:** `Remove-AdminFlowOwnerRole` for any flow transferred in error.

</details>

<details><summary>Playbook 3 — Package export/reimport for bulk connection remapping (advanced, higher risk)</summary>

For environments with dozens of affected flows, exporting flows as a solution package allows bulk connection-reference remapping during import rather than one flow at a time:

1. Export the flows as a solution (Power Apps portal → Solutions → export, or `Export-AdminPowerAppEnvironmentSolution` type tooling depending on tenant setup).
2. During **import**, the portal presents a connection-mapping screen where each connection reference in the package can be pointed at a new, already-established connection under the successor identity.
3. Import completes, flows are recreated/updated with the new connection references.

**Rollback:** retain the original exported package. If import causes unexpected issues (e.g., trigger history reset, flow run ID discontinuity affecting any external tracking that depends on run IDs), the prior flow state can only be restored from a pre-change backup/export taken before Playbook 3 began — there is no automatic undo for a completed solution import. Treat this as a change-managed activity with a tested rollback package, not a routine fix, and reserve it for high-volume offboarding events (e.g., team restructuring) rather than single-user departures.

</details>

<details><summary>Playbook 4 — Establishing the service-account pattern going forward (prevents recurrence)</summary>

For any flow classified as business-critical during Phase 3 triage:
1. Provision or identify a dedicated, non-personal licensed account (e.g., `svc-powerautomate@contoso.com`) with appropriate Power Automate Premium licensing.
2. Add it as a co-owner via `Set-AdminFlowOwnerRole`.
3. Re-authenticate every connection in the flow under that service account's identity rather than any individual's.
4. Document the service account's credential/MFA management ownership (typically the automation/platform team, not an individual).

This converts a recurring offboarding risk into a one-time governance investment. No rollback concerns — purely additive.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Full flow-ownership evidence collection for an offboarding event or escalation.
#>
param(
    [Parameter(Mandatory)][string]$DepartingUserUpn,
    [string]$OutputPath = "C:\Evidence\FlowOwnership-$(Get-Date -Format yyyyMMdd-HHmm)"
)
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$results = @()

Get-AdminPowerAppEnvironment | ForEach-Object {
    $envName = $_.EnvironmentName
    Get-AdminFlow -EnvironmentName $envName -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.CreatedBy.userPrincipalName -eq $DepartingUserUpn -or $_.CreatedBy.email -eq $DepartingUserUpn) {
            $coOwners = Get-AdminFlowOwnerRole -EnvironmentName $envName -FlowName $_.FlowName -ErrorAction SilentlyContinue
            $results += [PSCustomObject]@{
                Environment = $_.EnvironmentName
                FlowName    = $_.DisplayName
                FlowId      = $_.FlowName
                Enabled     = $_.Enabled
                CoOwnerCount = ($coOwners | Where-Object { $_.RoleType -eq "CanEdit" }).Count
            }
        }
    }
}

$results | Export-Csv "$OutputPath\flow-inventory.csv" -NoTypeInformation
Write-Host "Evidence collected: $OutputPath\flow-inventory.csv" -ForegroundColor Green
Write-Host "Flows found: $($results.Count) | Without co-owner: $(($results | Where-Object CoOwnerCount -eq 0).Count)" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AdminPowerAppEnvironment` | List all Power Platform environments in the tenant |
| `Get-AdminFlow -EnvironmentName` | List all flows in an environment (any owner, admin view) |
| `Get-AdminFlowOwnerRole` | List owner/co-owner role assignments on a flow |
| `Set-AdminFlowOwnerRole` | Grant ownership/edit role to a new principal |
| `Remove-AdminFlowOwnerRole` | Revoke an ownership/edit role |
| `Enable-AdminFlow` / `Disable-AdminFlow` | Force enable/disable a flow (admin override) |
| `Get-FlowRunHistory` (custom, `Scripts/Get-FlowRunHistory.ps1`) | Pull recent run history/status for a flow |
| Portal: flow → action → "Change connection" | The only supported way to re-point a single connection's identity |
| Portal: Solutions → export/import | Bulk connection remapping across many flows at once |

---
## 🎓 Learning Pointers
- The single most important mental model: **ownership grants edit rights; connections determine runtime identity.** Every "we transferred it and it's still broken" ticket traces back to conflating these two. Microsoft Learn: [Manage connections in Power Automate](https://learn.microsoft.com/en-us/power-automate/add-manage-connections) and [Administer Power Automate](https://learn.microsoft.com/en-us/power-platform/admin/admin-documentation).
- A flow with a dead **trigger** connection produces zero visible failures — no runs start at all. Treat "no runs since X date" as a higher-priority signal than a pile of failed-run alerts, not a lower one.
- Push for the service-account pattern proactively (Playbook 4) rather than reactively during offboarding — it converts a recurring fire drill into a one-time setup cost per business-critical flow.
- Power Platform licensing is per-connector-tier (standard vs. premium), not per-flow — a successor owner without Premium can inherit ownership cleanly but fail to save/enable the flow the moment they touch a premium connector action.
- Default Environment flows are the most commonly missed in discovery sweeps because admins mentally scope offboarding to "the environment we manage," while end users default-create there unless Managed Environments/DLP routing prevents it.
- Companion hotfix runbook: `Flow-Ownership-Transfer-B.md`. For connector auth failures unrelated to ownership, see `Connector-Auth-B.md`.
