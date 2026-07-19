# Intune Cloud PKI — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

Cloud PKI is Microsoft's fully cloud-hosted PKI for Intune — **no NDES, no on-premises Certificate Connector, no on-premises CA required** for a native (non-BYOCA) deployment. If you catch yourself looking for an NDES server or a `NDESConnectorSvc` service for a Cloud PKI issue, stop — that's the separate on-prem SCEP/PKCS topic (`Certificates-B.md`), not this one.

```powershell
# 1. Confirm the device actually has the Cloud PKI trusted-root chain delivered
Get-ChildItem Cert:\LocalMachine\Root | Where-Object Issuer -like "*<YourCloudPKIRootName>*" | Select Subject, Thumbprint, NotAfter

# 2. Confirm the leaf certificate landed (device store) or check user store for user-targeted profiles
Get-ChildItem Cert:\LocalMachine\My, Cert:\CurrentUser\My | Where-Object Issuer -like "*<YourCloudPKIIssuingCAName>*" | Select Subject, Issuer, Thumbprint, NotAfter

# 3. Windows MDM diagnostic log — search for SCEP/Cert errors
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 100 |
    Where-Object Message -match "SCEP|Certificate" | Select TimeCreated, Id, Message | Format-List

# 4. macOS equivalent (run in Terminal on the Mac)
# log show --info --debug --predicate 'subsystem == "com.apple.SCEP"' --last 1h

# 5. In the Intune admin center: Tenant administration > Cloud PKI > select the CA > check its status
```

| If... | Then... |
|---|---|
| CA status shows **"Signing required"** | This is a **BYOCA-only, expected pending state** — not a failure. The CSR hasn't been signed by your internal CA yet. See Fix 1. |
| CA status shows **"Active"** but leaf certs never appear on any device | Check the SCEP certificate profile's assignment and confirm the Trusted Certificate profile for the Root **and** Issuing CA is assigned to the **same group**, in the **same order**. See Fix 2. |
| Root cert present, leaf cert missing on **one** device only | Device-specific — check profile assignment status for that device and MDM diagnostic log. See Fix 3. |
| Error thumbprint/CA mismatch on device | The CA selected in the SCEP profile doesn't match the CA that actually issued/would issue the cert (common after creating a second issuing CA). See Fix 4. |
| Android-specific SCEP failure, works fine on Windows | Android requires the **Root CA certificate**, not the Intermediate/Issuing CA cert, in the SCEP profile's trusted-root reference. See Fix 5. |
| macOS error `Error Domain=MDM-SCEP Code=15001` | Device could not validate the issuing CA — the Trusted Certificate profile for that CA hasn't landed, or references the wrong CA. See Fix 2. |
| "3 CA" limit reached, can't create a new CA | Hard tenant cap — 3 CA objects total (Root + Issuing + BYOCA all count). See Fix 6. |
| Certificates issued fine, but Intune admin center "View all certificates" seems to be missing entries past ~1,000 | Known UI limitation, not a data-loss issue — use **Devices > Monitor > Certificates** for the full list. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Cloud PKI Root CA]  (self-signed, or none if pure BYOCA anchored externally)
        |
        ▼
[Cloud PKI Issuing CA]  (native cloud-signed  OR  BYOCA anchored to your private CA)
        |  (BYOCA only: CSR downloaded → signed by your internal CA → cert + chain uploaded back)
        ▼
[Trusted Certificate profile — Root CA cert]  ──┐
[Trusted Certificate profile — Issuing/Intermediate CA cert] ──┤  same assignment group, delivered first
        |                                                       │
        ▼                                                       │
[SCEP Certificate profile]  (references Cloud PKI SCEP URI) ────┘
        |
        ▼
[Device checks in → receives trust + SCEP profiles]
        |
        ▼
[Device generates CSR locally — private key never leaves device]
        |
        ▼
[Cloud PKI SCEP service validates challenge] → [SCEP validation service] → [Issuing CA signs]
        |
        ▼
