# Shared Mailbox — Reference Runbook (Mode A: Deep Dive)
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
- Shared mailbox creation and lifecycle (cloud-only and hybrid)
- Access delegation: Full Access, Send As, Send on Behalf
- Auto-mapping behaviour and Outlook client behaviour
- Shared mailbox licensing rules (50 GB vs licensed scenarios)
- Hybrid shared mailboxes (on-prem → cloud migration paths)
- Forwarding, calendar sharing, and mobile access quirks
- Common break patterns introduced by Entra Connect sync

**Does not cover:**
- Room/Equipment mailboxes (similar but distinct feature set)
- Microsoft 365 Groups (a separate object type)
- Distribution groups or mail-enabled security groups

**Assumed role:** Exchange Administrator or Global Admin. All commands run against Exchange Online via `Connect-ExchangeOnline`.

**Versions:** Exchange Online (EXO v3 module). Hybrid scenarios assume Exchange Server 2016+ on-prem.

---

## How It Works

<details><summary>Full architecture</summary>

### Object Model

A shared mailbox in Exchange Online is a **disabled-sign-in user object** in Entra ID combined with an **Exchange mailbox** of type `SharedMailbox`. The user account intentionally has no password usable for interactive sign-in (sign-in is blocked at the Entra level unless explicitly enabled for SMTP AUTH or legacy scenarios).

```
Entra ID
└── User Object (AccountEnabled = false / sign-in blocked)
    └── Exchange Online
        └── Mailbox (RecipientTypeDetails = SharedMailbox)
            ├── Primary SMTP address (e.g. support@contoso.com)
            ├── Additional SMTP aliases
            ├── Full Access delegates → auto-map in Outlook
            ├── Send As delegates  → send FROM the mailbox address
            └── Send on Behalf → send "on behalf of" the mailbox
```

### Delegation Mechanics

**Full Access** grants the right to open the mailbox folder hierarchy. It does NOT grant Send As rights. Auto-mapping (Outlook adds the mailbox automatically without user action) is an Exchange-level feature driven by the `msExchDelegateListLink` attribute — it works for Full Access only.

**Send As** is an Active Directory permission (`SendAs` extended right on the object) surfaced through Exchange. When a delegate sends mail, the From header shows the shared mailbox address with no "on behalf of" qualifier. This is the most common delegation for support team scenarios.

**Send on Behalf** (Exchange `GrantSendOnBehalfTo` parameter) allows sending where the From header reads: `Delegate Name <shared@contoso.com> on behalf of Shared Mailbox`. This is less common but preferred in some legal/compliance contexts.

### Licensing

Shared mailboxes up to **50 GB do not require a license** — Exchange Online Plan 1 coverage is included implicitly. Above 50 GB, or to enable Litigation Hold / In-Place Archive / Microsoft 365 Compliance features, an Exchange Online Plan 2 (or M365 E3/E5) license must be assigned to the shared mailbox user object. Assigning a license to a shared mailbox converts it to a regular mailbox unless the `RecipientTypeDetails` is deliberately kept as SharedMailbox.

### Hybrid Considerations

In hybrid deployments, shared mailboxes can exist:
1. **Cloud-only** — created directly in EXO, no on-prem counterpart
2. **On-prem mastered** — created in on-prem AD, migrated to cloud via Move-MoveRequest; Entra Connect syncs the object; the cloud mailbox is authoritative after migration
3. **Linked** — rare; mailbox in cloud, user account managed on-prem

The hybrid scenario introduces a mastering problem: if you attempt to manage mail attributes (SMTP aliases, forwarding) from both on-prem EAC and EXO simultaneously, write-back conflicts occur. After migration, manage exclusively from EXO.

</details>

---

## Dependency Stack

