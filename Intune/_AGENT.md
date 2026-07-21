# Intune — Agent Instructions

## What's in this folder

Microsoft Intune / Endpoint Manager — device management, compliance, configuration, app deployment, and update management.

Covers:
- **Enrollment** — Windows Autopilot, manual MDM enrollment, co-management, enrollment restrictions
- **Policy** — configuration profiles, compliance policies, settings catalog, GPO conflicts, assignment filters, scope tags/RBAC
- **Apps** — Win32 app deployment, managed apps (LOB/VPP), app protection (MAM), Enterprise App Management (Microsoft-curated Enterprise App Catalog — licensing, auto-update mechanics/limitations, content lifecycle, Autopilot ESP/Device Prep blocking-app integration)
- **Updates** — Update rings (WUfB), feature updates, driver updates (WDfB), Autopatch
- **Security & compliance controls** — LAPS (steady-state rotation/retrieval **and** legacy Microsoft LAPS → Windows LAPS migration/coexistence, including the silent legacy-emulation-mode behavior — see `Troubleshooting/LAPS-Migration-A.md` for the precedence rules that decide which of the two products is actually governing an account at any given moment), certificates (on-prem NDES/PKCS **and** cloud-native Cloud PKI), custom compliance scripts, security baselines, Endpoint Privilege Management (EPM)
- **Specialty device modes** — Kiosk / Assigned Access
- **Automation** — Platform scripts, Proactive Remediations
- **Reporting** — compliance dashboards, device inventory, assignment/coverage reports, Graph queries, Endpoint analytics (Startup performance / Application reliability / Work from anywhere scoring)
- **Remote Help** — Entra-authenticated helper/sharer remote assistance app, tenant enablement, RBAC, licensing (both helper AND sharer need one), deployment, Conditional Access integration — distinct from Windows 365/AVD's own connection stack and from the separate `remoteAssistancePartner` third-party ISV onboarding feature

---

## Before responding, also check

