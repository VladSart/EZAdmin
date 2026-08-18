# Group Writeback v2 → Cloud Sync Group Provisioning Migration — Reference Runbook (Mode A: Deep Dive)
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
- Migrating cloud-created security groups written back to on-premises Active Directory via **Microsoft Entra Connect Sync Group Writeback v2** (a public preview feature, deprecated and unsupported since 30 June 2024) to **Microsoft Entra Cloud Sync's Group Provisioning to Active Directory** feature
- The full documented 7-step migration procedure, including the `msDS-ExternalDirectoryObjectID` reference-attribute prerequisite and the attribute-scoped `cloudNoFlow`/`JoinNoFlow` coexistence rule pair
- Scale limits, licensing, and naming-convention differences between the two writeback mechanisms
- The irreversible `Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false` cutover step and its side effects

**Does not cover:**
- **Group Writeback v1** — the older, still-supported (no announced end-of-support date) mechanism that continues to handle mail-enabled Microsoft 365 group writeback regardless of this migration. This file's migration path explicitly excludes mail-enabled groups/DLs.
- **General Cloud Sync agent installation, health, and provisioning mechanics** (gMSA, quarantine, disconnected-forest sync) — see `CloudSync-A.md`/`-B.md`
- **The broader Connect Sync → Cloud Sync sync-engine migration** (users/contacts/OU-scoped `cloudNoFlow`) — see `CloudSyncMigration-A.md`/`-B.md`. That topic's coexistence rule pair is scoped by **OU**; this topic's is scoped by **attribute filter** (`cloudMastered`/`mail`) — the two are not interchangeable templates.
- **Governing on-premises AD-based (Kerberos) applications via group writeback and entitlement management access packages** — a related but distinct scenario documented separately by Microsoft (`govern-on-premises-groups`), referenced in passing in `AccessReviews-A.md`/`LifecycleWorkflows-A.md`, not duplicated here
- **Connect Sync version/EOL lifecycle** — see `ConnectSyncUpgrade-A.md`/`-B.md`

**Assumes:**
- An existing Microsoft Entra Connect Sync deployment with Group Writeback v2 enabled and actively writing cloud security groups back to on-premises AD DS
- On-premises AD DS running Windows Server 2016, 2019, or 2022 (required for the `msDS-ExternalDirectoryObjectId` schema attribute)
- A provisioning agent will be installed/available for Microsoft Entra Cloud Sync (build 1.1.1367.0+ for the migration procedure itself; 1.1.1373.0+ for the Group Provisioning to AD feature)
- Microsoft Entra ID P1 licensing
- Hybrid Identity Administrator (Entra) and Domain Administrator (on-prem) access

---
## How It Works

<details><summary>Full architecture — why this migration exists and how it's scoped</summary>

### What Group Writeback v2 was, and why it's being retired

Group Writeback v2 was a **public preview** capability in Microsoft Entra Connect Sync that provisioned cloud-created security groups (and, in its scope, Microsoft 365 groups) back to on-premises Active Directory. Microsoft deprecated the preview and withdrew support as of **30 June 2024**. The feature continues to function for tenants that haven't migrated, but receives no fixes and can stop working without advance notice — the standard risk profile of an unsupported preview feature left running in production. This is a materially different risk posture than a GA feature nearing a published end-of-support date (contrast with `ConnectSyncUpgrade-A.md`'s hard 30 September 2026 deadline) — there is no scheduled failure date here, only an open-ended one.

### Why the migration is narrowly scoped

Microsoft's documented migration procedure applies to **exactly one** category of object: cloud-created security groups written back with **universal** scope. Two related but distinct cases are explicitly out of scope:

- **Mail-enabled groups and distribution lists** written back via either Group Writeback v1 or v2 are not covered by this migration — they aren't part of the procedure, and after v2 is disabled, Microsoft 365 groups revert to Group Writeback v1 behavior regardless (see the side-effect note below).
- **Group Writeback v1** itself is untouched by this migration and continues operating independently — it has no announced end-of-support date as of this writing.

### The reference-attribute prerequisite: why `msDS-ExternalDirectoryObjectID` matters

