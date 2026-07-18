# Windows Autopilot Reset — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)

---
## Scope & Assumptions

This runbook covers **Windows Autopilot Reset** — the "return this device to a business-ready state, keep it enrolled" reset mechanism, as distinct from three other Windows/Intune reset mechanisms that get confused with it in day-to-day MSP work:

| Mechanism | Keeps Entra join? | Keeps MDM enrollment? | Removes OEM bloat? | Supports Hybrid Join? |
|-----------|:---:|:---:|:---:|:---:|
| **Autopilot Reset** (this doc) | Yes | Yes | No (reapplies existing config) | **No** |
| **Wipe** (factory reset) | Optional (`KeepEnrollmentData`) | Optional (`KeepEnrollmentData`) | Yes (full OS reinstall) | Yes |
| **Fresh Start** | Yes | Auto re-enrolls on next Entra sign-in | Yes | Not applicable (Entra-join scenario) |
| **Autopilot re-registration + full wipe** | No (device object recreated) | No | Yes | Yes (the actual hybrid-join reset path) |

Autopilot Reset's entire value proposition is *speed and continuity*: it doesn't reinstall Windows or re-run the Autopilot OOBE deployment profile from scratch. It strips personal state and hands the device to the next user while keeping the device's existing Entra/Intune identity and configuration intact — which is exactly why it has a narrower support matrix than a full wipe.

**Assumes:**
- Devices are Windows 10/11, MDM-managed via Intune
- Caller has Intune Service Administrator role for remote reset scenarios
- Familiarity with `dsregcmd`, Graph PowerShell SDK, and basic WinRE/REAgentC operations

---
## How It Works

<details><summary>Full architecture</summary>

### What Autopilot Reset actually does

1. Removes personal files, installed apps (beyond the original baseline), and user settings
2. Reapplies the device's original configuration — region, language, keyboard, Wi-Fi profiles, provisioning packages
3. Keeps the device's Entra ID identity connection and Intune management connection intact — no re-enrollment, no new device object
4. Blocks the sign-in screen / desktop access until an MDM policy sync completes and any provisioning packages are reapplied — this is a deliberate gate, not a bug, ensuring the device is fully policy-compliant before handoff

### What's retained across the reset (this is the differentiator vs. a wipe)

- Wi-Fi connection details and credentials
- Provisioning packages previously applied to the device
- A provisioning package present on a USB drive plugged in at reset time (local reset only)
- Microsoft Entra device membership and MDM enrollment information (the device object itself — no re-registration)
- SCEP certificates

### The two trigger scenarios

**Local reset** — for field techs, shared-device carts, or kiosk-style redeployment without portal access:
```
Prerequisite: DisableAutomaticReDeploymentCredentials CSP = 0 (Allow)
    deployed via Intune Device Restrictions profile, "Autopilot Reset" = Allow
    (disabled tenant-wide by default — deliberate secure default)
        │
        ▼
At lock screen: Ctrl+Win+R
        │
        ▼
Custom sign-in screen appears (dual purpose: authorization check + provisioning
package notice)
        │
        ▼
Sign in with local administrator credentials
        │
        ▼
Reset executes locally — no MDM round-trip required to *trigger* it, though MDM
sync still gates final desktop access
```
Note: local reset does **not** update the device's primary user or Entra device owner automatically — this must be done manually post-reset if ownership needs to change.

**Remote reset** — for IT-initiated redeployment without physically touching the device:
```
Prerequisite: device is Entra joined AND actively MDM-managed (Intune)
Prerequisite: admin has Intune Service Administrator role
        │
        ▼
Intune admin center: Devices > [select device(s)] > More > Autopilot Reset
        │
        ▼
Reset command delivered via MDM channel on next device check-in
        │
        ▼
Reset executes — primary user and Entra device owner are CLEARED
        │
        ▼
Next user to sign in becomes the new primary user / device owner automatically
(shared devices remain marked as shared — this reassignment doesn't apply to them)
```

### The hard exclusion: hybrid join and Surface Hub

