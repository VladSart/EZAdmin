# Teams Rooms Device Management — Hotfix Runbook (Mode B: Ops)
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

Run these as admin or via Teams Admin Center / Graph. First three are portal-based, last two are PowerShell.

```powershell
# 1. Check Teams Rooms device sign-in status via Teams Admin Center
# Portal: https://admin.teams.microsoft.com > Devices > Teams Rooms

# 2. Check the resource account license
Connect-MgGraph -Scopes "User.Read.All", "Directory.Read.All"
$acct = Get-MgUser -Filter "displayName eq '<ROOM-DISPLAY-NAME>'" -Property DisplayName,UserPrincipalName,AssignedLicenses,AccountEnabled
$acct | Select-Object DisplayName, UserPrincipalName, AccountEnabled
($acct.AssignedLicenses | ForEach-Object { $_.SkuId }) | ForEach-Object {
    Get-MgSubscribedSku | Where-Object { $_.SkuId -eq $_ } | Select-Object SkuPartNumber
}

# 3. Check Exchange mailbox (room must have calendar processing enabled)
Connect-ExchangeOnline
Get-CalendarProcessing -Identity "<room@domain.com>" | 
    Select-Object Identity, AutomateProcessing, AllowConflicts, BookingWindowInDays

# 4. Check Intune enrollment state for the device (if managed via Intune)
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "contains(deviceName, '<ROOM-NAME>')" |
    Select-Object DeviceName, OperatingSystem, ComplianceState, EnrolledDateTime, LastSyncDateTime

# 5. Check Teams Room application version and health status
# Via Graph (Teams devices API)
Connect-MgGraph -Scopes "TeamworkDevice.Read.All"
Get-MgTeamworkDevice | Where-Object { $_.DisplayName -match "<ROOM-NAME>" } |
    Select-Object DisplayName, DeviceType, HealthStatus, CurrentUser | Format-Table
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| AccountEnabled = False | Resource account disabled | → Fix 1 |
| No Teams Rooms license assigned | Device can't sign in | → Fix 2 |
| AutomateProcessing ≠ AutoAccept | Meeting invites not processing | → Fix 3 |
| ComplianceState = Noncompliant | Intune policy blocking app | → Fix 4 |
| HealthStatus = Critical / Unhealthy | Device hardware or app issue | → Fix 5 |
| Device offline in TAC | Network or device restart needed | → Fix 5 |

---
## Dependency Cascade

<details><summary>What must be true for Teams Rooms to work</summary>

```
Microsoft Teams Service (Cloud)
    └── Teams Rooms Resource Account (Entra ID)
          ├── Account enabled (not blocked)
          ├── License: Teams Rooms Basic (free) OR Teams Rooms Pro
          ├── Password set (no expiry, or known rotation schedule)
          └── Exchange Online Mailbox (room type)
                ├── CalendarProcessing: AutomateProcessing = AutoAccept
                ├── Room capacity and booking window configured
                └── Meeting policies allowing Teams meeting links
                      └── Teams Meeting Policy assigned to resource account
                            └── Teams Rooms Device (physical hardware)
                                  ├── Signed in as resource account
                                  ├── App version current (Teams Rooms for Windows/Android)
                                  ├── Network: HTTPS :443, UDP for media (3478-3481)
                                  ├── Firewall bypass for *.teams.microsoft.com, *.skype.com
                                  └── (Optional) Intune enrolled for config/compliance
```

</details>

---
## Diagnosis & Validation Flow

**1. Verify resource account exists and is enabled**
```powershell
Connect-MgGraph -Scopes "User.Read.All"
Get-MgUser -Filter "userPrincipalName eq '<room@domain.com>'" |
    Select-Object DisplayName, UserPrincipalName, AccountEnabled, UserType
```
Expected: AccountEnabled = True, UserType = Member.

**2. Verify license includes Teams Rooms capability**
```powershell
# Teams Rooms Basic = SKU "Microsoft_Teams_Rooms_Basic"
# Teams Rooms Pro  = SKU "Microsoft_Teams_Rooms_Pro"
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "Teams_Rooms" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N="Available";E={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}}
```

**3. Validate calendar processing**
```powershell
Get-CalendarProcessing -Identity "<room@domain.com>" | Format-List AutomateProcessing, AllowConflicts, BookingWindowInDays, MaximumDurationInMinutes, DeleteComments, AddOrganizerToSubject
```
Expected: AutomateProcessing = AutoAccept.

**4. Check Teams meeting policy on resource account**
```powershell
Get-CsOnlineUser -Identity "<room@domain.com>" | 
    Select-Object DisplayName, TeamsMeetingPolicy, TeamsCallingPolicy, AssignedPlan
