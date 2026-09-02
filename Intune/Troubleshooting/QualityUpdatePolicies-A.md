# Windows Autopatch Quality Update Policies — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

This runbook covers the **cloud-based Windows quality update policy** object introduced to Windows Autopatch starting September 1, 2026 (rollout complete across all tenants by ~October 15, 2026) — the new admin-facing control surface for **approving, deferring, and pausing** monthly Windows security updates, monthly non-security preview releases, out-of-band (OOB) releases, and supported .NET Framework updates. It also covers the companion per-device **Quality update status report**. It does **not** cover:

- Ring-based deployment orchestration, automatic incident-triggered pause/rollback, or the driver/firmware track — see `Autopatch-A/B.md`, which remains accurate and complementary.
- Hotpatch-specific enrollment/eligibility mechanics — see `Hotpatch-A/B.md`, referenced here only for the documented interaction with non-security update approval.
- Quick machine recovery's own remediation-fix content — the *same policy experience and approval controls* now extend to Quick machine recovery, but its recovery-environment mechanics are a distinct topic.
- Legacy (non-cloud, CSP/GPO-based) Windows Update for Business deferral/deadline policy authoring — referenced here only where it interacts with (and is overridden by) the new cloud-based policy.

---

## How It Works

<details><summary>Full architecture</summary>

Prior to this feature, Windows Autopatch's update behavior was largely **implicit**: ring assignment plus Microsoft's own health-telemetry-driven auto-pause gave admins staggered rollout and safety, but no direct lever to say "approve this specific release now" or "hold this specific release, but only this one." The cloud-based quality update policy adds that missing lever as a first-class, per-release, per-category, per-policy object — while explicitly layering on top of, not replacing, the existing ring/update-ring infrastructure.

```
┌────────────────────────────────────────────────────────────────────┐
│  Microsoft ships a release (2nd Tuesday = security; 4th week =       │
│  non-security preview; ad hoc = OOB security/non-security)           │
└───────────────────────────────┬──────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────┐
│  Windows quality update policy (cloud-based, per-category settings)  │
│      ├── Monthly security updates      → default: AUTOMATIC          │
│      ├── Monthly non-security preview  → default: MANUAL             │
│      ├── OOB security updates          → default: MANUAL             │
│      └── OOB non-security updates      → default: MANUAL             │
│            (same settings govern the matching .NET Framework         │
│             update category, in the same policy object)              │
└───────────────────────────────┬──────────────────────────────────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    ▼                             ▼
      ┌───────────────────────────┐   ┌───────────────────────────────┐
      │ AUTOMATIC approval         │   │ MANUAL approval                 │
      │  Deferral: 0-30 days       │   │  Admin must explicitly Approve  │
      │  → release offered after   │   │  each release, per policy,      │
      │    (release date +         │   │  before ANY device receives it  │
      │    deferral)                │   │                                  │
      │  → admin can override      │   │  Admin can also PAUSE an        │
      │    (approve early)         │   │  already-approved release       │
      └─────────────┬───────────────┘   └───────────────┬─────────────────┘
                     └───────────────┬───────────────────┘
                                       ▼
                    ┌──────────────────────────────────────┐
                    │  Release state: Approved / Paused /    │
                    │  Needs review (per policy)             │
                    │    Pause → revokes approval, no NEW     │
                    │    devices receive it; already-          │
                    │    installed devices are NOT rolled back │
                    │    Resume → re-Approve, offered again    │
                    │    as if newly approved                  │
                    └────────────────────┬────────────────────┘
                                          │  (up to 8h Intune check-in latency
                                          │   for pause/resume to reach devices)
                                          ▼
                    ┌──────────────────────────────────────┐
                    │  Device compliance date calculated:    │
                    │   Manual: approval date + deadline      │
                    │   Automatic: release date + deferral +  │
                    │     deadline                             │
                    │  (deadline itself sourced from Update    │
                    │   rings / WUfB CSP policy, unchanged)    │
                    └────────────────────┬────────────────────┘
                                          ▼
                    ┌──────────────────────────────────────┐
                    │  Quality update status report          │
                    │  (per-device, 4h refresh cycle)         │
                    │    Update status / Target release /     │
                    │    Installed release / Applied policy   │
                    └──────────────────────────────────────┘
```

