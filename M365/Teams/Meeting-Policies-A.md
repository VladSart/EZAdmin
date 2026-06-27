# Teams Meeting Policies — Reference Runbook (Mode A: Deep Dive)
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

Covers **Microsoft Teams Meeting Policies** — the administrative controls that govern what users can do before, during, and after Teams meetings. This includes:

| Policy Type | What It Controls |
|-------------|-----------------|
| **Meeting policies** | Recording, transcription, lobby, who can present, meeting chat, reactions |
| **Meeting configuration** | Customizable meeting join pages, footer info, legal URL |
| **Live events policies** | Live event scheduling, attendee limits, recording options |
| **Audio conferencing policies** | Dial-in/dial-out, PSTN conferencing minutes |
| **App setup policies** | Which apps appear in the meeting stage |
| **Caller ID policies** | What caller ID appears to external participants |

**Policy inheritance model:**
- Global (Org-wide default) → applied to all users unless overridden
- Named policy → assigned to a user or group; overrides global
- Group policy assignment → assigned via security/M365 group (lower priority than direct assignment, higher than global)

**Assumptions:**
- Teams Admin Center access required.
- PowerShell via `MicrosoftTeams` module for bulk operations.
- License requirements: Teams meeting policies require at least a **Microsoft 365/Teams license**. Some features (e.g., live events, PSTN conferencing) require **Teams Premium** or **Audio Conferencing** add-on.

---

## How It Works

<details><summary>Full architecture</summary>

### Policy Evaluation Chain

```
[User joins or schedules a Teams meeting]
          |
          v
[Teams service evaluates effective policy for the user]
   Priority order (highest → lowest):
   1. Direct user assignment (via Grant-CsTeamsMeetingPolicy)
   2. Group policy assignment (via New-CsGroupPolicyAssignment)
   3. Global (Org-wide default) policy
          |
          v
[Policy payload delivered to Teams client at sign-in / policy refresh]
   - Client caches policy
   - Refresh cycle: ~2-4 hours, or on sign-out/sign-in
          |
          v
[Teams client enforces policy locally]
   - Removes/hides controls based on policy (e.g., no recording button)
   - Server-side enforcement for critical controls (lobby, who can present)
```

### Meeting Lobby Logic

The lobby is one of the most-configured (and most-misunderstood) elements. The effective lobby setting is determined by BOTH the organiser's policy AND the meeting-level setting (what the organiser set for that specific meeting):

```
Organiser's policy: AllowedUsersToBypassLobby
   ├── EveryoneInCompany (default)     → internal users bypass, external wait
   ├── Everyone                         → nobody goes to lobby
   ├── EveryoneInCompanyExcludingGuests → guests wait
   ├── InvitedUsers                     → only explicitly invited bypass
   ├── OrganizerOnly                    → only organiser bypasses
   └── EveryoneInSameAndFederatedCompany → internal + federated bypass

Meeting-level override (Teams client meeting options):
   The organiser can RESTRICT the policy but NOT exceed it.
   e.g., if policy = EveryoneInCompany, organiser can set OrganizerOnly
         but cannot set Everyone (if admin blocked it in policy).
```

### Recording Pipeline

```
[User clicks "Record" in meeting]
          |
          v
[Teams checks: AllowCloudRecording = true in user's policy?]
   No  → Record button hidden / disabled
   Yes → Recording starts
          |
          v
[Recording stored in OneDrive (standard meeting) or SharePoint (channel meeting)]
          |
          v
[Post-meeting processing: transcription, chapters, recap]
   Requires: AllowTranscription = true (for automatic transcription)
   Requires: Teams Premium licence for Intelligent Recap
          |
          v
[Recording available in chat / channel within ~15 min post-meeting]
   Retention: OneDrive/SharePoint retention policies apply
```

### Who Can Present Logic

```
Policy: DesignatedPresenterRoleMode
   ├── EveryoneUserOverride   → everyone is presenter, organiser can change
   ├── EveryoneInCompanyUserOverride → org members are presenters
   ├── OrganizerOnlyUserOverride → only organiser is presenter by default
   └── RoleIsPresenter        → Teams decides (meeting type dependent)
```

### Group Policy Assignment Ranking

When a user is in multiple groups, all with different policy assignments:
```
Ranking (lower number = higher priority):
  Rank 1 assigned to Group A (50 members) → these users get Policy A
  Rank 2 assigned to Group B (200 members) → users ONLY in Group B get Policy B
  Users in both groups → get Policy A (rank 1 wins)
```

</details>

---

## Dependency Stack

