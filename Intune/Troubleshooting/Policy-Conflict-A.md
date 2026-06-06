# Intune Policy Conflicts — Reference Runbook (Mode A: Deep Dive)

> Engineering-grade reference. Explains the full architecture of how Intune policies reach a device, why MDM and GPO conflict, and how to resolve conflicts at root cause. For L2/L3 diagnosis, post-mortems, and building real understanding.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How Intune Policies Work](#how-intune-policies-work)
- [CSP Architecture](#csp-configuration-service-provider-architecture)
- [MDM vs GPO Conflict Matrix](#mdm-vs-gpo-conflict-matrix)
- [Compliance vs Configuration Precedence](#compliance-policy-vs-configuration-profile-precedence)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- **Covers:** Intune configuration profiles (Settings Catalog, Administrative Templates, custom OMA-URI), compliance policies, and their interaction with on-premises Group Policy
- **Environment:** Windows 10/11 devices that are Entra Joined, Hybrid Entra Joined, or co-managed (Intune + SCCM)
- **Not covered:** macOS MDM policies (different CSP architecture), Intune app deployment failures (separate runbook)
- **Assumes:** L2/L3 familiarity with Entra ID, Intune Admin Center, and Group Policy; PowerShell 5.1+; Microsoft.Graph module available

---

## How Intune Policies Work

<details><summary>Full architecture — expand for deep understanding</summary>

### The Policy Delivery Pipeline

When an admin creates a policy in the Intune portal and assigns it to a group, the following sequence occurs:

```
Admin creates policy in Intune portal
    → Policy stored in Intune Service (cloud)
    → Device group membership evaluated
    → Policy targeted to matching devices
    → Device polls Intune service (MDM check-in)
    → Intune returns OMA-DM SyncML payload to device
    → Windows MDM client (dmclient.exe) receives payload
    → dmclient passes each setting to the appropriate CSP
    → CSP writes to registry / WMI / OS API
    → CSP reports success or failure back to dmclient
    → dmclient reports status back to Intune service
    → Status visible in portal (Succeeded / Error / Conflict)
```

**Key insight:** Intune never directly touches the registry. It sends OMA-DM protocol messages to the Windows MDM client, which delegates to CSP handlers. The CSP is the actual system component that writes the OS setting. This is why "Intune says succeeded but setting isn't applied" usually points to a CSP-level override (e.g., GPO holding the registry key).

### OMA-DM Protocol

Intune communicates with the Windows MDM client using OMA-DM (Open Mobile Alliance Device Management) protocol over HTTPS. The payload is SyncML — an XML format specifying:
- `Add` / `Replace` / `Delete` / `Get` operations
- The URI (CSP path) of the setting
- The value and data type

The device initiates the session; Intune never pushes unsolicited. Check-in schedule:
- Immediately after enrollment
- Every 8 hours (standard maintenance window)
- Within 15 minutes after user signs in
- Immediately when admin triggers "Sync" from portal
- When scheduled task `\Microsoft\Windows\EnterpriseMgmt\*` fires

### How Intune Knows the Policy Applied

After processing the SyncML payload, dmclient collects the CSP result for each operation and sends a Status message back to the Intune service. The portal displays this aggregated status per device per profile. The three main failure states:

| Portal Status | Meaning | Where to dig |
|--------------|---------|-------------|
| **Error** | CSP returned a failure code | MDM event log EventID 454/455; MDMDiagReport |
| **Conflict** | Same setting targeted by two policies with different values | Portal: profile → device install status → conflict details |
| **Not applicable** | Platform filter, scope tag, or OS version mismatch | Policy assignment and filters |
| **Pending** | Device hasn't checked in since policy was assigned | Check LastMDMRefreshTime |

</details>

---

## CSP (Configuration Service Provider) Architecture

<details><summary>Deep dive on CSP — the translation layer between MDM and Windows</summary>

### What Is a CSP?

A Configuration Service Provider is a Windows component that acts as an interface between OMA-DM policy instructions and the actual OS setting. Think of it as a typed API: you tell the CSP "set this setting to this value" and the CSP knows exactly which registry key, WMI property, or Windows API call to use.

Every Intune Settings Catalog item corresponds to a CSP path. Example:
```
Intune setting:  "Allow Auto Update" (Windows Update)
CSP path:        ./Device/Vendor/MSFT/Policy/Config/Update/AllowAutoUpdate
Registry result: HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update\AllowAutoUpdate
```

### CSP Path Structure

```
./         = root of the MDM namespace
Device/    = device-scoped (applies regardless of signed-in user)
User/      = user-scoped (applies to the specific user's session)
Vendor/MSFT/Policy/Config/  = Policy CSP namespace
<Area>/    = policy area (e.g., Update, Defender, System, Browser)
<Setting>  = the specific setting name
```

### The PolicyManager Registry Tree

The Policy CSP writes to a structured registry location:
```
HKLM:\SOFTWARE\Microsoft\PolicyManager\
    current\
        device\
            <Area>\
                <Setting>        ← current effective value
                <Setting>_ProviderSet  ← which MDM provider set it
        providers\
            <EnrollmentGUID>\
                <Area>\
                    <Setting>    ← value from this specific enrollment
    default\                     ← default values if not configured
```

The `current` hive is the **effective value** — what Windows is actually using. If you see a value in `current` that doesn't match what Intune shows, a higher-priority source has overwritten it (GPO, local policy, or another MDM enrollment).

### CSPs That Commonly Conflict With GPO

| CSP Area | Registry Path Written By CSP | Corresponding GPO Path |
|----------|------------------------------|----------------------|
| `Update` | `PolicyManager\current\device\Update\` | `SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\` |
| `Defender` | `PolicyManager\current\device\Defender\` | `SOFTWARE\Policies\Microsoft\Windows Defender\` |
| `Browser` (Edge) | `SOFTWARE\Policies\Microsoft\Edge\` | `SOFTWARE\Policies\Microsoft\Edge\` (same path!) |
| `BitLocker` (FVE) | writes via FVE CSP to system store | `SOFTWARE\Policies\Microsoft\FVE\` |
| `AppLocker` | via AppLocker CSP | `SOFTWARE\Policies\Microsoft\Windows\SrpV2\` |
| `Firewall` | via Firewall CSP / WMI | `SOFTWARE\Policies\Microsoft\WindowsFirewall\` |

**Critical note on Edge:** The Edge CSP and Edge ADMX GPO write to the **same registry path** (`SOFTWARE\Policies\Microsoft\Edge\`). GPO and MDM fighting over this location is the most common Edge policy conflict. When both are present, the last writer wins — which creates unpredictable behaviour.

### ADMX-Backed Policies in Intune

Intune's "Administrative Templates" profile type and some Settings Catalog items use ingested ADMX files. These write to `HKLM:\SOFTWARE\Policies\...` — the same location as on-premises GPO. This means:

1. An Intune ADMX-backed setting and an on-prem GPO setting targeting the same key **will conflict at the registry level**
2. The last writer wins (not MDM, not GPO — literally whichever ran most recently)
3. On reboot, GPO runs first, then MDM sync. On MDM sync trigger, MDM runs last. The setting keeps flipping.

**Solution:** For settings you want MDM to own, use Settings Catalog items (CSP-backed, writes to PolicyManager) rather than Administrative Templates (ADMX-backed, writes to Policies hive).

</details>

---

## MDM vs GPO Conflict Matrix

| Setting Type | MDM Path | GPO Path | Who Wins | Notes |
|-------------|----------|----------|----------|-------|
| Policy CSP setting | `PolicyManager\current\device\` | `SOFTWARE\Policies\...` | **MDM wins** | CSP is authoritative for PolicyManager hive |
| ADMX-backed Intune setting | `SOFTWARE\Policies\...` | `SOFTWARE\Policies\...` | **Last writer wins** | Unpredictable; avoid mixing |
| Edge browser policies | `SOFTWARE\Policies\Microsoft\Edge\` | `SOFTWARE\Policies\Microsoft\Edge\` | **Last writer wins** | Same path; GPO and MDM directly compete |
| BitLocker (FVE CSP) | System FVE store + registry | `SOFTWARE\Policies\Microsoft\FVE\` | **Conflict — neither applies** | BitLocker CSP and GPO FVE cannot coexist cleanly |
| Windows Defender | `PolicyManager\...Defender` | `SOFTWARE\Policies\Microsoft\Windows Defender\` | **MDM wins** for policy-mapped keys | GPO wins for settings with no CSP equivalent |
| Windows Update | `PolicyManager\...Update` | `SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\` | **MDM wins** | WU is fully CSP-covered; prefer MDM |
| AppLocker | AppLocker CSP + registry | `SOFTWARE\Policies\Microsoft\Windows\SrpV2\` | **MDM wins** | Verified on Win11 22H2+ |
| Local Group Policy | `SOFTWARE\Policies\...` (LGPO) | Same | **MDM wins** over LGPO for CSP-backed | LGPO = lowest priority of all |
| Non-MDM-aware keys | N/A (Intune can't write via CSP) | `SOFTWARE\Policies\...` | **GPO wins** | No CSP = no MDM coverage |
| Co-management workload | Depends on workload slider | Depends | **Set by workload** | Config workload to Intune = Intune wins |

**The rule in plain English:**
- If the setting is in the **Settings Catalog** (CSP-backed): MDM wins.
- If the setting is in **Administrative Templates** in Intune (ADMX-backed): fight with GPO, unpredictable.
- If the setting has **no CSP equivalent**: GPO wins, Intune cannot manage it.
- If **two Intune policies** target the same CSP key: neither applies until you resolve the conflict.

---

## Compliance Policy vs Configuration Profile Precedence

<details><summary>Understanding the compliance/config separation</summary>

### They Do Different Things

| Aspect | Configuration Profile | Compliance Policy |
|--------|----------------------|------------------|
| Purpose | Pushes settings to the device | Checks if device meets requirements |
| Action | Writes values (CSP/registry) | Reads values, compares to threshold |
| Result | Setting is applied | Device is "Compliant" or "Not compliant" |
| Remediates? | Yes — sets the value | No — only reports; optionally blocks access via CA |
| Evaluated how often | On sync (pushed) | On sync + scheduled (pulled) |

### Evaluation Order

1. Configuration profiles apply first (MDM sync writes settings to device)
2. Compliance policy evaluates second (reads current device state)
3. Conditional Access checks compliance state (if configured)

**Common mistake:** Admin creates a compliance policy requiring BitLocker = On, but never creates a configuration profile to enable BitLocker. Compliance fails indefinitely because Intune is checking for something it never configured. Always pair "enforce" (config profile) with "check" (compliance policy).

### Grace Period and Noncompliance Actions

Compliance policies support a grace period before noncompliance actions trigger. Default is 0 days (immediate). In practice, set at least 1 day to allow new devices time to enroll and sync. Noncompliance actions available:
- Send notification email
- Remotely lock device
- Retire device
- Mark device compliant (override — for testing only, avoid in production)

### Compliance State Reporting Lag

The compliance state in the Intune portal can lag behind reality by up to the device's check-in interval. After fixing a policy conflict, allow one full MDM sync cycle (trigger manually via portal or scheduled task) before declaring the device compliant.

</details>

---

## Dependency Stack

```
Intune Tenant
    MDM Authority = Microsoft Intune
        ↓
    Policy assigned to Entra Security Group
        ↓
    Device is member of that group
        ↓
    Device has valid MDM enrollment (dmclient.exe running)
        ↓
    Device can reach Intune endpoints (*.manage.microsoft.com:443)
        ↓
    OMA-DM session established (device-initiated, every 8h or triggered)
        ↓
    SyncML payload delivered to Windows MDM client
        ↓
    dmclient delegates to appropriate CSP
        ↓
    CSP writes to registry / OS API
        ↓
    No GPO / competing policy overwriting the same key
        ↓
    CSP reports SUCCESS
        ↓
    dmclient reports status to Intune service
        ↓
    Portal shows "Succeeded"
        ↓
    Compliance policy reads the value → device = Compliant
```

If any link in this chain is broken, the setting won't apply. Policy troubleshooting is always working top-down through this chain.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Second Candidate |
|---------|------------------|-----------------|
| Portal shows "Conflict" for a setting | Two Intune policies target the same CSP key with different values | Settings Catalog + Administrative Templates both covering the same key |
| Portal shows "Error" — device can't apply setting | GPO holding the registry key MDM is trying to write | CSP not supported on this OS build/edition |
| Policy shows "Succeeded" but setting isn't in effect | GPO overwrote the CSP value after sync | ADMX-backed policy fighting with on-prem GPO at same registry path |
| Compliance stuck "Not evaluated" | Device hasn't synced — MDMRefreshTime is stale | Device enrollment is broken; dmclient not running |
| Compliance stuck "Not compliant" despite fix | Compliance engine hasn't re-evaluated since fix was applied | The specific compliance requirement is genuinely unmet (check individual settings) |
| Setting applies to some devices, not others | Group membership inconsistency | Assignment filter misconfigured |
| Setting applies in portal but wrong value in registry | CSP path mismatch — policy writing to different path than expected | Stale cached value from previous policy |
| All policies show "Pending" | Device offline or MDM check-in not occurring | Intune service connectivity issue (check service health) |
| BitLocker policy conflict | BitLocker FVE CSP and GPO FVE path conflict — cannot coexist | Co-management workload not set to Intune |
| Edge policies overriding MDM settings | Edge ADMX GPO writing to same path as Intune Administrative Template | User-scoped vs device-scoped policy mismatch |
| Windows Update ring not applying | WU workload set to SCCM in co-management | Conflicting ring policies at different priority levels |

---

## Validation Steps

**1 — Confirm device MDM enrollment and identity**
```powershell
# Full enrollment check
dsregcmd /status

# Expected output for healthy MDM-enrolled device:
# AzureAdJoined     : YES
# MDMUrl            : https://manage.microsoft.com
# MDMEnrollmentURL  : https://enrollment.manage.microsoft.com/...
# AzureAdPrt        : YES
```

**2 — Check MDM enrollment registry**
```powershell
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" |
  ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.ProviderID -eq "MS DM Server") {
        [PSCustomObject]@{
            EnrollmentID    = $_.PSChildName
            State           = $p.EnrollmentState  # 1 = enrolled
            UPN             = $p.UPN
            LastSync        = $p.LastMDMRefreshTime
            MDMDeviceID     = $p.MDMDeviceID
        }
    }
  } | Format-Table -AutoSize
```

**3 — Check policy effective values in PolicyManager**
```powershell
# Check what MDM has written for a specific area
$area = "Update"   # Change to the policy area you're investigating
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\$area" -ErrorAction SilentlyContinue
```

**4 — Compare PolicyManager vs Policies hive**
```powershell
# This reveals MDM vs GPO conflict on a per-area basis
$areas = @("Update","Defender","System","Browser","BITS")
foreach ($area in $areas) {
    $mdmPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\$area"
    $gpePath  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\$area"
    
    $mdmExists = Test-Path $mdmPath
    $gpeExists = Test-Path $gpePath
    
    if ($mdmExists -and $gpeExists) {
        Write-Host "BOTH EXIST — potential conflict: $area" -ForegroundColor Red
    } elseif ($mdmExists) {
        Write-Host "MDM only: $area" -ForegroundColor Green
    } elseif ($gpeExists) {
        Write-Host "GPO only: $area" -ForegroundColor Yellow
    }
}
```

**5 — Generate MDM diagnostic report**
```powershell
# Must run as admin
$diagPath = "C:\Temp\MDMDiag_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
Start-Process -FilePath "mdmdiagnosticstool.exe" `
  -ArgumentList "-area DeviceConfiguration;DeviceEnrollment;DeviceProvisioning -zip `"$diagPath`"" `
  -Wait -NoNewWindow
Write-Host "Diagnostic saved to: $diagPath" -ForegroundColor Green
# Unzip and open MDMDiagReport.html in a browser
# Key sections: Policy CSP, Enrolled Policies, Error Details
```

**6 — Check for GPO RSoP**
```powershell
# Generate HTML RSoP report
gpresult /H "C:\Temp\GPReport_$(Get-Date -Format 'yyyyMMdd').html" /F
Write-Host "GPO report: C:\Temp\GPReport_$(Get-Date -Format 'yyyyMMdd').html" -ForegroundColor Green
# Look for any settings that overlap with your Intune policies
# Focus on: Security Settings, Windows Components, System
```

**7 — Event log — most detailed error source**
```powershell
$providers = @(
    "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin",
    "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Operational"
)
foreach ($log in $providers) {
    Write-Host "`n=== $log ===" -ForegroundColor Cyan
    Get-WinEvent -LogName $log -MaxEvents 50 -ErrorAction SilentlyContinue |
      Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
      Sort-Object TimeCreated -Descending |
      Select-Object TimeCreated, Id, Message -First 15 |
      Format-Table -Wrap
}
```

Key event IDs:
| EventID | Meaning |
|---------|---------|
| 404 | MDM policy error — includes CSP path and error code |
| 405 | Policy conflict detected |
| 406 | CSP not supported on this device |
| 208 | MDM sync session started |
| 209 | MDM sync session completed |
| 454 | CSP write failure |
| 814 | Policy applied successfully |

---

## Troubleshooting Steps

### Phase 1 — Identify the failing policy and setting

1. In the Intune portal, navigate to **Devices → Configuration → [policy name] → Device install status**
2. Filter by the specific device — note the status column (Error / Conflict / Succeeded)
3. Click into the device row — expand settings to identify **exactly which setting** is failing
4. For Conflict status: the portal shows which other policy is conflicting and on which setting
5. For Error status: the portal shows the error code — cross-reference with the MDM event log on the device

### Phase 2 — Determine the conflict type

**Type A — Intune vs Intune (two profiles targeting same CSP key):**
- Both policy names will be visible in portal conflict details
- Resolution: remove the setting from one policy, or consolidate into a single policy

**Type B — Intune vs on-premises GPO (MDM vs ADMX):**
- Portal shows Error (not Conflict) — GPO conflict doesn't register as a portal-level conflict
- Setting may show Succeeded in portal but wrong value on device
- Evidence: `GPReport.html` shows the GPO setting; PolicyManager and Policies hive both have values
- Resolution: unlink GPO for that setting, or switch from Intune Administrative Template to Settings Catalog equivalent

**Type C — Co-management workload misconfiguration:**
- SCCM is managing the Configuration workload; Intune policies are effectively ignored
- Evidence: `dsregcmd /status` shows `MDMUrl` present but policies not applying; SCCM agent is enrolled
- Resolution: In Intune → Co-management settings, set the Configuration Policies workload to Intune (or Pilot Intune)

**Type D — Scoping/targeting issue:**
- Policy applies to wrong group, or device is excluded
- Evidence: Policy shows "Not applicable" for the device in portal
- Resolution: Fix group assignment, check assignment filters, verify scope tags

### Phase 3 — Resolve and validate

1. Make the fix (see Remediation Playbooks below)
2. Force MDM sync: trigger via portal Sync button or scheduled task on device
3. Wait 3–5 minutes for sync to complete
4. Check portal: Device configuration → profile → device install status
5. Check registry on device: verify the setting landed in the correct hive with the correct value
6. If compliance-related: trigger another sync to force compliance re-evaluation

---

## Remediation Playbooks

<details><summary>Playbook 1 — Resolve Intune-vs-Intune policy conflict</summary>

**Scenario:** Two Settings Catalog profiles both configure the same setting with different values. Portal shows "Conflict" for the device.

**Step 1: Identify both conflicting policies**
```
Intune Admin Center
→ Devices → Configuration
→ Click the policy showing Conflict
→ Device install status → [affected device]
→ Note: "This setting is in conflict with [Other Policy Name]"
```

**Step 2: Decide which policy should own the setting**
- Option A: One policy is authoritative, remove the setting from the other
- Option B: Both policies have overlapping scope; consolidate into one

**Step 3: Remove conflicting setting from lower-priority policy**
```
Intune Admin Center
→ Devices → Configuration → [lower-priority policy]
→ Edit → Configuration settings
→ Find the conflicting setting → remove it (set to "Not configured")
→ Review + save → Confirm changes
```

**Step 4: Validate**
```powershell
# Force sync on affected device
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" `
  -TaskName "Schedule #1 created by enrollment client"

Start-Sleep -Seconds 180

# Check portal — conflict should resolve within one sync cycle
# Also verify registry on device:
$area    = "<PolicyArea>"    # e.g., "Update"
$setting = "<SettingName>"   # e.g., "AllowAutoUpdate"
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\$area" -Name $setting -ErrorAction SilentlyContinue
```

**Rollback:** If removing the setting caused an unintended side effect, restore the setting in the policy and assign to a test group first before rolling to production.

</details>

<details><summary>Playbook 2 — Resolve Intune vs on-premises GPO conflict</summary>

**Scenario:** GPO is fighting with an Intune Settings Catalog or Administrative Template profile. Setting appears "Succeeded" in portal but wrong value on device.

**Step 1: Identify the specific setting and both paths**
```powershell
# On the device — find what MDM wrote vs what GPO wrote
$area    = "<PolicyArea>"   # e.g., "WindowsUpdate"
$setting = "<SettingName>"  # e.g., "AllowAutoUpdate"

# MDM value (CSP-backed)
$mdmVal = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\$area" `
             -Name $setting -ErrorAction SilentlyContinue).$setting
Write-Host "MDM (PolicyManager) value: $mdmVal"

# GPO value (Policies hive)
$gpoVal = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\$area" `
             -Name $setting -ErrorAction SilentlyContinue).$setting
