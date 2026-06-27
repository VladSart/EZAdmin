# Email Authentication (DMARC/DKIM/SPF) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index (with jump links)
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

This runbook covers the full email authentication stack for **Microsoft 365 / Exchange Online** tenants:

- **SPF** (Sender Policy Framework) — RFC 7208
- **DKIM** (DomainKeys Identified Mail) — RFC 6376
- **DMARC** (Domain-based Message Authentication, Reporting, and Conformance) — RFC 7489
- **ARC** (Authenticated Received Chain) — RFC 8617 — for legitimate forwarding scenarios
- **MTA-STS** (Mail Transfer Agent Strict Transport Security) — RFC 8461
- **BIMI** (Brand Indicators for Message Identification) — for logo display in supporting clients

**Assumes:**
- Exchange Online (cloud-only or hybrid) is the primary mail platform
- Admin has Exchange Admin or Security Admin role in M365 admin center
- Custom domain(s) added and verified in Microsoft 365

---

## How It Works

<details><summary>Full architecture</summary>

### The Authentication Chain

```
Sending server (Exchange Online)
        │
        ├── SMTP MAIL FROM (envelope-from / Return-Path)
        │       └── SPF: Receiver checks if sending IP is authorized
        │               for the envelope-from domain in DNS
        │
        ├── DKIM signature in message header
        │       └── Exchange Online adds X-DKIM-Signature header
        │               signed with private key stored in EXO
        │       └── Receiver looks up public key at:
        │               selector._domainkey.sendingdomain.com
        │               and verifies signature
        │
        └── From: header (what user sees)
                └── DMARC: checks alignment
                        ├── Does SPF envelope-from domain align
                        │   with From: header domain?
                        └── Does DKIM d= tag domain align
                            with From: header domain?
                                    │
                            (relaxed: org domain match OK)
                            (strict: exact match required)
                                    │
                        DMARC policy applied based on result
```

### SPF in Depth

SPF is a DNS TXT record that lists which IP addresses or domains are allowed to send email for a domain.

**Mechanism types:**
- `ip4:x.x.x.x/nn` — specific IPv4 range (no DNS lookup)
- `ip6:` — IPv6 range (no DNS lookup)
- `include:domain.com` — includes SPF record of another domain (costs 1 lookup, which may itself have lookups)
- `a:` — includes the A records of a domain (1 lookup)
- `mx:` — includes the MX targets (1 lookup per MX)
- `ptr:` — reverse DNS (expensive, discouraged)
- `exists:` — complex macro-based (1 lookup)

**Qualifiers:**
- `+` (default, pass), `-` (fail/hardfail), `~` (softfail), `?` (neutral)
- `-all` = hardfail anything not listed (recommended)
- `~all` = softfail (mail delivered but marked)

**SPF Result codes:**
- `Pass` — sending IP is authorized
- `Fail` — explicitly not authorized
- `SoftFail` — not authorized, but soft (`~all`)
- `TempError` — DNS lookup failed (transient)
- `PermError` — too many DNS lookups or invalid SPF syntax

### DKIM in Depth

DKIM adds a cryptographic signature to every outgoing message. The signature covers selected headers and the message body.

**How Exchange Online implements DKIM:**
1. Each domain gets two key pairs (selector1 and selector2) — rotated automatically by Microsoft
2. Active selector signs all outbound mail
3. When Microsoft rotates keys (every ~6 months), it switches from selector1→selector2 or vice versa
4. CNAME records must exist in DNS for both selectors (pointing to Microsoft-managed keys)

**What's signed (l= header in DKIM-Signature):**
- By default: From:, To:, Subject:, Date:, MIME-Version:, Content-Type:, Message-ID:
- Body hash also included (bh=)
- Modifications to signed headers/body break the signature

**Why DKIM survives forwarding (usually):**
- When mail is forwarded, the From: header stays the same
- DKIM signature was applied to the original message
- As long as no signed headers are modified, the signature remains valid
- But: some forwarders modify Subject: (add Re:) or rewrite MIME, which breaks DKIM

