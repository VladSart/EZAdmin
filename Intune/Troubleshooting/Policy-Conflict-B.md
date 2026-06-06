# Intune Policy Conflicts — Hotfix Runbook (Mode B: Ops)

> Policy not applying, MDM vs GPO fight, compliance stuck, settings catalog conflict. Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

```powershell
# 1 — Check device join and MDM enrollment state
dsregcmd /status
# Key fields:
#   AzureAdJoined       : YES (must be YES for Intune policies)
#   MDMUrl              : https://manage.microsoft.com (must be present)
#   MDMEnrollmentURL    : https://enrollment.manage.microsoft.com/... (must be present)
#   AzureAdPrt          : YES (if NO — identity broken, fix that first)

# 2 — Check the MDM diagnostic event log (richest source of policy errors)
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" `
  -MaxEvents 50 |
  Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
  Sort-Object TimeCreated -Descending |
  Select-Object TimeCreated, Id, Message |
  Format-Table -Wrap

# 3 — Check Operational log for policy application events
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Operational" `
  -MaxEvents 100 |
  Sort-Object TimeCreated -Descending |
  Select-Object TimeCreated, Id, Message -First 30 |
  Format-Table -Wrap

# 4 — Check for GPO/CSP conflicts on a specific registry key
# (example: BitLocker CSP key often conflicts with GPO)
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\FVE" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device" -ErrorAction SilentlyContinue

# 5 — Check last MDM sync time
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Enrollments\*" |
  Where-Object { $_.ProviderID -eq "MS DM Server" } |
  Select-Object EnrollmentState, LastMDMRefreshTime, MDMDeviceID
```

**Interpret:**

| Symptom | Likely Cause | Go to |
|---------|-------------|-------|
| `MDMUrl` empty in dsregcmd | Device not MDM enrolled | [Fix 1](#fix-1--device-not-properly-enrolled) |
| Event 404 / 405 in MDM log | Policy targeting wrong group | [Fix 2](#fix-2--fix-policy-group-targeting) |
| Event 406 — CSP not supported | Settings catalog profile using unsupported CSP on this OS build | [Fix 4](#fix-4--resolve-settings-catalogcsp-conflict) |
| Policy shows "Conflict" in portal | Two policies setting same key with different values | [Fix 4](#fix-4--resolve-settings-catalogcsp-conflict) |
| Policy shows "Error" in portal | CSP write failure — often GPO holding the key | [Fix 3](#fix-3--clear-conflicting-gpo-csp-keys) |
| Compliance stuck "Not evaluated" | Device hasn't synced recently | [Fix 5](#fix-5--force-mdm-policy-sync) |
| Compliance stuck "Not compliant" after fix | Compliance policy reassessment needed | [Fix 6](#fix-6--force-compliance-reassessment) |
| Setting appears in registry but GPO value wins | MDM vs GPO precedence issue for non-CSP key | [Fix 3](#fix-3--clear-conflicting-gpo-csp-keys) |

---

## Dependency Cascade

<details><summary>What must be true for an Intune policy to apply correctly</summary>

```
MDM Authority = Microsoft Intune (not co-management/SCCM unless intentional)
    → Device is Entra Joined or Hybrid Entra Joined (HAADJ)
        → Device is MDM enrolled (MDMUrl present in dsregcmd)
            → Device is in the correct Entra security group
                → Policy is assigned to that group (not excluded)
                    → Policy targets correct scope (User vs Device)
                        → CSP key is writable (not locked by GPO ADMX)
                            → No conflicting policy sets same key differently
                                → Device has synced recently (< 8 hrs for standard, 30 min for sync-forced)
                                    → Compliance policy evaluates AFTER config profile applies
