# NTLM Relay to AD CS (PetitPotam / ESC8) — Hotfix Runbook (Mode B: Ops)
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

Run these on the AD CS server(s) hosting Certificate Authority Web Enrollment and/or Certificate Enrollment Web Service (CES):

```powershell
# 1. Is Certificate Authority Web Enrollment or CES installed on this server at all?
Get-WindowsFeature ADCS-Web-Enrollment, ADCS-Enroll-Web-Svc | Where-Object InstallState -eq "Installed"

# 2. Is Extended Protection for Authentication (EPA) currently required on the relevant IIS sites?
#    (Requires the IIS WebAdministration module)
Import-Module WebAdministration -ErrorAction SilentlyContinue
Get-WebConfiguration -Filter "system.webServer/security/authentication/windowsAuthentication/extendedProtection" `
  -PSPath "IIS:\Sites\Default Web Site\CertSrv" -ErrorAction SilentlyContinue |
  Select-Object TokenChecking

# 3. Is the site reachable over plain HTTP (not just HTTPS)? Plain HTTP is the primary exposure.
Test-NetConnection -ComputerName localhost -Port 80
Test-NetConnection -ComputerName localhost -Port 443

# 4. Is NTLM authentication still allowed on this server generally (not yet restricted)?
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0" -Name "RestrictSendingNTLMTraffic" -ErrorAction SilentlyContinue

# 5. Which certificate templates are published and permit client authentication (the payoff an
#    attacker is actually after via a successful relay)?
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext -LDAPFilter `
  "(&(objectClass=pKICertificateTemplate)(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2))" -Properties Name |
  Select-Object Name
```

| What you see | What it means |
|---|---|
| `ADCS-Web-Enrollment` or `ADCS-Enroll-Web-Svc` installed, and `TokenChecking` is not `Require` (or the query returns nothing) | **This server is exposed to PetitPotam-style NTLM relay (ESC8).** EPA is not enforced — go to Fix 1 immediately, this is the primary, Microsoft-documented mitigation |
| Port 80 (plain HTTP) responds on the CA Web Enrollment / CES site | HTTP is a lower-friction relay target than HTTPS even with EPA elsewhere — go to Fix 2 (disable HTTP / require SSL) |
| Neither Web Enrollment nor CES roles are installed anywhere in the environment | This specific attack path doesn't apply to this AD CS deployment — confirm via `certutil -TCAInfo` that no other server hosts these roles before closing the ticket |
| `RestrictSendingNTLMTraffic` is not configured (or `0`) domain/server-wide | NTLM is still fully permitted — go to Fix 3 as defense-in-depth, in addition to (never instead of) Fix 1 |
| Client-authentication-capable templates are published with broad enrollment permissions | The impact of a successful relay is high — a relayed identity can obtain a usable authentication certificate; prioritize Fix 1 and consider template hardening (Fix 4) |
| Security tooling (Defender for Identity / a pentest) flagged "PetitPotam" or "ESC8" specifically | Same underlying issue — jump straight to Fix 1, then confirm with the Triage commands above |

---
## Dependency Cascade

<details><summary>What must be true for this attack to succeed</summary>

```
AD CS role installed with an HTTP(S)-based enrollment endpoint
  ├── Certificate Authority Web Enrollment (CertSrv)
  └── Certificate Enrollment Web Service (CES)
        └── That endpoint accepts NTLM authentication (default IIS Windows Authentication
            behavior unless explicitly restricted to Negotiate:Kerberos)
              └── Extended Protection for Authentication (EPA) is NOT set to Required
                  (the specific control that cryptographically ties the authentication to
                  the TLS session it arrived on — without it, a relayed auth is accepted
                  as if it came from the original connection)
                    └── An attacker can COERCE a target machine (often a Domain Controller)
                        to authenticate to an attacker-controlled listener
                          ├── PetitPotam (MS-EFSRPC / EfsRpcOpenFileRaw)
                          ├── PrinterBug / SpoolSample (MS-RPRN, Print Spooler)
                          ├── DFSCoerce (MS-DFSNM)
                          └── ShadowCoerce (MS-FSRVP)
                                └── Attacker relays the coerced NTLM authentication to the
                                    exposed AD CS HTTP(S) endpoint (ESC8)
                                      └── Requests and receives a certificate usable for
                                          client authentication AS the coerced identity
                                            └── Uses that certificate for PKINIT logon as
                                                the coerced identity (often a DC's machine
                                                account) — DCSync / domain compromise
```

