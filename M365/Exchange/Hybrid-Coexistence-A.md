# Exchange Hybrid Coexistence — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Exchange Hybrid Classic and Modern topologies
- HCW (Hybrid Configuration Wizard) issues and re-runs
- Free/Busy and calendar sharing between on-prem and Exchange Online
- SMTP mail flow (on-prem ↔ EXO) in both directions
- Shared namespace mail routing (split domain)
- Mailbox migrations (on-prem to EXO, EXO to on-prem)
- OAuth (Modern Authentication) for hybrid features
- Directory synchronization impact on hybrid mail flow

**Does not cover:**
- Standalone Exchange Online configuration (no hybrid)
- Exchange 2010 (EOL) hybrid — unsupported
- Cross-forest hybrid (separate Active Directory forests)

**Assumptions:**
- On-premises Exchange Server 2016 CU23+, 2019 CU12+, or Subscription Edition (SE)
- Microsoft Entra Connect (formerly Azure AD Connect) is configured and syncing
- Admin has both on-premises Exchange and Exchange Online management access
- Hybrid Configuration Wizard was run to establish hybrid

---
## How It Works

<details><summary>Full architecture — Exchange Hybrid coexistence</summary>

**Exchange Hybrid** is a federation between on-premises Exchange and Exchange Online that makes both environments appear as a single organization to end users.

### Core Components

```
On-Premises Side                          Exchange Online Side
─────────────────────────────────────────────────────────────
Exchange Server (2016/2019/SE)            Exchange Online tenant
  ├── Edge Transport (optional)             ├── EXO connector (inbound from on-prem)
  ├── Hybrid Server (designated)            ├── EXO connector (outbound to on-prem)
  ├── Send Connector → EXO                 └── Microsoft 365 services
  ├── Receive Connector ← EXO
  ├── HybridConfiguration object
  └── Autodiscover published externally

Entra Connect (AAD Connect)
  └── Syncs mailbox objects → mail users in EXO
       └── Maintains ExchangeGuid, LegacyExchangeDN, proxyAddresses
```

### Classic vs. Modern Hybrid

| Feature | Classic Hybrid | Modern Hybrid (HMA) |
|---------|---------------|---------------------|
| Authentication | Basic/NTLM via federation trust | OAuth 2.0 / Modern Auth |
| Free/Busy | Exchange Web Services (EWS) | EWS with OAuth token |
| Mailbox migration | MRS Proxy via EWS | MRS Proxy with OAuth |
| Minimum Exchange | 2013 | 2016 CU18+ / 2019 |
| Certificate requirement | Wildcard/SAN cert for federated auth | Entra ID handles auth |

### Mail Flow Paths

**On-prem → EXO:**
```
On-prem sender
  → On-prem Exchange (HUB/CAS)
    → Send connector targeting EXO (smtp.office365.com:587 or MX)
      → EXO inbound connector (validates TLS cert CN = on-prem Hybrid server)
        → EXO recipient mailbox
```

**EXO → On-prem:**
```
EXO sender
  → EXO outbound connector (routes to on-prem MX or smart host)
    → On-prem MX record / Edge server
      → On-prem receive connector
        → On-prem recipient mailbox
```

**Free/Busy lookup:**
```
EXO user requests F/B for on-prem user
  → EXO queries Availability Service
    → Routes via federation/OAuth to on-prem EWS
      → On-prem Exchange returns F/B data
        → EXO displays in Outlook/OWA
```

### The HybridConfiguration Object

Running HCW creates/updates the `HybridConfiguration` object in on-prem Exchange AD. This object stores:
- Hybrid domains (your SMTP namespaces participating in hybrid)
- Send/Receive connector references
- TLS certificate thumbprint
- Federation Trust reference
- On-prem Exchange versions involved

```powershell
# View HybridConfiguration object
Get-HybridConfiguration | Format-List
```

### Entra Connect — Critical Role

Entra Connect is not optional for hybrid — it's the directory foundation:
- **Mail users** are created in EXO for every on-prem mailbox
- **ExchangeGuid** must match between on-prem and EXO for migration
- **LegacyExchangeDN** and **proxyAddresses** must be synchronized correctly
- Sync failures = hybrid mail flow failures, migration failures, F/B failures

</details>

---
## Dependency Stack

