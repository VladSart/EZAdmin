# Smart App Control (SAC) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:** Smart App Control on Windows 11 (22H2 onward), especially after the **14 April 2026 cumulative update KB5083769** (OS builds 26100.8246 / 26200.8246), which made SAC reversible. Typical MSP contexts: unmanaged SMB PCs, BYOD, home-worker devices, break/fix clients without Intune.

**Out of scope:** App Control for Business / WDAC policy authoring (`Security/Defender/WDAC-A.md`), AppLocker (`Windows/Troubleshooting/AppLocker-A.md`), Defender AV detections, and SmartScreen for downloads.

**Source confidence:**

| Fact | Source | Confidence |
|---|---|---|
| SAC reversible from KB5083769 (14 Apr 2026), 24H2/25H2 | Topedia (26 Apr 2026, links the KB), CIAOPS (16 Apr 2026) | High |
| MST-transform installs as the documented reason to temporarily disable | Microsoft Support SAC FAQ, quoted by Topedia | High |
| Decision order: cloud reputation → signature → block; no per-app exceptions | Microsoft Support SAC FAQ; CIAOPS | High |
| Managed (Intune/GPO/ConfigMgr) devices expected Off; enterprises pointed at App Control for Business | Community write-ups of Microsoft guidance (HTMD, CIAOPS) | Medium-high |
| Registry `CI\Policy\VerifiedAndReputablePolicyState` 0/1/2 | Long-standing, widely documented field behaviour | Medium-high. Read it, don't write it |
| `Get-MpComputerStatus` `SmartAppControlState` / `SmartAppControlExpiration` | Present on current Defender platform versions | Medium. The script treats them as optional |

---
## How It Works

<details><summary>Full architecture</summary>

### What SAC actually is

SAC is a **Microsoft-signed App Control (WDAC) base policy** called *VerifiedAndReputableDesktop*, shipped in the OS and enforced by the **Code Integrity** engine, the same engine that enforces App Control for Business. The difference is who owns the policy:

```
                    ┌───────────────────────────────┐
                    │     Code Integrity (ci.dll)    │  kernel + user-mode enforcement
                    └──────────────┬────────────────┘
                 ┌─────────────────┴─────────────────┐
     Microsoft-owned policy                   Org-owned policies
     "Smart App Control"                      "App Control for Business"
     • on/off/eval only                       • allow/deny rules, managed installer,
     • ISG reputation + signature               ISG option, supplemental policies
     • no exceptions, no central mgmt         • Intune/GPO/ConfigMgr deployed, audit mode
     • consumer/unmanaged                     • managed fleets
```

### Decision pipeline (per file, pre-execution)

1. **Cloud reputation (Intelligent Security Graph).** Known-good, prevalent files are allowed. Known-bad files are blocked.
2. **Signature check.** If reputation is inconclusive, a valid signature chaining to a trusted root (Microsoft Trusted Root Program) allows the file. Self-signed and private-CA signatures don't count.
3. **Otherwise block.** No prompt, no "run anyway", no exception list.

SAC covers PE files (EXE/DLL/SYS), MSI, and scripts, including the *files the installer loads*. MST transform files can't be signed, so a transform with no reputation blocks the install. That's why Microsoft's FAQ names MST as the case where you temporarily disable SAC.

### The three states and the lifecycle

| State | Registry value | Blocks? | How you get there |
|---|---|---|---|
| **Evaluation** | `2` | No. It observes | Clean install (default). SAC decides on its own whether the user is a good fit, then moves to On or Off |
| **On** | `1` | Yes | Auto from Evaluation, or the user toggles it |
| **Off** | `0` | No | Auto from Evaluation (poor fit / enterprise-managed), or the user toggles it |

**Before KB5083769:** Off was terminal, and only a reset or reinstall could get back to Evaluation/On. Upgraded devices often landed Off permanently. **From KB5083769:** On ↔ Off is a user toggle in Windows Security. That turns SAC from a "decide once at OOBE" feature into a usable control for SMB/unmanaged fleets.

### Why enterprise devices are Off

During Evaluation, SAC detects enterprise management (MDM enrollment, domain join, ConfigMgr) and turns itself Off. The design intent is that an organisation with management tooling should run **App Control for Business**, where it owns the allow list, can use **managed installer** (apps deployed by Intune Management Extension / ConfigMgr are trusted automatically), and can audit before enforcing. SAC has none of that, and no central telemetry beyond each device's CI event log.

### Where blocks surface

- User toast: "Smart App Control blocked an app that may be unsafe".
- `Microsoft-Windows-CodeIntegrity/Operational`: **3077** (enforced block), **3033/3034** (signature-level not met), **3076** (audit-mode would-block, seen when a policy is in audit). Event text references the policy, so you can tell SAC blocks apart from org App Control policies.
- Defender for Endpoint (if onboarded): Advanced Hunting `DeviceEvents` with `ActionType` starting `AppControl`.

</details>

---
## Dependency Stack

