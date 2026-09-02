# Endpoint DLP Protection for Excluded Windows Folders — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Microsoft Purview Endpoint DLP's new capability (Microsoft 365 Roadmap ID 562992, Message Center MC1384420) to extend policy enforcement to files stored in **previously fully-excluded Windows folders** — specifically `%AppData%` (Roaming and Local) and temporary directories — during egress activities.
- The base **File path exclusions for Windows** mechanism this feature is built on top of (exclusion syntax, default-excluded paths), since the new capability cannot be understood in isolation from it.
- The Defender anti-malware client version prerequisite and its operational implications for phased rollout.

**Out of scope (covered elsewhere):**
- General Endpoint DLP onboarding, policy authoring, and the broader DLP policy model — see `DLP-Policy-A.md`/`-B.md`.
- Network share coverage and exclusions (a related but architecturally separate Endpoint DLP settings section) — briefly referenced here only where it intersects.
- macOS file path exclusions — this feature, as documented at time of writing, is Windows-only.
- DLP alert lifecycle, auto-resolution, and tagging — see `DLPAlertAutoResolution-A.md`/`-B.md`.

**Assumed baseline:**
- Microsoft Purview Endpoint DLP already onboarded on Windows 10/11 devices (Intune-managed or onboarding-script-based).
- Any DLP-licensed Microsoft 365/Office 365 tier (this is a settings/enforcement-scope change, not a separately licensed add-on).
- Worldwide standard multi-tenant cloud — GA rollout window mid-September 2026 through end of September 2026 per the current (third-revision) Message Center timeline. GCC/GCC High/DoD and sovereign clouds are not confirmed in this wave as of this writing.

---

## How It Works

### The problem this closes

Endpoint DLP's file path exclusion mechanism exists for legitimate performance and false-positive-reduction reasons: constantly scanning every write into a user's `AppData` folder (used heavily by legitimate applications for caches, temp files, and local config) would generate significant noise and overhead. Microsoft therefore ships `%SystemDrive%\Users\*(1)\AppData\Roaming` and `%SystemDrive%\Users\*(1)\AppData\Local` as **default-excluded** paths — files here are invisible to DLP entirely: not audited, not policy-evaluated, regardless of content.

The gap this created: `AppData` is user-writable and increasingly used by both legitimate line-of-business tools *and* as a deliberate evasion technique — a user (or malicious actor) who wants to move sensitive content off a device without triggering DLP can simply stage it in `AppData\Local\Temp` first, since that location was never inspected regardless of what policies existed elsewhere on the device.

### What actually changed

This feature does **not** remove the default exclusion. Excluded folders remain excluded for at-rest scanning and on-open auditing — a file can sit in `AppData` indefinitely without ever being scanned. What changes is a new, opt-in **protected exclusion path** designation: an admin can flag specific excluded paths (the two AppData defaults, or any custom exclusion) so that DLP policy checks apply specifically during **egress activities** — copy, print, save to network share, upload to cloud service — even though the folder remains otherwise excluded.

This is best understood as a third state layered onto the existing two-state model:

| State | At-rest scanning | On-open auditing | Egress-activity policy check |
|-------|:---:|:---:|:---:|
| Not excluded (default DLP scope) | Yes | Yes | Yes |
| Excluded (legacy default behavior) | No | No | No |
| **Excluded + Protected (new)** | No | No | **Yes** |

### Prerequisite: Defender anti-malware client 4.18.26051+

The egress-time check for protected-excluded paths is implemented in the Defender anti-malware client component that also hosts Endpoint DLP's activity-monitoring sensor. Devices running an older platform build silently receive **no enforcement** for protected paths — there is no error state, no partial enforcement, and no portal indicator distinguishing "not protected because too old a client" from "not protected because the path isn't flagged." This makes the client version the first and most load-bearing fact to check in any troubleshooting flow (see Troubleshooting Phase 1).

### Precedence when audit and block policies overlap

Microsoft's documented behavior: if both an audit-mode and a block-mode Devices-scoped policy apply to the same user and the same egress activity, **block takes precedence**. This is standard DLP conflict-resolution behavior extended to this new protected-path population, and is a common source of confusion during a phased audit-to-block rollout if a client assumes audit-mode intent will always be honored first.

---

## Dependency Stack

```
Layer 5: DLP policy rule action outcome
           (Audit — logged only  |  Block — action prevented; wins on conflict)
Layer 4: DLP policy scoped to Devices workload, rule covers the specific egress
           activity (copy / print / network-share save / cloud upload)
Layer 3: Protected exclusion path flag (NEW, Roadmap 562992) — opt-in per path,
           configured in Purview portal only, no cmdlet surface
Layer 2: File path exclusion list (pre-existing base mechanism)
           - Default: %SystemDrive%\Users\*(1)\AppData\Roaming
           - Default: %SystemDrive%\Users\*(1)\AppData\Local
           - Any admin-added custom path, using the same wildcard/depth syntax
Layer 1: Endpoint DLP onboarding + Defender anti-malware client >= 4.18.26051
           (hard prerequisite — enforcement silently no-ops below this floor)
```

