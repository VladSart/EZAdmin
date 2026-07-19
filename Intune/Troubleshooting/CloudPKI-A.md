# Intune Cloud PKI — Reference Runbook (Mode A: Deep Dive)
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

Covers **Microsoft Cloud PKI** — the fully cloud-hosted PKI service for Microsoft Intune, available as part of Intune Suite, as a standalone add-on, or (starting **July 1, 2026**) bundled into Microsoft 365 E5. Covers both deployment models:

- **Native Cloud PKI**: Root CA and Issuing CA both created and signed entirely in the cloud.
- **BYOCA (bring your own CA)**: a Cloud PKI Issuing CA anchored to an existing private root (typically Active Directory Certificate Services), via a manual CSR-sign-upload loop.

Assumes devices are Intune-enrolled (Windows, iOS/iPadOS, macOS, or Android) and the target platform supports Intune's SCEP device configuration profile.

**Does not cover:**
- On-premises NDES/PKCS certificate delivery via Intune Certificate Connector — see `Certificates-A.md`/`Certificates-B.md`. Cloud PKI and the on-prem NDES/PKCS model are two entirely separate, non-overlapping certificate-delivery architectures that happen to both terminate in an Intune SCEP or PKCS certificate profile.
- Third-party cloud CA-as-a-service integrations (DigiCert, Keyfactor, etc. via their own Intune connectors) — different vendor, different connector model.
- S/MIME certificate configuration and user-initiated browser/MMC certificate requests.
- Azure Key Vault-issued certificates for Azure resources (unrelated product — see `Azure/KeyVault/KeyVault-A.md`).

---
## How It Works

<details><summary>Full architecture</summary>

### Component model

Microsoft Cloud PKI replaces the entire on-premises certificate-issuance stack — no NDES server, no IIS, no Intune Certificate Connector, no on-prem CA to patch or babysit — with three Microsoft-hosted services:

- **B1 — Cloud PKI service**: hosts the certification authorities (Root/Issuing CA objects) themselves.
- **B2 — Cloud PKI SCEP service**: the certificate registration authority (CRA) that receives SCEP requests from enrolled devices.
- **B3 — Cloud PKI SCEP validation service**: validates the device's SCEP challenge before requesting the Issuing CA sign the CSR.

Together, B2+B3 constitute the "certificate registration authority" that an on-prem deployment would otherwise need NDES for.

### Native Cloud PKI request flow

```
Device                    Intune Service          Cloud PKI SCEP (B2)     Cloud PKI Validation (B3)    Issuing CA (B1)
  |                            |                         |                         |                        |
  |-- MDM check-in ----------->|                         |                         |                        |
  |<- Trust + SCEP profiles ---|                         |                         |                        |
  |                            |                         |                         |                        |
  |-- CSR generated on-device  |                         |                         |                        |
  |   (private key never leaves device)                  |                         |                        |
  |-- SCEP request + challenge ------------------------->|                         |                        |
  |                            |                         |-- validate challenge -->|                        |
  |                            |                         |<- pass/fail ------------|                        |
  |                            |                         |-- request signature ----------------------------->|
  |                            |                         |<- signed leaf cert --------------------------------|
  |<- Signed certificate ---------------------------------|                         |                        |
```

The SCEP challenge is encrypted and signed using the Intune SCEP registration-authority keys — this is a Microsoft-managed secret, not something an administrator configures or rotates manually (unlike an on-prem NDES challenge password lifetime setting).

### Key material and signing

- **Licensed CAs** use HSM-backed signing and encryption keys provisioned via **Azure Managed HSM** — no separate Azure subscription is required for this; Intune handles it transparently.
- **Trial CAs** (Intune Suite trial or standalone Cloud PKI trial) use **software-backed** keys (`System.Security.Cryptography.RSA`). These keys **cannot be converted to HSM-backed** even after a license is purchased — a CA created during trial stays software-backed for its lifetime.
- Supported algorithms: RSA at 2048/3072/4096-bit; SHA-256/384/512 hashing. SHA-1 and 1024-bit keys are explicitly unsupported.

### CRL and AIA hosting