Write-Host "GPO (Policies) value     : $gpoVal"
```

**Step 2: Determine if Intune is using CSP path or ADMX path**
- If your Intune policy is in **Settings Catalog**: it uses CSP → PolicyManager hive → MDM should win
- If your Intune policy is in **Administrative Templates**: it uses ADMX → Policies hive → conflicts directly with GPO

**Step 3a: If Intune uses Settings Catalog (CSP-backed)**
```
The GPO is writing to the Policies hive, Intune writes to PolicyManager.
Windows should honour the PolicyManager value.
If it's not working:
1. Check if there's an ADMX-backed Intune policy ALSO targeting this setting (would overwrite PolicyManager with Policies hive value)
2. Check if the effective OS behavior follows PolicyManager — use 'gpresult /r' and compare
3. If a non-MDM-aware key is involved, GPO wins by design — switch to the CSP equivalent in Settings Catalog
```

**Step 3b: If Intune uses Administrative Templates (ADMX-backed)**
```
Both paths write to SOFTWARE\Policies\... — this is a true conflict.
Resolution: Migrate the Intune policy to Settings Catalog equivalent, OR unlink the on-prem GPO.

To find the Settings Catalog equivalent:
Intune Admin Center → Devices → Configuration → Create → Settings Catalog
Search for the setting name — most ADMX settings have a CSP equivalent
```

**Step 4: Unlink or disable the offending GPO (if on-prem GPO must be removed)**
```
Group Policy Management Console (on a DC)
→ Find the GPO containing the conflicting setting
→ Right-click the OU link → Link Enabled: False
  (or)