**Precedence is the architectural core of this feature.** A device can simultaneously be targeted by a legacy Update ring policy (deadline, active hours, deferral via CSP) AND a new cloud-based quality update policy (approval, deferral, pause). Rather than merging the two, Windows Autopatch applies strict precedence: the cloud-based quality update policy's approval and deferral settings win outright; the legacy ring policy's deadline and grace-period settings remain in force alongside it. This is a deliberate hybrid, not a migration cutover — Microsoft explicitly supports (and expects) a transition period where both coexist.

**.NET Framework updates are folded into the same policy object, but asymmetrically by platform.** For Windows 11 devices, the quality update policy's approval settings govern .NET Framework security/non-security/OOB releases identically to OS releases (same category, same approval toggle). Windows 10 devices enrolled in Extended Security Updates (ESU) are the exception: they keep receiving .NET Framework updates through legacy Windows Update client-side settings regardless of this policy — only their OS quality updates are governed by it. .NET Framework 3.5 is excluded from this entire workflow at the platform level and is never managed through Windows Autopatch quality update policies.

**Quick machine recovery inherits the identical control model** (automatic/manual approval, defer, approve-immediately, pause) for Microsoft-provided fixes applied via the Windows Recovery Environment when a device fails to boot twice consecutively — configured in the same policy creation flow, not a separate object.

</details>

---

## Dependency Stack

