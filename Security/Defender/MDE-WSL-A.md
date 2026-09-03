# Defender for Endpoint Plug-in for WSL — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers the **Microsoft Defender for Endpoint plug-in for Windows Subsystem for Linux (WSL) 2**, applicable to tenants licensed for **Defender for Endpoint Plan 2**. It assumes:

- The Windows 10 (2004+, build 19044+) or Windows 11 host is already onboarded to Defender for Endpoint — this plug-in has no independent onboarding path and cannot function without a healthy host `Sense` service.
- WSL 2 is installed and at least one distribution is running (or intended to run) under WSL2, not the legacy WSL1 architecture.
- The host is **not** ARM64 and **not** a multi-session Windows variant (e.g. Windows 365/AVD multi-session) — the plug-in is unsupported on both.

Out of scope: native (pre-plug-in) Defender for Endpoint on Linux running as a standalone Linux server/VM (see the general Linux onboarding path, distinct architecture, distinct package); Defender Antivirus running natively on the Windows host (unaffected by this plug-in either way); container security scanning products aimed at Docker/Kubernetes workloads (a different product surface, not WSL-specific).

---
## How It Works

<details><summary>Full architecture</summary>

WSL2 is architecturally a **lightweight Hyper-V-backed virtual machine** running a real Linux kernel, distinct from WSL1's translation-layer approach. Because each WSL2 distro runs inside an isolated virtualized subsystem rather than as ordinary Windows processes, the Windows host's own Defender for Endpoint sensor has no native visibility into what happens *inside* that subsystem — file writes, process execution, and network activity occurring inside a WSL2 distro are invisible to the host sensor by default.

