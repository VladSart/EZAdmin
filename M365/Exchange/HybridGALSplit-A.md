# Exchange Hybrid GAL Split (Cloud ↔ On-Prem Recipient Visibility) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.
> Hotfix: `HybridGALSplit-B.md` · Script: `Scripts/Get-HybridRecipientVisibilityAudit.ps1`

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
- **In scope:** Exchange Server (2016/2019/SE) + Exchange Online full/modern hybrid with Entra Connect Sync or Cloud Sync; recipient representation on each side; `RemoteMailbox` lifecycle; `ExchangeGuid`/`ArchiveGuid` linking; cloud-only recipients in a hybrid org; hidden-flag SOA; tools-only (last Exchange server removed) orgs.
- **Out of scope:** OAB generation/download mechanics and ABPs (`AddressBook-OAB-A.md`), connectors/OAuth/free-busy (`Hybrid-Coexistence-A.md`), migration batch failures (`MigrationBatches-A.md`), sync-engine internals (`EntraID/`).
- **Assumption:** directory sync is **one-way for recipient objects** (on-prem → cloud) with the standard Exchange hybrid writeback attributes enabled in Entra Connect (`msExchArchiveStatus`, `proxyAddresses` (cloud `LegacyExchangeDN` as X500), `msExchSafeSendersHash`, `msExchUCVoiceMailSettings`, `msExchUserHoldPolicies`, `publicDelegates`, `msExchDelegateListLink`). **`ExchangeGuid` is not written back.**

---
## How It Works
<details><summary>Full architecture</summary>

### Two address books, one source of truth
Every user's GAL comes from the directory **their own mailbox** lives in:

```
             on-prem AD (SOA for synced objects)
             ┌───────────────────────────────────┐
             │ UserMailbox (on-prem mbx)         │
             │ RemoteUserMailbox (cloud mbx)  ───┼──┐ represents
             │ MailContact / MailUser / DLs      │  │
             └──────────────┬────────────────────┘  │
     on-prem GAL / OAB      │ Entra Connect (one-way recipient sync)
     (on-prem viewers)      ▼                        │
             ┌───────────────────────────────────┐  │
             │ Entra ID → EXO directory          │  │
             │ MailUser (= on-prem mbx)          │  │
             │ UserMailbox (cloud mbx) ◄─────────┼──┘
             │ + cloud-only objects (IsDirSynced=False)
             └───────────────────────────────────┘
                 EXO GAL / OAB (cloud viewers)
```

- An **on-prem mailbox** appears in EXO as a `MailUser` whose `ExternalEmailAddress` routes back on-prem. Entra Connect creates it automatically — this direction rarely breaks unless sync scope/errors intervene.
- A **cloud mailbox** appears on-prem **only** as a `RemoteMailbox` (an AD user with `msExchRecipientTypeDetails` = `RemoteUserMailbox` (2147483648), `RemoteSharedMailbox`, `RemoteRoomMailbox`, `RemoteEquipmentMailbox`) and `targetAddress` = `RemoteRoutingAddress` (`alias@tenant.mail.onmicrosoft.com`). Nothing in the cloud creates this object for you — on-prem Exchange tooling must.
- A **cloud-only** object (created in EXO/Entra, `IsDirSynced = False`) has no on-prem representation at all. Entra Connect does not write recipient objects back.

### How the "licensed-before-enabled" split happens
1. Admin creates AD user (no Exchange attributes) → syncs to Entra as a plain user.
2. Admin assigns an Exchange Online licence. EXO sees a synced user with no `msExchRecipientTypeDetails` / `msExchMailboxGuid` and **provisions a fresh mailbox** with a new `ExchangeGuid`.
3. On-prem still sees `RecipientType : User`. On-prem viewers can't find the person; on-prem senders addressing them by SMTP may NDR (no recipient owns that address on-prem, and if the domain is authoritative on-prem the message is rejected).

The correct sequence is `New-RemoteMailbox` (new user) or `Enable-RemoteMailbox` (existing user) **before** licensing. EXO then sees the Remote type and provisions the mailbox to match.

