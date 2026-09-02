# Legacy macOS Update Policy Retirement (MDM → DDM Migration) — Reference Runbook (Mode A: Deep Dive)
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

Covers the **deprecation of Intune's legacy MDM-based "Update policies for macOS" console feature** (Graph type `macOSSoftwareUpdateConfiguration`, portal path Devices > Apple updates > macOS update policies) and the migration path to **Declarative Device Management (DDM) Software Update Enforcement**, configured via the Settings Catalog. Apple deprecated the underlying MDM software-update commands the legacy feature depends on; Microsoft's own documentation states Intune "will soon end support" for MDM-based Apple software update policies, with **no confirmed retirement date published as of this writing**.

This is **not**:
- A re-explanation of DDM's internal architecture, the pre-DDM vs. DDM enforcement pipeline, or Settings Catalog Software Update Enforcement configuration mechanics — all of that is already covered in depth in `SoftwareUpdates-A.md`/`-B.md` and `DDM-A.md`/`-B.md`. This runbook assumes that content as background and focuses specifically on the **migration decision, sequencing, and current-state-correctness** question.
- A statement of a confirmed cutover date — none exists yet. Treat any date mentioned by a vendor blog or third party as speculative until it appears on the official Microsoft Learn deprecation page itself.
- Related to iOS/iPadOS's own, separately-tracked update-policy deprecation, which follows a similar but not identical timeline and settings surface (`planning-guide-ios-ipados` on Microsoft Learn) — out of scope here.

**In scope:**
- macOS devices enrolled in Intune, targeted historically or currently by the legacy `macOSSoftwareUpdateConfiguration` profile type
- The OS-version boundary (macOS 13 as the DDM-availability line) that determines whether the legacy policy is still necessary, optional, or actively discouraged for a given device today

**Assumptions:**
- Devices are supervised and ADE-enrolled (required for either the legacy MDM update commands or DDM software update enforcement)
- Tenant already has, or is building, a DDM Software Update Enforcement Settings Catalog profile as the target end-state

**Source-confidence note:** Microsoft's own Learn pages (`deprecated-mdm-policies-macos`, `ms.date` 2025-09-24, `updated_at` 2026-06-22; `planning-guide-macos`, `updated_at` 2026-06-22) explicitly use "will soon end support" without a date — this runbook deliberately does not manufacture a specific deadline. Revisit and tighten this runbook once Microsoft publishes one.

---
## How It Works

<details><summary>Full architecture — why this deprecation exists and what actually changes</summary>

### Why Apple deprecated the underlying commands

Apple's own platform direction (announced at WWDC, effective across iOS/iPadOS/macOS) moved software-update management from **imperative MDM commands** (`ScheduleOSUpdate`, `AvailableOSUpdates`, `InstallApplication`) — where the MDM server tells the device exactly what to do and polls for completion — to **declarative device management**, where the MDM server publishes a *desired state* (target version, deadline) and the device itself autonomously manages the entire download/prepare/notify/install lifecycle, reporting status back only on its own schedule. This is a platform-wide architectural shift, not an Intune-specific product decision — Intune's deprecation of the legacy console feature is downstream of Apple's own command deprecation, which is why there's no way for Microsoft to simply "keep supporting" the old feature indefinitely once Apple stops honoring the underlying commands.

### What the legacy feature actually configured

The legacy **Update policies for macOS** feature (introduced pre-DDM, applicable macOS 12–15 supervised) exposed:
- Per-update-type behavior (**Critical**, **Firmware**, **Configuration file**, **All other updates**) — each independently configurable as Download and install / Download only / Install immediately / Notify only / Install later / Not configured
- **Max User Deferrals** and **Priority** for the "Install later" behavior on minor OS updates
- A **weekly schedule** (update-at-next-check-in, or time-windowed "during"/"outside" scheduling), evaluated against Intune-service time, not device-local time
- A companion Settings Catalog **Restrictions** policy layer (`Enforced Software Update Delay` and siblings) to control *visibility* of updates independent of the install-behavior policy above

