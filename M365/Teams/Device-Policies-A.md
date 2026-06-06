# Teams Device Policies — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Covers how Teams device policies are structured, applied, and debugged across MTR (Teams Rooms), Teams Phones, Displays, and common endpoint policy assignments.

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
- Teams meeting policies (audio/video, recording, content sharing)
- Teams messaging policies (chat features, read receipts, Giphy, priority notifications)
- Teams calling policies (private calls, call forwarding, voicemail)
- Teams app setup policies (pinned apps, installed apps)
- Teams update policies (ring assignments for app updates)
- Microsoft Teams Rooms (MTR) on Windows and Android
- Teams IP phones and common area phones
- Policy assignment: direct, group-based, and global (org-wide default)

**Out of scope:**
- Phone System / calling plan configuration (separate voice runbook)
- Teams channel and team creation policies
- MTR hardware provisioning and room account setup (separate MTR runbook)
- Teams meeting room licensing (covered in Licensing runbook)

**Assumptions:**
- Admin has Teams Administrator or Teams Communications Administrator role
- Devices are enrolled in Intune (for MTR on Windows) or Teams Admin Center management
- PowerShell: MicrosoftTeams module v4.x or later

---

## How It Works

<details><summary>Full architecture</summary>

### Policy Architecture

Teams policies are tenant-level objects stored in Microsoft's Teams service backend. They are **not** Intune policies or Azure AD objects — they live in the Teams infrastructure. They are assigned to:

1. **Users** (directly or via group)
2. **Devices** (for MTR and certified Teams devices)
3. **Org-wide (global)** — fallback if no explicit assignment

```
Teams Policy Store (Microsoft backend)
        │
        ├── Meeting Policies         (CsTeamsMeetingPolicy)
        ├── Messaging Policies       (CsTeamsMessagingPolicy)
        ├── Calling Policies         (CsTeamsCallingPolicy)
        ├── App Setup Policies       (CsTeamsAppSetupPolicy)
        ├── Update Policies          (CsTeamsUpdateManagementPolicy)
        ├── Audio Conferencing       (CsOnlineAudioConferencingRoutingPolicy)
        └── Emergency Calling        (CsTeamsEmergencyCallingPolicy)
                  │
        ┌─────────┴─────────────────────────────────┐
        │                                           │
   Direct assignment                        Group assignment
   (Grant-CsTeams*Policy -Identity <UPN>)   (New-CsGroupPolicyAssignment)
        │                                           │
        └──────────────────┬────────────────────────┘
                           │
                    Teams client (app)
                           │
                    Policy effective at next
                    client sync (up to 1h)
```

### Policy Precedence (most to least specific)

```
1. Direct assignment (Grant-CsTeams*Policy -Identity <user>)
        ↓ (if none)
2. Group assignment — highest priority group wins
   (group assignment rank: lower number = higher priority)
        ↓ (if none)
3. Global (org-wide default) policy
```

When a user is in multiple groups with conflicting policies, the **rank** assigned to each group policy assignment determines which wins. Rank 1 wins over Rank 2, etc.

### Device Policy vs. User Policy

- **User-assigned policies** apply based on the identity signed in on the device
- **Device-assigned policies** (MTR, Teams Phones) apply to the device account regardless of who's signed in
- For **MTR devices**: the resource account has policies assigned to it. The policies on the meeting organiser also influence the meeting experience (e.g. recording permissions)
- For **common area phones**: the shared device account has policies; there's no individual user signed in

### Policy Sync to Clients

Teams clients sync policy state approximately every hour. After a policy change:
- Desktop client: up to 1h before the new policy takes effect
- MTR: may require a device restart to pick up policy changes
- Teams Phone: reboot or sign-out/sign-in may be needed for immediate update
- Forcing a sync: `Invoke-CsTeamsConfigurationUpdate` (admin only, tenant-level)

### Update Policies (Teams App Update Rings)

Teams for Windows supports update rings similar to Windows Update:
- **Targeted (Preview):** Latest features first (admin-opted in users)
- **Validation:** Beta features for testers
- **Standard:** Default GA release
- **Broad (Slow ring):** Delayed updates for stability-first environments

