# Certificate-Based Authentication Mapping (KB5014754) — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session on the DC that logged the failure (or against a DC via `-ComputerName`):

```powershell
# 1. Current KDC strong-mapping enforcement mode (registry key is UNSUPPORTED on any DC patched
#    Sept 9 2025 or later — such DCs are permanently in Full Enforcement regardless of this value)
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" -Name "StrongCertificateBindingEnforcement" -ErrorAction SilentlyContinue

# 2. Most recent certificate-mapping failures/warnings in the System log (Kdcsvc source)
Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=39 or EventID=40 or EventID=41)]]" -MaxEvents 10 |
  Select-Object TimeCreated, Id, Message

# 3. Confirm this DC's cumulative update level (Full Enforcement became permanent/unbypassable
#    starting with the Sept 9 2025 update — this is the single most important fact for triage)
Get-HotFix | Where-Object { $_.Description -match "Security Update" } | Sort-Object InstalledOn -Descending | Select-Object -First 5

# 4. Check the affected user's manual altSecurityIdentities mapping (if any) — run against a DC/GC
Get-ADUser -Identity <SamAccountName> -Properties altSecurityIdentities | Select-Object -ExpandProperty altSecurityIdentities

# 5. Dump the presented certificate to check for the SID extension (OID 1.3.6.1.4.1.311.25.2)
certutil -dump <path-to-cert.cer> | Select-String "1.3.6.1.4.1.311.25.2","Subject Alternative Name"
```

| What you see | What it means |
|---|---|
| Event 39 (Warning) | DC is pre-Sept-2025-patch and still in **Compatibility mode** — weak mapping accepted, but flagged. Certificate needs a strong mapping before this DC's next enforcement-relevant update. |
| Event 39 (Error) | DC is in **Full Enforcement** (permanent on any DC patched Sept 2025+) and authentication was **denied** — no strong mapping and no valid SID extension found. Go to Fix 1. |
| Event 40 | Certificate predates the user account and no strong mapping exists — only logged in Compatibility mode; on a fully-patched DC this becomes an outright Event 39 denial instead. Go to Fix 2. |
| Event 41 | Certificate has a SID extension, but the SID **does not match** the authenticating user — either a real mis-issuance/security incident or the cert was reused/cloned across accounts. Go to Fix 3 — do not treat as routine. |
| `StrongCertificateBindingEnforcement` key absent AND DC patched Sept 2025+ | This is expected and correct — the key is retired. The DC is in Full Enforcement unconditionally; do not go looking for a compatibility toggle that no longer exists. |
| Cert is from a non-Microsoft/third-party CA | It almost certainly lacks the SID extension (only Microsoft Enterprise CAs add it automatically). Go to Fix 4 — explicit `altSecurityIdentities` mapping is the only path. |
| Failure is on an IIS/web app, not a domain sign-in | This is the Schannel/TLS client-certificate path, a separate registry key (`CertificateMappingMethods`) and a separate KDC mechanism (Kerberos S4U2Self) — go to Fix 5. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Client presents a certificate for PKINIT (smart card/WHfB/cert-based logon) or TLS client auth
  └── Does the certificate carry the SID extension (OID 1.3.6.1.4.1.311.25.2)?
        ├── YES — issued by an Enterprise CA from an online template since May 2022, extension not
        │         disabled via msPKI-Enrollment-Flag +0x00080000
        │         └── KDC validates: does the embedded SID match the authenticating account's SID?
        │               ├── MATCH → authentication succeeds
        │               └── MISMATCH → Event 41, authentication DENIED (treat as possible incident)
        └── NO — third-party CA, extension explicitly disabled, or pre-May-2022 certificate
              └── Does the user/computer object have an explicit STRONG altSecurityIdentities
                  mapping (X509IssuerSerialNumber / X509SKI / X509SHA1PublicKey)?
                    ├── YES → authentication succeeds regardless of enforcement mode
                    └── NO → only a WEAK mapping (X509IssuerSubject/X509SubjectOnly/X509RFC822)
                          or no mapping at all exists
                          └── Is this DC in Full Enforcement? (permanent/unconditional on any DC
                              patched with the Sept 9 2025 update or later — no registry bypass exists)
                                ├── YES → Event 39 (Error), authentication DENIED
                                └── NO (pre-Sept-2025-patch DC only) → Event 39 (Warning), allowed
                                      but flagged as exposure — this is borrowed time
