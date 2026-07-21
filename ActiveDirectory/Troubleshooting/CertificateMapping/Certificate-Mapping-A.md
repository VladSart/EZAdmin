# Certificate-Based Authentication Mapping (KB5014754) — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This runbook covers the certificate-to-account mapping hardening Microsoft shipped starting with the May 10, 2022 security updates in response to [CVE-2022-34691](https://msrc.microsoft.com/update-guide/vulnerability/CVE-2022-34691), [CVE-2022-26931](https://msrc.microsoft.com/update-guide/vulnerability/CVE-2022-26931), and [CVE-2022-26923](https://msrc.microsoft.com/update-guide/vulnerability/CVE-2022-26923) — collectively tracked as **KB5014754**. It covers both authentication paths this hardening touches: **PKINIT** (Kerberos certificate-based logon — smart card, Windows Hello for Business certificate trust, cert-based VPN) validated by the KDC, and **Schannel TLS client-certificate mapping** (IIS and other server applications) validated via Kerberos S4U2Self. As of the current timeline, every supported Windows Server DC that has received the September 9, 2025 security update or later is in **Full Enforcement permanently** — the Compatibility-mode registry bypass Microsoft originally shipped as a transition aid no longer functions on those DCs.

**Does not cover:** general AD Certificate Services (AD CS) installation, CA hierarchy design, or certificate template permission delegation (those are CA-administration topics, not this authentication-hardening control); Entra ID's own, architecturally separate Certificate-Based Authentication for cloud sign-in — see `EntraID/Troubleshooting/CBA-A.md`/`-B.md` for that (cloud CBA validates against uploaded trusted CAs directly in Entra ID and has its own `certificateUserIds` binding model, unrelated to the on-prem KDC mechanism documented here); LDAP signing/channel binding, a separate NTLM-relay-to-LDAP hardening control on a different protocol — see `Troubleshooting/LDAPSigning/LDAP-Signing-A.md`.

---
## How It Works

<details><summary>Full architecture</summary>

**The vulnerability this closes.** Before the May 2022 update, the KDC's PKINIT certificate-to-account mapping logic had two gaps an attacker with limited write access to AD (such as the ability to rename a computer object) could exploit: (1) certificate mapping did not account for a trailing `$` on machine account names, allowing a certificate issued to one machine to be emulated against another; (2) User Principal Name (UPN) values are not guaranteed unique or immutable in AD the way a SID is — an attacker who could create or rename an account to claim another principal's UPN, or exploit a UPN/sAMAccountName mismatch, could obtain a certificate that mapped to a victim account. Both are privilege-escalation paths from limited AD write access to full account impersonation.

**The fix has two independent layers.**

1. **The SID extension (OID `1.3.6.1.4.1.311.25.2`).** Starting with the May 2022 update, every Microsoft Enterprise CA automatically embeds the requesting account's SID as a non-critical certificate extension on every certificate issued from an *online* template (i.e., templates that go through the CA's live enrollment process, as opposed to offline/manual issuance). The KDC can then compare the SID embedded in the presented certificate against the authenticating account's actual SID at logon time — a check that is immune to UPN reuse or name changes, because a SID is never reused within a domain's lifetime. An admin can suppress this extension per-template by setting bit `0x00080000` on `msPKI-Enrollment-Flag`, but doing so removes this specific protection for that template's certificates.

2. **Explicit strong mapping via `altSecurityIdentities`.** For certificates that predate the SID extension, come from a third-party/non-Microsoft CA, or have the extension deliberately disabled, administrators can manually bind a certificate to an account via the `altSecurityIdentities` multi-valued attribute. Of the six supported mapping string formats, three are classified **weak** (based on reusable identifiers — Subject/Issuer distinguished name, Subject-only, or RFC822/email address) and three are classified **strong** (based on identifiers that cannot be reused once issued — Issuer+SerialNumber, Subject Key Identifier, or SHA1 public key hash). `X509IssuerSerialNumber` is Microsoft's recommended strong mapping type, and as of the February 2024 update, Active Directory Users & Computers' certificate-mapping UI defaults to it instead of the historically weak Subject/Issuer format.