Cloud Sync's Group Provisioning to AD DS feature validates group membership references by querying the Active Directory **global catalog** for the `msDS-ExternalDirectoryObjectID` attribute — an indexed attribute that replicates across every global catalog in the forest. Groups that were written back by Connect Sync Group Writeback v2 carry their Entra object ID in `adminDescription` instead. Before migration, that value must be copied to `msDS-ExternalDirectoryObjectID` for every existing written-back group, or Cloud Sync has nothing to match membership references against post-cutover — the single most common root cause of "group migrated but membership looks empty or wrong" tickets for this topic.

### The coexistence mechanism — attribute-scoped, not OU-scoped

Like the broader Connect Sync → Cloud Sync migration, this procedure prevents both tools from fighting over the same objects using a custom `cloudNoFlow`/`JoinNoFlow` sync-rule pair. The key architectural difference: this pair is scoped by **attribute filter**, not by organizational unit —

- **Inbound** join rule: scope `cloudMastered EQUAL true` AND `mail ISNULL` → sets metaverse attribute `cloudNoFlow = True`. The `mail ISNULL` condition is what keeps mail-enabled groups out of this rule's scope, matching the migration's documented boundary.
- **Outbound** rule: `LinkType = JoinNoFlow`, scope `cloudNoFlow EQUAL true`.

`JoinNoFlow` is deliberately **not** equivalent to full staging (read-only) mode: it blocks object adds, object deletes, and non-reference attribute updates from exporting, but **reference attribute updates — including group membership changes — can still flow through**. This is a subtle but important distinction; a group scoped out by `cloudNoFlow` is not fully frozen from Connect Sync's perspective until Cloud Sync has actually taken over and Connect Sync's own export for that object is confirmed idle.

### The cutover switch and its side effect

`Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false` is the actual feature-disable operation, and Microsoft documents it as **irreversible**. Its side effect is easy to miss: once disabled, **all Microsoft 365 groups begin writing back to Active Directory independently of the "Writeback Enabled" setting** in the Microsoft Entra admin center — in other words, M365 group writeback reverts unconditionally to Group Writeback v1's always-on behavior for that object class, regardless of what the admin center toggle shows. This should be communicated to the customer as an explicit, expected consequence before the switch is flipped, not discovered afterward.

### Naming convention divergence

Connect Sync's default writeback naming format is `CN=Group_<guid>,OU=<container>,DC=<domain>`. Cloud Sync's default format is `CN=<display name>_<last 12 digits of object ID>,OU=<container>,DC=<domain>` — and Cloud Sync uses its own new format by default **even for groups that were written back under Connect Sync's old default naming**, meaning migrated groups get renamed unless the `CN` attribute-flow expression is explicitly overridden to reproduce the old format (`Append("Group_", [objectId])`).

</details>

---
## Dependency Stack

```
Layer 6 — Feature status (deprecation, not a scheduled EOL)
          — GWB v2 unsupported since 30 Jun 2024; functions until it breaks,
                no advance-warning mechanism for an unsupported preview feature
Layer 5 — Scope gate
          ├─ Cloud-created SECURITY groups, universal scope — IN scope
          └─ Mail-enabled groups / DLs — OUT of scope, fall back to GWB v1
Layer 4 — Prerequisites
          ├─ Hybrid Identity Administrator (Entra) + Domain Administrator (on-prem)
          ├─ AD DS schema: msDS-ExternalDirectoryObjectId (Server 2016+)
          ├─ Provisioning agent >= 1.1.1367.0 (migration) / >= 1.1.1373.0 (feature)
          ├─ Connect Sync build >= 2.2.8.0
          ├─ Agent connectivity to DCs: TCP/389 (LDAP), TCP/3268 (Global Catalog)
          └─ Entra ID P1 licensing
Layer 3 — Reference-attribute prep (MUST complete before rule/staging changes)
          └─ adminDescription -> msDS-ExternalDirectoryObjectID, per group,
                in the Group Writeback target OU
Layer 2 — Coexistence mechanism (attribute-scoped, not OU-scoped)
          ├─ Connect Sync in staging mode + scheduler disabled while rules build
          ├─ Inbound rule: cloudMastered=true AND mail=ISNULL -> cloudNoFlow=True
          └─ Outbound rule: LinkType=JoinNoFlow, scope cloudNoFlow=true
                (reference/membership attributes still flow — not full staging)
Layer 1 — Cutover
          ├─ Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false (IRREVERSIBLE;
          │       side effect: all M365 groups writeback becomes unconditional)
          └─ Cloud Sync Group Provisioning to AD job, scoped to the same
                cloud-created-security-group population
Layer 0 — Validation & scale
          ├─ Membership reference resolution (depends on Layer 3 completing)
          ├─ Group Provisioning to AD scale limits (50K members/group; 10K-20K
          │       groups depending on scoping mode)
          └─ Naming-convention reconciliation (CN attribute-flow expression)
```

