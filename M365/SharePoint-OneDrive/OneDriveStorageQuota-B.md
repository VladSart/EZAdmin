# OneDrive Storage Quota Enforcement (Level 2 Expansion Removal, License Alignment, PAYG) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

> **Source-confidence note (September 2026):** three separate Message Center posts drive this runbook.
> - **MC1310684** (published 14 May 2026, rolled out early–mid July 2026, commercial clouds only — gov clouds excluded): "bug fix" that re-evaluates every OneDrive quota against the user's **license entitlement** during quota refresh. Admin-set quotas above the licence allowance get pulled down; users over the new quota go **read-only**.
> - **MC1465765** (published 1 Sept 2026, **sent only to tenants that used the old "Level 2 Expansion" to 25 TB**, not mirrored on public MC archives): E3/E5 users whose quota was raised above 5 TB lose the legacy increase **between November 2026 and February 2027**; anyone still over 5 TB goes read-only. Microsoft Support confirmed to Topedia (9 Sept 2026) that the 5 TB → 25 TB on-request expansion no longer exists for M365/O365 E3/E5.
> - **MC1477185** (22 Sept 2026, roadmap 562352): **OneDrive Pay-as-you-go storage** — $0.20/GB/month for usage *above* the licensed entitlement, up to 25 TB per account, preview now, GA November 2026 (all clouds early December 2026). Not available for EDU, GCC or 21Vianet (per Topedia).
>
> Microsoft's own Learn text for the read-only state and the PAYG setup exists; the MC1465765 wording is quoted from Topedia/Office365ITPros, not read directly.

---

## Triage

Run in the **SharePoint Online Management Shell** (or `Microsoft.Online.SharePoint.PowerShell` module) as SharePoint Administrator.

```powershell
Connect-SPOService -Url "https://<tenantName>-admin.sharepoint.com"

# 1. Every OneDrive over 5 TB used, or with a quota above 5 TB (Level 2 expansion survivors)
$od = Get-SPOSite -IncludePersonalSite $true -Limit All -Filter "Url -like '-my.sharepoint.com/personal/'"
$od | Where-Object { $_.StorageUsageCurrent -gt 5242880 -or $_.StorageQuota -gt 5242880 } |
    Select-Object Owner, Url, @{n='UsedGB';e={[math]::Round($_.StorageUsageCurrent/1024,1)}},
                  @{n='QuotaGB';e={[math]::Round($_.StorageQuota/1024,1)}}, LockState

# 2. Any OneDrive already read-only or no-access
$od | Where-Object { $_.LockState -ne 'Unlock' } | Select-Object Owner, Url, LockState

# 3. Specific user — used vs quota vs lock
Get-SPOSite -Identity "https://<tenantName>-my.sharepoint.com/personal/<user_domain_com>" |
    Select-Object Owner, StorageUsageCurrent, StorageQuota, StorageQuotaWarningLevel, LockState

# 4. Tenant default OneDrive quota (MB)
Get-SPOTenant | Select-Object OneDriveStorageQuota
```

> Values from `Get-SPOSite` are **MB (binary)**. 1 TB = 1,048,576 MB; 5 TB = 5,242,880 MB; 25 TB = 26,214,400 MB.

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| User's `StorageUsageCurrent` > 5,242,880 on an E3/E5 licence | Level 2 expansion user — will go read-only Nov 2026 – Feb 2027 unless reduced or paid for | → Fix 1 (reduce) or Fix 3/4 (buy storage) **before** enforcement |
| `StorageQuota` > licence entitlement but usage is under it | Quota will be silently lowered at next refresh; no user impact yet | Fix 2 — set quota to entitlement yourself so it's predictable |
| User on Business Basic/Standard/Premium or E1 and quota > 1 TB | Admin-set quota above licence — MC1310684 already pulls these down | Fix 2, and Fix 1 if usage > 1 TB |
| `LockState = ReadOnly` and usage > quota | Quota enforcement already hit | Fix 1 (clean-up incl. recycle bin) then Fix 5 (confirm unlock) |
| `LockState = ReadOnly` and usage **< quota** | Not a quota lock — admin lock, retention/legal hold workflow, or leaver process | Investigate lock source; see `Permissions-B.md` / `Sync-Issues-B.md` |
| User says "OneDrive won't sync / upload" but LockState = Unlock and usage < 90% | Not this issue | → `Sync-Issues-B.md` |
| Admin center usage numbers don't match `Get-SPOSite` | Usage reports are cached; MO1471241 (Sept 2026) delayed OneDrive/SharePoint usage reports from 8 Sept | Trust `Get-SPOSite` for decisions |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
User holds a licence with a OneDrive storage entitlement
    ├── E3/E5 (M365 or O365) ....... 1 TB default, admin can raise to 5 TB
    ├── Business Basic/Std/Premium, E1 ... 1 TB
    ├── F-SKUs ..................... 2 GB
    └── Education A1 ............... 100 GB
        │
Quota refresh evaluates configured quota against:
    licence entitlement  +  purchased add-on storage  +  PAYG (if billing policy linked)
        │
    ┌── Configured quota <= allowed ceiling → kept
    └── Configured quota  > allowed ceiling → reset to ceiling  (MC1310684 / MC1465765)
        │
