# Intune Remote Help — Hotfix Runbook (Mode B: Ops)
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

Remote Help is Microsoft's Entra-authenticated remote-assistance app for Intune-managed (and optionally unenrolled/Entra-registered) devices. A **helper** (support staff) connects to a **sharer** (end user) — both must sign in with an Entra account from the *same* tenant. This is a distinct product from Windows 365/AVD's own connection stack and from third-party RMM tools onboarded as a `remoteAssistancePartner` — don't conflate ticket types.

```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementRBAC.Read.All"

# 1. Is Remote Help even enabled tenant-wide? (default: disabled)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings" |
  Select remoteAssistanceState, allowSessionsToUnenrolledDevices, blockChat

# 2. Does the helper's role assignment actually carry Remote Help permissions?
#    (Built-in "Help Desk Operator" has the full set; custom roles frequently miss one piece)
Get-MgDeviceManagementRoleDefinition -All |
  Where-Object { ($_.RolePermissions.ResourceActions.AllowedResourceActions -join ';') -match 'RemoteAssistance' } |
  Select DisplayName, IsBuiltIn

# 3. On the SHARER device — is the app installed and is IME running (needed for admin-center-initiated
#    "remote launch" notifications; not needed if the sharer opens the app manually and reads a code aloud)?
Get-Item "C:\Program Files\Remote Help\RemoteHelp.exe" -ErrorAction SilentlyContinue |
  Select @{N='Installed';E={$true}}, VersionInfo
Get-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue | Select Status

# 4. Any recent Remote Help errors logged locally on the sharer device?
Get-WinEvent -LogName "Microsoft-Windows-RemoteHelp/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue |
  Select TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap

# 5. Confirm the sharer's device compliance state (drives the non-blocking compliance warning helpers see)
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<deviceName>'" |
  Select DeviceName, ComplianceState, IsEncrypted, AzureAdRegistered
```

