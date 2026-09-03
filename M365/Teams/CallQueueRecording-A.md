# Teams Call Queue Automatic Recording & Transcription — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Automatic Recording for Call Queue** (GA-track August 13, 2026) and its sibling **Compliance Recording for Call Queue** (Teams admin center UI added August 17, 2026), both part of the broader Auto Attendant / Call Queue voice-applications platform. It assumes:

- The reader manages Teams Phone (Calling Plan, Operator Connect, or Direct Routing) for one or more call queues and needs to add recording/transcription to inbound queue calls.
- Teams PowerShell module **7.8.0 or later** is installed — the `*-CsAutoRecordingTemplate` cmdlet family does not exist in earlier versions.
- The queue already exists and is functional for basic call routing (`M365/Teams/Calling-A.md` covers queue creation and voice routing fundamentals — this runbook picks up from a working queue).

Out of scope: general Teams meeting cloud recording (`Meeting-Policies-A/B.md`), third-party compliance recording platform integration mechanics beyond the application-instance prerequisite, and Teams Phone Agent recording (a separate, Frontier-program-gated feature referenced only for architectural contrast below).

> **Source-confidence note:** both features are new (August 2026) and evolving quickly. Microsoft's own release notes describe admin-center configuration for Automatic Recording as "coming soon" — treat any admin-center screenshots or walkthroughs older than a few weeks with suspicion, and re-verify current portal behavior before a client engagement. Automatic Recording for Teams Phone Agent (the sibling capability, out of scope here) is currently gated to the Frontier Public Preview program and the Voice Applications trial — do not assume Call Queue recording carries the same gating; it does not, per Microsoft's own documentation distinction.

---

## How It Works

<details><summary>Full architecture</summary>

There are now **three separate, non-overlapping recording mechanisms** that can apply to a Teams Phone agent's calls, and confusing them is the single biggest source of "why isn't this being recorded" tickets:

1. **Automatic Recording for Call Queue** — a first-party Teams feature. When enabled on a queue via an assigned template, every **inbound** call answered by a representative is recorded and (optionally) transcribed automatically, with zero per-agent policy assignment required. Storage is SharePoint, access is via SharePoint directly or through the Queues App's Shared Call History.

2. **Compliance Recording for Call Queue** — also first-party, added a few days after Automatic Recording. It records all agent-answered **inbound** queue calls unconditionally, **ignoring any compliance recording policy assigned to the individual agent** for those specific inbound-queue-call instances. It requires a compliance recording **application instance** (the mechanism used for third-party compliance recording platforms) even though no third-party platform integration is actually required for the call-queue-scoped version — this application-instance requirement is a structural leftover from the underlying compliance recording plumbing, not evidence that a third-party recorder is in play.

3. **Per-user Compliance Recording Policy** (`Grant-CsTeamsComplianceRecordingPolicy`) — the original, general-purpose mechanism. It governs everything **not** covered by #1 or #2: outbound calls placed by an agent (even from within a call-queue context, these are treated as ordinary outbound user calls, unassociated with the queue), and any of that user's calls outside the queue entirely.

The architectural point worth internalizing: **queue-level recording and user-level recording are separate control planes that happen to both be called "recording."** A call queue can have Automatic Recording fully configured and working, and an agent working that queue can still have zero recording coverage on the outbound calls they make from the same desk five minutes later. Microsoft's own documentation flags this explicitly and states the outbound-call gap "will be addressed in a future release" — as of this writing, it has not been.

**Recording template lifecycle.** An `Automatic Recording for Call Queue` template (`New-CsAutoRecordingTemplate`) is a reusable object, not a per-queue setting — multiple call queues can point at the same template, and the SharePoint site a template provisions can be reused across multiple templates deliberately (Microsoft explicitly recommends this to avoid site sprawl). The queue itself only stores a template *reference* (`AutoRecordingTemplateId` on `Set-CsCallQueue`), not a copy of the template's settings — so editing template behavior (where possible) propagates to every queue referencing it, while the two fields that **cannot** be edited post-creation (`SharePointHostName`/`SharePointSiteName`, and `AgentViewPermission`) force a new template object and a queue reassignment if they need to change.

**SharePoint provisioning coupling.** The SharePoint site isn't an arbitrary existing site you point the template at — Microsoft requires it be provisioned *through* the template-creation flow itself, and a manually created site is explicitly documented as unsupported (causing access/permission errors). The admin account that runs `New-CsAutoRecordingTemplate` becomes the SharePoint site admin of the resulting site as a side effect of that provisioning step. This is a common trap during offboarding: if that admin's account is disabled or loses SharePoint admin rights, the recording pipeline's upload step starts failing while the call-queue-side experience (the call itself, answering, disconnecting) looks completely normal — because call handling and the asynchronous recording upload are decoupled. Microsoft's stated mitigation is to proactively add every Teams administrator who might need to manage the template as a SharePoint site admin on that site, rather than relying on a single admin's continued access.