[Signed leaf certificate delivered to device cert store]
```

Nothing here touches an on-prem server. If any step is being diagnosed with NDES logs, IIS logs, or an on-prem Certificate Connector, you are troubleshooting the wrong topic — hand off to `Certificates-B.md`.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm CA object health in the admin center**
Portal: **Tenant administration > Cloud PKI** → select the CA.
Expected: Status = **Active**. If **Signing required**, the CA is a BYOCA pending your internal CA's signature — not broken, just incomplete (Fix 1).

**Step 2 — Confirm trust chain delivered to device**
```powershell
Get-ChildItem Cert:\LocalMachine\Root  | Where Subject -like "*<RootCAName>*" | Select Subject, Thumbprint, NotAfter
Get-ChildItem Cert:\LocalMachine\CA    | Where Subject -like "*<IssuingCAName>*" | Select Subject, Thumbprint, NotAfter
```
Expected: both present with a future `NotAfter`. Absent = Trusted Certificate profile hasn't delivered — this is silent, no user-visible error.

**Step 3 — Confirm leaf certificate presence**
```powershell
Get-ChildItem Cert:\LocalMachine\My, Cert:\CurrentUser\My | Where Issuer -like "*<IssuingCAName>*" | Select Subject, Issuer, Thumbprint, NotAfter
```
Expected: certificate with subject matching the SCEP profile's configured subject name.

**Step 4 — Pull the Windows MDM diagnostic log**
```powershell
$diagPath = "$env:TEMP\MDMDiag_$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Path $diagPath -Force | Out-Null
MdmDiagnosticsTool.exe -out $diagPath
```
Search `MDMDiagReport.xml` for `SCEP` or the CA name. Cloud PKI failures surface through the same MDM diagnostic channel as on-prem SCEP — the difference is entirely on the backend, not the client-side log format.

**Step 5 — Confirm profile assignment order (Windows/macOS/iOS/Android)**
Portal: **Devices > Configuration profiles** → Trusted Certificate profile(s) and SCEP profile → **Assignments** tab. Both must target the **same group**. If the Trusted Certificate profile for the Issuing CA is missing from the assignment, the device will reject the leaf cert as untrusted even though issuance succeeded server-side.

**Step 6 — Cross-check CA identity in the SCEP profile**
Portal: **Devices > Configuration profiles** → the SCEP profile → confirm the **Certification Authority** field points at the intended Issuing CA (easy to pick the wrong one once a tenant has 2+ CAs).

---
## Common Fix Paths

<details><summary>Fix 1 — BYOCA stuck in "Signing required"</summary>

**This is expected, not a bug**, for every BYOCA issuing CA until you complete the manual signing loop:

1. In **Tenant administration > Cloud PKI**, open the CA and download the CSR (`.req` file).
2. Sign it with your internal CA:
   - Certification Authority Web Enrollment (simplest — submit the `.req` as a request, select the correct template, retrieve `certnew.cer` and `certnew.p7b`), **or**
   - `certreq.exe -submit -attrib "CertificateTemplate:<TemplateName>" request.req certnew.cer`
3. Back in the Cloud PKI CA properties, upload **both** the signed certificate (`certnew.cer`) and the full chain (`certnew.p7b`) — Intune requires both files.
4. Status flips to **Active** once both are accepted.
5. Create a Trusted Certificate profile for **every** certificate in the private CA hierarchy (root + any intermediates) — not just the new issuing CA — and assign it to the same group as the SCEP profile.

**Rollback:** none needed — this is a one-time setup step, not a destructive change.

</details>

<details><summary>Fix 2 — Trusted Certificate profile not assigned to matching group</summary>

```powershell
# Verify on the device whether the trust chain actually landed
$root = Get-ChildItem Cert:\LocalMachine\Root | Where Thumbprint -eq "<RootThumbprint>"
$int  = Get-ChildItem Cert:\LocalMachine\CA   | Where Thumbprint -eq "<IssuingCAThumbprint>"
if (-not $root) { Write-Host "Root CA missing — check Trusted Cert profile assignment" -ForegroundColor Red }
if (-not $int)  { Write-Host "Issuing CA missing — check Trusted Cert profile assignment" -ForegroundColor Red }
```

Fix: in the portal, open both Trusted Certificate profiles (Root, Issuing) and the SCEP profile — assign all three to the **identical** group. Force a sync:
```powershell
$session = New-CimSession
Invoke-CimMethod -Namespace root/cimv2/mdm/dmmap -ClassName MDM_DMClient -MethodName TriggerDMSession -Arguments @{ ProviderID = "MS DM Server" } -CimSession $session
```

**Rollback:** N/A — assignment correction is additive.

</details>

<details><summary>Fix 3 — Single device not getting the leaf certificate</summary>

1. Portal: **Devices > [device] > Device configuration** — confirm both Trusted Certificate profiles and the SCEP profile show **Succeeded**.
2. If **Pending**, force a check-in (`TriggerDMSession`, see Fix 2) and wait 10 minutes.
3. If **Error**, pull the MDM diagnostic log (Diagnosis Step 4) and match the error code.
4. Remove near-expired duplicate certs before forcing re-enrollment:
```powershell
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Issuer -like "*<IssuingCAName>*" -and $_.NotAfter -lt (Get-Date).AddDays(30) } |
    ForEach-Object { Write-Host "Stale cert: $($_.Subject) [$($_.Thumbprint)]" -ForegroundColor Yellow }
    # Remove-Item "Cert:\LocalMachine\My\$($_.Thumbprint)" -Force   # uncomment to actually remove