```
Active Directory (on-premises)
  └── Exchange Server installed (2016/2019/SE with latest CUs)
        └── Entra Connect syncing AD objects to Entra ID
              └── Exchange Online tenant configured (verified domain)
                    └── HCW run successfully (HybridConfiguration object exists)
                          ├── On-prem Send Connector → EXO (TLS, cert matching)
                          ├── On-prem Receive Connector ← EXO (TLS, IP restriction)
                          ├── EXO Inbound Connector (validates on-prem cert CN)
                          ├── EXO Outbound Connector (routes to on-prem smart host/MX)
                          ├── Autodiscover DNS (external, points to on-prem for on-prem mailboxes)
                          └── OAuth configured (for Modern Hybrid)
                                └── Free/Busy working (EWS accessible externally)
                                      └── MRS Proxy enabled (for mailbox migrations)
                                            └── Mail flow ↔ operational
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Free/Busy shows "No information" for cross-premises users | OAuth broken; EWS unreachable; Autodiscover failure | `Test-OAuthConnectivity`, EWS URL, Autodiscover |
| Mail stuck in on-prem queue destined for EXO | Send connector misconfigured; TLS cert mismatch; EXO rejecting | Queue viewer, send connector TLS cert |
| Mail stuck in EXO, not delivered to on-prem | Outbound connector routing issue; on-prem receive connector rejecting | EXO message trace, on-prem receive connector |
| Mailbox migration fails with "MRSProxy not enabled" | MRS Proxy not enabled on on-prem CAS | EWS virtual directory MRSProxyEnabled |
| Migration fails with "ExchangeGuid mismatch" | Entra Connect not syncing ExchangeGuid; value was manually set incorrectly | Get-RemoteMailbox, Get-Mailbox comparison |
| NDR 550 5.1.x for EXO recipient from on-prem | On-prem can't route to EXO; recipient policy issue | Accepted domains, send connector |
| NDR 550 5.1.x for on-prem recipient from EXO | On-prem MX not reachable; recipient not in AD; proxy address issue | MX record, mail user object in EXO |
| Autodiscover returns EXO config to on-prem mailbox users | SCP not set; Autodiscover DNS override missing | Set-ClientAccessService, Autodiscover DNS |
| OAuth test fails with "401 Unauthorized" | IntraOrganizationConnector not configured; OAuth cert expired | Test-OAuthConnectivity, Get-AuthConfig |
| HCW fails during run | Exchange server not up-to-date (CU); port blocked; permissions missing | CU level, firewall, org management role |

---
## Validation Steps

**Step 1 — Verify HybridConfiguration object exists and is populated**
```powershell
# On-premises Exchange PowerShell
Get-HybridConfiguration | Select-Object Domains, Guid, ClientAccessServers, `
    EdgeTransportServers, ReceivingTransportServers, SendingTransportServers,
    TLSCertificateName, OnPremisesSmartHost
```
Expected: Populated fields. Domains should include your SMTP namespaces.  
Bad: Null/empty — HCW was never completed or the object was corrupted.

**Step 2 — Test OAuth connectivity (Modern Hybrid)**
```powershell
# On-premises Exchange PowerShell
Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com/ews/exchange.asmx `
    -Mailbox <on-prem-mailbox@domain.com> -Verbose | Format-List
```
Expected: `ResultType = Success`.  
Bad: `401 Unauthorized`, `CorrelationID in header` — OAuth not configured or certificate issue.

**Step 3 — Test Free/Busy from EXO to on-prem**
```powershell
# Exchange Online PowerShell
Test-MAPIConnectivity -Identity <exo-mailbox@domain.com>

# More specific F/B test:
Get-AvailabilityConfig
# Check: OrgWideAccount and PerUserFreeBusy settings
```

**Step 4 — Test mail flow on-prem → EXO**
```powershell
# On-premises Exchange PowerShell
Send-MailMessage -From "test@<yourdomain.com>" -To "<exo-user@yourdomain.com>" `
    -Subject "Hybrid Test $(Get-Date)" -SmtpServer localhost -Body "Hybrid mail flow test"

# Check queue
Get-Queue | Where-Object { $_.Status -ne "Ready" } | Select-Object Identity, Status, MessageCount, NextHopDomain
```

