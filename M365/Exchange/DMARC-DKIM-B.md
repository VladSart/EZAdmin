# Email Authentication (DMARC/DKIM/SPF) — Hotfix Runbook (Mode B: Ops)
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

Run these from any PowerShell or command prompt (no module required for DNS checks):

```powershell
# Replace <domain> with the sending domain (e.g. contoso.com)
$domain = "<domain>"

# 1. Check SPF record
Resolve-DnsName -Name $domain -Type TXT | Where-Object { $_.Strings -like '*spf*' } | Select-Object -ExpandProperty Strings

# 2. Check DKIM selector 1 (Exchange Online default)
Resolve-DnsName -Name "selector1._domainkey.$domain" -Type CNAME -ErrorAction SilentlyContinue | Select-Object Name, NameHost

# 3. Check DKIM selector 2
Resolve-DnsName -Name "selector2._domainkey.$domain" -Type CNAME -ErrorAction SilentlyContinue | Select-Object Name, NameHost

# 4. Check DMARC record
Resolve-DnsName -Name "_dmarc.$domain" -Type TXT | Select-Object -ExpandProperty Strings

# 5. Check MX record
Resolve-DnsName -Name $domain -Type MX | Select-Object Name, NameExchange, Preference
```

**Interpretation:**

| Finding | Action |
|---------|--------|
| SPF record missing or no `include:spf.protection.outlook.com` | SPF not set for Exchange Online → Fix 1 |
| SPF has 10+ DNS lookups | SPF PermError risk (too many lookups) → Fix 2 |
| selector1/selector2 CNAME returns NXDOMAIN | DKIM DNS not published → Fix 3 |
| DMARC record missing | No DMARC enforcement → Fix 4 |
| DMARC p=reject and mail failing | Check DKIM/SPF alignment → Fix 5 |
| MX not pointing to Exchange Online | Hybrid or misconfigured → note for Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Sender (Exchange Online / on-prem)
        │
        ├── SPF record published in DNS
        │       └── include:spf.protection.outlook.com (for EXO)
        │
        ├── DKIM keys enabled in Exchange Online
        │       └── selector1/selector2 CNAME records in DNS
        │       └── Exchange Online signs outbound mail with private key
        │
        └── DMARC record published in DNS
                └── References SPF domain and/or DKIM domain
                └── Alignment: From: header domain must match
                        ├── SPF envelope-from (Return-Path domain)
                        └── DKIM d= tag domain
                                │
                    Receiver checks alignment
                                │
                    ┌───────────┴───────────┐
                    │                       │
              Pass (deliver)          Fail (p=none/quarantine/reject)
```

**The critical concept — Alignment:**
DMARC doesn't just check if SPF passes and DKIM passes. It checks if the domain that passed SPF/DKIM **matches the From: header domain**. This is called alignment. Mail forwarded through a third party often breaks SPF alignment (the Return-Path changes), which is why DKIM alignment is more reliable.

</details>

---

## Diagnosis & Validation Flow

**Step 1: Identify the exact failure from a bounce/rejection**

Look at the message trace or NDR for DMARC failure details:
```
dmarc=fail (p=reject sp=reject dis=reject) header.from=contoso.com
```
This tells you: DMARC policy is reject, and this message failed.

Then check which mechanism failed:
```
spf=fail smtp.mailfrom=contoso.com
dkim=fail header.i=@contoso.com
```

**Step 2: Check DKIM status in Exchange Online**
```powershell
# Connect to Exchange Online:
Connect-ExchangeOnline -UserPrincipalName <admin@tenant.onmicrosoft.com>

# Check DKIM signing config for all domains:
Get-DkimSigningConfig | Select-Object Domain, Enabled, Status, Selector1CNAME, Selector2CNAME | Format-List
# Expected: Enabled: True, Status: Valid
# Bad: Enabled: False, or Status showing error
```

**Step 3: Validate DKIM DNS is published**
```powershell
$domain = "<yourdomain>"
# Check what EXO expects:
$dkim = Get-DkimSigningConfig -Identity $domain
Write-Host "Selector1 CNAME should be: $($dkim.Selector1CNAME)"
Write-Host "Selector2 CNAME should be: $($dkim.Selector2CNAME)"