```
[Microsoft Intune tenant with Windows Autopatch enabled]
    │
    ├── [Cloud-based Windows quality update policy] (new object, Sept 2026 rollout)
    │     ├── Scope tags (or Default)
    │     ├── Device/group assignment
    │     │     └── Device auto-enrolls in Autopatch for quality updates on assignment
    │     │           └── 24h grace period on unassignment before auto-unenrollment
    │     ├── Per-category approval method (immutable after policy creation):
    │     │     ├── Monthly security          — default Automatic
    │     │     ├── Monthly non-security       — default Manual
    │     │     ├── OOB security               — default Manual
    │     │     └── OOB non-security           — default Manual
    │     ├── Deferral period (0-30 days) — Automatic categories only
    │     ├── Quick machine recovery settings (same approval/defer/pause model)
    │     └── Hotpatch update setting
    │           └── Approving non-security updates while hotpatch is ON pulls the
    │                 device off the hotpatch path for that cycle (documented conflict)
    │
    ├── [Legacy Update ring policy] (may coexist)
    │     └── Deadline + grace period + active hours — remain in effect regardless
    │           of which policy governs approval/deferral
    │
    ├── [Legacy quality update policy with only hotpatch setting] (may coexist)
    │     └── Cloud-based quality update policy takes priority when both are assigned
    │
    ├── Device NOT on a Windows Insider build
    │     └── Insider-build devices are excluded from quality update policy enrollment
    │           entirely — approval settings never apply to them
    │
    └── [Quality update status report] (Reports > Windows Autopatch > Windows quality
          updates > Reports tab) — 4-hour data refresh cycle, reads the effective state
          of everything above per device
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Security update not installing despite "Automatic" | Deferral period too long, or release Paused | Policy deferral setting; release approval state |
| Non-security/OOB update never arrives | Default is Manual for these categories — expected, not a fault | Per-category approval method |
| Devices that already installed a paused release are "still affected" | Pause never rolls back — documented, not a bug | Client expectation, not a config check |
| Pause/resume appears to have no effect for hours | Up to 8h Intune check-in latency | Elapsed time since action |
| Hotpatch device took an unexpected full restart | Non-security update approved while hotpatch enabled — pulls device off hotpatch path | Policy hotpatch setting + recently approved categories |
| Compliance date looks wrong | Wrong formula applied (manual vs. automatic) or deadline source misread | Approval method for the specific release; Update ring/WUfB deadline setting |
| Can't change Automatic↔Manual on existing policy | Approval method is immutable post-creation by design | Policy age; must create new policy instead |
| Device behavior inconsistent under dual ring + cloud policy assignment | Cloud policy wins approval/deferral; ring policy's deadline/grace period still active | Quality update status report's "Applied policy" column |
| Windows 10 ESU device's .NET Framework updates ignore the policy | Expected — ESU devices get .NET Framework via legacy client settings regardless | Device OS/ESU enrollment status |
| .NET Framework 3.5 updates behave unpredictably vs. policy expectations | Out of scope entirely — never managed by Autopatch quality update policies | Confirm .NET Framework version in question |

---

## Validation Steps

1. **Policy assignment.** Manage updates blade → confirm device/group targeted by the intended cloud-based policy. Good: listed under the expected policy. Bad: only under a legacy ring, or under an unexpected second policy.
2. **Per-category approval settings.** Open policy → verify each of the four categories independently. Good: matches documented intent for each. Bad: assumption that "Automatic" applies uniformly across categories.
3. **Release state.** Manage updates → select Release → check Approved-policies count and Paused flag. Good: Approved, not Paused, for the relevant policy. Bad: Needs review or Paused.
4. **Compliance date math.** Cross-check Target compliance against the correct formula (manual vs. automatic) using the Quality update status report. Good: matches calculation. Bad: doesn't match — check deadline source (Update ring/WUfB) separately.
5. **Precedence resolution.** If dual-policy, confirm via the report's Applied policy column rather than inferring. Good: matches documented precedence order. Bad: unexpected policy shown as authoritative — re-examine assignment scope for overlaps.
6. **Hotpatch interaction.** If hotpatch-enabled, confirm no non-security update was recently approved for that policy before treating an unexpected restart as a fault.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Policy identification.** Establish which policy type(s) actually target the device: cloud-based quality update policy, legacy Update ring, legacy hotpatch-only quality update policy — any combination is possible, and precedence rules only make sense once all applicable policies are identified.

**Phase 2 — Category-level settings audit.** For the specific release category in question (security/non-security/OOB security/OOB non-security, or the .NET Framework equivalent), confirm the actual configured approval method and deferral — never assume uniformity across categories within one policy.

**Phase 3 — Release-level state check.** Confirm the specific release's approval/pause status for the specific policy — release state is evaluated per policy, not globally.

**Phase 4 — Timing/latency check.** Before escalating a "didn't take effect" ticket, confirm elapsed time against the documented up-to-8-hour pause/resume propagation window, and against the deferral period for automatic approvals.

**Phase 5 — Cross-feature interaction check.** Confirm hotpatch state and recent non-security approvals if an unexpected restart is involved; confirm ESU/LTSC/.NET Framework 3.5 exclusions if .NET Framework behavior is in question.

**Phase 6 — Reporting cross-check.** Use the Quality update status report as the authoritative per-device source of truth for Applied policy, Target/Installed release, and compliance date — reconcile any discrepancy against portal configuration rather than the reverse.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Design a quality update policy for a new environment (Microsoft's own recommended pattern)</summary>

1. **Monthly security updates:** Automatic approval, short deferral (0-5 days is Microsoft's implicit recommendation via "reduces administrative effort" framing) — critical fixes should not wait on manual action.
2. **Monthly non-security preview, OOB releases:** leave Manual (the default) for environments needing strict change management; only switch a category to Automatic if the environment specifically wants zero-touch handling for that category and accepts the reduced review window.
3. **Quick machine recovery:** decide Automatic vs. Manual based on the same risk-tolerance conversation as OS updates — Microsoft-provided WinRE fixes are lower-risk than general Windows updates but still worth an explicit decision, not a default left unexamined.
4. **Hotpatch:** if hotpatch is a goal for this ring, leave non-security updates on Manual (or don't approve them) to avoid inadvertently pulling devices off the hotpatch path.
5. Document the chosen approval method per category — remember it cannot be changed later without creating a new policy.

</details>

<details><summary>Playbook 2 — Respond to a bad release mid-rollout</summary>

1. Identify every policy the problematic release has been approved under (Manage updates → Release → Approved policies).
2. Pause the release for each affected policy — this is per-policy, not a single tenant-wide action.
3. Communicate to stakeholders: already-installed devices are unaffected by pause (no rollback capability exists here); only further rollout stops.
4. Allow up to 8 hours for the pause to reach all targeted devices before declaring rollout halted.
5. Investigate root cause; when resolved (or Microsoft ships a fix), re-approve (resume) the release — it's offered again as if newly approved.
6. If the issue is severe enough to require rolling back already-installed devices, that is out of scope for this policy mechanism entirely — pursue standard OS uninstall/rollback procedures on affected devices directly.

</details>

<details><summary>Playbook 3 — Migrate a device population from legacy Update rings to cloud-based quality update policies</summary>
1. Inventory current legacy Update ring deferral/deadline/active-hours settings per ring — these deadline/grace-period values remain relevant and continue to apply even after a cloud-based policy is layered on.
2. Create cloud-based quality update policies mirroring the intended approval behavior per category.
3. Assign the new policy alongside the existing ring policy (both can coexist) — confirm via the Quality update status report's Applied policy column that the cloud policy is now taking precedence for approval/deferral as expected.
4. Run a pilot group through at least one full monthly cycle before wider rollout, watching for hotpatch-interaction or .NET Framework-platform-exception surprises.
5. Once validated, decide whether to retain the legacy ring policy indefinitely (for its deadline/grace-period role) or migrate deadline/grace-period configuration into supported Update rings policy settings and simplify to a single-policy model.
</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects device-level Windows Autopatch quality update policy evidence via Microsoft
    Graph for escalation packages.
.DESCRIPTION
    The quality update policy object itself (approval method, deferral, pause state,
    release approval) is managed through the Intune admin center Manage updates workflow,
    which does not expose a documented, stable Graph API for policy/release read access
    as of this writing. This script collects what IS reliably Graph-reachable — device
    compliance/OS state and a prioritized portal checklist — rather than guessing at an
    unstable or unsupported Graph endpoint.
.NOTES
    Read-only. Requires Microsoft.Graph.DeviceManagement module and
    DeviceManagementManagedDevices.Read.All scope.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DeviceName,
    [string]$OutputPath = ".\QualityUpdatePolicyEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

Write-Status "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" -NoWelcome
Write-Status "Connected." "OK"

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

$filter = if ($DeviceName) { "deviceName eq '$DeviceName'" } else { $null }
Write-Status "Querying managed devices$(if ($DeviceName) { " matching '$DeviceName'" })..."

$devices = if ($filter) {
    Get-MgDeviceManagementManagedDevice -Filter $filter
} else {
    Get-MgDeviceManagementManagedDevice -Top 50
}

foreach ($d in $devices) {
    $insiderFlag = if ($d.OSVersion -match "(?i)insider|preview") { "POSSIBLE_INSIDER_BUILD" } else { "STANDARD" }
    $results.Add([PSCustomObject]@{
        DeviceName       = $d.DeviceName
        OSVersion        = $d.OSVersion
        ComplianceState  = $d.ComplianceState
        LastSyncDateTime = $d.LastSyncDateTime
        InsiderBuildFlag = $insiderFlag
        Note             = "Approval/deferral/pause state is portal-only — see checklist below"
    })
}

Write-Status "Collected $($results.Count) device record(s)." "OK"

Write-Status ""
Write-Status "=== PORTAL-ONLY EVIDENCE — collect manually before escalating ===" "WARN"
$checklist = @(
    "Intune admin center > Devices > Manage updates > Windows updates > Quality updates > Manage updates"
    "  -> per-Release: Approved policies count, Paused state"
    "Policy detail: per-category approval method (security/non-security/OOB security/OOB non-security) + deferral days"
    "Reports > Windows Autopatch > Windows quality updates > Reports tab > Quality update status"
    "  -> per device: Update status, Target compliance, Target release, Installed release, Applied policy, Hotpatch readiness"
    "Confirm whether device is ALSO targeted by a legacy Update ring policy (dual-policy precedence check)"
)
foreach ($item in $checklist) {
    Write-Host "  [ ] $item" -ForegroundColor Yellow
    $results.Add([PSCustomObject]@{ DeviceName = "N/A"; Note = "PORTAL_CHECK: $item" })
}

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported to $OutputPath." "OK"
```

