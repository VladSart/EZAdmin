# BitLocker Network Unlock — Reference Runbook (Mode A: Deep Dive)

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

This runbook covers **BitLocker Network Unlock** — a key protector that lets a domain-joined, `TPM+PIN`-protected Windows device skip the PIN entry prompt at boot when it's on a trusted wired corporate network. It is entirely an **on-premises, Active Directory / Group Policy / Windows Deployment Services (WDS) technology** — there is no Entra ID, Intune, or cloud-managed equivalent. It does not replace or interact with the Intune BitLocker CSP escrow path covered in `Windows/Troubleshooting/BitLocker/BitLocker-A.md`; that runbook's TPM sealing, PCR, and recovery-key-escrow content is a prerequisite baseline this document builds on top of, not a duplicate.

Assumes:
- Windows 10/11 clients, domain-joined via on-prem AD DS (Network Unlock has no hybrid/Entra-only variant)
- BitLocker already configured with `TPM+PIN` protectors via Group Policy before Network Unlock is layered on
- A Windows Server host for the WDS role and BitLocker Network Unlock feature, separate from (but coexisting with) any existing DHCP server
- UEFI native-mode client firmware, not Legacy/CSM BIOS

Out of scope: Intune-managed/cloud-only BitLocker escrow (see `BitLocker-A.md`), BitLocker To Go (removable media), and Device Encryption on non-domain-joined consumer devices.

---

## How It Works

<details>
<summary><strong>Full architecture</strong></summary>

Network Unlock is a **key protector**, not a separate encryption mode. A BitLocker OS volume normally has a `TPM+PIN` protector: the TPM releases half of the unlock material only if PCR measurements match, and the user supplies the other half (the PIN) at boot. Network Unlock adds a second, independent unlock path — a `Network (Certificate Based)` protector — that, when successfully exercised, supplies the equivalent of the PIN automatically, so the boot proceeds without prompting the user.

