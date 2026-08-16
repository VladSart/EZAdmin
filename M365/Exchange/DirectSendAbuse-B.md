# Exchange Online Direct Send Abuse — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

**Disambiguation up front:** this topic is about the **Direct Send *abuse vector*** — external attackers connecting to your tenant's own MX endpoint (`<tenant>.mail.protection.outlook.com`) with no authentication and no license, and successfully delivering mail that *looks* internal because it's addressed from-and-to your own accepted domain. This is **not** the same "direct send" term used in `Mail-Flow-A.md`'s hybrid routing diagram (an on-prem Exchange server sending outbound mail directly via MX rather than through EOP) — that's a legitimate outbound routing pattern between your own servers and EOP. This topic is about **inbound, unauthenticated, spoofed mail arriving through a feature most admins don't know is on by default.**

```powershell
# 1. Confirm current tenant-wide exposure — is Direct Send currently rejectable?
Connect-ExchangeOnline
Get-OrganizationConfig | Select-Object Identity, RejectDirectSend

# 2. Pull a sample of recent messages that used Direct Send delivery
#    (Connectors blank/mismatched = not delivered through your expected connector)
Get-MessageTrace -StartDate (Get-Date).AddDays(-2) -EndDate (Get-Date) |
    Where-Object { $_.RecipientAddress -like "*@<yourdomain.com>" } |
    Select-Object Received, SenderAddress, RecipientAddress, Subject, FromIP

# 3. For a specific suspect message — pull full headers and check the two tell-tale fields
Get-MessageTraceDetail -MessageTraceId <guid> -RecipientAddress <recipient@domain.com>

# 4. Confirm your SPF record's enforcement posture (hard fail vs soft fail vs none)
Resolve-DnsName -Name <yourdomain.com> -Type TXT | Where-Object { $_.Strings -like "*v=spf1*" }

# 5. Check whether legitimate Direct Send senders exist that a blanket reject would break
#    (scanners, ERP systems, alerting appliances, third-party mail mergers)
Get-MessageTrace -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) |
    Where-Object { [string]::IsNullOrEmpty($_.Organization) -or $_.FromIP -notlike "*.outlook.com" } |
    Group-Object SenderAddress | Sort-Object Count -Descending | Select-Object -First 20
```

| Result | Action |
|--------|--------|
| `RejectDirectSend: False` (default) and phishing reports of internal-looking spoofed mail | → Fix 1: Enable RejectDirectSend |
| `RejectDirectSend` not settable / cmdlet not found | → Fix 5: Role/module prerequisite gap |
| Legitimate devices/apps found relying on unauthenticated Direct Send (step 5) | → Fix 2: Migrate them to authenticated SMTP Client Submission or SMTP Relay first |
| SPF record has no hard fail (`~all`/`?all` instead of `-all`) | → Fix 3: Harden SPF before or alongside enabling Reject |
| Anti-spoofing/EOP policies show no distinct handling for intra-org-domain spoofing | → Fix 4: Confirm EOP anti-phishing spoof intelligence is active |
| Enabled RejectDirectSend but legitimate scanner mail now bouncing with 5.7.68 | → Fix 2 (retroactively) — allowlist that specific sender via SMTP Relay/Client Submission, don't disable Reject |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Attacker or unmanaged device connects directly to <tenant>.mail.protection.outlook.com]
  └─ No authentication required by design — Direct Send exists for devices/apps without mailboxes
         │
[Message From/To address both match an accepted domain in your tenant]
  └─ This is what makes the mail LOOK internal to the recipient, regardless of sender identity
         │
[RejectDirectSend organization setting]
  ├─ False (default) → message proceeds to EOP filtering as an "Inbound"/"Anonymous" message
  └─ True → message rejected outright: 550 5.7.68 TenantInboundAttribution
         │
[EOP anti-spam / anti-phishing / spoof intelligence evaluates the message]
  └─ SPF check runs (message is NOT exempt from SPF like true intra-org mail is)
  └─ Hard-fail SPF (-all) + no allowlisted sending IP → high confidence spoof / can be quarantined
  └─ Soft-fail or no SPF enforcement → message likely reaches the inbox looking fully legitimate
         │
[Recipient sees mail "From" a coworker/executive, no external-sender warning applies]
  └─ Business Email Compromise (BEC) / lateral phishing risk realized
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the current tenant-wide RejectDirectSend state**
```powershell
Get-OrganizationConfig | Select-Object Identity, RejectDirectSend
```
Default is `False` — Direct Send is exposed by default, not something anyone had to opt into.

**2. Confirm whether a suspect message was actually delivered via Direct Send**