For MTR on Windows, update management is separate — handled via **MTR Update Management** in Teams Admin Center or Intune policies on the underlying Windows device.

</details>

---

## Dependency Stack

```
Teams Admin Center / PowerShell (admin interface)
        │
        ▼
Teams Service Backend (Microsoft cloud)
        │
        ├── Policy Store: CsTeams*Policy objects
        │
        ├── Assignment Engine
        │         ├── Direct assignments (per-user, per-device-account)
        │         └── Group assignments (via Entra ID group membership)
        │                   └── Group membership sync: up to 24h delay
        │
        ├── Entra ID
        │         ├── User account: enabled, licensed
        │         ├── Teams licence: E3/E5 or Teams Essentials
        │         └── Group membership (for group-based policy)
        │
        └── Teams Client (Windows app, MTR, Teams Phone)
                  ├── Policy sync: up to 1h
                  └── For MTR: device account must be valid + signed in
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| User can't record meetings | Meeting policy: `AllowCloudRecording = False` or recording policy restriction | `Get-CsTeamsMeetingPolicy -Identity <policy>` |
| Recording button greyed out but policy says allowed | Organizer's policy controls recording, not attendee's | Check organizer's assigned meeting policy |
| User can't start private calls | Calling policy: `AllowPrivateCalling = False` | `Get-CsTeamsCallingPolicy -Identity <policy>` |
| App not available/pinned in Teams client | App setup policy missing the app, or app admin disabled org-wide | Check app setup policy and org-wide app settings |
| Policy change not applied after 2h | Policy sync delay, or group membership not yet propagated | Check effective policy; force client sign-out/sign-in |
| MTR shows wrong meeting policy | MTR resource account has wrong policy; or organizer policy overrides | Check resource account's policy assignment |
| Teams Phone feature unavailable | Device account policy vs. calling policy mismatch | Check `Get-CsUserPolicyAssignment -Identity <resourceAccountUPN>` |
| "This feature is not available in your region" | Calling policy restriction by geographic policy | Check if user has a region-specific policy applied |
| Group policy not applying | Group membership not synced yet (up to 24h), or direct assignment overrides | Check `Get-CsUserPolicyAssignment` for effective policy; check group membership |
| Users in same group getting different experiences | Mixed direct assignments overriding group policy | Audit direct assignments: `Get-CsOnlineUser \| Select *Policy*` |

---

## Validation Steps

**1. Check effective policy for a user**
```powershell
Connect-MicrosoftTeams
# Get all policy assignments for a user (includes effective policy with precedence)
Get-CsUserPolicyAssignment -Identity <UPN> | Format-Table PolicyType, PolicyName, AssignmentType
```

**2. Check specific policy settings**
```powershell
# Meeting policy
Get-CsTeamsMeetingPolicy -Identity <policyName> |
  Select-Object Identity, AllowCloudRecording, AllowTranscription,
    AllowIPVideo, ScreenSharingMode, AllowMeetNow, AllowExternalParticipantGiveRequestControl

# Messaging policy
Get-CsTeamsMessagingPolicy -Identity <policyName> |
  Select-Object Identity, AllowUserChat, AllowGiphy, AllowPriorityMessages,
    AllowUserDeleteMessage, ReadReceiptsEnabledType

# Calling policy
Get-CsTeamsCallingPolicy -Identity <policyName> |
  Select-Object Identity, AllowPrivateCalling, AllowCallForwardingToUser,
    AllowVoicemail, AllowCallGroups, AllowDelegation
```

**3. Check group policy assignments**
```powershell
# List all group policy assignments in the tenant
Get-CsGroupPolicyAssignment | Format-Table GroupId, PolicyType, PolicyName, Rank

# Check which groups a user is in (relevant for Teams policy)
Get-MgUserMemberOf -UserId <UPN> | Select-Object AdditionalProperties
```

**4. Check MTR device account policy**
```powershell
# For a Teams Room resource account
$roomUPN = "<room@contoso.com>"
Get-CsUserPolicyAssignment -Identity $roomUPN | Format-Table PolicyType, PolicyName, AssignmentType