This is a materially different control model from DDM's Software Update Enforcement (a single target-version-and-deadline declaration that the device executes autonomously) — there is **no exact 1:1 field mapping** between the two. A migration is a redesign of the update-management approach, not a lift-and-shift of settings.

### The OS-version boundary that matters right now

| macOS version | DDM software update management available? | Correct mechanism today |
|---|---|---|
| 12 (Monterey) and older | No | Legacy MDM update policy — the only option |
| 13 (Ventura) and newer | Yes | DDM Software Update Enforcement (Settings Catalog) — Microsoft's own planning guide says explicitly **don't use** the legacy MDM policy settings on these devices |

This means the "deprecation" isn't purely a future event to plan around — for any macOS 13+ device still targeted by the legacy policy, the tenant is *already* out of alignment with Microsoft's current guidance, independent of when the feature is formally retired. This is the single most important framing point for triage: don't treat every legacy-policy sighting as low-urgency just because there's no hard deadline yet.

### Why "just leave both assigned" isn't a safe default

Microsoft's documentation frames DDM as the *replacement* for the legacy mechanism on macOS 13+, not as a complementary or higher-priority layer on top of it. The planning guide's explicit instruction — "Don't use the MDM-based software update policy settings on these devices" — means overlapping assignment on macOft 13+ devices is an unsupported, under-documented combination whose interaction Microsoft does not commit to a defined behavior for. Treat any ticket describing inconsistent update behavior on a device with both profiles assigned as an overlap-caused symptom first, before assuming a DDM-specific bug.

</details>

---
## Dependency Stack

```
Apple platform decision
  Legacy MDM software-update commands deprecated (WWDC-announced, cross-platform)
        │
        ▼
Microsoft Intune product response
  "Update policies for macOS" (macOSSoftwareUpdateConfiguration) — support ending,
  no confirmed date published as of this writing
        │
        ▼
OS-version gate (determines what's correct TODAY, not just eventually)
  macOS 12 and older → legacy policy remains the only mechanism
  macOS 13 and newer → DDM Software Update Enforcement is the sole recommended mechanism
        │
        ▼
Target-state configuration (macOS 13+)
  Settings Catalog > Declarative Device Management > Software Update Enforcement
  (target version/build + enforced deadline + delay-before-enforcement)
  optionally paired with
  Settings Catalog > Restrictions (Enforced Software Update Delay and siblings)
  for pre-deadline visibility control
        │
        ▼
Migration sequencing discipline
  Add DDM profile → validate on pilot group → remove legacy policy assignment
  (not a simultaneous swap — avoids the undocumented overlap-behavior risk)
        │
        ▼
Ongoing tracking
  macOS-12-fleet upgrade progress determines when the legacy policy can be
  fully retired tenant-wide, not a single fixed date
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| macOS 13+ device still assigned the legacy update policy | Migration not yet started for this device group, or group membership wasn't updated after devices upgraded past macOS 12 | `Get-MgDeviceManagementDeviceConfiguration -Filter "isof('microsoft.graph.macOSSoftwareUpdateConfiguration')"` cross-referenced with device OS version |
| Update behavior inconsistent/unpredictable on a specific device | Legacy policy AND DDM profile both targeting the same device | Enumerate all Software-Update-related profiles assigned to that device's groups |
| macOS 12 device has no update management at all | Legacy policy was removed prematurely, before the device was upgraded past 12 | Confirm device OS version before any legacy-policy removal, per-device not per-group |
| "We migrated to DDM but nothing changed" | DDM Settings Catalog profile was created but never assigned, or assigned to the wrong device group | Confirm actual assignment, not just profile existence |
| Stakeholder asks for a hard migration deadline | No published date exists yet | Cite Microsoft's own "will soon end support" language rather than inventing a date |
| Ticket is actually about DDM enforcement not working (deadline ignored, wrong version installed) | Wrong runbook — this is DDM configuration/enforcement troubleshooting, not the migration-off-legacy question | Redirect to `SoftwareUpdates-A.md`/`-B.md` |

---
## Validation Steps

1. **Inventory legacy policy assignments tenant-wide.**
   ```powershell
   Get-MgDeviceManagementDeviceConfiguration -Filter "isof('microsoft.graph.macOSSoftwareUpdateConfiguration')" | Select-Object Id, DisplayName
   ```
   Good: empty result (already migrated) or a known, tracked, intentionally-scoped-to-macOS-12 set. Bad: policies assigned to groups that also contain macOS 13+ devices.

2. **Cross-reference actual device OS versions against legacy-policy-targeted groups.**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" | Select-Object DeviceName, OSVersion, Id
   ```
   Good: every legacy-policy-targeted device is confirmed macOS 12 or older. Bad: any macOS 13+ device present in that population.

