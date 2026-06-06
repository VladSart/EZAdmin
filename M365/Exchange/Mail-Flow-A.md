# Exchange Online Mail Flow — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what. Covers EXO-only and hybrid mail flow, transport pipeline internals, connector architecture, and MTA-STS.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How Mail Flow Works](#how-mail-flow-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

| In scope | Out of scope |
|----------|-------------|
| Exchange Online (EXO) mail flow | On-premises Exchange only |
| Hybrid mail flow (centralized + decentralized) | SMTP relay from non-Microsoft devices (see separate runbook) |
| Inbound/outbound connectors (custom routing) | Shared Mailbox delegation (see SharedMailbox-B.md) |
| Transport rules (ETRs) | Litigation Hold / eDiscovery |
| EOP anti-spam/anti-malware pipeline | Teams-specific calling / Chat delivery |
| MTA-STS, SPF, DKIM, DMARC | Third-party SEG (check SEG logs first) |

**Assumptions:**
- You have Exchange Online admin rights or Global Admin
- `ExchangeOnlineManagement` module v3+ installed: `Install-Module ExchangeOnlineManagement`
- If using hybrid: on-prem Exchange Management Shell also available
- `Connect-ExchangeOnline` already run in this session

---

## How Mail Flow Works

<details><summary>Full pipeline architecture (click to expand)</summary>

### Inbound Mail Path (external → EXO mailbox)

```
External MTA
    │
    ▼
[MX Record] ──▶ <tenant>.mail.protection.outlook.com (port 25)
    │
    ▼
[EOP Inbound Edge] ── Connection filtering (IP reputation, blocklists)
    │
    ▼
[EOP Anti-spam] ─────── SCL scoring, bulk mail threshold, safe/block lists
    │
    ▼
[EOP Anti-malware] ─── Attachment scanning, Safe Attachments (Defender P1/P2)
    │
    ▼
[Transport Rules] ───── ETRs evaluated in priority order (lower number = first)
    │
    ▼
[Data Loss Prevention] ─ DLP policy evaluation (if Purview licensed)
    │
    ▼
[Journaling] ────────── If journal rules configured
    │
    ▼
[Mailbox delivery] ─── Inbox rules → Junk folder → Clutter → Inbox
```

### Outbound Mail Path (EXO mailbox → external)

```
User sends from Outlook / OWA / API
    │
    ▼
[EXO Submission] ─── SMTP AUTH or Graph / MAPI
    │
    ▼
[Transport Rules] ─── ETRs evaluated
    │
    ▼
[DLP] ─────────────── Policy enforcement
    │
    ▼
[Outbound spam] ────── High-risk delivery pool if sender flagged
    │
    ▼
[Outbound connector check]
    │
    ├── No matching connector → Direct send via MX (UseMXRecord = $true)
    │
    └── Matching connector → Smart host / partner org / on-prem hybrid
    │
    ▼
[Safe Links wrapping] ── Defender for Office 365 P1/P2
    │
    ▼
External MTA
```

### Hybrid Centralised Routing (Edge Transport via on-prem)

When `CentralisedMailTransport` is enabled (common in hybrid), **all** outbound mail routes through on-prem Exchange first:

```
EXO → Outbound connector (on-prem smart host) → On-prem HUB → External
```

Benefits: On-prem journaling, compliance, DLP applied to EXO traffic.  
Risk: On-prem outage = EXO outbound blocked.

### Hybrid Decentralised Routing (direct send)

Each environment (EXO + on-prem) sends outbound directly:

```
EXO  ──── direct ────▶ External
On-prem ── direct ───▶ External
```

Benefits: EXO not dependent on on-prem for outbound.  
Risk: Split SPF/DKIM signing — both IP ranges must be in SPF.

</details>

---

## Dependency Stack