A gap at Layer 3 (the `msDS-ExternalDirectoryObjectID` copy) is invisible until Layer 1's cutover completes — plan and verify it early, since it's the hardest layer to retroactively diagnose once groups are already mid-migration.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Group migrates but shows empty or broken membership in AD post-cutover | `adminDescription` was never copied to `msDS-ExternalDirectoryObjectID` before migration | Compare the two attributes for the affected group; re-run the copy script and force a Cloud Sync re-provision |
| Mail-enabled group/DL unexpectedly stops writing back after GWB v2 is disabled | Expected in most cases via GWB v1 fallback, but confirm GWB v1 itself is still enabled and functioning — it's a separate feature switch | `Get-ADSyncAADCompanyFeature` and confirm which writeback feature flags are active; re-check the admin center "Writeback Enabled" setting per group |
| M365 groups now writing back to AD when the admin center shows "Writeback Enabled" = off | Documented side effect of disabling GroupWritebackV2 — M365 group writeback becomes unconditional (GWB v1 behavior) regardless of the toggle | Confirm this was communicated in advance; if it's genuinely unwanted, GWB v1 itself needs a separate configuration change, not a re-enable of v2 |
| Groups renamed after migration (`CN=Group_<guid>` became `CN=<name>_<objectid>`) | Cloud Sync's default CN naming format differs from Connect Sync's default | Apply the `Append("Group_", [objectId])` CN attribute-flow expression override if the old naming must be preserved |
| Both Connect Sync and Cloud Sync appear to be touching the same group (flapping/duplication) | `cloudNoFlow` inbound rule's scope condition (`cloudMastered`/`mail`) isn't matching the intended groups, or the outbound `JoinNoFlow` rule's scope doesn't match the inbound rule's output | Inspect both rules' scope conditions; confirm every intended group actually has `cloudNoFlow = True` set |
| Migration stalls because agent version is too old | Provisioning agent below `1.1.1367.0` (migration) or `1.1.1373.0` (feature) | Check installed agent version against current minimums before scheduling the migration window |
| Cloud Sync Group Provisioning to AD job fails or behaves erratically at scale | Tenant exceeds documented scale limits (>50K members/group, or group/membership counts above the scoping-mode ceiling) | Re-check scoping mode (Selected security groups vs. All security groups + attribute filter) against current tenant scale |
| Permissions error when the Cloud Sync provisioning agent tries to create/update groups in AD after an agent upgrade | Service account permissions aren't reapplied automatically on upgrade — only assigned during a clean install | Run `Set-AADCloudSyncPermissions -PermissionType UserGroupCreateDelete -TargetDomain "<FQDN>" -EACredential $credential` |
| Rollback attempted after `Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false` was run | Microsoft documents this operation as irreversible — there is no supported undo | Restore from a pre-migration Connect Sync configuration backup as the only fallback; this is not a guaranteed clean reversal |

---
## Validation Steps

1. **Scope confirmed — only cloud-created security groups with universal scope are targeted.**
   ```powershell
   Get-ADGroup -Filter * -SearchBase "<Group Writeback target OU DN>" -Properties mail, GroupScope |
     Where-Object { $_.mail -or $_.GroupScope -ne 'Universal' }
   ```
   Expected: empty result (nothing mail-enabled or non-universal-scope in the migration set). Bad: any group returned here needs to be excluded and handled via GWB v1 instead.