### Why ExchangeGuid matters
- When `Enable-RemoteMailbox` runs on an AD user, the on-prem `ExchangeGuid` is `00000000-…` until set. When a mailbox is **moved** to EXO via MRS, the on-prem object is converted to `RemoteMailbox` with the real GUID — so migrated users are usually fine; *newly-created* cloud mailboxes are the risk.
- EXO stamps the GUID on mailbox creation, but **does not write it back**. Consequences of a zero/mismatched GUID:
  - **Offboarding** (move EXO → on-prem) fails: MRS needs the on-prem target to carry the source GUID.
  - If EXO receives a *synced* `msExchMailboxGuid` that differs from the existing mailbox, behaviour ranges from ignored to a provisioning error on the object. Matching GUIDs keep everything idempotent.
  - Archive: same story for `ArchiveGuid`; `msExchArchiveStatus` is written back, the GUID is not.

### Hidden-from-GAL SOA
`msExchHideFromAddressLists` is synced up. For `IsDirSynced = True` objects, EXO rejects or overwrites cloud-side changes. Hide/unhide on-prem, sync, then wait for **both** sides' OAB cycles.

### Tools-only orgs (last Exchange server removed)
Since Exchange 2019 CU12, the Exchange Management Tools ship a **recipient management PowerShell snap-in** (`Microsoft.Exchange.Management.PowerShell.RecipientManagement`) that edits Exchange attributes in AD directly (no server). It supports `*-RemoteMailbox`, `*-MailUser`, `*-MailContact`, DL cmdlets. There is no on-prem GAL for anyone to view any more (no on-prem mailboxes), so the "split" shrinks to correct provisioning and GUID hygiene for future offboarding/compliance.

### Room/shared/equipment nuances
- `Enable-RemoteMailbox -Shared` / `-Room` / `-Equipment` exist on Exchange 2013 CU21+/2016 CU10+/2019+. On older builds, shared mailboxes created in EXO show as `RemoteUserMailbox` on-prem — cosmetically wrong but functional; converting requires setting `msExchRemoteRecipientType` and `msExchRecipientTypeDetails` manually (avoid; upgrade instead).
- Converting a cloud mailbox type in EXO (`Set-Mailbox -Type Shared`) does **not** change the on-prem object type; update it on-prem too (`Set-RemoteMailbox -Type Shared`, Exchange 2016 CU10+/2019).
</details>

