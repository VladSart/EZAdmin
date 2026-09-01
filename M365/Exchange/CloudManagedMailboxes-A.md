# Cloud-Managed Remote Mailboxes — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index (with jump links)
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
- Cloud-based management of Exchange attributes for directory-synced, EXO-hosted mailboxes (`IsExchangeCloudManaged`)
- Phase 1 (GA): per-mailbox Exchange-attribute Source of Authority (SOA) transfer to Exchange Online
- Phase 2 (GA): writeback of designated Exchange attributes from EXO to on-premises Active Directory via Microsoft Entra Cloud Sync
- Tenant-wide SOA default (`Set-OrganizationConfig -ExchangeAttributesCloudManagedByDefault`) and its sequencing risk
- Prerequisites: Entra Connect Sync build, Cloud Sync provisioning agent build, RBAC roles
- New-mailbox and mailbox-deletion workflow changes introduced by this feature

**Does not cover:**
- **Object-level Source of Authority transfer** (identity attributes — `displayName`, `userPrincipalName`, group membership, etc.) — a separate, more mature GA feature covered by `Get-User`/`Get-Group`/`Get-MailContact` SOA configuration, not by `IsExchangeCloudManaged`. See [Configure user Source of Authority](https://learn.microsoft.com/en-us/entra/identity/hybrid/how-to-user-source-of-authority-configure), [Group SOA](https://learn.microsoft.com/en-us/entra/identity/hybrid/how-to-group-source-of-authority-configure), [Contact SOA](https://learn.microsoft.com/en-us/entra/identity/hybrid/how-to-user-source-of-authority-configure#configure-contact-soa).
- General Exchange Hybrid topology, HCW, mail flow, or OAuth — see `Hybrid-Coexistence-A.md`/`-B.md`
- Cross-tenant or on-prem-to-cloud mailbox move mechanics — see `MigrationBatches-A.md`/`-B.md`
- Cloud Sync topology/agent troubleshooting unrelated to this feature — general Cloud Sync agent health is out of scope here

**Assumptions:**
- Directory-synchronized users with mailboxes already provisioned in Exchange Online (hybrid environment)
- On-premises Exchange Server (any currently-supported version) still exists as the "Last Exchange Server" for AD attribute writes prior to adopting this feature
- Admin has both on-premises Exchange Management Shell access and Exchange Online PowerShell access
- This document reflects the feature's General Availability state as of the August 2026 update (writeback GA, `mail` attribute writeback default-mapped for configurations created on/after 2026-08-03)

---
## How It Works

<details><summary>Full architecture — cloud-managed Exchange attributes and writeback</summary>

### The problem this solves

In a standard Exchange Hybrid deployment, a directory-synced user's Exchange attributes (custom attributes, hidden-from-GAL flag, proxy addresses, mailbox permissions flags, etc.) are **sourced from on-premises Active Directory**, even though the mailbox itself lives in Exchange Online. Admins must run `Set-RemoteMailbox` (or edit AD directly) on-prem, then wait for a sync cycle to push the change to the cloud. This keeps organizations dependent on retaining at least one on-premises Exchange server — the "Last Exchange Server" (LES) — purely to run the cmdlets that touch AD, even after every mailbox has migrated to the cloud.

### The two-tier attribute model

Every directory-synced mail user has attributes in two buckets:

```
Identity attributes                         Exchange attributes
(displayName, givenName, sn, title,         (proxyAddresses, extensionAttribute1-15,
 department, manager, UPN,                   msExchHideFromAddressLists,
 usageLocation, objectSID, ...)               msExchRecipientTypeDetails, ...)
        │                                              │
        ▼                                              ▼
Always sourced from                          SOA can be transferred to EXO
on-premises AD.                              per-mailbox via IsExchangeCloudManaged.
Never editable in EXO,                       Editable via EXO PowerShell / EAC /
even after SOA transfer.                     M365 Admin Center once transferred.
```

`IsExchangeCloudManaged` moves **only** the Exchange-attribute bucket's SOA to the cloud. It is a narrower, Exchange-scoped sibling of the broader **object-level SOA transfer** feature (which moves identity-attribute ownership itself, and is the actual mechanism for fully decommissioning on-prem AD dependency for a user — see Scope note above).

### Phase 1 — Per-mailbox SOA transfer (GA)

```powershell
Set-Mailbox -Identity <User> -IsExchangeCloudManaged $true
```

Setting this property to `$true`:
- Stops on-prem `Set-RemoteMailbox` changes to Exchange attributes from overwriting the cloud values on the next sync cycle
- Unlocks EXO PowerShell, Exchange Admin Center, and M365 Admin Center as valid places to edit those attributes directly
- Does **not** touch identity attributes — those keep flowing on-prem → cloud exactly as before
- Applies only to `IsDirSynced = $true` user objects with a mailbox already in Exchange Online — not mail-enabled groups or mail contacts (those have their own, separate SOA mechanisms)

Setting it back to `$false` reverses the direction: the next sync cycle overwrites the cloud Exchange attributes with whatever is currently in on-prem AD, so any cloud-only edits made while `$true` must be manually re-applied on-prem first if they need to survive.

### Phase 2 — Writeback via Microsoft Entra Cloud Sync (GA)

Writeback closes the loop in the other direction: once a mailbox is cloud-managed, changes made in EXO to a **subset** of Exchange attributes are synchronized back to on-premises AD, so on-prem-facing tools/reports (e.g. AD-integrated address books, on-prem scripts reading AD) stay current without anyone touching AD directly.

```
Exchange Online (Set-Mailbox -CustomAttribute1 "X")
        │
        ▼
Microsoft Entra Cloud Sync — "EXO to AD attribute sync" configuration
  (separate provisioning job; requires Cloud Sync agent, coexists with Connect Sync)
        │
        ▼
On-premises Active Directory — extensionAttribute1 updated
  (~20 minute sync cycle, or Provision on demand for immediate push)
```

Cloud Sync is **not** a replacement for Connect Sync in this architecture. Connect Sync (or Cloud Sync, if that's the org's primary sync engine) continues to handle normal directory synchronization exactly as before. The writeback job is an additional, narrowly-scoped Cloud Sync provisioning configuration that only pushes the specific writeback-supported attribute set in the EXO → AD direction. The two sync mechanisms run side by side without conflict.

### Writeback-supported attribute set

Not every cloud-editable Exchange attribute writes back. As of GA, the supported writeback set is:

- `mail` (mapped from EXO's `Mail`/`WindowsEmailAddress` — this specific mapping is auto-included only for writeback configurations created **on or after 2026-08-03**; configurations created during public preview must manually add it via "Restore default mappings")
- `proxyAddresses` (from `EmailAddresses`/`WindowsEmailAddress`)
- `extensionAttribute1` through `extensionAttribute15` (from `CustomAttribute1-15`)
- `msExchExtensionCustomAttribute1` through `msExchExtensionCustomAttribute5`
- `msExchRecipientDisplayType` / `msExchRecipientTypeDetails` (from `Type`)

Everything else that's cloud-editable (litigation hold flags, audit settings, hide-from-GAL, moderation settings, etc.) is **EXO-only** — edits stick in the cloud but never propagate to on-prem AD. This matters for any org running on-prem tooling or reports that expect those values in AD; they will silently go stale for cloud-managed mailboxes unless the specific attribute is on the writeback list.

### Tenant-wide SOA default

For orgs that have finished migrating every mailbox off on-prem Exchange, `Set-OrganizationConfig -ExchangeAttributesCloudManagedByDefault` flips the default so **new** mailboxes are cloud-managed automatically, without an explicit per-mailbox `Set-Mailbox -IsExchangeCloudManaged $true` call. This is exposed via the `BlockExchangeProvisioningFromOnPremEnabled` property (confusingly named — `$true` means "provisioning is expected to come from the cloud default, not on-prem", not literally "on-prem provisioning is blocked at the AD level").

This setting has an explicit, Microsoft-documented **unsupported sequencing failure mode**: if enabled while on-prem Exchange recipients are still being created or newly entering sync scope, the resulting cloud object becomes a bare Entra ID user (not a proper Exchange Online `MailUser`), because the identity sync happens but the object never gets Exchange-provisioned. There is **no self-service recovery path** — `IsExchangeCloudManaged` can only be toggled on an existing EXO mailbox, and the broken object isn't one. Recovery requires Microsoft Support.

</details>

---
## Dependency Stack

```
Active Directory (on-premises)
  └── User is directory-synchronized (IsDirSynced = True)
        └── Mailbox provisioned in Exchange Online
              └── Microsoft Entra Connect Sync ≥ 2.5.190.0 installed
                    (older builds attempt to push Exchange attrs to SOA-transferred mailboxes and fail)
                    │
                    ├── Phase 1: Set-Mailbox -IsExchangeCloudManaged $true
                    │     └── Exchange attributes editable via EXO PowerShell / EAC / M365 Admin Center
                    │           (identity attributes remain on-prem-sourced, always — separate stack)
                    │
                    └── Phase 2 (optional): Writeback
                          └── Microsoft Entra Cloud Sync installed (coexists with Connect Sync)
                                └── Provisioning agent ≥ 1.1.1107.0, status "Active"
                                      └── "EXO to AD attribute sync" Cloud Sync configuration created
                                            └── Provisioning started (initial sync + ~20 min steady-state cycle)
                                                  └── Attribute Mapping includes Mail → mail (GA default, or restored manually)
                                                        └── WRITEBACK-SUPPORTED ATTRIBUTES SYNC EXO → ON-PREM AD
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| `Set-Mailbox -IsExchangeCloudManaged $true` throws or has no effect | Object isn't a directory-synced user mailbox (group/contact/cloud-only user) | `Get-Mailbox \| Select RecipientTypeDetails, IsDirSynced` |
| Property flips to `True` then reverts to `False` (or attribute values revert) | Connect Sync build older than `2.5.190.0` still pushing on-prem values | `(Get-ADSyncGlobalSettings).Parameters['Microsoft.Synchronize.ServerConfigurationVersion']` |
| Cloud edit reverts shortly after being made | SOA flipped too soon after last on-prem `Set-RemoteMailbox` change (race with pending sync cycle) | `Get-RemoteMailbox \| Select WhenChanged`; compare against SOA flip time |
| Cloud edit sticks in EXO but never appears on-prem | Attribute not on writeback-supported list, OR writeback job not configured/running | Check attribute against supported list; check Cloud Sync configuration status |
| Writeback worked before, `mail` changes specifically don't write back | Writeback config created during Public Preview, missing the post-GA default `Mail → mail` mapping | Attribute Mappings tab in the Cloud Sync configuration |
| Writeback configuration shows agent errors | Provisioning agent below `1.1.1107.0`, or not registered/Active | Entra admin center → Cloud Sync → Agents |
| Name/title/department edits rejected or ignored in EXO even on a cloud-managed mailbox | Expected — identity attributes are never editable in EXO under this feature | Confirm attribute is in the identity bucket, not Exchange bucket |
| New on-prem-created mailboxes come up broken after enabling tenant-wide SOA | Tenant-wide SOA enabled before on-prem mailbox migration was complete (unsupported sequencing) | `Get-OrganizationConfig \| Select BlockExchangeProvisioningFromOnPremEnabled`; escalate to Microsoft Support if already triggered |
| Offboarding/mailbox move fails or on-prem updates silently don't apply | `IsExchangeCloudManaged` still `True` when the mailbox is being moved/offboarded | `Get-Mailbox \| Select IsExchangeCloudManaged` before offboarding |
| Shared/equipment mailbox creation fails when tenant-wide SOA is on | Tenant-wide SOA expects EXO-native provisioning; standard on-prem `New-RemoteMailbox` flow for shared mailboxes doesn't fit that model | Create directly in EXO, or license-and-convert pattern (see Playbook 4) |

---
## Validation Steps

**Step 1 — Confirm prerequisites before rolling this out to any mailbox**
```powershell
# On-prem: Connect Sync build
(Get-ADSyncGlobalSettings).Parameters['Microsoft.Synchronize.ServerConfigurationVersion']
# Expected: 2.5.190.0 or higher

# Role check — caller needs one of: Exchange Administrator (recommended), Hybrid Identity Administrator, Global Administrator
```

**Step 2 — Transfer SOA for a single pilot mailbox**
```powershell
Set-Mailbox -Identity <User> -IsExchangeCloudManaged $true
Get-Mailbox -Identity <User> | Format-List Identity, IsExchangeCloudManaged
```
Expected: `IsExchangeCloudManaged: True`, and it stays `True` through at least one full sync cycle.

**Step 3 — Confirm identity attributes are unaffected**
```powershell
Get-Mailbox -Identity <User> | Format-List DisplayName
# Then on-prem:
Get-RemoteMailbox -Identity <User> | Format-List Name
# Change name on-prem, wait for sync, confirm it still flows through normally
```

**Step 4 — Install/verify Cloud Sync agent before enabling writeback**
```powershell
# Entra admin center → Identity → Hybrid management → Microsoft Entra Connect → Cloud Sync → Agents
# Status must show "Active"
# Locally on the agent server:
Get-Item "C:\Program Files\Microsoft Azure AD Connect Provisioning Agent\AADConnectProvisioningAgent.exe" |
    Select-Object -ExpandProperty VersionInfo | Select-Object ProductVersion
# Expected: 1.1.1107.0 or higher
```

**Step 5 — Create and start the writeback configuration**
```
Entra admin center → Cloud Sync → Configurations → New configuration → "EXO to AD attribute sync (Preview)"
  (the menu label may still say Preview even though the capability is GA — this is a UI-copy lag, not a functional gate)
Verify the agent matches the target domain → Create → Start provisioning
```

**Step 6 — Verify writeback end-to-end**
```powershell
# EXO:
Set-Mailbox -Identity <User> -CustomAttribute1 "TestValue_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
# Wait ~20 min or use Provision on demand
# On-prem EMS:
Get-RemoteMailbox -Identity <User> | Format-List CustomAttribute1
```
Expected: value matches.

**Step 7 — Verify the `mail` writeback mapping specifically (common gap for pre-GA configs)**
```
Entra admin center → open the writeback configuration → Attribute Mapping tab
Look for a direct mapping: Mail (source) → mail (target)
```
Bad: mapping absent on a configuration created before 2026-08-03 that was never restored to defaults.

---
## Troubleshooting Steps (by phase)

### Phase 1: SOA Transfer Issues

1. Confirm object eligibility: `Get-Mailbox -Identity <User> | Select RecipientTypeDetails, IsDirSynced`
2. If not a synced user mailbox → wrong feature. Redirect to Group/Contact/User object-level SOA docs.
3. If eligible but the flag won't hold → check Connect Sync build (`2.5.190.0`+ required)
4. If build is current but it still reverts → check timing against the last on-prem `Set-RemoteMailbox` change (need sync cycle + 24h buffer)
5. Confirm role: Exchange Administrator / Hybrid Identity Administrator / Global Administrator

### Phase 2: Writeback Issues

1. Confirm Cloud Sync (not just Connect Sync) is installed — writeback has this as a **mandatory**, separate prerequisite
2. Confirm agent build ≥ `1.1.1107.0` and status `Active`
3. Confirm the "EXO to AD attribute sync" configuration exists and its job status is healthy (not paused/errored)
4. Confirm the specific attribute being tested is actually on the writeback-supported list (most EXO-editable attributes are **not** writeback-eligible — see the attribute table in [How It Works](#how-it-works))
5. For `mail`/`proxyAddresses` specifically failing on an older configuration: check for the missing post-GA default mapping, restore defaults if needed (this clears custom mappings — record them first)
6. Use "Provision on demand" to force an immediate sync rather than waiting for the ~20-minute cycle when validating a fix

### Phase 3: Tenant-Wide SOA Sequencing Incidents

1. Immediately confirm current state: `Get-OrganizationConfig | Select BlockExchangeProvisioningFromOnPremEnabled`
2. If `True` and on-prem mailbox migration is **not** complete: disable it immediately —
   ```powershell
   Set-OrganizationConfig -ExchangeAttributesServerManagedByDefault
   ```
3. Stop all on-prem Exchange recipient creation/sync-scope changes for affected users
4. Do **not** attempt self-service recovery on already-broken objects (bare Entra ID users where a MailUser was expected) — open a Microsoft Support case
5. Document every affected UPN before escalating — Support will need the list

### Phase 4: Offboarding / Reverse Migration Issues

1. Check `IsExchangeCloudManaged` **before** any planned mailbox move or offboarding: `Get-Mailbox | Select IsExchangeCloudManaged`
2. If `True`, back up current cloud attribute values (no automatic restore exists)
3. Set `IsExchangeCloudManaged = $false` and allow the sync to re-source values from on-prem AD
4. Manually re-apply any cloud-only values that must persist, via on-prem `Set-RemoteMailbox`
5. Proceed with the mailbox move/offboarding only after SOA has been confirmed back on-prem

---
## Remediation Playbooks

<details><summary>Playbook 1 — Roll out cloud management to a pilot group safely</summary>

```powershell
# Step 1: Confirm prerequisites org-wide
(Get-ADSyncGlobalSettings).Parameters['Microsoft.Synchronize.ServerConfigurationVersion']
# Must be 2.5.190.0+ before ANY mailbox is flipped, org-wide — an old build will fight every SOA-transferred mailbox

# Step 2: Pick a small pilot group (5-10 mailboxes), confirm eligibility
$pilotUsers = @("<user1>", "<user2>", "<user3>")
foreach ($u in $pilotUsers) {
    Get-Mailbox -Identity $u | Select-Object DisplayName, IsDirSynced, RecipientTypeDetails
}

# Step 3: Confirm sync freshness for each (no on-prem changes in the last 24h+ sync cycle)
foreach ($u in $pilotUsers) {
    Get-RemoteMailbox -Identity $u | Select-Object DisplayName, WhenChanged
}

# Step 4: Transfer SOA for the pilot group
foreach ($u in $pilotUsers) {
    Set-Mailbox -Identity $u -IsExchangeCloudManaged $true
}

# Step 5: Validate each, then monitor for one full business cycle before expanding
foreach ($u in $pilotUsers) {
    Get-Mailbox -Identity $u | Select-Object DisplayName, IsExchangeCloudManaged
}
```

**Rollback:** `Set-Mailbox -Identity <User> -IsExchangeCloudManaged $false` per user, after backing up any cloud-only edits made during the pilot.
</details>

<details><summary>Playbook 2 — Stand up writeback from scratch</summary>

```
Prerequisites:
- Cloud management (Phase 1) already enabled for at least the pilot mailboxes
- Hybrid Identity Administrator role
- Cloud Sync provisioning agent installed, version 1.1.1107.0+, status Active

Process:
1. Entra admin center → Identity → Hybrid management → Microsoft Entra Connect → Cloud Sync
2. Configurations → New configuration dropdown → "EXO to AD attribute sync (Preview)"
3. Verify the listed agent matches the target on-prem domain → Create
4. Wait for job creation (a few minutes) → Overview tab → Start provisioning → confirm Yes
5. Allow a few minutes for the initial sync cycle
```

```powershell
# Post-setup validation:
Set-Mailbox -Identity <PilotUser> -CustomAttribute1 "WritebackTest_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
# Wait ~20 min, then on-prem EMS:
Get-RemoteMailbox -Identity <PilotUser> | Format-List CustomAttribute1
```

**Rollback:** Pause provisioning (Overview tab) to halt writeback without deleting configuration; fully delete the configuration via the `...` menu on the Configurations page if abandoning writeback entirely.
</details>

<details><summary>Playbook 3 — Recover from a missing `mail` writeback mapping (pre-GA configuration)</summary>

```
1. Open the existing Exchange Online attribute writeback configuration
2. Left menu → Attribute Mapping
3. Check for a direct Mail (source) -> mail (target) mapping
4. If present: no action needed
5. If absent (created during Public Preview):
   a. Record all custom attribute mappings and scoping filters currently configured — Restore defaults clears them
   b. Select "Restore default mappings" -> confirm Yes (this also restarts the sync job)
   c. Re-apply any custom mappings/scoping filters noted in step (a)
6. After the job restarts, re-check Attribute Mapping tab — Mail -> mail should now be present
7. Validate: change WindowsEmailAddress in EXO, confirm it reaches on-prem `mail` attribute after next cycle
```

**Rollback:** N/A — restoring defaults is itself the recovery action; there's no further rollback beyond re-applying the pre-restore custom mappings recorded in step (a).
</details>

<details><summary>Playbook 4 — Create a shared/equipment mailbox correctly under tenant-wide SOA</summary>

When `BlockExchangeProvisioningFromOnPremEnabled` is `True`, the standard on-prem `New-RemoteMailbox` workflow no longer fits cleanly for shared/equipment mailboxes that have no real on-prem AD identity requirement. Use one of these two supported paths instead:

```powershell
# Option A — create directly in Exchange Online, no on-prem object at all
New-Mailbox -Shared -Name "<Shared Mailbox Name>" -DisplayName "<Display Name>" -Alias <alias>

# Option B — if the org still wants a synced on-prem identity for this object:
# 1. Create and sync the on-prem AD user as usual
# 2. Temporarily assign an Exchange Online license to provision the mailbox
# 3. Convert it to shared once the mailbox exists
Set-Mailbox -Identity <alias> -Type Shared
# 4. Remove the temporary license once conversion is complete
```

**Rollback:** For Option A, delete the mailbox directly in EXO (`Remove-Mailbox`). For Option B, the on-prem AD object still governs identity — remove it there to fully deprovision.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Cloud-Managed Remote Mailbox diagnostic evidence for escalation
.NOTES     Run in Exchange Online PowerShell. Run the on-prem block separately from
           on-premises Exchange Management Shell and merge the two output folders.
#>

$reportPath = ".\CloudManagedMailbox-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

# Org-level SOA default state
Get-OrganizationConfig | Select-Object BlockExchangeProvisioningFromOnPremEnabled |
    Format-List | Out-File "$reportPath\01-TenantWideSOA.txt"

# All cloud-managed mailboxes (fleet view)
Get-Mailbox -ResultSize Unlimited |
    Where-Object { $_.IsDirSynced -eq $true } |
    Select-Object DisplayName, PrimarySmtpAddress, IsDirSynced, IsExchangeCloudManaged |
    Format-Table -AutoSize | Out-File "$reportPath\02-CloudManagedInventory.txt"

# Specific mailbox deep-dive (if provided)
$target = Read-Host "Enter a specific mailbox UPN to deep-dive (or press Enter to skip)"
if ($target) {
    Get-Mailbox -Identity $target |
        Select-Object DisplayName, IsDirSynced, IsExchangeCloudManaged, CustomAttribute1, CustomAttribute2,
            ProxyAddresses, EmailAddresses, HiddenFromAddressListsEnabled |
        Format-List | Out-File "$reportPath\03-TargetMailbox.txt"
}

# Note: Cloud Sync writeback configuration status is not exposed via EXO PowerShell —
# capture a screenshot of Entra admin center > Cloud Sync > Configurations > (job) > Overview
# and the Attribute Mapping tab, and include both in the evidence package manually.

Write-Host "EXO-side evidence collected -> $reportPath" -ForegroundColor Green
Write-Host "Now run the matching block below from ON-PREMISES Exchange Management Shell:" -ForegroundColor Yellow

<#
# ---- Run this block on-premises ----
$reportPath = ".\CloudManagedMailbox-Evidence-OnPrem-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

(Get-ADSyncGlobalSettings).Parameters['Microsoft.Synchronize.ServerConfigurationVersion'] |
    Out-File "$reportPath\01-ConnectSyncBuild.txt"

$target = Read-Host "Enter the same mailbox UPN checked on the EXO side (or press Enter to skip)"
if ($target) {
    Get-RemoteMailbox -Identity $target |
        Select-Object Name, WhenChanged, CustomAttribute1, CustomAttribute2, EmailAddresses |
        Format-List | Out-File "$reportPath\02-TargetRemoteMailbox.txt"
}

Write-Host "On-prem evidence collected -> $reportPath" -ForegroundColor Green
#>
```

---
## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Check SOA state for a mailbox | `Get-Mailbox <User> \| Select IsDirSynced, IsExchangeCloudManaged` |
| Transfer Exchange-attribute SOA to cloud | `Set-Mailbox <User> -IsExchangeCloudManaged $true` |
| Transfer SOA back to on-prem | `Set-Mailbox <User> -IsExchangeCloudManaged $false` |
| Find all cloud-managed mailboxes | `Get-Mailbox -ResultSize Unlimited \| Where {$_.IsDirSynced -and $_.IsExchangeCloudManaged}` |
| Check Connect Sync build | `(Get-ADSyncGlobalSettings).Parameters['Microsoft.Synchronize.ServerConfigurationVersion']` |
| Check tenant-wide SOA default | `Get-OrganizationConfig \| Select BlockExchangeProvisioningFromOnPremEnabled` |
| Enable tenant-wide SOA default | `Set-OrganizationConfig -ExchangeAttributesCloudManagedByDefault` |
| Disable tenant-wide SOA default | `Set-OrganizationConfig -ExchangeAttributesServerManagedByDefault` |
| Edit a cloud-managed custom attribute | `Set-Mailbox <User> -CustomAttribute1 "value"` |
| Check on-prem last-changed timestamp | `Get-RemoteMailbox <User> \| Select WhenChanged` (on-prem EMS) |
| Verify writeback landed on-prem | `Get-RemoteMailbox <User> \| Select CustomAttribute1` (on-prem EMS) |
| Create shared mailbox under tenant-wide SOA | `New-Mailbox -Shared -Name "<name>" -Alias <alias>` |
| New mailbox under per-mailbox model | On-prem `New-RemoteMailbox`, license via M365 Admin Center, then `Set-Mailbox -IsExchangeCloudManaged $true` |

---
## 🎓 Learning Pointers

- **Exchange-attribute SOA and object-level SOA are two different features that happen to share the word "SOA."** `IsExchangeCloudManaged` only ever touches the Exchange-attribute bucket. Conflating it with full object-level SOA transfer (which moves identity ownership itself) is the most common scoping mistake when a customer says "we want to get off on-prem AD" — clarify which one they actually need before designing a migration plan.
- **Writeback is an allow-list, not a mirror.** Only ~10 of the ~68 cloud-editable Exchange attributes write back to on-prem AD. Any org with on-prem tooling that reads AD directly (reporting scripts, on-prem GAL-dependent apps) needs an explicit inventory of which attributes they depend on before adopting cloud management, or those values will silently drift.
- **The 24-hour buffer after the last on-prem change isn't arbitrary — it's covering worst-case sync latency plus a safety margin.** Document the org's actual observed Connect Sync cycle time and communicate the real wait period to the team doing the rollout, rather than assuming the minimum.
- **Tenant-wide SOA is designed for orgs that are already fully migrated — not as an accelerant to finish migrating.** Enabling it early breaks new on-prem-created recipients in a way with no self-service recovery path. Treat it as a "flip this last, not first" setting.
- **This feature is Microsoft's stated on-ramp for retiring the Last Exchange Server**, not a general-purpose hybrid attribute-editing convenience. Frame rollout conversations around that end goal — see [Decommission the last Exchange Server](https://learn.microsoft.com/en-us/exchange/hybrid-deployment/decommission-last-exchange-server) for the full sequencing (Exchange-attribute SOA → object-level SOA → LES decommission).
- Full attribute-by-attribute editable/writeback map (105 rows: identity vs. Exchange, cmdlet, and parameter for each): [Cloud-based management of Exchange attributes for Remote Mailboxes](https://learn.microsoft.com/en-us/exchange/hybrid-deployment/enable-exchange-attributes-cloud-management)

