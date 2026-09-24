# Exchange Online EWS Retirement (EWSEnabled + EWSAllowedAppIDs) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

**Scope:** Exchange Web Services (SOAP) in **Exchange Online only**. Phased disablement begins **1 October 2026**; permanent shutdown **1 April 2027** with no re-enablement (Message Center MC1227454). Exchange Server (on-premises, incl. SE) is **not** affected. For the legacy Outlook for Mac angle see `macOS/Troubleshooting/OutlookMac-B.md`; for EWS-based cross-tenant free/busy see `CrossTenantCalendarSharing-B.md`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

Typical tickets from October 2026: *"our CRM/backup/archiving/sync tool stopped reading mailboxes"*, *"vendor says EWS is blocked"*, *"legacy Outlook for Mac / Mac Calendar can't connect"*, *"it worked yesterday, we changed nothing"*.

```powershell
Connect-ExchangeOnline -ShowBanner:$false

# 1. The two values that decide everything. -RetrieveEwsOperationAccessPolicy is REQUIRED —
#    without it EwsAllowedAppIDs comes back empty even when populated.
Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy |
    Format-List EwsEnabled, EwsAllowedAppIDs

# 2. The OLDER user-agent-based policy — a second, independent gate (also applies to REST)
Get-OrganizationConfig |
    Format-List EwsApplicationAccessPolicy, EwsAllowList, EwsBlockList, EwsAllowOutlook, EwsAllowMacOutlook

# 3. Per-mailbox override for an affected user / service account
Get-CASMailbox -Identity <UPN> | Format-List EwsEnabled, EwsApplicationAccessPolicy, EwsAllowList, EwsBlockList

# 4. Resolve the vendor app's App ID (from the vendor or the EWS usage report) to a name
#    (Microsoft Graph PowerShell, Application.Read.All)
Get-MgServicePrincipal -Filter "appId eq '<AppId-GUID>'" | Select-Object DisplayName, AppId, PublisherName
```

| Result | Meaning | Action |
|---|---|---|
| `EwsEnabled : False` | EWS blocked tenant-wide (either you set it, or the 1 Oct 2026 rollout flipped an unset tenant) | → Fix 1 (re-enable with a correct allow list) |
| `EwsEnabled : True` and `EwsAllowedAppIDs` empty/blank | From enforcement this is **block-all** (was allow-all before Oct 2026) | → Fix 1 |
| `EwsEnabled : True`, list populated, affected app's App ID **missing** | App not allowed | → Fix 2 (read-merge-write) |
| App ID **is** on the list, change made < 24 h ago | Server cache not refreshed yet | Wait up to 24 h, then retest |
| App ID on list, > 24 h, still failing; `EwsApplicationAccessPolicy : EnforceAllowList` and app's user agent not in `EwsAllowList` (or matched in `EwsBlockList`) | Failing the **older** user-agent check — both checks must pass | → Fix 3 |
| Org OK, but `Get-CASMailbox` shows `EwsEnabled : False` for the target/service mailbox | Per-mailbox block | → Fix 4 |
| Affected client is legacy Outlook for Mac | EWS-only client — no durable fix | → Fix 5 |
| Date is on/after **1 April 2027** | Permanent retirement — no setting restores EWS | → Fix 6 (migrate to Graph, no workaround) |

---
## Dependency Cascade

<details><summary>What must be true for an EWS call to succeed in Exchange Online (Oct 2026 – Mar 2027)</summary>

```
[Calendar date < 1 April 2027]                      ← after this, nothing below matters
  └─ Org: EwsEnabled = True                         ← False = block all; unset/$null = subject to Microsoft's rollout
       └─ Org: EwsAllowedAppIDs contains the caller's Entra App (client) ID
            │    (True + empty list = BLOCK ALL after enforcement)
            │    (change propagation: up to 24 h server cache refresh)
            └─ Org: legacy user-agent policy passes (if configured)
                 │    EwsApplicationAccessPolicy EnforceAllowList → UA must match EwsAllowList
                 │    EnforceBlockList → UA must NOT match EwsBlockList
                 └─ Mailbox: CASMailbox EwsEnabled not False (org False overrides per-user True)
                      └─ App auth: OAuth token for Office 365 Exchange Online
                           │   app-only  → full_access_as_app  + admin consent (+ any Application Access Policy / RBAC for Applications scoping)
                           │   delegated → EWS.AccessAsUser.All + consent
                           └─ Basic auth → already dead in EXO (not an EWS-retirement issue)
```

Microsoft first-party components (e.g. Microsoft Office `d3590ed6-52b3-4102-aeff-aad2292ab01c`, Microsoft Outlook `5d661950-3475-41cd-a2c3-d671a3162bc1`) can also show up in EWS usage. If you want them to keep working through the transition, they have to be on the list too.
</details>