Key failure points:
- **EPA is the actual control that closes this gap — disabling/blocking any single coercion primitive (PetitPotam specifically) does not close it**, because multiple independent coercion techniques exist and new ones surface periodically. Treat "we patched/blocked PetitPotam" as incomplete unless EPA + NTLM restriction on the AD CS endpoints is also confirmed
- A Domain Controller's own machine account is the highest-value coercion target, since a certificate obtained in its name enables PKINIT logon *as* that DC — from there, DCSync (replicate all password hashes, including krbtgt) is a short hop to full domain compromise
- This is a distinct attack chain from — but closely related to — the certificate-mapping hardening covered in `ActiveDirectory/Troubleshooting/CertificateMapping/Certificate-Mapping-A.md`: that topic covers how a certificate is validated/mapped to an account during authentication; this topic covers how an attacker obtains a *valid, correctly-issued* certificate in the first place via a relayed identity. Certificate mapping hardening does not prevent ESC8 — the certificate obtained via relay is a legitimately issued one for the coerced account
- Any AD CS deployment with Web Enrollment or CES installed is potentially exposed, even if nobody remembers deliberately enabling it — these roles are sometimes installed years ago for a since-forgotten use case and left running

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Inventory every AD CS server and which HTTP(S) enrollment roles it runs**
```powershell
Get-WindowsFeature ADCS-Web-Enrollment, ADCS-Enroll-Web-Svc | Where-Object InstallState -eq "Installed"
```
Expected: a definitive list. If neither role is installed anywhere, this specific attack path (ESC8) doesn't apply — document and close.

**Step 2 — Confirm EPA's actual configured state on each exposed site**
```
IIS Manager → Sites → Default Web Site → CertSrv (and/or the CES virtual directory) →
  Authentication → Windows Authentication → Advanced Settings → Extended Protection
```
Expected: `Required`. `Off` or `Accept` (the pre-mitigation defaults) leave the endpoint relay-exploitable.

**Step 3 — Confirm HTTPS is required and HTTP is disabled**
```powershell
Test-NetConnection -ComputerName localhost -Port 80
```
Expected: ideally, port 80 either isn't listening for this site or immediately redirects/rejects — plain HTTP has no channel to bind EPA to in the first place.

**Step 4 — Confirm NTLM restriction posture (defense-in-depth, not a substitute for Step 2)**
```powershell
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0" -Name "RestrictSendingNTLMTraffic" -ErrorAction SilentlyContinue
```
Expected: a deliberate value, ideally restricting NTLM on the AD CS server(s) specifically even if not domain-wide.

**Step 5 — Confirm which certificate templates are actually reachable via the exposed endpoint**
```powershell
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext -LDAPFilter `
  "(&(objectClass=pKICertificateTemplate)(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2))" -Properties Name
```
Expected: understand what an attacker gets if they succeed — client-authentication-capable templates raise the severity of leaving EPA unconfigured.

---
## Common Fix Paths

<details><summary>Fix 1 — Enable and require Extended Protection for Authentication (primary mitigation)</summary>

**Cause:** Without EPA, the AD CS HTTP(S) endpoint accepts a relayed NTLM authentication as if it originated from the actual connecting client, since nothing ties the authentication to the specific TLS session it arrived on.

```
In IIS Manager, for BOTH the Certificate Authority Web Enrollment site AND the Certificate
Enrollment Web Service site (if installed):

1. Select the site/virtual directory → Authentication → Windows Authentication → Advanced Settings
2. Set Extended Protection to "Required" (more secure) — "Accept" leaves relay-vulnerable
   clients still able to authenticate unprotected
3. For the CES role specifically, also update the web.config file it maintains:
     <windir>\systemdata\CES\<CA Name>_CES_Kerberos\web.config
   Add/confirm <extendedProtectionPolicy policyEnforcement="Always" /> to match the "Required" UI
   setting
4. Restart IIS to apply
     iisreset /restart
```

**Rollback note:** EPA "Required" can reject legitimate clients using very old TLS/authentication
stacks that don't send the necessary channel-binding token — if this happens, investigate the
specific client rather than reverting EPA to "Accept"/"Off" domain-wide, since that re-opens the
exact relay path this fix closes.

</details>

<details><summary>Fix 2 — Disable HTTP, require SSL on the enrollment sites</summary>

**Cause:** Plain HTTP has no TLS session for EPA to bind to at all — even with EPA "Required" elsewhere, an HTTP-reachable endpoint remains exploitable.

```
In IIS Manager, for the same sites as Fix 1:
1. Select the site → SSL Settings → check "Require SSL"
2. Confirm HTTP (port 80) either redirects to HTTPS or is not bound to the site at all
3. Restart IIS
     iisreset /restart
```

**Rollback note:** Requiring SSL will break any legacy client/script still hardcoded to `http://` —
identify and update those before or immediately after this change; do not leave HTTP open
indefinitely to avoid updating a known caller.

</details>

<details><summary>Fix 3 — Restrict or disable NTLM on the AD CS server(s) (defense-in-depth)</summary>

