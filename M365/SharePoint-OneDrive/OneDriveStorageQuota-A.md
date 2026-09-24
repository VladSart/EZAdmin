# OneDrive Storage Quota Enforcement (Level 2 Expansion Removal, License Alignment, PAYG) — Reference Runbook (Mode A: Deep Dive)
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

- **In scope:** OneDrive for Business storage quotas in Microsoft 365 commercial tenants, and the three 2026 changes that hardened them:
  1. **MC1310684** is the license-alignment "bug fix". Published 14 May 2026, it rolled out early to mid July 2026 and was withdrawn from gov clouds on 3 June 2026.
  2. **MC1465765** removes the Level 2 expansion. It was published 1 Sept 2026 and sent only to tenants that used the expansion. Enforcement runs November 2026 to February 2027.
  3. **MC1477185** introduces OneDrive Pay-as-you-go storage (roadmap 562352). It was published 22 Sept 2026, is in preview now, reaches GA in November 2026, and completes across all clouds in early December 2026.
- **Out of scope:** SharePoint *tenant* pooled storage (Office 365 Extra File Storage, SharePoint PAYG storage). OneDrive sync-client quota errors are covered in `Sync-Issues-A.md`. Retention of unlicensed/leaver OneDrives is also out of scope.
- **Assumes:** SharePoint Online Management Shell, a SharePoint Administrator (or Global Administrator), and optionally Microsoft Graph PowerShell for licence lookups.
- **Source confidence:** MC1310684 was read in full from the mc.merill.net archive. MC1465765 is quoted by Topedia (4 Sept 2026) and Office365ITPros (23 Sept 2026); it is not on public MC mirrors. PAYG pricing and setup are consistent across Topedia (11 and 23 Sept 2026), Office365ITPros and Learn *Add storage space*. **One unresolved conflict:** the two sources disagree on whether PAYG can be scoped to specific users. See Playbook 4.

---

## How It Works

<details><summary>Full architecture</summary>

### 1. Three numbers, not one

Every OneDrive has three storage values that admins routinely conflate:

```
  ┌────────────────────────────┐
  │ Licence entitlement        │  what the SKU(s) grant — the service description table
  │   E3/E5 : 1 TB default, admin-raisable to 5 TB
  │   Business Basic/Std/Prem, O365 E1 : 1 TB
  │   F-SKUs : 2 GB    A1 : 100 GB
  ├────────────────────────────┤
  │ + Paid storage             │  add-on packs (fixed) and/or PAYG (metered)
  │   hard ceiling 25 TB per account, whatever you pay
  ├────────────────────────────┤
  │ = Allowed ceiling          │  the highest quota the service will honour
  └────────────────────────────┘
  Configured quota  (Set-SPOSite -StorageQuota / admin center)  — what the admin typed
  Usage             (StorageUsageCurrent)                       — what is actually stored
```

Before 2026, the configured quota was effectively authoritative. An admin could type 10 TB and it stuck, and Level 2 tenants were told to do exactly that. **After MC1310684, the service periodically "refreshes" quotas and clamps any configured quota above the allowed ceiling back down to it.** Microsoft framed this as a bug fix: user-specific limits "could be incorrectly applied during quota refreshes."

### 2. The Level 2 expansion and its removal

Enterprise customers with at least five qualifying licences used to get "beyond 1 TB to unlimited" OneDrive storage. From about 2020–2022 this became a two-level process:

- Level 1: admins could raise any user to **5 TB** themselves.
- Level 2: once a user reached **90% of 5 TB**, Microsoft Support could approve an expansion allowing quotas of up to **25 TB**.

In August 2023 Microsoft stopped offering the unlimited option to new customers. It silently removed the 25 TB wording from the OneDrive service description between February and April 2026, and Microsoft confirms the service descriptions don't show change history. MC1465765 then told tenants that still had Level 2 users that those legacy increases will be removed during November 2026 to February 2027. The quota realigns to the licence, and anyone above it becomes read-only. In a support case with Topedia, Microsoft confirmed the on-request 5 → 25 TB route no longer exists for M365/O365 E3/E5.