---
## Diagnosis & Validation Flow

1. **Get the org state (read-only).**
   `Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy | Format-List EwsEnabled, EwsAllowedAppIDs`
   - Good: `EwsEnabled : True` + a list of GUIDs that includes the failing app.
   - Bad: `False`, or `True` with an empty list, or the app's GUID absent.

2. **Confirm the failing app's App ID.** Ask the vendor for the Entra **Application (client) ID** their EWS connector uses, or pull it from the admin center: **Reports → Usage → Exchange → EWS usage** tab → *Usage details* (Application ID, SOAP Action, Call Volume, Last Activity date UTC). Filter 90 days and **Export**.
   - Data is aggregated weekly and can lag up to **10 days** — recent activity may be missing.

3. **Resolve GUID → app.** `Get-MgServicePrincipal -Filter "appId eq '<GUID>'"`.
   - No result: likely a Microsoft back-end service or a multi-tenant app never consented here. Check the Microsoft first-party app list before chasing it.

4. **Check the older UA gate.** `Get-OrganizationConfig | fl EwsApplicationAccessPolicy,EwsAllowList,EwsBlockList`
   - `EwsApplicationAccessPolicy` blank or `EnforceBlockList` with empty `EwsBlockList` = not blocking.
   - `EnforceAllowList` = the app's **user-agent string** must also match an `EwsAllowList` pattern.

5. **Check the mailbox.** `Get-CASMailbox <UPN> | fl EwsEnabled` — `False` blocks that mailbox even when the org is enabled.

6. **Correlate timing.** Was the list changed in the last 24 h? Changes take up to 24 h. Was the list auto-populated by Microsoft in September 2026? (Microsoft pre-populated lists only for tenants whose admins had **not** modified `EwsAllowedAppIDs`. Any admin edit, even a partial one, opts the tenant out of that help.)

---
## Common Fix Paths

<details><summary>Fix 1 — EWS blocked tenant-wide (EwsEnabled False, or True with empty list)</summary>

Only do this for apps with a signed-off business need and a Graph migration plan — this is a bridge to **1 April 2027**, not a fix.

```powershell
# Build the COMPLETE list — setting the property overwrites it entirely
$appIds = @(
    '<VendorApp-AppId-1>',
    '<VendorApp-AppId-2>'
)
Set-OrganizationConfig -EwsEnabled $true -EwsAllowedAppIDs ($appIds -join ',')

# Verify what actually landed
Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy | Format-List EwsEnabled, EwsAllowedAppIDs
```
Wait up to 24 h before declaring success or failure.

**Rollback:** `Set-OrganizationConfig -EwsEnabled $false` blocks all EWS again. (Microsoft's published guidance also describes setting `EwsEnabled` back to unset/`$null` as an emergency re-enable until the final deprecation. Treat that as a last resort, confirm current behaviour against the Exchange Team blog first, and never leave a tenant on it.)
</details>

<details><summary>Fix 2 — Add one app without wiping the rest (read → merge → write)</summary>

There is no incremental add. Writing a new value replaces the whole list.

```powershell
$newAppId = '<AppId-GUID>'
$current  = (Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy).EwsAllowedAppIDs
# Property may surface as a comma-separated string or a collection — normalise both
$existing = @($current) | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$merged   = @($existing + $newAppId) | Sort-Object -Unique

"Before: $($existing.Count)  After: $($merged.Count)"
$existing | Out-File ".\EwsAllowedAppIDs-backup-$(Get-Date -f yyyyMMdd-HHmm).txt"   # rollback copy

Set-OrganizationConfig -EwsAllowedAppIDs ($merged -join ',')
(Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy).EwsAllowedAppIDs
```
**Rollback:** re-apply the backup file's contents with the same `Set-OrganizationConfig -EwsAllowedAppIDs` call.
To **remove** one app, filter it out of `$existing` and write the result back. Setting `$null` removes the App ID restriction altogether, which after enforcement does **not** mean "allow everything". Don't use it as a shortcut.
</details>

<details><summary>Fix 3 — App passes the App ID list but fails the older user-agent policy</summary>

The two lists are independent. `EwsAllowList` is **user-agent** based (and also governs REST). `EwsAllowedAppIDs` is **App ID** based. From enforcement, the App ID check takes precedence **and** an app has to pass both.

```powershell
# See what's configured
Get-OrganizationConfig | Format-List EwsApplicationAccessPolicy, EwsAllowList, EwsBlockList

# Option A — add the app's UA pattern to the allow list (read-merge-write; get the UA string from the vendor)
$ua = @((Get-OrganizationConfig).EwsAllowList) + '<VendorUA>*' | Where-Object { $_ } | Sort-Object -Unique
Set-OrganizationConfig -EwsAllowList $ua

# Option B — if the UA policy no longer serves a purpose now that App IDs are enforced,
# revert to block-list mode with no entries (allows all UAs; App ID list still gates EWS)
Set-OrganizationConfig -EwsApplicationAccessPolicy EnforceBlockList -EwsBlockList $null
```
**Rollback:** record the original `EwsApplicationAccessPolicy`/`EwsAllowList`/`EwsBlockList` values first and re-apply them.
</details>

<details><summary>Fix 4 — Mailbox-level block</summary>

```powershell
Get-CASMailbox -Identity <UPN> | Format-List EwsEnabled
Set-CASMailbox -Identity <UPN> -EwsEnabled $true
```
The per-mailbox `True` does nothing while the org is `False`. Org-level disable overrides user-level overrides.
**Rollback:** `Set-CASMailbox -Identity <UPN> -EwsEnabled $false`.
</details>

<details><summary>Fix 5 — Legacy Outlook for Mac / other EWS-only desktop clients</summary>

Legacy Outlook for Mac talks to Exchange Online over EWS and has no Graph mode. Move the user to **new Outlook for Mac** (`EnableNewOutlook` = 3 in `com.microsoft.Outlook`). Full procedure: `macOS/Troubleshooting/OutlookMac-B.md`.
Apple's built-in Mail/Calendar on macOS: Apple's deployment docs describe Calendar using EWS for Exchange accounts, and community reports show an "Apple Internet Accounts" App ID in EWS usage reports. Treat any Apple native-app EWS dependency as "confirm with current Apple documentation". Outlook is the supported route.
</details>

<details><summary>Fix 6 — On/after 1 April 2027, or the app has no future on EWS</summary>

There's no configuration fix. Escalate to the vendor or app owner for their Microsoft Graph version. Known Graph gaps to raise with vendors: archive mailboxes, public folders and Microsoft 365 Group mailboxes (per vendor documentation; check Microsoft's current EWS-to-Graph gap list). Public-folder-dependent tooling has **no** Graph equivalent. See `PublicFolders-A.md`.
</details>

