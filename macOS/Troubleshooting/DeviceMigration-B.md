# Apple Device Migration (MDM-to-MDM + Managed Migration Assistant) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers macOS 26+ wipe-free MDM-to-MDM re-enrollment via Apple Business/Apple School Manager ("Migrate Devices" / Assign Device Management) and Managed Migration Assistant (Mac-to-Mac user-data transfer, macOS 26.4+), both configured through Microsoft Intune.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Triage

**First, split the ticket into one of two failure families — they share almost no root cause:**

- **"My Mac moved to a different MDM and something broke"** → MDM-to-MDM Device Management Migration (ABM/ASM "Assign Device Management")
- **"My data/files didn't come over to my new Mac"** → Managed Migration Assistant (Mac-to-Mac data transfer)

```powershell
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All","DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All" -NoWelcome

# 1. Apple MDM Push cert + ABM/ASM (DEP) token health — prerequisite for BOTH mechanisms
$push = Invoke-MgGraphRequest -GET "https://graph.microsoft.com/v1.0/deviceManagement/applePushNotificationCertificate"
$push | Select-Object appleIdentifier, expirationDateTime
$dep = Invoke-MgGraphRequest -GET "https://graph.microsoft.com/v1.0/deviceManagement/depOnboardingSettings"
$dep.value | Select-Object tokenName, tokenExpirationDateTime, appleIdentifier
# Bad: either expirationDateTime in the past → nothing below will work until renewed

# 2. Is the affected device even on macOS 26+? (hard platform gate for BOTH mechanisms)
$dev = Invoke-MgGraphRequest -GET "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '<DeviceName>'"
$dev.value | Select-Object deviceName, osVersion, managementAgent, enrollmentType, userPrincipalName
# MDM migration needs macOS 26.0+; Managed Migration Assistant DESTINATION Mac needs macOS 26.4+ specifically

# 3. Is a Migration Assistant declarative policy actually assigned to this device? (Managed Migration Assistant only)
$policies = Invoke-MgGraphRequest -GET "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=technologies has 'appleRemoteManagement'"
$policies.value | Where-Object { $_.name -match "[Mm]igrat" }
```

On the Mac itself (Terminal — confirms which MDM currently owns the device, useful when a migration is mid-flight or disputed):
```bash
sudo profiles status -type enrollment
# Look at "MDM enrollment" and the organization name — confirms OLD vs NEW MDM currently in control
```

In **Apple Business / Apple School Manager**: Devices → Inventory → search serial → the device page shows a **pending migration** banner with target MDM and deadline if one is in flight, and the **Activity** log shows success/failure detail for a completed or attempted migration.

**Interpret immediately:**