**The three enforcement modes (historical — see Full Enforcement note below).** The `StrongCertificateBindingEnforcement` registry value (`HKLM\SYSTEM\CurrentControlSet\Services\Kdc`) originally supported three states: `0` (disabled — strong mapping check skipped entirely, never recommended, and requires setting Schannel's `CertificateMappingMethods` to `0x1F` for computer-certificate Schannel auth to keep working), `1` (Compatibility — authenticate if a strong mapping exists OR if the SID extension validates OR, failing both, allow with a warning if the certificate doesn't predate the account), and `2` (Full Enforcement — authenticate only if a strong mapping exists or the SID extension validates; anything else is denied outright). **Disabled mode was removed entirely on April 11, 2023.** Compatibility mode's registry-key support ended with the September 9, 2025 update — after that update is installed, the key has no effect and every DC is unconditionally in Full Enforcement. Between February 11, 2025 and September 9, 2025, DCs were force-moved to Enforcement by the February update but retained the ability to step back to Compatibility via the registry key as a bridge; that bridge window is now closed for any DC on current updates.

**Certificate backdating.** A related but separate registry value, `CertificateBackdatingCompensation` (also under the `Kdc` key), allowed a configurable grace window for certificates whose issuance timestamp predates the AD account's creation timestamp — common after account rebuilds or forest migrations — but only under weak mappings and only in Compatibility mode. Like the enforcement key itself, this key stopped having effect once a DC is running the September 2025 update or later, since Compatibility mode itself no longer exists on those DCs.

**The Schannel/TLS path is architecturally separate.** When a server application (classically IIS with client-certificate authentication configured) needs to map a presented TLS client certificate to a Windows account, it does so via Schannel, which in turn uses the Kerberos **Service-For-User-to-Self (S4U2Self)** protocol extension to resolve the certificate to an account — a completely different code path from KDC/PKINIT, governed by its own registry value: `CertificateMappingMethods` (`HKLM\System\CurrentControlSet\Control\SecurityProviders\Schannel`), a bitmask where `0x0001`/`0x0002`/`0x0004` are the now-disabled-by-default weak Subject/Issuer/UPN mapping methods, and `0x0008`/`0x0010` are the strong S4U2Self methods enabled by default (bitmask sum `0x18`, changed down from the pre-hardening default of `0x1F`). Because the S4U2Self request flows from the *application server* to the DC — not from the client directly — the relevant Kerberos Operational log events for this path live on the app server, not the end-user's machine. This is a frequent troubleshooting misstep: engineers look for Kerberos errors on the client when the actual failure is logged on the IIS box.

</details>

---
## Dependency Stack

