# Microsoft Teams — Agent Instructions

## What's in this folder
Runbooks and scripts for Microsoft Teams issues faced by MSP L2/L3 engineers. Covers calling/PSTN problems, device policies, meeting configuration, and Teams-specific governance topics (guest access, channel policies, retention).

## Before responding, also check
- `M365/_AGENT.md` — M365-wide triage starting points and licensing checks
- `EntraID/` — if Teams sign-in is failing (token/conditional access)
- `Security/ConditionalAccess/` — if devices are blocked from Teams
- `M365/Exchange/` — if calendar integration or meeting invites are broken
- `Intune/` — if Teams app deployment or update issues on managed devices

## Folder contents

| File | What it covers |
|------|---------------|
| `Calling-B.md` | Teams PSTN calling issues — no dial tone, call quality, direct routing, Operator Connect |
| `Calling-A.md` | Teams calling deep dive — voice routing architecture, dial plans, PSTN gateway/Operator Connect internals |
| `Device-Policies-B.md` | Teams device policies — meeting room devices, IP phones, update rings, Teams Rooms |
| `Device-Policies-A.md` | Teams device policy deep dive — policy architecture, precedence, direct vs. group assignment, MTR/IP phone management planes |
| `Meeting-Policies-B.md` | Meeting policy hotfix — recording/lobby/screen-share restrictions not applying |
| `Meeting-Policies-A.md` | Meeting policy deep dive — policy sync, group assignment rank conflicts, organizer-vs-attendee precedence |
| `Teams-Rooms-A.md` | Teams Rooms (MTR) deep dive — resource account model, licensing, device management plane |
| `Teams-Rooms-B.md` | Teams Rooms hotfix — device not signing in, offline, wrong meeting policy |
| `Scripts/Get-TeamsCallQuality.ps1` | Call quality dashboard (CQD-style) for a user or fleet |
| `Scripts/Get-TeamsMeetingPolicyAudit.ps1` | Meeting policy + group assignment rank-conflict audit, optional per-user effective policy resolution |
| `Scripts/Get-TeamsRoomDeviceHealth.ps1` | Teams Rooms resource account and licensing health fleet report |
| `Scripts/Get-TeamsDevicePolicyAudit.ps1` | Device account health, update/IP-phone policy assignment, and calendar auto-accept audit for resource accounts |

## Common entry points

- "User can't make calls / no dial tone" → `Calling-B.md` Triage — check license, number assignment, dial plan
- "Poor call quality / choppy audio" → `Calling-B.md` Fix 3 (QoS / network)
- "Teams Room device not signing in" → `Device-Policies-B.md` Fix 1
- "IP phone showing as offline" → `Device-Policies-B.md` Triage
- "Teams device won't update firmware" → `Device-Policies-B.md` Fix 4
- "Room shows wrong meeting info / calendar not auto-accepting" → `Device-Policies-B.md` Fix 6, or `Scripts/Get-TeamsDevicePolicyAudit.ps1` for a fleet-wide check
- "Can't record / different users get different meeting features" → `Meeting-Policies-B.md`, use `Scripts/Get-TeamsMeetingPolicyAudit.ps1` for rank-conflict detection
- "User can't join meetings" → check `EntraID/` for auth, then CA policy
- "Teams not syncing calendar" → `M365/Exchange/` — EWS and Autodiscover
- "Guest can't access team" → check Teams admin centre → Guest access settings
- "Can't record meetings" → check Teams meeting policy (AllowCloudRecording)

## Key diagnostic commands

```powershell
# Connect to Teams PowerShell
Connect-MicrosoftTeams

# Check user's Teams calling configuration
Get-CsOnlineUser -Identity <UPN> | Select-Object DisplayName, LineUri, EnterpriseVoiceEnabled, HostedVoiceMail, TeamsUpgradeMode, OnlineVoiceRoutingPolicy, DialPlan

# Check assigned calling license
Get-MgUserLicenseDetail -UserId <UPN> | Select-Object SkuPartNumber

# List all Teams policies assigned to user
Get-CsUserPolicyAssignment -Identity <UPN> | Format-Table PolicyType, PolicyName

# Check Teams Rooms / device accounts
Get-CsOnlineUser -Filter {InterpretedUserType -eq "SfbOnpremUser" -or InterpretedUserType -eq "TeamsOnlyUser"} | Where-Object {$_.DisplayName -like "*room*"} | Select-Object DisplayName, LineUri, TeamsUpgradeMode

# Test PSTN connectivity (requires Teams admin)
# Get-CsOnlinePstnUsage | Select-Object -ExpandProperty Usage
# Get-CsVoiceRoute | Select-Object Name, NumberPattern, PstnGatewayList | Format-Table -AutoSize
```

## Key dependency chain

```
Entra ID identity (not blocked, MFA working)
    └── Teams license assigned (Teams Essentials / M365 E3 / Teams Phone add-on)
        └── Teams upgrade mode (TeamsOnly for full features)
            └── Teams meeting policy (recording, transcription, guest join)
                └── Teams app setup policy (pinned apps, side-loading)
                    └── Calling policy (PSTN calling enabled)
                        └── Voice routing policy (direct routing or Operator Connect)
                            └── Dial plan (E.164 normalization)
                                └── Phone number assigned (LineUri)
                                    └── PSTN CALLING FUNCTIONAL
```

## Response format reminder (always 3 layers)

1. **Triage** — identify the failure layer (license? policy? number? routing?) in 60 seconds
2. **Fix** — targeted PowerShell remediation, least-privilege changes
3. **Validate** — confirm with test call or policy re-read before closing
