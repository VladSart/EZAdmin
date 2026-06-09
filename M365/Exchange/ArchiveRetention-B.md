# Exchange Online Archive & Retention — Hotfix Runbook (Mode B: Ops)
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
# 1. Check archive mailbox status
Connect-ExchangeOnline
Get-Mailbox -Identity <UPN> | Select-Object DisplayName, ArchiveStatus, ArchiveState, ArchiveDatabase, RetentionHoldEnabled, LitigationHoldEnabled

# 2. Check if archive is provisioned/enabled
Get-Mailbox -Identity <UPN> | Select-Object ArchiveGuid, ArchiveQuota, ArchiveWarningQuota

# 3. Check archive size and item count
Get-MailboxStatistics -Identity <UPN> -Archive -ErrorAction SilentlyContinue | Select-Object DisplayName, TotalItemSize, ItemCount, LastLogonTime

# 4. Check MRM (Managed Records Management) policy applied
Get-Mailbox -Identity <UPN> | Select-Object RetentionPolicy, RetentionComment, RetentionUrl

# 5. Check litigation / in-place hold status
Get-Mailbox -Identity <UPN> | Select-Object LitigationHoldEnabled, LitigationHoldDuration, LitigationHoldDate, LitigationHoldOwner, InPlaceHolds
```

| Result | Meaning | Action |
|--------|---------|--------|
| `ArchiveStatus = None` | Archive not enabled | Fix 1 |
| `ArchiveStatus = Active`, items not moving | Auto-archive MRM policy not working | Fix 2 |
| Archive full / quota warning | Archive quota exceeded | Fix 3 |
| `RetentionHoldEnabled = True` | MRM processing paused on mailbox | Fix 4 |
| `LitigationHoldEnabled = True` | Items preserved — cannot permanently delete | Fix 5 |
| Archive enabled but not visible in Outlook | Outlook profile needs refresh / AutoDiscover issue | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Exchange Online Plan 2 license (or M365 E3/E5 for auto-expanding archive)
    └── Mailbox provisioned in Exchange Online
            └── Archive mailbox enabled (Enable-Mailbox -Archive)
                    └── MRM Retention Policy assigned to mailbox
                            ├── Retention policy tags configured
                            │       └── Archive tag: "Move to Archive" action
                            └── Managed Folder Assistant (MFA) runs on mailbox
                                    └── Items matching tag criteria moved to archive
                                            └── Auto-expanding archive kicks in if >100 GB
                                                    └── (Requires Exchange Online Plan 2)
```

**Hold stack (separate from archive, but often confused):**
```
Litigation Hold / Compliance Hold
    ├── Items cannot be permanently deleted from recoverable items
    ├── Retention policy can still move items to archive
    └── eDiscovery search covers both primary + archive mailbox
```

**Common gaps:**
- User has Exchange Online Plan 1 (no archive) or basic M365 Business license
- Archive enabled but no "Move to Archive" retention tag in the policy
- Retention hold set (migration or manual) pausing all MRM processing
- Auto-expanding archive not enabled on the mailbox even though license allows it
- Outlook client configured without AutoDiscover — archive folder not discovered
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm license supports archive**
```powershell
# Check assigned licenses
Get-MgUserLicenseDetail -UserId '<UPN>' |
  Where-Object { $_.SkuPartNumber -match "EXCHANGEENTERPRISE|SPE_E3|SPE_E5|O365_BUSINESS_PREMIUM|M365_E3|M365_E5" } |
  Select-Object SkuPartNumber
```
Exchange Online Plan 2 = `EXCHANGEENTERPRISE`. Plan 1 = `EXCHANGESTANDARD` (archive requires P2 or add-on).

**Step 2 — Check archive mailbox status**
```powershell
Get-Mailbox -Identity <UPN> | Format-List ArchiveStatus, ArchiveState, ArchiveGuid, ArchiveQuota, ArchiveWarningQuota
```
- `ArchiveStatus = None` → not enabled → run `Enable-Mailbox -Identity <UPN> -Archive`
- `ArchiveStatus = Active` → enabled and running
- `ArchiveState = HostedPending` → provisioning in progress (wait 15–30 min)

**Step 3 — Check archive size**
```powershell
Get-MailboxStatistics -Identity <UPN> -Archive | Select-Object TotalItemSize, ItemCount, DeletedItemCount
```
If `TotalItemSize` is near `ArchiveQuota`, archive is full → Fix 3.

**Step 4 — Check MRM retention policy and tags**
```powershell
# Get policy name
$mbx = Get-Mailbox -Identity <UPN>
$mbx.RetentionPolicy

# Get tags in that policy
Get-RetentionPolicyTag -RetentionPolicy $mbx.RetentionPolicy | 
  Select-Object Name, Type, RetentionAction, AgeLimitForRetention, MessageClass
```
Look for a tag with `RetentionAction = MoveToArchive`. If missing → Fix 2.

