# Exchange Online Archive & Retention — Reference Runbook (Mode A: Deep Dive)
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

- Exchange Online (EXO) only — on-premises Exchange and hybrid scenarios flagged where they diverge
- Covers: In-Place Archive, Auto-Expanding Archive (AEA), Messaging Records Management (MRM) v1 (retention tags/policies) and v2 (Microsoft 365 retention labels/policies via Compliance Center)
- Assumes: Exchange Online Plan 2 or Microsoft 365 E3+ for archive; E5/Compliance add-on for advanced retention features
- **Important**: MRM 1.0 (Managed Folder Assistant, retention tags) and MRM 2.0 (Compliance Center retention labels) co-exist but have different processing paths. Conflicts between them are a major source of confusion.

---
## How It Works

<details><summary>Full architecture — In-Place Archive and MRM processing</summary>

### In-Place Archive

An In-Place Archive is a secondary mailbox provisioned on the same backend as the primary, exposed as a separate folder tree in Outlook/OWA ("Online Archive — username"). It is **not** a separate mailbox object — it shares the same `ExchangeGUID` family as the primary but has its own `ArchiveGUID` and `ArchiveDatabase`.

```
User Mailbox (Primary)
├── Inbox, Sent Items, Calendar, etc.
│     └── Items subject to MRM processing
└── Archive (In-Place Archive)
      ├── Archived Items (default target)
      ├── Deleted Items
      └── Any folder the user or policy creates
```

**Auto-Expanding Archive (AEA)**: When the archive grows beyond 100 GB, Exchange Online automatically provisions additional "auxiliary" archive databases. From the user's perspective it's seamless. From an admin perspective: you cannot target specific auxiliary databases; content search and eDiscovery span all of them automatically.

### MRM 1.0 — Managed Folder Assistant (MFA)

The Managed Folder Assistant is a back-end service that runs on Exchange Online servers. It processes each mailbox approximately **every 7 days** (not configurable in EXO, unlike on-prem). MFA applies:
- **Retention Tags** — applied per-folder or per-item (Personal tags set by users)
- **Retention Policy** — a container of retention tags assigned to the mailbox

Tag types:
| Tag Type | Applies To | Set By |
|----------|-----------|--------|
| Default Policy Tag (DPT) | All untagged items | Admin |
| Retention Policy Tag (RPT) | Specific default folders | Admin |
| Personal Tag | Items/folders (user-selectable) | Admin creates, user applies |

**MFA actions on expiry:**
- `MoveToArchive` → moves item to In-Place Archive
- `DeleteAndAllowRecovery` → soft delete (recoverable)
- `PermanentlyDelete` → hard delete (not recoverable post-dumpster)

### MRM 2.0 — Compliance Center Retention Policies / Labels

Microsoft 365 retention policies and labels are processed by a different back-end service: the **Compliance Engine** (sometimes called TRIM). Processing cycle: **up to 7 days** for new policy assignments; enforcement varies.

Key behavioural difference from MRM 1.0: MRM 2.0 operates at the compliance layer. When a retention label marks an item "retain then delete," the item is not immediately deleted — it is moved to the **SubstrateHolds** or **ComplianceAssetID** hidden folders in the mailbox for the hold period, then permanently deleted by the Compliance Engine.

### Litigation Hold vs In-Place Hold vs Compliance Hold

| Hold Type | Set Via | Scope | Overrides Deletion? |
|-----------|---------|-------|-------------------|
| Litigation Hold | EXO PowerShell / EAC | Entire mailbox | Yes — all items preserved |
| eDiscovery Hold (Core) | Compliance Center | Query-based or full mailbox | Yes |
| Microsoft 365 Retention Label (retain) | Compliance Center | Per-item/policy | Yes |
| In-Place Hold (legacy) | Classic EAC | Query-based | Yes — deprecated, use eDiscovery |

**Retention Hold** (`RetentionHoldEnabled = $true`): Pauses MFA processing for a mailbox. Used during onboarding/migrations to prevent items being deleted before retention policies are properly applied. Often left on accidentally — a major cause of "archive not moving items."

</details>

---
## Dependency Stack