**The unlock material is split in two, and both halves are required:**
1. A 256-bit intermediate key stored locally, decryptable only by the TPM (same TPM-sealing mechanism as any other BitLocker protector — see `BitLocker-A.md`'s TPM/PCR section).
2. A second 256-bit intermediate key ("network key") that must be obtained live, over the network, from a trusted server, every single boot. This key is never stored locally in usable form.

**The boot-time sequence:**
1. Windows Boot Manager detects a Network Unlock protector exists on the volume.
2. The client's **UEFI firmware** (not Windows itself — this happens pre-OS) uses its own DHCP driver to obtain an IPv4 address on the first enumerated, DHCP-capable network adapter.
3. The client broadcasts a vendor-specific DHCP request containing the network key and a fresh AES-256 session key, both encrypted with the WDS server's Network Unlock certificate's 2048-bit RSA public key.
4. The WDS server's `Nkpprov.dll` provider — a plugin analogous to a PXE provider — recognizes the vendor-specific request, decrypts it with the corresponding RSA private key, and returns the network key re-encrypted with the client's session key via its own vendor-specific DHCP reply.
5. The client combines the returned network key with its local TPM-derived key to reconstruct the AES-256 key that unlocks the volume master key.
6. Boot proceeds with **no PIN prompt shown**.

**Critical architectural point — separation of DHCP and WDS:** the DHCP server that assigns the client's actual IP address and the WDS server hosting the Network Unlock provider are **two distinct roles**, even though WDS itself is closely associated with PXE/DHCP-adjacent behavior in most engineers' mental model. WDS does not need to (and by design should not) also be the DHCP server for this to work — but it does need clean, unblocked line-of-sight to see the client's vendor-specific broadcast on the same L2 segment (or via IP-helper/relay if the WDS server sits on a different subnet, though this is not a primary documented configuration).

**Fail-open by design, not fail-secure:** if the Network Unlock provider is unreachable for *any* reason — server down, cert expired, subnet blocked, Wi-Fi-only device, wrong firmware mode — BitLocker does not error out or block boot. It silently falls back to the standard `TPM+PIN` prompt, exactly as if Network Unlock had never been configured. This is a deliberate design choice (a broken automation layer should never itself cause a lockout), but it means Network Unlock failures present as "the PIN prompt didn't go away," never as an explicit error — all troubleshooting is registry/log-log-driven, never UI-driven.

**Certificate model:** the WDS server's Network Unlock certificate is a 2048-bit RSA key pair packaged as an X.509 cert with a specific Application Policy OID (`1.3.6.1.4.1.311.67.1.1`, "BitLocker Network Unlock"). Only the **public key** (`.cer`) is distributed to clients, via Group Policy, into the `FVE_NKP` certificate store — clients never hold the private key. Only the WDS server holds the private key (`.pfx`), used to decrypt incoming network-key requests. Only **one** Network Unlock certificate can be active domain-wide at a time via the standard GPO path — rotating it is a delete-old/add-new operation, not additive, which has real operational implications during a planned rotation (see Remediation Playbooks).

</details>

---

## Dependency Stack

```
Windows Server: WDS role + BitLocker-NetworkUnlock feature installed & running
         ↑ hosts
Nkpprov.dll provider (registered plugin, listens for vendor-specific DHCP broadcasts)
         ↑ holds private key matching
X.509 cert (2048-bit RSA, OID 1.3.6.1.4.1.311.67.1.1) issued/self-signed for Network Unlock
         ↑ public half of which is deployed via
Group Policy: Public Key Policies → BitLocker Drive Encryption Network Unlock Certificate
         ↑ delivered to
Domain-joined client's FVE_NKP certificate store (requires reboot to take effect)
         ↑ which, combined with an existing TPM+PIN baseline, produces
"Network (Certificate Based)" key protector on the client's encrypted OS volume
         ↑ exercised at every boot via
UEFI-native firmware's own DHCP driver (pre-OS, first enumerated NIC only)
         ↑ requiring a physical path across
Separate DHCP server (issues the actual IP) on the same broadcast domain / relay
         ↑ optionally gated by
bde-network-unlock.ini subnet policy file on the WDS server (restricts by cert+subnet)
```

Every layer above is independently a single point of failure with **no propagated error** — a break anywhere in this stack produces the exact same symptom (PIN prompt persists) regardless of which layer actually failed.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| PIN prompt persists on all domain devices after initial rollout | GPO never delivered, or no client has rebooted since GPO link | `gpresult /h`, then confirm reboot occurred |
| PIN prompt persists on one specific device only | Cert/protector never created on that device, or that device is Wi-Fi-only | `manage-bde -protectors -get C:`, `Get-NetAdapter` |
| Worked before, now fails for everyone at once | Network Unlock certificate expired or was deleted/replaced without client reboot cycle | Check cert `NotAfter` on WDS server |
| Works on-site, fails for the same device from a branch office | Subnet policy file (`bde-network-unlock.ini`) restricting that subnet, or no L2/relay path to WDS server from that subnet | Review `.ini`, confirm network topology |
| Fails only on one hardware model/vendor line | UEFI network stack firmware bug on that model (documented: Surface Pro 4) | Check OEM firmware notes; consider SEMM for Surface |
| Fails intermittently on older client OS versions | DHCP server configured for BOOTP compatibility misinterpreting the handshake's third message | DHCP scope option: DHCP vs "DHCP and BOOTP" |
| WDS role installed, still never works, even on day one | `BitLocker-NetworkUnlock` optional feature not installed (WDS role alone is not enough) | `Get-WindowsFeature BitLocker-NetworkUnlock` |
| Docked laptop works, undocked (different NIC order) fails | Network Unlock only tries the *first-enumerated* adapter — no failover to a second NIC | Check adapter enumeration order in UEFI, not just Device Manager |

---

## Validation Steps

Numbered. Command + expected "good" output + what "bad" looks like.

**1. Confirm baseline TPM+PIN exists (prerequisite, not part of Network Unlock itself)**
```powershell
(Get-BitLockerVolume -MountPoint C:).KeyProtector | Select-Object KeyProtectorType
```
Good: includes `TpmPin`. Bad: only `Tpm` or `RecoveryPassword` — Network Unlock has nothing to attach to yet.

**2. Confirm the client holds the Network Unlock certificate**
```powershell
Get-ChildItem "HKLM:\Software\Policies\Microsoft\SystemCertificates\FVE_NKP\Certificates"
```
Good: one certificate entry, thumbprint matches the server's active cert. Bad: empty — GPO/reboot gap.

**3. Confirm the Network (Certificate Based) protector exists**
```powershell
manage-bde -protectors -get C:
```
Good: a protector of type `TpmCertificate (9)` listed alongside the existing TPM+PIN protector. Bad: absent even though step 2 shows a cert — needs one more reboot.

**4. Confirm native UEFI (not Legacy/CSM)**
```powershell
Confirm-SecureBootUEFI
```
Good: `True`. Bad: `False` or an error — Network Unlock is architecturally impossible in Legacy/CSM mode; this is not fixable in software.

**5. Confirm server-side role and feature state**
```powershell
Get-WindowsFeature WDS-Deployment, BitLocker-NetworkUnlock
Get-Service WDSServer
```
Good: both `Installed`, service `Running`. Bad: `BitLocker-NetworkUnlock` shows `Available` — feature never installed, provider never registered.

**6. Confirm certificate validity window on the server**
```powershell
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.EnhancedKeyUsageList -match "1.3.6.1.4.1.311.67.1.1" } |
  Select-Object Thumbprint, NotBefore, NotAfter
```
Good: `NotAfter` comfortably in the future. Bad: expired or expiring within the current change window.

**7. Confirm GPO delivery of the "Allow Network Unlock at startup" setting**
```powershell
gpresult /h C:\Temp\gpresult.html /f
```
Good: setting present under Computer Configuration, `Enabled`, from an identifiable GPO. Bad: absent — either not linked to this OU, or blocked by a WMI filter/security filtering scope, or superseded by a higher-priority GPO with the setting `Disabled`.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Confirm this is a Network Unlock problem, not a BitLocker problem**
Rule out the baseline first: is BitLocker itself healthy, encrypted, and using TPM+PIN? If not, fix that via `BitLocker-A.md`/`BitLocker-B.md` before touching Network Unlock at all — Network Unlock troubleshooting on top of an unhealthy BitLocker baseline wastes time chasing a symptom that will resolve itself once the baseline is fixed.

**Phase 2 — Isolate scope: one device, one subnet/site, one hardware model, or everyone**
This single question eliminates most of the dependency stack immediately:
- **One device only** → almost certainly client-side (cert delivery, protector creation, wired vs. Wi-Fi, firmware mode). Skip straight to client-side validation steps 1-4.
- **One subnet/site only** → almost certainly network path or subnet policy file (`bde-network-unlock.ini`) or missing DHCP relay/L2 adjacency to the WDS server from that site.
- **One hardware model only** → almost certainly a UEFI firmware stack quirk on that model — check OEM release notes before spending time on GPO/server config that's demonstrably fine for other models.
- **Everyone, all at once, starting from a specific date** → almost certainly server-side: certificate expiry, WDS service stopped, or a GPO change.

**Phase 3 — Client-side deep check**
Work through Validation Steps 1-4 in order. Each is a hard gate — do not skip ahead. The most common real-world finding at this phase is step 2/3: a cert delivered by GPO but the device hasn't been rebooted since, so the protector was never created.

**Phase 4 — Server-side deep check**
Work through Validation Steps 5-6. Confirm the WDS role state and certificate validity are actually current, not assumed — certificate expiry silently breaking a feature that "always just worked" is the single most disruptive failure mode in this stack because it affects every device at once with no warning.

**Phase 5 — Network path check**
Confirm the client's wired NIC is the *first-enumerated* adapter in UEFI (not just "connected" from the OS's point of view), and that there is no 802.1X/DHCP-snooping/port-security policy on the switch blocking the pre-authentication, pre-boot vendor-specific DHCP broadcast. This layer is invisible to `Get-NetAdapter` and other OS-level tooling since the actual handshake happens in UEFI, before Windows loads.

