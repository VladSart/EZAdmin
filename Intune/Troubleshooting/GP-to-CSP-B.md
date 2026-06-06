# Group Policy to Intune/CSP Migration — Hotfix Runbook (Mode B: Ops)
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

Run these first — they tell you which path to take:

```powershell
# 1. Check if GPO and MDM policies are both active (conflict zone)
Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" -MaxEvents 10 |
    Select-Object TimeCreated, Id, Message | Format-List

# 2. Check MDM enrollment and authority
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" |
    Select-Object UPN, ProviderID, EnrollmentState | Format-Table

# 3. Check GP vs MDM winner — look for dual authority
$mdmKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM"
if (Test-Path $mdmKey) { Get-ItemProperty $mdmKey } else { Write-Host "No MDM policy override key found" }

# 4. Check for lingering GP settings after migration
gpresult /r /scope:computer 2>&1 | Select-String -Pattern "Applied|Denied|Filtered"

# 5. Check Settings Catalog / CSP delivery in Intune event log
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 20 |
    Select-Object TimeCreated, Id, Message | Format-List
```

| Result | Next Step |
|--------|-----------|
| GPO still applying after Intune migration | → [Fix 1 — Remove / Block Legacy GPO](#fix-1--remove--block-legacy-gpo) |
| MDM setting not applying (CSP conflict) | → [Fix 2 — CSP / MDM Policy Not Landing](#fix-2--csp--mdm-policy-not-landing) |
| Setting reverts after reboot | → [Fix 3 — Policy Tattoo or Registry Remnant](#fix-3--policy-tattoo-or-registry-remnant) |
| Intune setting blocked by "MDM Wins" not enabled | → [Fix 4 — Enable MDM Over GPO](#fix-4--enable-mdm-over-gpo) |
| User settings (not device) need migration | → [Fix 5 — User-Scope CSP vs User GPO](#fix-5--user-scope-csp-vs-user-gpo) |
| CSP not available for a GP setting | → [Fix 6 — ADMX-Backed Policies in Intune](#fix-6--admx-backed-policies-in-intune) |

---
## Dependency Cascade

<details><summary>What must be true for Intune/CSP to win over Group Policy</summary>

```
Active Directory / Entra ID Hybrid Join or Entra-only join
        │
        ▼
Device enrolled in Intune (MDM authority = Intune)
        │
        ▼
[Hybrid] GPO still in scope UNLESS:
  - OU moved out of GPO scope, OR
  - GPO blocked/filtered, OR
  - "MDM Wins" override enabled (Win 10 1803+)
        │
        ▼
MDM/CSP policy delivered via Intune
  Settings Catalog → maps to CSP paths
  ADMX-backed → ingested into Intune and delivered via OMA-URI
  Custom OMA-URI → direct CSP path write
        │
        ▼
WMI Bridge writes CSP values to registry
  (HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\*)
        │
        ▼
Windows applies effective policy (CSP > GP where MDM wins is active)
        │
        ▼
Setting takes effect (may require reboot or user logoff)
```
</details>

---
## Diagnosis & Validation Flow

**1. Confirm the device is fully MDM-enrolled (not co-managed with partial authority)**
```powershell
# Check MDM enrollment status
dsregcmd /status | Select-String "MDMUrl|MDMEnrolled|AzureADJoined|DomainJoined"
# MDMEnrolled : YES = Intune enrolled
# DomainJoined : YES = GP can still apply (hybrid scenario)
```

**2. Check what Intune actually delivered for a specific setting**
```powershell
# Find the CSP key for the setting (example: BitLocker)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker" -ErrorAction SilentlyContinue

# General pattern for any CSP:
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device" |
    Select-Object PSChildName
```
Expected: your policy's settings appear under the relevant CSP node.

**3. Check what GPO is still delivering**
```powershell
# Full GP report to HTML — easiest way to see everything applied
gpresult /h C:\Temp\gp-report.html /f
Start-Process C:\Temp\gp-report.html

# Quick text summary
gpresult /r
```
Look for policies that overlap with your Intune Settings Catalog settings — these are conflict candidates.

**4. Check the MDM Diagnostic report for CSP application status**
```powershell
# Generate MDM diagnostics (saves to C:\Users\Public\Documents\MDMDiagnostics)
$diagPath = "$env:USERPROFILE\Desktop\MDMDiag"
New-Item -ItemType Directory -Path $diagPath -Force
MdmDiagnosticsTool.exe -area DeviceEnrollment;DeviceProvisioning;TPM -zip "$diagPath\MDMDiag.zip"
```
Open MDMDiag.zip → `MDMDiagReport.html` → check "Configuration sources" and "Policy values" sections.

**5. Confirm effective registry value (GP vs MDM winner)**
```powershell
# Example: check who owns the screensaver timeout setting
# GP path:
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop" -ErrorAction SilentlyContinue
# MDM/CSP path:
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeviceLock" -ErrorAction SilentlyContinue
```
If both exist, the one that writes the "effective" value wins — this depends on whether MDM-over-GPO is enabled.

---
## Common Fix Paths

<details><summary>Fix 1 — Remove / Block Legacy GPO</summary>

**When:** GPO settings are still applying on Intune-managed devices because the device is still in an OU with GPO scope.

**Option A: Move device to an OU with no GPO (cleanest)**
```powershell
# Find device's current OU
$computer = "<DeviceName>"
(Get-ADComputer -Identity $computer -Properties DistinguishedName).DistinguishedName

# Move to a "Modern Management" OU that has Block Inheritance set
# (Do this in ADUC or via AD module)
Move-ADObject -Identity "<current-DN>" -TargetPath "OU=Modern-Management,DC=domain,DC=com"
```

**Option B: Block inheritance on the OU (if you control OU design)**
Done via Group Policy Management Console → right-click OU → Block Inheritance.

**Option C: Filter out enrolled devices via WMI filter**
```
WMI Query: SELECT * FROM Win32_ComputerSystem WHERE (NOT PartOfDomain = False) AND Name NOT IN (list)
```
Or use a security group filter: deny "Apply Group Policy" permission to an "Intune-Managed-Devices" group.

**Rollback:** Move device back to original OU or remove the security filter.
</details>

<details><summary>Fix 2 — CSP / MDM Policy Not Landing</summary>

**When:** Intune shows policy as "Succeeded" for the device but the setting is not effective.

```powershell
# 1. Force a full Intune sync
Invoke-CimMethod -Namespace root\cimv2\mdm\dmmap -ClassName MDM_DMClient `
    -MethodName TriggerSync -Arguments @{ commandID = 1 }

# Wait 2-3 minutes, then check the policy manager
Start-Sleep -Seconds 120
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device" | Select-Object PSChildName

# 2. Check for errors in the Intune Management Extension log
Get-Content "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" |
    Select-String "error|fail|conflict" | Select-Object -Last 20

# 3. Check SyncML error codes in MDM diagnostic log
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" |
    Where-Object { $_.Message -like "*error*" -or $_.Id -eq 404 } |
    Select-Object TimeCreated, Id, Message | Format-List
```

**Common cause:** CSP path typo in custom OMA-URI, wrong data type (String vs Integer), or policy scope mismatch (device vs user).
</details>

<details><summary>Fix 3 — Policy Tattoo or Registry Remnant</summary>

**When:** Setting reverts to old GP value after reboot even though GP is removed.

Group Policy "tattoos" the registry when the GP is removed if the setting didn't have a defined "not configured" cleanup. The value stays until explicitly deleted.

```powershell
# Find tattooed values (common locations)
$tattooKeys = @(
    "HKLM:\SOFTWARE\Policies",
    "HKCU:\SOFTWARE\Policies",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies"
)
foreach ($key in $tattooKeys) {
    if (Test-Path $key) {
        Get-ChildItem $key -Recurse -ErrorAction SilentlyContinue |
            Select-Object PSPath
    }
}

# Delete a specific tattooed value (example: IE proxy setting)
Remove-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings" `
    -Name "ProxyEnable" -ErrorAction SilentlyContinue
```

**Rollback:** Document every value before removing. Export the key first:
```powershell
reg export "HKLM\SOFTWARE\Policies" C:\Temp\policies-backup.reg
```
</details>

<details><summary>Fix 4 — Enable MDM Over GPO</summary>

**When:** On hybrid-joined devices, GPO is winning over MDM settings because "MDM Wins" isn't enabled.

Available on Windows 10 1803+ — allows MDM/CSP to override conflicting GPO settings.

```powershell
# Check if MDM Wins is currently enabled
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM" -ErrorAction SilentlyContinue
# ControlPolicyConflict = 1 means MDM Wins is ON

# Enable via Intune (recommended) — Settings Catalog:
# Windows Components > MDM > "Prefer MDM over Group Policy"
# (This is itself a CSP setting: ./Device/Vendor/MSFT/Policy/Config/ControlPolicyConflict/MDMWinsOverGP = 1)

# Or deploy via PowerShell for testing:
$mdmKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM"
if (-not (Test-Path $mdmKey)) { New-Item -Path $mdmKey -Force }
Set-ItemProperty -Path $mdmKey -Name "ControlPolicyConflict" -Value 1 -Type DWord
```

**⚠️ Note:** This only works for policies that have a CSP equivalent. ADMX-only settings that don't have a CSP counterpart still require a GPO or ADMX ingestion in Intune.

**Rollback:** `Set-ItemProperty -Path $mdmKey -Name "ControlPolicyConflict" -Value 0 -Type DWord`
</details>

<details><summary>Fix 5 — User-Scope CSP vs User GPO</summary>

**When:** Device-scope policies migrate fine but user-scope settings (e.g., mapped drives, user IE settings) don't apply via Intune.

```powershell
# Check current user's GP-applied settings
gpresult /r /scope:user

# CSP user-scope settings are delivered under:
# ./User/Vendor/MSFT/Policy/Config/...  (not ./Device/)
# In Intune, ensure the config profile assignment is "Users" not "Devices" for user-scope CSPs

# Check user-scope MDM policy manager
Get-ChildItem "HKCU:\SOFTWARE\Microsoft\PolicyManager\current\user" -ErrorAction SilentlyContinue |
    Select-Object PSChildName
```

**Note:** Many legacy user GP settings (mapped drives, logon scripts, folder redirection) have no CSP equivalent. For these, consider PowerShell remediation scripts or Platform Scripts in Intune as replacements.
</details>

<details><summary>Fix 6 — ADMX-Backed Policies in Intune</summary>

**When:** A Group Policy setting has no native Settings Catalog equivalent, but does have an ADMX template.

Intune supports ingesting ADMX files to create custom ADMX-backed policies.

```powershell
# Step 1: Identify the ADMX and ADML files for the product
# Common sources: Office ADMX, Chrome ADMX, vendor-specific templates

# Step 2: In Intune portal (manual — no PowerShell for ADMX ingestion)
# Devices > Configuration > Import ADMX
# Upload the .admx and .adml files

# Step 3: Create a Settings Catalog profile using the imported ADMX settings

# Step 4: Verify delivery via OMA-URI (custom policy approach — alternative)
# OMA-URI: ./Device/Vendor/MSFT/Policy/ConfigOperations/ADMXInstall/<PolicyName>/Policy/<ADMX content>
# Data type: String (XML)

# Verify ADMX-backed policy landed
Get-ItemProperty "HKLM:\SOFTWARE\Policies\<vendor-path>" -ErrorAction SilentlyContinue
```

**MS Docs:** https://learn.microsoft.com/en-us/mem/intune/configuration/administrative-templates-configure-edge
</details>

---
## Escalation Evidence

```
=== GP-to-CSP Migration Escalation Package ===
Date/Time              : 
Device Name            : 
Entra Join Type        : [ ] Entra-Only  [ ] Hybrid (AD + Entra)
Intune Enrolled        : 
Domain / AD OU         : 
MDM Wins Enabled       : [ ] Yes  [ ] No  [ ] Unknown

--- Conflicting Setting ---
Setting description    : 
GP path / registry key : 
Intune CSP OMA-URI     : 
Expected value         : 
Actual value on device : 

--- GP Report Snippet ---
(paste relevant section of gpresult /r output)

--- MDM Policy Manager Key ---
# Get-ChildItem "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\<CSP-node>"

--- Intune Sync Status (from MEM portal) ---
Device compliance      : 
Last check-in          : 
Config profile status  : 

--- MDM Diagnostic Report ---
Generated at: 

--- Actions Taken ---
1. 
2. 
3. 
```

---
## 🎓 Learning Pointers

- **Hybrid join means GP never fully goes away** unless you actively remove scope. Entra-only joined devices have zero GPO — the cleaner end state for modern management. Plan the migration to Entra-only as the long-term goal if your estate permits.
- **MDM Wins (ControlPolicyConflict=1) is not magic.** It only applies to settings that have a CSP equivalent AND where Intune has configured that setting. If Intune hasn't configured a setting, GPO still owns it even with MDM Wins on. The effective policy is the union of both — Intune wins on conflicts, GPO fills in the rest.
- **Registry tattoos are the sneakiest migration problem.** When GPO is removed or the device moves OUs, the setting might still be in the registry. Always run `gpresult /h` and compare the GP registry paths against what you expect post-migration.
- **Use the GP Analytics tool in Intune** before migrating. Upload an exported GPO (XML) and Intune will map each setting to its CSP equivalent (or flag it as unsupported). This turns a weeks-long manual audit into a 30-minute task: Devices → Group Policy Analytics.
- **Platform Scripts ≠ CSP policies.** PowerShell scripts via Intune run once (or at each check-in) and are great for tattoo cleanup or setting non-CSP registry values, but they don't have the policy enforcement, conflict detection, or reporting that Settings Catalog profiles have. Use them sparingly as a bridge, not a replacement.
- **MS Docs — GP Analytics:** https://learn.microsoft.com/en-us/mem/intune/configuration/group-policy-analytics | **CSP Reference:** https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-configuration-service-provider
