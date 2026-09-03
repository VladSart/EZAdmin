# Teams Call Queue Automatic Recording & Transcription — Hotfix Runbook (Mode B: Ops)
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

> **Source-confidence note:** Automatic Recording for Call Queue went GA-track August 13, 2026 (Compliance Recording for Call Queue followed August 17, 2026 with Teams admin center UI). As of this writing, configuration is **PowerShell-only** — Teams admin center UI is "coming soon" per Microsoft's own release notes. Do not tell a client to look for this in the portal yet; verify against the live admin center before revising this note. This is a distinct feature from the general Teams meeting cloud recording capability already covered in `Meeting-Policies-A/B.md` — do not conflate the two when triaging.

---

## Triage

Run these within the first 60 seconds to classify the problem. Requires Teams PowerShell module **7.8.0 or later**.

```powershell
Connect-MicrosoftTeams

# 1. Confirm module version supports Automatic Recording cmdlets
(Get-Module MicrosoftTeams -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version

# 2. Does an automatic recording template exist, and what does it say?
Get-CsAutoRecordingTemplate | Select-Object Identity, Name, RecordingEnabled, TranscriptionEnabled, AgentViewPermission, SharePointHostName, SharePointSiteName

# 3. Is the call queue actually assigned a template?
Get-CsCallQueue -Identity "<CallQueueGUID>" | Select-Object Identity, Name, AutoRecordingTemplateId, ConferenceMode, SharedCallHistory

# 4. Prerequisite gates: conference mode + call-answering routing type
Get-CsCallQueue -Identity "<CallQueueGUID>" | Select-Object ConferenceMode, RoutingMethod, DistributionLists, Users
```

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| `Get-CsAutoRecordingTemplate` returns nothing at all | No template has ever been created for this tenant, or module is too old to see it | Go to Fix 1 |
| Template exists but `AutoRecordingTemplateId` on the queue is `$null`/blank | Template was created but never assigned to this specific queue | Go to Fix 2 |
| `ConferenceMode` is `$false`/disabled | Recording prerequisite not met — Automatic Recording for Call Queue requires Conference mode | Go to Fix 3 |
| Call answering uses `Users`/Shifts instead of a group or channel | Unsupported configuration — Automatic Recording only works when call answering routes through a group or channel | Go to Fix 4 |
| Recording works but agents can't see it in Queues App | `AgentViewPermission` was left disabled at template creation — **cannot be changed on an existing template** | Go to Fix 5 |
| Recordings/transcripts silently stop appearing after working fine for weeks | SharePoint site structure, file names, or permissions changed underneath the template | Go to Fix 6 |
| Transcript language is wrong (not matching the queue's configured language) | Known Microsoft issue — transcription defaults to English (US) regardless of queue language; fix is in development, no workaround yet | Note as known limitation, no fix available |
| Outbound calls made by agents from a recorded queue aren't recorded | Expected — Automatic/Compliance Recording for Call Queue covers **inbound** queue calls only | Go to Fix 7 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Automatic Recording for Call Queue actually recording + visible in Queues App
│
├── Teams PowerShell module 7.8.0+ (cmdlets don't exist below this version)
│
├── Auto Attendant / Call Queue base licensing in place
│
├── Call Queue prerequisites
│   ├── Conference mode ENABLED on the queue
│   ├── Call answering uses a GROUP or CHANNEL (Users/Shifts unsupported)
│   └── Shared Call History ENABLED on the queue
│       └── required for agents/authorized users to see recordings via Queues App
│
├── Automatic Recording template (New-CsAutoRecordingTemplate)
│   ├── SharePoint host + site name (immutable once template is created)
│   │   └── SharePoint site MUST be provisioned through the template flow
│   │       (manually created sites → access/permission errors)
│   │   └── SharePoint host must have been visited at least once before template creation
│   │   └── site creation must be enabled tenant-wide
│   ├── Recording Enabled = true (default: OFF)
│   ├── Transcription Enabled = true (default: OFF)
│   ├── Agent View Permission (default: OFF, IMMUTABLE after creation)
│   └── Recording Document Owner (fallback identity for upload failures)
│
├── Template assigned to the queue: Set-CsCallQueue -AutoRecordingTemplateId <ID>
│
├── Explicit recording consent (participant agreement) = OFF
│   └── if ON, automatic recording for the queue will not proceed as configured
│
├── Queues App licensed for agents/authorized users who need to view recordings
│
└── Template creator (or another designated admin) is also a SharePoint site admin
    for the associated site — required to manage authorized users or reuse the site
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the module and the template exist**
```powershell
(Get-Module MicrosoftTeams -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version
Get-CsAutoRecordingTemplate
```
Expect: version ≥ 7.8.0, and at least one template object returned with a populated `Identity`. If the module is older, `Get-CsAutoRecordingTemplate` will error as an unrecognized cmdlet — update the module first (`Update-Module MicrosoftTeams`) before proceeding with any other step.

**Step 2 — Confirm the specific queue is assigned the template**
```powershell
$cq = Get-CsCallQueue -Identity "<CallQueueGUID>"
$cq | Select-Object Name, AutoRecordingTemplateId, ConferenceMode, SharedCallHistory, RoutingMethod
```
Expect: `AutoRecordingTemplateId` matches a real template `Identity` from Step 1. Blank/`$null` means the queue was never assigned a template — this is the single most common root cause reported as "recording isn't happening at all."

**Step 3 — Confirm queue-level prerequisites**
```powershell
$cq.ConferenceMode      # must be $true
$cq.SharedCallHistory    # must be $true for agent/authorized-user visibility
```
`ConferenceMode = $false` blocks Automatic Recording entirely — it is a hard prerequisite, not a preference.

**Step 4 — Confirm SharePoint site health**
```powershell
$tpl = Get-CsAutoRecordingTemplate -Identity $cq.AutoRecordingTemplateId
$tpl | Select-Object SharePointHostName, SharePointSiteName, RecordingDocumentOwner
# Manually browse to https://<SharePointHostName>/sites/<SharePointSiteName> and confirm
# the requesting admin account still has site-admin access and the folder structure is intact
```
If the admin who created the template has left, been offboarded, or lost SharePoint site-admin rights, uploads will start failing silently from the call queue's perspective — the call still connects and disconnects normally, only the recording write fails.

**Step 5 — Confirm consent gate**
```powershell
Get-CsTeamsMeetingPolicy -Identity Global | Select-Object *Consent*
```
Explicit recording consent must be **Off** tenant-wide (or for the relevant policy scope) for Automatic Recording for Call Queue to behave as documented. If consent prompting is on, treat this as a policy conflict, not a bug.

---

## Common Fix Paths

<details><summary>Fix 1 — No automatic recording template exists yet</summary>

```powershell
# Requires Teams PowerShell module 7.8.0+
New-CsAutoRecordingTemplate `
    -Name "<TemplateName>" `
    -Description "<Description>" `
    -RecordingEnabled $true `
    -TranscriptionEnabled $true `
    -AgentViewPermission All `
    -SharePointHostName "<tenant>.sharepoint.com" `
    -SharePointSiteName "<NewSiteName>" `
    -RecordingDocumentOwner "<AdminOrOwnerObjectId>"
```
The SharePoint host must have been visited at least once before this call, and site creation must be enabled tenant-wide (`Get-SPOTenant | Select-Object DenyAddAndCustomizePages, ShowAllUsersClaim` and portal site-creation setting). `SharePointHostName`/`SharePointSiteName` cannot be changed after creation — double-check before running.

</details>

<details><summary>Fix 2 — Template exists but isn't assigned to this queue</summary>

```powershell
$templates = Get-CsAutoRecordingTemplate
$templates | Select-Object Identity, Name    # find the right template Identity

Set-CsCallQueue -Identity "<CallQueueGUID>" -AutoRecordingTemplateId "<TemplateIdentity>"

# Confirm
(Get-CsCallQueue -Identity "<CallQueueGUID>").AutoRecordingTemplateId
```
Get the `CallQueueGUID` either from the Teams admin center URL when editing the queue (`/call-queues/v2/edit/<GUID>`) or via `Get-CsCallQueue | Select-Object Identity, Name`.

</details>

<details><summary>Fix 3 — Conference mode disabled</summary>

Conference mode is configured per-queue in the Teams admin center call queue editor (Call answering settings), not currently exposed as a simple standalone PowerShell switch on `Set-CsCallQueue` in all module versions — confirm the current cmdlet parameter set for your installed module version (`Get-Command Set-CsCallQueue -Syntax`) before scripting a bulk change, since this has shifted across recent releases. For a single queue, enabling it in the admin center is the reliable path today.

**Rollback note:** disabling Conference mode after recording has been in use will silently stop new recordings from that queue going forward; it does not delete history already captured.

</details>

<details><summary>Fix 4 — Call answering uses Users/Shifts instead of a group or channel</summary>

Automatic Recording for Call Queue is only supported when **Call answering** routes through a group or a channel. If the queue currently answers via individually assigned Users or a Shifts schedule, this is an architecture mismatch, not a misconfiguration — the queue must be redesigned around group- or channel-based call answering before recording can be enabled. This is a call-flow redesign conversation with the client, not a quick toggle; scope it as a change request.

</details>

<details><summary>Fix 5 — Agents can't see their own recordings/transcripts</summary>

`AgentViewPermission` is **immutable once the template is created**. If it was left at the default (disabled) and agents need visibility:

```powershell
# Create a NEW template with AgentViewPermission enabled — the existing one cannot be edited
New-CsAutoRecordingTemplate -Name "<NewTemplateName>" -Description "<Description>" `
    -RecordingEnabled $true -TranscriptionEnabled $true -AgentViewPermission All `
    -SharePointHostName "<tenant>.sharepoint.com" -SharePointSiteName "<CanReuseExistingSiteName>" `
    -RecordingDocumentOwner "<OwnerObjectId>"

# Reassign the queue to the new template
Set-CsCallQueue -Identity "<CallQueueGUID>" -AutoRecordingTemplateId "<NewTemplateIdentity>"
```
The SharePoint site provisioned by the original template **can** be reused across multiple templates — set the same `SharePointHostName`/`SharePointSiteName` on the new template to avoid fragmenting recording history across two sites. Also confirm agents hold a **Queues App** license — view access requires the app regardless of the permission flag.

</details>

<details><summary>Fix 6 — SharePoint site drift breaks uploads</summary>

Confirm the template creator (or a designated backup admin) still has SharePoint site-admin rights on the associated site:

```powershell
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<SiteName>" | Select-Object Owner, SiteAdmins
```
If the original creator has left the organization, add another Teams administrator as a site admin on that SharePoint site directly (SharePoint admin center → site permissions) rather than attempting to recreate the template — recreating loses the site link and fragments history. Do not rename the site or restructure its folders; Microsoft documents this as a direct cause of access/permission errors and recording failures.

</details>

<details><summary>Fix 7 — Outbound agent calls aren't being recorded</summary>

This is expected behavior, not a bug. Automatic/Compliance Recording for Call Queue covers **inbound** queue calls only. Outbound calls placed by an agent are treated as ordinary user calls, unassociated with the queue, and require a standard [compliance recording policy](https://learn.microsoft.com/en-us/microsoftteams/teams-compliance-recording-setup) assigned directly to that agent's account to be captured:

```powershell
Get-CsTeamsComplianceRecordingPolicy
Grant-CsTeamsComplianceRecordingPolicy -Identity "<AgentUPN>" -PolicyName "<PolicyName>"
```
Set client expectations explicitly here: recording a queue does not mean every call an agent touches is recorded.

</details>

---

## Escalation Evidence

```
TICKET: Teams Call Queue Automatic Recording Issue
=====================================================
Call Queue Name / GUID: <name / GUID>
Teams PowerShell module version: <output of Get-Module version check>
Template Identity assigned: <AutoRecordingTemplateId or "none">
Template settings (RecordingEnabled / TranscriptionEnabled / AgentViewPermission):
Conference Mode enabled: <true/false>
Shared Call History enabled: <true/false>
Call answering type (group/channel/Users/Shifts): <value>
SharePoint host/site: <host> / <site>
SharePoint site-admin access confirmed for: <admin UPN>
Explicit recording consent policy state: <on/off>
Symptom: <no recording at all / agents can't view / transcript wrong language / recording stops after N weeks>
Reproduction: <steps>
Business impact: <e.g., compliance requirement, QA review blocked>
```

---

## 🎓 Learning Pointers

- Automatic Recording for Call Queue is a **different feature** from Compliance Recording for Call Queue and from general Teams meeting cloud recording — all three store to different places and are governed by different policies. Confirm which one the client actually means before troubleshooting. See [Plan - Recording for Teams Phone Agent, Auto Attendant, and Call Queue calls](https://learn.microsoft.com/en-us/microsoftteams/aa-cq-plan-recording).
- Configuration is PowerShell-only as of this writing (module 7.8.0+) — there is no admin center UI for Automatic Recording templates yet, only for the newer Compliance Recording for Call Queue path. Don't waste triage time hunting for a portal toggle.
- `SharePointHostName` and `SharePointSiteName` are immutable once a template is created — get these right the first time, or plan to create a new template (which can safely reuse an existing site).
- `AgentViewPermission` is also immutable post-creation — the only fix is a new template, not an edit.
- See [Setup - Automatic Recording template for Call Queue](https://learn.microsoft.com/en-us/microsoftteams/aa-cq-setup-call-queue-template-recording-automatic) for the full prerequisite and known-issues list, and [Configure call recording, transcription, and captions in Teams](https://learn.microsoft.com/en-us/microsoftteams/call-recording-transcription-captions) for how this fits into Teams' broader recording landscape.
- Transcript language defaulting to English (US) regardless of configured queue language is a known, currently unresolved Microsoft limitation — don't spend triage time chasing it as a local misconfiguration.