---
## Dependency Stack
```
L7  Viewer's client (classic Outlook Cached → OAB; OWA/new Outlook → live GAL)
L6  OAB generation on the viewer's side (on-prem arbitration mbx / EXO ~8 h)
L5  Address list stamping (on-prem: showInAddressBook via recipient update; EXO: AddressListMembership)
L4  Recipient object present on the viewer's side
       on-prem: RemoteMailbox for cloud mbx | EXO: MailUser for on-prem mbx
L3  Directory sync (Entra Connect / Cloud Sync) — scope, no export errors, Exchange hybrid writeback
L2  Provisioning order (New/Enable-RemoteMailbox BEFORE licence) + GUID stamping
L1  On-prem AD schema with Exchange attributes + Exchange server or Management Tools for recipient mgmt
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Cloud user missing from on-prem GAL & on-prem EAC | Licensed before `Enable-RemoteMailbox` | On-prem `Get-User` → `RecipientType : User` |
| On-prem users get NDR 5.1.1 sending to cloud user | Same as above (no on-prem recipient owns the address; domain authoritative) | On-prem `Get-Recipient <smtp>` returns nothing |
| Offboarding move fails "target mailbox doesn't have an SMTP proxy matching…" / GUID errors | Zero/mismatched `ExchangeGuid` on on-prem `RemoteMailbox` | Compare GUIDs both sides |
| Shared mailbox created in EXO invisible to on-prem users | Cloud-only object (`IsDirSynced : False`) | `Get-EXOMailbox -Properties IsDirSynced` |
| Shared mailbox shows as user mailbox on-prem | Created on old CU / type changed only in cloud | On-prem `RecipientTypeDetails` vs EXO |
| Can't unhide synced user in EXO admin center | On-prem SOA | `IsDirSynced : True` |
| On-prem mailbox not in cloud GAL | Sync scope / export error | `Get-ADSyncCSObject`, Entra Connect Health |
| Visible in OWA, missing in classic Outlook | OAB lag | `AddressBook-OAB-B.md` |
| Duplicate entries in cloud GAL | Cloud-only mailbox + synced contact/MailUser with same name; or failed soft-match | `Get-EXORecipient -Anr <name>` |

---
## Validation Steps
1. **On-prem representation of cloud mailboxes**
   ```powershell
   Get-RemoteMailbox -ResultSize Unlimited | Group-Object RecipientTypeDetails | Select Name,Count
   ```
   Good: counts roughly equal synced cloud mailbox counts by type. Bad: far fewer than EXO's `IsDirSynced` mailbox count.
2. **GUID integrity**
   ```powershell
   Get-RemoteMailbox -ResultSize Unlimited | Where-Object ExchangeGuid -eq ([guid]::Empty) | Measure-Object
   ```
   Good: `Count : 0`. Bad: any — run the audit script for per-object comparison.
3. **Routing address**
   ```powershell
   Get-RemoteMailbox -ResultSize Unlimited | Where-Object { $_.RemoteRoutingAddress -notlike "*.mail.onmicrosoft.com" } | Select Name,RemoteRoutingAddress
   ```
   Good: empty. Bad: routing to a custom domain → loops.
4. **Cloud-only mailboxes in hybrid**
   ```powershell
   Get-EXOMailbox -ResultSize Unlimited -Properties IsDirSynced | Where-Object { -not $_.IsDirSynced } | Select DisplayName,RecipientTypeDetails,PrimarySmtpAddress
   ```
   Good: empty or a documented list (each with an on-prem contact). Bad: undocumented objects.
5. **On-prem mailboxes as cloud MailUsers**
   ```powershell
   (Get-Mailbox -ResultSize Unlimited).Count                           # on-prem
   (Get-EXORecipient -RecipientTypeDetails MailUser -ResultSize Unlimited).Count   # cloud
   ```
   Good: cloud MailUser count ≥ on-prem mailbox count (MailUsers also include other mail users).

---
## Troubleshooting Steps (by phase)
**Phase 1 — Identify viewer side.** The fix lives in the viewer's directory. Don't touch EXO for an on-prem viewer's problem.
**Phase 2 — Object existence.** Missing object = provisioning (cloud→on-prem) or sync (on-prem→cloud). Never an OAB issue.
**Phase 3 — Object correctness.** Type, `RemoteRoutingAddress`, GUIDs, hidden flag, proxyAddresses.
**Phase 4 — Propagation.** On-prem change → AD replication → Entra Connect delta (default 30 min) → EXO directory → EXO address-list stamping → EXO OAB (~8 h) → Outlook download (~24 h). Cloud viewers can wait a day+ in classic Outlook even after everything is fixed.
**Phase 5 — Process.** Find who/what created the object wrongly (licensing automation, group-based licensing on an "all staff" group, EXO admin center shared-mailbox creation) and fix the process.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Retro-fit RemoteMailbox for licensed-before-enabled users (bulk)</summary>

```powershell
# 1. Cloud session (Connect-ExchangeOnline -Prefix Cloud): export synced cloud mailboxes
Get-EXOMailbox -ResultSize Unlimited -Properties ExchangeGuid,ArchiveGuid,IsDirSynced |
  Where-Object IsDirSynced |
  Select-Object UserPrincipalName,Alias,RecipientTypeDetails,ExchangeGuid,ArchiveGuid |
  Export-Csv .\CloudSynced.csv -NoTypeInformation

# 2. On-prem: find which have no Exchange attributes
$rows = Import-Csv .\CloudSynced.csv
$todo = foreach ($r in $rows) {
  $u = Get-User $r.UserPrincipalName -ErrorAction SilentlyContinue
  if ($u -and $u.RecipientType -eq 'User') { $r }
}
$todo | Export-Csv .\NeedsEnableRemote.csv -NoTypeInformation   # REVIEW before step 3