```

**5. Test network connectivity from device network segment**
Required for Teams media:
- TCP 443: `*.teams.microsoft.com`, `*.skype.com`, `login.microsoftonline.com`
- UDP 3478–3481: Teams media relay (STUN/TURN)
- If behind proxy: Teams Rooms should bypass proxy for media

**6. Check device health in Teams Admin Center**
Portal: `https://admin.teams.microsoft.com` > Devices > Teams Rooms on Windows (or Android)
- Health status, last activity, peripheral status (camera, microphone, display)
- Software version vs. latest available

---
## Common Fix Paths

<details><summary>Fix 1 — Re-enable blocked resource account</summary>

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All"

# Find and enable the account
$user = Get-MgUser -Filter "userPrincipalName eq '<room@domain.com>'"
Update-MgUser -UserId $user.Id -AccountEnabled $true

# Verify
Get-MgUser -UserId $user.Id -Property AccountEnabled | Select-Object AccountEnabled
```

Also check if a Conditional Access policy is blocking the account:
- Entra portal > Sign-in logs > filter by the resource account UPN > look for CA policy failure
- Most Rooms accounts should be excluded from MFA CA policies (device can't do MFA interactively)

**Rollback:**
```powershell
Update-MgUser -UserId $user.Id -AccountEnabled $false
```

</details>

<details><summary>Fix 2 — Assign Teams Rooms license</summary>

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.Read.All"

# Get the Teams Rooms Pro SKU ID
$sku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq "Microsoft_Teams_Rooms_Pro" }

# Assign license
$licenseParams = @{
    AddLicenses = @(@{ SkuId = $sku.SkuId })
    RemoveLicenses = @()
}
Set-MgUserLicense -UserId "<room@domain.com>" -BodyParameter $licenseParams

# Confirm
(Get-MgUser -UserId "<room@domain.com>" -Property AssignedLicenses).AssignedLicenses |
    ForEach-Object { Get-MgSubscribedSku | Where-Object { $_.SkuId -eq $_.SkuId } | Select-Object SkuPartNumber }
```

Note: Teams Rooms Basic (free, up to 25 rooms) is sufficient for basic join/present. Teams Rooms Pro required for advanced management, AI features, and detailed analytics.

**Rollback:**
```powershell
$licenseParams = @{
    AddLicenses = @()
    RemoveLicenses = @($sku.SkuId)
}
Set-MgUserLicense -UserId "<room@domain.com>" -BodyParameter $licenseParams
```

</details>

<details><summary>Fix 3 — Fix calendar processing (AutoAccept not set)</summary>

```powershell
Connect-ExchangeOnline

# Set AutoAccept and recommended room settings
Set-CalendarProcessing -Identity "<room@domain.com>" `
    -AutomateProcessing AutoAccept `
    -AllowConflicts $false `
    -DeleteComments $false `
    -DeleteSubject $false `
    -AddOrganizerToSubject $false `
    -RemovePrivateProperty $false `
    -BookingWindowInDays 180 `
    -MaximumDurationInMinutes 1440

# Verify
Get-CalendarProcessing -Identity "<room@domain.com>" | 
    Select-Object AutomateProcessing, AllowConflicts, BookingWindowInDays
```

**Rollback:**
```powershell
Set-CalendarProcessing -Identity "<room@domain.com>" -AutomateProcessing None
```

</details>

<details><summary>Fix 4 — Exclude room account from blocking Conditional Access policy</summary>

Resource accounts cannot complete MFA prompts interactively. They must be excluded from MFA/compliant-device CA policies, or placed in a dedicated CA policy with Device Compliance exemption.

```powershell
# Identify which CA policy is blocking — check sign-in logs
Connect-MgGraph -Scopes "AuditLog.Read.All"
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<room@domain.com>' and status/errorCode ne 0" -Top 20 |
    Select-Object CreatedDateTime, AppDisplayName, Status, ConditionalAccessStatus,
    @{N="CAPolicies";E={$_.AppliedConditionalAccessPolicies.DisplayName -join "; "}} | Format-Table -Wrap
```

In Entra admin center: Identity > Protection > Conditional Access > select the blocking policy > Exclude the room account UPN or a dedicated "Teams Rooms Accounts" group.

