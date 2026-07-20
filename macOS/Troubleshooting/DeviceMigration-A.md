# Apple Device Migration (MDM-to-MDM + Managed Migration Assistant) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers two distinct, macOS 26-era Apple features that IT tickets frequently conflate because both are triggered from Setup Assistant and both are gated by Apple Business Manager (ABM) / Apple School Manager (ASM):

1. **Device Management Migration** — the ABM/ASM "Assign Device Management" workflow that re-enrolls an organization-owned device from one MDM to another **without a factory wipe**, for iOS 26, iPadOS 26, and macOS 26 or later.
2. **Managed Migration Assistant** — an Intune-configured declarative policy (`com.apple.configuration.migration-assistant.settings`) that gives IT organizational control over which parts of a user's Home folder transfer from an old Mac to a new one during Setup Assistant, for a destination Mac on **macOS 26.4 or later**.

Both are configured and observed through **Microsoft Intune** in this repo's scope. Both are recent enough (Device Management Migration announced WWDC 2025, shipped with the OS 26 family in late 2025; Managed Migration Assistant published to Apple's deployment documentation March 24, 2026) that community troubleshooting material is thin — this runbook leans on Apple's and Microsoft's own current documentation plus early real-world migration reports rather than years of accumulated forum wisdom.

**Out of scope:**
- The pre-macOS-26 wipe-and-reenroll method of moving a device between MDMs — still the only option for devices that don't meet the OS/ownership/enrollment requirements below, and covered in `ADE-Enrollment-A.md` (Remediation Playbook 2)
- Consumer (unmanaged) Migration Assistant run by an end user outside any MDM configuration — this runbook covers the **managed/declarative** variant only
- iOS/iPadOS-specific migration behavior (app preservation via `await_device_configured`, Activation Lock handling) beyond what's needed to understand the shared architecture — the Mac-specific behaviors are the focus
- Data migration between an on-prem AD-bound Mac and a cloud-native one — that's an identity/binding change, not a data-transport one; see `Platform-SSO-A.md` and `EntraID/Troubleshooting/HybridJoin-A.md` if identity is also changing as part of the device refresh

**Assumed knowledge:** engineer understands Intune's macOS management model (ADE, Settings Catalog, DDM), has access to Apple Business Manager or Apple School Manager with sufficient role permissions, and understands the existing ADE dependency chain in `ADE-Enrollment-A.md`.

---
## How It Works

<details><summary>Device Management Migration — full architecture</summary>

Historically, moving a Mac from one MDM to another required a full erase: the outgoing MDM had to unenroll the device, ABM/ASM reassignment had to happen, and the device had to be wiped and re-run through Setup Assistant to pick up the new MDM via ADE. There was no supported way to change MDM ownership on a live, in-use device.

Starting with the iOS 26 / iPadOS 26 / macOS 26 family, Apple built device re-enrollment directly into ABM/ASM as a first-class workflow: **Assign Device Management** (marketed informally as "Migrate Devices"). The core architectural shift is that the device is never actually unmanaged during the transition — the new MDM's profile is installed *before* the old MDM's profile is removed, so continuous management coverage is maintained across the cutover, and already-installed managed apps and user data survive.

**Eligibility gate (enforced by Apple at the ABM/ASM level, invisible to and not overridable by Intune):**
- Device OS must be iOS 26, iPadOS 26, or macOS 26, or later
- Device must be organization-owned and enrolled via Automated Device Enrollment (ADE) — macOS 26+ additionally supports a device that unenrolls from ADE and re-enrolls via profile-based enrollment
- A device manually enrolled via Apple Configurator only qualifies once its 30-day provisional ownership period has elapsed
- Shared iPad is explicitly excluded
- A device configured for Return to Service with app preservation (`is_return_to_service = TRUE`) is excluded
- Migration to or from Apple Business Essentials, or to/from the built-in device management service, is not supported
- ABM/ASM accounts themselves cannot be merged — cross-ABM-account device transfers are handled case by case by Apple, not by this workflow

If a device fails any of these checks, the admin console simply won't offer the deadline option for it, and any bulk migration action against it fails silently into the ABM/ASM Activity log rather than producing an in-line error.

