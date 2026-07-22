# Windows Server 2025 Hotpatch (Azure Arc) — Hotfix Runbook (Mode B: Ops)
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

```powershell
# 1. Confirm OS edition/build is hotpatch-eligible (need Server 2025 Std/Datacenter, build 26100.1742+, non-preview)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object ProductName, CurrentBuild, UBR, EditionID

# 2. Confirm VBS/VSM is actually Running (not just policy-enabled)
Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName 'Win32_DeviceGuard' | Select-Object -ExpandProperty VirtualizationBasedSecurityStatus

# 3. Confirm the machine is Arc-connected and the agent is healthy
& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show

# 4. Confirm hotpatch license/enrollment state (requires Az.ConnectedMachine or Azure Update Manager REST — quickest is the portal)
#    Portal path: Azure Update Manager > Machines > <machine> > Recommended updates > Hotpatch column
#    CLI equivalent (needs az connectedmachine extension):
az connectedmachine extension list --machine-name "<arc-machine-name>" -g "<resource-group>" --query "[?name=='MDE.Windows' || contains(name,'Hotpatch')]"

# 5. Confirm no reboot-forcing update installed off the required baseline (check current KB vs. published baseline list)
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, InstalledOn
```

| Result | Meaning | Do this |
|---|---|---|
| `EditionID` isn't `ServerStandard`/`ServerDatacenter`, or build < 26100.1742 | Not eligible for hotpatch at all | Stop — not a hotpatch bug, it's an eligibility gap. Plan an OS/build upgrade if hotpatch is required. |
| `VirtualizationBasedSecurityStatus` ≠ `2` | VBS is not running (may be policy-enabled but inactive) | Go to [Fix 1](#common-fix-paths) |
| `azcmagent show` shows `Disconnected` or errors | Arc connectivity is broken — hotpatch enrollment/updates cannot flow | Go to [Fix 2](#common-fix-paths) |
| Portal shows **Not enrolled** | License step was never completed | Go to [Fix 3](#common-fix-paths) |
| Portal shows **Pending** for >10 minutes | Stuck enrollment — often the Oct 2025 feature-licensing bug or an Arc agent issue | Go to [Fix 4](#common-fix-paths) |
| Machine enrolled (**Enabled**) but every monthly update still forces a reboot | Machine has drifted off the required baseline build | Go to [Fix 5](#common-fix-paths) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Azure subscription + Arc-enabled server (Connected Machine agent healthy)
        │
        ▼
Windows Server 2025 Standard/Datacenter, build 26100.1742+ (non-preview)
        │
        ▼
UEFI + Secure Boot (Gen2 VM if virtualized) ──► VBS/VSM policy enabled
        │
        ▼
VBS/VSM actually RUNNING (VirtualizationBasedSecurityStatus = 2)
        │
        ▼
Hotpatch license ENROLLED (Arc portal or Azure Update Manager "Change" flow)
        │
        ▼
Machine on the exact required baseline build for the current quarter
        │
        ▼
Periodic/on-demand assessment surfaces hotpatch as a recommended update
        │
        ▼
Scheduled or on-demand install applies the hotpatch — NO reboot
(unless it's a baseline month, which always requires a full LCU + reboot)
```

Note: **Windows Server 2025 Datacenter: Azure Edition** skips the Arc-enablement requirement — hotpatch is on by default for that SKU, but every other layer (VBS, baseline currency) still applies.
</details>

---
## Diagnosis & Validation Flow

1. **Confirm eligibility.**
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object ProductName, CurrentBuild, UBR, EditionID
   ```
   Expect `EditionID` = `ServerStandard`, `ServerDatacenter`, or `ServerAzureEdition`, and `CurrentBuild.UBR` ≥ `26100.1742`. Server Core and Desktop Experience are both fine. `ServerEssentials` or anything below the build floor is a hard no.

2. **Confirm VBS is Running, not just configured.**
   ```powershell
   Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName 'Win32_DeviceGuard' | Select-Object -ExpandProperty VirtualizationBasedSecurityStatus
   ```
   `2` = running. `1` = configured but not running (needs reboot or hardware gap). `0` = not configured at all.

3. **Confirm Arc agent health.**
   ```powershell
   & "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show
   ```
   Look for `Agent Status: Connected` and a recent `Last Heartbeat`. Anything else means hotpatch enrollment and delivery are both blocked upstream of the OS.

4. **Check hotpatch enrollment status** in the Azure portal: **Azure Update Manager → Machines → \<machine\> → Recommended updates**, or **Machines → Edit columns → Hotpatch status** for an at-scale view.
   Possible values: `Not enrolled`, `Pending`, `Enabled`, `Disabled`, `Canceled`.

5. **Check for baseline drift** — compare installed KB history against the current quarter's published baseline KB (check the [Hotpatch release notes](https://support.microsoft.com/en-us/topic/release-notes-for-hotpatch-on-windows-server-2025-datacenter-azure-edition-c548437e-8c7a-4e27-99f4-e8746f97f8fa) for the exact current-quarter baseline KB number, since it changes every release).
   ```powershell
   Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, InstalledOn
   ```

---
## Common Fix Paths

<details><summary>Fix 1 — VBS/VSM is not running</summary>

```powershell
# Enable VSM policy (registry) — requires reboot to take effect
New-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -PropertyType 'Dword' -Value 1 -Force
Restart-Computer -Confirm

# After reboot, re-verify:
Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName 'Win32_DeviceGuard' | Select-Object -ExpandProperty VirtualizationBasedSecurityStatus
```
If it's still not `2` after reboot, the gap is hardware/firmware: confirm UEFI + Secure Boot are enabled in firmware, and if virtualized, confirm the VM is Generation 2 (Hyper-V) or has the vendor-equivalent VBS support enabled (e.g., VMware "Enable Virtualization-based Security" on the VM). This is a firmware/hypervisor-layer fix, not a Windows one — no rollback notes needed since nothing destructive was changed, but the reboot itself is a planned-outage action on a server.

</details>

<details><summary>Fix 2 — Arc agent disconnected or unhealthy</summary>

```powershell
& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show
& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" logs
```
Common causes: expired/revoked service principal, outbound firewall blocking Arc endpoints (`*.his.arc.azure.com`, `*.guestconfiguration.azure.com`, etc.), or a stopped `himds` service.
```powershell
Get-Service himds, GCArcService, ExtensionService | Select-Object Name, Status
Start-Service himds, GCArcService, ExtensionService
```
If re-connecting is required: `azcmagent disconnect` then `azcmagent connect` with a fresh onboarding token from the portal. Full Arc connectivity troubleshooting is out of scope here — see `Azure/Arc/AzureArc-B.md`.

</details>

<details><summary>Fix 3 — Hotpatch shows "Not enrolled"</summary>

Portal path (per-machine):
1. **Azure Update Manager → Machines → \<machine\>**
2. Under **Recommended updates**, find **Hotpatch**, select **Change**
3. Select **Receive monthly Hotpatch updates**
4. Select **Enable Hotpatching**, then **Confirm**
5. Wait ~10 minutes for the change to apply

Portal path (at scale, many machines at once):
1. **Azure Update Manager → Machines → Settings → Update settings**
2. **+ Add machine** → select target machines → **Add**
3. Set the **Hotpatch** dropdown to **Enable** → **Save**

No PowerShell cmdlet performs this step directly as of this writing — it is a portal/ARM operation. If automating at scale, use the `az rest` wrapper against the Update Manager ARM API or Bicep/ARM template deployment rather than clicking through per machine.

</details>

<details><summary>Fix 4 — Enrollment stuck on "Pending" (feature-licensing bug)</summary>

If enrollment has been stuck on **Pending** for well over 10 minutes and the machine is running an October 2025 security update (KB5066835, OS Build 26100.6899, or later), this is very likely the documented **feature-licensing issue**: the hotpatch feature license fails to activate, leaving enablement stuck "In Progress"/Pending, or — on already-enrolled machines — causing the license to silently expire so the *next* hotpatch forces a reboot instead of installing hot.

**Workaround (registry/script method — faster for a handful of machines):**
```powershell
Stop-Service -Name 'HIMDS'
New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' -Force
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' -PropertyType 'dword' -Name '4264695439' -Value 1 -Force
try {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Subscriptions' -Name 'DeviceLicensingServiceCommandMutex' -ErrorAction Stop
} catch {
    Write-Host "DeviceLicensingServiceCommandMutex entry not present, skipping removal."
}
Restart-Computer -Confirm
```
**Workaround (Group Policy method — better for fleet-wide remediation):** install the `KB5062660 251028_18301 Feature Preview` ADMX package, enable the corresponding policy under **Computer Configuration\Administrative Templates\KB5062660 251028_18301 Feature Preview**, reboot, then remove the same `DeviceLicensingServiceCommandMutex` registry value as above.

**Rollback notes:** the registry override under `FeatureManagement\Overrides` is additive and specific to this feature ID — removing the key and rebooting reverts the workaround if needed. `Windows Server 2025 Datacenter: Azure Edition` is not affected by this bug (hotpatch is built in for that SKU). Microsoft's release notes currently state this issue is fully mitigated going forward, but machines that missed the remediation window in Nov/Dec 2025 may still show its symptoms — this fix path remains valid for any machine still exhibiting them.

</details>

<details><summary>Fix 5 — Machine drifted off baseline (forces reboot every month)</summary>

Hotpatch only applies to a machine running the *exact* required baseline build for the current quarter. If any out-of-band, non-listed, or superseding update was installed outside the hotpatch pipeline, the machine falls back to regular (reboot-requiring) monthly updates until the next quarterly baseline ships.

```powershell
# Confirm current build vs. the published baseline for this quarter (check release notes link below for the current number)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object CurrentBuild, UBR
```
There is no supported way to force a machine back onto the hotpatch track mid-quarter — it self-corrects at the **next published baseline month**, which requires accepting one more full LCU + reboot. Plan that reboot as a normal maintenance window; no destructive rollback is applicable here, this is expected lifecycle behavior, not an error state.

</details>

---
## Escalation Evidence

```
=== Windows Server 2025 Hotpatch Escalation ===
Machine name:            <hostname>
Azure Arc resource ID:   <subscription>/resourceGroups/<rg>/providers/Microsoft.HybridCompute/machines/<name>
Subscription:            <sub-id>
OS edition / build:      <EditionID> / <CurrentBuild.UBR>
VBS status (CIM):        <VirtualizationBasedSecurityStatus value>
Arc agent status:        <azcmagent show output — Connected/Disconnected>
Hotpatch status (portal):<Not enrolled / Pending / Enabled / Disabled / Canceled>
Time stuck in this state:<duration>
Last patch assessment:   <timestamp from Recommended updates tab>
Recent KB history:       <Get-HotFix output, last 5>
October 2025 licensing bug workaround attempted?  <Yes/No — which method>
Screenshot attached:     <Recommended updates blade / Update settings blade>
Ticket priority:         <P1/P2/P3>
```

---
## 🎓 Learning Pointers

- Hotpatch enrollment is a two-layer state machine: the **license** (Not enrolled → Pending → Enabled/Disabled/Canceled) and the **update pipeline** (assessment → schedule/on-demand install). A stuck Pending status is a license-layer problem, not an update-pipeline one — don't waste time troubleshooting Update Manager schedules until enrollment itself reads Enabled. See [Manage hotpatches on Arc-enabled machines](https://learn.microsoft.com/en-us/azure/update-manager/manage-hot-patching-arc-machines).
- As of **19 May 2026**, Server 2025 Arc-enabled hotpatch is free — no per-core meter. If a client still sees a Hotpatch line item on an invoice, that's a stale bill from before the change, not evidence the feature costs money now. See [Simplified access to Hotpatching enabled by Azure Arc](https://techcommunity.microsoft.com/blog/AzureArcBlog/simplified-access-to-hotpatching-enabled-by-azure-arc-for-windows-server-2025/4521251).
- This is architecturally a *different product surface* from the Windows 11 client hotpatch delivered via Windows Autopatch (`Intune/Troubleshooting/Hotpatch-A.md`) — same "no-reboot patching" concept, completely different admin plane (Azure Arc/Update Manager vs. Intune/Autopatch), different licensing history, and a separate baseline calendar. Don't cross-apply fixes between the two without checking which plane the ticket is actually about.
- "VBS policy-enabled" and "VBS Running" are different states in every Microsoft hotpatch surface documented in this repo (client and server) — always verify with the CIM `VirtualizationBasedSecurityStatus` property, never trust that a GPO/CSP pushed successfully as proof it's active.
- Baseline-month reboots are expected, not a bug — hotpatch reduces reboot *frequency*, it doesn't eliminate the quarterly full-LCU cycle. Set that expectation with clients up front to avoid repeat "why did it reboot anyway" tickets.