**Best practice:** Create a dedicated Entra ID group for all room resource accounts. Exclude this group from MFA CA policies. Apply a separate CA policy to this group requiring only sign-in from trusted network locations.

</details>

<details><summary>Fix 5 — Restart/recover unresponsive Teams Rooms device</summary>

**Via Teams Admin Center (remote restart):**
Portal: admin.teams.microsoft.com > Devices > Teams Rooms > select device > Actions > Restart

**Via PowerShell (if device is Intune-managed):**
```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All"
$device = Get-MgDeviceManagementManagedDevice -Filter "contains(deviceName, '<ROOM-NAME>')"
Invoke-MgDeviceManagementManagedDeviceRebootNow -ManagedDeviceId $device.Id
```

**Force app update via Teams Admin Center:**
admin.teams.microsoft.com > Devices > Teams Rooms > select device > Update > Software

**On-device recovery (physical access required):**
1. Connect keyboard (CTRL+ALT+DEL on Windows-based systems)
2. Sign out of Teams Rooms app
3. Sign back in with resource account credentials
4. If app crash-looping: Settings (gear icon) > Reset device (last resort — will re-enroll)

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Teams Rooms Device
========================================
Date/Time (UTC)       : [                    ]
Reported by           : [                    ]
Room name             : [                    ]
Resource account UPN  : [                    ]
Device make/model     : [                    ]
App platform          : [ Windows / Android / Surface Hub ]
Teams Rooms app ver   : [                    ]

Symptoms
--------
[ ] Device shows offline in Teams Admin Center
[ ] Can't join meetings
[ ] Calendar not showing meetings
[ ] Sign-in failure / account error
[ ] Audio/video/display issues
[ ] Other: [                                ]

Triage results
--------------
Resource account enabled      : [ Yes / No ]
License assigned              : [ Teams Rooms Basic / Pro / None ]
CalendarProcessing setting    : [ AutoAccept / None / Other ]
CA policy blocking            : [ Yes / No / Unknown ]
Intune compliance state       : [                    ]
TAC health status             : [ Healthy / Unhealthy / Offline ]
Last activity in TAC          : [                    ]

Evidence collected
------------------
[ ] Sign-in log export for resource account (last 7 days)
[ ] Get-CalendarProcessing output
[ ] Get-CsOnlineUser output for resource account
[ ] TAC device health screenshot
[ ] Intune device details screenshot (if enrolled)

Escalation path: Microsoft 365 admin centre > Support > Teams Rooms issue.
Include Teams diagnostic ID if available (in-meeting: Alt+Shift+D).
```

---
## 🎓 Learning Pointers

- **Resource accounts are special — not regular user accounts** — they should have a room mailbox type, no interactive login license, Teams Rooms license, and be excluded from MFA CA policies. Getting any of these wrong breaks the sign-in. [MS Docs: Create resource accounts for Teams Rooms](https://learn.microsoft.com/en-us/microsoftteams/rooms/create-resource-account)
- **Teams Rooms Basic vs Pro — know the difference** — Basic is free (up to 25 rooms) but has no advanced management, no AI features, and limited TAC analytics. Pro unlocks remote management, Teams Rooms Intelligent Speaker, companion mode, and front-row layout. [MS Docs: Teams Rooms licenses](https://learn.microsoft.com/en-us/microsoftteams/rooms/rooms-licensing)
- **AutoAccept must be set via Exchange, not Entra** — the calendar processing setting (`Set-CalendarProcessing`) is an Exchange Online concept. It controls whether the room auto-accepts meeting invites. Forgetting this step is the #1 cause of "room calendar not showing meetings" issues.
- **Media quality requires UDP** — Teams Rooms needs UDP 3478–3481 open outbound for media relay. If forced through a proxy or firewall that only allows TCP 443, you'll get poor call quality or dropped video. Use Quality of Service markings for media traffic where possible. [MS Docs: Network requirements for Teams](https://learn.microsoft.com/en-us/microsoftteams/prepare-network)
- **Teams Admin Center is your health dashboard** — admin.teams.microsoft.com > Devices > Teams Rooms gives you per-device health, peripheral status (camera online?), app version, and the ability to remotely restart or push updates. Bookmark this for any room support call.
- **Intune + Teams Rooms = optional but recommended** — enrolling room devices in Intune lets you enforce configuration (kiosk mode, Windows Update rings, certificate deployment) and remotely wipe/reset if compromised. Use a dedicated Intune enrollment profile for room devices with AutopilotWhiteGlove for pre-provisioning.