```
Microsoft 365 Compliance Center (Purview)
  └── MRM 2.0 Retention Policies / Labels (Compliance Engine / TRIM)
        └── SubstrateHolds / ComplianceAssetID folders in mailbox

Exchange Online Admin Center / PowerShell
  └── MRM 1.0 Retention Policies (Managed Folder Assistant)
        ├── Retention Tags → action: MoveToArchive / Delete
        └── Retention Policy → assigned to mailbox

Mailbox (Primary)
  ├── Active items
  ├── Recoverable Items (dumpster)
  │     ├── Deletions
  │     ├── Purges
  │     ├── SubstrateHolds       ← MRM 2.0 hold copies
  │     └── DiscoveryHolds       ← eDiscovery hold copies
  └── In-Place Archive (ArchiveMailbox)
        ├── Archived Items
        └── Recoverable Items (archive dumpster)
              └── Auto-Expanding Archive (AEA) auxiliary databases
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Archive not provisioned, user can't see it | Archive not enabled for the mailbox | `Get-Mailbox user | Select ArchiveStatus` |
| Items not moving to archive automatically | Retention Hold is ON, or no MoveToArchive tag assigned | `Get-Mailbox user | Select RetentionHoldEnabled, RetentionPolicy` |
| MFA ran but items still in primary | Tag action age not met, or personal tag overrides DPT | Check item age vs retention tag age limit |
| Auto-expanding archive not provisioning | AEA not enabled for the mailbox or tenant | `Get-Mailbox user | Select AutoExpandingArchiveEnabled` |
| User can't see Online Archive in Outlook | Outlook not in cached mode, or Autodiscover issue | Test in OWA first; check Autodiscover |
| Archive quota exceeded errors | Archive full, AEA not enabled | Check `ArchiveQuota` and `ArchiveWarningQuota` |
| Items retained past deletion date | Litigation Hold or compliance hold active | `Get-Mailbox user | Select LitigationHoldEnabled, LitigationHoldDate` |
| Retention label not applying | Label sync delay (up to 7 days), or conflicting higher-priority policy | Check Compliance Center policy priority |
| Recoverable Items folder bloated | Litigation hold preventing purge of deleted items | `Get-MailboxFolderStatistics user -FolderScope RecoverableItems` |
| Retention Hold stuck on | Admin set it during migration and forgot to clear it | `Set-Mailbox user -RetentionHoldEnabled $false` |

---
## Validation Steps

**Step 1 — Check archive status and configuration**
```powershell
Get-Mailbox -Identity <USER> | Select-Object DisplayName, ArchiveStatus, ArchiveDatabase,
    AutoExpandingArchiveEnabled, ArchiveGuid, ArchiveQuota, ArchiveWarningQuota,
    RetentionPolicy, RetentionHoldEnabled, LitigationHoldEnabled
```
Expected good: `ArchiveStatus = Active`, `RetentionHoldEnabled = False`, `RetentionPolicy` assigned

**Step 2 — Check MFA processing timestamp**
```powershell
Get-MailboxFolderStatistics -Identity <USER> -FolderScope Archive |
    Select-Object Name, ItemsInFolder, FolderSize | Format-Table
```
Verifies archive exists and has folder structure. No results = archive not provisioned.

**Step 3 — Check retention tags on assigned policy**
```powershell
$policy = (Get-Mailbox -Identity <USER>).RetentionPolicy
Get-RetentionPolicy $policy | Select-Object -ExpandProperty RetentionPolicyTagLinks |
    ForEach-Object { Get-RetentionPolicyTag $_ | Select-Object Name, Type, AgeLimitForRetention, RetentionAction }
```
Look for: at least one `MoveToArchive` tag with a `DefaultPolicy` or `RecoverableItems` type.

**Step 4 — Check Recoverable Items size (litigation hold impact)**
```powershell
Get-MailboxFolderStatistics -Identity <USER> -FolderScope RecoverableItems |
    Select-Object Name, ItemsInFolder, FolderAndSubfolderSize | Format-Table
