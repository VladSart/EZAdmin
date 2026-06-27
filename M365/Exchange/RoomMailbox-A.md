# Room & Resource Mailboxes — Reference Runbook (Mode A: Deep Dive)
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
- Room mailboxes (conference rooms, meeting spaces)
- Equipment mailboxes (projectors, vehicles, AV gear)
- Resource booking policies and auto-accept/decline logic
- Calendar processing delegate configuration
- Booking window, capacity, and conflict management
- Hybrid scenarios (on-premises Exchange + Exchange Online)
- Microsoft Teams Rooms (MTR) mailbox integration

**Assumes:**
- Exchange Online or Exchange Hybrid (on-prem 2016+)
- Exchange Online PowerShell v3 module connected
- Entra ID / M365 licensing in place
- Sufficient RBAC: at minimum `Recipient Management` role

**Out of scope:**
- Physical room hardware provisioning
- Teams Rooms device management (see `M365/Teams/Teams-Rooms-B.md`)

---

## How It Works

<details><summary>Full architecture</summary>

Room and equipment mailboxes are a specialised Exchange mailbox type. Unlike regular user mailboxes, they are designed to be unattended — their booking is handled entirely by Exchange's **Calendar Attendant** service (formerly Resource Booking Attendant).

```
Meeting Organiser (Outlook/Teams)
         |
         | SMTP invite → Exchange Transport
         |
         ▼
Room Mailbox Inbox
         |
         ▼
  [Calendar Attendant] ← AutoAcceptDeclineEnabled property
         |
    ┌────┴────────────────────────────────────┐
    │  Booking Policy Engine                  │
    │  ─────────────────────────────────────  │
    │  AllowConflicts?                        │
    │  BookingWindowInDays (default 180)      │
    │  MaximumDurationInMinutes (default 1440)│
    │  AllowRecurringMeetings?                │
    │  ScheduleOnlyDuringWorkHours?           │
    │  Capacity (informational only)          │
    └────┬────────────────────────────────────┘
         |
    ┌────┴─────┐     ┌──────────────────────┐
    │ ACCEPT   │     │ DECLINE              │
    │ booking  │     │ with reason message  │
    └──────────┘     └──────────────────────┘
         |
  Calendar updated
  Organiser receives Accept/Decline
```

**Key objects:**

| Property | Cmdlet | Purpose |
|---|---|---|
| `AutoAcceptDeclineEnabled` | `Get/Set-CalendarProcessing` | Master switch for automated booking |
| `ResourceDelegates` | `Get/Set-CalendarProcessing` | Users who get booking requests for manual approval |
| `AllBookInPolicy` | `Get/Set-CalendarProcessing` | If `$true`, all senders auto-accepted (subject to other rules) |
| `BookInPolicy` | `Get/Set-CalendarProcessing` | Specific list of users who can auto-book |
| `RequestInPolicy` | `Get/Set-CalendarProcessing` | Users whose requests go to delegate for approval |
| `AllRequestInPolicy` | `Get/Set-CalendarProcessing` | All senders request approval from delegate |
| `ForwardRequestsToDelegates` | `Get/Set-CalendarProcessing` | Forwards meeting requests to delegates |
| `DeleteNonCalendarItems` | `Get/Set-CalendarProcessing` | Cleans non-calendar email from inbox |
| `RemovePrivateProperty` | `Get/Set-CalendarProcessing` | Strips private flag from accepted meetings |
| `AddOrganizerToSubject` | `Get/Set-CalendarProcessing` | Includes organiser name in subject |
| `DeleteSubject` | `Get/Set-CalendarProcessing` | Clears meeting subject on accept |

**Mailbox type hierarchy:**

```
Exchange Recipient
└── Mailbox
    ├── UserMailbox (regular user)
    └── ResourceMailbox
        ├── Room     ← RoomMailboxPolicy applies
        └── Equipment
```

**Processing flow for a booking request:**