→ Edit the GPO → navigate to the setting → set to "Not configured"

Run on affected device:
gpupdate /force
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" -TaskName "Schedule #1 created by enrollment client"
```

**Rollback:** Re-enable the GPO link in GPMC. The GPO re-applies on next `gpupdate` or device restart.

</details>

<details><summary>Playbook 3 — Fix compliance policy not evaluating</summary>

**Scenario:** Device shows "Not evaluated" or remains "Not compliant" after configuration fix.

**Step 1: Verify the config profile applied first**
```powershell
# In portal:
# Devices → [device] → Device configuration
# Confirm the relevant config profile shows "Succeeded" — not "Conflict" or "Error"
# If it's in error — fix the config profile FIRST before touching compliance

# On device — verify the actual setting value
$path    = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\<Area>"
$setting = "<SettingName>"
(Get-ItemProperty $path -Name $setting -ErrorAction SilentlyContinue).$setting
```

**Step 2: Force compliance re-evaluation**
```powershell
# Method 1: Trigger MDM sync (compliance evaluates during sync)
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" `
  -TaskName "Schedule #1 created by enrollment client"
Start-Sleep -Seconds 120

# Method 2: Via portal
# Intune Admin Center → Devices → [device] → Check compliance

# Method 3: Via Settings app on device
# Settings → Accounts → Access work or school → [account] → Info → Sync
```

**Step 3: Check individual compliance settings**
```
Intune Admin Center
→ Devices → [device] → Device compliance
→ Expand each compliance policy
→ Each individual setting shows Compliant / Not compliant
→ Identify the specific setting still failing
```

**Step 4: If a setting is genuinely not compliant, configure it**
Common compliance settings that require a corresponding config profile:
| Compliance Requirement | Config Profile to Create |
|----------------------|------------------------|
| BitLocker required | BitLocker Settings Catalog profile |
| Defender real-time protection | Antivirus Settings Catalog profile |
| OS version minimum | Windows Update ring profile |
| Secure Boot | No Intune config needed — Secure Boot is hardware; check BIOS |
| TPM required | No Intune config — TPM is hardware |

**Rollback:** Not applicable for compliance changes (compliance policies are read-only — they don't change device state, only report it).

</details>

<details><summary>Playbook 4 — Fix co-management workload conflict</summary>

**Scenario:** Device is co-managed (Intune + SCCM/ConfigMgr). Intune policies are assigned and show in the portal, but settings aren't applying because SCCM owns the workload.

**Step 1: Verify co-management state**
```powershell
# On device
dsregcmd /status
# Look for: MDMUrl AND SCCM enrollment indicators

