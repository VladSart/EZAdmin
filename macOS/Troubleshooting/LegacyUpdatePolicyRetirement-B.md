# Legacy macOS Update Policy Retirement (MDM → DDM Migration) — Hotfix Runbook (Mode B: Ops)
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

> **This is a deprecation, not an outage.** Apple has deprecated MDM-based software update workloads; Microsoft Intune will "soon" end support for the legacy **Update policies for macOS** console feature (Devices > Apple updates > macOS update policies). No confirmed retirement date has been published as of this writing — treat every ticket here as a proactive migration item, not a break-fix.

Run against the tenant (Graph/PowerShell, not on-device):

```powershell
# 1. Which macOS devices are still targeted by the legacy update-policy feature?
Get-MgDeviceManagementDeviceConfiguration -Filter "isof('microsoft.graph.macOSSoftwareUpdateConfiguration')" |
    Select-Object Id, DisplayName

# 2. What macOS version is actually on the affected devices?
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" |
    Select-Object DeviceName, OSVersion, ManagementAgent
```

| Result | Interpretation |
|---|---|
| Legacy `macOSSoftwareUpdateConfiguration` policies exist AND targeted devices are macOS 13+ | **Actively wrong today**, not just "future risk" — Microsoft's own guidance says don't use the MDM-based policy on macOS 13+ at all; DDM should already be the sole mechanism there. Go to Fix 1. |
| Legacy policies exist, targeted devices are macOS 12 only | Currently correct (macOS 12 has no DDM path) — but flag for a forward-looking migration plan once those devices are upgraded past 12. Go to Fix 2. |
| No legacy `macOSSoftwareUpdateConfiguration` policies found | Tenant already fully migrated to DDM for software updates — close as no action needed, but confirm the DDM Settings Catalog profile actually exists (don't assume "no legacy policy" means "DDM is configured"; it could mean neither is configured). |
| Ticket describes an update that "won't force install" or "ignores the deadline" on a macOS 13+ device | Likely symptom of DDM Software Update Enforcement misconfiguration — this is a **different, already-covered** topic; see `SoftwareUpdates-A.md`/`-B.md` for DDM enforcement architecture and troubleshooting, not this file. |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Apple's own platform decision: legacy MDM software-update commands deprecated
    │
    ▼
Microsoft Intune: "Update policies for macOS" console feature — end of support pending
(no confirmed date; Microsoft's own guidance already says stop using it on macOS 13+)
    │
    ▼
Device OS version determines the correct mechanism TODAY:
    macOS 12 and older  → legacy MDM update policy is the ONLY option (DDM doesn't exist there)
    macOS 13 and newer  → DDM is the recommended/sole-supported mechanism;
                           legacy MDM update policy should NOT be assigned
    │
    ▼
DDM replacement = Settings Catalog, NOT a 1:1 setting-for-setting swap:
    Legacy "Update policy" (Critical/Firmware/Configuration/All-other-updates
    behavior + weekly schedule windows)
        ↓ maps conceptually, not literally, to ↓
    Settings Catalog > Declarative Device Management > Software Update Enforcement
    (specific-version + deadline + delay-before-enforcement model)
    PLUS
    Settings Catalog > Restrictions (Enforced Software Update Delay and siblings)
    for visibility-delay behavior
    │
    ▼
Coexistence risk: assigning BOTH the legacy policy and a DDM Settings Catalog
profile to the same macOS 13+ device is not a supported end-state — Microsoft's
own guidance is explicit that the legacy policy should not be used at all once
DDM is available for that OS version
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm which devices still carry a legacy update policy.**
   ```powershell
   Get-MgDeviceManagementDeviceConfiguration -Filter "isof('microsoft.graph.macOSSoftwareUpdateConfiguration')"
   ```
   Any result here is a candidate for migration review — this profile type is the one Microsoft's deprecation notice targets.

2. **Cross-reference against actual device OS version**, not just enrollment date or assumed fleet baseline:
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" | Select-Object DeviceName, OSVersion
   ```
   Any macOS 13+ device still assigned the legacy policy is out of alignment with current Microsoft guidance today, independent of when the feature is actually retired.

3. **Check whether a DDM Software Update Settings Catalog profile already coexists** for the same device group:
   ```powershell
   Get-MgDeviceManagementConfigurationPolicy | Where-Object { $_.TemplateReference.TemplateFamily -eq 'declarativeDeviceManagement' -or $_.Name -match 'Software Update' }
   ```
   If both a legacy policy and a DDM profile target the same macOS 13+ device, don't assume they layer additively — validate actual on-device behavior against the Symptom → Cause Map in `SoftwareUpdates-A.md`, since overlapping mechanisms is an unsupported and under-documented combination.

4. **Confirm no dependency on macOS-12-only fleet before removing the legacy policy.**
   Removing the legacy policy from a device group that still includes macOS 12 devices removes their *only* update-management mechanism — verify OS version per-device, not per-group-assumption, before any change.

---
## Common Fix Paths

<details><summary>Fix 1 — macOS 13+ devices still on the legacy update policy (out of alignment today)</summary>

1. Confirm target devices are macOS 13+ (Validation Step 2).
2. Build the DDM equivalent via **Settings Catalog > Declarative Device Management > Software Update Enforcement** (specific target version + install deadline + delay-before-enforcement) — see `SoftwareUpdates-A.md`/`-B.md` for full DDM configuration mechanics; this file does not duplicate that.
3. Pilot the DDM profile against a small device group *before* removing the legacy policy — the two are not guaranteed to coexist cleanly, so sequence this as add-DDM → validate → remove-legacy, not a simultaneous swap.
4. Once validated, remove the legacy `macOSSoftwareUpdateConfiguration` assignment from the migrated device group.

**Rollback:** Reassign the legacy policy if DDM enforcement doesn't behave as expected — this is safe as an interim step since the legacy mechanism remains fully functional until Microsoft's (currently unpublished) actual retirement date.
</details>

<details><summary>Fix 2 — Mixed fleet: some devices still macOS 12, can't fully retire the legacy policy yet</summary>

1. Split the device group: macOS 13+ devices get the DDM Software Update Enforcement profile (Fix 1); macOS 12 devices keep the legacy update policy as their only available mechanism.
2. Track macOS 12 devices explicitly as a forward-migration list — once each is upgraded past 12, move it out of the legacy-policy-targeted group and confirm DDM coverage picks it up.
3. Do not wait for 100% fleet upgrade before starting the macOS 13+ portion of the migration — the deprecation applies per-device-capability, not per-tenant-readiness.

**Rollback:** N/A — this is a scoping/sequencing fix, not a destructive change.
</details>

<details><summary>Fix 3 — Legacy policy and DDM profile both assigned to the same macOS 13+ device (conflict risk)</summary>

1. Do not assume the two "just layer" safely — Microsoft's guidance is that the legacy policy should not be used at all once DDM is available for that OS version, not that it's a lower-priority fallback.
2. Remove the legacy policy assignment for the overlapping device group once the DDM profile is confirmed working (per Fix 1's validate-before-remove sequencing).
3. If update behavior looks inconsistent on an overlapping device, treat the overlap itself as the prime suspect before deep-diving into DDM-specific troubleshooting.

**Rollback:** Remove whichever profile was added most recently to return to the prior known-working single-mechanism state, then re-attempt migration with tighter validation.
</details>

<details><summary>Fix 4 — Stakeholder asks "when do we HAVE to migrate?"</summary>

There is no published hard deadline as of this writing — Microsoft's own documentation says only that support will end "soon." Do not commit to a specific date on the organization's behalf. Correct framing: (a) on macOS 13+, the legacy policy is already discouraged today, independent of the eventual retirement date; (b) migrate opportunistically now rather than waiting for a forced-cutover deadline that could arrive with less notice than a Message-Center-driven change typically gets. Revisit this runbook's header note once Microsoft publishes a confirmed date.

**Rollback:** N/A — communication guidance only.
</details>

---
## Escalation Evidence

```
=== Legacy macOS Update Policy Retirement — Escalation Template ===
Tenant:
Ticket #:
Device group affected:
Device count in group:
macOS versions present in group (13+ / 12 / mixed):
Legacy macOSSoftwareUpdateConfiguration policy name(s):
DDM Software Update Settings Catalog profile present for same group? (Y/N):
Both legacy AND DDM currently assigned to the same device(s)? (Y/N):
Observed behavior:
Expected behavior:
Steps already attempted:
```

---
## 🎓 Learning Pointers
- This is a **deprecation-driven migration**, structurally similar to this repo's `ConnectSyncUpgrade-A/B.md` and `MemberOfRetirement-A/B.md` topics — no confirmed hard date yet, but the "correct" state (DDM on macOS 13+) is already true today regardless of when enforcement of the deprecation actually lands.
- Read the deprecation notice directly rather than trusting a summary: [Use Microsoft Intune policies to manage macOS software updates](https://learn.microsoft.com/en-us/intune/device-updates/apple/deprecated-mdm-policies-macos) carries Microsoft's own "will soon end support" language and the exact OS-version applicability (macOS 12–15 for the legacy feature).
- The [Admin guide and checklist for macOS software updates](https://learn.microsoft.com/en-us/intune/device-updates/apple/planning-guide-macos) is explicit that macOS 13 is the version boundary: DDM for 13+, legacy MDM policy only as a last resort for 12 and older.
- Don't conflate this topic with DDM's own internal architecture or enforcement troubleshooting — that's already covered in depth in `SoftwareUpdates-A.md`/`-B.md` and `DDM-A.md`/`-B.md`. This runbook is scoped specifically to the migration-off-the-legacy-feature decision and sequencing.
- The [Intune Customer Success blog post on this transition](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-move-to-declarative-device-management-for-apple-software-updates/4432177) is Microsoft's own recommended first read for the "why now" context behind the deprecation.