```

**Rollback:** if a device loses an auth-critical cert (Wi-Fi/VPN), re-enroll immediately or use a wired/known-good path to restore access.

</details>

<details><summary>Fix 4 — CA/thumbprint mismatch in SCEP profile</summary>

Symptom: certificate request rejected referencing a CA thumbprint that doesn't match what's configured. Almost always means the SCEP profile's **Certification Authority** field points at the wrong CA (common once a tenant has more than one Issuing CA).

Fix: in the portal, open the SCEP profile → confirm the **Certification Authority** selector matches the Issuing CA you intend, not a leftover from an earlier test CA. Re-save and re-sync.

**Rollback:** N/A.

</details>

<details><summary>Fix 5 — Android SCEP failure only</summary>

Android's SCEP implementation expects the **Root CA certificate** in the trusted-root reference — not the Intermediate/Issuing CA certificate that a two-tier hierarchy might lead you to select. Windows and iOS tolerate either; Android does not.

Fix: in the Trusted Certificate profile targeting Android, confirm the uploaded certificate is the actual Root CA cert, not the Issuing CA cert. Create a second, Android-scoped Trusted Certificate profile if the existing one was built for Windows/iOS with the Issuing CA cert.

**Rollback:** N/A — corrective re-scoping.

</details>

<details><summary>Fix 6 — Tenant CA capacity (3-CA hard limit) reached</summary>

Root CA, Issuing CA, and BYOCA issuing CA objects **all count toward the same 3-CA cap** per tenant (licensed or trial). There is no increase available.

Options:
- Retire an unused CA (disable, then delete once all certs it issued have expired or been reissued elsewhere).
- Consolidate: use a single Root CA with two Issuing CAs rather than separate Root+Issuing pairs per use case.
- If BYOCA is the goal, you may not need a Cloud PKI Root CA at all — anchor an Issuing CA directly to your existing private root.

**Rollback:** deleting a CA is destructive to any certs still relying on it for revocation checks — confirm no active devices depend on it first.

</details>

---
## Escalation Evidence

```
Ticket: Intune Cloud PKI certificate issue
─────────────────────────────────────────
Device name:              <____________________>
Platform (Win/iOS/macOS/Android): <____________>
Cloud PKI CA name + type (Root/Issuing/BYOCA):  <____________________>
CA status in admin center (Active/Signing required/Disabled): <_______>
SCEP profile name:        <____________________>
Trusted Cert profile(s) assigned to same group?  Y / N
Root CA cert present on device? (Get-ChildItem Cert:\LocalMachine\Root)  Y / N
Issuing CA cert present on device? (Cert:\LocalMachine\CA)               Y / N
Leaf cert present? (Cert:\LocalMachine\My or CurrentUser\My)             Y / N
MDM diagnostic log error code (if any): <____________________>
Time of last successful device check-in: <____________________>
Number of CAs currently in tenant (of 3 max): <__> / 3
```

---
## 🎓 Learning Pointers

- **Cloud PKI is architecturally the opposite model from `Certificates-B.md`.** There's no NDES, no on-prem Certificate Connector, no Enterprise CA to keep patched. The entire registration authority (SCEP service + SCEP validation service) is Microsoft-hosted. If a fix path involves an on-prem server, you're troubleshooting the wrong topic. [Overview of Microsoft Cloud PKI](https://learn.microsoft.com/en-us/intune/cloud-pki/)

- **"Signing required" is a normal BYOCA state, not a stuck deployment.** Every BYOCA issuing CA starts here and needs a manual CSR-sign-upload loop through your existing internal CA before it goes Active. Don't burn triage time treating this as a fault. [Bring your own CA with Cloud PKI](https://learn.microsoft.com/en-us/intune/cloud-pki/configure-byoca)

- **The 3-CA-per-tenant cap is hard and shared across Root, Issuing, and BYOCA objects alike.** Plan hierarchy (one root, multiple issuing CAs) rather than assuming you can always spin up a fresh CA per project or per test. [Known issues and limitations](https://learn.microsoft.com/en-us/intune/cloud-pki/)

- **Trial CAs use software-backed keys and can never convert to HSM-backed keys**, even after purchasing a license — if HSM backing matters for your compliance posture, don't build production CAs during a trial. [Try Microsoft Cloud PKI](https://learn.microsoft.com/en-us/intune/cloud-pki/)

- **Starting July 1, 2026, Cloud PKI is bundled into Microsoft 365 E5** (previously a separate Intune Suite add-on or standalone purchase) — a tenant may show Cloud PKI as available/enabled with no separate licensing action taken, which can surprise an MSP still tracking it as a paid add-on in their billing model. [Microsoft 365 E5 changes July 2026](https://sourcepassmcoe.com/articles/what-is-changing-in-microsoft-365-e5-on-july-1-2026-sourcepass-mcoe)

- **The "View all certificates" admin center UI caps at 1,000 entries per CA** — this is a known, documented limitation, not a data gap. For the full picture, use **Devices > Monitor > Certificates** instead. [Known issues and limitations](https://learn.microsoft.com/en-us/intune/cloud-pki/)