- Intune hosts the **CRL Distribution Point (CDP)** for every CA it manages — no separate CDP publishing infrastructure needed, unlike an on-prem CA where CDP/AIA placement is a common configuration failure point.
- CRL validity is **7 days**; publish/refresh occurs every **3.5 days**, and the CRL updates immediately on any certificate revocation.
- The **AIA (Authority Information Access)** endpoint is similarly Intune-hosted per Issuing CA, letting relying parties retrieve parent certificates.

### BYOCA deployment model

BYOCA lets you anchor a Cloud PKI Issuing CA to an existing private CA (typically on-prem AD CS) rather than a Cloud-PKI-native root:

1. Create the CA object in **Tenant administration > Cloud PKI**, with **CA Type = Issuing CA** and **Root CA Source = Bring your own root CA**.
2. Choose an RSA key size (2048/3072/4096) and define specific EKUs — the wildcard "Any Purpose" EKU (`2.5.29.37.0`) is explicitly **prohibited** for security reasons.
3. The CA object enters **"Signing required"** status and exposes a downloadable CSR (`.req` file).
4. Sign the CSR against your internal CA — via Certification Authority Web Enrollment or `certreq.exe -submit`.
5. Download both the signed certificate (`certnew.cer`) **and** the full chain (`certnew.p7b`) — Intune requires both to activate the CA.
6. Upload both files back into the Cloud PKI CA object; status flips to **Active**.
7. Create an Intune **Trusted Certificate profile for every certificate in the private CA hierarchy** (root and any intermediates) — required on every platform issuing Cloud PKI SCEP certs from this CA, since the device must trust the entire chain, not just the Cloud-PKI-managed Issuing CA.

BYOCA and native Cloud-PKI CAs can coexist in the same tenant (e.g., one root CA with two issuing CAs, or three independent BYOCA issuing CAs) — subject to the shared 3-CA capacity cap described below.

### Capacity model

A tenant may have **at most 3 CA objects total**, counting Root CA, Issuing CA, and BYOCA Issuing CA together — regardless of trial vs. licensed state. This is a hard platform ceiling with no increase path documented; hierarchy planning (one root feeding multiple issuing CAs, or retiring unused CAs) is the only lever.

</details>

---
## Dependency Stack