**Phase 6 — Deep server-side log capture (if 1-5 all check out)**
Enable WDS diagnostic debug logging and reproduce the failure. This is the only way to see the actual decrypt attempt (or absence of one) on the server side, distinguishing "request never arrived" (network path problem) from "request arrived but decrypt failed" (certificate/key mismatch problem).
```powershell
wevtutil.exe sl Microsoft-Windows-Deployment-Services-Diagnostics/Debug /e:true
```

---

## Remediation Playbooks

<details>
<summary><strong>Playbook 1 — Initial Network Unlock rollout to a new OU/site</strong></summary>

1. Confirm every target device already has healthy `TPM+PIN` BitLocker via existing GPO before adding Network Unlock — do not attempt to roll out both simultaneously; you lose the ability to distinguish which layer failed.
2. Install `WDS-Deployment` + `BitLocker-NetworkUnlock` features on the target server (this can be the same or different server from any existing PXE/imaging WDS instance).
3. Generate or import the Network Unlock certificate; import the `.pfx` (private key) to the WDS server, distribute the `.cer` (public key only) via the domain's Public Key Policies GPO node.
4. Enable "Allow Network Unlock at startup" in the same or a linked GPO, scoped to the target OU.
5. Roll out to a small pilot group first — reboot pilot devices twice (once to receive GPO+cert, once more if the protector doesn't appear immediately) and confirm via Validation Steps 1-3 before wider rollout.
6. **Rollback:** disable the "Allow Network Unlock at startup" GPO setting — this automatically removes the Network Unlock key protector from client devices on next policy refresh, with zero impact on the underlying TPM+PIN protection or encrypted data.

</details>

<details>
<summary><strong>Playbook 2 — Planned certificate rotation (before expiry, not emergency)</strong></summary>

1. Generate the new certificate (self-signed or CA-issued) on/for the WDS server ahead of the old one's expiry — build in weeks of lead time, not days, because of the reboot-gated propagation delay described below.
2. Import the new cert's private key (`.pfx`) to the WDS server's `BitLocker Drive Encryption Network Unlock` certificate store — **do not remove the old certificate from the server yet.**
3. On the DC: add the new `.cer` to the Public Key Policies GPO node **alongside** the existing one is not supported — only one certificate is deliverable via this GPO path at a time. This is the operationally tricky part: the moment you swap the GPO's certificate, every client that hasn't yet rebooted with the *old* cert-derived protector will fall back to PIN prompt (safe, but a support-ticket spike) until they receive and reboot with the *new* cert.
4. Communicate the PIN-prompt-may-reappear-temporarily window to affected teams before executing step 3.
5. `gpupdate /force` broadly, then track reboot cycles across the fleet over the following days.
6. Once fleet-wide validation confirms the new protector is present everywhere (Validation Step 3), remove the old certificate from the WDS server's local store.
7. **Rollback:** if the new certificate has a problem, re-add the old `.cer` to the GPO node (assuming its private key wasn't yet removed from the WDS server) — clients revert to PIN prompt in the interim regardless, so there's no unlock risk either direction.

</details>

<details>
<summary><strong>Playbook 3 — Diagnosing a site-wide outage (server appears healthy, all devices at one site fail)</strong></summary>

1. Confirm from a healthy site/device that the WDS server and certificate are genuinely fine (rules out Playbook 2-style expiry).
2. Check for an IP-helper/DHCP-relay configuration change on the affected site's router/switch — Network Unlock's vendor-specific broadcast needs to reach the WDS server, and unlike ordinary DHCP relay, this is not always covered by an existing "relay DHCP to server X" configuration if that configuration was scoped narrowly to standard DHCP ports/options only.
3. Check for a recent network security change (802.1X rollout, port security, DHCP snooping with trusted-port lists) — these are common, innocent-looking causes of a sudden site-wide Network Unlock outage that don't affect standard DHCP client behavior at all, only the vendor-specific broadcast Network Unlock relies on.
4. Review `bde-network-unlock.ini` on the WDS server for a recently added/edited subnet restriction that inadvertently excludes the affected site.
5. **Rollback:** none needed — this playbook is diagnostic. Fixes are typically network infrastructure changes (relay config, switch policy) outside BitLocker/AD tooling entirely.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Network Unlock evidence from a client for escalation or audit.
.DESCRIPTION
    Run locally as admin on the affected client. Produces a text summary covering
    baseline BitLocker protector state, Network Unlock certificate presence,
    firmware mode, and adapter enumeration — everything needed to hand off
    to whoever owns the WDS server side.
#>
$out = [System.Collections.Generic.List[string]]::new()
$out.Add("=== BITLOCKER NETWORK UNLOCK EVIDENCE — $(Get-Date) ===")
$out.Add("Hostname: $env:COMPUTERNAME")

$out.Add("`n--- KEY PROTECTORS ---")
(Get-BitLockerVolume -MountPoint C:).KeyProtector |
    ForEach-Object { $out.Add("  $($_.KeyProtectorType) : $($_.KeyProtectorId)") }

$out.Add("`n--- FVE_NKP CERTIFICATE ---")
$cert = Get-ChildItem "HKLM:\Software\Policies\Microsoft\SystemCertificates\FVE_NKP\Certificates" -ErrorAction SilentlyContinue
if ($cert) { $out.Add("  Present: $($cert.Name)") } else { $out.Add("  MISSING — GPO/reboot gap") }

$out.Add("`n--- SECURE BOOT / UEFI MODE ---")
try {
    $sb = Confirm-SecureBootUEFI
    $out.Add("  Confirm-SecureBootUEFI: $sb")
} catch {
    $out.Add("  ERROR (likely Legacy/CSM mode): $($_.Exception.Message)")
}

$out.Add("`n--- NETWORK ADAPTERS (enumeration order matters, this is a proxy only) ---")
Get-NetAdapter | Sort-Object ifIndex | ForEach-Object {
    $out.Add("  [$($_.ifIndex)] $($_.Name) - $($_.MediaType) - $($_.Status)")
}

$out.Add("`n--- GPO SUMMARY (Network Unlock relevant lines) ---")
$gpFile = "$env:TEMP\gpresult_nku.html"
gpresult /h $gpFile /f | Out-Null
$out.Add("  Full report: $gpFile (open manually and search 'Network Unlock')")

$out -join "`n" | Out-File "$env:TEMP\NetworkUnlock-Evidence-$env:COMPUTERNAME.txt" -Encoding UTF8
Write-Host "Evidence written to $env:TEMP\NetworkUnlock-Evidence-$env:COMPUTERNAME.txt" -ForegroundColor Green
```

For server-side evidence, use `Windows/Scripts/Get-NetworkUnlockReadinessAudit.ps1` (companion script to this runbook) — it covers WDS role/feature state, certificate expiry, and subnet policy file contents in one pass.

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `manage-bde -protectors -get C:` | List all key protectors on a volume, including `TpmCertificate (9)` for Network Unlock |
| `Get-ChildItem "HKLM:\Software\Policies\Microsoft\SystemCertificates\FVE_NKP\Certificates"` | Confirm client received the Network Unlock cert via GPO |
| `Confirm-SecureBootUEFI` | Confirm native UEFI mode (required — Legacy/CSM cannot support Network Unlock) |
| `Get-NetAdapter \| Sort-Object ifIndex` | Check adapter enumeration order (first NIC is the only one Network Unlock tries) |
| `Get-WindowsFeature WDS-Deployment, BitLocker-NetworkUnlock` | Confirm both server-side role and feature are installed |
| `Get-Service WDSServer` | Confirm the WDS service is actually running |
| `Install-WindowsFeature BitLocker-NetworkUnlock` | Install the Network Unlock optional feature (WDS role alone is not sufficient) |
| `Get-ChildItem Cert:\LocalMachine\My \| Where EnhancedKeyUsageList -match "1.3.6.1.4.1.311.67.1.1"` | Find the active Network Unlock cert on the server and check its expiry |
| `Get-Content "$env:windir\System32\bde-network-unlock.ini"` | Review subnet restriction policy on the WDS server (if present) |
| `wevtutil.exe sl Microsoft-Windows-Deployment-Services-Diagnostics/Debug /e:true` | Enable WDS debug logging for deep server-side capture |
| `gpresult /h report.html /f` | Confirm GPO delivery of "Allow Network Unlock at startup" and the certificate policy |
| `gpupdate /force` | Force policy refresh on a client (still requires a reboot for the protector itself) |

---

## 🎓 Learning Pointers

- **Network Unlock's boot-time handshake happens entirely in UEFI, before Windows loads** — this is why OS-level network diagnostics (`Get-NetAdapter`, `Test-NetConnection`) can only ever be a proxy, never a direct test, for whether the handshake will succeed. A NIC that looks perfectly healthy from within Windows can still fail Network Unlock if it isn't the first-enumerated adapter, or if the UEFI driver for it has a firmware bug. Read: [Network Unlock — Microsoft Learn](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/network-unlock)

- **Fail-open, not fail-secure, and silently so** — every layer of this stack degrades to "just ask for the PIN" on failure, with zero user-facing error and zero automatic alerting. This is the right security design (an automation failure should never cause a lockout) but it means Network Unlock has no built-in monitoring signal — if you want proactive detection of a fleet-wide outage (e.g., a cert that quietly expired), you need to build it yourself from WDS server logs or a scheduled audit script, not wait for a support ticket spike.

- **WDS is a dependency here in name only** — most engineers associate WDS purely with PXE boot/OS imaging. For Network Unlock, WDS is really just a convenient, already-built host process for the `Nkpprov.dll` provider plugin; it doesn't need to actually be configured for or used by any imaging workflow. Don't assume a WDS server "isn't doing anything" and decommission it without first checking whether it's silently serving Network Unlock.

- **Certificate rotation is the highest-risk planned-maintenance operation in this stack** — because only one cert can be GPO-deployed at a time, and protector creation is reboot-gated, there is an unavoidable window where devices that haven't yet rebooted with the new cert fall back to PIN prompt. This is safe (no lockout risk) but will generate a predictable spike in "why is my PC suddenly asking for a PIN" tickets if not communicated ahead of time. Treat it as a proper change window, not a quick swap.

- **This technology has no cloud/Entra/Intune path — full stop** — if a device is Entra-joined (not hybrid) or managed purely via Intune with no on-prem AD DS/GPO, Network Unlock is architecturally not available to it. Don't spend time trying to find an Intune CSP equivalent; there isn't one. The closest cloud-era analogue for reducing PIN friction is Windows Hello for Business or simply reassessing whether `TPM+PIN` is still necessary given modern hardware-based mitigations (see the "When should an additional method of authentication be considered" guidance in Microsoft's BitLocker FAQ).

- **Community-reported hardware quirks are real and worth checking early** — the documented Surface Pro 4 UEFI network stack issue (resolved via Surface Enterprise Management Mode, SEMM) is a good reminder that "infrastructure confirmed working for other models" is a valid and fast way to rule out GPO/server config and jump straight to an OEM firmware investigation. Read: [BitLocker Network Unlock: known issues — Microsoft Learn](https://learn.microsoft.com/en-us/troubleshoot/windows-client/windows-security/bitlocker-network-unlock-known-issues)
