# WDAC / AppLocker — Hotfix Runbook (Mode B: Ops)
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
# 1. Check if WDAC (CI) policy is enforced or audit-only
$ciPolicy = Get-CIPolicy -FilePath "$env:SystemRoot\System32\CodeIntegrity\CiPolicies\Active\*.cip" -ErrorAction SilentlyContinue
if (-not $ciPolicy) { Write-Host "No active WDAC policy found (or policy in legacy path)" }
citool --list-policies 2>$null  # Windows 11 / Server 2022+

# 2. Check Code Integrity event log for recent blocks
Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -MaxEvents 20 |
    Select-Object TimeCreated, Id, Message | Format-List

# 3. Check AppLocker enforcement mode
Get-AppLockerPolicy -Effective | Test-AppLockerPolicy -Path <blocked-app-path> -User Everyone

# 4. Check AppLocker event log
Get-WinEvent -LogName "Microsoft-Windows-AppLocker/EXE and DLL" -MaxEvents 20 |
    Select-Object TimeCreated, Id, Message | Format-List

# 5. Check Application Identity service (AppLocker dependency)
Get-Service AppIDSvc | Select-Object Name, Status, StartType
```

| Result | Next Step |
|--------|-----------|
| CI event ID 3077 (block) or 3076 (audit) | → Identify blocked binary, add rule or publisher exception |
| AppIDSvc Stopped | → [Fix 1 — AppLocker Service Not Running](#fix-1--appLocker-service-not-running) |
| New software blocked after policy push | → [Fix 2 — Add Publisher or Hash Rule](#fix-2--add-publisher-or-hash-rule) |
| WDAC policy in wrong enforcement mode | → [Fix 3 — Switch WDAC Policy to Audit Mode](#fix-3--switch-wdac-policy-to-audit-mode) |
| Conflict between WDAC and AppLocker | → [Fix 4 — Policy Conflict Resolution](#fix-4--policy-conflict-resolution) |
| Supplemental policy needed (ISV/LOB app) | → [Fix 5 — Deploy Supplemental WDAC Policy](#fix-5--deploy-supplemental-wdac-policy) |
| Policy not applying after Intune push | → [Fix 6 — Policy Deployment Verification](#fix-6--policy-deployment-verification) |

---
## Dependency Cascade

<details><summary>What must be true for WDAC/AppLocker to function correctly</summary>

```
Intune / GPO Policy Delivery
        │
        ▼
Policy File on Disk
  WDAC: C:\Windows\System32\CodeIntegrity\CiPolicies\Active\{GUID}.cip
  AppLocker: Registry (HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2)
        │
        ▼
Code Integrity Service (ci.dll — kernel-level, always running)
   OR
Application Identity Service (AppIDSvc — AppLocker only)
        │
        ▼
Policy Mode: Audit vs Enforce
  Audit  → logs blocks, allows execution (safe for rollout)
  Enforce → hard blocks execution/loading
        │
        ▼
Policy Rules (Allow / Deny / Exception)
  Publisher rules → rely on Authenticode signature
  Hash rules      → tied to exact file binary
  Path rules      → least secure, avoid for EXE/DLL
        │
        ▼
Application Execution Allowed or Blocked
```
</details>

---
## Diagnosis & Validation Flow

**1. Identify what was blocked and where**
```powershell
# WDAC blocks (Event ID 3077 = enforced block, 3076 = audit would-block)
Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" |
    Where-Object { $_.Id -in 3076, 3077 } |
    Select-Object TimeCreated, @{N="File";E={$_.Properties[1].Value}},
                  @{N="PolicyName";E={$_.Properties[6].Value}},
                  @{N="PolicyID";E={$_.Properties[7].Value}} |
    Sort-Object TimeCreated -Descending | Select-Object -First 10
```

**2. Get signer / hash info for blocked file**
```powershell
$blockedFile = "<path-to-blocked-exe>"
Get-AuthenticodeSignature -FilePath $blockedFile | Select-Object Status, SignerCertificate
Get-FileHash -FilePath $blockedFile -Algorithm SHA256
```
Expected: file is signed by a known publisher. If unsigned → hash rule required.

**3. Check active WDAC policy enforcement mode**
```powershell
# Windows 11 / Server 2022
citool --list-policies

# All Windows versions — check policy XML cached copy
$policyPath = "C:\Windows\System32\CodeIntegrity\CiPolicies\Active"
Get-ChildItem $policyPath -Filter "*.cip" | ForEach-Object {
    Write-Host "Policy: $($_.Name)"
}
```

**4. Test AppLocker policy against a specific path**
```powershell
Get-AppLockerPolicy -Effective | Test-AppLockerPolicy -Path "C:\path\to\app.exe" -User Everyone
# DeniedByPolicy = blocked; Allowed = permitted
```

**5. Verify Intune CI policy OMA-URI delivered correctly**
```powershell
# Check MDM-delivered WDAC policy
Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_AppLocker |
    Select-Object -ExpandProperty ApplicationLaunchRestrictions