| Symptom | Meaning | Go to |
|---------|---------|-------|
| "Add Deadline" is greyed out in ABM/ASM when assigning a new MDM | Device fails a migration requirement (OS version, ownership, enrollment method, Shared iPad, ABE) | [Fix 1](#fix-1--add-deadline--migration-unavailable-in-abmasm) |
| Bulk migration activity shows failures in the ABM/ASM Activity log | Same requirement failures, at fleet scale | [Fix 1](#fix-1--add-deadline--migration-unavailable-in-abmasm) |
| Device never picks up the new MDM / stays on old MDM after admin confirms migration | Destination MDM not correctly linked as an MDM server in ABM/ASM (token/public-key exchange) | [Fix 2](#fix-2--device-never-picks-up-the-new-mdm) |
| Mac stuck on a non-dismissible full-screen prompt after the deadline passed | Expected deadline-enforcement behavior — needs local admin credential + network to proceed, not a fault by itself | [Fix 3](#fix-3--mac-stuck-at-the-non-dismissible-migration-prompt) |
| Migration completed but Wi-Fi/VPN/apps/compliance are missing or wrong post-migration | Expected — migration moves **enrollment + already-installed managed apps + data only**, never profiles/policies/scripts | [Fix 4](#fix-4--configuration-missing-after-a-successful-migration) |
| New Mac Setup Assistant shows "Transfer Your Data to This Mac" but files are missing/incomplete afterward | Managed Migration Assistant scope/storage issue, not a transport failure | [Fix 5](#fix-5--managed-migration-assistant-data-missing-or-incomplete) |
| VPP/volume-purchased apps show license or install errors after migration | Content token wasn't moved from the old MDM to the new one | [Fix 6](#fix-6--vpp-apps-fail-to-install-after-migration) |

---

## Dependency Cascade

<details><summary>What must be true for either mechanism to work</summary>

```
┌────────────────────────────────────────────────────────────┐
│         Apple Push Notification service (APNs) cert         │
│   Valid, not expired — required for ALL MDM communication   │
└───────────────────────────┬──────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────┐
│      ABM/ASM ↔ destination MDM server link (token + key)     │
│   Destination MDM (Intune) added as an MDM server in ABM/ASM │
└───────────────────────────┬──────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────┐
│         Device eligibility gate (checked by Apple, not MS)   │
│   macOS 26+, org-owned, ADE-enrolled (or profile-based        │
│   re-enroll on 26+), not Shared iPad, not ABE, not RTS        │
└──────────────┬───────────────────────────┬────────────────────┘
               │                           │
   ┌───────────▼──────────┐    ┌───────────▼──────────────────┐
   │  MDM-to-MDM Migration │    │  Managed Migration Assistant  │
   │  (ABM/ASM "Assign     │    │  (needs destination macOS     │
   │  Device Management")  │    │  26.4+, Migration Assistant   │
   │  await_device_        │    │  declarative config, ADE +    │
   │  configured cutover   │    │  supervision on destination)  │
   └───────────┬──────────┘    └───────────┬──────────────────┘
               │                           │
   ┌───────────▼──────────┐    ┌───────────▼──────────────────┐
   │ New MDM must already  │    │ Peer-to-peer data path        │
   │ have profiles/        │    │ (Wi-Fi/Ethernet/Thunderbolt)  │
   │ policies/scripts/apps │    │ between OLD Mac and NEW Mac    │
   │ rebuilt — migration   │    │ on the same network segment    │
   │ does NOT copy these   │    │                                │
   └────────────────────────┘    └────────────────────────────────┘
```

**Critical:** both mechanisms are gated by Apple's eligibility check at the ABM/ASM level, not by anything Intune can override. If the deadline option won't show, the fault is almost always the device (OS version, ownership, enrollment method) — not the Intune side.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm which failure family this is**

Ask (or check the ticket): is the complaint about a Mac that changed *which MDM manages it*, or about a *brand-new Mac missing files* from an old one? These use different Apple mechanisms sharing only the platform-version and ABM/ASM prerequisites.

**Step 2 — Confirm platform eligibility before touching anything else**

```bash
# On the affected Mac
sw_vers -productVersion
# MDM migration: needs 26.0+
# Managed Migration Assistant DESTINATION Mac specifically: needs 26.4+ (source Mac only needs macOS 15+)
```

**Step 3 — Check ABM/ASM device page directly**

ABM/ASM → Devices → Inventory → search serial → confirm:
- Current assigned MDM server
- Any pending migration (target server + deadline)
- Ownership = organization-owned, enrollment method = Automated Device Enrollment (or profile-based on 26+)
- Not flagged Shared iPad / Return to Service

**Step 4 — For MDM migration: check the destination MDM server link in ABM/ASM**

ABM/ASM → Settings → MDM Servers → confirm the destination MDM (e.g. your Intune tenant) is listed with a **valid, non-expired** server token — this is a separate token from any existing ADE token already in use, and migrating between two Intune tenants needs its own dedicated server entry too.

**Step 5 — For Managed Migration Assistant: check the declarative status report**

Intune portal → Devices → [destination Mac] → Device configuration / Declarative status → look for the Migration Assistant configuration status and its post-transfer report (date, time, data transferred, files that failed to migrate). This is the single most useful artifact for this failure family — it tells you exactly what did and didn't come over, rather than requiring you to guess.

**Step 6 — For "configuration missing" complaints: confirm this is expected, not a fault**

Neither mechanism copies configuration profiles, compliance policies, Settings Catalog policies, or shell scripts from the old MDM to the new one. If the destination MDM (Intune) wasn't pre-configured with equivalent policies before the migration was triggered, that gap is expected and must be closed by policy authoring, not troubleshooting.

---

## Common Fix Paths

<details><summary>Fix 1 — "Add Deadline" / migration unavailable in ABM/ASM</summary>

**When:** the deadline option is greyed out when assigning a device to a new MDM server, or a bulk migration action fails for specific serials in the Activity log.

Check each requirement in order — this is the single most commonly reported real-world friction point with this feature:

```bash
# On the device
sw_vers -productVersion   # must be 26.0 or later
```

- Device OS is below macOS/iOS/iPadOS 26 → **not fixable remotely**; the device must be updated to 26+ before migration is possible at all
- Device enrolled manually via Apple Configurator and still inside its 30-day provisional ownership window → wait out the window, or use the legacy wipe-based move instead (see `ADE-Enrollment-A.md` Playbook 2 — the pre-26 path, still valid for ineligible devices)
- Device is a Shared iPad → migration is explicitly unsupported for Shared iPad; not fixable
- Device is enrolled in Apple Business Essentials, or migration involves the org's built-in device management service → unsupported combination; must move off ABE to a full MDM first
- Device has `is_return_to_service` set → clear Return to Service configuration first
- Device is not organization-owned / not ADE-enrolled → this feature requires ADE ownership; a BYOD or personally-owned device cannot use it

</details>

<details><summary>Fix 2 — Device never picks up the new MDM</summary>

**When:** admin confirmed the migration in ABM/ASM, but the device stays on the old MDM indefinitely (not just "hasn't hit its deadline yet").

1. Confirm the destination MDM is correctly added as an MDM server in ABM/ASM: **Settings → MDM Servers → [destination server]** — token must be current, not expired
2. If migrating into Intune for the first time (e.g. Jamf/Workspace ONE → Intune), confirm the public key/server token exchange completed: download Intune's public key → upload to ABM/ASM → download the resulting server token (.p7m) → upload into Intune. This is a **separate** exchange from any pre-existing ADE token the org already uses — a common mistake is assuming an existing ADE token covers the new migration server entry
3. Confirm the Apple MDM Push certificate (APNs) in Intune is valid — an expired push cert silently blocks the new MDM from ever completing the handshake
4. Have the user check for and act on the migration notification on the device (Notification Center on Mac, or the Settings app after a deadline is set) — the default flow is user-approved, not silently automatic, until the deadline is enforced

</details>

<details><summary>Fix 3 — Mac stuck at the non-dismissible migration prompt</summary>

**When:** the migration deadline passed and the Mac shows a full-screen prompt that won't go away.

This is **expected enforcement behavior**, not a bug:

- The user must enter their **local administrator credentials** to proceed — this is required, there is no bypass
- If the Mac shows a Wi-Fi picker instead, it lost connectivity after the old MDM profile was removed — get it back online and the prompt will proceed automatically
- A device stuck offline at the deadline remains at this screen indefinitely until it reconnects — there is no timeout that abandons the migration
- If the prompt appears broken (not responding to credential entry after several minutes with good connectivity), a restart is the first safe step; escalate to Apple Business/School Manager support only if the prompt persists after restart with confirmed connectivity

</details>

<details><summary>Fix 4 — Configuration missing after a successful migration</summary>

**When:** the migration itself completed (device shows enrolled in the new MDM) but Wi-Fi, VPN, compliance policies, or apps that existed under the old MDM are missing.

**This is expected, not a fault.** Migration moves enrollment plus whatever apps/data were already installed — it does not copy configuration profiles, compliance policies, Settings Catalog policies, or scripts from the old MDM.

1. Before migrating any further devices, audit the old MDM's configuration (profiles, compliance policies, security baselines, scripts, app assignments) and rebuild equivalents in Intune
2. For already-migrated devices missing config, assign the now-created Intune policies/apps to the appropriate group — they will apply on next check-in like any normal Intune deployment
3. Run a pilot batch and have users validate Wi-Fi/VPN/email/key-app access before migrating the rest of the fleet

</details>

<details><summary>Fix 5 — Managed Migration Assistant: data missing or incomplete</summary>

**When:** a new Mac went through "Transfer Your Data to This Mac" but the user reports missing files or folders.

1. Check the Intune declarative status report for this device first — it lists exactly which files failed to migrate and why, rather than requiring a manual audit
2. Confirm what's actually in scope: Managed Migration Assistant migrates the Home folder (visible + hidden files/folders, folder aliases, privacy/security settings) and **always** migrates `~/Library`. It does **not** migrate `/Applications`, `/Users/Shared/`, other System Settings, printers, or file-level aliases/symlinks — a user reporting a missing app or a `/Users/Shared` file is reporting expected behavior, not a bug
3. Check the destination Mac's free storage against the source Home folder size — if the destination doesn't have enough space, only `RequiredPaths`-configured content is guaranteed priority; everything else may be partially migrated or skipped
4. Confirm the destination Mac is on macOS **26.4+** specifically — a device on 26.0–26.3 is eligible for MDM-to-MDM migration but not for Managed Migration Assistant, and the transfer prompt simply won't appear
5. If the two Macs are on different network segments/VLANs (common for a "new device onboarding" SSID separate from production Wi-Fi), peer-to-peer discovery can fail — put both Macs on the same segment, or fall back to Apple Silicon Share Disk (Cmd+D at the Startup Options screen) for a wired transfer

</details>

<details><summary>Fix 6 — VPP apps fail to install after migration</summary>

**When:** volume-purchased (VPP/content-token) apps show license or install errors on a migrated device.

Content tokens are **not** moved automatically by device migration:

1. In the old MDM, remove the content token (this starts a grace period — up to 30 days or until the app developer performs a receipt check, whichever comes first)
2. Upload a fresh/equivalent content token to the new MDM (Intune) and reassign the licenses
3. If a migration deadline greater than 30 days was set on devices with VPP apps in scope, shorten it — Apple's own guidance is to keep VPP-involved migration deadlines under 30 days to avoid a licensing gap

</details>

---

## Escalation Evidence

```
=== Apple Device Migration — Escalation Template ===
Date/Time:                    ___________________________
Ticket #:                     ___________________________

FAILURE FAMILY
  [ ] MDM-to-MDM Device Management Migration
  [ ] Managed Migration Assistant (Mac-to-Mac data transfer)

ENVIRONMENT
  Device model / serial:        ___________________________
  macOS version (source):       ___________________________
  macOS version (destination):  ___________________________
  Old MDM:                      ___________________________
  New MDM / Intune tenant:      ___________________________
  ABM/ASM account:              ___________________________
  Migration deadline set (Y/N): ___________________________

TRIAGE RESULTS
  APNs cert expiry:             ___________________________
  ABM/ASM server token expiry:  ___________________________
  Device shown eligible in ABM/ASM (Y/N): _________________
  ABM/ASM Activity log entry:   ___________________________
  `sudo profiles status -type enrollment` output:
    ___________________________
  Declarative status / migration report (if Managed Migration Assistant):
    ___________________________

FIXES ATTEMPTED
  1. ___________________________
  2. ___________________________

ESCALATION TARGET:
  [ ] Apple Business/School Manager support (business.apple.com / school.apple.com → Support)
  [ ] Microsoft Intune support (admin.microsoft.com → Support)
  [ ] Network/proxy team (peer-to-peer transport or APNs connectivity)
```

---

## 🎓 Learning Pointers

- **Migration is fundamentally a wipe-free re-enrollment, not a clone.** The new MDM profile installs before the old one is removed, so the device is never truly unmanaged mid-flight — but that continuity only covers enrollment and already-installed managed apps/data, never configuration. Plan the destination MDM's policies as a separate, pre-migration project. See: [Migrate managed devices to another device management service](https://support.apple.com/guide/deployment/migrate-managed-devices-dep4acb2aa44/web)

- **The "Add Deadline" greyed-out state is Apple's eligibility gate, not an Intune bug.** Every real-world report of this symptom traces back to OS version, ownership, or enrollment method — check `sw_vers -productVersion` before touching anything on the Intune side. See: [Migrate devices to a new management service in Apple Business](https://support.apple.com/guide/business/migrate-devices-to-a-new-management-service-axm3a49a769d/web)

- **There is no bulk API for triggering ABM/ASM-side migration yet — it's portal-only.** Bulk actions in the portal (up to 1024 serials pasted at once) are the current ceiling; don't design an automation around scripting the migration trigger itself.

- **Managed Migration Assistant's destination requirement (macOS 26.4+) is stricter than the MDM-migration requirement (26.0+).** A device fully eligible for MDM-to-MDM migration can still be ineligible to receive a Mac-to-Mac data transfer if it hasn't been updated past 26.3. See: [Managed Migration Assistant for macOS](https://support.apple.com/guide/deployment/managed-migration-assistant-for-macos-dep4f861792f/web)

- **The Setup Assistant Restore pane cannot be hidden — plan for it, don't fight it.** Even a fully locked-down zero-touch deployment must surface this one screen; build end-user communication around it rather than trying to suppress it via policy.

- **VPP content tokens and volume-purchased apps are the one thing that quietly breaks if migration and licensing aren't sequenced together.** Treat token movement as its own checklist item before setting any migration deadline longer than 30 days.