The plug-in solves this by **installing directly into the WSL2 virtualized subsystem itself**, not just onto the Windows host filesystem. On install, it deploys `DefenderforEndpointPlug-in.dll` (loaded by WSL's plugin-loading mechanism) plus a `healthcheck.exe` diagnostic tool. When any WSL distro next starts, the plug-in loads inside that subsystem and begins collecting file, process, and network telemetry from *inside* the Linux environment — the same signal categories Defender for Endpoint on Linux would collect on a standalone Linux host, but sourced from within the virtualized WSL2 kernel rather than bare metal.

```
┌─────────────────────────────────────────────────────────┐
│  Windows 10/11 Host (already onboarded to MDE)          │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Sense (host EDR sensor) — Windows-side telemetry  │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │  WSL2 (Hyper-V-backed lightweight VM)              │  │
│  │  ┌─────────────────────────────────────────────┐  │  │
│  │  │  Linux distro (e.g. Ubuntu)                  │  │  │
│  │  │  ┌───────────────────────────────────────┐  │  │  │
│  │  │  │ DefenderforEndpointPlug-in.dll          │  │  │  │
│  │  │  │ (loaded into the WSL2 subsystem itself) │  │  │  │
│  │  │  │  → file / process / network telemetry   │  │  │  │
│  │  │  └───────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
                        │
                        ▼  (auto-onboards to same tenant as host)
        Microsoft Defender portal (security.microsoft.com)
        WSL2 instance appears as a SEPARATE Linux "device" object,
        tagged WSL2, hostname matching the Windows host,
        with a "hosting" link back to the Windows host device.
```

The critical architectural decision Microsoft made here is that **each WSL2 instance registers as its own logical device object** in the portal — not as a sub-property of the Windows host device. This is why Advanced Hunting needs the `HostDeviceId` attribute on `DeviceInfo` to programmatically re-associate a WSL2 device back to its physical/virtual Windows host; without it, an analyst looking at a `DeviceId` for a Linux OS-platform device would have no way to know which Windows machine it actually lives inside.

Because the subsystem is virtualized and effectively spun up fresh (or resumed) each time WSL starts, there's an inherent bootstrap delay: the plug-in itself takes ~5 minutes to fully initialize after a distro starts, and the device object doesn't reliably materialize in the portal until the distro has been running for **at least ~30 minutes**. This is not a bug or slow telemetry pipeline — it's a deliberate registration threshold that filters out extremely short-lived container/dev-environment usage from generating noisy, low-value device churn in the portal.

</details>

---
## Dependency Stack

```
Layer 5:  Microsoft Defender portal device inventory & Advanced Hunting
              (WSL2 shows as its own Linux "device"; HostDeviceId links it to the host)
Layer 4:  Defender for Endpoint cloud service (tenant the host is onboarded to)
              (plug-in auto-onboards here — no separate tenant selection exists)
Layer 3:  Defender for Endpoint plug-in for WSL (DefenderforEndpointPlug-in.dll)
              (loaded into the WSL2 subsystem when a distro starts; healthcheck.exe
               is the local diagnostic surface)
Layer 2:  WSL 2 subsystem (2.0.7.0+), running an active distro under WSL2 (not WSL1)
              (Hyper-V-backed lightweight VM; custom kernel/cmdline = unsupported
               for guaranteed visibility)
Layer 1:  Windows 10 (2004+/19044+) or Windows 11 host — non-ARM64, non-multi-session
              (host must already be onboarded to MDE Plan 2 — Sense service healthy)
```

A break at any layer below the plug-in (Layer 2 or Layer 1) makes the plug-in layer irrelevant — always validate bottom-up.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No WSL2 device ever appears in portal, on any host | Plug-in not installed anywhere, or hosts not onboarded to MDE | `Test-Path` for plug-in DLL; `Get-Service Sense` |
| One specific distro never appears, others on same host do | That distro is WSL1, or never runs 30+ minutes continuously | `wsl -l -v`; distro uptime pattern |
| `healthcheck.exe` reports unhealthy Defender status but host itself shows healthy in portal | Plug-in-to-cloud connectivity issue distinct from host sensor health | `healthcheck.exe --extendedProxy` |
| Alerts fire for host-level activity but never for anything run inside a distro | Plug-in not loaded/functioning even though installed (silent load failure) | `healthcheck.exe`; reinstall/repair |
| Analyst can't tell which Windows host a WSL2 alert belongs to | Working as designed — must join on `HostDeviceId`, it's not automatic in the base alert view | Advanced Hunting query with `HostDeviceId` join |
| Response action (isolate/AV scan) attempted against WSL2 device fails or is greyed out | Expected — WSL2 logical device doesn't support response actions | No fix; act on host device instead |
| Custom-kernel dev environment shows partial/no telemetry despite "Healthy" health check | Documented unsupported configuration — visibility not guaranteed with custom kernel | `.wslconfig` review for kernel/kernelCommandLine keys |

---
## Validation Steps

1. **Host onboarding is healthy.**
   ```powershell
   Get-Service Sense | Select-Object Name, Status, StartType
   ```
   Good: `Running` / `Automatic`. Bad: service missing, stopped, or disabled — resolve via `MDE-Onboarding-A.md` before proceeding.

2. **WSL2 version and distro state.**
   ```powershell
   wsl --version
   wsl -l -v
   ```
   Good: WSL version `2.0.7.0`+, target distro's `VERSION` column = `2`. Bad: version below floor (run `wsl --update`, or `wsl --update --pre-release` if still below floor after a normal update), or `VERSION` = `1`.

3. **Plug-in installation footprint.**
   ```powershell
   Test-Path "$env:ProgramFiles\Microsoft Defender for Endpoint plug-in for WSL\plug-in\DefenderforEndpointPlug-in.dll"
   Test-Path "$env:ProgramFiles\Microsoft Defender for Endpoint plug-in for WSL\tools\healthcheck.exe"
   ```
   Good: both `True`. Bad: either `False` — plug-in never installed or partially removed; reinstall from the Defender portal onboarding page.

4. **Plug-in self-reported health.**
   ```powershell
   cd "$env:ProgramFiles\Microsoft Defender for Endpoint plug-in for WSL\tools"
   .\healthcheck.exe
   ```
   Good: `Defender Health Status: Healthy`, all four version fields at or above floor. Bad: any non-Healthy status, or a "retry in five minutes" message that persists after 15+ minutes of a running distro.

5. **Portal registration.**
   Devices > All devices > filter tag `WSL2`. Good: device present, hostname matches Windows host, "hosting" link on the device Overview pane correctly points to that host. Bad: absent after 30+ minutes of continuous distro runtime with a Healthy local health check — escalate as a genuine registration failure (Evidence Pack).

6. **Cross-reference via Advanced Hunting.**
   ```kusto
   DeviceInfo
   | where OSPlatform == "Linux" and isnotempty(HostDeviceId)
   | distinct WSLDeviceId=DeviceId, HostDeviceId
   ```
   Good: a row exists mapping the expected WSL2 `DeviceId` to the expected Windows host `DeviceId`. Bad: no row — either the WSL2 device never registered, or `HostDeviceId` population is delayed (re-check after another sync cycle).

---
## Troubleshooting Steps (by phase)

**Phase 1 — Host & WSL prerequisites.** Confirm Layer 1 and Layer 2 of the Dependency Stack independently of Defender entirely: host OS build/architecture support, WSL version floor, at least one distro running under WSL2. Most "plug-in doesn't work" tickets that turn out to be prerequisite gaps are caught here.

**Phase 2 — Installation integrity.** Confirm the plug-in DLL and healthcheck tool are actually present and unmodified since install. A partial install (interrupted MSI, disk cleanup tooling that touched `%ProgramFiles%`) produces the `ERROR_FILE_NOT_FOUND` failure mode on `wsl` launch — repair via Programs and Features or a clean reinstall.

**Phase 3 — Local health & connectivity.** Run `healthcheck.exe`, and if the Defender Health Status or connectivity test is unhealthy, run `healthcheck.exe --extendedProxy` before touching `.wslconfig` — the extended proxy diagnostic frequently identifies the exact failing proxy layer (static TelemetryProxyServer vs. WinHTTP vs. Network & Internet) without guesswork.

**Phase 4 — Portal registration & cross-device correlation.** Once local health is confirmed Healthy, allow the full 30-minute registration window before escalating an absence. Use the `HostDeviceId` Advanced Hunting join for any workflow (SOAR, reporting, ticket automation) that needs to programmatically resolve WSL2 alerts back to a specific physical/virtual asset owner.

**Phase 5 — Deep escalation.** If Phases 1-4 are all green but the portal still shows no data or persistently unhealthy status, collect a support bundle (`healthcheck.exe --supportBundle`) and networking logs (`collect-networking-logs.ps1` from the WSL diagnostics repo) before opening a Microsoft support case — these are the two artifacts support will ask for first.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide rollout of the WSL plug-in to developer workstations</summary>

1. Identify the target population: hosts already onboarded to MDE Plan 2, running Windows 10 2004+/19044+ or Windows 11, non-ARM64, non-multi-session, with WSL2 in active use (a reasonable proxy: presence of `wsl.exe` process history or the `WSL2` feature enabled via `Get-WindowsOptionalFeature`).
2. Download the plug-in MSI once from the Defender portal (Settings > Endpoints > Onboarding > select "Windows Subsystem for Linux 2 (plug-in)").
3. Package and deploy via Intune as a Win32/LOB app (`intune-service/apps/lob-apps-windows`) targeted at the identified population, rather than manual per-machine installs.
4. Pilot on a small cohort first — confirm `healthcheck.exe` reports Healthy and the device registers in the portal within 30-40 minutes before scaling to the full fleet.
5. Optionally, apply a Windows Settings Catalog policy disabling WSL1 (**Allow WSL1 = Disabled**) alongside the plug-in rollout, since WSL1 distros are invisible to the plug-in regardless of install state — this closes the most common post-rollout "it's still not showing up" gap.
6. Document the rollout cohort and rollout date for future audit reference, since there's no portal-level historical log distinguishing "never installed" from "installed but not yet reporting."

Rollback: uninstall the MSI (`msiexec /x`) per machine, or remove the Win32 app assignment in Intune. Removing the plug-in has no effect on the Windows host's own MDE protection or onboarding status.

</details>

<details><summary>Playbook 2 — Investigating a suspected compromise inside a WSL2 distro</summary>

1. Identify the WSL2 device object in the portal (filter tag `WSL2`, or resolve via the `HostDeviceId` Advanced Hunting join from the known Windows host).
2. Review the device timeline for file, process, and network events — treat this identically to investigating a standalone Linux host, since the plug-in sources the same telemetry categories.
3. **Remember the response-action ceiling**: you cannot isolate, AV-scan, or run response commands against the WSL2 device object itself. If containment is required, isolate the **Windows host** — this also suspends the WSL2 subsystem running inside it, since WSL2 is a child virtualized environment of the host.
4. Use Live Response or direct host access to inspect/remediate inside the distro manually (e.g. `wsl` shell access from the host), since no remote response-action channel exists for the WSL2 device object.
5. After remediation, confirm the WSL2 device's timeline shows no further suspicious activity, and consider whether the underlying Windows host itself also needs investigation (a compromised WSL2 distro doesn't automatically imply host compromise, but shared kernel/network context makes it worth ruling out).

