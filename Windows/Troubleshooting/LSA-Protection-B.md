# LSA Protection (RunAsPPL) — Hotfix Runbook (Mode B: Ops)
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

> ⚠️ **Not the same feature as VBS/Credential Guard.** If the ticket mentions `lsaiso.exe`, HVCI, or "Memory Integrity," go to `Windows/Troubleshooting/VBS-CredentialGuard-B.md` instead. LSA Protection (this topic) is an older, VBS-independent mechanism — it runs on hardware that can't do Credential Guard at all, and it's what's silently blocking a smart card driver, VPN client, or password filter DLL from loading into `lsass.exe`.

```powershell
# 1. Registry state (may show blank/0 even when protection IS active — see step 3)
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue).RunAsPPL

# 2. Effective policy via Intune/GPO CSP bridge
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\LocalSecurityAuthority' -ErrorAction SilentlyContinue).ConfigureLsaProtectedProcess

# 3. GROUND TRUTH — did LSASS actually start protected? (registry lies, this doesn't)
Get-WinEvent -LogName System -MaxEvents 200 |
    Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Wininit' -and $_.Id -eq 12 } |
    Select-Object -First 1 TimeCreated, Message

# 4. Any plug-in/driver actually blocked from loading into LSASS?
Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 100 |
    Where-Object { $_.Id -in 3033,3063,3065,3066 } |
    Select-Object TimeCreated, Id, Message

# 5. Is this a new-install Win11 22H2+ enterprise-joined, HVCI-capable box? (auto-enable criteria)
Get-ComputerInfo | Select-Object WindowsProductName, OsBuildNumber
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined"
```

| Result | Interpretation |
|--------|---------------|
| Event ID 12 present, "level: 4" | LSA Protection **is** active — trust this over the registry |
| Event ID 12 absent entirely | Protection never started this boot — check policy delivery or hardware gate (HVCI-capable?) |
| `RunAsPPL` = 0 or absent, but Event ID 12 shows level 4 | **Auto-enablement in effect** (Win11 22H2+, domain/Entra-joined, HVCI-capable, clean install) — registry key was never written, this is expected, not a misconfiguration |
| Event 3033/3063 present | A driver/plug-in was **blocked** (enforcement mode) — this is your root cause for "smart card / VPN / password filter stopped working" |
| Event 3065/3066 present, nothing blocked | **Audit mode only** — nothing is broken yet, but this driver *will* break the next time enforcement is on (default audit is on by itself on 22H2+) |
| Symptom is a boot loop / repeated LSASS crash | Skip to Fix 3 (Safe Mode disable) — do not keep rebooting into the same failure |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Symptom: smart card login fails / VPN client can't auth / password filter silently
         stops enforcing / LSASS crashes on boot
        │
        ▼
Is RunAsPPL / LSA Protection active on this box?
   ├─ Registry RunAsPPL = 1 or 2  ──────────────► explicitly configured (GPO/Intune/manual)
   ├─ Registry RunAsPPL absent/0, WinInit Event 12 shows level 4
   │                                 ──────────────► auto-enabled (Win11 22H2+, domain/Entra-joined,
   │                                                  HVCI-capable, clean install — no registry trace)
   └─ WinInit Event 12 absent entirely
                                     ──────────────► not active this boot — policy/hardware gate issue,
                                                      not a plug-in compatibility problem
        │
        ▼ (if active)
Is the failing component (driver/DLL) loaded as an LSA plug-in?
   ├─ Smart card mini-driver, crypto CSP/KSP, password filter DLL, some VPN
   │  auth modules, some legacy AV credential-scan hooks
        │
        ▼
