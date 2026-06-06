# Teams Device Policies — Hotfix Runbook (Mode B: Ops)
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

```powershell
# Connect to Teams
Connect-MicrosoftTeams

# 1. List all Teams-managed devices and their status
Get-CsTeamsDeviceConfigurationPolicy | Select-Object Identity | Format-Table

# 2. Get a specific room account's configuration
Get-CsOnlineUser -Identity <RoomAccountUPN> | Select-Object DisplayName, LineUri, EnterpriseVoiceEnabled, AccountEnabled, TeamsUpgradeMode | Format-List

# 3. Check Teams Room license
Get-MgUserLicenseDetail -UserId <RoomAccountUPN> | Select-Object SkuPartNumber

# 4. List IP phone policies
Get-CsTeamsIPPhonePolicy | Select-Object Identity, AllowHotDesking, HotDeskingIdleTimeoutInMinutes, SignInMode | Format-Table -AutoSize

# 5. Check Teams update policies (controls firmware update rings)
Get-CsTeamsUpdateManagementPolicy | Select-Object Identity, AllowManagedUpdates, UpdateDayOfWeek, UpdateTimeOfDay, UpdateWindowEndTime | Format-Table -AutoSize
```

**Interpretation Table:**

| Symptom | Likely Cause | Go To |
|---------|-------------|-------|
| Teams Room can't sign in | Account not licensed / password expired | Fix 1 |
| Device shows "offline" in TAC | Network issue or device firmware/app crash | Fix 2 |
| IP phone stuck on sign-in screen | IP phone policy or resource account issue | Fix 3 |
| Device won't update firmware | Update policy blocking auto-update | Fix 4 |
| Hot-desking not working on IP phone | Hot-desking not enabled in IP phone policy | Fix 5 |
| Room shows wrong timezone or meeting info | Room account calendar misconfigured | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for Teams Room devices to work</summary>

```
Resource account created in Entra ID (not a user account)
    └── Teams Rooms Pro / Teams Rooms Basic license assigned
        └── Teams Phone license (if calling enabled)
            └── Account not blocked, password not expired, MFA disabled (service account)
                └── Exchange Online mailbox configured (accept meeting invites)
                    └── Calendar processing configured (auto-accept)
                        └── Device enrolled and signed into resource account
                            └── Device connected to network (HTTPS to *.teams.microsoft.com)
                                └── Teams device configuration policy assigned
                                    └── ROOM FUNCTIONAL
```
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Verify resource account health**
```powershell
# Check account status in Entra ID
Get-MgUser -UserId <RoomAccountUPN> | Select-Object DisplayName, AccountEnabled, UserPrincipalName

# Check last sign-in (requires AuditLog.Read.All)
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<RoomAccountUPN>'" -Top 5 | Select-Object CreatedDateTime, Status, AppDisplayName | Format-Table
```
Expected: `AccountEnabled: True`, no failed sign-ins.

**Step 2 — Verify Teams Rooms license**
```powershell
Get-MgUserLicenseDetail -UserId <RoomAccountUPN> | Select-Object SkuPartNumber
```
Expected: `Microsoft_Teams_Rooms_Pro` or `Microsoft_Teams_Rooms_Basic`.

**Step 3 — Verify Exchange calendar processing**
```powershell
# Check the room mailbox calendar auto-accept settings
Get-CalendarProcessing -Identity <RoomAccountUPN> | Select-Object AutomateProcessing, AllowConflicts, DeleteNonCalendarItems, RemovePrivateProperty | Format-List
```
Expected: `AutomateProcessing: AutoAccept`.

**Step 4 — Check device in Teams Admin Centre**
- Teams Admin Centre → Devices → Rooms on Teams / IP Phones
- Check device health, last seen timestamp, firmware version
- Look for "Needs attention" status

**Step 5 — Check network connectivity from the device**
Required endpoints for Teams Rooms:
- `*.teams.microsoft.com` (TCP 443)
- `*.skype.com` (TCP 443)
- `login.microsoftonline.com` (TCP 443)
- `*.sfbassets.com` (TCP 443, for firmware updates)

---
## Common Fix Paths

<details><summary>Fix 1 — Fix Teams Room account sign-in failure</summary>

**Use when:** Teams Room device shows sign-in error or is stuck on the sign-in screen (room account, not user account).