# Check MTR device-specific settings in Teams Admin Center:
# Teams devices → Teams Rooms on Windows → [device] → Policies
```

**5. Verify Teams licence**
```powershell
# User must have a Teams licence for policies to apply
Get-MgUserLicenseDetail -UserId <UPN> |
  Select-Object -ExpandProperty ServicePlans |
  Where-Object { $_.ServicePlanName -match "TEAMS" }
# Expected: ServicePlanProvisioningStatus = Success
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify the Policy Gap

1. Run `Get-CsUserPolicyAssignment` for the affected user — note the `AssignmentType`:
   - `Direct` = directly assigned, overrides group
   - `Group` = via group membership
   - `Default` = org-wide default (no explicit assignment)

2. Compare the effective policy to the intended policy — what's the difference?

3. If the policy looks correct but the feature isn't working:
   - Has it been more than 1 hour since the assignment?
   - Ask the user to sign out of Teams and sign back in to force a policy refresh

### Phase 2 — Group Policy Investigation

4. If the user has a group assignment:
```powershell
# Find which group is providing the policy:
$assignments = Get-CsGroupPolicyAssignment | Where-Object { $_.PolicyType -eq "TeamsMeetingPolicy" }
foreach ($a in $assignments) {
  $members = Get-MgGroupMember -GroupId $a.GroupId | Select-Object -ExpandProperty AdditionalProperties
  if ($members.userPrincipalName -contains "<targetUPN>") {
    Write-Host "Policy '$($a.PolicyName)' via group '$($a.GroupId)' rank $($a.Rank)"
  }
}
```

5. Check for conflicting group assignments (user in multiple policy groups):
   - The group with **Rank 1** wins for each policy type
   - If two groups both assign a `TeamsMeetingPolicy`, the lower rank number wins

### Phase 3 — MTR-Specific Investigation

6. For MTR issues, check if the device is online in Teams Admin Center:
   - **Teams devices → Teams Rooms on Windows → [device]**
   - Status must be **Healthy** and last heartbeat recent

7. Check the MTR resource account:
```powershell
# Verify resource account has correct licence (Teams Rooms Pro or Basic)
Get-MgUserLicenseDetail -UserId <roomUPN> |
  Where-Object { $_.SkuPartNumber -match "MEETING_ROOM" -or $_.SkuPartNumber -match "MTR" }

# Check meeting policy on resource account
Get-CsUserPolicyAssignment -Identity <roomUPN> | Where-Object PolicyType -eq "TeamsMeetingPolicy"
```

8. For MTR not picking up policy changes: restart the device from Teams Admin Center:
   - **Teams devices → [device] → Restart**

---

## Remediation Playbooks

<details><summary>Playbook 1 — Assign a meeting policy to users (direct)</summary>

```powershell
Connect-MicrosoftTeams

# Assign a specific meeting policy to a single user:
Grant-CsTeamsMeetingPolicy -Identity <UPN> -PolicyName "<PolicyName>"

# Remove a direct assignment (reverts to group or global default):
Grant-CsTeamsMeetingPolicy -Identity <UPN> -PolicyName $null

# Assign to multiple users in bulk:
$users = Get-Content "C:\users.txt"  # One UPN per line
foreach ($user in $users) {
  Grant-CsTeamsMeetingPolicy -Identity $user -PolicyName "<PolicyName>"
  Write-Host "Assigned to $user"
}

# Verify effective policy:
Get-CsUserPolicyAssignment -Identity <UPN> | Where-Object PolicyType -eq "TeamsMeetingPolicy"
```

**Rollback:** `Grant-CsTeamsMeetingPolicy -Identity <UPN> -PolicyName $null` to remove direct assignment.

</details>

<details><summary>Playbook 2 — Set up group-based policy assignment</summary>

