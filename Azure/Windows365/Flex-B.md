# Windows 365 Flex (formerly Frontline) — Hotfix Runbook (Mode B: Ops)
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

Run these first. Interpret results to choose a fix path. If the ticket says "Frontline," treat it as "Flex" — same product, renamed May 2026.

```powershell
# 1. Confirm the affected Cloud PC is actually Flex (Dedicated or Shared), not Enterprise/Business
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '<user@domain.com>'" |
    Select-Object DisplayName, Status, ProvisioningType, ServicePlanName

# 2. Identify the mode from the backing provisioning policy
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy |
    Select-Object DisplayName, ProvisioningType, Id

# 3. Check pool/group sizing vs. licenses (Shared mode) or concurrency (Dedicated mode)
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'"
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } | Group-Object Status

# 4. Confirm the user's full license bundle — NOT just the Flex pool
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Select-Object SkuPartNumber, ServicePlans

# 5. Confirm Cloud PC power state (Dedicated mode auto-powers-off between sessions — this is normal)
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<cloudpc-name>'" |
    Select-Object DeviceName, ComplianceState, LastSyncDateTime
```

| Result | Action |
|--------|--------|
| Shared mode, "no Cloud PC available", pool fully utilized | → [Fix 1 — Shared-Mode Pool Exhaustion](#fix-1--shared-mode-pool-exhaustion) |
| Dedicated mode, "no Cloud PC available" despite licenses existing | → [Fix 2 — Dedicated-Mode Concurrency Buffer Blocked](#fix-2--dedicated-mode-concurrency-buffer-blocked) |
| User reports slow connect, Dedicated mode | → [Fix 3 — Cold-Start / Power-State Confusion](#fix-3--cold-start--power-state-confusion) |
| "Resize" fails, greyed out, or missing for this Cloud PC | → [Fix 4 — Resize Not Supported for Flex](#fix-4--resize-not-supported-for-flex) |
| Shared-mode users report inconsistent app/config behavior across sessions | → [Fix 5 — Config Drift / Bulk Reprovision](#fix-5--config-drift--bulk-reprovision) |
| Ticket references "Frontline" and nothing matches in current portal | → [Fix 6 — Frontline/Flex Naming Confusion](#fix-6--frontlineflex-naming-confusion) |
| Automation/report script silently stopped finding Shared-mode policies | → [Fix 7 — Deprecated `provisioningType eq 'shared'` Filter](#fix-7--deprecated-provisioningtype-eq-shared-filter) |
| User missing Windows Enterprise / Intune / Entra ID P1 despite Flex pool license existing | → [Fix 8 — Incomplete License Bundle](#fix-8--incomplete-license-bundle) |
| Shared-mode user in GCC/sovereign cloud can't get a Cloud PC | → [Fix 9 — Region/Cloud Restriction](#fix-9--regioncloud-restriction) |
| All triage clean, still failing | → Escalate — open a Microsoft 365 admin center service request under Windows 365 |

---
## Dependency Cascade

<details><summary>What must be true for a Flex Cloud PC to be available and connectable</summary>

```
Windows 365 Flex License Pool (tenant-level, pooled — NOT visible as per-user assignment)
  └── User has separately-licensed prerequisites: Windows Enterprise + Intune + Entra ID P1
        └── Provisioning Policy — Mode (mutually exclusive)
              ├── Dedicated mode
              │     ├── Entra ID group membership (pins up to 3 Cloud PCs/license to 1 user)
              │     ├── 1 concurrent session/license + concurrency buffer (4x/day, 1hr, no GPU)
              │     └── Auto power-off/prestart cycle
              └── Shared mode
                    ├── Entra ID group membership (any member, any available pool Cloud PC)
                    ├── 1 concurrent session/license, NO concurrency buffer
                    └── Profile create/delete per session (unless UES enabled)
                          └── Cloud PC VM (Microsoft-managed subscription)
                                ├── Windows 365 agent
                                ├── Intune enrollment (mandatory)
                                └── AVD connection broker registration
                                      └── User's local client
                                            └── Conditional Access evaluation
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm this is a Flex Cloud PC, and which mode**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '<user@domain.com>'" |
    Select-Object DisplayName, ProvisioningType, Status
```
Expected: `ProvisioningType` distinguishes Enterprise from Frontline/Flex Dedicated or Shared. Everything downstream depends on getting this right first — Enterprise/Business troubleshooting steps (`Windows365-B.md`) do not apply here.

**Step 2 — Confirm pool/concurrency state**
```powershell
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'"
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } | Group-Object Status
```
Expected (Shared mode): active count below total licensed pool size. If it's pinned at the pool max, this is expected exhaustion, not a fault — go to Fix 1.
Expected (Dedicated mode): if the user's own Cloud PC shows unavailable despite being licensed, check the concurrency buffer block state next (portal report — no direct Graph endpoint as of this writing).

**Step 3 — Confirm full license bundle, not just the Flex pool**
```powershell
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Select-Object SkuPartNumber, ServicePlans
```
Expected: Windows Enterprise + Intune + Entra ID P1 service plans present (standalone or via M365 E3/E5/F3/A3/A5/Business Premium). The Flex pool license alone does not satisfy these.

**Step 4 — Confirm power state before assuming a fault (Dedicated mode)**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<cloudpc-name>'" |
    Select-Object DeviceName, ComplianceState, LastSyncDateTime
```
Expected: A Dedicated-mode Cloud PC that's been idle shows as powered off — this is normal, not a fault; the user's next connect will cold-start it.

**Step 5 — Confirm Intune enrollment (identical requirement to Enterprise/Business)**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" |
    Where-Object { $_.Model -like "*Cloud PC*" } | Select-Object DeviceName, ComplianceState
```
Expected: Compliant, present. Flex Cloud PCs are Intune-mandatory the same as Enterprise/Business — see `Windows365-A.md` for enrollment failure triage if missing.

---
## Common Fix Paths

<details><summary>Fix 1 — Shared-Mode Pool Exhaustion</summary>

**When:** Shared-mode "no Cloud PC available," and the pool's active-session count equals the group's licensed count.

```powershell
# Confirm the exhaustion is real and sustained (check more than once, at different times of day)
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<shared-policy-name>'"
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } | Group-Object Status

# There is no concurrency buffer in Shared mode — the only fixes are:
# 1. Purchase and assign additional Flex licenses to the backing Entra ID group, OR
# 2. Split the user population across multiple Shared-mode policies sized to each
#    group's actual peak usage window (e.g., separate morning/evening shift groups)
```

**Rollback:** N/A — this is a capacity fix, not a destructive action. Confirm with the client before purchasing additional licenses.

</details>

<details><summary>Fix 2 — Dedicated-Mode Concurrency Buffer Blocked</summary>

**When:** Dedicated mode, licenses exist, but users still can't connect during shift overlap.

```powershell
# No direct Graph endpoint for buffer block state as of this writing — check via the
# Windows 365 Flex connection hourly report and concurrency alert in the Intune admin
# center (Reports > Windows 365)

# If temporarily blocked (used >1hr on 4+ occasions in 24h): wait out the 48-hour block,
# base concurrency ceiling is still fully usable during the block

# If permanently blocked (2+ temporary blocks within 7 days): open a support ticket from
# the Intune portal to request the block be lifted — no self-service unblock exists
```

**Rollback:** N/A — diagnostic/escalation path only. Prevention: right-size the license pool per Playbook 1 in `Flex-A.md` rather than relying on the buffer repeatedly.

</details>

<details><summary>Fix 3 — Cold-Start / Power-State Confusion</summary>

**When:** User reports "my Cloud PC is slow to connect" (Dedicated mode) and backend health otherwise looks fine.

```powershell
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<cloudpc-name>'" |
    Select-Object DeviceName, ComplianceState, LastSyncDateTime
```

**Explain to the user/technician:** Dedicated-mode Flex Cloud PCs auto-power-off after sign-off and cold-start on next connect — this adds latency that does not exist on Enterprise/Business Cloud PCs, which stay running. After 3+ consistent-time connections across 30 days, intelligent prestart begins warming the Cloud PC ~30 minutes before the user's typical connect time; irregular schedules won't benefit from this.

**Rollback:** N/A — this is expected behavior, not a fault to fix.

</details>

<details><summary>Fix 4 — Resize Not Supported for Flex</summary>

**When:** A technician attempts to Resize a Flex Cloud PC (following Enterprise/Business muscle memory from `Windows365-B.md` Fix 5) and it fails or is unavailable.

```powershell
# Confirm this is actually a Flex Cloud PC first:
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '<user@domain.com>'" |
    Select-Object ProvisioningType

# If Frontline/Flex-flavored: Resize is a documented not-yet-supported feature. The only
# path to change a user's resource tier is moving them to a different-sized provisioning
# policy/license, which requires reprovisioning (destructive to local Shared-mode state;
# Dedicated mode retains persisted data across a policy reassignment in most cases, but
# confirm current behavior before promising this to the user)
```

**Rollback:** N/A — no action was actually performed if Resize failed outright.

</details>

<details><summary>Fix 5 — Config Drift / Bulk Reprovision</summary>

**When:** Shared-mode users report inconsistent app versions or settings across sessions on "the same" pool.

```powershell
# No direct Graph cmdlet for bulk reprovision with % availability as of this writing —
# Intune admin center only: Devices > Provision Cloud PCs > Provisioning policies >
# select the Shared-mode policy > Reprovision > set "Keep a percentage of devices available"

# Cloud PCs will NOT reprovision while a user is signed in. To force it:
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<shared-policy-name>'"
$active = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id -and $_.Status -eq "provisioned" }
foreach ($cpc in $active) {
    Invoke-MgBetaDeviceManagementVirtualEndpointCloudPcRestart -CloudPcId $cpc.Id
}
```

**Rollback:** None — reprovisioning wipes local state by design in Shared mode (already non-persistent). Warn affected users of the maintenance window before forcing disconnects.

</details>

<details><summary>Fix 6 — Frontline/Flex Naming Confusion</summary>

**When:** A ticket, old runbook, or user references "Windows 365 Frontline" and nothing by that name appears in current documentation or portal navigation.

```
No PowerShell needed. Explain: Windows 365 Frontline was renamed to Windows 365 Flex on
May 8, 2026 — same product, same licenses, same mechanics, no migration required. The
Intune admin center's "Frontline Type" device property column has NOT yet been renamed
to match (confirmed lagging as of this writing) — seeing "Frontline Type" in the UI does
not mean you're looking at a different or legacy product.
```

**Rollback:** N/A.

</details>

<details><summary>Fix 7 — Deprecated `provisioningType eq 'shared'` Filter</summary>

**When:** A scheduled script/report that filters `provisioningType eq 'shared'` stops returning newly-created Shared-mode policies.

```powershell
# Deprecated literal (still works until April 30, 2027, but incomplete going forward):
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "provisioningType eq 'shared'"

# Fix — broaden to catch all current shared-flavored values:
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All |
    Where-Object { $_.ProvisioningType -in @('shared','sharedByUser','sharedByEntraGroup') }
```

**Rollback:** N/A — logic correction to reporting/automation, no tenant-side change.

</details>

<details><summary>Fix 8 — Incomplete License Bundle</summary>

**When:** User has a Flex pool assignment (group membership confirmed) but the Cloud PC never provisions or the client blocks sign-in.

```powershell
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Select-Object SkuPartNumber, ServicePlans
```

**Common miss:** Flex is a separate product not governed by M365 F1/F3 eligibility — but it still requires the user to independently hold Windows 11/10 Enterprise, Microsoft Intune, and Microsoft Entra ID P1 (bundled in M365 E3/E5/F3/A3/A5/Business Premium, or standalone). Group membership in the Flex-backing Entra ID group alone is not sufficient.

**Rollback:** N/A — licensing assignment fix, not destructive.

</details>

<details><summary>Fix 9 — Region/Cloud Restriction</summary>

**When:** A tenant in GCC/GCC High/DoD or another sovereign cloud cannot provision Shared-mode Flex Cloud PCs.

```
No PowerShell fix — Windows 365 Flex Shared mode is Azure Global Cloud only as of this
writing. Confirm the tenant's cloud environment and, if sovereign-cloud, redirect the
client to Windows 365 Enterprise/Business (Windows365-A.md) or Dedicated-mode Flex if that
mode's region support differs — verify current region support before committing to either.
```

**Rollback:** N/A — architectural constraint, not a fixable configuration issue.

</details>

---
## Escalation Evidence

Copy this template, fill in all fields, attach to ticket before escalating to Microsoft Support.

```
=== WINDOWS 365 FLEX ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Affected user(s)/group: _______________
Tenant ID: _______________
Provisioning Policy Name: _______________
Mode: [ ] Dedicated  [ ] Shared
Cloud PC Display Name (if applicable): _______________

SYMPTOM:
[ ] Shared-mode "no Cloud PC available"
[ ] Dedicated-mode concurrency buffer block
[ ] Slow connect / power-state confusion
[ ] Resize failure (Flex — confirm not applicable to Enterprise/Business)
[ ] Config drift across shared pool
[ ] Naming confusion (Frontline vs. Flex)
[ ] Automation/script gap (deprecated provisioningType value)
[ ] Incomplete license bundle
[ ] Region/cloud restriction
[ ] Other: _______________

TRIAGE RESULTS:
Cloud PC ProvisioningType: _______________
Cloud PC Status: _______________
License SKU(s): _______________
Pool active count / licensed count: _______________
Concurrency buffer state (if known): _______________

ACTIONS TAKEN:
_______________

CORRELATION ID / Request ID: _______________
SERVICE PLAN ID: _______________
```

---
## 🎓 Learning Pointers

- **"Frontline" and "Flex" are the same product** — the May 8, 2026 rename changed nothing functionally, but the Intune admin center's own "Frontline Type" column hasn't been updated to match yet. Don't burn triage time looking for a separate legacy product. Reference: [What is Windows 365 Flex?](https://learn.microsoft.com/en-us/windows-365/enterprise/introduction-windows-365-flex)
- **Pooled licenses don't show up where you'd expect**: Flex licenses appear assigned to zero users in the M365 admin center by design — check the Windows 365 utilization report or Graph instead of the standard per-user license blade. Reference: [Windows 365 Flex licensing](https://learn.microsoft.com/en-us/windows-365/enterprise/windows-365-flex-license)
- **Shared mode has no safety net, Dedicated mode has a limited one**: Shared-mode pool exhaustion is a hard stop with zero buffer; Dedicated mode gets a 4x/day, 1-hour concurrency buffer that can itself get temporarily (48h) or permanently blocked from overuse. Know which mode you're troubleshooting before promising a fix. Reference: [Concurrency buffer](https://learn.microsoft.com/en-us/windows-365/enterprise/concurrency-buffer)
- **Resize doesn't exist for Flex — don't apply Enterprise/Business habits**: `Windows365-B.md` Fix 5 (Resize) does not apply here; the only path to change resource tier is a policy/license change, which is destructive to Shared-mode session state. Reference: [What is Windows 365 Flex?](https://learn.microsoft.com/en-us/windows-365/enterprise/introduction-windows-365-flex)
- **The `provisioningType` enum is actively mid-deprecation**: `shared` retires April 30, 2027 in favor of `sharedByUser`/`sharedByEntraGroup` — update any automation filtering on the old literal before it silently starts missing newly-created policies.
