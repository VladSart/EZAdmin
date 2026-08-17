# Automated Investigation & Response (AIR) — Reference Runbook (Mode A: Deep Dive)
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

Automated Investigation and Response (AIR) is Microsoft Defender for Endpoint's automated alert-triage engine: when an eligible alert fires, AIR launches an automated investigation that examines related entities (files, processes, registry keys, scheduled tasks, services, drivers), reaches a verdict per artifact (**Malicious**, **Suspicious**, or **No threats found**), and either takes remediation action automatically or queues it for human approval — depending on the **automation level** configured on the device's **device group**.

This is **not** the same thing as:
- **Manual response actions** (Isolate device, Run antivirus scan, Stop and quarantine a file, etc.) — analyst-triggered actions available regardless of AIR/automation level, including in Defender for Endpoint Plan 1.
- **Live Response** — an interactive remote shell/scripting session onto a device, entirely separate from AIR's automated workflow.
- **Automatic attack disruption** — a distinct, incident-level containment capability (e.g., auto-isolating a device or disabling a compromised account mid-attack) that operates on different triggers than per-alert AIR investigations.
- **Real-time protection / cloud-delivered protection** — the underlying antivirus engine that blocks/quarantines in real time regardless of AIR's automation level setting; AIR governs the *investigation and remediation of what already happened*, not real-time blocking.

AIR is available in **Microsoft Defender for Endpoint Plan 2** and **Microsoft Defender for Business**. It does **not** exist in Plan 1 — device groups can still be created in Plan 1 (device group creation itself is supported in both Plan 1 and Plan 2), but there is no automated investigation capability to configure an automation level for. In Defender for Business, automation is preconfigured to Full and is not tenant-configurable the way it is in Defender for Endpoint Plan 2.

---
## How It Works

<details><summary>Full architecture</summary>

**Trigger and scope.** An eligible alert on an onboarded, Plan-2-or-Business-licensed device triggers an automated investigation. The investigation examines the alert's related entities and expands outward through their relationships (a suspicious process's parent/child processes, files it touched, registry keys it wrote, etc.), reaching an independent verdict per piece of evidence.

**Automation level — a per-device-group setting.** Automation level is not a tenant-wide toggle. It is configured on each **device group**, and device groups are matched against a device using a **ranked, top-down** rule set — the first (highest-ranked) group whose membership criteria the device satisfies wins; a device that matches no custom group falls into the built-in "Ungrouped devices" group, which has its own default automation level. This is the single most common source of "why did device A get auto-remediated but device B in the same OU didn't" — they matched different groups, or one fell through to Ungrouped with a different default.

**The five automation levels:**

| Level | Behavior |
|---|---|
| **Full — remediate threats automatically** (recommended) | Remediation actions taken automatically on artifacts verdicted Malicious. All actions logged and undoable in Action Center → History. Default for tenants created on/after **August 16, 2020** with no device groups yet defined. |
| **Semi — require approval for any remediation** | Every remediation action, regardless of file location, queues in Action Center → Pending for human approval. Default for tenants created **before** August 16, 2020 (with no device groups defined). |
| **Semi — require approval for core folders remediation** | Malicious verdicts on files/executables in OS directories (e.g., `\windows\*`, Program Files) require approval; malicious verdicts elsewhere remediate automatically. Suspicious verdicts always require approval under this level. |
| **Semi — require approval for non-temp folders remediation** | Malicious verdicts on files outside temp-style locations (`\users\*\downloads\*`, `\program files\*`, etc.) require approval; malicious verdicts inside temp-style locations remediate automatically. Suspicious verdicts always require approval. |
| **No automated response** (not recommended) | Automated investigation never runs for devices in this group. No verdicts, no actions, nothing logged to Action Center from AIR. Real-time AV/EDR blocking is **unaffected** — this setting only disables the post-alert investigation/remediation workflow. |

**Verdict-to-action table (Full and Semi levels):**

