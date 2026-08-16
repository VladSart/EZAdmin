# Windows Backup for Organizations (Windows Settings Backup and Restore) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the settings/app-list continuity model, not just the fix commands.

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
- Windows Backup for Organizations — Microsoft's current name transition is to **Windows settings backup and restore**; both names appear across documentation and policy surfaces during the transition and refer to the same feature
- Backup: Windows settings/preferences and the Microsoft Store installed-app list, scheduled (every 8 days) and manual triggers
- Restore: both supported paths — during OOBE (device enrollment) and during first sign-in (post-enrollment, newer capability)
- Eligibility requirements (OS build, join type) for both backup and restore independently
- Policy configuration surfaces: Intune Settings Catalog, GPO, and CSP — and the explicit unsupported-combination warning
- The five companion policies that silently gate backup functionality
- Conditional Access and Authentication Strength interference during the restore flow
- Microsoft Graph `windowsSetting` resource for data export/deletion
- The July 2026 Enterprise State Roaming (ESR) management consolidation, at a disambiguation level

**Out of scope:**
- **OneDrive Known Folder Move (KFM) / OneDrive sync** — file and document continuity, an entirely separate feature with no code-level relationship to this one beyond both being part of a "device refresh/migration" conversation. Covered in `M365/SharePoint-OneDrive/Sync-Issues-A.md`. This disambiguation is the single most important thing to get right before troubleshooting either.
- **Enterprise State Roaming's own pre-2026 architecture** (IE favorites, legacy app data roaming, the older IE/Edge-favorites-specific roaming mechanism) — genuinely out of scope here; this topic covers only the point where ESR management surfaces now live under the same UI/policy umbrella as of July 2026, not ESR's own historical mechanics.
- **Windows Autopilot provisioning itself** (device enrollment, ESP, profile assignment) — covered in `Autopilot/`. This topic only touches Autopilot at the single point where OOBE restore's mode requirement (user-driven only) intersects it.
- **User Experience Virtualization (UE-V)** or other legacy third-party settings-roaming tooling — architecturally unrelated predecessor technologies, not migration targets covered here.
- **Full Windows backup/system-image tools** (File History, legacy Windows 7 Backup and Restore, third-party imaging) — this feature is not a disk image or file-level backup tool of any kind.