# Check what DNS actually has:
Resolve-DnsName "selector1._domainkey.$domain" -Type CNAME
Resolve-DnsName "selector2._domainkey.$domain" -Type CNAME
```
If these don't match, the DNS records need updating at the registrar.

**Step 4: Check SPF lookup count**
```powershell
# Quick lookup count check — count "include:", "a:", "mx:", "ptr:", "exists:" directives:
$spf = (Resolve-DnsName $domain -Type TXT | Where-Object { $_.Strings -like '*spf*' }).Strings
Write-Host "SPF record: $spf"
# Count 'include:' occurrences — each resolves to at least 1 lookup:
($spf -split ' ' | Where-Object { $_ -match '^include:|^a:|^mx:|^ptr:|^exists:' }).Count
# If > 10: risk of PermError — Fix 2 needed
```

**Step 5: Check DMARC policy strength**
```powershell
$dmarc = (Resolve-DnsName "_dmarc.$domain" -Type TXT -ErrorAction SilentlyContinue).Strings
Write-Host "DMARC: $dmarc"
# Look for p=none (monitor only), p=quarantine, p=reject
```

---

## Common Fix Paths

<details>
<summary>Fix 1 — SPF record missing or not including Exchange Online</summary>

**DNS record to create/update (at your DNS registrar):**
```
Type: TXT
Name: @ (or yourdomain.com)
Value: v=spf1 include:spf.protection.outlook.com -all
```

**If domain also sends from other services (e.g. Salesforce, Mailchimp, HubSpot):**
```
v=spf1 include:spf.protection.outlook.com include:sendgrid.net include:servers.mcsv.net -all
```

⚠️ Keep total DNS lookups under 10. Each `include:` counts as at least 1 lookup.

**Verify after DNS propagation (up to 48h, usually <1h):**
```powershell
Resolve-DnsName yourdomain.com -Type TXT | Where-Object { $_.Strings -like '*spf*' }
```

</details>

<details>
<summary>Fix 2 — SPF too many DNS lookups (PermError risk)</summary>

**Cause:** SPF spec allows max 10 DNS lookups. Exceeding this causes a PermError, which DMARC may treat as SPF failure.

**Solution — Flatten SPF using IP addresses instead of includes:**
1. Resolve each `include:` to its IP ranges
2. Replace includes with `ip4:` or `ip6:` entries where possible

**Tools:** Use https://mxtoolbox.com/spf.aspx to count lookups and find offending includes.

**Example flattened record:**
```
v=spf1 ip4:40.92.0.0/15 ip4:40.107.0.0/16 include:spf.protection.outlook.com -all
```

**Alternative — Use a macro-based SPF flattening service** (e.g., PowerDMARC, Dmarcian) that dynamically resolves includes.

**Rollback:** Keep the old SPF record in a text file before replacing it.

</details>

<details>
<summary>Fix 3 — DKIM not enabled or DNS CNAME records not published</summary>

**Step 1 — Enable DKIM signing in Exchange Online:**
```powershell
Connect-ExchangeOnline -UserPrincipalName <admin@tenant.onmicrosoft.com>

# Enable DKIM for the domain:
Set-DkimSigningConfig -Identity <yourdomain.com> -Enabled $true

# If no config exists yet, create it:
New-DkimSigningConfig -DomainName <yourdomain.com> -Enabled $true

# Get the required CNAME values:
Get-DkimSigningConfig -Identity <yourdomain.com> | Select-Object Selector1CNAME, Selector2CNAME
```

**Step 2 — Publish the CNAME records at your DNS registrar:**

The output will show two CNAMEs like:
```
selector1-yourdomain-com._domainkey.yourtenant.onmicrosoft.com
selector2-yourdomain-com._domainkey.yourtenant.onmicrosoft.com
```

Create these DNS records:
```
Type: CNAME
Name: selector1._domainkey
Value: selector1-yourdomain-com._domainkey.yourtenant.onmicrosoft.com