### 3. What read-only means

When usage exceeds the (new) quota, the OneDrive site collection's `LockState` becomes `ReadOnly`. Per Learn and MC1465765, users **can view and download** but **cannot upload, modify or synchronise**. The sync client surfaces this as a full or read-only library. Office365ITPros reasonably assumes deletes remain possible, since that is the only way back under quota. Test this before promising it to a user.

### 4. Paid storage: two mechanisms

| | OneDrive extra storage add-on | OneDrive PAYG storage |
|---|---|---|
| Introduced | June 2026 | Preview Sept 2026, GA Nov 2026 |
| Billing | Fixed packs 100 GB – 6 TB, product ID `CFQ7TTBZTMB1` | Metered, **only GB above licensed entitlement** |
| List price (Topedia) | $0.24/GB/month, **decimal** TB | $0.20/GB/month ($0.00667/GB/day) |
| Prerequisite | Purchase in M365 admin center | Billing policy → Azure subscription → attach "Microsoft 365 OneDrive Storage" |
| Per-user scope | You raise specific users' quotas | **Disputed.** Assume tenant-wide (see Playbook 4) |
| Excluded | — | EDU, GCC, 21Vianet (Topedia) |
| Ceiling | 25 TB per account | 25 TB per account |

Because PAYG bills on *usage* above entitlement, the configured quota is only a **spend cap**. Once a billing policy is attached, raising a quota means approving spend.

### 5. Why usage numbers disagree

- `Get-SPOSite` `StorageUsageCurrent` comes from the site collection itself (MB, binary). It is the authoritative input to enforcement.
- The admin-center OneDrive usage report (and the Graph `getOneDriveUsageAccountDetail` report that the PnP over-quota script uses) is a daily-aggregated **report**. From 8 September 2026, service incident **MO1471241** stopped OneDrive, SharePoint and Group activity reports from refreshing.
- Both include **recycle bin contents (first and second stage, 93 days)** and **all file versions**, including Preservation Hold Library copies created by retention policies.

</details>

---

## Dependency Stack

```
Layer 6  User experience  — OneDrive web/sync/Office apps: read-write vs read-only
Layer 5  Site lock        — LockState on the personal site collection (Unlock / ReadOnly / NoAccess)
Layer 4  Enforcement      — Usage (incl. recycle bins, versions, PHL) compared to configured quota
Layer 3  Quota refresh    — Configured quota clamped to allowed ceiling (MC1310684, MC1465765)
Layer 2  Allowed ceiling  — Licence entitlement + add-on packs + PAYG billing policy  (≤ 25 TB)
Layer 1  Licensing        — Assigned SKU(s) in Entra ID; tenant cloud (Commercial / GCC / EDU / 21V)
```

A break at any lower layer surfaces as a Layer 6 complaint ("OneDrive says it's full / read-only").

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| User was fine at 7 TB for years, suddenly read-only (Nov 2026 – Feb 2027) | Level 2 expansion removed (MC1465765) | `Get-SPOSite` quota now 5,242,880 MB; MC1465765 in Message Center |
| Quota "reverted" from 3 TB to 1 TB after an admin raised it | Business-plan or E1 user; admin quota above entitlement clamped (MC1310684) | `Get-MgUserLicenseDetail` → `SPB`/`STANDARDPACK`/… |
| Quota reverted even though the user is E3/E5 and under 5 TB | Licence change or removal; a mixed-SKU user evaluated on the lower SKU; refresh bug | Licence history, admin-center quota diagnostic |
| Deleted 1 TB, still read-only | Content sitting in second-stage recycle bin or Preservation Hold Library | Site recycle bin; retention policies covering OneDrive |
| Admin-center usage report shows old values | MO1471241 report refresh incident (Sept 2026), or normal 24–48 h lag | Compare to `Get-SPOSite` |
| Unexpected Azure charge "Microsoft 365 OneDrive Storage" | PAYG policy attached and quotas raised above entitlement | Billing policy + list of users with quota > entitlement |
| Can't find the PAYG option | EDU/GCC/21Vianet tenant, or preview not yet in the tenant | Tenant cloud; roadmap 562352 status |
| Read-only but usage < quota | Not a quota lock (admin lock, leaver workflow, Restricted content, hold process) | Who set the lock: audit log `SiteLocked`-type events |

