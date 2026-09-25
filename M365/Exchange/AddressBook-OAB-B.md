# Exchange Online GAL & Offline Address Book — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.
> Covers: new/renamed user not showing in Outlook's address book, hidden user still visible (or visible user hidden), stale autocomplete entries bouncing with `IMCEAEX` NDRs, Address Book Policy (ABP) scoping surprises.
> Deep dive: `AddressBook-OAB-A.md` · Script: `Scripts/Get-AddressBookDiagnostics.ps1`

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run in `Connect-ExchangeOnline` (ExchangeOnlineManagement v3+):

```powershell
$u = "<user@contoso.com>"
Get-Recipient $u | Format-List DisplayName,RecipientTypeDetails,HiddenFromAddressListsEnabled,IsDirSynced,WhenChanged,AddressListMembership
Get-EXOMailbox $u -Properties AddressBookPolicy,OfflineAddressBook | Format-List AddressBookPolicy,OfflineAddressBook
Get-OfflineAddressBook | Format-List Name,IsDefault,AddressLists,LastTouchedTime
Get-AddressBookPolicy -ErrorAction SilentlyContinue | Format-Table Name,GlobalAddressList,OfflineAddressBook
```

Then ask **which client** the complaining user is on — this decides 80% of tickets.

| Observation | Meaning | Go to |
|---|---|---|
| Recipient visible in OWA / new Outlook / Outlook for Mac but **not** in classic Outlook | Classic Outlook in Cached Mode reads the **downloaded OAB**, not the live GAL. Expected 24–48 h lag | Fix 1 |
| `HiddenFromAddressListsEnabled : True` | Recipient is hidden — deliberate or wrong | Fix 2 |
| `IsDirSynced : True` and you can't change the hidden flag in EXO | Source of authority is on-prem AD (`msExchHideFromAddressLists`) | Fix 2 |
| `AddressListMembership` is empty and recipient isn't hidden | Recipient hasn't been stamped into the Default GAL — object hasn't been recalculated | Fix 3 |
| Viewing user has an `AddressBookPolicy` | They see only the ABP's GAL/OAB — missing recipient may simply be out of scope | Fix 4 |
| Sends bounce with `IMCEAEX-_o=...` or "the recipient doesn't exist" but address is correct | Stale **autocomplete** (nickname cache) entry pointing to an old `LegacyExchangeDN` | Fix 5 |
| Recipient not in `Get-Recipient` at all | Not an address-book problem — sync/licensing/provisioning | `EntraID/` Connect/Cloud Sync runbooks |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
User sees recipient in classic Outlook (Cached Mode)
└── Outlook downloaded an OAB generated AFTER the change
    ├── Outlook OAB download succeeded (Autodiscover → OABUrl, ~24 h cadence or manual)
    ├── EXO generated the OAB (service-side, ~every 8 h, not admin-triggerable in EXO)
    └── Recipient is a member of an address list included in the OAB
        ├── Recipient is in the Default GAL / address list (AddressListMembership stamped)
        │   └── Recipient is NOT hidden (HiddenFromAddressListsEnabled = False)
        │       └── Hidden flag correct at source of authority
        │           ├── Cloud-only → EXO
        │           └── Dir-synced → on-prem AD msExchHideFromAddressLists → Entra Connect/Cloud Sync (≈30 min cycle)
        │               (unless mailbox is cloud-managed: IsExchangeCloudManaged = True)
        └── Recipient exists in EXO (Get-Recipient returns it)
└── Viewer is not scoped by an ABP that excludes the recipient