```

**Co-management note:** If the Workload slider for "Device Configuration" is set to Intune in co-management, GPO policies still apply unless explicitly blocked. MDM wins for CSP-equivalent keys; GPO wins for everything else.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm MDM enrollment and authority**
```powershell
# Check MDM enrollment via registry
$enrollments = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" -ErrorAction SilentlyContinue
foreach ($e in $enrollments) {
    $props = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
    if ($props.ProviderID -eq "MS DM Server") {
        Write-Host "Enrollment ID : $($e.PSChildName)"
        Write-Host "State         : $($props.EnrollmentState)"  # 1=enrolled
        Write-Host "UPN           : $($props.UPN)"
        Write-Host "Last Sync     : $($props.LastMDMRefreshTime)"
    }
}
```
Expected: `EnrollmentState = 1`, `LastMDMRefreshTime` within the last 8 hours.

**Step 2 — Check which policies the device is receiving**
```
Intune Admin Center (intune.microsoft.com)
→ Devices → [find device] → Device configuration
→ Each profile listed with: Succeeded / Error / Conflict / Pending / Not applicable
→ Click into "Error" or "Conflict" profiles → shows exact setting name and conflict source
```

**Step 3 — Verify device group membership**
```powershell
Connect-MgGraph -Scopes "Device.Read.All","GroupMember.Read.All"

# Get device object
$device = Get-MgDevice -Filter "displayName eq '<DeviceName>'"

# Check group memberships
Get-MgDeviceMemberOf -DeviceId $device.Id |
  Select-Object -ExpandProperty AdditionalProperties |
  ForEach-Object { $_.displayName }
```
Confirm the device is in the group the policy is assigned to. Entra group membership can take up to 15 minutes to propagate.

**Step 4 — Check for GPO conflicts on specific keys**
```powershell
# Generate a full GPO RSoP report (run as admin on device)
gpresult /H C:\Temp\GPReport.html /F
# Open in browser — look for settings that overlap with your Intune profile

# Quick check for specific GPO policy paths that frequently conflict:
$conflictPaths = @(
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate",        # WU policies
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender",             # Defender
    "HKLM:\SOFTWARE\Policies\Microsoft\FVE",                          # BitLocker
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System",               # AppLocker/WDAC
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"          # DNS
)
foreach ($path in $conflictPaths) {
    if (Test-Path $path) {
        Write-Host "`n=== $path ===" -ForegroundColor Yellow
        Get-ItemProperty $path
    }
}
```

**Step 5 — Check the MDM diagnostic report**
```powershell
# Generate MDM diagnostic report (run as admin)
mdmdiagnosticstool.exe -area DeviceConfiguration -zip "C:\Temp\MDMDiag.zip"
# Unzip and open MDMDiagReport.html — shows:
#   - All enrolled policies
#   - CSP paths being written
#   - Error detail for failures
#   - Conflict list with conflicting policy IDs
```
The `MDMDiagReport.html` shows every CSP path the device attempted to write and whether it succeeded. Cross-reference with `EventID 404/405/406` in the Admin event log.

**Step 6 — Check settings catalog conflict details in portal**
```
Intune Admin Center
→ Devices → Configuration → [profile showing Conflict]
→ Device install status → [select the affected device]
→ Review: "Conflict" entries show the conflicting setting and the other policy causing the conflict
→ Note: both policy names — you'll need to edit one of them
```

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — Device not properly enrolled</summary>

The policy targeting is correct but the device isn't reporting — this is an enrollment health issue rather than a policy conflict.

```powershell
# Verify enrollment health
dsregcmd /status
# MDMUrl must be present. If missing, re-trigger enrollment:

# Force MDM auto-enrollment via scheduled task
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" `
  -TaskName "Schedule #1 created by enrollment client"

# Or via registry trigger
$enrollTask = Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" |
              Where-Object { $_.TaskName -like "Schedule*" }
$enrollTask | Start-ScheduledTask

# If MDMUrl is empty entirely — re-run MDM enrollment
Start-Process "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o /c /i"
# Wait 2-3 minutes, re-check dsregcmd /status
```

</details>

<details id="fix-2"><summary>Fix 2 — Fix policy group targeting</summary>

Policy is not applying because the device/user is not in the assigned group.

```powershell
# Step 1: Identify which group the policy is assigned to
# Intune Admin Center → Devices → Configuration → [policy] → Properties → Assignments