```
[L0] Windows 11 client (22H2+). Not Server, not Windows 10
  └─[L1] Servicing: KB5083769 (Apr 2026) or later → reversible toggle
      └─[L2] SAC base policy provisioned (VerifiedAndReputablePolicyState present)
          └─[L3] State: 2 Eval → auto-decides │ 1 On │ 0 Off
              └─[L4] Code Integrity enforcement (ci.dll) + CI event log
                  └─[L5] ISG cloud reputation reachable (else signature-only path)
                      └─[L6] Per-file verdict: reputation ▸ trusted signature ▸ block
                          └─[L7] Management context: unmanaged → SAC appropriate
                                                    managed → App Control for Business
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Smart App Control blocked…" toast | Unsigned/unknown file under State 1 | CI 3077 names the file |
| Installer fails part-way, no clear error | Unsigned DLL/MST loaded by a signed installer | CI 3077/3033 around install time |
| SAC toggle greyed out / "turned off by your organization" | Managed device, or policy in place | Domain join / MDM enrollment |
| SAC Off and "can't be turned on" | Build below KB5083769 | `CurrentBuild.UBR` |
| App blocked but State is 2 | Not SAC (Evaluation never blocks) | Defender / SmartScreen / ASR / org WDAC |
| App blocked on managed device with SAC Off | Org App Control policy | `CiTool --list-policies` |
| Internal tool blocked even though signed | Signed with internal CA / self-signed cert | `Get-AuthenticodeSignature` chain |
| SAC flips from Eval to Off by itself | Enterprise management detected, or usage pattern judged incompatible | Expected behaviour |
| Newly released vendor version blocked, old one fine | New binary has no reputation yet and is unsigned | Vendor signing / wait for reputation |

---
## Validation Steps

1. **State**: `(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy').VerifiedAndReputablePolicyState`. Good: `1` (or `0` by decision). Bad: `$null` on a Win11 build means SAC isn't provisioned.
2. **Build**: `"$((gp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild).$((gp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)"`. Good: ≥ 26100.8246 / 26200.8246.
3. **Active CI policies**: `CiTool.exe --list-policies` (Windows 11 22H2+). Good: you can see which policies are enforced (SAC vs org policies). Bad: an unexpected org policy is present on a supposedly unmanaged device.
4. **Defender status**: `Get-MpComputerStatus | Select SmartAppControlState, SmartAppControlExpiration`. Should agree with step 1.
5. **Block evidence**: CI Operational 3077/3033 for the specific path. Good: none after the fix.
6. **Signature**: `Get-AuthenticodeSignature <file>` → `Valid`, and the signer chains to a public root.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Attribute the block.** State `1` + CI 3077 naming the file = SAC. Anything else goes to the relevant runbook (Defender, ASR, WDAC, AppLocker).

**Phase 2 — Identify the failing file.** Installers often fail on a *child* file. Read the CI event's file path, not the installer name. Check each unsigned component with `Get-AuthenticodeSignature`.

**Phase 3 — Choose the durable path:**
- Vendor app → signed or current build (Playbook 1).
- One-off trusted install → toggle cycle (Playbook 2).
- Recurring unsigned tooling → SAC isn't the right control for this device/persona (Playbook 4).
- Managed device → App Control for Business (Playbook 3).

**Phase 4 — Confirm end state.** State is back to the intended value, the app launches, and no new CI blocks appear over the next session.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Make the app SAC-compatible</summary>

- Vendor: get the current signed release. Old unsigned builds won't gain reputation.
- Internal LOB: sign **every** PE and script with a publicly trusted code-signing cert (OV/EV) or **Azure Trusted Signing** (Microsoft-managed, chains to the Microsoft Identity Verification root). Timestamp the signature (`signtool sign /tr <tsa> /td sha256 /fd sha256`) so it stays valid after the cert expires.
- Re-test on a SAC-On device.
</details>

<details><summary>Playbook 2 — Controlled toggle cycle (post-KB5083769 only)</summary>

1. Record the current state (Evidence Pack).
2. Windows Security → App & browser control → Smart App Control settings → **Off**.
3. Install the trusted package.
4. Toggle **On**.
5. Verify the state is `1` and the installed app actually launches. If it doesn't, the app's runtime binaries are unsigned, so go to Playbook 1 or 4.

**Rollback:** none needed. The toggle is reversible on this build. Don't edit `VerifiedAndReputablePolicyState` directly: it's unsupported and can leave CI policy and UI state inconsistent.
</details>

<details><summary>Playbook 3 — Managed fleet: move to App Control for Business</summary>

1. Intune → Endpoint security → App control for business → create policy with **"Trust apps with good reputation"** (ISG) and **"Trust apps from managed installers"**. Deploy in **Audit**.
2. Collect 3076 audit events (or MDE `AppControlCodeIntegrityPolicyAudited`) for 2–4 weeks and add supplemental rules for legitimate LOB apps.
3. Switch to Enforce ring by ring.
4. Reference: `Security/Defender/WDAC-A.md`.

**Rollback:** set the policy back to Audit, or unassign it. Enforcement lifts after policy refresh/reboot.
</details>

<details><summary>Playbook 4 — Opt the device out with compensating controls</summary>

- SAC **Off** (document the reason and owner).
- Defender AV real-time + cloud-delivered protection + tamper protection on.
- SmartScreen on for apps/files (`Get-MpPreference`, Windows Security → Reputation-based protection).
- ASR rules in Block, especially "Block executable files from running unless they meet a prevalence, age, or trusted list criterion", which is the closest AV-side analogue to SAC.
- Standard user + EPM for elevation (`Intune/Troubleshooting/EPM-A.md`).
</details>

<details><summary>Playbook 5 — Rolling SAC out to an unmanaged SMB client base</summary>

1. Patch to KB5083769+ (verify with the status script).
2. Run `Get-SmartAppControlStatus.ps1` via RMM to baseline state, build, management status and recent blocks.
3. Pilot: toggle On for standard office users. Watch CI 3077 in the RMM output for 2 weeks.
4. Broaden. Exclude dev/admin personas (Playbook 4).
5. If the client later adopts Intune, plan the move to Playbook 3. SAC will switch itself off on enrolled devices.
</details>

---
## Evidence Pack

```powershell
$out = "C:\Temp\SACEvidence_$($env:COMPUTERNAME)_$(Get-Date -f yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$ci = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -EA SilentlyContinue
[PSCustomObject]@{
    Computer   = $env:COMPUTERNAME
    Product    = $cv.ProductName
    Build      = "$($cv.CurrentBuild).$($cv.UBR)"
    SACState   = if ($ci) { $ci.VerifiedAndReputablePolicyState } else { $null }
    DomainJoin = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
} | Format-List | Out-File "$out\summary.txt"

Get-MpComputerStatus -EA SilentlyContinue | Format-List * | Out-File "$out\mpstatus.txt"
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -EA SilentlyContinue | Get-ItemProperty |
    Select-Object PSChildName, ProviderID, UPN, EnrollmentType | Export-Csv "$out\enrollments.csv" -NoTypeInformation
if (Get-Command CiTool.exe -EA SilentlyContinue) { CiTool.exe --list-policies | Out-File "$out\ci-policies.txt" }
Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 500 -EA SilentlyContinue |
    Where-Object Id -in 3033,3034,3076,3077 |
    Select-Object TimeCreated, Id, Message | Export-Csv "$out\ci-events.csv" -NoTypeInformation
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10 HotFixID, InstalledOn |
    Export-Csv "$out\hotfixes.csv" -NoTypeInformation

Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| SAC state | `(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy').VerifiedAndReputablePolicyState` |
| Defender SAC view | `Get-MpComputerStatus \| Select SmartAppControlState, SmartAppControlExpiration` |
| Build + UBR | `$v=gp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; "$($v.CurrentBuild).$($v.UBR)"` |
| Recent CU | `Get-HotFix \| Sort InstalledOn -Desc \| Select -First 5` |
| Active CI policies | `CiTool.exe --list-policies` |
| SAC/CI blocks | `Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' \| ? Id -in 3077,3033` |
| File signature | `Get-AuthenticodeSignature <file>` |
| Domain joined? | `(Get-CimInstance Win32_ComputerSystem).PartOfDomain` |
| MDM enrolled? | `Get-ChildItem HKLM:\SOFTWARE\Microsoft\Enrollments \| Get-ItemProperty \| ? ProviderID` |
| Open SAC settings | `start windowsdefender://appbrowser` |
| Status script | `.\Get-SmartAppControlStatus.ps1 -Hours 72` |

---
## 🎓 Learning Pointers
- SAC is just a Microsoft-owned App Control policy running on the same Code Integrity engine as WDAC. Learn the CI event IDs once and they work for both. — [App Control for Business overview](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/appcontrol)
- The April 2026 change (KB5083769) made SAC practical for SMB and unmanaged fleets. Before that, "Off" was permanent. — [Topedia](https://blog-en.topedia.com/2026/04/smart-app-control-in-windows-11-can-now-be-re-enabled-without-reinstalling/), [CIAOPS](https://blog.ciaops.com/2026/04/16/existing-systems-can-now-enable-windows-smart-app-control-and-you-should/)
- MST transforms can't be signed. That's the documented case for a temporary toggle. — [Smart App Control FAQ](https://support.microsoft.com/en-us/windows/smart-app-control-frequently-asked-questions-285ea03d-fa88-4d56-882e-6698afdb7003)
- For in-house apps, Azure Trusted Signing is the cheapest way to satisfy SAC's "trusted signature" branch. — [Trusted Signing (Learn)](https://learn.microsoft.com/en-us/azure/trusted-signing/overview)
- Managed fleets should use App Control for Business with ISG + managed installer, which is SAC's logic plus an allow list. See `Security/Defender/WDAC-A.md`.