**Step 5 — Verify connectors**
```powershell
# On-premises:
Get-SendConnector | Where-Object { $_.AddressSpaces -like "*office365*" -or $_.Name -like "*hybrid*" } |
    Select-Object Name, Enabled, TlsAuthLevel, TlsDomain, SmartHosts, AddressSpaces

Get-ReceiveConnector | Where-Object { $_.Name -like "*hybrid*" -or $_.Name -like "*EOP*" } |
    Select-Object Name, Enabled, Bindings, RemoteIPRanges, AuthMechanism

# Exchange Online PowerShell:
Get-InboundConnector | Where-Object { $_.ConnectorType -eq "OnPremises" } |
    Select-Object Name, Enabled, RequireTls, TlsSenderCertificateName, SenderIPAddresses

Get-OutboundConnector | Where-Object { $_.ConnectorType -eq "OnPremises" } |
    Select-Object Name, Enabled, TlsSettings, SmartHosts, RecipientDomains
```

**Step 6 — Verify MRS Proxy for migrations**
```powershell
# On-premises Exchange PowerShell
Get-WebServicesVirtualDirectory | Select-Object Server, Name, InternalURL, ExternalURL, MRSProxyEnabled
```
Expected: `MRSProxyEnabled = True` on CAS servers used for migration.

**Step 7 — Check Autodiscover for on-prem mailbox users**
```powershell
# On-premises Exchange PowerShell
Get-ClientAccessService | Select-Object Name, AutoDiscoverServiceInternalUri
# Internal SCP should point to on-prem Autodiscover URL, not EXO

# External DNS (run from outside network):
Resolve-DnsName autodiscover.<yourdomain.com> -Type CNAME
# Should point to on-prem (not autodiscover.outlook.com) for on-prem mailbox users
# OR use Autodiscover redirect/SRV record
```

---
## Troubleshooting Steps (by phase)

### Phase 1: Mail Flow Issues

**On-prem → EXO delivery failure:**
1. On-prem: `Get-Queue | Where Status -ne "Ready"` — identify stuck queue
2. Open queue viewer — check next hop domain and error message
3. Common errors:
   - `421 4.4.2` — TLS negotiation failure → cert CN mismatch or cert expired
   - `554 5.6.0` — Message encoding issue
   - `550 5.1.0` — Recipient not found in EXO
4. Check EXO inbound connector: is the on-prem certificate CN in `TlsSenderCertificateName`?
5. Check on-prem cert: `Get-ExchangeCertificate | Where-Object { $_.Services -like "*SMTP*" }`

**EXO → On-prem delivery failure:**
1. EXO: Message trace in admin.microsoft.com → Exchange admin center → Mail flow → Message trace
2. Check EXO outbound connector routing destination (smart host or MX)
3. Test on-prem receive connector is accepting EXO IP ranges (EOP IP ranges change — use service tag)
4. Check on-prem accepted domains: `Get-AcceptedDomain` — your domain must be listed

### Phase 2: Free/Busy Failures

1. Run `Test-OAuthConnectivity` — if fails, OAuth is the issue
2. Check OAuth certificate:
```powershell
Get-AuthConfig | Select-Object CurrentCertificateThumbprint
Get-ExchangeCertificate -Thumbprint <thumbprint> | Select-Object NotAfter, Status
# If expired → replace OAuth certificate
```
3. Check IntraOrganizationConnector:
```powershell
# Both on-prem and EXO:
Get-IntraOrganizationConnector | Format-List
# DiscoveryEndpoint should be populated and Enabled = True
```
4. Check AvailabilityAddressSpace:
```powershell
# On-prem:
Get-AvailabilityAddressSpace | Format-List
# Should have entry for your EXO domain
```
5. Test EWS connectivity from outside:
```powershell
Invoke-WebRequest -Uri "https://mail.<yourdomain.com>/ews/exchange.asmx" -UseBasicParsing |
    Select-Object StatusCode
```

### Phase 3: Migration Issues

**ExchangeGuid mismatch:**
```powershell
# On-prem:
$onPremGuid = (Get-Mailbox <alias>).ExchangeGuid

# EXO:
$exoGuid = (Get-MailUser <alias>).ExchangeGuid

if ($onPremGuid -ne $exoGuid) {
    Write-Warning "ExchangeGuid mismatch: on-prem=$onPremGuid EXO=$exoGuid"
    # Fix: set EXO mail user's ExchangeGuid to match on-prem
    # Set-MailUser -Identity <alias> -ExchangeGuid $onPremGuid
    # WARNING: this must match — migration will fail otherwise
}
```

**MRS Proxy not enabled:**
```powershell
# Enable MRS Proxy on CAS servers
Set-WebServicesVirtualDirectory -Identity "<ServerName>\EWS (Default Web Site)" `
    -MRSProxyEnabled $true
