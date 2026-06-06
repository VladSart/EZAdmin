# Exchange Online Protection — Anti-Spam & EOP — Reference Runbook (Mode A: Deep Dive)
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

- Tenant has Exchange Online (any M365 plan that includes EOP)
- Engineer has Exchange Administrator or Security Administrator role
- Covers inbound and outbound spam filtering, spoofing, phishing, and safe-sender/block-sender configuration
- Covers both cloud-only and Exchange Hybrid mail flow scenarios
- Does NOT cover Microsoft Defender for Office 365 (MDO/Plan 1/2) in depth — this is EOP-layer only
- Assumes familiarity with DNS (SPF, DKIM, DMARC)

---

## How It Works

<details><summary>Full EOP Architecture</summary>

EOP is the filtering engine that processes all inbound and outbound mail for Exchange Online. Every message passes through a pipeline of filter layers in sequence:

```
Internet Sender
      │
      ▼
[Edge Protection / Connection Filtering]
  - IP Reputation checks (Microsoft global list)
  - Sender Policy Framework (SPF) pre-check
  - IP Allow/Block lists
      │
      ▼
[Anti-Malware Scanning]
  - Multiple engine scan
  - Zero-hour auto purge (ZAP) eligibility established
      │
      ▼
[Anti-Spam Filtering]
  - Content scoring: Spam Confidence Level (SCL) assigned 0-9
    SCL -1  = Bypassed (allow-listed)
    SCL 0-4 = Not spam (delivered to Inbox)
    SCL 5-6 = Spam (default: delivered to Junk)
    SCL 7-9 = High confidence spam (default: delivered to Junk or Quarantine)
  - Phishing Confidence Level (PCL) assigned
  - Bulk Complaint Level (BCL) assigned 0-9
      │
      ▼
[Anti-Phishing Filtering]
  - Spoof intelligence (implicit auth + explicit allow/block)
  - Impersonation detection (MDO Plan 1/2 only)
      │
      ▼
[Transport Rules (mail flow rules)]
  - Applied after EOP filtering
  - Can override SCL, set actions, modify headers
      │
      ▼
[Outbound Spam Filtering]
  - Applied to all tenant-originated mail
  - Detects compromised accounts sending spam
  - Can restrict or block senders
      │
      ▼
[Recipient Mailbox Rules / Junk Email Settings]
  - User-level safe/blocked sender lists
  - Junk Email folder thresholds
      │
      ▼
Delivery (Inbox, Junk, Quarantine, or Drop)
```

**Key Filter Objects:**

| Object | Where Configured | Purpose |
|--------|-----------------|---------|
| Anti-spam policy | Defender portal > Policies > Anti-spam | Sets SCL thresholds, bulk threshold, actions |
| Anti-phishing policy | Defender portal > Policies > Anti-phishing | Spoof intelligence, DMARC enforcement |
| Connection filter policy | Defender portal > Policies > Anti-spam | IP allow/block lists |
| Outbound spam policy | Defender portal > Policies > Anti-spam | Outbound limits, forwarding rules |
| Safe sender lists (user) | Outlook / OWA | Per-user whitelist, bypasses Junk filter |
| Safe sender lists (admin) | Anti-spam policy > Allowed senders/domains | Tenant-wide bypass — use sparingly |

**Zero-Hour Auto Purge (ZAP):** After delivery, if a message is later reclassified as spam or malware, ZAP can retroactively move it from Inbox to Junk or Quarantine. Requires mailbox to be in Exchange Online and ZAP enabled.

</details>

---

## Dependency Stack

