# Azure VM Boot & Disk Repair — Reference Runbook (Mode A: Deep Dive)
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

This file covers OS-level boot and disk failures on Azure IaaS Windows VMs
(Resource Manager deployment model) — the layer directly below where
`Azure/Compute/VMExtensions-A.md` picks up. It assumes:

- The VM Agent / extension pipeline is a **separate concern**, documented in
  `VMExtensions-A.md`. If `Get-AzVM -Status` shows `AgentStatus: Ready` and
  extensions are provisioning fine, this is the wrong file — the problem is
  above the OS boot layer, not in it.
- Boot diagnostics is already enabled on the VM. If it isn't, start with
  `VMExtensions-A.md`'s boot-diagnostics coverage first — this file assumes
  you can already retrieve a boot screenshot to classify the symptom.
- The VM uses **Resource Manager** deployment (Classic/ASM VMs are out of
  scope and unsupported by current tooling).
- Managed disks are the primary path throughout. Unmanaged (VHD-in-storage-
  account) disks are explicitly out of scope for the deep procedures here —
  see the Fix 9 cross-reference in `VMBootRepair-B.md` for where to go
  instead; the mechanics diverge enough at the blob/lease level that
  duplicating them here would risk drifting out of sync with Microsoft's
  own maintained procedure.
- Linux VM boot repair (GRUB, fstab, initramfs) is **not covered** — the
  documented Microsoft repair tooling, log paths, and common failure
  signatures for Linux boot failures are materially different from the
  Windows BCD/chkdsk/registry-hive mechanics this file documents in depth,
  and would dilute rather than strengthen a single-file treatment. A
  dedicated Linux-boot-repair topic is a candidate for a future build.
- Azure Disk Encryption (ADE) is covered as a **cross-cutting prerequisite**
  layer (an encrypted disk must be unlocked before anything else here can
  proceed), not as its own independently-triggered topic.

---
## How It Works

<details><summary>Full architecture</summary>

### The boot sequence, layer by layer

An Azure Windows VM boots through the same sequence a physical/on-prem
machine would, with one added layer underneath everything: boot
diagnostics reads the virtual framebuffer and COM1 serial port directly
from the hypervisor, independent of whether any layer below has succeeded.

```
┌─────────────────────────────────────────────────────────────┐
│  Boot diagnostics (hypervisor-level, always available)       │
│  Reads: virtual framebuffer (screenshot) + COM1 serial port  │
│  Independent of: firmware, BCD, filesystem, Guest Agent       │
└─────────────────────────────────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Firmware boot (Generation-dependent, fixed at VM creation)   │
│  Gen 1: legacy BIOS, MBR partitioning                         │
│  Gen 2: UEFI, GPT partitioning, Secure Boot capable            │
└─────────────────────────────────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Boot Configuration Data (BCD) store                          │
│  Gen 1: <boot partition>\boot\bcd                              │
│  Gen 2: <EFI System Partition>\EFI\Microsoft\boot\bcd          │
│  Contains: {bootmgr} entry, Windows Boot Loader entry(ies),    │
│  each with device/osdevice partition pointers                 │
└─────────────────────────────────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  NTFS file system integrity (Windows volume)                  │
│  A "dirty" volume bit forces chkdsk at every boot attempt      │
│  until it completes cleanly                                    │
└─────────────────────────────────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Kernel init + service control manager                        │
│  Services flagged ErrorControl=Critical (2) that fail to      │
│  start trigger an automatic reboot rather than continuing      │
└─────────────────────────────────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Guest Agent / RDP-SSH reachable                               │
│  ← VMExtensions-A.md's territory begins here                   │
└─────────────────────────────────────────────────────────────┘
```

**Azure Disk Encryption (ADE)**, when present, is not a step in this
vertical sequence — it's a horizontal gate that sits in front of every
layer's *offline-repair* path. Once a VM fails to boot, repairing any
layer above requires attaching the OS disk to a second ("repair") VM and
reading it directly. If ADE is enabled, that disk is BitLocker-locked and
unreadable on the repair VM until unlocked with the correct key material
— regardless of which of the five layers above actually caused the
original failure.

### Why offline repair is the standard pattern

