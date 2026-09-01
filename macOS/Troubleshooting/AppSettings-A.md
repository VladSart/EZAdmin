# macOS/iOS App Settings (Binary & App Launch Control) — Reference Runbook (Mode A: Deep Dive)
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

Covers **App Settings**, a Settings Catalog policy category (**Declarative Device Management (DDM) > App Settings**) that exposes Apple's native `app.settings` DDM configuration, introduced with **macOS 27 and iOS/iPadOS 27 (supervised devices only)** and announced at WWDC 2026. The declaration has two independent halves that share a delivery mechanism but govern different platforms and enforcement layers:

- **App launch control** (`Allowed Apps` / `Denied Apps`, bundle-ID based) — iOS/iPadOS, controlling which apps can be shown or launched.
- **Binary execution control** (`Allowed Binaries` / `Denied Binaries` / `Always Allow Managed Apps`, code-signature-identifier based) — macOS, enforced through Apple's Endpoint Security extension framework, controlling which binaries — standalone or embedded inside an app bundle, including command-line tools — are permitted to run.

This is the feature that finally gives the Mac genuine application-allowlisting parity with supervised iOS: previously, Mac admins had blunt tools (Gatekeeper's signed/notarized check, the coarse "allow apps from" source restriction) or had to license a third-party endpoint-control product to get real allow/deny enforcement at execution time.

**Does not cover:**
- The DDM protocol/transport layer itself (declaration sync, Status Channel, the false-error/downgrade-detection pattern, `ddmd`/`mdmclient` diagnostics) — see `DDM-A.md`. A fault there affects every DDM-category setting simultaneously, not just App Settings; use that file first if multiple unrelated Settings Catalog "Declarative Device Management" categories are failing at once.
- Gatekeeper and notarization — see `Gatekeeper-Notarization-A.md`. Gatekeeper is a signing/notarization trust check that runs at install/first-launch time and is independent of this feature; a binary can be Gatekeeper-approved and still be blocked by App Settings' Endpoint Security enforcement, or vice versa in principle (though in practice `Allowed Binaries` entries are built from legitimately signed binaries).
- PPPC/TCC and the new declarative `Privacy` key — see `PPPC-A.md`. That layer governs *permission consent* (camera, microphone, Accessibility, etc.) for a binary that is already permitted to execute; App Settings governs whether the binary executes at all. They are sequential, distinct gates.
- General VPP/Apple Business app deployment mechanics (licensing, Device vs. User assignment) — see `VPP-App-Deployment-A.md`. This file only covers how deployed-app status intersects with the `Always Allow Managed Apps` toggle, not deployment itself.
- The deprecated legacy `Allowed app bundle IDs` / `Denied app bundle IDs` settings in the classic Restrictions profile (iOS) — referenced here only to flag the migration and overlap risk, not documented in depth as its own topic.

---
## How It Works

<details><summary>Full architecture</summary>

### Why this exists

For years there was a real capability gap between supervised iOS/iPadOS and the Mac. A supervised iPhone could be locked to a clean allow list of apps with nothing else runnable. A Mac had only Gatekeeper (cares solely whether an app is signed and notarized, not whether it's *permitted*) and a coarse "allow apps downloaded from: App Store / identified developers / anywhere" toggle. Real application allowlisting on macOS meant buying and maintaining a third-party endpoint-security product. App Settings closes that gap natively, and — critically — it is not limited to double-clickable apps: it covers *any* executable binary, including command-line tools. That matters operationally because a large share of modern "living off the land" and social-engineering techniques (a user tricked into pasting and running a shell command, a downloaded `curl` one-liner, a script dropped into `/tmp`) never touch a `.app` bundle at all, and were therefore invisible to every prior macOS control.

### Delivery mechanism

App Settings is authored in Intune as a **Settings Catalog** policy under the **Declarative Device Management (DDM)** category. Selecting it exposes the same keys Apple defines in the `app.settings` DDM configuration schema directly in the settings picker — Intune does not add its own abstraction layer on top of Apple's schema for this feature, which means the authoritative reference for exact field semantics is Apple's own `app.settings` schema definition, not a Microsoft-specific document. The policy is delivered through the standard DDM channel (declaration sync, Status Channel reporting) documented in `DDM-A.md` — App Settings introduces no new transport mechanics of its own.

### Platform prerequisites — the hard, silent gate

App Settings requires **iOS/iPadOS 27+ or macOS 27+, and the device must be supervised**. Supervision status is independent of OS version and is generally a consequence of the enrollment method (Automated Device Enrollment/ADE is the practical path to supervision; a manually/BYOD-enrolled device is very unlikely to be supervised). There is no error, warning, or partial-application state for a device that fails either check — the declaration simply never has an effect. This is the single highest-value fact in this entire topic: confirm platform version and supervision *before* investigating anything about policy content.

### App launch control (iOS/iPadOS)

`Allowed Apps` and `Denied Apps` take bundle IDs. If `Allowed Apps` is populated, the device shows and launches *only* apps whose bundle ID is listed — covering App Store apps, custom-distributed/marketplace apps, and locally-installed apps alike. The special value `com.apple.webapp` allows all web clips through an allow list. `Denied Apps` prevents the listed bundle IDs from being shown or launched; being denied does **not** prevent installation, only visibility/launch. If a bundle ID appears in both lists, the device blocks it — deny always wins over allow for the same identifier. Denying a system app can have cascading effects unrelated to the app itself — Apple's own documentation calls out that denying the App Store app, for instance, can prevent users from accepting Volume Purchase Program (VPP) license terms, which then blocks otherwise-unrelated app deployments.

This app-launch-control mechanism **replaces** the legacy Restrictions-profile settings of the same conceptual purpose (`Allowed app bundle IDs` / `Denied app bundle IDs`), which are deprecated — not removed — on iOS 27. Because "deprecated" here means "still functions," a device can end up with both a legacy Restrictions profile and a new App Settings policy simultaneously evaluating the same bundle ID, potentially with conflicting intent. Migrate fully rather than layering the two.

### Binary execution control (macOS)

This is the architecturally new half of the feature. Enforcement runs through Apple's **Endpoint Security extension framework** — a kernel-level API that macOS's own security agents (and, previously, third-party EDR products) already use to observe and gate process execution. `Allowed Binaries` and `Denied Binaries` each hold a list of **binary identifiers**, and a binary matches an identifier only when *every populated field on that identifier* matches:

| Field | Description | Matching behavior |
|---|---|---|
| `CDHash` | 40-character code directory hash | Pins one exact build — the tightest possible match, nothing else passes |
| `SigningID` | Code-signature signing identifier | Matches a specific app/binary from a developer |
| `TeamID` | Code-signature team identifier | Matches everything signed by one developer/team; use `*APPLE*` for Apple binaries with an empty team identifier |
| `PathPrefix` | File-system path prefix | Matches by location rather than signature alone |
| `SigningState` | One of `All`, `TestFlight`, `DeveloperID`, `Enterprise`, `AppStore`, `Apple` (default `All`) | Narrows matching to a specific distribution/signing channel |

**Validation rule, and the most common misconfiguration:** for an `Allowed Binaries` entry, either `CDHash` or `TeamID` **must** be present. For a `Denied Binaries` entry, one of `CDHash`, `TeamID`, or `SigningID` **must** be present. An entry missing its required field(s) will not reliably match the intended binary. There is no substitute for generating these values from the real binary — `codesign -dvvv <path>` is the authoritative source; values copied from documentation, a different build, or a similarly-named binary are a guess, not a configuration.

The device always permits **system-critical processes that are signed and sealed as part of the operating system itself** — this is a baked-in floor beneath any admin-configured policy, not something that needs to be separately allow-listed.

`Always Allow Managed Apps` (boolean, default `False`) is a convenience toggle: when `True`, apps deployed as managed apps are automatically folded into the effective allow list, reducing the ongoing burden of manually enumerating every legitimately-deployed app. Its scope is narrower than the name suggests — **it only applies to apps managed through VPP or installed using the Line-of-business app type**, and explicitly **does not** cover apps installed using the Line-of-business (PKG) or Line-of-business (DMG) app types, which are installed via the Intune agent rather than Apple's native managed-app mechanism. This distinction is a frequent source of "why did my Intune-deployed app just get blocked" tickets the first time binary control is enabled fleet-wide.

### Why this is a genuinely higher-stakes deployment than most Settings Catalog policies

An `Allowed Binaries`-based policy is fail-closed by nature: once `Allowed Binaries` is populated for a device, only matching binaries run. There is no Microsoft-documented staged/audit-only enforcement mode for this policy type — contrast with the Intune STIG audit baseline (`STIGAuditBaseline-A.md`), which is deliberately audit-only by design. Missing even one legitimately-needed tool (a quarterly finance script, a developer's CLI dependency) in the allow list produces a silent, hard block with no admin-facing warning anywhere in Intune — the failure surfaces as a confused end-user ticket, not a portal alert. The only mitigations are process ones: build the allow list from observed real usage (not a guess), and pilot on a narrow ring before any fleet-wide enforcing rollout.

### Monitoring

App Settings status is reported through Apple's DDM **Status Channel**, the same mechanism documented in `DDM-A.md`. Review **Device status** and **Per-setting status** on the configuration profile in the Intune admin center, and check Intune **audit logs** for changes to the policy itself. A `Success` status confirms the declaration was delivered and accepted by the device — it does **not** independently confirm that the configured binary identifiers are semantically correct; a syntactically valid but wrong `TeamID` will still report `Success` while continuing to block (or wrongly permit) the intended binary.

</details>

---
## Dependency Stack

```
[Device platform: macOS 27+ (binary control) or iOS/iPadOS 27+ (app launch control)]
        │
        ▼
[Device is SUPERVISED — ADE/DEP enrollment is the practical path;
 no error/warning exists for an unsupervised device, the declaration just never lands]
        │
        ▼
[Shared DDM transport layer — declaration sync, Status Channel
 (see DDM-A.md if this layer itself is unhealthy across multiple policy types)]
        │
        ▼
[Settings Catalog policy authored: Declarative Device Management (DDM) > App Settings]
        │
        ├── iOS/iPadOS branch: Allowed Apps / Denied Apps (bundle IDs)
        │       │  Deny always wins over Allow for the same bundle ID.
        │       │  Overlaps with the DEPRECATED (not removed) legacy
        │       │  Restrictions-profile bundle ID settings — migrate, don't layer.
        │       ▼
        │   [Device app-launch layer enforces locally]
        │
        └── macOS branch: Allowed Binaries / Denied Binaries / Always Allow Managed Apps
                │  Binary identifiers: CDHash / SigningID / TeamID / PathPrefix / SigningState
                │  Allowed requires CDHash or TeamID; Denied requires CDHash, TeamID, or SigningID
                │  System-critical OS-signed processes always permitted (floor beneath policy)
                │  Always Allow Managed Apps: VPP + LOB(non-PKG/DMG) only —
                │  does NOT cover LOB (PKG) / LOB (DMG) apps installed via the Intune agent
                ▼
        [macOS Endpoint Security extension framework enforces locally, kernel-level]
        │
        ▼
[Status reported via DDM Status Channel — Device status / Per-setting status tabs,
 Intune audit logs for policy changes]
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Policy assigned, device shows no effect whatsoever | Device unsupervised, or OS version below 27 on the relevant platform | `IsSupervised` and `OsVersion` via Graph/admin center |
| Policy shows `Success` at the device but the intended binary is still blocked (or still runs, if denying) | Binary identifier value(s) don't actually match the real binary | `codesign -dvvv` on the actual binary; compare every populated field |
| Policy shows `Error` at the device | Malformed identifier — missing a required field for its list type | `Allowed` needs CDHash or TeamID; `Denied` needs CDHash, TeamID, or SigningID |
| Managed/VPP app stops launching right after enabling binary control | `Always Allow Managed Apps` left at default `False`, and the app isn't separately allow-listed | Confirm toggle value and app install method |
| Intune-agent-installed LOB (PKG/DMG) app blocked despite `Always Allow Managed Apps = True` | That toggle explicitly excludes PKG/DMG-via-agent app types — by design, not a bug | Add the app's binary identifier to `Allowed Binaries` explicitly |
| A CLI tool or script (not an app) gets blocked | Expected — binary control covers any executable, not just `.app` bundles | Confirm whether the tool is legitimately needed; allow-list if so |
| iOS app icon missing/unlaunchable after upgrading to iOS 27 | Legacy deprecated Restrictions-profile bundle ID setting still assigned alongside the new App Settings policy, conflicting | Check for both policies targeting the same device |
| A remote-support/automation tool broke after a macOS 27 upgrade | Unrelated feature — the old PPPC/TCC Accessibility grant mechanism is *removed*, not deprecated, on macOS 27 | Cross-reference `PPPC-A.md`, not this file |
| Denying a system app (e.g. App Store) causes unrelated app-deployment failures | Documented cascading effect — denying the App Store app can block VPP license-term acceptance | Reconsider whether that system app truly needs to be in `Denied Apps` |
| A `Denied Binaries` entry doesn't block anything | Missing all three of `CDHash`/`TeamID`/`SigningID` — no required field is populated | Regenerate identifier via `codesign -dvvv` and re-check required-field rule |

---
## Validation Steps

**Step 1 — Confirm platform and supervision eligibility**
```powershell
Get-MgBetaDeviceManagementManagedDevice -Filter "deviceName eq '<deviceName>'" |
    Select-Object DeviceName, OperatingSystem, OsVersion, IsSupervised
```
Expected: OS version 27+ on the relevant platform, `IsSupervised = True`. Either failing is a hard, silent stop — nothing below this layer will ever take effect.

**Step 2 — Confirm the Settings Catalog policy configuration**
Intune admin center > **Devices > Configuration** > the App Settings policy > **Configuration settings** tab — review the exact Allowed/Denied entries and their populated fields against what's expected.

**Step 3 — Confirm assignment scope**
**Assignments** tab — confirm the affected device's group is genuinely targeted, and check for any exclusion groups that might unexpectedly cover the device.

**Step 4 — Confirm delivery status**
**Device status** / **Per-setting status** tabs (or Graph `deviceManagement/configurationPolicies/{id}/deviceStatuses`). `Success` confirms delivery and acceptance, not semantic correctness of the identifier values.

**Step 5 — Confirm the real binary's identifiers**
```bash
codesign -dvvv /path/to/binary
```
Compare `CDHash` (`Get-FileHash`-equivalent on macOS — actually surfaced directly by `codesign`), `TeamIdentifier`, and the signing identifier line-by-line against the configured policy values. Treat any mismatch, however small, as the root cause before looking anywhere else.

**Step 6 — For managed-app tickets, classify the install method**
Confirm in Intune whether the affected app is VPP-licensed, Line-of-business (non-PKG/DMG), or Line-of-business (PKG/DMG) — only the first two are eligible for `Always Allow Managed Apps` coverage.

**Step 7 — For iOS tickets, check for legacy/new policy overlap**
Confirm whether a Restrictions profile using the deprecated `Allowed app bundle IDs` / `Denied app bundle IDs` settings is still assigned to the same device.

---
## Troubleshooting Steps (by phase)

### Phase 1: Eligibility
1. Confirm OS version and supervision state (Validation Step 1) before anything else — this eliminates an entire class of "policy doesn't work" tickets in one check.
2. If the device is unsupervised by design (BYOD), document this as an accepted gap for that population rather than continuing to chase the policy.

### Phase 2: Policy authoring and delivery
1. Confirm policy assignment scope and delivery status (Validation Steps 2–4).
2. For `Error` status, check the required-field rule for the specific list type (`Allowed` vs. `Denied`) before assuming a transport-layer fault; cross-reference `DDM-A.md` only if *multiple unrelated* DDM-category policies are simultaneously failing on the same device.

### Phase 3: Identifier accuracy
1. Generate real identifier values via `codesign -dvvv` on the actual binary in question (Validation Step 5).
2. Compare every populated field; a `Success`-status policy with an incorrect identifier value is the most common false-negative pattern in this feature.
3. Correct and re-save; confirm the device picks up the new declaration version on its next check-in before declaring the fix verified.

### Phase 4: Managed-app and CLI-tool scoping
1. For managed-app outages, classify install method and `Always Allow Managed Apps` eligibility (Validation Step 6).
2. For blocked CLI tools/scripts, confirm intent — this is very often the control working correctly, not a defect — before adding an allow entry.

### Phase 5: iOS legacy overlap
1. Check for a co-assigned legacy Restrictions profile (Validation Step 7).
2. Migrate fully to App Settings and remove (don't merely ignore) the legacy assignment once confirmed working, to eliminate the overlap risk going forward.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Stand up macOS binary execution control safely (pilot-first)</summary>

1. Confirm the target pilot ring is macOS 27+ and supervised (ADE-enrolled) — this feature has no fallback for unsupervised devices.
2. Deploy an initial, deliberately **narrow** `Allowed Binaries` list built from actually-observed legitimate usage on representative pilot devices, not a guess at what "should" be needed. There is no Microsoft-documented report-only mode for this policy type, so treat the pilot ring itself as the audit mechanism.
3. Set `Always Allow Managed Apps = True` if the pilot population's managed apps are VPP/LOB(non-PKG/DMG); separately allow-list any LOB (PKG)/(DMG) apps installed via the Intune agent.
4. Monitor the pilot ring closely for unexpected blocks (help-desk tickets, silent failures reported by users) for a meaningful window before considering fleet-wide rollout.
5. Expand the allow list iteratively based on confirmed legitimate needs; widen assignment scope only once the list is stable for the pilot ring.
6. Document the finalized policy and its rationale — this is now the organization's system-of-record for "what's allowed to run on a managed Mac," worth treating with the same rigor as a firewall rule set.

**Rollback:** Remove the policy's assignment (or set `Allowed Binaries` back to empty) to stop enforcement immediately; the policy object itself can remain defined, unassigned, for future re-deployment.

</details>

<details><summary>Playbook 2 — Migrate iOS app launch control off the legacy Restrictions profile</summary>

1. Inventory the current legacy `Allowed app bundle IDs` / `Denied app bundle IDs` settings on the Restrictions profile(s) in use.
2. Build an equivalent Settings Catalog App Settings policy with the same bundle IDs in the corresponding `Allowed Apps` / `Denied Apps` lists — remember the special `com.apple.webapp` value if web clips were implicitly allowed before.
3. Assign the new policy to a pilot group first; confirm behavior matches the legacy profile's intent.
4. Once confirmed, migrate the remaining assignment groups, then remove the legacy Restrictions profile's assignment (retain the object, unassigned, for rollback).

**Rollback:** Re-assign the legacy Restrictions profile and remove the new App Settings policy's assignment if the migration surfaces regressions.

</details>

<details><summary>Playbook 3 — Diagnose and correct a binary-identifier mismatch</summary>

1. Identify the exact binary path being blocked (or wrongly permitted) from the user/ticket report.
2. Run `codesign -dvvv` against that exact path on the affected Mac — not a copy, not a similar build.
3. Compare every populated field against the policy's configured identifier entry, field by field.
4. Correct the mismatched field(s) in the Settings Catalog policy, respecting the required-field rule for the list type, and re-save.
5. Confirm the device receives the updated declaration on its next DDM check-in and re-test.

**Rollback:** Revert the identifier entry to its prior value if the correction has unintended side effects (e.g., accidentally widening a match beyond intent).

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect App Settings (binary/app launch control) evidence for escalation
.NOTES     Admin-side Graph portion requires Connect-MgGraph with
           DeviceManagementConfiguration.Read.All and DeviceManagementManagedDevices.Read.All.
           Device-local portion (codesign) must be run separately, ON the affected Mac.
           Output saved to current directory.
#>

$output = [System.Collections.Generic.List[string]]::new()
$ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC" -AsUTC
$out    = ".\AppSettingsEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"

function Add-Section {
    param([string]$Title, [scriptblock]$Body)
    $output.Add("=" * 60)
    $output.Add("  $Title")
    $output.Add("=" * 60)
    try { $output.Add((&$Body | Out-String).Trim()) }
    catch { $output.Add("ERROR: $($_.Exception.Message)") }
    $output.Add("")
}

Add-Section "Collection metadata" {
    "Collected : $ts"
}

Add-Section "Device platform / supervision (edit deviceName below)" {
    Get-MgBetaDeviceManagementManagedDevice -Filter "deviceName eq '<deviceName>'" |
        Select-Object DeviceName, OperatingSystem, OsVersion, IsSupervised | Format-List
}

Add-Section "App Settings Settings Catalog policies in tenant" {
    Get-MgBetaDeviceManagementConfigurationPolicy |
        Where-Object { $_.Name -match 'App Settings|Binary|AllowedBinaries|DeniedBinaries' } |
        Select-Object Id, Name, CreatedDateTime, LastModifiedDateTime | Format-Table -AutoSize | Out-String
}

Add-Section "Reminder — device-local step required separately" {
    "Run on the affected Mac: codesign -dvvv /path/to/binary"
    "Compare CDHash / TeamIdentifier / signing identifier against the policy's configured values."
}

$output | Set-Content -Path $out -Encoding UTF8
Write-Host "Evidence saved to: $out" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Confirm device platform/OS version/supervision | `Get-MgBetaDeviceManagementManagedDevice -Filter "deviceName eq '<name>'" \| Select DeviceName,OsVersion,IsSupervised` |
| List App Settings-related Settings Catalog policies | `Get-MgBetaDeviceManagementConfigurationPolicy \| Where Name -match 'App Settings'` |
| Check per-device policy status | `Get-MgBetaDeviceManagementConfigurationPolicyDeviceStatus -DeviceManagementConfigurationPolicyId <id>` |
| Generate real binary identifier values (on the Mac) | `codesign -dvvv /path/to/binary` |
| Policy content / Assignments / Device status | Intune admin center > Devices > Configuration > (policy) |
| Apple's authoritative schema reference | [`app.settings` on GitHub (Apple device-management repo)](https://github.com/apple/device-management/blob/seed_OS_27_0/declarative/declarations/configurations/app.settings.yaml) |

---
## 🎓 Learning Pointers

- **Supervision is the single highest-leverage fact in this whole topic.** App Settings requires macOS 27+/iOS-iPadOS 27+ *and* supervision, with zero error surfaced for a device that fails either gate — confirm this before any policy-content investigation. [App settings configuration for Apple devices](https://learn.microsoft.com/en-us/intune/device-configuration/templates/apple-ddm-app-settings)

- **Binary identifiers are only as good as the tool that generated them — `codesign -dvvv` on the real file, every time.** Documentation examples, values from a different build, or "close enough" guesses are the leading cause of a policy that reports `Success` while still failing to match the intended binary. [App settings configuration for Apple devices](https://learn.microsoft.com/en-us/intune/device-configuration/templates/apple-ddm-app-settings)

- **`Always Allow Managed Apps` is a convenience toggle with real edges — it does not mean "everything I deployed through Intune."** VPP and Line-of-business (non-PKG/DMG) apps are covered; Line-of-business (PKG) and (DMG) apps installed via the Intune agent are explicitly not, and need individual `Allowed Binaries` entries. Budget for this gap before enabling binary control fleet-wide. [App settings configuration for Apple devices](https://learn.microsoft.com/en-us/intune/device-configuration/templates/apple-ddm-app-settings)

- **This is the first native Mac control that reaches command-line tools, not just apps** — closing a real gap that techniques like tricking a user into pasting and running a shell command have relied on for years. Treat a blocked CLI tool as a sign the control is working, and build the allow list from confirmed real usage rather than assumption. [Apple's device-management app.settings schema](https://github.com/apple/device-management/blob/seed_OS_27_0/declarative/declarations/configurations/app.settings.yaml)

- **There is no documented staged/audit-only rollout mode for this feature — unlike the Intune STIG audit baseline, it is enforcing from the moment it's assigned.** Pilot narrowly, build from observed usage, and widen deliberately; an incomplete allow list fails closed and silently, with the failure surfacing as a confused end-user ticket rather than a portal warning.

- **Don't conflate this with the separate removal of the pushed-Accessibility PPPC grant on macOS 27.** A remote-support or automation tool breaking after a macOS 27 upgrade is very likely the *Privacy*-key/Accessibility change, not App Settings binary control — check `PPPC-A.md` first for that specific symptom pattern.
