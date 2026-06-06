# Exchange Online Protection — Anti-Spam & Mail Filtering — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run these immediately to determine the blast radius:

```powershell
# Connect to Exchange Online
Connect-ExchangeOnline -UserPrincipalName <admin@tenant.onmicrosoft.com>

# 1. Check recent inbound message trace (last 2 hours, target recipient)
Get-MessageTrace -RecipientAddress <UPN> -StartDate (Get-Date).AddHours(-2) -EndDate (Get-Date) |
    Select-Object Received, SenderAddress, Subject, Status, ToIP, FromIP |
    Format-Table -AutoSize

# 2. Check quarantine for the user (last 48 hours)
Get-QuarantineMessage -RecipientAddress <UPN> -StartExpiresDate (Get-Date).AddDays(-2) |
    Select-Object ReceivedTime, SenderAddress, Subject, QuarantineTypes, Released |
    Format-Table -AutoSize

# 3. Check if sender domain is on a block list
Get-TenantAllowBlockListItems -ListType Sender | Where-Object {$_.Value -like "*<domain>*"}

# 4. Check spam filter policy for the affected user/group
Get-HostedContentFilterPolicy | Select-Object Name, IsDefault, SpamAction, HighConfidenceSpamAction,
    PhishSpamAction, BulkThreshold | Format-Table -AutoSize
```

**Interpretation:**

| Result | Action |
|--------|--------|
| Message trace shows "Filtered as spam" | Check spam filter policy — recipient may need a quarantine release or allow rule |
| Message trace shows "Delivered" but message missing | Check Junk folder, Clutter, or user-level block rules in Outlook |
| Message not in trace at all | Message rejected before entry — check sender's MX/SPF/DKIM or tenant block list |
| Quarantine shows messages | Release message + determine if policy is over-aggressive |
| Sender in block list | Remove from block list if legitimate; verify not on tenant blocklist vs. Microsoft blocklist |

---

## Dependency Cascade

<details><summary>What must be true for legitimate mail to be delivered</summary>

```
External Mail Sent
  └── Microsoft Edge Network (MX record resolves to *.mail.protection.outlook.com)
        └── Connection Filtering (IP reputation check)
              ├── Sender IP not on Microsoft blocklist
              ├── Sender IP not on tenant Connection Filter policy block list
              └── Sender IP on IP Allow list? → bypass some checks
        └── Anti-Spoofing / DMARC / DKIM / SPF evaluation
              ├── SPF check against sender domain's DNS TXT record
              ├── DKIM signature validation
              └── DMARC policy applied (none / quarantine / reject)
        └── Anti-Spam Filtering (Hosted Content Filter Policy)
              ├── Spam confidence level (SCL) calculated
              ├── Bulk complaint level (BCL) evaluated
              ├── Phishing / high-confidence phishing checks
              └── Policy action: Deliver / Junk folder / Quarantine / Delete
        └── Anti-Malware Filtering (Hosted Malware Filter Policy)
              └── Attachment scanning
        └── Safe Attachments / Safe Links (Defender for Office 365 P1/P2, if licensed)
              ├── Detonation sandbox for attachments
              └── URL rewriting and scanning
        └── Delivery to recipient mailbox
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Run a message trace**
```powershell
# Get detail on a specific message (use MessageTraceId if known)
Get-MessageTrace -SenderAddress <sender@external.com> -RecipientAddress <user@tenant.com> `
    -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) | Format-Table -AutoSize
```
Expected: Row showing `Status: Delivered`. Bad: `FilteredAsSpam`, `GettingStatus`, or no rows.

**Step 2 — Get detailed trace events for a specific message**
```powershell
# Replace <MessageTraceId> from the above output
Get-MessageTraceDetail -MessageTraceId "<MessageTraceId>" -RecipientAddress <UPN> |
    Select-Object Date, Event, Action, Detail | Format-Table -AutoSize
```
Expected: `Receive`, `Transport rule evaluated`, `Deliver` events. Look for `SpamDiagnosticMetadata` in Detail column.

**Step 3 — Check quarantine for released / unreleased messages**
```powershell
Get-QuarantineMessage -RecipientAddress <UPN> -StartExpiresDate (Get-Date).AddDays(-30) |
    Sort-Object ReceivedTime -Descending | Format-Table ReceivedTime, SenderAddress, Subject, QuarantineTypes, Released
```
What the `QuarantineTypes` value means:
- `Spam` — caught by spam filter
- `Phish` — caught as phishing
- `HighConfidencePhish` — near-certain phishing
- `Bulk` — bulk/marketing email
- `Malware` — malware detected

