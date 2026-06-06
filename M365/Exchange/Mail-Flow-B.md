# Exchange Online Mail Flow — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes. Covers email not arriving, NDR bounces, spam false positives, stuck messages, and connector failures.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [NDR Code Reference](#ndr-code-reference)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

```powershell
# Connect first (skip if already connected)
Connect-ExchangeOnline -UserPrincipalName admin@contoso.com

# 1. Trace the message — covers up to 10 days back
Get-MessageTrace `
  -SenderAddress <sender@domain.com> `
  -RecipientAddress <recipient@domain.com> `
  -StartDate (Get-Date).AddDays(-2) `
  -EndDate (Get-Date) |
  Select Received, SenderAddress, RecipientAddress, Subject, Status, ToIP, FromIP |
  Format-Table -AutoSize

# 2. If you have the MessageTraceId, get full event detail
Get-MessageTraceDetail `
  -MessageTraceId <guid-from-above> `
  -RecipientAddress <recipient@domain.com> |
  Select Date, Event, Action, Detail | Format-Table -Wrap

# 3. Check MX record (run from any machine — no EXO connection needed)
Resolve-DnsName -Name <recipientdomain.com> -Type MX | Select NameExchange, Preference
# Expected: <tenant>.mail.protection.outlook.com

# 4. Check active transport rules that could be blocking
Get-TransportRule | Where-Object { $_.State -eq "Enabled" } |
  Select Priority, Name, Description | Sort-Object Priority | Format-Table -Wrap

# 5. Check inbound/outbound connectors
Get-InboundConnector  | Select Name, Enabled, ConnectorType, TlsSenderCertificateName
Get-OutboundConnector | Select Name, Enabled, ConnectorType, SmartHosts, UseMXRecord
```

**Interpret immediately:**

