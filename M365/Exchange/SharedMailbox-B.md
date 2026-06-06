# Exchange Online Shared Mailbox — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes. Covers access failures, AutoMapping, Send As, Send On Behalf, and calendar delegate permissions.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

```powershell
# Connect first (skip if already connected)
Connect-ExchangeOnline -UserPrincipalName admin@contoso.com

# 1. Confirm the shared mailbox exists and get its type
Get-Mailbox -Identity shared@contoso.com |
  Select DisplayName, PrimarySmtpAddress, RecipientTypeDetails, IsShared,
         LitigationHoldEnabled, ArchiveStatus

# RecipientTypeDetails should be: SharedMailbox
# If UserMailbox: it was converted or created wrong

# 2. Check who has Full Access permission
Get-MailboxPermission -Identity shared@contoso.com |
  Where-Object { $_.User -notlike "NT AUTHORITY*" -and $_.User -notlike "S-1-5*" } |
  Select User, AccessRights, IsInherited, Deny | Format-Table -AutoSize

# 3. Check Send As permission
Get-RecipientPermission -Identity shared@contoso.com |
  Where-Object { $_.Trustee -notlike "NT AUTHORITY*" } |
  Select Trustee, AccessRights | Format-Table -AutoSize

# 4. Check Send On Behalf permission
Get-Mailbox -Identity shared@contoso.com |
  Select -ExpandProperty GrantSendOnBehalfTo

# 5. Check AutoMapping setting for a specific user
Get-MailboxPermission -Identity shared@contoso.com -User user@contoso.com |
  Select User, AccessRights, AutoMapping
```

**Interpret immediately:**

