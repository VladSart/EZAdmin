# NTLM Relay to AD CS (PetitPotam / ESC8) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- The NTLM-relay-to-AD-CS attack chain: authentication coercion (PetitPotam and related techniques) combined with an AD CS HTTP(S) enrollment endpoint that doesn't enforce Extended Protection for Authentication (EPA) — the class of misconfiguration commonly labeled **ESC8** in AD CS security research
- Microsoft's documented mitigation (KB5005413 / ADV210003): EPA enforcement, HTTPS-only enrollment, and NTLM restriction on AD CS servers
- Certificate template exposure as a severity multiplier once a relay succeeds
- The downstream impact chain: relayed identity → issued certificate → PKINIT logon as that identity → DCSync/domain compromise when the coerced identity is a Domain Controller

**Out of scope:**
- The full catalog of AD CS misconfiguration classes (ESC1 through ESC15 and beyond, per community numbering conventions) — this topic covers only ESC8 (NTLM relay to HTTP(S) enrollment endpoints) in depth; template-permission-based escalations (ESC1/ESC2/ESC3/ESC4) are referenced only where they compound this specific attack's impact
- Certificate-to-account mapping/binding hardening (KB5014754, the SID extension, `altSecurityIdentities`) — a related but architecturally separate topic covering how a *presented* certificate is validated during authentication, not how an attacker obtains one; see `ActiveDirectory/Troubleshooting/CertificateMapping/Certificate-Mapping-A.md`
- General AD CS certificate enrollment/renewal troubleshooting (expired certs, autoenrollment failures, template publication issues unrelated to security hardening) — see `Windows/Troubleshooting/CertificateServices-A.md`
- General NTLM authentication troubleshooting (secure channel failures, LM compatibility level, `0x80070005` errors unrelated to relay attacks) — see `Windows/Troubleshooting/NTLM-A.md`
- LDAP-specific relay mitigation (LDAP signing/channel binding) — an architecturally parallel but protocol-separate hardening topic; see `ActiveDirectory/Troubleshooting/LDAPSigning/LDAP-Signing-A.md`
- Deep offensive-security tooling/exploitation walkthroughs — this topic is written for defenders assessing and remediating exposure, not for reproducing the attack chain step-by-step

**Assumptions:**
- At least one server in the environment runs the AD CS "Certificate Authority Web Enrollment" and/or "Certificate Enrollment Web Service" (CES) role — if neither is installed anywhere, this specific attack path does not apply, though the broader coercion techniques (PetitPotam, PrinterBug, etc.) can still be relayed to other NTLM-accepting services and are worth understanding regardless
- You have IIS Manager access and local administrator rights on the AD CS server(s) in question
- No `pwsh`/live lab environment was available to execute-test the IIS/EPA configuration commands in this runbook directly; every setting referenced is drawn from Microsoft's own published KB5005413 guidance rather than from execution-tested output

---
## How It Works

<details><summary>Full attack chain architecture — coercion, relay, and the certificate payoff</summary>

### Step 1 — Authentication Coercion

The attack chain begins with **coercion**: tricking a target Windows machine into initiating an outbound authentication attempt toward a destination the attacker controls. PetitPotam, the technique this topic's name references, achieves this by abusing the MS-EFSRPC (Encrypting File System Remote Protocol) interface — specifically calls like `EfsRpcOpenFileRaw` — which, when called against a target with an attacker-supplied UNC path, cause that target to attempt to authenticate to the supplied path as its own machine account. Critically, **PetitPotam is not the only coercion primitive** — PrinterBug/SpoolSample (abusing the Print Spooler's `RpcRemoteFindFirstPrinterChangeNotification` via MS-RPRN), DFSCoerce (MS-DFSNM), and ShadowCoerce (MS-FSRVP, the Volume Shadow Copy remote protocol) all achieve conceptually the same outcome through different RPC interfaces. This matters directly for remediation: patching or blocking PetitPotam specifically closes one door among several, not the whole attack surface — the actual fix has to be at the relay destination, not the coercion source.

The most attractive coercion target is a **Domain Controller's own machine account**, because a certificate later obtained in that identity's name enables the attacker to authenticate *as* the DC itself.

