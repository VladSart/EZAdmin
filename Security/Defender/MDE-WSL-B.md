# Defender for Endpoint Plug-in for WSL — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** the plug-in extends Defender for Endpoint **visibility** into WSL2 containers — it does **not** add response actions (no isolate, no AV scan, no process kill, no antimalware) for the WSL2 logical device. If a ticket asks "why can't I isolate this WSL container," the answer is "you can't — that's by design," not a bug. Also: a WSL2 instance that ran for **less than ~30 minutes never shows up in the portal at all** — this is the single most common "the plug-in isn't working" false alarm.

Run these first, in this order (from an elevated Command Prompt/PowerShell on the Windows host):

```powershell
# 1 — Confirm WSL version meets the plug-in floor (2.0.7.0+)
wsl --version

# 2 — Confirm the Windows host itself is onboarded to MDE (plug-in piggybacks on this)
Get-Service Sense | Select-Object Name, Status, StartType

# 3 — Run the plug-in's own health check (most authoritative single signal)
cd "$env:ProgramFiles\Microsoft Defender for Endpoint plug-in for WSL\tools"
.\healthcheck.exe

# 4 — Confirm at least one distro is actually running (plug-in requires an active distro)
wsl -l -v

# 5 — Check install directories exist at all (confirms MSI actually installed)
Test-Path "$env:ProgramFiles\Microsoft Defender for Endpoint plug-in for WSL\plug-in\DefenderforEndpointPlug-in.dll"
```

| Symptom | Likely cause | Go to |
|---------|-------------|-------|
| `healthcheck.exe` says "Launch WSL distro with 'bash' command and retry in five minutes" | Normal startup timing — no distro has been started yet, or too recently | Fix 1 |
| `healthcheck.exe` says "Waiting for Telemetry. Please retry in five minutes" | Normal startup timing — telemetry pipeline still initializing | Fix 1 |
| WSL2 instance never appears in Microsoft Defender portal device inventory | Distro ran for less than ~30 minutes, or plug-in not installed/onboarded yet | Fix 2 |
| Launching `wsl` throws `ERROR_FILE_NOT_FOUND` referencing `DefenderforEndpointPlug-in` | Faulty/corrupt plug-in install | Fix 3 |
| `healthcheck.exe` connectivity test reports `invalid` | Proxy misconfiguration or DNS/networking mode issue between WSL2 and Defender cloud service URLs | Fix 4 |
| Requester wants Isolate Device / AV Scan / Live Response / process kill on the WSL2 device object | Not supported — WSL2 logical device is monitoring/investigation/alerting only | Fix 5 |
| A distro's events/alerts never appear even after 30+ min uptime and a "Healthy" health check | Distro is running under **WSL1**, not WSL2 — plug-in only instruments WSL2 | Fix 6 |
| Custom kernel or custom kernel command line in use on a distro; visibility seems incomplete | Unsupported configuration — plug-in doesn't block it but doesn't guarantee visibility either | Fix 7 |
| Needs a non-default device tag in the portal for this host's WSL2 entries | No custom tag configured — default tag is always `WSL2` | Fix 8 |

---
## Dependency Cascade

<details><summary>What must be true for the WSL plug-in to report data</summary>

```
[Windows 10 2004+ (19044+) or Windows 11 host, non-ARM64, non-multi-session]
    └── [Host already onboarded to Microsoft Defender for Endpoint Plan 2]
            └── [WSL 2.0.7.0+ installed, at least one distro running under WSL2 (not WSL1)]
                    └── [Defender for Endpoint plug-in for WSL MSI installed
                         (downloaded from Defender portal onboarding page)]
                            └── [Plug-in auto-onboards to the SAME tenant as the
                                 Windows host — no separate onboarding step]
                                    ├── ~5 min: plug-in fully initializes
                                    └── ~30 min: WSL2 instance registers as a
                                         device in the Defender portal
                                            └── [Distro must stay running 30+ min
                                                 to actually appear — short-lived
                                                 containers may NEVER show up]
```

Everything upstream of "plug-in installed" is a normal WSL2/host prerequisite unrelated to Defender. Everything downstream of "auto-onboards" is timing, not configuration — most "it's not showing up" tickets are closed by simply waiting or keeping the distro alive longer.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm host onboarding first.** The plug-in rides on the host's own MDE onboarding — if `Get-Service Sense` isn't running, fix host onboarding before touching the plug-in at all (see `MDE-Onboarding-A.md`).

