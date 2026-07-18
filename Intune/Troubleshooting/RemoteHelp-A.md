# Intune Remote Help — Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Microsoft Intune Remote Help — the native, Entra-authenticated remote-assistance app for Windows, macOS, and Android, including its web-app fallback
- Tenant enablement, RBAC, licensing, deployment (Win32/Enterprise App Catalog), Conditional Access integration, and session monitoring
- Windows-focused triage depth (macOS/Android are covered at the planning/RBAC level; device-local diagnostics assume Windows unless noted)

**Out of scope:**
- Windows 365 / Azure Virtual Desktop's own RDP connection stack — a related but architecturally separate technology. Remote Help can operate *inside* a Cloud PC/AVD session (as the sharer's in-session app) but is not how you connect *to* the Cloud PC itself. See `Azure/Windows365/Windows365-A.md`.
- `remoteAssistancePartner` in Microsoft Graph — a **different** feature: onboarding metadata for third-party remote-assistance ISVs (e.g., TeamViewer-style partners) surfaced in the device action bar. Not Microsoft's own Remote Help app; do not conflate the two when reading Graph documentation.
- General Intune enrollment/compliance troubleshooting — see `Troubleshooting/Enrollment-A.md` and `Troubleshooting/Policy-Conflict-A.md`. Remote Help consumes compliance state (as a non-blocking warning) but does not diagnose it.
- Endpoint analytics / device experience scoring — a related telemetry surface, not part of Remote Help itself. See `Troubleshooting/EndpointAnalytics-A.md`.

**Assumed baseline:**
- Tenant has Microsoft Intune Plan 1 or Plan 2, plus a Remote Help add-on license (or an Intune Suite license that bundles it) assigned to both helpers and sharers
- Devices are Microsoft Entra registered or joined; Windows devices meet the OS-build/KB baseline needed for reliable notification delivery
- Admin has `DeviceManagementConfiguration.Read.All` / `.ReadWrite.All` and `DeviceManagementRBAC.Read.All` Graph scopes for the checks in this document
- Tenant is not GCC High or DoD (Remote Help is unsupported there in full)

---

## How It Works

<details><summary>Full architecture</summary>

### Helper / Sharer Model

Remote Help has exactly two roles per session:

- **Helper** — support staff providing assistance
- **Sharer** — the end user receiving assistance, sharing their session

Both sign in with a Microsoft Entra account **from the same tenant** for every session — there is no persistent pairing or saved trust relationship, and no cross-tenant bridging exists. This authentication step is what lets Remote Help show each party verified identity information about the other (name, job title, company, profile picture, verified domain) before any screen sharing begins, and it's the mechanism Intune RBAC and Conditional Access hook into.

### Transport

Once a session is authorized, Remote Help connects both parties to Microsoft's cloud-hosted **Remote Assistance Service** at `remotehelp.microsoft.com` over port 443, using the Remote Desktop Protocol (RDP) tunneled inside a TLS 1.2 connection. Nothing about the transport is peer-to-peer or on-prem-relayed — both helper and sharer independently reach the cloud service, which is why SSL-inspecting corporate proxies are a common, non-obvious point of failure: inspection breaks the RDP-over-TLS handshake even though the destination FQDN itself might otherwise be allowed.

Microsoft explicitly states it cannot see session content (screen images, keystrokes) — only session **metadata** (who helped whom, on what device, start/end time, feature usage such as view-only vs. elevation) is logged, retained 30 days, then discarded.

### Three Ways a Session Gets Started

