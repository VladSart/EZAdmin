# Exchange Public Folders — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index (with jump links)
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

Covers **Exchange Online Public Folders** (modern PF architecture) and **Exchange Hybrid** scenarios where on-premises Public Folders are accessed by Exchange Online users. Does not cover legacy Exchange 2010/2007 PF architecture.

Assumes:
- Exchange Online tenant with active licenses
- Exchange Online PowerShell module (`ExchangeOnlineManagement`) installed and connected
- For Hybrid: Exchange Management Shell on-prem also available
- Engineer has `Exchange Administrator` or `Global Administrator` role

---
## How It Works

<details><summary>Full architecture — Public Folder mailbox model</summary>

Exchange Online Public Folders use a **mailbox-based** model (introduced in Exchange 2013), replacing the legacy per-server store model. All Public Folder data lives in specially typed Exchange mailboxes.

**Hierarchy vs. Content split:**

```
┌─────────────────────────────────────────────────────────────────┐
│  Public Folder Mailbox Architecture                             │
│                                                                 │
│  Root PF Mailbox (IsRootPublicFolderMailbox = True)            │
│  ┌──────────────────────────────────────────────────┐           │
│  │  Hierarchy Master (source of truth)              │           │
│  │  - Folder names, structure, parent-child tree    │           │
│  │  - Permissions stored per folder in hierarchy   │           │
│  │  - HierarchySyncStatus tracked here             │           │
│  └──────────────────────┬───────────────────────────┘           │
│                         │  sync (every 24h or on-demand)        │
│  ┌──────────────────────▼───────────────────────────┐           │
│  │  Content PF Mailboxes (1..N)                     │           │
│  │  - Store actual folder content (items/messages)  │           │
│  │  - Each has a read-only copy of the hierarchy   │           │
│  │  - Users auto-assigned via load balancing        │           │
│  └──────────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────┘
```

**User access flow:**

1. Outlook/OWA client connects to Exchange Online
2. Exchange resolves user's `EffectivePublicFolderMailbox` property
3. Client opens PF mailbox — reads hierarchy from its local copy
4. When user opens a folder, content is served from the assigned content mailbox
5. If folder content lives on a different PF mailbox, Exchange transparently proxies the request

**Hierarchy sync mechanics:**
- The `Update-PublicFolderMailbox` cmdlet (or background timer) triggers `HierarchySynchronizer`
- Sync copies folder tree from root to all secondary PF mailboxes
- If sync fails repeatedly, secondary mailboxes show stale hierarchy — users may see folders that don't match current state

**Mail-enabled Public Folders:**
- Any PF can be mail-enabled via `Enable-MailPublicFolder`
- Creates a hidden mail object with SMTP address in Exchange directory
- Inbound mail routed to the PF like a mailbox; stored as items in the folder
- By default: `RequireSenderAuthenticationEnabled = True` — external senders blocked

</details>

---
## Dependency Stack

