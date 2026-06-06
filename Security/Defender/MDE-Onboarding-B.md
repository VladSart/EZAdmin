# MDE Onboarding — Hotfix Runbook (Mode B: Ops)
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

Run on the affected device (elevated PowerShell):

```powershell
# 1 — Onboarding registry status
$ob = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -EA SilentlyContinue
[PSCustomObject]@{
    OnboardingState = $ob.OnboardingState   # 1 = onboarded, 0 = not
    OrgId           = $ob.OrgId
    SenseIsRunning  = $ob.SenseIsRunning    # 1 = sensor up
}

# 2 — SENSE service
Get-Service "Sense" | Select-Object Name, Status, StartType

# 3 — MDM enrolment check (Intune channel)
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" |
    Get-ItemProperty | Select-Object UPN, EnrollmentState, ProviderID

# 4 — Recent MDE event log errors
Get-WinEvent -LogName "Microsoft-Windows-SENSE/Operational" -MaxEvents 20 -EA SilentlyContinue |
    Where-Object LevelDisplayName -ne "Information" |
    Select-Object TimeCreated, Id, Message

# 5 — Quick health dump
& "C:\Program Files\Windows Defender Advanced Threat Protection\MsSense.exe" -health 2>&1 | Select-Object -First 30
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| `OnboardingState = 0` | Package not applied or MDM scope missing | Fix 1 |
| `Sense = Stopped`, StartType Disabled | Tamper Protection or policy conflict disabled service | Fix 2 |
| Service running but portal shows device absent | Cloud connectivity issue or duplicate device object | Fix 3 |
| MDM enrolment empty / wrong ProviderID | Device not enrolled in Intune — MDE config not delivered | Fix 4 |
| SENSE event ID 15 / 16 errors | Onboarding package mismatch or org ID conflict | Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true for MDE onboarding to succeed</summary>

```
[Network: HTTPS to *.securitycenter.windows.com, *.ods.opinsights.azure.com]
    └── [Azure AD device object exists and is healthy]
            └── [Intune MDM enrolment active (for MDM-based onboarding)]
                    └── [MDE onboarding config profile pushed via Intune]
                            └── [SENSE service: Running, Automatic]
                                    └── [Onboarding registry key populated (OrgId set)]
                                            └── [Device appears in MDE portal within ~15 min]
```

**GPO-based onboarding path:**
```
[Group Policy Object: WindowsDefenderATP.admx applied]
    └── [Onboarding package script run as SYSTEM]
            └── [Same SENSE service and registry outcome as above]
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm OS eligibility**
```powershell
(Get-WmiObject Win32_OperatingSystem).Caption
(Get-WmiObject Win32_OperatingSystem).BuildNumber
```
Expected: Windows 10 1709+ (build 16299+), Windows 11, or Server 2019+. Earlier builds require MMA agent — different onboarding method.