```
User Action: Open shared mailbox in Outlook
        │
        ▼
Outlook AutoDiscover ──────────────────────────────────────────────┐
        │  (DNS SRV or HTTPS autodiscover.<domain>)                │
        ▼                                                          │
Exchange Online Autodiscover Service                               │
        │  Returns mailbox endpoint                                │
        ▼                                                          │
Exchange Online Mailbox Server                                     │
        │                                                          │
        ├── Entra ID User Object (must exist, sign-in blocked OK)  │
        │       └── ObjectId maps to ExchangeGUID                  │
        │                                                          │
        ├── Delegation ACLs (Full Access / Send As / SoB)          │
        │       └── Stored on mailbox object in EXO                │
        │                                                          │
        ├── Auto-mapping Service (msExchDelegateListLink attr)     │
        │       └── Triggers Outlook to silently mount mailbox     │
        │                                                          │
        └── SMTP Namespace (Primary + Aliases)                     │
                └── MX record → EXO mail routing                   │
                                                                   │
[Hybrid only]                                                      │
On-prem AD ──► Entra Connect Sync ──► Entra ID ───────────────────┘
        (AADConnect must not overwrite EXO attributes post-migration)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| User cannot open shared mailbox in Outlook | Full Access not granted; or auto-mapping disabled | `Get-MailboxPermission -Identity <sharedMBX>` |
| Shared mailbox appeared then disappeared from Outlook | Auto-mapping toggled; Full Access removed and re-added | Check `AutoMapping` param on `Add-MailboxPermission` |
| "You don't have permission to send from this address" | Send As not granted (only Full Access was set) | `Get-RecipientPermission -Identity <sharedMBX>` |
| Sent items appear in delegate's mailbox, not shared mailbox | `MessageCopyForSentAsEnabled` not set | `Get-Mailbox <sharedMBX> | select MessageCopyForSentAs*` |
| Shared mailbox receiving external mail bouncing (550 5.1.1) | MX record incorrect; or mailbox deleted and recreated with new ExchangeGUID | Verify MX record; check `Get-Mailbox` ExchangeGUID |
| Cannot add SMTP alias (address already exists error) | Address in use on another object | `Get-Recipient -Filter "EmailAddresses -eq 'alias@domain.com'"` |
| Shared mailbox over quota / stopped receiving mail | Mailbox size exceeded 50 GB; no license assigned | `Get-MailboxStatistics <sharedMBX> | select TotalItemSize` |
| Hybrid: changes made in EXO get overwritten | Entra Connect still mastering the object | Check AADConnect sync scope; move management to cloud |
| Mobile (Outlook for iOS/Android) can't access shared mailbox | App-specific issue with delegate access; or MFA blocking | Test via OWA first; check CA policies targeting EXO |
| Calendar not visible/shareable from shared mailbox | Calendar permissions not explicitly set | `Get-MailboxFolderPermission <sharedMBX>:\Calendar` |

---

## Validation Steps

**1. Confirm mailbox exists and type**
```powershell
Get-Mailbox -Identity "support@contoso.com" | Select DisplayName, RecipientTypeDetails, PrimarySmtpAddress, IsMailboxEnabled, ProhibitSendQuota, ProhibitSendReceiveQuota
```
_Good:_ `RecipientTypeDetails = SharedMailbox`, `IsMailboxEnabled = True`  
_Bad:_ `RecipientTypeDetails = UserMailbox` — mailbox was incorrectly licensed and converted

**2. Check current size vs quota**
```powershell
Get-MailboxStatistics -Identity "support@contoso.com" | Select DisplayName, TotalItemSize, ItemCount, @{N='SizeMB';E={[math]::Round($_.TotalItemSize.Value.ToMB(),1)}}
```
_Good:_ Under 47,500 MB (leave headroom before 50 GB)  
_Bad:_ Approaching or over 50,000 MB without a license

**3. Validate Full Access delegates**
```powershell
Get-MailboxPermission -Identity "support@contoso.com" | Where-Object {$_.AccessRights -eq "FullAccess" -and $_.IsInherited -eq $false} | Select User, AccessRights, Deny
```
_Good:_ Target user or group appears with `Deny = False`  
_Bad:_ User absent; or `Deny = True` (explicit deny overrides all allows)

**4. Validate Send As delegates**
```powershell
Get-RecipientPermission -Identity "support@contoso.com" | Where-Object {$_.Trustee -ne "NT AUTHORITY\SELF"} | Select Trustee, AccessRights
```
_Good:_ Delegate listed with `SendAs`  
_Bad:_ Delegate absent — they can open the mailbox but not send as it

**5. Check Sent Items copy behaviour**
```powershell
Get-Mailbox -Identity "support@contoso.com" | Select MessageCopyForSentAsEnabled, MessageCopyForSendOnBehalfEnabled
```
_Good:_ `True` for whichever delegation type is in use  
_Bad:_ `False` — sent items land in delegate's Sent Items only

**6. Verify SMTP aliases**
```powershell
Get-Mailbox -Identity "support@contoso.com" | Select -ExpandProperty EmailAddresses | Sort
```
_Good:_ All expected aliases listed with `smtp:` prefix; primary has `SMTP:` (uppercase)  
_Bad:_ Missing alias; or unexpected alias pointing elsewhere

**7. Check sign-in status of the underlying user account**
```powershell
# Requires Microsoft.Graph or AzureAD module
Get-MgUser -UserId "support@contoso.com" | Select DisplayName, AccountEnabled, SignInActivity
```
_Good:_ `AccountEnabled = False` (normal for shared mailbox)  
_Bad:_ `AccountEnabled = True` with no MFA — a security risk requiring remediation

---

## Troubleshooting Steps (by phase)

### Phase 1 — Access Issues (user can't open the mailbox)

1. Confirm Full Access is granted (Validation Step 3)
2. Confirm auto-mapping setting:
   ```powershell
   # Check — there's no direct "get" cmdlet for AutoMapping; review the permission add command history
   # To re-add with auto-mapping explicitly enabled:
   Remove-MailboxPermission -Identity "support@contoso.com" -User "alice@contoso.com" -AccessRights FullAccess -Confirm:$false
   Add-MailboxPermission -Identity "support@contoso.com" -User "alice@contoso.com" -AccessRights FullAccess -AutoMapping $true
   ```
3. If auto-mapping is unwanted (large deployments, Outlook performance):
   ```powershell
   Add-MailboxPermission -Identity "support@contoso.com" -User "alice@contoso.com" -AccessRights FullAccess -AutoMapping $false
   # User must manually add via File > Open & Export > Other User's Folder
   ```
4. Allow 30-60 minutes for auto-mapping to propagate to Outlook. Outlook profile restart required.

### Phase 2 — Send As Issues

1. Confirm Send As is granted (Validation Step 4)
2. If missing, add it:
   ```powershell
   Add-RecipientPermission -Identity "support@contoso.com" -Trustee "alice@contoso.com" -AccessRights SendAs -Confirm:$false
   ```
3. Verify user is selecting the shared mailbox From address in Outlook (not their personal address)
4. If using Outlook for Mac or OWA, the "From" field must be manually added/switched

### Phase 3 — Sent Items Not in Shared Mailbox

```powershell
Set-Mailbox -Identity "support@contoso.com" -MessageCopyForSentAsEnabled $true -MessageCopyForSendOnBehalfEnabled $true
```
Propagation time: typically 5-15 minutes. No Outlook restart needed.

### Phase 4 — Quota / Size Issues

1. Check size (Validation Step 2)
2. If under 50 GB but blocked — check `ProhibitSendQuota` and `ProhibitSendReceiveQuota`:
   ```powershell
   Get-Mailbox "support@contoso.com" | Select ProhibitSendQuota, ProhibitSendReceiveQuota, UseDatabaseQuotaDefaults
   ```
3. If `UseDatabaseQuotaDefaults = True`, the mailbox inherits default quota. Override explicitly:
   ```powershell
   Set-Mailbox "support@contoso.com" -ProhibitSendQuota 49GB -ProhibitSendReceiveQuota 50GB -UseDatabaseQuotaDefaults $false
   ```
4. If genuinely over 50 GB, assign a license OR archive old items:
   ```powershell
   # Enable archive mailbox
   Enable-Mailbox "support@contoso.com" -Archive
   # Then configure auto-archiving via retention policy
   ```

### Phase 5 — Hybrid Mastering Conflicts

1. Identify if object is synced from on-prem:
   ```powershell
   Get-Mailbox "support@contoso.com" | Select IsDirSynced, ExternalDirectoryObjectId
   ```
2. If `IsDirSynced = True` and the mailbox is now in Exchange Online, check AADConnect sync rules to ensure EXO-authoritative attributes aren't being overwritten
3. To stop Entra Connect from overwriting specific attributes, use the Synchronization Rules Editor on the AADConnect server to set those attributes to `Constant` (not recommended to do blanket — be surgical)
4. Correct approach: complete migration, then exclude the user from AADConnect scope to prevent further sync conflicts — or use the Preferred Data Location / Exchange Hybrid write-back feature correctly

---

## Remediation Playbooks

<details><summary>Playbook 1 — Create a new shared mailbox</summary>

```powershell
# Connect first
Connect-ExchangeOnline -UserPrincipalName <adminUPN>