| `Get-MessageTrace` Status | Meaning | Go to |
|--------------------------|---------|-------|
| `Delivered` | EXO delivered it — problem is client-side | Check Inbox rules, Junk, Clutter, OWA |
| `Failed` | Hard bounce — check NDR code | [NDR Code Reference](#ndr-code-reference) |
| `Pending` | Queued in EXO — delivery retry ongoing | Usually clears in 15 min; if >1h see [Fix 5](#fix-5--stuck-in-transit--pending-queue) |
| `FilteredAsSpam` | EOP marked it spam | [Fix 2](#fix-2--spam-filter-false-positive) |
| `GettingStatus` | Too recent (<15 min) — wait and re-run | Wait, retry |
| No results | Message never reached EXO | Check MX, SPF, sending server; may be [Fix 6](#fix-6--connector-misconfigured) |

---

## Dependency Cascade

<details><summary>What must work for email to arrive end-to-end</summary>

```
[Sending server submits message]
         │
         ▼
[MX DNS lookup — must resolve to *.mail.protection.outlook.com]
  ✗ MX wrong → message routed to wrong server → never enters EXO
         │
         ▼
[Exchange Online Protection (EOP) receives message]
  → Anti-spam evaluation (SCL score)
  → Anti-phishing evaluation
  → Malware scan (Safe Attachments if Defender P1/P2)
  → SPF check (sending IP authorised for sender domain?)
  → DKIM signature validation
  → DMARC policy enforcement
  ✗ Any hard block here → FilteredAsSpam or rejected
         │
         ▼
[Transport Rules evaluated — in priority order, lowest number first]
  Rule can: reject, redirect, add header, quarantine, bypass spam filter
  ✗ Rule set to "Reject" → NDR 5.7.x back to sender
         │
         ▼
[Mailbox delivery]
  → Mailbox quota check (if full → NDR 5.2.2)
  → Litigation hold / archive policy (delivery still happens, copies retained)
  → User's Inbox Rules evaluated (runs AFTER transport rules)
  ✗ Inbox rule "Delete" → message disappears silently from user perspective
         │
         ▼
[Client retrieves message]
  Modern Auth (MAPI over HTTPS / OAuth) — Outlook, OWA, Outlook Mobile
  Legacy Auth (Basic) — blocked by CA in most tenants; use OWA to verify delivery
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm message reached EXO**
```powershell
# Use exact sender + recipient, widen the time window if unsure when it was sent
Get-MessageTrace `
  -SenderAddress sender@external.com `
  -RecipientAddress user@contoso.com `
  -StartDate (Get-Date).AddDays(-5) `
  -EndDate (Get-Date) |
  Sort-Object Received -Descending |
  Select Received, Status, Subject, FromIP, ToIP | Format-Table -AutoSize
```

> If no results: message never entered EXO. The problem is at the sending server or DNS/MX. Proceed to Step 2.
> If Status = Delivered: EXO did its job. The problem is Outlook-side. Check Junk, Inbox rules, Clutter, or wrong Outlook profile. Skip to Step 6.

**Step 2 — Verify MX record**
```powershell
# Check recipient domain MX
Resolve-DnsName -Name contoso.com -Type MX | Select NameExchange, Preference, TTL

# Expected output:
# NameExchange                          Preference
# contoso-com.mail.protection.outlook.com   10

# Also check from external DNS (in case of split DNS masking)
# Use: https://mxtoolbox.com/MXLookup.aspx
# Or: nslookup -type=MX contoso.com 8.8.8.8
```

**Step 3 — Check SPF/DKIM/DMARC**
```powershell
# Check SPF record for sending domain
Resolve-DnsName -Name senderdomain.com -Type TXT |
  Where-Object { $_.Strings -match "v=spf1" } | Select Strings

# Check DKIM selector records
Resolve-DnsName -Name "selector1._domainkey.senderdomain.com" -Type CNAME
Resolve-DnsName -Name "selector2._domainkey.senderdomain.com" -Type CNAME

# Check DMARC record
Resolve-DnsName -Name "_dmarc.senderdomain.com" -Type TXT | Select Strings

# For your own sending domain — check EXO DKIM signing config
Get-DkimSigningConfig | Select Domain, Enabled, Selector1CNAME, Selector2CNAME
```

**Step 4 — Check transport rules for matches**
```powershell
# List all enabled rules, highest priority first
Get-TransportRule | Where-Object { $_.State -eq "Enabled" } |
  Sort-Object Priority |
  Select Priority, Name, @{N="Actions";E={$_.Actions}} | Format-Table -Wrap

# Get detail on a specific rule
Get-TransportRule -Identity "<RuleName>" | Format-List *
```

**Step 5 — Check spam / quarantine policies**
```powershell
# View spam filter policies (what happens to spam-tagged messages)
Get-HostedContentFilterPolicy |
  Select Name, SpamAction, HighConfidenceSpamAction, BulkSpamAction, BulkThreshold

# Check quarantine for a specific message
Get-QuarantineMessage -RecipientAddress user@contoso.com -StartReceivedDate (Get-Date).AddDays(-5) |
  Select ReceivedTime, SenderAddress, Subject, QuarantineTypes | Format-Table

# Release a specific quarantined message
Release-QuarantineMessage -Identity <QuarantineMessageIdentity> -ReleaseToAll
```

**Step 6 — Check user Inbox rules (silent delivery issue)**
```powershell
# List all Inbox rules for the recipient mailbox
Get-InboxRule -Mailbox user@contoso.com |
  Select Name, Enabled, Priority, Description, DeleteMessage, MoveToFolder |
  Format-Table -Wrap

# A rule with DeleteMessage = True silently deletes incoming mail
# A rule that moves to a folder the user doesn't check is functionally the same
```

**Step 7 — Check mailbox quota**
```powershell
Get-MailboxStatistics -Identity user@contoso.com |
  Select DisplayName, TotalItemSize, ItemCount, ProhibitSendQuota, ProhibitSendReceiveQuota,
         StorageLimitStatus

# StorageLimitStatus: Normal = OK, ProhibitSend = can't send, ProhibitSendReceive = full — no delivery
```

**Step 8 — Check NDR detail (for bounced messages)**
```powershell
# Get the message trace detail — the Event/Detail fields contain the NDR code
Get-MessageTraceDetail `
  -MessageTraceId <guid> `
  -RecipientAddress recipient@contoso.com |
  Select Date, Event, Action, Detail | Format-Table -Wrap

# Look for Event = "Failed" or "NDR" and read the Detail field
# NDR codes start with 4.x.x (temporary) or 5.x.x (permanent)
```

---

## NDR Code Reference

| NDR Code | Meaning | Likely Cause | Fix |
|----------|---------|-------------|-----|
| `5.7.1` | Delivery not authorised | Transport rule rejected message, or SPF/DMARC hard fail | Check transport rules; check SPF record for sender |
| `5.7.23` | SPF validation failed | Sending IP not in sender domain's SPF record | Add sending IP to SPF; or whitelist sender in EOP |
| `5.7.57` | SMTP AUTH not permitted | Client trying to use SMTP AUTH (basic) — blocked by policy | Enable SMTP AUTH on mailbox or use app password / OAuth |
| `5.7.64` | TenantAttribution; Relay access denied | Outbound connector misconfigured; relay not authorised | Check connector; verify sending IP in inbound connector |
| `5.4.1` | Recipient address rejected | Recipient doesn't exist in EXO (typo, deleted mailbox) | Verify recipient UPN/alias in `Get-Mailbox`; check distribution group |
| `5.4.6` | Routing loop detected | Message bouncing between two systems (common in hybrid) | Check hybrid connector smart host; check transport rules for redirect loops |
| `5.1.8` | Sender not authorised — from policy | Outbound spam policy blocked sender account (compromised account) | Check outbound spam policy; reset user password + MFA |
| `5.2.2` | Mailbox full | Recipient mailbox at `ProhibitSendReceive` quota | Clear mailbox or increase quota; assign archive licence |
| `5.3.4` | Message too large | Message exceeds transport/mailbox size limits | Check `MaxReceiveSize` on mailbox and `MaxMessageSize` on connector |
| `4.4.7` | Message expired — delivery timeout | Destination server not reachable for 24–48h (temp failure sustained) | Check destination MX; check outbound connector smart host; check TLS cert on hybrid connector |
| `4.4.316` | Connection refused — TLS handshake | TLS cert mismatch on receiving server (often hybrid connector cert) | Renew/replace certificate on hybrid connector; check `TlsSenderCertificateName` |
| `4.7.26` | DMARC policy failure (quarantine/reject) | Message failed DMARC alignment | Fix SPF alignment or enable DKIM signing; add DMARC override rule carefully |

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — MX record pointing to wrong server</summary>

**Symptom:** No results in `Get-MessageTrace`; external senders report bounce or non-delivery

```powershell
# Confirm the MX record
Resolve-DnsName -Name contoso.com -Type MX | Select NameExchange, Preference

# Correct value: contoso-com.mail.protection.outlook.com (or tenant-specific variant)
# Wrong value examples:
#   - Old on-prem Exchange FQDN (migration not complete)
#   - Third-party spam gateway that's been decommissioned
#   - Wrong priority — backup MX with lower preference taking traffic

# Fix: Update MX record in DNS provider to point to EXO
# TTL matters — allow old TTL to expire before expecting results
# Typical TTL: 3600s (1 hour) — changes take up to TTL to propagate globally
```

> For hybrid orgs: MX may intentionally point to on-prem. Confirm expected routing design before changing.

</details>

<details id="fix-2"><summary>Fix 2 — Spam filter false positive (legitimate email landing in Junk or Quarantine)</summary>

**Symptom:** `Get-MessageTrace` shows `FilteredAsSpam` or message in quarantine; sender is legitimate

```powershell
# Check the spam confidence level (SCL) on the message
Get-MessageTraceDetail -MessageTraceId <guid> -RecipientAddress <recipient> |
  Where-Object { $_.Detail -match "SCL|spam|phish" } | Select Date, Detail

# Option A: Release from quarantine and allow sender
Release-QuarantineMessage -Identity <QuarantineMessageIdentity> -ReleaseToAll

# Option B: Add sender to allowed senders list in EOP policy
$policy = Get-HostedContentFilterPolicy -Identity Default
$allowed = $policy.AllowedSenders + @{Address="sender@external.com"}
Set-HostedContentFilterPolicy -Identity Default -AllowedSenders $allowed

# Option C: Create a transport rule to bypass spam filtering for trusted sender
New-TransportRule `
  -Name "Bypass Spam - TrustedSender" `
  -SenderAddresses "sender@external.com" `
  -SetSCL -1 `
  -Comments "Approved bypass - ticket ref: XXXX"

# Option D: Allow entire sender domain (use with caution)
$allowed = $policy.AllowedSenderDomains + @{Domain="trusteddomain.com"}
Set-HostedContentFilterPolicy -Identity Default -AllowedSenderDomains $allowed
```

> Warning: SetSCL -1 bypasses ALL spam and malware filtering. Only use for fully trusted senders.

</details>

<details id="fix-3"><summary>Fix 3 — Transport rule blocking or redirecting email</summary>

**Symptom:** `Get-MessageTraceDetail` shows Event = `Transport Rule` with Action = `Reject` or `Redirect`

```powershell
# Find the rule by name from the trace detail
Get-TransportRule -Identity "<RuleName>" | Format-List *

# Check what the rule is doing and to whom it applies
# Common problematic patterns:
#   - Reject rule meant for external but matching internal too
#   - Redirect rule sending to wrong address (old HR address, deactivated mailbox)
#   - Confidential label rule rejecting legitimate external recipients

# Disable a rule temporarily (use to confirm it's the cause)
Disable-TransportRule -Identity "<RuleName>"

# Edit a rule's conditions to narrow the scope
Set-TransportRule -Identity "<RuleName>" `
  -ExceptIfSenderDomainIs "contoso.com"  # Example: exclude internal senders

# Re-enable after fix
Enable-TransportRule -Identity "<RuleName>"
```

</details>

<details id="fix-4"><summary>Fix 4 — SPF / DKIM / DMARC failure causing rejection</summary>

**Symptom:** NDR 5.7.23 (SPF) or 4.7.26 (DMARC); `Get-MessageTraceDetail` shows auth failure

```powershell
# Check your tenant's outbound SPF record
Resolve-DnsName -Name contoso.com -Type TXT |
  Where-Object { $_.Strings -match "v=spf1" } | Select Strings
# Must include: include:spf.protection.outlook.com

# Enable DKIM signing for your domain (do both selectors)
New-DkimSigningConfig -DomainName contoso.com -Enabled $true
# Then publish the CNAME records shown in the output to your DNS provider

# Verify DKIM is active
Get-DkimSigningConfig -Identity contoso.com |
  Select Domain, Enabled, Status, Selector1CNAME, Selector2CNAME

# Check DMARC policy (this is a DNS record, not an EXO setting)
Resolve-DnsName -Name "_dmarc.contoso.com" -Type TXT | Select Strings
# Recommended minimum: "v=DMARC1; p=none; rua=mailto:dmarc-reports@contoso.com"
# p=reject will cause bounces if SPF or DKIM aren't aligned — start with p=none
```

> For a third-party sender (e.g. CRM, bulk email) sending on behalf of your domain: add their sending IPs/include to your SPF record, or have them DKIM-sign with your domain (most support this).

</details>

<details id="fix-5"><summary>Fix 5 — Stuck in transit / Pending queue</summary>

**Symptom:** `Get-MessageTrace` shows Status = `Pending` for more than 1 hour; NDR 4.4.7 after 48h

```powershell
# Get the trace detail to see what EXO is trying to do
Get-MessageTraceDetail -MessageTraceId <guid> -RecipientAddress <recipient> |
  Select Date, Event, Action, Detail | Format-Table -Wrap

# Check outbound connector if message is being routed via a smart host
Get-OutboundConnector | Select Name, Enabled, SmartHosts, TlsSettings, UseMXRecord

# For hybrid orgs — check the on-prem connector is reachable
Test-MigrationServerAvailability -ExchangeRemoteMove `
  -RemoteServer mail.contoso.com `
  -Credentials (Get-Credential)

# Check if the destination MX is reachable from EXO (external delivery test)
# Use: https://testconnectivity.microsoft.com → "Outbound SMTP Email"
# Or check the Microsoft Remote Connectivity Analyzer
```

**Common causes of 4.4.7:**
- Destination mail server is down or rejecting connections
- Outbound connector smart host is unreachable (hybrid connector pointing to dead server)
- TLS handshake failing due to certificate mismatch on connector
- Destination server's MX record pointing to wrong IP

</details>

<details id="fix-6"><summary>Fix 6 — Connector misconfigured (relay / partner connector)</summary>

**Symptom:** NDR 5.7.64 (relay denied) or all email from a specific source failing; on-prem relay broken

```powershell
# Check inbound connectors (what EXO accepts from external/on-prem)
Get-InboundConnector | Format-List Name, Enabled, ConnectorType, SenderIPAddresses,
  TlsSenderCertificateName, RequireTls, RestrictDomainsToCertificate

# Check outbound connectors (where EXO routes to)
Get-OutboundConnector | Format-List Name, Enabled, ConnectorType, SmartHosts,
  TlsSettings, TlsDomain, UseMXRecord

# Common fix: on-prem relay server IP changed — update inbound connector IP list
Set-InboundConnector -Identity "From On-Premises" `
  -SenderIPAddresses @("203.0.113.10","203.0.113.11")

# Common fix: smart host FQDN changed or cert expired
Set-OutboundConnector -Identity "To On-Premises" `
  -SmartHosts "mail.contoso.com" `
  -TlsDomain "mail.contoso.com"

# Test outbound connector delivery
Validate-OutboundConnector -Identity "To On-Premises"
```

</details>

<details><summary>Fix 7 — Hybrid org: on-prem relay issues and certificate expiry</summary>

**Symptom:** Mail between on-prem mailboxes and EXO mailboxes failing; NDR 4.4.316 or 5.4.6

```powershell
# Check the hybrid inbound connector cert name
Get-InboundConnector -Identity "*Inbound from*" |
  Select TlsSenderCertificateName, RequireTls, CloudServicesMailEnabled

# On the on-prem Exchange server — check the Send/Receive connector cert
# (Run in on-prem Exchange Management Shell, not EXO)
Get-SendConnector "Outbound to Office 365" | Select TlsAuthLevel, TlsDomain, SmartHosts
Get-ReceiveConnector "Inbound from Office 365" | Select AuthMechanism, TlsCertificateName

# Check certificate expiry on on-prem hybrid server
# (On-prem Exchange Management Shell)
Get-ExchangeCertificate | Select Subject, NotAfter, Services, Thumbprint |
  Sort NotAfter | Format-Table

# If cert expired: renew via DigiCert/Sectigo/etc, then assign to SMTP service
# Enable-ExchangeCertificate -Thumbprint <newthumbprint> -Services SMTP

# Re-run Hybrid Configuration Wizard if connector settings are badly misaligned
# Start-HybridConfiguration (run on on-prem Exchange server)
```

> If you run HCW, have the hybrid Exchange admin on the call — HCW overwrites connector settings.

</details>

<details><summary>Fix 8 — Mailbox full / quota exceeded</summary>

**Symptom:** Inbound delivery failing; NDR 5.2.2 to senders; user can't receive email

```powershell
# Check current usage
Get-MailboxStatistics -Identity user@contoso.com |
  Select TotalItemSize, ItemCount, StorageLimitStatus, LastLogonTime

# Check quota settings
Get-Mailbox -Identity user@contoso.com |
  Select IssueWarningQuota, ProhibitSendQuota, ProhibitSendReceiveQuota, UseDatabaseQuotaDefaults

# Option A: Increase quota (requires appropriate licence)
Set-Mailbox -Identity user@contoso.com `
  -ProhibitSendReceiveQuota 50GB `
  -ProhibitSendQuota 49GB `
  -IssueWarningQuota 47GB

# Option B: Enable archive (requires Exchange Plan 2 or add-on licence)
Enable-Mailbox -Identity user@contoso.com -Archive

# Option C: Delete large items (user-led — guide them to Outlook cleanup tools)
# Or use PowerShell to find large items
Get-MailboxFolderStatistics -Identity user@contoso.com -FolderScope All |
  Sort-Object FolderSize -Descending | Select FolderPath, FolderSize -First 10
```

</details>

---

## Escalation Evidence

```
Exchange Mail Flow Failure — Evidence Pack
==========================================
Tenant:                    
Sender address:            
Recipient address:         
Message subject (approx):  
Date/time sent:            [UTC preferred]
MessageTraceId:            [from Get-MessageTrace]
Get-MessageTrace Status:   [Delivered / Failed / FilteredAsSpam / Pending / No result]
NDR code (if bounce):      [e.g. 5.7.1, 4.4.7]
Get-MessageTraceDetail output:  [paste Event + Detail columns]
MX record result:          [nslookup output]
Transport rules checked:   [names of any rules that matched]
Connector state:           [connector names, enabled Y/N, SmartHosts]
SPF record:                [paste TXT record]
DKIM signing enabled:      [Y/N, domain]
DMARC record:              [paste TXT record]
Quarantine checked:        [Y/N, any matches?]
Mailbox quota state:       [StorageLimitStatus + TotalItemSize]
Hybrid environment:        [Y/N — on-prem Exchange version]
Hybrid connector cert expiry: [NotAfter date if hybrid]
```

---

## 🎓 Learning Pointers

- **`Get-MessageTrace` only covers 10 days** — for older messages, use the Extended Message Trace in the Exchange Admin Center (EAC → Mail flow → Message trace → Extended trace). Extended traces are async and emailed to you as a report. Know this limit before telling a customer "message never arrived."
- **Transport rule vs Inbox rule precedence** — transport rules run in the cloud as the message is processed, before delivery to the mailbox. Inbox rules run after delivery, on the client or OWA. A transport rule with "Reject" NDRs the sender. An Inbox rule with "Delete" delivers and immediately deletes — the sender gets no bounce. This distinction matters enormously when diagnosing "message disappeared."
- **DMARC enforcement order** — SPF and DKIM must be correctly aligned before setting `p=quarantine` or `p=reject`. The recommended path: publish `p=none` first, monitor reports, fix alignment issues, then tighten to `p=quarantine`, then `p=reject`. Jumping straight to `p=reject` without DKIM will block your own legitimate email. [MS Docs: DMARC in EOP](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/email-authentication-dmarc-configure)
- **Mail flow architecture deep dive** — the full EOP pipeline (connection filtering → malware → policy → content filtering → rules → delivery) is documented in [MS Docs: Mail flow in EOP](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/how-policies-and-protections-are-combined). Understanding the order of operations prevents chasing the wrong layer.
- **SetSCL -1 bypass risks** — a transport rule that sets SCL to -1 skips ALL spam and malware checks for matched messages. It is appropriate for known trusted relay servers sending internal notification email, but dangerous if scoped too broadly. Always document why a bypass rule exists and what ticket approved it.
- **Hybrid connector certificate is a common silent killer** — on-prem hybrid connectors use a TLS certificate (usually third-party CA). When it expires, mail between on-prem and EXO silently queues, then NDRs. Set a calendar reminder 60 days before expiry. [Check with `Get-ExchangeCertificate` on the hybrid server.]
