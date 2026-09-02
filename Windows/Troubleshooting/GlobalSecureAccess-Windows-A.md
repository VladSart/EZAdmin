# Global Secure Access Client (Windows) — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- The **Windows-specific** Global Secure Access (GSA) client: install/upgrade mechanics, the Windows services the client runs, health check tests, log collection, and the Windows-only feature surface (NRPT rules, Hyper-V interaction, coexistence with Azure VPN/Netskope, per-app vs. system-wide behavior)
- The upcoming **automatic-upgrade-via-Windows-Update model** (starting November 2026 for clients at or above version 2.31.125 / 2.32.294 on Arm) and how to opt out of it
- The **Prefer Local Network** setting (added in client v2.32.294, August 2026) for overlapping local/private-application subnet scenarios (printing, casting)
- The client's Forwarding Profile Service (the renamed successor to the Policy Retriever Service) and its automatic-restart-on-failure behavior
- Client version history mechanics relevant to troubleshooting a "this used to work" ticket — which functional changes shipped in which version

**Does not cover:**
- **Tenant-level Global Secure Access configuration** — traffic forwarding profiles, Conditional Access-based Global Secure Access policies, Private Access application publishing, or the Internet Access/Private Access licensing model. See `EntraID/Troubleshooting/GlobalSecureAccess-A.md`/`-B.md` for the tenant-side/cross-platform architecture; this file assumes a forwarding profile is already correctly configured and focuses purely on the Windows client's own behavior.
- **macOS-specific GSA client mechanics** (system extension activation, Transparent Proxy service, macOS 26 compatibility floor) — see `macOS/Troubleshooting/GlobalSecureAccess-macOS-A.md`/`-B.md`. The two clients share the same cloud-side forwarding profile concept but have almost entirely separate installation, service, and diagnostic mechanics.
- **iOS/Android GSA client specifics** — each has its own separate deployment mechanics, not covered here or in the macOS file.
- **Global Secure Access licensing/cost** — see `EntraID/Troubleshooting/EntraSuiteLicensing-A.md`/`-B.md`.
- **Legacy on-prem Application Proxy-only publishing** — a related but distinct mechanism; see `EntraID/Troubleshooting/AppProxy-A.md`/`-B.md`.

**Assumes:**
- A Microsoft Entra tenant already has at least one Global Secure Access traffic forwarding profile enabled (Microsoft 365, Private Access, and/or Internet Access) — this file troubleshoots the client's ability to honor that profile, not the profile's own configuration
- Windows devices are either Microsoft Entra-joined, Entra hybrid-joined, or Entra-registered (BYOD, preview support since client v2.26.108)
- Deployment via MDM (Intune) or manual installer execution — both are covered

---
## How It Works

<details><summary>Full architecture — the Windows client model</summary>

### Two Windows services, one renamed mid-flight

The GSA Windows client runs as a set of Windows services, and their names have changed across versions — a genuine source of confusion when following older documentation or forum posts against a current install:

- **Global Secure Access Engine Service** (originally "Global Secure Access Management Service," renamed in client v2.8.45) — the core tunneling/traffic-forwarding engine.
- **Global Secure Access Forwarding Profile Service** (introduced in client v2.22.90, *replacing* the earlier "Global Secure Access Policy Retriever Service," which was itself a rename of the original "Global Secure Access Auto Upgrade Service" from v2.8.45) — responsible for pulling the current forwarding profile from the Global Secure Access cloud service. As of client v2.31.125, this service is configured to **automatically restart on failure** — a meaningful resilience improvement over earlier versions, where a crashed Policy Retriever Service silently stopped picking up profile updates until a manual restart or reboot.

When a customer or an older internal note references the "Policy Retriever Service" or "Auto Upgrade Service" by name, translate to the current service name before troubleshooting — `Get-Service` will not return a match on the old name.

### Forwarding profile retrieval — polling, sign-in triggers, and manual refresh

The client's forwarding profile isn't purely push-based. It updates via: the service's own polling cycle, an explicit **Get policy** button in the client UI (client v2.22.90+) that polls the cloud service on demand, and a forced refresh triggered whenever a user signs in to Windows (client v2.8.45+). Interactive sign-in support for the policy pull itself (client v2.22.90+) also means a policy requiring MFA or Terms of Use acceptance can now prompt interactively rather than silently failing to apply.

### Automatic upgrades via Windows Update — a genuine architecture change, not just a delivery-channel switch