**Assumptions:**
- Tenant is a commercial Microsoft 365/Entra ID tenant (not GCCH/Sovereign/China — this feature isn't available there)
- Devices are managed via Intune, GPO, or a combination understood to be non-mixed for this specific feature
- Reader has Intune Service Administrator or Global Administrator access for enrollment-policy-related troubleshooting

---

## How It Works

<details><summary>Full architecture</summary>

### What Actually Gets Backed Up — and the Naming Confusion Worth Addressing Upfront

Windows Backup for Organizations backs up exactly two categories of data: **user settings and preferences** (grouped into categories a user or admin can selectively include/exclude — accessibility settings, personalization, language preferences, and similar), and the **list of installed Microsoft Store applications** (so they can be re-installed and reappear on the Start menu after a restore — the apps themselves aren't packaged into the backup, only the reference to reinstall them).

It does **not** back up: documents, Desktop files, Pictures, or any user-generated content; Win32/desktop (non-Store) application installations or their data; browser history/bookmarks beyond what's covered by browser-native sync; or anything resembling a disk image or system-state backup. The feature's name (still transitioning from "Windows Backup for Organizations" to "Windows settings backup and restore" across Microsoft's own documentation and policy surfaces as of mid-2026) is itself a common source of scope confusion — "Backup" reads to most IT staff and end users as "my files are backed up," which is never true here. Explicitly confirming scope with a client before troubleshooting is worth the thirty seconds it takes, since a genuine data-loss ticket routed here wastes real time.

### The Backup Cycle

Once policy-enabled, backup runs as an automatic scheduled task **every 8 days**, with no admin-configurable interval — a user can also trigger a backup manually at any time via the Windows Backup app (search "Windows Backup" in the Start menu search box, select **Back up**). There is no bulk/fleet-wide "back up now" administrative trigger; each device backs up on its own independent 8-day cycle from whenever the policy first applied to it, which means a freshly-enrolled device's first automatic backup can lag by up to 8 days unless a user manually triggers one.

### Eligibility Is Independently Gated for Backup vs. Restore, and Again Independently for Each Restore Path

This is the single most load-bearing structural fact about the feature: **backup eligibility, OOBE-restore eligibility, and first-sign-in-restore eligibility are three separate requirement sets**, each with its own minimum OS build and its own join-type constraint, and none of the three imply the others.

| Capability | Minimum builds (as of mid-2026 documentation) | Join type | Additional constraint |
|---|---|---|---|
| **Backup** | Win10 22H2 19045.6216+; Win11 22H2 22621.5768+ / 23H2 22631.5768+ / 24H2 26100.4946+ | Entra joined OR Entra hybrid joined | None |
| **OOBE restore** | Win11 22H2 22621.3958+ / 23H2 22631.3958+ / 24H2 26100.4770+ | **Entra joined only** (not hybrid) | Autopilot **user-driven mode only**; at least one backup profile must already exist for the signing-in user |
| **First-sign-in restore** | Win11 24H2 26100.7922+ / 25H2 26200.7922+ | Entra joined OR Entra hybrid joined (broader — also supports multi-user and Windows 365 Cloud PC scenarios) | Device must have already completed enrollment; triggers on the user's first sign-in after enrollment, not during OOBE itself |

A device can be fully eligible for backup and completely ineligible for either restore path (most commonly: hybrid-joined devices on an OS build that predates first-sign-in restore's minimum, which satisfies backup's more permissive requirements but neither restore path's stricter ones). None of this surfaces as an error anywhere in the UI — a device simply doesn't offer the option it doesn't qualify for, with no diagnostic message pointing at which specific requirement failed.

### Configuration Surface: Three Channels, One Explicit Anti-Pattern

Windows Backup for Organizations can be configured via **Intune Settings Catalog**, **CSP** (directly, for non-Intune MDM or custom deployment scenarios), or **Group Policy**. Microsoft's own documentation states plainly: **do not mix GPO and CSP/MDM configuration for this feature** — "Avoid mixing GPO and CSP policy settings for Windows Backup for Organizations, as it can lead to unexpected results." Unlike many other Windows policy areas where GPO and MDM/CSP settings for genuinely different features simply coexist, or where a documented precedence order resolves conflicts predictably (MDM generally winning on Entra-joined devices per the standard Policy CSP conflict-resolution behavior), this feature's own documentation doesn't commit to a predictable winner when both channels configure it — the practical guidance is to pick one channel per device population and stay there.

**Backup** configuration:

| Category | Setting name | Value |
|---|---|---|
| Administrative Templates\Windows Components\Sync your settings | Enable Windows Backup | Enabled |

**Restore** configuration has two genuinely independent policy objects, not one policy with two names:

1. **Enrollment policy** (Intune-specific, tenant-wide): Devices > Enrollment > Windows Backup and Restore > "Show restore page" = On. This is applied **only at the moment of device enrollment** — before standard MDM policy configuration takes effect — specifically so the restore page can be shown during OOBE, which happens before any normal device-configuration policy would have had a chance to apply through the usual refresh cycle. Changing this setting has **zero retroactive effect** on already-enrolled devices; it only governs devices enrolling from that point forward. Configuring or changing it requires Intune Service Administrator or Global Administrator role — a materially higher bar than the Intune Policy/Profile Manager role sufficient for most other device configuration policies in this repo's other topics.
2. **Post-enrollment policy** (Settings Catalog, applies via normal policy refresh like any other device configuration policy):

   | Category | Setting name | Value |
   |---|---|---|
   | Windows Backup And Restore | Enable Windows Restore | Enabled |

This second policy governs **first-sign-in restore** specifically, and behaves like every other Settings Catalog policy — it takes effect on the device's next policy refresh, with no enrollment-time special casing.

### The Five Silent Backup-Blocking Companion Policies

Backup depends on five separate Windows policies remaining **non-Disabled** (Not Configured or Enabled are both fine — only an explicit Disabled blocks it):

- `EnableActivityFeed`, `PublishUserActivities`, `UploadUserActivities` (Computer Configuration > Administrative Templates > System > OS Policies)
- `EnableCDP` (ADMX_GroupPolicy Policy CSP)
- `AllowConnectedDevices` (Connectivity Policy CSP)

None of these five carry "backup" in their name — they're the underlying Connected Devices Platform (CDP) and activity-feed/Timeline infrastructure Windows Backup for Organizations is built on top of, originally surfaced for Timeline/Cloud Clipboard/cross-device-experience features. A security-hardening baseline or privacy-focused GPO that disables "Activity Feed" for reasons entirely unrelated to Windows Backup (a very plausible, common configuration in security-conscious environments) silently breaks Windows Backup as a side effect, with **zero cross-referencing anywhere in the Windows Backup policy documentation or UI** pointing back at this dependency. This is architecturally the same class of gotcha as `AD-GroupPolicy-A.md`'s GPC/GPT two-part-replication-disagreement pattern and `DDM-A.md`'s cross-feature-dependency issues elsewhere in this repo — a feature quietly depending on infrastructure that predates it and was never designed with it in mind.

### Conditional Access and the OOBE Restore Token

Restore requires the device to silently acquire an Entra ID access token as part of the OOBE/first-sign-in flow, scoped to the Microsoft restore service application (`d32c68ad-72d2-4acb-a0c7-46bb2cf93873`). If a Conditional Access policy applies broadly to "All cloud applications" — a common baseline CA configuration — it evaluates against this app too, and if it can't be satisfied at that point in setup (device compliance state not yet established, since the device is mid-provisioning; app protection policy requirements that don't apply to a system service; etc.), the user sees a generic, unhelpful access-denied page (**"You don't have access to this"** / **"You can't get there from here"**) that gives no indication the actual cause is CA scope, not a genuine permissions problem. The documented fix is a CA policy exclusion for that specific app ID — narrowing "All cloud applications" CA policies is a known, expected operational step for any tenant adopting this feature with a broad CA baseline already in place, not a security regression.

A related, distinct issue can surface for tenants enforcing **Phishing-Resistant MFA (PRMFA)** via an Authentication Strength CA policy: if the Intune app IDs (`0000000a-0000-0000-c000-000000000000` and `d4ebce55-015a-49b5-a083-c84d1797ae8c`) are excluded from that PRMFA policy (a common configuration, since Intune enrollment itself often needs to happen before a strong authenticator is registered) and the user enrolls without a pre-registered strong auth method, the **separate restore experience app** (`74d197dc-b84d-4d43-a1b2-b5bf3bb91c11`) is not covered by that same exclusion and prompts for PRMFA anyway during OOBE. In Hyper-V VM test/lab scenarios this is a genuine dead end (VM-based OOBE has no practical path to a hardware-bound authenticator) — Microsoft's own documented workaround for VM testing is a Temporary Access Pass (TAP), not attempting to satisfy PRMFA inside the VM.

### Data Governance — Graph API, Not a Device-Side Control

Backed-up settings data lives in the organization's tenant data store, independent of any specific device. Viewing, exporting, or deleting a user's backup profile(s) is a Graph operation against the `windowsSetting` resource:

- `GET /users/{id}/windowsSettings` — requires `UserWindowsSettings.Read.All`
- `DELETE /users/{id}/windowsSettings/{id}` — requires `UserWindowsSettings.ReadWrite.All`

There is no admin-center UI blade for this in the Intune console as of current documentation — it's Graph-API-only, meaning any offboarding runbook or DSR (data subject request) process needs a scripted step rather than a portal click-through, and any MSP handling client offboarding should have this scripted ahead of time rather than discovering the Graph-only requirement mid-request.

### The July 2026 Enterprise State Roaming Consolidation

As of July 2026, **management of Enterprise State Roaming (ESR)** — Microsoft's older mechanism for roaming certain Windows/app settings and enterprise data via Azure, predating this feature — **moved under Windows settings backup and restore's own management surface.** The end-user-facing toggles in Settings > Accounts > Windows backup ("Remember my preferences," "Remember my apps") now control both systems simultaneously, and are only interactive (not greyed out) if IT has enabled *either* Windows Backup or ESR — a tenant with only legacy ESR configured and no Windows Backup for Organizations policy will still see these toggles as live, which can read as "Windows Backup is on" when it's actually ESR alone governing them. This repo does not yet carry dedicated ESR architecture coverage — flag any client with pre-existing ESR configuration for a closer look at how their specific ESR policies now interact with this consolidated surface, rather than assuming the two remain fully independent going forward.

</details>

---

## Dependency Stack

```
Tenant is commercial (not GCCH/Sovereign/China) — feature doesn't exist in those environments
    │
Device meets the SPECIFIC minimum build for the capability in question (backup / OOBE restore /
    first-sign-in restore each have their OWN independent minimum — none imply the others)
    │
Device join type matches capability requirement:
    Backup              → Entra joined OR Entra hybrid joined
    OOBE restore        → Entra joined ONLY (hybrid explicitly excluded)
    First-sign-in restore → Entra joined OR Entra hybrid joined (broadest — also Windows 365 Cloud PC)
    │
Policy applied via EXACTLY ONE channel — Intune Settings Catalog, CSP, or GPO
    (mixing GPO+CSP for this feature is explicitly documented as unsupported, unpredictable)
    │
FIVE companion policies non-Disabled (Not Configured or Enabled — only explicit Disabled blocks):
    EnableActivityFeed | PublishUserActivities | UploadUserActivities | EnableCDP | AllowConnectedDevices
    — none named "backup," inherited from unrelated Activity-Feed/CDP infrastructure, zero cross-reference
      in the feature's own docs/UI pointing back at this dependency
    │
Backup scheduled task (8-day cycle, no admin-configurable interval) OR manual trigger via Windows Backup app
    → settings + Microsoft Store app LIST only, never files/documents (that's OneDrive KFM's job)
    │
[If restore is wanted] a SEPARATE, independently-configured restore policy — TWO possible paths,
    NOT interchangeable:
    ├─ Enrollment policy (tenant-wide, Intune Devices > Enrollment) → OOBE restore
    │     requires Entra-joined-only + Autopilot USER-DRIVEN mode only + Intune Service/Global Admin to set
    │     zero retroactive effect on already-enrolled devices
    └─ Post-enrollment Settings Catalog policy ("Enable Windows Restore") → first-sign-in restore
          applies via normal policy refresh like any other device configuration policy
    │
Conditional Access does not block token acquisition for the restore app
    (d32c68ad-72d2-4acb-a0c7-46bb2cf93873 — needs explicit CA exclusion if a policy scopes "All cloud apps")
[If PRMFA enforced] separate restore-experience app (74d197dc-b84d-4d43-a1b2-b5bf3bb91c11) is
    NOT automatically covered by an Intune-app PRMFA exclusion — VM/lab OOBE needs a TAP, not a
    hardware authenticator workaround
    │
User signs in during OOBE/first-sign-in with the SAME Entra ID account used for backup
    │
Settings + Store app list restored (files/documents are NEVER part of this restore — OneDrive KFM's
    own sync resumes independently, on its own separate dependency chain)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Client reports lost documents/Desktop files after a device swap | Wrong feature entirely — this backs up settings/app-list only, never files | Confirm scope before troubleshooting; redirect to OneDrive KFM if files are the actual complaint |
| Backup policy shows Enabled, device is eligible, but no backup ever completes | One of five companion policies (EnableActivityFeed/PublishUserActivities/UploadUserActivities/EnableCDP/AllowConnectedDevices) is Disabled somewhere in the effective policy stack | Check all five explicitly — none are named "backup" |
| Inconsistent backup behavior across an otherwise-identical device fleet | GPO and CSP/Intune both configuring this feature on the same devices — explicitly unsupported mixing | Confirm which single channel is authoritative per device; remove the other |
| Device is Entra hybrid joined, backup works fine, but OOBE restore option never appears | OOBE restore requires Entra-joined-only — hybrid-joined devices are explicitly excluded from this specific restore path | Confirm join type against the OOBE-restore-specific requirement, not the (more permissive) backup requirement |
| First-sign-in restore doesn't trigger even though the enrollment restore policy is configured | Enrollment policy governs OOBE restore only — first-sign-in restore needs the SEPARATE post-enrollment Settings Catalog policy | Confirm the correct one of the two independent restore policies was configured for the desired restore path |
| Restore fails with a generic access-denied error during OOBE | Conditional Access scoped to "All cloud apps" blocking the restore service app's token acquisition | Check for a CA exclusion covering app ID `d32c68ad-72d2-4acb-a0c7-46bb2cf93873` |
| Unexpected PRMFA prompt during OOBE, especially inside a Hyper-V VM | PRMFA Authentication Strength CA policy excludes Intune app IDs but not the separate restore-experience app ID | Use a TAP for VM/lab OOBE testing; confirm the restore app ID isn't inadvertently caught by the PRMFA policy in production |
| Autopilot self-deploying-mode device never offers OOBE restore | Documented — OOBE restore supports user-driven mode only | Confirm Autopilot profile mode; this is by design, not a fault |
| A device enrolled before the enrollment-restore-policy change still doesn't show OOBE restore after the tenant setting was turned on | Enrollment policy is applied only AT enrollment time — it has zero retroactive effect on already-enrolled devices | Re-enrollment (not a policy refresh) is required for the change to take effect on that device |
| Toggles in Settings > Accounts > Windows backup are interactive even though the org "hasn't configured Windows Backup" | ESR (Enterprise State Roaming) is separately enabled and, since July 2026, shares these same toggles | Check for pre-existing ESR configuration before assuming Windows Backup itself is what's driving the visible toggle state |
| Need to export or delete a former employee's backup data | No admin-center UI exists for this — Graph API only | Use `GET`/`DELETE /users/{id}/windowsSettings` with the appropriate `UserWindowsSettings.*` permission |

---

## Validation Steps

**1. Confirm tenant cloud environment supports the feature at all:**
Commercial Microsoft 365/Entra ID only — GCCH/Sovereign clouds and China are explicitly unsupported. Confirm this first for any government/sovereign-cloud client before investigating further.

**2. Confirm device join type and OS build against the SPECIFIC capability being tested (not a generic "is it eligible" check):**
```powershell
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|WorkplaceJoined"
[System.Environment]::OSVersion.Version
```
Cross-reference the exact build against whichever of the three independent requirement sets (backup / OOBE restore / first-sign-in restore) is relevant to the ticket — don't assume backup eligibility implies restore eligibility.

**3. Confirm policy is applied through exactly one channel:**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -ErrorAction SilentlyContinue
```
If this device is also domain-joined and receiving a GPO that touches the same settings, flag the mixed-channel risk even if values currently look consistent — behavior under mixed management is documented as unpredictable, not "GPO wins" or "CSP wins" in a fixed order.

**4. Confirm all five companion policies are non-Disabled:**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed","PublishUserActivities","UploadUserActivities" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GroupPolicy" -Name "EnableCdp" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Connectivity" -Name "AllowConnectedDevices" -ErrorAction SilentlyContinue
```
Expected: none of the five explicitly `0`. A missing key is equivalent to Not Configured (fine); an explicit `0` is the blocking state.

**5. Confirm which restore policy (if any) is actually configured, matched to the restore path being tested:**
- OOBE restore → check the Intune tenant-wide enrollment setting (portal-only, no local registry trace on an already-enrolled device — the setting only affected this device's initial enrollment moment)
- First-sign-in restore → check the post-enrollment Settings Catalog policy landed via normal MDM policy evidence (Event Viewer `Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin`, or `Get-ItemProperty` under the Backup policy registry path)

**6. If a restore access error was reported, confirm the CA exclusion:**
```
Check the CA policy applicable to "All cloud applications" (or a broad app group including it) for an
exclusion entry matching d32c68ad-72d2-4acb-a0c7-46bb2cf93873
```

**7. Confirm actual backup data exists for the user in question before troubleshooting restore further:**
```http
GET https://graph.microsoft.com/v1.0/users/{id}/windowsSettings
```
No backup profile returned → the problem is upstream in backup, not restore; redo backup-side validation first.

---

## Troubleshooting Steps (by phase)

### Phase 1: Scope Confirmation

1. Confirm the actual complaint is about settings/app-list continuity, not file/document loss — redirect immediately to OneDrive KFM coverage if it's the latter.
2. Confirm tenant cloud environment supports the feature.

### Phase 2: Backup-Side Eligibility and Policy

1. Confirm join type and OS build against backup's own (most permissive) requirement set.
2. Confirm exactly one policy channel (GPO or Intune/CSP) is configuring this feature for the device — flag and resolve any mixed-channel finding before troubleshooting further.
3. Confirm all five companion policies are non-Disabled.
4. If still no backup after 8+ days with no manual trigger attempted, have the user manually trigger via the Windows Backup app before assuming a deeper fault — the 8-day automatic cadence alone can explain "no backup yet" on a recently-enrolled device.

### Phase 3: Restore-Side Eligibility and Policy

1. Identify which restore path the client actually needs (OOBE vs. first-sign-in) — these have different join-type and build requirements and are governed by two independent policies, not one.
2. For OOBE restore: confirm the tenant-wide enrollment policy was set BEFORE the device in question enrolled — remember this setting has zero retroactive effect.
3. For first-sign-in restore: confirm the post-enrollment Settings Catalog policy has actually applied via normal MDM policy evidence.
4. Confirm Autopilot deployment mode is user-driven if OOBE restore is required.

### Phase 4: Authentication-Layer Interference

1. If a generic access-denied error appears during restore, check Conditional Access scope and the restore app ID exclusion.
2. If a PRMFA prompt appears unexpectedly (especially in VM/lab testing), confirm Authentication Strength CA policy scope and use a TAP for VM scenarios rather than fighting the CA policy itself.

### Phase 5: Data Governance

1. For offboarding/DSR requests, use the Graph `windowsSetting` API directly — confirm the correct permission (`Read.All` vs. `ReadWrite.All`) is consented before attempting either operation.
2. Treat deletion as irreversible in all communication with the requesting party.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield rollout: backup + first-sign-in restore for an Entra-joined fleet</summary>

```powershell
# 1. Confirm target devices meet the OS build minimums for BOTH backup and first-sign-in restore
#    before assigning policy — assigning to ineligible devices produces silent no-ops, not errors.

# 2. Deploy the backup policy via Intune Settings Catalog:
#    Administrative Templates\Windows Components\Sync your settings\Enable Windows Backup = Enabled

# 3. Deploy the restore policy via Intune Settings Catalog (separate policy object):
#    Windows Backup And Restore\Enable Windows Restore = Enabled

# 4. Explicitly verify none of the five companion policies are Disabled in ANY existing baseline
#    or security policy already assigned to the same device group — check before rollout, not after
#    the first "why isn't this working" ticket.

# 5. Do NOT also configure this feature via GPO for the same devices, even partially/experimentally.
```

**Rollback:** Set "Enable Windows Backup" to Disabled to stop future backups; existing backed-up data remains in the tenant store until explicitly deleted via Graph (see Playbook 3).

</details>

<details><summary>Playbook 2 — Add OOBE restore support for a hardware-refresh Autopilot fleet</summary>

```powershell
# 1. Confirm the Autopilot deployment profile for this device population is USER-DRIVEN mode.
#    Self-deploying-mode profiles cannot use OOBE restore at all — this is a hard product limitation,
#    not a policy to configure around.

# 2. In the Intune admin center (portal-only, no PowerShell equivalent for this specific tenant-wide
#    enrollment setting): Devices > Enrollment > Windows Backup and Restore > Show restore page: On
#    Requires Intune Service Administrator or Global Administrator role to change.

# 3. This setting affects ONLY devices enrolling from this point forward. If devices have already
#    been enrolled and need OOBE restore capability, they must be re-enrolled (wipe + re-provision) —
#    there is no retroactive activation path for already-enrolled devices.

# 4. Confirm backup policy (Playbook 1) is ALSO in place and users have at least one backup profile
#    before the hardware refresh — OOBE restore has nothing to restore from otherwise.
```

**Rollback:** Set "Show restore page" to Off — again, only affects devices enrolling after the change; already-enrolling devices mid-OOBE at the moment of the change may see inconsistent behavior depending on exact timing.

</details>

<details><summary>Playbook 3 — Offboarding data governance via Graph</summary>

```http
# 1. Confirm the departing user's backup profile(s) exist
GET https://graph.microsoft.com/v1.0/users/{userId}/windowsSettings
Authorization: Bearer {token with UserWindowsSettings.Read.All}

# 2. If export/retention is required before deletion, capture the response body per organizational
#    offboarding/records-retention policy.

# 3. Delete the profile(s) if the offboarding process calls for it
DELETE https://graph.microsoft.com/v1.0/users/{userId}/windowsSettings/{windowsSettingId}
Authorization: Bearer {token with UserWindowsSettings.ReadWrite.All}
```

**Rollback:** None — deletion is permanent. Confirm export/retention needs are satisfied BEFORE the delete call, not after.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Windows Backup for Organizations evidence for escalation
.NOTES     Run locally on the affected device as an administrator
#>

$OutputDir = "C:\Temp\WindowsBackup-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. Device identity and join state
dsregcmd /status | Out-File "$OutputDir\dsregcmd-status.txt"
[System.Environment]::OSVersion.Version | Out-File "$OutputDir\OS-Build.txt"

# 2. Backup policy state
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -ErrorAction SilentlyContinue |
    Out-File "$OutputDir\BackupPolicy.txt"

# 3. The five companion policies
$companionPolicies = [ordered]@{
    "System\EnableActivityFeed"      = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    "System\PublishUserActivities"   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    "System\UploadUserActivities"    = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    "GroupPolicy\EnableCdp"          = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GroupPolicy"
    "Connectivity\AllowConnectedDevices" = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Connectivity"
}
$companionPolicies.GetEnumerator() | ForEach-Object {
    $propName = ($_.Key -split '\\')[-1]
    [PSCustomObject]@{
        Policy = $_.Key
        Value  = (Get-ItemProperty -Path $_.Value -Name $propName -ErrorAction SilentlyContinue).$propName
    }
} | Export-Csv "$OutputDir\CompanionPolicies.csv" -NoTypeInformation

# 4. Restore policy trace (post-enrollment path only — enrollment-time policy has no local trace)
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Backup" -ErrorAction SilentlyContinue |
    Out-File "$OutputDir\RestorePolicy.txt"

# 5. Recent MDM policy application events
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" -MaxEvents 200 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match "Backup|SettingSync" } |
    Select-Object TimeCreated, Id, Message |
    Export-Csv "$OutputDir\MDM-BackupEvents.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Join type — always check first, requirement differs by capability (backup vs. each restore path)
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|WorkplaceJoined"

# OS build — cross-reference against the SPECIFIC capability's own minimum
[System.Environment]::OSVersion.Version

# Backup policy state
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -ErrorAction SilentlyContinue

# The five companion policies that silently block backup if ANY is Disabled
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed","PublishUserActivities","UploadUserActivities" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GroupPolicy" -Name "EnableCdp" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Connectivity" -Name "AllowConnectedDevices" -ErrorAction SilentlyContinue

# Post-enrollment restore policy trace (first-sign-in restore path — OOBE restore's enrollment
# policy has NO local registry trace, it's a tenant-wide portal-only setting)
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Backup" -ErrorAction SilentlyContinue

# Manually trigger a backup (user-initiated, via the Windows Backup app UI — no CLI equivalent documented)
# Start-Process "ms-settings:backup"   # opens Settings > Accounts > Windows backup

# Graph — check a user's existing backup profile(s) before troubleshooting restore
# GET https://graph.microsoft.com/v1.0/users/{userId}/windowsSettings  (UserWindowsSettings.Read.All)

# Graph — delete a user's backup data (offboarding/DSR — irreversible)
# DELETE https://graph.microsoft.com/v1.0/users/{userId}/windowsSettings/{id}  (UserWindowsSettings.ReadWrite.All)

# Recent MDM policy application events, filtered for backup-related entries
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" -MaxEvents 200 |
    Where-Object { $_.Message -match "Backup|SettingSync" } | Select TimeCreated, Id, Message
```

---

## 🎓 Learning Pointers

- **The name itself is the biggest source of misrouted tickets.** "Windows Backup for Organizations" (transitioning to "Windows settings backup and restore") sounds like general-purpose data protection to almost everyone outside the small group of engineers who've read the actual scope. It backs up settings and a Store app list — nothing else, ever. Confirming scope before troubleshooting is the highest-leverage first step in this entire topic. [MS Docs: Windows Backup for Organizations Overview](https://learn.microsoft.com/en-us/windows/configuration/windows-backup/)

- **Backup, OOBE restore, and first-sign-in restore are three independently-gated capabilities, not one feature with a single on/off switch.** Each has its own minimum OS build and its own join-type requirement, and a device eligible for one is routinely ineligible for another — most commonly, hybrid-joined devices that qualify for backup but are hard-excluded from OOBE restore specifically. Always confirm which of the three is actually in question before checking eligibility.

- **Five policies with no obvious connection to "backup" can silently break it.** `EnableActivityFeed`, `PublishUserActivities`, `UploadUserActivities`, `EnableCDP`, and `AllowConnectedDevices` are Connected Devices Platform / Timeline-era policies this feature was quietly built on top of. A security or privacy baseline disabling "Activity Feed" for reasons having nothing to do with Windows Backup is a completely plausible, silent root cause — and nothing in this feature's own documentation or UI cross-references the dependency.

- **The enrollment-time OOBE restore policy has zero retroactive effect.** This trips up admins used to standard Intune device configuration policies, where a policy change eventually reaches every targeted device on its next check-in. This specific setting only ever applies at the literal moment of enrollment — an already-enrolled device needs to be wiped and re-enrolled, not just wait for a policy refresh, to pick up a later change to this setting.

- **Windows 11 26H2's default-enablement change affects backup only, not restore.** It's easy to assume "enabled by default now" means the whole feature, including restore, is now hands-off — it isn't. Restore remains fully opt-in and requires deliberate admin configuration on both available paths regardless of the 26H2 baseline change. [MS Docs: New Resilience Baseline](https://aka.ms/NewResilienceBaseline)

- **Enterprise State Roaming's July 2026 management consolidation means the user-facing Settings toggles no longer map 1:1 to "is Windows Backup for Organizations configured."** A tenant with legacy ESR policy and no Windows Backup for Organizations policy at all will still show live, interactive toggles — worth checking for pre-existing ESR configuration before concluding Windows Backup itself is what's active on a given device. [MS Docs: Enterprise State Roaming](https://learn.microsoft.com/en-us/windows/configuration/windows-backup/catalog-esr)