2. **`msDS-ExternalDirectoryObjectID` matches `adminDescription` for every written-back group.**
   ```powershell
   Get-ADGroup -Filter * -SearchBase "<Group Writeback target OU DN>" -Properties adminDescription, msDS-ExternalDirectoryObjectID |
     Where-Object { $_.adminDescription -ne $_.'msDS-ExternalDirectoryObjectID' }
   ```
   Expected: empty result. Bad: any mismatch means Cloud Sync membership validation will fail for that group post-migration.

3. **Provisioning agent and Connect Sync build meet minimums.**
   Expected: agent >= `1.1.1367.0` (>= `1.1.1373.0` if configuring Group Provisioning to AD in the same pass), Connect Sync >= `2.2.8.0`. Bad: either below minimum — upgrade first.

4. **`cloudNoFlow`/`JoinNoFlow` rule pair exists with the correct attribute scope.**
   ```powershell
   Get-ADSyncRule | Where-Object { $_.Name -match 'cloudNoFlow' } | Select-Object Name, Direction, Precedence
   ```
   Expected: exactly one inbound (join, scope `cloudMastered=true AND mail=ISNULL`) and one outbound (`JoinNoFlow`, scope `cloudNoFlow=true`) rule. Bad: missing rule half, or a scope condition that doesn't match the documented filter.

5. **Full sync cycle completes cleanly immediately before the feature-disable step.**
   Expected: `Start-ADSyncSyncCycle -PolicyType Initial` completes with no export errors for in-scope groups. Bad: any export error — resolve before proceeding to the irreversible switch.

6. **Post-cutover: Cloud Sync Group Provisioning to AD job is actively provisioning the migrated groups.**
   Expected: migrated groups visible in Cloud Sync's provisioning logs, membership resolving correctly. Bad: groups not appearing, or membership showing as unresolved — revisit Validation Step 2.

7. **Post-cutover: confirm the M365-group writeback side effect was communicated and is acceptable.**
   Expected: customer explicitly aware that M365 groups now write back independently of the admin-center toggle. Bad: this surfaces as a surprise ticket after the fact.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm scope and inventory.** Pull every currently-written-back group's `mail` and `GroupScope` attributes. Separate the in-scope set (cloud-created security groups, universal scope) from anything that needs to stay on Group Writeback v1.

**Phase 2 — Complete the reference-attribute prerequisite.** Run the `adminDescription` → `msDS-ExternalDirectoryObjectID` copy script against the full in-scope group set and verify with Validation Step 2 before proceeding — this is the highest-leverage step to get right early.

**Phase 3 — Verify prerequisites.** Agent version, Connect Sync build, AD DS schema/OS version, P1 licensing, and RBAC (Hybrid Identity Administrator + Domain Administrator).

**Phase 4 — Build the coexistence rule pair in staging mode.** Place Connect Sync in staging mode, disable the scheduler, build both the inbound and outbound rules with the documented attribute scope, then exit staging mode and re-enable the scheduler.

**Phase 5 — Configure Cloud Sync's Group Provisioning to AD job**, scoped to the same in-scope group population, before flipping the feature switch — so there's minimal gap between "Connect Sync stops" and "Cloud Sync starts."

**Phase 6 — Flip the switch.** Run a full sync cycle, execute `Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false`, run a full sync cycle again. Treat this as the point of no return.

**Phase 7 — Validate and communicate.** Confirm membership resolution, confirm the M365-group writeback side effect is expected and acceptable, and document the outcome — there is no supported rollback beyond a full configuration restore.

---
## Remediation Playbooks

<details><summary>Playbook 1 — From-scratch migration, end to end</summary>