```
┌─────────────────────────────────────────────┐
│              Client Application             │  Outlook, OWA, iOS Mail, Teams
├─────────────────────────────────────────────┤
│         Exchange Online Mailbox             │  Mailbox rules, Junk threshold
├─────────────────────────────────────────────┤
│        Transport Pipeline (EXO)             │  ETRs, DLP, journaling
├─────────────────────────────────────────────┤
│      Exchange Online Protection (EOP)       │  Anti-spam, anti-malware, connectors
├─────────────────────────────────────────────┤
│       Inbound / Outbound Connectors         │  Custom routing, partner TLS
├─────────────────────────────────────────────┤
│   DNS (MX, SPF, DKIM CNAME, DMARC TXT)     │  External resolvers
├─────────────────────────────────────────────┤
│    On-premises Exchange (hybrid only)       │  HubTransport, Edge, Send/Receive connectors
├─────────────────────────────────────────────┤
│          Microsoft 365 Auth                 │  Entra ID, OAuth tokens for SMTP AUTH
└─────────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| External → user: mail not arriving | MX wrong, spam filtered, ETR blocking | `Resolve-DnsName`, `Get-MessageTrace` |
| External → user: delayed (30+ min) | EOP queue, recipient domain MX degraded, greylisting | `Get-MessageTrace` Status=Pending |
| Internal → external: NDR 5.7.64 | `TrustedArcSealers` mismatch or ARC seal failure | EAC > Mail flow > Connectors |
| Internal → external: NDR 5.7.1 | Relay denied — SMTP AUTH issue or connector mismatch | `Get-OutboundConnector`, check sender domain |
| NDR 5.4.1 | Recipient address doesn't exist in target system | `Get-Recipient`, `Get-RemoteDomain` |
| NDR 5.1.8 | Sender's IP on outbound spam block list | Check high-risk delivery pool / tenant reputation |
| Hybrid: mail stuck on-prem | On-prem connector to EXO broken (cert, TLS) | On-prem: `Test-MigrationServerAvailability` |
| Hybrid: EXO → on-prem fails | Outbound connector TLS mismatch or smart host unreachable | `Get-OutboundConnector`, on-prem receive connector |
| ETR not firing | Wrong conditions, wrong scope (inbound vs outbound), wrong priority | `Get-TransportRule | Select Name,State,Priority,Conditions` |
| Safe Attachments blocking | Defender for O365 P1 policy — attachment detonation positive | Defender portal > Policies > Safe Attachments |
| SPF fail / DMARC reject | Sending IP not in SPF record, DKIM not signing | `nslookup -type=TXT <domain>`, Check-SPF |
| Mail loop (loop detected NDR) | ETR redirecting back to sender or MX pointing to on-prem which routes back | Trace full ETR chain, check MX |

---

## Validation Steps

**1. Verify MX record**
```powershell
Resolve-DnsName -Name <recipientdomain.com> -Type MX | Select NameExchange, Preference
# Good: <tenant>.mail.protection.outlook.com (priority typically 0 or 10)
# Bad:  anything else as primary MX in EXO-only setup
```

**2. Trace the message**
```powershell
Connect-ExchangeOnline -UserPrincipalName <admin@domain.com>

$trace = Get-MessageTrace `
  -SenderAddress <sender@domain.com> `
  -RecipientAddress <recipient@domain.com> `
  -StartDate (Get-Date).AddHours(-48) `
  -EndDate (Get-Date)
$trace | Select Received, Status, Subject, ToIP, FromIP | Format-Table -AutoSize

# Get full event chain for a specific message
Get-MessageTraceDetail -MessageTraceId $trace[0].MessageTraceId `
  -RecipientAddress <recipient@domain.com> | Select Date, Event, Action, Detail | Format-Table -Wrap
# Good: final event = "Delivered" or "Expanded" (group)
# Bad:  "FilteredAsSpam", "Failed", stuck at "InboundConnectorReceive" with no delivery
```

**3. Check active transport rules**
```powershell
Get-TransportRule | Where-Object { $_.State -eq "Enabled" } |
  Select Priority, Name, Mode, @{n='Conditions';e={$_.Conditions -join ', '}} |
  Sort-Object Priority | Format-Table -Wrap
# Bad: rule with Redirect or Delete action matching message characteristics
```

