# Intune — Agent Instructions

## What's in this folder

Microsoft Intune / Endpoint Manager — device management, compliance, configuration, app deployment, and update management.

Covers:
- **Enrollment** — Windows Autopilot, manual MDM enrollment, co-management, enrollment restrictions
- **Policy** — configuration profiles, compliance policies, settings catalog, GPO conflicts, assignment filters, scope tags/RBAC
- **Apps** — Win32 app deployment, managed apps (LOB/VPP), app protection (MAM), Enterprise App Management (Microsoft-curated Enterprise App Catalog — licensing, auto-update mechanics/limitations, content lifecycle, Autopilot ESP/Device Prep blocking-app integration)
- **Updates** — Update rings (WUfB), feature updates, driver updates (WDfB), Autopatch, and Windows 11 Hotpatch (restart-free monthly security updates delivered exclusively through Autopatch — the six-condition eligibility gate led by VBS-must-be-*Running*-not-just-enabled, the quarterly baseline/hotpatch release calendar, and the tenant-wide default-Allow behavior live since the May 2026 update cycle — architecturally distinct from Windows Server 2025 hotpatch, which is Azure Update Manager/Arc-managed, not Intune/Autopatch-managed) Also covers the **Windows Update Maintenance Window (Preview)** — the Update Policy CSP feature (`MaintenanceWindowEnabled` and related nodes) that defines a strict, exclusive window governing when download/install/restart are *allowed* to run, distinct from Active hours' softer restart-suppression-only model; no native Settings Catalog UI yet (custom profile/OMA-URI only), gated behind a server-side Known-Issue-Rollback-style feature-flighting switch entirely outside admin control, meaning a correctly-delivered policy can show "Succeeded" while having no observable effect Also covers the new (Sept 2026) **cloud-based Windows quality update policy** — a distinct admin-facing approval/deferral/pause control layered over Autopatch's ring orchestration, with per-category (security/non-security/OOB) approval defaults, an immutable approval method once created, pause-never-rolls-back semantics, and a documented precedence order over legacy Update ring policies
- **Security & compliance controls** — LAPS (steady-state rotation/retrieval **and** legacy Microsoft LAPS → Windows LAPS migration/coexistence, including the silent legacy-emulation-mode behavior — see `Troubleshooting/LAPS-Migration-A.md` for the precedence rules that decide which of the two products is actually governing an account at any given moment), certificates (on-prem NDES/PKCS **and** cloud-native Cloud PKI), custom compliance scripts, security baselines, Endpoint Privilege Management (EPM). Also covers the **Intune Suite → Microsoft 365 E3/E5 base-licensing bundling** (July–August 2026) that folded Remote Help/Advanced Analytics/Plan 2 into E3 and additionally EPM/Cloud PKI/Enterprise App Management into E5 — a licensing/procurement topic, not a technical deployment
- **Multi Admin Approval (MAA)** — access-policy-gated second-admin-approval change control for Apps/Compliance/Configuration policies, Device actions, RBAC roles, Windows scripts, and Tenant Configuration. Covers both delegated (interactive) enforcement and the newer (2026) application-authenticated (app-auth/Graph API/service-principal automation) enforcement — the `x-msft-approval-justification` header / HTTP 412 + `x-msft-approval-code` request-response cycle, the two silent-failure approver-group conditions (wrong group type, missing direct RBAC role-assignment membership), the 3-day no-notification request expiry, and the self-referential Role-policy RBAC deadlock and its recovery path
- **Specialty device modes** — Kiosk / Assigned Access
- **Automation** — Platform scripts, Proactive Remediations
- **Device Actions** — Wipe/Retire/Delete remote actions, including the documented tenant-wide daily submission quotas (500 Wipe/day, 1,000 Retire/day, 1,000 Delete/day), cumulative across UI + bulk + Graph API submissions; the Delete-action cascade into an underlying Retire or Wipe command depending on platform/Android enrollment type; and the BitLocker key-protector-removal safeguard triggered on Delete/Retire of Entra-joined, BitLocker-protected devices
- **Reporting** — compliance dashboards, device inventory, assignment/coverage reports, Graph queries, Endpoint analytics (Startup performance / Application reliability / Work from anywhere scoring)
- **Remote Help** — Entra-authenticated helper/sharer remote assistance app, tenant enablement, RBAC, licensing (both helper AND sharer need one), deployment, Conditional Access integration — distinct from Windows 365/AVD's own connection stack and from the separate `remoteAssistancePartner` third-party ISV onboarding feature. Also covers **Windows Unattended Support with Remote Sign-In** (Intune Suite Service Release 2608, August 2026) — a separate app stack (Azure Virtual Desktop Agent + Bootloader, not `RemoteHelp.exe`), its own dedicated RBAC permission (not in any built-in role), and a physical/corporate-owned/x64/Entra-joined device eligibility gate; do not conflate its dependency chain with attended Remote Help's
- **STIG Audit Baseline (GCC High only)** — a Security Technical Implementation Guide (DISA) audit-only compliance baseline for Windows 10/11, available **exclusively in US Government Community Cloud High tenants** (never commercial/GCC/DoD cloud), gated by the separately-licensed Intune Advanced Analytics add-on. Audits the full current benchmark (Microsoft Windows 11 STIG SCAP Benchmark, Version 2 Release 7, 197 rules) as one non-customizable profile — no CAT-level or individual-rule subsetting, UX-only profile creation (no Graph write endpoint). Rides the standard device-configuration delivery pipeline, so co-managed devices need the Device configuration workload set to Pilot Intune/Intune or data never arrives, silently. ~20 rules are permanently excluded from automated evaluation (require manual/physical verification). Bulk Graph export (`exportJobs`) is ~200x cheaper than the per-setting cached-report pattern at this rule count — prefer it for any full-tenant automation
- **Surface Management Portal** — the Intune admin center workspace (All services > Surface Management Portal) for Surface-brand hardware: warranty/protection-plan coverage, support requests, service orders (replacement/repair), device Insights, and Security Copilot integration. Not a separate license — gated only by an enrolled Surface device plus a Microsoft 365 admin role (assigned via `admin.microsoft.com`, not Intune RBAC). Has no comprehensive Graph API of its own; only the compliance/encryption/storage/OS-eligibility slice of its Insights overlaps standard Intune Graph data

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
| `Troubleshooting/QualityUpdatePolicies-B.md` / `-A.md` | Hotfix / deep dive: cloud-based Windows quality update policy — per-category (security/non-security/OOB) approval/deferral/pause, immutable approval method, .NET Framework integration, precedence vs. legacy Update ring policies |
| `Scripts/Get-QualityUpdatePolicyAudit.ps1` | Device-level compliance/OS/Insider-build evidence collector for quality-update-policy escalations, plus a portal-only evidence checklist (policy config/release approval state has no stable Graph endpoint) |
| `Troubleshooting/Hotpatch-B.md` / `-A.md` | Hotfix / deep dive: Windows 11 hotpatch eligibility gate (VBS Running, baseline currency, Arm64 CHPE), the quarterly baseline/hotpatch calendar, May 2026 tenant-wide default-Allow change, manual rollback (no auto-rollback exists) |
| `Scripts/Get-HotpatchReadinessAudit.ps1` | One-shot local device readiness check: OS build/architecture, VBS runtime status, baseline currency, Arm64 CHPE state, local enrollment signal, hotpatch-related Application log errors |
| `Troubleshooting/Certificates-B.md` / `-A.md` | Hotfix / deep dive: on-prem NDES/PKCS certificate profile delivery failures via Intune Certificate Connector |
| `Troubleshooting/CloudPKI-B.md` / `-A.md` | Hotfix / deep dive: Microsoft Cloud PKI (fully cloud-hosted PKI — no NDES/connector/on-prem CA) — CA status, BYOCA signing loop, trust chain delivery, 3-CA capacity cap |
| `Troubleshooting/IntuneSuiteBaseLicensing-B.md` / `-A.md` | Hotfix / deep dive: the July 1 – Aug 1 2026 Intune Suite → Microsoft 365 E3/E5 base-licensing bundling — E3 gets Remote Help/Advanced Analytics/Plan 2 features, E5 additionally gets EPM/Cloud PKI/Enterprise App Management; tenant SKU eligibility, per-user assignment gaps, and redundant standalone-add-on-spend review — licensing-only, hands off to each feature's own runbook for technical issues |
| `Scripts/Get-IntuneSuiteLicensingAudit.ps1` | Tenant-wide SKU classification (E3/E5-qualifying vs. non-qualifying), standalone add-on redundant-spend flagging, optional per-user bundled-service-plan check |
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
| `Troubleshooting/RemoteHelp-Unattended-B.md` / `-A.md` | Hotfix / deep dive: Windows Unattended Support with Remote Sign-In (Intune Suite Service Release 2608, August 2026) — a separate AVD-remoting-based app stack and RBAC permission from attended Remote Help, sharing only the tenant-wide enable switch and Conditional Access hookup; deliberately-excluded-from-every-built-in-role RBAC permission, absolute (no-override) physical/corporate/x64/joined device eligibility, and the independent in-session authentication boundary |
| `Scripts/Get-RemoteHelpUnattendedReadinessAudit.ps1` | Tenant-wide readiness audit for Unattended Support — tenant switch state, custom-role permission coverage, device eligibility, agent app deployment status |
| `Troubleshooting/ScopeTags-B.md` / `-A.md` | Hotfix / deep dive: Scope Tags / RBAC visibility issues |
| `Troubleshooting/Security-Baselines-B.md` / `-A.md` | Hotfix / deep dive: Endpoint Security Baseline Error/Conflict states |
| `Troubleshooting/WUfB-B.md` / `-A.md` | Hotfix / deep dive: Windows Update for Business ring assignment, GPO conflicts |
| `Troubleshooting/MaintenanceWindow-B.md` / `-A.md` | Hotfix / deep dive: Windows Update Maintenance Window (Preview) CSP — strict update-action window vs. Active hours' softer restart-suppression model, the server-side feature-flighting gate that can silently withhold effect despite a "Succeeded" policy push, build-eligibility floor, custom Settings Catalog/OMA-URI deployment (no native UI yet), and the under-documented interaction with Update ring deadlines |
| `Scripts/Get-MaintenanceWindowReadinessAudit.ps1` | Read-only build-eligibility, MDM-delivery, and event-log runtime-evidence audit for the Maintenance Window CSP, local or via `-ComputerName` remote invocation; cannot confirm the server-side feature-flighting gate directly (no supported diagnostic exists) |
| `Troubleshooting/SurfaceManagementPortal-B.md` / `-A.md` | Hotfix / deep dive: Surface Management Portal access issues, the Hardware Warranty role + Global Reader co-requirement, empty-portal data-population timing, support/service-order backend drift, Security Copilot plugin enablement |
| `Troubleshooting/MultiAdminApproval-B.md` / `-A.md` | Hotfix / deep dive: MAA access-policy write-operation gating — the 400 (missing justification header) vs. 412+approval-code (working as designed) distinction, app-auth automation failures since the 2026 Graph API enforcement change, approver-group silent-failure conditions, 3-day request expiry, exclusions, and the Role-policy RBAC deadlock recovery path |
| `Scripts/Get-MAAAccessPolicyAudit.ps1` | Tenant-wide audit of MAA access policies, approver-group type/RBAC-assignment health (flags both silent-failure conditions), and pending-request expiry risk |
| `Troubleshooting/STIGAuditBaseline-B.md` / `-A.md` | Hotfix / deep dive: Intune STIG audit baseline (GCC High only) — audit-only DISA STIG compliance reporting, Advanced Analytics licensing gate, co-management workload delivery dependency, the ~20-rule manual-verification exclusion set, single-non-customizable-profile design, and bulk-vs-per-setting Graph export cost tradeoff |
| `Scripts/Get-STIGAuditBaselineStatus.ps1` | Admin-side Graph audit — Advanced Analytics licensing signal, STIG baseline template/version discovery, existing audit profile (PolicyId) enumeration, optional per-policy rule-level audit summary pull via the cached-report pattern |
| `Troubleshooting/DeviceActionQuotas-B.md` / `-A.md` | Hotfix / deep dive: Wipe/Retire/Delete daily tenant-wide quotas (500/1,000/1,000), the Delete→Retire/Wipe cascade by platform and Android enrollment type (a Delete against corporate-owned Android also draws from the smaller Wipe pool), and the BitLocker key-protector-removal safeguard on Delete/Retire of Entra-joined encrypted devices |
| `Scripts/Get-DeviceActionQuotaAudit.ps1` | Read-only planning audit — flags corporate-owned Android devices that would cascade Delete into the Wipe quota, and optionally checks BitLocker recovery-key escrow readiness for Entra-joined Windows devices ahead of a bulk Delete/Retire batch |
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
| `Scripts/Get-SurfaceManagementPortalAudit.ps1` | Tenant-wide Surface-model device audit via Graph (compliance/encryption/storage/first-signin-signal, mirroring the Graph-derivable subset of the portal's own Insights cards) + Hardware Warranty Administrator/Specialist role-holder audit flagging missing Global Reader co-assignment |
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
- "Why does this tenant suddenly have EPM/Remote Help/Cloud PKI/Enterprise App Management" / "are we still paying for Intune Suite we don't need" / "feature shows unlicensed even though we're on E3/E5" → `Troubleshooting/IntuneSuiteBaseLicensing-B.md` + `Scripts/Get-IntuneSuiteLicensingAudit.ps1` (confirm licensing FIRST, then hand off to the feature's own runbook if still broken)
- "Security baseline shows Error/Conflict" → `Troubleshooting/Security-Baselines-B.md` + `Scripts/Get-SecurityBaselineDrift.ps1`
- "Device stuck on old Windows version / feature update not installing" → `Troubleshooting/FeatureUpdates-B.md` + `Scripts/Get-FeatureUpdateDeploymentStatus.ps1`
- "App Protection / MAM policy not applying, 'Open in' blocked" → `Troubleshooting/AppProtection-B.md` + `Scripts/Get-AppProtectionCoverageReport.ps1`
- "Autopatch device not in expected ring / deployment stalled" → `Troubleshooting/Autopatch-B.md` + `Scripts/Get-AutopatchReadiness.ps1`
- "Security update stuck / deferral too long / release paused" → `Troubleshooting/QualityUpdatePolicies-B.md` → Triage + Fix 1
- "Optional/non-security update didn't deploy" → `Troubleshooting/QualityUpdatePolicies-B.md` → Fix 2 (Manual is the default for non-security/OOB categories)
- "Can we change an existing quality update policy from Automatic to Manual" → `Troubleshooting/QualityUpdatePolicies-B.md` → Fix 6 (approval method is immutable — new policy required)
- "Device keeps rebooting even though hotpatch is supposed to be on" → `Troubleshooting/Hotpatch-B.md` (Triage — check for a baseline month first, then VBS runtime status)
- "Device never gets hotpatch, always the restart-requiring update" → `Troubleshooting/Hotpatch-B.md` (Fix 1 — VBS enabled vs. actually Running is the #1 cause)
- "We never configured hotpatch but devices seem to have it" → `Troubleshooting/Hotpatch-B.md` (Fix 3 — tenant-wide default flipped to Allow in May 2026)
- "A hotpatch update broke something, how do we roll it back" → `Troubleshooting/Hotpatch-B.md` (Fix 4 — no automatic rollback exists)
- "Arm64 device won't get hotpatch" → `Troubleshooting/Hotpatch-B.md` (Fix 5 — CHPE disable requirement)
- "Is Windows 11 hotpatch the same as Windows Server 2025 hotpatch?" → No — `Troubleshooting/Hotpatch-A.md` Scope & Assumptions explicitly disambiguates (Autopatch/Intune-managed vs. Azure Update Manager/Arc-managed)
- "Quick hotpatch readiness check on a device" → `Scripts/Get-HotpatchReadinessAudit.ps1`
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
- "Configured a Maintenance Window but updates still install/restart outside it" → `Troubleshooting/MaintenanceWindow-B.md` Fix 1 — likely the server-side feature-flighting gate, not a config mistake
- "Need a hard window for update installs, not just no-restart-during-work-hours" → `Troubleshooting/MaintenanceWindow-B.md` Fix 4 — Active hours and Maintenance Window are not interchangeable; pick the right one
- "Remote Help session won't start / notification never arrives / can't get elevation" → `Troubleshooting/RemoteHelp-B.md` + `Scripts/Get-RemoteHelpReadinessAudit.ps1`
- "Need to sign in to a device with nobody there / unattended remote support / Remote Sign-In" → `Troubleshooting/RemoteHelp-Unattended-B.md` + `Scripts/Get-RemoteHelpUnattendedReadinessAudit.ps1` (distinct RBAC permission and app stack from attended Remote Help)
- "Can't find Surface Management Portal" / "portal shows no devices" / "warranty admin role assigned but still no data" / "how do we automate Surface warranty reporting" / "Security Copilot doesn't know about our Surface devices" → `Troubleshooting/SurfaceManagementPortal-B.md` + `Scripts/Get-SurfaceManagementPortalAudit.ps1`
- "Automation/script suddenly getting 400 or 412 errors against Graph" / "our scheduled Intune automation stopped working with no code change" / "approval request stuck / expired / nobody approved it" / "approver group can't approve anything" / "locked out of fixing RBAC because RBAC changes need approval" → `Troubleshooting/MultiAdminApproval-B.md` + `Scripts/Get-MAAAccessPolicyAudit.ps1`
- "Need DISA STIG compliance reporting for a DoD contract" / "STIG baseline missing from Security baselines list" / "GCC High tenant, no audit data appearing" / "why isn't the STIG baseline fixing failed rules" → `Troubleshooting/STIGAuditBaseline-B.md` + `Scripts/Get-STIGAuditBaselineStatus.ps1` (confirm GCC High tenancy FIRST — this feature does not exist in commercial/GCC/DoD cloud; audit-only, remediate findings separately via Settings Catalog/security baseline/compliance policy/GPO)
- "Bulk Wipe/Retire/Delete job stopped mid-run with no per-device error" / "device action did nothing, no error shown" / "large offboarding project silently stalled" → `Troubleshooting/DeviceActionQuotas-B.md` + `Scripts/Get-DeviceActionQuotaAudit.ps1` (check the daily tenant-wide quota FIRST — 500 Wipe/1,000 Retire/1,000 Delete, shared across UI/bulk/Graph — before assuming a permissions or connectivity fault)
- "BitLocker suspended right after we deleted/retired a device" → `Troubleshooting/DeviceActionQuotas-B.md` Fix 3 — documented safeguard on Entra-joined encrypted devices, not a bug; capture the recovery key before, not after

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
