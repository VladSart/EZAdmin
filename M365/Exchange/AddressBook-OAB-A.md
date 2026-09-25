# Exchange Online GAL & Offline Address Book — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.
> Hotfix: `AddressBook-OAB-B.md` · Script: `Scripts/Get-AddressBookDiagnostics.ps1`

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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions
- **In scope:** Exchange Online (commercial) address lists, the Global Address List (GAL), Offline Address Book (OAB), Address Book Policies (ABPs), hide-from-GAL, Outlook autocomplete (nickname cache) interaction with `LegacyExchangeDN`/X500.
- **Out of scope:** on-prem Exchange OAB generation mailboxes/virtual directories (only referenced in hybrid context), Information Barriers internals (`Security/Purview/InformationBarriers-A.md`), recipient provisioning failures (`EntraID/` sync runbooks).
- Admin has ExchangeOnlineManagement v3+ and Exchange Administrator (plus **Address Lists** role for ABP/address list edits).

---
## How It Works

<details><summary>Full architecture</summary>

### Three different "address books"
| Surface | Data source | Freshness |
|---|---|---|
| Live GAL (OWA, new Outlook for Windows, Outlook for Mac, Outlook mobile, classic Outlook in Online Mode, classic Outlook "Global Address List" entry) | Directory lookup against EXO in real time | Minutes after the object changes (plus Entra sync for dir-synced objects) |
| OAB (classic Outlook in **Cached Exchange Mode**, default "Offline Global Address List") | Files generated service-side, downloaded to `%LOCALAPPDATA%\Microsoft\Outlook\Offline Address Books\<guid>\` | EXO generates ~every 8 h; Outlook downloads ~every 24 h → 24–48 h worst case |
| Autocomplete / nickname cache (all Outlooks) | Suggested-recipient stream stored in the mailbox, keyed by the recipient's `LegacyExchangeDN` at the time it was cached | Never refreshes itself — stale until the entry is removed or re-picked |

Most "user missing from the GAL" tickets are the viewer looking at surface 2 while the admin checks surface 1.

### Address list membership
Every recipient carries `AddressListMembership`, the list of address lists whose `RecipientFilter` it matched when it was last written. Default lists: *Default Global Address List*, *All Users*, *All Groups*, *All Contacts*, *All Rooms*, *All Distribution Lists*, *Public Folders*. Membership is (re)computed when the object is written — creating a new custom address list does **not** retroactively stamp existing objects; they must be "touched".

`HiddenFromAddressListsEnabled = $true` excludes the recipient from every address list regardless of filters.

### OAB generation in EXO
- One default OAB ("Default Offline Address Book") covering the Default GAL; additional OABs exist only if you create them for ABPs.
- Generation is a service-side assistant — there is no admin trigger (`Update-OfflineAddressBook` is on-prem only). `LastTouchedTime` on `Get-OfflineAddressBook` indicates the last generation touch.
- Outlook discovers the download location through Autodiscover (`OABUrl`), downloads a full OAB the first time and differentials (`.lzx` diff files) thereafter. If too many diffs are missed, a full download is forced.

### Hide-from-GAL source of authority
| Mailbox state | Where to set hidden flag |
|---|---|
| Cloud-only | `Set-Mailbox -HiddenFromAddressListsEnabled` |
| Dir-synced, on-prem Exchange schema present | On-prem AD `msExchHideFromAddressLists` (EMS or ADUC Attribute Editor) → sync |
| Dir-synced, `IsExchangeCloudManaged = True` | EXO (SOA transferred per mailbox) — see `CloudManagedMailboxes-A.md` |
| Dir-synced, no Exchange schema ever | Not settable without schema extension or cloud-managed transfer |

### Address Book Policies
An ABP binds four things: one GAL, one OAB, one or more address lists, one room list. Assigned per mailbox (`Set-Mailbox -AddressBookPolicy`). The mailbox sees **only** those. Used for multi-company tenants and school segmentation. A mailbox with an ABP whose GAL filter excludes itself behaves oddly (can't see itself) — Microsoft requires the user to be in their own GAL. Information Barriers v1 create ABP-like segmentation; IB in newer modes doesn't use ABPs, but both can make recipients "disappear".

### Autocomplete & LegacyExchangeDN
Internally, EXO routes by `LegacyExchangeDN` (an X.500 DN like `/o=ExchangeLabs/ou=Exchange Administrative Group (FYDIBOHF23SPDLT)/cn=Recipients/cn=<guid-ish>`). If a mailbox is deleted and re-created, migrated cross-tenant, or moved from on-prem without the old DN preserved, the new object gets a new DN. Cached autocomplete entries still carry the old one; sending produces an NDR whose recipient is the **IMCEAEX**-encapsulated old DN. Adding the old DN as an `X500:` proxy address makes the old DN resolve to the new object.
</details>

---
## Dependency Stack

```
[7] Viewer's client renders the recipient
[6] Client data source: live directory  |  downloaded OAB (Cached Mode)  |  autocomplete cache
[5] OAB download: Autodiscover OABUrl → HTTPS → diff/full files in %LOCALAPPDATA%
[4] OAB generation (EXO service, ~8 h) includes the address lists in scope
[3] Viewer scoping: no ABP, or ABP whose GAL filter includes the recipient
[2] Recipient stamped into address lists (AddressListMembership) and not hidden
[1] Recipient exists in EXO (provisioned, licensed or shared/resource, synced if dir-synced)
[0] Source of authority for attributes: EXO (cloud-only / cloud-managed) or on-prem AD (dir-synced)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| New starter missing in classic Outlook only | OAB not yet regenerated/downloaded | OWA search; local OAB folder timestamp |
| Leaver still visible in classic Outlook after hide | Same lag in reverse | as above |
| Missing everywhere, not hidden | `AddressListMembership` empty | `Get-Recipient ... AddressListMembership` |
| Hide fails with "object is being synchronized from on-premises" | Dir-synced SOA | `IsDirSynced`, `IsExchangeCloudManaged` |
| Some users see recipient, others don't | ABP on viewers | `Get-EXOMailbox -Properties AddressBookPolicy` |
| Shared/room mailbox not in GAL | Hidden by migration tooling, or room not in *All Rooms* | `HiddenFromAddressListsEnabled`, `RecipientTypeDetails` |
| NDR `IMCEAEX-_o=ExchangeLabs_ou=...` | Stale autocomplete after re-create/migration | Missing X500 proxy on target |
| Classic Outlook never updates GAL | OAB download disabled by policy / Autodiscover lacks OABUrl | Test E-mail AutoConfiguration; `DownloadOAB` policy value |
| Changed display name shows old name in To: line | Autocomplete stores display name snapshot | Remove suggestion, re-pick |
| Everyone's OAB massive/slow first download | Large tenant + many recipients; normal first full download | Folder size; not a fault |