StorageUsageCurrent (incl. first+second stage recycle bin, 93 days) vs quota
    ├── below quota → normal read/write/sync
    └── above quota → site LockState = ReadOnly
            ├── view / download: YES
            ├── upload / edit / sync: NO
            └── delete: needed to get back under quota (Office365ITPros assumes allowed)
        │
Relief paths (hard ceiling 25 TB per account in every case):
    ├── Reduce content
    ├── OneDrive extra storage add-on (CFQ7TTBZTMB1, $0.24/GB/mo decimal TB, 100 GB – 6 TB packs)
    └── OneDrive PAYG storage (billing policy → Azure subscription → "Microsoft 365 OneDrive Storage", $0.20/GB/mo)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Get the real numbers (not the usage report)**
```powershell
$s = Get-SPOSite -Identity "<oneDriveUrl>"
"{0:N1} GB used / {1:N1} GB quota / {2}" -f ($s.StorageUsageCurrent/1024), ($s.StorageQuota/1024), $s.LockState
```
Expected healthy: used < 90% of quota, `Unlock`. If used ≥ quota → quota lock is real.

**Step 2 — Confirm the user's licence entitlement**
```powershell
Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All"
Get-MgUserLicenseDetail -UserId "<UPN>" | Select-Object SkuPartNumber
```
`SPE_E3`, `SPE_E5`, `ENTERPRISEPACK`, `ENTERPRISEPREMIUM` → max 5 TB (without paid storage). `SPB`, `O365_BUSINESS_PREMIUM`, `O365_BUSINESS_ESSENTIALS`, `STANDARDPACK` → 1 TB. Unlicensed → OneDrive enters the unlicensed-account retention path, a different problem.

**Step 3 — Is the tenant in the Level 2 cohort?**
Check Message Center for **MC1465765**. It was sent only to affected tenants. If it's absent but Triage query 1 returns users with quota > 5 TB, open a Microsoft case to confirm scope. One commenter on Office365ITPros had 25 TB users and no MC post.

**Step 4 — Is paid storage already in place?**
M365 admin center → **Billing → Your products** (look for OneDrive extra storage) and **Settings → Org settings → Pay-as-you-go services** / billing policies (look for Microsoft 365 OneDrive Storage linked to a policy). No paid storage means the ceiling is the licence.

**Step 5 — Run the built-in diagnostic**
M365 admin center → Help → search **"OneDrive storage quota"** → **Run Tests**. Not available in GCC High, DoD, 21Vianet or Education.

---

## Common Fix Paths

<details><summary>Fix 1 — Get the user back under quota (clean-up)</summary>

1. User opens OneDrive web → ⚙ Settings → **More settings → Storage Metrics** to find the largest folders and files.
2. Remember the **recycle bins count toward usage for 93 days**. After deleting, empty the first-stage bin (user) and the second-stage bin (site collection admin).
3. Old versions count too. Trim version history on very large, frequently edited files. Batch trim jobs use `New-SPOSiteFileVersionBatchDeleteJob` (needs a current SPO Management Shell).

```powershell
# Make yourself site collection admin on the OneDrive to empty the 2nd-stage bin / inspect
Set-SPOUser -Site "<oneDriveUrl>" -LoginName "<adminUPN>" -IsSiteCollectionAdmin $true

# Trim versions older than 180 days across the OneDrive (DESTRUCTIVE — versions are permanently deleted)
New-SPOSiteFileVersionBatchDeleteJob -Identity "<oneDriveUrl>" -DeleteBeforeDays 180
Get-SPOSiteFileVersionBatchDeleteJobProgress -Identity "<oneDriveUrl>"

# Remove yourself again
Set-SPOUser -Site "<oneDriveUrl>" -LoginName "<adminUPN>" -IsSiteCollectionAdmin $false
```
**Rollback:** none for version trims or emptying the second-stage bin. Content is gone. Check retention or backup (see `M365/Backup/`) before trimming for a user under legal hold. Retention-held versions are preserved in the Preservation Hold Library and **still count toward quota**.

</details>

<details><summary>Fix 2 — Set quota to the licence entitlement before Microsoft does</summary>

This makes enforcement predictable and triggers the user's warning emails early.
```powershell
# 5 TB quota, warning at 4.5 TB (values in MB)
Set-SPOSite -Identity "<oneDriveUrl>" -StorageQuota 5242880 -StorageQuotaWarningLevel 4718592
```
If usage is already above the new value, the site goes **read-only immediately**. Do Fix 1 first, or schedule this with the user.
**Rollback:** set `-StorageQuota` back to the previous value (record it first). This only holds until the next licence-based refresh if the old value exceeded entitlement.

</details>

<details><summary>Fix 3 — Buy OneDrive extra storage add-on (fixed capacity)</summary>

- M365 admin center → Marketplace → **OneDrive extra storage** (product ID `CFQ7TTBZTMB1`). Packs run from 100 GB to 6 TB at $0.24/GB/month list (Topedia, Sept 2026). The add-on uses **decimal** TB (1 TB = 1,000 GB) while quotas use **binary** (1 TB = 1,024 GB), so size packs with a margin.
- After the purchase is provisioned, raise the user's quota (admin center → Active users → user → OneDrive → Storage used → Edit, or `Set-SPOSite -StorageQuota`). The per-account ceiling is still **25 TB**.