```
Microsoft Teams Service (cloud)
    │
    ├── Entra ID (user identity, group membership for policy assignment)
    │
    ├── Teams meeting policies (PowerShell / Teams Admin Center)
    │       ├── Global (Org-wide default)
    │       ├── Direct user assignment
    │       └── Group policy assignment
    │
    ├── OneDrive / SharePoint (meeting recording storage)
    │       └── Retention / sensitivity labels applied by Purview
    │
    ├── PSTN / Audio Conferencing (dial-in numbers)
    │       └── Audio Conferencing licence + Calling Plan / Direct Routing
    │
    ├── Teams Premium licence (Intelligent Recap, custom meeting backgrounds, watermarks)
    │
    ├── Teams client (enforces most UI restrictions locally)
    │       └── Policy cache refresh: ~2-4 hours
    │
    └── Teams admin roles
            ├── Teams Administrator (full policy control)
            └── Teams Communications Administrator (calling/conferencing policies)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Record button missing for user | `AllowCloudRecording = false` in their effective policy | `Get-CsTeamsMeetingPolicy` → check assigned policy |
| External participants going directly into meeting (bypassing lobby) | `AutoAdmittedUsers = Everyone` in policy | Check organiser's policy + meeting-level options |
| Users can't see transcription/recap after meeting | `AllowTranscription = false` or missing Teams Premium licence | Check policy + licence assignment |
| User getting different policy than expected | Group policy assignment conflict / direct assignment overrides | Check `Get-CsUserPolicyAssignment` |
| Policy change not taking effect | Client cache not yet refreshed | Wait 2-4h or have user sign out/in |
| Live event recording option not available | Live events policy restriction | Check `Get-CsTeamsLiveEventPolicy` |
| Dial-in conferencing numbers missing from meeting invite | Audio Conferencing licence not assigned, or bridge settings wrong | Check licence + `Get-CsOnlineDialInConferencingUserInfo` |
| Meeting chat disabled during meeting | `MeetingChatEnabledType = Disabled` in policy | Check policy value |
| Anonymous users can't join | `AllowAnonymousUsersToJoinMeeting = false` | Check global or organiser's policy |
| Reactions (emoji) not available in meeting | `AllowMeetingReactions = false` | Check effective policy |
| Recording saves to wrong location | Channel vs non-channel meeting routing | OneDrive for personal, SharePoint for channel — by design |

---

## Validation Steps

**1. Check what policy a user is assigned**

```powershell
# Connect
Connect-MicrosoftTeams

# Check directly assigned meeting policy
$upn = "<UserUPN>"
Get-CsUserPolicyAssignment -Identity $upn | Where-Object { $_.PolicyType -eq "TeamsMeetingPolicy" }

# If blank, user inherits Global policy
```

Expected: Either a named policy or empty (= Global).

**2. Read the effective meeting policy for a user**

```powershell
# Get effective (resolved) policy — shows what the user actually gets
Get-CsEffectivePolicy -Identity $upn -PolicyType TeamsMeetingPolicy
```

Expected: All policy properties with current values.

**3. Check all available meeting policies in the tenant**

```powershell
Get-CsTeamsMeetingPolicy | Select-Object Identity, AllowCloudRecording, AllowTranscription,
    AutoAdmittedUsers, AllowAnonymousUsersToJoinMeeting, AllowMeetingReactions,
    DesignatedPresenterRoleMode, MeetingChatEnabledType |
    Format-Table -AutoSize
```

**4. Check group policy assignments**

```powershell
# List all group policy assignments for meeting policies
Get-CsGroupPolicyAssignment -PolicyType TeamsMeetingPolicy |
    Select-Object GroupId, PolicyName, Rank, PolicyType |
    Sort-Object Rank
```

**5. Check Audio Conferencing status for a user**

```powershell
Get-CsOnlineDialInConferencingUserInfo -Identity $upn |
    Select-Object Identity, ConferencingProvider, AllowPSTNOnlyMeetings,
        TollNumber, TollFreeNumber, ConferenceId
```

Expected: `ConferencingProvider = Microsoft`, `TollNumber` populated.

**6. Verify licence for Teams Premium features**

```powershell
# Graph: Check user licences
Connect-MgGraph -Scopes "User.Read.All"

$user = Get-MgUser -UserId $upn -Property AssignedLicenses, DisplayName
$skuIds = $user.AssignedLicenses.SkuId