---
## Validation Steps

1. **Recipient exists and isn't hidden**
   ```powershell
   Get-Recipient "<smtp>" | fl RecipientTypeDetails,HiddenFromAddressListsEnabled,IsDirSynced,WhenChangedUTC
   ```
   Good: one result, `False`. Bad: none (provisioning), `True` (hidden).

2. **Membership stamped**
   ```powershell
   (Get-Recipient "<smtp>").AddressListMembership
   ```
   Good: includes `\Default Global Address List`. Bad: empty.

3. **OAB covers the right lists**
   ```powershell
   Get-OfflineAddressBook | fl Name,IsDefault,AddressLists,LastTouchedTime
   ```
   Good: default OAB includes `\Default Global Address List`; `LastTouchedTime` within ~24 h.

4. **Viewer scoping**
   ```powershell
   Get-EXOMailbox "<viewer>" -Properties AddressBookPolicy,OfflineAddressBook | fl AddressBookPolicy,OfflineAddressBook
   ```
   Good: both empty (tenant default). Non-empty → validate that ABP's GAL filter.

5. **Client download healthy** (viewer PC)
   ```powershell
   Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook\Offline Address Books" -Recurse -File | Measure-Object Length -Sum -Maximum
   (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook\Offline Address Books" -Recurse -File | Sort LastWriteTime -Desc | Select -First 1).LastWriteTime
   Get-ItemProperty "HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode" -ErrorAction SilentlyContinue
   ```
   Good: files present, newest < 48 h, no `DownloadOAB = 0`. Bad: no folder (never downloaded / Online Mode), stale, or policy disabling download.

6. **Autocomplete/X500**
   ```powershell
   (Get-Recipient "<smtp>").EmailAddresses | ? { $_ -like "X500:*" }
   Get-Recipient "<smtp>" | select LegacyExchangeDN
   ```
   After a re-create/migration, the old DN should appear as X500.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Directory (is the object right?)** Steps 1–2. Fix at source of authority. Allow Entra Connect/Cloud Sync delta (~30 min) + EXO replication before retesting.

**Phase 2 — Scoping (is the viewer allowed to see it?)** Step 4. ABP/IB decisions are policy, not faults — confirm intent with the customer before changing.

**Phase 3 — Distribution (has the snapshot caught up?)** Steps 3 & 5. Compare "change time" vs "now": < 48 h is expected lag. > 48 h with a stale local folder → client download problem (Autodiscover, proxy blocking the OAB URL, policy, corrupted diff chain → Playbook B).

