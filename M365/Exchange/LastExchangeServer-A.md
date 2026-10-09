# Last Exchange Server Removal (Management Tools Only) — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** hybrid orgs that kept one Exchange server (the "Last Exchange Server", LES) only to edit recipient attributes, and want to run with **no Exchange server** using the Exchange Management Tools recipient-management snap-in (Exchange 2019 CU12+ setup, and later CUs/Exchange Server SE). Eligibility, preparation, shutdown, hybrid cleanup, AD cleanup, post-shutdown operations and tool upgrades.
- **Compared but not covered in depth:** moving Exchange-attribute SOA to the cloud (see `CloudManagedMailboxes-A.md`), full de-hybrid with sync removal.
- **Out of scope:** mailbox/public-folder migration (`MigrationBatches-A.md`, `PublicFolders-A.md`), SMTP relay redesign (`DirectSendAbuse-A.md`).
- Assumes AD remains the source of authority with Entra Connect Sync or Cloud Sync and Exchange hybrid writeback enabled.

---
## How It Works
<details><summary>Full architecture</summary>

### Why the LES existed
For a directory-synced user, Exchange attributes (`proxyAddresses`, `targetAddress`, `msExchRecipientTypeDetails`, `msExchRemoteRecipientType`, `mailNickname`, `msExchHideFromAddressLists`, custom attributes…) are mastered in on-prem AD. Exchange Online rejects edits to those attributes on synced objects. Editing them by hand in ADSI is unsupported and error-prone, so Microsoft's supported tool was always an Exchange server running `Set-RemoteMailbox` etc. — hence a server kept alive purely as an attribute editor.

### What the Management Tools snap-in changes
Since Exchange 2019 CU12 (April 2022), the Management Tools role ships a PowerShell snap-in, `Microsoft.Exchange.Management.PowerShell.RecipientManagement`, whose cmdlets write Exchange attributes **directly to AD** without contacting an Exchange server:

```
Before (LES running)                         After (tools only)
Admin -> EMS remote PS -> Exchange server    Admin -> Windows PowerShell + snap-in
         (RBAC check, audit log)                      (AD ACL check only)
      -> AD                                        -> AD
      -> Entra Connect -> EXO                      -> Entra Connect -> EXO
```
Supported cmdlet families: `*-MailUser`, `*-MailContact`, `*-RemoteMailbox`, `*-DistributionGroup` (not `Upgrade-DistributionGroup`), `*-DistributionGroupMember` (incl. `Update-`), `*-EmailAddressPolicy` (incl. `Update-`), `Set-User`/`Get-User`. Anything else (transport, connectors, mailbox cmdlets, RBAC) is not there.

### What you lose
| Capability | With LES | Tools only |
|---|---|---|
| Exchange RBAC (role groups, custom roles) | Yes | **No** — only Domain Admins + *Recipient Management EMT* group (AD ACLs set by `Add-PermissionForEMT.ps1`) |
| On-prem EAC | Yes | No |
| Admin audit log of recipient changes | Yes | No — rely on AD auditing (Directory Service Changes, 5136) |
| SMTP relay / on-prem transport | Yes | No |
| Hybrid free/busy, mailbox moves back on-prem | Yes | No |
| Remote session (`New-PSSession` to /PowerShell) | Yes | No — snap-in only; output types differ (`ProxyAddressCollection` vs `ArrayList`) |

### Why "shut down, don't uninstall"
Uninstalling the last Exchange server removes organisation-level AD objects the snap-in relies on to compute and write Exchange attributes. Microsoft's documented flow is: shut down → (optionally) run `CleanupActiveDirectoryEMT.ps1` → wipe/reformat the machine. The computer object can then be removed as part of normal AD hygiene.

### The 40-second delay
After shutdown, `New-`/`Set-` cmdlets stall ~40 s: the Admin Audit Log initializer still tries to reach the (now off) server. Running `CleanupActiveDirectoryEMT.ps1` removes the references and the delay disappears.

### What the AD cleanup script does (irreversible)
`$env:ExchangeInstallPath\Scripts\CleanupActiveDirectoryEMT.ps1`, run as Domain Admin: removes system/arbitration mailboxes, unnecessary Exchange containers, Exchange Security Group permissions on the domain and configuration partitions, and the Exchange Security Groups themselves (Organization Management, Exchange Trusted Subsystem, Exchange Windows Permissions…). The latter is a real security win — `Exchange Windows Permissions` historically held WriteDACL on the domain root.

