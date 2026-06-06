# Exchange Online — Agent Instructions

## What's in this folder

Exchange Online — cloud-hosted email, calendar, and messaging within Microsoft 365.

Covers:
- **Mail flow** — inbound/outbound delivery, NDRs, bounces, stuck messages, transport rules, connectors
- **Shared mailboxes** — access, permissions, AutoMapping, Send As, Send On Behalf, calendar delegates
- **Calendars** — delegate access, room/resource mailboxes, free/busy visibility, calendar sharing
- **Hybrid coexistence** — on-prem Exchange routing through Exchange Online, Hybrid Configuration Wizard, hybrid connectors, certificate issues
- **Spam and phishing** — EOP (Exchange Online Protection) policies, Safe Sender lists, quarantine, anti-phishing rules
- **Connectors** — inbound/outbound connectors, partner connectors, on-prem relay, TLS enforcement

---

## Before responding, also check

- `EntraID/` — authentication failures, SSO issues, OAuth token errors affecting Outlook and OWA
- `Security/Defender/` (when built) — Defender for Office 365, Safe Links, Safe Attachments, ZAP policies
- `M365/Licensing/` — missing Exchange Plan 1 or Plan 2 service plan; shared mailbox licensing for archiving
- `Security/ConditionalAccess/` — CA policies blocking Outlook (modern auth) or ActiveSync (legacy auth)

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Mail-Flow-B.md` | Hotfix: email not arriving, bouncing, stuck, going to spam, NDR codes |
| `Mail-Flow-A.md` | Deep dive: mail flow architecture, transport rules, connectors, DMARC |
| `SharedMailbox-B.md` | Hotfix: can't access shared mailbox, Send As failing, AutoMapping, calendar permissions |
| `Hybrid-Coexistence-B.md` | Hotfix: on-prem to EXO routing, hybrid connector failures, certificate expiry |

---

## Common entry points

- "User not receiving emails / emails bouncing" → `Mail-Flow-B.md`
- "Email going to spam / quarantine incorrectly" → `Mail-Flow-B.md` (spam filter section)
- "Email stuck in transit / delayed hours/days" → `Mail-Flow-B.md` (4.4.7 NDR section)
- "Can't open shared mailbox in Outlook" → `SharedMailbox-B.md`
- "Shared mailbox not showing in Outlook left-pane" → `SharedMailbox-B.md` (AutoMapping)
- "Send As / Send On Behalf not working from shared mailbox" → `SharedMailbox-B.md`
- "Shared mailbox calendar permissions broken" → `SharedMailbox-B.md` (calendar delegate section)
- "On-prem users can't email cloud users or vice versa" → `Hybrid-Coexistence-B.md`
- "Hybrid connector certificate expired" → `Hybrid-Coexistence-B.md`
- "SPF / DKIM / DMARC failing, email rejected by recipient" → `Mail-Flow-B.md`
- "Transport rule blocking legitimate email" → `Mail-Flow-B.md` (transport rules section)

---

## Key diagnostic commands

```powershell
# Connect to Exchange Online
Connect-ExchangeOnline -UserPrincipalName admin@contoso.com

# Mail flow trace — covers last 10 days, 250 results max per query
Get-MessageTrace `
  -SenderAddress sender@contoso.com `
  -RecipientAddress recipient@contoso.com `
  -StartDate (Get-Date).AddDays(-2) `
  -EndDate (Get-Date) |
  Select Received, SenderAddress, RecipientAddress, Subject, Status, ToIP, FromIP

# Detailed trace for a specific message (get MessageTraceId from above)
Get-MessageTraceDetail -MessageTraceId <guid> -RecipientAddress recipient@contoso.com

# Check mailbox existence and properties
Get-Mailbox -Identity shared@contoso.com |
  Select DisplayName, PrimarySmtpAddress, RecipientTypeDetails, IsShared, LitigationHoldEnabled

# Check mobile device sync state (ActiveSync / Outlook Mobile)
Get-MobileDeviceStatistics -Mailbox user@contoso.com |
  Select DeviceFriendlyName, LastSyncAttemptTime, Status, DeviceOS

# Test client connectivity (MAPI/RPC)
Test-MAPIConnectivity -Identity user@contoso.com

# Check mailbox permissions (for shared mailbox issues)
Get-MailboxPermission -Identity shared@contoso.com |
  Where-Object { $_.User -notlike "NT AUTHORITY*" } |
  Select User, AccessRights, IsInherited

# Check transport rules (mail flow rules)
Get-TransportRule | Select Name, State, Priority, Description | Sort-Object Priority

# Check connectors
Get-InboundConnector | Select Name, Enabled, ConnectorType, TlsSenderCertificateName
Get-OutboundConnector | Select Name, Enabled, ConnectorType, SmartHosts

# Check anti-spam / quarantine policies
Get-HostedContentFilterPolicy | Select Name, SpamAction, HighConfidenceSpamAction, BulkSpamAction
```

---

## Key dependency chain

```
[User identity in Entra ID]
         │
         ▼
[Exchange Online mailbox provisioned]
  (requires Exchange Plan 1 or Plan 2 licence)
         │
         ▼
[DNS: MX record → *.mail.protection.outlook.com]
[DNS: Autodiscover CNAME → autodiscover.outlook.com]
         │
         ▼
[Exchange Online Protection (EOP)]
  Anti-spam → Anti-phishing → Safe Attachments/Links
         │
         ▼
[Transport Rules evaluated]
  (org-level rules, then connector rules)
         │
         ▼
[Mailbox Rules evaluated]
  (user-level Inbox rules — run AFTER transport rules)
         │
         ▼
[Delivery to mailbox]
  (subject to mailbox quota, litigation hold, archive policy)
         │
         ▼
[Client authentication]
  Modern Auth (MAPI/OAuth) → Outlook, OWA, Outlook Mobile
  Legacy Auth (Basic/NTLM) → blocked by Conditional Access in most tenants
```

**Hybrid add-on (when on-prem Exchange exists):**
```
[On-prem Exchange] → [Hybrid Send Connector] → [EXO Protection] → [Cloud mailbox]
                  ← [Hybrid Receive Connector] ←
  (certificate on hybrid connector must be valid and match TLS name)
```

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — `Get-MessageTrace` → identify failure point in the chain → fix → validate delivery
2. **Deep Dive** — mail flow architecture, EOP pipeline, transport rule evaluation order, hybrid topology
3. **Learning Pointers** — what to go deeper on after the ticket is closed