Autopilot Reset's entire mechanism depends on the device's Entra join and MDM enrollment being directly reusable without re-registration. A hybrid-joined device's identity is anchored in on-prem AD first, synced to Entra via Entra Connect — that dependency chain cannot be "reset in place" the way a pure cloud-native Entra join can. Surface Hub devices are excluded because they run a locked-down device-family OS profile with its own separate reset semantics.

For both, the only supported path is a **full device Wipe**. For hybrid-joined devices specifically, this carries a known operational cost: **up to 24 hours** before the device is ready to redeploy, because the stale on-prem AD/Entra device object needs to age out before the device can complete a clean re-registration. This can be expedited by manually re-registering the device object rather than waiting.

### WinRE as a hard preflight gate

Before any user data is touched, Autopilot Reset checks whether Windows Recovery Environment is configured and enabled. If not, the entire operation fails immediately with `ERROR_NOT_SUPPORTED (0x80070032)` — this is a fast, safe failure (nothing is touched), but it's a common surprise on devices imaged by a third party or OEM that shipped with WinRE disabled or the recovery partition undersized/removed.

</details>

---
## Dependency Stack

```
Device Identity Layer
    └── Microsoft Entra ID joined (cloud-native)
            └── NOT Entra hybrid joined (hard exclusion)
            └── NOT Surface Hub (hard exclusion)

Recovery Environment Layer
    └── WinRE installed AND enabled (reagentc /enable)
            └── Recovery partition present with sufficient free space
            └── Checked as a preflight gate BEFORE any reset action begins

Trigger Path Layer (pick one)
    ├── Local Reset Path
    │       └── DisableAutomaticReDeploymentCredentials CSP = Allow (0)
    │               └── Delivered via Intune Device Restrictions profile
    │               └── Assigned to the correct device group (disabled by default elsewhere)
    │       └── Local administrator credentials available to whoever triggers it
    │
    └── Remote Reset Path
            └── Device actively MDM-managed (recent check-in)
            └── Admin holds Intune Service Administrator role
            └── Device reachable to receive the MDM command on next sync

Execution Layer
    └── Personal data/apps/settings stripped
    └── Retained state reapplied (Wi-Fi, provisioning packages, SCEP certs, Entra/MDM identity)
    └── Desktop access blocked until MDM sync completes + provisioning packages reapplied

Post-Reset Identity Layer
    ├── Local reset  → primary user / device owner unchanged (manual update if needed)
    └── Remote reset → primary user / device owner cleared → claimed by next sign-in
            └── Exception: shared devices remain shared, no reassignment
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Reset fails immediately with `ERROR_NOT_SUPPORTED (0x80070032)` | WinRE disabled or not configured | `reagentc /info` |
| Ctrl+Win+R at lock screen does nothing | `DisableAutomaticReDeploymentCredentials` not deployed/still `1` (Block) on this device | Check CSP value + Intune profile assignment |
| "Autopilot Reset" action greyed out or fails silently in Intune portal | Device is hybrid joined, or not currently MDM-managed | `dsregcmd /status` + `ManagementState` via Graph |
| Reset ran, but device still shows the previous user as primary | Local reset was used — this is documented behavior, not a failure | Confirm which reset path was used; update owner manually if needed |
| Reset stuck at "Applying settings," desktop never appears | MDM sync not completing, or a provisioning package failed to reapply | Check MDM enrollment health and provisioning package event log |
| Hybrid-joined device given to a new user still shows stale info days later | Full wipe was used (correct choice) but device hasn't finished re-registering | Confirm elapsed time vs. the documented up-to-24h re-registration window; expedite via manual re-registration if urgent |
| Wi-Fi doesn't reconnect automatically after reset | Wi-Fi profile wasn't actually pre-existing on the device (e.g., first-ever connection was via captive portal or manual entry that wasn't saved as a managed profile) | Confirm the profile existed before reset; retention only applies to profiles present at reset time |
| Provisioning package on USB drive wasn't applied | Package wasn't detected because it was inserted after the Ctrl+Win+R screen appeared, or the package itself failed validation | Re-trigger with the USB drive already inserted before initiating reset |

---
## Validation Steps

**Step 1 — Confirm device eligibility (join type)**
```powershell
dsregcmd /status | Select-String "AzureAdJoined","DomainJoined","EnterpriseJoined"
```
*Good:* `AzureAdJoined: YES`, `DomainJoined: NO`. *Bad:* `DomainJoined: YES` present alongside Entra join — hybrid, not eligible.

**Step 2 — Confirm WinRE**
```cmd
reagentc.exe /info
```
*Good:* `Windows RE status: Enabled`, with a valid recovery partition path shown. *Bad:* `Disabled` or no partition listed.

**Step 3 — Confirm local reset enablement (if using local path)**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\CredentialProviders" -ErrorAction SilentlyContinue |
    Select-Object DisableAutomaticReDeploymentCredentials
```
*Good:* `0`. *Bad:* `1` or key missing — policy not deployed/synced to this device yet.