# Step 2: Check if device is in that group
Connect-MgGraph -Scopes "Device.Read.All","Group.Read.All","GroupMember.Read.All"

$deviceName = "<DeviceName>"
$groupName  = "<GroupName>"

$device = Get-MgDevice -Filter "displayName eq '$deviceName'"
$group  = Get-MgGroup -Filter "displayName eq '$groupName'"

# Check if device is a direct member
$members = Get-MgGroupMember -GroupId $group.Id
$isMember = $members | Where-Object { $_.Id -eq $device.Id }

if ($isMember) {
    Write-Host "Device IS in group — policy should apply. Check sync." -ForegroundColor Green
} else {
    Write-Host "Device NOT in group. Add it:" -ForegroundColor Red
    # Add device to group
    New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $device.Id
    Write-Host "Added. Allow 5-15 min for propagation, then force sync." -ForegroundColor Yellow
}
```

After adding to group: wait 15 minutes, then force an MDM sync (see Fix 5).

</details>

<details id="fix-3"><summary>Fix 3 — Clear conflicting GPO/CSP keys</summary>

GPO is writing to registry keys that Intune also manages. For CSP-equivalent paths, MDM should win — but if an ADMX-backed GPO set the key first and Intune can't overwrite it, the setting appears stuck.

```powershell
# Step 1: Identify the conflicting GPO and the registry path it's writing
# Run gpresult, identify the offending GPO and the exact registry value

# Step 2: Determine if MDM wins or GPO wins for this key:
# MDM WINS  → HKLM:\SOFTWARE\Microsoft\PolicyManager\... (CSP-backed)
# GPO WINS  → HKLM:\SOFTWARE\Policies\... (ADMX-backed, not CSP equivalent)
# CONFLICT  → both paths exist with different values

# Step 3a: If you want MDM to win — unlink/disable the conflicting GPO
# (Do this in Group Policy Management Console on a DC)
# GPMC → find the GPO → right-click → Link Enabled = False on affected OU

# Step 3b: If GPO must stay — remove the conflicting Intune setting
# (Don't fight a GPO you can't remove; let GPO own that key)

# Step 4: Clear stale GPO registry cache on the device
# WARNING: This removes ALL GPO-applied settings and forces a full re-apply
# Only do this if you're sure the GPO conflict is one-time or resolved

# Remove GPO registry extensions cache
Remove-Item "HKLM:\SOFTWARE\Microsoft\Group Policy\History" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "HKLM:\SOFTWARE\Microsoft\Group Policy\State"   -Recurse -Force -ErrorAction SilentlyContinue

# Force full GPO re-apply
gpupdate /force /wait:60

# Then force MDM sync (Fix 5) — MDM will re-apply after GPO
```

**CSP vs ADMX-backed GPO precedence rule:**
- If a setting has a CSP path (visible in Settings Catalog) AND a matching ADMX GPO setting, **MDM wins** for that key.
- If a setting is ADMX-only (no CSP equivalent), **GPO wins** regardless of Intune.
- If both are set to different values on the same CSP key, Intune reports "Conflict" and **neither applies** — you must resolve by removing one.

</details>

<details id="fix-4"><summary>Fix 4 — Resolve Settings Catalog / CSP conflict</summary>

Two Intune profiles are assigning different values to the same CSP setting. Neither applies until you resolve this.

```
Intune Admin Center
→ Devices → Configuration → [policy showing Conflict]
→ Device install status → [device] → shows conflicting setting + other policy name

Resolution options:
  Option A — Remove the conflicting setting from one policy
    Edit the lower-priority policy → remove the specific setting → Save
    (The other policy now has no competition and applies cleanly)

  Option B — Consolidate into a single policy
    Create new policy with the authoritative value
    Remove the setting from both conflicting policies
    Assign new policy to the same groups

  Option C — Use assignment filters to scope policies to different device sets
    Assign Policy A to "Group X with filter: OS = Win11"
    Assign Policy B to "Group Y with filter: OS = Win10"
    Eliminates overlap if the conflict is environment-specific
