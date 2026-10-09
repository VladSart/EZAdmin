# Last Exchange Server Removal (Management Tools Only) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers: deciding whether the last on-prem Exchange server can be shut down, moving recipient management to the Exchange Management Tools snap-in, and the breakage seen after shutdown.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run in the Exchange Management Shell **on the last Exchange server while it is still running**.

```powershell
Set-AdServerSettings -ViewEntireForest $true
# 1. Any on-prem mailboxes or public folder mailboxes left? (must be zero, except built-in arbitration/system)
Get-Mailbox -ResultSize Unlimited | Measure-Object
Get-Mailbox -PublicFolder -ResultSize Unlimited | Measure-Object

# 2. Is the server still doing anything besides recipient management?
Get-ExchangeServer | Select-Object Name, AdminDisplayVersion, ServerRole
Get-ReceiveConnector | Where-Object { $_.Name -notmatch '^(Default|Client Proxy|Client Frontend|Outbound Proxy Frontend)' } |
    Select-Object Identity, Bindings, @{n='RemoteIPRanges';e={$_.RemoteIPRanges -join ','}}, PermissionGroups

# 3. Coexistence domain set as target delivery domain?
Get-RemoteDomain Hybrid* | Format-List DomainName, TargetDeliveryDomain

# 4. Where do MX and Autodiscover point?
Get-AcceptedDomain | ForEach-Object { Resolve-DnsName $_.DomainName -Type MX -ErrorAction SilentlyContinue | Select-Object Name, NameExchange }
Get-ClientAccessService | Select-Object Name, AutoDiscoverServiceInternalUri
```

| Result | Meaning | Action |
|---|---|---|
| Any user/shared/room mailboxes on-prem | Not eligible | Migrate them first (`MigrationBatches-B.md`) |
| Public folder mailboxes on-prem | Not eligible | Migrate PFs (`PublicFolders-B.md`) |
| More than one Exchange server | Not the "last" yet | Decommission extras normally (uninstall is fine for non-last servers) |
| Custom (non-default) receive connectors + internal traffic in logs | Server is an SMTP relay | **Do not shut down** until relay moved — Fix 4 |
| No `TargetDeliveryDomain = True` remote domain | New remote mailboxes may route wrong | Fix 1 step 2 |
| MX not `*.mail.protection.outlook.com` | Mail still flows through on-prem | Repoint MX first |
| `AutoDiscoverServiceInternalUri` populated | Domain-joined Outlook will query a dead server via SCP | Fix 3 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Admin runs Set-RemoteMailbox on a tools-only workstation/server
└── Exchange Management Tools from Exchange 2019 CU12+ (or Exchange Server SE) installed
    └── AD schema/org prepared to that build (Setup /PrepareSchema /PrepareAD)
        └── Snap-in loaded: Add-PSSnapin *RecipientManagement   (every session)
            └── Caller is Domain Admin OR member of "Recipient Management EMT" (Add-PermissionForEMT.ps1)
                └── Writes Exchange attributes directly to on-prem AD (no Exchange server, no RBAC, no audit log)
                    └── Entra Connect Sync / Cloud Sync with Exchange hybrid writeback enabled
                        └── Exchange Online picks up the change on next sync cycle
```
Exchange RBAC stops working the moment the last server is off — role groups like *Recipient Management* no longer grant anything.
</details>

---
## Diagnosis & Validation Flow

1. **Eligibility check** (all must be true — from Microsoft's published criteria):
   all mailboxes and public folders in EXO; AD is SOA with Entra Connect or Cloud Sync; no need for on-prem EAC, RBAC, or recipient-change auditing; only one Exchange server, used only for recipient management.
   Run `M365/Exchange/Scripts/Get-LastExchangeServerReadiness.ps1` for a scored report.

2. **Built-in admin/arbitration mailboxes:**
   ```powershell
   Get-Mailbox -ResultSize Unlimited | Select-Object Name, RecipientTypeDetails, Database
   ```
   Built-in admin mailboxes aren't synced to the cloud — Microsoft says disable them (`Disable-Mailbox <name>`) before proceeding. Arbitration/system mailboxes (`Get-Mailbox -Arbitration`) are handled by the AD cleanup script later — leave them.

3. **Install Management Tools on the new admin box** (domain-joined, client or server):
   ```powershell
   .\Setup.exe /Role:ManagementTools /IAcceptExchangeServerLicenseTerms_DiagnosticDataON
   ```
   If the org is only 2013/2016, this upgrades the org to 2019 and **extends the schema** — run `/PrepareSchema` and `/PrepareAD` under change control first. Also install RSAT AD tools.

4. **Create the EMT permission group** (as Domain Admin, on the tools box):
   ```powershell
   Add-PSSnapin *RecipientManagement
   & "$env:ExchangeInstallPath\Scripts\Add-PermissionForEMT.ps1"
   Get-ADGroup 'Recipient Management EMT'
   ```
   Expected: group exists; add helpdesk admins to it.

5. **Test with the server still running, then again with it shut down:**
   ```powershell
   Add-PSSnapin *RecipientManagement
   Get-RemoteMailbox <user> | Format-List PrimarySmtpAddress, RemoteRoutingAddress, ExchangeGuid
   Set-RemoteMailbox <user> -CustomAttribute1 'EMT-test'
   ```
   Expected: works. After shutdown `New-`/`Set-` take ~40 s each until AD cleanup runs (Admin Audit Log initializer timing out against the dead server) — this is documented, not a fault.

---
## Common Fix Paths

<details><summary>Fix 1 — Prepare the environment (before shutdown)</summary>

```powershell
Set-AdServerSettings -ViewEntireForest $true
# 1. Disable built-in admin mailboxes left on-prem (NOT arbitration mailboxes)
Get-Mailbox -ResultSize Unlimited | Format-Table Name, RecipientTypeDetails
Disable-Mailbox '<Administrator>' -Confirm:$false