# Restart IIS: iisreset /noforce
```

---
## Remediation Playbooks

<details><summary>Playbook 1 — Re-run HCW to fix broken hybrid configuration</summary>

HCW can be re-run at any time without disrupting mail flow. It updates configuration rather than rebuilding from scratch.

```
Pre-requisites:
- Exchange server at latest CU for its version (non-negotiable — HCW checks)
- Global Admin + Organization Management role
- Outbound 443 from on-prem Exchange server to *.office365.com, *.outlook.com
- Inbound 443 to on-prem EWS (for Autodiscover/F-B)

Process:
1. Download HCW from: https://microsoft.com/download/details.aspx?id=45372
2. Run on the on-prem Exchange server (or admin workstation with Exchange tools)
3. Select "Use Express Settings" for standard hybrid
4. Complete wizard — it will update connectors, OAuth, and HybridConfiguration object

Post-run checks:
```
```powershell
Get-HybridConfiguration | Format-List
Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com/ews/exchange.asmx `
    -Mailbox <onprem-mailbox> -Verbose
Get-SendConnector | Where { $_.Name -like "*Outbound to Office 365*" } | Select Enabled, TlsAuthLevel
```

**Rollback:** Connectors are updated in-place. If HCW breaks something, export connector config before running and restore if needed.

</details>

<details><summary>Playbook 2 — Renew expired OAuth authentication certificate</summary>

OAuth auth between on-prem Exchange and EXO uses a certificate stored in the AuthConfig. This cert expires every 5 years by default but can expire unexpectedly.

```powershell
# Step 1: Check current OAuth cert status
$authConfig = Get-AuthConfig
$thumbprint = $authConfig.CurrentCertificateThumbprint
$cert = Get-ExchangeCertificate -Thumbprint $thumbprint -ErrorAction SilentlyContinue

if ($cert) {
    Write-Host "OAuth cert expires: $($cert.NotAfter)"
    if ($cert.NotAfter -lt (Get-Date).AddDays(30)) {
        Write-Warning "Certificate expires in less than 30 days — renew now!"
    }
} else {
    Write-Warning "OAuth cert not found by thumbprint — likely expired/removed"
}

# Step 2: Create new self-signed certificate for OAuth
$newCert = New-ExchangeCertificate -KeySize 2048 -PrivateKeyExportable $false `
    -Services None -SubjectName "CN=Microsoft Exchange Server Auth Certificate" `
    -DomainName "microsoft.com" -FriendlyName "Microsoft Exchange Server Auth Certificate"

Write-Host "New cert thumbprint: $($newCert.Thumbprint)"

# Step 3: Update AuthConfig to use new cert (takes effect in 48 hours via scheduled task)
Set-AuthConfig -NewCertificateThumbprint $newCert.Thumbprint -NewCertificateEffectiveDate (Get-Date)

# Step 4: Publish the new OAuth cert to EXO immediately (don't wait 48 hours)
Set-AuthConfig -PublishCertificate

# Step 5: Clear OAuth token cache
Set-AuthConfig -ClearPreviousCertificate

# Step 6: Verify
Get-AuthConfig | Select-Object CurrentCertificateThumbprint, PreviousCertificateThumbprint
Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com/ews/exchange.asmx `
    -Mailbox <onprem-mailbox> -Verbose
```

**Rollback:** Previous certificate thumbprint is stored — `Set-AuthConfig` can roll back to previous thumbprint if needed.

</details>

<details><summary>Playbook 3 — Fix ExchangeGuid mismatch blocking migrations</summary>

```powershell
# Step 1: Identify the mismatch
$alias = "<user-alias>"

$onPremMailbox = Get-Mailbox -Identity $alias -ErrorAction SilentlyContinue
$exoMailUser = Get-MailUser -Identity $alias -ErrorAction SilentlyContinue  # Run in EXO PowerShell

if ($onPremMailbox -and $exoMailUser) {
    $onPremGuid = $onPremMailbox.ExchangeGuid
    $exoGuid = $exoMailUser.ExchangeGuid

    Write-Host "On-prem ExchangeGuid: $onPremGuid"
    Write-Host "EXO ExchangeGuid: $exoGuid"

    if ($onPremGuid -ne $exoGuid) {
        Write-Warning "MISMATCH DETECTED"
    } else {
        Write-Host "GUIDs match — not a GUID issue" -ForegroundColor Green
    }
}

# Step 2: Fix — set EXO mail user to match on-prem GUID
# ⚠️ Run in Exchange Online PowerShell
# Set-MailUser -Identity $alias -ExchangeGuid $onPremGuid