```
User Mailbox (Exchange Online)
        │
        │ relies on
        ▼
EOP Filtering Pipeline
        │
        ├── Anti-spam policy (assigned to: all users OR specific groups)
        ├── Anti-phishing policy
        ├── Connection filter policy
        ├── Outbound spam policy
        │
        │ validates against
        ▼
DNS Authentication Layer
        │
        ├── SPF record  (TXT @ sending domain)
        ├── DKIM keys   (CNAME records at selector1._domainkey / selector2._domainkey)
        └── DMARC record (TXT _dmarc.senderdomain.com)
        │
        │ feeds into
        ▼
Spoof Intelligence / Authentication Results
        │
        └── composite auth result in message header (compauth=)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Legitimate mail landing in Junk | SCL threshold too low, or sender has bad IP reputation | Check X-Forefront-Antispam-Report header, SCL value |
| Legitimate mail quarantined | Anti-spam policy bulk threshold too strict, or phishing FP | Check BCL and PCL in headers; check quarantine |
| Spam reaching Inbox | Allow-listed sender/domain incorrectly configured; ZAP disabled | Check allowed senders/domains in anti-spam policy |
| Mail rejected with 5.7.1 | SPF hard fail, or sender IP on block list | Check SPF record alignment; check connection filter |
| Mail rejected with 550 5.7.501–503 | Outbound spam detected, account restricted | Check outbound spam policy; check restricted senders portal |
| Spoofed mail being delivered | Spoof intelligence miss; DMARC policy too permissive | Check spoof intelligence insight; check DMARC policy |
| ZAP not moving messages | Mailbox rules moving mail before ZAP acts; ZAP disabled | Check ZAP setting in anti-spam policy |
| User complaints about quarantine notifications | Quarantine policy not configured; notifications disabled | Check quarantine policy assigned in anti-spam policy |
| Outbound mail flagged as spam by recipients | SPF/DKIM/DMARC misconfigured on sending domain | Run `Get-DkimSigningConfig`; validate DNS |

---

## Validation Steps

**1. Pull message headers for a specific mail**
```powershell
# Connect to Exchange Online
Connect-ExchangeOnline -UserPrincipalName <adminUPN>

# Get message trace for the last 10 days
Get-MessageTrace -RecipientAddress <recipient@domain.com> -StartDate (Get-Date).AddDays(-10) -EndDate (Get-Date) | Format-List
```
Expected: `Status` shows `Delivered`, `Quarantined`, `Filtered`, etc.  
Bad: `Status` = `Failed` without a bounce — indicates silent drop or routing issue.

**2. Check the SCL in message headers**
Ask the user to forward the raw message headers (Outlook: File > Properties > Internet headers). Look for:
```
X-Forefront-Antispam-Report: ... SCL:5; ...
```
- SCL 5-6 = spam threshold hit
- SCL 7-9 = high confidence spam
- SCL -1 = bypassed (allow-listed)
- BCL 4+ = bulk mail threshold hit

**3. Check current anti-spam policy**
```powershell
Get-HostedContentFilterPolicy | Select-Object Name, SpamAction, HighConfidenceSpamAction, BulkThreshold, PhishSpamAction, MarkAsSpamBulkMail, ZapEnabled | Format-List
```
Expected: `ZapEnabled = True`; `SpamAction = MoveToJmf` or `Quarantine`; `BulkThreshold` between 4-7.

**4. Validate DKIM signing for your domain**
```powershell
Get-DkimSigningConfig | Select-Object Domain, Enabled, Status, Selector1CNAME, Selector2CNAME | Format-List
```
Expected: `Status = Valid`; `Enabled = True` for all sending domains.  
Bad: `Status = CnameMissing` — DKIM CNAME records not published in DNS.

**5. Check SPF record from Exchange Online perspective**
```powershell
# Check if SPF include for Microsoft is present
Resolve-DnsName -Name <yourdomain.com> -Type TXT | Where-Object { $_.Strings -match "spf1" }
```
Expected: Output includes `include:spf.protection.outlook.com`.  
Bad: Missing — spoofing protection fails.

**6. Check outbound restricted senders**
```powershell
Get-BlockedSenderAddress | Format-List
```
Expected: Empty list for healthy tenants.  
Bad: User account listed — account likely compromised; must reset password and remove from list.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify the message fate
1. Run `Get-MessageTrace` for the affected sender/recipient in the relevant date range.
2. Note `Status` (Delivered, FilteredAsSpam, Quarantined, Failed, GettingStatus).
3. If status is `GettingStatus` for mail older than 10 days, use `Start-HistoricalSearch` for up to 90 days.
4. Check `Get-MessageTraceDetail` for individual hop events and latency.

### Phase 2 — Analyse headers
1. Obtain raw headers from the user's email client.
2. Paste into https://mha.azurewebsites.net (Microsoft Message Header Analyzer) or parse manually.
3. Check `SCL`, `BCL`, `PCL`, `SFV` (spam filter verdict), and `compauth` values.
4. `SFV:SPM` = marked as spam; `SFV:SKI` = skip (whitelisted); `SFV:BLK` = blocked.

### Phase 3 — Check policies for gaps
1. Run `Get-HostedContentFilterPolicy` and compare bulk threshold to the BCL in headers.
2. Check if a custom policy exists with looser settings: `Get-HostedContentFilterRule`.
3. Confirm ZAP is enabled: `(Get-HostedContentFilterPolicy -Identity Default).ZapEnabled`.

### Phase 4 — Validate email authentication
1. Run SPF, DKIM, and DMARC checks from MXToolbox or PowerShell DNS queries.
2. Verify DKIM is enabled and keys are published: `Get-DkimSigningConfig`.
3. Check DMARC record: `Resolve-DnsName _dmarc.<yourdomain.com> -Type TXT`.
4. DMARC `p=none` = monitor only; `p=quarantine` or `p=reject` = active enforcement.

### Phase 5 — Remediate or whitelist cautiously
1. If FP (legit mail marked as spam), prefer submitting via Defender portal > Submissions rather than whitelisting.
2. If whitelisting a domain is required, use the anti-spam policy allowed domains list, not transport rules.
3. Document every whitelist entry with business justification.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Remove a user from the Restricted Senders list</summary>

**When:** A user account was restricted from sending email (usually after compromise).

```powershell
Connect-ExchangeOnline -UserPrincipalName <adminUPN>