```

```powershell
# After resolving conflict in portal, force re-apply:
# (Run on device)
$session = New-CimSession
Invoke-CimMethod -Namespace "root\cimv2\mdm\dmmap" `
  -ClassName "MDM_DMSessionActions" `
  -MethodName "GenericAlert" `
  -CimSession $session `
  -Arguments @{ param = "" } -ErrorAction SilentlyContinue

# Simpler alternative — sync via scheduled task
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" `
  -TaskName "Schedule #1 created by enrollment client"
```

</details>

<details id="fix-5"><summary>Fix 5 — Force MDM policy sync</summary>

```powershell
# Method 1: Scheduled task (most reliable — runs as SYSTEM)
$tasks = Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" -ErrorAction SilentlyContinue
if ($tasks) {
    $tasks | ForEach-Object {
        Write-Host "Starting: $($_.TaskName)"
        Start-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName
    }
} else {
    Write-Warning "No EnterpriseMgmt scheduled tasks found — device may not be enrolled"
}

# Method 2: Via Intune portal (triggers within ~5 min)
# Intune Admin Center → Devices → [device] → Sync

# Method 3: Company Portal
# Open Company Portal → Settings → Sync This Device

# Method 4: DeviceEnroller (re-triggers policy pull)
# Run as SYSTEM via PsExec or scheduled task:
# psexec -s -i C:\Windows\System32\DeviceEnroller.exe /c /cimport

# Verify sync happened — check LastMDMRefreshTime
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" |
  Where-Object { $_.ProviderID -eq "MS DM Server" } |
  Select-Object UPN, LastMDMRefreshTime, EnrollmentState
```

</details>

<details id="fix-6"><summary>Fix 6 — Force compliance reassessment</summary>

Device configuration is now correct but compliance policy still shows "Not compliant." The compliance engine evaluates on a schedule (every ~8 hours) or on sync.

```powershell
# Method 1: Force sync (triggers compliance re-evaluation)
# See Fix 5 above

# Method 2: Via portal — retrigger compliance check
# Intune Admin Center → Devices → [device] → Check compliance

# Method 3: On device — retrigger compliance DM session
# Open Settings → Accounts → Access work or school
# Click on the account → Info → Sync
# Wait 2-3 minutes → Info → Sync again (first sync pulls policy, second evaluates)

# Method 4: PowerShell — trigger sync and check result
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" `
  -TaskName "Schedule #1 created by enrollment client"
Start-Sleep -Seconds 120

# Check compliance state via Graph
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
$device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'"
Write-Host "Compliance State : $($device.ComplianceState)"
Write-Host "Last Sync        : $($device.LastSyncDateTime)"
```

**If compliance stays stuck after sync:** The compliance policy itself may have a setting that truly isn't met (BitLocker off, Secure Boot off, OS version below minimum). Check: Intune → Devices → [device] → Device compliance → expand each policy to see which individual setting is failing.

</details>

<details><summary>Fix 7 — Remediation script for persistent policy failures</summary>

Use when a specific CSP key is consistently failing to apply and manual sync doesn't help.

```powershell
# Deploy this as an Intune Remediation Script (detection + remediation pair)
# Detection script — checks if the setting is in desired state
# Example: Checking if a specific registry key has the MDM-set value

$desiredPath  = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\<PolicyArea>"
$desiredName  = "<SettingName>"
$desiredValue = "<ExpectedValue>"

$current = Get-ItemProperty -Path $desiredPath -Name $desiredName -ErrorAction SilentlyContinue
if ($current.$desiredName -eq $desiredValue) {
    Write-Host "Compliant"
    exit 0
} else {
    Write-Host "Non-compliant: current = $($current.$desiredName)"
    exit 1
}

