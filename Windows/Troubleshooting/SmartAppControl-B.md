# Smart App Control (SAC) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "Smart App Control blocked this app", or SAC won't turn on/off, in under 10 minutes.

> **Context (Sept 2026):** Smart App Control is Windows 11's built-in, reputation-based app-control layer (Windows Security → App & browser control → Smart App Control). Until April 2026 it was a one-way switch: once it was **Off**, you had to reset or reinstall Windows to turn it back on. The **14 April 2026 cumulative update KB5083769** (builds 26100.8246 / 26200.8246, Windows 11 24H2/25H2) removed that restriction. SAC can now be switched On/Off from Windows Security without a reinstall. Microsoft's SAC FAQ now tells users to temporarily disable SAC for installs that rely on unsigned **MST transform files**, then re-enable it. **SAC has no per-app allow list and no "run anyway".** It is not designed for enterprise-managed devices. For those, use App Control for Business (WDAC). Sources: [Topedia, 26 Apr 2026](https://blog-en.topedia.com/2026/04/smart-app-control-in-windows-11-can-now-be-re-enabled-without-reinstalling/); [CIAOPS, 16 Apr 2026](https://blog.ciaops.com/2026/04/16/existing-systems-can-now-enable-windows-smart-app-control-and-you-should/); [Smart App Control FAQ (Microsoft Support)](https://support.microsoft.com/en-us/windows/smart-app-control-frequently-asked-questions-285ea03d-fa88-4d56-882e-6698afdb7003).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

```powershell
# 1. SAC state (0 = Off, 1 = On/Enforce, 2 = Evaluation)
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue |
    Select-Object VerifiedAndReputablePolicyState

# 2. Defender's view (property exists on current Defender platform versions)
Get-MpComputerStatus | Select-Object SmartAppControlState, SmartAppControlExpiration, AMProductVersion

# 3. Build: is the April 2026 re-enable fix present? (need 26100.8246+ / 26200.8246+)
$v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"$($v.CurrentBuild).$($v.UBR)"

# 4. Is the device managed? (MDM enrollment or domain join means SAC is not the right control)
(Get-CimInstance Win32_ComputerSystem).PartOfDomain
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
    Get-ItemProperty | Where-Object { $_.PSObject.Properties.Name -contains 'ProviderID' } | Select-Object ProviderID, UPN

# 5. Recent Code Integrity blocks (SAC enforces through the CI engine)
Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object Id -in 3077, 3033, 3034, 3076 | Select-Object TimeCreated, Id, Message -First 10
```

| Finding | Action |
|---|---|
| State `1` + CI 3077/3033 events naming the user's app | SAC is blocking an unsigned/unknown binary, as designed. Go to Fix 1 (vendor-signed version) or Fix 2 (temporary off → install → on) |
| State `2` (Evaluation) and the app is blocked | Not SAC. Evaluation mode never blocks. Check Defender AV, SmartScreen, ASR, WDAC/AppLocker |
| State `0` and user/owner wants it on, build **below** 26100.8246 | The one-way switch still applies. Install the latest CU first (Fix 3) |
| State `0`, build **at or above** the fix, toggle greyed out | Managed device or policy-controlled. Fix 4. Use App Control for Business instead |
| Domain-joined or Intune-enrolled device | SAC isn't the supported control here. Fix 4 |
| Block happens during an MSI install that uses an `.mst` transform | Known Microsoft-documented case. Fix 2 |
| Blocks on dev/admin tooling (self-built exes, unsigned scripts) | SAC is a poor fit for this persona. Fix 2 won't stick. Recommend Off plus other controls (Fix 5) |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Windows 11 (22H2+), consumer/unmanaged or lightly managed device
   │
   ├─ Build ≥ 26100.8246 / 26200.8246 (KB5083769, Apr 2026)
   │     → SAC can be switched On/Off freely
   │   Build below that → Off is permanent until reset/reinstall
   │
Code Integrity engine (ci.dll) + SAC base policy "VerifiedAndReputable"
   │   HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy\VerifiedAndReputablePolicyState
   │     0 Off · 1 On (enforce) · 2 Evaluation
   │
Intelligent Security Graph (cloud reputation) reachable
   │   Offline/unknown reputation → falls back to signature check
   │
Pre-execution decision per file (EXE, DLL, MSI, scripts, MST):
   1. Cloud says known-good → allow
   2. Validly signed by trusted cert → allow
   3. Otherwise → BLOCK (no user override, no allow list)
   │
Not overridden by enterprise management:
   MDM/GPO/ConfigMgr-managed devices → SAC is expected Off; use App Control for Business
```
</details>

---
## Diagnosis & Validation Flow

1. **Read the state**
   ```powershell
   (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -EA SilentlyContinue).VerifiedAndReputablePolicyState
   ```
   `1` = enforcing, `2` = evaluating (never blocks), `0` = off, `$null` = pre-SAC build or SAC not provisioned.

2. **Prove SAC is the blocker, not something else**
   ```powershell
   Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 200 |
       Where-Object { $_.Id -in 3077,3033,3034 -and $_.TimeCreated -gt (Get-Date).AddHours(-2) } |
       Format-List TimeCreated, Id, Message
   ```
   Good match: a 3077 (enforced block) or 3033 (signature level not met) that names the file the user launched, with the SAC/VerifiedAndReputable policy referenced. No CI event → look at Defender (`Get-MpThreatDetection`), SmartScreen, or ASR (`Get-MpComputerStatus`, event 1121 in `Microsoft-Windows-Windows Defender/Operational`).

3. **Check the file's signature**
   ```powershell
   Get-AuthenticodeSignature '<C:\path\to\app.exe>' | Select-Object Status, SignerCertificate
   ```
   `NotSigned` / `UnknownError` together with no cloud reputation explains the block. A `Valid` signature that's still blocked usually means a DLL or child process is the unsigned piece. Check which file the CI event names.

4. **Check the build supports toggling**
   ```powershell
   $v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; "$($v.CurrentBuild).$($v.UBR)"
   ```
   ≥ `26100.8246` / `26200.8246` → the toggle is reversible.

5. **Validate after the fix**. Relaunch the app, confirm no new 3077, and confirm the state is where the owner wants it (usually `1`).

---
## Common Fix Paths

<details><summary>Fix 1 — Get a signed / reputable build of the app (preferred)</summary>

- Download the vendor's current, signed installer from the vendor's site, not a mirror or old copy.
- For internal LOB apps: sign them with a trusted code-signing certificate (publicly trusted OV/EV, or Azure Trusted Signing). Self-signed or internal-CA certs **don't** satisfy SAC.
- Validate: `Get-AuthenticodeSignature` → `Valid`, then relaunch.
</details>

<details><summary>Fix 2 — Temporary off → install → back on (build ≥ KB5083769)</summary>

Only for a trusted installer (Microsoft-documented case: MSI installs with unsigned `.mst` transforms).

1. Windows Security → App & browser control → **Smart App Control settings** → **Off**.
2. Run the install.
3. Same page → **On**.
4. Confirm: `VerifiedAndReputablePolicyState` = `1`.

- **Warning:** the *installed* app still has to pass SAC every time it launches. If the app's own binaries are unsigned, it'll be blocked again once SAC is on. That's Fix 1 or Fix 5 territory.
- On a build **below** the April 2026 CU, step 3 isn't possible. Do Fix 3 first.
- SAC isn't exposed through a supported CSP/GPO for consumer toggling. Don't script the registry value. Use the Windows Security UI.
</details>

<details><summary>Fix 3 — "Can't turn SAC back on" on an older build</summary>

```powershell
# Check for KB5083769 or any later cumulative update
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, InstalledOn
```
Install the latest cumulative update through Windows Update, reboot, and re-check the build is ≥ 26100.8246 / 26200.8246. The toggle then becomes available. Before April 2026, the only path was Reset this PC or a reinstall. You no longer need to do that.
</details>

<details><summary>Fix 4 — Managed / business device: use App Control for Business instead</summary>

- For Intune-enrolled, domain-joined or ConfigMgr devices, SAC is expected **Off**, and Microsoft points enterprises to **App Control for Business** (WDAC) with managed installer and ISG rules. That gives you the same reputation-based blocking, but *with* allow-list control.
- Build it via Intune → Endpoint security → App Control for Business. Start in **audit** mode. See `Security/Defender/WDAC-B.md`.
- Don't try to force SAC on managed fleets. There's no central management or reporting, and no exception handling.
</details>

<details><summary>Fix 5 — SAC is a poor fit for this user (devs, admins, script-heavy roles)</summary>

- Turn SAC **Off** and document it.
- Compensating controls: Defender AV + cloud protection, SmartScreen, ASR rules in block mode, standard-user rights / EPM (`Intune/Troubleshooting/EPM-B.md`).
- Revisit if the persona changes. Since April 2026, turning SAC back on is a toggle, not a rebuild.
</details>

---
## Escalation Evidence

```
SMART APP CONTROL — ESCALATION
================================
Ticket #:                        <>
Device / user:                   <hostname> / <UPN>
Build (CurrentBuild.UBR):        <e.g. 26100.8246>
VerifiedAndReputablePolicyState: <0 / 1 / 2 / not present>
Get-MpComputerStatus SAC state:  <SmartAppControlState>
Managed? (domain / MDM provider):<>
Blocked file (from CI event):    <full path>
CI event IDs + time:             <3077 / 3033 @ ...>
Authenticode status of file:     <Valid / NotSigned / ...>
Vendor / internal app:           <>
Fix attempted:                   <1 signed build / 2 temp off-on / 3 CU / 4 AppControl / 5 off+compensating>
Outcome:                         <>
```

---
## 🎓 Learning Pointers
- SAC's decision is cloud reputation → valid signature → block. There's no third "ask the user" step, so "just allow it" isn't an option. — [Smart App Control FAQ](https://support.microsoft.com/en-us/windows/smart-app-control-frequently-asked-questions-285ea03d-fa88-4d56-882e-6698afdb7003)
- April 2026 (KB5083769) changed only the *lifecycle*: On/Off is now reversible. The enforcement engine didn't change. — [Topedia](https://blog-en.topedia.com/2026/04/smart-app-control-in-windows-11-can-now-be-re-enabled-without-reinstalling/), [CIAOPS](https://blog.ciaops.com/2026/04/16/existing-systems-can-now-enable-windows-smart-app-control-and-you-should/)
- Evaluation mode (`2`) never blocks. If a user in Evaluation reports a block, look at Defender, SmartScreen or ASR instead.
- SAC is the consumer-grade version of App Control for Business, built on the same Code Integrity engine and events. Managed fleets get the enterprise version: `Security/Defender/WDAC-A.md`, and the [App Control for Business overview (Learn)](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/appcontrol).
- Deep dive: `SmartAppControl-A.md`. Status script: `Windows/Scripts/Get-SmartAppControlStatus.ps1`.