```
1. Organiser sends meeting invite to room@company.com
2. Exchange Transport delivers to room mailbox
3. Calendar Attendant evaluates:
   a. Is AutoAcceptDeclineEnabled = True?
      NO → do nothing (manual inbox management)
      YES → continue
   b. Is sender in BookInPolicy or AllBookInPolicy = True?
      YES → auto-accept if no conflicts
      NO → Is sender in RequestInPolicy or AllRequestInPolicy?
        YES → forward to ResourceDelegates for approval
        NO → auto-decline
   c. Conflict check:
      AllowConflicts = False → decline if overlap exists
      AllowConflicts = True → accept regardless
   d. Policy checks:
      BookingWindowInDays, MaximumDurationInMinutes,
      ScheduleOnlyDuringWorkHours, AllowRecurringMeetings
4. Accept/Decline/Forward response sent
```

**Hybrid considerations:**

In Exchange Hybrid, room mailboxes can exist on-premises or in Exchange Online. Key rules:
- If the mailbox is on-prem: `Set-CalendarProcessing` runs against the on-prem Exchange shell
- If the mailbox is in EXO: `Set-CalendarProcessing` runs in Exchange Online PowerShell
- Free/Busy lookups cross forest via Organisation Relationship + Autodiscover
- Hybrid room mailboxes must have a cloud object (mail-enabled user or synced via Entra Connect)

</details>

---

## Dependency Stack