### Step 2 — Relaying the Coerced Authentication

Once a target begins an NTLM authentication attempt toward the attacker's listener, the attacker doesn't need to crack or even fully capture the credential — NTLM's challenge-response design allows the captured authentication attempt to be **relayed** in real time to a *different* service that also accepts NTLM, effectively authenticating to that second service *as* the coerced identity, without ever knowing the underlying password or hash. This is the general NTLM relay pattern; PetitPotam-to-AD-CS is simply one particularly high-value relay destination.

### Step 3 — The Relay Destination: AD CS HTTP(S) Enrollment Endpoints (ESC8)

**ESC8** — using AD CS security research's community numbering convention (originating from SpecterOps' "Certified Pre-Owned" research) — specifically names the scenario where the relay destination is an AD CS **Certificate Authority Web Enrollment** site or **Certificate Enrollment Web Service (CES)** endpoint. These IIS-hosted services accept NTLM authentication by default and, critically, IIS's default Windows Authentication configuration does **not** enable Extended Protection for Authentication (EPA) out of the box. Without EPA, IIS has no way to verify that the authentication it just accepted actually originated from the TLS/TCP connection it arrived on — a relayed NTLM authentication looks, from IIS's perspective, identical to a legitimate one from the real client.

EPA works by binding the authentication to a cryptographic **channel binding token (CBT)** derived from the specific TLS session (or, for non-TLS connections, a weaker service-binding check) the request arrived on. A relayed authentication was negotiated on a *different* connection than the one presenting it to AD CS, so its CBT (if the relaying tool even attempts to forward one) won't match — EPA set to "Required" rejects the mismatch outright. This is the same architectural principle as LDAP channel binding (see `ActiveDirectory/Troubleshooting/LDAPSigning/LDAP-Signing-A.md`) applied to a different protocol/service — both controls close a relay attack by cryptographically tying authentication to its originating session rather than trusting the presented identity alone.

Plain HTTP compounds the exposure further: with no TLS session at all, there's no channel for EPA to bind to in the first place, making an HTTP-reachable enrollment endpoint exploitable regardless of EPA configuration elsewhere. This is why Microsoft's guidance treats "require SSL" as a co-equal primary mitigation alongside EPA, not an optional extra.

### Step 4 — The Payoff: Certificate Issuance and PKINIT Logon

Once the relayed authentication succeeds against the AD CS HTTP(S) endpoint, the attacker — now authenticated as the coerced identity — requests a certificate. If a certificate template is available that grants the relayed identity enrollment rights and includes a client-authentication-capable Extended Key Usage (Client Authentication, Smart Card Logon, PKINIT Client Authentication, or the catch-all "Any Purpose" EKU), AD CS issues a **legitimately valid** certificate for that identity. This is the critical distinction from a forged or stolen certificate: the certificate is real, correctly signed by the organization's own CA, and will pass every standard validation check — including, notably, the certificate-mapping hardening covered in `Certificate-Mapping-A.md`, since that hardening validates whether a *presented* certificate correctly maps to an account, not whether the certificate was obtained through a legitimate request in the first place.

With a valid client-authentication certificate for the coerced identity in hand, the attacker performs a PKINIT-based Kerberos logon **as that identity**. When the coerced identity is a Domain Controller's machine account, this is catastrophic: an attacker authenticated as a DC can perform a **DCSync** operation (using the DC's own replication rights to pull every account's password hash, including the `krbtgt` account — the key to forging Golden Tickets) or abuse Resource-Based Constrained Delegation (RBCD) to pivot further. This chain — unauthenticated coercion, to relay, to certificate issuance, to DCSync — is why ESC8 combined with an available coercion primitive is treated as a critical-severity finding in any AD CS security assessment, not a routine hardening gap.

### Why Fixing "Just PetitPotam" Isn't Enough

A common but incomplete remediation instinct is to patch or block the specific MS-EFSRPC coercion vector PetitPotam uses and consider the issue closed. Because DFSCoerce, ShadowCoerce, PrinterBug, and other coercion primitives (and likely others not yet publicly documented) achieve the same outcome through unrelated RPC interfaces, blocking one leaves the fundamental exposure — an AD CS HTTP(S) endpoint that will accept a relayed NTLM authentication as legitimate — completely intact. The durable fix has to be at the relay *destination* (EPA + HTTPS-only + NTLM restriction on AD CS), which is why this runbook's Remediation Playbooks center entirely on the AD CS server side rather than on hardening against any individual coercion technique.