# 3. Apply (pilot 1-2 first)
foreach ($r in (Import-Csv .\NeedsEnableRemote.csv)) {
  $p = @{ Identity = $r.UserPrincipalName; RemoteRoutingAddress = "$($r.Alias)@<tenant>.mail.onmicrosoft.com" }
  switch ($r.RecipientTypeDetails) { 'SharedMailbox' { $p.Shared = $true } 'RoomMailbox' { $p.Room = $true } 'EquipmentMailbox' { $p.Equipment = $true } }
  Enable-RemoteMailbox @p
  Set-RemoteMailbox $r.UserPrincipalName -ExchangeGuid $r.ExchangeGuid
  if ($r.ArchiveGuid -and $r.ArchiveGuid -ne [guid]::Empty.ToString()) { Set-RemoteMailbox $r.UserPrincipalName -ArchiveGuid $r.ArchiveGuid }
}
```
Rollback: `Disable-RemoteMailbox` is **dangerous** on a live cloud mailbox (sync may cause EXO to disconnect it). If a pilot object looks wrong, correct attributes with `Set-RemoteMailbox` instead of disabling.
</details>

<details><summary>Playbook 2 — Bulk GUID repair</summary>

```powershell
$cloud = Import-Csv .\CloudSynced.csv | Group-Object UserPrincipalName -AsHashTable -AsString
Get-RemoteMailbox -ResultSize Unlimited | ForEach-Object {
  $c = $cloud[$_.UserPrincipalName]
  if ($c -and $_.ExchangeGuid.ToString() -ne $c.ExchangeGuid) {
    [pscustomobject]@{ UPN=$_.UserPrincipalName; OnPrem=$_.ExchangeGuid; Cloud=$c.ExchangeGuid }
  }
} | Export-Csv .\GuidMismatch.csv -NoTypeInformation
# Review, then:
Import-Csv .\GuidMismatch.csv | ForEach-Object { Set-RemoteMailbox $_.UPN -ExchangeGuid $_.Cloud }
```
Rollback: the CSV holds the old on-prem values — `Set-RemoteMailbox -ExchangeGuid <OnPrem>` restores.
</details>

<details><summary>Playbook 3 — Bring a cloud-only mailbox under on-prem management (soft-match)</summary>

1. Confirm soft-match isn't blocked: `(Get-MgDirectoryOnPremiseSynchronization).Features.BlockSoftMatchEnabled` → `$false`.
2. Create AD user in a sync-scoped OU with **identical** UPN and `proxyAddresses` (primary `SMTP:` matching EXO `PrimarySmtpAddress`), `mail` set.
3. `Enable-RemoteMailbox` (with `-Shared`/`-Room` as needed) + `Set-RemoteMailbox -ExchangeGuid`.
4. Delta sync. Verify `Get-EXOMailbox <upn> -Properties IsDirSynced` → `True`, and no duplicate in `Get-EXORecipient -Anr`.
5. Rollback: if a duplicate appears, move the AD user out of sync scope (deletes the *synced* duplicate, not the original cloud object) and investigate the match failure.
Note: shared/room mailboxes have disabled accounts on-prem; leave the AD account disabled.
</details>

<details><summary>Playbook 4 — On-prem visibility for cloud-only objects you won't convert</summary>

Create mail contacts in an OU **excluded from sync**:
```powershell
New-MailContact -Name "<Display>" -ExternalEmailAddress "<addr@contoso.com>" -OrganizationalUnit "<contoso.com/NoSync/HybridContacts>"
```
Document these — they drift (renames in EXO won't flow back).
</details>

<details><summary>Playbook 5 — Fix provisioning going forward</summary>

- New users: `New-RemoteMailbox -Name ... -UserPrincipalName ... -Password ... -OnPremisesOrganizationalUnit ...` (creates AD user + Remote attributes in one step), then licence.
- Group-based licensing: keep new users out of licensing groups until `RemoteMailbox` exists, or have the onboarding script call `Enable-RemoteMailbox` before adding to the group.
- Shared mailboxes: `New-RemoteMailbox -Shared` on-prem, never EXO admin center.
</details>

---
## Evidence Pack
Run `Scripts/Get-HybridRecipientVisibilityAudit.ps1` (needs on-prem EMS/recipient snap-in + `Connect-ExchangeOnline -Prefix Cloud` in the same session). Minimal manual equivalent:
```powershell
$out = "$env:TEMP\HybridGAL_$(Get-Date -f yyyyMMdd_HHmm)"; New-Item -ItemType Directory $out -Force | Out-Null
Get-RemoteMailbox -ResultSize Unlimited | Select UserPrincipalName,RecipientTypeDetails,ExchangeGuid,ArchiveGuid,RemoteRoutingAddress,HiddenFromAddressListsEnabled | Export-Csv "$out\OnPremRemote.csv" -NoTypeInformation
Get-EXOMailbox -ResultSize Unlimited -Properties ExchangeGuid,IsDirSynced,HiddenFromAddressListsEnabled | Select UserPrincipalName,RecipientTypeDetails,ExchangeGuid,IsDirSynced,HiddenFromAddressListsEnabled | Export-Csv "$out\CloudMbx.csv" -NoTypeInformation
Get-OrganizationConfig | Select Name,AdminDisplayVersion | Export-Csv "$out\OnPremOrg.csv" -NoTypeInformation
Compress-Archive "$out\*" "$out.zip" -Force; "Evidence: $out.zip"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| New cloud mailbox (hybrid) | `New-RemoteMailbox -Name <n> -UserPrincipalName <upn> -Password (Read-Host -AsSecureString)` |
| Existing AD user → cloud mailbox | `Enable-RemoteMailbox <upn> -RemoteRoutingAddress <alias>@<tenant>.mail.onmicrosoft.com` |
| Shared/room variant | add `-Shared` / `-Room` / `-Equipment` |
| Stamp GUID | `Set-RemoteMailbox <upn> -ExchangeGuid <guid>` |
| Stamp archive GUID | `Set-RemoteMailbox <upn> -ArchiveGuid <guid>` |
| Change type on-prem | `Set-RemoteMailbox <upn> -Type Shared` |
| Hide (on-prem SOA) | `Set-RemoteMailbox <upn> -HiddenFromAddressListsEnabled $true` |
| Cloud GUID | `(Get-EXOMailbox <upn> -Properties ExchangeGuid).ExchangeGuid` |
| Cloud-only list | `Get-EXOMailbox -Properties IsDirSynced -ResultSize Unlimited \| ? {!$_.IsDirSynced}` |
| Zero-GUID list | `Get-RemoteMailbox -ResultSize Unlimited \| ? ExchangeGuid -eq ([guid]::Empty)` |
| Re-stamp address lists on-prem | `Update-Recipient <upn>` |
| Delta sync | `Start-ADSyncSyncCycle -PolicyType Delta` |
| Tools-only snap-in | `Add-PSSnapin Microsoft.Exchange.Management.PowerShell.RecipientManagement` |