# Verify the user is restricted
Get-BlockedSenderAddress

# Remove from restricted list
Remove-BlockedSenderAddress -SenderAddress <user@domain.com>

# Confirm
Get-BlockedSenderAddress
```

**Before removing:** Ensure the account password has been reset, MFA has been enforced, and active sessions revoked:
```powershell
# Revoke all sessions
Revoke-AzureADUserAllRefreshToken -ObjectId (Get-AzureADUser -SearchString <user@domain.com>).ObjectId
```

**Rollback:** If spam continues after removal, re-restrict the sender manually in the Defender portal under Review > Restricted entities.

</details>

<details><summary>Playbook 2 — Enable DKIM signing for a custom domain</summary>

**When:** DKIM is not enabled for a sending domain, causing mail to fail authentication.

```powershell
Connect-ExchangeOnline -UserPrincipalName <adminUPN>

# Check current state
Get-DkimSigningConfig -Identity <yourdomain.com>

# Get CNAME values to publish in DNS
$config = Get-DkimSigningConfig -Identity <yourdomain.com>
$config.Selector1CNAME
$config.Selector2CNAME
```

Publish these two CNAME records at your DNS provider:
```
selector1._domainkey.<yourdomain.com>  CNAME  selector1-<yourdomain-com>._domainkey.<tenant>.onmicrosoft.com
selector2._domainkey.<yourdomain.com>  CNAME  selector2-<yourdomain-com>._domainkey.<tenant>.onmicrosoft.com
```

Wait for DNS propagation (15-60 min), then enable:
```powershell
Set-DkimSigningConfig -Identity <yourdomain.com> -Enabled $true