</details>

---
## Dependency Stack

```
AD CS role: Certificate Authority Web Enrollment and/or CES installed
  └── Endpoint reachable over HTTP and/or HTTPS
        ├── HTTP (no TLS session) — EPA has nothing to bind to, exploitable regardless
        │     of any other setting
        └── HTTPS — TLS session exists, EPA CAN be enforced if configured
              └── IIS Windows Authentication accepts NTLM (default)
                    └── Extended Protection for Authentication (EPA)
                          ├── Off / Accept — relayed authentication accepted as legitimate
                          └── Required — CBT mismatch from a relayed session is REJECTED
                                └── (upstream prerequisite, attacker side) A coercion
                                    primitive forces a target to authenticate outward:
                                      PetitPotam (MS-EFSRPC) | PrinterBug (MS-RPRN) |
                                      DFSCoerce (MS-DFSNM) | ShadowCoerce (MS-FSRVP)
                                        └── Relayed authentication reaches the AD CS
                                            endpoint as the coerced identity
                                              └── Certificate template available with
                                                  client-authentication EKU AND the
                                                  coerced identity has enrollment rights
                                                    └── Certificate issued → PKINIT logon
                                                        as the coerced identity
                                                          └── (if coerced identity = DC)
                                                              DCSync → full domain
                                                              compromise
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Security assessment / pentest report flags "PetitPotam" or "ESC8" against an AD CS server | EPA is not set to Required on the Web Enrollment/CES site(s) | IIS Manager → site → Windows Authentication → Advanced Settings → Extended Protection |
| Defender for Identity or a similar tool raises an AD CS-related certificate posture alert | Same underlying exposure, detected via monitoring rather than active testing | Cross-reference against `Security/Defender/MDI-A.md`'s certificate posture assessment coverage |
| An old, possibly forgotten AD CS server is discovered still running Web Enrollment during an environment audit | AD CS roles are frequently installed for a one-off legacy need and left running unmonitored for years | `Get-WindowsFeature ADCS-Web-Enrollment, ADCS-Enroll-Web-Svc` across every server, not just known CA hosts |
| A Domain Controller's machine account shows unexpected certificate-based authentication or replication activity from an unfamiliar source | Possible active exploitation of this chain — treat as a security incident, not routine troubleshooting | Escalate immediately; correlate against DCSync-indicative replication events and unusual PKINIT logons for the DC's own account |
| Certificate template inventory shows broad "Authenticated Users" enrollment rights combined with a client-authentication EKU | Even with EPA fixed, this template configuration raises the severity of any future AD CS misconfiguration, including but not limited to ESC8 | `certtmpl.msc` review of enrollment ACLs for every client-auth-capable template |
| EPA is set to Required, but a specific legacy client/tool can no longer authenticate to the enrollment endpoint | Expected trade-off — that client's authentication stack doesn't send a valid channel binding token | Confirm the client's TLS/auth library version before considering any EPA relaxation |

---
## Validation Steps

**Step 1 — Inventory every server running AD CS Web Enrollment/CES roles**
```powershell
Get-WindowsFeature ADCS-Web-Enrollment, ADCS-Enroll-Web-Svc | Where-Object InstallState -eq "Installed"
```
Expected: a complete, current list — run this across every server in the environment periodically, not just servers already known to host AD CS, since these roles are commonly forgotten rather than actively maintained.

**Step 2 — Confirm EPA's actual configured value on each exposed site**
```
IIS Manager → Sites → [Default Web Site] → CertSrv (and CES virtual directory if present) →
  Authentication → Windows Authentication → Advanced Settings → Extended Protection
