# Windows Backup for Organizations (Windows Settings Backup and Restore) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

Run these first. Results tell you which fix path to take.

```powershell
# 1. Confirm this is actually the right feature — NOT OneDrive Known Folder Move (files), a different topic
#    Windows Backup for Organizations (now "Windows settings backup and restore") backs up SETTINGS +
#    the Microsoft Store APP LIST only. It does not back up documents, desktop files, or user data.

# 2. Confirm join type and OS build meet backup requirements
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|WorkplaceJoined"
[System.Environment]::OSVersion.Version

# 3. Confirm the backup policy is actually applied and enabled (Intune Settings Catalog / GPO / CSP)
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -ErrorAction SilentlyContinue

# 4. Confirm the four "must not be Disabled" companion policies are not blocking backup silently
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed","PublishUserActivities","UploadUserActivities" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GroupPolicy" -Name "EnableCdp" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Connectivity" -Name "AllowConnectedDevices" -ErrorAction SilentlyContinue

# 5. Confirm restore-specific config if the ticket is about OOBE/first-sign-in restore, not backup itself
#    (restore is a SEPARATE policy from backup, disabled by default even when backup is enabled)
```

| If | Then |
|----|------|
| Client describes losing desktop files, documents, or folders after a device refresh | This is NOT Windows Backup for Organizations — that's OneDrive Known Folder Move, a different feature/topic entirely → **Fix 1** (redirect) |
| Device is Entra registered (Workplace Joined) only, not joined/hybrid joined | Feature requires Entra joined or Entra hybrid joined — registered-only devices are not eligible, full stop | → **Fix 2** |
| OS build is below the documented minimum for the Windows version | Silently ineligible — no error surfaced anywhere in the UI | → **Fix 2** |
| Backup policy shows Enabled but no backup ever ran | One of the four companion policies (EnableActivityFeed/PublishUserActivities/UploadUserActivities/EnableCDP/AllowConnectedDevices) is set to Disabled somewhere in the policy stack | → **Fix 3** |
| Client mixed GPO and Intune/CSP configuration for this feature | Unsupported combination — "avoid mixing," produces unexpected/inconsistent results | → **Fix 4** |
| Backup works, but the OOBE restore option never appears on a new device | Restore is a separate policy, disabled by default — confirm the correct one of TWO restore-policy paths (enrollment-time vs. post-enrollment) was actually configured | → **Fix 5** |
| Restore fails with "You don't have access to this" / "You can't get there from here" during OOBE | Conditional Access is blocking the token the restore service needs — requires a CA exclusion for the restore app ID | → **Fix 6** |
| Unexpected phishing-resistant MFA (PRMFA) prompt appears during OOBE, especially in a Hyper-V VM test | Authentication Strength CA policy enforcing PRMFA with Intune apps excluded — use TAP for VM/lab testing instead | → **Fix 7** |
| Autopilot self-deploying mode device, OOBE restore option never shows | OOBE restore is documented as user-driven-mode-only — self-deploying mode is not supported for this feature | → **Fix 8** |
| Client wants their backed-up data deleted/exported (offboarding, GDPR request) | Use the Graph `windowsSetting` API, not a device-side action | → **Fix 9** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Device meets minimum OS build for its Windows version (silently ineligible below it — no error)
        │
Device is Microsoft Entra joined OR Microsoft Entra hybrid joined (registered-only = not eligible)
        │
User signs in with Microsoft Entra ID
        │
Backup policy configured — Intune Settings Catalog OR GPO OR CSP (NEVER mix GPO+CSP for this feature)
   ("Enable Windows Backup" = Enabled)
        │
FOUR companion policies must NOT be Disabled (any one of them blocks backup silently, no error):
   EnableActivityFeed | PublishUserActivities | UploadUserActivities | EnableCDP | AllowConnectedDevices
        │
