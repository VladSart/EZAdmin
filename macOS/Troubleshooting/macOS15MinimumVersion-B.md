# Intune macOS 15 Minimum Version Requirement (Golden Gate 27) — Hotfix Runbook (Mode B: Ops)
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

A user or help desk ticket reports that a Mac cannot enroll in Intune, or Company Portal / the Intune MDM agent won't install, and the device turns out to be running an older macOS version. Before troubleshooting enrollment mechanics, rule this in or out first.

```powershell
# Run via Graph — check the reported OS version for the device/user in question
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All |
    Select-Object DeviceName, OSVersion, UserPrincipalName, EnrolledDateTime |
    Sort-Object OSVersion
```

| Result | Interpretation |
|---|---|
| Device is running macOS 14.x or below AND is attempting a **new** enrollment | This is the expected block once Intune's minimum-version change ships. Not a bug — go to [Common Fix Paths](#common-fix-paths). |
| Device is running macOS 14.x or below AND is already enrolled | Not affected — already-enrolled devices remain enrolled on unsupported versions. If it's failing, troubleshoot as a normal enrollment/management issue, not a version-floor block. |
| Device is macOS 15+ and still fails to enroll | Not this topic — troubleshoot as a standard ADE/Direct Enrollment issue (see `ADE-Enrollment-A.md`/`-B.md`). |
| Fleet-wide question: "how many of our Macs are below the new floor?" | Not a live incident — see the reporting query in [Diagnosis & Validation Flow](#diagnosis--validation-flow) and treat as a proactive readiness task. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Apple releases macOS "Golden Gate 27" (expected later in 2026, exact date is
Apple's to set, not Microsoft's)
    └── Microsoft ships the corresponding Intune/Company Portal/MDM-agent update
            shortly after (Company Portal is a UNIFIED iOS+macOS app — this is
            why the change is timed to the Apple release, not an arbitrary date)
            └── New minimum supported macOS version becomes 15 (Sequoia) and later
                    ├── Devices ALREADY enrolled on macOS 14.x or below:
                    │       remain enrolled, continue to be managed
                    │       (NOT retroactively unenrolled or blocked)
                    └── Devices attempting a NEW enrollment on macOS 14.x or below:
                            enrollment blocked — must upgrade macOS first
                            └── Nuance: devices enrolled WITHOUT user affinity
                                    (ADE without user affinity, or Direct
                                    Enrollment) have a separately-documented,
                                    slightly different support statement due to
                                    shared/kiosk-style usage patterns — see
                                    aka.ms/Intune/macOS/ADE-DE-support
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm whether the affected device is a new enrollment attempt or an already-enrolled device.**
   The block only applies to NEW enrollments. An already-enrolled device failing for other reasons is a different troubleshooting path entirely — don't misattribute an unrelated failure to this change.

2. **Confirm the device's actual macOS version.**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<device-name>'" | Select-Object DeviceName, OSVersion
   ```
   Or, on the device itself: `sw_vers -productVersion`.
   Expected good: 15.0 or later. Bad: 14.x or below attempting new enrollment.

3. **Run a fleet-wide readiness sweep before this becomes reactive.**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All |
       Where-Object { [version]($_.OSVersion -replace '^(\d+\.\d+).*','$1') -lt [version]"15.0" } |
       Select-Object DeviceName, OSVersion, UserPrincipalName
   ```
   Use this proactively — the goal is identifying and upgrading affected devices before new-enrollment attempts fail in the field, not just reacting to individual tickets.

4. **If the device uses ADE without user affinity or Direct Enrollment (shared/kiosk Macs), check the separate support statement before assuming the standard rule applies unmodified.**
   These enrollment types have documented nuance beyond the basic "14.x blocked, 15+ allowed" rule — verify against current Microsoft guidance rather than assuming.

---
## Common Fix Paths

<details><summary>Fix 1 — A specific new-enrollment attempt is blocked on macOS 14.x or below</summary>

1. Confirm the device meets Apple's own macOS Sequoia (15) hardware compatibility list — not every Mac that runs macOS 14 can run macOS 15.
2. Have the user (or, for corporate-owned devices, IT) upgrade macOS to 15 or later via System Settings → General → Software Update, or a supervised/scripted upgrade path if you manage OS updates centrally.
3. Retry enrollment once the device reports macOS 15+.

Rollback: not applicable — this is a required upgrade, not a configuration change to undo.

</details>

<details><summary>Fix 2 — Hardware is too old to support macOS 15</summary>

1. Cross-check the device's model against [macOS Sequoia's compatible Mac list](https://support.apple.com/120282).
2. If the hardware genuinely cannot run macOS 15, it cannot be newly enrolled in Intune after this change ships — plan for hardware refresh rather than expecting a management-side workaround.
3. If the device only needs to remain functional (not newly enrolled), and it's already enrolled, no action is required — already-enrolled devices are unaffected.

Rollback: not applicable.

</details>

<details><summary>Fix 3 — Need to proactively identify and communicate to affected users before this ships</summary>

1. Run the fleet-wide readiness query from Diagnosis step 3 against your tenant.
2. Add the `OSVersion` and additional identifying columns (owner, department) as needed for your organization's reporting.
3. Communicate a clear upgrade deadline to affected users, tied to Microsoft's own rollout timing (shortly after Apple ships macOS Golden Gate 27 — watch the Intune "What's new" page and Message Center for the exact cutover date rather than assuming a fixed date now).
4. Re-run the query periodically as the rollout approaches to track upgrade progress.

Rollback: not applicable — this is a proactive reporting/communication task.

</details>

---
## Escalation Evidence

```
=== macOS 15 Minimum Version — Escalation Template ===
Device name:                                 <fill in>
Reported macOS version (sw_vers -productVersion): <fill in>
Enrollment type (ADE with user affinity / ADE without user affinity / Direct Enrollment / Company Portal BYOD): <fill in>
Is this a NEW enrollment attempt or an already-enrolled device?: <fill in>
Hardware model (for macOS 15 compatibility check): <fill in>
Business impact (user blocked / fleet-readiness planning):  <fill in>
Requested next step:                         <upgrade guidance / hardware refresh escalation / ADE-DE nuance clarification>
```

---
## 🎓 Learning Pointers

- This is a documented **Plan for Change** (Message Center MC1403402), not a live incident yet as of this writing — the exact cutover date depends on Apple's own macOS Golden Gate 27 release timing, which Microsoft does not control. Track the [Intune "What's new" / in-development](https://learn.microsoft.com/en-us/intune/whats-new/in-development) page and your tenant's Message Center for the confirmed date rather than assuming.
- **Already-enrolled devices are never retroactively affected.** Only new enrollment attempts on macOS 14.x or below are blocked once the change ships — don't tell users their currently-managed Mac will stop working.
- Company Portal for iOS and macOS is a **unified app** — this is specifically why the macOS version floor change is timed to follow the Apple OS release rather than landing on an independent Microsoft schedule.
- Enrollment types without user affinity (ADE without user affinity, Direct Enrollment) have a documented, separate support nuance due to shared-device usage patterns — don't assume the standard user-affinity enrollment rule applies unmodified; check `aka.ms/Intune/macOS/ADE-DE-support` for current guidance.
- Not every Mac that currently runs macOS 14 will support macOS 15 — cross-check against Apple's own compatibility list before promising users a simple in-place upgrade path.
- Related: `macOS/Troubleshooting/ADE-Enrollment-A.md`/`-B.md` (enrollment mechanics this floor change gates), `macOS/Troubleshooting/SoftwareUpdates-A.md`/`-B.md` (managing the OS upgrade itself at scale via Intune).