# Create shared mailbox
New-Mailbox -Shared -Name "Support Team" -DisplayName "Support Team" `
    -Alias "support" -PrimarySmtpAddress "support@contoso.com"

# Grant Full Access with auto-mapping
Add-MailboxPermission -Identity "support@contoso.com" `
    -User "alice@contoso.com" -AccessRights FullAccess -AutoMapping $true

# Grant Send As
Add-RecipientPermission -Identity "support@contoso.com" `
    -Trustee "alice@contoso.com" -AccessRights SendAs -Confirm:$false

# Enable Sent Items copy
Set-Mailbox "support@contoso.com" `
    -MessageCopyForSentAsEnabled $true `
    -MessageCopyForSendOnBehalfEnabled $true

Write-Host "Shared mailbox created and configured." -ForegroundColor Green
```

**Rollback:** `Remove-Mailbox "support@contoso.com" -Confirm:$false`  
⚠️ Removal is destructive. Mailbox is soft-deleted and recoverable for 30 days via `Undo-SoftDeletedMailbox`.

</details>

<details><summary>Playbook 2 — Bulk grant access from a group</summary>

```powershell
# Grant all members of a security group access to a shared mailbox
$GroupMembers = Get-DistributionGroupMember -Identity "SupportTeam" -ResultSize Unlimited
foreach ($member in $GroupMembers) {
    Add-MailboxPermission -Identity "support@contoso.com" `
        -User $member.PrimarySmtpAddress `
        -AccessRights FullAccess -AutoMapping $false -Confirm:$false
    Add-RecipientPermission -Identity "support@contoso.com" `
        -Trustee $member.PrimarySmtpAddress `
        -AccessRights SendAs -Confirm:$false
    Write-Host "Granted: $($member.DisplayName)" -ForegroundColor Cyan
}
```

