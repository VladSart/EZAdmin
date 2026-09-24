# Exchange Online EWS Retirement (EWSEnabled + EWSAllowedAppIDs) — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** EWS (SOAP) against **Exchange Online**. This covers the October 2026 phased disablement, the `EWSEnabled` + `EWSAllowedAppIDs` control model, how it layers on the older user-agent `EwsApplicationAccessPolicy`, per-mailbox `CASMailbox.EwsEnabled`, discovering EWS consumers (usage report + Entra permission grants), and planning the 1 April 2027 shutdown.
- **Out of scope:** EWS on Exchange Server 2016/2019/SE (no changes announced). Also out of scope: writing Graph migration code for developers (see the OfficeDev `ews-migration-analyzer` repo) and general Exchange hybrid topology (`Hybrid-Coexistence-A.md`).
- **Assumes:** ExchangeOnlineManagement v3 with **Organization Management** (write) or **View-Only Organization Management / Global Reader** (read), plus Microsoft Graph PowerShell with `Application.Read.All` + `DelegatedPermissionGrant.Read.All` for the permission audit.
- **Source currency:** Built 2026-09-24 from MC1227454 (5 Feb 2026), the Exchange Team posts *Exchange Online EWS, Your Time is Almost Up* (updated Aug–Sep 2026) and *Introducing EWSAllowedAppIDs* (19 Jun 2026, updated Aug–Sep 2026), the Learn `Set-OrganizationConfig` reference (Example 7), and the Learn *EWS usage report* page (updated 2026-08-07). Some Exchange Team blog wording is quoted via secondary sources (vendor KBs, ABT) because the blog renders client-side. Re-verify dates against the live blog after 1 Oct 2026.

---
## How It Works

<details><summary>Full architecture</summary>

### Timeline
| Date | Event |
|---|---|
| Sept 2023 | Retirement first announced for 1 Oct 2026 |
| Jan 2024 | Midnight Blizzard incident (involved EWS). Per Microsoft Learn, this raised the urgency and widened the scope to include Microsoft's own apps |
| 2025 | EWS usage report added to the M365 admin center. Dedicated Exchange hybrid app introduced so hybrid free/busy can move off shared EWS identity |
| 5 Feb 2026 | MC1227454: phased model, AppID allow list announced |
| 19 Jun 2026 | `EWSAllowedAppIDs` introduced (rollout of *setting* the list reached tenants progressively; all tenants can read it) |
| **31 Aug 2026** | Recommended deadline for admins to set `EwsEnabled=True` + their own list to stay out of the automatic October block |
| Sept 2026 | Microsoft **pre-populates** the allow list from observed usage for tenants whose admins had **not** modified `EwsAllowedAppIDs` |
| **1 Oct 2026** | Phased disablement begins. Unset tenants get `EwsEnabled=False` as the rollout reaches them. The `True`+empty list combination becomes block-all |
| **1 Apr 2027** | Permanent shutdown. Admin control removed, "no exceptions" |

"Scream tests" (temporary blocks to surface dependencies) were announced as possible before October 2026. If a tenant saw unexplained, self-healing EWS outages over the summer, that's the likely cause.

### The control model: three layers, evaluated together
```
                ┌───────────────────────────────────────────────┐
 EWS request ─► │ 1. Org: EwsEnabled  (True / False / unset)    │── False ─► 403-class denial
                │ 2. Org: EwsAllowedAppIDs (Entra App IDs)      │── not listed / empty ─► denial
                │ 3. Org: EwsApplicationAccessPolicy + UA lists │── UA fails ─► denial
                │ 4. Mailbox: CASMailbox.EwsEnabled             │── False ─► denial for that mailbox
                └───────────────────────────────────────────────┘
                                   │ all pass
                                   ▼
                    OAuth token checks (app-only / delegated permissions,
                    Application Access Policies / RBAC for Applications scoping)
```

