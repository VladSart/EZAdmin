# Azure VM Boot & Disk Repair — Hotfix Runbook (Mode B: Ops)
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

Run these from Azure PowerShell (Az module) with a connected context. All five run in well under 60 seconds against a single VM. **Do this before touching anything destructive** — the OS disk is precious evidence, and several fixes require you to know the encryption/managed-disk state before choosing a repair path.

```powershell
# 1. Pull the current boot screenshot + serial log — classify the symptom BEFORE guessing
Get-AzVMBootDiagnosticsData -ResourceGroupName "<rg>" -Name "<vmName>" -Windows -LocalPath "C:\Temp\BootDiag"

# 2. Confirm power/provisioning state
Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status |
  Select-Object @{N='PowerState';E={($_.Statuses | Where-Object Code -like 'PowerState/*').DisplayStatus}},
                @{N='ProvisioningState';E={($_.Statuses | Where-Object Code -like 'ProvisioningState/*').DisplayStatus}}

# 3. Is the OS disk encrypted with Azure Disk Encryption? (branches the entire repair path)
Get-AzVmDiskEncryptionStatus -ResourceGroupName "<rg>" -VMName "<vmName>"

# 4. If encrypted, which ADE version — single-pass (v2+, automatable) or dual-pass (v1, manual-only)?
(Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" |
  Where-Object ExtensionType -like "*DiskEncryption*").TypeHandlerVersion

# 5. Is the OS disk managed or unmanaged? (unmanaged needs a different, older attach procedure)
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>").StorageProfile.OsDisk.ManagedDisk
# $null here means unmanaged — go to Fix 9 instead of Fix 7/8
```

| What you see | What it means |
|---|---|
| Screenshot shows "Boot failure. Reboot and Select proper Boot device" or references `INACCESSIBLE_BOOT_DEVICE` | Boot Configuration Data (BCD) is corrupted, or the boot partition lost its Active flag — go to Fix 2 |
| Screenshot shows "Scanning and repairing drive (C:)" or "Checking file system on C:" and doesn't progress for 30+ minutes | Check Disk is stuck offline-servicing the volume — go to Fix 3 |
| Screenshot shows the Windows boot logo repeating, or the VM briefly shows "running" then reboots on a loop | Reboot loop — one of three distinct causes, all handled starting at Fix 4 |
| `PowerState` isn't `VM running` | Try Fix 1 first — a plain stop/start resolves a surprising fraction of "won't boot" tickets by itself |
| `OsVolumeEncrypted` = `Encrypted` | You cannot attach this disk to a repair VM and read it directly — go to Fix 7 (encrypted-disk path) before any manual BCD/chkdsk work |
| ADE extension version is `1.x` | Dual-pass encryption — the automated `az vm repair --unlock-encrypted-vm` path does **not** work; manual BEK unwrap only (Fix 7, Resolution 3) |
| `ManagedDisk` property is `$null` | Unmanaged disk — snapshot/attach mechanics differ from the managed-disk flow used throughout this file; see Fix 9 |
| Screenshot is blank, all-black, or clearly stale | Could be a boot diagnostics storage problem rather than a guest boot problem — cross-check against `Azure/Compute/VMExtensions-A.md` Fix 6 before assuming the OS itself is broken |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Boot diagnostics (hypervisor-level — independent of everything below;
see Azure/Compute/VMExtensions-A.md for its own architecture)
  │  Read this FIRST. It works even when nothing below has started.
  ▼
Firmware boot sequence (Gen1 = legacy BIOS/MBR, Gen2 = UEFI/GPT)
  │  Generation is fixed at VM creation and cannot be changed after —
  │  determines which BCD repair commands apply (Fix 2 branches on this)
  ▼
Boot Configuration Data (BCD) store
  Gen1: <boot partition>:\boot\bcd
  Gen2: <EFI System Partition>:\EFI\Microsoft\boot\bcd
  │  Must correctly point {bootmgr} and the Windows Boot Loader identifier
  │  at the right partitions — corruption here = INACCESSIBLE_BOOT_DEVICE
  ▼