Rollback: not applicable — this is an investigative playbook, not a configuration change.

</details>

---
## Evidence Pack

```kusto
// MDE Plug-in for WSL — Evidence Pack
// Run in security.microsoft.com > Advanced hunting

// 1. All WSL2 device IDs in the tenant, mapped to their Windows host
DeviceInfo
| where OSPlatform == "Linux" and isnotempty(HostDeviceId)
| distinct WSLDeviceId=DeviceId, HostDeviceId

// 2. Recent process activity inside a specific WSL2 instance
DeviceProcessEvents
| where DeviceId == "<wslDeviceId>"
| order by Timestamp desc
| take 100

// 3. Flag WSL2 devices where curl/wget executed (common exfil/download vector check)
let wsl_endpoints = DeviceInfo
    | where OSPlatform == "Linux" and isnotempty(HostDeviceId)
    | distinct DeviceId;
DeviceProcessEvents
| where FileName in ("curl", "wget")
| where DeviceId in (wsl_endpoints)
| sort by Timestamp desc
```

```powershell
# Local host-side supporting evidence
Get-Service Sense | Select-Object Name, Status, StartType
wsl --version
wsl -l -v
Test-Path "$env:ProgramFiles\Microsoft Defender for Endpoint plug-in for WSL\plug-in\DefenderforEndpointPlug-in.dll"
& "$env:ProgramFiles\Microsoft Defender for Endpoint plug-in for WSL\tools\healthcheck.exe" --supportBundle
```