# Verify
Get-DkimSigningConfig -Identity <yourdomain.com> | Select-Object Domain, Enabled, Status
```

Expected `Status = Valid`. If still `CnameMissing`, DNS has not propagated — wait and retry.

**Rollback:** `Set-DkimSigningConfig -Identity <yourdomain.com> -Enabled $false` (mail still flows, just unsigned).

</details>

<details><summary>Playbook 3 — Tune bulk mail threshold to reduce FPs</summary>

**When:** Legitimate bulk mail (newsletters, marketing) is being moved to Junk. BCL in headers is 4-6.

```powershell
Connect-ExchangeOnline -UserPrincipalName <adminUPN>

# View current settings
Get-HostedContentFilterPolicy -Identity Default | Select-Object BulkThreshold, MarkAsSpamBulkMail

# Raise threshold (6 = less aggressive, allows more bulk)
Set-HostedContentFilterPolicy -Identity Default -BulkThreshold 6

# Confirm
Get-HostedContentFilterPolicy -Identity Default | Select-Object BulkThreshold
```

BCL scale: 0 = not bulk; 9 = very spammy bulk. Setting threshold to 7 allows most bulk mail through; setting to 4 blocks most of it.

**Rollback:** `Set-HostedContentFilterPolicy -Identity Default -BulkThreshold 4` to restore stricter filtering.

</details>

<details><summary>Playbook 4 — Submit false positive/negative to Microsoft</summary>

**When:** Mail is incorrectly classified (good mail quarantined, or spam delivered).

Preferred method (portal):
1. Defender portal > Actions & submissions > Submissions
2. Select "Email" tab
3. Add sender/subject/recipient, select classification correction
4. Submit — Microsoft retrains models

PowerShell method:
```powershell
# No native cmdlet for submissions — use portal or Graph API
# For quarantine release (FP):
Get-QuarantineMessage -SenderAddress <sender@external.com> | Where-Object { $_.Subject -like "*keyword*" }
Release-QuarantineMessage -Identity <QuarantineMessageIdentity> -User <recipient@yourdomain.com>
```

</details>

---

## Evidence Pack

```powershell
# ============================================================
# EOP Anti-Spam Evidence Collection Script
# Run as Exchange Administrator or Security Administrator
# ============================================================

Connect-ExchangeOnline -UserPrincipalName <adminUPN>

$outputPath = "$env:TEMP\EOP-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $outputPath | Out-Null

# 1. Anti-spam policies
Get-HostedContentFilterPolicy | Select-Object Name, SpamAction, HighConfidenceSpamAction,
    BulkThreshold, PhishSpamAction, MarkAsSpamBulkMail, ZapEnabled, AllowedSenders, AllowedSenderDomains,
    BlockedSenders, BlockedSenderDomains |
    Export-Csv "$outputPath\AntiSpamPolicies.csv" -NoTypeInformation

# 2. Anti-spam rules (which policy applies to which groups)
Get-HostedContentFilterRule | Select-Object Name, State, Priority, HostedContentFilterPolicy,
    RecipientDomainIs, SentToMemberOf |
    Export-Csv "$outputPath\AntiSpamRules.csv" -NoTypeInformation

# 3. Anti-phishing policies
Get-AntiPhishPolicy | Select-Object Name, Enabled, AuthenticationFailAction,
    EnableSpoofIntelligence, EnableUnauthenticatedSender, PhishThresholdLevel |
    Export-Csv "$outputPath\AntiPhishPolicies.csv" -NoTypeInformation

# 4. DKIM signing config
Get-DkimSigningConfig | Select-Object Domain, Enabled, Status, Selector1CNAME, Selector2CNAME |
    Export-Csv "$outputPath\DKIMConfig.csv" -NoTypeInformation

# 5. Restricted senders
Get-BlockedSenderAddress |
    Export-Csv "$outputPath\RestrictedSenders.csv" -NoTypeInformation

# 6. Message trace (last 24h - adjust as needed)
Get-MessageTrace -StartDate (Get-Date).AddHours(-24) -EndDate (Get-Date) -PageSize 250 |
    Export-Csv "$outputPath\MessageTrace-24h.csv" -NoTypeInformation

