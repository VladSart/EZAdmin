# Exchange Room / Resource Mailbox — Hotfix Runbook (Mode B: Ops)
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

Connect to Exchange Online first:
```powershell
Connect-ExchangeOnline -UserPrincipalName <AdminUPN>
```

Then run:
```powershell
# 1. Get room mailbox basics (replace with room UPN or display name)
$room = "<room@domain.com>"
Get-Mailbox -Identity $room | Select DisplayName, RecipientTypeDetails, ResourceType,
    EmailAddresses, HiddenFromAddressListsEnabled, BookingProcessEnabled

# 2. Check booking delegates and policy
Get-CalendarProcessing -Identity $room | Select AutomateProcessing, BookInPolicy,
    RequestOutOfPolicy, AllBookInPolicy, AllRequestInPolicy, ResourceDelegates,
    AddOrganizerToSubject, DeleteComments, DeleteSubject, RemovePrivateProperty,
    EnforceSchedulingHorizon, SchedulingHorizonInDays, MaximumDurationInMinutes,
    BookingWindowInDays, ConflictPercentageAllowed, MaximumConflictInstances

# 3. Check permissions on the room
Get-MailboxPermission -Identity $room | Where-Object { $_.User -notlike "NT AUTHORITY*" }

# 4. Did any recent bookings fail? (check room calendar)
Get-MailboxFolderStatistics -Identity $room -FolderScope Calendar | Select Name, ItemsInFolder, FolderSize

# 5. Check if room is visible and accepting
Get-Mailbox -Identity $room | Select -ExpandProperty ResourceCapacity
```

