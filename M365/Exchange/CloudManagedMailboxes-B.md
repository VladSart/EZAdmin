# Cloud-Managed Remote Mailboxes — Hotfix Runbook (Mode B: Ops)
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

Run these first — identify which side (on-prem AD vs. EXO) currently owns the mailbox's Exchange attributes:

```powershell
# 1. Confirm the mailbox is directory-synced and check current SOA state
Get-Mailbox -Identity <User> | Format-List DisplayName, IsDirSynced, IsExchangeCloudManaged

# 2. Confirm Entra Connect Sync build (must be 2.5.190.0+ once any mailbox is cloud-managed)
Get-ADSyncGlobalSettings | Select-Object -ExpandProperty Parameters | Where-Object {$_.Name -like "*ServerConfigurationVersion*"}
# Or, on the Connect server:
(Get-ADSyncGlobalSettings).Parameters['Microsoft.Synchronize.ServerConfigurationVersion']

# 3. Confirm Cloud Sync provisioning agent version (required for writeback — 1.1.1107.0+)
Get-AzureADConnectHealthAADSyncMachine -ErrorAction SilentlyContinue
# Faster: check locally on the agent server —
# C:\Program Files\Microsoft Azure AD Connect Provisioning Agent\AADConnectProvisioningAgent.exe → Properties → Details

# 4. Check whether tenant-wide SOA is enabled (affects how NEW mailboxes behave)
Get-OrganizationConfig | Format-List BlockExchangeProvisioningFromOnPremEnabled

# 5. Find every mailbox currently cloud-managed (fleet view)
Get-Mailbox -ResultSize Unlimited | Where-Object { $_.IsDirSynced -eq $true -and $_.IsExchangeCloudManaged -eq $true } |
    Select-Object DisplayName, PrimarySmtpAddress, IsExchangeCloudManaged
```

**Interpretation Table:**