```powershell
Connect-MicrosoftTeams

# Get the Entra group object ID:
$group = Get-MgGroup -Filter "displayName eq '<GroupName>'"
$groupId = $group.Id

# Assign a meeting policy to a group (Rank 1 = highest priority):
New-CsGroupPolicyAssignment -GroupId $groupId `
  -PolicyType "TeamsMeetingPolicy" `
  -PolicyName "<PolicyName>" `
  -Rank 1

# Check all group assignments for a policy type:
Get-CsGroupPolicyAssignment | Where-Object PolicyType -eq "TeamsMeetingPolicy" |
  Sort-Object Rank | Format-Table GroupId, PolicyName, Rank

# Update rank for an existing assignment:
Set-CsGroupPolicyAssignment -GroupId $groupId `
  -PolicyType "TeamsMeetingPolicy" `
  -Rank 2

# Remove a group policy assignment:
Remove-CsGroupPolicyAssignment -GroupId $groupId -PolicyType "TeamsMeetingPolicy"
```

**Note:** Group policy propagation can take up to 24 hours for large groups. Direct assignments apply immediately.

</details>

<details><summary>Playbook 3 — Create a custom meeting policy for a specific use case</summary>

```powershell
Connect-MicrosoftTeams

# Example: Create a restricted policy for external-facing users
# (no recording, no screen sharing by guests, no anonymous join)
New-CsTeamsMeetingPolicy -Identity "External-Restricted" `
  -AllowCloudRecording $false `
  -AllowTranscription $false `
  -ScreenSharingMode "SingleApplication" `
  -AllowAnonymousUsersToJoinMeeting $false `
  -AllowExternalParticipantGiveRequestControl $false `
  -AllowGuestAudioVideo "Enabled" `
  -AutoAdmittedUsers "EveryoneInCompany"

# Verify the policy was created:
Get-CsTeamsMeetingPolicy -Identity "External-Restricted"

# Assign to a group:
$groupId = (Get-MgGroup -Filter "displayName eq 'External Users'").Id
New-CsGroupPolicyAssignment -GroupId $groupId `
  -PolicyType "TeamsMeetingPolicy" `
  -PolicyName "External-Restricted" `
  -Rank 1

# Rollback — remove the policy (must remove all assignments first):
# Remove-CsGroupPolicyAssignment -GroupId $groupId -PolicyType "TeamsMeetingPolicy"
# Remove-CsTeamsMeetingPolicy -Identity "External-Restricted"
```

</details>

<details><summary>Playbook 4 — Fix MTR resource account policy</summary>

```powershell
Connect-MicrosoftTeams

$roomUPN = "<room@contoso.com>"

# Check current policy assignments:
Get-CsUserPolicyAssignment -Identity $roomUPN | Format-Table PolicyType, PolicyName

# Assign appropriate meeting policy for a room account:
# (MTR rooms typically get a policy that allows recording and transcription by organizer)
Grant-CsTeamsMeetingPolicy -Identity $roomUPN -PolicyName "AllOn"
# Or a custom MTR policy:
Grant-CsTeamsMeetingPolicy -Identity $roomUPN -PolicyName "<MTR-Policy-Name>"

# Assign calling policy (common area phones don't need advanced calling):
Grant-CsTeamsCallingPolicy -Identity $roomUPN -PolicyName "AllowCalling"

# After policy change on MTR resource account, restart the device:
# Teams Admin Center → Teams devices → Teams Rooms on Windows → [device] → Restart

# Verify in Teams Admin Center after restart:
# Teams devices → [device] → Policies tab — should show new policy
```

</details>

<details><summary>Playbook 5 — Audit and clean up policy sprawl</summary>

```powershell
Connect-MicrosoftTeams
Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All"

# Get all users with direct policy assignments (not using group or default)
$allUsers = Get-CsOnlineUser -ResultSize Unlimited
$directPolicyUsers = $allUsers | Where-Object {
  $_.TeamsCallingPolicy -ne $null -or
  $_.TeamsMeetingPolicy -ne $null -or
  $_.TeamsMessagingPolicy -ne $null
}

Write-Host "Users with direct policy assignments: $($directPolicyUsers.Count)"
$directPolicyUsers | Select-Object UserPrincipalName, TeamsMeetingPolicy,
  TeamsCallingPolicy, TeamsMessagingPolicy |
  Export-Csv "$env:TEMP\DirectPolicyAssignments.csv" -NoTypeInformation