Backup scheduled task runs automatically every 8 days (or manual trigger via Windows Backup app)
   → backs up SETTINGS + Microsoft Store APP LIST ONLY — never user files/documents (that's OneDrive KFM)
        │
[If restore is wanted] a SEPARATE restore policy, disabled by default, must ALSO be configured:
   ├─ Enrollment policy (tenant-wide, Intune Devices > Enrollment) — required for OOBE restore
   │     — Entra joined only (NOT hybrid), Autopilot user-driven mode only (NOT self-deploying)
   └─ Post-enrollment policy (Settings Catalog "Enable Windows Restore") — first-sign-in restore path
        │
Conditional Access does not block the restore app's token acquisition
   (app ID d32c68ad-72d2-4acb-a0c7-46bb2cf93873 needs a CA exclusion if CA applies to "All cloud apps")
        │
User signs in during OOBE / first sign-in with the SAME Entra ID account used for backup
        │
Settings + app list restored
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm this is genuinely the right topic before anything else:**
If the complaint is about lost documents, desktop files, or folders — stop here and redirect to OneDrive Known Folder Move (`M365/SharePoint-OneDrive/Sync-Issues-B.md`). This feature has no file-backup capability whatsoever; conflating the two wastes significant troubleshooting time.

**2. Confirm device eligibility (join type + OS build):**
```powershell
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|WorkplaceJoined"
[System.Environment]::OSVersion.Version
```
`WorkplaceJoined: YES` with `AzureAdJoined: NO` and `DomainJoined: NO` → registered-only, not eligible — Fix 2. Build below the documented minimum for that Windows version/release → also Fix 2 (there is no partial-support state; it's fully off).

**3. Confirm the backup policy landed and is enabled:**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -ErrorAction SilentlyContinue
```
Absent or not set to Enabled → policy never applied; check Intune deployment/assignment or GPO linking before assuming a client-side fault.

**4. Confirm the four companion policies are not silently blocking backup:**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed","PublishUserActivities","UploadUserActivities" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GroupPolicy" -Name "EnableCdp" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Connectivity" -Name "AllowConnectedDevices" -ErrorAction SilentlyContinue
```
If ANY of these five values (three under System, one under GroupPolicy, one under Connectivity) is explicitly `0`/Disabled anywhere in the effective policy stack — GPO or CSP — backup silently does not occur. This is the single most common "backup policy says Enabled but nothing ever backs up" root cause, and none of these five policies are obviously related to backup by name — Fix 3.

**5. Confirm GPO/CSP aren't mixed:**
Check whether this device is receiving Windows Backup settings from both a linked GPO and an Intune Settings Catalog/CSP policy simultaneously. Microsoft explicitly documents this combination as unsupported and a source of unexpected results — Fix 4.

**6. If the ticket is about restore rather than backup, confirm which restore policy path was configured:**
```powershell
# Post-enrollment restore policy trace (Settings Catalog "Enable Windows Restore")
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Backup" -ErrorAction SilentlyContinue
```
OOBE restore specifically requires the separate tenant-wide **enrollment** policy (Intune Devices > Enrollment > Windows Backup and Restore), not the post-enrollment Settings Catalog policy — these are two independent switches and only the enrollment one affects the OOBE experience. First-sign-in restore (post-enrollment, newer capability) uses the Settings Catalog path instead — Fix 5.

**7. If restore fails with an access-denied-style error during OOBE, suspect Conditional Access:**
The restore flow needs to silently acquire a token as part of sign-in; a CA policy scoped to "All cloud apps" (rather than excluding this specific service) blocks it with a generic-looking access error that doesn't obviously point at CA — Fix 6.

---

## Common Fix Paths

<details><summary>Fix 1 — Client actually means OneDrive Known Folder Move, not this feature</summary>

**Symptom:** Complaint involves lost documents, Desktop, Pictures, or other user files after a device swap/refresh.

Windows Backup for Organizations (Windows settings backup and restore) backs up **Windows settings and preferences, plus the list of installed Microsoft Store apps — nothing else.** It has never had file/document backup capability at any point in its history. File continuity across device swaps is OneDrive Known Folder Move's job (`M365/SharePoint-OneDrive/Sync-Issues-B.md`), a completely separate configuration surface.

**Rollback:** N/A — diagnostic redirect only.

</details>

<details><summary>Fix 2 — Device fails eligibility (join type or OS build)</summary>

**Symptom:** Backup never runs; no error is shown anywhere in Settings or Event Viewer that clearly says "ineligible."

```powershell
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|WorkplaceJoined"
[System.Environment]::OSVersion.Version
```

Confirm against current minimum builds (verify against `Windows/_AGENT.md` or MS Learn at time of ticket, since these builds shift with each cumulative update baseline):
- Windows 10 22H2, Windows 11 22H2/23H2/24H2 each have their own separate minimum build for backup
- Must be Microsoft Entra joined or Microsoft Entra hybrid joined — Entra-registered-only (BYOD/personal) devices are never eligible

There is no remediation beyond meeting the requirement itself — update the device to a qualifying build, or re-provision the join type if it's registered-only and organizationally owned.

**Rollback:** N/A — eligibility fix, not a configuration rollback.

</details>

<details><summary>Fix 3 — One of the four companion policies is silently blocking backup</summary>

**Symptom:** The main "Enable Windows Backup" policy shows Enabled, the device is eligible, but no backup has ever completed and the Windows Backup app shows no history.

```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed","PublishUserActivities","UploadUserActivities" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GroupPolicy" -Name "EnableCdp" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Connectivity" -Name "AllowConnectedDevices" -ErrorAction SilentlyContinue
```

If any of `EnableActivityFeed`, `PublishUserActivities`, `UploadUserActivities`, `EnableCdp`, or `AllowConnectedDevices` is explicitly set to `0` (Disabled) by ANY policy source (GPO or Intune, including a policy set for an unrelated reason — these are general activity-feed/connected-devices policies, not backup-specific), Windows Backup will not occur. None of these five are named anything like "backup," which is exactly why they're missed — a security baseline or privacy-hardening GPO disabling "activity feed" for unrelated reasons is a very plausible silent cause.

Remediate by ensuring none of the five are set to Disabled (Not Configured or Enabled are both fine) in whichever policy engine (GPO/Intune) is authoritative for this device.

**Rollback:** Re-disable if a specific one of these was intentionally hardened for a documented security reason — escalate the conflict to whoever owns that policy rather than silently overriding it.

</details>

<details><summary>Fix 4 — GPO and CSP/Intune configuration mixed for this feature</summary>

**Symptom:** Inconsistent behavior across a device fleet — some devices back up, others don't, despite apparently identical Intune assignment, or settings that don't match what either the GPO or the Intune policy alone specifies.

Confirm whether this device is simultaneously receiving:
- A linked Group Policy Object configuring Windows Backup settings, AND
- An Intune Settings Catalog policy or CSP-based configuration for the same feature

Microsoft explicitly states this combination is unsupported and can lead to unexpected results — it is not merely "the more restrictive one wins" the way overlapping GPOs typically resolve. The fix is picking exactly one management channel (GPO for domain-joined-managed-via-GPO devices, Intune for cloud-managed) and removing the other's configuration for this specific feature.

**Rollback:** Re-apply whichever channel was removed if this wasn't actually the cause — this is a diagnostic finding, not automatically the root cause on every mixed-management device.

</details>

<details><summary>Fix 5 — Restore doesn't appear despite backup working</summary>

**Symptom:** Users are confirmed to have backup data (`Get windowsSetting` via Graph returns results), but the restore option never appears during OOBE on a replacement device, or the first-sign-in restore prompt never triggers.

Restore is governed by an entirely separate policy from backup, and is disabled by default. Two distinct configuration paths exist depending on which restore experience is wanted:

```powershell
# OOBE restore requires the TENANT-WIDE ENROLLMENT policy specifically —
# Intune admin center > Devices > Enrollment > Windows Backup and Restore > Show restore page: On
# This is NOT the same as a device configuration policy and only takes effect for devices
# enrolling AFTER the setting is changed — it does not retroactively apply to already-enrolled devices.
```

For **first-sign-in restore** (the newer, broader-eligibility path — works on hybrid-joined and multi-user devices, unlike OOBE restore) confirm the post-enrollment Settings Catalog policy is assigned:

| Category | Setting name | Value |
|---|---|---|
| Windows Backup And Restore | Enable Windows Restore | Enabled |

Confirm build minimums for the specific restore path in use — first-sign-in restore requires a materially newer build than OOBE restore.

**Rollback:** N/A — enabling additional policy, no destructive change.

</details>

<details><summary>Fix 6 — Conditional Access blocks restore with an access-denied error</summary>

**Symptom:** During OOBE or first sign-in, restore fails with "You don't have access to this" or "You can't get there from here," even though the user's credentials are correct and the device meets all eligibility requirements.

This happens when a Conditional Access policy scoped to "All cloud applications" evaluates against the restore service's own app registration and blocks it (commonly via a device-compliance or app-protection requirement that can't be satisfied yet, since the device is still mid-setup).

**Fix:** Create a CA policy exclusion for the Microsoft restore service app ID:
```
d32c68ad-72d2-4acb-a0c7-46bb2cf93873
```
Verify this app ID is present in the exclusion list of any CA policy scoped broadly enough to catch it, then retry the restore flow.

**Rollback:** Remove the exclusion if it was added in error or the org's CA posture requires re-evaluation — but confirm the restore flow is expected to be blocked in that case (it will be).

</details>

<details><summary>Fix 7 — Unexpected PRMFA prompt during OOBE (often surfaced in Hyper-V VM testing)</summary>

**Symptom:** An unexpected phishing-resistant MFA challenge appears during the OOBE restore flow, and the test/lab device (frequently a Hyper-V VM) has no compatible authenticator available.

This occurs when all three of the following are true: the org enforces PRMFA via an Entra ID Authentication Strength Conditional Access policy, the Microsoft Intune app IDs (`0000000a-0000-0000-c000-000000000000` and `d4ebce55-015a-49b5-a083-c84d1797ae8c`) are excluded from that same policy, and the user is enrolling without having previously registered a strong authentication method.

**In VM/lab scenarios specifically:** PRMFA (Windows Hello for Business, FIDO2 key, etc.) is genuinely difficult to satisfy inside a Hyper-V VM during OOBE. Use a **Temporary Access Pass (TAP)** for VM-based testing rather than trying to force a hardware-bound authenticator into a virtualized OOBE session.

**Rollback:** N/A — this is expected behavior for the described policy combination, not a fault to be reverted.

</details>

<details><summary>Fix 8 — Autopilot self-deploying mode device never shows OOBE restore</summary>

**Symptom:** OOBE restore works reliably on user-driven Autopilot deployments but never appears on self-deploying-mode devices, even with an eligible backup profile and correct enrollment restore policy.

This is documented, not a bug: OOBE restore requires **Autopilot user-driven mode**. Self-deploying mode (kiosk/shared-device/no-user-interaction scenarios) is explicitly unsupported for the restore prompt, since the flow inherently requires interactive user sign-in during setup — something self-deploying mode is designed to avoid.

**Rollback:** N/A — confirm this is by design; if restore is genuinely required for this device population, the Autopilot profile itself needs to move to user-driven mode, which is a separate, larger change with its own implications.

</details>

<details><summary>Fix 9 — Client requests backup data export/deletion (offboarding, GDPR)</summary>

**Symptom:** A departing user's data needs to be reviewed, exported, or purged from the organization's backup data store, or a data-subject-request obligates data deletion.

This is done via Microsoft Graph, not any device-side or Windows Backup app action:

```http
# Requires UserWindowsSettings.Read.All (read/export) or UserWindowsSettings.ReadWrite.All (delete)
GET    /users/{id}/windowsSettings
DELETE /users/{id}/windowsSettings/{windowsSettingId}
```

Confirm consent for the relevant Graph permission has been granted before attempting either call.

**Rollback:** Deletion is not reversible — confirm this is the intended action (e.g., a genuine offboarding or DSR) before executing, since a deleted backup profile cannot be un-deleted.

</details>

---

## Escalation Evidence

```
=== Windows Backup for Organizations Failure — Ticket Evidence ===

Date/Time:                        _______________
Device name / User UPN:           _______________
Windows version / build:          _______________
Join type (Entra/Hybrid/Reg-only):_______________
Reported symptom:                 _______________  (backup not running / restore missing / CA block / PRMFA / wrong-feature)

--- Commands Run ---
dsregcmd join state:                        _______________
Backup policy (SettingSync) state:          _______________
Companion policies (5) all non-Disabled:    _______________  (Y/N — which one, if any, is Disabled)
GPO+CSP mixed configuration detected:       _______________  (Y/N)
Restore policy configured (which path):     _______________  (Enrollment / Post-enrollment / Neither)
Autopilot mode (user-driven/self-deploy):   _______________
Conditional Access exclusion present:       _______________  (app ID d32c68ad-72d2-4acb-a0c7-46bb2cf93873)

--- Steps Taken ---
[ ] Confirmed this isn't actually an OneDrive KFM (file backup) ticket
[ ] Confirmed device eligibility (join type + OS build)
[ ] Checked backup policy applied and Enabled
[ ] Checked all five companion policies for a silent Disabled block
[ ] Checked for mixed GPO+CSP configuration
[ ] Confirmed correct restore policy path (enrollment vs. post-enrollment) for the restore scenario in question
[ ] Checked Conditional Access exclusion for restore app ID if an access error was reported
```

---

## 🎓 Learning Pointers

- **This feature backs up settings and the Store app list — never files.** The single most common ticket-routing mistake is treating any "we lost data after a device swap" complaint as this feature's problem. Always confirm what was actually lost before troubleshooting; if it's documents or Desktop files, the correct topic is OneDrive Known Folder Move, not this one. [MS Docs: Windows Backup for Organizations Overview](https://learn.microsoft.com/en-us/windows/configuration/windows-backup/)

- **Five unrelated-sounding policies can silently block backup with zero error surfaced anywhere.** `EnableActivityFeed`, `PublishUserActivities`, `UploadUserActivities`, `EnableCDP`, and `AllowConnectedDevices` all have to be non-Disabled for backup to run — none of their names suggest a connection to Windows Backup, making them easy to overlook when a security-hardening GPO or Intune baseline disables "Activity Feed" or "connected devices" for an unrelated privacy reason. Always check all five before assuming a deeper problem.

- **26H2 changes the default posture, but only for backup — restore is still opt-in.** Starting with Windows 11 26H2, backup is enabled by default on eligible Entra-joined/hybrid-joined devices as a new resilience baseline. This does NOT mean restore starts working automatically — admins must still explicitly configure a restore policy (enrollment or post-enrollment) for the OOBE/first-sign-in restore experience to ever appear. [MS Docs: New Resilience Baseline](https://aka.ms/NewResilienceBaseline)

- **OOBE restore and first-sign-in restore are two different features with different eligibility requirements**, not two names for the same thing. OOBE restore needs Entra-joined-only + Autopilot user-driven mode + the tenant-wide enrollment policy. First-sign-in restore (the newer capability) works on hybrid-joined devices too, including Windows 365 Cloud PCs, and uses the separate post-enrollment Settings Catalog policy. Confirm which one a client actually wants before configuring.

- **Starting July 2026, Enterprise State Roaming (ESR) management moved under this same feature's umbrella** — the user-facing Settings toggles ("Remember my preferences"/"Remember my apps") now control both Windows Backup for Organizations AND ESR simultaneously, and are only interactive if IT has enabled at least one of the two. If a client has existing ESR configuration, factor that overlap in before assuming Windows Backup and ESR are independent, unrelated systems going forward. [MS Docs: Enterprise State Roaming](https://learn.microsoft.com/en-us/windows/configuration/windows-backup/catalog-esr)

- **GCCH/Sovereign cloud and China tenants don't have this feature at all** — confirm cloud environment before spending time troubleshooting what will otherwise look like a total, unexplained failure.