**Note:** Auto-mapping set to `$false` for bulk grants — auto-mapping 10+ mailboxes degrades Outlook performance.

</details>

<details><summary>Playbook 3 — Add SMTP alias to shared mailbox</summary>

```powershell
$mailbox = Get-Mailbox "support@contoso.com"
$aliases = $mailbox.EmailAddresses

# Check alias not already in use
$existing = Get-Recipient -Filter "EmailAddresses -eq 'helpdesk@contoso.com'" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Warning "Address helpdesk@contoso.com is already used by: $($existing.DisplayName)"
} else {
    $aliases += "smtp:helpdesk@contoso.com"
    Set-Mailbox "support@contoso.com" -EmailAddresses $aliases
    Write-Host "Alias added." -ForegroundColor Green
}
```

**Rollback:** Remove the alias from `$aliases` and run `Set-Mailbox` again with the original array.

</details>

<details><summary>Playbook 4 — Convert user mailbox to shared</summary>

```powershell
# Useful when a leaver's mailbox should become a shared access inbox
Set-Mailbox -Identity "leaver@contoso.com" -Type Shared

# Block sign-in at Entra level
# (requires Graph or AzureAD module)
Update-MgUser -UserId "leaver@contoso.com" -AccountEnabled:$false

# Grant access to manager
Add-MailboxPermission -Identity "leaver@contoso.com" `
    -User "manager@contoso.com" -AccessRights FullAccess -AutoMapping $true