# Check co-management enrollment
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" |
  ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    Write-Host "$($_.PSChildName): ProviderID=$($p.ProviderID), State=$($p.EnrollmentState)"
  }
# You may see both MS DM Server (Intune) and ConfigMgr entries
```

**Step 2: Check co-management workload settings**
```
Intune Admin Center
→ Devices → Windows → Co-management settings
→ Check workload sliders:
    Device Configuration: Intune or SCCM?
    Compliance policies:  Intune or SCCM?
    Windows Update:       Intune or SCCM?

If "Device Configuration" is set to SCCM (or "Configuration Manager"):
→ Intune configuration profiles are NOT applied
→ SCCM CI/DCM policies apply instead
```

**Step 3: Migrate workload to Intune**
```
Option A: Move all co-managed devices
Intune Admin Center → Devices → Windows → Co-management settings
→ Set Device Configuration workload to: Intune
→ Save — applies to all co-managed devices

Option B: Pilot migration (recommended)
→ Set Device Configuration workload to: Pilot Intune
→ Assign a pilot group containing the test devices
→ Validates before full rollout
```

**Step 4: Validate**
```powershell
# After workload change, trigger MDM sync on a pilot device
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" `
  -TaskName "Schedule #1 created by enrollment client"
# Check portal — Intune config profiles should now show status for this device
```

**Rollback:** Set workload slider back to Configuration Manager in Intune admin portal.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Intune policy conflict evidence from a Windows device.

.DESCRIPTION
    Gathers all relevant diagnostic data for an Intune policy conflict investigation:
    MDM enrollment state, event log errors, PolicyManager registry values,
    GPO RSoP data, and generates the MDM diagnostic report.
    Output is a structured report file and MDM diagnostic zip.

.PARAMETER OutputPath
    Directory to write evidence files. Default: C:\Temp\IntuneEvidence

.PARAMETER PolicyArea
    Optional. Specific CSP policy area to inspect in detail (e.g., "Update", "Defender").

.EXAMPLE
    .\Get-IntunePolicyConflictEvidence.ps1 -OutputPath "C:\Temp\IntuneEvidence"

.EXAMPLE
    .\Get-IntunePolicyConflictEvidence.ps1 -PolicyArea "Update" -OutputPath "D:\Evidence"

.NOTES
    Must run as Administrator.
    Generates: EvidenceReport.txt, MDMDiag.zip, GPReport.html
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "C:\Temp\IntuneEvidence",
    [string]$PolicyArea = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("OK","WARN","ERROR","INFO")]
        [string]$Level = "INFO"
    )
    $colour = switch ($Level) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        "INFO"  { "Cyan"   }
    }
    $prefix = switch ($Level) {
        "OK"    { "[OK]   " }
        "WARN"  { "[WARN] " }
        "ERROR" { "[ERROR]" }
        "INFO"  { "[INFO] " }
    }
    Write-Host "$prefix $Message" -ForegroundColor $colour
}

# ── Preflight ──────────────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Status "Must run as Administrator." -Level ERROR
    exit 1
}

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
$reportFile = Join-Path $OutputPath "EvidenceReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$report     = [System.Text.StringBuilder]::new()

function Add-Section {
    param([string]$Title)
    $line = "=" * 70
    $null = $report.AppendLine("`n$line")
    $null = $report.AppendLine("  $Title")
    $null = $report.AppendLine($line)
}