**Step 5 — Check MFA (Managed Folder Assistant) last run**
```powershell
Get-MailboxStatistics -Identity <UPN> | Select-Object LastLogonTime, MoveToArchiveProcessingResult
```
Also check:
```powershell
Get-Mailbox -Identity <UPN> | Select-Object RetentionHoldEnabled
```
If `RetentionHoldEnabled = True`, MFA is paused → Fix 4.

---
## Common Fix Paths

<details><summary>Fix 1 — Enable archive mailbox</summary>

**Symptom:** User has no archive folder. `ArchiveStatus = None`.

```powershell
# Enable archive
Enable-Mailbox -Identity <UPN> -Archive

# Verify (may take 15-30 minutes to provision)
Get-Mailbox -Identity <UPN> | Select-Object ArchiveStatus, ArchiveGuid
```

**For bulk enablement:**
```powershell
# Enable archive for all users with Exchange Plan 2 who don't have archive yet
Get-Mailbox -Filter { ArchiveStatus -eq "None" -and RecipientTypeDetails -eq "UserMailbox" } -ResultSize Unlimited |
  Enable-Mailbox -Archive
```

**Auto-expanding archive (requires Exchange Online Plan 2):**
```powershell
# Enable auto-expanding archive for a specific user
Enable-Mailbox -Identity <UPN> -AutoExpandingArchive

# Enable tenant-wide (applies to all future mailboxes)
Set-OrganizationConfig -AutoExpandingArchive
```

**Rollback:** Disabling archive is destructive (data loss). Do not disable without explicit user/legal approval.
</details>

<details><summary>Fix 2 — Items not moving to archive (MRM policy issue)</summary>

**Symptom:** Archive exists but primary mailbox keeps growing; items never move.

**Check 1 — Policy has a MoveToArchive tag:**
```powershell
Get-RetentionPolicyTag -RetentionPolicy (Get-Mailbox <UPN>).RetentionPolicy |
  Where-Object { $_.RetentionAction -eq "MoveToArchive" }
```

If no MoveToArchive tag:
```powershell
# Create a default archive tag (moves all items older than 2 years)
New-RetentionPolicyTag -Name "Archive - 2 Years" -Type All -RetentionAction MoveToArchive -AgeLimitForRetention 730

# Add it to the existing policy
$policy = (Get-Mailbox <UPN>).RetentionPolicy
Set-RetentionPolicy -Identity $policy -RetentionPolicyTagLinks (
    (Get-RetentionPolicy -Identity $policy).RetentionPolicyTagLinks + 
    (Get-RetentionPolicyTag "Archive - 2 Years").DistinguishedName
)
```

**Check 2 — Force MFA to run immediately:**
```powershell
# Kick off MFA for the specific mailbox (may take hours for large mailboxes)
Start-ManagedFolderAssistant -Identity <UPN>
```
MFA runs in the background — items will be moved during its next cycle (typically within 24 hours after triggering, can be up to 7 days in large tenants).

**Check 3 — Folder-level personal tags overriding default:**
If a user has applied a "Never Delete" or "Never Move" personal tag to a folder, MFA won't move items in that folder regardless of the default policy. User must remove the personal tag in Outlook.
</details>

<details><summary>Fix 3 — Archive quota exceeded</summary>

**Symptom:** `TotalItemSize` approaching or at `ArchiveQuota`. New items can't move to archive.

**Option A — Increase archive quota (if not using auto-expanding):**
```powershell
Set-Mailbox -Identity <UPN> -ArchiveQuota 150GB -ArchiveWarningQuota 140GB
```
Note: Exchange Online Plan 2 allows 100 GB base archive + auto-expanding. Plan 1 has a 50 GB cap.

**Option B — Enable auto-expanding archive (requires Plan 2):**
```powershell
Enable-Mailbox -Identity <UPN> -AutoExpandingArchive
```
After enabling, Exchange Online automatically provisions additional archive storage as needed. This is a one-way operation.

**Option C — Clean up archive (if content is eligible):**
```powershell
# Check what's in recoverable items (often a large hidden contributor)
Get-MailboxStatistics -Identity <UPN> -Archive | Select-Object TotalDeletedItemSize
```
If holds are not in place, the Recoverable Items folder can be purged by compliance admins via Content Search + purge action. Do not do this without explicit legal/compliance sign-off.

**Rollback:** Auto-expanding archive cannot be disabled once enabled.
</details>

<details><summary>Fix 4 — Retention hold pausing MRM</summary>

**Symptom:** `RetentionHoldEnabled = True` — MFA skips the mailbox entirely.

```powershell
# Check
Get-Mailbox -Identity <UPN> | Select-Object RetentionHoldEnabled, RetentionHoldUntil, RetentionComment

# Remove retention hold (only if it's safe to do so — check with admin/compliance first)
Set-Mailbox -Identity <UPN> -RetentionHoldEnabled $false

# Force MFA immediately after removing hold
Start-ManagedFolderAssistant -Identity <UPN>
```