```
[Leaf certificate on device — issued, renewed, or revoked]
         |
         ▼
[SCEP certificate profile — device configuration, references Cloud PKI SCEP URI]
         |
         ▼
[Trusted Certificate profile(s) — Root CA cert + Issuing CA cert]
         |         (must be assigned to the SAME group as the SCEP profile,
         |          and must include EVERY cert in the chain for BYOCA)
         ▼
[Cloud PKI Issuing CA — Active status]
         |
         ├── Native path: signed entirely within Cloud PKI service (B1)
         |
         └── BYOCA path: CSR signed externally → cert + chain uploaded → status Active
         |
         ▼
[Cloud PKI SCEP service (B2) + SCEP validation service (B3)]
         |         (Microsoft-hosted certificate registration authority — no NDES equivalent to manage)
         ▼
[Azure Managed HSM-backed signing keys]   (licensed CAs)
    or [software-backed RSA keys]          (trial CAs — permanent, non-upgradable)
         |
         ▼
[Device enrolled in Intune + platform supports SCEP device configuration profile]
         |
         ▼
[Tenant capacity: ≤ 3 CA objects total across Root/Issuing/BYOCA]
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| BYOCA CA stuck showing "Signing required" for days | Expected pending state — CSR not yet signed and uploaded | Download CSR, sign via internal CA, upload both `.cer` and `.p7b` |
| Leaf cert never appears on any device targeting a given profile | Trusted Certificate profile(s) for Root/Issuing CA not assigned to the same group as the SCEP profile | Compare Assignments tab on both profile types |
| One specific device never gets its leaf cert | Device-specific delivery failure — profile assignment status, offline device, or stale check-in | `Devices > [device] > Device configuration`; MDM diagnostic log |
| Android devices fail SCEP; Windows/iOS succeed on the same profile set | Android requires the Root CA cert (not Issuing/Intermediate) in its Trusted Certificate profile | Confirm which cert was uploaded to the Android-targeted Trusted Cert profile |
| macOS error `Error Domain=MDM-SCEP Code=15001` | Device cannot validate the issuing CA — trust chain incomplete or wrong CA referenced | `log show --predicate 'subsystem == "com.apple.SCEP"'`; verify Trusted Cert profile |
| Certificate request rejected with thumbprint/CA mismatch | SCEP profile's Certification Authority selector points at the wrong CA (common with 2+ CAs in tenant) | Open SCEP profile, confirm CA selector |
| Can't create a new CA — "capacity" error | 3-CA-per-tenant hard cap reached (Root+Issuing+BYOCA combined) | `Tenant administration > Cloud PKI` — count existing CA objects |
| Certificate issued but doesn't match expected subject | Subject/SAN template misconfiguration in the SCEP profile | Compare profile's Subject Name/SAN settings against the intended variable (UPN vs Device ID) |
| Revoked certificate still appears valid to relying parties for several days | CRL refresh cadence — CRL is valid for 7 days, refreshed every 3.5 days, though revocation itself updates the CRL immediately | Confirm CRL was actually re-published (revocation event vs. cached CRL on relying party) |
| "View all certificates" in admin center seems incomplete past ~1,000 rows | Known, documented UI pagination limitation — not a data-loss issue | Use **Devices > Monitor > Certificates** for the complete list |
| Trial-created CA can't be converted to HSM-backed keys after purchasing a license | By design — trial CAs are permanently software-backed | No workaround; must create a new CA post-purchase if HSM backing is required |
| BYOCA CA rejected during creation over EKU configuration | "Any Purpose" EKU (`2.5.29.37.0`) is explicitly prohibited by Cloud PKI | Define specific, narrower EKUs (client auth, etc.) instead |
| Data-residency requirement can't be satisfied for Cloud PKI | Data residency option is **not currently available** for Cloud PKI as a documented limitation | Confirm with compliance stakeholders before committing to Cloud PKI for regulated workloads |

---
## Validation Steps

**Step 1 — Confirm CA object status**
Portal: **Tenant administration > Cloud PKI**. Expected: **Active**. "Signing required" (BYOCA only) or "Disabled" both explain a total absence of new issuance without representing a fault to chase further.

**Step 2 — Confirm RBAC permissions for the operator**
Custom Intune roles carry three distinct Cloud PKI permissions — **Read CAs**, **Create certificate authorities**, and **Revoke issued leaf certificates** (the last also requires Read CAs). A support engineer who can view CA status but can't revoke a compromised cert is missing the third permission, not experiencing a bug.
```powershell
# Confirm the signed-in operator's assigned Intune role includes the Cloud PKI permission set
Get-MgRoleManagementDeviceRoleAssignment -Filter "principalId eq '<ObjectId>'" | Select RoleDefinitionId
```

**Step 3 — Confirm trust chain on a representative device**
```powershell
Get-ChildItem Cert:\LocalMachine\Root | Where Subject -like "*<RootCAName>*" | Select Subject, Thumbprint, NotAfter
Get-ChildItem Cert:\LocalMachine\CA   | Where Subject -like "*<IssuingCAName>*" | Select Subject, Thumbprint, NotAfter
```
Expected: both present. For BYOCA, **every** certificate in the private hierarchy must independently be delivered via its own Trusted Certificate profile.

**Step 4 — Confirm leaf certificate delivery**
```powershell
Get-ChildItem Cert:\LocalMachine\My, Cert:\CurrentUser\My | Where Issuer -like "*<IssuingCAName>*" | Select Subject, Issuer, Thumbprint, NotAfter
```

**Step 5 — Pull MDM diagnostics (Windows) or SCEP subsystem log (macOS)**
```powershell
MdmDiagnosticsTool.exe -out "$env:TEMP\MDMDiag_$(Get-Date -Format yyyyMMdd_HHmmss)"
```
macOS:
```
log show --info --debug --predicate 'subsystem == "com.apple.SCEP"' --last 1h
```

**Step 6 — Confirm CA capacity headroom before any new-CA request**
Count existing CA objects (Root + Issuing + BYOCA) against the tenant's 3-CA cap in **Tenant administration > Cloud PKI** before troubleshooting a "can't create CA" ticket any further.

**Step 7 — Confirm CRL is actually reachable by relying parties**
```powershell
certutil -URL <LeafCertThumbprintOrFilePath>
```
Use the CRL Distribution Point tab in the resulting dialog to fetch and validate the CDP URL that Intune is hosting for that CA.

---
## Troubleshooting Steps (by phase)

### Phase 1: CA object health

1. **Tenant administration > Cloud PKI** — confirm CA status (Active / Signing required / Disabled).
2. For BYOCA in "Signing required," confirm whether the CSR has actually been downloaded and signed yet — this is often simply an incomplete setup step, not a failure.
3. Confirm CA type (Root / Issuing / BYOCA) matches what the SCEP profile expects.

### Phase 2: Trust chain delivery

1. Confirm every certificate in the chain (Root, and for BYOCA any intermediates) has its own Trusted Certificate profile.
2. Confirm all Trusted Certificate profiles and the SCEP profile share the **same assignment group**.
3. For Android specifically, confirm the Trusted Certificate profile targeting Android devices references the **Root CA cert**, not an Issuing/Intermediate cert.

### Phase 3: SCEP profile configuration

1. Confirm the SCEP profile's **Certification Authority** selector references the intended CA (a frequent error once a tenant has 2+ CAs).
2. Confirm Subject Name/SAN variables match the profile's targeting (device-targeted vs. user-targeted).
3. Confirm the profile is assigned to the correct device/user group and hasn't been scoped narrower than intended by a Scope Tag.

### Phase 4: Device-side delivery

1. Confirm device enrollment state and recent check-in.
2. Pull MDM diagnostics (Windows) or the SCEP subsystem log (macOS); cross-reference error codes against the Symptom → Cause Map.
3. Force a check-in to re-trigger profile evaluation if the device appears stalled mid-delivery.

### Phase 5: Capacity and licensing

1. Confirm the tenant hasn't hit the 3-CA cap before assuming a creation failure is a bug.
2. Confirm licensing state — Intune Suite, standalone Cloud PKI add-on, or (from July 1, 2026) bundled Microsoft 365 E5 — since a lapsed license silently blocks new CA creation and issuance without necessarily surfacing an obvious license-expired error in the CA object itself.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield native Cloud PKI onboarding</summary>

```powershell
# This is a portal-driven workflow — Cloud PKI CA creation has no PowerShell/Graph
# cmdlet equivalent as of this writing; document portal steps for repeatability.
```

1. **Tenant administration > Cloud PKI** → Create → CA Type = **Root CA**. Choose key size (2048/3072/4096) and hash algorithm.
2. Create a second CA, CA Type = **Issuing CA**, **Root CA Source = Cloud PKI Root CA**, chaining to the root created above.
3. Define specific EKUs for the Issuing CA — avoid "Any Purpose."
4. Create a Trusted Certificate profile for the Root CA cert, and a second for the Issuing CA cert.
5. Create a SCEP certificate profile referencing the Issuing CA and the correct Subject Name/SAN variables for your use case.
6. Assign all three profiles (2 Trusted Cert + 1 SCEP) to the **same** target group.
7. Validate on a single pilot device before broad assignment.

**Rollback:** disable the SCEP profile assignment; the CA itself can remain Active with no impact until reused.

</details>

<details><summary>Playbook 2 — BYOCA onboarding anchored to an existing AD CS root</summary>

1. **Tenant administration > Cloud PKI** → Create → CA Type = **Issuing CA**, Root CA Source = **Bring your own root CA**.
2. Choose RSA key size; define specific EKUs (no "Any Purpose").
3. Download the CSR (`.req`) once status shows **Signing required**.
4. Sign via Certification Authority Web Enrollment, or:
```
certreq.exe -submit -attrib "CertificateTemplate:<TemplateName>" request.req certnew.cer
```
5. Download the signed cert (`certnew.cer`) **and** the full chain (`certnew.p7b`) from your internal CA.
6. Upload both files to the Cloud PKI CA object — status flips to **Active**.
7. Create a Trusted Certificate profile for **every** cert in the chain (root + any intermediates) — a single profile covering only the new Issuing CA is insufficient.
8. Create the SCEP profile referencing this Issuing CA's SCEP URI.
9. Assign all Trusted Certificate profiles + the SCEP profile to the same group; pilot before broad rollout.

**Rollback:** the private root/internal CA is unaffected by any Cloud PKI-side failure — worst case is disabling the BYOCA issuing CA object and falling back to the prior on-prem NDES/PKCS flow if one still exists in parallel.

</details>

<details><summary>Playbook 3 — Recovering from the 3-CA capacity cap</summary>

1. Inventory existing CA objects: **Tenant administration > Cloud PKI**.
2. Identify any CA with zero active assignments or fully expired issued certificates — a safe removal candidate.
3. Before deleting, confirm via **Devices > Monitor > Certificates** that no device holds a still-valid certificate issued by that CA.
4. Disable, then delete the unused CA to free a capacity slot.
5. If consolidation (not deletion) is the goal, re-architect toward one Root CA feeding multiple Issuing CAs rather than multiple independent Root+Issuing pairs.

**Rollback:** deleting a CA is destructive for revocation-checking of any certs it issued — confirm zero dependency first; there is no soft-delete/undo documented for Cloud PKI CA objects.

</details>

<details><summary>Playbook 4 — Fleet-wide certificate health check ahead of a compliance audit</summary>

Run `Get-CloudPKIHealth.ps1` (see Scripts/) tenant-wide via Graph to produce an inventory of every CA, its status, capacity utilization against the 3-CA cap, and any Issuing CA nearing CRL/AIA-relevant expiry — before an auditor asks for it rather than during.

**Rollback:** N/A — read-only.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Cloud PKI evidence for escalation to Microsoft support
.NOTES     Run on the affected device as local admin/SYSTEM. Output saved to Desktop.
#>

$output = [System.Collections.Generic.List[string]]::new()
$ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC" -AsUTC
$out    = "$env:USERPROFILE\Desktop\CloudPKIEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"

function Add-Section {
    param([string]$Title, [scriptblock]$Body)
    $output.Add("=" * 60)
    $output.Add("  $Title")
    $output.Add("=" * 60)
    try { $output.Add((&$Body | Out-String).Trim()) }
    catch { $output.Add("ERROR: $($_.Exception.Message)") }
    $output.Add("")
}

Add-Section "Collection metadata" {
    "Collected : $ts"
    "Device    : $env:COMPUTERNAME"
    "User      : $env:USERNAME"
}

Add-Section "Trusted root CA certs" {
    Get-ChildItem Cert:\LocalMachine\Root | Select-Object Subject, Thumbprint, NotAfter | Format-Table -AutoSize | Out-String
}

Add-Section "Intermediate/Issuing CA certs" {
    Get-ChildItem Cert:\LocalMachine\CA | Select-Object Subject, Issuer, Thumbprint, NotAfter | Format-Table -AutoSize | Out-String
}

Add-Section "Leaf certificates (device store)" {
    Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, Issuer, Thumbprint, NotBefore, NotAfter | Format-Table -AutoSize | Out-String
}

Add-Section "Leaf certificates (current user store)" {
    Get-ChildItem Cert:\CurrentUser\My | Select-Object Subject, Issuer, Thumbprint, NotBefore, NotAfter | Format-Table -AutoSize | Out-String
}

Add-Section "MDM diagnostic — recent SCEP/Certificate events" {
    Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match "SCEP|Certificate|Cert" } | Select-Object -First 50 |
        Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List | Out-String
}

$output | Set-Content -Path $out -Encoding UTF8
Write-Host "Evidence saved to: $out" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List device root certs | `Get-ChildItem Cert:\LocalMachine\Root \| Format-Table Subject, Thumbprint, NotAfter` |
| List device intermediate/issuing certs | `Get-ChildItem Cert:\LocalMachine\CA \| Format-Table Subject, Issuer, NotAfter` |
| List device leaf certs | `Get-ChildItem Cert:\LocalMachine\My \| Format-Table Subject, Issuer, NotAfter` |
| List user leaf certs | `Get-ChildItem Cert:\CurrentUser\My \| Format-Table Subject, Issuer, NotAfter` |
| Force Intune check-in | `Invoke-CimMethod -Namespace root/cimv2/mdm/dmmap -Class MDM_DMClient -Method TriggerDMSession -Arguments @{ProviderID='MS DM Server'}` |
| Export MDM diagnostics | `MdmDiagnosticsTool.exe -out C:\Temp\MDMDiag` |
| View MDM event log | `Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 100` |
| macOS SCEP subsystem log | `log show --info --debug --predicate 'subsystem == "com.apple.SCEP"' --last 1h` |
| macOS installed cert check | `security find-certificate -a` |
| Check CDP URL for a cert | `certutil -URL <path-to-cert-or-thumbprint>` |
| Sign a BYOCA CSR via certreq | `certreq.exe -submit -attrib "CertificateTemplate:<Name>" request.req certnew.cer` |
| Confirm role assignment (Graph) | `Get-MgRoleManagementDeviceRoleAssignment -Filter "principalId eq '<ObjectId>'"` |
| View all issued certs (fleet, workaround) | Portal: **Devices > Monitor > Certificates** (not the CA's own "View all certificates," which caps at 1,000) |

---
## 🎓 Learning Pointers

- **Cloud PKI is not "on-prem PKI with a cloud UI" — it removes the on-prem tier entirely.** No NDES, no IIS, no Intune Certificate Connector to patch or monitor. The trade-off is a hard 3-CA-per-tenant cap and no current data-residency option — both are real architectural constraints to weigh before recommending Cloud PKI over the existing NDES/PKCS model for a client with strict data-sovereignty requirements. [Overview of Microsoft Cloud PKI](https://learn.microsoft.com/en-us/intune/cloud-pki/)

- **BYOCA's "Signing required" state is the single most common false alarm** in a fresh Cloud PKI deployment — every BYOCA CA passes through it and it can sit there indefinitely until someone completes the manual CSR-sign-upload loop. Build this step into onboarding runbooks explicitly rather than leaving it as a portal quirk to be discovered. [Bring your own CA with Cloud PKI](https://learn.microsoft.com/en-us/intune/cloud-pki/configure-byoca)

- **Trial CAs permanently lock in software-backed keys.** If a client's compliance posture requires HSM-backed keys, do not build "test" CAs during an Intune Suite trial expecting to upgrade them later — build the licensed CA from day one. [Try Microsoft Cloud PKI](https://learn.microsoft.com/en-us/intune/cloud-pki/)

- **Android's SCEP client is stricter than Windows/iOS about which certificate belongs in the trust profile** — it wants the Root CA cert specifically, not an Intermediate/Issuing CA cert. A Trusted Certificate profile built and tested against Windows can silently fail Android with no obvious error pointing at "wrong cert type." [Cloud PKI SCEP troubleshooting discussion](https://techcommunity.microsoft.com/discussions/microsoft-intune/cloud-pki-scep/4406137)

- **July 1, 2026 folds Cloud PKI into Microsoft 365 E5** alongside Security Copilot, Endpoint Privilege Management, and Enterprise Application Management — a client already on E5 may suddenly have Cloud PKI available with zero purchasing action on their part. Worth proactively checking E5 tenants for this rather than waiting for a client to ask "do we have this now?" [What changes in Microsoft 365 E5 on July 1, 2026](https://sourcepassmcoe.com/articles/what-is-changing-in-microsoft-365-e5-on-july-1-2026-sourcepass-mcoe)

- **RBAC for Cloud PKI is three separate permissions, not one "PKI admin" toggle** — Read CAs, Create certificate authorities, and Revoke issued leaf certificates are independently assignable. A help-desk tier that can view CA health but can't revoke a compromised certificate is a deliberate design, not a misconfiguration — confirm which permission tier an escalating engineer actually holds before assuming a bug. [RBAC permissions for Cloud PKI](https://learn.microsoft.com/en-us/intune/cloud-pki/)