**4. Validate SPF**
```powershell
# Run from external machine or PowerShell with internet access
$domain = "<yourdomain.com>"
Resolve-DnsName -Name $domain -Type TXT | Where-Object { $_.Strings -like "*v=spf1*" }
# Good: contains all sending IPs/includes; ends with -all (hard fail) or ~all (soft fail)
# Bad:  IP of sending server not present; multiple SPF records (only 1 allowed)
```

**5. Validate DKIM**
```powershell
# Check DKIM signing config in EXO
Get-DkimSigningConfig | Select Domain, Enabled, Status, Selector1CNAME, Selector2CNAME
# Good: Enabled=$true, Status=Valid
# Bad:  Status=CnameMissing — CNAME not in DNS yet; Status=KeyMissing

# Verify CNAME resolves in DNS
Resolve-DnsName -Name "selector1._domainkey.<yourdomain.com>" -Type CNAME
```

**6. Check connectors**
```powershell
Get-InboundConnector  | Select Name, Enabled, ConnectorType, TlsSenderCertificateName, RequireTls
Get-OutboundConnector | Select Name, Enabled, ConnectorType, SmartHosts, UseMXRecord, TlsSettings
# Good: all connectors Enabled matching their documented purpose
# Bad:  TlsSenderCertificateName mismatch (cert name ≠ cert on sending server)
```

**7. Hybrid: test on-prem → EXO send connector**
```powershell
# On-premises Exchange Management Shell
Test-MigrationServerAvailability -ExchangeRemoteMove -RemoteServer outlook.office365.com
# Good: Result = Success
# Bad:  Timeout or certificate error → check send connector TLS cert name
```

---

## Troubleshooting Steps by Phase

### Phase 1 — Confirm where mail died (5 min)