---

## Validation Steps

1. **Enumerate all OneDrives with real usage**
   ```powershell
   Connect-SPOService -Url "https://<tenantName>-admin.sharepoint.com"
   $od = Get-SPOSite -IncludePersonalSite $true -Limit All -Filter "Url -like '-my.sharepoint.com/personal/'"
   $od.Count
   ```
   Good: the count roughly matches licensed users plus retained leavers. Bad: `0` means the wrong admin URL or missing permissions.

2. **Level 2 exposure**
   ```powershell
   $od | Where-Object StorageUsageCurrent -gt 5242880 | Measure-Object
   ```
   Good: `Count : 0`. Bad: any number above 0 means users will be read-only by February 2027 unless you act.

3. **Quota-above-entitlement exposure.** Run `Scripts/Get-OneDriveQuotaEnforcementReadiness.ps1 -ResolveLicenses`.
   Good: no `QuotaAboveEntitlement = True` rows. Bad: rows exist, and they will be clamped at the next refresh.

4. **Paid storage present?** Check the admin center Billing → Your products (add-on) and Settings → Org settings → Pay-as-you-go services (billing policy linked to OneDrive Storage).
   Good: the answer matches your intent. Bad: PAYG is attached with nobody deciding who can go above entitlement.

5. **Locks.**
   ```powershell
   $od | Where-Object LockState -ne 'Unlock' | Select-Object Owner, LockState
   ```
   Good: only known leavers or holds. Bad: active users are `ReadOnly`.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Before enforcement (now → October 2026)**
- Inventory (Validation 1–3), then a stakeholder list per affected user with used TB, business owner and decision (reduce / add-on / PAYG).
- Set quota warning levels so users get email warnings: `-StorageQuotaWarningLevel` ~90% of the target quota.
- For decisions to reduce, start clean-up now. Version trimming and second-stage bin purges don't free space instantly because usage recalculates asynchronously.

**Phase 2 — During enforcement (November 2026 → February 2027)**
- Daily: `Get-SPOSite` sweep for `LockState` changes on the affected list.
- Pre-brief the helpdesk. Read-only users can still download, so for urgent needs, point them to copying active working files to a SharePoint team site with pooled tenant storage. Don't paste them into another user's OneDrive.

**Phase 3 — After enforcement**
- Confirm quotas equal entitlement plus paid storage for every user.
- If PAYG is used, set an Azure **budget alert** on the billing subscription and resource group.
- Add a monthly check (the script) to catch drift: new admins raising quotas under PAYG, and leavers whose OneDrive is retained above entitlement.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Bulk right-size quotas to entitlement (safe path)</summary>

Only lowers quotas where **usage is already under the target**, so nobody goes read-only.

```powershell
# Input: CSV from Get-OneDriveQuotaEnforcementReadiness.ps1
$rows = Import-Csv "<path>\OneDriveQuotaReadiness.csv" |
        Where-Object { $_.QuotaAboveEntitlement -eq 'True' -and $_.EntitlementMB -ne '' }
foreach ($r in $rows) {
    $target = [int64]$r.EntitlementMB
    if ([int64]$r.UsedMB -lt ($target * 0.95)) {
        Set-SPOSite -Identity $r.Url -StorageQuota $target -StorageQuotaWarningLevel ([int64]($target * 0.9))
        Write-Host "Set $($r.Url) -> $target MB"
    } else {
        Write-Warning "SKIP $($r.Url): used $($r.UsedMB) MB is within 5% of / above target — handle manually"
    }
}
```
**Rollback:** the CSV holds the original `QuotaMB`. Re-apply it with `Set-SPOSite -StorageQuota <QuotaMB>`. The service may clamp it again if it exceeds the ceiling.