```
Expected: `Required`. For CES specifically, additionally confirm the web.config file:
```
<windir>\systemdata\CES\<CA Name>_CES_Kerberos\web.config
```
contains `<extendedProtectionPolicy policyEnforcement="Always" />` matching the UI setting.

**Step 3 — Confirm HTTPS-only reachability**
```powershell
Test-NetConnection -ComputerName <ADCSServerName> -Port 80
Test-NetConnection -ComputerName <ADCSServerName> -Port 443
```
Expected: port 443 responds; port 80 either doesn't respond for this site or redirects to HTTPS rather than serving the enrollment endpoint directly.

**Step 4 — Confirm NTLM restriction posture as defense-in-depth**
```powershell
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0" -Name "RestrictSendingNTLMTraffic" -ErrorAction SilentlyContinue
```
Expected: a deliberate value on the AD CS server(s), ideally restricting NTLM specifically there even if not enforced domain-wide.

**Step 5 — Inventory client-authentication-capable certificate templates and their enrollment permissions**
```powershell
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext -LDAPFilter `
  "(&(objectClass=pKICertificateTemplate)(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2))" -Properties Name
```
Expected: understand the actual severity if EPA were bypassed — broad enrollment rights on client-auth templates raise this from "hardening gap" to "critical exposure."

**Step 6 — Confirm no active exploitation indicators, especially involving Domain Controller identities**
Review recent PKINIT-based logons and replication (DCSync-pattern) activity for any DC machine account from an unexpected source, in coordination with your SIEM/Defender for Identity tooling — this step is about incident detection, not routine hardening validation, and should be escalated immediately if anything is found.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Inventory Exposure
1. Identify every AD CS server running Web Enrollment or CES roles, environment-wide
2. For each, confirm whether the endpoint is reachable over HTTP, HTTPS, or both

### Phase 2 — Assess Current Mitigation State
1. Check EPA configuration on every exposed site
2. Check HTTPS-required/HTTP-disabled state
3. Check NTLM restriction posture on the AD CS server(s)

### Phase 3 — Assess Blast Radius
1. Inventory client-authentication-capable certificate templates and their enrollment permissions
2. Identify whether any Domain Controller or other Tier 0 identity could plausibly be coerced and relayed against this specific AD CS deployment (i.e., is the AD CS server reachable from a segment where DCs also sit)

### Phase 4 — Remediate
1. Apply EPA "Required" (Playbook 1) — the primary, non-negotiable control
2. Require SSL / disable HTTP (Playbook 1, same change window)
3. Restrict NTLM on the AD CS server(s) as defense-in-depth (Playbook 2)
4. Harden certificate template permissions where warranted (Playbook 3)

### Phase 5 — Validate
1. Re-run the Validation Steps above post-change
2. If pentest/security-tooling flagged this originally, request re-validation against the same finding

### Phase 6 — Monitor Going Forward
1. Add AD CS role inventory (Step 1) to a periodic environment audit, not just a one-time remediation — these roles are commonly re-introduced or forgotten again over time
2. Confirm Defender for Identity (or equivalent) certificate posture assessments are active and alerting on this class of misconfiguration, per `Security/Defender/MDI-A.md`

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full EPA + HTTPS-only rollout across all AD CS enrollment endpoints</summary>

**Scenario:** A fresh audit or pentest has identified one or more AD CS servers with Web Enrollment/CES exposed without EPA, and a coordinated remediation is needed.

**Step 1 — Inventory scope**
```powershell
Get-WindowsFeature ADCS-Web-Enrollment, ADCS-Enroll-Web-Svc | Where-Object InstallState -eq "Installed"
```

**Step 2 — For each in-scope server, enable and require EPA**
```
IIS Manager → CertSrv (and CES virtual directory) → Authentication → Windows Authentication →
  Advanced Settings → Extended Protection → Required
```
For CES, also directly edit:
```
<windir>\systemdata\CES\<CA Name>_CES_Kerberos\web.config
```
adding/confirming `<extendedProtectionPolicy policyEnforcement="Always" />`.

**Step 3 — Require SSL, confirm HTTP is not independently reachable**
```
IIS Manager → site → SSL Settings → Require SSL
```

**Step 4 — Restart IIS on each server**
```powershell
iisreset /restart
```

**Step 5 — Validate**
Re-run Validation Steps 2-3 against every server in scope. Optionally, if a pentest identified the original finding, coordinate a re-test.

