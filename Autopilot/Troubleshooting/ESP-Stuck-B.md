# Enrollment Status Page Stuck — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes. Device is stuck on ESP during Autopilot provisioning.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [ESP Phases Explained](#esp-phases-explained)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis Flow](#diagnosis--validation-flow)
- [Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

```powershell
# Run from OOBE shell (Shift+F10 → PowerShell) or after ESP bypass/skip

# 1. Check which ESP phase is stuck — look at the screen first
#    Phase 1: "Preparing your device for mobile management"  → Device Preparation
#    Phase 2: "Setting up your device for work"              → Device Setup
#    Phase 3: "Setting up your account for work"             → Account Setup

# 2. Collect Autopilot event log — most useful single source
Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot" `
  -MaxEvents 50 | Select TimeCreated, Id, Message | Format-Table -Wrap

# 3. Check ESP-specific events (app install tracking)
Get-WinEvent -LogName "Microsoft-Windows-Provisioning-Diagnostics-Provider/Admin" `
  -MaxEvents 30 | Select TimeCreated, Id, Message | Format-Table -Wrap

# 4. Run MDM diagnostics — generates full log bundle
mdmdiagnosticstool.exe -area Autopilot;DeviceProvisioning;DeviceEnrollment `
  -zip C:\ESP-Diags-$(Get-Date -Format yyyyMMdd-HHmm).zip

# 5. Check app deployment status from the device's perspective
$session = New-CimSession
Get-CimInstance -Namespace root\ccm\clientsdk -ClassName CCM_Application `
  -CimSession $session 2>$null
# If no SCCM agent — check via registry for IME (Intune Management Extension) status
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps" -ErrorAction SilentlyContinue
```

**Interpret:**
| Symptom | Likely cause | Go to |
|---------|-------------|-------|
| Stuck on "Preparing your device" for >5 min | Autopilot profile not applied, TPM issue, or enrollment failure | [Fix 1](#fix-1--device-preparation-phase-stuck) |
| Stuck on "Setting up your device" — progress bar frozen | Win32 app failing to install, detection rule wrong, or dependency missing | [Fix 2](#fix-2--win32-app-failing-during-device-setup) |
| Stuck on "Setting up your device" — shows specific app name | That named app is blocked — check Intune for deployment status | [Fix 2](#fix-2--win32-app-failing-during-device-setup) |
| Stuck on "Setting up your account" | User-targeted app or policy failing, user licence issue | [Fix 3](#fix-3--account-setup-phase-stuck) |
| ESP timeout error (60 min default) | Too many apps, slow network, or app install loop | [Fix 4](#fix-4--esp-timeout) |
| "Something went wrong" with error code | Specific app or policy failure — note the code | [Fix 2](#fix-2--win32-app-failing-during-device-setup) |
| ESP completes but device not usable | Post-ESP policy not yet applied (normal — give 15 min) | Wait / [Fix 5](#fix-5--bypass-esp-for-testing) |

---

## ESP Phases Explained

**Phase 1 — Device Preparation**
The device enrolls into Intune, receives its Autopilot profile, and the Intune Management Extension (IME) is installed. If stuck here: enrollment itself has failed, or the profile was never assigned.

**Phase 2 — Device Setup**
Device-targeted apps (Win32, LOB, MSI) and device-targeted configuration policies are applied. This is where most ESP hangs occur. The ESP waits for every app marked as **Required** with **block device setup** enabled to complete successfully. A single failing app blocks the entire phase.

**Phase 3 — Account Setup**
After the user signs in, user-targeted apps and policies are applied. Requires a valid user identity and licence. Less common to hang here, but user-licensed apps (Visio, Project) or per-user policies can block it.

---

## Dependency Cascade

<details><summary>What must succeed for ESP to complete</summary>

```
Autopilot profile assigned to device (via group tag → dynamic group)
    → Device enrolls into Intune (MDM endpoints reachable)
    → ESP policy applied to device (All Devices or targeted group)
    → Intune Management Extension (IME) installed on device
    → IME checks in with Intune for Win32 app assignments
        → For each REQUIRED app with "block" enabled:
            → App content downloaded from Intune CDN
            → Dependency apps installed first (in dependency order)
            → Detection rule runs after install
            → Detection must return SUCCESS
            → Only then does ESP tick off that app
    → All required device policies applied (compliance, config)
    → Phase 2 complete → user presented with sign-in
    → User signs in → Phase 3 begins
    → User-targeted required apps + policies applied
    → Phase 3 complete → desktop presented
```

**Blocking conditions:**
- Any required app failing detection → ESP retries until timeout
- App dependency not installed first → parent app install fails
- Win32 app content not reachable (CDN blocked by proxy) → download fails
- Detection rule points to wrong path/registry key → always fails even after install
- ESP timeout (default 60 min) → triggers error screen
- "Available" apps do NOT block ESP — only "Required" apps with block enabled do

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Identify stuck phase and app**

From the ESP screen, note:
- Which phase is shown
- If an app name is listed — that is the blocking app
- The exact error text or code if shown

**Step 2 — Check IME log on device**
```powershell
# IME log — the primary source for Win32 app install failures
$imePath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
# Last 200 lines
Get-Content $imePath -Tail 200

# Search specifically for errors
Select-String -Path $imePath -Pattern "error|fail|0x8" -CaseSensitive:$false | Tail 50
```

**Step 3 — Check Autopilot event log for ESP event IDs**
```powershell
# ESP-specific event IDs:
# 306 = ESP category tracking started
# 307 = ESP category completed
# 70  = ESP app install started
# 71  = ESP app install completed
# 81  = ESP timeout warning

Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot" |
  Where-Object { $_.Id -in 70, 71, 81, 306, 307 } |
  Select TimeCreated, Id, Message | Format-Table -Wrap
```

**Step 4 — Check Intune portal for app deployment status**
```
Intune Admin Center → Apps → [App name]
→ Device install status: find the device, look for "Failed" or "Pending install"
→ Error code in the status column → look up at aka.ms/intuneapps-errors

Intune Admin Center → Devices → [Device name]
→ App install status → filter by "Failed"
→ Configuration profiles → any "Error" state
```

**Step 5 — Check ESP policy settings in Intune**
```
Intune → Devices → Enroll devices → Windows enrollment → Enrollment Status Page
→ Check: which profile is assigned to this device
→ Check: "Show app and profile configuration progress" = Yes
→ Check: "Block device use until all apps and profiles are installed" = Yes/No
→ Check: timeout value (default 60 minutes)
→ Check: "Allow users to use device if installation takes longer than X minutes"
```

**Step 6 — Check app targeting**
```powershell
# Verify device is in the correct Entra group for the required app
Connect-MgGraph -Scopes "Device.Read.All","Group.Read.All"
$device = Get-MgDevice -Filter "displayName eq '<DeviceName>'"
Get-MgDeviceMemberOf -DeviceId $device.Id | Select DisplayName, Id
# Cross-reference against the group the Win32 app is assigned to
```

**Step 7 — Check for supersedence conflicts**
```
Intune → Apps → [App name] → Properties → Supersedence
If the app supersedes a previous version AND the previous version is still required
by another policy → install loop. The superseded app keeps getting detected as required.
```

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — Device Preparation phase stuck</summary>

Device Preparation fails before IME is installed. Usually an enrollment failure.

```powershell
# Check enrollment event log
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" |
  Sort-Object TimeCreated -Descending |
  Select TimeCreated, Id, Message -First 20 | Format-Table -Wrap

# Check if device enrolled at all
# In Intune portal: Devices → All devices → search for device serial or name
# If not present: enrollment failed before ESP started
# If present but "Pending": enrolled but hasn't checked in
```

Common causes and fixes:
- Device not registered in Autopilot → upload hash, see `Profile-Not-Assigned-B.md`
- TPM attestation failure → see `TPM-Attestation-B.md`
- MDM endpoints blocked → run `Test-AutopilotNetworkRequirements.ps1`
- Wrong tenant → device hash uploaded to a different tenant

</details>

<details id="fix-2"><summary>Fix 2 — Win32 app failing during Device Setup</summary>

This is the most common ESP hang. One app is failing detection and blocking the phase.

```powershell
# Step 1: Read IME log — find the failing app
$log = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Select-String -Path $log -Pattern "ResultCode|install failed|detection|0x8" | Select -Last 30

# Step 2: Check what detection rule the app uses
# Intune → Apps → [App] → Properties → Detection rules
# Common mistakes:
#   - File path uses %ProgramFiles% but app installs to %ProgramFiles(x86)%
#   - Registry key path is wrong (HKLM vs HKCU for system installs)
#   - Product code for MSI is wrong (use Orca or MSI properties to verify)
#   - Version comparison set too strictly

# Step 3: Check if app dependency is installed
# Intune → Apps → [App] → Properties → Dependencies
# If dependency is listed: check it installed first
# IME installs dependencies before the parent app
# If dependency fails → parent app never attempts install

# Step 4: Check app install command
# Intune → Apps → [App] → Properties → Program
# Install command must exit 0 on success — confirm with: echo %ERRORLEVEL%
# Silent install switches missing? (e.g., /quiet /norestart)
```

**Quick fix options (in order of preference):**

1. Fix the detection rule in Intune → app re-evaluates without device reset
2. Fix the dependency chain → add missing dependency app to Intune
3. Mark the app as "not blocking" in ESP policy (buys time, not a real fix):
   ```
   Intune → Devices → Enrollment Status Page → [profile] → Edit
   → "Block device use until these required apps are installed" → remove the failing app from the list
   ```
4. Force IME sync after fix:
   ```powershell
   # From device PowerShell
   Get-ScheduledTask | Where-Object { $_.TaskName -like "*Intune*" } | Start-ScheduledTask
   ```

</details>

<details id="fix-3"><summary>Fix 3 — Account Setup phase stuck</summary>

Phase 3 runs after user sign-in. User-targeted required apps or policies are failing.

```powershell
# Check user-targeted app failures in IME log
$log = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Select-String -Path $log -Pattern "user context|accountsetup|userapps" -CaseSensitive:$false | Select -Last 30

# Check user licence — unlicensed apps block phase 3
Connect-MgGraph -Scopes "User.Read.All"
Get-MgUserLicenseDetail -UserId "<UserUPN>" | Select SkuPartNumber
# Microsoft 365 Apps (OFFICESUBSCRIPTION), Visio, Project — each needs a licence
```

Common causes:
- User not licensed for a required app (e.g., Visio required but no Visio licence)
- User-targeted required app has a detection failure
- MFA prompt interrupting the account setup flow (check CA policies — exempt Autopilot registration)
- User is not in the group that the required app targets

</details>

<details id="fix-4"><summary>Fix 4 — ESP timeout (60 min default)</summary>

The default ESP timeout is 60 minutes. Environments with many large apps or slow WAN links hit this regularly.

**Extend the timeout:**
```
Intune → Devices → Enroll devices → Enrollment Status Page → [Profile] → Edit
→ "Show error when installation takes longer than specified number of minutes"
→ Change from 60 to 120 or 180
```

**Identify what was still installing at timeout:**
```powershell
# IME log — look for apps still in progress at the time of the ESP error
$log = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
# Find the last 'timeout' or 'ESP' entry and look backwards
Select-String -Path $log -Pattern "timeout|ESP|installation" -CaseSensitive:$false | Select -Last 40
```

**Reduce ESP scope (correct fix for the long term):**
- Move large apps (like full Office suite) to "Available" instead of "Required" if they don't need to be pre-staged
- Use Autopilot pre-provisioning (white glove) — technician phase installs device apps before shipping to user
- Stagger required apps — only block on truly critical apps (VPN, security agent, cert)

</details>

<details id="fix-5"><summary>Fix 5 — Bypass ESP for testing / emergency access</summary>

> Use this to get to the desktop to collect logs or test a fix. Not a production resolution.

```
At the ESP screen:
→ Press Ctrl+Shift+F3 to enter Audit Mode (built-in administrator) — bypasses ESP entirely
  OR
→ If "Allow user to collect logs" is enabled: click the link to export logs first

In Intune ESP policy:
→ "Allow users to use device if installation takes longer than X minutes" = Yes
  This lets the user skip to desktop after timeout rather than showing hard failure
```

To skip ESP for a **specific device** during a test deployment:
```
Intune → Devices → Autopilot devices → [Device] → Properties
→ Deployment profile: assign a test profile with ESP configured as "Not configured" (no ESP)
```

</details>

<details><summary>Fix 6 — App supersedence conflict</summary>

**Symptom:** App installs, ESP detects it as failed, installs again — infinite loop until timeout.

```
Intune → Apps → [App v2.0] → Properties → Supersedence
→ If App v1.0 is listed AND App v1.0 is still a required assignment on the same device:
  The device tries to install v2.0 (supersedes), detects v1.0 gone, re-evaluates v1.0 as required

Fix:
1. Remove the v1.0 required assignment from the device group, OR
2. Set v1.0 assignment to "Uninstall" rather than "Required", OR
3. Remove v1.0 from Intune entirely if no longer needed
```

</details>

---

## Escalation Evidence

```
ESP Stuck — Evidence Pack
=========================
Device serial / name:        
Autopilot profile name:      
ESP phase stuck on:          [Device Preparation / Device Setup / Account Setup]
Blocking app name (if shown):
ESP timeout value:           [minutes]
IME log snippet:             [paste last 30 lines of IntuneManagementExtension.log]
Autopilot event IDs found:   [70/71/81/306/307 — which ones, with timestamps]
App deployment status:       [from Intune portal — state + error code if any]
ESP policy settings:         [block = yes/no, timeout value, apps in block list]
Group membership confirmed:  [device in correct group? yes/no]
Detection rule verified:     [yes/no — what does it check for?]
MDMDiagnostics zip:          [attach C:\ESP-Diags-*.zip]
Time stuck (approx):         [minutes]
Network path:                [corporate LAN / VPN / direct internet]
```

---

## 🎓 Learning Pointers

- **ESP only blocks on Required apps with "block" enabled** — "Available" apps never block ESP regardless of whether they install. The ESP policy has a specific list of apps that must complete; if an app is Required in Intune but not in that list, it installs in the background post-ESP. Understanding this distinction stops engineers from chasing the wrong app. [MS Docs: ESP overview](https://learn.microsoft.com/en-us/mem/autopilot/enrollment-status)
- **Detection rules are evaluated, not trusted** — Intune does not trust the install command's exit code alone. It runs the detection rule after the install command completes. If the detection rule returns "not detected", Intune considers the install failed and retries. This is why a working installer + wrong detection rule = infinite loop. [MS Docs: Win32 app detection](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-add#step-3-detection-rules)
- **IME logs are the ground truth** — `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` contains every app evaluation, download, install attempt, and detection result. The Intune portal status lags by minutes; the IME log is real-time. Train yourself to read it.
- **Dependency order matters** — Win32 app dependencies are evaluated and installed before the parent. If a dependency fails, the parent never runs. Check dependency app detection rules independently before blaming the parent app.
- **White glove / pre-provisioning solves the timeout problem** — In pre-provisioning mode, a technician completes the device setup phase before shipping the device to the user. The user only hits Account Setup, which is fast. For environments with heavy device-side software, this is the right architectural answer. [MS Docs: Pre-provisioning](https://learn.microsoft.com/en-us/mem/autopilot/pre-provision)
- **ESP timeout is per-phase, not total** — the configured timeout (default 60 min) applies to each phase independently. A device can theoretically take 3× the timeout before fully failing. Extending the timeout to 120 min is safe and prevents false failures on slow links.