---
## Command Cheat Sheet

| Purpose | Command / Location |
|---|---|
| Check WSL version | `wsl --version` |
| Update WSL | `wsl --update` (or `wsl --update --pre-release` if still below floor) |
| List distros + WSL version each | `wsl -l -v` |
| Upgrade one distro to WSL2 | `wsl --set-version <Name> 2` |
| Set WSL2 as default for new distros | `wsl --set-default-version 2` |
| Run plug-in health check | `healthcheck.exe` (in plug-in `tools` dir) |
| Extended proxy diagnostic | `healthcheck.exe --extendedProxy` |
| Generate support bundle | `healthcheck.exe --supportBundle` |
| Restart WSL cleanly | `wsl --shutdown` then `wsl` |
| Confirm host MDE onboarding | `Get-Service Sense` |
| Download plug-in MSI | Defender portal > Settings > Endpoints > Onboarding > "Windows Subsystem for Linux 2 (plug-in)" |
| Advanced Hunting host mapping | `DeviceInfo \| where OSPlatform == "Linux" and isnotempty(HostDeviceId)` |
| Block WSL1 fleet-wide | Intune Settings Catalog > "Windows Subsystem for Linux" > **Allow WSL1 = Disabled** |
| Set custom device tag | Registry `HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging`, value `GROUP` |
| Override plug-in release ring | Registry `HKLM:\SOFTWARE\Microsoft\Microsoft Defender for Endpoint plug-in for WSL`, value `OverrideReleaseRing` |

---
## 🎓 Learning Pointers

- The plug-in loads **inside the virtualized WSL2 subsystem itself**, not just onto the Windows host filesystem — this is why it needs a running distro to activate, and why a distro's uptime (not just its existence) governs whether it ever appears in the portal. [Defender for Endpoint plug-in for WSL](https://learn.microsoft.com/en-us/defender-endpoint/mde-plugin-wsl)
- Each WSL2 instance is a **separate device object** in the portal, joined back to its Windows host only via the `HostDeviceId` attribute on `DeviceInfo` — any reporting, SOAR playbook, or dashboard built against WSL2 telemetry needs that join baked in, or alerts will show as orphaned Linux devices with no obvious owner.
- The **response-action ceiling is architectural, not a licensing gap** — no Defender for Endpoint plan or add-on restores isolate/AV-scan/live-response-command capability to a WSL2 device object. Plan containment procedures around isolating the Windows host instead.
- WSL1 is **invisible to the plug-in by design** — this is a common latent gap in "why isn't this dev machine reporting" investigations, since many developers have long-lived WSL1 distros from before WSL2 became default, unnoticed until this exact troubleshooting scenario surfaces it.
- Automatic update support depends on plug-in version: **pre-`1.24.522.2` builds don't self-update at all**; `1.24.522.2`+ updates via Windows Update on all rings, but WSUS/SCCM/Microsoft Update catalog delivery is Production-ring only — a fleet pinned to a non-Production ring via WSUS/SCCM will silently stop receiving plug-in updates through that channel.
- This plug-in is a narrower, complementary control to `LocalAIAgentDiscovery-A.md`'s June 2026 macOS/agent-inventory expansion — both extend Defender visibility into non-native-Windows execution contexts, but this one is WSL2-specific telemetry, not AI-agent-specific behavioral inspection.