**Rollback note:** If a legitimate legacy client breaks after this change, diagnose that specific client's TLS/authentication stack rather than reverting EPA to "Accept"/"Off" — a targeted client fix (library update, reconfiguration) preserves the security control; a blanket EPA rollback re-opens the relay path for everyone.

</details>

<details><summary>Playbook 2 — Restricting NTLM on AD CS servers as defense-in-depth</summary>

**Scenario:** EPA is already enforced (Playbook 1 complete), and the organization wants to further reduce NTLM's footprint on AD CS servers specifically, without a disruptive domain-wide NTLM restriction.

**Step 1 — Confirm current NTLM restriction state**
```powershell
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0" -Name "RestrictSendingNTLMTraffic" -ErrorAction SilentlyContinue
```

**Step 2 — Apply a scoped GPO targeting only the AD CS server(s)**
```
Computer Configuration > Windows Settings > Security Settings > Local Policies > Security Options >
  "Network security: Restrict NTLM: Incoming NTLM traffic" → Deny all domain accounts

Scope this GPO via security filtering or a WMI filter to the specific AD CS server computer
object(s), rather than applying domain-wide in a first pass.
```

**Step 3 — Alternatively/additionally, restrict IIS's own authentication provider order**
```
IIS Manager → site → Authentication → Windows Authentication → Providers →
  remove NTLM, leave Negotiate:Kerberos only
```

**Step 4 — Validate no legitimate NTLM-dependent caller broke**
Monitor for authentication failures from expected callers (auto-enrollment clients, scripts,
monitoring tools) for a full business cycle after the change before considering it final.

**Rollback note:** Reverting is as simple as removing the GPO scoping/re-adding NTLM to the IIS
provider list — treat any rollback as evidence that a specific caller needs remediation (upgrade
to Kerberos-capable auth) rather than a reason to abandon the restriction.

</details>

<details><summary>Playbook 3 — Certificate template permission hardening (severity reduction, not a substitute for Playbook 1)</summary>

**Scenario:** EPA/HTTPS/NTLM mitigations (Playbooks 1-2) are in place, and the organization wants to reduce the impact of any future AD CS misconfiguration by tightening which identities can obtain client-authentication-capable certificates.

**Step 1 — Inventory client-authentication-capable templates**
```powershell
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext -LDAPFilter `
  "(&(objectClass=pKICertificateTemplate)(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2))" -Properties Name, nTSecurityDescriptor
```

**Step 2 — Review each template's enrollment ACL**
Open `certtmpl.msc`, review the Security tab for each client-auth-capable template. Look
specifically for broad "Authenticated Users"-scope enrollment rights that aren't actually
required for the template's real-world use case.

**Step 3 — Tighten enrollment permissions to the actual required population**
Replace broad grants with scoped security groups matching the template's genuine use case
(e.g., a specific device-authentication template scoped to a computer group, not "Authenticated Users").

**Step 4 — Validate no legitimate auto-enrollment population lost access**
Check issued-certificate history for the template before and after the change to confirm the
scoped population still successfully enrolls; pilot against a single OU/group before a broad rollout.

**Rollback note:** ACL changes are directly reversible by re-adding the prior enrollment
permissions, but treat any rollback as a signal to re-scope the template correctly rather than
returning to an overly broad grant.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  NTLM Relay to AD CS (ESC8) Evidence Collector
.NOTES     Run with local admin rights on the AD CS server(s) in question.
#>

$reportPath = "C:\Temp\NTLMRelayADCSEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== AD CS Roles Installed ===" | Out-File "$reportPath\01_Roles.txt"
Get-WindowsFeature ADCS-Web-Enrollment, ADCS-Enroll-Web-Svc |
  Select-Object Name, InstallState | Format-Table | Out-File "$reportPath\01_Roles.txt" -Append

"=== HTTP/HTTPS Reachability ===" | Out-File "$reportPath\02_Connectivity.txt"
Test-NetConnection -ComputerName localhost -Port 80 | Out-File "$reportPath\02_Connectivity.txt" -Append
Test-NetConnection -ComputerName localhost -Port 443 | Out-File "$reportPath\02_Connectivity.txt" -Append

"=== NTLM Restriction Posture ===" | Out-File "$reportPath\03_NTLMRestriction.txt"
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0" -Name "RestrictSendingNTLMTraffic" -ErrorAction SilentlyContinue |
  Format-List | Out-File "$reportPath\03_NTLMRestriction.txt" -Append

"=== Client-Authentication-Capable Certificate Templates ===" | Out-File "$reportPath\04_Templates.txt"
try {
  Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext -LDAPFilter `
    "(&(objectClass=pKICertificateTemplate)(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2))" -Properties Name |
    Select-Object Name | Format-Table | Out-File "$reportPath\04_Templates.txt" -Append
} catch {
  "Could not query certificate templates: $_" | Out-File "$reportPath\04_Templates.txt" -Append
}