| Finding | Interpretation | Do this |
|---|---|---|
| `remoteAssistanceState = disabled` | Nothing works tenant-wide regardless of licensing/RBAC — this is the #1 first-deployment blocker | Go to [Fix 1](#common-fix-paths) |
| No role definition matches `RemoteAssistance` for the helper's assigned role | Helper has no Remote Help permission at all — session request never even offers | Go to [Fix 2](#common-fix-paths) |
| Helper role has permissions but session still fails to start | Check the license side next — **both** helper and sharer need a Remote Help/Intune Suite license, not just the helper | Go to [Fix 3](#common-fix-paths) |
| RemoteHelp.exe missing on sharer device | App was never deployed, or deployment/detection rule is broken | Go to [Fix 4](#common-fix-paths) |
| RemoteHelp.exe present but IME service not running | Manual/code-based sessions still work; **remote-launch from the admin center will not** — the sharer never gets a notification | Go to [Fix 5](#common-fix-paths) |
| Event ID in the 1001–1003 range in the RemoteHelp/Operational log | WebView2 Runtime problem, not a Remote Help bug per se | Go to [Fix 6](#common-fix-paths) |
| `ComplianceState = noncompliant` | Session still works — helper just sees a non-blocking warning banner. Don't chase this as a blocker. | Note only; not a fix path |
| Device is enrolled to a *different* tenant than the helper, or helper is an outsourced tech on a partner tenant | Remote Help cannot bridge tenants — this is a hard product limitation | Go to [Fix 7](#common-fix-paths) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant setting: remoteAssistanceState = enabled
  (Tenant administration > Remote Help > Settings — default is DISABLED)
        │
        ▼
Remote Help / Intune Suite license assigned to BOTH the helper AND the sharer
  (official Microsoft requirement — a frequent point of confusion; several
   third-party writeups incorrectly claim only the helper needs a license)
        │
        ▼
Helper's Intune role assignment includes ALL THREE:
  - Remote Tasks — Offer remote assistance
  - Remote Assistance Connector — Read
  - At least one of: View screen | Take full control | Elevation | Unattended
  (built-in "Help Desk Operator" role has the full set out of the box)
        │
        ▼
Helper and sharer both sign in with Entra accounts from the SAME tenant
  (no cross-tenant bridging — outsourced/MSP helpdesk-in-another-tenant scenarios
   need the sharer's org to issue guest devices/accounts, not a Remote Help setting)
        │
        ▼
Sharer (user or device) falls within the helper's RBAC scope group
  ("All Devices" scope does NOT include unenrolled devices — use a user scope
   group if unenrolled-device support is enabled)
        │
        ▼
Client present on the sharer's device:
  - Native app (Windows/macOS/Android) — full capability including elevation
  - OR web app — view-only, reduced capability, used when native install isn't possible
  Windows native app also requires Microsoft Edge WebView2 Runtime
        │
        ▼
Network: port 443 outbound to remotehelp.microsoft.com reachable from BOTH
  helper and sharer (RDP-over-TLS 1.2 tunnel — SSL-inspecting proxies must
  exclude the Remote Help endpoints or the tunnel breaks)
        │
        ▼
FOR ADMIN-CENTER-INITIATED ("remote launch") SESSIONS SPECIFICALLY:
  - Intune Management Extension (IME) service running on the sharer's device
  - Device not in Do Not Disturb / notifications not blocked
  - Newly enrolled devices: 1-hour delay before notifications start working
        │
        ▼
Session establishes → compliance warning shown (non-blocking) if sharer device
  is noncompliant → Elevation available only if EnableSecureCredentialPrompting
  CSP is NOT set → Conditional Access (Windows/macOS only) enforced against the
  RemoteAssistanceService service principal if configured
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm tenant-wide enablement first — this gates everything else.**
   `Invoke-MgGraphRequest -Method GET -Uri ".../deviceManagement/remoteAssistanceSettings"`. Expected: `remoteAssistanceState = enabled`. New licenses/settings changes can take 30 minutes to 8 hours to take effect — don't treat a fresh change as broken within that window.

2. **Confirm the helper's role has the full three-permission combo, not just one piece.**
   A role with only "View screen" but missing "Remote Tasks — Offer remote assistance" or "Remote Assistance Connector — Read" looks configured but silently can't start sessions. Check against the built-in **Help Desk Operator** role as a known-good baseline.

3. **Confirm licensing on both sides — this is the single most common "why doesn't this work" ticket.**
   There is no clean Graph query for per-user Remote Help license state; cross-reference the user's assigned license SKUs (`Get-MgUserLicenseDetail`) against your tenant's Intune Suite / Remote Help add-on SKU. If the sharer has no license, the session fails even though the helper's side looks perfect.

4. **Confirm same-tenant sign-in.**
   Ask both parties to confirm the organization name shown at Remote Help sign-in. A helper signed into a *different* tenant (common in outsourced/MSP-across-tenants setups) cannot connect — this is a hard limitation, not a misconfiguration to chase.

5. **Confirm scope group inclusion for the sharer.**
   If unenrolled-device support is enabled, remember `All Devices` does not include unenrolled devices in this context — the sharer/device must be covered by a **user** scope group on the helper's role assignment.

6. **On the sharer's device, confirm the client and its dependency (Windows: WebView2).**
   `Get-Item "C:\Program Files\Remote Help\RemoteHelp.exe"`. Missing → deployment gap. Present but sessions fail to open the UI → check for WebView2 error codes 1001–1003 in the RemoteHelp/Operational event log.

7. **If using admin-center "remote launch" specifically (not manual code entry), confirm IME is running and the device isn't suppressing notifications.**
   `Get-Service IntuneManagementExtension`. Also check Do Not Disturb / focus-assist state and whether the device enrolled less than an hour ago.

8. **If elevation is expected but the option never appears, check `EnableSecureCredentialPrompting`.**
   This CSP, if enabled, silently blocks UAC elevation prompts during Remote Help sessions — it must be disabled for elevation to function.

9. **Validate with a real test session to a known-good pilot device before closing the ticket.**
   A successful tenant-setting/RBAC check does not guarantee an end-to-end session — confirm connectivity and the actual UI handshake work, since network/proxy issues (SSL inspection) only surface at connect time.

---
## Common Fix Paths

<details><summary>Fix 1 — Remote Help disabled tenant-wide</summary>

```powershell
$payload = @{
    "@odata.type"                      = "#microsoft.graph.remoteAssistanceSettings"
    "remoteAssistanceState"            = "enabled"
    "allowSessionsToUnenrolledDevices" = $false   # set $true only if you've deliberately planned for reduced audit/compliance visibility
    "blockChat"                        = $false
} | ConvertTo-Json

Invoke-MgGraphRequest -Method PATCH `
  -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings" `
  -Body $payload -ContentType "application/json"
```

No rollback risk in enabling — it's an opt-in tenant switch with no destructive side effect. Allow up to 8 hours before assuming it hasn't taken effect.

</details>

<details><summary>Fix 2 — Helper role missing a required permission</summary>

Easiest fix: assign the built-in **Help Desk Operator** role (has the full permission set) instead of debugging a custom role. If a custom role is required for scoping reasons, add the three permissions explicitly in the Intune admin center role editor (Remote Tasks category + Remote Help category), or via Graph:

```powershell
# Inspect exactly what a custom role currently grants
(Get-MgDeviceManagementRoleDefinition -RoleDefinitionId "<roleDefinitionId>").RolePermissions.ResourceActions.AllowedResourceActions
```

No rollback concern — adding permissions is additive and low-risk; confirm scope groups aren't overly broad if security is a concern.

</details>

<details><summary>Fix 3 — Sharer (or helper) missing a Remote Help license</summary>

```powershell
# Confirm what's actually assigned to the affected user
Get-MgUserLicenseDetail -UserId "<userPrincipalName>" | Select SkuPartNumber, ServicePlans
```

Fix: assign the Remote Help add-on SKU (or the Intune Suite SKU that bundles it) to the affected user in Entra ID / Microsoft 365 admin center. Note the propagation delay (30 min–8 hrs) before retesting. This is a licensing/procurement fix, not a technical misconfiguration — flag it clearly in the ticket so it isn't mistaken for a bug.

</details>

<details><summary>Fix 4 — Remote Help app not installed on sharer device</summary>

```powershell
# Confirm assignment coverage for the Remote Help Win32/Enterprise Catalog app
Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Remote Help')" |
  Select Id, DisplayName, PublishingState
```

Redeploy via the Enterprise App Catalog (fastest, Intune Suite–included) or as a manual Win32 app using `remotehelpinstaller.exe /quiet acceptTerms=1`. No rollback concern; reinstalling in place is safe and doesn't require removing the prior version first.

</details>

<details><summary>Fix 5 — Admin-center "remote launch" notification never arrives</summary>

Check, in order:
- Is `IntuneManagementExtension` running on the sharer's device? If stopped, restart it — `Restart-Service IntuneManagementExtension`.
- Was the device enrolled less than 1 hour ago? This is a documented delay before notification delivery starts working — wait, don't troubleshoot further within that window.
- Is the device in Do Not Disturb / Focus Assist? Notifications are suppressed silently — ask the sharer to check the notification center directly or temporarily disable focus assist.
- As an immediate workaround for any of the above: have the sharer open the Remote Help app manually and read the session code to the helper instead of waiting on the notification.

No rollback risk — service restart and manual code entry are both non-destructive.

</details>

<details><summary>Fix 6 — WebView2 error codes 1001/1002/1003</summary>

```powershell
# Confirm current WebView2 Runtime presence/version
Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -ErrorAction SilentlyContinue |
  Select pv
```

Fix: ensure Microsoft Edge is installed and current (WebView2 ships with it on Windows 11 and current Edge installs); if still failing, install the [Evergreen WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/consumer/) directly, then relaunch Remote Help. No rollback concern — WebView2 is not removed when Remote Help is uninstalled, so reinstalling it doesn't affect anything else on the device.

</details>

<details><summary>Fix 7 — Cross-tenant helpdesk scenario (outsourced/MSP support across tenants)</summary>

Remote Help fundamentally cannot bridge two tenants — this isn't a setting to enable. Documented workarounds:
- Issue the outsourced helper a device/account joined to **your** tenant (tenant A), rather than their home organization's tenant (tenant B).
- Or provide the helper access to a Windows 365 Cloud PC or AVD session joined to tenant A, and run Remote Help from inside that session.

Not a technical fix — this needs a scoping/procurement decision with the outsourcing arrangement, so flag it as such rather than continuing to debug RBAC or licensing.

</details>

---
## Escalation Evidence

```
REMOTE HELP ESCALATION
Tenant: <tenantName>
Helper UPN: <helperUPN>              Helper role assigned: <roleName>
Sharer UPN: <sharerUPN>               Sharer device name: <deviceName>

Tenant remoteAssistanceState: <enabled/disabled>
allowSessionsToUnenrolledDevices: <true/false>     blockChat: <true/false>

Helper role has all 3 required permissions (Offer remote assistance /
  Remote Assistance Connector-Read / at least one Remote Help action)? <yes/no>
Helper license confirmed: <yes/no>      Sharer license confirmed: <yes/no>

Sharer device: RemoteHelp.exe present? <yes/no>   Version: <version>
IME service status (if remote-launch used): <running/stopped/n-a>
WebView2 present/current: <yes/no>

Recent RemoteHelp/Operational event log entries (last 20, verbatim):
<paste>

Device ComplianceState: <compliant/noncompliant>     Same tenant confirmed: <yes/no>
Network: port 443 to remotehelp.microsoft.com reachable? <yes/no>   SSL-inspecting proxy in path? <yes/no>

Steps already attempted: <bullet list>
```

---
## 🎓 Learning Pointers
- **Both the helper and the sharer need a Remote Help license — not just the helper.** This is stated explicitly in Microsoft's own prerequisites and is one of the most common sources of community confusion (several third-party blogs get this wrong). See [Plan for Remote Help](https://learn.microsoft.com/en-us/intune/remote-help/plan#prerequisites).
- **A role needs three separate permissions working together**, not just one Remote Help action — "Remote Tasks: Offer remote assistance" and "Remote Assistance Connector: Read" are easy to miss when building a custom role from scratch. See [RBAC for Remote Help](https://learn.microsoft.com/en-us/intune/remote-help/plan#role-based-access-control-rbac).
- **Unattended sessions currently only work sharer-side on Android dedicated devices** — despite "unattended" sounding platform-generic, the documented helper/sharer support matrix does not list it for Windows or macOS native sharing as of this run. Verify current platform support before promising it to a customer. See [Helper and client modes](https://learn.microsoft.com/en-us/intune/remote-help/plan#helper-and-client-modes).
- **`All Devices` as an RBAC scope group silently excludes unenrolled devices** — if you've enabled unenrolled-device support, you must use a dedicated user scope group or those sessions will report the sharer as "out of scope" with no clearer error. See [Plan for Remote Help — Prerequisites note](https://learn.microsoft.com/en-us/intune/remote-help/plan#prerequisites).
- **Remote Help cannot bridge tenants, full stop** — this trips up outsourced/MSP helpdesk models specifically; the fix is organizational (issue tenant-A devices/accounts to the outsourced team), not a configuration change. See [Planning considerations](https://learn.microsoft.com/en-us/intune/remote-help/plan#planning-considerations).
- Cross-reference: `remoteAssistancePartner` in Graph is a **different** feature — third-party remote-assistance ISV onboarding into the device action bar — not Microsoft's own Remote Help app. Don't chase this endpoint when troubleshooting native Remote Help sessions.