# 2. Coexistence domain as target delivery domain
New-RemoteDomain -Name 'Hybrid Domain - <tenant>.mail.onmicrosoft.com' -DomainName '<tenant>.mail.onmicrosoft.com'
Set-RemoteDomain -Identity 'Hybrid Domain - <tenant>.mail.onmicrosoft.com' -TargetDeliveryDomain $true

# 3. Scripting Agent? copy its config to the tools box
(Get-CmdletExtensionAgent 'Scripting Agent').Enabled
Copy-Item "$env:ExchangeInstallPath\Bin\CmdletExtensionAgents\ScriptingAgentConfig.xml" "\\<ToolsBox>\c$\Program Files\Microsoft\Exchange Server\V15\Bin\CmdletExtensionAgents\"
```
Disabling a mailbox deletes it after the retention period — confirm the admin mailbox holds nothing needed.
</details>

<details><summary>Fix 2 — Clean up hybrid and shut down permanently</summary>

On the last server, in this order (Microsoft's sequence):
```powershell
# a) Hybrid cleanup: Scenario 2 steps 1-8 of "decommission on-premises Exchange" (org relationships, connectors, OAuth)
# b) Federation trust + certificate
Remove-FederationTrust 'Microsoft Federation Gateway'
$fed = (Get-ExchangeCertificate | Where-Object { $_.Subject -eq 'CN=Federation' }).Thumbprint
if ($fed) { Remove-ExchangeCertificate -Thumbprint $fed }
# c) Reset first-party SP key credentials (script from aka.ms/ConfigureExchangeHybridApplication)
.\ConfigureExchangeHybridApplication.ps1 -ResetFirstPartyServicePrincipalKeyCredentials
# d) Modern hybrid only: remove hybrid app + uninstall Hybrid Agent
Import-Module 'C:\Program Files\Microsoft Hybrid Service\HybridManagement.psm1'
Remove-HybridApplication -appId <AppId> -Credential (Get-Credential)
# e) Confirm MX + Autodiscover public DNS point at EXO, then:
Stop-Computer
```
**Never run Exchange Setup uninstall on the last server.** Uninstall removes AD objects the Management Tools need; the doc's instruction is shut down, clean up AD, then wipe/reformat the box.
Get the hybrid AppId from `Get-MigrationEndpoint 'Hybrid Migration Endpoint - EWS (Default Web Site)' | Select RemoteServer` in EXO PowerShell.
</details>

<details><summary>Fix 3 — Outlook slow / prompts after shutdown (Autodiscover SCP)</summary>

Domain-joined Outlook looks up the Autodiscover SCP in AD first. If it still points at the dead server, profile creation and Autodiscover refresh stall until timeout.
```powershell
# Before shutdown (EMS on the last server):
Get-ClientAccessService | Set-ClientAccessService -AutoDiscoverServiceInternalUri $null
# After shutdown, check AD directly:
Get-ADObject -LDAPFilter '(&(objectClass=serviceConnectionPoint)(keywords=77378F46-2C66-4aa9-A6A6-3E7A48B19596))' `
  -SearchBase (Get-ADRootDSE).configurationNamingContext -Properties serviceBindingInformation |
  Select-Object DistinguishedName, serviceBindingInformation
```
If SCPs remain and you are not ready for AD cleanup, a short-term client workaround is the Outlook `ExcludeScpLookup` policy (HKCU\Software\Microsoft\Office\16.0\Outlook\AutoDiscover, DWORD 1) via GPO/Intune.
</details>

<details><summary>Fix 4 — Server is still an SMTP relay</summary>