NTFS file system integrity on the Windows volume
  │  A dirty bit set here forces chkdsk at every boot until it completes —
  │  if chkdsk itself hangs, the VM never reaches this layer's exit
  ▼
Windows kernel + critical-error-control services
  │  A third-party service flagged ErrorControl=Critical that fails to
  │  start forces an automatic reboot — indistinguishable from a "boot
  │  failure" in boot diagnostics without checking the registry offline
  ▼
Guest Agent / RDP-SSH reachable ← this is where VMExtensions-A.md picks up
```

**Azure Disk Encryption (ADE) is a cross-cutting layer, not a step in this
chain** — it sits between "disk physically attached to a repair VM" and
"any of the layers above are even readable." An encrypted disk must be
unlocked (Fix 7) before chkdsk, BCD repair, or registry edits can happen at
all, regardless of which layer above is actually broken.

Key failure points:
- Generation (1 vs 2) is invisible from the portal's boot screenshot alone — running the wrong BCD command set (Gen1 syntax against a Gen2 EFI partition, or vice versa) silently does nothing
- A snapshot of the OS disk before any repair attempt is not optional — every Microsoft-documented repair path assumes you can walk back to a known-good copy if the repair itself goes wrong
- `az vm repair` requires outbound port 443 from the target VM's subnet and only runs one script at a time with a hard 90-minute timeout that cannot be extended or resumed

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Classify the symptom from the boot diagnostics screenshot**
```powershell
Get-AzVMBootDiagnosticsData -ResourceGroupName "<rg>" -Name "<vmName>" -Windows -LocalPath "C:\Temp\BootDiag"
```
Expected: a screenshot matching one of the Triage-table rows above. Screenshots can lag up to 10 minutes behind a live event — don't conclude "still broken" from an immediately-repeated pull.

**Step 2 — Confirm encryption and managed-disk state before choosing a repair mechanism**
```powershell
Get-AzVmDiskEncryptionStatus -ResourceGroupName "<rg>" -VMName "<vmName>"
```
Expected: `OsVolumeEncrypted: NotEncrypted` (simplest path) or `Encrypted` (go to Fix 7 first). Getting this wrong wastes an entire repair-VM cycle — an encrypted disk simply appears locked with no readable content when attached unprepared.

**Step 3 — Snapshot the OS disk before any offline action**
```powershell
$disk = Get-AzDisk -ResourceGroupName "<rg>" -DiskName "<osDiskName>"
$snapshotConfig = New-AzSnapshotConfig -SourceUri $disk.Id -Location $disk.Location -CreateOption Copy
New-AzSnapshot -ResourceGroupName "<rg>" -SnapshotName "<osDiskName>-presnap-$(Get-Date -Format yyyyMMddHHmm)" -Snapshot $snapshotConfig
```
Expected: snapshot resource created successfully. This is your rollback point for every fix below — do not skip it, even under ticket-pressure time constraints.

**Step 4 — Choose the repair path**
Unencrypted or ADE v2 (single-pass) managed disk, and public IP allowed on a repair VM → automated `az vm repair` (Fix 7's "Resolution 1" pattern, fastest). Same disk state but no public IP allowed → manual snapshot/attach/repair (Fix 2/3/4 as needed). ADE v1 (dual-pass) or unmanaged disk → manual-only path (Fix 7 Resolution 3, or Fix 9).

**Step 5 — Perform the repair on the attached/repair-VM copy**
Specific commands are in the Fix section matching your Step 1 classification.

**Step 6 — Swap the repaired disk back and validate**
```powershell
# Portal: source (failed) VM > Disks > Swap OS disk > select the repaired disk
# Or, if using az vm repair:
az vm repair restore -g <rg> -n <vmName> --verbose
```
Expected: the VM starts and boot diagnostics shows a normal login/desktop screen within a few minutes.

**Step 7 — Confirm the VM is actually usable, not just "started"**
```powershell
Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -Name "<vmName>" -CommandId 'RunPowerShellScript' -ScriptString "Get-Service RdAgent, WindowsAzureGuestAgent | Select Name, Status"
```
Expected: `PowerState/running`, both agent services `Running`. If Run Command itself doesn't work yet, that's a separate problem — see `Azure/Compute/VMExtensions-B.md`.

---
## Common Fix Paths

<details><summary>Fix 1 — Simple stop/deallocate and start</summary>

**Cause:** A transient platform-level hiccup or a stuck update reboot resolves itself on a clean stop/start for a meaningful fraction of "won't boot" tickets — always try this before anything destructive.

```powershell
Stop-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Force
Start-Sleep -Seconds 30
Start-AzVM -ResourceGroupName "<rg>" -Name "<vmName>"
# Re-pull boot diagnostics after ~5 minutes
Get-AzVMBootDiagnosticsData -ResourceGroupName "<rg>" -Name "<vmName>" -Windows -LocalPath "C:\Temp\BootDiag"
```

**Rollback note:** N/A — non-destructive, no data risk. If this doesn't clear the symptom, proceed to the fix matching your Triage classification.

</details>

<details><summary>Fix 2 — INACCESSIBLE_BOOT_DEVICE / BCD repair</summary>

**Cause:** The Boot Configuration Data is corrupted, or the Windows partition lost its Active flag (Generation 1 VMs only — Generation 2/UEFI VMs don't use an active partition at all).

```console
:: Run as administrator ON THE REPAIR VM, against the attached failed disk