# Teams Premium SKU: 1fec84c7-0432-4cc6-9cda-ef8b2267e61c (verify current at aka.ms/m365licensingguide)
$teamsPremiumSku = "1fec84c7-0432-4cc6-9cda-ef8b2267e61c"
if ($skuIds -contains $teamsPremiumSku) {
    Write-Host "Teams Premium: ASSIGNED" -ForegroundColor Green
} else {
    Write-Host "Teams Premium: NOT assigned" -ForegroundColor Yellow
}
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify Effective Policy

1. Run `Get-CsUserPolicyAssignment -Identity <UPN>` to find directly assigned policies.
2. Run `Get-CsGroupPolicyAssignment -PolicyType TeamsMeetingPolicy` to find group assignments.
3. If both exist, direct assignment wins.
4. If only group assignment: check rank. Lower rank number = higher priority.
5. If neither: user gets Global policy. Check Global with `Get-CsTeamsMeetingPolicy -Identity Global`.

### Phase 2 — Recording / Transcription Issues

1. Confirm `AllowCloudRecording = True` in the effective policy.
2. Confirm user has a Teams licence (not just the base plan — Recordings require valid storage destination).
3. Check OneDrive storage capacity — if full, recording will fail silently.
4. For channel meeting recordings: check SharePoint site storage.
5. If recording exists but users can't access it: check OneDrive/SharePoint permissions on the recording file.

### Phase 3 — Lobby Misconfiguration

1. Run `Get-CsTeamsMeetingPolicy -Identity <PolicyName> | Select AutoAdmittedUsers, AllowPstnUsersToBypassLobby`.
2. Confirm expected `AutoAdmittedUsers` value:
   - `EveryoneInCompany` — most common default for internal-heavy orgs
   - `Everyone` — appropriate for public webinars; risk for sensitive meetings
3. Educate organizers: they can restrict per-meeting in Meeting Options, but cannot expand beyond what their policy allows.
4. If external guests are bypassing lobby unexpectedly: check if guests are being treated as "federated" users (B2B guests from trusted tenants may bypass if `EveryoneInSameAndFederatedCompany` is set).

### Phase 4 — Policy Change Not Taking Effect

1. Ask the user to **sign out and back into Teams** (forces policy refresh).
2. Alternatively, wait 2-4 hours for automatic policy cache refresh.
3. Confirm the change was saved in Teams Admin Center or that the PowerShell command returned no errors.
4. Re-run `Get-CsEffectivePolicy` after the wait to confirm propagation.

### Phase 5 — Group Policy Assignment Conflicts

1. List all group assignments: `Get-CsGroupPolicyAssignment -PolicyType TeamsMeetingPolicy`.
2. Check if the user is a member of multiple groups with conflicting assignments.
3. Determine which rank wins (lower = higher priority).
4. Adjust rank: `Set-CsGroupPolicyAssignment -GroupId <GroupId> -PolicyType TeamsMeetingPolicy -Rank 1`.
5. Or remove group assignment and use direct assignment for exceptions: `Grant-CsTeamsMeetingPolicy -Identity <UPN> -PolicyName <PolicyName>`.

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Enable Cloud Recording for a User / Group</summary>

```powershell
Connect-MicrosoftTeams

# Option A: Modify existing policy (affects all users with this policy)
$policyName = "<PolicyName>"  # e.g., "AllUsers" or "Global"
Set-CsTeamsMeetingPolicy -Identity $policyName -AllowCloudRecording $true

# Option B: Create a new policy and assign to specific user
New-CsTeamsMeetingPolicy -Identity "RecordingEnabled" -AllowCloudRecording $true -AllowTranscription $true

# Assign to individual user
Grant-CsTeamsMeetingPolicy -Identity "<UserUPN>" -PolicyName "RecordingEnabled"

# Assign to group
$groupId = (Get-MgGroup -Filter "displayName eq '<GroupName>'").Id
New-CsGroupPolicyAssignment -GroupId $groupId -PolicyType TeamsMeetingPolicy `
    -PolicyName "RecordingEnabled" -Rank 1
```

**Rollback:**
```powershell
# Revert user to global policy
Grant-CsTeamsMeetingPolicy -Identity "<UserUPN>" -PolicyName $null  # null = revert to global
```

</details>

<details>
<summary>Fix 2 — Tighten Lobby Settings (Security Hardening)</summary>

```powershell
Connect-MicrosoftTeams