None of the layers above can be fixed while the failing VM's own OS won't
boot — there's no way to run `bcdedit` or `chkdsk` *inside* an instance
that never reaches a usable shell. Microsoft's documented pattern for all
five layers is therefore identical in shape even though the specific
commands differ: **attach a copy of the failed OS disk to a second,
healthy VM as a data disk, repair it offline, then either swap the disk
back onto the original VM or promote the repaired disk into a new VM.**

Two mechanisms exist for this:

1. **Manual** — snapshot the OS disk → create a managed disk from the
   snapshot → create a repair VM → attach the new disk as a data disk →
   repair → detach → swap the original VM's OS disk (portal: "Swap OS
   disk") or create a new specialized VM from the repaired disk.
2. **Automated** — the `az vm repair` CLI extension performs the same
   snapshot/attach/repair-VM lifecycle end-to-end (`create` → `run` →
   `restore`), including automatic ADE unlocking for single-pass-encrypted
   managed disks when `--unlock-encrypted-vm` is passed. It also supports
   `--enable-nested` for troubleshooting nested-Hyper-V scenarios, and a
   community-maintained [repair script library](https://github.com/Azure/repair-script-library)
   accessible via `az vm repair list-scripts` / `az vm repair run --run-id`.

The automated path is preferred whenever it's eligible (unencrypted, or
ADE single-pass/v2+, managed disk, and organizational policy allows a
repair VM with a public IP address) — it removes the manual
snapshot/disk/VM bookkeeping and the associated chance of human error in
resource naming or region/zone mismatches. It is **not** eligible for ADE
dual-pass (v1) encrypted disks, unmanaged disks, or environments that
categorically disallow public IPs on any VM (in which case the
semi-automated BEK-volume method, below, is the next-best option).

### Azure Disk Encryption: version and unlock-method matrix

ADE has two encryption generations, distinguishable via the
`AzureDiskEncryption` extension's `TypeHandlerVersion`:

- **Version 1.x — dual-pass encryption.** Older, more complex on-disk
  layout. **No automated unlock path exists.** Manual KEK/BEK
  retrieval-and-unwrap is the only supported method.
- **Version 2.x+ — single-pass encryption.** Current default for new
  encryptions. Supports both the fully-automated `az vm repair
  --unlock-encrypted-vm` path and a semi-automated BEK-volume method that
  avoids needing a public IP on the repair VM.

Three unlock resolutions exist, selected based on version, managed/
unmanaged state, and public-IP policy:

| Resolution | Applies to | Public IP required | Mechanism |
|---|---|---|---|
| 1 — Automated | Managed, v2+ only | Yes | `az vm repair create --unlock-encrypted-vm` |
| 2 — Semi-automated | Managed, v2+ only | No | Attach disk copy at repair-VM *creation* time (auto-populates a hidden BEK volume) → assign it a drive letter → locate the `.BEK` file → `manage-bde -unlock` |
| 3 — Manual | v1 (dual-pass), unmanaged, or when 1/2 fail | No | Retrieve the BEK (and KEK if wrapped) directly from Key Vault via PowerShell, write it to the repair VM's local disk, then `manage-bde -unlock` |

Critically: **unlocking a disk with `manage-bde -unlock` does not decrypt
it.** The volume remains BitLocker-protected for the duration of the
repair session; only an explicit `manage-bde -off` permanently decrypts,
and that is a deliberate, separate, and much slower action that should
never be triggered as a side effect of a repair procedure.

### Reboot loop: three distinct causes, one shared symptom

Boot diagnostics shows the same visual symptom (the boot logo repeating,
or a "running" VM that never stabilizes) for three architecturally
unrelated causes, which is why offline registry/log inspection — not
guessing from the screenshot alone — is required to pick the right fix:

1. **A critical service failing to start.** Any service (third-party or
   an Azure platform agent) flagged `ErrorControl = 2` (Critical) in its
   service registry key forces Windows to auto-reboot if it fails to
   start, rather than continuing with a degraded boot. Diagnosed by
   loading the offline `SYSTEM` hive and checking the relevant
   `ErrorControl` values under the *active* ControlSet (found via
   `Select\Current`, not assumed to be `ControlSet001`).