:: 1. Recreate the boot record (creates a fresh BCD entry pointing at the Windows partition)
bcdboot <WindowsPartitionLetter>:\Windows /S <BootPartitionLetter>:

:: 2. Generation 1 only — verify/set the Active flag via DISKPART
diskpart
list disk
sel disk <N>
list partition
sel partition <N>
detail partition
active
exit

:: 3. Check filesystem integrity before trusting the BCD edit below
chkdsk <WindowsPartitionLetter>: /f

:: 4. Get the Windows Boot Loader identifier (NOT Windows Boot Manager) — Generation 1:
bcdedit /store <BootPartitionLetter>:\boot\bcd /enum /v
:: Generation 2:
bcdedit /store <EFIPartitionLetter>:EFI\Microsoft\boot\bcd /enum /v

:: 5. Repair the BCD entries — Generation 1 (replace <Identifier> with the value from step 4):
bcdedit /store <BootPartitionLetter>:\boot\bcd /set {bootmgr} device partition=<BootPartitionLetter>:
bcdedit /store <BootPartitionLetter>:\boot\bcd /set {bootmgr} integrityservices enable
bcdedit /store <BootPartitionLetter>:\boot\bcd /set {<Identifier>} device partition=<WindowsPartitionLetter>:
bcdedit /store <BootPartitionLetter>:\boot\bcd /set {<Identifier>} integrityservices enable
bcdedit /store <BootPartitionLetter>:\boot\bcd /set {<Identifier>} recoveryenabled Off
bcdedit /store <BootPartitionLetter>:\boot\bcd /set {<Identifier>} osdevice partition=<WindowsPartitionLetter>:
bcdedit /store <BootPartitionLetter>:\boot\bcd /set {<Identifier>} bootstatuspolicy IgnoreAllFailures