# Recommended secure lobby settings for most enterprise orgs
Set-CsTeamsMeetingPolicy -Identity Global `
    -AutoAdmittedUsers "EveryoneInCompany" `
    -AllowPstnUsersToBypassLobby $false `
    -AllowAnonymousUsersToJoinMeeting $false

# For highly sensitive orgs (only explicitly invited bypass lobby):
Set-CsTeamsMeetingPolicy -Identity Global `
    -AutoAdmittedUsers "InvitedUsers" `
    -AllowPstnUsersToBypassLobby $false

# Create a "Webinar-style" policy for departments hosting public events:
New-CsTeamsMeetingPolicy -Identity "PublicWebinar" `
    -AutoAdmittedUsers "Everyone" `
    -AllowPstnUsersToBypassLobby $true

# Assign the webinar policy only to approved users
Grant-CsTeamsMeetingPolicy -Identity "<EventOrganizerUPN>" -PolicyName "PublicWebinar"
```

**Rollback:**
```powershell
# Restore default lobby behaviour
Set-CsTeamsMeetingPolicy -Identity Global `
    -AutoAdmittedUsers "EveryoneInCompany" `
    -AllowPstnUsersToBypassLobby $true
```

</details>

<details>
<summary>Fix 3 — Bulk Assign Meeting Policy via Group</summary>

```powershell
Connect-MicrosoftTeams
Connect-MgGraph -Scopes "Group.Read.All"

# Get group ID
$groupName = "<SecurityGroupName>"
$groupId = (Get-MgGroup -Filter "displayName eq '$groupName'").Id

if (-not $groupId) {
    Write-Error "Group not found: $groupName"
    exit 1
}

# Assign policy to group
$policyName = "<PolicyName>"
New-CsGroupPolicyAssignment -GroupId $groupId `
    -PolicyType TeamsMeetingPolicy `
    -PolicyName $policyName `
    -Rank 2  # Adjust rank as needed

Write-Host "Policy '$policyName' assigned to group '$groupName' (ID: $groupId)" -ForegroundColor Green

# Verify
Get-CsGroupPolicyAssignment -PolicyType TeamsMeetingPolicy |
    Where-Object { $_.GroupId -eq $groupId }
```

**Rollback:**
```powershell
Remove-CsGroupPolicyAssignment -GroupId $groupId -PolicyType TeamsMeetingPolicy
```

</details>

<details>
<summary>Fix 4 — Enable Audio Conferencing (Dial-In)</summary>

```powershell
# Prerequisites: Audio Conferencing licence assigned to user in M365 admin center

Connect-MicrosoftTeams

# Verify Audio Conferencing is provisioned for user
Get-CsOnlineDialInConferencingUserInfo -Identity "<UserUPN>"