1. **Admin-center "remote launch"** — a helper, from **Devices > All devices > [device] > New remote assistance session**, triggers a push notification to the sharer's device. This path has its own dependency chain: it requires the **Intune Management Extension (IME)** service to be running on the sharer's Windows device (IME is the same background service used for Win32 apps/Platform Scripts/Remediations), and newly enrolled devices have a documented ~1-hour delay before they begin receiving these notifications at all.
2. **Manual session-code exchange** — the sharer opens the Remote Help app directly (no notification needed) and reads a generated code to the helper (or vice versa, depending on direction), who enters it to connect. This path has no IME dependency and works even on a device that was enrolled seconds ago.
3. **Security-code method for Azure Virtual Desktop sessions** — because AVD desktop sessions broadcast admin-center-launched notifications to *all* active users on a host (and RemoteApp sessions can't be targeted from the admin center at all), the documented supported method inside AVD is for the helper to generate a code from their own Remote Help app and have the sharer enter it inside their AVD session.

### Client Surfaces and the Mode-Support Matrix

Remote Help ships a **native app** (Windows/macOS/Android) and a **web app** (reduced-capability fallback for when native install isn't possible). Critically, *helper* and *sharer* roles are not symmetric across platforms — a helper can only run the native app from **Windows**, or the web app from Windows/macOS; there is no macOS-native helper role. A sharer, by contrast, can share from Windows native, macOS native, Android native, or either platform's web app.

Session **modes** also vary by this same helper/sharer pairing:

| | Helper: Windows native | Helper: Windows web | Helper: macOS web |
|---|---|---|---|
| Sharer: Windows native | View only, Full control, Elevation | Unsupported | Unsupported |
| Sharer: macOS native | Unsupported | View only, Full control | View only, Full control |
| Sharer: Android native | Unsupported | View only, Full control, **Unattended** | View only, Full control, **Unattended** |
| Sharer: macOS webapp | Unsupported | View only | View only |
| Sharer: Windows webapp | Unsupported | View only | View only |

**This table is the single most important architectural fact for setting correct expectations**: as documented at the time of this run, Unattended access — full control with no end-user presence required — is available only where the *sharer* is an Android device enrolled as an Intune dedicated device. It is not listed for Windows- or macOS-native sharing. Community and vendor commentary about a broader Windows unattended rollout has circulated, and the Remote Help RBAC permission itself is named generically ("Remote Help — Unattended"), but its own documented description still scopes it to Android dedicated devices — treat any claim of Windows/macOS unattended support as unconfirmed until re-verified directly against the current Microsoft Learn planning page at the time of the engagement, not assumed from this document or from marketing material.

### RBAC Model

Remote Help permissions live in Intune's own role-based access control (the same RBAC surface used for every other Intune role), not in Entra ID directory roles. A helper needs a **combination** of permissions, not just one:

| Permission | What it grants |
|---|---|
| Remote Tasks — Offer remote assistance | The base ability to offer help at all |
| Remote Assistance Connector — Read | Lets the client detect whether Remote Help is even configured for the tenant when starting a session |
| Remote Help — View screen | View the sharer's screen without control |
| Remote Help — Take full control | Full control of the sharer's device |
| Remote Help — Elevation | Enter UAC credentials on the sharer's device during elevation prompts |
| Remote Help — Unattended | Connect to Android dedicated devices without per-session sharer acceptance |

A helper needs *Offer remote assistance* + *Remote Assistance Connector Read* + **at least one** of the four Remote Help action permissions to do anything at all. The built-in **Help Desk Operator** role includes the full set; the built-in **School Administrator** role includes everything except Unattended. Custom roles are common in MSP environments for tiered support (view-only for L1, full control for L2/L3) and are the most frequent source of "helper sees nothing" tickets when one piece of the three-part combination is missed.

Scope groups matter here too: assigning a role against the `All Devices` built-in scope group does **not** cover unenrolled devices — Remote Help sessions to unenrolled (Entra-registered-only) devices require a dedicated **user** scope group instead, since unenrolled devices have no device-object presence to match against a device-scoped group.

### Deployment Model

Remote Help is not a policy or profile — it's an installable app (`RemoteHelp.exe` on Windows) that must be present on every device expected to act as either helper or sharer. Two supported delivery paths on Windows:

- **Enterprise App Catalog** (bundled with Intune Suite) — Microsoft-maintained prepackaged Win32 app, least manual effort, auto-updates.
- **Manual Win32 app** — repackage `remotehelpinstaller.exe` as a `.intunewin` file; install command `remotehelpinstaller.exe /quiet acceptTerms=1`; uninstall command `remotehelpinstaller.exe /uninstall /quiet acceptTerms=1`; detection rule keyed on file version at `C:\Program Files\Remote Help\RemoteHelp.exe`.

Either path installs **Microsoft Edge WebView2 Runtime** as a dependency if not already present (WebView2 ships by default with Windows 11 and current Edge installs) — WebView2 is *not* removed on Remote Help uninstall, since other apps commonly depend on it too. The most common Windows-side install failure mode traces back to a broken or missing WebView2 Runtime, surfaced as error codes 1001–1003 in the app's own dialog.

### Conditional Access Integration

Remote Help exposes itself to Entra Conditional Access as a service principal — **RemoteAssistanceService**, app ID `1dee7b72-b80d-4e56-933d-8b6b04f9a3e2` — which must be explicitly created via Microsoft Graph PowerShell (`New-MgServicePrincipal -AppId "1dee7b72-b80d-4e56-933d-8b6b04f9a3e2"`) before it can be targeted in a CA policy. This is a one-time provisioning step per tenant, not something that exists by default. CA support for Remote Help is documented as Windows- and macOS-only; Android sessions are not covered by CA policies targeting this service principal.

</details>

---

## Dependency Stack

```
Licensing floor
    │   Intune Plan 1 or Plan 2 (base), PLUS a Remote Help add-on or
    │   Intune Suite license assigned to BOTH the helper and the sharer —
    │   not helper-only, despite common assumption
    │
Tenant enablement
    │   deviceManagement/remoteAssistanceSettings.remoteAssistanceState
    │   = enabled (default: disabled) — a single tenant-wide switch that
    │   gates every session regardless of anything below it
    │
Intune RBAC (helper side)
    │   Offer remote assistance + Remote Assistance Connector Read +
    │   at least one of (View screen / Full control / Elevation / Unattended)
    │   scoped against a group that actually contains the sharer/device
    │   ("All Devices" excludes unenrolled devices)
    │
Authentication
    │   Helper AND sharer sign in with Entra accounts from the SAME
    │   tenant, per session — no persistent trust, no cross-tenant bridge
    │
Client presence (per platform)
    │   Windows/macOS/Android native app, OR reduced-capability web app
    │   Windows native additionally requires Edge WebView2 Runtime
    │
Network reachability
    │   Port 443 outbound to remotehelp.microsoft.com from BOTH parties;
    │   RDP-over-TLS-1.2 tunnel — SSL-inspecting proxies must exclude it
    │
Session trigger path (choose one)
    ├── Admin-center remote launch → requires IME running on sharer device,
    │     device enrolled > 1 hour, notifications not suppressed (DND)
    ├── Manual session code (sharer or helper generates, other enters)
    └── AVD/RemoteApp session → security-code method only; admin-center
          launch broadcasts to all active users on the host and cannot
          target a specific RemoteApp session at all
    │
Session established
    │
    ├── Compliance warning shown to helper if sharer device is
    │     noncompliant — NON-BLOCKING, informational only
    │
    ├── Elevation available only if the sharer's device does NOT have
    │     EnableSecureCredentialPrompting CSP enabled (it silently blocks
    │     the UAC prompt path used by elevation)
    │
    └── Optional Conditional Access enforcement (Windows/macOS only) via
          the RemoteAssistanceService service principal, once provisioned
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Helper never sees a Remote Help option at all for a device | Tenant-wide `remoteAssistanceState` is disabled | `Invoke-MgGraphRequest GET .../remoteAssistanceSettings` |
| Helper's role looks assigned but session still won't start | Missing one of the three required permission pieces (Offer remote assistance / Connector Read / an action permission) | Inspect the assigned role's `RolePermissions.ResourceActions` |
| Everything on the helper side checks out, session still fails | Sharer (or helper) has no Remote Help/Intune Suite license — both are required | `Get-MgUserLicenseDetail` for both parties |
| Sharer never receives a notification when helper clicks "Launch" in the admin center | IME not running, device in Do Not Disturb, or device enrolled < 1 hour ago | `Get-Service IntuneManagementExtension`; ask sharer to check notification center |
| Manual code entry works fine, but remote-launch doesn't | Confirms the issue is IME/notification-specific, not licensing/RBAC/network | Same as above — isolate to the trigger path, not the session itself |
| Remote Help app fails to open / shows error 1001–1003 | Microsoft Edge WebView2 Runtime missing or broken | Check Edge install/update state; reinstall WebView2 if needed |
| Session connects but helper can't get an elevation prompt through | `EnableSecureCredentialPrompting` CSP enabled on the sharer's device | Query the policy's applied state via `mdmdiagnosticstool` output or the CSP's reporting node |
| Sharer/device is in scope for the role but session reports out-of-scope | `All Devices` scope group used, but the sharer is an unenrolled device — that scope excludes unenrolled devices | Confirm scope group type; switch to a user scope group for unenrolled support |
| Outsourced/MSP helper can't connect to a customer's device at all | Cross-tenant scenario — Remote Help cannot bridge tenants under any setting | Confirm both parties' tenant via the sign-in screen's organization name |
| Helper trying to reach a specific published RemoteApp in AVD gets a broadcast to the wrong session or nothing at all | Admin-center launch broadcasts to all active users on an AVD desktop host and cannot target RemoteApp sessions directly | Use the security-code method instead |
| CA policy meant to require MFA for helpers doesn't seem to apply | `RemoteAssistanceService` service principal was never provisioned via Graph, or CA policy doesn't correctly exclude/target it | `Get-MgServicePrincipal -Filter "appId eq '1dee7b72-b80d-4e56-933d-8b6b04f9a3e2'"` |
| CA policy for Remote Help doesn't apply to an Android session | CA support for Remote Help is documented Windows/macOS only | Confirm platform before treating as a CA misconfiguration |
| Session works but the compliance warning appears every time and is being treated as a blocker | The compliance warning is informational-only by design — it never blocks the session | Clarify expectation with the requester; not a bug |
| SSL-inspecting proxy environment reports random Remote Help connection drops | Proxy is inspecting the RDP-over-TLS-1.2 tunnel to `remotehelp.microsoft.com`, breaking it | Exclude Remote Help's documented endpoints from SSL inspection |

---

## Validation Steps

**1. Confirm tenant enablement**
```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings"
```
Good: `remoteAssistanceState: "enabled"`. Bad: `"disabled"` (the tenant default) — nothing downstream matters until this is flipped, and a fresh change can take up to 8 hours to fully propagate.

**2. Confirm the helper's role carries the full permission combination**
```powershell
Get-MgDeviceManagementRoleAssignment -All | Select DisplayName, RoleDefinitionId, ScopeMembers
(Get-MgDeviceManagementRoleDefinition -RoleDefinitionId "<id>").RolePermissions.ResourceActions.AllowedResourceActions
```
Good: the action list contains an "Offer remote assistance" action, a "Remote Assistance Connector" read action, and at least one Remote Help action (View/Full control/Elevation/Unattended). Bad: any one piece missing — the session silently won't offer, with no single clear error pointing at RBAC.

**3. Confirm licensing on both sides**
```powershell
Get-MgUserLicenseDetail -UserId "<helperUPN>" | Select SkuPartNumber
Get-MgUserLicenseDetail -UserId "<sharerUPN>" | Select SkuPartNumber
```
Good: both show a Remote Help add-on or Intune Suite SKU. Bad: either one missing — this is a licensing gap, not a technical fault, and is the single most-reported point of confusion in community forums for this feature.

**4. Confirm the client and its dependency on the sharer's Windows device**
```powershell
Get-Item "C:\Program Files\Remote Help\RemoteHelp.exe" | Select VersionInfo
Get-Service IntuneManagementExtension | Select Status
```
Good: file present, IME `Running` (only required for admin-center remote-launch). Bad: file missing (deployment gap) or IME stopped (remote-launch notifications will fail even though manual code sessions still work).

**5. Confirm network path**
Good: sharer and helper can both reach `remotehelp.microsoft.com` on port 443 without SSL inspection breaking the tunnel. Bad: connection drops mid-session or fails to establish specifically inside a corporate network with an SSL-inspecting proxy — check proxy exclusions before assuming a Remote Help-side fault.

**6. End-to-end validation**
Run an actual test session between a known-good helper account and a pilot sharer device using both the manual-code path and, if relevant to the ticket, the admin-center remote-launch path — passing steps 1–5 individually does not guarantee the full handshake succeeds, since proxy/notification issues only surface at connect time.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Classify the failure point
1. Determine whether the complaint is "no option to start a session at all" (tenant/RBAC/licensing), "notification never arrives" (IME/DND/enrollment-age, remote-launch path only), "app won't open" (WebView2/client), or "session connects but a specific capability is missing" (elevation/unattended/CA).
2. Confirm whether the sharer is enrolled, unenrolled-but-registered, or on an unsupported platform/edition (GCC High, DoD) before doing anything else — several of the above symptom classes have hard, unfixable platform gates.

### Phase 2 — Rule out tenant-wide blockers
1. Confirm `remoteAssistanceState` is enabled.
2. Confirm licensing for both helper and sharer.
3. Confirm the helper's assigned role includes the complete required permission combination.

### Phase 3 — Isolate the trigger path (if the complaint is "no notification")
1. If manual session-code entry works but admin-center remote launch doesn't, the problem is isolated entirely to IME/notification delivery — do not re-check licensing or RBAC, which are already proven to work.
2. Check IME service state, Do Not Disturb/Focus Assist state, and enrollment age (< 1 hour is a known, expected delay).

### Phase 4 — Isolate client vs. network vs. capability
1. If the app won't open at all, check for WebView2 error codes before assuming a licensing/RBAC issue.
2. If the app opens and authenticates but the session drops or never completes the handshake, suspect SSL-inspecting proxy interference with the RDP-over-TLS-1.2 tunnel.
3. If the session connects but a specific capability (elevation, unattended, CA enforcement) doesn't behave as expected, treat that capability's own prerequisite chain independently — a working baseline session does not imply elevation or CA are correctly configured.

### Phase 5 — AVD/RemoteApp-specific triage
1. Confirm whether the target is a full AVD desktop session or a RemoteApp session — only the desktop case can receive an admin-center-launched notification (broadcast to all active users on the host); RemoteApp sessions require the security-code method exclusively.
2. Note that the restart option available in normal Remote Help sessions is not available when assisting AVD sessions.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield tenant onboarding</summary>

1. Confirm licensing: Intune Plan 1/2 baseline plus Remote Help add-on or Intune Suite, sized to cover both anticipated helpers and sharers (not helpers alone).
2. Enable the tenant setting:
   ```powershell
   $payload = @{
       "@odata.type"                      = "#microsoft.graph.remoteAssistanceSettings"
       "remoteAssistanceState"            = "enabled"
       "allowSessionsToUnenrolledDevices" = $false
       "blockChat"                        = $false
   } | ConvertTo-Json
   Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings" -Body $payload -ContentType "application/json"
   ```
3. Assign the built-in **Help Desk Operator** role to L1/L2 support staff as a fast, known-good starting point; build tiered custom roles later once the operating model is proven (view-only for L1, full control/elevation for L2+).
4. Deploy the client — Enterprise App Catalog if Intune Suite is licensed (least effort, auto-updating); otherwise package `remotehelpinstaller.exe` as a Win32 app with the documented install/detection settings.
5. Pilot with a small group before tenant-wide rollout — validate both the manual-code and admin-center remote-launch paths, and confirm SSL-inspecting proxies (if any) exclude the Remote Help endpoints.
6. Communicate to end users what a legitimate Remote Help request looks like (identity verification screen, explicit consent prompt) as a phishing-awareness measure, per Microsoft's own deployment guidance.

**Rollback:** disable the tenant setting (`remoteAssistanceState: "disabled"`) to immediately stop all new sessions tenant-wide with no other side effects; uninstall the client app via the same Win32/Catalog mechanism used to deploy it.

</details>

<details><summary>Playbook 2 — Enable Conditional Access for Remote Help</summary>

1. Provision the service principal (one-time per tenant):
   ```powershell
   Install-Module Microsoft.Graph -Scope CurrentUser
   Connect-MgGraph -Scopes "Application.ReadWrite.All"
   New-MgServicePrincipal -AppId "1dee7b72-b80d-4e56-933d-8b6b04f9a3e2"
   ```
2. In Entra Conditional Access, create a policy targeting the **RemoteAssistanceService** resource (search by the same app ID), scoped to your helper population.
3. Apply grant controls appropriate to elevated-access tooling — MFA and/or compliant-device requirements are Microsoft's own stated recommendation given helpers have elevated access into user devices.
4. Confirm scope: this policy enforces on Windows and macOS sessions only — do not expect it to apply to Android sessions.

**Rollback:** disable or delete the Conditional Access policy; the service principal itself can remain provisioned with no effect if no policy targets it.

</details>

<details><summary>Playbook 3 — Diagnose and fix a fleet-wide "remote-launch notifications not arriving" pattern</summary>

1. Confirm this is isolated to the remote-launch trigger path specifically (manual code sessions still succeed) — if manual sessions also fail, work the broader tenant/RBAC/licensing chain instead, this playbook doesn't apply.
2. Check whether the affected devices share a common recent event — bulk re-enrollment (triggers the 1-hour notification delay fleet-wide), a Do Not Disturb/focus-assist configuration profile pushed recently, or an IME outage.
3. Fleet-wide IME health can be cross-checked against `Scripts/Get-PlatformScriptRunStatus.ps1` in this same folder, since IME is a shared dependency across Platform Scripts, Win32 apps, Remediations, and Remote Help remote-launch.
4. If isolated to specific devices rather than fleet-wide, check each device's local `IntuneManagementExtension` service state and recent restart history individually.

**Rollback:** N/A — this is a diagnostic playbook; fixes applied (service restarts, waiting out the enrollment-age delay, adjusting a DND-related configuration profile) are non-destructive.

</details>

<details><summary>Playbook 4 — Decommission Remote Help (offboarding or replacing with another tool)</summary>

1. Confirm this is intentional — disabling Remote Help does not affect historical session logs already retained (30-day rolling window from Microsoft's side) but does immediately stop all new sessions tenant-wide.
2. Disable the tenant setting via the same PATCH call shown in Playbook 1's rollback.
3. Remove Remote Help RBAC permissions from custom roles, or remove Help Desk Operator role assignments if Remote Help was the only reason those assignments existed — check for other Help Desk Operator-dependent workflows first, since that role bundles more than Remote Help alone.
4. Uninstall the client app fleet-wide via the same Win32/Enterprise Catalog app used to deploy it (`remotehelpinstaller.exe /uninstall /quiet acceptTerms=1` for manual Win32 deployments).
5. Remove any Conditional Access policy targeting the `RemoteAssistanceService` resource; the service principal itself can be left in place or removed with no ongoing cost.

**Rollback:** re-enable the tenant setting and redeploy the client app — no data is lost by disabling, since Remote Help retains no persistent session content.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Microsoft Intune Remote Help diagnostic evidence for escalation or handoff.
    See also: Scripts/Get-RemoteHelpReadinessAudit.ps1 for the full standalone version.
#>
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementRBAC.Read.All"

$outDir = "$env:TEMP\RemoteHelp-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

try {
    Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings" |
        Select-Object remoteAssistanceState, allowSessionsToUnenrolledDevices, blockChat |
        Export-Csv "$outDir\TenantSettings.csv" -NoTypeInformation
} catch {
    "remoteAssistanceSettings query failed: $($_.Exception.Message)" | Out-File "$outDir\TenantSettings-ERROR.txt"
}

Get-MgDeviceManagementRoleDefinition -All |
    Where-Object { ($_.RolePermissions.ResourceActions.AllowedResourceActions -join ';') -match 'RemoteAssistance' } |
    Select-Object DisplayName, IsBuiltIn, Id |
    Export-Csv "$outDir\RolesWithRemoteHelp.csv" -NoTypeInformation

# Local, device-side evidence (run this block ON the affected sharer's device)
if (Test-Path "C:\Program Files\Remote Help\RemoteHelp.exe") {
    (Get-Item "C:\Program Files\Remote Help\RemoteHelp.exe").VersionInfo |
        Select-Object FileVersion, ProductVersion |
        Export-Csv "$outDir\LocalClientVersion.csv" -NoTypeInformation
}
Get-Service IntuneManagementExtension -ErrorAction SilentlyContinue |
    Select-Object Status, StartType |
    Export-Csv "$outDir\IMEState.csv" -NoTypeInformation
Get-WinEvent -LogName "Microsoft-Windows-RemoteHelp/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$outDir\RemoteHelpEventLog.csv" -NoTypeInformation

Write-Host "Evidence collected in $outDir" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Invoke-MgGraphRequest -Method GET -Uri ".../deviceManagement/remoteAssistanceSettings"` | Check tenant-wide enable state, unenrolled-device support, chat block |
| `Invoke-MgGraphRequest -Method PATCH -Uri ".../deviceManagement/remoteAssistanceSettings"` | Change tenant-wide enable state (beta resource — no typed cmdlet) |
| `Get-MgDeviceManagementRoleDefinition -All` | List Intune roles; filter for `RemoteAssistance` in resource actions |
| `Get-MgDeviceManagementRoleAssignment -All` | List role assignments and their scope groups |
| `Get-MgUserLicenseDetail -UserId <upn>` | Best-effort check for Remote Help/Intune Suite SKU on a user |
| `Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Remote Help')"` | Confirm the client app is present in Intune and check assignment |
| `New-MgServicePrincipal -AppId "1dee7b72-b80d-4e56-933d-8b6b04f9a3e2"` | One-time provisioning of the RemoteAssistanceService principal for CA |
| `Get-MgServicePrincipal -Filter "appId eq '1dee7b72-b80d-4e56-933d-8b6b04f9a3e2'"` | Confirm the CA service principal already exists |
| `Get-Service IntuneManagementExtension` | Local: confirm IME health (remote-launch notification dependency) |
| `Get-Item "C:\Program Files\Remote Help\RemoteHelp.exe"` | Local: confirm client install + version |
| `Get-WinEvent -LogName "Microsoft-Windows-RemoteHelp/Operational"` | Local: session/install error history |
| `(Get-Item "$env:ProgramFiles\Remote Help\RemoteHelp.exe").VersionInfo` | Local: exact installed version for a Win32 detection-rule value |
| `remotehelpinstaller.exe /quiet acceptTerms=1` | Silent install (Win32 app deployment) |
| `remotehelpinstaller.exe /uninstall /quiet acceptTerms=1` | Silent uninstall |

> Session history and audit details (who helped whom, on what device, duration) are **portal-only** — Intune admin center > Tenant administration > Remote Help > Monitor / Remote Help sessions tabs, and Tenant Administration > Audit Logs. There is no confirmed Graph endpoint returning individual session records at the time of this run.

---

## 🎓 Learning Pointers

- **Both the helper and the sharer must be licensed — this is stated explicitly in Microsoft's own prerequisites**, and remains one of the most consistently misunderstood points in community discussion of this feature (a multi-year-running complaint thread on Microsoft's own Tech Community still surfaces this as a value/cost objection). Budget licensing for your entire sharer population, not just your helpdesk. See: [Plan for Remote Help — Prerequisites](https://learn.microsoft.com/en-us/intune/remote-help/plan#prerequisites)

- **Unattended access is currently documented as Android-dedicated-device-only** — don't take "unattended" at face value as a Windows capability. The helper/sharer mode-support table is the authoritative source, and it should be re-checked at time of engagement since this is an actively evolving area of the product. See: [Helper and client modes](https://learn.microsoft.com/en-us/intune/remote-help/plan#helper-and-client-modes)

- **A working session proves the baseline chain, not every capability layered on top.** Elevation (blocked by `EnableSecureCredentialPrompting`), Conditional Access (requires a one-time service-principal provisioning step most tenants never do), and unattended access all have their own independent prerequisite chains that a plain successful connection does not validate. See: [Using Remote Help — elevation notes](https://learn.microsoft.com/en-us/intune/remote-help/start-session) and [Deploy Remote Help — Conditional Access setup](https://learn.microsoft.com/en-us/intune/remote-help/deploy#set-up-conditional-access-for-remote-help)

- **`All Devices` as an RBAC scope silently excludes unenrolled devices** — a subtlety Microsoft calls out explicitly in its own planning documentation precisely because it's easy to miss and produces a confusing "in scope but somehow not" failure mode. See: [Plan for Remote Help — RBAC note](https://learn.microsoft.com/en-us/intune/remote-help/plan#role-based-access-control-rbac)

- **The transport is genuinely cloud-relayed RDP-over-TLS, not peer-to-peer** — this is why SSL-inspecting proxies are a real, recurring failure mode rather than a theoretical one, and why the fix is a proxy exclusion, not a Remote Help-side setting. See: [Network endpoints for Remote Help](https://learn.microsoft.com/en-us/intune/fundamentals/endpoints#remote-help)

- Cross-reference: Remote Help is a distinct product from `remoteAssistancePartner` (third-party ISV onboarding into the device action bar) and from Windows 365/AVD's own connection stack (`Azure/Windows365/Windows365-A.md`) — Remote Help can run *inside* a Cloud PC session but is not how you connect to one.