**Admin-initiated flow:**
1. In ABM/ASM, an admin with sufficient role (Administrator, Site Manager, or Device Enrollment Manager in ASM; the equivalent view/add/delete-device-management-services-plus-manage-default-platform-assignment permission set in ABM) selects one or more devices and chooses **Assign Device Management**, picking the destination MDM server
2. An optional **deadline** can be set — more than 1 day and less than 90 days out
3. Confirming creates an ABM/ASM Activity entry that tracks progress and can itself be stopped/cancelled before it starts (which reverts the device to its original MDM and cancels any in-flight prompts)

**Device-side flow:**
1. The user receives a notification (Notification Center on Mac; the Settings app on all OS 26 platforms once a deadline exists) inviting them to complete the migration
2. Notification frequency escalates as the deadline nears: daily, then hourly in the final 24 hours, then at 60/30/10/1-minute intervals in the final hour
3. If the user acts, they approve the change and the device fetches its new assignment from Apple, downloads and installs the new MDM's profile, and — only after that succeeds — removes the old MDM's profile
4. If the deadline passes with no user action, iPhone/iPad restart and migrate automatically; a Mac instead shows a **non-dismissible, full-screen prompt** that requires the user's local administrator credentials to proceed
5. If the device has no connectivity after the old profile is removed, it presents a Wi-Fi picker rather than failing outright — there's no timeout that abandons an offline migration; it simply waits

**What migration deliberately does *not* do:** it does not copy configuration profiles, compliance policies, Settings Catalog policies, or scripts from the old MDM to the new one. Real-world testing (multiple third-party MDM vendors, independently) confirms migration moves **enrollment, plus whatever managed apps and user data were already present on the device** — nothing more. Rebuilding policy parity in the destination MDM is a separate, must-do-first project, not something this feature automates.

**Activation Lock and FileVault continuity (mostly iOS/iPadOS-relevant, included for completeness):** migration always clears the previous service's Activation Lock and invalidates its bypass codes. The new service can choose to reapply Activation Lock by assigning a profile with `await_device_configured: true` before migration starts and sending an Activation Lock request to ABM/ASM ahead of the `DeviceConfigured` command. On Mac specifically, the new MDM can deliver a fresh FileVault escrow configuration that automatically rotates the Personal Recovery Key using the device's bootstrap token — which requires the new MDM to support bootstrap token escrow.

**Volume-purchased (VPP) app licensing is not carried over automatically.** The content token granting VPP license visibility belongs to whichever MDM currently holds it; a migration deadline longer than 30 days risks a licensing gap because unassigned apps remain usable for up to 30 days or until the developer performs a receipt check, whichever comes first, and only fully stop working once the new service unassigns them.

</details>

<details><summary>Managed Migration Assistant — full architecture</summary>

Consumer Migration Assistant has existed on macOS for years as a user-driven tool for copying data between Macs, with the user making every decision about what transfers. Managed Migration Assistant, introduced alongside macOS 26.4, embeds the same underlying transfer mechanism into Setup Assistant but hands control of *what* transfers to the organization via a declarative device management configuration, `com.apple.configuration.migration-assistant.settings`, authored and assigned through the MDM (Intune, via Settings Catalog / DDM).

**Requirements:**
- Source Mac: macOS 15 or later
- Destination Mac: macOS **26.4** or later specifically — a stricter floor than the 26.0 floor for Device Management Migration
- Destination Mac must be registered in ABM/ASM and assigned to a device management service, supervised, and enrolled via Automated Device Enrollment
- A data connection between the two Macs — Migration Assistant automatically selects the fastest available transport out of direct peer-to-peer Wi-Fi, infrastructure Wi-Fi, Ethernet, or Thunderbolt, and continues checking for a faster option mid-transfer

**Configuration model:** the declarative configuration lets an admin specify, relative to the Home folder of the user being migrated (paths require a trailing `/`):
- `RequiredPaths` — subfolders/files that must migrate regardless of user choice
- `ExcludedPaths` — subfolders/files excluded, which can be nested inside a required path to carve out an exception (e.g. require `Documents/` but exclude `Documents/Personal/`)
- Which local user accounts are not even offered for migration
- Whether system-level privacy and security settings migrate

`~/Library` is **always** migrated regardless of any of the above settings and cannot be excluded.

**What's in scope for migration:** visible and hidden folders/files in the Home folder (including things like `.ssh` and `.bash_history` unless specifically excluded), folder aliases and symlinks (though the *original* target outside the Home folder is never migrated), and privacy/security settings.