2. **A recent update, application install, or policy change.** Diagnosed
   from Event Logs, `CBS.log`, and `Windows Update.log` on the offline
   disk. Fixed via Last Known Good Configuration recovery — which only
   reverts driver/service *registry* state from the last successful boot,
   not files changed by the update itself.
3. **Registry hive corruption.** The most severe and the explicit last
   resort — restoring `\Windows\System32\config\regback` files
   overwrites the corrupted hive, but reintroduces any registry state
   drift between the regback snapshot's timestamp and the failure. A VM
   recovered this way should be treated as a bridge to migrate data off
   and rebuild, not a permanent fix.

</details>

---
## Dependency Stack

```
▲ Guest Agent / RDP-SSH reachable         (VMExtensions-A.md territory)
│
│ ─────────────── ADE unlock gate (horizontal, applies to every ▼ layer) ───
│
▼ Kernel init + service ErrorControl      (Reboot loop causes 1)
▼ NTFS file system integrity              (chkdsk stuck)
▼ Boot Configuration Data (BCD)           (INACCESSIBLE_BOOT_DEVICE)
▼ Firmware boot sequence (Gen 1/2)        (determines BCD command syntax)
▼ Boot diagnostics                        (always available, read this first)
```

Repair direction is bottom-up in the sense that boot diagnostics is always
your first read, but diagnosis of the *specific* failing layer works
top-down from the screenshot's visual signature: a recognizable OS error
message narrows you to one layer immediately, while a blank/generic
screenshot means working down from firmware generation before assuming
any single layer.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Screenshot: "Boot failure. Reboot and Select proper Boot device" | BCD corrupted or boot partition inactive | `bcdedit /enum /v` against the attached disk's BCD store |
| Screenshot: references `INACCESSIBLE_BOOT_DEVICE` explicitly | BCD device/osdevice pointers wrong, or boot partition inactive (Gen 1) | Same as above; also `diskpart` → `detail partition` for Active flag |
| Screenshot: "Checking file system on C:" / "Scanning and repairing drive (C:)" stuck 30+ min | Offline chkdsk hung, or an NTFS error too large to self-heal online | Attach disk to repair VM, run `chkdsk <drive>: /f` directly |
| Screenshot: boot logo repeats in a loop, never reaches lock screen | Reboot loop — one of three causes (service, update, hive corruption) | Offline `SYSTEM`/`SOFTWARE` hive inspection, Event Logs, `CBS.log` |
| VM shows `running` in the portal but boot diagnostics never updates past an old timestamp | Boot diagnostics itself may be broken, not the guest OS | Cross-check `VMExtensions-A.md` (Premium/ZRS storage incompatibility, stale-screenshot idle-timeout) before assuming an OS-layer fault |
| Disk attached to repair VM shows as locked with a padlock icon in File Explorer | Azure Disk Encryption enabled, disk not yet unlocked | `Get-AzVmDiskEncryptionStatus`; determine v1 vs v2 before choosing a resolution |
| `az vm repair create --unlock-encrypted-vm` fails or the disk still shows locked afterward | Disk is ADE v1 (dual-pass) — the automated unlock only supports v2+ | Check `AzureDiskEncryption` extension `TypeHandlerVersion`; fall back to manual KEK/BEK unwrap |
| Repair VM creation fails with a message referencing "contains encryption settings and therefore cannot be used as a data disk" | Attempted to attach the encrypted disk to an *already-existing* VM rather than at creation time | Create the repair VM without the disk first, then attach through the portal afterward (documented workaround) |
| `az vm repair run` times out with no output after ~90 minutes | Script exceeded the hard, non-extendable Cloud Shell/CLI script timeout | Re-run the equivalent steps locally via Azure CLI (not Cloud Shell) for long-running scripts, e.g. `win-sfc-sf-corruption` |
| VM boots to "Preparing Automatic Repair" / Windows Recovery Environment loop | Windows' own automatic-repair loop, a variant of the reboot-loop symptom class | Same offline diagnosis path as reboot loop; check `bootstatuspolicy` in BCD (should be `IgnoreAllFailures` after Fix 2's repair, which also breaks this loop) |
| Manual disk swap ("Swap OS disk") doesn't show the new disk as an option | Detach from repair VM hasn't fully propagated yet | Wait 10-15 minutes after detach before retrying — a documented Azure propagation delay, not a failure |
| `Get-AzVM` shows `ManagedDisk` as `$null` for the OS disk | Legacy unmanaged (VHD-in-storage-account) disk | Different attach/repair mechanic entirely — see Scope & Assumptions and the linked unmanaged-disk procedure |
| VM never shows any boot diagnostics screenshot at all, even after 10+ minutes | Boot diagnostics not enabled, or storage account itself unreachable | This is a `VMExtensions-A.md` problem, not this file's — resolve boot diagnostics visibility first |