1. Inventory written-back groups; confirm in-scope set (cloud-created security, universal scope) vs. excluded set (mail-enabled/DL, stays on GWB v1).
2. Run the `adminDescription` → `msDS-ExternalDirectoryObjectID` copy script against the in-scope set; verify with the check script.
3. Confirm provisioning agent version, Connect Sync build, AD DS schema/OS, P1 licensing, and RBAC.
4. Back up the Connect Sync configuration (Import/Export settings) — the only fallback if something goes wrong before the irreversible switch.
5. Place Connect Sync in staging mode; disable the sync scheduler.
6. Create the inbound `cloudNoFlow` rule (join, scope `cloudMastered=true AND mail=ISNULL`) and the outbound `JoinNoFlow` rule (scope `cloudNoFlow=true`), via UI or the documented `New-ADSyncRule`/`Add-ADSyncAttributeFlowMapping`/`Add-ADSyncScopeConditionGroup` PowerShell sequence.
7. Exit staging mode; re-enable the sync scheduler.
8. Run a full sync cycle: `Start-ADSyncSyncCycle -PolicyType Initial`.
9. Install/configure the Cloud Sync provisioning agent if not already present; configure a Group Provisioning to AD job scoped to the in-scope group population.
10. Disable GWB v2: `Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false`. Run a full sync cycle again.
11. Validate membership resolution and provisioning activity in Cloud Sync's logs.
12. Communicate the M365-group unconditional-writeback side effect to the customer.

**Rollback:** steps 1-9 are individually reversible (remove the rule pair, disable the Cloud Sync job). Step 10 is documented as irreversible — the only fallback beyond that point is restoring the pre-migration configuration backup from step 4, which is not guaranteed to cleanly reverse a completed cutover.
</details>

<details><summary>Playbook 2 — Recovering from a missed reference-attribute prerequisite (post-migration)</summary>

1. Identify affected groups: compare `adminDescription` and `msDS-ExternalDirectoryObjectID` for every group in the (former) writeback OU.
2. Run the copy script against any mismatched groups.
3. Force a Cloud Sync re-provisioning cycle for the affected groups (via the Cloud Sync job's on-demand provisioning feature, scoped to the affected group(s) if possible, to avoid a full re-run).
4. Validate membership resolves correctly afterward.

**Rollback:** n/a — this is a corrective action, not a destructive one.
</details>

<details><summary>Playbook 3 — Preserving the original Connect Sync group-naming convention</summary>

1. Before migrating (or before the first Cloud Sync provisioning run touches existing groups), open the Cloud Sync Group Provisioning to AD job's attribute mappings.
2. Locate the `CN` attribute-flow expression and replace the Cloud Sync default with: `Append("Group_", [objectId])`.
3. Save and validate against a single test group via Cloud Sync's on-demand provisioning feature before applying broadly.

**Rollback:** revert the `CN` expression to the Cloud Sync default (`Append(Append(Left(Trim([displayName]), 51), "_"), Mid([objectId], 25, 12))`) — does not retroactively rename groups already provisioned under either expression without a further re-sync.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Group Writeback v2 -> Cloud Sync migration readiness and
             in-progress-migration evidence, for planning or ticket escalation.
.DESCRIPTION Read-only. Gathers GWB v2 feature status, in-scope/out-of-scope
             group counts, reference-attribute mismatch count, agent version,
             and cloudNoFlow rule presence. Exports to CSV.
.NOTES       Run on the Connect Sync server with the ActiveDirectory and ADSync
             modules available. Provide the Group Writeback target OU's DN.
#>

param([Parameter(Mandatory)][string]$GroupWritebackOU)

Import-Module ADSync -ErrorAction SilentlyContinue
$gwbV2Status = (Get-ADSyncAADCompanyFeature -ErrorAction SilentlyContinue).GroupWritebackV2

$props = @('mail','GroupScope','adminDescription','msDS-ExternalDirectoryObjectID')
$groups = Get-ADGroup -Filter * -SearchBase $GroupWritebackOU -Properties $props -ErrorAction SilentlyContinue

$inScope   = $groups | Where-Object { -not $_.mail -and $_.GroupScope -eq 'Universal' }
$outScope  = $groups | Where-Object { $_.mail -or $_.GroupScope -ne 'Universal' }
$mismatched = $inScope | Where-Object { $_.adminDescription -ne $_.'msDS-ExternalDirectoryObjectID' }

$agentVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent' -ErrorAction SilentlyContinue).DisplayVersion

$cloudNoFlowRules = Get-ADSyncRule -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'cloudNoFlow' }