**The consent gate.** Explicit recording consent (the "this call may be recorded" participant-agreement setting) is a tenant/policy-level control that sits **above** all three recording mechanisms. If explicit consent is turned on, Automatic Recording for Call Queue's documented behavior assumes consent is **off** — the two aren't designed to run together, and Microsoft's setup documentation lists the consent-off requirement as a known issue/prerequisite rather than an optional compatibility mode.

</details>

---

## Dependency Stack

```
Layer 5: Access & Visibility
  └─ Queues App (licensed) + Shared Call History (queue setting) → agent/authorized-user
     recording visibility in-app; direct SharePoint access is the fallback path regardless

Layer 4: Recording Behavior
  └─ Automatic Recording template: RecordingEnabled, TranscriptionEnabled,
     AgentViewPermission (immutable post-creation), Recording Document Owner (upload-failure fallback)
     — OR — Compliance Recording for Call Queue (application-instance-backed, ignores
     per-agent compliance recording policy for inbound queue calls)

Layer 3: Storage Binding
  └─ SharePoint host + site (immutable post-creation, MUST be template-provisioned,
     NOT a manually created site) + template-creator's SharePoint site-admin rights

Layer 2: Queue Prerequisites
  └─ Conference mode ENABLED + Call answering via GROUP or CHANNEL (not Users/Shifts)
     + Shared Call History ENABLED

Layer 1: Platform Prerequisites
  └─ Teams PowerShell module 7.8.0+ + Auto Attendant/Call Queue base licensing
     + Queues App licensing + explicit recording consent = OFF
```

A failure at any layer presents identically to the agent/caller: "the call happened normally, but there's no recording." Diagnosis always works top-down through this stack from Layer 5, since the symptom gives no signal about which layer failed.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| No recording exists for any call in the queue | Template never assigned, or Conference mode disabled | `Get-CsCallQueue` → `AutoRecordingTemplateId`, `ConferenceMode` |
| `Get-CsAutoRecordingTemplate` cmdlet not recognized | Teams PowerShell module below 7.8.0 | `Get-Module MicrosoftTeams -ListAvailable` |
| Recording exists in SharePoint but agents see nothing in Queues App | `AgentViewPermission` disabled at template creation, or Queues App unlicensed, or Shared Call History disabled | Template properties + license assignment + `SharedCallHistory` queue setting |
| Recordings stopped appearing after weeks of working | SharePoint site structure/permissions changed, or template creator lost site-admin access | `Get-SPOSite` site admins, manually browse the site |
| Transcript exists but is in the wrong language | Known Microsoft limitation — transcription defaults to English (US) regardless of queue language | No fix; document as expected behavior |
| Recording configured but nothing happens at all | Explicit recording consent policy is ON, blocking automatic behavior | `Get-CsTeamsMeetingPolicy` consent settings |
| Inbound queue calls recorded, outbound agent calls are not | Expected architecture — outbound calls are user-scoped, need a separate compliance recording policy | `Get-CsTeamsComplianceRecordingPolicy` assignment for the agent |
| Compliance Recording for Call Queue enabled but agent's individually assigned compliance policy seems ignored for inbound calls | Expected — Compliance Recording for Call Queue explicitly overrides/ignores per-agent policy for inbound queue calls only | Confirm this is inbound-only; check outbound separately |
| Template creation fails citing site/host errors | SharePoint host never visited before template creation, or site creation disabled tenant-wide | `Get-SPOTenant`, manually visit the target host once first |

---

## Validation Steps

1. **Module and cmdlet availability**
   ```powershell
   (Get-Module MicrosoftTeams -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version
   ```
   Good: ≥ `7.8.0`. Bad: cmdlet errors as unrecognized on any `*-CsAutoRecordingTemplate` call — update the module first.

2. **Template inventory and settings**
   ```powershell
   Get-CsAutoRecordingTemplate | Format-List Identity, Name, RecordingEnabled, TranscriptionEnabled, AgentViewPermission, SharePointHostName, SharePointSiteName, RecordingDocumentOwner
   ```
   Good: at least one template with `RecordingEnabled = $true` and a resolvable SharePoint host/site. Bad: no templates, or settings that don't match what the client believes is configured.