2. **Confirm WSL2 (not WSL1) and version floor.**
   ```powershell
   wsl --version
   wsl -l -v
   ```
   Expected: `2.0.7.0` or later, and the target distro's `VERSION` column shows `2`. If it shows `1`, that distro will never report — see Fix 6.

3. **Run `healthcheck.exe` and read all four fields.**
   ```powershell
   cd "$env:ProgramFiles\Microsoft Defender for Endpoint plug-in for WSL\tools"
   .\healthcheck.exe
   ```
   Expect: Plug-in Version `1.24.522.2`+, WSL Version `2.0.7.0`+, Defender App Version `101.24032.0007`+, Defender Health Status `Healthy`. Anything short of "Healthy" points at connectivity (Fix 4) or a corrupt install (Fix 3).

4. **Check the portal with the right filter.** Devices view > filter tag `WSL2`. Confirm sufficient wait time (up to 10 minutes for the machine object, up to 30 minutes total for the instance) before treating an absence as a real problem.

5. **Confirm HostDeviceId mapping via Advanced Hunting** (ties the WSL2 device object back to its Windows host — useful when multiple hosts/devices make portal identification ambiguous):
   ```kusto
   DeviceInfo
   | where OSPlatform == "Linux" and isnotempty(HostDeviceId)
   | distinct WSLDeviceId=DeviceId, HostDeviceId
   ```

---
## Common Fix Paths

<details><summary>Fix 1 — "Retry in five minutes" health check messages</summary>

These are not errors — they're the plug-in's own startup-timing messages.

```powershell
# Start a distro if none is running
wsl

# Wait 5 minutes, then re-run
cd "$env:ProgramFiles\Microsoft Defender for Endpoint plug-in for WSL\tools"
.\healthcheck.exe
```
No rollback needed — this is expected behavior, not a fault.
</details>

<details><summary>Fix 2 — WSL2 instance never appears in the portal</summary>

```powershell
# 1. Confirm the plug-in is actually installed
Test-Path "$env:ProgramFiles\Microsoft Defender for Endpoint plug-in for WSL\plug-in\DefenderforEndpointPlug-in.dll"

# 2. If not installed, download the MSI from the Defender portal:
#    security.microsoft.com > Settings > Endpoints > Onboarding >
#    select platform "Windows Subsystem for Linux 2 (plug-in)" > Download package
# Then install it (or deploy via Intune as a Win32/LOB app):
# msiexec /i DefenderPlugin-x64-<version>.msi /qn

# 3. If already installed, keep a distro running continuously for 30+ minutes,
#    then re-check the portal filtered on tag "WSL2"
wsl
Start-Sleep -Seconds 1800
```
Rollback: none — install-only operation, no destructive change.
</details>

<details><summary>Fix 3 — Faulty install (ERROR_FILE_NOT_FOUND on launch)</summary>

```powershell
# Repair via Programs and Features (GUI):
# Control Panel > Programs > Programs and Features >
#   "Microsoft Defender for Endpoint plug-in for WSL" > Repair

# Or force a clean reinstall from an elevated prompt:
msiexec /x "Microsoft Defender for Endpoint plug-in for WSL" /qn
wsl --shutdown
msiexec /i "<path-to-latest-DefenderPlugin-x64-msi>" /qn
wsl
```
Rollback: uninstalling the plug-in only removes WSL2 visibility — it does not affect the Windows host's own MDE onboarding or protection.
</details>

<details><summary>Fix 4 — Connectivity test reports "invalid"</summary>

```powershell
# 1. Get detailed proxy diagnosis
cd "$env:ProgramFiles\Microsoft Defender for Endpoint plug-in for WSL\tools"
.\healthcheck.exe --extendedProxy

# 2. If unresolved, edit %UserProfile%\.wslconfig
# --- Windows 11: enable DNS tunneling + mirrored networking ---
# [wsl2]
# dnsTunneling=true
# networkingMode=mirrored
#
# --- Windows 10: disable the DNS proxy instead ---
# [wsl2]
# dnsProxy=false

wsl --shutdown
wsl
.\healthcheck.exe
```
Note: the plug-in only supports **http** proxies, and it auto-inherits the host's EDR telemetry proxy / WinHTTP proxy / Network & Internet proxy in that priority order — do not assume a separate proxy configuration is needed unless this diagnostic step says otherwise. The `DefenderProxyServer` and `ConnectivityTest` registry keys referenced in older internal notes are **no longer supported** — don't waste time on them.

Rollback: revert `.wslconfig` changes and `wsl --shutdown` / `wsl` to restart clean.
</details>