```
Exchange Online Organization
    │
    ├── OrganizationConfig (PublicFoldersEnabled = Local | Remote | None)
    │
    ├── Root PF Mailbox (IsRootPublicFolderMailbox = True) [REQUIRED — only 1]
    │       └── Hierarchy Master (folder tree, ACLs)
    │               └── HierarchySynchronizer Job
    │
    ├── Content PF Mailboxes [0..N additional]
    │       ├── Local read-only hierarchy copy
    │       └── Content store (items, messages)
    │
    ├── User Mailboxes
    │       └── EffectivePublicFolderMailbox → assigned content PF mailbox
    │
    ├── Mail-Enabled PFs (optional)
    │       ├── SMTP address in accepted domain
    │       ├── GAL entry (hidden by default possible)
    │       └── Transport routing rules
    │
    └── Client Layer
            ├── Outlook (MAPI/HTTP — uses EffectivePublicFolderMailbox)
            ├── OWA (browser — same assignment logic)
            └── Exchange ActiveSync (limited PF support)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| "Public Folders not enabled" error in Outlook | `PublicFoldersEnabled = None` | `Get-OrganizationConfig \| Select PublicFoldersEnabled` |
| All users can't access any PFs | Root PF mailbox missing or unhealthy | `Get-Mailbox -PublicFolder \| Where IsRootPublicFolderMailbox` |
| Folder structure not updating after changes | Hierarchy sync stalled | `Get-PublicFolderMailboxDiagnostics \| Select *Sync*` |
| One user can't access PFs, others fine | Wrong/missing `EffectivePublicFolderMailbox` | `Get-Mailbox <user> \| Select EffectivePublicFolderMailbox` |
| "Permission denied" on specific folder | Missing client permission | `Get-PublicFolderClientPermission "\<path>"` |
| Mail-enabled PF not receiving email | External senders blocked or wrong SMTP | `Get-MailPublicFolder \| Select RequireSenderAuthenticationEnabled` |
| PF visible but items missing | User assigned to wrong content mailbox | Check `EffectivePublicFolderMailbox` vs. where content lives |
| "Mailboxes locked for new connections" | Migration or maintenance mode active | `Get-OrganizationConfig \| Select PublicFolderMailboxesLockedForNewConnections` |
| Hybrid: EXO users can't reach on-prem PFs | `PublicFoldersEnabled = Remote` not configured | `Get-OrganizationConfig \| Select PublicFoldersEnabled, RemotePublicFolderMailboxes` |

---
## Validation Steps

**Step 1 — Org-level PF config**
```powershell
Get-OrganizationConfig | Select PublicFoldersEnabled, PublicFolderMailboxesLockedForNewConnections, DefaultPublicFolderAgeLimit | Format-List
```
Good: `PublicFoldersEnabled: Local`, `LockedForNewConnections: False`
Bad: `None` = PFs globally disabled. `True` = locked (migration in progress?)

**Step 2 — PF mailbox inventory**
```powershell
Get-Mailbox -PublicFolder | Select Name, IsRootPublicFolderMailbox, Database, PrimarySmtpAddress, TotalItemSize | Format-Table -AutoSize
```
Good: At least 1 mailbox, exactly 1 with `IsRootPublicFolderMailbox = True`
Bad: No mailboxes, or no root mailbox

**Step 3 — Hierarchy sync health**
```powershell
Get-Mailbox -PublicFolder | ForEach-Object {
    $diag = Get-PublicFolderMailboxDiagnostics -Identity $_.Name
    [PSCustomObject]@{
        Mailbox = $_.Name
        IsRoot = $_.IsRootPublicFolderMailbox
        HierarchyLastSync = $diag.HierarchyLastSyncTime
        SyncStatus = $diag.HierarchySynchronizationStatus
        SyncFailures = $diag.HierarchySyncFailureCount
    }
}
```
Good: All mailboxes synced within 24h, `SyncStatus = Success`, `SyncFailures = 0`
Bad: `SyncStatus = Failed`, `HierarchyLastSyncTime` > 24h, `SyncFailures > 0`

**Step 4 — User assignment check**
```powershell
Get-Mailbox <UPN> | Select EffectivePublicFolderMailbox, DefaultPublicFolderMailbox
```
Good: `EffectivePublicFolderMailbox` points to a known, healthy PF mailbox
Bad: Empty/null, or points to a mailbox that doesn't exist or is overloaded

**Step 5 — Folder permission check**
```powershell
# Check top-level first
Get-PublicFolderClientPermission "\" | Format-Table User, AccessRights

# Check specific problem folder
Get-PublicFolderClientPermission "\<FolderPath>" | Format-Table User, AccessRights
```
Good: `Default` has at least `Reviewer`, or specific user is listed with access
Bad: `Default = None` and user not explicitly listed

**Step 6 — End-to-end connectivity test**
```powershell
Test-PublicFolderConnectivity
```
Good: All tests pass
Bad: Any failed test with error details

---
## Troubleshooting Steps (by phase)

### Phase 1 — Org & Infrastructure

1. Verify `PublicFoldersEnabled` (see Step 1 above). If `None`, enable it — but understand why it might have been disabled.
2. Verify root PF mailbox exists. If missing, a previous migration or accidental deletion is likely. Creating a new one reinitialises the hierarchy.
3. Check if `PublicFolderMailboxesLockedForNewConnections = True` — this indicates a migration was started but may not have completed. Do not attempt changes during an active migration.

### Phase 2 — Hierarchy Sync

1. Check `HierarchyLastSyncTime` across all PF mailboxes.
2. Force sync: `Update-PublicFolderMailbox -Identity <root> -InvokeSynchronizer`
3. Wait 5–10 minutes, re-check diagnostics.
4. If sync fails repeatedly with errors, look at the specific error code in `HierarchySyncFailureCount` diagnostics — common causes: database quota exceeded, corrupt item in hierarchy, network transient.
5. For quota issues: `Set-Mailbox -PublicFolder <name> -ProhibitSendReceiveQuota <size>GB`

### Phase 3 — User-Level Issues

1. If one user affected: check `EffectivePublicFolderMailbox`. Null/empty = Exchange hasn't assigned the mailbox yet (can happen with new users or after license changes).
2. Manually assign: `Set-Mailbox <user> -DefaultPublicFolderMailbox <PFMailboxName>` — effective within minutes.
3. If user reports "can see folders but can't open content": user is assigned to a different PF mailbox than where content lives. Exchange should auto-proxy, but if proxying is broken, reassign to the correct mailbox.
4. If user gets "permission denied": check both the folder's ACL and the parent folder chain — permissions are not inherited by default in PFs; each folder has explicit ACLs.

### Phase 4 — Mail-Enabled PF Issues

1. Verify SMTP address is in an accepted domain: `Get-AcceptedDomain`
2. Check if `RequireSenderAuthenticationEnabled = True` — this blocks anonymous/external senders.
3. Verify the PF appears in the correct address list.
4. Check transport rules — any rule could be redirecting or blocking mail to PF addresses.
5. If external delivery fails: test with `Send-MailMessage` or external client. Check message trace: `Get-MessageTrace -RecipientAddress <pf-smtp-address>`

### Phase 5 — Exchange Hybrid PF Access

On-premises PF → accessed by EXO users:
1. Set `Set-OrganizationConfig -PublicFoldersEnabled Remote`
2. Specify on-prem PF mailboxes: `Set-OrganizationConfig -RemotePublicFolderMailboxes <Mailbox1>,<Mailbox2>`
3. Ensure Hybrid connector is healthy (run Hybrid Configuration Wizard if needed)
4. On-prem: ensure EXO user objects have correct `ExternalEmailAddress`

EXO PF → accessed by on-prem Exchange users:
1. On-prem: `Set-OrganizationConfig -PublicFoldersEnabled Remote`
2. Point to EXO PF mailbox SMTP addresses

---
## Remediation Playbooks

<details><summary>Playbook 1 — Rebuild Public Folder hierarchy from scratch</summary>

⚠️ **Destructive — only if hierarchy is corrupt and all users are affected.**

```powershell
# Step 1: Document existing PF structure before making changes
Get-PublicFolder -Recurse | Select Identity, Name, MailEnabled | Export-Csv C:\Temp\PF-Inventory.csv -NoTypeInformation

