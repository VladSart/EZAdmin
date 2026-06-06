# Windows Hello for Business — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer.

```powershell
# 1. Check WHfB provisioning state on the device
dsregcmd /status | Select-String "NgcSet","NgcKeyId","AzureAdJoined","DomainJoined","WamDefaultSet"

# 2. Check if WHfB is blocked by policy
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" -ErrorAction SilentlyContinue

# 3. Check TPM state (WHfB requires TPM 2.0)
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmActivated, ManagedAuthLevel

# 4. Check NGC key folder health
$ngcPath = "$env:LOCALAPPDATA\Microsoft\NGC"
if (Test-Path $ngcPath) { Get-ChildItem $ngcPath -Force } else { Write-Host "NGC folder missing" }

# 5. Check WHfB Intune policy assignment
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
Get-MgDeviceManagementIntent | Where-Object { $_.DisplayName -like "*Hello*" }
```

| Result | Action |
|--------|--------|
| `NgcSet: NO` | → Fix 1: Re-trigger WHfB provisioning |
| `TpmReady: False` | → Fix 2: Resolve TPM issues |
| Policy key `Enabled = 0` | → Fix 3: Fix blocking policy |
| NGC folder missing or corrupted | → Fix 4: Clear NGC keys |
| Intune policy not assigned | → Fix 5: Assign WHfB policy |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[TPM 2.0 chip — present, enabled, ready]
         |