</details>

<details><summary>Playbook 2 — Reduce a Level 2 user from > 5 TB to under 5 TB</summary>

1. Get the owner to agree on what's archival. Common candidates are raw media, VM images, PST exports and old project dumps.
2. Target: a SharePoint site (pooled tenant storage), Azure Blob/Files (cheapest for cold data), or deletion.
3. Move with **SharePoint Migration Tool / Migration Manager** (see `Migration-A.md`) or a OneDrive-to-SharePoint "Move to", which keeps version history for files ≤ the move limits.
4. After the move, purge the **first- and second-stage recycle bins** and consider a **version trim**:
   ```powershell
   New-SPOSiteFileVersionBatchDeleteJob -Identity "<oneDriveUrl>" -DeleteBeforeDays 365
   ```
5. Check retention. If a retention policy covers OneDrive, deleted content moves to the **Preservation Hold Library and still counts**. You may need a policy exclusion for the user, which is a compliance decision, not an IT one (see `Security/Purview/RetentionLabels-A.md`).

**Rollback:** moves are reversible. Recycle bin purges and version trims are **not**.

</details>

<details><summary>Playbook 3 — Fixed-capacity add-on for a known few users</summary>

1. Size the need: `(UsedMB − EntitlementMB) / 1024` = binary GB. Add ~3% for the decimal/binary gap, plus growth headroom.
2. Buy **OneDrive extra storage** (`CFQ7TTBZTMB1`) in the admin center Marketplace.
3. After it provisions, raise quotas for those users only (≤ 25 TB each).
4. Document the assignment. The add-on is tenant capacity, not bound to a user in Entra, so the audit trail is your own record.

**Rollback:** lower quotas first, then reduce or cancel packs.

</details>

<details><summary>Playbook 4 — PAYG with guardrails</summary>

1. Create a dedicated resource group for the billing policy so cost reporting is clean.
2. Admin center → Settings → Org settings → Pay-as-you-go services → **Billing policies** → New → select the subscription and resource group.
3. Storage → **Microsoft 365 OneDrive Storage** → attach the policy.
4. Azure Cost Management → **Budget** on that resource group with 50/80/100% alerts.
5. Governance: restrict who holds SharePoint Administrator. With PAYG attached, any SharePoint Admin who raises a quota is committing spend.

> ⚠️ **Unresolved:** Topedia (11 Sept 2026) says the PAYG billing policy **cannot be assigned to individual users**. It applies to every OneDrive in the organisation that exceeds entitlement, and Topedia was still testing whether retained unlicensed OneDrives are billed. Office365ITPros (23 Sept 2026) says the agreement "can be limited to specific accounts or apply to all accounts". Check your admin-center UI at GA. Until then, design as if it's tenant-wide, and run the readiness script **before** attaching the policy so you know the day-one bill.

**Rollback:** lower every above-entitlement quota, **then** detach the policy. Detaching first leaves users over the new ceiling, and they go read-only.

</details>

---

## Evidence Pack

```powershell
# Collect OneDrive quota enforcement evidence for escalation (read-only)
param([string]$AdminUrl = "https://<tenantName>-admin.sharepoint.com",
      [string]$OneDriveUrl = "<oneDriveUrl>",
      [string]$Upn = "<UPN>",
      [string]$OutDir = "$env:TEMP\ODQuotaEvidence_$(Get-Date -f yyyyMMdd_HHmm)")
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Connect-SPOService -Url $AdminUrl
Get-SPOTenant | Select-Object OneDriveStorageQuota |
    Export-Csv "$OutDir\tenant.csv" -NoTypeInformation
Get-SPOSite -Identity $OneDriveUrl | Select-Object Url, Owner, StorageUsageCurrent, StorageQuota,
    StorageQuotaWarningLevel, LockState, LastContentModifiedDate |
    Export-Csv "$OutDir\site.csv" -NoTypeInformation
try {
    Connect-MgGraph -Scopes "User.Read.All" -NoWelcome
    Get-MgUserLicenseDetail -UserId $Upn | Select-Object SkuPartNumber, SkuId |
        Export-Csv "$OutDir\licences.csv" -NoTypeInformation
} catch { "Graph licence lookup failed: $($_.Exception.Message)" | Out-File "$OutDir\licences-error.txt" }
Get-Date -Format o | Out-File "$OutDir\collected.txt"
Compress-Archive -Path "$OutDir\*" -DestinationPath "$OutDir.zip" -Force
Write-Host "Evidence: $OutDir.zip"
```