**Step 4 — Check if sender is in tenant allow/block list**
```powershell
# Check sender email or domain
Get-TenantAllowBlockListItems -ListType Sender | Where-Object {$_.Value -like "*<domain.com>*"}

# Check spoofed sender entries
Get-TenantAllowBlockListSpoofItems | Where-Object {$_.SendingInfrastructure -like "*<domain>*"}
```

**Step 5 — Check SCL (Spam Confidence Level) stamp on a delivered message**
In Outlook or OWA: open message > View > View Internet Headers (or more options)
Look for:
```
X-Forefront-Antispam-Report: CIP:<IP>; ... SCL:5; ...
X-Microsoft-Antispam: BCL:0; ...
```
- SCL 0–4: Not spam
- SCL 5–6: Spam (goes to junk folder by default)
- SCL 7–9: High confidence spam (quarantine by default)

**Step 6 — Check anti-spam policy applied to recipient**
```powershell
# List all policies and their rules
Get-HostedContentFilterRule | Select-Object Name, HostedContentFilterPolicy, Priority, Enabled,
    @{N='Recipients';E={$_.SentTo}}, @{N='Groups';E={$_.SentToMemberOf}} | Format-Table -AutoSize
```
Default policy applies to all users not covered by a custom policy (lowest priority = catch-all).

---

## Common Fix Paths

<details><summary>Fix 1 — Release a Quarantined Message</summary>

```powershell
# List quarantined messages for the user
$msgs = Get-QuarantineMessage -RecipientAddress <UPN> -StartExpiresDate (Get-Date).AddDays(-7)
$msgs | Select-Object Identity, ReceivedTime, SenderAddress, Subject, QuarantineTypes | Format-Table

# Release a specific message to the original recipient
Release-QuarantineMessage -Identity "<Identity from above>" -User <UPN>

# Release to an alternative address (review without polluting recipient inbox)
Release-QuarantineMessage -Identity "<Identity>" -ReleaseToExternalEmail <admin@tenant.com>
```

**Note:** If message type is `HighConfidencePhish`, it cannot be released from quarantine directly — requires Global Admin or Security Admin role and explicit confirmation.

**Rollback:** Messages released from quarantine cannot be re-quarantined. If released in error, advise user to delete manually.

</details>

<details><summary>Fix 2 — Add Sender to Tenant Safe Sender List (Allow)</summary>

```powershell
# Allow a specific sender email address
New-TenantAllowBlockListItems -ListType Sender -Allow -Entries "safe@legitsender.com" `
    -ExpirationDate (Get-Date).AddDays(90) -Notes "Whitelisted per ticket #12345"

# Allow an entire domain (use with caution — prefer specific addresses)
New-TenantAllowBlockListItems -ListType Sender -Allow -Entries "*@legitsender.com" `
    -ExpirationDate (Get-Date).AddDays(90) -Notes "Verified vendor domain"
```

**⚠️ Warning:** Domain-level allows bypass spam filtering for ALL senders at that domain. Use only for verified trusted partners. Set an expiration date — never allow indefinitely.

**Rollback:**
```powershell
Remove-TenantAllowBlockListItems -ListType Sender -Ids "<Id from Get-TenantAllowBlockListItems>"
```

</details>

<details><summary>Fix 3 — Adjust Spam Filter Policy (Bulk Threshold)</summary>

```powershell
# Check current bulk complaint level (BCL) threshold — default is 7
Get-HostedContentFilterPolicy -Identity "Default" | Select-Object BulkThreshold, BulkSpamAction

# Increase BCL threshold to allow more bulk mail through (less aggressive)
# Valid range: 1 (very aggressive) to 9 (least aggressive)
Set-HostedContentFilterPolicy -Identity "Default" -BulkThreshold 7 -BulkSpamAction MoveToJmf

# Reduce false positives by lowering spam SCL action from Quarantine to JunkFolder
Set-HostedContentFilterPolicy -Identity "Default" -SpamAction MoveToJmf
```

**Rollback:**
```powershell
Set-HostedContentFilterPolicy -Identity "Default" -BulkThreshold 6 -SpamAction Quarantine
```

</details>

<details><summary>Fix 4 — Create a Custom Anti-Spam Policy for a VIP Group</summary>

```powershell
# Create a permissive policy for executives / VIPs who can't miss important mail
# IMPORTANT: Apply only to a security group, not to "all users"

$policyName = "VIP-Permissive-Spam-Policy"

# Create the policy
New-HostedContentFilterPolicy -Name $policyName `
    -SpamAction MoveToJmf `
    -HighConfidenceSpamAction Quarantine `
    -PhishSpamAction Quarantine `
    -HighConfidencePhishAction Quarantine `
    -BulkThreshold 8 `
    -MakeDefault $false

# Create the rule to apply it to a group
New-HostedContentFilterRule -Name "$policyName-Rule" `
    -HostedContentFilterPolicy $policyName `
    -SentToMemberOf "<VIP-Group-Name>" `
    -Priority 1 `
    -Enabled $true

Write-Host "VIP spam policy created and applied to group." -ForegroundColor Green
```

