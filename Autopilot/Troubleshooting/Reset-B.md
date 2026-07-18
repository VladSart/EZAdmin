# Windows Autopilot Reset — Hotfix Runbook (Mode B: Ops)
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

Run these first — the ticket is almost always "reset this device for the next user," and the fastest failure mode is picking the wrong reset mechanism for the device's join type.

```powershell
# 1. Confirm join type — this is the single gate that decides whether Autopilot Reset is even possible
dsregcmd /status | Select-String "AzureAdJoined","DomainJoined","EnterpriseJoined"

# 2. Confirm WinRE is enabled — Autopilot Reset fails immediately without it
reagentc.exe /info

# 3. (Remote reset) Confirm device is MDM-managed and Entra joined via Graph
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
    Select-Object DeviceName, ManagementState, JoinType

# 4. (Local reset) Confirm the CSP policy that gates local reset is deployed
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\CredentialProviders" -ErrorAction SilentlyContinue

# 5. Check for a stale primary user / device owner if reset already ran and behaved unexpectedly
Get-MgDevice -Filter "displayName eq '<DeviceName>'" | Select-Object Id, DisplayName, RegisteredOwners
```

| Result | Action |
|--------|--------|
| `DomainJoined: YES` and `AzureAdJoined: YES` (Hybrid) | → Autopilot Reset **not supported** — go to [Fix 1](#fix-1--hybrid-joined-or-surface-hub-device-needs-a-full-wipe-instead) |
| `reagentc /info` shows `Windows RE status: Disabled` | → Go to [Fix 2](#fix-2--enable-winre) |
| Device not MDM-managed / not Entra joined | → Go to [Fix 3](#fix-3--register-or-repair-mdm-enrollment-before-remote-reset) |
| CSP policy absent on device (local reset only) | → Go to [Fix 4](#fix-4--deploy-the-local-reset-enablement-policy) |
| Reset completed but device shows old owner or new user wasn't set primary | → Go to [Fix 5](#fix-5--primary-userentra-device-owner-not-updated-after-reset) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Device Join Type]
  └─ Microsoft Entra joined (cloud-native)
         │  ✕ Entra hybrid joined  → NOT SUPPORTED, use full Wipe instead
         │  ✕ Surface Hub          → NOT SUPPORTED, use full Wipe instead
         ▼
[WinRE]
  └─ Windows Recovery Environment installed AND enabled (reagentc /enable)
         │  Checked BEFORE reset starts — fails immediately with
         │  ERROR_NOT_SUPPORTED (0x80070032) if missing/disabled
         ▼
[Reset Path — pick one]
  ├─ LOCAL RESET
  │     └─ DisableAutomaticReDeploymentCredentials CSP = 0 (Allow), deployed via
  │        Intune Device Restrictions profile ("Autopilot Reset" setting)
  │        └─ Disabled by default — must be explicitly enabled per device group
  │        └─ Triggered by end user/tech: Ctrl+Win+R at lock screen → local admin sign-in
  │
  └─ REMOTE RESET
        └─ Device is Entra joined AND actively MDM-managed (Intune)
        └─ Admin has Intune Service Administrator role
        └─ Triggered from Intune admin center: Devices > [select] > More > Autopilot Reset
         │
         ▼
[During Reset]
  └─ Personal files/apps/settings removed
  └─ Wi-Fi profiles, provisioning packages, Entra/MDM enrollment info, SCEP certs RETAINED
  └─ Desktop access blocked until MDM sync completes + provisioning packages reapplied
         │
         ▼
[Post-Reset Identity State]
  ├─ Local reset  → primary user / Entra device owner NOT auto-updated (manual fix needed)
  └─ Remote reset → primary user / Entra device owner CLEARED; next sign-in claims it
                     (shared devices remain shared)
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the device is eligible (join type is the hard gate)**
```powershell
dsregcmd /status | Select-String "AzureAdJoined","DomainJoined"
```
*Good:* `AzureAdJoined: YES`, `DomainJoined: NO` — pure Entra join, Autopilot Reset supported.
*Bad:* `DomainJoined: YES` alongside `AzureAdJoined: YES` — this is a hybrid join. Autopilot Reset will not work; stop here and use a full device Wipe instead (see Fix 1).

**2. Confirm WinRE state**
```cmd
reagentc.exe /info
```
*Good:* `Windows RE status: Enabled`.
*Bad:* `Disabled` or `Windows RE is not configured on this PC.` — reset will fail immediately with `ERROR_NOT_SUPPORTED (0x80070032)`.

**3. For local reset — confirm the enablement policy landed on the device**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\CredentialProviders" -ErrorAction SilentlyContinue |
    Select-Object DisableAutomaticReDeploymentCredentials
```
*Good:* Value `0` (Allow). *Bad:* Value `1` or key absent — local reset is disabled (this is the secure-by-default state; it must be explicitly turned on per device group via an Intune Device Restrictions profile).

**4. For remote reset — confirm MDM management state via Graph**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
    Select-Object DeviceName, ManagementState, JoinType, LastSyncDateTime
```
*Good:* `ManagementState: managed`, recent `LastSyncDateTime`. *Bad:* Device absent from results, or stale sync (>7 days) — device may be offline or enrollment is broken; remote reset requires the device to actually check in to execute.

**5. After reset — confirm identity handoff**
```powershell
Get-MgDevice -Filter "displayName eq '<DeviceName>'" | Select-Object DisplayName, RegisteredOwners
```
*Good (remote reset):* Owner cleared or reassigned to the new signed-in user automatically.
*Expected (local reset):* Owner still shows the previous user — this is documented behavior, not a bug; update manually if needed.

---
## Common Fix Paths

<details><summary>Fix 1 — Hybrid-joined or Surface Hub device needs a full Wipe instead</summary>

Use when: `dsregcmd /status` shows `DomainJoined: YES` (hybrid join), or the device is a Surface Hub.

Autopilot Reset explicitly does not support these device types. The correct action is a full device Wipe from Intune (Devices > [select] > Wipe), optionally with **Retain enrollment state and user account** unchecked for a true factory reset.

```powershell
# Trigger a full wipe via Graph (equivalent to the portal "Wipe" action)
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.PrivilegedOperations.All"
$deviceId = (Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'").Id
Invoke-MgWipeDeviceManagementManagedDevice -ManagedDeviceId $deviceId -KeepEnrollmentData:$false -KeepUserData:$false
```

**Known timing gotcha:** after a hybrid-joined device goes through a full wipe, it can take up to **24 hours** before it's ready to be deployed again (the stale Entra/AD device object needs to clear). This can be expedited by manually re-registering the device object rather than waiting out the window.

**Rollback:** N/A — a wipe is destructive by design; there is no rollback once initiated.

</details>

<details><summary>Fix 2 — Enable WinRE</summary>

Use when: `reagentc /info` shows WinRE disabled or not configured.

```cmd
reagentc.exe /enable
reagentc.exe /info
```

If `/enable` fails, check that the recovery partition exists and has free space:
```cmd
reagentc.exe /info
diskpart
    list disk
    list partition
```
If the recovery partition was deleted or is too small, WinRE cannot be re-enabled without rebuilding the partition — escalate rather than attempting partition surgery on a production device.

**Rollback:** N/A — enabling WinRE is non-destructive and required for many other Windows recovery features, not just Autopilot Reset.

</details>

<details><summary>Fix 3 — Register or repair MDM enrollment before remote reset</summary>

Use when: device doesn't appear in `Get-MgDeviceManagementManagedDevice`, or `ManagementState` isn't `managed`.

```powershell
# On the device — confirm and force enrollment sync
dsregcmd /status
Start-Process -FilePath "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o"
```

Remote Autopilot Reset requires the device to be both Entra joined **and** actively MDM-managed at the moment the action is issued — a device that dropped enrollment (expired token, certificate issue) will show the action as available in the portal but it will silently never complete.

**Rollback:** N/A — corrective action.

</details>

<details><summary>Fix 4 — Deploy the local reset enablement policy</summary>

Use when: local reset is needed at scale (e.g., a shared-device pool, kiosk fleet, or field techs without portal access) but the CSP isn't deployed yet.

In Intune admin center:
1. **Devices > Configuration > Create > New Policy**
2. Platform: **Windows 10 and later**, Profile type: **Templates > Device restrictions**
3. Under **General**, set **Autopilot Reset** = **Allow**
4. Assign to the target device group

```powershell
# Validate the policy landed (run on device after next sync)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\CredentialProviders" |
    Select-Object DisableAutomaticReDeploymentCredentials
```

**This is intentionally opt-in per device group** — leaving it disabled tenant-wide is the safer default since anyone with local admin and physical access can trigger the reset once enabled (Ctrl+Win+R at the lock screen).

**Rollback:** Set the profile setting back to **Block**, or unassign the profile from the group.

</details>

<details><summary>Fix 5 — Primary user/Entra device owner not updated after reset</summary>

Use when: reset completed successfully but the device still shows the old user, or (for local reset) the new user isn't reflected.

This is **expected behavior for local reset** — it never touches primary user/device owner automatically. For remote reset, the owner should clear and reassign on next sign-in; if it doesn't, force it manually:

```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All"
$deviceId = (Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'").Id
Invoke-MgUpdateDeviceManagementManagedDeviceOwnedByUser -ManagedDeviceId $deviceId -UserId "<NewUserObjectId>"
```

**Rollback:** Re-run pointing at the previous user's object ID if reassigned incorrectly.

</details>

---
## Escalation Evidence

```
WINDOWS AUTOPILOT RESET ESCALATION
======================================
Date/Time                 :
Tenant ID                  :
Device Name                 :
Device Object ID             :
Join Type (dsregcmd)         : (AzureAdJoined / HybridJoined / DomainOnly)
Reset Type Attempted         : (Local / Remote)
WinRE Status (reagentc /info) :
MDM ManagementState           :
Local Reset CSP Value (if local) :
Error Code (if any)           :
Primary User Before Reset      :
Primary User After Reset       :
Steps Already Tried            :
```

---
## 🎓 Learning Pointers

- **Join type is the hard gate, not a soft preference** — Autopilot Reset flatly does not support Entra hybrid joined devices or Surface Hub. There's no workaround or override; the only path for those device types is a full Wipe, which carries its own up-to-24-hour re-registration delay for hybrid devices.
- **Local and remote reset diverge on identity handoff** — local reset deliberately leaves primary user/Entra device owner untouched (an admin must update it manually), while remote reset clears it so the next signed-in user is automatically claimed. Picking the wrong one for a device handoff scenario creates confusing ownership records.
- **Local reset is opt-in by design, not an oversight** — `DisableAutomaticReDeploymentCredentials` defaults to blocking local reset specifically so that Ctrl+Win+R at a lock screen can't be used as a casual bypass. Only enable it for device groups where that trigger path is genuinely needed (shared devices, field techs).
- **WinRE is checked before anything else happens** — a missing or disabled recovery environment fails the entire reset immediately (`ERROR_NOT_SUPPORTED (0x80070032)`), before any user data is touched. Always verify `reagentc /info` first, especially on devices imaged by an OEM or third party that may ship with a broken or undersized recovery partition.
- **MS Docs:** [Windows Autopilot Reset](https://learn.microsoft.com/en-us/autopilot/windows-autopilot-reset) | [Local Windows Autopilot Reset](https://learn.microsoft.com/en-us/autopilot/tutorial/reset/local-autopilot-reset) | [Remote Windows Autopilot Reset](https://learn.microsoft.com/en-us/autopilot/tutorial/reset/remote-autopilot-reset) | [Device action: Autopilot Reset](https://learn.microsoft.com/en-us/intune/device-management/actions/autopilot-reset)