<details><summary>Fix 5 — Requester wants response actions on the WSL2 device</summary>

No fix — set expectations. The WSL2 logical device supports **monitoring, investigation, and alerting only** (file, process, network telemetry; timeline; alerts/incidents). Antimalware, threat & vulnerability management, and response commands (isolate, AV scan, live response actions) are **not available** on this device type. If containment is genuinely required, isolate the **Windows host** instead — the host is a normal, fully capable MDE device.
</details>

<details><summary>Fix 6 — Distro is on WSL1, not WSL2</summary>

```powershell
# Check versions per distro
wsl -l -v

# Upgrade a specific distro to WSL2
wsl --set-version <YourDistroName> 2

# Make WSL2 the default for all future distros
wsl --set-default-version 2
```
To prevent recurrence fleet-wide, block WSL1 via Intune: **Devices > Configuration Profiles > Create > Windows 10 and later > Settings catalog** — search "Windows Subsystem for Linux," set **Allow WSL1** to **Disabled**.

Rollback: `wsl --set-version <DistroName> 1` reverts a single distro (loses plug-in visibility for it again).
</details>

<details><summary>Fix 7 — Custom kernel / custom kernel command line in use</summary>

No supported fix to restore guaranteed visibility while keeping the custom kernel — this is a documented, permanent limitation, not a bug to chase. Two options:

1. Remove the custom kernel/kernelCommandLine settings from `.wslconfig` and revert to the stock WSL2 kernel.
2. If the custom kernel is a business requirement, accept reduced/undefined visibility for that distro and document the exception — or block custom kernel configuration fleet-wide via the same Intune WSL Settings Catalog area referenced in Fix 6.
</details>

<details><summary>Fix 8 — Need a custom device tag instead of the default "WSL2"</summary>

```powershell
# Create the registry value (elevated)
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging" -Name "GROUP" -Value "<CustomTag>" -PropertyType String -Force

# Restart WSL to apply
wsl --shutdown
wsl

# Wait 5-10 minutes for the portal to reflect the change
```
Note: the value you set is automatically suffixed with `_WSL2` in the portal (e.g. `GROUP=Contoso` → tag shows as `Contoso_WSL2`). Rollback: delete the `GROUP` registry value and repeat the `wsl --shutdown` / `wsl` cycle to return to the default `WSL2` tag.
</details>

---
## Escalation Evidence

```
=== MDE Plug-in for WSL — Escalation Template ===
Windows host device name / MDE device ID:
Windows OS build:                          [winver / Get-ComputerInfo OsBuildNumber]
WSL version (wsl --version):
Distro name(s) + WSL version (wsl -l -v):
Plug-in installed? (Test-Path check):
healthcheck.exe output (all 4 fields):
  Plug-in Version:
  WSL Version:
  Defender App Version:
  Defender Health Status:
Connectivity test result (invalid/valid):
Support bundle generated? (healthcheck.exe --supportBundle) [path]:
Portal: device visible under tag WSL2? (Y/N, screenshot):
Time distro has been continuously running when checked:
Proxy in use (EDR telemetry / WinHTTP / Network&Internet / none):
Custom kernel or kernelCommandLine configured in .wslconfig? (Y/N):
```

---
## 🎓 Learning Pointers

- The plug-in is a **visibility-only** extension — it never adds response-action capability to the WSL2 device object. Set that expectation with requesters up front; it prevents most escalations on this topic before they start. [Defender for Endpoint plug-in for WSL](https://learn.microsoft.com/en-us/defender-endpoint/mde-plugin-wsl)
- **30 minutes is the real floor**, not a suggestion — a distro that never runs that long simply never registers as a device. This explains the large majority of "the plug-in isn't working" tickets that turn out to need no fix at all.
- The plug-in **auto-onboards to whatever tenant the Windows host is onboarded to** — there is no separate onboarding step, license check, or portal action to onboard the WSL2 subsystem independently. If the host is in the wrong tenant, so is every WSL2 device under it.
- `DefenderProxyServer` and `ConnectivityTest` registry keys are **deprecated** — if a runbook, blog post, or old internal note references them, treat that source as stale.
- This is a distinct control surface from `AIAgentRuntimeProtection-B.md`'s Codex CLI/agent coverage and from `LocalAIAgentDiscovery-B.md` — those inspect AI-agent process behavior on the Windows host itself; this plug-in inspects the WSL2 Linux subsystem's own file/process/network activity. Don't conflate the two when scoping "what does Defender see on this dev box."