# List all custom policies (non-default):
$customMeetingPolicies = Get-CsTeamsMeetingPolicy | Where-Object { $_.Identity -ne "Global" }
Write-Host "Custom meeting policies: $($customMeetingPolicies.Count)"
$customMeetingPolicies | Select-Object Identity | Format-Table

# Identify unused policies (no direct assignments, no group assignments):
$usedPolicies = ($directPolicyUsers.TeamsMeetingPolicy | Sort-Object -Unique)
$groupPolicies = (Get-CsGroupPolicyAssignment | Where-Object PolicyType -eq "TeamsMeetingPolicy").PolicyName
$allUsed = ($usedPolicies + $groupPolicies) | Sort-Object -Unique
$unused = $customMeetingPolicies | Where-Object { $_.Identity -notin $allUsed }
Write-Host "Potentially unused meeting policies: $($unused.Count)"
$unused | Select-Object Identity | Format-Table
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Teams policy evidence for a user/device escalation
.NOTES     Run from a machine with MicrosoftTeams module installed
           Requires Teams Administrator role
#>

param(
  [Parameter(Mandatory)]
  [string]$TargetUPN
)

Connect-MicrosoftTeams -ErrorAction Stop
Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All" -ErrorAction Stop

$OutputPath = "$env:TEMP\Teams-Policy-Evidence-$($TargetUPN.Split('@')[0])-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# 1. All policy assignments (effective policy with precedence)
Get-CsUserPolicyAssignment -Identity $TargetUPN |
  Export-Csv "$OutputPath\01-EffectivePolicies.csv" -NoTypeInformation

# 2. Raw user object policy properties
Get-CsOnlineUser -Identity $TargetUPN |
  Select-Object UserPrincipalName, TeamsCallingPolicy, TeamsMeetingPolicy,
    TeamsMessagingPolicy, TeamsAppSetupPolicy, TeamsUpdateManagementPolicy |
  Export-Csv "$OutputPath\02-UserPolicyProps.csv" -NoTypeInformation

# 3. Group memberships
Get-MgUserMemberOf -UserId $TargetUPN |
  Select-Object -ExpandProperty AdditionalProperties |
  ForEach-Object { [PSCustomObject]@{ DisplayName = $_["displayName"]; Id = $_["id"] } } |
  Export-Csv "$OutputPath\03-GroupMemberships.csv" -NoTypeInformation

# 4. Group policy assignments (all types)
Get-CsGroupPolicyAssignment |
  Export-Csv "$OutputPath\04-GroupPolicyAssignments.csv" -NoTypeInformation

# 5. Meeting policy settings (effective)
$meetingPolicy = (Get-CsUserPolicyAssignment -Identity $TargetUPN |
  Where-Object PolicyType -eq "TeamsMeetingPolicy").PolicyName
if ($meetingPolicy) {
  Get-CsTeamsMeetingPolicy -Identity $meetingPolicy |
    Export-Csv "$OutputPath\05-MeetingPolicyDetail.csv" -NoTypeInformation
}