```
M365 Admin Centre / Exchange Admin Centre (EAC)
        │
Exchange Online PowerShell (EXO v3)
        │
Exchange Online Transport Service
        │
Calendar Attendant Service (per-mailbox)
        │
├── BookingPolicy (CalendarProcessing settings)
├── ResourceDelegates (Mailbox permissions)
└── MailboxPermissions (FullAccess / Send-As / SendOnBehalfOf)
        │
Entra ID Object (disabled user account backing the mailbox)
        │
Entra Connect (if hybrid — synced from on-prem AD)
        │
On-Premises Exchange (if hybrid room mailbox)
        │
Active Directory (computer/service accounts for MTR if applicable)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Room not appearing in Outlook Room Finder | Missing `City`/`Floor`/`Capacity` attributes or wrong room list | `Get-Mailbox -Identity <room> \| FL ResourceCapacity,*Room*` |
| Meeting auto-declined immediately | `AllBookInPolicy = $false` and sender not in BookInPolicy | `Get-CalendarProcessing <room> \| FL AllBookInPolicy,BookInPolicy` |
| "Tentative" then no confirm | `AutoAcceptDeclineEnabled = $false` | `Get-CalendarProcessing <room> \| FL AutoAcceptDeclineEnabled` |
| Delegate never receives approval requests | `ForwardRequestsToDelegates = $false` or wrong delegate | `Get-CalendarProcessing <room> \| FL ForwardRequestsToDelegates,ResourceDelegates` |
| Room shows as busy even when free | Phantom calendar items, stuck meeting request | `Get-MailboxCalendarFolder <room>:\Calendar \| FL` then inspect via EAC |
| Recurring meetings declined | `AllowRecurringMeetings = $false` | `Get-CalendarProcessing <room> \| FL AllowRecurringMeetings` |
| Booking window violations | Meeting date beyond BookingWindowInDays | `Get-CalendarProcessing <room> \| FL BookingWindowInDays` |
| Room calendar not visible to organiser | Missing FullAccess or FolderPermission | `Get-MailboxPermission <room>` and `Get-MailboxFolderPermission <room>:\Calendar` |
| Subject/organiser stripped from accepted meetings | `DeleteSubject = $true` or `AddOrganizerToSubject = $false` | `Get-CalendarProcessing <room> \| FL DeleteSubject,AddOrganizerToSubject` |
| MTR unable to sign in / room account disabled | Entra account disabled or licence missing | `Get-MgUser -UserId <UPN> \| Select AccountEnabled,AssignedLicenses` |
| Room not auto-accepting in hybrid | Mailbox still on-prem, running EXO cmdlets against wrong shell | Check where mailbox lives: `Get-Mailbox <room> \| FL RecipientTypeDetails,Database` |
| "Your meeting request was received but will not be delivered" | Sender address blocked by transport rule or spam filter | Check message trace in EAC |

---

## Validation Steps

**1. Confirm mailbox type and location**

```powershell
Get-Mailbox -Identity "<RoomUPN>" | Select DisplayName, RecipientTypeDetails, Database, ExchangeGuid
```

Expected (EXO): `RecipientTypeDetails = RoomMailbox`, `Database` contains `NAMPR` or similar EXO DB name.

Bad: `RecipientTypeDetails = UserMailbox` → wrong type; `Database = ON-PREM-DB` → mailbox is on-prem, use on-prem shell.

---

**2. Check calendar processing policy**

```powershell
Get-CalendarProcessing -Identity "<RoomUPN>" | Format-List
```

Expected (typical): `AutoAcceptDeclineEnabled: True`, `AllBookInPolicy: True`, `AllowConflicts: False`, `BookingWindowInDays: 180`.

Bad: `AutoAcceptDeclineEnabled: False` → room behaves as unmanaged mailbox.

---

**3. Verify Room Finder attributes**

```powershell
Get-Mailbox -Identity "<RoomUPN>" | Select ResourceCapacity, ResourceCustom, CustomAttribute1
Get-Place -Identity "<RoomUPN>"
```

Expected: Capacity set, City/Building/Floor populated in `Get-Place`.

Bad: Empty → room won't appear in Outlook Room Finder geographic filters.

---

**4. Check Room List membership**

```powershell
Get-DistributionGroupMember -Identity "<RoomListName>"
```

Expected: Room mailbox listed as a member.

Bad: Room not in any list → invisible to Outlook Room Finder unless searched directly.

---

**5. Check permissions**

```powershell
Get-MailboxPermission -Identity "<RoomUPN>" | Where { $_.AccessRights -eq "FullAccess" }
Get-MailboxFolderPermission -Identity "<RoomUPN>:\Calendar"
```

Expected: Delegates have FullAccess if managing the calendar manually. Calendar folder shows `Default: AvailabilityOnly` or `Reviewer`.

---

**6. Check delegate configuration**

```powershell
Get-CalendarProcessing -Identity "<RoomUPN>" | Select ResourceDelegates, ForwardRequestsToDelegates, AllRequestInPolicy
```

Expected if delegate-managed: `ResourceDelegates` populated, `ForwardRequestsToDelegates: True`.

---

**7. Check Entra account status (for MTR)**

```powershell
Get-MgUser -UserId "<RoomUPN>" | Select DisplayName, AccountEnabled, AssignedLicenses
```

Expected for MTR: `AccountEnabled: True`, `AssignedLicenses` includes Teams Rooms licence.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Room Not Appearing in Room Finder

1. Confirm mailbox is type `RoomMailbox` (Step 1 above)
2. Verify Room List exists and room is a member
3. Set Place attributes:
   ```powershell
   Set-Place -Identity "<RoomUPN>" -City "London" -Floor "3" -FloorLabel "Third Floor" -Building "HQ" -Capacity 12 -Label "Boardroom"
   ```
4. Confirm Outlook client is on a recent build (Room Finder v2 requires Outlook 2016+)
5. Allow up to 24h for Place directory to propagate

---

### Phase 2 — Bookings Not Being Processed

1. Run `Get-CalendarProcessing` (Step 2 above) — note `AutoAcceptDeclineEnabled`
2. If disabled: enable it (see Remediation Playbook 1)
3. Check sender is in `BookInPolicy` or `AllBookInPolicy = $true`
4. Review message trace in EAC for delivery issues:
   ```
   EAC → Mail flow → Message trace → To: <RoomUPN>
   ```
5. Check for transport rules blocking room mailbox

---

### Phase 3 — Delegate Approval Not Working

1. Confirm delegate(s) set in `ResourceDelegates`
2. Confirm `ForwardRequestsToDelegates = $true`
3. Confirm `AllRequestInPolicy = $true` (or specific users in `RequestInPolicy`)
4. Confirm delegate mailbox is not full or quarantined
5. Check delegate's Junk/Clutter — approval emails sometimes filtered

---

### Phase 4 — Room Shows Incorrect Availability

1. Check for phantom items using EAC Calendar view (login as delegate, view room calendar)
2. If orphaned tentative items exist, remove via:
   ```powershell
   # Export calendar items to identify phantoms
   $session = New-EXOMailboxSession
   # Then use EAC Calendar or Outlook delegate access to delete
   ```
3. Run Managed Folder Assistant to clear stale processing:
   ```powershell
   Start-ManagedFolderAssistant -Identity "<RoomUPN>"
   ```
4. Check `AllowConflicts` — if `$true`, room accepts overlapping meetings (by design)

---

### Phase 5 — Hybrid Room Issues

1. Confirm which Exchange manages the mailbox:
   ```powershell
   Get-Mailbox "<room>" | Select RecipientTypeDetails, Database, ExchangeGuid
   ```
2. If on-prem database: connect to on-prem Exchange shell, not EXO
3. Check Organisation Relationship for Free/Busy sharing:
   ```powershell
   # In EXO:
   Get-OrganizationRelationship | Select Name, FreeBusyAccessEnabled, FreeBusyAccessLevel
   ```
4. Verify Autodiscover resolves correctly for on-prem room domain

---

## Remediation Playbooks

<details><summary>Playbook 1 — Enable Auto-Accept on a Room Mailbox</summary>

**Use case:** Room is not auto-accepting/declining bookings.

```powershell
# Connect to Exchange Online
Connect-ExchangeOnline -UserPrincipalName <AdminUPN>