function Add-Line {
    param([string]$Text = "")
    $null = $report.AppendLine($Text)
}

Write-Status "Starting Intune Policy Conflict evidence collection..." -Level INFO
$null = $report.AppendLine("INTUNE POLICY CONFLICT — EVIDENCE REPORT")
Add-Line "Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "Computer  : $env:COMPUTERNAME"
Add-Line "User      : $env:USERNAME"
Add-Line "PolicyArea: $(if ($PolicyArea) { $PolicyArea } else { '(all)' })"

# ── Section 1: Device Join State ───────────────────────────────────────────────
Write-Status "Collecting dsregcmd /status..." -Level INFO
Add-Section "1. DEVICE JOIN STATE (dsregcmd /status)"
try {
    $dsreg = dsregcmd /status 2>&1
    $dsreg | ForEach-Object { Add-Line $_ }
    
    $azJoined = ($dsreg | Select-String "AzureAdJoined").ToString().Trim()
    $mdmUrl   = ($dsreg | Select-String "MDMUrl").ToString().Trim()
    $prt      = ($dsreg | Select-String "AzureAdPrt\s*:").ToString().Trim()
    
    if ($azJoined -match "YES") { Write-Status "AzureAdJoined = YES" -Level OK }
    else                         { Write-Status "AzureAdJoined = NO — device must be Entra joined" -Level ERROR }
    
    if ($mdmUrl -match "manage.microsoft.com") { Write-Status "MDMUrl present" -Level OK }
    else                                        { Write-Status "MDMUrl missing — device not MDM enrolled" -Level ERROR }
    
    if ($prt -match "YES") { Write-Status "AzureAdPrt = YES" -Level OK }
    else                    { Write-Status "AzureAdPrt = NO — PRT issue, fix auth first" -Level WARN }
} catch {
    Add-Line "ERROR running dsregcmd: $_"
    Write-Status "dsregcmd failed: $_" -Level ERROR
}