```
Healthy: `Purges` folder small. Large `DiscoveryHolds` or `SubstrateHolds` = active compliance hold.

**Step 5 — Trigger MFA manually (test only)**
```powershell
Start-ManagedFolderAssistant -Identity <USER>
```
Note: In EXO this queues the job — it does not run synchronously. Check archive folder stats after ~30 minutes.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Archive Not Enabled

```powershell
# Enable archive for single user
Enable-Mailbox -Identity <USER> -Archive

# Verify
Get-Mailbox -Identity <USER> | Select ArchiveStatus
# Should return: Active (may take a few minutes to provision)
```

For bulk:
```powershell
# Enable archive for all users without one
Get-Mailbox -Filter { ArchiveStatus -eq "None" -and RecipientTypeDetails -eq "UserMailbox" } |
    Enable-Mailbox -Archive
```

### Phase 2 — Auto-Expanding Archive Not Triggering

```powershell
# Check if AEA is enabled at mailbox level
Get-Mailbox -Identity <USER> | Select AutoExpandingArchiveEnabled

# Enable AEA for specific mailbox
Enable-Mailbox -Identity <USER> -AutoExpandingArchive

# Enable AEA tenant-wide (recommended for all E3/E5 tenants)
Set-OrganizationConfig -AutoExpandingArchive
```

**Important:** AEA only kicks in when the archive reaches 90-100 GB. You cannot pre-provision auxiliary archives. Once AEA is enabled on a mailbox, it cannot be disabled.

### Phase 3 — Items Not Moving to Archive

```powershell
# Step 1: Check retention hold
Get-Mailbox -Identity <USER> | Select RetentionHoldEnabled, RetentionHoldUntil

# Clear retention hold if stuck
Set-Mailbox -Identity <USER> -RetentionHoldEnabled $false

# Step 2: Verify a MoveToArchive tag exists in the policy
$policy = (Get-Mailbox <USER>).RetentionPolicy
Get-RetentionPolicy $policy | Select -ExpandProperty RetentionPolicyTagLinks |
    ForEach-Object {
        Get-RetentionPolicyTag $_ |
            Where-Object { $_.RetentionAction -eq "MoveToArchive" } |
            Select Name, AgeLimitForRetention, RetentionAction
    }

# Step 3: Trigger MFA
Start-ManagedFolderAssistant -Identity <USER>
```

### Phase 4 — Litigation Hold Issues

```powershell
# Check hold status
Get-Mailbox -Identity <USER> | Select LitigationHoldEnabled, LitigationHoldDate,
    LitigationHoldOwner, LitigationHoldDuration

# Enable litigation hold (preserves ALL content indefinitely unless duration set)
Set-Mailbox -Identity <USER> -LitigationHoldEnabled $true -LitigationHoldDuration Unlimited

# Disable litigation hold (requires explicit business justification — irreversible for content in hold)
Set-Mailbox -Identity <USER> -LitigationHoldEnabled $false
```

### Phase 5 — MRM 2.0 Retention Label Not Applying

1. In Compliance Center → Data lifecycle management → Retention policies — verify the policy status is **On** and the Exchange location includes the user.
2. New policies take up to 7 days to propagate. Check `Policy distribution status` in the Compliance Center.
3. If a higher-priority policy exists that conflicts, the higher-priority one wins. Check all policies that apply to the mailbox.
4. Run the compliance diagnostics:
   - Compliance Center → Settings → Run diagnostics → "Troubleshoot retention policies"

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate from MRM 1.0 to MRM 2.0</summary>

Microsoft is deprecating MRM 1.0 retention tags/policies in favour of Compliance Center-managed policies. Timeline: users can no longer create new MRM 1.0 policies via EAC after EOM 2025.

**Assessment:**
```powershell
# Find all mailboxes still using MRM 1.0 policies
Get-Mailbox -ResultSize Unlimited |
    Where-Object { $_.RetentionPolicy -ne $null } |
    Select DisplayName, PrimarySmtpAddress, RetentionPolicy |
    Export-Csv "C:\Temp\MRM1_Mailboxes.csv" -NoTypeInformation