- `Autopilot/` — if enrollment failure happens during Autopilot flow specifically
- `EntraID/` — if device shows as non-compliant due to identity issues (Entra join state, PRT), or for co-management hybrid join state
- `Windows/` — if the underlying OS issue is causing compliance failure (GPO, VBS/Credential Guard, networking)
- `Security/ConditionalAccess/` — if compliance status is blocking access to resources
- `Security/Defender/` — for ASR/Tamper Protection/WDAC delivered via Intune but investigated as a Defender issue

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Troubleshooting/Enrollment-B.md` / `-A.md` | Hotfix / deep dive: device enrollment failures, MDM authority, enrollment restrictions |
| `Troubleshooting/Policy-Conflict-B.md` / `-A.md` | Hotfix / deep dive: policy not applying, compliance not resolving, CSP/GPO conflict model |
| `Troubleshooting/App-Deployment-B.md` / `-A.md` | Hotfix / deep dive: Win32 app stuck in pending/failed, IME/AgentExecutor pipeline |
| `Troubleshooting/EnterpriseAppManagement-B.md` / `-A.md` | Hotfix / deep dive: Enterprise App Catalog (EAM) — content-readiness stalls, auto-update rollback gap and its documented limitations, catalog removal lifecycle, dual catalog/Win32 deployment conflicts, ESP/Autopilot Device Prep blocking-app exclusion for auto-update apps — device-side pipeline is identical to App-Deployment, only catalog-specific lifecycle differs |
| `Troubleshooting/AppProtection-B.md` / `-A.md` | Hotfix / deep dive: MAM policy not applying, "Open in" blocked, data-at-rest PIN issues |
| `Troubleshooting/Autopatch-B.md` / `-A.md` | Hotfix / deep dive: Windows Autopatch ring assignment, readiness, deployment failures |
| `Troubleshooting/Certificates-B.md` / `-A.md` | Hotfix / deep dive: on-prem NDES/PKCS certificate profile delivery failures via Intune Certificate Connector |
| `Troubleshooting/CloudPKI-B.md` / `-A.md` | Hotfix / deep dive: Microsoft Cloud PKI (fully cloud-hosted PKI — no NDES/connector/on-prem CA) — CA status, BYOCA signing loop, trust chain delivery, 3-CA capacity cap |
| `Troubleshooting/CoManagement-B.md` / `-A.md` | Hotfix / deep dive: ConfigMgr/Intune co-management workload authority conflicts |
| `Troubleshooting/CustomCompliance-B.md` / `-A.md` | Hotfix / deep dive: custom compliance discovery script failures |
| `Troubleshooting/EndpointAnalytics-B.md` / `-A.md` | Hotfix / deep dive: Startup performance / Application reliability / Work from anywhere scoring not populating, data collection policy and network/SSL-inspection path |
| `Troubleshooting/DriverManagement-B.md` / `-A.md` | Hotfix / deep dive: Windows Driver Update for Business (WDfB) issues |
| `Troubleshooting/EPM-B.md` / `-A.md` | Hotfix / deep dive: Endpoint Privilege Management agent/elevation rule issues |
| `Troubleshooting/FeatureUpdates-B.md` / `-A.md` | Hotfix / deep dive: device stuck on old Windows version, feature update deployment |
| `Troubleshooting/Filters-B.md` / `-A.md` | Hotfix / deep dive: Assignment Filters not matching, stale device properties |
| `Troubleshooting/GP-to-CSP-B.md` / `-A.md` | Hotfix / deep dive: Group Policy Analytics migration to CSP, coverage gaps |
| `Troubleshooting/Kiosk-B.md` / `-A.md` | Hotfix / deep dive: Kiosk/Assigned Access configuration and lockdown issues |
| `Troubleshooting/LAPS-B.md` / `-A.md` | Hotfix / deep dive: Windows LAPS rotation/retrieval failures, legacy LAPS conflicts |
| `Troubleshooting/LAPS-Migration-B.md` / `-A.md` | Hotfix / deep dive: migrating FROM legacy Microsoft LAPS TO Windows LAPS — immediate vs. side-by-side coexistence paths, the silent legacy-emulation-mode precedence behavior, dual-account requirement, legacy software removal — distinct from `LAPS-A/B.md`'s steady-state operation scope |
| `Troubleshooting/Managed-Apps-B.md` / `-A.md` | Hotfix / deep dive: managed app (Win32/LOB/VPP) deployment health |
| `Troubleshooting/Platform-Scripts-B.md` / `-A.md` | Hotfix / deep dive: Platform Scripts not running, IME health |
| `Troubleshooting/Policy-Conflict-B.md` / `-A.md` | Hotfix / deep dive: policy conflicts across profile types |
| `Troubleshooting/Remediations-B.md` / `-A.md` | Hotfix / deep dive: Proactive Remediations not detecting/remediating |
| `Troubleshooting/RemoteHelp-B.md` / `-A.md` | Hotfix / deep dive: Remote Help session failures, tenant enablement, RBAC, licensing, remote-launch notification delivery, elevation/unattended/CA gaps |
| `Troubleshooting/ScopeTags-B.md` / `-A.md` | Hotfix / deep dive: Scope Tags / RBAC visibility issues |
| `Troubleshooting/Security-Baselines-B.md` / `-A.md` | Hotfix / deep dive: Endpoint Security Baseline Error/Conflict states |
| `Troubleshooting/WUfB-B.md` / `-A.md` | Hotfix / deep dive: Windows Update for Business ring assignment, GPO conflicts |
| `Scripts/Get-IntuneDeviceStatus.ps1` | Device compliance + enrollment state via Graph |
| `Scripts/Invoke-IntuneSync.ps1` | Force policy sync on device or bulk |
| `Scripts/Get-IntuneAssignmentReport.ps1` | Comprehensive assignment report — policies/apps/scripts with group targets + filters |
| `Scripts/Get-EnrollmentDiagnostics.ps1` | Device-local enrollment diagnostic — join state, MDM URL, scheduled task, endpoint reachability |
| `Scripts/Get-PolicyConflictScan.ps1` | Fleet-wide scan of every device+profile combination currently in Conflict/Error |
| `Scripts/Get-AppDeploymentDiagnostics.ps1` | Device-local Win32 app diagnostic — IME/AgentExecutor logs, Delivery Optimization state |
| `Scripts/Get-EnterpriseAppCatalogAudit.ps1` | Tenant-wide Enterprise App Catalog audit via Graph — content-readiness staleness, duplicate catalog/non-catalog deployments of the same app, stale/forgotten catalog apps, EAM/Intune Suite licensing confirmation |
| `Scripts/Get-ManagedAppDeploymentStatus.ps1` | Device-local + fleet-wide managed app (Win32/LOB/VPP) deployment health incl. Apple VPP token |
| `Scripts/Get-AppProtectionCoverageReport.ps1` | Fleet-wide App Protection Policy (MAM) coverage and health report |
| `Scripts/Get-AutopatchReadiness.ps1` | Fleet-level Autopatch readiness and ring-assignment audit |
| `Scripts/Get-CertificateProfileStatus.ps1` | Flags Failed/Conflict/stale-Pending SCEP/PKCS cert profiles (on-prem NDES/Connector model) |
| `Scripts/Get-CloudPKIHealth.ps1` | Tenant-wide Cloud PKI CA health/capacity audit via Graph — CA status, BYOCA signing staleness, 3-CA cap, key backing, issuance volume |
| `Scripts/Get-CoManagementStatus.ps1` | Device-local ConfigMgr client health, per-workload authority, hybrid join, MDM enrollment |
| `Scripts/Get-CustomComplianceScriptValidator.ps1` | Validates a Custom Compliance discovery script locally + cross-references fleet compliance state |
| `Scripts/Get-EndpointAnalyticsHealth.ps1` | Fleet-wide Endpoint analytics score/health sweep via Graph — flags below-threshold reporting population, unavailable (-1/-2) scores, and Work From Anywhere Cloud Provisioning gaps |
| `Scripts/Get-DriverManagementStatus.ps1` | WDfB policy state and local driver update conflicts |
| `Scripts/Get-EPMElevationReport.ps1` | EPM agent health and elevation rule delivery audit |
| `Scripts/Get-FeatureUpdateDeploymentStatus.ps1` | Local TargetReleaseVersion/safeguard-hold/GPO-conflict check + fleet-wide Feature Update Profile status |
| `Scripts/Get-GPtoCSPCoverageReport.ps1` | Fleet-wide Group Policy Analytics coverage report via Graph |
| `Scripts/Get-KioskDeviceHealthReport.ps1` | Device-local health snapshot for Kiosk/Assigned Access devices |
| `Scripts/Get-LAPSPasswordStatus.ps1` | Audit LAPS rotation/retrieval status + legacy LAPS conflict check |
| `Scripts/Get-LAPSMigrationStatus.ps1` | Classifies a device's legacy-vs-Windows-LAPS migration state (WindowsLapsActive / LegacyLapsActive / EmulationMode / EmulationSuppressed); optional `-ADSweep` for fleet-wide legacy/modern AD attribute progress reporting |
| `Scripts/Get-PlatformScriptRunStatus.ps1` | IME health locally and/or fleet-wide Platform Script run status via Graph |
| `Scripts/Get-RemediationRunHistory.ps1` | Fleet-wide Proactive Remediations run-state report via Graph |
| `Scripts/Get-RemoteHelpReadinessAudit.ps1` | Tenant-wide Remote Help readiness audit (enablement, RBAC combo completeness, scope-group gaps, app deployment) + optional local client/IME/WebView2/event-log diagnostics |
| `Scripts/Get-ScopeTagRBACAudit.ps1` | Tenant-wide Scope Tag / RBAC role assignment audit; optional per-admin effective-visibility check |
| `Scripts/Get-SecurityBaselineDrift.ps1` | Fleet-wide baseline Error/Conflict/Pending report across assigned baselines |
| `Scripts/Get-WUfBDeploymentStatus.ps1` | WUfB ring assignment, local policy state, and GPO conflicts |
| `Reporting/Get-NonCompliantDevices.ps1` | Export all non-compliant devices with reasons, grouped by policy/reason/user |
| `IntuneChecker.ps1` | ⚠️ Legacy/misfiled — root-level ad hoc sync+IME-repair one-liner, predates the `Scripts/`/`Troubleshooting/` convention; not linked from any runbook. Flagged for interactive user review (rename/relocate/retire), consistent with the similar misfiled Autopilot scripts — not touched autonomously per standing guidance. |

---

## Common entry points

- "Device not enrolling in Intune" → `Troubleshooting/Enrollment-B.md` + `Scripts/Get-EnrollmentDiagnostics.ps1`
- "Policy not applying to device" → `Troubleshooting/Policy-Conflict-B.md` + `Scripts/Get-PolicyConflictScan.ps1`
- "App stuck at 'Pending install'" → `Troubleshooting/App-Deployment-B.md` + `Scripts/Get-AppDeploymentDiagnostics.ps1`
- "Enterprise App Catalog app stuck 'content is still being prepared'" / "auto-update broke an app" / "app removed from the catalog" / "app fighting itself, two tiles for one product" / "can't add app as ESP or Autopilot Device Prep blocking app" → `Troubleshooting/EnterpriseAppManagement-B.md` + `Scripts/Get-EnterpriseAppCatalogAudit.ps1`
- "Device shows non-compliant, user can't access resources" → `Troubleshooting/Policy-Conflict-B.md` + `Security/ConditionalAccess/`
- "User can't see available apps" → check MDM scope + Company Portal; `Troubleshooting/Managed-Apps-B.md`
- "Settings applied by GPO are conflicting with Intune" → `Troubleshooting/Policy-Conflict-B.md` / `Troubleshooting/GP-to-CSP-B.md`
- "Bulk compliance report needed" → `Reporting/Get-NonCompliantDevices.ps1`
- "Need a full picture of what's assigned to a device/group" → `Scripts/Get-IntuneAssignmentReport.ps1`
- "LAPS password not showing / rotation not happening" → `Troubleshooting/LAPS-B.md` + `Scripts/Get-LAPSPasswordStatus.ps1`
- "Migrating off legacy LAPS to Windows LAPS" / "device seems to be managing a password but we never deployed LAPS there" / "can both LAPS products run at once" / "how do we retire the old LAPS agent safely" → `Troubleshooting/LAPS-Migration-B.md` + `Scripts/Get-LAPSMigrationStatus.ps1`
- "Cert profile stuck Pending/Failed for a device or fleet (on-prem NDES/PKCS)" → `Troubleshooting/Certificates-B.md` + `Scripts/Get-CertificateProfileStatus.ps1`
- "Cloud PKI CA stuck 'Signing required' / SCEP cert not issuing / hit the 3-CA limit" → `Troubleshooting/CloudPKI-B.md` + `Scripts/Get-CloudPKIHealth.ps1`
- "Security baseline shows Error/Conflict" → `Troubleshooting/Security-Baselines-B.md` + `Scripts/Get-SecurityBaselineDrift.ps1`
- "Device stuck on old Windows version / feature update not installing" → `Troubleshooting/FeatureUpdates-B.md` + `Scripts/Get-FeatureUpdateDeploymentStatus.ps1`
- "App Protection / MAM policy not applying, 'Open in' blocked" → `Troubleshooting/AppProtection-B.md` + `Scripts/Get-AppProtectionCoverageReport.ps1`
- "Autopatch device not in expected ring / deployment stalled" → `Troubleshooting/Autopatch-B.md` + `Scripts/Get-AutopatchReadiness.ps1`
- "Co-managed device workload going to wrong authority" → `Troubleshooting/CoManagement-B.md` + `Scripts/Get-CoManagementStatus.ps1`
- "Custom compliance script marking devices non-compliant incorrectly" → `Troubleshooting/CustomCompliance-B.md` + `Scripts/Get-CustomComplianceScriptValidator.ps1`
- "Startup performance / device experience score not showing, stuck at zero, or 'Insufficient data'" → `Troubleshooting/EndpointAnalytics-B.md` + `Scripts/Get-EndpointAnalyticsHealth.ps1`
- "Driver update not installing / WDfB conflict" → `Troubleshooting/DriverManagement-B.md` + `Scripts/Get-DriverManagementStatus.ps1`
- "EPM elevation request not working / agent missing" → `Troubleshooting/EPM-B.md` + `Scripts/Get-EPMElevationReport.ps1`
- "Assignment Filter not matching expected devices" → `Troubleshooting/Filters-B.md` + `Scripts/Get-AssignmentFilterAudit.ps1`
- "Migrating GPOs to CSP / need coverage gap report" → `Troubleshooting/GP-to-CSP-B.md` + `Scripts/Get-GPtoCSPCoverageReport.ps1`
- "Kiosk device not locking down / Assigned Access broken" → `Troubleshooting/Kiosk-B.md` + `Scripts/Get-KioskDeviceHealthReport.ps1`
- "Platform script (PowerShell) not running on device" → `Troubleshooting/Platform-Scripts-B.md` + `Scripts/Get-PlatformScriptRunStatus.ps1`
- "Proactive Remediation not detecting/fixing issue" → `Troubleshooting/Remediations-B.md` + `Scripts/Get-RemediationRunHistory.ps1`
- "Admin can't see/manage a device they should (or can see one they shouldn't)" → `Troubleshooting/ScopeTags-B.md` + `Scripts/Get-ScopeTagRBACAudit.ps1`
- "Windows Update for Business ring not applying / stuck deferring" → `Troubleshooting/WUfB-B.md` + `Scripts/Get-WUfBDeploymentStatus.ps1`
- "Remote Help session won't start / notification never arrives / can't get elevation" → `Troubleshooting/RemoteHelp-B.md` + `Scripts/Get-RemoteHelpReadinessAudit.ps1`

---

## Key diagnostic commands (always useful)

```powershell
# Device join + MDM state (run on the device)
dsregcmd /status