**Behaviour matrix (org layer, from Microsoft's published tables):**

| EwsEnabled | EwsAllowedAppIDs | Before Oct 2026 | From Oct 2026 enforcement |
|---|---|---|---|
| unset (`$null`, default) | ignored | All EWS allowed | Allowed until the rollout reaches the tenant and sets it to `False` |
| `True` | empty / `$null` | All EWS allowed | **All EWS blocked** |
| `True` | populated | Only listed apps | Only listed apps |
| `False` | any | All blocked | All blocked |

The reversal in row 2 is why this topic generates tickets. The "safe" August advice (set `True`) turns into a tenant-wide outage if nobody populates the list and Microsoft's auto-population doesn't apply (because an admin had already touched the property).

### Why App ID and not user agent
User agents are self-declared and trivially spoofed. The Entra App ID comes from the OAuth token, so it's bound to a registered identity with consent and ownership. The older `EwsAllowList`/`EwsBlockList` (user-agent patterns, `EnforceAllowList`/`EnforceBlockList`) still exists and **also governs REST**. Microsoft states that the AppID list takes precedence and an app must pass **both** checks.

### Write semantics
- `Set-OrganizationConfig -EwsAllowedAppIDs "<id1>,<id2>"` writes the **full** value. There's no append.
- `$null` removes the App ID restriction. Under enforcement that isn't "allow all" when `EwsEnabled=True` (row 2 above).
- Reading the list requires `Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy` (it's excluded from the default output for performance).
- Propagation: up to **24 h** for server caches to refresh. Test the day after a change.
- Auto-population ownership: once an admin modifies `EwsAllowedAppIDs`, Microsoft won't touch it again. If the list was auto-generated, admins keep full control to edit it afterwards.

### Where EWS consumers come from (discovery)
1. **M365 admin center → Reports → Usage → Exchange → EWS usage.** Per App ID × SOAP action: call volume and last activity (UTC). Windows of 7/30/90 days, aggregated weekly, up to 10 days lag. It's the only view of what *actually called* EWS.
2. **Entra permission grants on the `Office 365 Exchange Online` resource (appId `00000002-0000-0ff1-ce00-000000000000`):**
   - Application permission **`full_access_as_app`**: app-only EWS access to every mailbox unless scoped.
   - Delegated permission **`EWS.AccessAsUser.All`**: EWS as the signed-in user.
   These show which apps *could* call EWS. The difference between "granted" and "used in 90 days" is your dormant-access clean-up list.
3. **Vendor attestations** for SaaS connectors (backup, archiving, CRM sync, signature, room/visitor systems, e-discovery, migration tools).

### Collateral consumers to expect
- **Microsoft first-party:** Office, Outlook, Teams middle tier, and Power Query for Excel have all appeared in tenants' reports. Microsoft is removing these dependencies, but anything still calling EWS during the bridge period has to be allowed.
- **Legacy Outlook for Mac:** EWS-only. It stops working against EXO from October 2026 (`macOS/Troubleshooting/OutlookMac-A.md`).
- **Cross-tenant free/busy via Organization Relationships / Availability Address Space / Sharing Policy:** EWS-based. Migrate to XTAP (`CrossTenantCalendarSharing-A.md`).
- **Hybrid:** on-prem mailboxes can keep using EWS against on-prem Exchange. For EXO calls, Microsoft states only **Exchange SE** will support Graph, so hybrid customers need SE to host on-prem mailboxes going forward.
- **Backup/archiving vendors:** several vendors document Graph gaps for **archive mailboxes, public folders and M365 Group mailboxes** that keep them on EWS until April 2027. Public folders have no Graph API at all.
</details>

---
## Dependency Stack
```
[Layer 7] Business process (backup job, CRM sync, signature tool, legacy Mac client)
[Layer 6] Vendor/app code — EWS SOAP endpoint https://outlook.office365.com/EWS/Exchange.asmx
[Layer 5] OAuth token for Office 365 Exchange Online
            ├─ app-only: full_access_as_app + admin consent (+ Application Access Policy / RBAC for Apps scope)
            └─ delegated: EWS.AccessAsUser.All + consent
[Layer 4] Mailbox: CASMailbox.EwsEnabled ≠ False  (+ per-mailbox UA lists)
[Layer 3] Org: EwsApplicationAccessPolicy / EwsAllowList / EwsBlockList (user agent; also REST)
[Layer 2] Org: EwsAllowedAppIDs contains App ID  (24 h cache)
[Layer 1] Org: EwsEnabled = True
[Layer 0] Calendar: before 1 April 2027
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Every EWS app broke on/after 1 Oct 2026 at once | Tenant was unset and the rollout set `EwsEnabled=False`, **or** `True` with an empty list | Validation 1 |
| One app broke, others fine | App ID not on the list (not caught by auto-population, or removed by an admin) | Validation 2–3 |
| App ID added yesterday, still failing | < 24 h propagation, **or** failing the UA gate | Validation 4 |
| Only certain mailboxes fail for the app | `CASMailbox.EwsEnabled=False`, or Application Access Policy / RBAC for Applications scope excludes them | Validation 5 |
| Admin edited the list in July "to add one app" and now everything else is blocked | Partial edit opted the tenant out of September auto-population | Compare list vs 90-day usage export |
| Report shows an App ID nobody recognises | Microsoft back-end service, or an unowned third-party integration | Validation 3 + first-party app list |
| Legacy Outlook for Mac can't connect | EWS-only client | `OutlookMac-A.md` |
| Cross-tenant free/busy with a partner stopped | Org Relationship/Availability Address Space is EWS-based | `CrossTenantCalendarSharing-A.md` |
| Backup "archive mailbox" or "public folder" jobs fail but primary mailbox backups succeed | Vendor moved primary mail to Graph, archive/PF still on EWS | Vendor App ID on list? Plan exit before Apr 2027 |
| Everything fails and no setting helps | Date ≥ 1 Apr 2027 | No fix. Graph only |

---
## Validation Steps

1. **Org gate.**
   ```powershell
   Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy | Format-List EwsEnabled, EwsAllowedAppIDs
   ```
   Good: `EwsEnabled : True` plus the approved GUIDs. Bad: `False`, an empty list with `True`, or unset after 1 Oct 2026.

2. **Inventory vs list.** Export the EWS usage report (90 days) and compare the App IDs in it with the list. `Get-EWSRetirementReadiness.ps1 -UsageReportCsv <file>` does the diff.
   Good: every business-approved App ID in the usage export is on the list. Bad: active App IDs missing from the list (they'll break), or listed App IDs with no usage and no owner (unneeded exposure).

3. **Resolve identities.**
   ```powershell
   Connect-MgGraph -Scopes Application.Read.All
   Get-MgServicePrincipal -Filter "appId eq '<GUID>'" | Select DisplayName, AppId, AppOwnerOrganizationId, PublisherName
   ```
   `AppOwnerOrganizationId` = `f8cdef31-a31e-4b4a-93e4-5f571e91255a` means a Microsoft-owned app. Your own tenant ID means a home-grown app.

4. **UA gate.**
   ```powershell
   Get-OrganizationConfig | Format-List EwsApplicationAccessPolicy, EwsAllowList, EwsBlockList
   ```
   Good: blank, or `EnforceBlockList` with the app not matched. Bad: `EnforceAllowList` without the app's UA pattern.

5. **Mailbox gate.**
   ```powershell
   Get-EXOCASMailbox -ResultSize Unlimited -Properties EwsEnabled |
       Where-Object { $_.EwsEnabled -eq $false } | Select PrimarySmtpAddress, EwsEnabled
   ```
   Good: only intentional blocks. Bad: the service account or target mailboxes of an approved app appear here.

6. **Permission surface (who *can* call EWS).**
   ```powershell
   $exo = Get-MgServicePrincipal -Filter "appId eq '00000002-0000-0ff1-ce00-000000000000'"
   $role = $exo.AppRoles | Where-Object Value -eq 'full_access_as_app'
   Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $exo.Id -All |
       Where-Object AppRoleId -eq $role.Id | Select PrincipalDisplayName, PrincipalId, CreatedDateTime
   Get-MgOauth2PermissionGrant -Filter "resourceId eq '$($exo.Id)'" -All |
       Where-Object { $_.Scope -match 'EWS\.AccessAsUser\.All' } | Select ClientId, ConsentType, PrincipalId
   ```
   Every holder should be either on the allow list with an owner, or scheduled for removal.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-enforcement (to 30 Sep 2026): inventory.** Pull the 90-day usage export early in the month, because the window only shrinks. Run the permission-surface audit. Get written Graph-readiness answers from vendors, pinned to the version you actually run.

**Phase 2 — September reconciliation.** If the tenant wasn't admin-configured, read the auto-populated list and compare it with the usage export and the permission audit. Each entry ends as **keep** (owner + migration date recorded), **remove**, or **migrate now**. Microsoft warns that the auto-list may include apps you weren't aware of. Treat those as a governance finding, not something to accept by default.

**Phase 3 — Enforcement (1 Oct 2026 – 31 Mar 2027): break/fix.** Work down the dependency stack top to bottom (org → list → UA → mailbox → token). Remember the 24 h cache before re-testing.

**Phase 4 — Final shutdown (1 Apr 2027).** Nothing to troubleshoot at the EWS layer. Anything still failing is a Graph-migration escalation to the vendor or app owner.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Establish a deliberate allow list (first-time configuration)</summary>

```powershell
Connect-ExchangeOnline -ShowBanner:$false
$cfg = Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy
"EwsEnabled=$($cfg.EwsEnabled)"; "Current list: $($cfg.EwsAllowedAppIDs)"
# Snapshot for rollback
$cfg | Select-Object EwsEnabled, EwsAllowedAppIDs, EwsApplicationAccessPolicy, EwsAllowList, EwsBlockList |
    Export-Clixml ".\EWS-OrgConfig-backup-$(Get-Date -f yyyyMMdd-HHmm).xml"

$approved = @('<AppId-1>','<AppId-2>','<AppId-3>')      # business-approved only
Set-OrganizationConfig -EwsEnabled $true -EwsAllowedAppIDs ($approved -join ',')
Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy | Format-List EwsEnabled, EwsAllowedAppIDs
```
**Rollback:** `$b = Import-Clixml <backup>.xml; Set-OrganizationConfig -EwsAllowedAppIDs $b.EwsAllowedAppIDs` (plus `-EwsEnabled $b.EwsEnabled` if the value was boolean). If the backup shows `EwsEnabled` was unset, understand that you can't return to "unset" and still be protected by Microsoft's auto-population, because you've modified the property.
</details>

<details><summary>Playbook 2 — Add/remove an App ID safely (read-merge-write + verify)</summary>

```powershell
function Update-EwsAllowedAppIds {
    param([string[]]$Add = @(), [string[]]$Remove = @())
    $cur = (Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy).EwsAllowedAppIDs
    $list = @($cur) | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $new  = @($list + $Add | Where-Object { $_ -and ($Remove -notcontains $_) }) | Sort-Object -Unique
    if ($new.Count -eq 0) { throw "Refusing to write an empty list — that is block-all under enforcement." }
    $list | Out-File ".\EwsAllowedAppIDs-before-$(Get-Date -f yyyyMMdd-HHmmss).txt"
    Set-OrganizationConfig -EwsAllowedAppIDs ($new -join ',')
    (Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy).EwsAllowedAppIDs
}
Update-EwsAllowedAppIds -Add '<AppId-GUID>'
```
The empty-list guard exists because `True` + empty = block-all after enforcement.
</details>

<details><summary>Playbook 3 — Retire the older UA policy once App IDs are authoritative</summary>

If `EnforceAllowList` was set years ago to allow only Outlook and a few UAs, every newly allowed App ID must also match a UA pattern, which doubles the change work. Once the App ID list is in place:
```powershell
Get-OrganizationConfig | Select EwsApplicationAccessPolicy, EwsAllowList, EwsBlockList | Export-Clixml .\EWS-UA-backup.xml
Set-OrganizationConfig -EwsApplicationAccessPolicy EnforceBlockList -EwsBlockList $null
```
Note that this also relaxes the UA gate for **REST**. Check the policy isn't still being relied on for REST restriction first.
**Rollback:** re-apply the values from the backup file.
</details>

<details><summary>Playbook 4 — Reduce blast radius of apps you must keep until April 2027</summary>

An allow-listed app-only app with `full_access_as_app` can still reach **every** mailbox. Scope it:
- **RBAC for Applications** in Exchange Online (the successor to Application Access Policies): `New-ManagementScope` + `New-ServicePrincipal` + `New-ManagementRoleAssignment -App <SP> -Role "Application EWS.AccessAsApp" -CustomResourceScope <scope>`. Confirm the exact role name with `Get-ManagementRole | ? Name -like 'Application*EWS*'` before relying on it.
- Or legacy **Application Access Policy**: `New-ApplicationAccessPolicy -AppId <GUID> -PolicyScopeGroupId <mail-enabled-security-group> -AccessRight RestrictAccess`. Test with `Test-ApplicationAccessPolicy -Identity <mailbox> -AppId <GUID>`.
Scoping does **not** replace the allow list. The App ID still has to be listed.
</details>

<details><summary>Playbook 5 — Remove dormant EWS permissions (clean-up)</summary>

For service principals holding `full_access_as_app` or `EWS.AccessAsUser.All` with **no** usage in the 90-day export and no owner:
```powershell
# App-only role assignment removal (destructive — export first)
$exo  = Get-MgServicePrincipal -Filter "appId eq '00000002-0000-0ff1-ce00-000000000000'"
$role = $exo.AppRoles | Where-Object Value -eq 'full_access_as_app'
$asg  = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $exo.Id -All |
        Where-Object { $_.AppRoleId -eq $role.Id -and $_.PrincipalId -eq '<client-SP-objectId>' }
$asg | ConvertTo-Json | Out-File .\removed-full_access_as_app.json
Remove-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $exo.Id -AppRoleAssignmentId $asg.Id
```
**Rollback:** `New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $exo.Id -PrincipalId <client-SP-objectId> -ResourceId $exo.Id -AppRoleId $role.Id`.
</details>

---
## Evidence Pack

```powershell
# Collect-EWSRetirementEvidence.ps1 — read-only. Requires EXO connected; Graph optional.
$ts  = Get-Date -Format yyyyMMdd-HHmm
$out = Join-Path $PWD "EWS-Evidence-$ts"; New-Item -ItemType Directory -Path $out -Force | Out-Null

Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy |
    Select-Object Identity, EwsEnabled, EwsAllowedAppIDs, EwsApplicationAccessPolicy, EwsAllowList, EwsBlockList,
                  EwsAllowOutlook, EwsAllowMacOutlook, EwsAllowEntourage |
    Export-Clixml "$out\OrgConfig-EWS.xml"

Get-EXOCASMailbox -ResultSize Unlimited -Properties EwsEnabled, EwsApplicationAccessPolicy |
    Where-Object { $_.EwsEnabled -eq $false -or $_.EwsApplicationAccessPolicy } |
    Select-Object PrimarySmtpAddress, EwsEnabled, EwsApplicationAccessPolicy |
    Export-Csv "$out\CASMailbox-EWS-overrides.csv" -NoTypeInformation

Get-ApplicationAccessPolicy -ErrorAction SilentlyContinue | Export-Csv "$out\ApplicationAccessPolicies.csv" -NoTypeInformation

if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) {
    if (Get-MgContext) {
        $exo  = Get-MgServicePrincipal -Filter "appId eq '00000002-0000-0ff1-ce00-000000000000'"
        $role = $exo.AppRoles | Where-Object Value -eq 'full_access_as_app'
        Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $exo.Id -All |
            Where-Object AppRoleId -eq $role.Id |
            Select-Object PrincipalDisplayName, PrincipalId, CreatedDateTime |
            Export-Csv "$out\Grants-full_access_as_app.csv" -NoTypeInformation
        Get-MgOauth2PermissionGrant -Filter "resourceId eq '$($exo.Id)'" -All |
            Where-Object { $_.Scope -match 'EWS\.AccessAsUser\.All' } |
            Select-Object ClientId, ConsentType, PrincipalId, Scope |
            Export-Csv "$out\Grants-EWS.AccessAsUser.All.csv" -NoTypeInformation
    }
}
"Add manually: M365 admin center > Reports > Usage > Exchange > EWS usage (90 days) > Export" |
    Out-File "$out\README.txt"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
"Evidence: $out.zip"
```
For the full diff (usage vs list vs grants), run `Scripts/Get-EWSRetirementReadiness.ps1`.

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Read EWS org state + list | `Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy \| fl EwsEnabled,EwsAllowedAppIDs` |
| Set enabled + full list | `Set-OrganizationConfig -EwsEnabled $true -EwsAllowedAppIDs "<id1>,<id2>"` |
| Block EWS tenant-wide | `Set-OrganizationConfig -EwsEnabled $false` |
| Remove App ID restriction | `Set-OrganizationConfig -EwsAllowedAppIDs $null` (not "allow all" under enforcement) |
| Read UA policy | `Get-OrganizationConfig \| fl EwsApplicationAccessPolicy,EwsAllowList,EwsBlockList` |
| Neutralise UA policy | `Set-OrganizationConfig -EwsApplicationAccessPolicy EnforceBlockList -EwsBlockList $null` |
| Mailbox EWS state | `Get-CASMailbox <UPN> \| fl EwsEnabled` |
| Mailbox enable/disable | `Set-CASMailbox <UPN> -EwsEnabled $true/$false` |
| All mailbox blocks | `Get-EXOCASMailbox -ResultSize Unlimited -Properties EwsEnabled \| ? EwsEnabled -eq $false` |
| Resolve App ID | `Get-MgServicePrincipal -Filter "appId eq '<GUID>'"` |
| EXO resource SP | `Get-MgServicePrincipal -Filter "appId eq '00000002-0000-0ff1-ce00-000000000000'"` |
| Who holds full_access_as_app | `Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId <exoSP.Id> -All` (filter AppRoleId) |
| Who holds EWS.AccessAsUser.All | `Get-MgOauth2PermissionGrant -Filter "resourceId eq '<exoSP.Id>'" -All` |
| Test app scoping | `Test-ApplicationAccessPolicy -Identity <mbx> -AppId <GUID>` |
| Usage report | M365 admin center → Reports → Usage → Exchange → **EWS usage** → Export |

---
## 🎓 Learning Pointers
- **Read the behaviour matrix before touching anything.** The `True` + empty list reversal is the whole trap. Source: [Introducing EWSAllowedAppIDs](https://techcommunity.microsoft.com/blog/exchange/introducing-ewsallowedappids-preparing-for-the-final-phase-of-ews-retirement/4529471), with testing guidance in [Notes from the field: testing EWSAllowedAppIDs safely](https://techcommunity.microsoft.com/blog/exchange/notes-from-the-field-testing-ewsallowedappids-safely/4548568).
- **"Granted" and "used" are different lists.** The usage report shows what called EWS. The Entra grants show what *could*. The dormant entries in the gap are real, unowned mailbox-access paths. See [EWS usage report](https://learn.microsoft.com/microsoft-365/admin/activity-reports/ews-usage) and Tony Redmond's [Find Active EWS-Based Apps](https://office365itpros.com/2025/04/29/exchange-web-services-apps/).
- **An allow-listed app is still over-privileged.** `full_access_as_app` covers every mailbox. Scope it with RBAC for Applications for the months it survives.
- **Hybrid shops need Exchange SE.** Microsoft states only SE will support Graph for calls to Exchange Online. If you're still on 2016/2019, that upgrade has its own lead time. See [Deprecation of EWS in Exchange Online](https://learn.microsoft.com/exchange/clients-and-mobile-in-exchange-online/deprecation-of-ews-exchange-online).
- **Developers:** the OfficeDev [ews-migration-analyzer](https://github.com/OfficeDev/ews-migration-analyzer) scans code bases for EWS calls and maps them to Graph equivalents.
- Related: `macOS/Troubleshooting/OutlookMac-A.md` (EWS-only client), `CrossTenantCalendarSharing-A.md` (EWS-based federation → XTAP), `PublicFolders-A.md` (no Graph API).