:: Generation 2 (replace <Identifier> and <EFIPartitionLetter> accordingly):
bcdedit /store <EFIPartitionLetter>:EFI\Microsoft\boot\bcd /set {bootmgr} device partition=<EFIPartitionLetter>:
bcdedit /store <EFIPartitionLetter>:EFI\Microsoft\boot\bcd /set {bootmgr} integrityservices enable
bcdedit /store <EFIPartitionLetter>:EFI\Microsoft\boot\bcd /set {<Identifier>} device partition=<WindowsPartitionLetter>:
bcdedit /store <EFIPartitionLetter>:EFI\Microsoft\boot\bcd /set {<Identifier>} integrityservices enable
bcdedit /store <EFIPartitionLetter>:EFI\Microsoft\boot\bcd /set {<Identifier>} recoveryenabled Off
bcdedit /store <EFIPartitionLetter>:EFI\Microsoft\boot\bcd /set {<Identifier>} osdevice partition=<WindowsPartitionLetter>:
bcdedit /store <EFIPartitionLetter>:EFI\Microsoft\boot\bcd /set {<Identifier>} bootstatuspolicy IgnoreAllFailures
```

If the disk has only one partition (BCD folder and Windows folder on the same volume), replace every `partition=<Letter>:` argument above with the literal word `boot` instead.

**Rollback note:** All commands operate against the attached copy only, and you took a snapshot in Diagnosis Step 3 — if the BCD edit makes things worse, discard the repair-VM copy and start again from the snapshot rather than trying to "un-edit" bcdedit changes.

</details>

<details><summary>Fix 3 — Check Disk (chkdsk) stuck offline</summary>

**Cause:** An NTFS dirty-bit event forces chkdsk at boot; if it hangs online, running it offline against the attached disk usually completes where the boot-time pass didn't.

```console
:: On the repair VM, against the attached disk's drive letter
chkdsk <DriveLetter>: /f
```

**Rollback note:** `chkdsk /f` can modify file system metadata to fix errors — this is why Diagnosis Step 3's snapshot exists. Do not run `/r` unless you've separately confirmed disk-level (not just filesystem-level) integrity is also in question, as it's substantially slower with no added benefit here.

</details>

<details><summary>Fix 4 — Reboot loop, cause 1: critical service failing to start</summary>

**Cause:** A third-party (or Azure agent) service is flagged `ErrorControl = Critical` (value `2`) and fails to start, forcing Windows to automatically reboot rather than continue.

```
1. On the repair VM, with the failed disk attached and Online in Disk Management:
2. Copy \Windows\System32\config to a backup location first
3. regedit > HKEY_LOCAL_MACHINE > File > Load Hive > browse to \Windows\System32\config\SYSTEM
   > name it BROKENSYSTEM
4. Check which ControlSet is active:
   HKEY_LOCAL_MACHINE\BROKENSYSTEM\Select\Current
5. Check the criticality of the VM agent service (adjust ControlSet00x to match step 4):
   HKEY_LOCAL_MACHINE\BROKENSYSTEM\ControlSet00x\Services\RDAgent\ErrorControl
6. If set to 2, change it to 1. Also check and correct these if present and set to 2 or 3:
   HKEY_LOCAL_MACHINE\BROKENSYSTEM\ControlSet00x\Services\AzureWLBackupCoordinatorSvc\ErrorControl
   HKEY_LOCAL_MACHINE\BROKENSYSTEM\ControlSet00x\Services\AzureWLBackupInquirySvc\ErrorControl
   HKEY_LOCAL_MACHINE\BROKENSYSTEM\ControlSet00x\Services\AzureWLBackupPluginSvc\ErrorControl
7. Select BROKENSYSTEM > File > Unload Hive
8. Detach the disk from the repair VM, wait ~2 minutes for Azure to release it
9. Re-create the original VM from the OS disk (specialized deployment)
10. If this fixed it, reinstall the Guest Agent (WaAppAgent.exe) on the recovered VM
```

**Rollback note:** You edited an offline registry hive on a snapshot-backed disk — if the wrong service's ErrorControl was changed, revert from the pre-edit backup copy of the `config` folder rather than guessing at the original value.

</details>

<details><summary>Fix 5 — Reboot loop, cause 2: bad update or application install</summary>

**Cause:** A recent Windows Update, application install, or policy change is the trigger — check Event Logs, `CBS.log`, and `Windows Update.log` on the attached disk to confirm before acting.

```
Restore the VM to Last Known Good Configuration, following:
https://support.microsoft.com/help/4016731/
```

**Rollback note:** Last Known Good Configuration only reverts driver/service registry state from the most recent successful boot — it does not undo file changes made by the update/install itself. If the underlying update is still present, plan a follow-up remediation once the VM is stable again.

</details>

<details><summary>Fix 6 — Reboot loop, cause 3: registry hive corruption (last resort)</summary>

**Cause:** The active registry hive itself is corrupted. This is the least-preferred fix — restoring from `regback` reintroduces data loss for anything changed between the backup timestamp and now.

```
1. With the disk attached and Online on the repair VM:
2. Copy \Windows\System32\config to a backup location first
3. Copy the contents of \Windows\System32\config\regback into \Windows\System32\config
   (overwriting the current hive files)