```powershell
# Step 1: Confirm account exists and is enabled
Get-MgUser -UserId <RoomAccountUPN> | Select-Object AccountEnabled, UserPrincipalName

# Step 2: Reset the account password (resource accounts should have non-expiring passwords)
# Set password to non-expiring:
Update-MgUser -UserId <RoomAccountUPN> -PasswordPolicies "DisablePasswordExpiration"

# Step 3: Check if MFA is enforced (breaks automated sign-in)
# Review Conditional Access policies — resource accounts should be excluded from MFA CA policies
# Or use a dedicated CA policy for service accounts with named location + compliant device as conditions

# Step 4: Check if account is licensed correctly
Get-MgUserLicenseDetail -UserId <RoomAccountUPN> | Select-Object SkuPartNumber

# Step 5: Force device sign-out and re-sign-in from TAC
# Teams Admin Centre → Devices → select device → Actions → Sign out
# Then sign back in from the device using the resource account credentials

# Step 6: Verify UPN matches accepted domain
Get-MgUser -UserId <RoomAccountUPN> | Select-Object UserPrincipalName
```

**Rollback:** If password reset breaks other integrations, roll back by updating the room account password to a known value.
</details>

<details><summary>Fix 2 — Bring an offline device back online</summary>

**Use when:** Device shows "Offline" in Teams Admin Centre, confirmed as physically powered on.

```powershell
# Step 1: Check the device's last heartbeat in TAC
# Teams Admin Centre → Devices → find device → check "Last seen" timestamp

# Step 2: Verify network connectivity to Teams endpoints
# On the device (if you can access it): Check settings → network status

# Step 3: Restart the Teams app or device via TAC (if device is partially responsive)
# Teams Admin Centre → Devices → select device → Actions → Restart

# Step 4: Check if firmware is corrupted — factory reset as last resort
# Teams Admin Centre → Devices → select device → Actions → Factory reset (erases all local config)
```

**Network checks to run on-site:**
```powershell
# Run from a PC on the same VLAN as the Teams device:
Test-NetConnection -ComputerName teams.microsoft.com -Port 443
Test-NetConnection -ComputerName login.microsoftonline.com -Port 443
Test-NetConnection -ComputerName sfbassets.com -Port 443
```

**If on separate VLAN:** Verify firewall/ACL allows HTTPS from device VLAN to Microsoft endpoints.
</details>

<details><summary>Fix 3 — Fix IP phone stuck on sign-in screen</summary>

**Use when:** IP phone (Poly, Yealink, AudioCodes) shows sign-in code but code doesn't work, or phone loops on sign-in.

```powershell
# Step 1: Check if the device account is configured as a Teams-only user
$account = Get-CsOnlineUser -Identity <PhoneAccountUPN>
$account | Select-Object EnterpriseVoiceEnabled, TeamsUpgradeMode, LineUri | Format-List

# Step 2: Check IP phone policy assigned
Get-CsTeamsIPPhonePolicy | Select-Object Identity, SignInMode

# Assign a phone policy:
Grant-CsTeamsIPPhonePolicy -Identity <PhoneAccountUPN> -PolicyName "CommonAreaPhone"
# Or for personal desk phones:
Grant-CsTeamsIPPhonePolicy -Identity <PhoneAccountUPN> -PolicyName "UserExperience"

# Step 3: For Common Area Phones — ensure account has Common Area Phone license
Get-MgUserLicenseDetail -UserId <PhoneAccountUPN> | Select-Object SkuPartNumber
# Required: MCOCAP (Common Area Phone) license
```

**Sign-in code troubleshooting:**
1. Navigate to https://microsoft.com/devicelogin on a browser
2. Enter the code shown on the phone screen
3. Sign in with the phone/room account credentials
4. If code expired — restart phone to generate new code

**Rollback:** `Grant-CsTeamsIPPhonePolicy -Identity <UPN> -PolicyName $null` removes assigned policy.
</details>

<details><summary>Fix 4 — Control Teams device firmware update policy</summary>

**Use when:** Device updated unexpectedly and broke functionality, or devices are stuck on old firmware.

```powershell
# List existing update policies:
Get-CsTeamsUpdateManagementPolicy | Format-List

# Create a custom update policy with a defined maintenance window:
New-CsTeamsUpdateManagementPolicy -Identity "RoomDevices-Weekend" `
    -AllowManagedUpdates $true `
    -UseSmartScheduler $false `
    -UpdateDayOfWeek 0 `  # 0=Sunday
    -UpdateTimeOfDay "02:00:00" `
    -UpdateWindowEndTime "04:00:00"

# Assign to a room account:
Grant-CsTeamsUpdateManagementPolicy -Identity <RoomAccountUPN> -PolicyName "RoomDevices-Weekend"

# To pause updates temporarily (if device is in use / critical period):
Set-CsTeamsUpdateManagementPolicy -Identity "RoomDevices-Weekend" -AllowManagedUpdates $false
```

**Rollback:** Set `AllowManagedUpdates $true` and let devices update during next maintenance window.
</details>

<details><summary>Fix 5 — Enable hot-desking on IP phones</summary>

**Use when:** Users complain they can't sign in to a shared desk phone as themselves.

```powershell
# Check hot-desking status in phone policy:
Get-CsTeamsIPPhonePolicy -Identity "CommonAreaPhone" | Select-Object AllowHotDesking, HotDeskingIdleTimeoutInMinutes