```
Layer 5 — Application / Auth Consumer
  ├── PKINIT-consuming scenario: interactive smart-card/WHfB-cert/cert-based-VPN logon
  └── Schannel-consuming scenario: IIS/other server app with TLS client-cert auth configured
        └── uses Kerberos S4U2Self, NOT the KDC's direct PKINIT path — separate registry key

Layer 4 — Certificate-to-Account Binding Decision
  ├── PKINIT path (KDC, HKLM\SYSTEM\CurrentControlSet\Services\Kdc)
  │     ├── StrongCertificateBindingEnforcement (0/1/2 — RETIRED as of Sept 9 2025 update;
  │     │     Full Enforcement is unconditional on any DC at that patch level or later)
  │     ├── UseSubjectAltName (controls whether the SID extension is honored at all;
  │     │     default/0x1 = used, 0x0 = ignored even if present)
  │     └── CertificateBackdatingCompensation (Compatibility-mode-only grace window,
  │           also non-functional once Compatibility mode itself is retired)
  └── Schannel/TLS path (HKLM\System\CurrentControlSet\Control\SecurityProviders\Schannel)
        └── CertificateMappingMethods (bitmask: 0x1/0x2/0x4 weak, 0x8/0x10 strong S4U2Self;
              default 0x18 since the hardening shipped, was 0x1F before)

Layer 3 — Mapping Evidence Available on the Certificate/Account
  ├── SID extension embedded in the certificate itself (OID 1.3.6.1.4.1.311.25.2)
  │     └── requires: Microsoft Enterprise CA + online template + msPKI-Enrollment-Flag
  │           bit 0x00080000 NOT set
  └── altSecurityIdentities attribute on the AD account (explicit, admin-managed)
        ├── Strong types: X509IssuerSerialNumber (recommended), X509SKI, X509SHA1PublicKey
        └── Weak types: X509IssuerSubject, X509SubjectOnly, X509RFC822 (email) — insufficient
              alone under Full Enforcement

Layer 2 — Certificate Issuance
  ├── Microsoft Enterprise CA, online template → SID extension auto-added (default since
  │     the May 2022 update, per-template opt-out available)
  └── Third-party/non-Microsoft CA, or offline/manual issuance → NO automatic SID extension,
        ever — explicit altSecurityIdentities mapping is the only path to Full Enforcement compliance

Layer 1 — AD Account Identity
  └── SID (immutable, never reused within the domain's lifetime — the anchor every
        strong-mapping mechanism ultimately trusts) vs. UPN/sAMAccountName (mutable,
        reusable, the exact properties the pre-2022 vulnerability exploited)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Smart-card/WHfB users suddenly can't sign in after a DC patch cycle | DC crossed into Full Enforcement (Feb 2025 update forced it; Sept 2025 update made it permanent/unbypassable) and affected certs lack both the SID extension and a strong mapping | Event 39 (Error) in System log; `certutil -dump` the cert for the SID extension OID |
| One specific user/device fails while everyone else on the same cert template works fine | That one account's certificate predates the AD account's creation, or has a stale/incorrect explicit mapping | Event 40 (Compatibility-mode DCs only) or Event 39 (Enforcement); compare cert `NotBefore` to `whenCreated` |
| Authentication denied with a certificate that looks completely valid and correctly issued | SID mismatch — the embedded SID doesn't match the authenticating account, despite a technically valid cert | Event 41 — treat as a possible security event, not routine config drift |
| All certificates from one specific CA/PKI vendor fail, others succeed | That CA is non-Microsoft (or a Microsoft CA with the SID extension deliberately disabled on the issuing template) | `certutil -dump` shows no OID `1.3.6.1.4.1.311.25.2`; confirm CA vendor and template `msPKI-Enrollment-Flag` |
| IIS site with client-certificate auth stops mapping users, but domain sign-in (smart card, WHfB) is unaffected | This is the Schannel/S4U2Self path, not PKINIT — separate registry key, separate failure mode | `CertificateMappingMethods` value under `SecurityProviders\Schannel`; Kerberos Operational log **on the app server**, not the client |
| Certificates worked fine for years, then broke tenant-wide on a specific patch date with no config change made locally | The DC crossed an enforcement milestone (Feb 11 2025 forced move to Enforcement, or Sept 9 2025 permanent retirement of the Compatibility bypass) purely from installing routine Windows updates | `Get-HotFix` install dates vs. the KB5014754 timeline; this is expected behavior, not a bug |
| Attempted registry fix (`StrongCertificateBindingEnforcement = 1`) has no effect | DC is patched Sept 9 2025+ and the key is retired — this is not a permissions or syntax problem, the key is simply non-functional at that patch level | `Get-HotFix` to confirm patch date |
| Users authenticate fine via smart card but a scheduled task/service using the same certificate for Schannel-based auth fails | Two independent mapping systems evaluated the same certificate differently — PKINIT succeeded, S4U2Self/Schannel mapping did not (or vice versa) | Check both `StrongCertificateBindingEnforcement`-governed events AND `CertificateMappingMethods`/Kerberos Operational log on the relevant server |
| GPO change to "Process even if the Group Policy objects have not changed" correlates with intermittent name-based mapping failures | Documented Microsoft-acknowledged interaction between that GPO setting and KDC name-based strong mappings | Disable that specific setting on DCs if name-based strong mappings (via the "Allow name-based strong mappings for certificates" GPO) are in use |
| New PKI stood up, certificates issued, but nothing changed for existing accounts that already had explicit mappings | Explicit `altSecurityIdentities` mappings take precedence and are unaffected by CA changes — expected, not a defect | `Get-ADUser -Properties altSecurityIdentities` to confirm existing mappings are still present and correctly formatted |

---
## Validation Steps

1. **Confirm the DC's actual enforcement state via patch level, not the registry key alone.**
   ```powershell
   Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 3
   ```
   Good: most recent security update dated September 9, 2025 or later — treat as permanent Full Enforcement. Bad/ambiguous: update older than that — the registry key may still be meaningful; check it explicitly.

2. **Enumerate recent Kdcsvc mapping events across the DC.**
   ```powershell
   Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=39 or EventID=40 or EventID=41)]]" -MaxEvents 50
   ```
   Good: zero events, or events trending down after remediation. Bad: a steady or increasing rate of Event 39 (Error) — active, unresolved denial exposure.

3. **Confirm the SID extension is present and valid on a sample of recently-issued internal certificates.**
   ```powershell
   certutil -dump <cert-file> | Select-String "1.3.6.1.4.1.311.25.2"
   ```
   Good: extension present for certificates from internal Enterprise CA templates. Bad: absent — check `msPKI-Enrollment-Flag` on the issuing template for an accidental `0x00080000` opt-out.

4. **Inventory explicit `altSecurityIdentities` mappings and classify weak vs. strong.**
   ```powershell
   Get-ADUser -Filter { altSecurityIdentities -like "*" } -Properties altSecurityIdentities |
     Select-Object SamAccountName, altSecurityIdentities
   ```
   Good: all mappings use `X509IssuerSerialNumber`, `X509SKI`, or `X509SHA1PublicKey`. Bad: any mapping using `X509IssuerSubject`, `X509SubjectOnly`, or `X509RFC822` — these do not satisfy Full Enforcement on their own.

5. **Verify the Schannel bitmask matches intended policy on servers doing TLS client-cert mapping.**
   ```powershell
   Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\SecurityProviders\Schannel" -Name "CertificateMappingMethods" -ErrorAction SilentlyContinue
   ```
   Good: `0x18` (strong-only, current default) unless a documented, time-boxed exception is in place. Bad: `0x1F` left permanently — weak mapping types silently re-enabled.

6. **Cross-check for the documented GPO interaction if name-based mappings are used.**
   ```powershell
   Get-GPRegistryValue -Name "Default Domain Controllers Policy" -Key "HKLM\Software\Policies\Microsoft\Windows\Group Policy" -ValueName "EnableAsynchronousProcessing" -ErrorAction SilentlyContinue
   ```
   Good: "Process even if the Group Policy objects have not changed" is not forcing reprocessing in a way that conflicts with name-based mapping GPOs. Bad: intermittent name-based mapping failures correlating with GPO refresh cycles.

7. **Confirm no DC in the environment is still running a pre-February-2025 update relying on default Compatibility-mode behavior.**
   ```powershell
   Get-ADDomainController -Filter * | ForEach-Object {
     Invoke-Command -ComputerName $_.HostName -ScriptBlock { (Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn }
   }
   ```
   Good: every DC current within a normal patch cadence. Bad: a straggler DC on materially older updates — it will behave differently (more permissively) than the rest of the fleet, producing confusing "works against one DC, fails against another" symptoms identical in shape to the LDAP-signing cross-DC-consistency issue.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Establish ground truth on enforcement state.** Do not trust "we never touched that registry key" as evidence of anything — check the actual patch level of the specific DC that logged the failure. A mixed-patch-level DC fleet will show inconsistent behavior for the exact same certificate.

**Phase 2 — Capture the exact event and every field in it.** Event 39/40/41 messages include Subject, Issuer, Serial Number, and Thumbprint (plus both SIDs for Event 41) — copy these verbatim rather than paraphrasing; the byte-order-sensitive fields you'll need for a manual mapping come directly from here.

**Phase 3 — Classify the certificate's issuance path.** Internal Microsoft Enterprise CA (check for the SID extension first — it may already be strongly mapped and the failure is something else, like Event 41 mismatch) vs. third-party/non-Microsoft CA (SID extension will never be present, plan for explicit mapping as the permanent state, not a one-off fix).

**Phase 4 — Distinguish PKINIT (KDC) failures from Schannel (S4U2Self) failures early.** The symptom presentation looks similar (a certificate-based authentication rejection) but the registry key, the relevant event log, and even which machine logs the event (client/DC for PKINIT vs. application server for Schannel) are completely different. Getting this wrong burns significant troubleshooting time.

**Phase 5 — For Event 41 specifically, pause before remediating.** Confirm whether this is legitimate stale-mapping drift (rare, but possible after certain account rebuild scenarios) or a genuine mis-issuance/security concern before simply updating the mapping to "make the error go away."

**Phase 6 — Remediate and validate against the specific playbook below, then re-run the fleet-wide event count from Validation Step 2 over the following days** to confirm the fix generalizes rather than just resolving the one reported case.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide SID-extension audit and rollout for an internal Enterprise CA</summary>

**Scenario:** Your organization uses a Microsoft Enterprise CA for user/computer authentication certificates and needs to confirm the SID extension is actually present across all relevant templates before relying on it as the primary Full Enforcement compliance mechanism.

1. Inventory every certificate template used for user/computer/smart-card/WHfB authentication:
   ```powershell
   certutil -catemplates
   ```
2. For each relevant template, check `msPKI-Enrollment-Flag` for the `0x00080000` SID-extension-suppression bit:
   ```powershell
   certutil -v -template <TemplateName> | Select-String "msPKI-Enrollment-Flag"
   ```
3. For any template with the bit set and no clear reason for it, clear it so new issuances get the extension:
   ```powershell
   certutil -dstemplate <TemplateName> msPKI-Enrollment-Flag -0x00080000
   ```
4. **Existing certificates are not retroactively updated** — the extension is only added at issuance time. Plan a reissuance cycle for any certificate issued before the template fix, or add explicit strong `altSecurityIdentities` mappings as a bridge for certificates that won't be reissued before their next natural renewal.
5. Re-run the fleet-wide Event 39/40/41 count (Validation Step 2) after the reissuance cycle completes to confirm exposure has dropped to zero.

**Rollback:** Re-setting the `msPKI-Enrollment-Flag` bit stops future issuances from getting the extension but does not remove it from certificates already issued — there is no reason to roll this back except to intentionally exclude a specific template from strong mapping (uncommon and generally not recommended).

</details>

<details><summary>Playbook 2 — Bulk explicit strong-mapping rollout for a third-party/non-Microsoft CA</summary>

**Scenario:** A significant population of accounts authenticate using certificates from a CA that will never produce the SID extension, and Full Enforcement is denying them.

1. Export the population of affected certificates with Subject/Issuer/SerialNumber (or Subject Key Identifier) from your PKI's own certificate database or inventory system — this data does not live in AD until you add it.
2. Build the mapping string per account, remembering to **reverse the byte order** of the Issuer distinguished name and SerialNumber:
   ```powershell
   # Example for one account — repeat via CSV import for bulk rollout
   Set-ADUser -Identity <SamAccountName> -Add @{
     altSecurityIdentities = "X509:<I>CN=ThirdPartyRootCA,O=Vendor<SR>0123456789ABCDEF"
   }
   ```
3. For bulk rollout, iterate a CSV (`SamAccountName,Issuer,SerialNumber`) rather than hand-mapping each account — validate a small batch first, since a malformed mapping string fails silently (the account simply won't authenticate via that certificate, with no clear error pointing at the mapping syntax itself).
4. Document this as a **standing PKI operational requirement**, not a one-time remediation — every certificate renewal from this CA needs its mapping updated, since the mapping is tied to the specific Issuer+SerialNumber (or SKI/public key) of one certificate and does not automatically follow a renewal.

**Rollback:** Remove the specific `altSecurityIdentities` value with `-Remove` on the same attribute if a mapping was added in error; this does not affect the underlying certificate or any other mapping on the account.

</details>

<details><summary>Playbook 3 — Diagnosing and fixing Schannel/TLS client-certificate mapping (IIS and similar server apps)</summary>

**Scenario:** An application using TLS client-certificate authentication (classically IIS) stops correctly mapping certificates to Windows accounts, while PKINIT-based domain sign-in is unaffected.

1. Confirm you're actually in the Schannel/S4U2Self path, not PKINIT — the failing scenario is a server application validating a client TLS certificate, not an interactive domain logon.
2. Check the current bitmask on the **application server** (not necessarily a DC):
   ```powershell
   Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\SecurityProviders\Schannel" -Name "CertificateMappingMethods" -ErrorAction SilentlyContinue
   ```
3. Review the Kerberos Operational log **on the application server**, since the S4U2Self request originates there, not on the client:
   ```powershell
   Get-WinEvent -LogName "Microsoft-Windows-Security-Kerberos/Operational" -MaxEvents 50
   ```
4. If diagnosing whether weak mapping methods were the previous (pre-hardening) reliance, temporarily test with `0x1F` in a controlled window to confirm the hypothesis, then move the underlying certificate/account to a strong mapping instead of leaving the weak bitmask enabled long-term.
5. Confirm the IIS site's own `<iisClientCertificateMappingAuthentication>` / one-to-one or many-to-one mapping configuration (a separate, IIS-specific mapping layer sitting on top of Schannel) is pointed at the correct account.

**Rollback:** Restore `CertificateMappingMethods` to `0x18` (or remove the override entirely to inherit the platform default) once diagnosis is complete — leaving `0x1F` in place re-enables weak mapping types for every application on that server relying on this shared registry key.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS Collects certificate-mapping-relevant evidence for escalation, read-only.
#>
$dc = $env:COMPUTERNAME
[PSCustomObject]@{
    ComputerName                       = $dc
    LatestHotfixDate                   = (Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn
    StrongCertificateBindingEnforcement = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" -Name "StrongCertificateBindingEnforcement" -ErrorAction SilentlyContinue).StrongCertificateBindingEnforcement
    UseSubjectAltName                  = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" -Name "UseSubjectAltName" -ErrorAction SilentlyContinue).UseSubjectAltName
    SchannelCertificateMappingMethods  = (Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\SecurityProviders\Schannel" -Name "CertificateMappingMethods" -ErrorAction SilentlyContinue).CertificateMappingMethods
    RecentEvent39Count                 = (Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=39)]]" -MaxEvents 500 -ErrorAction SilentlyContinue).Count
    RecentEvent40Count                 = (Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=40)]]" -MaxEvents 500 -ErrorAction SilentlyContinue).Count
    RecentEvent41Count                 = (Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=41)]]" -MaxEvents 500 -ErrorAction SilentlyContinue).Count
} | Format-List
```
For a multi-DC, per-account audit, use `Scripts/Get-CertificateMappingAudit.ps1`.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" -Name "StrongCertificateBindingEnforcement"` | Check KDC enforcement registry value (non-functional on DCs patched Sept 2025+) |
| `Get-HotFix \| Sort-Object InstalledOn -Descending` | Determine actual patch-level-driven enforcement state |
| `Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=39 or EventID=40 or EventID=41)]]"` | Pull certificate-mapping failure/warning events |
| `certutil -dump <cert>` | Inspect a certificate for the SID extension (OID `1.3.6.1.4.1.311.25.2`) |
| `Get-ADUser -Identity <user> -Properties altSecurityIdentities` | View an account's explicit certificate mappings |
| `Set-ADUser -Identity <user> -Add @{altSecurityIdentities="..."}` | Add an explicit strong mapping |
| `Set-ADUser -Identity <user> -Remove @{altSecurityIdentities="..."}` | Remove a specific mapping value |
| `certutil -template` | Inspect a certificate for its issuing template |
| `certutil -v -template <name> \| Select-String "msPKI-Enrollment-Flag"` | Check whether SID extension is suppressed on a template |
| `certutil -dstemplate <name> msPKI-Enrollment-Flag -0x00080000` | Re-enable SID extension issuance on a template |
| `Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\SecurityProviders\Schannel" -Name "CertificateMappingMethods"` | Check the Schannel/TLS client-cert mapping bitmask |
| `Get-WinEvent -LogName "Microsoft-Windows-Security-Kerberos/Operational"` | Review Kerberos S4U2Self events (on the app server for Schannel scenarios) |
| `Get-ADDomainController -Filter *` | Enumerate DCs for a fleet-wide patch/enforcement consistency check |
| `Get-ADUser -Filter { altSecurityIdentities -like "*" } -Properties altSecurityIdentities` | Inventory every account with an explicit mapping, for weak/strong classification |

---
## 🎓 Learning Pointers

- **This hardening has already reached its permanent end state.** Unlike LDAP signing/channel binding (which still has a live registry lever), the Compatibility-mode bypass for certificate mapping stopped functioning entirely on any DC patched with the September 9, 2025 update. Treat "check the registry key" as informative only for DCs behind on updates — for everything else, the answer is always Full Enforcement.
- **The SID extension and `altSecurityIdentities` are two independent, either-or mechanisms for satisfying strong mapping** — a certificate only needs one, not both. Don't assume a certificate lacking the extension is unfixable without an explicit mapping to fall back on, and don't assume a certificate with the extension makes an existing explicit mapping redundant (both are evaluated, either can satisfy the check).
- **Byte order matters when hand-building an `altSecurityIdentities` mapping string** — the Issuer and SerialNumber fields as reported by `certutil -dump` are in "forward" format and must be reversed before insertion. This is the most common source of a mapping that looks correct but silently doesn't work.
- **Event 41 (SID mismatch) deserves different handling than Event 39/40 (missing mapping)** — it means a cryptographically valid, strongly-mapped certificate pointed at the wrong account, which is a meaningfully different (and potentially more serious) finding than simply "no strong mapping exists yet."
- **PKINIT and Schannel/S4U2Self are genuinely separate systems that happen to share a topic name.** Confirm which one you're actually troubleshooting before reaching for a fix — the registry keys, the relevant event logs, and even which machine logs the diagnostic event differ completely between the two.
- Related: [KB5014754 — Certificate-based authentication changes on Windows domain controllers](https://support.microsoft.com/en-us/topic/kb5014754-certificate-based-authentication-changes-on-windows-domain-controllers-ad2c23b0-15d8-4340-a468-4d4f3b188f16), [Understanding and Troubleshooting Strong Certificate Name Mapping in Active Directory (Microsoft Tech Community)](https://techcommunity.microsoft.com/blog/askds/understanding-and-troubleshooting---strong-certificate-name-mapping-in-active-di/4451386), [TLS registry settings — CertificateMappingMethods](https://learn.microsoft.com/en-us/windows-server/security/tls/tls-registry-settings#certificatemappingmethods)
