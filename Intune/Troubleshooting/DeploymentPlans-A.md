# Intune Deployment Plans & Deployments (Ring-Based Rollouts) — Reference Runbook (Mode A: Deep Dive)
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

- **In scope:** the Intune **Deployments** feature (public preview), which includes **deployment plans** (reusable ring templates) and **deployments** (the run for a single payload). The admin center location is **Devices > Manage devices > Deployments**.
- **Supported in preview:** Windows 10 and later only. Payloads can be **Settings catalog** policies, **Endpoint security** policies, **Win32 apps**, and **Enterprise App Catalog (EAC) apps**.
- **Out of scope:** Windows quality/feature update rings and Autopatch groups (see `Intune/Troubleshooting/Autopatch-A.md` and `WUfB`-related runbooks). Those are a separate ring system for OS updates. Also out of scope: manual "pilot group then broad group" assignment practice, other than as the baseline this feature automates.
- **Sources:** four Microsoft Learn pages fetched live on 2026-09-25, all with `ms.date` 2026-08-26 and `updated_at` 2026-09-21: [overview](https://learn.microsoft.com/en-us/intune/device-management/deployments/overview), [create-deployment-plan](https://learn.microsoft.com/en-us/intune/device-management/deployments/create-deployment-plan), [create-deployment](https://learn.microsoft.com/en-us/intune/device-management/deployments/create-deployment), [rbac-scope-tags](https://learn.microsoft.com/en-us/intune/device-management/deployments/rbac-scope-tags), plus [known-issues](https://learn.microsoft.com/en-us/intune/device-management/deployments/known-issues). Community coverage: [HTMD / Anoop C Nair](https://www.anoopcnair.com/intune-introduces-staged-deployment-plans/), [Zero Trust Stories](https://zerotruststories.com/how-to-use-native-wave-deployment-in-intune/).
- **Assumption / gap:** Microsoft hasn't documented a Graph or PowerShell surface for the deployment or deployment-plan objects. Everything scriptable in this runbook works on the **payload** (its assignments, type, and intent) and on **Entra groups**, which are documented. Treat any beta Graph path you find for the Deployments objects as unsupported until Learn documents it.

---
## How It Works

<details><summary>Full architecture</summary>

### Two objects, clearly split

| | Deployment plan | Deployment |
|---|---|---|
| What it is | Reusable template: ring names, groups and filters per ring, excludes, wait time between rings | One rollout run for **one** payload |
| Holds a payload? | **No** | Yes, exactly one |
| Editable after creation? | Yes. Edits **don't** affect deployments already created from it | Name and description only. Payload, rings, schedule, groups, and scope tags are fixed |
| Scope tags | Assigned directly | **None of its own**. Visibility comes from the payload's scope tags |
| RBAC | Dedicated `Deployment plan` C/R/U/D permission | **No dedicated permission**. Needs Read + Assign on the payload's category (Device configurations or Mobile apps) |
| Platform | Specific platform (filters are platform-scoped) or **All platforms** (filters picked when the plan is loaded into a deployment) | Inherits from the payload |

When you load a plan into a deployment, the plan is **copied**. You set the first ring's start date and time at that point, and you can adjust groups and filters for that one deployment. After that the deployment doesn't depend on the plan. That's why later plan edits don't carry through.

### The assignment mechanism

Deployments don't have their own delivery channel. When a ring activates, Intune **writes that ring's groups into the payload's own assignment list** as Required include assignments. Devices then pick up the payload through normal check-in: the Intune Management Extension for Win32/EAC apps, and the policy CSP pipeline for Settings catalog and Endpoint security.

```
T0  Payload assignments: [Existing group] (Required)
    Deployment created: Ring1=[Pilot1,Pilot2]  Ring2=[Broad1,Broad2]  Ring3=[All devices]
Ring1 start  → payload: [Existing, Pilot1, Pilot2]
Ring1 + wait → payload: [Existing, Pilot1, Pilot2, Broad1, Broad2]    (cumulative)
Ring3        → payload: [All devices]  + excludes unchanged             (REPLACE)
```

Consequences:
1. **The payload is the source of truth.** A direct edit to its assignments overrides whatever the deployment wrote. The deployment doesn't lock the payload.
2. **Payload content edits carry forward.** If you change the policy settings or app version mid-rollout, groups already assigned get the change at their next check-in, and the next ring gets the updated version. There's no pinned version per ring. A mid-rollout edit reaches pilot *and* earlier rings straight away.
3. **Cancel and Pause aren't rollbacks.** They stop *future* ring activation. Assignments already written stay on the payload.
4. **Virtual-group finality.** A ring with **All users** or **All devices** is automatically the final ring. You can't combine it with security groups in the same ring. When it activates it **replaces** the payload's Required include-group assignments. Excludes stay.

### Safeguards the service enforces

| Safeguard | When checked | Failure behaviour |
|---|---|---|
| **Collision:** the same group is on the payload and in a ring | At creation (blocks Create) **and** at each ring activation | At activation, the deployment goes into an **error state and pauses**. Remove the group from the payload, then Resume |
| **One payload, one live deployment** | At creation | The payload isn't offered while another *scheduled or active* deployment uses it |
| **Minimum 1 hour between rings** | Plan and deployment authoring | Can't save |
| **At least one group per ring** | Authoring, and when a plan with deleted groups is opened | Can't save |
| **Deleted groups** | At ring activation (deployment) and when opened (plan) | Soft-deleted: error, can be fixed by restoring within 30 days (Resume stays disabled until **all** are restored). Permanently deleted, or a mix: error, cancel or delete required |

### App-specific constraints

- Win32 and EAC apps: **Required intent only**. Available and Uninstall intents aren't supported. A deployment can't roll out an Available (Company Portal) app, and it can't stage an uninstall.
- EAC apps: **Update with supersedence** is supported. **Automatically update** isn't supported with deployments.

### Governance hooks

- **Multi Admin Approval.** If an MAA access policy covers the payload's type (for example the *App Windows* platform), then **Create, Resume, Cancel, and Delete** each need approval. A pending Create is **invisible** in the Deployments list (known issue). Check **Tenant administration > Multi Admin Approval** or **Admin tasks**. Approvers need Read on the payload to follow the link in the request.
- **Built-in role mapping for plans:** Application Manager, Endpoint Security Manager, Policy and Profile Manager, and School Administrator get full CRUD. Read Only Operator and Help Desk Operator get Read. Custom roles need the `Deployment plan` permission added explicitly.

### Preview UI limitations (known issues)
- The Deployments list can't be sorted. It's ordered by ring start in active deployments.
- Search only matches the deployment name, not the payload name.
</details>

---
## Dependency Stack

```
[7] Device outcome           — app installed / policy applied (IME / CSP pipeline, unchanged)
[6] Device check-in          — standard Intune sync cadence; no deployment-specific channel
[5] Payload assignment list  — Required includes (cumulative) / virtual-group REPLACE / excludes
[4] Ring activation engine   — schedule (≥1h gaps) → collision check → group-state check → write
[3] Deployment object        — one payload, immutable rings, pause/resume/cancel (+MAA gates)
[2] Deployment plan (opt.)   — template copied at creation; scope-tagged; CRUD RBAC
[1] Payload eligibility      — Windows 10/11; Settings catalog | Endpoint security | Win32 | EAC; Required only
[0] Identity & RBAC          — Entra security groups (live), Intune role (Read+Assign on payload category), scope tags
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Deployment state = error, paused, at ring N | Collision with a group already on the payload | Compare ring groups with `.../assignments` output |
| Error text "Group deleted from Microsoft Entra ID" | Ring group permanently deleted | `Get-MgGroup` fails, and `Get-MgDirectoryDeletedItemAsGroup` also fails |
| Group status "Soft-deleted", Resume greyed out | One or more ring groups in the recycle bin | `Get-MgDirectoryDeletedItemAsGroup -DirectoryObjectId` |
| Deployment "vanished" after Create | MAA request pending | Tenant administration > Multi Admin Approval |
| Payload not in picker | Unsupported type or platform, already in a live deployment, or outside the admin's scope tags | Payload `@odata.type` / `platforms`; admin's role assignment scope |
| Cancelled but devices keep installing | Earlier rings' assignments persist by design | Payload assignments |
| Original targeted groups gone after last ring | Virtual-group ring replaced them | Payload assignments show only All devices/All users |
| Pilot devices got an untested change mid-rollout | Payload edited during the rollout; edits reach all assigned rings | Payload `lastModifiedDateTime` against ring timestamps |
| Can't edit the ring schedule of a running deployment | Immutable by design | Cancel, then recreate with the new schedule |
| Plan edit didn't change a running deployment | Plans are copied at creation | Expected |
| Can't create a plan with a custom role | Custom role lacks `Deployment plan: Create` | Role definition permissions |
| EAC app deployment misbehaving on version updates | App uses **Automatically update** | EAC app update setting |

---
## Validation Steps

1. **Graph connectivity and scopes.**
   ```powershell
   Connect-MgGraph -Scopes DeviceManagementConfiguration.Read.All,DeviceManagementApps.Read.All,Group.Read.All
   (Get-MgContext).Scopes
   ```
   Good: all three scopes listed. Bad: a missing scope means you'll get `403` on the reads below.

2. **Payload type (policy).**
   ```powershell
   Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/<id>?`$select=id,name,platforms,technologies,templateReference"
   ```
   Good: `platforms` = `windows10`, `technologies` contains `mdm`. Bad: `macOS`/`iOS`/`linux` aren't supported in preview.

3. **Payload type and intents (app).**
   ```powershell
   $app = Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/<id>"
   $app.'@odata.type'
   (Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/<id>/assignments").value | Select-Object @{n='intent';e={$_.intent}}, @{n='group';e={$_.target.groupId}}
   ```
   Good: `#microsoft.graph.win32LobApp`, or `#microsoft.graph.win32CatalogApp` for EAC (beta type name). All intents are `required`, or there are no assignments yet. Bad: `available`/`uninstall` intents mean those assignments sit outside the ring model.

4. **Planned ring groups are live and don't collide.** Every planned group resolves with `Get-MgGroup`, and none appears in step 2/3's assignment `groupId` list. The script `Get-IntuneDeploymentReadiness.ps1` automates this.

5. **After each ring activates.** Re-read payload assignments. Good: the ring's groups have been added and earlier ones kept (or replaced on a virtual-group ring). Bad: nothing changed after the ring start time, which means check the deployment state for error or MAA pending.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Authoring (plan or deployment won't save)**
- Ring gaps under 1 hour, an empty ring, a virtual group mixed with security groups, or deleted groups in a loaded plan. Fix in the wizard.
- Custom role without the `Deployment plan` permission (plans), or without Read + Assign on the payload category (deployments).

