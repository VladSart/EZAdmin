# Azure Update Manager — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure Update Manager** — the current, native, non-Automation-dependent patch management service for Azure VMs and Azure Arc-enabled servers: on-demand assessment/install, periodic assessment, scheduled patching via maintenance configurations and configuration assignments, the patch-extension model, the guest-OS-side update-client dependencies (Windows Update Agent / WSUS, Linux package manager + sudo) that account for most real-world "patching isn't working" tickets, and **Windows Server 2025 Hotpatch delivered via Azure Arc/Update Manager** (eligibility gate, license/enrollment lifecycle, quarterly baseline cadence). Explicitly out of scope: Azure Automation's legacy Update Management solution (retired 31 August 2024 — see `Azure/Automation/`), Automatic VM Guest Patching (`patchMode: AutomaticByPlatform`) as a standalone Compute feature — a different mechanism from Hotpatch despite the naming overlap, **Windows 11 client Hotpatch via Windows Autopatch** — an architecturally separate product/admin plane, see `Intune/Troubleshooting/Hotpatch-A.md`, on-premises WSUS server administration itself, and Azure Arc onboarding/connectivity (a hard prerequisite, covered in `Azure/Arc/`).

---

## Before responding, also check

- **Azure/Arc** — Update Manager on a non-Azure machine is entirely dependent on a healthy Arc Connected Machine agent; a disconnected Arc agent produces symptoms that look exactly like a patching failure. Confirm Arc status first for any Arc-enabled server ticket.
- **Azure/Automation** — if the ticket mentions "Update Management" (no "r") inside an Automation account, that's the retired legacy solution, not this folder's topic — flag for migration per `Automation/AzureAutomation-A.md` Remediation Playbook 4 / this folder's own Playbook 2.
- **Windows/Troubleshooting/Windows Update** — for on-premises/non-Azure Windows Update Agent or WSUS-client-side issues unrelated to any Azure machine.
- **Security/Defender** — MDE and patching are often bundled into the same "hardening" conversation with a client, but are functionally independent; don't conflate a missing MDE agent with a patching gap.

---

## Folder contents

| File | What it covers |
|------|----------------|
| `UpdateManager-B.md` | Hotfix runbook — extension missing/stuck, HRESULT update-agent errors, missing/broken schedule assignment after a VM move, maintenance-window-exceeded failures, Linux sudo/root privilege failures |
| `UpdateManager-A.md` | Deep dive — extension/agent architecture, on-demand vs. periodic vs. scheduled patching model, maintenance-window arithmetic, Resource Graph retention limits, fleet onboarding and legacy-migration playbooks |
| `Scripts/Get-AzureUpdateManagerHealth.ps1` | Read-only fleet sweep — VM power state, extension-operations eligibility, patch extension health, optional Arc connection check, optional per-machine schedule-assignment check, orphaned-schedule detection |
| `ServerHotpatch-B.md` | Hotfix — Windows Server 2025 Hotpatch (Arc) eligibility/enrollment triage: VBS not running, Arc agent unhealthy, stuck "Pending" enrollment (October 2025 feature-licensing bug), baseline drift forcing monthly reboots |
| `ServerHotpatch-A.md` | Deep dive — eligibility-gate/license-plane/delivery-plane architecture, quarterly baseline+hotpatch cadence, May 2026 free-tier billing change, the two distinct October 2025 incidents (feature-licensing bug vs. mistaken WSUS OOB update KB5070881), Datacenter: Azure Edition's built-in-hotpatch divergence |
| `Scripts/Get-ServerHotpatchReadiness.ps1` | Read-only local/fleet readiness audit — OS build/edition eligibility, VBS running state, Arc agent presence, baseline-drift sanity check, October 2025 bug-workaround artifact detection |

---

## Common entry points

