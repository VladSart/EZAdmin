# AD CS Vulnerable Certificate Templates (ESC1 / ESC4) — Hotfix Runbook (Mode B: Ops)
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

Run these against the forest's Configuration naming context (any domain-joined machine with the ActiveDirectory RSAT module can run this — it does not need to be run on the CA itself):

```powershell
# 1. Which published templates allow the ENROLLEE to supply their own subject/SAN?
#    (msPKI-Certificate-Name-Flag bit 0x1 = CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT)
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
  -LDAPFilter "(objectClass=pKICertificateTemplate)" `
  -Properties Name, msPKI-Certificate-Name-Flag, pKIExtendedKeyUsage |
  Where-Object { $_.'msPKI-Certificate-Name-Flag' -band 0x1 } |
  Select-Object Name, msPKI-Certificate-Name-Flag

# 2. Of those, which also carry a client-authentication-capable EKU (the ESC1 combination)?
#    Client Authentication = 1.3.6.1.5.5.7.3.2, Smart Card Logon = 1.3.6.1.4.1.311.20.2.2,
#    PKINIT Client Auth = 1.3.6.1.5.2.3.4, Any Purpose = 2.5.29.37.0
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
  -LDAPFilter "(&(objectClass=pKICertificateTemplate)(msPKI-Certificate-Name-Flag:1.2.840.113556.1.4.804:=1)(|(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2)(pKIExtendedKeyUsage=1.3.6.1.4.1.311.20.2.2)(pKIExtendedKeyUsage=1.3.6.1.5.2.3.4)(pKIExtendedKeyUsage=2.5.29.37.0)))" `
  -Properties Name | Select-Object Name

# 3. Which CAs have these templates actually published (a template object existing is not
#    the same as it being enrollable — only published templates are reachable)?
certutil -CATemplates

# 4. Who can enroll against a given flagged template? (run against one template at a time,
#    replace <TemplateName>)
$tmpl = Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
  -LDAPFilter "(&(objectClass=pKICertificateTemplate)(name=<TemplateName>))" -Properties nTSecurityDescriptor
$tmpl.nTSecurityDescriptor.Access | Where-Object { $_.ActiveDirectoryRights -match "ExtendedRight|GenericAll|WriteDacl|WriteOwner|WriteProperty" } |
  Select-Object IdentityReference, ActiveDirectoryRights, AccessControlType

# 5. Does the CA itself restrict enrollment agents / require manager approval on flagged
#    templates? (a compensating control that lowers — but doesn't eliminate — ESC1 risk)
certutil -config - -getreg policy\EditFlags
```

| What you see | What it means |
|---|---|
| Command #1 returns any templates AND command #2 shows the same template with a client-auth EKU | **This is ESC1-shaped.** A low-privileged principal who can enroll can request a certificate impersonating any identity (including Domain Admin) by supplying an arbitrary SAN — go to Fix 1 |
| Command #4 shows a non-admin identity (a broad group like "Domain Users"/"Authenticated Users", or an individual low-priv account) holding `WriteDacl`, `WriteOwner`, or `WriteProperty` on the template object | **This is ESC4-shaped.** That principal can reconfigure the template into an ESC1 shape themselves, even if it looks safe today — go to Fix 2 |
| Command #1 returns nothing | No published template currently allows enrollee-supplied subject — ESC1 does not apply today; still worth a periodic re-check since templates get cloned/modified |
| Command #3 shows a flagged template is NOT published on any CA | Lower urgency — the object exists in AD but isn't reachable for enrollment; still recommend disabling/fixing rather than leaving it live for future re-publication |
| Manager approval (`EditFlags` includes `EDITF_REQUESTEXTENSIONS`/pending-approval semantics) is required on a flagged template | A real but partial mitigation — a human must approve every request — do not treat this as a substitute for Fix 1, since approval can be a rubber stamp in practice |
| Certify/Certipy or a pentest report already names a specific template as "ESC1" or "ESC4" | Same underlying finding — go straight to Fix 1/Fix 2 for that named template, then re-run Triage broadly to confirm nothing else is affected |

---
## Dependency Cascade

<details><summary>What must be true for ESC1 or ESC4 to be exploitable</summary>

```
ESC1 — Template misconfiguration (direct)
Certificate template published on an enterprise CA
  └── CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT set (msPKI-Certificate-Name-Flag bit 0x1)
        (the requester, not the CA/AD, supplies the certificate's Subject/SAN)
          └── Template's EKU includes a client-authentication-capable purpose
              (Client Authentication / Smart Card Logon / PKINIT Client Auth / Any Purpose)
                └── A low-privileged security principal holds Enroll (and, for v1 templates,
                    implicitly Autoenroll) rights on the template
                      └── That principal requests a certificate, supplying an arbitrary SAN
                          (e.g. a Domain Admin's UPN) in the enrollment request itself
                            └── CA issues a VALID certificate for the attacker-chosen identity
                                  └── PKINIT logon as that identity — full impersonation,
                                      up to and including Domain Admin / DC machine account

ESC4 — Template ACL abuse (indirect, becomes ESC1)
A non-admin principal holds WriteDacl, WriteOwner, or WriteProperty on a template's AD object
  └── That principal edits the template's own configuration:
        ├── Sets CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT
        ├── Adds a client-authentication EKU
        └── Grants themselves (or "Authenticated Users") Enroll rights
              └── Template is now ESC1-shaped — same exploitation chain as above
```

