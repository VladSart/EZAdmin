# AD CS Vulnerable Certificate Templates (ESC1 / ESC4) — Reference Runbook (Mode A: Deep Dive)
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
- **ESC1** — a certificate template that sets `CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT` (the requester, not AD/the CA, supplies the certificate's Subject/SAN), also carries a client-authentication-capable Extended Key Usage, and grants Enroll rights to a low-privileged security principal — allowing that principal to request and receive a valid certificate impersonating any identity of their choosing, including a Domain Admin or a Domain Controller's machine account
- **ESC4** — a certificate template AD object whose access control list grants a non-admin, low-privileged principal `WriteDacl`, `WriteOwner`, or `WriteProperty` rights on the template itself, allowing that principal to reconfigure a currently-safe-looking template into an ESC1 shape (set the enrollee-supplied-subject flag, add a client-auth EKU, grant themselves Enroll) and then exploit it
- Detection via native PowerShell/`Get-ADObject` queries against the Configuration naming context and the `certutil`/certificate-templates MMC tooling that ships with RSAT AD CS tools — this topic is written for defenders running an audit, not for reproducing exploitation
- Remediation: correcting template subject-name/EKU configuration, correcting template ACLs, disabling/unpublishing vulnerable templates, and scoping enrollment agent restrictions

**Out of scope:**
- **ESC8** — NTLM relay to an AD CS HTTP(S) enrollment endpoint. That is a *different attack primitive*: ESC8 requires coercing a target into an outbound NTLM authentication attempt and relaying it to obtain a certificate *as the coerced identity*; ESC1/ESC4 require no coercion or relay at all — a principal who already has legitimate enrollment rights simply requests a certificate for an identity they choose. See `Windows/Troubleshooting/NTLMRelayADCS-A.md` for that topic. If a finding names "ESC8" specifically, this is the wrong document — go there instead.
- **General AD CS certificate enrollment/renewal operational troubleshooting** — expired certificates, autoenrollment plumbing failures (missing Autoenroll ACE, GPO not applying, SCEP/NDES errors), template publication issues unrelated to security misconfiguration. That is an *availability* problem, not a security-misconfiguration problem, even though both topics involve reading a template's ACL. See `Windows/Troubleshooting/CertificateServices-A.md` — its template-ACL checks confirm the *intended* population (Read/Enroll/Autoenroll) can successfully auto-enroll; this topic confirms the *unintended* population cannot obtain an identity-spoofing-capable certificate. The two checks look similar (both read `nTSecurityDescriptor` on a template object) but answer opposite questions.
- **Certificate-to-account mapping validation (KB5014754)** — a certificate obtained via ESC1/ESC4 is, like a certificate obtained via ESC8, a *legitimately issued* one that will pass standard mapping validation. See `ActiveDirectory/Troubleshooting/CertificateMapping/Certificate-Mapping-A.md` for that separate hardening layer, which governs whether a *presented* certificate correctly maps to an account — it does not prevent an attacker from obtaining a valid certificate for an arbitrary identity in the first place via ESC1/ESC4.
- The full ESC1-through-ESC15+ AD CS misconfiguration catalog (per SpecterOps' "Certified Pre-Owned" community numbering convention) — this topic covers only ESC1 (vulnerable template — enrollee-supplied subject) and ESC4 (template ACL abuse) in depth. Other classes (ESC2 — Any Purpose EKU without enrollee-supplied-subject; ESC3 — enrollment agent template abuse; ESC5-ESC15 — PKI object/CA-level misconfigurations) are not covered here.
- Offensive tooling walkthroughs (Certify, Certipy) — referenced conceptually only, to explain what an attacker's tooling is actually checking for, never as instructions to run against a live environment.

**Assumptions:**
- You have RSAT's ActiveDirectory PowerShell module and read access to the Configuration naming context (any domain-joined workstation with RSAT installed can run the detection queries — CA server access is not required for detection, only for remediation)
- At least one Enterprise CA exists in the forest and templates are the standard AD-object-backed v1/v2/v3/v4 schema (this topic does not cover standalone/non-enterprise CAs, which use a different, file-based template model)
- No `pwsh`/live lab environment was available to execute-test the LDAP filter syntax or PowerShell commands in this runbook directly against a real Configuration naming context; the filters are drawn from well-documented AD schema attribute definitions (`msPKI-Certificate-Name-Flag`, `pKIExtendedKeyUsage`) and standard LDAP bitwise-match filter syntax (`:1.2.840.113556.1.4.804:` — the `LDAP_MATCHING_RULE_BIT_AND` OID) rather than from execution-tested output

---
## How It Works

<details><summary>Full architecture — template configuration flags, ACLs, and the impersonation payoff</summary>

### The Two Independent Axes of Template Security

Every certificate template's exploitability for ESC1/ESC4 purposes reduces to two independent questions:

1. **Who supplies the certificate's Subject/SAN — the requester, or Active Directory?**
2. **Who is currently allowed to enroll, and who is currently allowed to CHANGE who is allowed to enroll (or change #1 itself)?**

ESC1 is a "yes" to a dangerous combination of question 1 (requester) plus a client-auth EKU plus a "yes" to broad enrollment on question 2. ESC4 is a "yes" to write-access on question 2 regardless of the current answer to question 1 — because ESC4 lets an attacker flip question 1's answer themselves.

### ESC1 — Enrollee-Supplied Subject

Every certificate template carries an `msPKI-Certificate-Name-Flag` attribute, a bitmask. Bit `0x1` is `CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT`. When set, the CA builds the issued certificate's Subject Name and/or Subject Alternative Name (SAN) fields from data the *requester* supplies in the certificate signing request — not from the requester's own AD object attributes. This flag exists for legitimate reasons: subordinate CA templates, smart card enrollment agent templates, and certain non-AD-integrated scenarios need to enroll on behalf of an identity that isn't the requester's own account. The flag itself is not automatically a vulnerability.

It becomes ESC1 when three conditions are simultaneously true:
- `CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT` is set
- The template's Extended Key Usage includes a client-authentication-capable purpose: **Client Authentication** (`1.3.6.1.5.5.7.3.2`), **Smart Card Logon** (`1.3.6.1.4.1.311.20.2.2`), **PKINIT Client Authentication** (`1.3.6.1.5.2.3.4`), or the catch-all **Any Purpose** (`2.5.29.37.0`) / no EKU restriction at all
- A low-privileged security principal (frequently "Domain Users" or "Authenticated Users", inherited from a poorly-scoped clone of a broader template) holds Enroll rights

When all three hold, any member of that low-privileged population can submit a certificate request specifying an arbitrary SAN — for example, the UPN of a Domain Admin, or a Domain Controller's machine account name — and the CA, trusting the requester per its template configuration, issues a **cryptographically valid, correctly signed certificate** for that chosen identity. The requester never needed the target identity's credentials, never needed to compromise anything else. This is the entire attack: one enrollment request, no relay, no coercion, no lateral movement required before the certificate lands.

### ESC4 — Template ACL Abuse

A certificate template is itself an Active Directory object (under `CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,...`), and like any AD object it carries an `nTSecurityDescriptor` with a standard access control list. Beyond the Enroll/Autoenroll extended rights that govern who can *request* a certificate, this ACL also governs who can *modify the template itself* — via `WriteDacl` (change the ACL), `WriteOwner` (take ownership, then grant themselves any right), `WriteProperty` (directly edit attributes including `msPKI-Certificate-Name-Flag` and `pKIExtendedKeyUsage`), or `GenericAll`.

If a non-admin principal holds any of these rights — commonly the result of an overly broad delegation made years earlier for an unrelated PKI-management reason, or a template cloned from one that had such a delegation — that principal does not need the target template to be ESC1-shaped *today*. They can:
1. Set `CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT` on the template
2. Add a client-authentication EKU if one isn't already present
3. Grant themselves (or a broad group) Enroll rights, if not already present
4. Enroll using the now-ESC1-shaped template, exactly as described above

This is why an audit that only checks "is any published template currently ESC1-shaped" is incomplete — a template with a currently-safe configuration but a weak ACL is a time bomb, not a clean bill of health. ESC4 audits must check ACL write-rights on **every** template, independent of that template's current subject-name/EKU configuration.

### Why This Passes Every Standard Validation Check

A certificate obtained via ESC1 or ESC4 is not forged, not stolen, and not a spoofed chain — it is issued by the organization's real, trusted Enterprise CA, using the CA's real signing key, following the CA's own configured rules for that template. It will pass ordinary certificate chain validation, and it will pass the certificate-to-account mapping hardening covered in `ActiveDirectory/Troubleshooting/CertificateMapping/Certificate-Mapping-A.md` (KB5014754) cleanly, because that hardening validates whether a *presented* certificate's SAN/SID extension correctly maps to the account presenting it — and an ESC1/ESC4-obtained certificate's SAN is, by design, exactly the identity the attacker chose to impersonate. The mapping is "correct" from Schannel/KDC's perspective; the problem happened earlier, at issuance time, not at presentation time.

### PKINIT Logon and Impact

With a valid client-authentication certificate for an arbitrary chosen identity, the holder performs a PKINIT-based Kerberos logon as that identity. If the chosen identity is a Domain Controller's own machine account or a Domain/Enterprise Admin, the impact is immediate and severe: DCSync (replicate every account's password hash including `krbtgt`), or any other action the impersonated identity is authorized to perform. Unlike `NTLMRelayADCS-A.md`'s ESC8 chain — which requires a live coercion target and a working relay setup at attack time — ESC1/ESC4 require only a single successful enrollment request, making it, in practice, a lower-effort and lower-noise attack path once a vulnerable template exists.

</details>

---
## Dependency Stack

```
Certificate template AD object (under Configuration NC, Public Key Services container)
  ├── msPKI-Certificate-Name-Flag bit 0x1 (CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT)
  │     ├── NOT set → requester cannot dictate SAN; ESC1 does not apply to this template
  │     └── SET → requester dictates SAN
  │           └── pKIExtendedKeyUsage includes a client-authentication-capable purpose
  │                 (Client Auth / Smart Card Logon / PKINIT Client Auth / Any Purpose)
  │                 ├── NOT present → certificate can't be used for PKINIT logon; lower severity
  │                 └── PRESENT → ESC1 shape confirmed
  │                       └── Enroll right granted to a low-privileged principal
  │                             └── Template published on a reachable Enterprise CA
  │                                   └── ESC1 is live-exploitable: attacker enrolls,
  │                                       supplies arbitrary SAN, receives valid certificate
  │                                         └── PKINIT logon as chosen identity
  │                                               └── (if identity = DC or Domain Admin)
  │                                                   DCSync / full domain compromise
  │
  └── nTSecurityDescriptor (the template object's own ACL)
        └── WriteDacl / WriteOwner / WriteProperty / GenericAll held by a non-admin principal
              └── ESC4: that principal can reconfigure the template into the ESC1 shape above
                    at will, regardless of the template's CURRENT msPKI-Certificate-Name-Flag
                    or EKU values — the ESC1 branch above then applies on their own timeline
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| A pentest report or security tool (Certify/Certipy-style output, or a manual audit) names a specific template as "ESC1" | `CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT` + client-auth EKU + broad Enroll rights on that template | Run Triage/Validation Steps 1-2 against that specific template name |
| A pentest report names a template or the forest generally as "ESC4" | A non-admin principal holds WriteDacl/WriteOwner/WriteProperty on the template object | Run Validation Step 5's ACL sweep against every template, not just the named one |
| An environment-wide certificate template audit turns up a template that was cloned from a known-vulnerable base (e.g. a clone of the legacy "Web Server" or "User" template with unusually broad rights) | Clones frequently inherit an overly broad Enroll ACE from the source template without anyone revisiting it | Compare the clone's ACL against its stated business purpose; scope down to the actual required population |
| Certificate issuance logs / CA database show an unexpected SAN issued to an unexpected requester | Possible active exploitation — a live ESC1 enrollment event | Escalate immediately; pull the CA's issued-certificate database entry for that request and cross-reference the requesting identity against the SAN it received |
| Defender for Identity or similar posture-assessment tooling flags an AD CS certificate template finding | Same underlying class of misconfiguration, detected proactively | Cross-reference against `Security/Defender/MDI-A.md`'s AD CS posture assessment coverage |
| `Get-ADCSVulnerableTemplateAudit.ps1` reports a template as ESC1-shaped, but the template's Enroll ACE only lists a scoped, justified security group | Lower actual risk than a broad "Authenticated Users" grant, but still worth reviewing whether that group's membership is itself tightly controlled | Review the group's own membership and nesting — a broad or self-service-joinable group defeats the scoping |
| A template flagged by this topic's audit was also referenced in `NTLMRelayADCS-A.md`'s Fix 4/Playbook 3 ("harden certificate templates") | The two topics can overlap on the same template — ESC8's severity-reduction guidance and this topic's ESC1/ESC4-specific detection are complementary, not duplicate | Apply this topic's Fix 1/2 (structural template correction) rather than assuming ESC8's generic ACL-tightening guidance alone is sufficient — ESC8's fix reduces blast radius of a relay; this topic's fix closes a direct, relay-free exploitation path |

---
## Validation Steps

**Step 1 — Enumerate every published template with `CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT` set**
```powershell
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
  -LDAPFilter "(objectClass=pKICertificateTemplate)" `
  -Properties Name, msPKI-Certificate-Name-Flag |
  Where-Object { $_.'msPKI-Certificate-Name-Flag' -band 0x1 } | Select-Object Name
```
Expected: an empty list, or a short, deliberately-scoped list of templates whose legitimate use case genuinely requires enrollee-supplied subject (subordinate CA / enrollment agent templates).

**Step 2 — Cross-reference against client-authentication-capable EKUs**
```powershell
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
  -LDAPFilter "(&(objectClass=pKICertificateTemplate)(msPKI-Certificate-Name-Flag:1.2.840.113556.1.4.804:=1)(|(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2)(pKIExtendedKeyUsage=1.3.6.1.4.1.311.20.2.2)(pKIExtendedKeyUsage=1.3.6.1.5.2.3.4)(pKIExtendedKeyUsage=2.5.29.37.0)))" `
  -Properties Name | Select-Object Name
```
Expected: this is the actual ESC1 candidate list — every name returned here needs Step 4's ACL review.

**Step 3 — Confirm which CAs actually publish each candidate**
```powershell
certutil -CATemplates
```
Expected: cross-check reachability. A candidate not published anywhere is lower urgency but should still be corrected before any future re-publication.

**Step 4 — Pull the enrollment ACL for each ESC1 candidate**
```powershell
$tmpl = Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
  -LDAPFilter "(&(objectClass=pKICertificateTemplate)(name=<TemplateName>))" -Properties nTSecurityDescriptor
$tmpl.nTSecurityDescriptor.Access |
  Where-Object { $_.ActiveDirectoryRights -match "ExtendedRight" -and $_.ObjectType -eq "0e10c968-78fb-11d2-90d4-00c04f79dc55" } |
  Select-Object IdentityReference, AccessControlType
```
(The GUID `0e10c968-78fb-11d2-90d4-00c04f79dc55` is the well-known Certificate-Enrollment extended right.) Expected: Enroll scoped to a specific, justified population — never "Authenticated Users"/"Domain Users" on a template that passed Step 2.

**Step 5 — Sweep ACL write-rights (ESC4) across every template, independent of Steps 1-4**
```powershell
Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
  -LDAPFilter "(objectClass=pKICertificateTemplate)" -Properties Name, nTSecurityDescriptor |
  ForEach-Object {
    $tn = $_.Name
    $_.nTSecurityDescriptor.Access |
      Where-Object { $_.ActiveDirectoryRights -match "WriteDacl|WriteOwner|GenericAll|WriteProperty" -and
                     $_.IdentityReference -notmatch "Domain Admins|Enterprise Admins|SYSTEM|Administrators|Cert Publishers" } |
      Select-Object @{N='Template';E={$tn}}, IdentityReference, ActiveDirectoryRights
  }
```
Expected: no results. Any non-admin identity returned here is an ESC4 finding requiring Playbook 2, regardless of what Steps 1-4 found for that same template.

**Step 6 — Confirm compensating controls where a template legitimately needs enrollee-supplied-subject**
```
certsrv.msc → CA properties → Enrollment Agents tab
```
Expected: enrollment agent restrictions are explicitly scoped (specific agents, specific target templates, specific target groups) rather than left at the default unrestricted state.

**Step 7 — Review CA issuance logs for anomalous SAN/requester pairs (incident-detection, not routine audit)**
Cross-reference the CA's issued-certificate database (`certutil -view`) for any request where the SAN issued does not match the requesting account's own identity, in coordination with your SIEM/Defender for Identity tooling. This step is about detecting active exploitation, and should be escalated immediately if anything is found.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Inventory
1. Enumerate every published template forest-wide (Validation Step 1)
2. Cross-reference against client-auth EKUs to build the ESC1 candidate list (Step 2)
3. Confirm actual CA-level publication/reachability for each candidate (Step 3)

### Phase 2 — ACL Review
1. Pull the Enroll ACL for every ESC1 candidate (Step 4)
2. Independently sweep WriteDacl/WriteOwner/WriteProperty/GenericAll across ALL templates (Step 5), not just the ESC1 candidates

### Phase 3 — Assess Blast Radius
1. For each finding, identify the scope of the granted population — an individual low-priv account is a narrower finding than "Authenticated Users"
2. Identify whether any finding, if exploited, could yield a Tier 0 identity (DC machine account, Domain/Enterprise Admin) — treat those as critical-severity

### Phase 4 — Remediate
1. Correct ESC1-shaped templates (Playbook 1) — subject-name/EKU correction, ACL scoping, or disable if not correctable in the current window
2. Correct ESC4 ACL findings (Playbook 2) — remove non-admin write-rights on every affected template
3. Scope enrollment agent restrictions for templates that legitimately need enrollee-supplied-subject (Playbook 3)

### Phase 5 — Validate
1. Re-run Validation Steps 1-5 post-change and confirm the finding list has shrunk to only deliberately-scoped, justified entries
2. If a pentest/security-tooling report flagged this originally, request re-validation against the same finding

### Phase 6 — Monitor Going Forward
1. Add this audit (or `Get-ADCSVulnerableTemplateAudit.ps1`) to a periodic environment review, not just a one-time remediation — template ACLs and configuration drift over time as new clones are created for legitimate needs
2. Confirm Defender for Identity (or equivalent) AD CS posture assessments are active, per `Security/Defender/MDI-A.md`

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full ESC1 template correction (subject-name and EKU rework)</summary>

**Scenario:** An audit or pentest has identified one or more published templates matching the ESC1 shape (enrollee-supplied-subject + client-auth EKU + broad Enroll rights).

**Step 1 — Confirm scope**
Run Validation Steps 1-4 to build the confirmed finding list with current Enroll ACLs.

**Step 2 — Clone before editing**
Never edit a live, actively-used template in place. In `certtmpl.msc`, duplicate the affected template.

**Step 3 — Correct the clone**
```
Subject Name tab → "Build from this Active Directory information"
  (clears CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT)

Extended Key Usage tab → remove Client Authentication / Smart Card Logon /
  PKINIT Client Authentication / Any Purpose, unless the template's real use case
  genuinely requires client authentication AND enrollee-supplied-subject simultaneously
  (rare — usually one or the other, not both)

Security tab → scope Enroll to the actual justified population, not "Authenticated Users"
```

**Step 4 — Publish the clone, retire the original**
```
CA MMC (certsrv.msc) → Certificate Templates → New → Certificate Template to Issue
  (select the corrected clone)

Once issued-certificate history confirms nothing depends on the original:
  Certificate Templates → right-click original → Delete (unpublishes from this CA)
```

**Step 5 — Validate**
Re-run Validation Steps 1-4; the corrected clone should no longer appear in the Step 2 ESC1 candidate list.

**Rollback note:** Keep the original template object (unpublished, not deleted from AD) as a
fallback if an unknown legitimate consumer breaks — re-publish temporarily while building the
correct long-term replacement, but treat that as a stopgap, not a resolution.

</details>

<details><summary>Playbook 2 — ESC4 ACL correction (remove non-admin write-rights)</summary>

**Scenario:** Validation Step 5's sweep found a non-admin principal holding WriteDacl, WriteOwner, WriteProperty, or GenericAll on one or more template objects.

**Step 1 — Document the exact offending ACE before touching anything**
```powershell
$templateDN = (Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
  -LDAPFilter "(&(objectClass=pKICertificateTemplate)(name=<TemplateName>))").DistinguishedName
(Get-Acl -Path "AD:\$templateDN").Access | Format-List
```

**Step 2 — Remove the offending ACE**
```powershell
$acl = Get-Acl -Path "AD:\$templateDN"
$offendingAce = $acl.Access | Where-Object { $_.IdentityReference -like "*<OffendingGroupOrUser>*" }
$acl.RemoveAccessRule($offendingAce) | Out-Null
Set-Acl -Path "AD:\$templateDN" -AclObject $acl
```

**Step 3 — If the write-rights were needed for legitimate delegated PKI administration**
Re-grant the SAME rights, scoped to a dedicated, tightly-membership-controlled PKI-administration
security group instead of a broad or individual grant — delegated administration should exist
through a deliberate, auditable group, not an ad hoc historical ACE.

**Step 4 — Validate**
Re-run Validation Step 5; the corrected template should no longer appear in the sweep.

**Rollback note:** Because Step 1 documents the exact original ACE, restoring it is
straightforward if removal breaks a legitimate workflow — but investigate why that workflow
needed unscoped write-access before restoring rather than restoring reflexively.

</details>

<details><summary>Playbook 3 — Enrollment agent restriction scoping (for templates that legitimately need enrollee-supplied-subject)</summary>

**Scenario:** A template genuinely needs `CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT` (e.g. a smart card
enrollment agent workflow) and Playbook 1's "remove the flag" fix isn't applicable — the
compensating control is restricting WHO can act as an enrollment agent.

**Step 1 — Review current enrollment agent configuration**
```
certsrv.msc → CA Properties → Enrollment Agents tab
```

**Step 2 — Apply explicit restriction**
```
Select "Restrict enrollment agents" →
  For each enrollment agent identity: specify exactly which certificate templates they may
  use, and exactly which target security groups/OUs they may enroll on behalf of
```

**Step 3 — Validate**
Attempt an enrollment-agent-based request from an identity NOT explicitly permitted; confirm it is rejected.

**Rollback note:** Removing an overly broad restriction is non-destructive to already-issued
certificates — safe to tighten first and expand only as specific, justified needs surface.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  AD CS Vulnerable Certificate Template (ESC1/ESC4) Evidence Collector
.NOTES     Run with RSAT ActiveDirectory module access to the Configuration NC.
           Does not require CA server access for the detection portion.
#>

$reportPath = "C:\Temp\ADCSTemplateEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== ESC1 Candidates: Enrollee-Supplied-Subject + Client-Auth EKU ===" | Out-File "$reportPath\01_ESC1Candidates.txt"
try {
    Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
      -LDAPFilter "(&(objectClass=pKICertificateTemplate)(msPKI-Certificate-Name-Flag:1.2.840.113556.1.4.804:=1)(|(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2)(pKIExtendedKeyUsage=1.3.6.1.4.1.311.20.2.2)(pKIExtendedKeyUsage=1.3.6.1.5.2.3.4)(pKIExtendedKeyUsage=2.5.29.37.0)))" `
      -Properties Name | Select-Object Name | Format-Table | Out-File "$reportPath\01_ESC1Candidates.txt" -Append
} catch {
    "Could not query: $_" | Out-File "$reportPath\01_ESC1Candidates.txt" -Append
}

"=== ESC4 Candidates: Non-Admin WriteDacl/WriteOwner/WriteProperty/GenericAll ===" | Out-File "$reportPath\02_ESC4Candidates.txt"
try {
    Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
      -LDAPFilter "(objectClass=pKICertificateTemplate)" -Properties Name, nTSecurityDescriptor |
      ForEach-Object {
        $tn = $_.Name
        $_.nTSecurityDescriptor.Access |
          Where-Object { $_.ActiveDirectoryRights -match "WriteDacl|WriteOwner|GenericAll|WriteProperty" -and
                         $_.IdentityReference -notmatch "Domain Admins|Enterprise Admins|SYSTEM|Administrators|Cert Publishers" } |
          Select-Object @{N='Template';E={$tn}}, IdentityReference, ActiveDirectoryRights
      } | Format-Table | Out-File "$reportPath\02_ESC4Candidates.txt" -Append
} catch {
    "Could not query: $_" | Out-File "$reportPath\02_ESC4Candidates.txt" -Append
}

"=== CA Published Templates (correlate against candidates above) ===" | Out-File "$reportPath\03_PublishedTemplates.txt"
try {
    certutil -CATemplates | Out-File "$reportPath\03_PublishedTemplates.txt" -Append
} catch {
    "certutil not available or no CA reachable from this host: $_" | Out-File "$reportPath\03_PublishedTemplates.txt" -Append
}

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List templates with enrollee-supplied-subject set | `Get-ADObject -SearchBase (Get-ADRootDSE).ConfigurationNamingContext -LDAPFilter "(objectClass=pKICertificateTemplate)" -Properties Name,msPKI-Certificate-Name-Flag \| Where-Object { $_.'msPKI-Certificate-Name-Flag' -band 0x1 }` |
| List ESC1-shaped templates (subject + client-auth EKU combined) | `Get-ADObject ... -LDAPFilter "(&(objectClass=pKICertificateTemplate)(msPKI-Certificate-Name-Flag:1.2.840.113556.1.4.804:=1)(pKIExtendedKeyUsage=1.3.6.1.5.5.7.3.2))"` |
| Pull a template's full ACL | `(Get-ADObject ... -Properties nTSecurityDescriptor).nTSecurityDescriptor.Access` |
| Confirm which CAs publish a template | `certutil -CATemplates` |
| View CA issuance log for a specific request | `certutil -view -restrict "RequestID=<id>"` |
| Open Certificate Templates MMC | `certtmpl.msc` |
| Open the issuing CA console | `certsrv.msc` |
| Well-known Certificate-Enrollment extended right GUID | `0e10c968-78fb-11d2-90d4-00c04f79dc55` |
| Client Authentication EKU OID | `1.3.6.1.5.5.7.3.2` |
| Any Purpose EKU OID | `2.5.29.37.0` |

---
## 🎓 Learning Pointers

- **ESC1/ESC4 require no relay, no coercion, no network exploitation at all** — the entire attack is one legitimate-looking enrollment request from an account that already has the rights. This is what makes template misconfiguration a distinct, and in practice stealthier, attack surface from `NTLMRelayADCS-A.md`'s ESC8, even though both live under the "AD CS misconfiguration" umbrella.
- **A template's ACL is itself part of the attack surface (ESC4), independent of its current subject-name/EKU configuration.** Auditing only current-configuration (ESC1-shape) checks and skipping the ACL write-rights sweep leaves a real gap — a safe-looking template today can be one `WriteDacl` away from unsafe tomorrow.
- **This is architecturally distinct from `CertificateServices-A.md`'s template-ACL coverage**, even though both read the same `nTSecurityDescriptor` attribute. That topic verifies the *right* population can auto-enroll (an availability question); this topic verifies the *wrong* population cannot obtain an identity-spoofing-capable certificate (a security question).
- **A certificate obtained via ESC1/ESC4 passes certificate-mapping validation (KB5014754) cleanly** — see `ActiveDirectory/Troubleshooting/CertificateMapping/Certificate-Mapping-A.md`. That hardening validates whether a presented certificate correctly maps to an account; an ESC1/ESC4 certificate's mapping is technically "correct" because the SAN is exactly what the attacker requested. Fixing certificate mapping does not fix this gap.
- v1 (legacy) templates grant Enroll implicitly to holders of Read — always confirm the template schema version before concluding "the ACL shows no Enroll grant, so nobody can enroll."
- Related: [Microsoft Learn — Certificate Templates](https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/certificate-templates), [Microsoft Learn — Configure Certificate Template Permissions](https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/configure-certificate-template-permissions), SpecterOps "Certified Pre-Owned: Abusing Active Directory Certificate Services" (the origin of the ESC1-ESC8+ community numbering convention referenced throughout this repo's AD CS topics).