# Enable auto-accept
Set-CalendarProcessing -Identity "<RoomUPN>" `
    -AutoAcceptDeclineEnabled $true `
    -AllBookInPolicy $true `
    -AllowConflicts $false `
    -BookingWindowInDays 180 `
    -MaximumDurationInMinutes 480 `
    -AllowRecurringMeetings $true `
    -DeleteComments $false `
    -DeleteSubject $false `
    -AddOrganizerToSubject $true `
    -RemovePrivateProperty $false

# Verify
Get-CalendarProcessing -Identity "<RoomUPN>" | Format-List AutoAcceptDeclineEnabled, AllBookInPolicy, AllowConflicts
```

**Rollback:** If issues arise, revert to delegate-managed:
```powershell
Set-CalendarProcessing -Identity "<RoomUPN>" -AutoAcceptDeclineEnabled $false
```

</details>

<details><summary>Playbook 2 — Configure Delegate-Managed Booking</summary>

**Use case:** Room requires human approval before confirming.

```powershell
# Set delegate
$delegate = "facilities@<domain>.com"

Set-CalendarProcessing -Identity "<RoomUPN>" `
    -AutoAcceptDeclineEnabled $true `
    -AllBookInPolicy $false `
    -AllRequestInPolicy $true `
    -ResourceDelegates $delegate `
    -ForwardRequestsToDelegates $true `
    -DeleteComments $false `
    -AddOrganizerToSubject $true

# Grant delegate calendar access
Add-MailboxPermission -Identity "<RoomUPN>" -User $delegate -AccessRights FullAccess -AutoMapping $false
Add-MailboxFolderPermission -Identity "<RoomUPN>:\Calendar" -User $delegate -AccessRights Editor

Write-Host "Delegate configured: $delegate"
```

**Rollback:**
```powershell
Remove-MailboxPermission -Identity "<RoomUPN>" -User $delegate -AccessRights FullAccess -Confirm:$false
Set-CalendarProcessing -Identity "<RoomUPN>" -ResourceDelegates $null -AllBookInPolicy $true
```

</details>

<details><summary>Playbook 3 — Create a New Room Mailbox</summary>

**Use case:** Provisioning a new conference room.

```powershell
# Create room mailbox
New-Mailbox -Name "Boardroom A" `
    -DisplayName "Boardroom A" `
    -Alias "BoardroomA" `
    -Room `
    -PrimarySmtpAddress "boardrooma@<domain>.com" `
    -ResourceCapacity 12

# Set calendar processing
Set-CalendarProcessing -Identity "boardrooma@<domain>.com" `
    -AutoAcceptDeclineEnabled $true `
    -AllBookInPolicy $true `
    -AllowConflicts $false `
    -BookingWindowInDays 180 `
    -MaximumDurationInMinutes 480 `
    -AllowRecurringMeetings $true `
    -DeleteComments $false `
    -DeleteSubject $false `
    -AddOrganizerToSubject $true

# Set Place attributes for Room Finder
Set-Place -Identity "boardrooma@<domain>.com" `
    -City "<City>" `
    -Building "<Building>" `
    -Floor "<Floor>" `
    -FloorLabel "<Floor Label>" `
    -Capacity 12 `
    -Label "Boardroom A"

# Add to Room List (create list first if needed)
# New-DistributionGroup -Name "All Meeting Rooms" -RoomList
Add-DistributionGroupMember -Identity "<RoomListName>" -Member "boardrooma@<domain>.com"

Write-Host "Room mailbox created and configured."
```