Type: CNAME
Name: selector2._domainkey
Value: selector2-yourdomain-com._domainkey.yourtenant.onmicrosoft.com
```

**Step 3 — Verify after DNS propagation:**
```powershell
Resolve-DnsName "selector1._domainkey.yourdomain.com" -Type CNAME
# Expected: resolves to the onmicrosoft.com CNAME target
```

**Note:** DKIM signing won't activate until both CNAMEs resolve correctly. Exchange Online validates the DNS before enabling signing.

</details>

<details>
<summary>Fix 4 — DMARC record missing</summary>

**Minimum DMARC record (monitor-only, no enforcement):**
```
Type: TXT
Name: _dmarc
Value: v=DMARC1; p=none; rua=mailto:dmarc-reports@yourdomain.com
```

**Recommended progression:**
1. Start with `p=none` and collect reports for 2–4 weeks
2. Promote to `p=quarantine` once legitimate traffic passes
3. Promote to `p=reject` for full enforcement

**Full DMARC record example:**
```
v=DMARC1; p=quarantine; pct=100; rua=mailto:dmarc@yourdomain.com; ruf=mailto:dmarc-forensic@yourdomain.com; sp=quarantine; adkim=r; aspf=r
```

**Tags explained:**
- `p=` — policy for main domain (none/quarantine/reject)
- `sp=` — policy for subdomains
- `pct=` — percentage of failing mail to apply policy to (100 = all)
- `rua=` — aggregate report destination
- `adkim=r` — DKIM alignment relaxed (r) or strict (s)
- `aspf=r` — SPF alignment relaxed or strict

</details>

<details>
<summary>Fix 5 — DMARC failing despite SPF/DKIM passing (alignment issue)</summary>

**Cause:** SPF and/or DKIM pass, but the domain in those records doesn't **align** with the From: header domain.

**Common scenario:** Mail sent via a third-party service (Mailchimp, Salesforce) where:
- The Return-Path (SPF domain) is `bounce.mailchimp.com` — fails alignment with `yourdomain.com`
- DKIM is signed with `mailchimp.com` — fails alignment with `yourdomain.com`

**Fix A — Enable custom DKIM signing on the third-party sender:**
- Most email services support "custom domain DKIM" — the service lets you publish their DKIM key under your domain
- Example: Mailchimp → Account → Domains → Authenticate → publish CNAME records under `yourdomain.com`

**Fix B — Use DMARC relaxed alignment (aspf=r, adkim=r):**
Relaxed alignment allows org domain matching (e.g., `yourdomain.com` aligns with `mail.yourdomain.com`).
This is already the default (`r`) but verify your DMARC record isn't using `s` (strict).

**Fix C — Add the third-party service's IPs/includes to your SPF:**
This fixes SPF alignment if the Return-Path can be configured to use your domain.

**Verify alignment by reading DMARC aggregate reports:**
- Reports (sent to `rua=` address) are in XML and show per-source alignment results
- Use a DMARC report analyser: https://dmarc.postmarkapp.com or https://dmarcian.com

</details>

<details>
<summary>Fix 6 — Mail failing after enabling DMARC p=reject (legitimate mail broken)</summary>

**Cause:** A legitimate sending source wasn't covered by SPF/DKIM.

**Immediate mitigation — Drop policy back to quarantine:**
```
Update DNS _dmarc record: change p=reject to p=quarantine; pct=25
```
This buys time to identify and fix the legitimate source.

**Identify failing sources from DMARC reports:**
- Read `rua=` aggregate reports — they list every IP that sent mail claiming to be from your domain
- Any IP not in your SPF, or not DKIM-signing with your domain, will show as failed

**Then either:**
1. Add the source to SPF and/or configure DKIM on it
2. If it's not a legitimate sender: leave it failing (it's likely spoofed mail)

Once all legitimate sources pass, increase pct= back to 100 and p= back to reject.

</details>

---

## Escalation Evidence

```
=== Email Authentication Escalation ===
Date/Time        : [TIMESTAMP]
Raised by        : [ENGINEER NAME]
Ticket #         : [TICKET]

Affected Domain  : [yourdomain.com]
Issue Type       :
  [ ] Outbound mail being rejected/quarantined by recipients
  [ ] Inbound mail failing authentication
  [ ] DMARC reports showing failures
  [ ] Sudden change after DNS/config update

Current DNS state
-----------------
SPF record       : [PASTE]
DKIM selector1   : [PASTE CNAME value or NXDOMAIN]
DKIM selector2   : [PASTE CNAME value or NXDOMAIN]
DMARC record     : [PASTE]

Exchange Online DKIM status (Get-DkimSigningConfig output)
----------------------------------------------------------
[PASTE]

Failure evidence (NDR / message header / DMARC report excerpt)
--------------------------------------------------------------
[PASTE]

Steps already taken
-------------------
[ ] Checked SPF includes EXO
[ ] Verified DKIM CNAMEs published
[ ] Confirmed DMARC alignment mode
[ ] Checked third-party senders
[ ] Reviewed DMARC aggregate reports
```

---

## 🎓 Learning Pointers

- **SPF alone is not enough for DMARC:** SPF checks the envelope sender (Return-Path), not the visible From: header. When email is forwarded, SPF almost always breaks. DKIM survives forwarding (the signature travels with the message), which is why enabling DKIM is essential before tightening DMARC.

- **The 10-lookup SPF limit is permanent:** The RFC is explicit: 10 DNS lookups for SPF evaluation. Every `include:`, `a:`, `mx:`, and `ptr:` counts. `ip4:` and `ip6:` do not count. Large orgs with many SaaS senders routinely hit this limit — use flattening or macros.

- **DMARC reports are gold:** The `rua=` aggregate reports (XML, sent daily or weekly) show you every IP that sent mail claiming your domain, and whether they passed or failed SPF/DKIM/DMARC. Read them before you move from `p=none` to enforcement, or you'll break legitimate mail.

- **MS Docs — Enable DKIM for your custom domain in Microsoft 365:** https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/email-authentication-dkim-configure

- **MS Docs — Set up DMARC:** https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/email-authentication-dmarc-configure

- **MXToolbox (free DNS/SPF/DKIM/DMARC check tool):** https://mxtoolbox.com/SuperTool.aspx