---
## 🎓 Learning Pointers
- Read Microsoft's [Create a cloud-based mailbox in a hybrid deployment](https://learn.microsoft.com/exchange/hybrid-deployment/create-cloud-based-mailbox) — it's the one-page answer to "why isn't this user in the on-prem GAL?"
- [Manage recipients in hybrid environments using Exchange Management Tools](https://learn.microsoft.com/exchange/manage-hybrid-exchange-recipients-with-management-tools) explains the snap-in and the "last Exchange server" story; it's the prerequisite reading before any decommission project.
- Understand which attributes Entra Connect writes back — [Exchange hybrid writeback](https://learn.microsoft.com/entra/identity/hybrid/connect/reference-connect-sync-attributes-synchronized#exchange-hybrid-writeback) — and notice `msExchMailboxGuid` isn't in the list; that's why Playbook 2 exists.
- Soft vs hard match (Playbook 3): [Entra Connect: soft matching](https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-connect-install-existing-tenant) — know it before you create an AD object that's meant to adopt a cloud mailbox.
- Samuraj-cz's [Exchange Hybrid — mailboxes and their locations, recipients, attributes](https://www.samuraj-cz.com/en/article/exchange-hybrid-mailboxes-and-their-locations-recipients-attributes-and-bug-fixes/) is a good attribute-level map of `msExchRecipientTypeDetails` / `msExchRemoteRecipientType` values.

> **See also (run 283):** full tools-only / last-Exchange-server shutdown procedure — `LastExchangeServer-B.md` / `-A.md`.