```

**Migration approach:**
1. Create equivalent retention labels and policies in Compliance Center
2. Assign Compliance Center policies to Exchange locations
3. Remove MRM 1.0 retention policy from mailboxes (set to $null or assign default no-op policy)
4. Monitor via Compliance Center policy distribution status
5. **Do not remove MRM 1.0 tags until Compliance Engine policies are confirmed active**

**Note:** Archive policies (MoveToArchive) have no direct equivalent in MRM 2.0. Use MRM 2.0 only for deletion/hold. Archive enablement remains via EXO PowerShell.

</details>

<details><summary>Playbook 2 — Remediate Bloated Recoverable Items Folder</summary>

When litigation hold is active, Recoverable Items can grow beyond the 30 GB quota (or 100 GB with E5/Compliance), causing delivery failures.

```powershell
# 1. Check current Recoverable Items size
Get-MailboxFolderStatistics -Identity <USER> -FolderScope RecoverableItems |
    Select-Object Name, @{N="SizeMB";E={[math]::Round($_.FolderAndSubfolderSize.Value.ToMB(),2)}} |
    Sort-Object SizeMB -Descending

# 2. Increase the Recoverable Items quota temporarily (if on litigation hold)
Set-Mailbox -Identity <USER> -RecoverableItemsQuota 60GB -RecoverableItemsWarningQuota 55GB

# 3. Run Search and Purge via Compliance Center if old hold items can be released
# Compliance Center → Content Search → New search → target user → Actions → Purge items
# Requires eDiscovery role
```

**Root cause action:** Review whether litigation hold is still required. If not, disabling it allows MFA to purge aged items from Recoverable Items on its next run.

</details>

<details><summary>Playbook 3 — Force MFA Processing and Validate Archive Move</summary>

```powershell
# 1. Note current item count in primary inbox
$beforePrimary = Get-MailboxFolderStatistics -Identity <USER> -FolderScope Inbox |
    Select ItemsInFolder, FolderSize

# 2. Note current archive item count
$beforeArchive = Get-MailboxFolderStatistics -Identity <USER> -FolderScope Archive |
    Select ItemsInFolder, FolderSize

# 3. Queue MFA
Start-ManagedFolderAssistant -Identity <USER>

# 4. Wait 30-60 minutes, then re-check
Start-Sleep -Seconds 3600
$afterArchive = Get-MailboxFolderStatistics -Identity <USER> -FolderScope Archive |
    Select ItemsInFolder, FolderSize

Write-Host "Archive before: $($beforeArchive.ItemsInFolder) items"
Write-Host "Archive after:  $($afterArchive.ItemsInFolder) items"
```

If item count does not change after MFA run, check:
- Retention Hold (`RetentionHoldEnabled`)
- Item ages vs retention tag age limits
- Personal tags set by user that override the DPT

</details>

---
## Evidence Pack

```powershell
# Run this script to collect all archive/retention evidence for a user
param([string]$UserIdentity = "<USER>")

Write-Host "=== MAILBOX CONFIGURATION ===" -ForegroundColor Cyan
Get-Mailbox -Identity $UserIdentity | Select-Object DisplayName, PrimarySmtpAddress,
    ArchiveStatus, ArchiveGuid, ArchiveDatabase, ArchiveQuota, ArchiveWarningQuota,
    AutoExpandingArchiveEnabled, RetentionPolicy, RetentionHoldEnabled, RetentionHoldUntil,
    LitigationHoldEnabled, LitigationHoldDate, LitigationHoldDuration, LitigationHoldOwner |
    Format-List

Write-Host "=== RETENTION POLICY TAGS ===" -ForegroundColor Cyan
$policy = (Get-Mailbox -Identity $UserIdentity).RetentionPolicy
if ($policy) {
    Get-RetentionPolicy $policy | Select -ExpandProperty RetentionPolicyTagLinks |
        ForEach-Object { Get-RetentionPolicyTag $_ } |
        Select Name, Type, AgeLimitForRetention, RetentionAction | Format-Table
} else {
    Write-Host "No MRM 1.0 retention policy assigned"
}

Write-Host "=== ARCHIVE FOLDER STATISTICS ===" -ForegroundColor Cyan
Get-MailboxFolderStatistics -Identity $UserIdentity -FolderScope Archive |
    Select Name, ItemsInFolder, FolderAndSubfolderSize | Format-Table