# Step 2: Document all permissions
Get-PublicFolder -Recurse | ForEach-Object {
    Get-PublicFolderClientPermission $_.Identity | 
    Select @{N="Folder";E={$_.Identity}}, User, AccessRights
} | Export-Csv C:\Temp\PF-Permissions.csv -NoTypeInformation

# Step 3: Force hierarchy sync on all mailboxes
Get-Mailbox -PublicFolder | ForEach-Object {
    Update-PublicFolderMailbox -Identity $_.Name -InvokeSynchronizer
}

# Step 4: Wait and validate
Start-Sleep -Seconds 300
Get-Mailbox -PublicFolder | ForEach-Object {
    Get-PublicFolderMailboxDiagnostics $_.Name | Select *Sync*, *Hierarchy*
}
```

**Rollback:** Hierarchy changes affect all users immediately. Document first, always.

</details>

<details><summary>Playbook 2 — Migrate user to different PF mailbox</summary>

```powershell
# Check current assignment
$user = Get-Mailbox <UPN>
Write-Host "Current: $($user.EffectivePublicFolderMailbox)"

# List available PF mailboxes with item counts
Get-Mailbox -PublicFolder | ForEach-Object {
    $stats = Get-MailboxStatistics $_.Identity
    [PSCustomObject]@{
        Name = $_.Name
        IsRoot = $_.IsRootPublicFolderMailbox
        Items = $stats.ItemCount
        Size = $stats.TotalItemSize
    }
}

# Reassign user to a specific PF mailbox
Set-Mailbox <UPN> -DefaultPublicFolderMailbox <PFMailboxName>

# Verify (may take a few minutes to propagate)
Get-Mailbox <UPN> | Select EffectivePublicFolderMailbox, DefaultPublicFolderMailbox
```

**Rollback:** `Set-Mailbox <UPN> -DefaultPublicFolderMailbox $null` (returns to auto-assignment)

</details>

<details><summary>Playbook 3 — Bulk permission assignment</summary>

```powershell
# Grant a security group Reviewer to all PFs
$folders = Get-PublicFolder -Recurse
$folders | ForEach-Object {
    try {
        Add-PublicFolderClientPermission -Identity $_.Identity -User <GroupOrUser> -AccessRights Reviewer -ErrorAction Stop
        Write-Host "OK: $($_.Identity)" -ForegroundColor Green
    } catch {
        Write-Warning "SKIP: $($_.Identity) — $($_.Exception.Message)"
    }
}

# Remove all permissions for a departed user
$folders | ForEach-Object {
    try {
        Remove-PublicFolderClientPermission -Identity $_.Identity -User <UserUPN> -Confirm:$false -ErrorAction SilentlyContinue
    } catch {}
}
```

</details>

---
## Evidence Pack

```powershell
# Run this to collect full escalation evidence
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$output = "C:\Temp\PF-Evidence-$timestamp.txt"