**Phase 4 — Client cache (is Outlook using an old pointer?)** Step 6. IMCEAEX NDRs, old display names, wrong person resolving → autocomplete (Playbook D).

---
## Remediation Playbooks

<details><summary>Playbook A — Bulk re-stamp after creating/changing address lists or ABP filters</summary>

```powershell
# Confirm attribute is unused first
Get-Recipient -ResultSize Unlimited -Filter "CustomAttribute15 -ne `$null" | Measure-Object
$all = Get-Mailbox -ResultSize Unlimited
foreach ($m in $all) {
    Set-Mailbox $m.Identity -CustomAttribute15 "ABtouch" -WarningAction SilentlyContinue
    Set-Mailbox $m.Identity -CustomAttribute15 $null -WarningAction SilentlyContinue
}
# Repeat with Set-MailUser / Set-MailContact / Set-DistributionGroup / Set-UnifiedGroup as needed
```
Throttling: large tenants — batch by 500 with `Start-Sleep`. Rollback: none needed (attribute returns to null). Dir-synced objects: EXO rejects writes to synced attributes — if `Set-Mailbox` errors with "being synchronized from your on-premises organization", touch `extensionAttribute15` on-prem instead and let the delta sync trigger recalculation.
</details>

<details><summary>Playbook B — Rebuild a user's OAB (corrupted diff chain / never updates)</summary>

1. Outlook closed. Rename `%LOCALAPPDATA%\Microsoft\Outlook\Offline Address Books` to `.old_<date>`.
2. Open Outlook, wait for connection, then *Send/Receive → Download Address Book* → Full Details, uncheck "changes since last".
3. Verify new folder populated and address book shows expected entries.
4. If download never starts: Ctrl+right-click Outlook tray icon → *Test E-mail AutoConfiguration* → confirm an **OAB URL** is returned; check proxy/SSL inspection isn't blocking it.
5. Rollback: restore renamed folder.
</details>

<details><summary>Playbook C — Hide/unhide dir-synced objects without on-prem Exchange tools</summary>

- If the on-prem schema has Exchange attributes: `Set-ADUser <sam> -Replace @{msExchHideFromAddressLists=$true}` then delta sync.
- If migrating away from on-prem Exchange: move SOA per mailbox (`Set-Mailbox -IsExchangeCloudManaged $true`, tenant prerequisites apply) — full procedure in `CloudManagedMailboxes-A.md`. After transfer, set the hidden flag in EXO.
- Do **not** edit via Graph/Entra — the attribute is Exchange-owned.
</details>

<details><summary>Playbook D — Re-created or migrated mailbox: kill IMCEAEX NDRs tenant-wide</summary>

1. Collect old DNs from NDRs (users forward them) or from the source tenant/on-prem (`Get-Mailbox <old> | select LegacyExchangeDN`).
2. Decode NDR form: strip `IMCEAEX-` and `@domain`; `_`→`/`, `+20`→space, `+28`→`(`, `+29`→`)`, `+2E`→`.`, `+40`→`@`.
3. Add proxy:
   ```powershell
   Set-Mailbox "<new>" -EmailAddresses @{Add="X500:<decoded DN>"}
   ```
   Dir-synced → add `X500:<DN>` to `proxyAddresses` on-prem.
4. Rollback: `@{Remove="X500:<DN>"}`. X500 proxies are harmless if wrong, but never add the same DN to two objects.
</details>

<details><summary>Playbook E — Segmenting the GAL with ABPs (multi-company tenant)</summary>

```powershell
New-AddressList "CompanyA Users" -RecipientFilter "((RecipientType -eq 'UserMailbox') -and (Company -eq 'CompanyA'))"
New-AddressList "CompanyA Rooms" -RecipientFilter "((RecipientDisplayType -eq 'ConferenceRoomMailbox') -and (Company -eq 'CompanyA'))"
New-GlobalAddressList "CompanyA GAL" -RecipientFilter "(Company -eq 'CompanyA')"
New-OfflineAddressBook "CompanyA OAB" -AddressLists "\CompanyA GAL"
New-AddressBookPolicy "CompanyA ABP" -AddressLists "\CompanyA Users" -RoomList "\CompanyA Rooms" -GlobalAddressList "\CompanyA GAL" -OfflineAddressBook "\CompanyA OAB"
Get-Mailbox -Filter "Company -eq 'CompanyA'" | Set-Mailbox -AddressBookPolicy "CompanyA ABP"
```
Then run Playbook A so existing objects are stamped. Requires Address Lists role. Rollback: `Set-Mailbox -AddressBookPolicy $null`, then remove objects in reverse order. Check Information Barriers isn't also in use — they conflict.
</details>

---
## Evidence Pack

```powershell
# Run connected to EXO. Produces a folder with text/CSV evidence.
param([string[]]$Recipient = @("<smtp1>"), [string]$Viewer = "<viewer smtp>", [string]$Out = "$env:TEMP\ABEvidence_$(Get-Date -f yyyyMMddHHmm)")
New-Item $Out -ItemType Directory -Force | Out-Null
Get-OfflineAddressBook | fl * | Out-File "$Out\OAB.txt"
Get-GlobalAddressList | fl Name,RecipientFilter | Out-File "$Out\GAL.txt"
Get-AddressList | fl Name,RecipientFilter,Path | Out-File "$Out\AddressLists.txt"
Get-AddressBookPolicy -ErrorAction SilentlyContinue | fl * | Out-File "$Out\ABP.txt"
foreach ($r in $Recipient) {
  Get-Recipient $r | fl DisplayName,PrimarySmtpAddress,RecipientTypeDetails,HiddenFromAddressListsEnabled,IsDirSynced,LegacyExchangeDN,EmailAddresses,AddressListMembership,WhenChangedUTC |
    Out-File "$Out\Recipient_$($r -replace '[@\.]','_').txt"
}
Get-EXOMailbox $Viewer -Properties AddressBookPolicy,OfflineAddressBook | fl * | Out-File "$Out\Viewer.txt"
Compress-Archive "$Out\*" "$Out.zip" -Force
"Evidence: $Out.zip"
```
On the viewer's PC add: `Scripts/Get-AddressBookDiagnostics.ps1 -ClientOnly` output and a screenshot of *Test E-mail AutoConfiguration* (Results tab).

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Recipient GAL state | `Get-Recipient <x> \| fl HiddenFromAddressListsEnabled,AddressListMembership` |
| All hidden recipients | `Get-Recipient -ResultSize Unlimited -Filter "HiddenFromAddressListsEnabled -eq `$true"` |
| Hide cloud mailbox | `Set-Mailbox <x> -HiddenFromAddressListsEnabled $true` |
| Hide dir-synced (on-prem) | `Set-ADUser <sam> -Replace @{msExchHideFromAddressLists=$true}` |
| OABs & last touch | `Get-OfflineAddressBook \| ft Name,IsDefault,LastTouchedTime` |
| GAL filters | `Get-GlobalAddressList \| fl Name,RecipientFilter` |
| Address lists | `Get-AddressList \| ft Name,Path` |
| ABPs | `Get-AddressBookPolicy \| fl` |
| Viewer ABP | `Get-EXOMailbox <x> -Properties AddressBookPolicy` |
| Mailboxes by ABP | `Get-Mailbox -ResultSize Unlimited \| ? AddressBookPolicy \| group AddressBookPolicy` |
| Add X500 | `Set-Mailbox <x> -EmailAddresses @{Add="X500:<dn>"}` |
| LegacyExchangeDN | `Get-Recipient <x> \| select LegacyExchangeDN` |
| Local OAB freshness | `gci "$env:LOCALAPPDATA\Microsoft\Outlook\Offline Address Books" -r -File \| sort LastWriteTime -desc \| select -f 3` |
| Trigger delta sync | `Start-ADSyncSyncCycle -PolicyType Delta` (Connect server) |

---
## 🎓 Learning Pointers
- The OAB is a periodic snapshot for Cached Mode; understanding the three data sources (live GAL / OAB / autocomplete) turns most GAL tickets into a 2-minute explanation. — [Offline address books in Exchange](https://learn.microsoft.com/en-us/exchange/email-addresses-and-address-books/offline-address-books/offline-address-books)
- Client-side download behaviour and manual download options. — [Administering the offline address book in Outlook](https://support.microsoft.com/en-us/topic/administering-the-offline-address-book-in-outlook-51958cc8-684a-83f9-aea5-97d4dddc0af4)
- ABPs in Exchange Online: design, the Address Lists role requirement, and the "user must be in own GAL" rule. — [Address book policies in Exchange Online](https://learn.microsoft.com/en-us/exchange/address-books/address-book-policies/address-book-policies)
- `IMCEAEX` NDRs after mailbox re-creation are a `LegacyExchangeDN` problem; the X500 proxy is the durable fix — the same technique used in `MigrationBatches-A.md` for cross-tenant moves.
- Hide-from-GAL SOA follows the mailbox's attribute SOA — the cloud-managed mailbox feature (`CloudManagedMailboxes-A.md`) is the supported route to manage it in EXO without on-prem Exchange tools.