3. **Confirm DDM Software Update Enforcement coverage exists for the macOS 13+ population.**
   Verify a Settings Catalog profile under the Declarative Device Management category is assigned to the corresponding device group(s) — absence here means those devices currently have **no** update management at all if the legacy policy has already been removed, which is a worse state than an unmigrated one.

4. **Check for overlap.**
   Confirm no single device or device group is targeted by both the legacy policy and a DDM Software Update Enforcement profile simultaneously, except deliberately during a bounded pilot-validation window.

5. **Confirm the migration tracking artifact exists.**
   Since there's no forced cutover date, migration progress depends entirely on internal tracking discipline — confirm a list of remaining macOS-12 devices (and their expected upgrade timeline) exists somewhere durable, not just tribal knowledge.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Inventory
- Enumerate all legacy `macOSSoftwareUpdateConfiguration` profiles and their assignments.
- Enumerate actual OS versions for every targeted device — don't trust group naming conventions as a proxy for actual OS version.

### Phase 2 — Gap analysis
- Identify macOS 13+ devices still on the legacy policy (out of alignment today).
- Identify macOS 13+ devices with **neither** mechanism configured (a gap independent of this migration, but often discovered during this exercise).
- Identify any macOS 12 devices at risk of having their only update mechanism removed prematurely by an overly broad migration change.

### Phase 3 — Migration execution
- Build/confirm the DDM Software Update Enforcement profile for the macOS 13+ target state.
- Pilot against a small device group; validate actual on-device update behavior (see `SoftwareUpdates-A.md` Validation Steps for DDM-specific checks).
- Remove the legacy policy assignment only after DDM behavior is confirmed working for that group.

### Phase 4 — Ongoing tracking
- Maintain the macOS-12-device list as an active migration backlog, not a one-time snapshot.
- Re-check Microsoft Learn periodically for a published retirement date — once one exists, this runbook's framing shifts from "proactive best practice" to "hard deadline," and messaging to stakeholders should update accordingly.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full tenant migration audit and remediation plan</summary>

1. Run the Evidence Pack script below to get a point-in-time inventory of legacy-policy assignments vs. actual device OS versions.
2. Segment the output into three buckets: (a) macOS 13+ on legacy policy — migrate now; (b) macOS 12 on legacy policy — correct, track for future upgrade; (c) macOS 13+ with no update mechanism at all — build DDM profile as a net-new gap, unrelated to this specific deprecation but often surfaced by the same audit.
3. Execute Fix 1 from the companion Mode B runbook for bucket (a), tracking each device group through pilot → validate → cutover.

**Rollback:** Each step is independently reversible (re-add legacy policy, remove DDM profile) until the final legacy-policy-removal step for a given group.
</details>

<details><summary>Playbook 2 — Communicating migration urgency without a hard deadline</summary>