# 6. Licence status
Get-MgUserLicenseDetail -UserId $TargetUPN |
  Select-Object SkuPartNumber, @{N="TeamsEnabled"; E={
    ($_.ServicePlans | Where-Object ServicePlanName -match "TEAMS").ProvisioningStatus
  }} |
  Export-Csv "$OutputPath\06-LicenceStatus.csv" -NoTypeInformation

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath.zip" -Force
Write-Host "Zipped: $OutputPath.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Get effective policies for user | `Get-CsUserPolicyAssignment -Identity <UPN>` |
| Get meeting policy detail | `Get-CsTeamsMeetingPolicy -Identity <name>` |
| Get calling policy detail | `Get-CsTeamsCallingPolicy -Identity <name>` |
| Get messaging policy detail | `Get-CsTeamsMessagingPolicy -Identity <name>` |
| List all meeting policies | `Get-CsTeamsMeetingPolicy` |
| Assign meeting policy (direct) | `Grant-CsTeamsMeetingPolicy -Identity <UPN> -PolicyName <name>` |
| Remove direct assignment | `Grant-CsTeamsMeetingPolicy -Identity <UPN> -PolicyName $null` |
| Assign policy via group | `New-CsGroupPolicyAssignment -GroupId <id> -PolicyType TeamsMeetingPolicy -PolicyName <name> -Rank 1` |
| List group policy assignments | `Get-CsGroupPolicyAssignment` |
| Remove group policy assignment | `Remove-CsGroupPolicyAssignment -GroupId <id> -PolicyType TeamsMeetingPolicy` |
| Create custom meeting policy | `New-CsTeamsMeetingPolicy -Identity <name> [params]` |
| Get all users' policy state | `Get-CsOnlineUser -ResultSize Unlimited \| Select UPN,*Policy*` |
| Restart MTR device | Teams Admin Center → Teams devices → [device] → Restart |
| Force Teams client policy refresh | Sign out and sign in to Teams client |
| Get app setup policy | `Get-CsTeamsAppSetupPolicy -Identity <name>` |
| Assign app setup policy | `Grant-CsTeamsAppSetupPolicy -Identity <UPN> -PolicyName <name>` |

---

## 🎓 Learning Pointers

- **The organizer's policy controls meeting capabilities, not the attendee's** — this is the #1 source of confusion. If a user says "I can't record this meeting," check the organizer's `AllowCloudRecording` setting, not the attendee's. The organizer's meeting policy governs what is possible in any meeting they create. An attendee with recording allowed but in a meeting created by an organizer with recording blocked — cannot record. [Teams meeting policy overview](https://learn.microsoft.com/en-us/microsoftteams/meeting-policies-overview)

- **Group policy propagation lag is real and can be 24 hours** — Entra ID group membership changes can take up to 24h to propagate to Teams policy assignment. After adding a user to a group that has a Teams policy assigned, the user may not see the policy for up to a day. For urgent changes, use a direct assignment (`Grant-CsTeams*Policy`) as an immediate fix while the group catches up. [Group policy assignment](https://learn.microsoft.com/en-us/microsoftteams/assign-policies-users-and-groups)

- **Teams Admin Center vs. Intune for MTR on Windows** — MTR on Windows is a Windows device that happens to run the MTR app. For the Windows OS layer (Windows Update, certificate deployment, local admin), Intune manages it. For the Teams experience layer (meeting policies, calling policies), Teams Admin Center and PowerShell manage it. The resource account's Teams policies control the MTR meeting experience; Intune policies control the underlying OS. Don't conflate these two management planes. [MTR management overview](https://learn.microsoft.com/en-us/microsoftteams/rooms/rooms-manage)

- **Policy names in the portal vs. PowerShell** — Some policy names shown in Teams Admin Center are display names and differ from the PowerShell `Identity` name. Always use `Get-CsTeamsMeetingPolicy` (etc.) to confirm the exact name before scripting bulk assignments. The special string `"Global"` always refers to the org-wide default.

- **Update management for Teams app ≠ Windows Update** — Teams app updates are managed via the `CsTeamsUpdateManagementPolicy` in Teams Admin Center, not via Windows Update rings in Intune. The Teams app self-updates from Microsoft's CDN independently of Windows Update. If you need to hold users on an older Teams version (e.g. for compatibility testing), use a Teams update policy ring, not Intune or WSUS. [Teams update policies](https://learn.microsoft.com/en-us/microsoftteams/teams-client-update)

- **Batch policy assignment with PowerShell is the only scalable approach** — Teams Admin Center's bulk assignment UI caps at a few hundred users and is slow. For any assignment touching more than 50 users, use PowerShell with `New-CsBatchPolicyAssignmentOperation` which runs assignments asynchronously in bulk (up to 5,000 users per batch). Check batch status with `Get-CsBatchPolicyAssignmentOperation`. [Batch policy assignment](https://learn.microsoft.com/en-us/powershell/module/teams/new-csbatchpolicyassignmentoperation)