Starting **November 2026**, the GSA client for Windows begins receiving upgrades through Windows Update itself, for devices already running client version **2.31.125 (x64)** or **2.32.294 (Windows on Arm)** or later. Below those versions, a device is not eligible for the new delivery mechanism and continues on whatever manual/MDM-driven upgrade process was already in place — there is no forced jump to the new model for an old client; it has to already be current enough to opt in.

**Opting out** requires a specific installer parameter set at install or upgrade time, run from a command line or deployed via MDM:
```cmd
<Global Secure Access installer file> /quiet /norestart EnableWindowsUpdates=0
```
An organization that opts out takes on full responsibility for keeping the client current on those devices — Microsoft is explicit that opted-out devices do not receive the latest features, fixes, or security updates automatically. This is a per-install-invocation setting, not a tenant-wide policy switch — a fleet with mixed deployment history can have some devices opted in and others opted out depending on how each was originally installed or last upgraded.

### Prefer Local Network — solving the overlapping-subnet problem

Added in client v2.32.294 (released August 26, 2026): a **Prefer local network** option that appears in client settings only when an administrator enables it. It addresses a specific, previously undocumented failure mode: when a user's current local network subnet happens to overlap with the address space of a Private Access application, traffic that should stay local (printing to a nearby printer, casting to a nearby display) could get tunneled through Global Secure Access instead — breaking the local-only functionality. Enabling this option lets the client correctly prefer the genuinely local resource over the tunneled one when the address spaces collide.

### Intelligent Local Access — the adjacent, related feature

Separate from Prefer Local Network but conceptually related: **Intelligent Local Access** (ILA, introduced client v2.24.117, enhanced through v2.28.96 and v2.31.125) lets Private Access applications be assigned to specific private networks and shows connection-state indicators (an information bar noting when the device is connected to a private network) in the client's Connections tab. ILA governs *which* private network a Private Access app is reached through; Prefer Local Network governs a narrower, specific overlap-address-space conflict on top of that.

### Coexistence with other network software