Each layer is a strict precondition for the one above it. A misconfiguration or gap at Layer 1 or Layer 2 produces identical symptoms to a Layer 3/4 misconfiguration from the end user's perspective ("nothing happened when I copied the file") — which is why Troubleshooting Phase 1 always starts at the bottom of the stack, not the top.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Sensitive file copied out of `AppData` with zero DLP activity logged | Defender client below 4.18.26051, OR path not flagged protected | `Get-MpComputerStatus`; portal exclusion-list protected flag |
| File in `AppData` blocked from being opened/edited locally | Misdiagnosis — this feature never adds at-rest/on-open enforcement; something else is blocking (AV/EDR detection, unrelated policy) | Confirm the action was actually an egress activity, not local open/edit |
| Protection works for cloud upload but not for USB copy (or vice versa) | Policy rule's activity list doesn't cover both activity types | Review Devices-scoped policy rule's monitored-activities list |
| Feature toggle not visible in the portal at all | Tenant hasn't received the staged GA rollout yet | Confirm current date against the live MC1384420 rollout window; no early-access switch exists |
| Works in audit mode, then suddenly blocks after a second policy is added | Two policies now apply to the same user/activity; block precedence rule triggered | Enumerate all Devices-scoped policies matching the user |
| Legitimate line-of-business tool now generating high alert volume from `AppData` writes | Expected consequence of newly-visible, previously-invisible legitimate `AppData` activity — not a bug | Audit-mode pilot review (see Remediation Playbook 1) |

---

## Validation Steps

1. **Confirm client version floor.**
   ```powershell
   Get-MpComputerStatus | Select-Object AMProductVersion, AMServiceVersion
   ```
   *Good:* `AMProductVersion` >= `4.18.26051`. *Bad:* older — stop here, this fully explains no-enforcement.

2. **Confirm tenant rollout status.**
   Purview portal → Data loss prevention → Overview → Data loss prevention settings → Endpoint settings → File path exclusions for Windows. Look for the protected-path control.
   *Good:* control present. *Bad:* staged-rollout gap, not a misconfiguration.

3. **Confirm exact path and syntax match.**
   Compare the flagged path against the real file location using Microsoft's documented syntax (`\` = folder only, `\*` = subfolders only, `(n)` = exact subfolder depth, `%EnvironmentVariable%` supported).
   *Good:* exact match, correct depth. *Bad:* off-by-one wildcard depth is the most common silent miss.

4. **Confirm policy coverage of the tested activity.**
   ```powershell
   Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "EndpointDevices" } | Get-DlpComplianceRule |
       Select-Object Name, ParentPolicyName, BlockAccess, GenerateAlert
   ```
   *Good:* rule's activity scope includes the tested action. *Bad:* activity type not covered — extend the rule.

5. **Confirm end-to-end via `Get-DlpDetailReport`.**
   ```powershell
   Get-DlpDetailReport -StartDate (Get-Date).AddHours(-4) -EndDate (Get-Date) | Where-Object { $_.Workload -eq "EndpointDevices" }
   ```
   *Good:* an entry exists for the test window. *Bad:* nothing logged after the 3-hour propagation window has passed — treat as a genuine gap and escalate with the Evidence Pack below.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Prerequisite verification (always start here)**
Confirm Defender client version and Endpoint DLP onboarding status before touching any policy or exclusion-list configuration. The overwhelming majority of "protected folder isn't working" reports trace back to an unmet Layer 1 or Layer 2 prerequisite, not a Layer 3/4 misconfiguration.

**Phase 2 — Configuration verification**
Walk the Dependency Stack top-down against the portal: is the path flagged protected (Layer 3)? Is there a Devices-scoped policy rule covering the tested activity (Layer 4)? Missing either one produces the identical "nothing happened" symptom.

**Phase 3 — Timing and propagation**
DLP configuration changes (policy or exclusion-list) carry an up-to-3-hour propagation window, consistent with standard Purview DLP policy-update latency. Re-test after this window before concluding a genuine defect.

**Phase 4 — Conflict and precedence review**
If enforcement is happening but not in the expected mode (blocked when audit was expected, or vice versa), enumerate every Devices-scoped policy applying to the user and check for an overlapping audit/block pair — remember block always wins.

**Phase 5 — Escalation**
If all four phases check out and behavior still doesn't match documented expectations, this is Preview/early-GA-wave functionality with a thin troubleshooting doc set — package the Evidence Pack below and open a Microsoft support case rather than continuing to guess.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Safe rollout of protected-folder enforcement to a pilot group</summary>