```

---
## Common Fix Paths

<details><summary>Fix 1 — AppLocker Service Not Running</summary>

**When:** AppLocker rules are configured but not enforced because AppIDSvc is stopped.

```powershell
# Start the service and set to auto
Set-Service -Name AppIDSvc -StartupType Automatic
Start-Service -Name AppIDSvc

# Verify
Get-Service AppIDSvc | Select-Object Name, Status, StartType
```

**Note:** WDAC does NOT require AppIDSvc — it runs at the kernel level via ci.dll. If AppIDSvc is missing entirely, the AppLocker subsystem may be unsupported on this Windows edition (Home, for example).

**Rollback:** `Set-Service -Name AppIDSvc -StartupType Manual; Stop-Service AppIDSvc`
</details>

<details><summary>Fix 2 — Add Publisher or Hash Rule</summary>

**When:** Legitimate software is blocked by an existing policy.

**Publisher Rule (preferred — survives updates):**
```powershell
# 1. Get publisher info from the binary
$sig = Get-AuthenticodeSignature -FilePath "<blocked-exe-path>"
$publisher = $sig.SignerCertificate.Subject
Write-Host "Publisher: $publisher"

# 2. Generate a new WDAC policy from the file (use WDAC Wizard or PowerShell)
# Requires ConfigCI module (Windows 10/11 Enterprise/Education)
New-CIPolicy -FilePath "C:\Temp\Supplemental-Publisher.xml" `
    -DriverFiles (Get-SystemDriver -ScanPath "<blocked-exe-path>" -UserPEs) `
    -Level Publisher -Fallback Hash

# 3. Review, sign (optional), and deploy
```

**Hash Rule (for unsigned software — fallback):**
```powershell
$hash = (Get-FileHash -FilePath "<blocked-exe-path>" -Algorithm SHA256).Hash
# Add hash to WDAC supplemental policy XML under <Allow> section
# Or in AppLocker: New-AppLockerPolicy with file hash
```

**Rollback:** Remove the supplemental policy or hash/publisher rule, then refresh policy.
</details>

<details><summary>Fix 3 — Switch WDAC Policy to Audit Mode</summary>

**When:** Enforcement is blocking production work and you need immediate relief while investigating.

```powershell
# 1. Get the active policy GUID
citool --list-policies  # note the PolicyID

# 2. Export the policy XML for editing
# (You need the original XML — should be in source control or Intune policy)
# If you have it locally:
ConvertFrom-CIBinaryPolicy -BinaryFilePath "C:\Windows\System32\CodeIntegrity\CiPolicies\Active\<PolicyID>.cip" `
    -XmlFilePath "C:\Temp\ActivePolicy.xml"

# 3. Set to audit mode in XML
[xml]$policy = Get-Content "C:\Temp\ActivePolicy.xml"
$rule = $policy.SiPolicy.Rules.Rule | Where-Object { $_.Option -eq "Enabled:Enforce" }
if ($rule) { $rule.Option = "Enabled:Audit Mode" }
$policy.Save("C:\Temp\ActivePolicy_Audit.xml")

# 4. Recompile and refresh
ConvertFrom-CIPolicyFormat -XmlFilePath "C:\Temp\ActivePolicy_Audit.xml" `
    -BinaryFilePath "C:\Windows\System32\CodeIntegrity\CiPolicies\Active\<PolicyID>.cip"

# 5. Refresh (reboot required for full effect, or use citool on Win11)
citool --update-policy "C:\Temp\ActivePolicy_Audit.xml"
```

**⚠️ Rollback:** This reduces security posture. Re-enable enforcement as soon as the allow-list is corrected.
</details>

<details><summary>Fix 4 — Policy Conflict Resolution</summary>

**When:** WDAC and AppLocker are both deployed and conflicting (supported on Windows 11 22H2+ only; earlier builds cannot run both).

```powershell
# Check Windows version — WDAC + AppLocker coexistence requires Win 11 22H2+
(Get-WmiObject Win32_OperatingSystem).Version
(Get-WmiObject Win32_OperatingSystem).Caption

# On older builds, AppLocker is IGNORED when WDAC is present
# Confirm which policy is actually active
citool --list-policies
Get-AppLockerPolicy -Effective | Format-List
```

**Resolution:** On pre-22H2 systems, pick one. WDAC is Microsoft's recommended path going forward. AppLocker requires management via GPO or Intune's AppLocker CSP; it cannot be used alongside WDAC enforcement on older builds.

**Rollback:** Disable AppLocker by removing rules or setting all rule collections to "Not configured" in GPO/Intune.
</details>

<details><summary>Fix 5 — Deploy Supplemental WDAC Policy</summary>

**When:** A base policy is too restrictive but you cannot modify it (e.g., org-managed base policy). A supplemental policy extends it without replacing it.

```powershell
# 1. Create supplemental policy XML
# Use WDAC Policy Wizard (GUI) or PowerShell:
New-CIPolicy -FilePath "C:\Temp\Supplemental-LOB.xml" `
    -ScanPath "<path-to-app-folder>" `
    -Level Publisher -Fallback Hash -UserPEs