Is it Microsoft-signed (WHQL for drivers / file-signing-service for non-drivers)
AND SDL-compliant?
   ├─ NO  → blocked (Event 3033/3063) — this is BY DESIGN, not a bug. Vendor must
   │         ship a signed build, or the client must accept losing that integration.
   └─ YES → should load; if still failing, check Smart App Control (suppresses
             audit events — see Fix 4) or a corrupted signature chain
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm LSA Protection is actually the cause, not VBS/Credential Guard.**
   `Get-Process lsaiso -ErrorAction SilentlyContinue` — if this returns a process, Credential Guard/VBS is also in play; both can independently block the same plug-in. Check both runbooks if present.

2. **Get ground truth from the event log, never trust the registry alone.**
   ```powershell
   Get-WinEvent -LogName System -MaxEvents 200 | Where-Object { $_.Id -eq 12 -and $_.ProviderName -like '*Wininit*' } | Select-Object -First 1
   ```
   Expected good output contains `level: 4`. No event this boot = not active, regardless of what the registry says.

3. **Identify the specific blocked component.**
   ```powershell
   Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 200 |
       Where-Object { $_.Id -in 3033,3063 } |
       ForEach-Object { $_.Message } | Select-Object -First 5
   ```
   The message text names the DLL/driver path — this is what needs a signed replacement, not a policy change.

4. **Check whether Smart App Control is hiding audit events.**
   Open Windows Security → App & browser control → Smart App Control settings. If **On**, audit events (3065/3066) are suppressed entirely — you'll only see hard failures (3033/3063), which makes pre-enforcement testing impossible until it's turned off.

5. **If this is a boot loop / repeated crash, stop diagnosing live — go to Safe Mode first** (Fix 3), collect the evidence pack from there, then decide on a permanent fix.

---
## Common Fix Paths

<details><summary>Fix 1 — Confirm this is expected auto-enablement, not a rollout error (no action needed)</summary>

```powershell
# Confirm all three auto-enable criteria in one pass
$os = Get-ComputerInfo
$join = dsregcmd /status
$hvciCapable = (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard).AvailableSecurityProperties -contains 2

[PSCustomObject]@{
    Build              = $os.OsBuildNumber
    IsWin11_22H2Plus   = [int]$os.OsBuildNumber -ge 22621
    DomainOrEntraJoined = ($join -match 'AzureAdJoined\s*:\s*YES' -or $join -match 'DomainJoined\s*:\s*YES')
    HVCICapable        = $hvciCapable
}
```

If all three are true and Event ID 12 shows `level: 4`, this device is correctly auto-protected. **Do not "fix" this by clearing the registry** — there's nothing to clear, and disabling it removes a security control the client didn't explicitly ask to remove. Document and close.

</details>

<details>
<summary>Fix 2 — Enable LSA Protection explicitly (Intune, no UEFI lock — recommended default)</summary>

Intune → Devices → Configuration profiles → Create → Windows 10 and later → Templates → Custom:

| Field | Value |
|-------|-------|
| OMA-URI | `./Device/Vendor/MSFT/Policy/Config/LocalSecurityAuthority/ConfigureLsaProtectedProcess` |
| Data type | Integer |
| Value | `2` (no UEFI lock — recoverable remotely) or `1` (UEFI lock — tamper-proof but requires physical/OEM tool to reverse) |

Local/registry equivalent for a single machine:
```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 2 -Type DWord
Restart-Computer
```