---
## Validation Steps

**1. Confirm boot diagnostics is producing current data**
```powershell
Get-AzVMBootDiagnosticsData -ResourceGroupName "<rg>" -Name "<vmName>" -Windows -LocalPath "C:\Temp\BootDiag"
```
Good: a screenshot with a timestamp/visible content matching recent VM activity. Bad: identical output across repeated pulls minutes apart, or a completely black/empty image — treat as a boot-diagnostics-layer problem first.

**2. Confirm VM generation before selecting BCD command syntax**
```powershell
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>").HyperVGeneration
```
Good: returns `V1` or `V2` unambiguously. Bad: this property is empty/unexpected — don't guess; check the portal's VM Overview blade generation field directly instead.

**3. Confirm ADE state and version before any attach**
```powershell
Get-AzVmDiskEncryptionStatus -ResourceGroupName "<rg>" -VMName "<vmName>"
(Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" | Where-Object ExtensionType -like "*DiskEncryption*").TypeHandlerVersion
```
Good: a clear `NotEncrypted` or `Encrypted` result, with a version number if encrypted. Bad: `Get-AzVmDiskEncryptionStatus` itself errors — this usually means the extension isn't installed/reporting, which is itself diagnostically useful (rules out ADE as the blocker).

**4. Confirm managed vs. unmanaged before choosing a repair mechanism**
```powershell
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>").StorageProfile.OsDisk.ManagedDisk
```
Good: a resource ID is returned (managed). Bad: `$null` (unmanaged — stop and use the linked legacy procedure instead of anything else in this file).