---
## Escalation Evidence

```
EWS RETIREMENT — ESCALATION
Tenant / primary domain       : <tenant.onmicrosoft.com>
Date/time of first failure    : <UTC>
Affected app (name / vendor)  : <name>            App (client) ID: <GUID>
Auth model                    : [ ] app-only full_access_as_app  [ ] delegated EWS.AccessAsUser.All
EwsEnabled (org)              : <True/False/blank>
EwsAllowedAppIDs (org)        : <paste — from -RetrieveEwsOperationAccessPolicy>
App ID present on list?       : <Y/N>   Last list change (UTC): <time>  (>24 h ago? Y/N)
EwsApplicationAccessPolicy    : <EnforceAllowList/EnforceBlockList/blank>
EwsAllowList / EwsBlockList   : <values>
CASMailbox EwsEnabled (target): <True/False/blank>
EWS usage report (90d) export : attached  [ ] yes
Vendor Graph-migration ETA    : <date or "none committed">
Error text returned to app    : <paste exact SOAP fault / HTTP status>
Business owner sign-off for continued EWS use until 1 Apr 2027: <name>
```

---
## 🎓 Learning Pointers
- **`True` + empty list flips meaning in October 2026.** Before enforcement it allowed everything. After, it blocks everything. If someone "just set EwsEnabled to True" over the summer, check the list now. Microsoft's tables are in the [Introducing EWSAllowedAppIDs](https://techcommunity.microsoft.com/blog/exchange/introducing-ewsallowedappids-preparing-for-the-final-phase-of-ews-retirement/4529471) post.
- **Every write replaces the list.** There's no add or remove, only read-merge-write. [Set-OrganizationConfig](https://learn.microsoft.com/powershell/module/exchangepowershell/set-organizationconfig) (Example 7) documents the syntax and the mandatory `-RetrieveEwsOperationAccessPolicy` read switch.
- **The usage report is your inventory, with blind spots.** It keeps 90 days at most, lags up to 10 days and is aggregated weekly, so quarterly or annual jobs can be missing. See the [EWS usage report](https://learn.microsoft.com/microsoft-365/admin/activity-reports/ews-usage).
- **Two allow lists, two different keys.** The old `EwsAllowList` matches user-agent strings. The new one matches Entra App IDs, and both must pass. Plenty of "we added the App ID and it still fails" tickets are really this.
- **April 2027 has no escape hatch.** Every App ID you allow today needs a named owner and a Graph migration date. Background: [Exchange Online EWS, Your Time is Almost Up](https://techcommunity.microsoft.com/blog/exchange/exchange-online-ews-your-time-is-almost-up/4492361) and MC1227454.
- Deep dive, including the Graph-side permission audit for `full_access_as_app`/`EWS.AccessAsUser.All`: `EWSRetirement-A.md` + `Scripts/Get-EWSRetirementReadiness.ps1`.