**Phase 2 — Creation (Create fails or the deployment isn't listed)**
- Collision flagged at creation: remove the group from the payload **or** from the ring before you Create.
- Payload already in a scheduled or active deployment.
- MAA pending: the deployment is hidden until it's approved.

**Phase 3 — Ring activation (error / paused)**
- Collision at activation: someone added a ring's group to the payload after creation. This is common when another admin "helpfully" assigns the pilot group by hand.
- Soft-deleted or deleted group: see the B runbook Fix 2.

**Phase 4 — Device delivery (ring activated but devices aren't getting it)**
- This is no longer a Deployments problem. Troubleshoot like any assignment: filters (per-ring assignment filters apply), excludes, IME health (`Intune/Troubleshooting/IME-*`/Win32 runbooks), and policy conflicts.

**Phase 5 — Post-rollout / rollback**
- Cancel doesn't remove assignments. Clean up by hand on the payload.
- Uninstall isn't a supported deployment intent, so do uninstalls outside Deployments.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Clear a mid-rollout collision and resume</summary>

```powershell
$policyId  = '<configurationPolicyId>'
$colliding = '<groupId>'
$uri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId"
$current = (Invoke-MgGraphRequest GET "$uri/assignments").value
$current | ConvertTo-Json -Depth 6 | Out-File "$env:TEMP\assign-backup-$policyId-$(Get-Date -f yyyyMMddHHmm).json"
$keep = @($current | Where-Object { $_.target.groupId -ne $colliding } | ForEach-Object { @{ target = $_.target } })
Invoke-MgGraphRequest POST "$uri/assign" -Body (@{ assignments = $keep } | ConvertTo-Json -Depth 8) -ContentType 'application/json'
```
Then **Resume** in the portal (with MAA approval if required).
**Rollback:** re-POST the backup set to `/assign`. **Risk:** `/assign` replaces the whole assignment set. Always back up first, and never post an empty array unless you mean to unassign everything.
For apps, use the portal (**Apps > app > Properties > Assignments > Edit**) rather than editing mobileApp assignments with raw API calls.
</details>

<details><summary>Playbook 2 — Recover from deleted ring groups</summary>

1. List deleted groups and restore the ones you need:
   ```powershell
   Get-MgDirectoryDeletedItemAsGroup -All | Select-Object Id, DisplayName, DeletedDateTime
   Restore-MgDirectoryDeletedItem -DirectoryObjectId '<groupId>'
   ```
2. If all groups are restored, **Resume**. If any group is permanently gone, **Cancel** or **Delete** the deployment, fix the plan (remove the dead groups and refill empty rings), and create a new deployment. Rings that already completed keep their assignments on the payload, so exclude those groups from the new deployment's rings or you'll hit a collision.
</details>

<details><summary>Playbook 3 — True rollback of a bad rollout</summary>

1. **Pause** (or Cancel) to stop further rings (MAA approval if applicable).
2. Revert the **payload content**: restore the previous policy settings, or for apps, supersede back or deploy the previous version. Remember edits go to every group already assigned.
3. Remove ring-added groups from the payload's assignments (Playbook 1 pattern, one group at a time or as a filtered set).
4. For apps that must come off devices, add a separate **Uninstall** assignment. Deployments can't do it.
5. Record what was removed, so a new deployment can reuse the same groups without collisions.
</details>

<details><summary>Playbook 4 — Design a safe standard plan (MSP template)</summary>

| Ring | Groups | Wait to next | Notes |
|---|---|---|---|
| 0 – IT canary | `SG-Ring0-IT` | 24 h | Security group; include a VM or two |
| 1 – Pilot | `SG-Ring1-Pilot` (≈5%) | 72 h | Named business champions |
| 2 – Broad | `SG-Ring2-Broad` | 72 h | Most of the fleet |
| 3 – Final | `SG-Ring3-Remainder` **or** All devices | — | Pick the security group if you need to keep other Required assignments. A virtual group replaces them |

- Put **executives, kiosks, and critical servers** in the plan-level **exclude** group, which applies to all rings.
- Scope-tag plans per customer or site in multi-tenant-style delegated setups.
- Don't reuse ring groups as direct payload assignments anywhere, or future deployments will collide. Keep a naming convention (`SG-Ring*`) reserved for Deployments.
</details>

---
## Evidence Pack

```powershell
<#  Collects payload + group evidence for an Intune Deployments escalation. Read-only. #>
param(
  [Parameter(Mandatory)][ValidateSet('Policy','App')] [string]$PayloadKind,
  [Parameter(Mandatory)][string]$PayloadId,
  [string[]]$RingGroupIds = @(),
  [string]$OutDir = "$env:TEMP\IntuneDeploymentEvidence-$(Get-Date -f yyyyMMdd-HHmmss)"
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$base = if ($PayloadKind -eq 'Policy') { "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$PayloadId" }
        else { "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$PayloadId" }
Invoke-MgGraphRequest GET $base | ConvertTo-Json -Depth 10 | Out-File "$OutDir\payload.json"
(Invoke-MgGraphRequest GET "$base/assignments").value | ConvertTo-Json -Depth 10 | Out-File "$OutDir\payload-assignments.json"
$groups = foreach ($g in $RingGroupIds) {
  $state = 'Live'; $name = $null
  try { $name = (Get-MgGroup -GroupId $g -Property DisplayName).DisplayName }
  catch { try { $name = (Get-MgDirectoryDeletedItemAsGroup -DirectoryObjectId $g).DisplayName; $state = 'SoftDeleted' } catch { $state = 'NotFound/PermanentlyDeleted' } }
  [pscustomobject]@{ GroupId = $g; DisplayName = $name; State = $state }
}
$groups | Export-Csv "$OutDir\ring-groups.csv" -NoTypeInformation
(Get-MgContext) | Select-Object Account, TenantId, Scopes | ConvertTo-Json | Out-File "$OutDir\context.json"
Compress-Archive -Path "$OutDir\*" -DestinationPath "$OutDir.zip" -Force
Write-Host "Evidence: $OutDir.zip  (add portal screenshots of the deployment detail + MAA request)"
```

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Connect | `Connect-MgGraph -Scopes DeviceManagementConfiguration.Read.All,DeviceManagementApps.Read.All,Group.Read.All` |
| Policy metadata | `Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/<id>"` |
| Policy assignments | `(Invoke-MgGraphRequest GET ".../configurationPolicies/<id>/assignments").value` |
| Replace policy assignments | `Invoke-MgGraphRequest POST ".../configurationPolicies/<id>/assign" -Body <json>` |
| App type | `(Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/<id>").'@odata.type'` |
| App assignments + intent | `(Invoke-MgGraphRequest GET ".../mobileApps/<id>/assignments").value` |
| Group live? | `Get-MgGroup -GroupId <id>` |
| Group soft-deleted? | `Get-MgDirectoryDeletedItemAsGroup -DirectoryObjectId <id>` |
| Restore group | `Restore-MgDirectoryDeletedItem -DirectoryObjectId <id>` |
| All soft-deleted groups | `Get-MgDirectoryDeletedItemAsGroup -All` |
| Win32 delivery on device | `Get-Content "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\AppWorkload.log" -Tail 200` |
| Force device check-in | `Get-ScheduledTask -TaskName 'PushLaunch' \| Start-ScheduledTask` (Enterprise Mgmt task) |
| Pre-flight readiness | `.\Get-IntuneDeploymentReadiness.ps1 -PolicyId <id> -PlannedRingGroupIds <g1>,<g2>` |

---
## 🎓 Learning Pointers
- **"Deployments are an assignment writer, not a delivery channel."** Almost every surprise (collisions, Cancel not rolling back, pilots getting mid-rollout edits) comes from that. Read [How payload assignments change as rings deploy](https://learn.microsoft.com/en-us/intune/device-management/deployments/overview#how-payload-assignments-change-as-rings-deploy) once and the behaviour becomes predictable.
- **No version pinning per ring.** Unlike Autopatch or update rings, editing the payload mid-rollout reaches every ring already assigned. For content changes, use supersedence (apps) or a *new* policy object with its own deployment, rather than editing the one in flight.
- **Delegation model:** plans have their own CRUD permission and scope tags. Deployments borrow both from the payload. In delegated MSP setups, scope-tag the payloads correctly or technicians won't see each other's deployments: [Permissions, scope tags, and approvals](https://learn.microsoft.com/en-us/intune/device-management/deployments/rbac-scope-tags).
- **MAA + Deployments:** four gated actions, and a pending Create is hidden. Pair with [MultiAdminApproval-A.md](MultiAdminApproval-A.md).
- **Deleted-group lifecycle matters.** Group clean-up automation, like Lifecycle Workflows or stale-group scripts, can break an active deployment. Exclude `SG-Ring*` groups from clean-up jobs. [Restore a deleted group](https://learn.microsoft.com/en-us/entra/identity/users/groups-restore-deleted).
- Hotfix companion: [DeploymentPlans-B.md](DeploymentPlans-B.md). Pre-flight script: `Intune/Scripts/Get-IntuneDeploymentReadiness.ps1`.