1. Identify a small pilot user/device group already onboarded to Endpoint DLP with the required client version confirmed.
2. Flag the desired exclusion paths as protected in the portal.
3. Extend (or create) a Devices-scoped DLP policy rule in **audit mode only**, covering the egress activities of interest.
4. Run for a minimum of one full business cycle (Microsoft's own phased-rollout guidance pattern used elsewhere in DLP — see the companion `DLPAlertAutoResolution-A.md` for the same audit-first principle applied to a different DLP surface).
5. Review `Get-DlpDetailReport` output for the pilot window — specifically flag any legitimate line-of-business tool now generating unexpected volume from `AppData` writes; add narrowly-scoped exclusions for confirmed-safe tooling before promoting to block mode.
6. Promote to block mode only for the validated pilot population, then expand incrementally.

**Rollback:** unflagging the protected path, or reverting the policy rule to audit/removing the activity from scope, is immediate and non-destructive.

</details>

<details><summary>Playbook 2 — Responding to a legitimate false-positive surge after enabling protection</summary>

1. Do not immediately unflag the protected path tenant-wide — this re-opens the original evasion gap for everyone, not just the false-positive source.
2. Identify the specific application/process generating the volume via `Get-DlpDetailReport` grouped by device and activity pattern.
3. Add a narrowly-scoped custom file path exclusion for that specific application's known `AppData` subpath (using the same syntax rules), rather than broadening the exclusion back to the full default paths.
4. Document the exception with an owner and review date — the same governance discipline this repo applies to any DLP exception (see `DLPAlertAutoResolution-A.md` Remediation Playbooks for the documentation template pattern).

**Rollback:** removing the narrow custom exclusion re-applies full protection; no destructive action was taken.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Read-only evidence collector for Endpoint DLP protected-excluded-folder escalations.
#>
$OutputPath = "C:\DLP-EndpointFolder-Evidence"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Get-MpComputerStatus | Select-Object AMProductVersion, AMServiceVersion, AntivirusSignatureLastUpdated |
    Export-Csv "$OutputPath\DefenderClientVersion.csv" -NoTypeInformation

Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "EndpointDevices" } |
    Export-Csv "$OutputPath\DevicesScopedPolicies.csv" -NoTypeInformation

Get-DlpComplianceRule | Where-Object { $_.ParentPolicyName -in (Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "EndpointDevices" }).Name } |
    Select-Object Name, ParentPolicyName, BlockAccess, GenerateAlert, NotifyUser |
    Export-Csv "$OutputPath\DevicesScopedRules.csv" -NoTypeInformation

Get-DlpDetailReport -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) -PageSize 200 |
    Where-Object { $_.Workload -eq "EndpointDevices" } |
    Export-Csv "$OutputPath\RecentEndpointDlpActivity.csv" -NoTypeInformation

Write-Host "Evidence exported to $OutputPath. Portal-only items (protected-path flags, exact exclusion syntax) must be captured via screenshot — no cmdlet reads them." -ForegroundColor Yellow
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-MpComputerStatus` | Local Defender client version — check against 4.18.26051 floor |
| `Invoke-Command -ComputerName <x> { Get-MpComputerStatus }` | Same check, remote device |
| `Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'"` | Intune-managed Windows device inventory (onboarding population proxy) |
| `Get-DlpCompliancePolicy \| Where Workload -match EndpointDevices` | Devices-scoped DLP policies |
| `Get-DlpComplianceRule` | Rule-level detail: BlockAccess, GenerateAlert, monitored activities |
| `Get-DlpDetailReport` | Historical DLP match/activity report, filterable by Workload |
| `Update-MpSignature` | Force signature update (does not update platform/engine version) |
| `Connect-IPPSSession` | Required session for all Security & Compliance PowerShell cmdlets above |
| `Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"` | Required for Intune device inventory queries |

---

## 🎓 Learning Pointers

- This feature is an **additive, opt-in enforcement layer** on top of the existing exclusion mechanism — it does not change default behavior for any path an admin hasn't explicitly flagged. See [Configure endpoint DLP settings](https://learn.microsoft.com/en-us/purview/dlp-configure-endpoint-settings#file-path-exclusions).
- The three-state model (not excluded / excluded / excluded-and-protected) is worth internalizing explicitly — most tickets stem from assuming only two states exist.
- The Defender anti-malware client version floor fails silently, not loudly — there is no error, warning, or portal indicator when a device is too old to enforce. Always check this first.
- `AppData` and temp-folder staging is a documented data-exfiltration evasion pattern; this feature closes a real gap, not a theoretical one — frame client conversations accordingly when justifying the audit-mode pilot investment.
- MC1384420's rollout timeline has already been revised once (originally early July 2026 GA, now mid–end September 2026) across three published versions — always pull the live Message Center record rather than quoting a cached date, and note the roadmap ID (562992) when cross-referencing.
- Cross-reference `DLPAlertAutoResolution-A.md`/`-B.md` for the same "audit first, promote to block only after a validated pilot" discipline applied to a different Purview DLP surface — this repo treats it as a standing pattern, not a one-off recommendation.