**Step 2 — Check onboarding registry key**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"
```
Good: `OnboardingState = 1`, `OrgId` matches your tenant GUID.
Bad: Key missing or `OnboardingState = 0` → package was never applied or failed silently.

**Step 3 — Confirm SENSE service**
```powershell
Get-Service "Sense"
sc.exe qc sense
```
Good: `Status: Running`, `START_TYPE: AUTO_START`.
Bad: Disabled or stopped without a crash → check Tamper Protection (`Tamper-Protection-B.md`) before trying to start it.

**Step 4 — Check network connectivity**
```powershell
$endpoints = @(
    "winatp-gw-cus.microsoft.com",
    "winatp-gw-eus.microsoft.com",
    "us-v20.events.data.microsoft.com",
    "settings-win.data.microsoft.com"
)
$endpoints | ForEach-Object {
    [PSCustomObject]@{
        Endpoint = $_
        TCP443   = (Test-NetConnection $_ -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded
    }
}
```
Bad: Any `False` → proxy/firewall blocking MDE telemetry. Check proxy exclusions.

**Step 5 — Confirm device in portal**
After onboarding, navigate to: **security.microsoft.com → Assets → Devices**. Allow up to 15 minutes for first appearance. Filter by device name.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Onboarding package not applied (OnboardingState = 0)</summary>

**Via Intune (MDM):**
1. In Intune portal → Endpoint Security → Endpoint Detection and Response
2. Create or re-assign an EDR policy targeting the device's group
3. On the device, force MDM sync:
```powershell
# Force Intune sync
Start-Process "$env:windir\system32\deviceenroller.exe" -ArgumentList "/o $env:COMPUTERNAME /c /cwd" -Wait
# Or via scheduled task:
Get-ScheduledTask | Where-Object TaskName -like "*Schedule*Sync*" | Start-ScheduledTask
```
4. Wait 5 minutes, re-check registry.

**Via Script (manual re-onboard):**
```powershell
# Download fresh onboarding package from security.microsoft.com
# Settings > Endpoints > Onboarding > Windows 10/11 > Download package
# Extract and run:
# WindowsDefenderATPOnboardingScript.cmd  (run as SYSTEM or elevated admin)

# Validate after running:
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" |
    Select-Object OnboardingState, OrgId
```

**Rollback:** Offboarding removes the device from MDE. Use only if org mismatch — not reversible from portal side for 30 days.
</details>

<details>
<summary>Fix 2 — SENSE service stopped or disabled</summary>

First check Tamper Protection — if enabled, you cannot change Defender services directly.
```powershell
Get-MpComputerStatus | Select-Object IsTamperProtected, TamperProtectionSource
```

If Tamper Protection is OFF:
```powershell
# Re-enable and start SENSE
Set-Service -Name "Sense" -StartupType Automatic
Start-Service -Name "Sense"
Get-Service "Sense"
```

If Tamper Protection is ON but blocking a legitimate change, see `Tamper-Protection-B.md` for the Intune-managed disable procedure.

**Root cause check:** look for GPO or Intune config that sets `DisableAntiSpyware` or disables SENSE:
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -EA SilentlyContinue |
    Select-Object DisableAntiSpyware, DisableRoutinelyTakingAction
```
If `DisableAntiSpyware = 1` is present from policy, fix the Intune/GPO source — not the registry directly.
</details>

<details>
<summary>Fix 3 — Device not appearing in portal (service healthy, onboarding state = 1)</summary>

**Check for duplicate/stale device object:**
```powershell
# Get machine GUID to identify in portal
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" |
    Select-Object OrgId, MachineId
```
In the portal: search for the `MachineId` value. If a stale object exists with the same hostname, offboard and delete the old one.

**Force telemetry flush:**
```powershell
Restart-Service "Sense" -Force
# Wait 2 minutes then check portal
```

**Connectivity test with diagnostic tool:**
```powershell
# Run MDE Client Analyzer (download from MS)
# https://aka.ms/MDEClientAnalyzer
# MDE_ClientAnalyzer.cmd or MDE_ClientAnalyzer.ps1
```

**Portal cache:** new devices can take up to 24 hours in edge cases. Check Events tab for any telemetry.
</details>

<details>
<summary>Fix 4 — Device not enrolled in Intune (no MDM enrollment)</summary>

MDE config cannot be delivered without Intune enrollment. Check enrollment status:
```powershell
dsregcmd /status | Select-String -Pattern "(AzureAdJoined|EnterpriseJoined|DomainJoined|MDMUrl)"
```
Expected for Intune-managed: `AzureAdJoined: YES`, `MDMUrl` populated.

If not enrolled:
- For AADJ devices: re-trigger auto-enrollment via Settings > Accounts > Access Work or School > re-connect
- For Hybrid-joined: check `EntraID/Troubleshooting/HybridJoin-B.md`
- For GPO-enrolled: verify `SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM` is set

After resolving enrollment, MDE EDR policy will deliver within ~15 minutes of next sync.
</details>

<details>
<summary>Fix 5 — OrgId mismatch / wrong tenant</summary>

Device was previously onboarded to a different tenant (common in MSP re-provisioning scenarios):
```powershell
# Check current OrgId
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status").OrgId

# Compare to your tenant ID:
# Azure Portal > Azure Active Directory > Overview > Tenant ID
```

If OrgId is wrong:
1. **Offboard first** using the correct offboarding package from the OLD tenant (if accessible), OR
2. Run the offboarding script from the new tenant's portal (Settings > Endpoints > Offboarding)
3. Reboot
4. Apply new tenant's onboarding package
5. Reboot again

```powershell
# After offboard + re-onboard, verify:
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" |
    Select-Object OnboardingState, OrgId, SenseIsRunning
```

**Note:** Offboarding is not instantaneous — allow 15 minutes before re-onboarding.
</details>

---

## Escalation Evidence

```
=== MDE ONBOARDING ESCALATION ===
Date/Time      : 
Engineer       : 
Ticket         : 

Device Name    : 
OS Version     : 
Build Number   : 
AAD Join State : (output of: dsregcmd /status | findstr "AzureAdJoined")
MDM Enrolled   : (Yes/No — check Intune portal)

OnboardingState: (reg value)
OrgId          : (reg value — confirm matches tenant)
SenseStatus    : (Running / Stopped / Disabled)
TamperProtect  : (Get-MpComputerStatus | Select IsTamperProtected)

Network Tests  : (paste results of Test-NetConnection block above)
SENSE Log Errs : (paste last 5 error events from Microsoft-Windows-SENSE/Operational)
MsSense -health: (paste first 30 lines)

Steps Attempted:
1. 
2. 
3. 

Expected behaviour : Device visible in MDE portal, SENSE running
Actual behaviour   : 
```

---

## 🎓 Learning Pointers

- **MDE uses the SENSE service** (`SenseCncProxy` on older builds) — not Windows Defender AV. AV can be disabled and MDE still works; SENSE is the EDR sensor. [MS Docs: MDE architecture](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/microsoft-defender-endpoint)
- **Intune is the preferred channel** but MDM policy conflicts (multiple MDM authorities) silently block delivery. Always check `dsregcmd /status` enrollment state first.
- **OrgId mismatches** are the #1 cause of "device not appearing" after re-imaging in MSP environments — always offboard before re-onboarding to a new tenant.
- **15-minute portal lag** is normal for first-time onboarding; waiting before escalating saves unnecessary escalation cycles.
- **MDE Client Analyzer** (`aka.ms/MDEClientAnalyzer`) automates most triage steps here — worth running when you have multiple affected devices.
- **Tamper Protection blocks service manipulation** — don't attempt `sc.exe stop sense` or registry edits while Tamper Protection is active; use Intune exclusion window instead. See `Tamper-Protection-B.md`.
