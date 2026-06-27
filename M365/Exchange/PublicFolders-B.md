# Exchange Public Folders — Hotfix Runbook (Mode B: Ops)
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

Run these first — results tell you where to go next.

```powershell
# 1. Check Public Folder mailbox health
Get-Mailbox -PublicFolder | Select Name, PrimarySmtpAddress, Database, IsRootPublicFolderMailbox | Format-Table -AutoSize

# 2. Check Public Folder hierarchy sync status
Get-PublicFolderMailboxDiagnostics -Identity <PFMailboxName> | Select *Sync*, *Hierarchy*, *LastSync* | Format-List

# 3. Check if Public Folders are enabled for the org
Get-OrganizationConfig | Select PublicFoldersEnabled, PublicFolderMailboxesLockedForNewConnections | Format-List

# 4. Test Public Folder access as a specific user
Test-PublicFolderConnectivity -MailboxCredential (Get-Credential)

# 5. Check for failed hierarchy sync
Get-PublicFolderMailboxDiagnostics -Identity <PFMailboxName> -IncludeAggregateResultOnly | Select *Error*, *Failure* | Format-List
```

| Result | Likely Cause | Go to |
|--------|-------------|-------|
| `PublicFoldersEnabled: False` | PF disabled at org level | [Fix 1](#fix-1--enable-public-folders-at-org-level) |
| IsRootPublicFolderMailbox missing | No root PF mailbox | [Fix 2](#fix-2--create-root-public-folder-mailbox) |
| HierarchyLastSyncTime > 24h old | Hierarchy sync stalled | [Fix 3](#fix-3--force-hierarchy-sync) |
| Access denied errors | Permission issue | [Fix 4](#fix-4--fix-public-folder-permissions) |
| Test-PublicFolderConnectivity fails | Connectivity / routing | [Fix 5](#fix-5--fix-public-folder-email-routing) |

---
## Dependency Cascade

<details><summary>What must be true for Public Folders to work</summary>

```
Exchange Online Org (PublicFoldersEnabled = True)
    └── Root PF Mailbox (IsRootPublicFolderMailbox = True)
            └── PF Hierarchy (replicated to all PF mailboxes)
                    └── Content PF Mailboxes (store folder content)
                            └── Folder Permissions (mail-enabled PFs need SMTP routing)
                                    └── User Mailbox (assigned to correct PF mailbox)
                                            └── Client Access (OWA / Outlook / EAS)
```

**Key facts:**
- Only ONE root PF mailbox per org
- Hierarchy is read from root, written by hierarchy sync job (runs every 24h by default)
- Users are auto-assigned to a PF mailbox based on load balancing
- Mail-enabled PFs require a valid SMTP address and accepted domain
- Exchange Hybrid: on-prem PFs can be accessed by Exchange Online users via routing

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm scope**
```powershell
# Is this one user or all users?
Get-MailboxFolderPermission -Identity "<UserUPN>:\<FolderPath>"

# How many PF mailboxes exist?
Get-Mailbox -PublicFolder | Measure-Object
```
Expected: At least 1 PF mailbox. Root mailbox present. Permissions show expected entries.

**Step 2 — Check hierarchy sync**
```powershell
$diag = Get-PublicFolderMailboxDiagnostics -Identity <PFMailboxName>
$diag | Select *Hierarchy*, *Sync*, *LastAttempted* | Format-List
```
Expected: `HierarchyLastSyncTime` within last 24 hours. No sync errors.

**Step 3 — Validate user assignment**
```powershell
Get-Mailbox <UserUPN> | Select EffectivePublicFolderMailbox, PublicFolderClientAccess
```
Expected: `EffectivePublicFolderMailbox` points to a valid PF mailbox name.

**Step 4 — Check folder permissions**
```powershell
Get-PublicFolderClientPermission -Identity "\<FolderPath>" | Format-Table User, AccessRights
```
Expected: User (or Default) has at least `Reviewer` rights.

**Step 5 — Test end-to-end**
```powershell
Test-PublicFolderConnectivity
```
Expected: All tests pass with no errors.

---
## Common Fix Paths

<details><summary>Fix 1 — Enable Public Folders at org level</summary>

```powershell
# Enable Public Folders for the organization
Set-OrganizationConfig -PublicFoldersEnabled Local

# Verify
Get-OrganizationConfig | Select PublicFoldersEnabled
```

**Note:** Value can be `Local` (Exchange Online PF mailboxes), `Remote` (on-prem PF accessed from EXO), or `None` (disabled).

**Rollback:** `Set-OrganizationConfig -PublicFoldersEnabled None`

</details>

<details><summary>Fix 2 — Create root Public Folder mailbox</summary>

```powershell
# Create the root (hierarchy) PF mailbox — must be first PF mailbox
New-Mailbox -PublicFolder "Public Folders" -HoldForMigration:$false

# Verify it's set as root
Get-Mailbox -PublicFolder | Select Name, IsRootPublicFolderMailbox
```

**Note:** First PF mailbox created is automatically the root. If root was deleted, create a new one and manually set hierarchy using migration tooling.

</details>

<details><summary>Fix 3 — Force hierarchy sync</summary>

```powershell
# Force hierarchy sync immediately
Update-PublicFolderMailbox -Identity <PFMailboxName> -InvokeSynchronizer

# Monitor progress (run a few times over 5 mins)
Get-PublicFolderMailboxDiagnostics -Identity <PFMailboxName> | Select *Hierarchy*, *LastSync*

# If multiple PF mailboxes, sync all
Get-Mailbox -PublicFolder | ForEach-Object {
    Write-Host "Syncing $($_.Name)..."
    Update-PublicFolderMailbox -Identity $_.Identity -InvokeSynchronizer
}
```

**Expected:** `HierarchyLastSyncTime` updates within 5–10 minutes.

</details>

<details><summary>Fix 4 — Fix Public Folder permissions</summary>

```powershell
# Grant a user access to a specific folder
Add-PublicFolderClientPermission -Identity "\<FolderPath>" -User <UserUPN> -AccessRights Reviewer

# Grant all authenticated users read access
Add-PublicFolderClientPermission -Identity "\<FolderPath>" -User Default -AccessRights Reviewer

# Grant Owner (full control) to an admin
Add-PublicFolderClientPermission -Identity "\<FolderPath>" -User <AdminUPN> -AccessRights Owner

# Apply recursively to all subfolders
Get-PublicFolder -Identity "\<FolderPath>" -Recurse | ForEach-Object {
    Add-PublicFolderClientPermission -Identity $_.Identity -User <UserUPN> -AccessRights Reviewer -ErrorAction SilentlyContinue
}

# Remove a specific permission
Remove-PublicFolderClientPermission -Identity "\<FolderPath>" -User <UserUPN>
```

**Common Access Rights:** `None`, `Reviewer`, `Contributor`, `Author`, `Editor`, `PublishingEditor`, `Owner`

</details>

<details><summary>Fix 5 — Fix Public Folder email routing (mail-enabled PFs)</summary>

```powershell
# Check if PF is mail-enabled
Get-PublicFolder -Identity "\<FolderPath>" | Select MailEnabled, PrimarySmtpAddress

# Mail-enable a Public Folder
Enable-MailPublicFolder -Identity "\<FolderPath>"

# Set SMTP address
Set-MailPublicFolder -Identity "\<FolderPath>" -PrimarySmtpAddress "<PFAlias>@<domain.com>"

# Verify mail flow settings
Get-MailPublicFolder "\<FolderPath>" | Select Name, PrimarySmtpAddress, EmailAddresses, RequireSenderAuthenticationEnabled

# Allow external senders (if required)
Set-MailPublicFolder -Identity "\<FolderPath>" -RequireSenderAuthenticationEnabled $false
```

**Rollback:** `Disable-MailPublicFolder -Identity "\<FolderPath>"`

</details>

---
## Escalation Evidence

```
=== Public Folder Escalation Pack ===
Ticket #: _______________
Engineer: _______________
Date/Time: _______________

ISSUE SUMMARY:
[ ] Cannot access Public Folders (all users)
[ ] Cannot access Public Folders (specific user)
[ ] Mail-enabled PF not receiving email
[ ] Hierarchy not syncing
[ ] Permission denied errors
[ ] Hybrid routing issue (on-prem PF)

ORG SETTINGS:
PublicFoldersEnabled: _______________
PublicFolderMailboxesLocked: _______________

PF MAILBOX COUNT: _______________
ROOT MAILBOX NAME: _______________
LAST HIERARCHY SYNC: _______________

AFFECTED USER: _______________
EffectivePublicFolderMailbox: _______________

ERROR MESSAGE (exact): 
_______________________________________________

Test-PublicFolderConnectivity output:
[ ] Pass [ ] Fail — Details: _______________
```

---
## 🎓 Learning Pointers

- **Root mailbox is the hierarchy master.** All PF mailboxes sync their hierarchy from the root mailbox. If the root is unhealthy or missing, no user can browse the folder tree — see [MS Docs: Public folder mailboxes](https://learn.microsoft.com/en-us/exchange/collaboration/public-folders/public-folders)
- **Hierarchy sync ≠ content sync.** The hierarchy (folder names/structure) syncs separately from content. A user can see folders but get errors opening them if the content mailbox assignment is wrong.
- **`EffectivePublicFolderMailbox` is auto-assigned.** Exchange load-balances users across PF mailboxes. You can manually override per-mailbox if one PF mailbox is overloaded: `Set-Mailbox <user> -DefaultPublicFolderMailbox <PFMailboxName>`
- **Mail-enabled PFs have their own SMTP address.** They appear in the GAL by default. If external mail to a PF bounces, check `RequireSenderAuthenticationEnabled` — it defaults to `$true`, blocking anonymous/external senders.
- **Exchange Hybrid: choose Local or Remote, not both.** In hybrid environments, PFs can live on-prem (`Remote`) or in Exchange Online (`Local`). Users in either location access the authoritative copy — see [Exchange Hybrid PF docs](https://learn.microsoft.com/en-us/exchange/hybrid-deployment/deploy-shared-virtual-directories)