User sees recipient in OWA / new Outlook / Mac / mobile
└── Online directory lookup — only the bottom three layers matter (minutes, not days)
```
</details>

---
## Diagnosis & Validation Flow

1. **Is the recipient in the live directory?**
   ```powershell
   Get-Recipient "<user@contoso.com>" | Select DisplayName,PrimarySmtpAddress,HiddenFromAddressListsEnabled
   ```
   Expected: one object, `HiddenFromAddressListsEnabled : False`. Nothing returned → provisioning/sync issue, not OAB.

2. **Is it stamped into address lists?**
   ```powershell
   (Get-Recipient "<user@contoso.com>").AddressListMembership
   ```
   Expected: at least `\Default Global Address List` and `\All Users` (or `\All Groups`/`\All Rooms` per type). Empty → Fix 3.

3. **Does the viewer see it online?** Have the viewer search in OWA (outlook.office.com → People / new message To: field).
   Found in OWA but not classic Outlook → OAB lag (Fix 1). Not found in OWA either → steps 2/4.

4. **Is the viewer scoped by an ABP?**
   ```powershell
   Get-EXOMailbox "<viewer@contoso.com>" -Properties AddressBookPolicy | Select AddressBookPolicy
   ```
   Non-empty → Fix 4.

5. **Is the viewer's Outlook actually in Cached Mode and downloading?** On the viewer's PC:
   ```powershell
   Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook\Offline Address Books" -Recurse -File |
     Sort LastWriteTime -Desc | Select -First 5 FullName,LastWriteTime,Length
   ```
   `LastWriteTime` older than ~48 h → download is failing or disabled (Fix 1, then Outlook `Test E-mail AutoConfiguration` → check `OAB URL` present).

---
## Common Fix Paths

<details><summary>Fix 1 — Classic Outlook OAB is stale (most common)</summary>

This is expected behaviour, not a fault, if the change is < 48 h old. Options, least to most invasive:

1. **Workaround now:** type the full SMTP address, or in the Address Book choose **Address Book: Global Address List** (online) rather than *Offline Global Address List*.
2. **Manual download:** Outlook → *Send/Receive* → *Send/Receive Groups* → *Download Address Book…* → untick *Download changes since last Send/Receive* → *Full Details* → OK. Only helps if EXO has already regenerated the OAB (~8 h cycle).
3. **Force a clean full download** (Outlook closed):
   ```powershell
   $oab = "$env:LOCALAPPDATA\Microsoft\Outlook\Offline Address Books"
   if (Test-Path $oab) { Rename-Item $oab "$oab.old_$(Get-Date -f yyyyMMddHHmm)" }
   # Start Outlook, then run step 2
   ```
   Rollback: close Outlook, delete the new folder, rename `.old_*` back.

You **cannot** force OAB generation in Exchange Online (`Update-OfflineAddressBook` is on-prem only). Set user expectation: up to 24–48 h.
</details>

<details><summary>Fix 2 — Hidden flag wrong</summary>

Cloud-only or cloud-managed mailbox:
```powershell
Set-Mailbox "<user@contoso.com>" -HiddenFromAddressListsEnabled $false   # or $true to hide
# Groups / contacts: Set-UnifiedGroup / Set-DistributionGroup / Set-MailContact -HiddenFromAddressListsEnabled
```
Dir-synced (`IsDirSynced : True`) — change it on-prem, EXO will reject the write:
```powershell
# On a DC / box with RSAT, then wait for sync (or Start-ADSyncSyncCycle -PolicyType Delta on the Connect server)
Set-ADUser "<samAccountName>" -Replace @{msExchHideFromAddressLists=$true}   # or -Clear msExchHideFromAddressLists to unhide
```
If the attribute doesn't exist, the AD schema was never extended for Exchange — see `CloudManagedMailboxes-B.md` (per-mailbox SOA transfer) rather than hand-editing.
</details>

<details><summary>Fix 3 — Recipient not stamped into address lists</summary>

Address list membership in EXO is recalculated when the object changes. Touch a harmless attribute:
```powershell
Set-Mailbox "<user@contoso.com>" -CustomAttribute15 "ABtouch"
Start-Sleep 60
Set-Mailbox "<user@contoso.com>" -CustomAttribute15 $null
(Get-Recipient "<user@contoso.com>").AddressListMembership
```
Dir-synced objects: EXO rejects the write — touch `extensionAttribute15` on-prem and let sync drive it. Check `CustomAttribute15` is unused in your tenant first (dynamic groups / ABP filters may reference it). For many objects (e.g. after creating a new address list) loop the same pattern over `Get-Recipient -ResultSize Unlimited` in off-hours.
</details>

<details><summary>Fix 4 — Viewer scoped by an Address Book Policy</summary>

```powershell
$abp = (Get-EXOMailbox "<viewer@contoso.com>" -Properties AddressBookPolicy).AddressBookPolicy
Get-AddressBookPolicy $abp | Format-List GlobalAddressList,AddressLists,OfflineAddressBook,RoomList
Get-GlobalAddressList (Get-AddressBookPolicy $abp).GlobalAddressList | Format-List RecipientFilter
```
Either the recipient's attributes don't match the GAL's `RecipientFilter` (fix the attribute — e.g. `CustomAttribute1`/`Company`), or the policy is correct and the ticket is "by design". To remove the scoping: `Set-Mailbox "<viewer>" -AddressBookPolicy $null` (restart Outlook; ABP change can take hours to reflect).
Note: ABP cmdlets need the **Address Lists** role, which is not in Organization Management by default.
</details>

<details><summary>Fix 5 — Stale autocomplete → IMCEAEX NDR</summary>

Cause: mailbox was deleted/re-created or migrated; Outlook's autocomplete entry still holds the old `LegacyExchangeDN`.

Quick (per user): in the To: field, start typing the name → click the **X** next to the suggestion → re-pick from the address book.

Permanent (everyone): add the old DN as an X500 proxy on the new mailbox. Build it from the NDR:
- Take the `IMCEAEX-...@domain` string, drop `IMCEAEX-` and `@domain`, replace `_` with `/`, `+20` with space, `+28`/`+29` with `(`/`)`, `+2E` with `.`.
```powershell
Set-Mailbox "<user@contoso.com>" -EmailAddresses @{Add="X500:/o=ExchangeLabs/ou=Exchange Administrative Group (FYDIBOHF23SPDLT)/cn=Recipients/cn=<old-cn>"}
```
Dir-synced: add the X500 to `proxyAddresses` on-prem instead. Rollback: `@{Remove="X500:..."}`.
</details>

---
## Escalation Evidence

```
Ticket: GAL / OAB — <short description>
Tenant:                     <tenant>.onmicrosoft.com
Affected recipient:         <smtp>   RecipientTypeDetails: <>   IsDirSynced: <True/False>
HiddenFromAddressListsEnabled: <>
AddressListMembership:      <paste>
Viewer(s):                  <smtp>   Client: <classic Outlook build / new Outlook / OWA / Mac / mobile>
Viewer AddressBookPolicy:   <none / name>
Visible in OWA?             <Y/N>
Local OAB folder newest file LastWriteTime: <>
Change made at (UTC):       <>   Hours elapsed: <>
Fixes attempted:            <1/2/3/4/5 + result>
Get-AddressBookDiagnostics.ps1 CSV attached: <Y/N>
```

---
## 🎓 Learning Pointers
- Classic Outlook Cached Mode reads a **downloaded snapshot**; OWA, new Outlook, Outlook for Mac and mobile hit the live directory. Asking "which client?" first saves most of these tickets. — [Offline address books](https://learn.microsoft.com/en-us/exchange/email-addresses-and-address-books/offline-address-books/offline-address-books)
- EXO regenerates OAB on its own schedule (~8 h) and Outlook downloads ~every 24 h — a 24–48 h window is normal and not escalatable. — [Administering the OAB in Outlook](https://support.microsoft.com/en-us/topic/administering-the-offline-address-book-in-outlook-51958cc8-684a-83f9-aea5-97d4dddc0af4)
- For dir-synced objects, `msExchHideFromAddressLists` is owned by on-prem AD; if the last Exchange server is gone, see `CloudManagedMailboxes-A.md` before attempting schema hacks.
- `IMCEAEX` NDRs are always an autocomplete/`LegacyExchangeDN` mismatch — the X500 proxy fix is the permanent answer after re-creating or migrating a mailbox.
- ABPs are the only supported way to segment the GAL in EXO; Information Barriers also create ABP-like segmentation — see `Security/Purview/InformationBarriers-B.md` if the tenant uses them. — [Address book policies](https://learn.microsoft.com/en-us/exchange/address-books/address-book-policies/address-book-policies)