- **"Machine shows Not assessed with a red exception"** → `UpdateManager-B.md` Fix 2 — decode the HRESULT before assuming it's an Azure-side fault
- **"No patch extension on this VM at all"** → `UpdateManager-B.md` Fix 1 — often expected (never triggered yet), confirm via an on-demand assessment before treating as broken
- **"Scheduled patching stopped after we moved the VM"** → `UpdateManager-B.md` Fix 3 — configuration assignments don't survive resource-group/subscription moves automatically
- **"Update history says Maintenance window exceeded but the window looked fine"** → `UpdateManager-B.md` Fix 4 — reboot reservation + per-update time budget arithmetic, not a platform bug
- **"Patching fails on Linux with a sudoers error"** → `UpdateManager-B.md` Fix 5
- **"Onboarding a new client's VM/Arc estate to scheduled patching"** → `UpdateManager-A.md` Playbook 1
- **"Client still has Automation-based Update Management — how do we move them"** → `UpdateManager-A.md` Playbook 2
- **"Fleet-wide patching coverage audit for a ticket/report"** → `Scripts/Get-AzureUpdateManagerHealth.ps1 -IncludeArc -CheckVMAssignments`
- **"Hotpatch won't enable / stuck Pending / server reboots every month despite hotpatch being on"** → `ServerHotpatch-B.md` — check VBS running state and Arc health before assuming a licensing bug
- **"Client asking why they're still being billed for hotpatch"** → `ServerHotpatch-A.md` Symptom→Cause Map — free since 19 May 2026, likely stale billing data
- **"Is this the Windows Server hotpatch or the Windows 11 client one"** → confirm the admin plane first (Azure Arc/Update Manager = `ServerHotpatch-A.md`; Intune/Autopatch = `Intune/Troubleshooting/Hotpatch-A.md`) — they share terminology but nothing else

---

## Key diagnostic commands

```powershell
# VM power/agent state — check this FIRST, nothing above it can be diagnosed meaningfully otherwise
Get-AzVM -ResourceGroupName <rg> -Name <vm> -Status

# Force a fresh assessment (also bootstraps the extension on first use)
Invoke-AzVMPatchAssessment -ResourceGroupName <rg> -VMName <vm>

# Patch extension provisioning state
Get-AzVMExtension -ResourceGroupName <rg> -VMName <vm> -Name "WindowsPatchExtension"

# Confirm extension operations aren't globally blocked on this VM
(Get-AzVM -ResourceGroupName <rg> -Name <vm>).OSProfile.AllowExtensionOperations

# Confirm the machine is actually assigned to the schedule expected
Get-AzConfigurationAssignment -ResourceGroupName <rg> -ResourceName <vm> -ResourceType virtualMachines -ProviderName Microsoft.Compute

# For Arc-enabled servers — confirm the layer beneath Update Manager first
Get-AzConnectedMachine -ResourceGroupName <rg> -Name <machine> | Select-Object Status, LastStatusChange
```

---

## Key dependency chain

```
Machine powered on + RBAC permission
    │
    ├── Base agent (Azure VM Agent, or Azure Connected Machine agent for Arc — see Azure/Arc/)
    │       ▼
    │   AllowExtensionOperations = true (OSProfile)
    │       ▼
    │   Patch extension (installs lazily on FIRST use — not pre-provisioned)
    │       ▼
    │   Guest OS update client (Windows: WUA/WSUS source config; Linux: package manager + sudo)
    ▼
Scheduling layer (independent resources — a schedule existing proves nothing about coverage)
    ├── Microsoft.Maintenance/maintenanceConfigurations (the window/recurrence/content)
    └── Microsoft.Maintenance/configurationAssignments (machine ↔ schedule link —
          does NOT survive a resource group/subscription move automatically)
    ▼
Maintenance window arithmetic (10-15min reboot reservation + per-update time budget)
    ▼
Install outcome (Succeeded / Failed / Completed with warnings)
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — unblock the specific machine's assessment/install or fix the schedule link (Mode B)
2. **Root cause** — which layer actually failed: base agent/Arc, extension, guest OS update client, or scheduling resource (Mode A)
3. **Prevention** — fleet-wide audit for orphaned schedules and extension-operations-disabled VMs before the next patch cycle, not after a client notices a gap