1. Run `Get-MessageTrace` (see Validation Step 2).
2. If **no trace result at all**: mail never reached EOP. Check sender's outbound, MX record, and whether sender domain is being rejected at connection filter.
3. If **FilteredAsSpam**: skip to [Playbook 2](#playbook-2--false-positive-spam-remediation).
4. If **Failed + NDR code**: look up code in [Symptom → Cause Map](#symptom--cause-map), skip to relevant playbook.
5. If **Delivered**: problem is post-delivery (Inbox rules, Junk, OWA focus filter, Outlook add-ins). Skip to [Playbook 5](#playbook-5--post-delivery-misdirection).
6. If **trace shows delivery to on-prem** (hybrid): shift to on-prem Exchange queue investigation.

### Phase 2 — DNS health (2 min)

1. Verify MX (Validation Step 1).
2. If MX is wrong → fix at DNS registrar. Propagation: up to 48h, TTL-dependent.
3. Check SPF and DKIM (Validation Steps 4–5).
4. Check DMARC:
   ```powershell
   Resolve-DnsName -Name "_dmarc.<domain.com>" -Type TXT
   # p=none = monitoring only; p=quarantine or p=reject = enforcement
   ```

### Phase 3 — Connector & transport rule audit (5 min)

1. Run Validation Steps 3 and 6.
2. Confirm no ETR is inadvertently matching the affected messages.
3. If inbound connector uses partner TLS (`ConnectorType = Partner`), verify sender's certificate subject matches `TlsSenderCertificateName`.
4. For outbound issues: confirm the right connector is selected (connector has `SenderDomains` or `SenderIPAddresses` that matches).

### Phase 4 — Anti-spam & Defender review (5 min)

1. Check EOP quarantine for filtered messages:
   ```powershell
   Get-QuarantineMessage -RecipientAddress <user@domain.com> |
     Select ReceivedTime, SenderAddress, Subject, QuarantineTypes | Format-Table -AutoSize
   ```
2. Check Defender for Office 365 Safe Attachments/Safe Links policy in the Defender portal if P1/P2 licensed.
3. Bulk complaint level (BCL) and spam confidence level (SCL) visible in message headers: `X-Microsoft-Antispam: BCL:X; SCL:X`.

### Phase 5 — Hybrid-specific investigation

1. Check on-prem HubTransport queue:
   ```powershell
   # On-prem Exchange Management Shell
   Get-Queue | Where-Object { $_.MessageCount -gt 0 } | Select Identity, DeliveryType, Status, MessageCount, NextHopDomain
   Get-Message -Queue "<ServerName>\<QueueIdentity>" | Select FromAddress, Recipients, Status, LastError
   ```
2. Verify hybrid send connector certificate:
   ```powershell
   Get-SendConnector | Select Name, TlsAuthLevel, TlsDomain, SmartHosts
   # TlsDomain must match Subject/SAN on the TLS cert presented by EXO (outlook.office365.com or *.mail.protection.outlook.com)
   ```
3. Verify HCW (Hybrid Configuration Wizard) was re-run after cert renewal.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Release / allow-list a quarantined message</summary>

**When:** `Get-MessageTrace` shows FilteredAsSpam; user never received message.

```powershell
# Find the quarantined message
$q = Get-QuarantineMessage -RecipientAddress <user@domain.com> |
     Where-Object { $_.SenderAddress -eq "<sender@external.com>" } |
     Select -First 1

# Release to mailbox
Release-QuarantineMessage -Identity $q.Identity -User <user@domain.com>

# Add sender to tenant allow list (safe senders) — 30-day expiry, extend in EAC if needed
New-TenantAllowBlockListItems -ListType Sender -Allow -Entries "<sender@external.com>" -Notes "Allow-listed after false positive"

# Verify
Get-TenantAllowBlockListItems -ListType Sender | Where-Object { $_.Value -like "*external.com*" }
```

**Rollback:** `Remove-TenantAllowBlockListItems` with the item Identity.

</details>

<details><summary>Playbook 2 — False positive spam remediation</summary>

**When:** Legitimate mail consistently marked as spam despite allow-listing.

```powershell
# Check current anti-spam policy
Get-HostedContentFilterPolicy | Select Name, SpamAction, HighConfidenceSpamAction, BulkThreshold, AllowedSenders, AllowedSenderDomains

# Lower bulk threshold for specific policy (default=7; lower = more aggressive filtering)
# To REDUCE false positives, raise threshold (e.g. to 9):
Set-HostedContentFilterPolicy -Identity <PolicyName> -BulkThreshold 9

# Add sender domain to allowed list in the policy (use with care — bypass all spam checks)
Set-HostedContentFilterPolicy -Identity <PolicyName> `
  -AllowedSenderDomains @{Add="<external-domain.com>"}
```

**Note:** `AllowedSenderDomains` bypasses spam scanning but NOT malware or Safe Attachments. Use `TenantAllowBlockListItems` for sender-level control with less blast radius.

**Rollback:** Revert `BulkThreshold` to original value. `Remove-HostedContentFilterPolicy` only if you created a new one.

</details>

<details><summary>Playbook 3 — Fix broken inbound connector (partner TLS)</summary>

**When:** External partner says mail bounces or gets rejected with TLS errors; `Get-MessageTrace` shows `ConnectorRejected` or no delivery.

```powershell
# Inspect the connector
Get-InboundConnector -Identity "<ConnectorName>" | Format-List *

# Key fields to verify:
# TlsSenderCertificateName — must match CN/SAN on partner's sending cert
# RequireTls               — $true means TLS mandatory
# SenderIPAddresses        — must include current sending IPs of partner

# Update cert name if partner renewed their cert:
Set-InboundConnector -Identity "<ConnectorName>" -TlsSenderCertificateName "<new-cert-subject>"

# Update IP if partner changed sending IP:
Set-InboundConnector -Identity "<ConnectorName>" -SenderIPAddresses @{Add="<new.ip.address>"}

# Test with message trace immediately after change
```

**Rollback:** Revert with previous cert name / IP. Changes take effect immediately — no restart required.

</details>

<details><summary>Playbook 4 — Repair DKIM signing</summary>

**When:** DMARC reports show DKIM=fail; `Get-DkimSigningConfig` shows Status=CnameMissing.

```powershell
# Step 1: Get the CNAME values EXO expects
Get-DkimSigningConfig -Identity <yourdomain.com> | Select Selector1CNAME, Selector2CNAME
# Example output:
# Selector1CNAME: selector1-yourdomain-com._domainkey.yourtenant.onmicrosoft.com
# Selector2CNAME: selector2-yourdomain-com._domainkey.yourtenant.onmicrosoft.com

# Step 2: Create these two CNAME records at your DNS registrar:
# Name:  selector1._domainkey.<yourdomain.com>   → Value: <Selector1CNAME output>
# Name:  selector2._domainkey.<yourdomain.com>   → Value: <Selector2CNAME output>

# Step 3: Wait for DNS propagation (TTL-dependent, test with nslookup)
Resolve-DnsName -Name "selector1._domainkey.<yourdomain.com>" -Type CNAME

# Step 4: Enable DKIM signing in EXO
Set-DkimSigningConfig -Identity <yourdomain.com> -Enabled $true

# Step 5: Verify
Get-DkimSigningConfig -Identity <yourdomain.com> | Select Status, Enabled
# Good: Status=Valid, Enabled=$true
```

**Rollback:** `Set-DkimSigningConfig -Enabled $false` — disables DKIM signing (DMARC will rely on SPF only).

</details>

<details><summary>Playbook 5 — Post-delivery misdirection (Junk / Inbox rules)</summary>

**When:** `Get-MessageTrace` shows `Delivered` but user can't find email.

```powershell
# Step 1: Check user's Inbox rules
Get-InboxRule -Mailbox <user@domain.com> | Select Name, Enabled, Priority, Conditions, Actions | Format-Table -Wrap

# Step 2: Check Junk folder (look via EAC or OWA — PowerShell can't easily enumerate Junk contents)
# Ask user to check Junk, Other (Focused inbox), and All Mail views

# Step 3: Check if Clutter is enabled (legacy — mostly Off for new tenants but can be on for old)
Get-Clutter -Identity <user@domain.com>
# If ClutterEnabled=$true and user is missing mail: Set-Clutter -Identity <user@domain.com> -Enable $false

# Step 4: Check mailbox audit logs for deletions
Search-MailboxAuditLog -Identity <user@domain.com> -LogonTypes Owner,Admin `
  -Operations HardDelete,SoftDelete,MoveToDeletedItems `
  -StartDate (Get-Date).AddDays(-2) -EndDate (Get-Date) |
  Select LastAccessed, Operation, FolderPath, SourceItemSubjects | Format-Table -Wrap

# Step 5: Search mailbox for the specific message
Search-Mailbox -Identity <user@domain.com> `
  -SearchQuery "subject:'<subject>' AND from:<sender@domain.com>" `
  -TargetMailbox <admin@domain.com> -TargetFolder "SearchResults" `
  -LogLevel Full
```

**Note:** `Search-Mailbox` is deprecated in favor of Compliance Search, but still works for this triage. Compliance Search requires eDiscovery permissions.

</details>

<details><summary>Playbook 6 — Hybrid outbound stuck in on-prem queue</summary>

**When:** On-prem queue has growing messages for EXO recipients; `NextHopDomain` = `<tenant>.mail.protection.outlook.com`.

```powershell
# On-prem Exchange Management Shell

# Step 1: Check the stuck queue
Get-Queue | Where-Object { $_.NextHopDomain -like "*.mail.protection.outlook.com" } |
  Select Identity, Status, MessageCount, LastError, NextRetryTime

# Step 2: Test TLS connectivity to EXO inbound
Test-SmtpConnectivity -Identity <SendConnectorName>

# Step 3: Check send connector cert
Get-SendConnector -Identity "<HybridSendConnector>" | Select TlsAuthLevel, TlsDomain, SmartHosts

# Step 4: If cert mismatch, update TlsDomain
Set-SendConnector -Identity "<HybridSendConnector>" -TlsDomain "*.mail.protection.outlook.com"

# Step 5: Force retry on stuck messages
Retry-Queue -Identity "<ServerName>\<QueueIdentity>"

# Step 6: Verify messages drain
Get-Queue | Where-Object { $_.NextHopDomain -like "*.mail.protection.outlook.com" } | Select Identity, MessageCount, Status
```

**Rollback:** Revert `TlsDomain` to previous value if retry fails and mail delivery breaks in new way.

</details>

---

## Evidence Pack

Run this script to collect all relevant data before escalating to Microsoft or a senior engineer:

```powershell
<#
.SYNOPSIS  Collect Exchange Online mail flow evidence for escalation
.NOTES     Run as Exchange admin. Requires ExchangeOnlineManagement module.
#>
param(
    [Parameter(Mandatory)][string]$SenderAddress,
    [Parameter(Mandatory)][string]$RecipientAddress,
    [string]$OutputPath = "$env:USERPROFILE\Desktop\MailFlowEvidence_$(Get-Date -Format yyyyMMdd_HHmm)"
)

Connect-ExchangeOnline -UserPrincipalName (Read-Host "Admin UPN")
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# 1. Message trace (last 48h)
Write-Host "[INFO] Collecting message trace..." -ForegroundColor Cyan
Get-MessageTrace -SenderAddress $SenderAddress -RecipientAddress $RecipientAddress `
  -StartDate (Get-Date).AddHours(-48) -EndDate (Get-Date) |
  Export-Csv "$OutputPath\MessageTrace.csv" -NoTypeInformation

# 2. Transport rules
Write-Host "[INFO] Collecting transport rules..." -ForegroundColor Cyan
Get-TransportRule | Where-Object { $_.State -eq "Enabled" } |
  Select Priority, Name, State, Mode, Conditions, Actions |
  Export-Csv "$OutputPath\TransportRules.csv" -NoTypeInformation

# 3. Connectors
Write-Host "[INFO] Collecting connectors..." -ForegroundColor Cyan
Get-InboundConnector  | Select * | Export-Csv "$OutputPath\InboundConnectors.csv"  -NoTypeInformation
Get-OutboundConnector | Select * | Export-Csv "$OutputPath\OutboundConnectors.csv" -NoTypeInformation

# 4. DKIM config
Write-Host "[INFO] Collecting DKIM config..." -ForegroundColor Cyan
Get-DkimSigningConfig | Select * | Export-Csv "$OutputPath\DkimSigningConfig.csv" -NoTypeInformation

# 5. Quarantine (last 48h for recipient)
Write-Host "[INFO] Collecting quarantine messages..." -ForegroundColor Cyan
Get-QuarantineMessage -RecipientAddress $RecipientAddress |
  Where-Object { $_.ReceivedTime -gt (Get-Date).AddHours(-48) } |
  Select * | Export-Csv "$OutputPath\QuarantineMessages.csv" -NoTypeInformation

# 6. Anti-spam policies
Get-HostedContentFilterPolicy | Select * | Export-Csv "$OutputPath\AntiSpamPolicies.csv" -NoTypeInformation
Get-HostedContentFilterRule    | Select * | Export-Csv "$OutputPath\AntiSpamRules.csv" -NoTypeInformation

# 7. DNS spot-check
Write-Host "[INFO] Checking DNS..." -ForegroundColor Cyan
$domain = $RecipientAddress.Split("@")[1]
$dns = @{
    MX    = (Resolve-DnsName -Name $domain -Type MX -ErrorAction SilentlyContinue).NameExchange
    SPF   = (Resolve-DnsName -Name $domain -Type TXT -ErrorAction SilentlyContinue | Where-Object { $_.Strings -like "*v=spf1*" }).Strings
    DMARC = (Resolve-DnsName -Name "_dmarc.$domain" -Type TXT -ErrorAction SilentlyContinue).Strings
}
$dns | ConvertTo-Json | Out-File "$OutputPath\DNS_SpotCheck.json"

Write-Host "[OK] Evidence collected at: $OutputPath" -ForegroundColor Green
Write-Host "[INFO] ZIP this folder and attach to your escalation ticket." -ForegroundColor Cyan
Disconnect-ExchangeOnline -Confirm:$false
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Connect to EXO | `Connect-ExchangeOnline -UserPrincipalName <admin@domain.com>` |
| Trace message (48h) | `Get-MessageTrace -SenderAddress <s> -RecipientAddress <r> -StartDate (Get-Date).AddHours(-48) -EndDate (Get-Date)` |
| Full event chain | `Get-MessageTraceDetail -MessageTraceId <guid> -RecipientAddress <r>` |
| Check MX | `Resolve-DnsName -Name <domain> -Type MX` |
| Check SPF | `Resolve-DnsName -Name <domain> -Type TXT \| Where { $_.Strings -like '*v=spf1*' }` |
| Check DKIM | `Get-DkimSigningConfig \| Select Domain, Enabled, Status` |
| List ETRs | `Get-TransportRule \| Select Priority, Name, State \| Sort Priority` |
| List connectors | `Get-InboundConnector; Get-OutboundConnector` |
| Quarantine search | `Get-QuarantineMessage -RecipientAddress <r>` |
| Release quarantine | `Release-QuarantineMessage -Identity <id> -User <r>` |
| Inbox rules | `Get-InboxRule -Mailbox <user>` |
| Tenant allow list | `New-TenantAllowBlockListItems -ListType Sender -Allow -Entries <sender>` |
| Anti-spam policy | `Get-HostedContentFilterPolicy \| Select Name, BulkThreshold, SpamAction` |
| On-prem queue | `Get-Queue \| Where { $_.MessageCount -gt 0 }` |
| On-prem retry | `Retry-Queue -Identity <queue-identity>` |
| Disconnect | `Disconnect-ExchangeOnline -Confirm:$false` |

---

## 🎓 Learning Pointers

- **EOP pipeline order matters:** Connection filter → Anti-spam → Anti-malware → Transport rules → DLP → Delivery. An ETR cannot rescue a message rejected at the connection filter stage. See: [Anti-spam protection in EOP](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/anti-spam-protection-about)

- **Message Trace covers 10 days max in PowerShell**; for older messages use the [Extended Message Trace](https://learn.microsoft.com/en-us/exchange/monitoring/trace-an-email-message/run-a-message-trace-and-view-results) in EAC (up to 90 days) — results emailed as CSV.

- **SPF has a 10 DNS lookup limit.** If your SPF chain includes many `include:` directives (common with cloud services), exceeding 10 causes PermError. Use `dmarcian.com/spf-survey` or `mxtoolbox.com/spf` to count. Solution: consolidation services (e.g., AutoSPF) or flattening.

- **DKIM key rotation:** EXO uses Selector1 and Selector2 alternately. When you run `Rotate-DkimSigningConfig`, EXO switches the active selector. The inactive one remains valid for 48h. Never delete the old CNAME until rotation completes. See: [Enable DKIM signing](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/email-authentication-dkim-configure)

- **Hybrid Config Wizard (HCW) must be re-run after any certificate renewal** on on-prem Exchange. The HCW updates both the on-prem send connector TLS settings and the EXO inbound connector to match the new cert. Skipping this is the most common cause of post-renewal hybrid mail failures.

- **DMARC `p=reject` can silently drop legitimate mail** if SPF/DKIM aren't perfectly aligned first. Always deploy DMARC in `p=none` (monitoring) for at least 2 weeks before enforcement. Use [DMARC Analyser](https://www.dmarcanalyzer.com/) or Defender's DMARC reports to identify legitimate sources before enforcing.