# Remediation script — forces the correct value
# WARNING: Only use this as a last resort. Direct registry writes for MDM-managed keys
# will be overwritten on next sync. This is for diagnosing WHAT is happening.
Set-ItemProperty -Path $desiredPath -Name $desiredName -Value $desiredValue -Force
```

**Better long-term fix:** If a Remediation script is needed for a CSP key, the underlying conflict hasn't been resolved. Go back to Fix 3 or Fix 4.

</details>

---

## Escalation Evidence

```
Intune Policy Conflict — Evidence Pack
=======================================
Date/Time of investigation  :
Device name                 :
Device OS / Build           : [Win11 23H2, Win10 22H2, etc.]
User UPN                    :
Affected policy name(s)     : [Name as shown in Intune portal]
Policy type                 : [Settings Catalog / Template / Compliance]
Portal status for device    : [Error / Conflict / Not applicable / Pending]

dsregcmd /status output     : [paste full output — redact domain if needed]
  AzureAdJoined             :
  MDMUrl                    :
  LastMDMRefreshTime (reg)  :

MDM Event Log errors        : [paste EventID, TimeCreated, Message for relevant errors]
  Key Event IDs seen        : [404 / 405 / 406 / other]

Conflicting policies found  : [Policy A name vs Policy B name, setting name]
GPO conflict found          : [Yes/No — GPO name, registry path]
gpresult /H attached        : [Yes/No]
Group membership confirmed  : [Device in correct group? Yes/No]
MDMDiag zip attached        : [Yes/No — generated via mdmdiagnosticstool.exe]

Steps already attempted     :
  [ ] Forced MDM sync
  [ ] Verified group membership
  [ ] Checked for GPO conflicts
  [ ] Removed conflicting policy setting
  [ ] Checked co-management workload slider

Escalation target           : [Microsoft Support / Internal L3 / Intune SME]
```

---

## 🎓 Learning Pointers

- **CSP (Configuration Service Provider) architecture:** Every Intune settings catalog item maps to a CSP path (e.g., `./Device/Vendor/MSFT/Policy/Config/Update/AllowAutoUpdate`). When Intune sends a policy, the MDM client writes to this CSP path, which maps to a registry key. If a GPO ADMX also writes to the same registry key, they fight. The Windows MDM client should win for CSP-equivalent keys — but only if the ADMX path and the CSP path map to the same registry location. They don't always. [CSP reference](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-configuration-service-provider)

- **MDM vs GPO precedence for overlapping keys:** For keys under `HKLM:\SOFTWARE\Microsoft\PolicyManager\`, MDM always wins. For keys under `HKLM:\SOFTWARE\Policies\`, GPO wins unless there is a CSP equivalent that writes to PolicyManager. You cannot rely on "MDM wins" as a blanket rule — you must know where the specific key lives. [MDM and GPO conflict](https://learn.microsoft.com/en-us/windows/client-management/mdm-and-gpo-integration)

- **Settings Catalog vs Administrative Templates:** Settings Catalog profiles and Administrative Templates profiles can both configure overlapping settings. Administrative Templates in Intune use ADMX ingestion and write to `SOFTWARE\Policies\...` — the same location as on-prem GPO. Settings Catalog uses CSP/PolicyManager paths. If you have both, you may have a same-device conflict between two Intune policies even without any on-prem GPO.

- **Compliance policy is always evaluated last:** A configuration profile sets a value; a compliance policy checks whether that value is set. Compliance never sets values — it only reads and reports. If compliance says "not compliant" for a setting that you know Intune is pushing, the configuration profile hasn't applied yet (check config profile status first, always).

- **`MdmDiagnosticsTool.exe` is the authoritative diagnostic:** The portal shows high-level status. The MDM Diagnostic Report shows the exact CSP path, the value the MDM client attempted to write, whether it succeeded, and why it failed. Every L2/L3 policy investigation should generate this report before escalating. Command: `mdmdiagnosticstool.exe -area DeviceConfiguration;DeviceEnrollment -zip C:\Temp\MDMDiag.zip`

- **Conflict resolution in Settings Catalog is all-or-nothing per setting:** When two policies conflict on the same setting, Intune does not apply either value — both fail. This is different from GPO where last-writer wins. If users report a setting is neither value from either policy, a conflict is the likely explanation. Check portal → Device configuration → profile → device install status.