**What's explicitly out of scope, always:** file-level aliases and symlinks, anything in `/Users/Shared/` even if owned by the migrating user, the contents of `/Applications`, other System Settings, and printers/services. Apps on the new Mac come from the destination MDM's own app assignment — the same as any other new-device deployment — not from this transfer.

**End-to-end flow:**
1. On the **source** Mac, the user opens Migration Assistant and authenticates with local administrator credentials
2. On the **new** Mac, during Setup Assistant, the user selects **Transfer Your Data to This Mac**
3. The new Mac enrolls via Automated Device Enrollment with `await_device_configured` set to `true`, holding it in an await-configuration state
4. The device management service (Intune) delivers the required configurations before releasing the hold — this includes any Platform SSO-with-ADE configuration in use, and critically the `com.apple.configuration.migration-assistant.settings` declarative configuration itself, so the org's `RequiredPaths`/`ExcludedPaths` policy is in place *before* the transfer UI appears
5. Once the local user account is created, Managed Migration Assistant walks the user through transferring the Home folder contents from the source Mac

**A hard UI constraint worth knowing:** the Restore pane in Setup Assistant (governed by the `Restore` skip key) **cannot be hidden**, even under a fully locked-down configuration. Some end-user interaction with the migration prompt is unavoidable by design — plan communication around it rather than trying to script around it.

**If the source Home folder exceeds the destination's free storage,** priority goes to `RequiredPaths` content; anything outside that may be partially migrated or dropped, which is the most common driver of "some of my files didn't come over" tickets once genuine transport failures are ruled out.

**Observability:** the declarative device status channel is the one meaningful exception to this repo's usual "Intune configures it, Apple runs it, zero completion telemetry" pattern (the same shape documented for Time Machine and Content Caching elsewhere in this folder). Migration Assistant actually reports back through DDM status — both live progress during the transfer and a **post-transfer report** with date, time, total data transferred, and a list of any files that couldn't be migrated. This report is the primary artifact for triaging a "my data is missing" ticket rather than manually diffing folder contents.

</details>

---
## Dependency Stack

```
Layer 7 — Post-migration app/policy parity (never automatic)
          Destination MDM (Intune) must independently hold equivalent
          profiles, compliance policies, Settings Catalog policies, scripts,
          and app assignments to the source MDM — migration does not copy these
                              │
Layer 6 — Managed Migration Assistant declarative config (Mac-to-Mac only)
          com.apple.configuration.migration-assistant.settings assigned via
          Intune Settings Catalog/DDM to the DESTINATION device *before*
          await_device_configured releases
                              │
Layer 5 — Peer-to-peer / wired data transport (Mac-to-Mac only)
          Direct Wi-Fi, infra Wi-Fi, Ethernet, or Thunderbolt between
          source and destination Mac on a reachable network segment
                              │
Layer 4 — Setup Assistant await_device_configured hold
          Device enrolls but withholds full configuration/UI release
          until the MDM finishes delivering required configs
                              │
Layer 3 — Device eligibility gate (Apple-enforced, at ABM/ASM)
          OS 26+ (26.4+ specifically for Managed Migration Assistant
          destination), org-owned, ADE-enrolled or profile-re-enrolled,
          not Shared iPad / ABE / Return-to-Service
                              │
Layer 2 — ABM/ASM ↔ destination MDM server link
          Destination MDM added as an MDM server in ABM/ASM with a valid,
          non-expired server token + public key exchange — a SEPARATE
          link from any pre-existing ADE token the org already uses
                              │
Layer 1 — Apple Push Notification service (APNs) certificate
          Valid, not expired — underlies ALL MDM communication for both
          the outgoing and incoming MDM
                              │
Layer 0 — ABM/ASM account itself
          Not merged/mergeable across organizations; case-by-case only
          for cross-account device transfers
```