# Step 3: Verify fix
# (Get-MailUser -Identity $alias).ExchangeGuid  # Should now match on-prem

# Step 4: Wait for Entra Connect sync cycle to propagate (~30 min)
# Then retry migration
```

⚠️ **Warning:** Only change the EXO MailUser's ExchangeGuid to match on-prem. Never change the on-prem mailbox ExchangeGuid on an active mailbox — this can cause data loss.

**Rollback:** Restore previous EXO MailUser ExchangeGuid value (note it before changing).

</details>

<details><summary>Playbook 4 — Fix split-brain Autodiscover serving EXO config to on-prem users</summary>

On-prem mailbox users must get on-prem Autodiscover — not autodiscover.outlook.com.

```powershell
# Step 1: Check SCP (Service Connection Point) in AD — used by domain-joined clients
Get-ClientAccessService | Select-Object Name, AutoDiscoverServiceInternalUri
# Should be https://mail.<yourdomain.com>/Autodiscover/Autodiscover.xml (on-prem URL)

# Step 2: Check external DNS — used by non-domain or mobile clients
# This must resolve to on-prem, OR use a redirect/SRV record
# External DNS: autodiscover.<yourdomain.com> → on-prem CAS/Load balancer IP

# Step 3: If Autodiscover DNS points to EXO (autodiscover.outlook.com CNAME):
# Add exclusion redirect on EXO:
# EXO PowerShell: Set-AutoDiscoverVirtualDirectory doesn't apply here
# Instead, use on-prem Autodiscover redirect to handle the response for on-prem users

# Step 4: On-prem — configure Autodiscover redirect
Set-ClientAccessService -Identity <ServerName> `
    -AutoDiscoverServiceInternalUri "https://autodiscover.<yourdomain.com>/Autodiscover/Autodiscover.xml"

# Step 5: Verify Autodiscover response for an on-prem mailbox (use Microsoft Remote Connectivity Analyzer)
# https://testconnectivity.microsoft.com → Exchange → Outlook Autodiscover
```

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Exchange Hybrid diagnostic evidence for escalation
.NOTES     Run from on-premises Exchange PowerShell (admin). Requires EXO session open in same shell for cross-premises data.
#>

$reportPath = "C:\Temp\ExHybrid-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

# HybridConfiguration
Get-HybridConfiguration | Format-List | Out-File "$reportPath\01-HybridConfiguration.txt"

# Send and Receive connectors (on-prem)
Get-SendConnector | Format-List | Out-File "$reportPath\02-SendConnectors.txt"
Get-ReceiveConnector | Format-List | Out-File "$reportPath\03-ReceiveConnectors.txt"

# EXO connectors (requires EXO connection)
try {
    Get-InboundConnector | Format-List | Out-File "$reportPath\04-EXO-InboundConnectors.txt"
    Get-OutboundConnector | Format-List | Out-File "$reportPath\05-EXO-OutboundConnectors.txt"
} catch { "EXO connection not available" | Out-File "$reportPath\04-EXO-Connectors-SKIPPED.txt" }

# OAuth config
Get-AuthConfig | Format-List | Out-File "$reportPath\06-AuthConfig.txt"

# IntraOrganizationConnector (both sides)
Get-IntraOrganizationConnector | Format-List | Out-File "$reportPath\07-IntraOrgConnector-OnPrem.txt"
try {
    Get-IntraOrganizationConnector | Format-List | Out-File "$reportPath\07-IntraOrgConnector-EXO.txt"
} catch {}

# Certificates
Get-ExchangeCertificate | Select-Object Thumbprint, NotBefore, NotAfter, Services, Subject, Status |
    Format-Table | Out-File "$reportPath\08-Certificates.txt"

# AvailabilityAddressSpace
Get-AvailabilityAddressSpace | Format-List | Out-File "$reportPath\09-AvailabilityAddressSpace.txt"

# Web Services VDir (MRS Proxy)
Get-WebServicesVirtualDirectory | Select-Object Server, Name, InternalURL, ExternalURL, MRSProxyEnabled |
    Format-Table | Out-File "$reportPath\10-WebServicesVDir.txt"

# Accepted Domains
Get-AcceptedDomain | Format-Table | Out-File "$reportPath\11-AcceptedDomains.txt"