# 2. Mark it as supplemental and link to base policy
$basePolicyId = "<base-policy-GUID-from-citool>"
Set-CIPolicyIdInfo -FilePath "C:\Temp\Supplemental-LOB.xml" `
    -SupplementsBasePolicyID $basePolicyId `
    -PolicyName "Supplemental-LOB-Apps"

# 3. Compile
ConvertFrom-CIPolicyFormat -XmlFilePath "C:\Temp\Supplemental-LOB.xml" `
    -BinaryFilePath "C:\Temp\Supplemental-LOB.cip"

# 4. Deploy via Intune (OMA-URI) or copy to active path
# OMA-URI: ./Vendor/MSFT/ApplicationControl/Policies/{NewGUID}/Policy
# Value type: Base64 (upload the .cip file content)
```

**Rollback:** Remove the supplemental policy OMA-URI from Intune or delete the .cip from the active path and run `citool --remove-policy {GUID}`.
</details>

<details><summary>Fix 6 — Policy Deployment Verification</summary>

**When:** Policy was pushed via Intune but not applying on device.

```powershell
# Check Intune sync completed
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 30 |
    Where-Object { $_.Message -like "*ApplicationControl*" -or $_.Message -like "*AppLocker*" } |
    Select-Object TimeCreated, Id, Message | Format-List

# Check OMA-URI delivered to WMI bridge
$policies = Get-CimInstance -Namespace root\cimv2\mdm\dmmap `
    -ClassName MDM_ApplicationControl_Policies01_01 -ErrorAction SilentlyContinue
$policies | Select-Object InstanceID

# Verify .cip file appeared in active path
Get-ChildItem "C:\Windows\System32\CodeIntegrity\CiPolicies\Active" | Select-Object Name, LastWriteTime

# Force Intune sync
Invoke-CimMethod -Namespace root\cimv2\mdm\dmmap -ClassName MDM_DMClient `
    -MethodName TriggerSync -Arguments @{ commandID = 1 }
```

**Common cause:** Policy file over 4 MB hits a WMI size limit. Trim the policy or split into base + supplemental.
</details>

---
## Escalation Evidence

```
=== WDAC / AppLocker Escalation Package ===
Date/Time          : 
Device Name        : 
Windows Version    : 
Intune Enrolled    : 
Domain Joined      : 

--- Policy State ---
Active WDAC Policies (citool output)      : 
AppLocker Enforcement Mode                : 
Policy deployed via                       : [ ] Intune  [ ] GPO  [ ] Script

--- Blocked Application ---
Executable path    : 
SHA256 hash        : 
Publisher/Signer   : 
Signed?            : [ ] Yes  [ ] No

--- Event Log Snippet ---
(paste last 5 CI/Operational events — IDs 3076/3077)

--- AppLocker Test Output ---
# Test-AppLockerPolicy result:

--- Intune Policy GUID ---

--- Actions Taken ---
1. 
2. 
3. 
```

---
## 🎓 Learning Pointers

- **WDAC vs AppLocker:** WDAC is kernel-enforced and cannot be bypassed by a local admin — this is the key differentiator. AppLocker runs in user space and can be subverted by a local admin. On Windows 11 22H2+, both can coexist; on older builds, WDAC silently wins. [WDAC vs AppLocker](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/appcontrol-and-applocker-overview)
- **Audit mode first, always.** Deploying WDAC in enforce mode without an audit pass is the single biggest cause of application breakage in production. Run audit for at least 2 weeks, collect event ID 3076 blocks, build your allow-list, then switch to enforce.
- **Managed Installer is your friend for Intune shops.** Enabling the Managed Installer option in a WDAC policy automatically trusts anything deployed via Intune/SCCM, eliminating the need to enumerate every app in your allow-list. [Managed Installer docs](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/design/configure-authorized-apps-deployed-with-a-managed-installer)
- **Scripts are a separate attack surface.** WDAC policies control PE files (EXE, DLL, OCX). To also control PowerShell scripts, enable Constrained Language Mode via WDAC — this is separate from blocking executables.
- **Publisher rules survive updates; hash rules don't.** If you use hash rules for a frequently-updated app, you'll be adding new hashes every patch cycle. Use publisher rules wherever the app is signed, and hash only for truly static unsigned binaries.
- **WDAC Wizard** (free GUI from Microsoft) greatly simplifies policy creation and merging: https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/design/appcontrol-wizard