**What it cannot do:** read cloud-based quality update policy definitions, per-category approval/deferral settings, release approval/pause state, or the Quality update status report's policy-derived columns (Target compliance, Applied policy) — none of these have a documented stable Graph endpoint as of this writing; all require the portal checklist above or the Quality update status report export (CSV, available directly from the report UI).

---

## Command Cheat Sheet

| Purpose | Command / Location |
|---------|---------------------|
| Connect to Graph for device state | `Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"` |
| Device compliance/OS snapshot | `Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<name>'"` |
| Create/edit quality update policy | Intune admin center → Devices → Manage updates → Windows updates → Quality updates → Create |
| Approve/pause a release | Manage updates → select Release → select policy → Approve / Pause |
| Per-device status report | Reports → Windows Autopatch → Windows quality updates → Reports tab → Quality update status |
| Export status report | Quality update status report → Export devices (CSV) |
| Legacy ring deferral/deadline (still relevant) | Devices → Manage updates → Windows updates → Update rings (CSP-based) |
| Hotpatch-specific troubleshooting | See `Hotpatch-A.md` / `Hotpatch-B.md` |
| Ring/orchestration troubleshooting | See `Autopatch-A.md` / `Autopatch-B.md` |

---

## 🎓 Learning Pointers

- **This feature adds a decision layer, not a replacement layer.** Everything in `Autopatch-A/B.md` about ring orchestration and Microsoft's own incident-triggered auto-pause remains true and active — the cloud-based quality update policy adds admin-driven approval/deferral/pause *on top*, with defined precedence rather than a takeover. Treat the two as complementary controls, not competing ones. MS Docs: [Windows quality updates and .NET Framework updates](https://learn.microsoft.com/en-us/windows/deployment/windows-autopatch/manage/windows-autopatch-windows-quality-update-overview)