# OAuth Test
Write-Host "Running OAuth connectivity test (may take 30s)..." -ForegroundColor Cyan
$testMailbox = Read-Host "Enter an on-premises mailbox UPN for OAuth test (or press Enter to skip)"
if ($testMailbox) {
    Test-OAuthConnectivity -Service EWS `
        -TargetUri "https://outlook.office365.com/ews/exchange.asmx" `
        -Mailbox $testMailbox -Verbose 2>&1 | Out-File "$reportPath\12-OAuthTest.txt"
}

# Message queue
Get-Queue | Where-Object { $_.Status -ne "Ready" } |
    Format-Table | Out-File "$reportPath\13-MessageQueues.txt"

# Package
$zipPath = "C:\Temp\ExHybrid-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').zip"
Compress-Archive -Path $reportPath -DestinationPath $zipPath -Force
Write-Host "Evidence collected: $zipPath" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| View hybrid config | `Get-HybridConfiguration \| Format-List` |
| Test OAuth | `Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com/ews/exchange.asmx -Mailbox <upn>` |
| Check Auth cert | `Get-AuthConfig \| Select CurrentCertificateThumbprint` |
| View on-prem send connectors | `Get-SendConnector \| Select Name, Enabled, SmartHosts, AddressSpaces` |
| View EXO inbound connectors | `Get-InboundConnector \| Select Name, Enabled, TlsSenderCertificateName` |
| Check message queue | `Get-Queue \| Where Status -ne "Ready"` |
| Check Exchange certs | `Get-ExchangeCertificate \| Select Thumbprint, NotAfter, Services, Subject` |
| Enable MRS Proxy | `Set-WebServicesVirtualDirectory "<Server>\EWS (Default Web Site)" -MRSProxyEnabled $true` |
| Check MRS Proxy | `Get-WebServicesVirtualDirectory \| Select Server, MRSProxyEnabled` |
| View availability config | `Get-AvailabilityAddressSpace \| Format-List` |
| IntraOrg connector | `Get-IntraOrganizationConnector \| Format-List` |
| Check accepted domains | `Get-AcceptedDomain \| Format-Table` |
| Force mailbox migration | `New-MoveRequest -Identity <alias> -Remote -RemoteHostName <onprem-cas-fqdn> -RemoteCredential $cred -TargetDeliveryDomain <tenant>.mail.onmicrosoft.com` |
| Check EXO mail user ExchangeGuid | `Get-MailUser <alias> \| Select ExchangeGuid` (EXO PS) |
| Fix ExchangeGuid | `Set-MailUser <alias> -ExchangeGuid <onprem-guid>` (EXO PS) |

---
## 🎓 Learning Pointers

- **Hybrid is not a single thing — it's a collection of interdependent features.** Mail flow, Free/Busy, migrations, and Autodiscover are all separate mechanisms that happen to work together in a hybrid. When "hybrid is broken," identify *which feature* is broken before diving in. Each has its own dependency chain and OAuth/auth requirements.
- **The HybridConfiguration object is ground truth for hybrid connectors.** If connectors get manually modified and drift from HCW's intent, re-running HCW restores them. Always check `Get-HybridConfiguration` before assuming a connector issue is a one-off — it might be systematic.
- **OAuth certificate expiry silently breaks Free/Busy and migrations** — there's no alert in the portal when the Auth cert expires. Build a monitoring check: `(Get-ExchangeCertificate -Thumbprint (Get-AuthConfig).CurrentCertificateThumbprint).NotAfter`. Alert 60+ days before expiry. [OAuth configuration](https://learn.microsoft.com/en-us/exchange/configure-oauth-authentication-between-exchange-and-exchange-online-organizations-exchange-2013-help).
- **ExchangeGuid is the migration contract.** The on-prem mailbox and the EXO mail user must have matching ExchangeGuid values for a mailbox move to succeed. Entra Connect maintains this sync — if it breaks, migrations break. The fix is always to correct the EXO mail user's GUID to match on-prem, never the other way around.
- **EOP IP ranges change.** The EXO → on-prem receive connector's `RemoteIPRanges` should use Exchange Online Protection (EOP) IP ranges. These are published at [Office 365 IP and URLs](https://learn.microsoft.com/en-us/microsoft-365/enterprise/urls-and-ip-address-ranges) and change periodically. Use the O365 IP Address Change notification service to stay current.
- **Microsoft Remote Connectivity Analyzer (RCA)** at testconnectivity.microsoft.com is the best external tool for hybrid validation — it tests Autodiscover, EWS, MRS Proxy, OAuth, and SMTP from Microsoft's infrastructure (as EXO would see your on-prem environment). Run it before and after any hybrid change. [RCA](https://testconnectivity.microsoft.com).