**The layer most tickets misdiagnose:** Layer 7. Because the migration itself visibly "succeeds" (device shows enrolled, deadline clears, Activity log shows complete), engineers frequently assume the job is done — the actual configuration-parity work at Layer 7 is a separate project that must be finished *before* triggering migration, not validated *after*.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Add Deadline" greyed out for one device | Device fails an eligibility requirement (OS/ownership/enrollment/Shared iPad/ABE) | `sw_vers -productVersion`; ABM/ASM device page ownership + enrollment method |
| Bulk migration action partially fails | Subset of selected devices fail eligibility | ABM/ASM Activity log per-serial detail |
| Device confirmed migrated in ABM/ASM but stays on old MDM | Destination MDM server link (token/public key) broken or expired | ABM/ASM → Settings → MDM Servers → destination server token status |
| Migration never even offered as an option tenant-wide | Destination MDM never added as an ABM/ASM MDM server entry | ABM/ASM → Settings → MDM Servers |
| All MDM commands (not just migration) failing fleet-wide | APNs certificate expired | Intune → Apple MDM Push certificate expiry |
| Mac shows non-dismissible full-screen prompt post-deadline | Expected deadline enforcement — awaiting local admin credential | User completes credential prompt; confirm connectivity |
| Mac shows Wi-Fi picker mid-migration | Device lost connectivity after old profile removed, before new one installed | Restore network access |
| Migrated device missing Wi-Fi/VPN/compliance/apps that existed before | Destination MDM wasn't pre-configured with equivalent policy (Layer 7 gap) | Compare source vs destination MDM policy inventory |
| VPP app shows license/install error post-migration | Content token not moved from old MDM to new MDM | Content token assignment in old vs new MDM |
| Migration deadline >30 days set on a device with VPP apps | Licensing grace period risk, not yet a failure | Shorten deadline or move token immediately |
| "Transfer Your Data to This Mac" never appears in Setup Assistant | Destination Mac below macOS 26.4, or not ADE/supervised | `sw_vers -productVersion`; ABM/ASM ownership/enrollment status |
| Migration Assistant transfer completes but files are missing | Home folder exceeded destination free space; non-`RequiredPaths` content dropped | Declarative status post-transfer report; destination free space |
| User reports a specific app "didn't migrate" | Expected — `/Applications` is explicitly out of scope for Managed Migration Assistant | Confirm app is (re)deployed via destination MDM's own app assignment |
| User reports `/Users/Shared` files missing | Expected — explicitly out of scope regardless of ownership | N/A, by design |
| Peer-to-peer transfer stalls or never starts | Source/destination Macs on different network segments (e.g. separate onboarding VLAN) | Confirm same-segment reachability; try Ethernet/Thunderbolt or Share Disk |
| Migration Assistant Restore pane can't be skipped in a "zero-touch" build | Explicitly not hideable by design, not a config gap | Adjust end-user communication, not policy |
| Cross-ABM-account device transfer request | ABM/ASM accounts can't be merged; this workflow doesn't support it | Escalate to Apple Business/School Manager support directly |

---
## Validation Steps

**1. Confirm both prerequisite services are healthy (shared by both mechanisms)**
```powershell
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All" -NoWelcome
Invoke-MgGraphRequest -GET "https://graph.microsoft.com/v1.0/deviceManagement/applePushNotificationCertificate" |
    Select-Object appleIdentifier, expirationDateTime
Invoke-MgGraphRequest -GET "https://graph.microsoft.com/v1.0/deviceManagement/depOnboardingSettings" |
    Select-Object -ExpandProperty value | Select-Object tokenName, tokenExpirationDateTime
```
Expected: both expiry dates well in the future. Bad: either is past or within 30 days.

**2. Confirm the destination MDM server link exists in ABM/ASM**

ABM/ASM → Settings → MDM Servers → destination server present, token status current. There is no Graph-exposed equivalent of this — it must be checked in the ABM/ASM console directly.

**3. Confirm device OS eligibility before migrating**
```bash
sw_vers -productVersion
# 26.0+  → eligible for Device Management Migration
# 26.4+  → additionally eligible as a Managed Migration Assistant destination
```

**4. Confirm device ownership/enrollment method**

ABM/ASM → Devices → Inventory → [serial] → Ownership = organization-owned; Enrollment = Automated Device Enrollment (or profile-based re-enrollment on 26+).

**5. For Managed Migration Assistant, confirm the declarative policy is assigned before migrating**
```powershell
Invoke-MgGraphRequest -GET "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=technologies has 'appleRemoteManagement'" |
    Select-Object -ExpandProperty value | Where-Object { $_.name -match "[Mm]igrat" }
```
Expected: the Migration Assistant settings policy exists and is assigned to the destination device's group **before** Setup Assistant is run on it — assigning it after enrollment starts is too late for that device.

**6. Post-migration, confirm continuous management (no gap)**