4. Detach the disk, wait ~2 minutes, re-create the VM from the OS disk (specialized deployment)
```

**Rollback note:** Explicitly a last resort per Microsoft's own guidance — the restored OS is not considered fully stable, since registry state between the regback timestamp and the failure is lost. Plan to migrate data off this VM and rebuild rather than treating it as a permanent fix.

</details>

<details><summary>Fix 7 — Automated repair via `az vm repair` (preferred when eligible)</summary>

**Cause / when to use:** Fastest path for an unencrypted managed disk, or a managed disk using ADE single-pass (v2+) encryption, provided your environment allows a repair VM with a public IP (or see the semi-automated BEK-unlock note below if it doesn't).

```azurecli
az extension add -n vm-repair
# or, if already installed:
az extension update -n vm-repair

# Step 1 — create the repair VM and attach a copy of the failed OS disk
az vm repair create -g <rg> -n <vmName> --repair-username <user> --repair-password '<StrongPassword!>' --verbose
# If the disk is ADE-encrypted (single-pass only), add:
az vm repair create -g <rg> -n <vmName> --repair-username <user> --repair-password '<StrongPassword!>' --unlock-encrypted-vm --verbose

# Step 2 — run a specific repair script (see `az vm repair list-scripts` for the catalog),
# or connect to the repair VM and perform manual mitigation (Fix 2/3/4 commands above)
az vm repair run -g <rg> -n <vmName> --run-on-repair --run-id <script-id> --verbose

# Step 3 — swap the repaired disk back onto the original VM
az vm repair restore -g <rg> -n <vmName> --verbose
```

**Encrypted-disk detail:** if the disk is single-pass (v2+) ADE but a public IP isn't permitted for the repair VM, use the **semi-automated** method instead — attach a disk copy at repair-VM creation time (which auto-populates a BEK volume), assign it a drive letter, then `manage-bde -unlock <encryptedDrive>: -RecoveryKey <bekDrive>:\<name>.BEK`. If the disk is ADE v1 (dual-pass) or unmanaged, neither automated method applies — see the manual KEK-unwrap procedure in `VMBootRepair-A.md`.

**Rollback note:** `az vm repair create` never modifies the original VM's OS disk — it operates on a copy. If `restore` produces a worse outcome, the pre-repair snapshot from Diagnosis Step 3 remains your ground-truth rollback point. Only one repair script can run at a time and it cannot be canceled once started — plan around the 90-minute hard timeout.

</details>

<details><summary>Fix 8 — Disk shows locked when attached (ADE encrypted, manual path)</summary>

**Cause:** Azure Disk Encryption is enabled and the disk was attached without going through an unlock procedure — it will show as a locked BitLocker volume with zero readable content.

```powershell
# Confirm ADE version first (Triage step 4) — this determines which resolution applies
# v2+ (single-pass), public IP allowed  -> use Fix 7's automated --unlock-encrypted-vm path
# v2+ (single-pass), no public IP       -> semi-automated BEK-volume method (Fix 7 detail above)
# v1 (dual-pass) or unmanaged           -> manual KEK/BEK unwrap only (full procedure in -A.md)