| Symptom | Likely Cause | Go To |
|---------|-------------|-------|
| `Set-Mailbox -IsExchangeCloudManaged $true` fails or is silently ignored | Mailbox isn't directory-synced, or is a group/contact (not supported — use object-level SOA instead) | Fix 1 |
| Attribute edited in EXO reverts on next sync cycle | SOA never actually transferred, or on-prem `Set-RemoteMailbox` is still running against it | Fix 2 |
| Attribute edited in EXO isn't appearing on-prem | Writeback not configured, or attribute isn't on the writeback-supported list | Fix 3 |
| Sync agent pushes fail after enabling cloud management | Entra Connect Sync build older than `2.5.190.0` | Fix 4 |
| First/last name edit rejected in EXO | Expected — identity attributes (givenName, sn, displayName, etc.) are **never** editable in EXO, even after SOA transfer | Fix 5 (explain, don't "fix") |
| New on-prem mailboxes are broken/half-provisioned after enabling tenant-wide SOA | Tenant-wide SOA enabled before all on-prem mailboxes were migrated — unsupported sequencing | Fix 6 (Microsoft Support required) |
| Offboarding a cloud-managed mailbox back to on-prem breaks sync | `IsExchangeCloudManaged` wasn't set back to `$false` before the move | Fix 7 |

---
## Dependency Cascade

<details><summary>What must be true for cloud-managed attributes (and writeback) to work</summary>

```
User is directory-synchronized (IsDirSynced = True)
    └── Mailbox exists in Exchange Online
        └── Entra Connect Sync ≥ 2.5.190.0 installed (prevents push failures against SOA-transferred mailboxes)
            └── Set-Mailbox -IsExchangeCloudManaged $true (per-mailbox SOA transfer — Phase 1, GA)
                └── Exchange attributes now editable via EXO PowerShell / EAC / M365 Admin Center
                    (identity attributes: still on-prem AD only, always)
                └── OPTIONAL: Writeback (Phase 2, GA)
                    └── Microsoft Entra Cloud Sync installed (coexists with Connect Sync — does not replace it)
                        └── Provisioning agent ≥ 1.1.1107.0, status "Active" in Entra admin center
                            └── "EXO to AD attribute sync" Cloud Sync configuration created + provisioning started
                                └── Changes to writeback-supported attributes sync EXO → on-prem AD (~20 min cycle)
                                    └── CLOUD-MANAGED MAILBOX + WRITEBACK FUNCTIONAL
```
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the mailbox is eligible**
```powershell
Get-Mailbox -Identity <User> | Format-List RecipientTypeDetails, IsDirSynced, IsExchangeCloudManaged
```
Expected: `IsDirSynced = True`. If `False`, this is a cloud-only mailbox — `IsExchangeCloudManaged` doesn't apply (attributes are already cloud-native). If the object is a mail-enabled group or mail contact, this feature doesn't apply — see [Learning Pointers](#-learning-pointers) for the correct feature.

**Step 2 — Confirm sync freshness before flipping the switch**
```powershell
# On-prem: check when Set-RemoteMailbox last ran against this user
Get-RemoteMailbox -Identity <User> | Format-List WhenChanged
```
Expected: allow one full sync cycle **plus 24 hours** after the last on-prem `Set-RemoteMailbox` change before setting `IsExchangeCloudManaged = $true`. Flipping too early causes a race where on-prem still overwrites EXO on the next cycle.

**Step 3 — Transfer SOA and verify**
```powershell
Set-Mailbox -Identity <User> -IsExchangeCloudManaged $true
Get-Mailbox -Identity <User> | Format-List Identity, IsExchangeCloudManaged
```
Expected: `IsExchangeCloudManaged: True`. If it reverts to `False` on its own, on-prem Connect Sync build is likely below `2.5.190.0` — go to Fix 4.

**Step 4 — Test an Exchange-attribute edit**
```powershell
Set-Mailbox -Identity <User> -CustomAttribute1 "ModifiedInTheCloud"
Get-Mailbox -Identity <User> | Format-List CustomAttribute1
```
Expected: change takes and sticks (doesn't revert on next sync). If it reverts, SOA transfer didn't actually apply — repeat Step 3 and re-check Step 2's timing.

**Step 5 — Test writeback (if configured)**
```powershell
# In EXO:
Set-Mailbox -Identity <User> -CustomAttribute1 "TestValue_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
# Wait ~20 minutes, or trigger Provision on demand in the Entra admin center (Cloud Sync configuration → Provision on demand)
# Then, in on-prem Exchange Management Shell:
Get-RemoteMailbox -Identity <User> | Format-List CustomAttribute1
```
Expected: value matches. If not, go to Fix 3.

**Step 6 — Check for identity-attribute confusion**
```powershell
# This will fail/be ignored even on a cloud-managed mailbox — identity attributes are on-prem-only, always:
Set-Mailbox -Identity <User> -DisplayName "New Name"   # Wrong tool
# Correct: change givenName/sn/displayName on-prem, let Connect Sync push it
```

---
## Common Fix Paths

<details><summary>Fix 1 — SOA transfer command fails or has no effect</summary>

**Use when:** `Set-Mailbox -IsExchangeCloudManaged $true` errors or the property won't stick.

```powershell
# Confirm the object type and sync state first — this feature is USER MAILBOXES ONLY
Get-Mailbox -Identity <User> | Select-Object RecipientTypeDetails, IsDirSynced

# If RecipientTypeDetails is not a mailbox type (e.g. it's a MailUniversalDistributionGroup or MailContact):
# This feature does not apply. Use Group SOA or Contact SOA transfer instead:
#   Group SOA:   https://learn.microsoft.com/en-us/entra/identity/hybrid/how-to-group-source-of-authority-configure
#   Contact SOA: https://learn.microsoft.com/en-us/entra/identity/hybrid/how-to-user-source-of-authority-configure#configure-contact-soa

# If it IS a synced user mailbox and the command still fails, confirm role assignment:
# Caller needs Exchange Administrator (recommended), Hybrid Identity Administrator, or Global Administrator
```

**Rollback:** N/A — no change was applied if the command failed.
</details>

<details><summary>Fix 2 — Edited attribute keeps reverting to the on-prem value</summary>

**Use when:** You set `IsExchangeCloudManaged = $true`, edited an attribute in EXO, and it snapped back to the old value on the next sync.

```powershell
# 1. Re-confirm the flag actually took effect
Get-Mailbox -Identity <User> | Format-List IsExchangeCloudManaged

# 2. If it shows True but still reverts, on-prem Set-RemoteMailbox may still be running against this user
#    (e.g. a scheduled provisioning script). Find and stop it before retrying.

# 3. Confirm you waited a full sync cycle + 24h after the LAST on-prem change before the SOA flip
#    (see Diagnosis Step 2) — if not, wait it out and re-apply the edit.

# 4. Re-apply the edit and re-verify after one more sync cycle
Set-Mailbox -Identity <User> -CustomAttribute1 "ModifiedInTheCloud"
```

**Rollback:** If cloud management isn't wanted after all, transfer SOA back — see Fix 7.
</details>

<details><summary>Fix 3 — Writeback isn't reaching on-prem AD</summary>

**Use when:** EXO-side edits work and stick, but never appear on-prem.

```powershell
# 1. Confirm the attribute is actually on the writeback-supported list (NOT every Exchange attribute writes back —
#    e.g. HiddenFromAddressListsEnabled, LitigationHoldEnabled, and most msExch* flags are EXO-only, no writeback)
#    Writeback-supported set includes: mail (proxy/WindowsEmailAddress), proxyAddresses, extensionAttribute1-15,
#    msExchExtensionCustomAttribute1-5, msExchRecipientDisplayType/TypeDetails. See -A.md attribute table for the full map.

# 2. Confirm the Cloud Sync writeback configuration exists and is running
#    Entra admin center → Identity → Hybrid management → Microsoft Entra Connect → Cloud Sync → Configurations
#    Look for the "EXO to AD attribute sync" job — Status should be "Healthy"/provisioning, not paused or errored.

# 3. Confirm the provisioning agent is Active and at the required build
#    Entra admin center → Cloud Sync → Agents → status must be "Active"
#    Locally: C:\Program Files\Microsoft Azure AD Connect Provisioning Agent\AADConnectProvisioningAgent.exe
#             → Properties → Details → version must be 1.1.1107.0 or later

# 4. If writeback was configured DURING PUBLIC PREVIEW, the "mail" attribute mapping may be missing
#    (auto-added only for configs created on/after 2026-08-03). Check Attribute Mappings tab for a direct
#    Mail (source) -> mail (target) mapping. If absent, use "Restore default mappings" in the configuration
#    (note: this clears custom mappings/scoping filters — record them first).

# 5. Force an immediate sync instead of waiting ~20 minutes:
#    Configuration -> Provision on demand -> search the user -> Provision
```

**Rollback:** Pausing the writeback job (Overview tab → Pause provisioning) stops further writeback without deleting the configuration.
</details>

<details><summary>Fix 4 — Entra Connect Sync build too old (push failures)</summary>

**Use when:** After enabling cloud management for any mailbox, on-prem Connect Sync repeatedly tries to push Exchange attributes to already-SOA-transferred mailboxes and fails.

```powershell
# Check current build (run on the Connect server):
(Get-ADSyncGlobalSettings).Parameters['Microsoft.Synchronize.ServerConfigurationVersion']
```

**Fix:** Upgrade Microsoft Entra Connect Sync to build `2.5.190.0` or later. Download the latest build and follow the standard in-place upgrade path — see [Upgrade from a previous version](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-upgrade-previous-version). No mailbox or SOA state is lost during the upgrade.

**Rollback:** N/A — this is a required forward upgrade, not a reversible config change.
</details>

<details><summary>Fix 5 — User expects to edit name/title fields from EXO (won't work — by design)</summary>

**Use when:** Someone reports "I turned on cloud management but I still can't change the user's display name from Exchange Online."

This is expected behavior, not a bug. `IsExchangeCloudManaged` only transfers SOA for **Exchange-specific attributes** (mailbox settings, custom attributes, proxy addresses, etc.). **Identity attributes** — `displayName`, `givenName`, `sn`, `title`, `department`, `manager`, `userPrincipalName`, `usageLocation`, and others — remain on-premises Active Directory attributes permanently under this feature. They must be changed on-prem and synced down as usual.

If the org's actual goal is to stop touching on-prem AD entirely for a user (not just Exchange attributes), that requires a separate, later step: **object-level Source of Authority transfer** — see the [Learning Pointers](#-learning-pointers) section.
</details>

<details><summary>Fix 6 — Tenant-wide SOA enabled too early (broken new-mailbox provisioning)</summary>

**Use when:** Tenant-wide SOA (`Set-OrganizationConfig -ExchangeAttributesCloudManagedByDefault`) was enabled while on-prem Exchange recipients were still being created, and new users are landing as plain Entra ID users instead of provisioning a mailbox.

```powershell
# 1. STOP creating/synchronizing new on-prem Exchange recipients immediately

# 2. Disable the tenant-wide default (does not fix already-affected users):
Set-OrganizationConfig -ExchangeAttributesServerManagedByDefault

# 3. Confirm it's disabled:
Get-OrganizationConfig | Format-List BlockExchangeProvisioningFromOnPremEnabled
# Expect: False
```

**Do not** attempt to self-remediate already-affected users — there is no supported self-service path to move a broken cloud object back to a proper on-prem-provisioned MailUser once this state occurs. **Escalate to Microsoft Support** with the affected UPNs. Do not continue mailbox provisioning/migration for those users until Support resolves it.

**Rollback:** None — this is a "stop digging and call Support" scenario, not a self-service fix.
</details>

<details><summary>Fix 7 — Offboarding a cloud-managed mailbox back to on-prem</summary>

**Use when:** A cloud-managed mailbox needs to move back to on-prem Exchange management (e.g. reverting a pilot, or migrating the mailbox itself back on-prem).

```powershell
# 1. Back up current cloud values before transferring SOA back — there is no automatic restore
Get-Mailbox -Identity <User> | Select-Object CustomAttribute1,CustomAttribute2,CustomAttribute3,ProxyAddresses,
    EmailAddresses | Format-List
Get-User -Identity <User> | Select-Object AssistantName | Format-List

# 2. Transfer SOA back to on-premises BEFORE attempting to move the mailbox itself
Set-Mailbox -Identity <User> -IsExchangeCloudManaged $false

# 3. Manually re-apply any values captured in step 1 to the on-prem RemoteMailbox object if they need to persist
Set-RemoteMailbox -Identity <User> -CustomAttribute1 "<value from step 1>"
```

**Why this order matters:** if you try to offboard/move a mailbox while `IsExchangeCloudManaged` is still `$true`, on-prem updates are blocked from applying and the offboarding sync breaks. Always flip the flag back to `$false` first.

**Rollback:** Not applicable — this fix path *is* the rollback for cloud management.
</details>

---
## Escalation Evidence

Copy, fill blanks, paste into ticket:

```
CLOUD-MANAGED REMOTE MAILBOX ESCALATION
========================================
Tenant:                    <tenantName>.onmicrosoft.com
Affected mailbox(es):      <UPN(s)>
IsDirSynced:                [ ] True  [ ] False
IsExchangeCloudManaged:      [ ] True  [ ] False  [ ] Reverting on its own

Sync method in use:
  [ ] Entra Connect Sync only   [ ] Entra Connect Sync + Cloud Sync (writeback)   [ ] Cloud Sync only

Entra Connect Sync build:    <version — must be 2.5.190.0+>
Cloud Sync agent version:    <version — must be 1.1.1107.0+ for writeback>
Cloud Sync agent status:     [ ] Active  [ ] Inactive  [ ] Not installed

Writeback configuration:
  Configuration exists:      [ ] Yes  [ ] No
  Job status:                <Healthy / Paused / Error / N/A>
  "Mail -> mail" mapping present:  [ ] Yes  [ ] No  [ ] N/A (created pre-2026-08-03, not restored)

Tenant-wide SOA (BlockExchangeProvisioningFromOnPremEnabled):  [ ] True  [ ] False

Attribute affected:         <e.g. CustomAttribute1, proxyAddresses, mail>
Expected value:              <value>
Actual value (EXO):          <value>
Actual value (on-prem AD):   <value>

Last on-prem Set-RemoteMailbox change (WhenChanged):  <timestamp>
Time since last on-prem change:                        <hours>
IsExchangeCloudManaged flip timestamp:                 <timestamp>

Recent changes (last 30 days):  <Connect/Cloud Sync upgrades, tenant-wide SOA toggles, migration activity>
```

---
## 🎓 Learning Pointers

- **This feature transfers Exchange-attribute SOA only — not object-level SOA.** The user's identity (`displayName`, `givenName`, `userPrincipalName`, group membership, etc.) stays on-premises Active Directory forever under `IsExchangeCloudManaged`. A separate, later capability — **object-level SOA transfer** for users/groups/contacts — is what fully moves identity ownership to Entra ID as part of an on-prem AD decommission. See [Configure user Source of Authority](https://learn.microsoft.com/en-us/entra/identity/hybrid/how-to-user-source-of-authority-configure). Don't conflate the two when scoping a "get off on-prem Exchange" project.
- **The 24-hour wait after the last on-prem change is not optional.** Flipping `IsExchangeCloudManaged` to `$true` too soon after an on-prem `Set-RemoteMailbox` edit creates a race condition where the pending sync cycle overwrites the cloud value. This is the single most common cause of "I set it and it didn't stick" tickets.
- **Cloud Sync doesn't replace Connect Sync for this feature — it runs alongside it.** Writeback specifically requires the Cloud Sync provisioning agent even in a Connect Sync-only environment. Don't uninstall Connect Sync thinking Cloud Sync now owns the whole pipeline; it only owns the writeback path.
- **Tenant-wide SOA is a one-way door if enabled too early.** Read the Fix 6 warning carefully before recommending `Set-OrganizationConfig -ExchangeAttributesCloudManagedByDefault` to a customer who hasn't finished migrating every on-prem mailbox — the failure mode has no supported self-service recovery.
- This is Microsoft's stated on-ramp for **Last Exchange Server (LES) decommission** — once every mailbox's Exchange-attribute SOA is cloud-managed, the on-prem Exchange server is no longer required just to edit mailbox properties. See [Decommission the last Exchange Server](https://learn.microsoft.com/en-us/exchange/hybrid-deployment/decommission-last-exchange-server).
- MS Docs — full attribute-by-attribute writeback map: https://learn.microsoft.com/en-us/exchange/hybrid-deployment/enable-exchange-attributes-cloud-management