**Rollback:** `Remove-Mailbox -Identity "boardrooma@<domain>.com" -Confirm:$false`

> ⚠️ This removes all calendar data permanently.

</details>

<details><summary>Playbook 4 — Bulk-Report Room Mailbox Configuration</summary>

**Use case:** Audit all room mailboxes for misconfiguration.

```powershell
Connect-ExchangeOnline -UserPrincipalName <AdminUPN>

$rooms = Get-Mailbox -RecipientTypeDetails RoomMailbox -ResultSize Unlimited

$report = foreach ($room in $rooms) {
    $cp = Get-CalendarProcessing -Identity $room.PrimarySmtpAddress
    $place = Get-Place -Identity $room.PrimarySmtpAddress -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        DisplayName            = $room.DisplayName
        PrimarySmtpAddress     = $room.PrimarySmtpAddress
        Capacity               = $room.ResourceCapacity
        AutoAccept             = $cp.AutoAcceptDeclineEnabled
        AllBookInPolicy        = $cp.AllBookInPolicy
        AllowConflicts         = $cp.AllowConflicts
        BookingWindowDays      = $cp.BookingWindowInDays
        MaxDurationMins        = $cp.MaximumDurationInMinutes
        AllowRecurring         = $cp.AllowRecurringMeetings
        DelegateCount          = ($cp.ResourceDelegates | Measure-Object).Count
        ForwardToDelegates     = $cp.ForwardRequestsToDelegates
        City                   = $place.City
        Building               = $place.Building
        Floor                  = $place.Floor
    }
}

$report | Export-Csv -Path ".\RoomMailbox-Audit-$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
Write-Host "Report exported: RoomMailbox-Audit-$(Get-Date -Format yyyyMMdd).csv"
```

</details>

<details><summary>Playbook 5 — Fix Phantom/Ghost Calendar Items</summary>

**Use case:** Room shows as busy despite no visible meetings.

```powershell
# Step 1: Count items in calendar
$folderStats = Get-MailboxFolderStatistics -Identity "<RoomUPN>" -FolderScope Calendar
$folderStats | Select Name, ItemsInFolder, FolderSize

# Step 2: Run Managed Folder Assistant to trigger cleanup
Start-ManagedFolderAssistant -Identity "<RoomUPN>"

# Step 3: If phantom items remain, use Outlook (delegate access) or EAC to manually delete
# Or use EWS/Graph API to enumerate and delete calendar items
# For Graph-based cleanup (requires Calendar.ReadWrite app permission):
# GET /users/{room-id}/calendar/events?$filter=showAs eq 'tentative'

# Step 4: Verify calendar is clear
Start-Sleep -Seconds 30
$folderStats2 = Get-MailboxFolderStatistics -Identity "<RoomUPN>" -FolderScope Calendar
$folderStats2 | Select Name, ItemsInFolder
```

</details>

---

## Evidence Pack