| Automation level | Verdict | Result |
|---|---|---|
| Full | Malicious | Automatic remediation |
| Any Semi variant | Malicious or Suspicious (per the variant's folder-scope rule) | Pending approval, or automatic if inside the variant's "safe to automate" folder scope |
| Any Full/Semi level | No threats found | No action, nothing pending |
| No automated response | (n/a — no investigation runs) | Nothing happens |

**Remediation actions AIR can take:** quarantine a file, remove a registry key, kill a process, stop a service, disable a driver, remove a scheduled task. A subset of these — plus a few manual-response-only actions like Isolate device and Restrict code execution — can be **undone** later from Action Center → History, whether they were taken automatically or manually.

**Pending action expiry.** Actions awaiting approval in Semi-automation mode time out after **7 days**. A timed-out action is treated identically to a rejected one — the artifact remains un-remediated, silently, unless someone notices and re-triages manually. This is a common source of "the malware is still there weeks later" tickets in environments running Semi-automation without a disciplined approval SLA.

**Why Full is the recommended default.** Microsoft's own telemetry (cited in the automation-levels documentation) shows tenants on full automation had 40% more high-confidence malware samples removed than those on lower automation levels — the practical failure mode of Semi-automation in the field is an unattended or under-resourced approval queue, not a technically inferior detection engine.

</details>

---
## Dependency Stack

```
Device onboarded to Defender for Endpoint, licensed Plan 2 or Defender for Business
  └── (Plan 1: device groups exist but AIR itself is unavailable — hard licensing gate)
  └── Real-time protection active, sensor healthy and reporting
        └── Alert generated, of a type eligible to trigger automated investigation
              └── Device group membership resolved (ranked, top-down, first match wins;
                  no match → falls to "Ungrouped devices" default group)
                    └── That group's Automation Level applies:
                          Full / Semi (3 variants) / No automated response
                            └── Per-artifact verdict reached: Malicious / Suspicious / No threats found
                                  └── Action taken automatically, OR queued Pending (7-day expiry
                                      → auto-rejected if untouched), per the level+verdict+folder-
                                      scope combination in the table above
                                        └── All outcomes (automatic or approved) logged to
                                            Action Center → History, undoable there
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Legitimate file/app quarantined | Correct verdict logic (Malicious/Suspicious) but a false positive on this specific artifact | Undo in Action Center History + add an allow indicator |
| Two similar devices behave differently under the same alert type | Different device group membership (rank-order match), or one fell through to Ungrouped | Check each device's resolved group under Assets → Devices |
| "Nothing happened" after an alert | Device group set to "No automated response," or the alert type isn't AIR-eligible | Check the group's automation level first |
| Old, seemingly-resolved threat artifact still present | A Semi-automation pending action expired (7-day timeout = auto-reject) with nobody noticing | Search Action Center History for a rejected/expired entry around the alert date |
| "AIR isn't doing anything, ever, tenant-wide" | Tenant/device is licensed Defender for Endpoint Plan 1 | Confirm licensing — Plan 1 has no AIR |
| Approval queue growing unmanaged | Semi-automation chosen without a staffing/SLA plan for approvals | Reconsider automation level per Remediation Playbook 2 |
| Undo doesn't seem available for an action | Action type isn't in the undo-supported list (see manual-response-only exceptions for Plan 1/Business), or it's older than the visible History retention | Confirm action type against the supported-undo table in Microsoft Learn |

---
## Validation Steps

1. **Confirm licensing tier.** Settings → Endpoints → Licenses, or the device's own overview page. Good: Plan 2 or Defender for Business confirmed. Bad: Plan 1 — stop troubleshooting AIR behavior, it structurally doesn't exist here.

2. **Resolve the device's actual device group.** Assets → Devices → \<device\>, cross-reference against Settings → Endpoints → Device groups rank order. Good: device matches the expected group. Bad: device fell to Ungrouped, or matched an unexpected higher-ranked group — revisit group criteria/ranking.

3. **Confirm the group's automation level matches organizational intent.** Good: Full (or a deliberately-chosen Semi variant with an approval process behind it). Bad: "No automated response" left as a stale default, or Semi-automation with an empty/neglected Pending queue.

4. **Trace a specific investigation end to end** via Action Center, filtering by device or incident ID, checking both Pending and History tabs, and the incident's own Evidence and Response tab for the same underlying data.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Licensing and device-group resolution.** Validation Steps 1–2. This alone resolves the large majority of "AIR isn't behaving as expected" tickets.

**Phase 2 — Automation-level-vs-verdict tracing.** Use the verdict-to-action table under How It Works to predict expected behavior for the specific automation level and folder location involved, then compare against what Action Center actually shows.

**Phase 3 — Approval-queue health (Semi-automation environments only).** Audit Action Center Pending tab for age; anything approaching 7 days needs immediate attention before it silently expires.

**Phase 4 — Undo and re-scope, if a false positive.** Remediation Playbook 1.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Undo a false-positive remediation at scale</summary>

1. Locate the original action in Action Center → History.
2. If the same file hash affected multiple devices, use **Apply to X more instances of this file** to batch-undo rather than repeating per-device.
3. Add an allow indicator for the file hash (Settings → Endpoints → Indicators) to prevent recurrence — Undo alone does not suppress future detections of the same artifact.
4. If the false positive stemmed from an ASR rule or a specific detection signature rather than a generic AV verdict, cross-reference `ASR-Rules-A.md` for rule-specific exclusion guidance — AIR remediates what upstream detection flags; a chronically noisy detection source needs its own tuning, not just repeated Undo cycles.

</details>

<details><summary>Playbook 2 — Right-size automation level across device groups</summary>

1. Inventory current device groups and their automation levels (Settings → Endpoints → Device groups).
2. For groups on Semi-automation, confirm there is an actual staffed process reviewing the Pending queue within the 7-day window — if not, either commit to that staffing or move the group to Full (Microsoft's recommended default, with full undo capability preserved as the safety net).
3. Reserve Semi-automation for groups with a genuine regulatory/change-control requirement for human sign-off on remediation — document why, since it's the exception, not the default, going forward.
4. Re-verify the Ungrouped devices default — this is the fallback for anything that doesn't match a custom group's criteria, and is easy to overlook when reviewing "our" configured groups.

</details>

<details><summary>Playbook 3 — Migrate a Plan 1 tenant considering AIR</summary>

1. Confirm the actual business driver — most Plan 1 "AIR" requests are really about wanting automated remediation, not just alerting.
2. Plan 1 has manual response actions (Isolate device, Run AV scan, Stop and quarantine file, Add indicator) but no automated investigation engine — a Plan 2 or Defender for Business upgrade is required to get AIR itself, not a configuration change.
3. Before upgrading, review device group design (this can be done at Plan 1 already, since device group creation is supported on both plans) so automation levels can be set correctly on day one of Plan 2 licensing rather than defaulting tenant-wide to Full for every group without a design pass.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS Pulls AIR-relevant device group and Action Center context via Microsoft Graph
          Security API for escalation packaging. Requires an app registration or
          delegated session with SecurityActions/SecurityEvents.Read permissions.
#>
Connect-MgGraph -Scopes "SecurityActions.Read.All","SecurityEvents.Read.All"

# Device groups and their automation levels are portal/Graph-API-managed, not exposed via
# a dedicated cmdlet as of this writing — pull via the underlying REST endpoint:
$deviceGroups = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/detectedApps" -ErrorAction SilentlyContinue
# (Placeholder — device group automation-level read is portal-only today; capture a
# Settings > Endpoints > Device groups screenshot/export as part of the evidence pack
# until a stable Graph endpoint is documented for this specific setting.)

# Recent remediation actions (Action Center) — via the security alerts/actions surface
$actions = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/alerts_v2?`$top=50" |
    Select-Object -ExpandProperty value

$actions | Select-Object id, title, severity, status, determination, createdDateTime |
    Export-Csv -Path ".\AIR-Evidence-Alerts.csv" -NoTypeInformation
```
Note: as of this writing, per-device-group automation-level configuration is portal-managed with no stable, documented Graph API surface for programmatic read — include a portal export/screenshot of **Settings → Endpoints → Device groups** alongside any scripted evidence pull.

---
## Command Cheat Sheet

```
Portal locations (AIR has no PowerShell cmdlet surface of its own):
  Action Center (Pending/History):     security.microsoft.com/action-center
  Device groups + automation level:    security.microsoft.com → Settings → Endpoints → Device groups
  Incident-context approve/reject:     Incidents & alerts → Incidents → <incident> → Evidence and Response
  Device plan/licensing:               Settings → Endpoints → Licenses
```

```powershell
# Graph-based alert/action pull (see Evidence Pack)
Connect-MgGraph -Scopes "SecurityActions.Read.All","SecurityEvents.Read.All"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/alerts_v2?`$top=50"
```

---
## 🎓 Learning Pointers

- [Automation levels in automated investigation and remediation — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/automation-levels) (updated 2026-01-15) — the authoritative level definitions and default-by-tenant-age rules.
- [Review remediation actions following automated investigations — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/manage-auto-investigation) (updated 2026-07-15) — the verdict-to-action table, undo mechanics, and the 7-day pending-action expiry.
- [Use automated investigations to investigate and remediate threats — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/automated-investigations) — the overall AIR architecture and Plan 2/Business licensing scope.
- Automation level is scoped to the **device group**, never the tenant as a whole — always resolve which group a device actually matched (rank order matters) before diagnosing "inconsistent" AIR behavior.
- Distinguish AIR from Live Response, manual response actions, and Automatic attack disruption — these are four separate Defender for Endpoint capabilities that get conflated in casual conversation but have different triggers, scopes, and licensing.
- A neglected Semi-automation approval queue is a bigger real-world risk than most orgs assume — Microsoft's own recommendation (and 40%-more-remediated telemetry) favors Full automation for this exact reason. Treat Semi-automation as a deliberate, staffed choice, not a "safer" default.
