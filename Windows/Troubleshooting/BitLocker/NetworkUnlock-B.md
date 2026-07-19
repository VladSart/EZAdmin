# BitLocker Network Unlock — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes.
> **Environment:** Windows 10/11 · Domain-joined (AD DS) · UEFI native mode · TPM+PIN protector · On-prem WDS server role

---

## Skim Index

- [Triage (60 seconds)](#triage-60-seconds)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Triage (60 seconds)

```powershell
# 1) Confirm the Network Unlock (certificate-based) protector actually exists on the client
manage-bde -protectors -get C:
# Look for: "Network Key Protector" / a protector of type "TpmCertificate (9)"
# No such protector = client was never configured for Network Unlock — that's the root cause, not a runtime failure

# 2) Confirm the FVE_NKP certificate is present and current on the client
Get-ChildItem -Path "HKLM:\Software\Policies\Microsoft\SystemCertificates\FVE_NKP\Certificates" -ErrorAction SilentlyContinue
# Empty/missing = GPO hasn't delivered the Network Unlock certificate to this device yet (requires reboot after GPO push)

# 3) Confirm the client is on a wired connection, not Wi-Fi (Network Unlock requires wired + UEFI DHCP)
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object Name, InterfaceDescription, MediaType

# 4) On the WDS/Network Unlock server — confirm the role + feature are actually running
Get-WindowsFeature WDS-Deployment, BitLocker-NetworkUnlock | Select-Object Name, InstallState
Get-Service WDSServer | Select-Object Status, StartType

# 5) Confirm Group Policy delivered the "Allow Network Unlock at startup" setting
gpresult /h C:\Temp\gpresult.html /f
# Open, search "Network Unlock" — confirm it's Enabled and which GPO is the winning one
```

**If X → Do Y**

| What you see | Likely cause | Jump to |
|---|---|---|
| No `TpmCertificate` protector on client after reboot | Cert/GPO never reached client, or client never rebooted post-policy | [Fix 1](#fix-1--network-certificate-based-protector-never-created) |
| Protector exists, still prompts for PIN every boot | Server-side provider unavailable, or client not on wired/UEFI-DHCP path | [Fix 2](#fix-2--protector-exists-but-pin-prompt-still-appears) |
| Works for most devices, fails for one model (e.g. Surface) | UEFI network stack quirk on that hardware | [Fix 3](#fix-3--hardware-specific-uefi-network-stack-failure) |
| Was working, now fails tenant/site-wide since a cert rotation | Stale or duplicate Network Unlock certificate on WDS server | [Fix 4](#fix-4--certificate-rotationexpiry-broke-unlock-site-wide) |
| Works on some subnets, not others | Subnet policy config file (`bde-network-unlock.ini`) restricting client's subnet | [Fix 5](#fix-5--subnet-policy-restriction-blocking-client) |
| WDS role fine, still fails | DHCP server not relaying the vendor-specific BOOTP-adjacent request correctly | [Fix 6](#fix-6--dhcp-bootp-interaction-blocking-the-handshake) |

---

## Dependency Cascade

<details>
<summary><strong>What must be true for Network Unlock to bypass the PIN prompt at boot</strong></summary>

```
[1] Client is domain-joined, UEFI native mode (no CSM/Legacy), firmware ≥ 2.3.1
         ↓ required for
[2] Client has a working DHCP driver in UEFI + first NIC configured for DHCP
         ↓ required for
[3] Client already has BitLocker TPM+PIN enabled (Network Unlock is an ADDITIONAL protector, not a replacement)
         ↓ combined with
[4] GPO "Allow Network Unlock at startup" delivered + rebooted → FVE_NKP cert present on client
         ↓ produces
[5] "Network (Certificate Based)" key protector created on the client's OS volume
         ↓ at boot, client
[6] Broadcasts vendor-specific DHCP request containing network key, encrypted with server's RSA public key
         ↓ requires wired path to
[7] Separate DHCP server (not WDS itself) on the same broadcast domain, correctly issuing an IP
         ↓ requires
[8] WDS server role running, BitLocker-NetworkUnlock feature installed, Nkpprov.dll plugin active
         ↓ requires
[9] Server holds the matching RSA private key for the cert the client was given
         ↓ optional gate
[10] bde-network-unlock.ini subnet policy (if present) permits this client's subnet for this cert
         ↓ success =
[11] Server decrypts, returns network key encrypted with session key → client combines with TPM-held key → volume unlocks, no PIN shown
```

**Break at any layer and BitLocker silently falls back to the standard `TPM+PIN` prompt** — there is no error dialog telling the user or the engineer which layer failed. That's why triage is entirely log/registry driven, not UI driven.

- Network Unlock is a *key protector add-on*, not a BitLocker mode. A device with no PIN protector configured cannot use Network Unlock — there's nothing for it to bypass.
- The WDS role does not need to be configured for actual OS deployment/PXE to support Network Unlock — it only needs the role installed and running as a host for the `Nkpprov.dll` provider plugin.

</details>

---

## Diagnosis & Validation Flow

Work top-to-bottom. Stop when you find the break.

**Step 1 — Confirm the client has TPM+PIN as a baseline (prerequisite, not Network Unlock itself)**
```powershell
(Get-BitLockerVolume -MountPoint C:).KeyProtector | Select-Object KeyProtectorType
# Must show TpmPin (or Tpm alone won't work — Network Unlock requires the PIN protector to exist)
```
No `TpmPin` protector present → this device was never enrolled in PIN-based BitLocker. Network Unlock cannot apply until that's fixed first — this is a BitLocker enrollment issue, not a Network Unlock issue. See `Windows/Troubleshooting/BitLocker/BitLocker-B.md`.

**Step 2 — Confirm the client-side certificate is present**
```powershell
Get-ChildItem "HKLM:\Software\Policies\Microsoft\SystemCertificates\FVE_NKP\Certificates"
```
Empty → GPO hasn't delivered the cert, or the client hasn't rebooted since the GPO was linked. The "Network (Certificate Based)" protector is **only added after a reboot** — this is the single most common false alarm in this runbook.

**Step 3 — Confirm the protector actually got created**
```powershell
manage-bde -protectors -get C:
```
Look for a protector type `TpmCertificate (9)`. If step 2 shows a cert but this step shows no protector, the client needs one more reboot cycle — the cert delivery and protector creation are not always same-boot.

**Step 4 — Confirm firmware mode (native UEFI, not CSM/Legacy)**
```powershell
Confirm-SecureBootUEFI
# True = native UEFI. An error or False here usually means Legacy/CSM boot — Network Unlock cannot work at all in this mode.
```

**Step 5 — Confirm wired connectivity at the OS level (sanity check — the real test happens pre-boot in UEFI, which PowerShell cannot see)**
```powershell
Get-NetAdapter | Select-Object Name, MediaType, Status
```
Wi-Fi-only device, or the onboard/first-enumerated adapter is disabled or non-DHCP (e.g., reserved for iLO/iDRAC-style management) → Network Unlock will fail because it stops enumerating at the first adapter with a DHCP failure. Docking-station Ethernet adapters can also break this if they aren't the first enumerated NIC.

**Step 6 — Confirm server-side role health**
```powershell
Get-WindowsFeature WDS-Deployment, BitLocker-NetworkUnlock
Get-Service WDSServer
```
Both features `Installed`, service `Running`. If `BitLocker-NetworkUnlock` shows `Available` (not installed), the provider plugin (`Nkpprov.dll`) was never registered — clients will always fall back to PIN.

**Step 7 — Confirm which Network Unlock certificate is currently deployed and its expiry**
```powershell
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.EnhancedKeyUsageList -match "1.3.6.1.4.1.311.67.1.1" } |
  Select-Object Thumbprint, NotAfter, Subject
```
Run on the WDS server. Compare `NotAfter` against today — an expired cert is a common silent site-wide failure after a long period of "it just worked."

**Step 8 — Check WDS diagnostic log for the actual decrypt attempt (requires enabling debug logging first)**
```powershell
wevtutil.exe sl Microsoft-Windows-Deployment-Services-Diagnostics/Debug /e:true
# Reproduce a failed unlock, then:
Get-WinEvent -LogName "Microsoft-Windows-Deployment-Services-Diagnostics/Debug" -MaxEvents 50 |
  Where-Object { $_.Message -match "NetworkUnlock|Nkp" } | Select-Object TimeCreated, Message
```

---

## Common Fix Paths

<details>
<summary><strong>Fix 1 — Network (certificate-based) protector never created</strong></summary>

**Confirms:** No `TpmCertificate (9)` protector in `manage-bde -protectors -get C:`, and/or `FVE_NKP\Certificates` registry key is empty.

```powershell
# 1. Confirm the GPO is actually linked and reaching this device
gpresult /h C:\Temp\gpresult.html /f
# Search for "BitLocker Drive Encryption Network Unlock Certificate" and "Allow Network Unlock at startup"

# 2. Force a GPO refresh
gpupdate /force

# 3. Reboot — the protector is only added on next boot after the cert + policy are both present
Restart-Computer

# 4. After reboot, re-check
manage-bde -protectors -get C:
Get-ChildItem "HKLM:\Software\Policies\Microsoft\SystemCertificates\FVE_NKP\Certificates"
```

**If still empty after a confirmed GPO refresh + reboot:** the `.cer` file was likely never correctly imported into the domain controller's Public Key Policies node. Re-verify on a DC:
`gpmc.msc → [GPO] → Computer Configuration → Policies → Windows Settings → Security Settings → Public Key Policies → BitLocker Drive Encryption Network Unlock Certificate` — should show exactly one certificate.

</details>

<details>
<summary><strong>Fix 2 — Protector exists but PIN prompt still appears</strong></summary>

**Confirms:** `TpmCertificate` protector present on client, cert present, but device still prompts for PIN at every boot.

```powershell
# On the WDS server — confirm the service and provider are actually live
Get-Service WDSServer | Select-Object Status
# If Stopped:
Start-Service WDSServer

# Confirm the BitLocker-NetworkUnlock optional feature is installed (not just WDS itself)
Get-WindowsFeature BitLocker-NetworkUnlock
# If not Installed:
Install-WindowsFeature BitLocker-NetworkUnlock
```

If the server side is healthy, the fallback is almost always the client's boot-time network path — confirm the device is plugged into a wired port on the correct broadcast domain (not behind a switch port with DHCP snooping/802.1X blocking pre-authentication traffic), and that it is not being docked to a Wi-Fi-only path during boot.

**Rollback / safe state:** there's no destructive change here — worst case is the device keeps prompting for PIN, which is the existing safe fallback behavior by design.

</details>

<details>
<summary><strong>Fix 3 — Hardware-specific UEFI network stack failure (e.g. Surface Pro/Book)</strong></summary>

**Confirms:** Infrastructure confirmed working for other device models on the same network/GPO, but one specific hardware line consistently fails.

Some devices (documented case: Surface Pro 4) have a UEFI network stack that isn't correctly initialized for Network Unlock even with DHCP "enabled" in firmware settings.

```text
# Surface-family devices specifically:
1. Use Microsoft Surface Enterprise Management Mode (SEMM) to properly configure the UEFI network stack for that model
2. If SEMM isn't available/desired, try setting the network adapter as the FIRST boot option in UEFI firmware settings (not just "enabled") — this has resolved the issue in some cases without SEMM
```

For other affected hardware: check OEM firmware release notes for "UEFI DHCP" or "PXE stack" fixes — this is a firmware-level limitation, not something fixable from Windows or Group Policy.

</details>

<details>
<summary><strong>Fix 4 — Certificate rotation/expiry broke unlock site-wide</strong></summary>

**Confirms:** Was working broadly, now fails for most/all devices around the same time; server-side cert `NotAfter` has passed or is close.

```powershell
# On the WDS server, generate a new self-signed cert (or re-enroll from CA if using a PKI)
New-SelfSignedCertificate -CertStoreLocation Cert:\LocalMachine\My `
  -Subject "CN=BitLocker Network Unlock certificate" `
  -Provider "Microsoft Software Key Storage Provider" `
  -KeyUsage KeyEncipherment -KeyUsageProperty Decrypt,Sign -KeyLength 2048 -HashAlgorithm sha512 `
  -TextExtension @("1.3.6.1.4.1.311.21.10={text}OID=1.3.6.1.4.1.311.67.1.1","2.5.29.37={text}1.3.6.1.4.1.311.67.1.1")

# Export the public .cer (no private key) for GPO deployment, and .pfx (with private key) for the WDS server import
# Import the new cert into the WDS server's local machine store under "BitLocker Drive Encryption Network Unlock"
```

**Then, on a domain controller:**
1. Delete the existing (expired) certificate from **Public Key Policies → BitLocker Drive Encryption Network Unlock Certificate** — only one certificate can be active at a time.
2. Add the new `.cer`.
3. `gpupdate /force` + reboot affected clients so they pick up the new cert and regenerate their protector.

**Rollback note:** deleting the old certificate is a one-way action for any device that hasn't yet received the new one — those devices simply fall back to PIN prompt until they pick up the replacement (no data loss, no lockout risk).

</details>

<details>
<summary><strong>Fix 5 — Subnet policy restriction blocking client</strong></summary>

**Confirms:** Works from some locations/subnets, fails from others, and a `bde-network-unlock.ini` file exists on the WDS server (`%windir%\System32\bde-network-unlock.ini`, same directory as `Nkpprov.dll`).

```powershell
# On the WDS server, review the subnet policy file
Get-Content "$env:windir\System32\bde-network-unlock.ini"
```

- If the failing client's subnet is not listed under the `[SUBNETS]` section, or is commented out (`;`) under the certificate's thumbprint section, it will always fail from that location by design.
- Add the missing subnet as a name=CIDR pair under `[SUBNETS]`, then reference it under the correct certificate-thumbprint section (thumbprint with **no spaces**).
- A malformed file causes the provider to fail entirely for **all** clients, not just one subnet — if the whole server suddenly stopped responding, check this file for corruption first.

</details>

<details>
<summary><strong>Fix 6 — DHCP/BOOTP interaction blocking the handshake</strong></summary>

**Confirms:** Older client OS (Windows 8/Server 2012-era, or a DHCP server explicitly configured for BOOTP compatibility) failing intermittently; infrastructure otherwise looks correct.

The third message in the Network Unlock handshake doesn't carry the standard DHCP Message Type option, so a DHCP server configured to also serve BOOTP clients can misinterpret it as a BOOTP request and respond incorrectly.

```text
On the DHCP server scope options:
Change the option from "DHCP and BOOTP" to "DHCP" only (if BOOTP support isn't otherwise required on that scope)
```

This is a legacy-hardware-era issue — on current Windows 10/11 clients it's rare, but still worth ruling out if the DHCP server was configured years ago for PXE/BOOTP-based imaging alongside Network Unlock.

</details>

---

## Escalation Evidence

Copy/paste into ticket before escalating:

```text
BITLOCKER NETWORK UNLOCK ESCALATION EVIDENCE
=============================================
Date/Time        : <timestamp>
Client Device    : <hostname>
Client OS        : <winver>
WDS/Server Name  : <hostname>

--- CLIENT STATE ---
TpmPin protector present   : <Yes/No — from Get-BitLockerVolume KeyProtector>
FVE_NKP certificate present: <Yes/No>
TpmCertificate protector present (manage-bde): <Yes/No>
Secure Boot / native UEFI confirmed: <Yes/No — Confirm-SecureBootUEFI>
Wired adapter, first-enumerated, DHCP-capable: <Yes/No>

--- SERVER STATE ---
WDS-Deployment feature   : <Installed/Not Installed>
BitLocker-NetworkUnlock feature: <Installed/Not Installed>
WDSServer service status : <Running/Stopped>
Network Unlock cert thumbprint : <thumbprint>
Cert NotAfter (expiry)   : <date>

--- POLICY ---
GPO "Allow Network Unlock at startup": <Enabled/Not Found — GPO name>
Subnet policy file present (bde-network-unlock.ini): <Yes/No>
Client's subnet explicitly permitted (if file present): <Yes/No/N-A>

--- SYMPTOM ---
Scope of failure: <single device / hardware model / subnet / site-wide>
Since when      : <date first noticed>

--- FIXES ATTEMPTED ---
<list what was tried and result>
```

---

## 🎓 Learning Pointers

- **Network Unlock is an additive protector, not a replacement mode** — the device still needs `TPM+PIN` configured as its baseline. Network Unlock's whole job is to let the boot process skip *displaying* the PIN prompt when a trusted network path is available; the PIN protector itself never goes away, and it's still needed the moment the device boots off-network. Read: [Network Unlock — Microsoft Learn](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/network-unlock)

- **The "Network (Certificate Based)" protector is reboot-gated, not policy-gated** — GPO delivering the certificate is necessary but not sufficient; the protector itself is only created on the *next boot* after both the policy and the certificate are present together. Don't chase a "policy applied but nothing happening" ticket without confirming a reboot happened after the GPO link, not just a `gpupdate /force`.

- **UEFI network enumeration stops at the first failure** — Network Unlock only tries the first-enumerated NIC's DHCP path; it does not fail over to a second adapter. On docking-station or multi-NIC devices (especially ones with a dedicated out-of-band management NIC), this is a frequent, hard-to-spot root cause that looks identical to "infrastructure problem" from the Windows side.

- **There is no client-side error UI for a Network Unlock failure** — it fails invisibly to a normal `TPM+PIN` prompt. This is why every diagnosis path in this runbook is registry/event-log driven rather than "what did the user see." See: [BitLocker Network Unlock: known issues — Microsoft Learn](https://learn.microsoft.com/en-us/troubleshoot/windows-client/windows-security/bitlocker-network-unlock-known-issues)

- **Only one Network Unlock certificate can be active domain-wide at a time** — rotating it is a delete-then-add operation on the DC's Public Key Policies node, not an additive one. Plan cert rotation as a change window: devices that haven't rebooted since the swap simply fall back to PIN (safe), but there's a real gap where "everything just stopped working" if the old cert is deleted before the new one propagates.

- **This is genuinely legacy, on-prem-only technology** — Network Unlock has no cloud/Entra/Intune equivalent; it's built entirely around AD DS, GPO, and WDS. In a hybrid or cloud-first environment, this only applies to domain-joined desktops/servers still governed by on-prem Group Policy, not to Entra-joined or co-managed devices using the Intune BitLocker CSP (see `Windows/Troubleshooting/BitLocker/BitLocker-B.md` for that separate, unrelated escrow path).