In Message Trace / Defender for Office 365 message header analysis, look for:
```
X-MS-Exchange-Organization-MessageDirectionality: Incoming
X-MS-Exchange-Organization-AuthAs: Anonymous
```
Legitimate intra-org mail (sent via Outlook/OWA/an authenticated connector) instead shows `MessageDirectionality: Originating` and `AuthAs: Internal`, and is exempt from SPF checking — Direct Send-delivered mail is **not** exempt, which is exactly what makes SPF your best lever short of an outright block.

**3. Check the `ConnectorName`/`Connectors` field in message trace**

If it's blank or doesn't match any connector you configured, the message arrived without going through an authenticated path — a strong Direct Send indicator alongside the headers above.

**4. Confirm your SPF record's enforcement**
```powershell
Resolve-DnsName -Name <yourdomain.com> -Type TXT | Where-Object { $_.Strings -like "*v=spf1*" }
```
`-all` = hard fail (recommended). `~all` = soft fail (message still often delivered, just marked). `?all`/no SPF = neutral, provides essentially no protection against this vector.

**5. Inventory legitimate Direct Send dependents before blocking anything**

Scanners, multifunction printers, on-prem line-of-business apps, and some third-party mail-merge/notification tools frequently rely on unauthenticated Direct Send without anyone documenting it. Enabling `RejectDirectSend` tenant-wide with no inventory pass is the single most common way this fix turns into a second outage.

---
## Common Fix Paths

<details><summary>Fix 1 — Enable RejectDirectSend</summary>

Use when: Direct Send abuse is confirmed or the risk is judged unacceptable, and step 5's inventory pass found no dependent legitimate senders (or they've already been migrated per Fix 2).

```powershell
Set-OrganizationConfig -RejectDirectSend $true

# Verify — change propagates tenant-wide within ~30 minutes
Get-OrganizationConfig | Select-Object Identity, RejectDirectSend
```

Requires an administrator with the **Organization Configuration** RBAC role (typically covered by Exchange Administrator/Global Administrator).

Once enabled, any unauthenticated Direct Send attempt is rejected at the SMTP level with:
```
550 5.7.68 TenantInboundAttribution; Direct Send not allowed for this organization from unauthorized sources
```

**Rollback:** `Set-OrganizationConfig -RejectDirectSend $false` — restores unauthenticated Direct Send tenant-wide immediately. Only roll back if a genuinely undocumented legitimate sender broke and there's no time to migrate it same-day; treat as temporary.

</details>

<details><summary>Fix 2 — Migrate a legitimate Direct Send dependent off unauthenticated submission</summary>

Use when: step 5's inventory (or a post-Fix-1 bounce) surfaces a real device/app that needs to keep sending.

Two supported alternatives, in order of preference:
1. **SMTP AUTH Client Submission** — the app/device authenticates with a licensed mailbox's credentials (or a service account) and submits via `smtp.office365.com:587`. Requires SMTP AUTH enabled for that mailbox (`Set-CASMailbox -Identity <mailbox> -SmtpClientAuthenticationDisabled $false`, and tenant-wide SMTP AUTH not blocked).
2. **SMTP Relay via a static/certificate-based connector** — for devices that can't do per-mailbox auth (many scanners/printers), configure a dedicated inbound connector scoped to the device's IP (or a certificate), which lets it relay without consuming a mailbox license and without depending on Direct Send's unauthenticated path.

```powershell
# Enable SMTP AUTH for a specific mailbox being migrated to Client Submission
Set-CASMailbox -Identity <mailbox@domain.com> -SmtpClientAuthenticationDisabled $false
```

**Rollback:** Revert the mailbox/connector change; the device falls back to whatever it was doing before (Direct Send, if `RejectDirectSend` is still `False`).

</details>

<details><summary>Fix 3 — Harden SPF to hard fail as an interim/defense-in-depth control</summary>

Use when: RejectDirectSend can't be enabled immediately (undocumented dependents still being inventoried), or as a permanent second layer even after Fix 1.

Update the domain's SPF TXT record so it ends in `-all` rather than `~all`/`?all`, and ensure it explicitly lists every legitimate sending source (`include:spf.protection.outlook.com` plus any on-prem/third-party sending IPs).

```
v=spf1 include:spf.protection.outlook.com include:<third-party-sender> -all
```

This does not stop Direct Send delivery attempts from reaching EOP, but because Direct Send-delivered mail is **not** exempt from SPF evaluation (unlike true intra-org mail), a hard-fail SPF record combined with EOP's anti-phishing/spoof-intelligence policies gives a real chance of quarantining spoofed messages even before RejectDirectSend is enabled.

**Rollback:** Revert to the prior SPF record if hardening breaks a sender that was relying on a soft-fail's more forgiving delivery — but treat that sender as one needing to be added explicitly via `include:`, not as a reason to abandon hard fail.

</details>

<details><summary>Fix 4 — Confirm EOP anti-phishing spoof intelligence is active</summary>

