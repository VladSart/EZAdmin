# Azure Compute (VMs) — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure IaaS VM health at the compute layer**: boot failures, disk repair, and the platform-side extension/agent framework that boot diagnostics, monitoring, backup, and remote-access tooling all depend on. This is the "the VM itself won't come up or won't respond" layer — distinct from `Azure/Backup/` (protecting the VM), `Azure/SiteRecovery/` and `Azure/OnPremDR/` (replicating the VM), and `Windows/Troubleshooting/` (guest-OS issues once you can actually get a session on the box).

---

## Before responding, also check

- **Azure/Backup** (`Azure/Backup/`) — if the VM won't boot *after* a restore, or the fix path is "restore from recovery point" rather than repair, that's the other folder
- **Azure/SiteRecovery** / **Azure/OnPremDR** — replication/failover-caused boot issues (e.g., a failed-over VM that won't come up) start there, not here
- **Windows/Troubleshooting** — once you have console/RDP access and the issue is inside the guest OS (not agent/extension/boot-device level), hand off there
- **Azure/Networking** — "can't RDP/SSH" is sometimes an NSG/routing problem, not an extension or boot problem — rule that out via `Get-AzNetworkWatcher` before assuming agent failure

---

## Folder contents

| File | What it covers |
|------|----------------|
| `VMBootRepair-B.md` | Hotfix runbook — VM won't boot: INACCESSIBLE_BOOT_DEVICE, reboot loops, stuck chkdsk, ADE-locked disks, unmanaged disk repair |
| `VMBootRepair-A.md` | Deep dive — boot repair architecture, manual snapshot/attach/repair, `az vm repair` automation, ADE key-unwrap playbooks |
| `VMExtensions-B.md` | Hotfix runbook — VM Agent/extension failures: stopped agent, stuck extension provisioning, CustomScriptExtension failures, blank boot diagnostics, unreachable Serial Console |
| `VMExtensions-A.md` | Deep dive — agent/extension architecture, transport certificate recovery, fleet-wide extension health baselining |
| `Scripts/Get-AzureVMBootRepairAudit.ps1` | Read-only audit: VM power/provisioning state, boot diagnostics availability, disk encryption status across the fleet |
| `Scripts/Get-AzureVMExtensionHealth.ps1` | Read-only audit: VM Agent status and per-VM extension provisioning state, flags stuck/failed extensions |

---

## Common entry points

- **"VM won't boot / stuck starting / INACCESSIBLE_BOOT_DEVICE"** → `VMBootRepair-B.md` Triage first, then Fix 2 or 7
- **"VM is in a reboot loop"** → `VMBootRepair-B.md` Fixes 4-6 (service, update/app, registry — in that order)
- **"Disk is locked / BitLocker/ADE won't unlock after repair"** → `VMBootRepair-B.md` Fix 8, or `VMBootRepair-A.md` Playbooks 3-4 for the full key-unwrap path
- **"Extension stuck in Transitioning/Creating"** → `VMExtensions-B.md` Fix 4
- **"CustomScriptExtension failed"** → `VMExtensions-B.md` Fix 5
- **"Boot diagnostics screenshot is blank/stale"** → `VMExtensions-B.md` Fix 6
- **"Can't reach Serial Console"** → `VMExtensions-B.md` Fix 7
- **"Guest Agent shows Not Ready"** → `VMExtensions-B.md` Fix 2/3, or `VMExtensions-A.md` Playbook 1 for a full reinstall
- **"Onboarding a new client's VM fleet, need a baseline"** → `VMExtensions-A.md` Playbook 4 + both audit scripts

---

## Key diagnostic commands

```powershell
# VM power/provisioning state and VM Agent status in one call
Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status |
  Select-Object @{N='PowerState';E={($_.Statuses | Where-Object Code -like 'PowerState/*').DisplayStatus}},
                @{N='ProvisioningState';E={($_.Statuses | Where-Object Code -like 'ProvisioningState/*').DisplayStatus}},
                @{N='VMAgent';E={$_.VMAgent.Statuses.DisplayStatus}}

# Extension provisioning state for a VM
Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" |
  Select-Object Name, ProvisioningState, EnableAutomaticUpgrade

# Pull boot diagnostics (screenshot + serial log)
Get-AzVMBootDiagnosticsData -ResourceGroupName "<rg>" -Name "<vmName>" -Windows -LocalPath "C:\Temp\BootDiag"

# az vm repair — automated boot repair (fastest path when eligible)
az vm repair create -g <rg> -n <vmName> --repair-username <user> --repair-password <pw> --verbose
```

---

## Key dependency chain

```
Azure Compute platform (host)
    │
    └── VM power/provisioning state (Running + Succeeded required for most repair paths)
            │
            └── VM Agent (Windows: WaAppAgent / Linux: waagent) — must report Ready
                    │
                    └── Extension framework (per-extension provisioning: CustomScript, Antimalware,
                        Backup, Monitoring Agent, Boot Diagnostics)
                            │
                            └── OS disk (managed disk snapshot → attach to repair VM, or ADE key
                                unwrap if encrypted) → boot device / BCD / chkdsk state
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — get the VM booting or the extension reporting healthy again (Mode B)
2. **Root cause** — agent-side, extension-side, or disk/boot-device level (Mode A)
3. **Prevention** — fleet-wide extension health baselining, boot diagnostics coverage, ADE key backup verification