[Device Join State]
  └─ Entra ID Joined (cloud-only) OR
  └─ Entra ID Hybrid Joined (sync'd from AD)
         |
[Primary Refresh Token (PRT) valid]
  └─ User signed in with Entra ID credentials
         |
[WHfB Policy enabled]
  └─ Intune/MDM or GPO — PassportForWork = Enabled
  └─ Key Trust or Certificate Trust configured
         |
[WHfB Provisioning flow]
  └─ OOBE or post-login prompt
  └─ PIN set / biometric enrolled
  └─ NGC key created in TPM + registered in Entra ID
         |
[User can sign in with PIN/biometric]
```

</details>

---
## Diagnosis & Validation Flow

**1. Check full device join and WHfB state**
```powershell
dsregcmd /status
```
Key fields to check:
| Field | Expected |
|-------|----------|
| `AzureAdJoined` | YES |
| `WamDefaultSet` | YES |
| `NgcSet` | YES (provisioned) |
| `NgcKeyId` | Non-empty GUID |
| `TenantId` | Matches your tenant |

**2. Check TPM readiness**
```powershell
Get-Tpm
Initialize-Tpm -AllowClear -AllowPhysicalPresence  # Only if not ready — DESTRUCTIVE
```
Expected: `TpmPresent: True`, `TpmReady: True`, `TpmEnabled: True`

**3. Review WHfB event logs**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-HelloForBusiness/Operational" -MaxEvents 30 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Format-List
```
Common error IDs: `1026` (provisioning failed), `2` (key registration failed), `1084` (policy not configured).

**4. Check for conflicting policies**
```powershell
# MDM policy wins over GPO when both exist — check both
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" -ErrorAction SilentlyContinue
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Policies\PassportForWork" -ErrorAction SilentlyContinue
```
Expected: `Enabled = 1` in one of these paths. `Enabled = 0` → Fix 3.

**5. Validate NGC key registration in Entra ID**
```powershell
Connect-MgGraph -Scopes "Device.Read.All"
$device = Get-MgDevice -Filter "displayName eq '<DeviceName>'"
$device.AlternativeSecurityIds  # Should contain NGC key thumbprint
```

---
## Common Fix Paths

<details><summary>Fix 1 — Re-trigger WHfB provisioning</summary>

Use when: Device is joined, PRT is valid, but `NgcSet: NO` and no NGC folder/keys.

```powershell
# Force provisioning via scheduled task
$task = Get-ScheduledTask -TaskName "Device-Sync" -TaskPath "\Microsoft\Windows\Workplace Join\" -ErrorAction SilentlyContinue
if ($task) { Start-ScheduledTask -TaskName "Device-Sync" -TaskPath "\Microsoft\Windows\Workplace Join\" }

# Alternatively, trigger via dsregcmd
dsregcmd /forcerecovery

# Then sign out and back in — provisioning prompt should appear on next login
# Or navigate to: Settings → Accounts → Sign-in options → Windows Hello PIN → Set up
```

**Rollback:** Non-destructive. If provisioning still fails after retry, proceed to Fix 4.

</details>

<details><summary>Fix 2 — Resolve TPM issues</summary>

Use when: `TpmReady: False` or `TpmEnabled: False`.

```powershell
# Check TPM manufacturer info
Get-Tpm
(Get-CimInstance -Namespace "root\cimv2\security\microsofttpm" -ClassName Win32_Tpm).ManufacturerVersionInfo

# Clear TPM (DESTRUCTIVE — clears all TPM-protected keys)
# Requires physical presence or UEFI confirmation
Clear-Tpm
```

**UEFI path (if PowerShell fails):** Reboot → UEFI/BIOS → Security → TPM → Enable + Clear.

**Driver update path:**
```powershell
# Check TPM driver version
Get-PnpDevice | Where-Object { $_.FriendlyName -like "*Trusted Platform*" }
# Update via Windows Update or OEM driver package
```

**Rollback:** Clearing TPM is irreversible — BitLocker recovery keys must be backed up first. Always verify BitLocker status before clearing: `Get-BitLockerVolume`.

</details>

<details><summary>Fix 3 — Fix blocking policy (GPO or Intune)</summary>

Use when: Registry key `Enabled = 0` under `PassportForWork`, or Event ID 1084.

```powershell
# Remove blocking local registry override (if set manually or by stale GPO)
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" -Name "Enabled" -ErrorAction SilentlyContinue

# Force Group Policy refresh
gpupdate /force

# Trigger Intune sync to pull correct policy
Start-Process "ms-settings:workplace"  # Opens Work/school account to sync
# Or:
Invoke-Command { Start-Service -Name "IntuneManagementExtension" }
```

**In Intune portal:** Verify the Identity Protection (WHfB) profile is assigned to the device/user group and not in conflict with another policy setting `Use Windows Hello for Business = Disabled`.

**Rollback:** Re-applying `Enabled = 1` restores WHfB. Re-run `gpupdate /force` after any GPO changes.

</details>

<details><summary>Fix 4 — Clear corrupted NGC keys</summary>

Use when: NGC folder exists but provisioning keeps failing; Event ID 1026 with key errors.

```powershell
# Step 1 — Back up NGC folder first
$ngcPath = "$env:LOCALAPPDATA\Microsoft\NGC"
Copy-Item $ngcPath "$env:TEMP\NGC_backup_$(Get-Date -f yyyyMMdd)" -Recurse -Force

# Step 2 — Take ownership and clear NGC folder (run as SYSTEM or with PsExec)
# Using PsExec: psexec -s -i powershell
$ngcPath = "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\NGC"
if (Test-Path $ngcPath) {
    $acl = Get-Acl $ngcPath
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","Allow")
    $acl.SetAccessRule($rule)
    Set-Acl $ngcPath $acl
    Remove-Item "$ngcPath\*" -Recurse -Force
}

# Step 3 — Re-trigger provisioning
dsregcmd /forcerecovery
```

**Note:** The NGC folder for WHfB keys is at `C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\NGC`, not the user profile path. Requires SYSTEM context to modify.

**Rollback:** Restore from backup folder. User will need to re-enrol their PIN/biometric.

</details>

<details><summary>Fix 5 — Assign WHfB Intune policy</summary>

Use when: No WHfB policy exists in Intune for the device.

```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All","Group.Read.All"

# Find the WHfB/Identity Protection policy
Get-MgDeviceManagementDeviceConfiguration |
    Where-Object { $_.OdataType -like "*identityProtection*" -or $_.DisplayName -like "*Hello*" } |
    Select-Object Id, DisplayName
```

**In Intune portal:**
1. Endpoint Security → Account Protection → Create policy
2. Platform: Windows 10 and later, Profile: Windows Hello for Business
3. Set `Configure Windows Hello for Business = Enable`
4. Assign to device or user group containing the affected device

**Rollback:** Remove policy assignment if it causes issues — devices retain existing WHfB keys.

</details>

---
## Escalation Evidence

```
WINDOWS HELLO FOR BUSINESS ESCALATION
======================================
Date/Time            : 
Tenant ID            : 
Device Name          : 
Join State           : (AzureAdJoined / HybridJoined / WorkplaceJoined)
NgcSet               : YES / NO
TpmReady             : YES / NO
TPM Version          : 
Policy Source        : Intune / GPO / None
Event Log Errors     : (paste Event IDs from HelloForBusiness/Operational)
NGC Folder Exists    : YES / NO
Intune Policy Name   : 
Intune Sync Status   : 
dsregcmd /status output: (attach full output)
Steps Already Tried  : 
```

---
## 🎓 Learning Pointers

- **NGC folder vs TPM** — the NGC (Next Generation Credentials) folder holds metadata about the WHfB key, but the private key never leaves the TPM. Deleting the NGC folder forces re-provisioning; it doesn't export or lose the credential — it just forces a new one to be created.
- **Key Trust vs Certificate Trust** — most cloud-only and Entra-joined deployments use Key Trust (simpler, no PKI). Hybrid environments may use Certificate Trust (requires ADFS or Entra Kerberos). Key Trust is preferred for new deployments.
- **WHfB replaces the password at the device level** — it authenticates the device to Entra ID using an asymmetric key pair; the PIN/biometric unlocks the TPM-protected key and never leaves the device or goes to Microsoft.
- **Event log is your best friend** — `Microsoft-Windows-HelloForBusiness/Operational` gives provisioning step-by-step. Error IDs 1026, 1084, and 2 cover 90% of failures.
- **Official docs:** [WHfB planning guide](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/hello-planning-guide) | [Troubleshoot WHfB](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/hello-errors-during-pin-creation)
- **Community:** [WHfB Tech Community](https://techcommunity.microsoft.com/t5/windows-it-pro-blog/bg-p/Windows-ITPro-Blog)
