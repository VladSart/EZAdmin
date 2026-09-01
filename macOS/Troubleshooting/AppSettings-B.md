# macOS/iOS App Settings (Binary & App Launch Control) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

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

**App Settings** is a Settings Catalog policy (category: **Declarative Device Management (DDM) > App Settings**) that surfaces Apple's native `app.settings` DDM declaration, new for **macOS 27+ and iOS/iPadOS 27+, supervised devices only**. It has two independent halves: **app launch control** (`Allowed Apps` / `Denied Apps` — bundle IDs, iOS/iPadOS) and **binary execution control** (`Allowed Binaries` / `Denied Binaries` / `Always Allow Managed Apps` — macOS, enforced via the Endpoint Security framework). If a ticket mentions a Mac binary or command-line tool refusing to run, an app that installs but won't launch on macOS 27, or an iOS app icon disappearing from the Home Screen after an update, this is the topic — **not** Gatekeeper/notarization (`Gatekeeper-Notarization-B.md`, a signing-trust check that runs before this) and not PPPC/TCC (`PPPC-B.md`, a permission-consent check that runs after a binary is already allowed to execute).

```powershell
# 1. Confirm the device meets the hard prerequisites: macOS 27+ or iOS/iPadOS 27+, AND supervised
#    (App Settings silently does not apply to unsupervised devices — no error, it just never lands)
Get-MgBetaDeviceManagementManagedDevice -Filter "deviceName eq '<deviceName>'" |
    Select-Object DeviceName, OperatingSystem, OsVersion, IsSupervised

# 2. Find the App Settings Settings Catalog policy and confirm assignment
Get-MgBetaDeviceManagementConfigurationPolicy -Filter "templateReference/templateFamily eq 'none'" |
    Where-Object { $_.Name -match 'App Settings|AppSettings|Binary' } |
    Select-Object Id, Name

# 3. Confirm per-device policy status via the DDM status channel
Get-MgBetaDeviceManagementConfigurationPolicyDeviceStatus -DeviceManagementConfigurationPolicyId <PolicyId> |
    Where-Object { $_.DeviceDisplayName -eq '<deviceName>' } |
    Select-Object DeviceDisplayName, Status, ErrorCode

# 4. On the affected Mac — generate the exact identifier fields for the blocked binary
#    codesign is the ONLY reliable source for CDHash/TeamID/SigningID; never guess these values
# codesign -dvvv /path/to/binary
```

| Result | Interpretation |
|---|---|
| `IsSupervised` is `False` | App Settings will never apply to this device, full stop — no error surfaces anywhere, it simply never delivers. This is the single most common "why doesn't this work" cause. See Fix 1. |
| `OsVersion` is below 27 on either platform | Same outcome as above — the DDM declaration requires macOS 27+ / iOS-iPadOS 27+ specifically, not merely a recent-enough OS. See Fix 1. |
| Policy status shows `Error` at the device | Check `ErrorCode` first — most commonly a malformed binary identifier (missing required field) rather than a delivery problem. See Fix 2. |
| A managed/VPP-deployed app stopped launching right after this policy was assigned | `Always Allow Managed Apps` was left `False` (its default) and the app isn't separately listed in `Allowed Binaries` — the single most common self-inflicted outage from this feature. See Fix 3. |
| A Line-of-business (PKG) or Line-of-business (DMG) app is blocked even with `Always Allow Managed Apps` set `True` | Expected — that setting explicitly does **not** cover apps installed via the Intune agent using those two app types. They must be added to `Allowed Binaries` explicitly. See Fix 3. |
| A command-line tool (`curl`, a custom script interpreter, a downloaded binary in `/tmp`) is being blocked, not an app | Expected and by design — binary control on macOS covers any executable, not just `.app` bundles. This is not a bug to fix, it's the feature working; confirm intent before adding an allow entry. See Fix 4. |
| iOS app icon vanished from Home Screen / can't be launched after upgrading to iOS 27 | The legacy `Allowed app bundle IDs` / `Denied app bundle IDs` Restrictions-profile settings are **deprecated on iOS 27** — a still-assigned legacy Restrictions profile and a new App Settings profile can now both be evaluating the same bundle ID with different intent. See Fix 5. |
| A remote-support/RMM/automation tool that relied on a *pushed* Accessibility grant stopped working after a Mac updated to macOS 27 | Not this feature — the old PPPC/TCC Accessibility grant mechanism is **removed** (not just deprecated) in macOS 27. Cross-reference `PPPC-A.md`; the fix is rebuilding the grant on the new `Privacy` key, unrelated to App Settings. |
| Policy shows `Success` at the device but the binary is still blocked | Confirm you're reading the **binary's actual** CDHash/TeamID/SigningID via `codesign`, not a value copied from documentation or a different build — a single-character mismatch in any populated field fails the match silently. See Fix 2. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Device is macOS 27+ or iOS/iPadOS 27+]
        │
        ▼