# Force Intune sync (run on device as admin)
Start-Process -FilePath "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o"
# Or trigger via Intune portal: Device → Sync

# Intune MDM diagnostic logs
mdmdiagnosticstool.exe -area DeviceEnrollment+DeviceProvisioning+TPM -zip C:\MDMLogs.zip

# Check what policies are applied and any errors
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" |
  Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
  Select TimeCreated, Id, Message | Format-Table -Wrap

# IME (Intune Management Extension) service health — needed for Win32 apps, Platform Scripts, Remediations
Get-Service -Name IntuneManagementExtension
Get-Content "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 100
```

---

## Key dependency chain

```
Entra ID device object exists + is enabled
    → Device is Entra joined (not just registered)
    → Intune licence assigned to user
    → MDM authority = Microsoft Intune (not mixed/SCCM — see co-management workload split)
    → Device within MDM scope (All Users or specific group)
    → Intune service reachable (firewall: *.manage.microsoft.com)
    → Device checks in (every 8h by default; force sync for immediate)
    → Policies target correct AAD group
    → Assignment Filter (if used) evaluates true against device properties
    → No conflicting GPO overriding Intune settings (MDM wins unless GPO is CSP-equivalent)
    → For Win32 apps/Platform Scripts/Remediations: IME service present and healthy on device
```

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — `dsregcmd /status` → identify broken layer → fix → force sync → validate
2. **Deep Dive** — MDM architecture, CSP vs GPO conflict model, compliance evaluation chain
3. **Learning Pointers** — what to study after resolution