```

Key failure points:
- The registry key that used to let you step back to Compatibility mode (`StrongCertificateBindingEnforcement`) is **retired**, not just defaulted differently — on any DC carrying the September 9, 2025 security update or later, setting it to `1` or `0` has no effect. This is unlike LDAP signing/channel binding, which still has a live registry lever — do not assume the same escape hatch exists here.
- Non-Microsoft CAs, and any Microsoft CA template with the SID extension deliberately suppressed, will never self-heal — they require an explicit, per-account `altSecurityIdentities` mapping as the only durable fix.
- Event 41 (SID mismatch) is fundamentally different from Event 39/40 — it means a *valid, strongly-mapped* certificate was presented for the wrong account. Investigate before remediating; this is the pattern a certificate-cloning or mis-issuance attack produces.
- TLS/Schannel client-certificate mapping (IIS, other server apps) is a parallel, independently-configured path (`CertificateMappingMethods` under `SecurityProviders\Schannel`) — fixing PKINIT/KDC mapping does nothing for this path and vice versa.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the DC's patch level and effective enforcement state**
```powershell
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 3
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" -Name "StrongCertificateBindingEnforcement" -ErrorAction SilentlyContinue
```
Expected: if the DC's cumulative update is dated September 9, 2025 or later, treat it as Full Enforcement regardless of the registry value — the key is cosmetic at that patch level.

**Step 2 — Pull the exact event and its embedded detail (Subject, Issuer, Serial, Thumbprint, and for Event 41, both SIDs)**
```powershell
Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=39 or EventID=40 or EventID=41)]]" -MaxEvents 5 |
  Format-List TimeCreated, Id, Message
```
Expected: the message body names the affected principal and the certificate's Subject/Issuer/Serial/Thumbprint — copy these verbatim, you'll need them for the fix.

**Step 3 — Check whether the certificate already carries the SID extension**
```powershell
certutil -dump <path-to-cert.cer> | Select-String "1.3.6.1.4.1.311.25.2"
```
Expected: presence confirms a Microsoft Enterprise CA issued it with the extension intact — absence means either a third-party CA or a template with the extension deliberately disabled.

**Step 4 — Check the account's current altSecurityIdentities value(s)**
```powershell
Get-ADUser -Identity <SamAccountName> -Properties altSecurityIdentities |
  Select-Object -ExpandProperty altSecurityIdentities
```
Expected: zero, one, or more mapping strings. Classify each against the weak/strong table in Fix 1 before deciding what to add.

**Step 5 — Validate after remediation**
```powershell
Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=39 or EventID=40 or EventID=41)]]" -MaxEvents 1
```
Expected: no new Event 39/40/41 for the remediated account on subsequent authentication attempts, and the user reports successful sign-in.

---
## Common Fix Paths

<details><summary>Fix 1 — Event 39 (Error): no strong mapping and no valid SID extension, authentication denied</summary>

**Cause:** The certificate has neither the SID extension nor a corresponding explicit strong `altSecurityIdentities` mapping, and this DC is in Full Enforcement (the default and only supported state on any DC patched Sept 2025+).

```powershell
# Preferred fix: reissue the certificate from a template that includes the SID extension
# (default for Microsoft Enterprise CA online templates since the May 2022 update, unless
# explicitly disabled via msPKI-Enrollment-Flag +0x00080000 — check the issuing template)
certutil -template