| Symptom | Quick check | Go to |
|---------|------------|-------|
| Can't open shared mailbox at all | `Get-MailboxPermission` — is user listed? | [Fix 1](#fix-1--user-missing-full-access-permission) |
| Has Full Access but not showing in Outlook | AutoMapping = True but Outlook not refreshed | [Fix 2](#fix-2--automapping-not-working--mailbox-not-appearing-in-outlook) |
| "Send As" rejected — "You don't have permission" | `Get-RecipientPermission` — Trustee missing | [Fix 3](#fix-3--send-as-permission-not-working) |
| "Send On Behalf" email shows "on behalf of" but user wants full Send As | Wrong permission type assigned | [Fix 4](#fix-4--send-on-behalf-vs-send-as-confusion) |
| Calendar permissions broken / delegate can't see free/busy | `Get-MailboxFolderPermission` | [Fix 5](#fix-5--calendar-delegate-permissions-broken) |
| Shared mailbox has a licence assigned | `Get-MsolUser` or Admin Center — licence shows | [Fix 6](#fix-6--shared-mailbox-incorrectly-licensed) |

---

## Dependency Cascade

<details><summary>What must be true for a shared mailbox to work correctly</summary>

```
[Shared mailbox object exists in Exchange Online]
  RecipientTypeDetails = SharedMailbox (not UserMailbox)
  No user licence required unless: archive enabled, Litigation Hold, or > 50 GB mailbox
         │
         ▼
[User has Full Access permission on the shared mailbox]
  Set via Add-MailboxPermission (EXO, persists in directory)
  Propagation time: up to 60 minutes after grant
         │
         ▼
[AutoMapping]
  AutoMapping = True (default) → Outlook automatically adds the mailbox to the profile
  AutoMapping works via: Full Access grant → EXO stamps the user's msExchDelegateListLink
  Outlook reads this attribute on profile load → adds shared mailbox to folder list
  ✗ AutoMapping = False → user must manually add via File → Account Settings → More Settings
  ✗ Outlook must be restarted (or profile rebuilt) for AutoMapping to take effect
         │
         ▼
[Send As / Send On Behalf]
  Send As = add via Add-RecipientPermission (EXO)
    → Outlook shows "From: shared@contoso.com" — recipient sees the shared address only
  Send On Behalf = add via Set-Mailbox -GrantSendOnBehalfTo
    → Recipient sees "Sender: user@contoso.com on behalf of shared@contoso.com"
  ✗ These are different permissions; assigning the wrong one causes confusion
         │
         ▼
[Calendar delegate access]
  Set via Add-MailboxFolderPermission on the Calendar folder
  Delegate permissions (Editor, Reviewer, etc.) are independent of Full Access
  Full Access does NOT automatically grant calendar editing rights to delegates
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm mailbox type and state**
```powershell
Get-Mailbox -Identity shared@contoso.com | Format-List `
  DisplayName, PrimarySmtpAddress, RecipientTypeDetails, IsShared,
  ProhibitSendReceiveQuota, ArchiveStatus, LitigationHoldEnabled,
  HiddenFromAddressListsEnabled

# Key checks:
# RecipientTypeDetails = SharedMailbox  ← must be this
# HiddenFromAddressListsEnabled = False ← if True, won't appear in GAL
# ArchiveStatus = None (unless archive explicitly needed)
```

**Step 2 — Audit Full Access permissions**
```powershell
# All non-system users with Full Access
Get-MailboxPermission -Identity shared@contoso.com |
  Where-Object {
    $_.User -notlike "NT AUTHORITY*" -and
    $_.User -notlike "S-1-5*" -and
    $_.AccessRights -contains "FullAccess"
  } |
  Select User, AccessRights, AutoMapping, IsInherited, Deny | Format-Table

# Check a specific user's exact access + AutoMapping flag
Get-MailboxPermission -Identity shared@contoso.com -User user@contoso.com |
  Select User, AccessRights, AutoMapping
```

**Step 3 — Audit Send As permission**
```powershell
Get-RecipientPermission -Identity shared@contoso.com |
  Where-Object { $_.Trustee -notlike "NT AUTHORITY*" } |
  Select Trustee, AccessRights, IsInherited | Format-Table
```

**Step 4 — Audit Send On Behalf permission**
```powershell
(Get-Mailbox -Identity shared@contoso.com).GrantSendOnBehalfTo
# Returns list of users who can send on behalf
# Empty = nobody has this permission
```

**Step 5 — Audit calendar permissions**
```powershell
# Get current calendar permissions
Get-MailboxFolderPermission -Identity "shared@contoso.com:\Calendar" |
  Select User, AccessRights, SharingPermissionFlags | Format-Table

# Check a specific user's calendar access level
Get-MailboxFolderPermission -Identity "shared@contoso.com:\Calendar" -User user@contoso.com
```

**Step 6 — Check licence state (shared mailboxes should NOT be licensed)**
```powershell
# Connect to Microsoft Graph if not already
Connect-MgGraph -Scopes "User.Read.All"

# Check if the shared mailbox has any licence assigned
Get-MgUserLicenseDetail -UserId shared@contoso.com |
  Select SkuPartNumber, SkuId

# No output = correct (unlicensed)
# Output present = shared mailbox has a licence assigned — see Fix 6
```

**Step 7 — Check mailbox statistics (is it full?)**
```powershell
Get-MailboxStatistics -Identity shared@contoso.com |
  Select DisplayName, TotalItemSize, ItemCount, StorageLimitStatus
# Shared mailbox default quota: 50 GB (no licence needed up to this limit)
# Beyond 50 GB: requires Exchange Plan 2 or Exchange Online Archiving
```

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — User missing Full Access permission</summary>

```powershell
# Grant Full Access (with AutoMapping on — default, recommended)
Add-MailboxPermission `
  -Identity shared@contoso.com `
  -User user@contoso.com `
  -AccessRights FullAccess `
  -InheritanceType All

# Verify the grant
Get-MailboxPermission -Identity shared@contoso.com -User user@contoso.com |
  Select User, AccessRights, AutoMapping

# Propagation time: up to 60 minutes
# User must restart Outlook after propagation for AutoMapping to take effect
```

> For security groups: you can grant Full Access to a group, but AutoMapping does NOT work with groups — only with individual user accounts. If AutoMapping is needed, grant per-user.

</details>

<details id="fix-2"><summary>Fix 2 — AutoMapping not working / mailbox not appearing in Outlook</summary>

**Symptom:** User has Full Access but shared mailbox doesn't auto-appear in Outlook left pane

```powershell
# Check AutoMapping flag for this user
Get-MailboxPermission -Identity shared@contoso.com -User user@contoso.com |
  Select User, AccessRights, AutoMapping
# If AutoMapping = False → remove and re-add the permission with AutoMapping enabled

# Step 1: Remove the existing permission
Remove-MailboxPermission `
  -Identity shared@contoso.com `
  -User user@contoso.com `
  -AccessRights FullAccess `
  -InheritanceType All `
  -Confirm:$false

# Step 2: Re-add WITH AutoMapping (the default; explicit here for clarity)
Add-MailboxPermission `
  -Identity shared@contoso.com `
  -User user@contoso.com `
  -AccessRights FullAccess `
  -InheritanceType All `
  -AutoMapping $true

# Step 3: User must fully restart Outlook (File → Exit, not just close window)
# On cached mode: Outlook may take one full restart to pick up the new auto-mapped mailbox
# If still not showing after restart: rebuild Outlook profile
#   Control Panel → Mail → Show Profiles → Add new profile

# If user DOESN'T want AutoMapping (prefers to add manually):
Add-MailboxPermission `
  -Identity shared@contoso.com `
  -User user@contoso.com `
  -AccessRights FullAccess `
  -InheritanceType All `
  -AutoMapping $false

# Manual add in Outlook: File → Account Settings → Account Settings → Change →
#   More Settings → Advanced → Add → type shared mailbox address
```

> AutoMapping requires Autodiscover to be working. If Autodiscover is broken, Outlook can't discover the shared mailbox even if AutoMapping = True.

</details>

<details id="fix-3"><summary>Fix 3 — Send As permission not working</summary>

**Symptom:** User gets error "You don't have permission to send the message on behalf of the specified user" or "You can only send from your own address" when trying to send from the shared mailbox address

```powershell
# Grant Send As permission
Add-RecipientPermission `
  -Identity shared@contoso.com `
  -Trustee user@contoso.com `
  -AccessRights SendAs `
  -Confirm:$false

# Verify
Get-RecipientPermission -Identity shared@contoso.com |
  Where-Object { $_.Trustee -eq "user@contoso.com" } |
  Select Trustee, AccessRights

# Propagation: up to 60 minutes; Outlook must be restarted
# After restart: in New Email → From field → select shared mailbox address
# If From field not visible: Options tab → Show From
```

> Note: Send As and Full Access are independent permissions. A user can have one without the other. For full shared mailbox functionality, users typically need both.

</details>

<details id="fix-4"><summary>Fix 4 — Send On Behalf vs Send As confusion</summary>

**Symptom:** User is set up with Send On Behalf but wants recipients to see only the shared mailbox address (not "on behalf of")

**The difference:**
- **Send As** → recipient sees: `From: shared@contoso.com` — user identity completely hidden
- **Send On Behalf** → recipient sees: `From: user@contoso.com on behalf of shared@contoso.com` — user is visible

```powershell
# If the user needs Send As (hide personal address):
# Step 1: Remove Send On Behalf if set
Set-Mailbox -Identity shared@contoso.com `
  -GrantSendOnBehalfTo @{Remove="user@contoso.com"}

# Step 2: Grant Send As instead
Add-RecipientPermission `
  -Identity shared@contoso.com `
  -Trustee user@contoso.com `
  -AccessRights SendAs `
  -Confirm:$false

# If the user needs Send On Behalf (e.g. "newsletters on behalf of team"):
# Remove Send As if set
Remove-RecipientPermission `
  -Identity shared@contoso.com `
  -Trustee user@contoso.com `
  -AccessRights SendAs `
  -Confirm:$false

# Grant Send On Behalf
Set-Mailbox -Identity shared@contoso.com `
  -GrantSendOnBehalfTo @{Add="user@contoso.com"}

# Verify both
Get-RecipientPermission -Identity shared@contoso.com | Select Trustee, AccessRights
(Get-Mailbox -Identity shared@contoso.com).GrantSendOnBehalfTo
```

</details>

<details id="fix-5"><summary>Fix 5 — Calendar delegate permissions broken</summary>

**Symptom:** User has Full Access to shared mailbox but can't view/edit its calendar; or a delegate can't accept/decline meeting requests

```powershell
# Check current calendar permissions
Get-MailboxFolderPermission -Identity "shared@contoso.com:\Calendar" |
  Select User, AccessRights, SharingPermissionFlags | Format-Table

# Common access levels:
#   None       = no access
#   Reviewer   = read-only (can see items)
#   Author     = create + read (can't edit others' items)
#   Editor     = full create/read/edit/delete
#   PublishingEditor = Editor + can create subfolders
#   Owner      = all permissions including delegate management

# Grant calendar access to a user
Add-MailboxFolderPermission `
  -Identity "shared@contoso.com:\Calendar" `
  -User user@contoso.com `
  -AccessRights Editor

# If user already has a permission entry but wrong level — use Set, not Add
Set-MailboxFolderPermission `
  -Identity "shared@contoso.com:\Calendar" `
  -User user@contoso.com `
  -AccessRights Editor

# Remove permission entry entirely
Remove-MailboxFolderPermission `
  -Identity "shared@contoso.com:\Calendar" `
  -User user@contoso.com `
  -Confirm:$false

# For delegate to receive meeting requests (not just view calendar):
# The meeting forwarding is controlled by the mailbox owner (or admin) in Outlook
# Go to: File → Account Settings → Delegate Access → Add delegate → check "receives copies of meeting-related messages"
# Or via PowerShell — set forwarding rule on shared mailbox to forward invitations to delegate

# Check Default and Anonymous permissions (affects free/busy visibility organisation-wide)
Get-MailboxFolderPermission -Identity "shared@contoso.com:\Calendar" |
  Where-Object { $_.User.DisplayName -in "Default","Anonymous" }
# Default = all internal users; AccessRights "AvailabilityOnly" = free/busy only (recommended)
```

</details>

<details id="fix-6"><summary>Fix 6 — Shared mailbox incorrectly licensed</summary>

**Symptom:** Shared mailbox has an active user licence assigned; tenant being charged; policy warning in admin center

```powershell
# Check licence on the shared mailbox account
Connect-MgGraph -Scopes "User.Read.All","Directory.ReadWrite.All"

$mbx = Get-MgUser -UserId shared@contoso.com
Get-MgUserLicenseDetail -UserId $mbx.Id | Select SkuPartNumber

# Remove the licence
$licenceSkuId = (Get-MgUserLicenseDetail -UserId $mbx.Id | Select -First 1 -ExpandProperty SkuId)
Set-MgUserLicense `
  -UserId $mbx.Id `
  -AddLicenses @() `
  -RemoveLicenses @($licenceSkuId)

# Verify licence removed
Get-MgUserLicenseDetail -UserId $mbx.Id
# Expected: no output
```

**When does a shared mailbox NEED a licence?**
- **Exchange Online Archiving** required → assign Exchange Online Archiving add-on (not a full user licence)
- **Mailbox > 50 GB** → shared mailboxes get 50 GB free; above that, assign Exchange Plan 2
- **Litigation Hold longer than 30 days** → requires Exchange Plan 2
- **In-Place Hold** → requires Exchange Plan 2

> A full user licence (M365 E3/E5, Business Premium, etc.) should never be assigned to a shared mailbox unless you're temporarily using it as a user account during migration.

</details>

<details><summary>Fix 7 — Shared mailbox hidden from Global Address List</summary>

**Symptom:** Users searching the GAL can't find the shared mailbox; autocomplete doesn't suggest it

```powershell
# Check if hidden
Get-Mailbox -Identity shared@contoso.com | Select HiddenFromAddressListsEnabled

# Unhide from GAL
Set-Mailbox -Identity shared@contoso.com -HiddenFromAddressListsEnabled $false

# Allow up to 24 hours for GAL sync; Outlook must refresh the offline address book
# Force OAB refresh in Outlook: Send/Receive → Send/Receive Groups → Download Address Book
```

</details>

---

## Escalation Evidence

```
Shared Mailbox Issue — Evidence Pack
=====================================
Tenant:                        
Shared mailbox address:        
RecipientTypeDetails:          [SharedMailbox / UserMailbox — output from Get-Mailbox]
Affected user(s):              
Issue type:                    [Access / AutoMapping / Send As / Send On Behalf / Calendar / GAL]
Get-MailboxPermission output:  [paste User + AccessRights + AutoMapping columns]
Get-RecipientPermission:       [paste Trustee + AccessRights]
GrantSendOnBehalfTo:           [paste list]
Calendar permissions:          [paste Get-MailboxFolderPermission output]
Licence state:                 [licensed Y/N, which SKU]
Mailbox quota / size:          [TotalItemSize + StorageLimitStatus]
Outlook version:               [Build number — Help → About Outlook]
Outlook profile type:          [Cached mode / Online mode]
AutoDiscover working:          [Test via https://testconnectivity.microsoft.com]
Steps already tried:           
```

---

## 🎓 Learning Pointers

- **AutoMapping is an Autodiscover-dependent feature** — Outlook reads the shared mailbox list from a property on the user's mailbox (`msExchDelegateListLink`) via Autodiscover. If Autodiscover is misconfigured (wrong CNAME, broken SRV record, or Outlook not trusting the autodiscover endpoint), AutoMapping silently fails even though the permission is correctly set. Always validate Autodiscover when AutoMapping doesn't work after a correct permission grant. [MS Docs: Autodiscover for Exchange](https://learn.microsoft.com/en-us/exchange/architecture/client-access/autodiscover)
- **Send As vs Send On Behalf — know the user experience difference cold** — Send As is the right choice when the shared mailbox represents a role or team address (support@, billing@, info@) and you want the user's personal identity completely hidden. Send On Behalf is appropriate for executives or managers who want it known a delegate is acting for them. Getting this wrong creates re-work and confused users. The permissions cmdlets are different too: `Add-RecipientPermission` for Send As, `Set-Mailbox -GrantSendOnBehalfTo` for Send On Behalf.
- **Shared mailbox licensing rules** — the default 50 GB free quota with no licence is a Microsoft design choice, not a flaw. Shared mailboxes that exceed 50 GB or need archiving/Litigation Hold require Exchange Plan 2 (or the standalone Exchange Online Archiving add-on). Assigning a full user licence (M365 E3/Business Premium) is wasteful and unnecessary. Understand what features actually require a licence. [MS Docs: Shared Mailbox Limits](https://learn.microsoft.com/en-us/microsoft-365/admin/email/about-shared-mailboxes)
- **Permission propagation delay is real** — Full Access and Send As changes in Exchange Online take up to 60 minutes to propagate through the service. Add-RecipientPermission for Send As has historically been slower than Add-MailboxPermission. If a user says "the permission isn't working" 5 minutes after you granted it, wait and retry before diagnosing further. The Outlook client also caches permission state — a full restart (not just window close) is required.
- **Full Access does NOT grant Send As** — this is the most common shared mailbox misunderstanding. Full Access lets you open and read the mailbox. Send As lets you send email from its address. They must be granted independently. A user with only Full Access who tries to send from the shared mailbox address will get a permissions error in Outlook's From field selection.
- **Calendar permissions and Full Access are independent** — granting Full Access to a shared mailbox does not automatically grant calendar editing rights. Calendar folder permissions must be set separately via `Add-MailboxFolderPermission`. This catches engineers who grant Full Access expecting calendar delegation to work, then wonder why the calendar is read-only.
