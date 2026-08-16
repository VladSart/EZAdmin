# Exchange Online Direct Send Abuse — Reference Runbook (Mode A: Deep Dive)
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

Covers the **abuse of Exchange Online's Direct Send feature** to deliver unauthenticated mail that spoofs internal senders — an attacker (or an unmanaged/undocumented device) connecting directly to a tenant's own MX endpoint (`<tenant-name>.mail.protection.outlook.com`) and successfully delivering a message where both the sender and recipient addresses belong to the tenant's own accepted domain(s), with no authentication of any kind.

**Does not cover:**
- **"Direct send" as a hybrid mail-flow routing term** — `Mail-Flow-A.md`'s Dependency Cascade uses "direct send" to describe an outbound connector configuration (`UseMXRecord = $true`) where on-prem Exchange routes outbound mail straight to a recipient's MX rather than through Exchange Online. That is a legitimate, deliberate routing choice between mail servers you control. This topic is about **inbound**, unauthenticated mail arriving through a feature separate from that routing concept — the shared term is coincidental and worth calling out explicitly to avoid conflating the two in a ticket or a client conversation.
- **General SMTP relay/open relay misconfiguration on-prem** — Direct Send is an Exchange Online-specific feature (unauthenticated submission accepted at the tenant's own MX for intra-org delivery); an on-prem open relay is a different, older class of misconfiguration with its own remediation.
- **DKIM/DMARC configuration mechanics** — see `DMARC-DKIM-A.md`/`-B.md` for setting up these records; this topic assumes SPF/DKIM/DMARC exist and focuses specifically on why Direct Send bypasses the protection they'd otherwise provide for genuinely external mail.
- **General EOP anti-phishing/quarantine policy tuning** — see the broader Exchange/Defender for Office 365 anti-spam documentation for policy design outside this specific vector.

**Assumes:** Exchange Administrator or Global Administrator access for `Set-OrganizationConfig`; `ExchangeOnlineManagement` PowerShell module current enough to expose `RejectDirectSend`; familiarity with SPF record syntax.

---
## How It Works

<details><summary>Full architecture</summary>

### What Direct Send is, and who it's for

Direct Send is a long-standing Exchange Online capability that lets a device or application deliver mail to mailboxes in your own tenant **without authenticating and without consuming a mailbox license** — by connecting directly to your tenant's MX endpoint, `<tenant-name>.mail.protection.outlook.com`, and submitting SMTP. It exists for a genuinely useful, narrow purpose: multifunction printers/scanners that email a scanned document to an internal user, on-prem line-of-business applications generating notification email, monitoring/alerting appliances, and similar systems that have no mailbox of their own and can't easily be configured to perform SMTP AUTH.

Because it requires **only** that the message's From and To addresses both resolve to an accepted domain in the tenant — not that the connecting party prove it is who it claims to be — Direct Send has no inherent way to distinguish "our own scanner, sending a legitimate scan notification" from "an attacker anywhere on the internet who has looked up our tenant's MX record and is submitting mail claiming to be our CFO."

### Why this bypasses normal anti-spoofing protection

Exchange Online treats genuinely internal mail — sent via Outlook, OWA, or an authenticated connector — as exempt from most external-mail filtering, because it's provably internal. This exemption is visible in message headers as:

```
X-MS-Exchange-Organization-MessageDirectionality: Originating
X-MS-Exchange-Organization-AuthAs: Internal
```

Direct Send-delivered mail does **not** get this treatment. It's correctly classified by Exchange Online Protection (EOP) as external/anonymous:

```
X-MS-Exchange-Organization-MessageDirectionality: Incoming
X-MS-Exchange-Organization-AuthAs: Anonymous
```

...which means it **is** subject to full EOP filtering, SPF/DKIM/DMARC evaluation, and anti-phishing spoof intelligence, exactly like any other inbound external message. This is the crucial nuance: Direct Send abuse isn't a filtering bypass in the strict sense — it's that the message's From address matching an accepted domain, combined with the recipient seeing a from-address that looks like a coworker with no "external sender" banner, produces a highly convincing phishing pretext even when EOP correctly flags it as externally-originated. Whether the message is actually blocked, quarantined, or delivered comes down entirely to how the tenant's SPF record and anti-phishing policy are configured — a tenant with a weak (`~all`/`?all`) SPF record and default-tolerant spoof intelligence settings will often let these messages straight into the inbox.

### The 2025–2026 campaign and Microsoft's response timeline

A phishing campaign specifically abusing this vector was identified affecting more than 70 organizations across multiple industries, with reporting placing the campaign's start around May 2025. The pattern: external attackers connect to a target tenant's own MX endpoint and send messages that appear to originate from a coworker or executive within that same tenant, exploiting exactly the "looks internal" effect described above to improve phishing/BEC success rates.

Microsoft's response has been an evolving, opt-in mitigation rather than a platform-wide default change:
- An opt-in `RejectDirectSend` organization-config property was introduced to let tenants explicitly reject unauthenticated Direct Send traffic.
- In April 2026, Microsoft briefly deployed a broader, automatic internal-spoofing mitigation — then rolled it back within days.
- By Microsoft's most recent public communication (~May 2026), the company characterized the underlying behavior as a **known architectural limitation, not a product vulnerability**, with no committed platform-level fix. This distinction matters operationally: it means tenants should not expect Microsoft to close this gap by default on their behalf, and should treat `RejectDirectSend` plus SPF/anti-phishing hardening as the durable mitigation, not a stopgap awaiting a permanent upstream fix.

### `RejectDirectSend` mechanics

`Set-OrganizationConfig -RejectDirectSend $true` tells Exchange Online to reject, at the SMTP level, any message submitted via the unauthenticated Direct Send path from a source not otherwise authorized (i.e., not coming through a connector, not authenticated via SMTP AUTH). Rejected messages receive:

```
550 5.7.68 TenantInboundAttribution; Direct Send not allowed for this organization from unauthorized sources
```

The setting is tenant-wide (there's no per-domain or per-recipient granularity), defaults to `$false` (Direct Send remains fully open unless an admin explicitly opts in to rejecting it), requires the **Organization Configuration** RBAC role to change, and propagates across the service within roughly 30 minutes of being set.

Enabling this setting has no effect on genuinely authenticated mail flows — Outlook/OWA client sends, hybrid connector-based mail, and properly configured SMTP AUTH Client Submission or SMTP Relay connectors are entirely unaffected, because none of those rely on the unauthenticated Direct Send path in the first place.

### Detecting existing Direct Send usage before disabling it

Because Direct Send has historically been undocumented tribal knowledge in many environments (a scanner configured years ago by someone no longer at the company is the canonical example), a detection pass before flipping `RejectDirectSend` is worth the time it takes. Two header fields, examined via message trace or Defender for Office 365's Advanced Hunting `EmailEvents` table, distinguish Direct Send-delivered mail from genuine intra-org mail:

| Signal | Genuine intra-org mail | Direct Send (legit or abused) |
|---|---|---|
| `X-MS-Exchange-Organization-MessageDirectionality` | `Originating` | `Incoming` |
| `X-MS-Exchange-Organization-AuthAs` | `Internal` | `Anonymous` |
| `EmailDirection` (Advanced Hunting) | `Intra-org` | `Inbound` |
| `Connectors` field in message trace | Populated / matches expected connector | Blank |
| SPF evaluated? | No — exempt | Yes |

A representative Advanced Hunting KQL query (Defender for Office 365 Plan 2 required) to surface Direct Send traffic against your own accepted domains:

```kql
EmailEvents
| extend auth = parse_json(AuthenticationDetails)
| where SenderFromDomain in ("<accepted-domain-1>", "<accepted-domain-2>")
    and RecipientDomain in ("<accepted-domain-1>", "<accepted-domain-2>")
| where isempty(Connectors) and EmailDirection == "Inbound"
| project Timestamp, SenderFromAddress, RecipientEmailAddress, Subject, AuthenticationDetails, NetworkMessageId, SenderIPv4
```

This distinguishes true Direct Send traffic from ordinary intra-org mail (which would show `EmailDirection == "Intra-org"` with no SPF data at all, since it's exempt) — giving a concrete list of senders to either identify as legitimate (and migrate per the Remediation Playbooks below) or treat as confirmed abuse.

</details>

---
## Dependency Stack

```
[Tenant's MX record points to <tenant-name>.mail.protection.outlook.com]
         │
         ▼
[Direct Send accepts unauthenticated SMTP submission at that endpoint]
  (by design — no mailbox license or SMTP AUTH required)
         │
         ▼
[Message From + To both match an accepted domain in the tenant]
  (this is the ONLY gate — no proof the sender is who/what it claims to be)
         │
         ▼
[RejectDirectSend organization-config property]
  False (default) → proceeds to EOP        |  True → rejected: 550 5.7.68 TenantInboundAttribution
         │
         ▼
[EOP classifies the message: MessageDirectionality=Incoming, AuthAs=Anonymous]
  (NOT exempt from SPF — unlike genuine intra-org mail)
         │
         ▼
[SPF record evaluated against the connecting IP]
  -all (hard fail) + IP not authorized → strong spoof signal, can be quarantined
  ~all/?all/none → weak or no signal, message likely proceeds
         │
         ▼
[Anti-phishing spoof intelligence + content filtering evaluate the message]
         │
         ▼
[Delivered to inbox, appearing to originate from a coworker — no external-sender banner applies
 because the From address IS an accepted-domain address]
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Users report receiving mail that appears to be from a coworker/executive, asking for gift cards/wire transfers/credential entry | Direct Send abuse — external sender spoofing an internal address via the unauthenticated MX path | Check message headers for `MessageDirectionality: Incoming` + `AuthAs: Anonymous` |
| Multiple internal-looking phishing reports with no external-sender warning banner shown | Same as above — the From address matches an accepted domain, so no external-sender UI cue fires | Same header check; also confirm `RejectDirectSend` state |
| `RejectDirectSend` enabled but a scanner/printer/LOB app suddenly can't send notification email, bouncing with 5.7.68 | Legitimate Direct Send dependent not yet migrated to authenticated submission | Cross-reference the bouncing sender IP/app against a pre-enablement inventory; migrate via Playbook 1 |
| Spoofed mail passes through despite SPF appearing configured | SPF record uses `~all`/`?all` (soft fail/neutral) rather than `-all`, or doesn't list all legitimate sending sources | `Resolve-DnsName -Type TXT` on the domain; confirm enforcement qualifier |
| Direct Send abuse confirmed but `RejectDirectSend` cmdlet unavailable | Outdated `ExchangeOnlineManagement` module, or connecting account lacks Organization Configuration role | `Get-Module ExchangeOnlineManagement -ListAvailable`; confirm RBAC role assignment |
| Uncertain whether a given past incident was Direct Send or a genuinely compromised mailbox | Both can produce "mail from a coworker that they didn't send" — the header pair above is the deciding evidence, not the sender's account audit log (a Direct Send message never touches the sender's actual mailbox) | Confirm via message headers first, before investigating account compromise on the apparent sender's mailbox |
| Reject enabled tenant-wide but abuse mail still occasionally reported | Confirm the reported message actually failed to reject — check whether it was sent before the ~30-minute propagation window completed, or whether it's an unrelated vector (compromised mailbox, look-alike domain) rather than true Direct Send | Pull headers for the specific reported message and confirm `AuthAs`/`MessageDirectionality` values match the Direct Send pattern before assuming the control failed |

---
## Validation Steps

**Step 1 — Confirm current RejectDirectSend state**
```powershell
Get-OrganizationConfig | Select-Object Identity, RejectDirectSend
```

**Step 2 — Run the Advanced Hunting query (Defender for Office 365 Plan 2) to inventory current Direct Send traffic**

See the KQL query in How It Works above. Run before making any change — this is the single most useful validation step, since it surfaces both abuse and legitimate dependents in one pass.

**Step 3 — Confirm SPF enforcement qualifier**
```powershell
Resolve-DnsName -Name <yourdomain.com> -Type TXT | Where-Object { $_.Strings -like "*v=spf1*" }
```
Look specifically at the qualifier before `all`: `-all` (hard fail), `~all` (soft fail), `?all` (neutral), or its complete absence.

**Step 4 — Confirm anti-phishing spoof intelligence configuration**
```powershell
Get-AntiPhishPolicy | Select-Object Name, EnableSpoofIntelligence, AuthenticationFailAction, EnableSpoofIntelligenceForDomains
```

**Step 5 — For a specific reported message, confirm the Direct Send header signature**

Pull the full header set via Message Trace + `Get-MessageTraceDetail`, or via the Defender for Office 365 email entity page, and copy into a header analyzer if needed. Confirm both `MessageDirectionality` and `AuthAs` before concluding a message was Direct Send-delivered rather than sent from a genuinely compromised mailbox (a compromised mailbox's outbound mail shows `Originating`/`Internal` — a materially different investigation path).

**Step 6 — After enabling RejectDirectSend, confirm propagation and test rejection**
```powershell
Get-OrganizationConfig | Select-Object RejectDirectSend
# Allow up to 30 minutes for the change to take effect tenant-wide before testing
```

---
## Troubleshooting Steps (by phase)

### Phase 1: Confirm the vector

1. Pull headers for a representative reported message; confirm `MessageDirectionality: Incoming` + `AuthAs: Anonymous` before proceeding — don't assume Direct Send without this confirmation, since account compromise produces a superficially similar user complaint ("I got mail that looked like it was from X") with an entirely different root cause and remediation path.

### Phase 2: Inventory before you block

1. Run the Advanced Hunting KQL query (or the equivalent message-trace sweep for tenants without Defender for Office 365 Plan 2) across at least the last 7–30 days.
2. Separate results into confirmed-malicious sender patterns vs. unidentified senders that need follow-up with business units (a device/app nobody remembers configuring is common) before assuming everything in the list is abuse.

### Phase 3: Harden before or alongside blocking

1. Confirm SPF is hard-fail (`-all`) and lists every legitimate sending source, including any Direct Send dependents identified in Phase 2 that haven't yet been migrated.
2. Confirm anti-phishing spoof intelligence is enabled as defense-in-depth, independent of whether Direct Send itself gets blocked.

### Phase 4: Block

1. Enable `RejectDirectSend` once Phase 2's inventory is either fully migrated (Playbook 1) or confirmed empty.
2. Monitor for 550 5.7.68 bounces in the days following — each one is either confirmation the control is working (external abuse attempt blocked) or a missed legitimate dependent that needs migrating.

### Phase 5: Sustain

1. Re-run the Phase 2 inventory query periodically (quarterly is reasonable) — new devices/apps get added to environments continuously, and a `RejectDirectSend`-enabled tenant will simply start bouncing them rather than silently accepting risk, which is the correct failure mode but still needs a documented path to remediate.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrating legitimate Direct Send dependents to authenticated submission</summary>

**When:** Phase 2's inventory surfaces a real device/app relying on unauthenticated Direct Send, ahead of enabling `RejectDirectSend`.

1. For devices/apps that can perform basic SMTP AUTH: enable SMTP AUTH Client Submission against a dedicated mailbox or shared mailbox.
```powershell
Set-CASMailbox -Identity <mailbox@domain.com> -SmtpClientAuthenticationDisabled $false
```
Confirm tenant-wide SMTP AUTH isn't globally disabled (a common hardening measure that would need a documented, scoped exception for this mailbox).

2. For devices that can't perform per-mailbox authentication (many multifunction printers/scanners): configure a dedicated SMTP Relay connector scoped to the device's static IP or a client certificate, which doesn't require a mailbox license and doesn't depend on Direct Send's unauthenticated path.

3. Validate the migrated sender's mail flow end-to-end before the tenant-wide `RejectDirectSend` cutover, ideally with `RejectDirectSend` already enabled in a controlled test if a lower environment exists, or during a defined maintenance window.

**Rollback:** Revert the mailbox/connector configuration; the device falls back to Direct Send if `RejectDirectSend` is still `$false` at that point.

</details>

<details><summary>Playbook 2 — SPF/anti-phishing hardening as a standing defense-in-depth layer</summary>

**When:** Alongside or ahead of `RejectDirectSend` enablement, and maintained permanently afterward — this isn't a one-time interim fix, it's a durable second layer.

1. Confirm the domain's SPF record ends in `-all` and lists every legitimate sending source explicitly (`include:spf.protection.outlook.com` plus any third-party mail services and any remaining, migrated Direct Send relay IPs).
2. Confirm DKIM signing is enabled for the domain and DMARC is published with at minimum `p=quarantine` (ideally `p=reject` once confidence in the SPF/DKIM alignment is high) — see `DMARC-DKIM-A.md` for the mechanics of setting these up if not already in place.
3. Confirm anti-phishing policy spoof intelligence is enabled with `AuthenticationFailAction` set to quarantine rather than a softer action.

**Rollback:** N/A — this is additive hardening; reverting SPF to a weaker qualifier or disabling spoof intelligence would only be done to unblock a specific misconfigured legitimate sender temporarily, and should be treated as a gap to close, not a stable end state.

</details>

<details><summary>Playbook 3 — Tenant-wide RejectDirectSend rollout</summary>

**When:** Phase 2's inventory is fully migrated or confirmed empty, and Playbook 2's hardening is in place as a second layer.

1. Enable the setting:
```powershell
Set-OrganizationConfig -RejectDirectSend $true
```
2. Communicate the change to IT/helpdesk ahead of time so a post-cutover 5.7.68 bounce is recognized immediately as "a Direct Send dependent we missed" rather than escalated as an unrelated mail-flow outage.
3. Monitor message trace/bounce reports for the following 1–2 weeks specifically for 5.7.68 NDRs, since infrequent-but-legitimate senders (a monthly batch job, a rarely-used alerting appliance) may not surface in a 7–30 day inventory window.

**Rollback:** `Set-OrganizationConfig -RejectDirectSend $false` — immediate, tenant-wide, restores unauthenticated Direct Send. Use only as a short-term unblock for a missed legitimate dependent while it's migrated per Playbook 1, not as a long-term response to the rollout surfacing gaps.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Direct Send exposure and configuration evidence for escalation or a hardening decision
.NOTES     Requires ExchangeOnlineManagement connected. Read-only.
#>

$output = [System.Collections.Generic.List[string]]::new()
$ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
$out    = ".\DirectSendEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"

function Add-Section {
    param([string]$Title, [scriptblock]$Body)
    $output.Add("=" * 60)
    $output.Add("  $Title")
    $output.Add("=" * 60)
    try { $output.Add((&$Body | Out-String).Trim()) }
    catch { $output.Add("ERROR: $($_.Exception.Message)") }
    $output.Add("")
}

Add-Section "Collection metadata" { "Collected : $ts" }

Add-Section "RejectDirectSend state" {
    Get-OrganizationConfig | Select-Object Identity, RejectDirectSend | Format-List | Out-String
}

Add-Section "Anti-phishing spoof intelligence" {
    Get-AntiPhishPolicy | Select-Object Name, EnableSpoofIntelligence, AuthenticationFailAction | Format-Table -AutoSize | Out-String
}

Add-Section "Recent message trace sample (last 2 days, adjust domain filter)" {
    Get-MessageTrace -StartDate (Get-Date).AddDays(-2) -EndDate (Get-Date) |
        Select-Object Received, SenderAddress, RecipientAddress, Subject, FromIP |
        Format-Table -AutoSize | Out-String
}

$output | Set-Content -Path $out -Encoding UTF8
Write-Host "Evidence saved to: $out" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check current RejectDirectSend state | `Get-OrganizationConfig \| Select RejectDirectSend` |
| Enable RejectDirectSend | `Set-OrganizationConfig -RejectDirectSend $true` |
| Disable (rollback) | `Set-OrganizationConfig -RejectDirectSend $false` |
| Message trace (last 2 days) | `Get-MessageTrace -StartDate (Get-Date).AddDays(-2) -EndDate (Get-Date)` |
| Detailed header trace for one message | `Get-MessageTraceDetail -MessageTraceId <guid> -RecipientAddress <addr>` |
| Check SPF record | `Resolve-DnsName -Name <domain> -Type TXT` |
| Check anti-phishing spoof intelligence | `Get-AntiPhishPolicy \| Select EnableSpoofIntelligence,AuthenticationFailAction` |
| Enable SMTP AUTH for a mailbox (migration) | `Set-CASMailbox -Identity <mbx> -SmtpClientAuthenticationDisabled $false` |
| Advanced Hunting: find Direct Send traffic | KQL against `EmailEvents` — see How It Works |
| Update Exchange Online module (if RejectDirectSend unrecognized) | `Update-Module ExchangeOnlineManagement -Force` |

---
## 🎓 Learning Pointers

- **Microsoft has explicitly classified this as an architectural limitation, not a vulnerability it intends to close by default.** After briefly deploying and then rolling back a broader automatic mitigation in April 2026, Microsoft's most recent public position (as of ~May 2026) leaves `RejectDirectSend` as an opt-in tenant responsibility. Any client asking "will Microsoft just fix this" needs a clear, honest answer: not on a committed timeline, and the current control surface (RejectDirectSend + SPF + anti-phishing) is the durable answer, not a stopgap. [Introducing more control over Direct Send in Exchange Online — Microsoft Tech Community](https://techcommunity.microsoft.com/blog/exchange/introducing-more-control-over-direct-send-in-exchange-online/4408790)
- **The exemption that protects genuine intra-org mail from SPF checking is exactly what Direct Send abuse doesn't get — and that's the whole story.** `MessageDirectionality`/`AuthAs` correctly classify Direct Send traffic as external/anonymous, which means SPF, DKIM, DMARC, and spoof intelligence all *do* apply. Whether an abuse attempt is actually stopped comes down entirely to whether those controls are configured tightly (hard-fail SPF, quarantine-on-fail spoof intelligence) — a tenant with loose SPF is not "unprotected because Direct Send bypasses filtering," it's "unprotected because its filtering configuration doesn't take advantage of the signal Direct Send traffic already carries."
- **Don't conflate this with mailbox compromise.** Both produce the same user-facing symptom ("I got mail that looked like it was from a coworker, and it wasn't"), but the header signature and remediation are completely different — Direct Send abuse never touches the impersonated user's actual mailbox or credentials, while a compromise investigation (password reset, session revocation, mailbox audit log review) is the wrong tree to bark up if headers show `AuthAs: Anonymous`.
- **Inventory before you block.** The single most common self-inflicted incident from this fix is discovering, via a wave of 5.7.68 bounces, that some undocumented device had been quietly relying on Direct Send — a 15-minute Advanced Hunting query beforehand turns that into a planned migration instead of a surprise outage.
- **This repo's own hybrid mail-flow documentation uses the term "direct send" for something unrelated — say so explicitly when briefing anyone on this topic.** `Mail-Flow-A.md`'s "direct send" is a legitimate outbound routing configuration between servers you control; this topic's "Direct Send" is an inbound, unauthenticated delivery feature being abused by third parties. The shared name is a genuine source of confusion in client conversations if not flagged up front.
- **Reference:** [Varonis: Ongoing Campaign Abuses Microsoft 365's Direct Send](https://www.varonis.com/blog/direct-send-exploit) | [Securing Direct Send in Exchange Online: closing the gaps in EOP-based MX setups](https://cloudnotes.blog/blog/post-2025-10-exo-direct-send-eop-mx-direct/) | [Set-OrganizationConfig (ExchangePowerShell) — Microsoft Learn](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-organizationconfig)