**Rollback:** reduce quota back to entitlement first, then cancel the add-on. Cancelling while users sit above entitlement triggers read-only.

</details>

<details><summary>Fix 4 — Enable OneDrive Pay-as-you-go storage (metered)</summary>

1. You need an **Azure subscription** in the same tenant and **Global Admin or SharePoint Admin + Billing/Azure Owner** to create the link.
2. M365 admin center → Settings → Org settings → **Pay-as-you-go services** → **Billing policies** → create a policy tied to the Azure subscription and resource group.
3. Under Storage → **Microsoft 365 OneDrive Storage** → attach the billing policy.
4. Raise individual quotas above entitlement (up to 25 TB). Billing counts **only the GB above the licensed entitlement**: $0.20/GB/month, shown as $0.00667/GB/day.

> ⚠️ **Scope conflict in sources:** Topedia (Sept 2026) says the policy **cannot be scoped to individual users** and applies to every OneDrive that goes above entitlement. Office365ITPros (23 Sept 2026) says it "can be limited to specific accounts". **Assume tenant-wide** until you see a per-user scope option in your admin center. That means any admin who raises a quota creates billable overage.
> Preview until November 2026 GA. Not available to EDU, GCC or 21Vianet.

**Rollback:** set quotas back to entitlement **before** detaching the billing policy. Detaching with users over entitlement triggers read-only at the next refresh.

</details>

<details><summary>Fix 5 — Confirm a read-only OneDrive has unlocked</summary>

```powershell
Get-SPOSite -Identity "<oneDriveUrl>" | Select-Object StorageUsageCurrent, StorageQuota, LockState
```
Usage figures refresh asynchronously and can take hours. If usage is under quota and the site is still `ReadOnly` after 24–48 h, run the admin-center quota diagnostic (Step 5 above), then escalate. **Do not** `Set-SPOSite -LockState Unlock` a OneDrive whose lock you didn't place. You may clear a retention or offboarding lock by mistake.

</details>

---

## Escalation Evidence

```
TICKET: OneDrive storage quota enforcement / read-only
=====================================================
Tenant: <tenantName>.onmicrosoft.com   Cloud: <Commercial/GCC/EDU>
Message Center posts present (MC1310684 / MC1465765 / MC1477185): <list>
Affected OneDrive URL: <url>
Owner UPN: <upn>
Licence SKU(s) (Get-MgUserLicenseDetail): <SkuPartNumber list>
StorageUsageCurrent (MB): <value>    StorageQuota (MB): <value>    LockState: <value>
Quota before change (if known): <value>   Date quota changed: <date>
Was quota ever raised above 5 TB via Microsoft Support "Level 2 expansion"? <yes/no + old case #>
Paid storage in place (add-on / PAYG billing policy): <add-on SKU + GB / billing policy name>
Recycle bin emptied (1st + 2nd stage)? <yes/no/date>
Admin-center "OneDrive storage quota" diagnostic result: <paste>
Business impact: <e.g., engineering archive, 6.2 TB, read-only since ...>
```

---

## 🎓 Learning Pointers

- **Quota ≠ entitlement.** Since MC1310684 (July 2026), Microsoft treats a quota above the licence as a bug and corrects it at refresh. Any MSP runbook that says "just raise the quota" is now incomplete unless paid storage is attached. See [Change a specific user's OneDrive storage space](https://learn.microsoft.com/en-us/sharepoint/change-user-storage).
- **Level 2 expansion is gone, not paused.** Microsoft Support confirmed the 5 → 25 TB request path no longer exists for E3/E5 ([Topedia, 4 Sept 2026](https://blog-en.topedia.com/2026/09/important-onedrive-storage-change-for-microsoft-enterprise-customers/)). The only way above 5 TB is now add-on or PAYG, capped at 25 TB ([Office365ITPros, 23 Sept 2026](https://office365itpros.com/2026/09/23/onedrive-storage-clampdown/)).
- **Recycle bins and versions count toward quota** for 93 days. Clean-ups that "didn't free anything" are usually sitting in the second-stage bin.
- **Binary vs decimal TB.** Quotas are 1,024 GB per TB; add-on packs are priced per 1,000 GB. Size purchases with headroom.
- **Use Microsoft's own over-quota report** as a cross-check: [PnP script sample "Identify OneDrive users over license-based storage quota"](https://pnp.github.io/script-samples/onedrive-overquota-report/README.html?tabs=graphps). It reads the admin-center usage report, which lagged in September 2026 (MO1471241).
- Pricing and setup for add-on and PAYG: [Add storage space for your subscription](https://learn.microsoft.com/en-us/microsoft-365/commerce/add-storage-space?view=o365-worldwide). Architecture and the enforcement timeline are covered in `OneDriveStorageQuota-A.md`. For the audit, run `Scripts/Get-OneDriveQuotaEnforcementReadiness.ps1`.