# If not provisioned, check licence first (needs AudioConferencing SKU)
# Then run:
Set-CsOnlineDialInConferencingUser -Identity "<UserUPN>" `
    -ServiceNumber "<TollNumber>"  # e.g., "+12025551234"

# Reset conference ID if user reports dial-in issues
Reset-CsOnlineDialInConferencingUserMeetingUrl -Identity "<UserUPN>"
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Teams Meeting Policy evidence for a user
.NOTES     Run from admin workstation with MicrosoftTeams and Microsoft.Graph modules
#>
param(
    [string]$UserUPN = "<UserUPN>",
    [string]$OutputPath = "$env:TEMP\TeamsMeetingPolicy-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
)

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null

Connect-MicrosoftTeams -ErrorAction Stop

Write-Host "Collecting user policy assignment..." -ForegroundColor Cyan
Get-CsUserPolicyAssignment -Identity $UserUPN |
    Export-Csv "$OutputPath\user-policy-assignments.csv" -NoTypeInformation

Write-Host "Collecting effective meeting policy..." -ForegroundColor Cyan
try {
    Get-CsEffectivePolicy -Identity $UserUPN -PolicyType TeamsMeetingPolicy |
        ConvertTo-Json | Out-File "$OutputPath\effective-meeting-policy.json"
} catch {
    Write-Warning "Get-CsEffectivePolicy not available; exporting assigned policy instead"
    Get-CsTeamsMeetingPolicy | Where-Object {
        $_.Identity -in (Get-CsUserPolicyAssignment -Identity $UserUPN).PolicyName
    } | ConvertTo-Json | Out-File "$OutputPath\assigned-meeting-policy.json"
}

Write-Host "Collecting all meeting policies..." -ForegroundColor Cyan
Get-CsTeamsMeetingPolicy |
    Select-Object Identity, AllowCloudRecording, AllowTranscription,
        AutoAdmittedUsers, AllowAnonymousUsersToJoinMeeting,
        AllowMeetingReactions, DesignatedPresenterRoleMode,
        MeetingChatEnabledType, AllowPstnUsersToBypassLobby |
    Export-Csv "$OutputPath\all-meeting-policies.csv" -NoTypeInformation

Write-Host "Collecting group policy assignments..." -ForegroundColor Cyan
Get-CsGroupPolicyAssignment -PolicyType TeamsMeetingPolicy |
    Export-Csv "$OutputPath\group-policy-assignments.csv" -NoTypeInformation

Write-Host "Collecting audio conferencing info..." -ForegroundColor Cyan
Get-CsOnlineDialInConferencingUserInfo -Identity $UserUPN -ErrorAction SilentlyContinue |
    Export-Csv "$OutputPath\audio-conferencing.csv" -NoTypeInformation

Write-Host "Done. Evidence saved to: $OutputPath" -ForegroundColor Green
Invoke-Item $OutputPath
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check user's meeting policy | `Get-CsUserPolicyAssignment -Identity <UPN>` |
| Check effective policy | `Get-CsEffectivePolicy -Identity <UPN> -PolicyType TeamsMeetingPolicy` |
| List all meeting policies | `Get-CsTeamsMeetingPolicy \| Select Identity, AllowCloudRecording` |
| Read specific policy | `Get-CsTeamsMeetingPolicy -Identity <PolicyName>` |
| Modify a policy | `Set-CsTeamsMeetingPolicy -Identity <PolicyName> -AllowCloudRecording $true` |
| Create new policy | `New-CsTeamsMeetingPolicy -Identity <Name> -AllowCloudRecording $true` |
| Assign policy to user | `Grant-CsTeamsMeetingPolicy -Identity <UPN> -PolicyName <PolicyName>` |
| Revert user to global | `Grant-CsTeamsMeetingPolicy -Identity <UPN> -PolicyName $null` |
| Assign policy to group | `New-CsGroupPolicyAssignment -GroupId <ID> -PolicyType TeamsMeetingPolicy -PolicyName <Name> -Rank 1` |
| List group assignments | `Get-CsGroupPolicyAssignment -PolicyType TeamsMeetingPolicy` |
| Remove group assignment | `Remove-CsGroupPolicyAssignment -GroupId <ID> -PolicyType TeamsMeetingPolicy` |
| Check audio conferencing | `Get-CsOnlineDialInConferencingUserInfo -Identity <UPN>` |
| List live event policies | `Get-CsTeamsLiveEventPolicy` |

---

## 🎓 Learning Pointers

- **Policy inheritance order:** Direct user assignment always wins over group assignment, which always wins over Global. If a user has a direct assignment, group assignments are completely ignored for that policy type. This is a common source of confusion when trying to use group-based policy management. See [Teams policy assignment](https://learn.microsoft.com/en-us/microsoftteams/policy-assignment-overview).

- **Lobby settings are a shared responsibility:** Admin policy sets the ceiling (the most permissive setting allowed), but meeting organisers can restrict below that ceiling in their Meeting Options. Security-conscious orgs should set the org-wide default to `InvitedUsers` and educate organisers that they can relax per-meeting, rather than setting a permissive global default. See [Meeting lobby settings](https://learn.microsoft.com/en-us/microsoftteams/lobby-meeting-settings).

- **Recording goes to OneDrive/SharePoint, not Stream:** Since 2021, all Teams meeting recordings go to OneDrive for Business (non-channel meetings) or SharePoint document libraries (channel meetings). Microsoft Stream is just the player, not the storage. This means OneDrive storage quotas and SharePoint permissions govern who can view recordings. See [Teams meeting recording](https://learn.microsoft.com/en-us/microsoftteams/tmr-meeting-recording-change).

- **Policy changes aren't instant:** The Teams client caches policies. After a policy change, affected users need to sign out and back in, or wait up to 4 hours for the cache to expire. This delay is a known and documented behaviour, not a bug.

- **Teams Premium unlocks Intelligent Recap and more:** Features like AI-generated meeting notes, speaker timeline, action items, custom backgrounds, and meeting watermarks all require Teams Premium. If users report missing features despite the correct policy, check the licence before escalating. See [Teams Premium features](https://learn.microsoft.com/en-us/microsoftteams/teams-add-on-licensing/licensing-enhance-teams).

- **Audio Conferencing is a separate licence add-on:** Dial-in meeting numbers are NOT included in standard Teams licences. The Audio Conferencing add-on (or Microsoft 365 E5/Teams Essentials with Audio Conferencing) must be assigned. Without it, meeting invites won't contain dial-in numbers. See [Audio Conferencing requirements](https://learn.microsoft.com/en-us/microsoftteams/country-and-region-availability-for-audio-conferencing-and-calling-plans/country-and-region-availability-for-audio-conferencing-and-calling-plans).