3. **Queue-level assignment and prerequisites**
   ```powershell
   Get-CsCallQueue -Identity "<GUID>" | Select-Object Name, AutoRecordingTemplateId, ConferenceMode, SharedCallHistory, RoutingMethod
   ```
   Good: `AutoRecordingTemplateId` populated and matching a real template; `ConferenceMode`/`SharedCallHistory` both `$true`.

4. **SharePoint site reachability and admin coverage**
   ```powershell
   Get-SPOSite -Identity "https://<host>/sites/<site>" | Select-Object Owner, SiteAdmins, Status
   ```
   Good: `Status = Active`, multiple Teams admins listed as site admins (not just the original creator).

5. **Consent policy state**
   ```powershell
   Get-CsTeamsMeetingPolicy -Identity Global | Select-Object *Consent*
   ```
   Good: explicit recording consent is off for the relevant policy scope.

6. **License coverage for viewers**
   ```powershell
   Get-MgUserLicenseDetail -UserId "<AgentUPN>" | Select-Object -ExpandProperty ServicePlans | Where-Object { $_.ServicePlanName -match "TEAMS_QUEUES|QUEUES_APP" }
   ```
   Good: Queues App service plan present and enabled for any agent/authorized user expected to view recordings in-app.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the mechanism in question.** Before touching any configuration, establish with the client which of the three recording mechanisms they mean (Automatic Recording for Call Queue, Compliance Recording for Call Queue, or per-user Compliance Recording Policy). Ask specifically whether the concern is inbound queue calls, outbound agent calls, or general meeting recording — this single question resolves a large share of "recording isn't working" tickets without touching PowerShell.

**Phase 2 — Platform and template layer.** Validate module version, template existence, and template settings (Validation Steps 1–2). A missing or misconfigured template is the most common root cause for "nothing is being recorded at all."

**Phase 3 — Queue binding and prerequisites.** Confirm the queue is actually pointed at the template and that Conference mode / Shared Call History / call-answering type are all correctly set (Validation Steps 3). Architecture mismatches here (Users/Shifts-based call answering) require a call-flow redesign, not a config fix — flag this to the client as a change request rather than attempting a quick patch.

**Phase 4 — Storage and access layer.** If recording is confirmed happening (files exist in SharePoint) but visibility is the complaint, work Validation Steps 4 and 6 — this is almost always a `AgentViewPermission` (immutable, requires new template) or licensing gap, not a storage failure.

**Phase 5 — Policy interaction.** If recording appears to not be firing at all despite a correctly configured template and queue, check the consent gate (Validation Step 5) before assuming a platform bug — Microsoft explicitly documents consent-on as incompatible with the current Automatic Recording implementation.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Stand up recording for a queue from scratch</summary>

```powershell
Connect-MicrosoftTeams

# 1. Confirm module version
(Get-Module MicrosoftTeams -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version

# 2. Confirm queue prerequisites, fix in admin center if needed (Conference mode, call answering type, Shared Call History)
Get-CsCallQueue -Identity "<GUID>" | Select-Object ConferenceMode, RoutingMethod, SharedCallHistory

# 3. Create the template (SharePoint host/site and AgentViewPermission are permanent — confirm with client first)
New-CsAutoRecordingTemplate -Name "<Name>" -Description "<Description>" `
    -RecordingEnabled $true -TranscriptionEnabled $true -AgentViewPermission All `
    -SharePointHostName "<tenant>.sharepoint.com" -SharePointSiteName "<SiteName>" `
    -RecordingDocumentOwner "<AdminObjectId>"

# 4. Assign to the queue
$tplId = (Get-CsAutoRecordingTemplate -Name "<Name>").Identity
Set-CsCallQueue -Identity "<GUID>" -AutoRecordingTemplateId $tplId

# 5. Confirm consent is off
Get-CsTeamsMeetingPolicy -Identity Global | Select-Object *Consent*

# 6. Assign Queues App license to agents/authorized users expected to view recordings
```

**Rollback:** unassign the template from the queue (`Set-CsCallQueue -Identity "<GUID>" -AutoRecordingTemplateId $null`) to stop new recordings immediately; this does not delete the SharePoint site or historical recordings.

</details>

<details><summary>Playbook 2 — Migrate a queue to a corrected template (AgentViewPermission or SharePoint location change)</summary>

Because both fields are immutable post-creation, this is always a create-new-and-reassign operation, never an in-place edit:

```powershell
# 1. Create the corrected template — reuse the EXISTING SharePoint site to avoid fragmenting history
New-CsAutoRecordingTemplate -Name "<NewName>" -Description "<Description>" `
    -RecordingEnabled $true -TranscriptionEnabled $true -AgentViewPermission All `
    -SharePointHostName "<tenant>.sharepoint.com" -SharePointSiteName "<ExistingSiteName>" `
    -RecordingDocumentOwner "<AdminObjectId>"

# 2. Reassign every queue currently on the old template
$oldTplId = (Get-CsAutoRecordingTemplate -Name "<OldName>").Identity
$newTplId = (Get-CsAutoRecordingTemplate -Name "<NewName>").Identity
Get-CsCallQueue | Where-Object { $_.AutoRecordingTemplateId -eq $oldTplId } | ForEach-Object {
    Set-CsCallQueue -Identity $_.Identity -AutoRecordingTemplateId $newTplId
}
```