1. Frame the ask around **current-state correctness** (macOS 13+ devices should already be on DDM per Microsoft's own guidance) rather than a countdown to a date that doesn't exist yet.
2. Flag that Apple/Microsoft deprecation cutovers in this ecosystem have historically arrived with limited lead time once officially announced (compare this repo's own `macOS15MinimumVersion-A/B.md` Plan-for-Change handling) — proactive migration reduces exposure to a compressed forced-migration window later.
3. Revisit and update this messaging once a confirmed date is published.

**Rollback:** N/A — communication guidance only.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Tenant-wide audit: legacy macOS update policy assignments vs. actual device OS versions.
.DESCRIPTION Read-only Graph query. Identifies macOS devices still targeted by the legacy
             macOSSoftwareUpdateConfiguration profile type, cross-referenced against their
             actual OS version, to flag macOS 13+ devices that are out of alignment with
             current Microsoft guidance. Does not create, modify, or remove any policy.
.NOTES       Requires Microsoft.Graph.DeviceManagement module and DeviceManagementConfiguration.Read.All,
             DeviceManagementManagedDevices.Read.All scopes.
#>
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All"

$legacyPolicies = Get-MgDeviceManagementDeviceConfiguration -Filter "isof('microsoft.graph.macOSSoftwareUpdateConfiguration')"
$macDevices     = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" | Select-Object DeviceName, OSVersion, Id, AzureAdDeviceId

$report = foreach ($policy in $legacyPolicies) {
    $assignments = Get-MgDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId $policy.Id
    [pscustomobject]@{
        PolicyName      = $policy.DisplayName
        PolicyId        = $policy.Id
        AssignmentCount = $assignments.Count
    }
}

$report | Format-Table -AutoSize
$macDevices | Where-Object { [version]($_.OSVersion -replace '[^\d\.].*$','') -ge [version]"13.0" } |
    Select-Object DeviceName, OSVersion |
    Format-Table -AutoSize -Property @{Label="macOS 13+ devices (verify individually against legacy policy assignment)"; Expression={$_.DeviceName}}, OSVersion
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-MgDeviceManagementDeviceConfiguration -Filter "isof('microsoft.graph.macOSSoftwareUpdateConfiguration')"` | List all legacy macOS update policies |
| `Get-MgDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId <id>` | List assignments for a specific legacy policy |
| `Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'"` | List all managed macOS devices with OS version |
| `Get-MgDeviceManagementConfigurationPolicy` | List Settings Catalog policies (to find the DDM Software Update Enforcement replacement) |

---
## 🎓 Learning Pointers
- This deprecation is a direct downstream consequence of Apple's own platform architecture shift (imperative MDM commands → declarative device management) — understanding that origin explains why Microsoft can't simply keep the legacy feature working indefinitely, and why the analogous iOS/iPadOS deprecation follows the same underlying cause.
- [Use Microsoft Intune policies to manage macOS software updates](https://learn.microsoft.com/en-us/intune/device-updates/apple/deprecated-mdm-policies-macos) is the authoritative deprecation notice — re-check its "Important" banner for a published date before this runbook is used again more than a few months out.
- [Admin guide and checklist for macOS software updates](https://learn.microsoft.com/en-us/intune/device-updates/apple/planning-guide-macos) is the single clearest source for the macOS-13-as-the-boundary rule and the explicit "don't use MDM policy on 13+" guidance this runbook is built around.
- This repo already has mature, separate coverage of DDM's own internals and enforcement troubleshooting (`SoftwareUpdates-A/B.md`, `DDM-A/B.md`) — resist the urge to re-explain that content here; this topic is specifically about the migration-off-legacy decision.
- Compare this "Plan for Change with no confirmed date" pattern to `macOS15MinimumVersion-A/B.md` in this same repo — both are proactive-migration topics that will need a follow-up tightening pass once Microsoft publishes a firm date, and both illustrate why this repo tracks unconfirmed-timeline deprecations explicitly rather than waiting for a hard deadline to document them.