**Step 4 — Confirm MDM management state (if using remote path)**
```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
    Select-Object DeviceName, ManagementState, JoinType, LastSyncDateTime
```
*Good:* `ManagementState: managed`, `LastSyncDateTime` recent. *Bad:* Device not found, or stale sync.

**Step 5 — Confirm caller's role for remote reset**
```powershell
Get-MgUserMemberOf -UserId "<caller UPN>" | Where-Object { $_.AdditionalProperties.displayName -eq "Intune Service Administrator" }
```
*Good:* Role present. *Bad:* Empty result — the reset action will not be available/permitted.

**Step 6 — Post-reset identity confirmation**
```powershell
Get-MgDevice -Filter "displayName eq '<DeviceName>'" | Select-Object DisplayName, RegisteredOwners
```
Compare against expectations for the reset path used (see Symptom → Cause Map).

---
## Troubleshooting Steps (by phase)

### Phase 1: Eligibility Failures

1. Always confirm join type before troubleshooting anything else — this is the #1 cause of "the reset option doesn't work/isn't there."
2. If hybrid joined: stop troubleshooting Autopilot Reset entirely and pivot to Remediation Playbook 1 (full Wipe path).
3. If Surface Hub: same pivot — full wipe/reset via Surface Hub's own device reset flow, not covered by this document.

### Phase 2: WinRE Preflight Failures

1. Run `reagentc /info`. If disabled, attempt `reagentc /enable`.
2. If `/enable` fails, check for a missing/corrupted recovery partition:
   ```cmd
   reagentc /info
   diskpart
       list disk
       select disk 0
       list partition
   ```
3. A missing recovery partition typically means the device was imaged without one (some OEM lean images strip it to save disk space) — this requires a partition rebuild, which is out of scope for a live production device; escalate for offline remediation or plan a full wipe/reimage instead.

### Phase 3: Local Reset Trigger Failures

1. Confirm the Device Restrictions profile with **Autopilot Reset = Allow** is actually assigned to the target device's group — a profile that exists but isn't assigned to the right group is the most common miss.
2. Confirm the device has synced since the profile was assigned (`Get-MgDeviceManagementManagedDevice` `LastSyncDateTime`, or force with a manual sync).
3. Confirm the person triggering the reset actually holds local administrator credentials on that specific device — domain/Entra admin roles do not automatically grant local admin rights unless configured via LAPS, Entra-joined-device local admin group policy, or similar.

### Phase 4: Remote Reset Trigger Failures

1. Confirm `ManagementState: managed` and a recent check-in — a device that's gone stale in Intune will show the action as available but it silently won't execute until the device reconnects.
2. Confirm the admin's role assignment includes Intune Service Administrator (or equivalent custom RBAC role with the specific remote-actions permission) — a Help Desk Operator or Read Only Operator role will not see or cannot execute this action.
3. If the action was issued but nothing happens after a reasonable window, check the device's own MDM diagnostic log for a rejected or failed command rather than re-issuing repeatedly.

### Phase 5: Post-Reset Anomalies