# If reissuance isn't immediately possible, add an explicit STRONG mapping instead.
# Get the Issuer and SerialNumber from the certificate first (certutil -dump), then REVERSE
# the byte order of both before building the mapping string — see Learning Pointers.
Set-ADUser -Identity <SamAccountName> -Add @{
  altSecurityIdentities = "X509:<I>DC=com,DC=contoso,CN=CONTOSO-DC-CA<SR>1200000000AC11000000002B"
}
```

**Rollback note:** Adding an `altSecurityIdentities` value is additive and low-risk; remove it with `-Remove` on the same attribute if issued in error. Reissuing a certificate is not reversible once the old one is revoked — confirm the new mapping works before revoking the old cert.

</details>

<details><summary>Fix 2 — Event 40: certificate predates the account, no strong mapping</summary>

**Cause:** The certificate's issuance timestamp is earlier than the AD account's creation timestamp (common after an account rebuild, a forest migration, or a certificate issued before onboarding completed) and no strong mapping bridges the gap.

```powershell
# Confirm the timestamps to understand the actual gap
$cert = Get-PfxCertificate -FilePath <path-to-cert.cer>
$cert.NotBefore
(Get-ADUser -Identity <SamAccountName> -Properties whenCreated).whenCreated

# Preferred fix: reissue the certificate now that the account exists
# Acceptable bridge: add an explicit strong altSecurityIdentities mapping (bypasses the
# backdating check entirely — strong mappings are never date-checked)
Set-ADUser -Identity <SamAccountName> -Add @{
  altSecurityIdentities = "X509:<I>DC=com,DC=contoso,CN=CONTOSO-DC-CA<SR>1200000000AC11000000002B"
}
```

**Rollback note:** No destructive action here — this is purely additive. Note that the old `CertificateBackdatingCompensation` registry workaround is also retired on Sept-2025+ patched DCs; do not spend time configuring it on a current DC.

</details>

<details><summary>Fix 3 — Event 41: certificate's SID does not match the authenticating account (investigate first)</summary>

**Cause:** The certificate carries a valid SID extension, but the embedded SID belongs to a *different* account than the one attempting to authenticate. This can be legitimate (a stale mapping after an account was deleted and its SID reused is rare in modern AD, but a shared/cloned certificate across two accounts is not) or it can indicate mis-issuance or an active attack.

```powershell
# Pull both SIDs from the event detail and confirm which account the certificate was
# actually issued to before touching anything
Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=41)]]" -MaxEvents 1 |
  Format-List Message

# If the certificate was legitimately reissued/reassigned and the old mapping is simply stale,
# correct the explicit mapping (or reissue) for the CORRECT account only
# If this looks like mis-issuance or credential sharing, treat as a security event — do not
# "fix" it by remapping without understanding why two accounts point at the same certificate
```

**Rollback note:** N/A — this fix path starts with investigation, not a technical rollback. Escalate to security if the cause isn't a benign stale mapping.

</details>

<details><summary>Fix 4 — Third-party/non-Microsoft CA certificates never get a SID extension</summary>

**Cause:** Only Microsoft Enterprise CAs auto-embed the SID extension on certificates issued from online templates. Third-party CAs (public CAs, other vendors' internal PKI) have no equivalent, and Full Enforcement will deny every one of these certificates unless an explicit strong mapping exists.

```powershell
# There is no template setting to fix on a non-Microsoft CA — an explicit strong
# altSecurityIdentities mapping per account is the only durable path
# X509IssuerSerialNumber is Microsoft's recommended strong mapping type
Set-ADUser -Identity <SamAccountName> -Add @{
  altSecurityIdentities = "X509:<I>CN=ThirdPartyRootCA,O=Vendor<SR>0123456789ABCDEF"
}

# For fleets with many affected accounts, script the bulk mapping from a CSV of
# SamAccountName/Issuer/SerialNumber rather than mapping one at a time
```

**Rollback note:** Additive, low-risk change per account. Track third-party-CA accounts as an ongoing maintenance item — every certificate renewal from that CA needs its mapping updated too, since the mapping is tied to the specific Issuer+SerialNumber (or SKI/public key) of one certificate.

</details>

<details><summary>Fix 5 — IIS/web app TLS client-certificate mapping fails (Schannel path, not PKINIT)</summary>

**Cause:** This is a separate mapping mechanism from KDC/PKINIT — Schannel maps a TLS client certificate to a Windows account via Kerberos S4U2Self, and it has its own registry-controlled bitmask.

```powershell
# Check current Schannel certificate mapping methods (default is 0x18 — S4U2Self + S4U2Self
# explicit, both strong; weak Subject/Issuer/UPN mappings are disabled by default)
Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\SecurityProviders\Schannel" -Name "CertificateMappingMethods" -ErrorAction SilentlyContinue