@"
=== Public Folder Evidence Pack — $timestamp ===
"@ | Set-Content $output

# Org config
"=== ORG CONFIG ===" | Add-Content $output
Get-OrganizationConfig | Select PublicFoldersEnabled, PublicFolderMailboxesLockedForNewConnections | Format-List | Out-String | Add-Content $output

# PF mailbox inventory
"=== PF MAILBOXES ===" | Add-Content $output
Get-Mailbox -PublicFolder | Select Name, IsRootPublicFolderMailbox, PrimarySmtpAddress, Database | Format-Table -AutoSize | Out-String | Add-Content $output

# Hierarchy sync status
"=== HIERARCHY SYNC ===" | Add-Content $output
Get-Mailbox -PublicFolder | ForEach-Object {
    Get-PublicFolderMailboxDiagnostics $_.Name | Select *Sync*, *Hierarchy*, *Error*, *Failure*
} | Format-List | Out-String | Add-Content $output

# Connectivity test
"=== CONNECTIVITY TEST ===" | Add-Content $output
Test-PublicFolderConnectivity | Out-String | Add-Content $output

Write-Host "Evidence written to $output" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check PF enabled | `Get-OrganizationConfig \| Select PublicFoldersEnabled` |
| List all PF mailboxes | `Get-Mailbox -PublicFolder \| Format-Table Name, IsRootPublicFolderMailbox` |
| Check hierarchy sync | `Get-PublicFolderMailboxDiagnostics <name> \| Select *Sync*, *Hierarchy*` |
| Force hierarchy sync | `Update-PublicFolderMailbox -Identity <name> -InvokeSynchronizer` |
| Check user assignment | `Get-Mailbox <UPN> \| Select EffectivePublicFolderMailbox` |
| Override user assignment | `Set-Mailbox <UPN> -DefaultPublicFolderMailbox <PFName>` |
| Browse PF tree | `Get-PublicFolder -Recurse \| Select Identity, MailEnabled` |
| Check folder perms | `Get-PublicFolderClientPermission "\<path>"` |
| Grant access | `Add-PublicFolderClientPermission -Identity "\<path>" -User <UPN> -AccessRights Reviewer` |
| Remove access | `Remove-PublicFolderClientPermission -Identity "\<path>" -User <UPN>` |
| Mail-enable a PF | `Enable-MailPublicFolder -Identity "\<path>"` |
| Allow external senders | `Set-MailPublicFolder "\<path>" -RequireSenderAuthenticationEnabled $false` |
| Test end-to-end | `Test-PublicFolderConnectivity` |
| Get PF stats | `Get-PublicFolderStatistics -Identity "\<path>"` |

---
## 🎓 Learning Pointers

- **One root mailbox, one hierarchy.** The root PF mailbox is a singleton — it holds the canonical hierarchy that all other PF mailboxes sync from. Treat it like a domain PDC emulator: losing it requires careful recovery, not just creating a replacement. See [Public folder mailboxes in Exchange Online](https://learn.microsoft.com/en-us/exchange/collaboration/public-folders/public-folders).
- **Hierarchy sync is not real-time.** Changes to folder structure take up to 24 hours to propagate to secondary PF mailboxes unless you force sync with `Update-PublicFolderMailbox -InvokeSynchronizer`. Always force sync after structural changes and before declaring an issue fixed.
- **Permissions are per-folder, not inherited by default.** Unlike SharePoint or NTFS, PF permissions don't flow down the tree automatically. Bulk permission changes require iterating with `Get-PublicFolder -Recurse`. The `Default` permission entry controls anonymous/authenticated access for all users not explicitly listed.
- **EffectivePublicFolderMailbox vs. DefaultPublicFolderMailbox.** `DefaultPublicFolderMailbox` is the admin-set override; `EffectivePublicFolderMailbox` is what Exchange actually uses (resolves override first, then auto-assigned). If a user's effective assignment is blank, they may be getting auto-assigned on first connection — force it manually for troubleshooting.
- **Hybrid PF routing is a one-way declaration.** You choose: PFs live on-prem (Remote) or in Exchange Online (Local). You can't mix — users in one location accessing PFs in both isn't supported. Plan migrations accordingly. See [Configure Exchange hybrid Public Folders](https://learn.microsoft.com/en-us/exchange/hybrid-deployment/set-up-modern-hybrid-public-folders).
- **Mail-enabled PFs are a spam target.** When you set `RequireSenderAuthenticationEnabled = $false`, external senders can reach the PF. Always pair this with a dedicated DLP policy or transport rule to prevent abuse, especially for public-facing PF addresses.