⚠️ Retention holds are sometimes set intentionally (e.g., during mailbox migration to prevent items being archived mid-flight). Always check with the project owner before removing.

**Common cause:** Migration tools (BitTitan MigrationWiz, IMAP migrations) set retention hold and don't clean up after migration completes.
</details>

<details><summary>Fix 5 — Litigation hold — user can't delete items</summary>

**Symptom:** User reports deleted items keep reappearing, or mailbox is unexpectedly large. `LitigationHoldEnabled = True`.

Litigation hold is intentional — items in the mailbox (including deleted items) are preserved for eDiscovery. Do NOT remove without explicit legal/compliance approval.

```powershell
# View hold details
Get-Mailbox -Identity <UPN> | Select-Object LitigationHoldEnabled, LitigationHoldDuration, LitigationHoldDate, LitigationHoldOwner

# Remove hold ONLY with explicit written approval
Set-Mailbox -Identity <UPN> -LitigationHoldEnabled $false
```

If user's mailbox is growing due to litigation hold, the correct fix is either:
- Increase mailbox/archive quota (not remove the hold)
- Enable archive so held items move there (archive is still covered by the hold)
- Explain to user that they cannot permanently delete items while hold is active
</details>

<details><summary>Fix 6 — Archive folder not visible in Outlook</summary>

**Symptom:** Archive is provisioned (Active) in EXO but user can't see it in Outlook.

**Check 1 — AutoDiscover:**
```powershell
# From user's machine (run as user):
Test-OutlookConnectivity -ProbeIdentity Autodiscover
```
Or use the Remote Connectivity Analyzer: https://testconnectivity.microsoft.com

**Check 2 — Outlook profile refresh:**
1. Close Outlook.
2. Open Control Panel > Mail > Email Accounts.
3. Remove and re-add the Exchange account.
4. Reopen Outlook — archive should appear within a few minutes.

**Check 3 — Outlook Web Access test:**
Have user sign into `https://outlook.office365.com` — if archive is visible in OWA but not in Outlook client, the issue is client-side (profile, cache, or old Outlook version).

**Minimum Outlook version for online archive:** Outlook 2013 or later. Earlier versions do not support Exchange Online archive.
</details>

---
## Escalation Evidence

```
=== EXCHANGE ARCHIVE/RETENTION ESCALATION EVIDENCE PACK ===
Date/Time (UTC): ___________________
Tenant: ___________________
Affected UPN: ___________________
Ticket: ___________________

SYMPTOM:
[ ] Archive not present / not enabled
[ ] Items not moving to archive
[ ] Archive quota exceeded
[ ] Items not being deleted (hold in place)
[ ] Archive not visible in client

ARCHIVE STATUS:
ArchiveStatus: ___________________
ArchiveState: ___________________
ArchiveGuid: ___________________
ArchiveQuota: ___________________
ArchiveWarningQuota: ___________________
Archive TotalItemSize: ___________________
Archive ItemCount: ___________________

MRM POLICY:
RetentionPolicy: ___________________
RetentionHoldEnabled: ___________________
MoveToArchive tag present: [ ] Yes  [ ] No

HOLD STATUS:
LitigationHoldEnabled: ___________________
LitigationHoldDuration: ___________________
LitigationHoldOwner: ___________________
InPlaceHolds: ___________________

LICENSE:
Exchange Plan: ___________________
Auto-expanding archive licensed: [ ] Yes  [ ] No

ADDITIONAL NOTES:
___________________

Collected by: ___________________ at ___________________
```

---
## 🎓 Learning Pointers

- **Archive ≠ backup** — the Exchange Online archive is another folder in the same cloud mailbox. It is not a separate backup copy. Data loss in Exchange Online (accidental mass-delete) requires the Recoverable Items folder or a third-party backup.
- **MFA runs on a 7-day cycle** by default in Exchange Online — `Start-ManagedFolderAssistant` queues the mailbox for priority processing, but it still runs asynchronously. Don't expect items to move immediately.
- **Auto-expanding archive is one-way** — once enabled, you cannot disable it. It also can't be used with on-premises mailboxes in hybrid (archive must be cloud-hosted).
- **Litigation hold preserves everything** — including items the user "deleted" from Deleted Items and Recoverable Items. The user's experience is that their mailbox quota is always full; the fix is to increase quota (or archive), not remove the hold.
- **Personal tags override default policy** — if an end-user has applied a "Never Move" personal retention tag to a folder in Outlook, MFA respects that preference over the default archive policy. Education for users is the fix, not a server-side override.
- **MS Docs:** [Enable archive mailboxes](https://learn.microsoft.com/en-us/purview/enable-archive-mailboxes) | [Auto-expanding archive](https://learn.microsoft.com/en-us/purview/autoexpanding-archiving) | [Retention tags and policies](https://learn.microsoft.com/en-us/exchange/security-and-compliance/messaging-records-management/retention-tags-and-policies)