**Rollback:**
```powershell
Remove-HostedContentFilterRule -Identity "$policyName-Rule" -Confirm:$false
Remove-HostedContentFilterPolicy -Identity $policyName -Confirm:$false
```

</details>

<details><summary>Fix 5 — Remove Sender from Block List</summary>

```powershell
# Find the block list entry
$blockEntry = Get-TenantAllowBlockListItems -ListType Sender |
    Where-Object {$_.Value -like "*<sender or domain>*"}

$blockEntry | Select-Object Id, Value, Action, ExpirationDate, Notes | Format-Table

# Remove the entry
Remove-TenantAllowBlockListItems -ListType Sender -Ids $blockEntry.Id
Write-Host "Block list entry removed." -ForegroundColor Green
```

**Note:** If the sender is blocked by Microsoft's global block list (not your tenant's), you cannot remove it — the sending domain must fix their sending infrastructure (SPF, DKIM, reputation).

</details>

---

## Escalation Evidence

```
TICKET ESCALATION — EOP Mail Filtering Issue
=============================================
Tenant Name        : ___________________________
Tenant Domain      : ___________________________
Date/Time of Issue : ___________________________
Reported By        : ___________________________
Engineer           : ___________________________

AFFECTED USERS
Recipient UPN(s)   : ___________________________
Sender Address(es) : ___________________________
Subject Line       : ___________________________
Approximate Time   : ___________________________

MESSAGE TRACE RESULTS
Message Trace ID   : ___________________________
Status             : ___________________________
Detail Events      : ___________________________

SCL/BCL FROM HEADERS
SCL Value          : ___________________________
BCL Value          : ___________________________
X-Forefront header : ___________________________

QUARANTINE STATUS
In Quarantine?     : Yes / No
Quarantine Type    : ___________________________
Released?          : Yes / No / N/A

POLICY STATE
Filter Policy      : ___________________________
Spam Action        : ___________________________
BCL Threshold      : ___________________________
Custom Rules       : ___________________________

ALLOW/BLOCK LIST
Sender in Allow?   : Yes / No
Sender in Block?   : Yes / No
Entry ID           : ___________________________

STEPS TAKEN
1. ___________________________
2. ___________________________
3. ___________________________

ESCALATION PATH: Microsoft 365 Admin Center > Support > New service request
Select: Exchange Online > Mail delivery issues
Provide: Message Trace ID, SCL headers, and this evidence block
```

---

## 🎓 Learning Pointers

- **SCL (Spam Confidence Level) is the core spam verdict number** — it runs from -1 (bypass) to 9 (definite spam). The default spam filter moves SCL 5-6 to Junk Mail Folder and quarantines SCL 7-9. If legitimate mail is scoring SCL 5+, the sender needs to improve their sending infrastructure (SPF, DKIM, DMARC alignment). Engineers cannot lower the SCL manually — only the sending domain can fix it. See: [SCL overview](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/anti-spam-spam-confidence-level-scl-about)

- **Tenant Allow/Block Lists are the correct tool for per-tenant exceptions** — they replace the old Exchange transport rules for IP/domain blocking. Unlike safe senders in Outlook, TABL entries apply at the EOP level before any client-side rules. Set expiry dates to avoid permanent allow entries accumulating. See: [Manage the Tenant Allow/Block List](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/tenant-allow-block-list-about)

- **Mail not in message trace at all means it was rejected at the SMTP connection layer** — the sending server received a 5xx rejection before EOP processed the message. Common causes: sender IP on a Microsoft blocklist, sending domain has no valid MX/SPF, or the sending IP is listed on a third-party RBL that Microsoft uses. Direct the external admin to check [MXToolbox](https://mxtoolbox.com/blacklists.aspx) and [JMRP/SNDS](https://sendersupport.olc.protection.outlook.com/pm/). See: [Troubleshoot email delivery problems in EOP](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/mail-flow-troubleshooting)

- **DMARC reject policy from a sender domain causes EOP to reject the message outright** if SPF or DKIM alignment fails. This is by design and cannot be overridden by tenant allow lists for `HighConfidencePhish` quarantine. If a legitimate sender has a strict DMARC policy but broken SPF/DKIM, the fix must happen on the sender's DNS. See: [How EOP uses DMARC](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/email-authentication-dmarc-configure)

- **Custom anti-spam policies don't override Microsoft's high-confidence phishing verdicts.** If EOP determines a message is `HighConfidencePhish`, it will be quarantined regardless of BCL threshold settings. This is a safety feature — MSPs should frame this to end users as expected behaviour, not a bug. The only override is adding the sender to the Tenant Allow/Block List, which should be done cautiously.