- **The approval-method-is-immutable constraint has real operational consequences.** Because Automatic↔Manual cannot be toggled on an existing policy, environments should treat initial policy design (Playbook 1) as a decision worth getting right up front — "we'll just change it later" isn't an available option; it requires a new policy and a reassignment exercise instead.

- **Pause is a rollout brake, not a rollback lever — and this is Microsoft's explicit, stated design, not a limitation to work around.** No cloud-based mechanism exists here to un-install an already-applied release from devices; pause only protects devices that haven't yet received it. Set this expectation the moment a "pause this release" request comes in.

- **Precedence between cloud-based and legacy policies is additive, not exclusive.** The cloud-based policy owns approval/deferral; the legacy ring policy's deadline and grace-period settings continue operating in parallel. A device is very often governed by pieces of both simultaneously by design during a transition period — don't assume "the new policy took over everything."

- **.NET Framework and hotpatch each carve out genuine, documented exceptions worth memorizing.** Windows 10 ESU devices bypass this policy for .NET Framework specifically (OS updates still governed normally); .NET Framework 3.5 is out of scope entirely; and approving non-security updates on a hotpatch-enabled policy actively removes the device from its hotpatch cycle rather than layering harmlessly alongside it. Each is a common source of "this looks broken" tickets that are actually working exactly as documented. MS Docs: [Quality update status report](https://learn.microsoft.com/en-us/windows/deployment/windows-autopatch/monitor/windows-autopatch-windows-quality-update-status-report)