# 7. Connection filter
Get-HostedConnectionFilterPolicy | Select-Object Name, IPAllowList, IPBlockList, EnableSafeList |
    Export-Csv "$outputPath\ConnectionFilter.csv" -NoTypeInformation

# 8. Outbound spam policy
Get-HostedOutboundSpamFilterPolicy | Select-Object Name, Enabled, ActionWhenThresholdReached,
    RecipientLimitInternalPerHour, RecipientLimitExternalPerHour, RecipientLimitPerDay |
    Export-Csv "$outputPath\OutboundSpamPolicy.csv" -NoTypeInformation

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path $outputPath -DestinationPath "$outputPath.zip"
Write-Host "Zipped: $outputPath.zip" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| View all anti-spam policies | `Get-HostedContentFilterPolicy \| Format-List` |
| Check DKIM status | `Get-DkimSigningConfig \| Select Domain, Enabled, Status` |
| Enable DKIM | `Set-DkimSigningConfig -Identity <domain> -Enabled $true` |
| Check restricted senders | `Get-BlockedSenderAddress` |
| Remove restricted sender | `Remove-BlockedSenderAddress -SenderAddress <UPN>` |
| Trace a message | `Get-MessageTrace -RecipientAddress <UPN> -StartDate ... -EndDate ...` |
| Release quarantined message | `Release-QuarantineMessage -Identity <ID> -User <UPN>` |
| View quarantine | `Get-QuarantineMessage -SenderAddress <addr>` |
| Check outbound policy | `Get-HostedOutboundSpamFilterPolicy` |
| Check connection filter | `Get-HostedConnectionFilterPolicy` |
| View anti-phishing policy | `Get-AntiPhishPolicy \| Format-List` |
| Rotate DKIM keys | `Rotate-DkimSigningConfig -Identity <domain> -KeySize 2048` |
| View spoof intelligence | Defender portal > Email & Collab > Policies > Anti-phishing > Spoof intelligence insight |
| Historical search (>10 days) | `Start-HistoricalSearch -StartDate ... -EndDate ... -ReportTitle "..." -ReportType MessageTrace -SenderAddress ...` |

---

## 🎓 Learning Pointers

- **SCL/BCL/PCL are your diagnostic keys.** Every spam verdict is explained in `X-Forefront-Antispam-Report` headers. Learn to read them before touching policy. MS Docs: [Anti-spam message headers](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/message-headers-eop-mdo)

- **Submissions beat whitelisting.** Submitting FPs/FNs to Microsoft via the Submissions portal improves the global model. Whitelisting domains bypasses all EOP filtering, including malware — do it only for trusted internal systems. MS Docs: [Admin submissions](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/submissions-admin)

- **ZAP is your backstop.** Zero-Hour Auto Purge retroactively catches mail that slips through. It is enabled by default but can be disabled per-policy. Confirm it is on for all policies, especially any custom ones. MS Docs: [Zero-hour auto purge](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/zero-hour-auto-purge)

- **DMARC enforcement requires SPF + DKIM aligned.** `p=reject` only protects if both SPF and DKIM pass and align to the From header domain. A DMARC `p=reject` record alone does nothing if SPF or DKIM is broken. Validate all three together. MS Docs: [DMARC in Microsoft 365](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/email-authentication-dmarc-configure)

- **Outbound spam restrictions indicate account compromise.** When `Get-BlockedSenderAddress` returns results, treat it as a security incident — not just a mail flow issue. Rotate credentials, revoke sessions, check inbox rules for exfiltration forwarding, and file a security ticket. MS Docs: [Restricted entities portal](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/outbound-spam-restore-restricted-users)

- **Spoof intelligence is not DMARC.** EOP's spoof intelligence catches unauthenticated senders using your domain's display name or address, even when DMARC is not configured. It uses implicit authentication (compauth). Adding DMARC provides explicit policy enforcement on top. MS Docs: [Spoof intelligence insight](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/anti-spoofing-spoof-intelligence)