### DMARC in Depth

DMARC ties SPF and DKIM together with a policy and an alignment requirement.

**DMARC record tags:**
```
v=DMARC1          Version (required)
p=none            Policy: none | quarantine | reject
sp=               Subdomain policy (defaults to p= if not specified)
pct=100           Percentage of failing mail to apply policy to
rua=mailto:       Aggregate report destination (XML, sent daily/weekly)
ruf=mailto:       Forensic/failure report destination (per-message, privacy concerns)
adkim=r           DKIM alignment: r=relaxed, s=strict
aspf=r            SPF alignment: r=relaxed, s=strict
ri=86400          Reporting interval (seconds, default 86400 = 1 day)
fo=0              Failure reporting options (0=both fail, 1=any fail, d=DKIM fail, s=SPF fail)
```

**Relaxed vs Strict alignment:**
- **Relaxed (r):** Organizational domain match. `mail.contoso.com` aligns with `contoso.com`. Default.
- **Strict (s):** Exact match only. `mail.contoso.com` does NOT align with `contoso.com`. Rarely recommended.

### ARC (Authenticated Received Chain)

ARC is designed for legitimate forwarding (mailing lists, email security gateways, journaling) where the original SPF/DKIM results would otherwise be lost or broken.

**How ARC works:**
1. Originating server: SPF/DKIM/DMARC evaluated normally
2. Forwarding server (ARC-sealing): preserves the original authentication results in ARC headers:
   - `ARC-Authentication-Results:` — original results
   - `ARC-Message-Signature:` — signature of the message at this hop
   - `ARC-Seal:` — signature of all ARC headers from this and previous hops
3. Final receiver: can check the ARC chain; if the chain is trusted, apply original results even if SPF breaks

**Microsoft 365 as ARC verifier:** EXO honours ARC seals from trusted sealers. If a message comes through a trusted forwarding path with a valid ARC chain, EXO can override an SPF/DMARC failure.

**Add ARC trusted sealers in M365:**
```powershell
# Check current trusted ARC sealers:
Get-ArcConfig

# Add a trusted ARC sealer (e.g. your email security gateway):
Set-ArcConfig -Identity Default -ArcTrustedSealers "gateway.yourvendor.com"
```

### MTA-STS

MTA-STS (RFC 8461) allows domains to publish a policy that receiving servers must use TLS when delivering mail. Prevents downgrade attacks.

**Requires:**
1. `_mta-sts.yourdomain.com` DNS TXT record
2. `https://mta-sts.yourdomain.com/.well-known/mta-sts.txt` HTTPS endpoint
3. Valid TLS certificate on the MX server

Exchange Online supports MTA-STS receiving for custom domains via the `mta-sts.outlook.com` hosting. To enable for inbound:
- Publish `_mta-sts` TXT record pointing to Microsoft's hosted policy endpoint
- Microsoft Docs: https://learn.microsoft.com/en-us/microsoft-365/compliance/use-mta-sts

</details>

---

## Dependency Stack