# Enable hot-desking:
Set-CsTeamsIPPhonePolicy -Identity "CommonAreaPhone" -AllowHotDesking $true -HotDeskingIdleTimeoutInMinutes 120

# If using a global or custom policy — update that instead:
Set-CsTeamsIPPhonePolicy -Identity Global -AllowHotDesking $true -HotDeskingIdleTimeoutInMinutes 60
```

**Note:** Hot-desking requires the phone account to be a Common Area Phone (CAP) account with the MCOCAP license. User sign-in to a hot-desk phone uses their personal Teams account temporarily.

**Rollback:** `Set-CsTeamsIPPhonePolicy -Identity "CommonAreaPhone" -AllowHotDesking $false`.
</details>

<details><summary>Fix 6 — Fix room calendar / meeting display issues</summary>

**Use when:** Teams Room device shows wrong meeting info, doesn't auto-accept invites, or shows old meetings.

```powershell
# Check calendar processing settings:
Get-CalendarProcessing -Identity <RoomAccountUPN> | Format-List

# Standard config for Teams Rooms (apply if misconfigured):
Set-CalendarProcessing -Identity <RoomAccountUPN> `
    -AutomateProcessing AutoAccept `
    -AddOrganizerToSubject $false `
    -DeleteComments $false `
    -DeleteSubject $false `
    -RemovePrivateProperty $false `
    -AllowConflicts $false `
    -ProcessExternalMeetingMessages $true

# Force mailbox resync (if calendar appears stuck):
# In Exchange Online Admin Centre → Mailboxes → select room mailbox → Calendar → Edit

# Check timezone on the room mailbox:
Get-MailboxCalendarConfiguration -Identity <RoomAccountUPN> | Select-Object WorkingHoursTimeZone, DefaultReminderTime | Format-List

# Set correct timezone:
Set-MailboxCalendarConfiguration -Identity <RoomAccountUPN> -WorkingHoursTimeZone "GMT Standard Time"
```

**Note:** Changes to calendar processing take up to 15 minutes to propagate to the device. If device still shows stale data after 30 minutes, restart the Teams app from TAC.

**Rollback:** Reset `AutomateProcessing` to `None` only if intentionally removing auto-accept behaviour.
</details>

---
## Escalation Evidence

```
TEAMS DEVICE ESCALATION
========================
Device type:       [ ] Teams Room (Windows/Android)  [ ] IP Phone (Poly/Yealink/AudioCodes)  [ ] Teams Display
Device model:      <make and model>
Firmware version:  <version from TAC or device settings>
Account UPN:       <RoomAccountUPN>

Account enabled:         [ ] Yes  [ ] No
License:                 <SKU name or "missing">
EnterpriseVoiceEnabled:  [ ] Yes  [ ] No (if calling required)
TeamsUpgradeMode:        <value>

Device status in TAC:    [ ] Online  [ ] Offline  [ ] Needs attention
Last seen in TAC:        <timestamp>

Calendar processing:
  AutomateProcessing:    <AutoAccept / None>
  AllowConflicts:        <True/False>

Error shown on device:   <exact error text or error code>
Network confirmed:       [ ] Tested HTTPS to teams.microsoft.com

Steps already tried:
  [ ] Restarted device  [ ] Reset account password  [ ] Re-assigned license  [ ] Factory reset
```

---
## 🎓 Learning Pointers

- **Room accounts must exclude MFA** — Teams Room devices use unattended sign-in. Any CA policy enforcing MFA for the room account UPN will break the device silently. Create a dedicated CA exclusion group for service/room accounts and document it.
- **Teams Rooms Pro vs Basic** — Basic is free for up to 25 rooms but lacks advanced TAC management, analytics, and automated alerts. Pro is required for device health monitoring at scale.
- **IP Phone firmware is carrier-specific** — Poly and Yealink firmware is Teams-certified by model. Check the Teams-certified devices list before updating: https://www.microsoft.com/en-us/microsoft-teams/across-devices/devices
- **`ProcessExternalMeetingMessages: $true`** is required if external guests send meeting invites to the room. Without it, external invites are silently rejected.
- **Hot-desking and direct line are mutually exclusive** — a Common Area Phone can either have a direct number assigned (traditional shared phone) or hot-desking enabled (personal sign-in). Not both simultaneously.
- MS Docs — Deploy Teams Rooms: https://learn.microsoft.com/en-us/microsoftteams/rooms/
- MS Docs — Teams IP phones: https://learn.microsoft.com/en-us/microsoftteams/business-voice/set-up-phone-system
