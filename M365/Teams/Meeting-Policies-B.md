# Teams Meeting Policies — Hotfix Runbook (Mode B: Ops)
> Fix or escalate Teams meeting policy issues — missing features, lobby problems, recording failures, and guest access blocks — in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

```powershell
# Connect to Teams PowerShell
# Install-Module MicrosoftTeams -Force
Connect-MicrosoftTeams

# 1. Check which meeting policy is assigned to the affected user
$upn = "<userUPN>"
Get-CsOnlineUser -Identity $upn | Select-Object DisplayName, TeamsMeetingPolicy, TeamsCallingPolicy

# 2. List all meeting policies in tenant
Get-CsMeetingPolicy | Select-Object Identity, AllowPrivateMeetingScheduling, AllowChannelMeetingScheduling, AllowMeetNow, AutoAdmitUsers, AllowCloudRecording, AllowTranscription

# 3. Check effective policy for the user (policy assigned vs inherited from Global)
(Get-CsOnlineUser -Identity $upn).TeamsMeetingPolicy
# Empty = user inherits the Global policy
```

| Result | Action |
|--------|--------|
| User has no policy assigned (inherits Global) and Global is restrictive | → [Fix 1 — Assign a custom policy](#fix-1--assign-a-meeting-policy-to-user) |
| `AutoAdmitUsers` set to `EveryoneInCompany` but guests stuck in lobby | → [Fix 2 — Lobby bypass for guests](#fix-2--configure-lobby-bypass-for-guests) |
| `AllowCloudRecording: False` | → [Fix 3 — Enable recording](#fix-3--enable-cloud-recording) |
| Feature missing in meeting (whiteboard, breakout rooms, Q&A) | → [Fix 4 — Enable missing meeting features](#fix-4--enable-missing-meeting-features) |
| External users cannot join | → [Fix 5 — External access & federation](#fix-5--fix-external-access--federation) |
| Policy assigned but user still sees old restrictions | → [Fix 6 — Force policy propagation](#fix-6--force-policy-propagation) |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Entra ID user (licensed for Teams)
        │
        ▼
Teams Meeting Policy (CsMeetingPolicy)
    ├── Assigned to user directly (takes priority over Global)
    └── Global policy (inherited if none assigned)
        │
        ▼
Meeting organizer's policy governs the meeting
    (What settings apply = the ORGANIZER's policy, not attendees')
        │
        ├── Lobby settings (AutoAdmitUsers)
        ├── Recording (AllowCloudRecording)
        ├── Transcription (AllowTranscription)
        ├── Meeting features (whiteboard, Q&A, breakout rooms)
        └── External/guest access
                │
                ▼
        Teams External Access Policy (CsExternalAccessPolicy)
        Teams Guest Access settings (Teams Admin Center → Org-wide)
        Entra ID B2B settings (cross-tenant access)
```

**Key principle: Meeting settings follow the organizer, not attendees.**
If user A organizes a meeting, A's policy controls lobby, recording, and features — regardless of what other attendees' policies say.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Identify the affected user's assigned policy**
```powershell
$upn = "<userUPN>"
$user = Get-CsOnlineUser -Identity $upn
$policyName = if ([string]::IsNullOrEmpty($user.TeamsMeetingPolicy)) { "Global" } else { $user.TeamsMeetingPolicy }
Write-Output "User: $($user.DisplayName) | Meeting Policy: $policyName"
```

**Step 2 — Get the full policy settings**
```powershell
Get-CsMeetingPolicy -Identity $policyName | Format-List *
```
Review all settings — compare to expected configuration.

**Step 3 — Confirm if the user is the organizer or attendee**
Meeting policies affect the ORGANIZER. If the user is an attendee complaining about lobby/recording, check the organizer's policy instead:
```powershell
$organizerUPN = "<organizerUPN>"
Get-CsOnlineUser -Identity $organizerUPN | Select-Object DisplayName, TeamsMeetingPolicy
```

**Step 4 — Check external/guest access (for federation issues)**
```powershell
# External access policy
Get-CsExternalAccessPolicy | Select-Object Identity, EnableFederationAccess, EnablePublicCloudAccess

# Guest access (tenant-level) — check Teams Admin Center
# Teams Admin Center → Org-wide settings → Guest access → Allow guest access: ON
Get-CsTenantFederationConfiguration | Select-Object AllowFederatedUsers, AllowPublicUsers, AllowTeamsConsumer
```

**Step 5 — Check for conflicting policy from Teams Rooms / Meeting Templates**
```powershell
# List meeting templates (if configured)
# Teams Admin Center → Meetings → Meeting templates
# Templates can lock specific meeting options — check if organizer used a template
```

---

## Common Fix Paths

<details><summary>Fix 1 — Assign a meeting policy to user</summary>

**Use when:** User inherits Global policy that's too restrictive, or user needs a specific capability (recording, etc.).

```powershell
Connect-MicrosoftTeams

$upn = "<userUPN>"
$policyName = "<PolicyName>"  # e.g., "AllowRecording" or custom policy name

# List available policies first
Get-CsMeetingPolicy | Select-Object Identity

# Assign the policy
Grant-CsMeetingPolicy -Identity $upn -PolicyName $policyName
Write-Output "Policy '$policyName' assigned to $upn. Allow 30-60 minutes for propagation."
```

**Bulk assignment (multiple users):**
```powershell
$users = @("<user1@domain.com>","<user2@domain.com>","<user3@domain.com>")
foreach ($upn in $users) {
    Grant-CsMeetingPolicy -Identity $upn -PolicyName "<PolicyName>"
    Write-Output "Assigned to: $upn"
}
```

**Rollback:**
```powershell
# Revert to Global policy (remove direct assignment)
Grant-CsMeetingPolicy -Identity $upn -PolicyName $null
```

</details>

<details><summary>Fix 2 — Configure lobby bypass for guests</summary>

**Use when:** External guests or federated users are stuck in lobby even when organizer doesn't intend it.

The `AutoAdmitUsers` setting on the organizer's policy controls who bypasses the lobby:

| Setting value | Who bypasses lobby |
|---|---|
| `EveryoneInCompany` | Only internal users skip lobby; guests wait |
| `EveryoneInSameAndFederatedCompany` | Internal + federated org users skip lobby |
| `Everyone` | All users (including anonymous) skip lobby |
| `OrganizerOnly` | Only the organizer skips lobby |
| `InvitedUsers` | Only users explicitly invited skip lobby |

```powershell
Connect-MicrosoftTeams

# Option A: Update the Global policy (affects all users without a direct assignment)
Set-CsMeetingPolicy -Identity Global -AutoAdmitUsers "EveryoneInSameAndFederatedCompany"

# Option B: Update a specific named policy
Set-CsMeetingPolicy -Identity "<PolicyName>" -AutoAdmitUsers "EveryoneInSameAndFederatedCompany"
```

> ⚠️ Setting `Everyone` skips lobby for anonymous join — only appropriate if anonymous meeting join is intentional and acceptable for your security posture.

**Rollback:**
```powershell
Set-CsMeetingPolicy -Identity Global -AutoAdmitUsers "EveryoneInCompany"
```

</details>

<details><summary>Fix 3 — Enable cloud recording</summary>

**Use when:** "Record" button missing in meeting, or recording fails to start.

```powershell
Connect-MicrosoftTeams

$policyName = "<PolicyName>"  # or "Global"

# Enable recording in the policy
Set-CsMeetingPolicy -Identity $policyName `
    -AllowCloudRecording $true `
    -AllowRecordingStorageOutsideRegion $true  # if recordings go to OneDrive/SharePoint across regions

Write-Output "Cloud recording enabled in policy: $policyName"
```

**Also check: OneDrive/SharePoint storage for recordings**
Recordings now save to organizer's OneDrive (personal meetings) or channel (channel meetings). Verify:
- User has OneDrive provisioned
- OneDrive storage not full
- Teams Admin Center → Meetings → Meeting settings → "Store recordings outside of your country or region" (if applicable)

**Also check: Meeting recording admin policy via Teams Admin Center**
```
Teams Admin Center → Meetings → Meeting policies → [Policy] → Recording & transcription
→ Cloud recording: ON
→ Recordings automatically expire: (configure if needed)
```

**Rollback:**
```powershell
Set-CsMeetingPolicy -Identity $policyName -AllowCloudRecording $false
```

</details>

<details><summary>Fix 4 — Enable missing meeting features</summary>

**Use when:** Users report missing whiteboard, breakout rooms, Q&A, polls, live reactions, or meeting chat.

```powershell
Connect-MicrosoftTeams
$policyName = "<PolicyName>"  # or "Global"

# Enable common features
Set-CsMeetingPolicy -Identity $policyName `
    -AllowWhiteboard $true `
    -AllowMeetingReactions $true `
    -AllowTranscription $true `
    -AllowAttendeeToEnableMic $true `
    -AllowAttendeeToEnableCamera $true `
    -AllowIPVideo $true `
    -AllowAnonymousUsersToDialOut $false `
    -AllowBreakoutRooms $true `
    -TeamsCameraFarEndPTZMode Disabled  # set to "SyncedToVideoMuting" or "Enabled" as needed

Write-Output "Meeting features updated in policy: $policyName"
```

**Specific: Enable Q&A**
```powershell
Set-CsMeetingPolicy -Identity $policyName -QnAEngagementMode Enabled
```

**Specific: Enable Polls (via Forms integration)**
```
Teams Admin Center → Teams apps → Manage apps → Search "Forms" → Ensure allowed
Teams Admin Center → Teams apps → Permission policies → Allow Forms app
```

> **Note:** Breakout rooms require the organizer to use the Teams desktop client (not web). Some features (e.g., large gallery, Together Mode) require specific meeting policies AND meeting mode settings.

**Rollback:** Reverse the specific setting to `$false` or `Disabled`.

</details>

<details><summary>Fix 5 — Fix external access & federation</summary>

**Use when:** External users from another tenant cannot join meetings or chat, or federated users are blocked.

```powershell
Connect-MicrosoftTeams

# Check current federation settings
Get-CsTenantFederationConfiguration | Format-List

# Enable federation with all Teams orgs (Teams-to-Teams)
Set-CsTenantFederationConfiguration -AllowFederatedUsers $true

# If you want to allow Teams Consumer (personal accounts)
Set-CsTenantFederationConfiguration -AllowTeamsConsumer $true -AllowTeamsConsumerInbound $true
```

**Block a specific domain (instead of all):**
```powershell
# To block only one domain while allowing others
$blocked = New-CsEdgeDomainPattern -Domain "blockedpartner.com"
Set-CsTenantFederationConfiguration -BlockedDomains @{Add=$blocked}
```

**Allow only specific domains:**
```powershell
$allowed = New-CsEdgeDomainPattern -Domain "partner.com"
Set-CsTenantFederationConfiguration -AllowedDomains @{Add=$allowed} -AllowFederatedUsers $true
```

**Also check: Entra ID cross-tenant access settings**
Modern B2B federation also depends on Entra ID External Identities → Cross-tenant access settings. If the partner tenant is explicitly blocked there, Teams federation will also fail regardless of Teams settings.
```
Entra ID Portal → External Identities → Cross-tenant access settings
→ Check if partner tenant has inbound/outbound blocked
```

**Rollback:**
```powershell
Set-CsTenantFederationConfiguration -AllowFederatedUsers $false
```

</details>

<details><summary>Fix 6 — Force policy propagation</summary>

**Use when:** Policy assigned correctly but user still sees old behavior. Teams policy changes can take 30–90 minutes to propagate.

```powershell
# Verify the assignment took effect
$upn = "<userUPN>"
Get-CsOnlineUser -Identity $upn | Select-Object TeamsMeetingPolicy

# If correct in the system but not in Teams client:
# 1. Ask user to sign out of Teams and sign back in
# 2. Or clear Teams cache (Windows):
#    Close Teams → Delete: %appdata%\Microsoft\Teams\Cache
#                          %appdata%\Microsoft\Teams\blob_storage
#                          %appdata%\Microsoft\Teams\databases
#                          %appdata%\Microsoft\Teams\GPUcache
#    Restart Teams

# Cache clear via PowerShell (run as the affected user, Teams must be closed)
$teamsCacheFolders = @(
    "$env:APPDATA\Microsoft\Teams\Cache",
    "$env:APPDATA\Microsoft\Teams\blob_storage",
    "$env:APPDATA\Microsoft\Teams\databases",
    "$env:APPDATA\Microsoft\Teams\GPUcache"
)
foreach ($folder in $teamsCacheFolders) {
    if (Test-Path $folder) {
        Remove-Item $folder -Recurse -Force
        Write-Output "Cleared: $folder"
    }
}
Write-Output "Teams cache cleared. Restart Teams to apply new policy."
```

**For web client users:** Ctrl+Shift+Delete → Clear cached data → Reload Teams web.

</details>

---

## Escalation Evidence

```
=== Teams Meeting Policy Escalation Pack ===
Date/Time:          _______________
Engineer:           _______________
Tenant ID:          _______________

Affected User UPN:          _______________
User's role in meeting:     [ ] Organizer  [ ] Attendee  [ ] Guest/External
Organizer UPN (if attendee): _______________

Assigned Meeting Policy:    _______________
Issue observed:             _______________
Expected behavior:          _______________

Policy setting causing issue: _______________
Current value of setting:     _______________
Required value:               _______________

External party domain (if federation issue): _______________
Federation enabled in tenant:   [ ] Yes  [ ] No
Entra cross-tenant access checked: [ ] Yes  [ ] No

Steps already taken:
[ ] Verified correct policy assigned to organizer
[ ] Confirmed policy settings via Get-CsMeetingPolicy
[ ] Checked Teams Admin Center for app permission policies
[ ] Cleared Teams client cache
[ ] Waited 60+ minutes after policy change

Teams client version (user):  _______________
Teams admin center URL of policy: _______________

Support tier:  [ ] L2 → L3  [ ] L3 → Microsoft
```

---

## 🎓 Learning Pointers

- **Organizer's policy, not attendees':** This is the single biggest source of confusion with Teams meeting policies. If a user says "I can't record this meeting," check whether they are the organizer. If they're an attendee, the organizer's `AllowCloudRecording` setting is what matters — not the attendee's. See: [Meeting policy overview](https://docs.microsoft.com/en-us/microsoftteams/meeting-policies-overview)

- **Global policy is the fallback for everyone:** If a user has no meeting policy assigned (`TeamsMeetingPolicy` is blank), they inherit the Global policy. Before creating dozens of custom policies, ensure the Global policy is set to a sensible baseline. Custom policies should be exceptions, not the rule.

- **Teams policy propagation is not instant — and cache makes it look slower:** Policy changes in Teams Admin Center or via PowerShell propagate to the service within minutes, but the Teams client can cache policy state for up to 90 minutes. Signing out and back in (or clearing cache) forces a fresh policy fetch. Don't assume a policy change failed just because the user's client still shows old behavior.

- **Lobby settings interact with Entra B2B trust:** `AutoAdmitUsers` on the meeting policy controls the in-meeting lobby. But if a guest's domain is blocked in Entra ID cross-tenant access settings, they won't even get to the lobby — they'll fail at authentication. Check both layers when external users can't join. See: [External access vs guest access](https://docs.microsoft.com/en-us/microsoftteams/communicate-with-users-from-other-organizations)

- **Recordings going to OneDrive/SharePoint broke many assumptions:** Classic Teams recordings went to Microsoft Stream. New recordings go to OneDrive (personal meetings) or the channel's SharePoint library (channel meetings). Permissions, storage quotas, and retention policies all now apply to recording files. If recordings are "disappearing," check OneDrive/SharePoint retention labels and the Teams recording expiry setting in the meeting policy. See: [Teams meeting recording](https://docs.microsoft.com/en-us/microsoftteams/tmr-meeting-recording-change)

- **Meeting templates can lock settings that policies normally control:** If your org uses custom meeting templates (Teams Premium feature), templates can lock lobby, recording, and other settings for specific meeting types — overriding what the organizer would normally be able to change. Always check if a template was applied if a user says "I can't change this setting in my meeting." See: [Teams meeting templates](https://docs.microsoft.com/en-us/microsoftteams/custom-meeting-templates-overview)