Use when: SPF is already hard-fail and RejectDirectSend can't be enabled yet, but spoofed internal-looking mail is still landing in inboxes.

```powershell
Get-AntiPhishPolicy | Select-Object Name, EnableSpoofIntelligence, AuthenticationFailAction
Get-HostedContentFilterPolicy | Select-Object Name, SpamAction, HighConfidenceSpamAction
```

Confirm `EnableSpoofIntelligence` is `$true` and `AuthenticationFailAction` is set to quarantine (not just tag) for messages that fail composite authentication. This is a defense-in-depth layer, not a substitute for Fix 1 — Direct Send mail from an IP that happens to have a clean reputation can still slip past spoof intelligence heuristics.

**Rollback:** N/A — policy review, not a destructive change.

</details>

<details><summary>Fix 5 — RejectDirectSend cmdlet/property not available</summary>

Use when: `Set-OrganizationConfig -RejectDirectSend` errors with an unrecognized parameter.

Confirm the Exchange Online PowerShell module (`ExchangeOnlineManagement`) is current — `RejectDirectSend` is a comparatively new organization-config property and older cached module versions won't recognize it.

```powershell
Get-Module ExchangeOnlineManagement -ListAvailable | Select-Object Version
Update-Module ExchangeOnlineManagement -Force
```

Also confirm the connecting account holds the **Organization Configuration** role — read access alone (Global Reader) can retrieve `Get-OrganizationConfig` output but cannot set the property.

**Rollback:** N/A — prerequisite fix, no config change involved.

</details>

---
## Escalation Evidence

```
DIRECT SEND ABUSE ESCALATION
=============================
Date/Time                          :
Tenant ID / Domain                 :
RejectDirectSend current state     : True / False
Sample suspect NetworkMessageId(s)  :
X-MS-Exchange-Organization-MessageDirectionality (Incoming/Originating) :
X-MS-Exchange-Organization-AuthAs (Anonymous/Internal)                 :
ConnectorName / Connectors field   :
SPF record enforcement (-all / ~all / ?all / none) :
Known legitimate Direct Send dependents identified :
Migration status of those dependents (SMTP AUTH / Relay / not yet) :
Anti-phish spoof intelligence enabled? : YES / NO
Number of affected recipients      :
Steps already tried                :
```

---
## 🎓 Learning Pointers

- **This is a documented, ongoing architectural limitation — not a bug Microsoft has committed to fixing platform-wide.** A phishing campaign abusing this exact vector was reported affecting 70+ organizations starting around May 2025. Microsoft briefly deployed an automatic internal-spoofing mitigation in April 2026, then rolled it back days later, and as of their most recent public communication classifies the behavior as a known architectural limitation rather than a vulnerability — meaning the burden of mitigation sits with each tenant, via `RejectDirectSend`, SPF hardening, and EOP anti-phishing configuration, not a forthcoming default-on fix. [Introducing more control over Direct Send in Exchange Online](https://techcommunity.microsoft.com/blog/exchange/introducing-more-control-over-direct-send-in-exchange-online/4408790)
- **Direct Send exists on purpose, for a narrow legitimate use case, with authentication skipped by design.** It's meant for devices and line-of-business apps that can't hold a mailbox license or perform SMTP AUTH — a scanner or ERP system sending intra-org notification mail. The abuse vector isn't a flaw in that use case; it's that the same unauthenticated path accepts mail from anyone on the internet who knows your tenant's MX name, with no verification that the connecting party is actually one of your own devices.
- **The header pair to memorize:** `MessageDirectionality: Incoming` + `AuthAs: Anonymous` = arrived from outside, subject to full filtering including SPF. `MessageDirectionality: Originating` + `AuthAs: Internal` = genuinely sent by an authenticated mailbox/connector, SPF-exempt. Confusing these two is the most common false-negative when triaging a suspected spoof.
- **RejectDirectSend defaults to off and is entirely opt-in.** A tenant that has never touched this setting is, by definition, exposed — this isn't a "if you changed a setting you're at risk" scenario, it's "if you haven't changed a setting you're at risk."
- **Before enabling a tenant-wide reject, inventory who's actually using Direct Send.** The most common self-inflicted outage from this fix isn't the reject itself — it's discovering, after the fact, that a scanner, alerting appliance, or a vendor's notification service had been quietly relying on unauthenticated Direct Send for years with no documentation anywhere.
- **Community/reference:** [Rapid7: Microsoft 365 Direct Send Abuse](https://www.rapid7.com/blog/post/dr-microsoft-365-direct-send-abuse/) | [Varonis: Ongoing Campaign Abuses Microsoft 365's Direct Send](https://www.varonis.com/blog/direct-send-exploit) | [Set-OrganizationConfig (ExchangePowerShell) — Microsoft Learn](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-organizationconfig)