**5. Snapshot exists and is a genuine point-in-time copy**
```powershell
Get-AzSnapshot -ResourceGroupName "<rg>" -SnapshotName "<snapshotName>" | Select-Object Name, TimeCreated, DiskSizeGB, ProvisioningState
```
Good: `ProvisioningState: Succeeded` with a `TimeCreated` from just before the repair attempt began. Bad: missing entirely, or `TimeCreated` predates the actual failure (meaning it's not a useful rollback point for this specific incident).

**6. Repair VM is genuinely healthy before trusting anything read from it**
```powershell
Get-AzVM -ResourceGroupName "<repairRg>" -Name "<repairVmName>" -Status
```
Good: `PowerState/running`, `AgentStatus: Ready`. Bad: the repair VM itself has problems — don't attempt to diagnose the *original* failed disk's contents through an unreliable repair VM.

**7. Post-repair boot success, confirmed at the OS level, not just the platform level**
```powershell
Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -Name "<vmName>" -CommandId 'RunPowerShellScript' -ScriptString "Get-Service RdAgent, WindowsAzureGuestAgent | Select Name, Status; Get-WinEvent -LogName System -MaxEvents 20 | Select TimeCreated, Id, LevelDisplayName, Message"
```
Good: `PowerState/running`, both agent services `Running`, no fresh Critical/Error events referencing the same root cause. Bad: platform-level "running" but Run Command still fails, or the same Event ID that caused the original failure reappears — the repair didn't address the actual root cause.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Classify before acting.** Pull boot diagnostics, match the
screenshot against the Symptom → Cause Map, and confirm VM generation. Do
not skip to a fix based on assumption — Generation-1 BCD syntax against a
Generation-2 EFI partition silently does nothing, and reboot-loop's three
causes require genuinely different remediation.

**Phase 2 — Establish the repair-path prerequisites.** Confirm ADE state/
version and managed/unmanaged status (Validation Steps 3-4) before
creating any repair VM or snapshot — these determine which of the three
ADE unlock resolutions, and which of the manual-vs-automated repair
mechanisms, are even available. Getting this wrong wastes an entire
repair-VM creation cycle discovering a locked, unreadable disk.

**Phase 3 — Protect the evidence.** Snapshot the OS disk before any
offline edit (Validation Step 5). This is not optional process overhead —
it is the actual rollback mechanism for every playbook below, since none
of the BCD/registry/chkdsk edits are individually reversible once applied.

**Phase 4 — Repair offline, on the copy, never on the only copy.**
Whether via the automated `az vm repair` flow or the manual snapshot/
attach sequence, all repair work happens on a disk *copy* attached to a
separate VM — never directly on the only existing copy of the failed
disk.

**Phase 5 — Swap back and validate at the OS level, not just the
platform level.** "VM shows running" is necessary but not sufficient —
confirm via Run Command that the Guest Agent is genuinely `Ready` and that
the specific Event Log signature that caused the original failure hasn't
reappeared (Validation Step 7) before considering the incident closed.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Manual snapshot/attach/repair (no public IP required, works for any eligible disk)</summary>

**When to use:** Organizational policy disallows public IPs on any VM
(ruling out the fully-automated `az vm repair create` path), or the disk
is ADE v1/unmanaged (ruling out automation entirely).

```powershell
# 1. Snapshot the failed VM's OS disk
$disk = Get-AzDisk -ResourceGroupName "<rg>" -DiskName "<osDiskName>"
$snapConfig = New-AzSnapshotConfig -SourceUri $disk.Id -Location $disk.Location -CreateOption Copy
New-AzSnapshot -ResourceGroupName "<rg>" -SnapshotName "<osDiskName>-repair-$(Get-Date -Format yyyyMMddHHmm)" -Snapshot $snapConfig

# 2. Create a new managed disk from that snapshot, in the SAME region/zone as the source
$snap = Get-AzSnapshot -ResourceGroupName "<rg>" -SnapshotName "<snapshotName>"
$diskConfig = New-AzDiskConfig -Location $snap.Location -CreateOption Copy -SourceResourceId $snap.Id
New-AzDisk -ResourceGroupName "<rg>" -DiskName "<osDiskName>-copy" -Disk $diskConfig

# 3. Create (or reuse) a repair VM in that same region/zone, then attach the new disk as DATA
$repairVm = Get-AzVM -ResourceGroupName "<repairRg>" -Name "<repairVmName>"
$diskCopy = Get-AzDisk -ResourceGroupName "<rg>" -DiskName "<osDiskName>-copy"
Add-AzVMDataDisk -VM $repairVm -Name "<osDiskName>-copy" -CreateOption Attach -ManagedDiskId $diskCopy.Id -Lun 1
Update-AzVM -ResourceGroupName "<repairRg>" -VM $repairVm

# 4. RDP to the repair VM. Perform the repair matching your Phase-1 classification
#    (BCD repair / chkdsk / registry hive edit — see VMBootRepair-B.md's Fix sections
#    for the exact commands).

# 5. Detach the repaired disk from the repair VM
Remove-AzVMDataDisk -VM $repairVm -DataDiskNames "<osDiskName>-copy"
Update-AzVM -ResourceGroupName "<repairRg>" -VM $repairVm
Start-Sleep -Seconds 120   # documented propagation delay before the disk is available to reattach

# 6. Swap the original VM's OS disk for the repaired copy (portal: Disks > Swap OS disk),
#    or build a new specialized VM directly from the repaired disk if the original VM
#    resource itself is also being retired.
```

**Rollback:** The original failed OS disk is never modified by this
procedure — only a copy is repaired. If the repair made things worse,
simply discard the copy and repeat from a fresh snapshot, or restore the
original VM's OS disk unchanged.

</details>

<details><summary>Playbook 2 — Automated repair via `az vm repair` (fastest, when eligible)</summary>

**When to use:** Unencrypted or ADE v2+ (single-pass) managed disk, and a
public IP on a short-lived repair VM is acceptable under policy.

```azurecli
az extension add -n vm-repair    # or: az extension update -n vm-repair

az vm repair create -g <rg> -n <vmName> --repair-username <user> --repair-password '<StrongPassword!>' --verbose
# Encrypted (v2+ only): add --unlock-encrypted-vm
# Nested Hyper-V troubleshooting: add --enable-nested

az vm repair list-scripts   # browse the repair-script-library catalog
az vm repair run -g <rg> -n <vmName> --run-on-repair --run-id <script-id> --verbose
# or connect to the repair VM directly and perform manual mitigation

az vm repair restore -g <rg> -n <vmName> --verbose
```

**Constraints to plan around:** only one script runs at a time and it
cannot be canceled; the hard timeout is 90 minutes with no resume;
outbound port 443 from the repair VM's subnet is required; the tags
`az vm repair` places on the repair VM must not be manually edited, or
`restore` will fail to locate the correct resources.

**Rollback:** `az vm repair create` operates on a disk copy exactly like
Playbook 1 — the original VM and its OS disk are untouched until
`restore` explicitly swaps them. A failed `run` step can simply be
followed by a fresh `create` cycle rather than requiring manual cleanup
in the common case.

</details>

<details><summary>Playbook 3 — ADE-encrypted disk unlock (Resolution 2: semi-automated, no public IP)</summary>

**When to use:** Managed disk, ADE v2+ (single-pass), but repair-VM public
IPs are disallowed by policy — the middle option between full automation
and the fully manual KEK/BEK unwrap.

```powershell
# 1-2. Snapshot + create a disk copy exactly as in Playbook 1, steps 1-2

# 3. Create a NEW repair VM (Windows Server Datacenter) and attach the disk copy
#    DURING VM CREATION — attaching it after creation does not trigger the automatic
#    BEK-volume population this method depends on.

# 4. On the repair VM, open Disk Management (diskmgmt.msc); locate the BEK volume
#    (no drive letter by default) and assign one via "Change Drive Letter and Paths"

# 5. Locate the .BEK file (hidden by default)
#    cmd: dir <BekDriveLetter>: /a:h /b /s

# 6. Unlock the encrypted volume
manage-bde -unlock <EncryptedDriveLetter>: -RecoveryKey <BekDriveLetter>:\<BekFileName>.BEK

# 7. Perform the actual repair (BCD/chkdsk/registry — VMBootRepair-B.md Fix sections)

# 8. Detach, wait for propagation, swap the OS disk back exactly as in Playbook 1
```

**Rollback:** Identical safety model to Playbook 1 — only a disk copy is
ever touched. If VM creation with the encrypted disk attached hangs or
errors with a message about "encryption settings," create the repair VM
first without the disk, then attach it afterward through the portal as a
documented workaround.

</details>

<details><summary>Playbook 4 — ADE-encrypted disk unlock (Resolution 3: manual KEK/BEK unwrap — v1/dual-pass or last resort)</summary>

**When to use:** ADE v1 (dual-pass) encrypted disk, an unmanaged disk, or
when Resolutions 1 and 2 both fail on an otherwise-eligible disk.

```powershell
# On the repair VM, after installing the Az PowerShell module locally:

# 1. Identify the key vault used for encryption
az vm encryption show --name <vmName> --resource-group <rg>
# note the "sourceVault" value

# 2. Confirm your account has the required key vault access policy permissions:
#    Key Management: Get, List, Update, Create | Cryptographic: Unwrap key
#    Secrets: Get, List, Set

# 3. Retrieve the BEK secret metadata (run on the repair VM, signed into Azure)
Add-AzAccount -SubscriptionID <subscriptionId>
Get-AzKeyVaultSecret -VaultName <vaultName> |
  Where-Object { $_.Tags.MachineName -eq "<vmName>" -and $_.ContentType -match 'BEK' } |
  Sort-Object -Property Created |
  Format-Table Created,
    @{Label="ContentType"; Expression={$_.ContentType}},
    @{Label="Volume"; Expression={$_.Tags.VolumeLetter}},
    @{Label="DiskEncryptionKeyFileName"; Expression={$_.Tags.DiskEncryptionKeyFileName}},
    @{Label="URL"; Expression={$_.Id}}

# 4a. If ContentType is plain "BEK" (not wrapped), download it directly:
$vault = "<vaultName>"
$bek = "<secretNameWithoutExtension>"
$secret = Get-AzKeyVaultSecret -VaultName $vault -Name $bek
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret.SecretValue)
$bekBase64 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.IO.File]::WriteAllBytes("C:\BEK\$bek.BEK", [Convert]::FromBase64String($bekBase64))

# 4b. If ContentType is "Wrapped BEK", it must be unwrapped using the KEK — this requires
#     the dedicated unwrap script referenced in Microsoft's own procedure rather than a
#     short inline snippet, since it involves Key Vault cryptographic unwrap operations.
#     See: https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/unlock-encrypted-disk-offline#download-and-unwrap-the-bek

# 5. Unlock the volume
manage-bde -unlock <EncryptedDriveLetter>: -RecoveryKey C:\BEK\<BekFileName>.BEK

# 6. Perform the actual repair, then detach/swap as in Playbook 1
```

**Rollback:** Same disk-copy safety model as every other playbook here.
The unlock step itself is non-destructive to the encrypted volume — it
does not decrypt it, only makes it readable for the duration the repair
VM has it attached and unlocked.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Azure VM boot/disk repair diagnostic evidence for escalation.
.DESCRIPTION Read-only. Gathers power/provisioning state, generation, ADE status/version,
             managed-disk state, existing OS-disk snapshots, and boot diagnostics config
             for a single VM, then writes a summary object suitable for pasting into a
             support ticket. Does not attach, detach, or modify any disk.
.PARAMETER   ResourceGroupName  Resource group containing the target VM.
.PARAMETER   VMName             Name of the target VM.
.EXAMPLE     .\Get-AzureVMBootRepairAudit.ps1 -ResourceGroupName rg-prod -VMName vm-web01
.NOTES       Requires an authenticated Az PowerShell session (Connect-AzAccount).
             Read-only — see Azure/Compute/Scripts/Get-AzureVMBootRepairAudit.ps1 for the
             full, parameterized, fleet-capable version of this script.
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$VMName
)

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
$encStatus = Get-AzVmDiskEncryptionStatus -ResourceGroupName $ResourceGroupName -VMName $VMName -ErrorAction SilentlyContinue
$adeExt = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -ErrorAction SilentlyContinue |
    Where-Object { $_.ExtensionType -like "*DiskEncryption*" }