# ── Section 2: MDM Enrollment Registry ─────────────────────────────────────────
Write-Status "Checking MDM enrollment registry..." -Level INFO
Add-Section "2. MDM ENROLLMENT REGISTRY"
try {
    $enrollments = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" -ErrorAction Stop
    $found = $false
    foreach ($e in $enrollments) {
        $p = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
        if ($p.ProviderID -eq "MS DM Server") {
            $found = $true
            Add-Line "Enrollment ID    : $($e.PSChildName)"
            Add-Line "EnrollmentState  : $($p.EnrollmentState)  (1 = enrolled)"
            Add-Line "UPN              : $($p.UPN)"
            Add-Line "MDM DeviceID     : $($p.MDMDeviceID)"
            Add-Line "LastMDMRefresh   : $($p.LastMDMRefreshTime)"
            Add-Line ""
            
            if ($p.EnrollmentState -eq 1) { Write-Status "Enrollment state = 1 (enrolled)" -Level OK }
            else { Write-Status "Enrollment state = $($p.EnrollmentState) — not fully enrolled" -Level WARN }
            
            $lastSync = $p.LastMDMRefreshTime
            if ($lastSync) {
                try {
                    $syncDt = [datetime]::ParseExact($lastSync, "MM/dd/yyyy HH:mm:ss", $null)
                    $age    = (Get-Date) - $syncDt
                    if ($age.TotalHours -gt 24) {
                        Write-Status "Last sync was $([int]$age.TotalHours)h ago — stale" -Level WARN
                    } else {
                        Write-Status "Last sync: $([int]$age.TotalHours)h $([int]$age.Minutes)m ago" -Level OK
                    }
                } catch { Add-Line "Could not parse LastMDMRefreshTime format" }
            }
        }
    }
    if (-not $found) {
        Add-Line "No MS DM Server enrollment found!"
        Write-Status "No Intune MDM enrollment found in registry" -Level ERROR
    }
} catch {
    Add-Line "ERROR reading enrollment registry: $_"
}