The client documents explicit coexistence support with **Azure VPN** (since v2.1.149) and **Netskope** (since v2.1.102), and specific behavior for **Hyper-V**: installing the GSA client on a Hyper-V host with an **internal** virtual switch causes the client to bypass network traffic from Hyper-V guest VMs (the host-level client doesn't need to also run inside each guest). Critically, **the client does not support Hyper-V host machines using an external virtual switch** — for that topology, the client must be installed inside the guest machine(s) directly, the host, or both, rather than relying on host-level bypass.

### Single-session limitation

As of client v2.31.125, a **Single Windows user session detected** health check test exists specifically because the client currently supports only one interactive Windows session at a time. On a multi-session host (e.g., via Remote Desktop Services or fast user switching), only one session's traffic is actually being tunneled/protected — this is a documented product limitation, not a misconfiguration, and the health check test exists precisely to surface it rather than let it fail silently.

</details>

---
## Dependency Stack

```
Layer 6 — Windows Update delivery eligibility (client v2.31.125+/2.32.294+ Arm)
          — governs WHETHER this device receives future upgrades automatically
                starting November 2026; below this floor, upgrades stay manual/MDM
Layer 5 — Installation / enrollment
          ├─ Device is Entra-joined, Entra hybrid-joined, or Entra-registered (BYOD)
          └─ Client installed via MDM (Intune Win32 app) or manual installer run
Layer 4 — Windows services (name history matters for older references)
          ├─ Global Secure Access Engine Service (core tunneling engine)
          └─ Global Secure Access Forwarding Profile Service (profile retrieval;
                auto-restart-on-failure since v2.31.125)
Layer 3 — Authentication & tenant sign-in
          └─ User/device signed in to the correct Entra tenant; account-picker
                and multi-tenant sign-out support since v2.31.125/v2.28.96
Layer 2 — Forwarding profile applied
          ├─ At least one traffic forwarding profile (M365/Private/Internet)
          │       enabled tenant-wide — "Disabled by your organization" is an
          │       expected break-glass state, not a bug
          └─ Profile retrieved via poll cycle, sign-in trigger, or manual
                "Get policy" refresh
Layer 1 — Traffic handling nuances
          ├─ Prefer Local Network (v2.32.294+) resolves overlapping-subnet
          │       conflicts with local resources (printing/casting)
          ├─ Intelligent Local Access governs private-network routing per app
          └─ Hyper-V: internal switch = host-level bypass works; external
                switch = NOT supported, install inside the guest instead
Layer 0 — Session model
          └─ Single interactive Windows session supported at a time — a
                multi-session host only protects one session's traffic
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Client hasn't updated to the latest version despite Windows Update running normally | Client version below the 2.31.125 (x64) / 2.32.294 (Arm) eligibility floor for Windows Update delivery, OR the device was installed/upgraded with `EnableWindowsUpdates=0` | Confirm installed version and installer history; manually upgrade to cross the floor, or remove the opt-out flag on next install |
| Printing to a nearby printer or casting to a local display fails or routes oddly with GSA active | Local subnet overlaps with a Private Access application's address space and Prefer Local Network isn't enabled/available | Confirm client is v2.32.294+ and an admin has enabled the Prefer Local Network option |
| A ticket references "Policy Retriever Service" or "Auto Upgrade Service" and nothing by that name exists | Service was renamed (Auto Upgrade Service → Policy Retriever Service → Forwarding Profile Service across versions) | Check for **Global Secure Access Forwarding Profile Service** under its current name |
| Client silently stops picking up forwarding profile updates until a manual restart | Forwarding Profile Service crashed and (on a pre-2.31.125 client) did not auto-restart | Upgrade to 2.31.125+ for the auto-restart behavior, or manually restart the service as an interim fix |
| GSA tunnels traffic from a Hyper-V guest VM unexpectedly, or doesn't at all | Wrong assumption about which virtual switch type is in use | Internal switch: host-level client bypasses guest traffic automatically. External switch: install the client inside the guest — host-level bypass is NOT supported for external switches |
| Only one of several concurrent Windows sessions on a host appears protected | Client's documented single-interactive-session limitation | Confirm via the "Single Windows user session detected" health check test; this is a product limitation, not a bug, on multi-session hosts |
| User can't find the Sign Out option, or it behaves differently than expected | Sign Out visibility/location changed across versions (system tray → account control in main window; hidden by default on Entra-joined devices since v2.28.96, shown by registry key) | Confirm client version and the relevant registry key for Entra-joined devices if Sign Out needs to be shown |
| MFA/Terms of Use-gated forwarding profile silently never applies | Client version predates interactive sign-in support for policy retrieval (pre-v2.22.90) | Upgrade the client — pre-2.22.90 clients cannot prompt interactively for a policy pull requiring MFA/ToU |

---
## Validation Steps

1. **Installed client version and Windows Update-delivery eligibility.**
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
     Where-Object { $_.DisplayName -match "Global Secure Access" } |
     Select-Object DisplayName, DisplayVersion
   ```
   Expected (for automatic Windows Update delivery starting November 2026): 2.31.125+ on x64, 2.32.294+ on Windows on Arm. Bad: below floor — device stays on manual/MDM upgrade path only.

2. **Both core services present and running.**
   ```powershell
   Get-Service -Name "*Global Secure Access*"
   ```
   Expected: **Global Secure Access Engine Service** and **Global Secure Access Forwarding Profile Service**, both `Running`. Bad: either service `Stopped` or missing entirely (missing suggests an incomplete or very old install still using a pre-rename service name).

3. **Client shows Connected with the expected active channels.**
   Open the client UI → **Connections** tab. Expected: active channels shown in order — Microsoft Entra, Microsoft 365, Private, Internet (per whichever forwarding profiles are enabled) — status not "Disconnected" and network/internet connectivity distinguished correctly. Bad: "Disconnected," or channels missing that should be active per the tenant's forwarding profile configuration.

4. **Health check tests pass, top to bottom.**
   Client UI → Advanced Diagnostics → Health Check tab. Expected: all applicable tests pass; note the "Single Windows user session detected" test specifically if the host supports multiple concurrent sessions. Bad: a failing test earlier in the dependency chain (see Dependency Stack) — resolve top-down since later tests often depend on earlier ones.

5. **Prefer Local Network is enabled where relevant (v2.32.294+ only).**
   Client Settings → confirm the option is visible and enabled if the tenant has overlapping local/private-application address spaces in play. Bad: option not visible (client below v2.32.294, or the admin-side enablement hasn't been configured).

6. **NRPT rules are consistent with expected DNS behavior.**
   ```powershell
   Get-DnsClientNrptPolicy
   ```
   Expected: rules present and consistent with the tenant's Private Access DNS configuration. Bad: stale rules left over after a "Disable Private Access" cycle on an older client (cleanup behavior for this was added in v2.20.56) — a lingering rule from a much older client version can misroute DNS.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm client version first, always.**
A large fraction of "why doesn't this work like the documentation/another device" tickets trace directly to a version gap — service names, UI locations, and entire features (Prefer Local Network, Windows Update delivery, interactive policy sign-in) are all version-gated.

**Phase 2 — Confirm both services by their CURRENT names, not historical ones.**
Don't search for "Policy Retriever Service" or "Auto Upgrade Service" on a current client — check for **Global Secure Access Forwarding Profile Service** and **Global Secure Access Engine Service**.

**Phase 3 — Validate the forwarding profile is actually being retrieved, not just that the service is running.**
A running service with a stale profile (pre-2.31.125, no auto-restart after a crash) looks identical to a healthy one until you check the **Get policy** button's result or the Connections tab's active channels against what the tenant's forwarding profile configuration should produce.

**Phase 4 — For local-resource (printing/casting) complaints specifically, check for subnet overlap before assuming a Private Access misconfiguration.**
This is a genuinely new failure class as of v2.32.294 — a symptom that looks like "GSA is blocking my printer" is very often actually "GSA is correctly tunneling traffic that happens to share an address space with the printer's subnet," fixed by Prefer Local Network rather than a policy change.

**Phase 5 — For Hyper-V hosts, confirm virtual switch type before assuming the client is misbehaving.**
Internal vs. external switch produces fundamentally different, both-documented, both-intentional behavior — this isn't a bug in either configuration, but assuming the wrong one leads to chasing a phantom issue.

**Phase 6 — For multi-session hosts, treat "only some sessions protected" as expected, not a fault.**
Confirm via the dedicated health check test rather than spending time trying to "fix" a documented single-session limitation.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Diagnose and recover a stalled Forwarding Profile Service</summary>

1. Confirm the service's current name and status: `Get-Service -Name "*Global Secure Access*"`.
2. If **Global Secure Access Forwarding Profile Service** is stopped, restart it: `Start-Service -Name "GSAForwardingProfileService"` (confirm the exact service `Name` value via `Get-Service`, since the display name and short name can differ).
3. From the client UI, use the **Get policy** button to force an immediate poll rather than waiting for the next cycle.
4. If this recurs repeatedly on a pre-2.31.125 client, upgrade — the auto-restart-on-failure behavior introduced in that version is the durable fix, not a recurring manual restart.

**Rollback:** none — restarting the service is non-destructive.
</details>

<details><summary>Playbook 2 — Roll out Windows Update-delivered client upgrades deliberately</summary>

1. Inventory current client versions across the fleet (Validation Step 1) to identify which devices are already at or above the 2.31.125 (x64) / 2.32.294 (Arm) eligibility floor.
2. For devices below the floor that should receive automatic future upgrades, plan a one-time manual/MDM upgrade to cross the floor before November 2026.
3. For devices that should NOT auto-upgrade (e.g., a change-controlled environment), ensure the install/upgrade command includes `EnableWindowsUpdates=0` and document this deliberately per device — don't let it happen by accident of install history.
4. After November 2026, periodically re-audit: a device opted out of Windows Update delivery is now the organization's own responsibility to keep current, and versions will drift without a tracked manual process.

**Rollback:** for a device that should switch from opted-out to Windows Update-delivered, reinstall/upgrade the client without the `EnableWindowsUpdates=0` parameter.
</details>

<details><summary>Playbook 3 — Resolve an overlapping local-subnet printing/casting complaint</summary>

1. Confirm the client version is 2.32.294 or later (Prefer Local Network requires this floor).
2. Confirm the tenant admin has enabled the Prefer Local Network option for the relevant Cloud Sync/GSA configuration — the option only appears in client settings once an admin enables it.
3. Enable Prefer Local Network in the client settings on the affected device(s).
4. Re-test the local printing/casting scenario.
5. If the client is below v2.32.294, upgrade first — there is no workaround for this specific conflict on older clients beyond disabling the overlapping Private Access application's forwarding scope entirely (a much blunter, tenant-wide fix best avoided).

**Rollback:** disable Prefer Local Network if it introduces unexpected routing behavior elsewhere — this is a client-local setting change with no tenant-wide effect.
</details>

<details><summary>Playbook 4 — Correct a Hyper-V host misconfiguration</summary>

1. Identify the virtual switch type in use: `Get-VMSwitch | Select-Object Name, SwitchType`.
2. If **Internal**: confirm the GSA client is installed on the Hyper-V **host** only — guest VM traffic bypass is automatic; do not also install inside every guest unless there's a separate reason to.
3. If **External**: the host-level client does NOT bypass guest traffic for this switch type — install the GSA client inside each guest VM that needs its own traffic tunneled/protected, the host, or both, depending on which traffic needs coverage.
4. Re-validate expected tunneling behavior from both host and guest perspectives after correcting the install topology.

**Rollback:** uninstalling the client from a location it shouldn't be (e.g., inside guests when only host-level internal-switch bypass was needed) is non-destructive to the underlying VM or network configuration.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Global Secure Access Windows client version, service, and
             health-relevant evidence for planning or ticket escalation.
.DESCRIPTION Read-only. Gathers installed client version, Windows Update-delivery
             eligibility, both core service states, NRPT policy rules, and Hyper-V
             virtual switch types present on the host (if any). Exports to CSV.
.NOTES       Run locally as an administrator on the affected Windows device.
#>

$clientInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match "Global Secure Access" } |
    Select-Object -First 1 DisplayName, DisplayVersion

$engineService = Get-Service -Name "*Global Secure Access Engine*" -ErrorAction SilentlyContinue
$profileService = Get-Service -Name "*Global Secure Access Forwarding Profile*" -ErrorAction SilentlyContinue
$nrptRuleCount = (Get-DnsClientNrptPolicy -ErrorAction SilentlyContinue | Measure-Object).Count
$hyperVSwitches = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object Name, SwitchType

[PSCustomObject]@{
    ComputerName            = $env:COMPUTERNAME
    ClientVersion           = $clientInfo.DisplayVersion
    EngineServiceStatus     = $engineService.Status
    ForwardingProfileServiceStatus = $profileService.Status
    NRPTRuleCount           = $nrptRuleCount
    HyperVSwitchTypes       = ($hyperVSwitches.SwitchType -join "; ")
    CollectedAt             = Get-Date
} | Export-Csv -Path ".\GSAWindowsClientEvidence_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
```

---
## Command Cheat Sheet

```powershell
# Installed client version
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -match "Global Secure Access" } | Select-Object DisplayName, DisplayVersion