[PSCustomObject]@{
    Server                       = $env:COMPUTERNAME
    GroupWritebackV2Enabled      = $gwbV2Status
    InScopeGroupCount            = $inScope.Count
    OutOfScopeGroupCount         = $outScope.Count
    ReferenceAttributeMismatches = $mismatched.Count
    ProvisioningAgentVersion     = $agentVersion
    CloudNoFlowRulesPresent      = ($cloudNoFlowRules.Count -gt 0)
    CollectedAt                  = Get-Date
} | Export-Csv -Path ".\GroupWritebackMigrationReadiness_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
```

---
## Command Cheat Sheet

```powershell
# Current GWB v2 feature status
Import-Module ADSync
(Get-ADSyncAADCompanyFeature).GroupWritebackV2

# Copy adminDescription -> msDS-ExternalDirectoryObjectID for all written-back groups
$gwbOU = '<DN of Group Writeback target OU>'
Get-ADGroup -Filter * -SearchBase $gwbOU -Properties adminDescription |
  Where-Object { $_.adminDescription } |
  ForEach-Object { Set-ADGroup -Identity $_.SamAccountName -Add @{'msDS-ExternalDirectoryObjectID'=$_.adminDescription} }

# Confirm the cloudNoFlow rule pair
Get-ADSyncRule | Where-Object { $_.Name -match 'cloudNoFlow' }

# Stop / start the sync scheduler around rule changes
Set-ADSyncScheduler -SyncCycleEnabled $false
Set-ADSyncScheduler -SyncCycleEnabled $true

# Force a full sync cycle
Start-ADSyncSyncCycle -PolicyType Initial

# The irreversible cutover switch
Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false

# Reapply Cloud Sync service-account permissions after an agent upgrade (not auto-applied)
Set-AADCloudSyncPermissions -PermissionType UserGroupCreateDelete -TargetDomain "<FQDN of domain>" -EACredential (Get-Credential)

# Expanded group selection for Cloud Sync job scope (>999 groups) via Graph
# POST https://graph.microsoft.com/v1.0/servicePrincipals/{servicePrincipalID}/appRoleAssignedTo

# Migration procedure reference
# https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/migrate-group-writeback

# Group Provisioning to AD DS feature reference (prereqs, scale limits)
# https://learn.microsoft.com/en-us/entra/identity/hybrid/group-writeback-cloud-sync
```

---
## 🎓 Learning Pointers

- **This is a deprecated-preview retirement, not a scheduled GA end-of-support.** GWB v2 has been unsupported since 30 June 2024 with no further scheduled failure date — it can stop working at any time without notice. Frame urgency accordingly: proactive, not reactive, but genuinely time-sensitive given the open-ended risk. [Migrate Microsoft Entra Connect Sync Group Writeback v2 to Microsoft Entra Cloud Sync](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/migrate-group-writeback)
- **`msDS-ExternalDirectoryObjectID` is the single highest-leverage prerequisite in this whole topic.** Nearly every "migrated but broken" ticket traces back to this attribute not being populated before cutover — verify it explicitly rather than assuming the copy script ran cleanly.
- **The `cloudNoFlow` mechanism here is attribute-scoped, not OU-scoped** — a genuinely different configuration from the general Connect Sync → Cloud Sync migration in `CloudSyncMigration-A.md`/`-B.md`. Don't copy one topic's rule definitions into the other.
- **`JoinNoFlow` still allows reference attributes (like group membership) to flow.** It is not equivalent to full staging/read-only mode — a common source of confusion when diagnosing "why did this membership change still happen" during a migration window.
- **`Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false` is irreversible and has a side effect beyond the switch itself** — Microsoft 365 groups begin writing back unconditionally afterward, independent of the admin-center toggle. Both facts belong in the pre-migration conversation with the customer, not the post-migration one. [Group writeback with Microsoft Entra Cloud Sync](https://learn.microsoft.com/en-us/entra/identity/hybrid/group-writeback-cloud-sync)
- **Group Provisioning to AD DS has its own scale ceilings, separate from the migration procedure itself** — up to 50,000 members per group, and a group/membership-count ceiling that depends on scoping mode (Selected security groups vs. All security groups + attribute filter). Check these against tenant scale before assuming the migrated feature will perform identically to GWB v2 at the same scale.