Key failure points:
- **A template's current configuration is not a durable guarantee if its ACL is weak.** A template that looks perfectly safe today (no enrollee-supplied subject, no client-auth EKU) can be reconfigured into an ESC1 shape by anyone with `WriteDacl`/`WriteOwner`/`WriteProperty` on it — this is exactly why Fix 2 exists as a separate check from Fix 1
- v1 (legacy) certificate templates grant Enroll implicitly to anyone with Read; v2+ templates require an explicit Enroll ACE — know which template version you're looking at before concluding "nobody can enroll"
- This is a distinct primitive from `Windows/Troubleshooting/NTLMRelayADCS-B.md`'s ESC8 (NTLM relay to an HTTP(S) enrollment endpoint) — ESC1/ESC4 require no coercion or relay at all, just a legitimate LDAP/RPC enrollment request from an account that already has the rights
- Also distinct from `Windows/Troubleshooting/CertificateServices-B.md`'s template-ACL coverage — that topic's template-ACL checks are about whether the *right* population can successfully auto-enroll (an availability problem); this topic is about whether the *wrong* population can enroll into an *identity-spoofing-capable* template shape (a security problem)

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Enumerate every published template with enrollee-supplied-subject set**
```powershell
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
  -LDAPFilter "(objectClass=pKICertificateTemplate)" `
  -Properties Name, msPKI-Certificate-Name-Flag |
  Where-Object { $_.'msPKI-Certificate-Name-Flag' -band 0x1 } | Select-Object Name
```
Expected: ideally an empty or short, deliberately-scoped list (e.g. a small number of subordinate-CA-facing enrollment agent templates that legitimately need this). Anything unexpected here — especially a general-purpose "Web Server" or "User" clone — needs immediate review.

**Step 2 — Cross-reference against client-authentication EKUs**
Use Triage command #2. Any overlap between Step 1's list and this list is the full ESC1 candidate set.

**Step 3 — Confirm which CAs actually publish each flagged template**
```powershell
certutil -CATemplates
```
Expected: understand real reachability — a flagged-but-unpublished template is lower urgency than one live on a CA today.

**Step 4 — Pull the enrollment ACL for each flagged template**
Use Triage command #4 for each. Expected: Enroll should be scoped to a specific, justified population — never "Authenticated Users" or "Domain Users" on a client-auth-capable, enrollee-supplied-subject template.

**Step 5 — Separately, check ACL write-rights (ESC4) on EVERY template, not just the flagged ones**
```powershell
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
  -LDAPFilter "(objectClass=pKICertificateTemplate)" -Properties Name, nTSecurityDescriptor |
  ForEach-Object {
    $_.nTSecurityDescriptor.Access |
      Where-Object { $_.ActiveDirectoryRights -match "WriteDacl|WriteOwner|GenericAll|WriteProperty" -and $_.IdentityReference -notmatch "Domain Admins|Enterprise Admins|SYSTEM|Administrators" } |
      Select-Object @{N='Template';E={$_.IdentityReference}}, ActiveDirectoryRights, @{N='TemplateName';E={$_.Name}}
  }
```
Expected: no non-admin identity holding these rights on any template — this is the ESC4 check, independent of a template's current safe-looking configuration.

---
## Common Fix Paths

<details><summary>Fix 1 — Remove enrollee-supplied-subject and/or the client-auth EKU from an ESC1-shaped template</summary>

**Cause:** The template lets the requester dictate their own certificate identity (SAN) while also being usable for authentication — the combination that lets any enrolling principal impersonate anyone.

```
1. Open the Certificate Templates MMC snap-in (certtmpl.msc) on the CA or a management
   workstation with RSAT AD CS tools installed
2. Duplicate the affected template first if it's actively in use (don't edit a live template
   blind — clone, fix, re-publish, then retire the old one)
3. On the clone: Subject Name tab → select "Build from this Active Directory information"
   instead of "Supply in the request" — this clears CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT
4. If the template's real use case does not need client authentication, remove the
   Client Authentication / Smart Card Logon / PKINIT Client Authentication / Any Purpose
   EKU(s) on the Extended Key Usage tab
5. Publish the corrected clone via the CA's Certificate Templates node
   (right-click → New → Certificate Template to Issue)
6. Unpublish/disable the original vulnerable template once issued-certificate history
   confirms nothing is actively depending on it
