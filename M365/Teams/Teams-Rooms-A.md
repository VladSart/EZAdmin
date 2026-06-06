# Teams Rooms — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Microsoft Teams Rooms (MTR) on Windows (previously Skype Room Systems)
- MTR on Android (Surface Hub, Poly, Logitech, Yealink certified devices)
- Teams Rooms resource account setup and lifecycle management
- MTR licensing: Teams Rooms Basic (free) vs. Teams Rooms Pro
- Meeting join failures, audio/video issues, and calendar sync problems
- Firmware/app update management via Teams Admin Center (TAC)
- MTR on Intune: enrollment, compliance, and remote management

**Out of Scope:**
- SIP/H.323 room system interop (use Cloud Video Interop connectors separately)
- Teams Phone System PSTN calling from MTR (covered in Calling-A.md)
- Surface Hub (runs its own OS variant — separate management model)

**Assumed Prerequisites:**
- Room resource account in Exchange Online (not on-premises mailbox unless hybrid coexistence is configured)
- Teams Rooms Basic or Pro license assigned to the resource account
- MTR device on the [certified hardware list](https://learn.microsoft.com/en-us/microsoftteams/rooms/certified-hardware)
- Network: Teams Rooms endpoints must reach all Microsoft 365 IP/URL categories (Optimize + Allow)

---

## How It Works

<details><summary>Full architecture</summary>

### Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                  MTR Device (Windows or Android)            │
│                                                             │
│  ┌──────────────────┐    ┌─────────────────────────────┐   │
│  │  Teams Rooms App │    │  Windows OS / Android OS    │   │
│  │  (UWP / APK)     │    │  (separate from user layer) │   │
│  └────────┬─────────┘    └─────────────────────────────┘   │
│           │ signs in as                                     │
│           ▼                                                 │
│  ┌────────────────────────────────┐                        │
│  │  Resource Account              │                        │
│  │  (cloud-only or synced user)   │                        │
│  │  License: Teams Rooms Basic/Pro│                        │
│  └───────────────┬────────────────┘                        │
└──────────────────┼──────────────────────────────────────────┘
                   │ connects to
┌──────────────────▼──────────────────────────────────────────┐
│               Microsoft 365 Cloud                           │
│  ┌────────────────┐  ┌───────────────┐  ┌───────────────┐  │
│  │ Teams Service  │  │ Exchange Online│  │  Intune/TAC   │  │
│  │ (meetings,     │  │ (calendar,     │  │  (device mgmt │  │
│  │  calling)      │  │  room booking) │  │   & policy)   │  │
│  └────────────────┘  └───────────────┘  └───────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Resource Account Architecture

The resource account is the identity anchor for MTR:
- **Type:** Regular user account (not a shared mailbox) with mailbox enabled
- **License:** Must have a Teams Rooms license. Exchange Online Plan 2 (or equivalent) is included in Teams Rooms Pro; Teams Rooms Basic includes limited Exchange
- **Password:** Must be set to never expire (or managed carefully) — account lockout breaks all room booking
- **MFA:** Must be excluded from MFA conditional access policies for the MTR sign-in (or use device compliance exclusion)
- **Sign-in allowed:** Must be enabled (`AccountEnabled = $true`)

### Meeting Join Flow

When a meeting join button is pressed:

```
1. MTR app reads calendar item from Exchange mailbox
2. Retrieves join link (Teams meeting or interop URI)
3. Authenticates to Teams as resource account
4. Negotiates media (ICE/STUN/TURN) to Teams transport relays
5. Joins meeting — video/audio via SRTP over DTLS
6. Meeting content (screen share) via separate media stream
```

### Calendar Sync (Room Booking)

MTR displays upcoming meetings from the resource account's Exchange calendar:

- Exchange Online calendar polling: every ~30 seconds
- Meeting data: organizer, subject, join link
- Calendar Processing (`Set-CalendarProcessing`) controls auto-accept behavior and display settings
- If `AutomateProcessing = AutoAccept` is not set, room appears free even when booked

### Update Management

- **App updates:** Teams Rooms app updates are pushed via Microsoft Update / Windows Store (Windows MTR) or Google Play / TAC (Android)
- **Firmware updates:** Device OEM delivers firmware; TAC can approve/block
- **TAC Auto-update rings:** "Validation", "General" — controls when updates apply
- **MTR Pro Management portal:** provides update scheduling and health dashboards (requires Teams Rooms Pro license)

</details>

---

## Dependency Stack

```
┌──────────────────────────────────────────────────────────┐
│             Teams Meeting / Call                         │
└─────────────────────────┬────────────────────────────────┘
                          │ joined by
┌─────────────────────────▼────────────────────────────────┐
│          Teams Rooms App (MTR)                           │
│  Windows UWP app or Android APK                         │
└──────┬──────────────────┬────────────────────────────────┘
       │ auth as           │ reads calendar from
┌──────▼──────────┐  ┌────▼──────────────────────────────┐
│ Resource Account│  │  Exchange Online Mailbox           │
│ (licensed user) │  │  CalendarProcessing: AutoAccept    │
└──────┬──────────┘  └────────────────────────────────────┘
       │ requires
┌──────▼──────────────────────────────────────────────────┐
│  Teams Rooms License (Basic or Pro)                     │
│  + Exchange Online Plan 1/2 (included in Pro)           │
└──────┬──────────────────────────────────────────────────┘
       │ managed by
┌──────▼──────────────────────────────────────────────────┐
│  Teams Admin Center (TAC)                               │
│  ├── Device management                                  │
│  ├── Configuration profiles                             │
│  └── Update rings                                       │
└──────┬──────────────────────────────────────────────────┘
       │ network requirements
┌──────▼──────────────────────────────────────────────────┐
│  Network: Teams Optimize + Allow IP/URL ranges          │
│  Ports: UDP 3478-3481, TCP 443, UDP 50000-59999         │
│  Bandwidth: min 1.5 Mbps / recommended 4+ Mbps per room│
└──────────────────────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Room shows "Can't sign in" | Resource account MFA / CA policy blocking | Check CA sign-in logs for the resource account UPN |
| Calendar not updating / blank screen | `AutomateProcessing` not set to AutoAccept | `Get-CalendarProcessing -Identity <room>` |
| Meeting join button missing | Meeting doesn't have a Teams join link, or is a hybrid interop meeting | Check meeting invite; verify Teams Rooms interop policy |
| No video from room camera | Camera not selected in MTR settings, or driver/firmware issue | MTR admin settings → Devices → Camera |
| Audio echo in room | AEC (acoustic echo cancellation) disabled or room peripherals not certified | Use only certified audio devices; check MTR audio settings |
| Room showing "offline" in TAC | MTR app not running, device powered off, or network blocked | Ping device; check MTR Windows service; check firewall |
| Update failed / stuck on old version | Windows Update blocked by GPO, or Store update blocked | Check Windows Update policy; verify MTR is not domain-joined with WU restrictions |
| Resource account password expired | Password expiration policy applied to room account | `Get-MgUser -UserId <room UPN> \| Select PasswordPolicies` |
| Room booking not auto-accepted | `AutomateProcessing = None` or `AutoAccept = $false` | `Get-CalendarProcessing -Identity <room> \| Select AutomateProcessing` |
| MTR showing wrong time zone | System time zone not set, or NTP issue | Check Windows time zone settings in MTR admin mode |

---

## Validation Steps

**1. Verify resource account is licensed and sign-in enabled**
```powershell
Connect-MgGraph -Scopes "User.Read.All","Directory.Read.All"
$room = Get-MgUser -UserId "<room-UPN>" -Property "displayName,accountEnabled,usageLocation,assignedLicenses,licenseAssignmentStates"
[PSCustomObject]@{
    DisplayName     = $room.DisplayName
    AccountEnabled  = $room.AccountEnabled
    UsageLocation   = $room.UsageLocation
    LicenseCount    = $room.AssignedLicenses.Count
    LicenseErrors   = ($room.LicenseAssignmentStates | Where-Object {$_.State -eq "Error"}).Error -join ", "
} | Format-List
```
*Expected:* `AccountEnabled = True`, `LicenseCount >= 1`, no license errors.

**2. Verify Exchange mailbox and calendar processing**
```powershell
Connect-ExchangeOnline -UserPrincipalName <admin-UPN>
Get-Mailbox -Identity "<room-UPN>" | Select-Object DisplayName, RecipientTypeDetails, IsResource
Get-CalendarProcessing -Identity "<room-UPN>" | Select-Object AutomateProcessing, AllowConflicts, DeleteComments, DeleteSubject, AddOrganizerToSubject, ProcessExternalMeetingMessages
```
*Expected:* `RecipientTypeDetails = RoomMailbox`, `AutomateProcessing = AutoAccept`.
*Bad:* `AutomateProcessing = None` — booking requests won't be auto-accepted.

**3. Verify Teams Rooms license SKU**
```powershell
$roomLicenses = Get-MgUserLicenseDetail -UserId "<room-UPN>"
$roomLicenses | Select-Object SkuPartNumber, @{N="Plans";E={$_.ServicePlans.ServicePlanName -join ", "}} | Format-Table -AutoSize
```
*Expected:* `MEETING_ROOM` (Basic) or `MTR_PREM` (Pro) in SkuPartNumber.
*Bad:* Only standard user licenses (E3/E5) — wrong license for a room device.

**4. Check Conditional Access — is room account excluded from MFA?**
```powershell
# Check sign-in logs for CA failures on the room account
Connect-MgGraph -Scopes "AuditLog.Read.All"
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<room-UPN>' and status/errorCode ne 0" -Top 20 |
    Select-Object CreatedDateTime, AppDisplayName,
        @{N="CAResult";E={$_.AppliedConditionalAccessPolicies.Result -join ", "}},
        @{N="FailureReason";E={$_.Status.FailureReason}} |
    Format-Table -AutoSize
```
*Expected:* No recent failed sign-ins.
*Bad:* Failures with `CA Policy: MFA required` — room account needs CA exclusion.

**5. Check MTR device health in Teams Admin Center (TAC)**
- TAC: Teams Devices → Teams Rooms on Windows (or Android)
- Verify: Online status, App version, Firmware version, Last seen timestamp
- TAC API via Graph (requires delegated Teams admin perms):
```powershell
# Via TAC UI is recommended — no direct Graph API for MTR health in PowerShell currently
# Use: https://admin.teams.microsoft.com/devices/teamsRooms
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Room Cannot Sign In

1. Confirm account is enabled and not locked:
   ```powershell
   Get-MgUser -UserId "<room-UPN>" -Property "accountEnabled,signInActivity" | Select AccountEnabled, @{N="LastSignIn";E={$_.SignInActivity.LastSignInDateTime}}
   ```

2. Reset the room account password (if expired):
   ```powershell
   # Generate a new password and set it
   $newPassword = [System.Web.Security.Membership]::GeneratePassword(20, 5)
   Update-MgUser -UserId "<room-UPN>" -PasswordProfile @{
       Password = $newPassword
       ForceChangePasswordNextSignIn = $false
   }
   Write-Host "New password (store securely and update MTR device): $newPassword"
   ```

3. Update the password on the MTR device (requires physical access or remote admin):
   - MTR Windows: Enter admin PIN → Settings → Account → Update password
   - MTR Android: Settings → Teams Admin Settings → Account → Sign out → Sign in with new password

4. Verify no Conditional Access policy is blocking sign-in (Step 4 above).

5. If MFA is enforced by CA: exclude the resource account from the MFA CA policy, or use a named location exclusion for the device's IP.

---

### Phase 2 — Calendar Not Showing Meetings

1. Verify `AutomateProcessing`:
   ```powershell
   Set-CalendarProcessing -Identity "<room-UPN>" -AutomateProcessing AutoAccept -AllowConflicts $false -DeleteComments $false -DeleteSubject $false -AddOrganizerToSubject $false -ProcessExternalMeetingMessages $true
   ```

2. Confirm the booking policy allows the organizer's domain:
   ```powershell
   Get-CalendarProcessing -Identity "<room-UPN>" | Select-Object AllBookInPolicy, AllRequestInPolicy, BookingWindowInDays, MaximumDurationInMinutes
   ```

3. Check that the resource account mailbox is not over quota:
   ```powershell
   Get-MailboxStatistics -Identity "<room-UPN>" | Select-Object DisplayName, TotalItemSize, ItemCount, LastLogonTime
   ```

4. If meetings still don't appear: force a calendar sync on the MTR device by restarting the Teams Rooms app (admin mode → More → Restart).

---

### Phase 3 — MTR Offline in TAC

1. Verify physical device is powered on and on the network.
2. Check Teams Rooms service is running (Windows MTR):
   - Admin mode PIN → Windows Start → Task Manager → look for `Teams` process
   - Or via Intune remote: check device compliance status
3. Verify network connectivity to Teams endpoints:
   ```powershell
   # Run from MTR device (admin mode → open PowerShell)
   Test-NetConnection -ComputerName "teams.microsoft.com" -Port 443
   Test-NetConnection -ComputerName "outlook.office365.com" -Port 443
   Resolve-DnsName "login.microsoftonline.com"
   ```
4. Restart Teams Rooms app: MTR admin menu → Restart.
5. If device shows offline for >24 hours after restart: re-image or factory reset and re-enroll.

---

### Phase 4 — Update Management Issues

**MTR app stuck on old version (Windows):**
1. In TAC: Teams Devices → select device → Update software
2. Or on device: admin mode → Settings → Windows Update → Check for updates
3. Verify Windows Update is not blocked by GPO:
   ```powershell
   # Run on MTR device
   Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue
   ```
   If `DisableWindowsUpdateAccess = 1` or `WUServer` is set to an internal WSUS with no MTR packages — this blocks updates.

**MTR domain-join warning:** Microsoft strongly recommends **not** domain-joining MTR devices. Domain policies (WU, security baselines, AppLocker) frequently break the MTR app. MTR devices should be Intune-enrolled only (Autopilot or manual enrollment with the MTR-specific enrollment profile).

---

## Remediation Playbooks

<details><summary>Playbook 1 — Provision a New Teams Room Resource Account</summary>

**Goal:** Create a fully configured resource account for a new MTR deployment.

```powershell
<#
.SYNOPSIS  Provision Teams Rooms resource account end-to-end
.NOTES     Requires: Exchange Online Admin, Teams Admin, User Admin
           Run from Exchange Online PowerShell + MgGraph
#>

Connect-ExchangeOnline
Connect-MgGraph -Scopes "User.ReadWrite.All","Directory.ReadWrite.All"

$roomName    = "ConfRoom-A101"
$roomUPN     = "conf-a101@contoso.com"
$roomDisplay = "Conference Room A101"
$roomAlias   = "conf-a101"
$location    = "London"
$skuId       = "<Teams-Rooms-Pro-SkuId>"  # Get from Get-MgSubscribedSku

# Step 1: Create room mailbox in Exchange Online
New-Mailbox -Name $roomDisplay -Room -PrimarySmtpAddress $roomUPN -RoomCapacity 10 -Location $location
Write-Host "Room mailbox created" -ForegroundColor Green

# Step 2: Configure calendar processing
Set-CalendarProcessing -Identity $roomUPN `
    -AutomateProcessing AutoAccept `
    -AllowConflicts $false `
    -DeleteComments $false `
    -DeleteSubject $false `
    -AddOrganizerToSubject $false `
    -ProcessExternalMeetingMessages $true `
    -RemovePrivateProperty $false
Write-Host "Calendar processing configured" -ForegroundColor Green

# Step 3: Enable sign-in on the resource account
$user = Get-MgUser -UserId $roomUPN
Update-MgUser -UserId $user.Id -AccountEnabled $true -UsageLocation "GB" -PasswordProfile @{
    Password = "<StrongPassword>"
    ForceChangePasswordNextSignIn = $false
}
Write-Host "Account enabled" -ForegroundColor Green

# Step 4: Assign password to never expire
Update-MgUser -UserId $user.Id -PasswordPolicies "DisablePasswordExpiration"

# Step 5: Assign Teams Rooms Pro license
Set-MgUserLicense -UserId $user.Id -AddLicenses @(@{SkuId = $skuId}) -RemoveLicenses @()
Write-Host "License assigned" -ForegroundColor Green

# Step 6: (Optional) Add to CA exclusion group for MFA bypass
# Add-MgGroupMember -GroupId "<CA-Exclusion-Group-Id>" -DirectoryObjectId $user.Id

Write-Host "`nResource account provisioned: $roomUPN" -ForegroundColor Cyan
Write-Host "Sign in to the MTR device with: $roomUPN / <StrongPassword>"
```

</details>

<details><summary>Playbook 2 — Bulk Audit All Teams Rooms Accounts</summary>

**Goal:** Health check across all room accounts — license, calendar, password expiry.

```powershell
Connect-ExchangeOnline
Connect-MgGraph -Scopes "User.Read.All"

# Get all room mailboxes
$rooms = Get-Mailbox -RecipientTypeDetails RoomMailbox -ResultSize Unlimited

$report = foreach ($room in $rooms) {
    $user = Get-MgUser -UserId $room.PrimarySmtpAddress -Property "accountEnabled,passwordPolicies,licenseAssignmentStates,usageLocation" -ErrorAction SilentlyContinue
    $calProc = Get-CalendarProcessing -Identity $room.PrimarySmtpAddress -ErrorAction SilentlyContinue
    $licErrors = ($user.LicenseAssignmentStates | Where-Object {$_.State -eq "Error"}).Error -join ", "
    $licensed = $user.LicenseAssignmentStates | Where-Object {$_.State -eq "Active"} | Measure-Object | Select-Object -ExpandProperty Count

    [PSCustomObject]@{
        DisplayName       = $room.DisplayName
        UPN               = $room.PrimarySmtpAddress
        AccountEnabled    = $user.AccountEnabled
        UsageLocation     = $user.UsageLocation
        PasswordExpires   = -not ($user.PasswordPolicies -match "DisablePasswordExpiration")
        ActiveLicenses    = $licensed
        LicenseErrors     = $licErrors
        AutoAccept        = ($calProc.AutomateProcessing -eq "AutoAccept")
        ExternalMeetings  = $calProc.ProcessExternalMeetingMessages
    }
}

$report | Export-Csv -Path "C:\Temp\TeamsRooms-Audit.csv" -NoTypeInformation
Write-Host "Audit written to C:\Temp\TeamsRooms-Audit.csv"
$report | Format-Table -AutoSize
```

</details>

<details><summary>Playbook 3 — Configure MTR via Intune (XML Configuration Profile)</summary>

**Goal:** Push a Teams Rooms XML configuration profile via Intune to control MTR app settings at scale.

**Steps:**
1. Create a configuration XML file (e.g., `SkypeSettings.xml`):
   ```xml
   <SkypeSettings>
     <AutoScreenShare>true</AutoScreenShare>
     <HideMeetingName>false</HideMeetingName>
     <UserAccount>
       <SkypeSignInAddress>conf-a101@contoso.com</SkypeSignInAddress>
       <ExchangeAddress>conf-a101@contoso.com</ExchangeAddress>
     </UserAccount>
     <TeamsMeetingsEnabled>true</TeamsMeetingsEnabled>
     <SFBMeetingEnabled>false</SFBMeetingEnabled>
   </SkypeSettings>
   ```

2. Deploy via Intune → Devices → Scripts → Windows PowerShell script:
   ```powershell
   # Script to place SkypeSettings.xml in the correct location
   $xmlContent = @'
   <SkypeSettings>
     <AutoScreenShare>true</AutoScreenShare>
     <TeamsMeetingsEnabled>true</TeamsMeetingsEnabled>
   </SkypeSettings>
   '@
   $xmlPath = "C:\Users\Skype\AppData\Local\Packages\Microsoft.SkypeRoomSystem_8wekyb3d8bbwe\LocalState\SkypeSettings.xml"
   [System.IO.File]::WriteAllText($xmlPath, $xmlContent)
   ```

3. Assign to the MTR device group in Intune.

**Reference:** [Teams Rooms XML configuration file](https://learn.microsoft.com/en-us/microsoftteams/rooms/xml-config-file)

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Teams Rooms evidence collector — resource account + health
.NOTES       Run as: Exchange Admin + Teams Admin + User Admin
             Output: C:\Temp\TeamsRooms-Evidence-<timestamp>.txt
#>

Connect-ExchangeOnline
Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All"

$roomUPN   = Read-Host "Enter Room UPN"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile   = "C:\Temp\TeamsRooms-Evidence-$timestamp.txt"

"=== Teams Rooms Evidence Pack - $timestamp ===" | Out-File $outFile
"Room UPN: $roomUPN" | Out-File $outFile -Append

"--- Mailbox Details ---" | Out-File $outFile -Append
Get-Mailbox -Identity $roomUPN | Select-Object DisplayName, RecipientTypeDetails, IsResource, PrimarySmtpAddress |
    Out-File $outFile -Append

"--- Calendar Processing ---" | Out-File $outFile -Append
Get-CalendarProcessing -Identity $roomUPN | Format-List | Out-File $outFile -Append

"--- Mailbox Statistics ---" | Out-File $outFile -Append
Get-MailboxStatistics -Identity $roomUPN | Select-Object TotalItemSize, ItemCount, LastLogonTime |
    Out-File $outFile -Append

"--- Entra User Account ---" | Out-File $outFile -Append
Get-MgUser -UserId $roomUPN -Property "accountEnabled,passwordPolicies,usageLocation,licenseAssignmentStates,signInActivity" |
    Select-Object AccountEnabled, PasswordPolicies, UsageLocation,
        @{N="LastSignIn";E={$_.SignInActivity.LastSignInDateTime}},
        @{N="LicenseState";E={$_.LicenseAssignmentStates.State -join ", "}} |
    Out-File $outFile -Append

"--- Recent Sign-In Errors ---" | Out-File $outFile -Append
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$roomUPN' and status/errorCode ne 0" -Top 20 |
    Select-Object CreatedDateTime, AppDisplayName,
        @{N="Error";E={$_.Status.FailureReason}},
        @{N="CA";E={$_.AppliedConditionalAccessPolicies.DisplayName -join ", "}} |
    Format-Table | Out-File $outFile -Append

Write-Host "Evidence written to: $outFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Get room mailbox details | `Get-Mailbox -Identity <room-UPN> \| Select RecipientTypeDetails, IsResource` |
| Get calendar processing | `Get-CalendarProcessing -Identity <room-UPN>` |
| Set auto-accept | `Set-CalendarProcessing -Identity <room-UPN> -AutomateProcessing AutoAccept` |
| Check account enabled | `Get-MgUser -UserId <room-UPN> -Property accountEnabled \| Select AccountEnabled` |
| Enable account | `Update-MgUser -UserId <room-UPN> -AccountEnabled $true` |
| Set password never expires | `Update-MgUser -UserId <room-UPN> -PasswordPolicies "DisablePasswordExpiration"` |
| Check license | `Get-MgUserLicenseDetail -UserId <room-UPN> \| Select SkuPartNumber` |
| Get all room mailboxes | `Get-Mailbox -RecipientTypeDetails RoomMailbox -ResultSize Unlimited \| Select DisplayName, PrimarySmtpAddress` |
| Check sign-in failures | `Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>' and status/errorCode ne 0" -Top 20` |
| Reset room password | `Update-MgUser -UserId <room-UPN> -PasswordProfile @{Password="<new>"; ForceChangePasswordNextSignIn=$false}` |
| Check mailbox quota | `Get-MailboxStatistics -Identity <room-UPN> \| Select TotalItemSize, ItemCount` |
| Check CA exclusion group | `Get-MgGroupMember -GroupId <CA-exclusion-group-id> \| Where {$_.Id -eq (Get-MgUser -UserId <room-UPN>).Id}` |

---

## 🎓 Learning Pointers

- **Resource accounts are real users, not shared mailboxes.** A common mistake is creating a shared mailbox for a Teams Room. MTR requires a regular user mailbox with the `IsResource` flag set (Room mailbox type). Shared mailboxes cannot sign in to Teams, which is why the room device cannot authenticate. Always use `New-Mailbox -Room` in Exchange Online, not `New-SharedMailbox`.

- **Never domain-join a Teams Rooms device.** Microsoft explicitly states MTR devices should not be domain-joined. Domain GPOs — especially security baselines, AppLocker policies, and WSUS configurations — routinely break the MTR UWP app or prevent updates. Use Intune-only management with an Autopilot profile targeting the MTR device. Reference: [Microsoft Teams Rooms deployment best practices](https://learn.microsoft.com/en-us/microsoftteams/rooms/rooms-prepare)

- **Conditional Access must explicitly exclude or accommodate the room account.** MTR signs in as the resource account non-interactively. Any CA policy requiring MFA, compliant device, or approved app will block sign-in unless you create a named location exclusion (for the room's IP) or exclude the account from MFA-requiring policies. Build a dedicated CA exclusion group for room accounts and document it in your CA policy naming.

- **Teams Rooms Basic vs. Pro determines your management surface.** Basic (free, up to 25 rooms) gives calendar display and meeting join but no TAC health monitoring, no intelligent speaker, no advanced analytics. Pro gives the full management portal, AI-driven room intelligence, and detailed analytics. For any MSP managing rooms at scale, Pro is necessary for remote troubleshooting visibility.

- **Calendar processing settings are the most overlooked configuration.** `AutomateProcessing = None` is the default for new room mailboxes — it means no auto-accept. Rooms will appear available in Outlook but meetings won't be confirmed or shown on the MTR display. Always run `Set-CalendarProcessing` with `AutomateProcessing AutoAccept` as part of provisioning. Reference: [Set-CalendarProcessing](https://learn.microsoft.com/en-us/powershell/module/exchange/set-calendarprocessing)

- **MTR update failures are usually a Windows Update policy problem.** MTR on Windows uses Windows Store and Windows Update for app and OS updates. If your tenant has a WSUS GPO or a WU baseline that redirects update traffic, MTR devices won't receive app updates and will fall out of support. Either scope those GPOs to exclude the MTR OU, or use Intune Update Rings and Block the WSUS GPO inheritance for the MTR device group.