**Cause:** Even with EPA in place, reducing NTLM's overall footprint shrinks the attack surface for this and other NTLM-relay-class issues (see also `Troubleshooting/NTLM-B.md` and `ActiveDirectory/Troubleshooting/LDAPSigning/LDAP-Signing-B.md` for related, protocol-adjacent hardening).

```
Computer Configuration > Windows Settings > Security Settings > Local Policies > Security Options:

"Network security: Restrict NTLM: Incoming NTLM traffic"
  → set to "Deny all accounts" or "Deny all domain accounts" on the AD CS server(s) specifically
    (start scoped to these servers before considering a domain-wide policy)

For IIS specifically, an alternative/additional step: set Windows Authentication's provider
order to Negotiate:Kerberos only (remove NTLM from the provider list) on the AD CS sites.
```

**Rollback note:** Restricting NTLM can break legitimate NTLM-dependent callers (older
line-of-business apps, some monitoring tools) that talk to this server — test in an audit-only
mode first if available, and treat Fix 1 (EPA) as the non-negotiable primary control regardless
of how this defense-in-depth step is scoped.

</details>

<details><summary>Fix 4 — Harden certificate templates to reduce blast radius (secondary, does not replace Fix 1)</summary>

**Cause:** Even with EPA/NTLM restrictions in place as defense-in-depth, templates that grant broad, unauthenticated-adjacent enrollment rights with client-authentication EKUs increase what a successful compromise (via this or any other AD CS misconfiguration) can achieve.

```powershell
# Identify client-authentication-capable templates and review their enrollment permissions
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext -LDAPFilter `
  "(&(objectClass=pKICertificateTemplate)(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2))" -Properties Name, nTSecurityDescriptor

# Review each template's enrollment ACL manually via the Certificate Templates MMC snap-in
# (certtmpl.msc) — remove unnecessary "Authenticated Users"-scope enrollment rights and
# unnecessary client-authentication EKUs where the template's actual use case doesn't need them
```

**Rollback note:** Template permission changes can break legitimate auto-enrollment for the
affected population — test against a pilot OU/security group before a broad rollout, and confirm
which templates are actually load-bearing (via issued-certificate history) before restricting them.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — NTLM Relay to AD CS (PetitPotam / ESC8) Issue

AD CS server(s) in scope: ____________
Roles installed (Web Enrollment / CES / both): ____________
EPA current setting (Off/Accept/Required): ____________
HTTP (port 80) reachable on the enrollment site (Yes/No): ____________
RestrictSendingNTLMTraffic current value: ____________
Client-authentication-capable templates published: ____________
Source of the finding (internal audit / pentest report / Defender for Identity alert / other): ____________

Steps already attempted:
[ ] Confirmed which AD CS servers run Web Enrollment/CES roles
[ ] Checked EPA setting on each exposed site
[ ] Confirmed HTTP vs. HTTPS-only reachability
[ ] Checked NTLM restriction posture on the AD CS server(s)
[ ] Reviewed which certificate templates are reachable and client-auth-capable
```

---
## 🎓 Learning Pointers

- **Extended Protection for Authentication (EPA), not blocking any single coercion technique, is the actual fix.** PetitPotam is one of several coercion primitives (PrinterBug, DFSCoerce, ShadowCoerce, and others discovered periodically) that all lead to the same relay-to-AD-CS outcome — closing the relay destination (EPA on AD CS) is durable; blocking one coercion source is not.
- **The highest-value target is a Domain Controller's own machine account** — a certificate obtained via a coerced DC identity enables PKINIT logon *as* that DC, which is a short path to DCSync and full domain compromise (krbtgt hash extraction). Treat any finding involving a DC as critical-severity, not routine hardening debt.
- **This is architecturally distinct from certificate mapping hardening (KB5014754)** — that topic governs whether a *presented* certificate correctly maps to an account during authentication; this topic governs how an attacker can obtain a *legitimately issued* certificate in the first place via a relayed identity. Fixing one does not fix the other; see `ActiveDirectory/Troubleshooting/CertificateMapping/Certificate-Mapping-A.md` for the companion topic.
- **AD CS Web Enrollment/CES are sometimes installed for a long-forgotten legacy use case and left running unmonitored** — an inventory sweep (Triage command #1) across every server, not just the ones an engineer remembers configuring, is worth doing periodically even without an active incident.
- Microsoft Defender for Identity includes AD CS-specific security posture assessments that flag exactly this class of misconfiguration proactively — see `Security/Defender/MDI-A.md` for general Defender for Identity coverage in this repo.
- Related: [KB5005413: Mitigating NTLM Relay Attacks on AD CS](https://support.microsoft.com/en-us/topic/kb5005413-mitigating-ntlm-relay-attacks-on-active-directory-certificate-services-ad-cs-3612b773-4043-4aa9-b23d-b87910cd3429), [ADV210003 Security Advisory](https://msrc.microsoft.com/update-guide/vulnerability/ADV210003)