[Device is SUPERVISED — ADE/DEP enrollment, or otherwise supervised;
 App Settings does not apply to unsupervised devices, no error given]
        │
        ▼
[Admin creates a Settings Catalog policy: Platform macOS or iOS/iPadOS,
 Profile type "Settings catalog" > Declarative Device Management (DDM) > App Settings]
        │
        ▼
[Admin configures the relevant setting group:
   iOS/iPadOS → Allowed Apps / Denied Apps (bundle IDs)
   macOS      → Allowed Binaries / Denied Binaries / Always Allow Managed Apps
    (binary identifiers built from CDHash / TeamID / SigningID / PathPrefix / SigningState,
     generated from the REAL binary via `codesign -dvvv`, never guessed)]
        │
        ▼
[Policy assigned to the correct device/user group, DDM channel delivers the declaration
 (shared transport with every other DDM-category setting — see DDM-A.md if delivery
  itself is failing across multiple unrelated policy types, not just this one)]
        │
        ▼
[Device's Endpoint Security extension (macOS) enforces binary execution control locally;
 device's app-launch layer (iOS/iPadOS) enforces app launch control locally]
        │
        ▼
[Status reported back via Apple's DDM Status Channel — visible in Intune admin center
 Device status / Per-setting status tabs, and in Intune audit logs]
```

If `IsSupervised` is `False` or the OS version gate isn't met, nothing below that line in the cascade ever executes — there is no partial application and no error surfaced to the admin. Confirm both before troubleshooting anything else.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm platform + supervision prerequisites**
```powershell
Get-MgBetaDeviceManagementManagedDevice -Filter "deviceName eq '<deviceName>'" |
    Select-Object DeviceName, OperatingSystem, OsVersion, IsSupervised
```
Expected: `OsVersion` ≥ 27 on the relevant platform, `IsSupervised` = `True`. Either failing means App Settings cannot apply to this device — stop here and address enrollment/supervision, not the policy content.

**Step 2 — Confirm the policy exists, is the Settings Catalog DDM App Settings category, and is assigned to this device**
Intune admin center > **Devices > Configuration** > locate the policy > **Assignments** tab. Confirm the affected device's group is actually targeted — a policy that looks right but is assigned to the wrong group produces identical symptoms to a broken policy.

**Step 3 — Confirm per-device delivery status**
Intune admin center > policy > **Device status** and **Per-setting status** tabs, or via Graph (`deviceManagement/configurationPolicies/{id}/deviceStatuses`). A `Success` status here confirms the declaration landed and was accepted — it does **not** confirm the binary identifier values themselves are correct, only that the profile applied without a delivery-layer error.

**Step 4 — For a specific blocked binary, generate its real identifiers on-device**
```bash
codesign -dvvv /path/to/binary
```
Cross-check every populated field (`CDHash`, `TeamID`/`Authority`, signing identifier) character-for-character against what's configured in the Allowed/Denied Binaries list. `Allowed Binaries` requires `CDHash` or `TeamID` present; `Denied Binaries` requires `CDHash`, `TeamID`, or `SigningID` present — an entry missing its required field(s) is a validation error, not a soft warning.

**Step 5 — For a managed-app outage right after policy assignment, check `Always Allow Managed Apps` scope**
Confirm whether the affected app is VPP-licensed or a Line-of-business (LOB, non-PKG/DMG) app (covered by `Always Allow Managed Apps = True`) versus a Line-of-business (PKG) or Line-of-business (DMG) app installed via the Intune agent (explicitly **not** covered — must be listed individually).

**Step 6 — For iOS launch-control tickets, check for a stale legacy Restrictions profile**
Confirm whether a Restrictions profile using the legacy `Allowed app bundle IDs` / `Denied app bundle IDs` settings is still assigned to the same device alongside the new App Settings policy — both are now capable of governing the same bundle ID with different, deprecated-vs-current logic.

---
## Common Fix Paths

<details><summary>Fix 1 — Policy never applies (unsupervised device or OS below 27)</summary>

1. Confirm supervision state: `Get-MgBetaDeviceManagementManagedDevice` → `IsSupervised`. Supervision generally requires ADE/DEP (Automated Device Enrollment) — a BYOD/manually-enrolled device is very unlikely to be supervised.
2. Confirm OS version is macOS 27+ or iOS/iPadOS 27+ specifically — a device on 26.x, however recent, does not qualify.
3. If the device is meant to be supervised but isn't, that's an enrollment-method problem to solve first (re-enroll via ADE) — there is no supervision workaround for this feature.
4. If the device is intentionally unsupervised (BYOD), App Settings is not an available control for it — document this as a known gap for that population rather than continuing to troubleshoot the policy itself.

**Rollback:** N/A — eligibility check only, no configuration change.

</details>

<details><summary>Fix 2 — Binary identifier mismatch (policy delivers Success, block persists)</summary>

1. On the affected Mac, run `codesign -dvvv` against the actual binary path in question — never reuse an identifier copied from a different build, a vendor's documentation, or a similarly-named binary.
2. Confirm the required-field rule was followed: `Allowed Binaries` entries need `CDHash` or `TeamID`; `Denied Binaries` entries need `CDHash`, `TeamID`, or `SigningID`. An entry missing all of its required fields will not match anything reliably.
3. Update the Settings Catalog policy with the corrected identifier and re-save — this creates a new declaration version that the device picks up on its next DDM check-in.
4. Re-check `Per-setting status` after the device's next sync; do not assume the fix landed just because the edit saved successfully in the portal.

**Rollback:** Remove the corrected/added identifier entry from the policy and re-save to revert to the prior (still-broken, but known) state if the change has unintended side effects.

</details>

<details><summary>Fix 3 — Managed app blocked despite being MDM-deployed</summary>

1. Confirm how the app was actually installed: VPP-licensed or Line-of-business (non-PKG/DMG) → eligible for `Always Allow Managed Apps`. Line-of-business (PKG) or Line-of-business (DMG), installed via the Intune agent → **not** covered by that toggle under any circumstances.
2. If eligible, confirm `Always Allow Managed Apps` is actually set to `True` on the assigned policy — its default is `False`, and simply deploying an app through Intune does not implicitly allow-list it.
3. If the app type is excluded from `Always Allow Managed Apps` by design (PKG/DMG via agent), add its binary identifier explicitly to `Allowed Binaries` using values from `codesign -dvvv` on a known-good copy of the installed binary.
4. Re-verify after the next device check-in.

**Rollback:** Set `Always Allow Managed Apps` back to its prior value, or remove the explicitly-added identifier, and re-save.

</details>

<details><summary>Fix 4 — Command-line tool or script blocked (working as designed)</summary>

1. Confirm this is genuinely an unwanted block and not the control doing its job — binary execution control on macOS covers any executable, including command-line tools and scripts dropped into locations like `/tmp`, by design. This is the specific capability that closes the old "unmanaged `curl` one-liner" gap that neither Gatekeeper nor the legacy "allow apps from" restriction ever covered.
2. If the tool is legitimately needed (e.g., a finance team's quarterly utility, a developer's CLI), generate its identifier via `codesign -dvvv` and add it to `Allowed Binaries` rather than disabling the control tenant-wide.
3. If the organization hasn't yet inventoried what legitimate command-line tooling its users actually run, do **not** deploy an `Allowed Binaries`-only enforcing policy fleet-wide without first auditing real usage — an incomplete allow list will silently block legitimate work with no admin-visible warning. There is no Microsoft-documented staged/report-only enforcement mode for this policy type (unlike the Intune STIG audit baseline); build the initial rollout narrow and pilot it.

**Rollback:** Remove the offending `Denied Binaries` entry, or add the needed `Allowed Binaries` entry, and re-save.

</details>

<details><summary>Fix 5 — iOS app inaccessible after upgrade (legacy vs. new app-launch control overlap)</summary>

1. Check for a still-assigned Restrictions profile using the legacy `Allowed app bundle IDs` / `Denied app bundle IDs` settings on the same device — these are deprecated (not removed) on iOS 27 and can still be actively evaluated alongside a new App Settings policy.
2. Compare both policies' bundle ID lists for the affected app for conflicting intent.
3. Migrate the restriction to the new App Settings `Allowed Apps` / `Denied Apps` settings, then remove the legacy Restrictions profile's assignment (retain the object, unassigned, in case rollback is needed) rather than running both indefinitely.
4. Re-test after the next check-in.

**Rollback:** Re-assign the legacy Restrictions profile and remove the new App Settings policy's assignment if the migration surfaces unexpected regressions.

</details>

---
## Escalation Evidence

```
Ticket: App Settings (Binary/App Launch Control) issue
─────────────────────────────────────────
Tenant ID:                              <____________________>
Device name / serial:                   <____________________>
Platform + OS version:                  <____________________>
IsSupervised:                           <____________________>
Policy name:                            <____________________>
Per-device policy status (Success/Error/ErrorCode): <_______>
Affected item (app bundle ID / binary path): <____________________>
codesign -dvvv output (CDHash/TeamID/SigningID) for the binary: <_______>
Configured identifier value(s) in the policy: <_______>
App install method (VPP / LOB non-PKG-DMG / LOB PKG / LOB DMG): <_______>
Always Allow Managed Apps setting value: <_______>
Legacy Restrictions profile also assigned (iOS, Y/N): <_______>
Symptom (won't launch / blocked at execution / icon missing / other): <_______>
Time issue first observed:              <____________________>
```

---
## 🎓 Learning Pointers

- **Supervision is a silent, hard gate — there is no error message for "this device isn't supervised."** App Settings simply never delivers on an unsupervised macOS 27 or iOS/iPadOS 27 device. Confirm `IsSupervised` before spending any time on the policy's content. [App settings configuration for Apple devices](https://learn.microsoft.com/en-us/intune/device-configuration/templates/apple-ddm-app-settings)

- **Binary identifiers must come from the real binary, every time.** `codesign -dvvv` on the actual file in question is the only trustworthy source for `CDHash`, `TeamID`, and `SigningID` — copying a value from documentation, a different build, or a similarly-named binary is the single most common cause of a policy that reports `Success` while the block persists. [App settings configuration for Apple devices](https://learn.microsoft.com/en-us/intune/device-configuration/templates/apple-ddm-app-settings)

- **`Always Allow Managed Apps` has a narrower scope than its name implies.** It only covers VPP-licensed apps and Line-of-business apps installed via the *non*-PKG/DMG app type — Line-of-business (PKG) and Line-of-business (DMG) apps installed through the Intune agent are explicitly excluded and must be allow-listed individually. Assuming "deployed through Intune" is enough is a guaranteed self-inflicted outage the first time this policy is enabled fleet-wide. [App settings configuration for Apple devices](https://learn.microsoft.com/en-us/intune/device-configuration/templates/apple-ddm-app-settings)

- **This is genuinely new ground for the Mac — command-line tools were never covered by Gatekeeper or the old "allow apps from" restriction.** Binary execution control via the Endpoint Security framework is the first native mechanism that can block an unsanctioned `curl` one-liner or a dropped-in-`/tmp` binary, which is exactly the technique living-off-the-land and ClickFix-style social-engineering attacks rely on. Treat a blocked CLI tool as the control working, not a bug, before investigating further.

- **There is no built-in staged/report-only rollout mode documented for this policy type**, unlike the Intune STIG audit baseline's dedicated audit-only design. An incomplete `Allowed Binaries` list fails closed and silently — pilot narrowly, build the list from observed real usage, and only widen enforcement once confident, rather than deploying an enforcing allow list fleet-wide from a guess.

- **The old PPPC/TCC Accessibility grant is removed, not deprecated, on macOS 27 — and that's a different feature from this one.** If a remote-support or automation tool stops working after a macOS 27 upgrade, don't assume it's an App Settings binary block; check `PPPC-A.md` and the new declarative `Privacy` key first, since Accessibility specifically has no legacy fallback on this release.