Intune → Devices → [device] → confirm `lastSyncDateTime` is recent and management state is `managed` — a genuine unenrollment gap (as opposed to expected old-profile-then-new-profile sequencing) shows as a device dropping out of Intune's managed list entirely.

**7. Post-transfer, pull the declarative status report (Managed Migration Assistant only)**

Intune → Devices → [destination Mac] → Declarative status / device configuration status blade → locate the Migration Assistant configuration entry and its transfer report (date, time, data volume, failed-file list).

---
## Troubleshooting Steps (by phase)

### Phase 1 — Pre-migration planning
- Audit the source MDM's full configuration surface (profiles, compliance policies, security baselines, scripts, app assignments) and confirm equivalents exist in the destination MDM (Intune) **before** triggering any migration — this is the single highest-leverage step, since Layer 7 gaps are the most common post-migration complaint
- Confirm every in-scope device is on macOS 26+ (or 26.4+ if Managed Migration Assistant is also in scope); schedule OS updates for any that aren't
- Set up separate ABM/ASM server token entries and, if VPP is involved, separate content tokens for old and new MDM — don't assume an existing token covers the new relationship
- Pilot with a small device batch before a fleet-wide migration deadline

### Phase 2 — Migration in flight (Device Management Migration)
- Watch the ABM/ASM Activity log for per-device success/failure rather than assuming a bulk action succeeded uniformly
- For devices approaching a set deadline with no user action, expect the escalating-notification behavior (daily → hourly → final-hour intervals) rather than treating it as a stuck state
- A device offline at the deadline simply waits at the enforcement screen — this is not a failure requiring intervention, only reconnection

### Phase 3 — Migration in flight (Managed Migration Assistant)
- Confirm both Macs can reach each other on the network before assuming a transport failure — peer-to-peer discovery requires same-segment reachability
- If discovery repeatedly fails on Wi-Fi, fall back to a wired path: Ethernet, Thunderbolt, or Apple Silicon Share Disk (Cmd+D at the Startup Options screen) as the modern equivalent of Target Disk Mode
- Don't interrupt an in-progress transfer to "fix" perceived slowness — Migration Assistant re-evaluates for a faster transport automatically

### Phase 4 — Post-migration validation
- Confirm continuous Intune management (no unenrollment gap) via `lastSyncDateTime` and management state
- Run the pilot-user checklist: Wi-Fi/VPN connectivity, email/calendar access, key business app availability
- For Managed Migration Assistant, review the declarative status transfer report per device rather than waiting for user complaints
- Reassign VPP licenses in the destination MDM once content tokens have been moved

### Phase 5 — Cleanup
- Once all devices are confirmed migrated and validated, decommission the old MDM server entry in ABM/ASM
- Remove any now-unused ADE/server tokens tied to the decommissioned MDM

### Phase 6 — Evidence-before-escalation
- Anything failing at the ABM/ASM eligibility gate (Layer 3) or the cross-account transfer question (Layer 0) is **not** fixable from Intune or from the device — escalate directly to Apple Business/School Manager support with the device's exact OS version, ownership, and enrollment method already confirmed, rather than looping through Intune-side troubleshooting that cannot affect Apple's own gate

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide MDM-to-MDM migration (e.g. Jamf/Workspace ONE → Intune)</summary>

**When:** consolidating a mixed-MDM Apple fleet onto Intune, or migrating a whole tenant to a new MDM vendor.

1. **Add Intune as an MDM server in ABM/ASM:** download Intune's public key, upload to ABM/ASM; download the resulting server token (.p7m), upload to Intune. This is separate from any existing ADE token already used for greenfield ADE enrollment
2. **Rebuild configuration parity in Intune first:** replicate Wi-Fi, VPN, email, certificate, compliance, and security baseline profiles; recreate scripts; stage app assignments and, if VPP is involved, a fresh content token
3. **Pilot:** migrate a small representative batch (5–10 devices spanning models/roles) without an enforced deadline; let users self-approve; validate against the pilot checklist in Phase 4 above
4. **Fleet rollout:** select the remaining devices in ABM/ASM (paste up to 1024 serials for bulk selection), assign to the Intune server, set a deadline between 1 and 90 days (under 30 days if VPP apps are in scope)
5. **Monitor:** watch the ABM/ASM Activity log and Intune's managed device list in parallel; investigate any device that fails eligibility individually via [Fix 1 in the Mode B runbook](DeviceMigration-B.md#fix-1--add-deadline--migration-unavailable-in-abmasm)
6. **Decommission:** once all devices are confirmed migrated and validated, remove the old MDM server entry from ABM/ASM