# The relevant Kerberos events for this path appear on the APPLICATION SERVER (e.g. the IIS
# box), not the client — the S4U2Self request flows from the app server to the DC
Get-WinEvent -LogName "Microsoft-Windows-Security-Kerberos/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue

# If legitimately needed as a temporary diagnostic step, re-enabling weak methods (0x1F)
# reverts to the pre-hardening behavior — treat as a time-boxed diagnostic only, not a fix
Set-ItemProperty "HKLM:\System\CurrentControlSet\Control\SecurityProviders\Schannel" -Name "CertificateMappingMethods" -Value 0x1F
```

**Rollback note:** Setting `CertificateMappingMethods` back to `0x18` (or removing the override to fall back to the current default) restores strong-mapping-only behavior. `0x1F` re-enables weak mapping types domain/app-wide for every app relying on this registry key — narrow the diagnostic window and revert.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Certificate-Based Authentication Mapping Issue (KB5014754)

Affected account: ____________
Affected DC(s): ____________
DC cumulative update date (pre/post Sept 9 2025): ____________
Event ID observed (39/40/41): ____________
Event Type (Warning/Error): ____________
Certificate Subject: ____________
Certificate Issuer: ____________
Certificate Serial Number: ____________
Certificate has SID extension (Yes/No, via certutil -dump): ____________
Current altSecurityIdentities value(s) on the account: ____________
Is this a PKINIT/smart-card/WHfB sign-in or a TLS/IIS app (Schannel) issue: ____________

Steps already attempted:
[ ] Confirmed DC patch level / effective enforcement mode
[ ] Captured exact event detail (Subject/Issuer/Serial/Thumbprint, and both SIDs if Event 41)
[ ] Checked certificate for the SID extension via certutil -dump
[ ] Checked account's current altSecurityIdentities mapping(s)
[ ] For Event 41 specifically: confirmed this is not a mis-issuance/security incident
```

---
## 🎓 Learning Pointers

- **The Compatibility-mode registry key is retired, not just re-defaulted.** On any DC carrying the September 9, 2025 update or later, `StrongCertificateBindingEnforcement` has no effect at any value — Full Enforcement is unconditional. Don't spend triage time looking for a toggle that no longer works.
- **`altSecurityIdentities` byte order is the single most common hand-mapping mistake.** When you copy the Issuer or SerialNumber fields from a certificate dump, you must reverse the byte order before building the mapping string — reversing "A1B2C3" correctly gives "C3B2A1", not "3C2B1A".
- **Event 41 (SID mismatch) is not routine noise — investigate before remediating.** Unlike Event 39/40 (missing/absent mapping), Event 41 means a strongly-mapped, cryptographically valid certificate pointed at the wrong account. Confirm why before changing anything.
- **Third-party CA certificates will never get the SID extension automatically.** Only Microsoft Enterprise CA online templates add it. Any org using a public CA or non-Microsoft internal PKI for user/computer authentication certificates needs an explicit strong `altSecurityIdentities` mapping strategy, permanently, not as a one-time fix.
- **PKINIT/KDC mapping and Schannel TLS client-certificate mapping are two separate systems with two separate registry keys.** Fixing one does nothing for the other — always confirm which path is actually failing (domain sign-in vs. IIS/web app) before choosing a fix.
- Related: [KB5014754 — Certificate-based authentication changes on Windows domain controllers](https://support.microsoft.com/en-us/topic/kb5014754-certificate-based-authentication-changes-on-windows-domain-controllers-ad2c23b0-15d8-4340-a468-4d4f3b188f16), [Understanding and Troubleshooting Strong Certificate Name Mapping in Active Directory (Microsoft Tech Community)](https://techcommunity.microsoft.com/blog/askds/understanding-and-troubleshooting---strong-certificate-name-mapping-in-active-di/4451386)