# Remove license (save cost — shared mailbox doesn't need one up to 50GB)
# Do this via M365 Admin Centre or Graph API
Write-Host "Mailbox converted to shared. Remove license in M365 Admin to save costs." -ForegroundColor Yellow
```

⚠️ Removing a license will also remove Teams, OneDrive, and other assigned services. Confirm scope with manager before proceeding.

</details>

<details><summary>Playbook 5 — Recover a deleted shared mailbox</summary>

```powershell
# Soft-deleted mailboxes are recoverable for 30 days
Get-Mailbox -SoftDeletedMailbox | Where-Object {$_.DisplayName -like "*Support*"} | Select DisplayName, PrimarySmtpAddress, WhenSoftDeleted, ExchangeGuid

# Restore
Undo-SoftDeletedMailbox -SoftDeletedObject <ExchangeGuid> -WindowsLiveID "support@contoso.com"

# If primary address conflict, specify new name:
# Undo-SoftDeletedMailbox -SoftDeletedObject <ExchangeGuid> -WindowsLiveID "support-restored@contoso.com"
```

After 30 days the mailbox enters the **purge queue** and is unrecoverable without litigation hold or a content search backup.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS Collect shared mailbox diagnostic evidence for escalation
.NOTES Run as Exchange Admin. Outputs to CSV files for ticket attachment.
#>
param(
    [Parameter(Mandatory)][string]$SharedMailboxIdentity,
    [string]$OutputPath = "$env:TEMP\SharedMBX-Evidence"
)

Connect-ExchangeOnline -UserPrincipalName (Read-Host "Admin UPN")
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# Mailbox summary
Get-Mailbox $SharedMailboxIdentity | Select * | Export-Csv "$OutputPath\mailbox-properties.csv" -NoTypeInformation

# Size
Get-MailboxStatistics $SharedMailboxIdentity | Select * | Export-Csv "$OutputPath\mailbox-statistics.csv" -NoTypeInformation

# Full Access delegates
Get-MailboxPermission $SharedMailboxIdentity | Where-Object {-not $_.IsInherited} |
    Export-Csv "$OutputPath\full-access-delegates.csv" -NoTypeInformation

# Send As delegates
Get-RecipientPermission $SharedMailboxIdentity |
    Export-Csv "$OutputPath\sendas-delegates.csv" -NoTypeInformation

# Folder permissions (calendar, etc.)
Get-MailboxFolderPermission "$($SharedMailboxIdentity):\Calendar" |
    Export-Csv "$OutputPath\calendar-permissions.csv" -NoTypeInformation

# SMTP addresses
(Get-Mailbox $SharedMailboxIdentity).EmailAddresses |
    Out-File "$OutputPath\smtp-addresses.txt"

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
Invoke-Item $OutputPath
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Get mailbox details | `Get-Mailbox "support@contoso.com" \| Select *` |
| Check size | `Get-MailboxStatistics "support@contoso.com" \| Select TotalItemSize,ItemCount` |
| List Full Access delegates | `Get-MailboxPermission "support@contoso.com" \| Where {!$_.IsInherited}` |
| Grant Full Access + auto-map | `Add-MailboxPermission -Identity "mbx" -User "user" -AccessRights FullAccess -AutoMapping $true` |
| Revoke Full Access | `Remove-MailboxPermission -Identity "mbx" -User "user" -AccessRights FullAccess -Confirm:$false` |
| Grant Send As | `Add-RecipientPermission -Identity "mbx" -Trustee "user" -AccessRights SendAs -Confirm:$false` |
| List Send As | `Get-RecipientPermission "support@contoso.com"` |
| Enable Sent Items copy | `Set-Mailbox "mbx" -MessageCopyForSentAsEnabled $true` |
| Add SMTP alias | `Set-Mailbox "mbx" -EmailAddresses @{Add="smtp:alias@domain.com"}` |
| Convert to shared | `Set-Mailbox "mbx" -Type Shared` |
| Create new shared mailbox | `New-Mailbox -Shared -Name "X" -Alias "x" -PrimarySmtpAddress "x@domain.com"` |
| Enable archive | `Enable-Mailbox "mbx" -Archive` |
| Find soft-deleted mailboxes | `Get-Mailbox -SoftDeletedMailbox \| Select DisplayName,WhenSoftDeleted` |
| Recover soft-deleted | `Undo-SoftDeletedMailbox -SoftDeletedObject <Guid>` |

---

## 🎓 Learning Pointers

- **Auto-mapping is Outlook-side, not mailbox-side.** The `msExchDelegateListLink` attribute on the user object tells Outlook to silently mount the shared mailbox at startup. It only works for Full Access, only for Outlook desktop (not OWA or mobile), and can cause performance issues if a user has 10+ shared mailboxes auto-mapped. Read more: [MS Docs — Auto-mapping](https://learn.microsoft.com/en-us/outlook/troubleshoot/profiles-and-accounts/remove-automapping-for-shared-mailbox)

- **Send As vs. Send on Behalf are different SMTP headers.** Send As produces a `From:` header with the shared mailbox address. Send on Behalf produces `From: Delegate <delegate@contoso.com>; Sender: shared@contoso.com`. Some mail systems and spam filters treat these differently. Know which your users need before configuring. [MS Docs — Delegate Access](https://learn.microsoft.com/en-us/exchange/recipients/shared-mailboxes)

- **MessageCopyForSentAsEnabled defaults to True for new mailboxes, but old ones may be False.** Always verify this when users complain sent items aren't showing in the shared mailbox. A quick `Set-Mailbox` call fixes it — no downtime, no restart required.

- **Licensing is a silent quota enforcer.** When a shared mailbox reaches 50 GB without a license, it stops receiving new mail without alerting admins visibly. Build a monitoring script or use Microsoft 365 Defender/Compliance to alert on mailbox quota. The `Get-MailboxStatistics` output combined with a threshold alert in PowerShell Scheduled Task is a simple MSP-friendly solution.

- **In hybrid, always migrate before managing.** Attempting to add SMTP aliases or set forwarding in both EXO and on-prem EAC for the same object causes Entra Connect to overwrite EXO changes on the next sync cycle (30 minutes). After `New-MoveRequest` completes, manage exclusively from EXO. [MS Docs — Manage Shared Mailboxes in Hybrid](https://learn.microsoft.com/en-us/exchange/hybrid-deployment/manage-shared-mailboxes)

- **Soft-delete recovery is only 30 days.** If a shared mailbox holds anything business-critical (audit trail, support tickets), apply a litigation hold or retention policy before someone accidentally deletes it. Litigation hold is free if the mailbox has an Exchange Online Plan 2 license. [MS Docs — Recover Deleted Mailbox](https://learn.microsoft.com/en-us/exchange/recipients-in-exchange-online/delete-or-restore-mailboxes)