1. If personal data appears NOT to have been removed: confirm the reset actually completed (check MDM sync + provisioning package reapplication status) rather than assuming it silently failed to strip data — an incomplete reset blocks desktop access rather than handing over a half-reset device, so this is more likely "still in progress" than "failed silently."
2. If Wi-Fi/provisioning packages didn't carry over: confirm they genuinely existed on the device *before* the reset — retention only applies to state that existed prior, it does not pull from a central template.
3. If primary user/owner is wrong post-reset: refer to the Symptom → Cause Map — this is reset-path-dependent behavior, not a fault in most cases.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full Wipe for hybrid-joined or Surface Hub devices (the actual hybrid reset path)</summary>

Use when: device is confirmed hybrid joined (or Surface Hub) and needs to be handed to a new user or fully reprovisioned.

```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.PrivilegedOperations.All"
$deviceId = (Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'").Id

# Full wipe — KeepEnrollmentData/KeepUserData both false for a true factory reset
# back to Autopilot OOBE (device will re-run the Autopilot deployment profile)
Invoke-MgWipeDeviceManagementManagedDevice -ManagedDeviceId $deviceId `
    -KeepEnrollmentData:$false -KeepUserData:$false
```

Expect up to 24 hours before the device's on-prem AD/Entra device object clears and the device is ready to re-enroll cleanly. To expedite, manually remove/re-register the stale device object in Entra ID and on-prem AD rather than waiting out the window — coordinate with the on-prem AD team since this touches synced objects.

**Rollback:** N/A — a wipe is destructive and irreversible once initiated. If triggered against the wrong device, there's no recall; only prevention (double-check device name/serial before confirming) applies.

</details>

<details><summary>Playbook 2 — Bulk remote reset for a batch of returning devices (e.g., end of a project, seasonal fleet)</summary>

```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.PrivilegedOperations.All"

$deviceNames = @("<Device1>","<Device2>","<Device3>")
foreach ($name in $deviceNames) {
    $dev = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$name'"
    if ($dev -and $dev.JoinType -notmatch "hybrid") {
        Invoke-MgCleanWindowsDeviceDeviceManagementManagedDevice -ManagedDeviceId $dev.Id
        Write-Host "Autopilot Reset issued for $name"
    } else {
        Write-Warning "$name skipped — not eligible (hybrid joined or not found)"
    }
}
```

Note: batching still respects each device's individual eligibility — always filter out hybrid-joined devices in the loop rather than assuming a device list is uniformly eligible.

**Rollback:** N/A — same as single-device remote reset; once issued and executed it cannot be undone.

</details>

<details><summary>Playbook 3 — Recover a device stuck mid-reset (desktop never appears)</summary>

1. Confirm the device still has network connectivity — MDM sync completion is a hard gate before desktop access, so a device that lost network mid-reset will appear stuck indefinitely.
2. Check provisioning package application status via the Autopilot/ModernDeployment diagnostic event log:
   ```powershell
   Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot" -MaxEvents 50 |
       Select-Object TimeCreated, Id, Message | Format-Table -Wrap
   ```
3. If a specific provisioning package repeatedly fails to reapply, remove/republish that package rather than repeatedly retrying the full reset.
4. If genuinely stuck with no progress and no network issue, a hard restart is safe (the reset process is designed to resume/re-evaluate on boot) — this is not equivalent to interrupting a Windows feature update mid-install.

**Rollback:** N/A — this playbook is itself the recovery path, not a change requiring rollback.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collect Windows Autopilot Reset evidence for a device, for escalation
.DESCRIPTION Gathers join state, WinRE status, local-reset CSP state, and MDM
             management state relevant to Autopilot Reset troubleshooting.
.PARAMETER   DeviceName   Local device hostname (for local diagnostics section)
.EXAMPLE     .\Collect-AutopilotResetEvidence.ps1 -DeviceName "CONTOSO-LT-042"
#>
param(
    [Parameter(Mandatory)][string]$DeviceName
)

Write-Host "`n=== DEVICE JOIN STATE ===" -ForegroundColor Cyan
dsregcmd /status | Select-String "AzureAdJoined","DomainJoined","EnterpriseJoined","TenantId","DeviceId"

Write-Host "`n=== WINRE STATE ===" -ForegroundColor Cyan
reagentc /info