Write-Host "=== RECOVERABLE ITEMS ===" -ForegroundColor Cyan
Get-MailboxFolderStatistics -Identity $UserIdentity -FolderScope RecoverableItems |
    Select Name, ItemsInFolder, FolderAndSubfolderSize | Format-Table

Write-Host "=== PRIMARY MAILBOX SIZE ===" -ForegroundColor Cyan
Get-MailboxStatistics -Identity $UserIdentity |
    Select DisplayName, TotalItemSize, ItemCount, LastLogonTime, LastUserActionTime | Format-List
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check archive status | `Get-Mailbox <user> \| Select ArchiveStatus, ArchiveQuota` |
| Enable archive | `Enable-Mailbox <user> -Archive` |
| Enable auto-expanding archive | `Enable-Mailbox <user> -AutoExpandingArchive` |
| Enable tenant-wide AEA | `Set-OrganizationConfig -AutoExpandingArchive` |
| Check retention policy | `Get-Mailbox <user> \| Select RetentionPolicy, RetentionHoldEnabled` |
| Clear retention hold | `Set-Mailbox <user> -RetentionHoldEnabled $false` |
| Trigger MFA | `Start-ManagedFolderAssistant -Identity <user>` |
| Enable litigation hold | `Set-Mailbox <user> -LitigationHoldEnabled $true` |
| Check Recoverable Items size | `Get-MailboxFolderStatistics <user> -FolderScope RecoverableItems` |
| Check archive folder sizes | `Get-MailboxFolderStatistics <user> -FolderScope Archive` |
| List all retention policy tags | `Get-RetentionPolicyTag \| Select Name, Type, RetentionAction, AgeLimitForRetention` |
| Assign retention policy | `Set-Mailbox <user> -RetentionPolicy "<PolicyName>"` |
| Remove retention policy | `Set-Mailbox <user> -RetentionPolicy $null` |
| Check mailbox statistics | `Get-MailboxStatistics <user> \| Select TotalItemSize, ItemCount` |

---
## 🎓 Learning Pointers

- **MRM 1.0 vs MRM 2.0 coexistence**: Both can be active simultaneously on a mailbox. MRM 2.0 takes precedence for *deletion* — if an item is subject to both a compliance retention label (retain) and an MRM 1.0 tag (delete), the item is retained. MRM 1.0 archive moves still operate independently. [MS Docs — How retention works for Exchange](https://learn.microsoft.com/en-us/purview/retention-policies-exchange)
- **Auto-Expanding Archive is one-way**: Once enabled at the tenant level (`Set-OrganizationConfig -AutoExpandingArchive`), all existing and new archives will eventually auto-expand. You cannot revert a mailbox to a fixed-size archive. Plan before enabling.
- **Retention Hold is a migration tool, not a safety feature**: `RetentionHoldEnabled` was designed to prevent MFA from processing a mailbox while you set up retention policies. It is frequently left enabled after migrations. A quick audit of all mailboxes with `RetentionHoldEnabled = $true` often surfaces dozens of "stuck" mailboxes. [MS Docs — Retention Hold](https://learn.microsoft.com/en-us/exchange/security-and-compliance/messaging-records-management/mailbox-retention-hold)
- **MFA is not a real-time service in EXO**: The 7-day cycle is a design choice for scale. For urgent testing, `Start-ManagedFolderAssistant` queues the run — it does not execute immediately. For compliance audits, account for this lag in SLAs.
- **The Recoverable Items quota trap**: Mailboxes on litigation hold have a Recoverable Items quota of 30 GB (100 GB with E5). When this fills, the mailbox stops accepting mail and sync stalls. Detection: monitor via `Get-MailboxFolderStatistics` for the `Purges` folder size. Remediation requires either increasing quota or disabling the hold. [Community — Recoverable Items quota management](https://techcommunity.microsoft.com/t5/exchange-team-blog/the-recoverable-items-folder-in-exchange-2013/ba-p/589462)
- **Exchange Admin Center deprecation of MRM 1.0**: The new EAC no longer surfaces MRM retention tags — you must use PowerShell. This is a good time to evaluate migrating to Compliance Center-managed policies for a unified retention management experience across Exchange, SharePoint, and Teams.