# ── Section 3: PolicyManager Registry ─────────────────────────────────────────
Write-Status "Reading PolicyManager registry..." -Level INFO
Add-Section "3. POLICYMANAGER REGISTRY (MDM-written values)"
$areas = if ($PolicyArea) { @($PolicyArea) } else {
    @("Update","Defender","System","Browser","BITS","DataProtection","Experience","Printers")
}
foreach ($area in $areas) {
    $path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\$area"
    if (Test-Path $path) {
        Add-Line "`n--- $area ---"
        $props = Get-ItemProperty $path -ErrorAction SilentlyContinue
        $props.PSObject.Properties |
          Where-Object { $_.Name -notmatch "^PS" } |
          ForEach-Object { Add-Line "  $($_.Name) = $($_.Value)" }
    }
}

# ── Section 4: GPO Policies Hive ───────────────────────────────────────────────
Write-Status "Checking GPO Policies hive for conflicts..." -Level INFO
Add-Section "4. GPO POLICIES HIVE (potential conflicts with MDM)"
$gpoPaths = @(
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender",
    "HKLM:\SOFTWARE\Policies\Microsoft\FVE",
    "HKLM:\SOFTWARE\Policies\Microsoft\Edge",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
)
foreach ($gpoPath in $gpoPaths) {
    if (Test-Path $gpoPath) {
        Add-Line "`n[FOUND] $gpoPath"
        $props = Get-ItemProperty $gpoPath -ErrorAction SilentlyContinue
        $props.PSObject.Properties |
          Where-Object { $_.Name -notmatch "^PS" } |
          ForEach-Object { Add-Line "  $($_.Name) = $($_.Value)" }
        Write-Status "GPO values found at: $gpoPath" -Level WARN
    }
}

# ── Section 5: Event Log Errors ────────────────────────────────────────────────
Write-Status "Pulling MDM event log errors..." -Level INFO
Add-Section "5. MDM EVENT LOG ERRORS (last 24 hours)"
$cutoff = (Get-Date).AddHours(-24)
$logs   = @(
    "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin",
    "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Operational"
)
foreach ($log in $logs) {
    Add-Line "`n--- $log ---"
    try {
        $events = Get-WinEvent -LogName $log -MaxEvents 100 -ErrorAction SilentlyContinue |
                  Where-Object { $_.TimeCreated -gt $cutoff -and $_.LevelDisplayName -in "Error","Warning" } |
                  Sort-Object TimeCreated -Descending
        if ($events) {
            foreach ($ev in $events | Select-Object -First 20) {
                Add-Line "[$($ev.TimeCreated.ToString('HH:mm:ss'))] EventID=$($ev.Id) [$($ev.LevelDisplayName)]"
                Add-Line "  $($ev.Message -replace "`n"," " -replace "`r","")"
            }
            Write-Status "$($events.Count) error/warning events in last 24h" -Level WARN
        } else {
            Add-Line "(No errors/warnings in last 24 hours)"
            Write-Status "No MDM errors in last 24h ($log)" -Level OK
        }
    } catch {
        Add-Line "Could not read log: $_"
    }
}

# ── Section 6: MDM Diagnostic Report ──────────────────────────────────────────
Write-Status "Generating MDM diagnostic report..." -Level INFO
$diagZip = Join-Path $OutputPath "MDMDiag_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
try {
    $mdmDiag = Get-Command mdmdiagnosticstool.exe -ErrorAction SilentlyContinue
    if ($mdmDiag) {
        Start-Process -FilePath "mdmdiagnosticstool.exe" `
          -ArgumentList "-area DeviceConfiguration;DeviceEnrollment -zip `"$diagZip`"" `
          -Wait -NoNewWindow
        if (Test-Path $diagZip) {
            Write-Status "MDM diagnostic zip: $diagZip" -Level OK
            Add-Section "6. MDM DIAGNOSTIC REPORT"
            Add-Line "Generated: $diagZip"
            Add-Line "Open MDMDiagReport.html inside the zip for full CSP detail."
        }
    } else {
        Write-Status "mdmdiagnosticstool.exe not found" -Level WARN
    }
} catch {
    Write-Status "MDM diagnostic generation failed: $_" -Level WARN
}