# Once unlocked, on the repair VM:
manage-bde -unlock <EncryptedDriveLetter>: -RecoveryKey <BekDriveLetter>:\<BekFileName>.BEK
```

**Rollback note:** Unlocking does **not** decrypt the disk — it remains BitLocker-protected while attached. Do not run `manage-bde -off` unless you specifically intend to permanently decrypt the volume; that's a separate, deliberate action, not a side effect of repair.

</details>

<details><summary>Fix 9 — Unmanaged OS disk (legacy)</summary>

**Cause:** Pre-managed-disk VMs (VHD-backed, in a storage account) use a different attach/repair mechanic than everything above, which assumes managed disks throughout.

```
Follow: https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/unmanaged-disk-offline-repair
This repo does not duplicate the full unmanaged-disk procedure — it is
materially different at the blob/VHD level, and unmanaged disks are rare
enough in current environments that the MS Learn article is kept as the
single source of truth rather than risking drift from a second copy here.
```

**Rollback note:** N/A — follow the linked procedure's own snapshot/backup guidance before attaching.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Azure VM Boot / Disk Repair

Subscription / Resource group / VM name: ____________
Boot diagnostics screenshot classification (BCD / chkdsk / reboot loop / blank): ____________
VM Generation (1 = BIOS/MBR, 2 = UEFI/GPT): ____________
OS disk encrypted with ADE? Version (v1 dual-pass / v2+ single-pass): ____________
OS disk managed or unmanaged: ____________
Pre-repair snapshot name + timestamp: ____________
Repair path attempted (automated az vm repair / manual attach / BEK unlock): ____________
Exact bcdedit/chkdsk/regedit output or error (paste verbatim): ____________
az vm repair create/run/restore command output (if used): ____________
Post-repair boot diagnostics screenshot attached (yes/no, timestamp): ____________

Steps already attempted:
[ ] Stop/deallocate + start (Fix 1)
[ ] Classified the exact boot diagnostics symptom before acting
[ ] Took a pre-repair snapshot of the OS disk
[ ] Confirmed ADE encryption state and version before choosing a repair path
[ ] Attempted the fix matching the classified symptom
[ ] Swapped the disk back / ran az vm repair restore
[ ] Re-validated with a fresh boot diagnostics pull and Run Command service check
```

---
## 🎓 Learning Pointers

- **INACCESSIBLE_BOOT_DEVICE almost always means the BCD store, not the disk itself, is broken** — `bcdboot` + `bcdedit` recovery fixes the overwhelming majority of cases without needing to touch the actual Windows installation. Treat a full disk-integrity investigation as the fallback, not the first move.
- **Generation (1 vs 2) is not visible from the boot screenshot** — running Generation-1 `bcdedit` syntax against a Generation-2 EFI partition (or vice versa) silently accomplishes nothing. Confirm generation via `Get-AzVM` properties before touching BCD commands.
- **A snapshot before any offline repair is the actual safety net, not the repair procedure itself.** Every Microsoft-documented path in this topic assumes you can discard a failed repair attempt and start over from a known-good copy — skipping this step turns a routine repair into a genuine incident if something goes wrong mid-edit.
- **ADE encryption version (single-pass v2+ vs dual-pass v1) determines whether automation is even possible**, not just which commands to run — `az vm repair --unlock-encrypted-vm` only works for single-pass disks. Check this before promising a fast turnaround on an encrypted VM.
- **Unlocking an encrypted disk on a repair VM does not decrypt it.** The volume stays BitLocker-protected throughout the repair; `manage-bde -off` is a separate, deliberate, and much slower action that should never be run as a side effect of troubleshooting.
- **`az vm repair` can only run one script at a time, cannot be canceled once started, and has a hard 90-minute timeout with no resume** — for a script you expect to run long (the repair-script-library's own `win-sfc-sf-corruption` is the documented example), run the equivalent commands locally via Azure CLI rather than inside Cloud Shell's session limits.
- Related: [Windows boot error (INACCESSIBLE_BOOT_DEVICE) in an Azure VM](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/windows-boot-failure), [Troubleshoot a Windows VM by attaching the OS disk to a repair VM](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/troubleshoot-recovery-disks-portal-windows), [Repair a Windows VM by using the Azure Virtual Machine repair commands](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/repair-windows-vm-using-azure-virtual-machine-repair-commands), [Unlocking an encrypted disk for offline repair](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/unlock-encrypted-disk-offline), [Windows reboot loop on an Azure VM](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/troubleshoot-reboot-loop), [Windows shows "checking file system" when booting an Azure VM](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/troubleshoot-check-disk-boot-error)