| Symptom | Likely Cause | Next Action |
|---------|-------------|-------------|
| Room not appearing in GAL/address book | `HiddenFromAddressListsEnabled = True` | [Fix 1](#fix-1--unhide-from-address-list) |
| Booking declined for everyone | `AutomateProcessing = None` or delegate conflict | [Fix 2](#fix-2--fix-calendar-processing) |
| Booking declined for specific users | `BookInPolicy` missing that user/group | [Fix 3](#fix-3--fix-booking-policy-permissions) |
| Double-booked / no conflict check | `ConflictPercentageAllowed` set incorrectly | [Fix 4](#fix-4--enforce-conflict-detection) |
| Meeting accepted but organiser gets no confirmation | `AddOrganizerToSubject` / mail routing issue | [Fix 5](#fix-5--fix-confirmation-email-issues) |
| "Resource mailbox not found" when booking | Mailbox type wrong (User mailbox, not Room) | Check `RecipientTypeDetails = RoomMailbox` |
| Room shows as unavailable all the time | Mailbox blocked / litigation hold / capacity 0 | Check `ResourceCapacity`, `LitigationHoldEnabled` |

---
## Dependency Cascade

<details><summary>What must be true for room booking to work</summary>

```
Exchange Online / Hybrid Exchange
  └── Room mailbox exists (RecipientTypeDetails: RoomMailbox)
        ├── Visible in GAL (HiddenFromAddressListsEnabled: False)
        ├── Has valid SMTP address in EmailAddresses
        └── CalendarProcessing configured (AutomateProcessing: AutoAccept or AutoUpdate)
              ├── Booking policy allows the organiser (BookInPolicy or AllBookInPolicy)
              ├── No conflicting booking in calendar
              │     └── MaximumConflictInstances / ConflictPercentageAllowed settings
              ├── Request within booking window (BookingWindowInDays)
              ├── Request within duration limits (MaximumDurationInMinutes)
              └── Calendar permissions allow organiser to see free/busy
                    └── MailboxFolderPermission on Calendar folder
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm mailbox type**
```powershell
Get-Mailbox -Identity $room | Select RecipientTypeDetails, ResourceType, ResourceCapacity
```
Expected: `RecipientTypeDetails = RoomMailbox`, `ResourceType = Room`, `ResourceCapacity ≥ 1`. If it's `UserMailbox` — the object was created wrong and needs conversion.

**Step 2 — Check calendar processing settings**
```powershell
Get-CalendarProcessing -Identity $room | Select AutomateProcessing, AllBookInPolicy, BookInPolicy, ResourceDelegates
```
Expected: `AutomateProcessing = AutoAccept` for full auto-booking. `AutoUpdate` means a delegate must manually approve.

**Step 3 — Verify GAL visibility**
```powershell
Get-Mailbox -Identity $room | Select HiddenFromAddressListsEnabled, EmailAddresses
```
Expected: `HiddenFromAddressListsEnabled = False`. At least one SMTP in EmailAddresses.

**Step 4 — Test booking permissions for a specific user**
```powershell
$organiser = "<organiser@domain.com>"
$cp = Get-CalendarProcessing -Identity $room
if ($cp.AllBookInPolicy) {
    "All users can book directly"
} elseif ($cp.BookInPolicy -contains $organiser) {
    "User is in BookInPolicy"
} else {
    "User NOT in BookInPolicy — booking will be declined or sent to delegate"
}
```

**Step 5 — Check calendar folder permissions**
```powershell
Get-MailboxFolderPermission -Identity "${room}:\Calendar" | Format-Table User, AccessRights
```
Expected: Default = `AvailabilityOnly` (for free/busy). If `None` — users can't see availability in scheduling assistant.

---
## Common Fix Paths

<details><summary>Fix 1 — Unhide from Address List</summary>

**When**: Room not appearing when users search in Outlook/Teams.

```powershell
Set-Mailbox -Identity $room -HiddenFromAddressListsEnabled $false

# Verify
Get-Mailbox -Identity $room | Select HiddenFromAddressListsEnabled
```

**Note**: Address list sync can take 30-60 minutes to propagate to all clients. Users may need to restart Outlook or clear the Offline Address Book (OAB):
- Outlook: Send/Receive → Download Address Book → Full Download

</details>

<details><summary>Fix 2 — Fix Calendar Processing (AutomateProcessing)</summary>

**When**: Bookings being declined or going to a delegate queue when they shouldn't be.

```powershell
# Full auto-accept (no delegates needed, no manual approval)
Set-CalendarProcessing -Identity $room `
    -AutomateProcessing AutoAccept `
    -AddOrganizerToSubject $true `
    -DeleteComments $false `
    -DeleteSubject $false `
    -RemovePrivateProperty $false

# If you WANT delegates to approve out-of-policy requests:
Set-CalendarProcessing -Identity $room `
    -AutomateProcessing AutoAccept `
    -AllRequestOutOfPolicy $false `
    -RequestOutOfPolicy $false `
    -ResourceDelegates "<delegate@domain.com>"

# Verify
Get-CalendarProcessing -Identity $room | Select AutomateProcessing, ResourceDelegates
```

**Rollback**:
```powershell
Set-CalendarProcessing -Identity $room -AutomateProcessing AutoUpdate
```

</details>

<details><summary>Fix 3 — Fix Booking Policy Permissions</summary>

**When**: Specific users or groups are being declined; others can book fine.

```powershell
# Option A: Allow ALL users to book directly (simplest)
Set-CalendarProcessing -Identity $room -AllBookInPolicy $true

# Option B: Allow specific users/groups
$allowedUsers = @("<user1@domain.com>", "<SecurityGroup@domain.com>")
Set-CalendarProcessing -Identity $room -AllBookInPolicy $false -BookInPolicy $allowedUsers

# Option C: Allow all but send out-of-hours requests to delegate
Set-CalendarProcessing -Identity $room `
    -AllBookInPolicy $true `
    -AllRequestOutOfPolicy $false `
    -RequestOutOfPolicy @("<manager@domain.com>") `
    -ResourceDelegates @("<manager@domain.com>")

# Verify
Get-CalendarProcessing -Identity $room | Select AllBookInPolicy, BookInPolicy, RequestOutOfPolicy, ResourceDelegates
```

</details>

<details><summary>Fix 4 — Enforce Conflict Detection</summary>

**When**: Room is being double-booked; two meetings at same time both accepted.

```powershell
# Strict: reject ANY conflicting booking
Set-CalendarProcessing -Identity $room `
    -ConflictPercentageAllowed 0 `
    -MaximumConflictInstances 0 `
    -AllowConflicts $false

# Moderate: allow up to 20% of recurring instances to conflict (useful for large rooms)
Set-CalendarProcessing -Identity $room `
    -ConflictPercentageAllowed 20 `
    -MaximumConflictInstances 5

# Verify
Get-CalendarProcessing -Identity $room | Select ConflictPercentageAllowed, MaximumConflictInstances, AllowConflicts
```

**Note**: For rooms already in a conflicted state, manually cancel the offending meetings from the room calendar (need full access to room mailbox):
```powershell
Add-MailboxPermission -Identity $room -User <AdminUPN> -AccessRights FullAccess -InheritanceType All -AutoMapping $false
# Then open room mailbox in Outlook via Open Another Mailbox and cancel conflicts
```

</details>

<details><summary>Fix 5 — Fix Confirmation Email Issues</summary>

**When**: Meeting gets accepted but organiser receives no confirmation email, or subject/body is stripped.

```powershell
# Restore full meeting detail in confirmations
Set-CalendarProcessing -Identity $room `
    -AddOrganizerToSubject $true `
    -DeleteComments $false `
    -DeleteSubject $false `
    -RemovePrivateProperty $false `
    -AddAdditionalResponse $true `
    -AdditionalResponse "This room has been reserved. Please contact facilities if you need AV support."

# Verify the room's mailbox sends from a valid address
Get-Mailbox -Identity $room | Select PrimarySmtpAddress, EmailAddresses
```

If confirmations are going to Junk: check the organiser's safe senders list or tenant anti-spam. Room mailbox should be added as a safe sender.

If confirmations aren't arriving at all: check mail flow rules (transport rules) that might be deleting/redirecting auto-responses:
```powershell
Get-TransportRule | Where-Object { $_.State -eq "Enabled" } |
    Select Name, Description, Conditions | Format-List
```

</details>

<details><summary>Fix 6 — Convert User Mailbox to Room Mailbox</summary>

**When**: `RecipientTypeDetails = UserMailbox` instead of `RoomMailbox`. (Object created incorrectly.)

```powershell
# CAUTION: This changes the mailbox type. Test in staging first.
# The account will lose the ability to sign in interactively.
Set-Mailbox -Identity $room -Type Room

# Set room-specific properties
Set-Mailbox -Identity $room -ResourceCapacity 10  # seating capacity

# Configure calendar processing
Set-CalendarProcessing -Identity $room -AutomateProcessing AutoAccept -AllBookInPolicy $true

# Hide the account from sign-in (room mailboxes shouldn't have user sign-ins)
# This is done via AAD/Entra — block sign-in on the associated account
Connect-MgGraph -Scopes "User.ReadWrite.All"
$userId = (Get-MgUser -Filter "mail eq '$room'").Id
Update-MgUser -UserId $userId -AccountEnabled $false

# Verify
Get-Mailbox -Identity $room | Select RecipientTypeDetails, ResourceType, ResourceCapacity
```

**Rollback**:
```powershell
Set-Mailbox -Identity $room -Type Regular
# Re-enable the account in Entra if needed
```

</details>

---
## Escalation Evidence

```
=== ROOM MAILBOX ESCALATION PACK ===
Date/Time           : [datetime]
Room Display Name   : [Get-Mailbox -Identity $room | Select DisplayName]
Room UPN/SMTP       : [PrimarySmtpAddress]
Recipient Type      : [RecipientTypeDetails]
Issue Description   : [booking declined / not found / double-booked / no confirmation]

CalendarProcessing Settings:
AutomateProcessing  : [value]
AllBookInPolicy     : [value]
BookInPolicy        : [list or "(empty)"]
ResourceDelegates   : [list or "(empty)"]
ConflictPercentage  : [value]
BookingWindowDays   : [value]
MaxDurationMinutes  : [value]

HiddenFromGAL       : [value]
ResourceCapacity    : [value]

Failing User UPN    : [if applicable]
Failing User Group Membership : [if applicable]

Calendar Permissions:
[paste: Get-MailboxFolderPermission -Identity "${room}:\Calendar"]

Recent booking decline examples:
[message subject, sender, date/time of decline notice]

Transport Rule interference:
[paste: Get-TransportRule | Where State -eq Enabled | Select Name, Conditions]
```

---
## 🎓 Learning Pointers

- **`AutomateProcessing` has three states, not two**: `AutoAccept` (auto-accept everything in policy), `AutoUpdate` (accept but requires delegate approval for out-of-policy), and `None` (manual processing by delegate — everything goes to inbox). Most deployments should use `AutoAccept` with `AllBookInPolicy $true` for simplicity. Ref: https://learn.microsoft.com/en-us/powershell/module/exchange/set-calendarprocessing

- **`BookInPolicy` vs `AllBookInPolicy`**: These are commonly confused. `AllBookInPolicy $true` overrides `BookInPolicy` and opens the room to everyone. If you set `AllBookInPolicy $false`, only users/groups in the `BookInPolicy` array can book directly. Users/groups in `RequestInPolicy` can request (goes to delegate). Users in neither get a flat decline.

- **Room account sign-in should be blocked in Entra**: Room mailboxes need an associated user account in AAD/Entra to exist as an Exchange recipient. That account should have sign-in blocked (`AccountEnabled = $false`) and no password, otherwise it's an attack surface. Verify this for every room in the tenant.

- **The scheduling assistant won't show accurate free/busy without calendar permissions**: Default is `AvailabilityOnly` which is usually correct. But if it was changed to `None`, users see "No information" and often think the room is broken. Check with `Get-MailboxFolderPermission -Identity "${room}:\Calendar"` — reset to default if needed: `Set-MailboxFolderPermission -Identity "${room}:\Calendar" -User Default -AccessRights AvailabilityOnly`

- **Recurring meeting conflicts**: `ConflictPercentageAllowed` and `MaximumConflictInstances` only apply to recurring series, not single instances. For a recurring booking, if the conflict count exceeds both thresholds, the entire series is declined. Consider raising `MaximumConflictInstances` for large conference rooms in busy environments. Single-instance meetings always use strict conflict checking.

- **Hybrid environments have extra complexity**: In Exchange Hybrid, room mailboxes managed on-premises must have their `CalendarProcessing` set via on-prem Exchange PowerShell, not EXO. Free/busy cross-premises also requires Organisation Relationship / Availability Address Space to be healthy. If a room appears available but bookings fail, check the hybrid config first: `Get-HybridMailflowDatacenterIPs` and `Test-OAuthConnectivity`.