# ── Section 7: GPO RSoP ────────────────────────────────────────────────────────
Write-Status "Generating GPO RSoP report..." -Level INFO
$gpoReport = Join-Path $OutputPath "GPReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
try {
    Start-Process -FilePath "gpresult.exe" `
      -ArgumentList "/H `"$gpoReport`" /F" `
      -Wait -NoNewWindow
    if (Test-Path $gpoReport) {
        Write-Status "GPO RSoP report: $gpoReport" -Level OK
        Add-Section "7. GPO RSOP"
        Add-Line "Generated: $gpoReport"
        Add-Line "Open in browser — search for settings overlapping with your Intune profile."
    }
} catch {
    Write-Status "gpresult failed: $_" -Level WARN
}

# ── Write report ───────────────────────────────────────────────────────────────
$report.ToString() | Out-File -FilePath $reportFile -Encoding utf8
Write-Status "Evidence report written: $reportFile" -Level OK
Write-Status "Evidence collection complete. Files in: $OutputPath" -Level OK

Write-Host "`nFiles collected:" -ForegroundColor Cyan
Get-ChildItem $OutputPath | ForEach-Object {
    Write-Host "  $($_.Name)  [$([math]::Round($_.Length/1KB, 1)) KB]" -ForegroundColor White
}
```

---

## Command Cheat Sheet

```powershell
# --- Enrollment & Identity ---
dsregcmd /status                                                    # Full enrollment and identity state
dsregcmd /refreshprt                                               # Refresh Primary Refresh Token

# --- Force MDM Sync ---
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" -TaskName "Schedule #1 created by enrollment client"

# --- MDM Diagnostic ---
mdmdiagnosticstool.exe -area DeviceConfiguration;DeviceEnrollment -zip C:\Temp\MDMDiag.zip

# --- GPO ---
gpresult /H C:\Temp\GPReport.html /F                              # RSoP HTML report
gpresult /r                                                        # Quick text RSoP
gpupdate /force                                                    # Force GPO re-apply

# --- Event Logs ---
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 50 | Where-Object { $_.LevelDisplayName -in "Error","Warning" } | Format-Table -Wrap

# --- Registry: MDM values ---
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\<Area>"

# --- Registry: Last sync time ---
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" | Where-Object { $_.ProviderID -eq "MS DM Server" } | Select UPN, LastMDMRefreshTime

# --- Graph: Device compliance state ---
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" | Select DeviceName, ComplianceState, LastSyncDateTime

# --- Graph: Device group membership ---
$d = Get-MgDevice -Filter "displayName eq '<DeviceName>'"
Get-MgDeviceMemberOf -DeviceId $d.Id | Select-Object -ExpandProperty AdditionalProperties | ForEach-Object { $_.displayName }
```

---

## 🎓 Learning Pointers

- **The CSP is the contract, the registry is the result.** Engineers often go straight to the registry to verify a policy. That's correct, but you must know *which* registry path the CSP writes to. Some settings have two paths — the PolicyManager path (CSP-written, authoritative for MDM) and the Policies path (ADMX-written, authoritative for GPO). If you're looking at the wrong path, you'll draw the wrong conclusion. The [Windows CSP reference](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-configuration-service-provider) lists the exact registry mapping for every policy.

- **Settings Catalog vs Administrative Templates is an architectural choice, not just a UI difference.** Settings Catalog items use the Policy CSP and write to `PolicyManager` — MDM-authoritative. Administrative Templates items in Intune use ADMX ingestion and write to `SOFTWARE\Policies` — the same location as on-prem GPO. In an environment with both on-prem GPO and Intune, Administrative Templates profiles will conflict with GPO for any overlapping settings. Default to Settings Catalog when a CSP equivalent exists. [Settings Catalog overview](https://learn.microsoft.com/en-us/mem/intune/configuration/settings-catalog)

- **MDM conflict ≠ GPO conflict in the portal.** When two Intune policies conflict, the portal explicitly shows "Conflict" and names both policies. When an on-prem GPO overrides an Intune policy, the portal may show "Succeeded" — because the MDM write succeeded — but the value on the device is wrong because GPO overwrote it afterward. This is the most insidious failure mode. Always verify the actual registry value on the device after confirming portal success.

- **Co-management workloads are the hidden hand.** In co-managed environments, the Device Configuration workload slider controls whether Intune or SCCM owns configuration policies. If the slider is on SCCM, Intune configuration profiles are silently ignored — not errored, not conflicted, just ignored. Engineers who don't know the environment is co-managed can spend an hour troubleshooting Intune for a problem caused by the workload slider. Check for co-management enrollment early in every investigation. [Co-management workloads](https://learn.microsoft.com/en-us/mem/configmgr/comanage/workloads)

- **Compliance and configuration are separate engines that must be deliberately paired.** Compliance policy checks for a state; it does not create that state. If you require BitLocker via compliance but have no Intune configuration profile enabling BitLocker, the device will be non-compliant forever. Every compliance requirement should have a corresponding configuration profile that enforces it. Document this pairing explicitly in your Intune design — it prevents half of all "why is this device non-compliant" tickets.

- **The MDM Diagnostic Report is the ground truth.** When portal data contradicts device state, `mdmdiagnosticstool.exe` resolves the dispute. The HTML report shows every enrolled policy, the exact SyncML received, the CSP path attempted, whether the write succeeded, and the error code if it failed. It also lists every detected conflict. No Intune investigation should escalate to Microsoft without this file attached. [MDMDiagnosticsTool reference](https://learn.microsoft.com/en-us/windows/client-management/mdm/diagnose-mdm-failures-in-windows-10)
