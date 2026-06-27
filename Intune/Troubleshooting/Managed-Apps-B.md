# Intune Managed Apps (MAM) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate MAM policy failures, app protection policy issues, and managed app data wipe in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run these on the **affected device** (or via Intune remote actions). Read the output table to determine your next step.

```powershell
# 1. Check Company Portal / Intune agent status (Windows MAM)
Get-Process -Name "CompanyPortal" -ErrorAction SilentlyContinue | Select-Object Name, Id, CPU

# 2. Check Intune Management Extension (IME) — required for Win32 MAM
Get-Service -Name "IntuneManagementExtension" -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType

# 3. Check MAM registration status (Windows Information Protection / MAM-WE)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WorkplaceJoin\TenantInfo\*" -ErrorAction SilentlyContinue |
    Select-Object TenantName, IsFederated

# 4. List apps with Intune MAM policy (via Graph — run from admin host)
# Connect-MgGraph -Scopes "DeviceManagementApps.Read.All"
# Get-MgDeviceAppManagementManagedAppStatus | Select-Object DisplayName, Status
```

| Result | Action |
|--------|--------|
| IME service stopped | → [Fix 1 — Restart IME](#fix-1--restart-intune-management-extension) |
| App protection policy showing "Not applied" | → [Fix 2 — Force MAM policy sync](#fix-2--force-mam-policy-sync) |
| "Access blocked" in managed app (Outlook, Teams, Edge) | → [Fix 3 — App protection conditional launch failure](#fix-3--resolve-app-protection-conditional-launch-block) |
| Selective wipe needed | → [Fix 4 — Trigger selective wipe](#fix-4--trigger-selective-wipe) |
| "Unmanaged" app status in Intune portal | → [Fix 5 — Re-enroll MAM registration](#fix-5--re-enroll-mam-registration) |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Entra ID user identity
        │
        ▼
App Protection Policy (MAM) assigned to user/group
        │
        ▼
Target app installed (Outlook, Teams, Edge, Company Portal, etc.)
        │
        ├── iOS/Android (MAM-WE — no enrollment needed)
        │       └── App SDK embedded in target app
        │           └── Policy fetched via Intune MAM endpoint
        │               (manage.microsoft.com)
        │
        └── Windows (MAM-WE or MDM-enrolled)
                └── Intune Management Extension (IME)
                    └── Company Portal (registration)
                        └── App Protection Policy applied at app launch
```

**MAM-WE (Without Enrollment) requirements:**
- User signs into managed app (Outlook/Teams/Edge) with work/school account
- App must include Intune App SDK or be wrapped
- Network access to `manage.microsoft.com` and `login.microsoftonline.com`

**MDM + MAM (enrolled devices):**
- Device enrolled in Intune
- App Protection Policy targets the user
- App installed from Company Portal or managed deployment

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Check app protection policy assignment in Intune portal**
```
Intune portal → Apps → App protection policies
→ Select policy → Properties → Assignments
→ Confirm the user's group is included (not excluded)
```
Expected: User appears in "Included groups." If in both included and excluded, exclusion wins.

**Step 2 — Check policy status per user**
```
Intune portal → Apps → App protection policies
→ Select policy → Monitor → App protection status
→ Search for the user
```
Expected: Status = "Checked in". Last check-in timestamp should be recent (within 24h).
Bad: "Not checked in" or no entry → policy never reached the device.

**Step 3 — Check managed app registration (iOS/Android)**
```
Intune portal → Apps → Monitor → App protection status
→ App report tab → filter by user
→ Check "Managed" column for each app
```

**Step 4 — Verify Intune MAM service reachability**
```powershell
# Windows — test MAM endpoint
Test-NetConnection -ComputerName "manage.microsoft.com" -Port 443
Test-NetConnection -ComputerName "fef.msua06.manage.microsoft.com" -Port 443
```
Expected: `TcpTestSucceeded: True`

**Step 5 — Check IME logs (Windows)**
```powershell
$logPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
Get-ChildItem $logPath | Sort-Object LastWriteTime -Descending | Select-Object -First 3

# Tail the current log for MAM errors:
Get-Content "$logPath\IntuneManagementExtension.log" -Tail 50 | Select-String -Pattern "MAM|AppProtection|Error|Failed"
```

---

## Common Fix Paths

<details><summary>Fix 1 — Restart Intune Management Extension</summary>

**Use when:** IME service stopped, Win32 app policies not applying, MAM check-in failing on Windows.

```powershell
# Restart IME service
Restart-Service -Name "IntuneManagementExtension" -Force
Start-Sleep -Seconds 10
Get-Service -Name "IntuneManagementExtension" | Select-Object Status

# Verify it checked in — look for "Agent checkin" in log
$logPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Get-Content $logPath -Tail 30 | Select-String "checkin|MAM|success"
```

If service won't start:
```powershell
# Re-register IME
$imePath = "${env:ProgramFiles}\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe"
if (Test-Path $imePath) {
    & $imePath /uninstall
    Start-Sleep -Seconds 5
    & $imePath /install
}
```

**Rollback:** N/A — this is non-destructive.

</details>

<details><summary>Fix 2 — Force MAM policy sync</summary>

**Use when:** Policy assigned but "Not checked in" / stale status in Intune portal.

**Via Intune portal (remote):**
```
Intune → Devices → [Select device] → Sync
```

**Via PowerShell (Windows — runs as user or SYSTEM):**
```powershell
# Trigger Intune sync via scheduled task
$scheduledTask = Get-ScheduledTask -TaskName "PushLaunch" -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" -ErrorAction SilentlyContinue
if ($scheduledTask) {
    Start-ScheduledTask -TaskPath $scheduledTask.TaskPath -TaskName $scheduledTask.TaskName
    Write-Output "Sync task triggered."
} else {
    # Fallback: restart IME (triggers immediate check-in)
    Restart-Service IntuneManagementExtension -Force
    Write-Output "IME restarted — check-in will occur within 2 minutes."
}
```

**On iOS/Android (user-driven):**
- Company Portal app → tap username → "Sync device"
- Or within the managed app: Settings → Work Account → Sync

Allow 5–10 minutes for policy to reflect in Intune portal after sync.

</details>

<details><summary>Fix 3 — Resolve app protection conditional launch block</summary>

**Use when:** User blocked from accessing work data in Outlook, Teams, or Edge with a policy enforcement message (e.g., "Your organization requires device PIN", "Jailbreak detected", "OS version not supported").

**Step 1 — Identify which conditional launch condition is blocking:**
```
Intune → Apps → App protection policies → [Policy] → Conditional launch settings
```
Common blocking conditions:
- Min OS version not met → User needs OS update
- PIN required, not set → User must set app PIN in the managed app
- Jailbreak/root detected → Device non-compliant; escalate or wipe
- Max PIN attempts → [Fix below]

**Step 2 — Reset PIN lock (admin-driven):**
```powershell
# Via Graph API — reset MAM PIN for a user
# Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All"

$userId = "<entraObjectId>"
# List managed app registrations
$registrations = Get-MgUserManagedAppRegistration -UserId $userId

# Wipe/reset a specific registration (removes PIN lock, not data)
$registrationId = $registrations[0].Id
Remove-MgUserManagedAppRegistration -UserId $userId -ManagedAppRegistrationId $registrationId
Write-Output "MAM registration reset. User must re-authenticate to managed app."
```

**Step 3 — If OS version blocking:**
- iOS: Settings → General → Software Update
- Android: Settings → System → System Update
- Windows: Settings → Windows Update

Minimum version requirements are in the policy conditional launch settings.

**Rollback:** PIN reset is non-destructive (work data preserved). If MAM registration removed, user re-registers on next app sign-in.

</details>

<details><summary>Fix 4 — Trigger selective wipe</summary>

**Use when:** User is leaving org, device lost/stolen, or security incident requiring removal of corporate data from managed apps without wiping the device.

> ⚠️ Selective wipe removes corporate data (email, files, tokens) from managed apps. Personal data and the device itself are unaffected.

**Via Intune portal:**
```
Intune → Apps → App protection policies → Monitor → App protection status
→ Find user → Select device → Wipe
```

**Via PowerShell (Graph):**
```powershell
# Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All"

$userId = "<entraObjectId>"
$managedDeviceId = "<managedDeviceId>"  # from Get-MgUserManagedDevice

# Trigger MAM selective wipe
$uri = "https://graph.microsoft.com/v1.0/users/$userId/managedAppRegistrations/$managedDeviceId/wipe"
Invoke-MgGraphRequest -Method POST -Uri $uri
Write-Output "Selective wipe initiated. App must check in to execute wipe."
```

**Timing:** Wipe executes when the app next checks in with the MAM service. If device is offline, wipe queues until connectivity is restored. Average: 1–4 hours for online device.

**Rollback:** Cannot undo a selective wipe. Verify user/device before triggering.

</details>

<details><summary>Fix 5 — Re-enroll MAM registration (iOS/Android)</summary>

**Use when:** App shows "Unmanaged" despite being assigned, or user switched accounts in managed app.

**User-driven steps:**
1. Sign out of work account in the managed app (Outlook: File → Account → Remove)
2. Uninstall and reinstall the app
3. Sign back in with work/school account
4. Allow Company Portal to register the device if prompted

**Admin-driven (removes stale registration first):**
```powershell
# Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All"

$userId = "<entraObjectId>"
$registrations = Get-MgUserManagedAppRegistration -UserId $userId

# List registrations — identify stale one
$registrations | Select-Object Id, AppIdentifier, DeviceName, CreatedDateTime

# Remove stale registration
$staleId = "<registrationId>"
Remove-MgUserManagedAppRegistration -UserId $userId -ManagedAppRegistrationId $staleId
Write-Output "Stale registration removed. User must re-authenticate to trigger new registration."
```

</details>

---

## Escalation Evidence

```
=== Intune MAM Escalation Pack ===
Date/Time:          _______________
Engineer:           _______________
Tenant ID:          _______________

Affected User UPN:          _______________
Affected App(s):            _______________
Device Platform:            [ ] iOS  [ ] Android  [ ] Windows  [ ] macOS
Device Name:                _______________
Intune Device ID:           _______________

App Protection Policy Name: _______________
Policy Last Check-In:       _______________
Policy Status in Portal:    _______________

Error message seen by user: _______________
Error in IME log (if Win):  _______________

Conditional Launch condition blocking (if applicable): _______________

Steps already taken:
[ ] Confirmed policy assignment includes user/group
[ ] Triggered device sync
[ ] Restarted IME (Windows)
[ ] Checked manage.microsoft.com reachability
[ ] Reviewed App protection status report in Intune

MAM endpoint reachable:     [ ] Yes  [ ] No
IME log path attached:      [ ] Yes  [ ] N/A

Support tier:               [ ] L2 → L3  [ ] L3 → Microsoft
```

---

## 🎓 Learning Pointers

- **MAM-WE vs MDM-enrolled MAM are different flows:** MAM Without Enrollment uses the Intune App SDK inside the app and requires no device enrollment. MDM-enrolled devices use Intune's full device management channel plus MAM. A user can have both active simultaneously on BYOD (MAM-WE) and corporate (MDM+MAM) devices. See: [MAM overview](https://docs.microsoft.com/en-us/mem/intune/apps/app-protection-policy)

- **Policy check-in is app-driven, not device-driven:** On iOS/Android, the managed app calls the MAM endpoint at each app launch (and periodically in background). If the app is force-closed or device is offline, policy won't update until next check-in. The "check-in frequency" is configurable in the policy. See: [MAM policy delivery](https://docs.microsoft.com/en-us/mem/intune/apps/app-protection-policy-delivery)

- **Conditional launch failures are logged in the app, not just Intune:** On iOS, managed app logs can be sent via Company Portal → Diagnostics. On Android, use the Intune Diagnostics app or Logcat. These logs often show the exact conditional launch condition that blocked access — faster to read than digging through Intune portal.

- **"Not targeted" vs "Not enrolled" vs "Not checked in" have distinct meanings:** Not targeted = policy doesn't include the user. Not enrolled = MAM registration not created (app never signed in). Not checked in = registration exists but policy hasn't synced recently. Fix path differs for each.

- **Selective wipe is the right action for leavers and lost BYOD:** Unlike a device wipe, selective wipe leaves personal apps and data intact. It's the correct process for BYOD offboarding. Document it in your offboarding runbook. Corporate-owned devices should get a full wipe via Intune device action. See: [Selective wipe](https://docs.microsoft.com/en-us/mem/intune/apps/apps-selective-wipe)