### Tool upgrades afterwards
Upgrading the tools to a newer **CU** requires `Setup /PrepareAD` first (which re-creates some objects), then `/m:Upgrade`, then re-running `CleanupActiveDirectoryEMT.ps1` if it was run before. **SUs** install normally.

### Two exits from the LES — choosing
```
                         Need on-prem Exchange ever again?
                                  │
                ┌───── Yes ───────┴────── No ──────┐
          Keep LES (supported)            Want AD to stay SOA for Exchange attrs?
                                                    │
                                    ┌──── Yes ──────┴──── No ─────┐
                         Management Tools only          Cloud-managed Exchange attributes
                         (this runbook)                 (CloudManagedMailboxes-A.md),
                                                        then decommission
```
</details>

---
## Dependency Stack
```
[8] Admin workflow: Add-PSSnapin *RecipientManagement each session, scripts adjusted for snap-in types
[7] Permissions: Domain Admins / "Recipient Management EMT" (AD ACLs from Add-PermissionForEMT.ps1)
[6] Management Tools (2019 CU12+ / SE) + RSAT-AD on a domain-joined machine; ScriptingAgentConfig.xml if used
[5] AD schema + Exchange org prepared to the tools' build (/PrepareSchema, /PrepareAD)
[4] Exchange org objects in AD config partition (kept intact: shut down, never uninstall)
[3] Remote domain <tenant>.mail.onmicrosoft.com with TargetDeliveryDomain = True
[2] Entra Connect Sync / Cloud Sync with Exchange hybrid writeback
[1] Exchange Online: all mailboxes + PFs migrated; MX/Autodiscover on EXO
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| `Add-PSSnapin` "no snap-ins registered" | Tools older than 2019 CU12, or only EMS shortcut used | `Get-PSSnapin -Registered` |
| Access denied on `Set-RemoteMailbox` after shutdown | Caller relied on Exchange RBAC; not in *Recipient Management EMT* | `whoami /groups` |
| Each `Set-`/`New-` takes ~40 s | Pre-cleanup audit-log initializer timeout | Expected until `CleanupActiveDirectoryEMT.ps1` |
| New remote mailbox gets wrong `RemoteRoutingAddress` | No remote domain with `TargetDeliveryDomain` | `Get-RemoteDomain \| fl DomainName,TargetDeliveryDomain` |
| Outlook slow to create profiles on domain-joined PCs | Autodiscover SCP still points at the dead server | SCP query (Validation 6) |
| Printers/apps stopped sending mail | LES was a relay | Message tracking `ClientIp` before shutdown |
| Cmdlets fail with org/schema errors after someone "uninstalled" the LES | Org AD objects removed by uninstall | Escalate — recovery may need `/PrepareAD` and Microsoft support |
| Tools CU upgrade fails "AD must be prepared with /PrepareAD" | Documented upgrade requirement | Playbook 5 |
| Scripts throw on `.EmailAddresses` methods | Snap-in returns `ProxyAddressCollection` | Adjust type handling |
| Free/busy with on-prem broken | Expected — no on-prem mailboxes should exist | Eligibility re-check |

---
## Validation Steps
1. **No on-prem recipients that need a server**
   ```powershell
   Set-AdServerSettings -ViewEntireForest $true
   Get-Mailbox -ResultSize Unlimited | Group-Object RecipientTypeDetails | Select-Object Name, Count
   Get-Mailbox -PublicFolder -ResultSize Unlimited | Measure-Object
   ```
   Good: no `UserMailbox`/`SharedMailbox`/`RoomMailbox` (built-in admin mailboxes disabled). Bad: anything else.
2. **Single server**
   ```powershell
   Get-ExchangeServer | Select-Object Name, AdminDisplayVersion
   ```
   Good: one row. Bad: more — decommission others first (normal uninstall is fine for non-last servers).
3. **Schema/org level** (from any domain-joined box with AD module)
   ```powershell
   $schema = (Get-ADRootDSE).schemaNamingContext
   (Get-ADObject "CN=ms-Exch-Schema-Version-Pt,$schema" -Properties rangeUpper).rangeUpper
   ```
   Good: `17003` (Exchange 2019 CU12 and later). Lower: running 2019 CU12+ setup will extend the schema.
4. **Remote domain**
   ```powershell
   Get-RemoteDomain | Where-Object TargetDeliveryDomain | Select-Object Name, DomainName
   ```
   Good: `<tenant>.mail.onmicrosoft.com`.
5. **Relay usage**
   ```powershell
   Get-MessageTrackingLog -Start (Get-Date).AddDays(-14) -EventId RECEIVE -ResultSize Unlimited |
     Where-Object Source -eq 'SMTP' | Group-Object ClientIp | Sort-Object Count -Descending | Select-Object -First 25 Name, Count
   ```
   Good: only EXO/hybrid IPs, or nothing. Bad: internal IPs.
6. **Autodiscover SCP**
   ```powershell
   Get-ADObject -LDAPFilter '(&(objectClass=serviceConnectionPoint)(keywords=77378F46-2C66-4aa9-A6A6-3E7A48B19596))' `
     -SearchBase (Get-ADRootDSE).configurationNamingContext -Properties serviceBindingInformation
   ```
   Good (after prep): no `serviceBindingInformation` pointing at the LES.