$osDisk = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName).StorageProfile.OsDisk
$snapshots = Get-AzSnapshot -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue |
    Where-Object { $_.CreationData.SourceResourceId -like "*$($osDisk.Name)*" }

[PSCustomObject]@{
    VMName               = $VMName
    ResourceGroup        = $ResourceGroupName
    PowerState           = ($vm.Statuses | Where-Object Code -like 'PowerState/*').DisplayStatus
    ProvisioningState    = ($vm.Statuses | Where-Object Code -like 'ProvisioningState/*').DisplayStatus
    Generation           = $vm.HyperVGeneration
    OsDiskManaged        = [bool]$osDisk.ManagedDisk
    OsDiskName           = $osDisk.Name
    ADEEncrypted         = $encStatus.OsVolumeEncrypted
    ADEExtensionVersion  = $adeExt.TypeHandlerVersion
    BootDiagnosticsOn    = $vm.DiagnosticsProfile.BootDiagnostics.Enabled
    ExistingSnapshots    = ($snapshots | Select-Object -ExpandProperty Name) -join '; '
    RecommendedPath      = if ($encStatus.OsVolumeEncrypted -eq 'Encrypted' -and $adeExt.TypeHandlerVersion -like '1.*') {
                                'Manual KEK/BEK unwrap only (Playbook 4) — ADE v1 dual-pass, no automation available'
                            } elseif ($encStatus.OsVolumeEncrypted -eq 'Encrypted') {
                                'Automated (Playbook 2, --unlock-encrypted-vm) or semi-automated (Playbook 3) — ADE v2+'
                            } elseif (-not $osDisk.ManagedDisk) {
                                'Unmanaged disk — out of scope, see linked legacy procedure'
                            } else {
                                'Automated az vm repair (Playbook 2) — unencrypted managed disk, fastest path'
                            }
} | Format-List
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AzVMBootDiagnosticsData -Windows -LocalPath <path>` | Pull the current boot screenshot + serial log |
| `Get-AzVM -Status` | Power state, provisioning state, HyperVGeneration |
| `Get-AzVmDiskEncryptionStatus` | Confirm ADE encryption state on OS/data volumes |
| `Get-AzVMExtension \| Where ExtensionType -like "*DiskEncryption*"` | ADE extension version (v1 dual-pass vs v2+ single-pass) |
| `New-AzSnapshotConfig` / `New-AzSnapshot` | Snapshot the OS disk before any offline repair |
| `New-AzDiskConfig -CreateOption Copy -SourceResourceId` / `New-AzDisk` | Create a managed disk from a snapshot |
| `Add-AzVMDataDisk` / `Remove-AzVMDataDisk` | Attach/detach a disk copy to/from a repair VM |
| `az vm repair create/run/restore` | Automated end-to-end offline repair (unencrypted or ADE v2+) |
| `az vm repair list-scripts` | Browse the community repair-script-library catalog |
| `bcdboot <winPartition>:\Windows /S <bootPartition>:` | Recreate the boot record |
| `bcdedit /store <path> /enum /v` | List BCD entries and get the Windows Boot Loader identifier |
| `bcdedit /store <path> /set {id} <property> <value>` | Repair individual BCD entry properties |
| `diskpart` → `list disk` / `sel disk` / `list partition` / `sel partition` / `active` | Verify/set the Active partition flag (Gen 1 only) |
| `chkdsk <drive>: /f` | Fix logical file system errors offline |
| `manage-bde -unlock <drive>: -RecoveryKey <bekPath>` | Unlock an ADE-encrypted volume on a repair VM |
| `manage-bde -status <drive>:` | Check BitLocker encryption/decryption progress |
| `Get-AzKeyVaultSecret -VaultName <vault>` | Retrieve BEK/KEK secret metadata for manual unlock |

---
## 🎓 Learning Pointers

- **Offline repair-VM attachment is the single unifying pattern behind every fix in this file** — BCD, chkdsk, reboot-loop registry edits, and ADE unlocking all follow the same "snapshot → attach a copy → repair → swap back" shape, even though the specific commands differ per layer. Recognizing this pattern means you always know the *next* step even when the specific error is unfamiliar.
- **Generation (1 vs 2) is a property of the VM at creation time, not something visible in a boot screenshot** — always confirm `HyperVGeneration` before running BCD commands, since Gen-1 syntax against a Gen-2 EFI partition fails silently rather than with a clear error.
- **ADE's single-pass/dual-pass distinction (extension version 2+ vs 1.x) is the actual gate on automation**, not merely a cosmetic version difference — `az vm repair --unlock-encrypted-vm` and the semi-automated BEK-volume method both only work against single-pass (v2+) encrypted disks. Confirm this before promising a fast automated turnaround to a customer.
- **Reboot loop has three architecturally distinct causes that produce an identical visual symptom** — offline log/hive inspection, not the screenshot alone, is what actually distinguishes a critical-service failure from a bad update from registry hive corruption, and picking the wrong fix wastes a full repair cycle.
- **Unlocking an ADE-encrypted disk is not the same as decrypting it** — `manage-bde -unlock` makes the volume readable for the current repair session only; the disk remains BitLocker-protected. Never run `manage-bde -off` as part of a routine repair.
- **A pre-repair snapshot is the actual rollback mechanism, not a formality** — none of the BCD, chkdsk, or registry-hive edits documented here are individually reversible once applied; the snapshot is what makes "start over" possible if a repair attempt makes things worse.
- Related: [Windows boot error (INACCESSIBLE_BOOT_DEVICE) in an Azure VM](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/windows-boot-failure), [Troubleshoot boot errors in Azure virtual machines](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/boot-error-troubleshoot), [Repair a Windows VM by using the Azure Virtual Machine repair commands](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/repair-windows-vm-using-azure-virtual-machine-repair-commands), [Unlocking an encrypted disk for offline repair](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/unlock-encrypted-disk-offline), [az vm repair CLI reference](https://learn.microsoft.com/en-us/cli/azure/vm/repair), [Windows reboot loop on an Azure VM](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/troubleshoot-reboot-loop), [Attach an unmanaged disk to a VM for offline repair](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/unmanaged-disk-offline-repair)