```
BIMI (brand logo in inbox) — requires VMC and DMARC p=reject
        │
DMARC policy (p=none/quarantine/reject)
        │
        ├── SPF alignment (envelope-from vs From: header)
        │       └── SPF TXT record in DNS
        │               └── Authorised sending IPs/includes
        │
        └── DKIM alignment (d= vs From: header)
                └── DKIM-Signature header in message
                        └── DKIM private key in Exchange Online
                                └── DKIM CNAME records in DNS
                                        └── Selector1/_domainkey → Microsoft-managed public key
                                        └── Selector2/_domainkey → Microsoft-managed public key
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Outbound mail quarantined by recipient | DMARC fail at recipient; SPF or DKIM not aligned | Check NDR/feedback loop email; validate SPF, DKIM |
| DKIM-Signature missing from outbound headers | DKIM signing not enabled in EXO | `Get-DkimSigningConfig` |
| DKIM selector CNAME returns NXDOMAIN | DNS records not published | Check DNS at registrar |
| SPF PermError | More than 10 DNS lookups | Count includes; flatten SPF |
| DMARC aggregate reports showing forwarded mail failing | Forwarding breaks SPF alignment; DKIM also breaks | Enable ARC; ensure DKIM signing |
| Legitimate newsletter failing DMARC | Third-party sender not signing with your domain | Configure custom DKIM on the service |
| DMARC p=reject breaking internal mail relay | On-prem relay sending From: your domain without SPF/DKIM | Add relay IP to SPF; configure DKIM on relay |
| BIMI logo not showing | DMARC not at p=reject, or no VMC certificate | Enforce DMARC first |
| MTA-STS policy causing delivery failures | TLS cert expired or MTA-STS record incorrect | Check cert and well-known endpoint |
| ARC seal not trusted | ARC sealer not in trusted list | Add to `Set-ArcConfig -ArcTrustedSealers` |

---

## Validation Steps

**1. Validate SPF record completeness and lookup count**
```powershell
$domain = "yourdomain.com"
$txt = (Resolve-DnsName -Name $domain -Type TXT).Strings
$spf = $txt | Where-Object { $_ -like 'v=spf1*' }
Write-Host "SPF: $spf"

# Count DNS-lookup mechanisms:
$lookups = ($spf -split ' ' | Where-Object { $_ -match '^include:|^a:|^mx:|^ptr:|^exists:' }).Count
Write-Host "DNS lookup count (must be <= 10): $lookups"
```

**2. Check DKIM signing config in Exchange Online**
```powershell
Connect-ExchangeOnline
Get-DkimSigningConfig | Select-Object Domain, Enabled, Status, Selector1CNAME, Selector2CNAME, KeySize | Format-List
# Status: Valid = good
# Status: CnameMissing = DNS not published
# Status: RevocationError = rare; key revocation issue
```

**3. Validate DKIM DNS publication**
```powershell
$domain = "yourdomain.com"
$cfg = Get-DkimSigningConfig -Identity $domain
Write-Host "Expected selector1: $($cfg.Selector1CNAME)"
$actual = (Resolve-DnsName "selector1._domainkey.$domain" -Type CNAME -EA SilentlyContinue).NameHost
Write-Host "Actual selector1 DNS: $actual"
if ($actual -eq $cfg.Selector1CNAME) { Write-Host "MATCH: OK" -ForegroundColor Green }
else { Write-Host "MISMATCH: DNS not updated" -ForegroundColor Red }
```

**4. Check DMARC policy and tags**
```powershell
$dmarc = (Resolve-DnsName "_dmarc.yourdomain.com" -Type TXT -EA SilentlyContinue).Strings
Write-Host "DMARC: $dmarc"
# Should include: v=DMARC1; p=<policy>; rua=mailto:<address>
```

**5. Read a message header to verify end-to-end authentication**

Send a test email to a Gmail or Outlook.com address, then view the raw headers:
- Gmail: More → Show Original
- Outlook.com: View → View message source

Look for:
```
Authentication-Results: mx.google.com;
  dkim=pass header.i=@yourdomain.com ...
  spf=pass ...
  dmarc=pass (p=NONE) header.from=yourdomain.com
```

**6. Check ARC configuration**
```powershell
Get-ArcConfig | Select-Object ArcTrustedSealers
```

**7. Validate MTA-STS (if configured)**
```powershell
# Check DNS record:
Resolve-DnsName "_mta-sts.yourdomain.com" -Type TXT

# Check policy endpoint:
Invoke-WebRequest "https://mta-sts.yourdomain.com/.well-known/mta-sts.txt" | Select-Object Content
# Expected content example:
# version: STSv1
# mode: enforce
# mx: *.mail.protection.outlook.com
# max_age: 604800
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Baseline: confirm all three records exist