```powershell
# Run this before escalating — collects everything needed for a support ticket

Connect-ExchangeOnline -UserPrincipalName <AdminUPN>
$roomUPN = "<RoomUPN>"
$outputPath = ".\RoomMailbox-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# Mailbox basics
Get-Mailbox -Identity $roomUPN | Format-List | Out-File "$outputPath\01-Mailbox.txt"

# Calendar processing
Get-CalendarProcessing -Identity $roomUPN | Format-List | Out-File "$outputPath\02-CalendarProcessing.txt"

# Mailbox permissions
Get-MailboxPermission -Identity $roomUPN | Out-File "$outputPath\03-MailboxPermissions.txt"

# Calendar folder permissions
Get-MailboxFolderPermission -Identity "${roomUPN}:\Calendar" | Out-File "$outputPath\04-CalendarFolderPermissions.txt"

# Place attributes
Get-Place -Identity $roomUPN | Format-List | Out-File "$outputPath\05-PlaceAttributes.txt"

# Distribution group membership (room lists)
(Get-DistributionGroup -ResultSize Unlimited | Where-Object {
    (Get-DistributionGroupMember -Identity $_.Name -ResultSize Unlimited |
     Select-Object -ExpandProperty PrimarySmtpAddress) -contains $roomUPN
}) | Select Name, PrimarySmtpAddress | Out-File "$outputPath\06-RoomListMembership.txt"

# Folder statistics
Get-MailboxFolderStatistics -Identity $roomUPN -FolderScope Calendar | Out-File "$outputPath\07-FolderStats.txt"

Write-Host "Evidence collected in: $outputPath"
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Get calendar processing settings | `Get-CalendarProcessing -Identity <UPN> \| FL` |
| Enable auto-accept | `Set-CalendarProcessing -Identity <UPN> -AutoAcceptDeclineEnabled $true -AllBookInPolicy $true` |
| Set booking window | `Set-CalendarProcessing -Identity <UPN> -BookingWindowInDays 90` |
| Set max meeting duration | `Set-CalendarProcessing -Identity <UPN> -MaximumDurationInMinutes 240` |
| Add resource delegate | `Set-CalendarProcessing -Identity <UPN> -ResourceDelegates <email>` |
| Get Place attributes | `Get-Place -Identity <UPN>` |
| Set Place attributes | `Set-Place -Identity <UPN> -City "London" -Capacity 10 -Building "HQ"` |
| List all room mailboxes | `Get-Mailbox -RecipientTypeDetails RoomMailbox -ResultSize Unlimited` |
| Add room to room list | `Add-DistributionGroupMember -Identity <ListName> -Member <RoomUPN>` |
| Create room list | `New-DistributionGroup -Name "Floor 3 Rooms" -RoomList` |
| Grant calendar access | `Add-MailboxFolderPermission -Identity <UPN>:\Calendar -User <user> -AccessRights Editor` |
| Run folder assistant | `Start-ManagedFolderAssistant -Identity <UPN>` |
| Get calendar item count | `Get-MailboxFolderStatistics -Identity <UPN> -FolderScope Calendar \| Select Name,ItemsInFolder` |
| Check mailbox type | `Get-Mailbox <UPN> \| Select RecipientTypeDetails` |
| Export audit report | See Playbook 4 above |

---

## 🎓 Learning Pointers

- **Room Finder v2** requires Place attributes (`Set-Place`) and room list membership. The legacy `Set-Mailbox -ResourceCapacity` alone is not enough for modern Outlook Room Finder — use `Set-Place` for all location metadata. [MS Docs: Set-Place](https://learn.microsoft.com/en-us/powershell/module/exchange/set-place)

- **Calendar Attendant vs. Calendar Processing** are often confused. Calendar Attendant is the Exchange service that runs the logic; Calendar Processing is the configuration object. `Set-CalendarProcessing` configures the Attendant — there is no separate "start/stop" for it per mailbox.

- **`AllBookInPolicy` vs `BookInPolicy`**: `AllBookInPolicy = $true` lets everyone auto-book. To restrict to specific users, set `AllBookInPolicy = $false` and list approved users in `BookInPolicy`. Unlisted users get declined unless in `RequestInPolicy` (delegate queue). [MS Docs: Set-CalendarProcessing](https://learn.microsoft.com/en-us/powershell/module/exchange/set-calendarprocessing)

- **MTR account requirements**: Teams Rooms devices need the room mailbox Entra account to be enabled (not disabled like normal room accounts) with a Teams Rooms licence. Password must be set to never expire. Forgetting this is one of the most common MTR break-fix scenarios. [MS Docs: Create a resource account](https://learn.microsoft.com/en-us/microsoftteams/rooms/create-resource-account)

- **Hybrid Free/Busy**: In Exchange Hybrid, room free/busy is shared via the Organisation Relationship and Autodiscover. If on-prem room mailboxes show no availability to cloud users (or vice versa), check the Organisation Relationship `FreeBusyAccessEnabled` flag and that Autodiscover SCP/DNS is resolving correctly.

- **`DeleteSubject = $true`** is a privacy setting that wipes the meeting title from the room calendar on accept. Many organisations inadvertently enable it during template-based provisioning — disable it if rooms should retain meeting titles for display on room panels. [Community thread with common gotchas](https://techcommunity.microsoft.com/t5/exchange/room-mailbox-calendar-processing-settings-explained/td-p/607461)