**Rollback:** cancel a pending (not-yet-completed) migration in ABM/ASM to revert the device to its original MDM assignment. A completed migration has no built-in rollback — treat it the same as any other re-enrollment and migrate back deliberately if needed.

</details>

<details><summary>Playbook 2 — Same-vendor tenant-to-tenant migration (M&A / tenant consolidation)</summary>

**When:** moving devices between two Intune tenants (e.g. acquiring organization consolidating an acquired company's Apple fleet onto its own tenant).

1. Treat the destination tenant as a completely separate MDM server for ABM/ASM purposes — it needs its own server token/public-key exchange even though both source and destination are "Intune"
2. Rebuild policy parity in the destination tenant exactly as in Playbook 1 — nothing about same-vendor migration copies configuration between tenants
3. Confirm user identity continuity separately (this is an Entra ID/hybrid-join concern, not a device-migration one) before migrating devices whose users are also moving tenants — see `EntraID/Troubleshooting/CrossTenant-A.md`
4. Follow the same pilot → fleet rollout → decommission sequence as Playbook 1

**Rollback:** same as Playbook 1 — cancel pending migrations; a completed migration is reversed by migrating back.

</details>

<details><summary>Playbook 3 — Rolling out Managed Migration Assistant for a hardware refresh cycle</summary>

**When:** standardizing how a fleet's Mac-to-Mac data transfers happen during an annual or ongoing hardware refresh, rather than leaving transfer scope to individual users.

1. Author the `com.apple.configuration.migration-assistant.settings` declarative configuration in Intune (Settings Catalog): define `RequiredPaths` for anything the org needs guaranteed (e.g. a specific project folder), `ExcludedPaths` for anything that should never transfer, and confirm whether privacy/security settings should migrate
2. Assign the configuration to the group containing destination devices **before** those devices go through Setup Assistant — assigning after Setup Assistant has started is too late for that device
3. Confirm every destination device in scope is on macOS 26.4+; hold back devices that aren't until they're updated
4. Communicate the unavoidable Restore-pane prompt to end users ahead of their refresh date so it isn't a surprise
5. After each transfer, review the declarative status post-transfer report rather than waiting for a support ticket — proactively catch storage-driven partial transfers

**Rollback:** removing or reassigning the declarative configuration only affects future Setup Assistant runs; it has no effect on transfers already completed.

</details>

<details><summary>Playbook 4 — Fleet-wide MSP audit sweep</summary>

**When:** an MSP wants a point-in-time readiness/health check across a client's Apple fleet before proposing or executing a migration project.

1. Run `Get-DeviceMigrationReadiness.ps1` (see [Evidence Pack](#evidence-pack)) against the tenant to inventory OS-version readiness, APNs/ABM token health, and whether a Migration Assistant declarative policy is even configured
2. Use the OS-version breakdown to size the pre-migration update-compliance work required before any migration deadline can be set fleet-wide
3. Flag device-based/shared-license devices (no signed-in user) separately — the default migration flow is user-approved; unattended devices need a deadline-enforced path planned deliberately rather than relying on self-service approval
4. Present findings as a pre-migration readiness gate, not a post-mortem — this playbook is most valuable run *before* a migration project starts

</details>

---
## Evidence Pack

```powershell
# Apple Device Migration — Evidence Pack
# Run with: DeviceManagementServiceConfig.Read.All, DeviceManagementManagedDevices.Read.All
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All","DeviceManagementManagedDevices.Read.All" -NoWelcome

Write-Host "=== APNs Certificate ===" -ForegroundColor Cyan
Invoke-MgGraphRequest -GET "https://graph.microsoft.com/v1.0/deviceManagement/applePushNotificationCertificate" |
    Select-Object appleIdentifier, expirationDateTime | Format-List

Write-Host "=== ABM/ASM (DEP) Tokens ===" -ForegroundColor Cyan
(Invoke-MgGraphRequest -GET "https://graph.microsoft.com/v1.0/deviceManagement/depOnboardingSettings").value |
    Select-Object tokenName, tokenExpirationDateTime, appleIdentifier | Format-Table -AutoSize

Write-Host "=== macOS Fleet OS-Version Readiness ===" -ForegroundColor Cyan
$macs = (Invoke-MgGraphRequest -GET "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'macOS'").value
$macs | ForEach-Object {
    [PSCustomObject]@{
        DeviceName   = $_.deviceName
        OSVersion    = $_.osVersion
        SerialNumber = $_.serialNumber
        Eligible_MDM_Migration           = ([version]($_.osVersion -replace '[^\d.].*$','')) -ge [version]"26.0"
        Eligible_ManagedMigrationAssistant = ([version]($_.osVersion -replace '[^\d.].*$','')) -ge [version]"26.4"
    }
} | Format-Table -AutoSize
```

Attach this output, the ABM/ASM Activity log entry for the affected device(s), the destination MDM server token status from the ABM/ASM console, and (for Managed Migration Assistant) the declarative status transfer report before opening an escalation.

---
## Command Cheat Sheet

| Purpose | Command / Location |
|---------|---------------------|
| Check device OS version | `sw_vers -productVersion` (on the Mac) |
| Check current MDM enrollment state | `sudo profiles status -type enrollment` |
| Force MDM profile re-check | `sudo profiles renew -type enrollment` |
| APNs cert expiry (Graph) | `GET /v1.0/deviceManagement/applePushNotificationCertificate` |
| ABM/ASM token inventory (Graph) | `GET /v1.0/deviceManagement/depOnboardingSettings` |
| List macOS managed devices (Graph) | `GET /v1.0/deviceManagement/managedDevices?$filter=operatingSystem eq 'macOS'` |
| Migration-related Settings Catalog policies (Graph, beta) | `GET /beta/deviceManagement/configurationPolicies?$filter=technologies has 'appleRemoteManagement'` |
| Pending/in-flight migration status | ABM/ASM → Devices → Inventory → [serial] |
| Migration Activity log | ABM/ASM → Devices → Inventory → Activity |
| Destination MDM server token status | ABM/ASM → Settings → MDM Servers |
| Bulk-select devices for migration | ABM/ASM → Devices → Inventory → paste up to 1024 serials |
| Declarative status / transfer report | Intune → Devices → [device] → Declarative status |
| Share Disk (Apple Silicon wired fallback) | Restart → hold power button → Startup Options → Cmd+D |
| Cancel a pending migration | ABM/ASM → device page → cancel migration (reverts to original MDM) |

---
## 🎓 Learning Pointers

- **This feature closes a real, years-old gap — but "no wipe" doesn't mean "no work."** Configuration parity (Layer 7) is entirely the admin's responsibility; treat every migration project as a policy-authoring project first and a migration-trigger second. See: [Plan your device management migration](https://support.apple.com/guide/deployment/plan-your-device-management-migration-depa5bf97586/web)

- **The eligibility gate lives at Apple, not Microsoft.** No amount of Intune-side troubleshooting fixes a greyed-out deadline option — it always traces back to OS version, ownership, or enrollment method at the ABM/ASM layer. Check `sw_vers -productVersion` before anything else. See: [Migrate managed devices to another device management service](https://support.apple.com/guide/deployment/migrate-managed-devices-dep4acb2aa44/web)

- **Managed Migration Assistant's destination floor (macOS 26.4+) is stricter than Device Management Migration's (26.0+) — don't assume one implies the other.** A device can be fully migration-eligible and still never show the data-transfer prompt. See: [Managed Migration Assistant declarative configuration](https://support.apple.com/guide/deployment/managed-migration-assistant-declarative-depd18014adc/web)

- **`~/Library` always migrates and cannot be excluded — plan `RequiredPaths`/`ExcludedPaths` around that fixed fact rather than against it.** Apps, `/Users/Shared`, and other System Settings are never in scope regardless of configuration — these come from the destination MDM's own app/policy assignment, not from the transfer.

- **VPP content tokens are the one artifact that silently breaks if migration and licensing aren't sequenced deliberately.** Move the token as its own explicit step, and keep any VPP-involved migration deadline under 30 days.

- **There's no bulk API for triggering migration yet.** Both mechanisms are portal-driven at this stage (bulk serial-number selection is the closest thing to automation) — don't scope an automation project around scripting the trigger itself; script the readiness auditing instead, which is what `Get-DeviceMigrationReadiness.ps1` is for.