```powershell
Get-MessageTrackingLog -Start (Get-Date).AddDays(-7) -EventId RECEIVE -ResultSize 5000 |
  Where-Object { $_.Source -eq 'SMTP' } | Group-Object ClientIp | Sort-Object Count -Descending | Select-Object -First 20 Name, Count
```
Any internal IPs (printers, apps, line-of-business servers) = live relay clients. Move them to an EXO option (SMTP AUTH client submission, EXO inbound connector by IP/cert, or a separate relay) before shutdown — see `DirectSendAbuse-B.md` for the Direct Send restrictions. Microsoft is explicit: if the server does anything but recipient management, don't shut it down.
</details>

<details><summary>Fix 5 — "Access denied" / cmdlet not found on the tools box</summary>

```powershell
Get-PSSnapin -Registered | Where-Object Name -like '*Exchange*'
Add-PSSnapin *RecipientManagement           # required in EVERY new session
whoami /groups | findstr /i "Recipient Management EMT"
```
- Snap-in missing → tools older than 2019 CU12; re-run setup from current CU/SE media.
- Access denied → user not Domain Admin and not in *Recipient Management EMT*; old Exchange role groups no longer work. Group membership needs a fresh logon (Kerberos token).
- Cmdlet outside the supported list (e.g. `Get-Mailbox` against EXO objects, `Upgrade-DistributionGroup`) → not available in the snap-in by design.
- Scripts break on `.EmailAddresses` types → snap-in returns `ProxyAddressCollection`, not `ArrayList`; adjust script logic.
</details>

<details><summary>Fix 6 — Updating the tools to a newer CU fails ("Active Directory must be prepared with Setup /PrepareAD")</summary>

```powershell
.\Setup.exe /PrepareAD /IAcceptExchangeServerLicenseTerms_DiagnosticDataON
.\Setup.exe /m:Upgrade  /IAcceptExchangeServerLicenseTerms_DiagnosticDataON
# Only if CleanupActiveDirectoryEMT.ps1 was run before AND no Exchange servers are running:
& "$env:ExchangeInstallPath\Scripts\CleanupActiveDirectoryEMT.ps1"
```
`/PrepareAD` re-creates some objects the cleanup script removed, which is why the cleanup must be re-run. Security Updates install normally without this.
</details>

<details><summary>Fix 7 — AD cleanup (irreversible)</summary>

Only when you will **never** run Exchange on-prem again:
```powershell
# Domain Admin, on the tools box, after the last server is shut down
& "$env:ExchangeInstallPath\Scripts\CleanupActiveDirectoryEMT.ps1"
```
Removes system mailboxes, unneeded Exchange containers, Exchange Security Group permissions on domain/config partitions, and the Exchange Security Groups. No rollback short of AD forest restore — take a System State backup of a DC first (`ActiveDirectory/` backup runbooks).
</details>

---
## Escalation Evidence
```
Last Exchange server name / build:   ______________ / ______________
Tools box name / Exchange build:     ______________ / ______________
On-prem mailbox count (non-arb):     ______   PF mailboxes: ______
Receive connectors in use (relay):   ______________________
TargetDeliveryDomain remote domain:  ______________________
MX / Autodiscover targets:           ______________________
Autodiscover SCP still present:      [ ] Yes [ ] No
Server state:                        [ ] Running [ ] Shut down [ ] Uninstalled (!!)
CleanupActiveDirectoryEMT run:       [ ] No [ ] Yes, date ______
Failing cmdlet + full error:         ______________________
Caller group membership (whoami /groups): (attach)
Get-LastExchangeServerReadiness.ps1 CSV: (attach)
```

---
## 🎓 Learning Pointers
- Microsoft's eligibility list, the snap-in cmdlet list and the shut-down-not-uninstall warning: [Manage recipients in Exchange Hybrid environments using Management tools](https://learn.microsoft.com/en-us/exchange/manage-hybrid-exchange-recipients-with-management-tools).
- The alternative path is moving Exchange-attribute SOA to the cloud instead of keeping tools on-prem — see `CloudManagedMailboxes-B.md` and [Decommission the last Exchange Server](https://learn.microsoft.com/en-us/exchange/hybrid-deployment/decommission-last-exchange-server).
- The 40-second delay after shutdown is the Admin Audit Log initializer timing out — a good example of why "it's slow" isn't always "it's broken"; it disappears after AD cleanup.
- RBAC lives in Exchange, not AD — so turning the server off silently removes every delegated role. Plan the *Recipient Management EMT* group membership before shutdown.
- Hidden relay traffic is the #1 reason a "recipient-management-only" server turns out not to be: always check message tracking for internal `ClientIp` values.
- Related: `HybridGALSplit-B.md` (provisioning remote mailboxes correctly with `Enable-RemoteMailbox`), `Hybrid-Coexistence-B.md`.