1. Run all triage commands from [DMARC-DKIM-B.md](DMARC-DKIM-B.md#triage)
2. SPF → DKIM → DMARC in that order
3. If any are missing, go to Remediation Playbooks

### Phase 2 — Confirm alignment

1. Get a raw message header from a failing message (request from recipient or use Microsoft's Remote Connectivity Analyser)
2. Find the `Authentication-Results:` header
3. Read each result:
   - `spf=pass smtp.mailfrom=yourdomain.com` — SPF passes with correct domain? ✓
   - `dkim=pass header.i=@yourdomain.com` — DKIM passes with correct domain? ✓
   - `dmarc=pass` — overall result ✓
4. If DMARC fails despite SPF/DKIM passing individually: alignment problem → Phase 3

### Phase 3 — Diagnose alignment failure

1. Note the domain in `smtp.mailfrom=` (SPF) — is it your domain or a third party?
2. Note the domain in `header.i=` (DKIM) — is it your domain or a third party?
3. Note the domain in `header.from=` (the From: header)
4. Alignment check: `smtp.mailfrom` and `header.from` must share the org domain (relaxed) or be identical (strict)
5. Same for DKIM `header.i=` and `header.from`

**If sending via third-party service:** the third-party's domain is in smtp.mailfrom and header.i= → alignment fails with your From: domain. Fix: configure custom DKIM on the service so `d=yourdomain.com`.

### Phase 4 — Read DMARC aggregate reports

1. DMARC reports are XML files, sent to the `rua=` address
2. Each report contains: source IP, sending domain, SPF result, DKIM result, DMARC disposition, count
3. Use a report parser (Dmarcian, Postmark Analyzer, or self-hosted) to identify:
   - IPs failing that shouldn't be (misconfigured services)
   - IPs passing that you don't recognise (potential spoofing)
4. Address each failing legitimate source before tightening policy

### Phase 5 — Progressive DMARC enforcement

Start at `p=none`, move progressively:
1. `p=none; pct=100` — monitor all mail, no enforcement, collect reports (2–4 weeks)
2. `p=quarantine; pct=5` — quarantine 5% of failing mail (reduces blast radius)
3. `p=quarantine; pct=100` — quarantine all failing mail (weeks)
4. `p=reject; pct=100` — reject all failing mail (enforcement)

Move to next step only when aggregate reports show <1% of legitimate mail failing.

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Full Exchange Online email authentication setup (new tenant)</summary>

**Step 1 — Add domain to M365 and verify**
- M365 Admin Center → Setup → Domains → Add domain
- Complete verification (TXT record in DNS)

**Step 2 — Publish SPF**
```
DNS TXT @ v=spf1 include:spf.protection.outlook.com -all
```

**Step 3 — Enable and publish DKIM**
```powershell
Connect-ExchangeOnline
New-DkimSigningConfig -DomainName yourdomain.com -Enabled $true
$dkim = Get-DkimSigningConfig -Identity yourdomain.com
Write-Host "Add to DNS at registrar:"
Write-Host "selector1._domainkey  CNAME  $($dkim.Selector1CNAME)"
Write-Host "selector2._domainkey  CNAME  $($dkim.Selector2CNAME)"
```
Publish CNAMEs in DNS, wait for propagation (~1h), then verify:
```powershell
Get-DkimSigningConfig -Identity yourdomain.com | Select-Object Status
# Expected: Valid
```

**Step 4 — Publish DMARC (monitor-only first)**
```
DNS TXT _dmarc  v=DMARC1; p=none; rua=mailto:dmarc@yourdomain.com
```

**Step 5 — Wait, read reports, then tighten**
After 2–4 weeks of `p=none`, review aggregate reports. Once <1% fail, move to `p=quarantine`, then `p=reject`.

</details>

<details>
<summary>Playbook 2 — Fix DKIM for third-party sending services</summary>

**Goal:** Make a third-party service (Salesforce, HubSpot, Mailchimp, Sendgrid) sign with DKIM using your domain, so DKIM alignment passes DMARC.

**General steps (service-specific docs vary):**

1. Log into the third-party service's admin panel
2. Navigate to: Sending Domains / Email Authentication / DKIM Setup
3. The service will generate a DKIM selector and give you a CNAME or TXT record to publish
4. Publish the record in DNS under your domain (e.g., `s1._domainkey.yourdomain.com`)
5. Verify in the service's portal; the service will now sign mail with `d=yourdomain.com`

**Verify alignment after setup:**
Send a test email → check raw headers → `dkim=pass header.i=@yourdomain.com`

**Rollback:** Remove the DNS record to stop that service from claiming your DKIM. Does not break other authentication.

</details>

<details>
<summary>Playbook 3 — Handle on-premises relay breaking DMARC</summary>

**Scenario:** On-prem servers (printers, scanners, applications) send email From: user@yourdomain.com but bypass Exchange Online, going directly to the internet or through a smart host. They lack SPF authorisation and DKIM signing.

**Option A — Route through Exchange Online (preferred):**
Configure the device to relay through your Exchange Online connector or M365 SMTP relay. EXO will then sign the message with DKIM.

SMTP relay settings for devices:
```
SMTP Server: yourtenant.mail.protection.outlook.com
Port: 25
TLS: Required
From address: must match an accepted domain in your tenant
```

**Option B — Add device IP to SPF:**
```
v=spf1 ip4:<device-IP> include:spf.protection.outlook.com -all
```
This only fixes SPF alignment, not DKIM. DMARC can still pass on SPF alone if alignment is met.

**Option C — Use a no-reply address with its own DMARC policy:**
Create a subdomain (noreply@notify.yourdomain.com) with a separate, relaxed DMARC policy for automated systems. This isolates sensitive relay traffic from your primary domain DMARC enforcement.

</details>

<details>
<summary>Playbook 4 — Rotate DKIM keys manually</summary>

Exchange Online rotates DKIM keys automatically, but you can trigger a manual rotation:

```powershell
# Rotate to selector2 (if selector1 is currently active):
Rotate-DkimSigningConfig -KeySize 2048 -Identity yourdomain.com
# Or use the EAC: Protection → DKIM → domain → Rotate

# Verify new active selector:
Get-DkimSigningConfig -Identity yourdomain.com | Select-Object Selector1PublishingStatus, Selector2PublishingStatus
# One will show "Published" (active), the other "NotRequired"
```

**Note:** Rotation is safe — both CNAME records remain valid and Microsoft handles the key pair. No DNS changes needed unless you haven't published both selectors yet.

</details>

---

## Evidence Pack

```powershell
# EZAdmin — Email Authentication Evidence Collector
# Run in: Exchange Online PowerShell session
# Run as: Exchange Admin

Connect-ExchangeOnline -ShowBanner:$false

$domains = Get-AcceptedDomain | Where-Object { $_.DomainType -ne 'InternalRelay' } | Select-Object -ExpandProperty DomainName
$outFile = "$env:USERPROFILE\Desktop\email-auth-evidence-$(Get-Date -Format yyyyMMdd-HHmmss).txt"

"=== Email Authentication Evidence Pack ===" | Out-File $outFile
"Date: $(Get-Date)" | Out-File $outFile -Append
"" | Out-File $outFile -Append

foreach ($domain in $domains) {
    "=== Domain: $domain ===" | Out-File $outFile -Append

    "--- SPF ---" | Out-File $outFile -Append
    try {
        (Resolve-DnsName $domain -Type TXT -EA Stop | Where-Object { $_.Strings -like '*spf*' }).Strings |
            Out-File $outFile -Append
    } catch { "ERROR: $($_.Exception.Message)" | Out-File $outFile -Append }

    "--- DKIM selectors ---" | Out-File $outFile -Append
    try {
        (Resolve-DnsName "selector1._domainkey.$domain" -Type CNAME -EA Stop).NameHost |
            ForEach-Object { "selector1: $_" } | Out-File $outFile -Append
    } catch { "selector1: NXDOMAIN or error" | Out-File $outFile -Append }
    try {
        (Resolve-DnsName "selector2._domainkey.$domain" -Type CNAME -EA Stop).NameHost |
            ForEach-Object { "selector2: $_" } | Out-File $outFile -Append
    } catch { "selector2: NXDOMAIN or error" | Out-File $outFile -Append }

    "--- DMARC ---" | Out-File $outFile -Append
    try {
        (Resolve-DnsName "_dmarc.$domain" -Type TXT -EA Stop).Strings | Out-File $outFile -Append
    } catch { "No DMARC record" | Out-File $outFile -Append }

    "--- Exchange Online DKIM Config ---" | Out-File $outFile -Append
    Get-DkimSigningConfig -Identity $domain -EA SilentlyContinue |
        Select-Object Enabled, Status, KeySize, Selector1CNAME, Selector2CNAME |
        Format-List | Out-File $outFile -Append

    "" | Out-File $outFile -Append
}

"--- ARC Trusted Sealers ---" | Out-File $outFile -Append
Get-ArcConfig | Out-File $outFile -Append

"=== END ===" | Out-File $outFile -Append
Write-Host "Evidence written to: $outFile"
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Check SPF record | `Resolve-DnsName yourdomain.com -Type TXT` |
| Check DKIM selector1 | `Resolve-DnsName selector1._domainkey.yourdomain.com -Type CNAME` |
| Check DKIM selector2 | `Resolve-DnsName selector2._domainkey.yourdomain.com -Type CNAME` |
| Check DMARC record | `Resolve-DnsName _dmarc.yourdomain.com -Type TXT` |
| Check MX record | `Resolve-DnsName yourdomain.com -Type MX` |
| Connect to EXO | `Connect-ExchangeOnline` |
| View DKIM signing config | `Get-DkimSigningConfig \| Format-List` |
| Enable DKIM for domain | `Set-DkimSigningConfig -Identity domain.com -Enabled $true` |
| Create new DKIM config | `New-DkimSigningConfig -DomainName domain.com -Enabled $true` |
| Rotate DKIM keys | `Rotate-DkimSigningConfig -Identity domain.com -KeySize 2048` |
| View ARC trusted sealers | `Get-ArcConfig` |
| Add ARC trusted sealer | `Set-ArcConfig -Identity Default -ArcTrustedSealers "gateway.vendor.com"` |
| Check MTA-STS DNS | `Resolve-DnsName _mta-sts.yourdomain.com -Type TXT` |
| Fetch MTA-STS policy | `Invoke-WebRequest https://mta-sts.yourdomain.com/.well-known/mta-sts.txt` |

---

## 🎓 Learning Pointers

- **SPF hardfail (-all) vs softfail (~all):** SPF with `-all` tells receivers to reject unauthorised senders. `~all` (softfail) tells them to accept but mark it. DMARC is what determines actual policy enforcement — SPF hardfail on its own is only honoured by receivers that do explicit SPF checks, which is less common than DMARC. Use `-all` for clarity, but rely on DMARC for enforcement.

- **DKIM key size matters:** Exchange Online defaults to 1024-bit DKIM keys for older domains. 2048-bit is now the recommended minimum. When creating new configs or rotating, specify `-KeySize 2048`. Older keys can be rotated without breaking anything — just allow propagation time.

- **BIMI requires DMARC at p=reject:** BIMI (Brand Indicators for Message Identification) allows your company logo to appear in Gmail and other supporting inboxes. The prerequisite is DMARC at `p=reject` (or `p=quarantine` for some implementations) and a VMC (Verified Mark Certificate) from an approved CA. This is a business/security milestone to aim for — it indicates mature email authentication.

- **DMARC aggregate reports are XML — use a tool:** The raw XML from `rua=` reports is parseable but tedious manually. Tools like Dmarcian (free tier available), Postmark's DMARC Analyser, and PowerDMARC visualise sources, failure rates, and trends. Set up report analysis before tightening DMARC policy.

- **MS Docs — Email authentication in Microsoft 365 (overview):** https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/email-authentication-about

- **MS Docs — Configure ARC trusted sealers:** https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/email-authentication-arc-configure

- **DMARC.org (vendor-neutral resource):** https://dmarc.org