7. **Snap-in works as a non-DA**
   ```powershell
   Add-PSSnapin *RecipientManagement; Get-RemoteMailbox -ResultSize 5 | Select-Object Name, RemoteRoutingAddress
   ```

---
## Troubleshooting Steps (by phase)
**Phase 1 — Eligibility.** Run `Get-LastExchangeServerReadiness.ps1`. Any HIGH finding (on-prem mailboxes, PFs, multiple servers, relay traffic) is a stop.
**Phase 2 — Prepare.** Disable built-in admin mailboxes; ensure `TargetDeliveryDomain`; install tools on a hardened admin box (tier-appropriate PAW, not a helpdesk laptop — the EMT group can write mail attributes forest-wide); copy `ScriptingAgentConfig.xml` if the Scripting Agent is enabled; run `Add-PermissionForEMT.ps1`; populate the EMT group; clear Autodiscover SCP.
**Phase 3 — Test with LES running, then stopped.** Exercise every cmdlet your runbooks use (create remote mailbox, add alias, hide from GAL, DL membership). Stop the server (don't uninstall) for a soak period — a week is common in practice — so any hidden dependency (relay, app using EWS on-prem, scanner-to-email) surfaces while restart is still trivial.
**Phase 4 — Permanent shutdown.** Turn LES back on, clean hybrid (decommission Scenario 2 steps 1–8), remove federation trust/cert, reset first-party SP key credentials, remove hybrid app/agent for Modern Hybrid, confirm MX/Autodiscover on EXO, shut down.
**Phase 5 — AD cleanup (optional, irreversible).** DC System State backup → `CleanupActiveDirectoryEMT.ps1` → wipe the LES disk.
**Phase 6 — Run-state.** Document the snap-in workflow; enable AD auditing for Exchange attribute changes; patch the tools with SUs; plan CU upgrades with `/PrepareAD` + cleanup re-run.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Tools box build</summary>

```powershell
# On the admin box (Windows Server 2019+/Windows 10/11 x64, domain-joined)
Install-WindowsFeature RSAT-ADDS -ErrorAction SilentlyContinue      # server; on client use Add-WindowsCapability for RSAT AD
# From mounted Exchange 2019 CU12+ / SE media:
D:\Setup.exe /Role:ManagementTools /IAcceptExchangeServerLicenseTerms_DiagnosticDataON
# As Domain Admin:
Add-PSSnapin *RecipientManagement
& "$env:ExchangeInstallPath\Scripts\Add-PermissionForEMT.ps1"
Add-ADGroupMember 'Recipient Management EMT' -Members '<helpdesk-admins-group>'
```
If the org is 2013/2016-only, run `/PrepareSchema` and `/PrepareAD` with the same media first (change window; schema changes are forest-wide and irreversible).
</details>

<details><summary>Playbook 2 — Soak test (reversible)</summary>

```powershell
# On LES
Get-ClientAccessService | Set-ClientAccessService -AutoDiscoverServiceInternalUri $null
Stop-Computer
# On tools box, as an EMT member (not DA)
Add-PSSnapin *RecipientManagement
New-RemoteMailbox -Name 'EMT Test' -UserPrincipalName emttest@<contoso.com> -Password (Read-Host -AsSecureString) -RemoteRoutingAddress emttest@<tenant>.mail.onmicrosoft.com
Set-RemoteMailbox emttest -EmailAddresses @{add='smtp:emt.alias@<contoso.com>'}
Set-RemoteMailbox emttest -HiddenFromAddressListsEnabled $true
```
Rollback: power the LES on — nothing has been removed yet. Remember the ~40 s per write cmdlet is expected during the soak.
</details>

<details><summary>Playbook 3 — Permanent shutdown with hybrid cleanup</summary>

```powershell
# LES powered on, EMS:
Remove-FederationTrust 'Microsoft Federation Gateway'
$fed = (Get-ExchangeCertificate | Where-Object { $_.Subject -eq 'CN=Federation' }).Thumbprint
if ($fed) { Remove-ExchangeCertificate -Thumbprint $fed -Confirm:$false }
.\ConfigureExchangeHybridApplication.ps1 -ResetFirstPartyServicePrincipalKeyCredentials
# If you deployed the dedicated hybrid app (HybridDedicatedApp-A.md), remove/disable that app registration as well.
# Modern Hybrid:
Import-Module 'C:\Program Files\Microsoft Hybrid Service\HybridManagement.psm1'
Remove-HybridApplication -appId <AppId> -Credential (Get-Credential)
# Then uninstall the Hybrid Agent (Programs and Features) - the AGENT, not Exchange
Stop-Computer
```
Plus the organisation relationship / connector cleanup in "How and when to decommission your on-premises Exchange servers" Scenario 2, steps 1–8, done in EXO.
Rollback: before AD cleanup, powering the LES back on and re-running HCW restores hybrid.
</details>

<details><summary>Playbook 4 — AD cleanup (irreversible)</summary>

```powershell
# 1. Back up a DC
wbadmin start systemstatebackup -backupTarget:<E:> -quiet
# 2. Domain Admin, tools box, LES shut down
Add-PSSnapin *RecipientManagement
& "$env:ExchangeInstallPath\Scripts\CleanupActiveDirectoryEMT.ps1"
# 3. Verify
Get-ADGroup -Filter "Name -eq 'Exchange Windows Permissions'"        # expect nothing
Add-PSSnapin *RecipientManagement; Measure-Command { Set-RemoteMailbox emttest -CustomAttribute2 'post-cleanup' }   # expect seconds, not ~40 s
```
Rollback: none short of authoritative AD restore. Community reports exist of the script failing on permissions or environment — test in a lab copy of AD first.
</details>

<details><summary>Playbook 5 — Upgrading the tools to a newer CU</summary>

```powershell
D:\Setup.exe /PrepareAD /IAcceptExchangeServerLicenseTerms_DiagnosticDataON
D:\Setup.exe /m:Upgrade /IAcceptExchangeServerLicenseTerms_DiagnosticDataON
# Only if cleanup was previously run and no Exchange servers are running:
& "$env:ExchangeInstallPath\Scripts\CleanupActiveDirectoryEMT.ps1"
```
SUs: run the SU package directly.
</details>

---
## Evidence Pack
```powershell
# Collect-LesEvidence.ps1 - read-only. Run in EMS on LES (if running) or tools box with snap-in.
param([string]$Out = "$env:TEMP\LesEvidence")
New-Item $Out -ItemType Directory -Force | Out-Null
try { Add-PSSnapin *RecipientManagement -ErrorAction SilentlyContinue } catch {}
& { Get-ExchangeServer | Select-Object Name, AdminDisplayVersion, ServerRole } 2>&1 | Out-File "$Out\servers.txt"
& { Get-RemoteDomain | Format-List Name, DomainName, TargetDeliveryDomain } 2>&1 | Out-File "$Out\remoteDomains.txt"
& { Get-RemoteMailbox -ResultSize 20 | Format-List Name, RemoteRoutingAddress, ExchangeGuid } 2>&1 | Out-File "$Out\remoteMailboxSample.txt"
$schema = (Get-ADRootDSE).schemaNamingContext
(Get-ADObject "CN=ms-Exch-Schema-Version-Pt,$schema" -Properties rangeUpper).rangeUpper | Out-File "$Out\schemaVersion.txt"
Get-ADGroup -Filter "Name -like 'Recipient Management EMT'" -Properties member | Select-Object Name, @{n='Members';e={$_.member -join '; '}} |
  Out-File "$Out\emtGroup.txt"
Get-ADObject -LDAPFilter '(&(objectClass=serviceConnectionPoint)(keywords=77378F46-2C66-4aa9-A6A6-3E7A48B19596))' `
  -SearchBase (Get-ADRootDSE).configurationNamingContext -Properties serviceBindingInformation |
  Select-Object DistinguishedName, @{n='Uri';e={$_.serviceBindingInformation -join ';'}} | Out-File "$Out\autodiscoverScp.txt"
Get-PSSnapin -Registered | Out-File "$Out\snapins.txt"
whoami /groups | Out-File "$Out\whoami.txt"
Compress-Archive "$Out\*" "$Out.zip" -Force; "Evidence: $Out.zip"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Load snap-in (every session) | `Add-PSSnapin *RecipientManagement` |
| Full snap-in (remote-domain fixes, never-had-Exchange case only) | `Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn` |
| Install tools | `Setup.exe /Role:ManagementTools /IAcceptExchangeServerLicenseTerms_DiagnosticDataON` |
| Grant non-DA rights | `& "$env:ExchangeInstallPath\Scripts\Add-PermissionForEMT.ps1"` |
| AD cleanup (irreversible) | `& "$env:ExchangeInstallPath\Scripts\CleanupActiveDirectoryEMT.ps1"` |
| Check on-prem mailboxes | `Get-Mailbox -ResultSize Unlimited \| Group RecipientTypeDetails` |
| Target delivery domain | `Get-RemoteDomain \| fl DomainName,TargetDeliveryDomain` |
| Clear Autodiscover SCP | `Get-ClientAccessService \| Set-ClientAccessService -AutoDiscoverServiceInternalUri $null` |
| Relay check | `Get-MessageTrackingLog -EventId RECEIVE -Start (Get-Date).AddDays(-14) \| Group ClientIp` |
| Remove federation trust | `Remove-FederationTrust 'Microsoft Federation Gateway'` |
| Reset first-party SP keys | `.\ConfigureExchangeHybridApplication.ps1 -ResetFirstPartyServicePrincipalKeyCredentials` |
| Schema version | `(Get-ADObject "CN=ms-Exch-Schema-Version-Pt,<schemaNC>" -Properties rangeUpper).rangeUpper` |
| Tools CU upgrade | `Setup.exe /PrepareAD ...` then `Setup.exe /m:Upgrade ...` |
| Readiness audit | `.\Get-LastExchangeServerReadiness.ps1` |

---
## 🎓 Learning Pointers
- Primary source for every step and warning here: [Manage recipients in Exchange Hybrid environments using Management tools](https://learn.microsoft.com/en-us/exchange/manage-hybrid-exchange-recipients-with-management-tools) — re-read before each engagement; it was last revised Oct 2025.
- Hybrid cleanup steps: [How and when to decommission your on-premises Exchange servers in a hybrid deployment](https://learn.microsoft.com/en-us/exchange/decommission-on-premises-exchange).
- The SOA alternative: [Cloud-based management of Exchange attributes](https://learn.microsoft.com/en-us/exchange/hybrid-deployment/enable-exchange-attributes-cloud-management) — compare against this runbook with the decision tree above (`CloudManagedMailboxes-A.md`).
- Removing `Exchange Windows Permissions` via the cleanup script closes a long-known AD privilege-escalation path — a security argument worth putting in the customer proposal.
- Community: Icewolf's 2019 CU12 Recipient Management walkthrough and Practical365's last-Exchange-server articles show the real-world gotchas (snap-in per session, type differences).
- Related here: `HybridGALSplit-A.md` (provisioning remote mailboxes correctly), `HybridDedicatedApp-A.md` (hybrid app registration to clean up), `DirectSendAbuse-A.md` (relay replacements).