Attach the admin-center **OneDrive storage quota diagnostic** output and a screenshot of MC1465765 (if present) alongside the ZIP.

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Connect | `Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com` |
| All OneDrives | `Get-SPOSite -IncludePersonalSite $true -Limit All -Filter "Url -like '-my.sharepoint.com/personal/'"` |
| One OneDrive | `Get-SPOSite -Identity <oneDriveUrl> \| fl StorageUsageCurrent,StorageQuota,LockState` |
| Over 5 TB | `... \| ? StorageUsageCurrent -gt 5242880` |
| Set quota (MB) | `Set-SPOSite -Identity <url> -StorageQuota 5242880 -StorageQuotaWarningLevel 4718592` |
| Tenant default | `Get-SPOTenant \| select OneDriveStorageQuota` / `Set-SPOTenant -OneDriveStorageQuota <MB>` |
| Licence SKUs | `Get-MgUserLicenseDetail -UserId <UPN> \| select SkuPartNumber` |
| Temp site admin | `Set-SPOUser -Site <url> -LoginName <adminUPN> -IsSiteCollectionAdmin $true` |
| Trim versions | `New-SPOSiteFileVersionBatchDeleteJob -Identity <url> -DeleteBeforeDays 365` |
| Trim progress | `Get-SPOSiteFileVersionBatchDeleteJobProgress -Identity <url>` |
| MB ↔ TB | 1 TB = 1,048,576 MB · 5 TB = 5,242,880 MB · 25 TB = 26,214,400 MB |
| Readiness audit | `.\Get-OneDriveQuotaEnforcementReadiness.ps1 -AdminUrl <url> -ResolveLicenses` |

---

## 🎓 Learning Pointers

- The service description is now the contract. Storage limits by plan are in the [OneDrive service description](https://learn.microsoft.com/en-us/office365/servicedescriptions/onedrive-for-business-service-description). Microsoft confirmed it carries no public change history, so snapshot it when you advise a client.
- To change quotas, and for the built-in quota diagnostic, see [Change a specific user's OneDrive storage space](https://learn.microsoft.com/en-us/sharepoint/change-user-storage). The page was updated 4 Sept 2026 to mention OneDrive Storage above licence.
- For purchase and PAYG setup, see [Add storage space for your subscription](https://learn.microsoft.com/en-us/microsoft-365/commerce/add-storage-space?view=o365-worldwide).
- For history and commentary, see [Office365ITPros — Microsoft Draws Hard Line for OneDrive Storage Quotas](https://office365itpros.com/2026/09/23/onedrive-storage-clampdown/) and [Topedia — Important OneDrive storage change](https://blog-en.topedia.com/2026/09/important-onedrive-storage-change-for-microsoft-enterprise-customers/). Topedia includes the Microsoft Support confirmation.
- The PAYG cost tables and the decimal-vs-binary pricing observation come from [Topedia — OneDrive PAYG storage](https://blog-en.topedia.com/2026/09/onedrive-pay-as-you-go-storage-as-a-new-microsoft-billing-service/).
- Microsoft's own over-quota report is the [PnP script sample onedrive-overquota-report](https://pnp.github.io/script-samples/onedrive-overquota-report/README.html?tabs=graphps). It is report-based, so cross-check it against `Get-SPOSite`, especially during MO1471241-type reporting delays.