```

**Rollback note:** Keep the original (unpublished) template object rather than deleting it —
if a legitimate, previously-unknown consumer breaks, you can temporarily re-publish it while
you build the correct replacement, though treat that as a stopgap, not a resolution.

</details>

<details><summary>Fix 2 — Correct the template's ACL to remove non-admin WriteDacl/WriteOwner/WriteProperty (ESC4)</summary>

**Cause:** A non-admin principal holding these rights can reconfigure the template into an ESC1 shape at any time, regardless of its current configuration.

```powershell
# Identify the offending ACE(s) first (see Triage command #4 / Step 5 above), then remove them
# via the Security tab in certtmpl.msc, or via ADSI Edit / Set-Acl for scripted removal.
# Example using the AD CS PKI module pattern (adjust identity/template names):

$templateDN = (Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
  -LDAPFilter "(&(objectClass=pKICertificateTemplate)(name=<TemplateName>))").DistinguishedName
$acl = Get-Acl -Path "AD:\$templateDN"
$offendingAce = $acl.Access | Where-Object { $_.IdentityReference -like "*<OffendingGroupOrUser>*" }
$acl.RemoveAccessRule($offendingAce) | Out-Null
Set-Acl -Path "AD:\$templateDN" -AclObject $acl
```

**Rollback note:** Record the exact ACE (identity, rights, inheritance) before removing it — if
the removal breaks a legitimate delegated-administration workflow (e.g. a PKI admin group that
should have this right), you can restore the precise original entry rather than over-granting a
broader replacement.

</details>

<details><summary>Fix 3 — Disable a vulnerable template entirely (fastest containment, use before Fix 1/2 if under active threat)</summary>

**Cause:** Immediate containment when a flagged template is confirmed exploitable and a full
redesign (Fix 1) can't happen in the current change window.

```
On each CA publishing the template:
  certsrv.msc → Certificate Templates node → right-click the template → Delete
  (this unpublishes it from THIS CA — the template object itself still exists in AD
  and can be re-published later once corrected)
```

**Rollback note:** Unpublishing breaks enrollment for anyone legitimately using this template —
confirm via issued-certificate history that this is an acceptable short-term trade-off, and treat
this as a bridge to Fix 1, not a permanent fix.

</details>

<details><summary>Fix 4 — Tighten enrollment agent restrictions (secondary, for templates that legitimately need enrollee-supplied-subject)</summary>

**Cause:** Some templates (e.g. subordinate-CA enrollment agent / smart card issuance templates)
legitimately need CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT — the fix there is restricting WHO can act as
an enrollment agent, not removing the flag.

```
certsrv.msc → CA properties → Enrollment Agents tab →
  "Restrict enrollment agents" → explicitly scope which agents can enroll on behalf of
  which target templates and which target security groups (least privilege, not "Everyone")
```

**Rollback note:** Removing an overly broad enrollment agent restriction is non-destructive to
existing certificates — safe to tighten first and expand later if a legitimate gap surfaces.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — AD CS Vulnerable Certificate Template (ESC1/ESC4) Issue

Template(s) in scope: ____________
ENROLLEE_SUPPLIES_SUBJECT set (Yes/No, per template): ____________
Client-authentication-capable EKU present (Yes/No, per template): ____________
Published on which CA(s): ____________
Enrollment ACL — who can Enroll: ____________
ACL write-rights (WriteDacl/WriteOwner/WriteProperty) held by any non-admin identity: ____________
Source of the finding (internal audit / Get-ADCSVulnerableTemplateAudit.ps1 / pentest report): ____________

Steps already attempted:
[ ] Ran Triage commands #1-#5 against the Configuration naming context
[ ] Confirmed which CAs actually publish the flagged template(s)
[ ] Pulled the full enrollment ACL for each flagged template
[ ] Checked WriteDacl/WriteOwner/WriteProperty across ALL templates, not just flagged ones
[ ] Applied containment (Fix 3, template unpublished) if under active threat
```

---
## 🎓 Learning Pointers

- **ESC1 and ESC4 require no relay, no coercion, and no exploit code — just a legitimate enrollment request from an account that already has the rights.** This is what makes template misconfiguration a lower-effort, higher-stealth attack path than `NTLMRelayADCS-B.md`'s ESC8: no network coercion traffic to detect, just a normal-looking certificate request.
- **A template's ACL is itself an attack surface, independent of its current configuration (ESC4).** Auditing only "does this template currently look dangerous" misses templates that are one ACL-abuse step away from becoming dangerous — always run the ACL sweep (Step 5) across every template, not just ones already flagged by Step 1.
- **v1 templates grant Enroll implicitly to anyone with Read** — don't assume "no explicit Enroll ACE" means "nobody can enroll" without confirming the template schema version first.
- **This is not the same gap as `CertificateServices-B.md`'s template-ACL triage** — that topic checks whether the *intended* population can auto-enroll (an operational issue); this topic checks whether an *unintended* population can obtain an identity-spoofing-capable certificate (a security issue). Don't assume fixing one addresses the other.
- Microsoft Defender for Identity includes AD CS-specific posture assessments that can surface some of this class of misconfiguration proactively — see `Security/Defender/MDI-A.md`.
- Related: [Microsoft Learn — Certificate Templates overview](https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/certificate-templates), SpecterOps "Certified Pre-Owned" research (the origin of the ESC1-ESC8+ community numbering convention referenced throughout this repo's AD CS topics).