"=== NOTE: EPA setting must be captured manually via IIS Manager ===" | Out-File "$reportPath\05_EPA_Manual.txt"
"Check: Sites > CertSrv (and CES virtual directory) > Authentication > Windows Authentication >" |
  Out-File "$reportPath\05_EPA_Manual.txt" -Append
"Advanced Settings > Extended Protection. Record whether it shows Off / Accept / Required." |
  Out-File "$reportPath\05_EPA_Manual.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check which AD CS HTTP(S) roles are installed | `Get-WindowsFeature ADCS-Web-Enrollment, ADCS-Enroll-Web-Svc` |
| Test HTTP/HTTPS reachability | `Test-NetConnection -ComputerName <server> -Port 80\|443` |
| Check NTLM restriction posture | `Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0 -Name RestrictSendingNTLMTraffic` |
| List client-auth-capable certificate templates | `Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext -LDAPFilter "(&(objectClass=pKICertificateTemplate)(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2))"` |
| Restart IIS after an EPA/SSL change | `iisreset /restart` |
| Open Certificate Templates MMC snap-in | `certtmpl.msc` |
| Check CA info / confirm which server hosts the CA role | `certutil -TCAInfo` |

---
## 🎓 Learning Pointers

- **EPA on the AD CS endpoint is the fix, not blocking any one coercion technique.** PetitPotam, PrinterBug, DFSCoerce, and ShadowCoerce are different doors to the same relay outcome — patch/block one and the fundamental exposure (an unprotected AD CS HTTP(S) endpoint) remains completely open to the next one discovered.
- **A relayed certificate is a genuinely, correctly issued one** — it passes every standard certificate validation check, including the certificate-mapping hardening in `Certificate-Mapping-A.md`. That hardening solves a different problem (does a *presented* certificate correctly map to an account); it does not prevent an attacker from *obtaining* a legitimate certificate via this relay chain in the first place.
- **A coerced Domain Controller identity is the worst-case outcome** — a certificate obtained in a DC's name enables PKINIT logon as that DC, and from there DCSync yields every account's password hash including krbtgt. Any finding touching a DC in this attack chain is critical-severity, full stop.
- **AD CS Web Enrollment/CES are commonly installed once and forgotten** — a periodic, environment-wide role inventory (not just checking servers you already know host AD CS) is genuinely valuable hygiene, not paranoia.
- **Plain HTTP defeats EPA structurally, not just by policy** — there's no TLS session for a channel binding token to bind to, so requiring SSL is a co-equal primary mitigation alongside EPA itself, not an optional hardening extra.
- Cross-reference `ActiveDirectory/Troubleshooting/LDAPSigning/LDAP-Signing-A.md` for the architecturally parallel relay-mitigation pattern (channel binding tying authentication to its originating TLS session) applied to a different protocol — understanding one deepens intuition for the other.
- Related: [KB5005413: Mitigating NTLM Relay Attacks on AD CS](https://support.microsoft.com/en-us/topic/kb5005413-mitigating-ntlm-relay-attacks-on-active-directory-certificate-services-ad-cs-3612b773-4043-4aa9-b23d-b87910cd3429), [ADV210003 Security Advisory](https://msrc.microsoft.com/update-guide/vulnerability/ADV210003), [Extended Protection for Authentication overview](https://msrc-blog.microsoft.com/2009/12/08/extended-protection-for-authentication/)