Write-Host "`n=== LOCAL RESET CSP STATE ===" -ForegroundColor Cyan
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\CredentialProviders" -ErrorAction SilentlyContinue |
    Select-Object DisableAutomaticReDeploymentCredentials

Write-Host "`n=== RECENT AUTOPILOT/MODERNDEPLOYMENT EVENTS ===" -ForegroundColor Cyan
Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot" -MaxEvents 30 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap

Write-Host "`nNOTE: Also capture manually via Graph/portal:" -ForegroundColor Yellow
Write-Host "  - Get-MgDeviceManagementManagedDevice ManagementState + LastSyncDateTime"
Write-Host "  - Get-MgDevice RegisteredOwners (before and after reset, for identity handoff disputes)"
Write-Host "  - Intune admin center > Devices > [device] > Device actions history (for remote reset command status)"
```

---
## Command Cheat Sheet

```powershell
# Check join type (hard eligibility gate)
dsregcmd /status

# Check WinRE state
reagentc /info
reagentc /enable

# Check local reset CSP value on device
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\CredentialProviders" |
    Select-Object DisableAutomaticReDeploymentCredentials

# Connect for Graph-based checks
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All","DeviceManagementManagedDevices.PrivilegedOperations.All"

# Check MDM management state
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'"

# Trigger remote Autopilot Reset via Graph
Invoke-MgCleanWindowsDeviceDeviceManagementManagedDevice -ManagedDeviceId "<ManagedDeviceId>"

# Trigger a full Wipe (for hybrid-joined/Surface Hub devices)
Invoke-MgWipeDeviceManagementManagedDevice -ManagedDeviceId "<ManagedDeviceId>" -KeepEnrollmentData:$false -KeepUserData:$false

# Check device owner before/after
Get-MgDevice -Filter "displayName eq '<DeviceName>'" | Select-Object DisplayName, RegisteredOwners

# Local reset trigger (physical device, at lock screen)
# Ctrl+Win+R  → sign in with local admin credentials

# Autopilot diagnostic event log
Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot" -MaxEvents 50
```

---
## 🎓 Learning Pointers

- **Four different "reset" mechanisms exist and they are not interchangeable** — Autopilot Reset, Wipe, Fresh Start, and hybrid-join re-registration each have a distinct scope (see the comparison table in Scope & Assumptions). Picking based on habit rather than the device's actual join type and desired end state is the most common source of confused tickets in this area.
- **Hybrid join is a hard, permanent exclusion, not a configuration gap** — there is no policy, license, or setting that enables Autopilot Reset for hybrid-joined devices. The architecture itself depends on an identity model (pure cloud Entra join) that hybrid join doesn't provide. Internalize this as a fast triage decision, not something to troubleshoot around.
- **Local vs. remote reset make different promises about identity handoff** — this is easy to get backwards. Local reset is the one that leaves the old owner in place (manual fix needed); remote reset is the one that clears it automatically. If a client asks "why does this device still show the old employee," the first question is which reset path was used.
- **WinRE health is worth checking proactively, not just reactively** — because it's a preflight gate that fails fast and safe, a fleet-wide `reagentc /info` sweep before a big redeployment project (e.g., seasonal device returns) can catch broken recovery partitions before they become day-of blockers.
- **The 24-hour hybrid-wipe window is a real operational constraint to communicate to clients** — when scoping a hybrid-joined device turnover project, build this delay into the timeline rather than promising same-day redeployment across the board.
- **MS Docs:** [Windows Autopilot Reset](https://learn.microsoft.com/en-us/autopilot/windows-autopilot-reset) | [Local Windows Autopilot Reset](https://learn.microsoft.com/en-us/autopilot/tutorial/reset/local-autopilot-reset) | [Remote Windows Autopilot Reset](https://learn.microsoft.com/en-us/autopilot/tutorial/reset/remote-autopilot-reset) | [Device action: Wipe](https://learn.microsoft.com/en-us/intune/device-management/actions/wipe) | [Device action: Fresh Start](https://learn.microsoft.com/en-us/intune/device-management/actions/fresh-start)