**Recommendation for MSP fleets:** use value `2` (no UEFI lock) unless the client has an explicit high-security requirement. Value `1` requires the [LSA Protected Process Opt-out tool](https://www.microsoft.com/download/details.aspx?id=40897) or a full Secure Boot reset to undo — a remote support nightmare if a legitimate driver needs to be reinstated.

</details>

<details>
<summary>Fix 3 — Emergency disable from Safe Mode (boot loop / LSASS crash recovery)</summary>

```powershell
# From Safe Mode with Command Prompt, or WinRE > Command Prompt with offline registry loaded

# If online Safe Mode:
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 0 -Type DWord
Restart-Computer

# If UEFI-locked (value was 1) and software disable has no effect:
# you MUST run the LSA Protected Process Opt-out tool (LsaPplConfig.efi) —
# download from https://www.microsoft.com/download/details.aspx?id=40897
# and follow the tool's boot-time instructions. Software registry edits alone
# will NOT remove a UEFI-locked configuration.
```

**Rollback note:** value `0`/deleted removes the protection entirely — this is a temporary unblock to stop the crash loop, not the fix. Once stable, identify and replace the offending unsigned plug-in, then re-enable via Fix 2.

</details>

<details>
<summary>Fix 4 — Turn off Smart App Control to restore audit visibility before re-enforcing</summary>

Windows Security → App & browser control → Smart App Control settings → **Off**. Reboot, reproduce, then check `Microsoft-Windows-CodeIntegrity/Operational` for events 3065/3066 again. Re-enable Smart App Control once the audit pass is complete if the client wants it on long-term — the two features can coexist, they just can't both be actively evaluated at once for diagnostic purposes.

</details>

<details>
<summary>Fix 5 — Get a vendor-signed build instead of disabling protection</summary>

If Fix 3/4 confirm a specific unsigned smart card driver, crypto CSP, or password filter is the blocker: check the vendor's release notes for "LSA Protection" or "RunAsPPL compatible" builds — most major smart card and VPN vendors shipped compliant drivers between 2023–2025 once Windows 11 22H2 auto-enablement made this unavoidable. Disabling LSA Protection tenant-wide to work around one legacy driver is a security regression that should require explicit client sign-off, documented as a risk acceptance.

</details>

---
## Escalation Evidence

```
LSA PROTECTION (RUNASPPL) ESCALATION
=====================================
Device name:            <hostname>
Windows build:           <OsBuildNumber>
Join type:               <AAD / Hybrid / Domain / Workgroup>
Registry RunAsPPL value: <0 / 1 / 2 / not present>
WinInit Event ID 12:     <present, level X / absent>
CodeIntegrity 3033/3063 events (blocked): <count + names>
CodeIntegrity 3065/3066 events (audit-only): <count + names>
Smart App Control state: <On / Off>
Symptom:                 <e.g. smart card login fails, VPN auth fails, boot loop>
Suspected component:     <driver/DLL path from event message>
Fix attempted:           <Fix # from this runbook>
Result:                  <resolved / still failing / escalating>
```

---
## 🎓 Learning Pointers

- **The registry key can be a false negative.** On a clean-install Windows 11 22H2+ device that's domain/Entra-joined and HVCI-capable, LSA Protection auto-enables *without ever writing `RunAsPPL`* to the registry. Trust WinInit Event ID 12, not the registry, when confirming state. See: [Configure added LSA protection](https://learn.microsoft.com/en-us/windows-server/security/credentials-protection-and-management/configuring-additional-lsa-protection#automatic-enablement)

- **LSA Protection ≠ Credential Guard.** LSA Protection is PPL (Protected Process Light) — available since Windows 8.1/Server 2012 R2, works on any hardware, no SLAT/TPM/Hyper-V required. Credential Guard needs VBS. A device can have one, both, or neither. Don't assume `lsaiso.exe`-focused fixes apply here — cross-reference `Windows/Troubleshooting/VBS-CredentialGuard-A.md` for that distinct feature.

- **Audit mode is on by default and easy to miss.** Windows 11 22H2+ ships with LSA plug-in audit logging enabled out of the box (events 3065/3066) even before you turn on enforcement — use this window to find incompatible drivers *before* a client-wide rollout breaks something.

- **Smart App Control silently kills your audit trail.** If it's on, you only see hard failures, not the pre-warning audit events. Always check its state before concluding "no compatibility issues found."

- **UEFI lock is a one-way door for remote support.** Value `1` can't be reversed by any registry or PowerShell method — only the Microsoft opt-out EFI tool or a full Secure Boot reset works, and both typically need local/physical access. Default new fleet deployments to value `2` unless the client has signed off on the recovery trade-off.