**Rollback:** reassign affected queues back to the old template's `Identity` — no data is lost since both templates can point at the same SharePoint site.

</details>

<details><summary>Playbook 3 — Onboard a backup SharePoint site admin (offboarding resilience)</summary>

```powershell
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<SiteName>" | Select-Object SiteAdmins
Set-SPOUser -Site "https://<tenant>.sharepoint.com/sites/<SiteName>" -LoginName "<BackupAdminUPN>" -IsSiteCollectionAdmin $true
```
Do this proactively for every Automatic Recording for Call Queue site in the tenant — Microsoft's own guidance recommends all Teams administrators be configured as site admins on these sites specifically to prevent the offboarding failure mode described in How It Works.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS Collects Automatic Recording for Call Queue state for escalation.
#>
Connect-MicrosoftTeams
$out = [ordered]@{}
$out.ModuleVersion = (Get-Module MicrosoftTeams -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()
$out.Templates = Get-CsAutoRecordingTemplate | Select-Object Identity, Name, RecordingEnabled, TranscriptionEnabled, AgentViewPermission, SharePointHostName, SharePointSiteName
$out.Queue = Get-CsCallQueue -Identity "<CallQueueGUID>" | Select-Object Name, AutoRecordingTemplateId, ConferenceMode, SharedCallHistory, RoutingMethod
$out.ConsentPolicy = Get-CsTeamsMeetingPolicy -Identity Global | Select-Object *Consent*
$out | ConvertTo-Json -Depth 4 | Out-File ".\CallQueueRecording-Evidence-$(Get-Date -Format yyyyMMdd-HHmm).json"
Write-Host "Evidence pack written." -ForegroundColor Green
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-CsAutoRecordingTemplate` | List all Automatic Recording templates and their settings |
| `New-CsAutoRecordingTemplate` | Create a new template (SharePoint location + AgentViewPermission are permanent) |
| `Set-CsCallQueue -AutoRecordingTemplateId` | Assign/unassign a template to a queue |
| `Get-CsCallQueue` | Inspect queue prerequisites: ConferenceMode, SharedCallHistory, RoutingMethod |
| `Get-CsTeamsComplianceRecordingPolicy` / `Grant-CsTeamsComplianceRecordingPolicy` | Manage per-user compliance recording for outbound/non-queue calls |
| `Get-CsTeamsMeetingPolicy -Identity Global` | Check explicit recording consent gate |
| `Get-SPOSite` | Inspect the SharePoint site backing a recording template |
| `Set-SPOUser -IsSiteCollectionAdmin` | Add a backup SharePoint site admin for template resilience |
| `Get-Module MicrosoftTeams -ListAvailable` | Confirm 7.8.0+ module version is installed |

---

## 🎓 Learning Pointers

- Internalize the three-mechanism model (Automatic Recording, Compliance Recording for Call Queue, per-user Compliance Recording Policy) before troubleshooting — most confusion in this space comes from treating "recording" as one feature when it's architecturally three. See [Plan - Recording for Teams Phone Agent, Auto Attendant, and Call Queue calls](https://learn.microsoft.com/en-us/microsoftteams/aa-cq-plan-recording).
- The outbound-call gap (queue recording doesn't cover an agent's outbound calls) is Microsoft's own documented limitation, explicitly slated for a future fix — set client expectations accordingly rather than troubleshooting it as a defect.
- Two template fields are permanent on creation (`SharePointHostName`/`SharePointSiteName` and `AgentViewPermission`) — always confirm these with the client before running `New-CsAutoRecordingTemplate`, since the only remediation path is a new template plus a queue reassignment.
- The template-creator-becomes-site-admin side effect is an offboarding trap worth flagging proactively to every MSP client running this feature — see [Setup - Automatic Recording template for Call Queue](https://learn.microsoft.com/en-us/microsoftteams/aa-cq-setup-call-queue-template-recording-automatic).
- Configuration is PowerShell-only today; Microsoft's release notes describe admin-center UI as "coming soon" for Automatic Recording (Compliance Recording for Call Queue already has admin-center UI as of August 17, 2026) — re-check current portal state before assuming either is UI-driven.