# Both core services, current names
Get-Service -Name "*Global Secure Access*"

# Restart the Forwarding Profile Service specifically
Restart-Service -Name "<exact service Name from Get-Service>"

# NRPT rules (Private Access DNS routing)
Get-DnsClientNrptPolicy

# Hyper-V virtual switch types on this host
Get-VMSwitch | Select-Object Name, SwitchType

# Silent install with Windows Update auto-upgrade OPTED OUT
# <installer file> /quiet /norestart EnableWindowsUpdates=0

# Official client release history (always re-check for the current version floor)
# https://learn.microsoft.com/en-us/entra/global-secure-access/reference-windows-client-release-history

# Official install guide (registry keys for Sign Out visibility, etc.)
# https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-install-windows-client
```

---
## 🎓 Learning Pointers

- **This is the dedicated Windows client counterpart to `macOS/Troubleshooting/GlobalSecureAccess-macOS-A.md`/`-B.md`.** The tenant-side forwarding profile concept is shared; almost everything else — install mechanics, service names, health checks, version-gated features — is platform-specific. Don't cross-apply a macOS fix to a Windows ticket or vice versa. [Global Secure Access client release notes (Windows)](https://learn.microsoft.com/en-us/entra/global-secure-access/reference-windows-client-release-history)
- **Service names have a real history — check the release notes before assuming a name is wrong.** "Auto Upgrade Service" → "Policy Retriever Service" → "Forwarding Profile Service" is one continuous lineage across three renames; an old runbook, forum post, or internal note referencing an older name isn't wrong, it's just dated.
- **The upcoming Windows Update delivery model (November 2026) has a version floor, not a universal cutover.** A fleet with mixed client versions will have some devices auto-upgrading via Windows Update and others still needing manual/MDM upgrades — audit before assuming the new model applies fleet-wide.
- **Prefer Local Network solves a real, specific, and previously invisible failure class.** A "GSA broke my printer" ticket is a legitimate candidate for this fix as of client v2.32.294 — recognize the overlapping-subnet pattern rather than treating every local-connectivity complaint as a Private Access policy issue.
- **The Hyper-V internal-vs-external virtual switch distinction is binary and unforgiving.** Getting this wrong (assuming host-level bypass works for an external switch) produces a failure mode that looks like a client bug but is actually a documented, intentional non-support boundary.
- **The single-interactive-session limitation is a product constraint, not a misconfiguration** — don't spend troubleshooting time trying to "fix" multi-session protection on a client that explicitly only supports one session at a time; set that expectation with the customer instead.
