# Microsoft Defender — Agent Instructions

## What's in this folder
Runbooks and scripts for Microsoft Defender for Endpoint (MDE), Defender for Cloud Apps (MDA), Defender for Identity (MDI), Defender for Cloud (CSPM — Azure-resource Secure Score, posture, multicloud/hybrid connectors), CIEM (Cloud Infrastructure Entitlement Management — a Defender CSPM sub-feature covering multicloud identity/permission risk, and the successor to the now-retired standalone Microsoft Entra Permissions Management product), Defender Vulnerability Management, Attack Surface Reduction (ASR), Network Protection, Cloud Protection, Tamper Protection, WDAC (Windows Defender Application Control), Attack Simulation Training, Defender for Office 365 Safe Links/Safe Attachments, and the tenant-wide **Microsoft Secure Score** (Identity/Device/Apps/Data — security.microsoft.com/securescore, explicitly distinct from Defender for Cloud's Azure-resource CSPM score of the same name) troubleshooting in MSP/enterprise environments. Covers onboarding, policy conflicts, sensor health, cloud posture management, identity entitlement/permission risk, real-time URL/attachment protection, tenant-wide security posture scoring, and incident response workflows across the Defender XDR suite plus Defender for Office 365.

## Before responding, also check
- `Security/ConditionalAccess/` — CA policies often interact with MDE compliance signals
- `Intune/Troubleshooting/Policy-Conflict-A.md` — MDE/WDAC policies are delivered via Intune; conflicts surface there
- `EntraID/Troubleshooting/HybridJoin-A.md` — Hybrid-joined devices require correct AAD join state for MDE tagging
- `Windows/Troubleshooting/` — OS-level issues (WMI, services) can break MDE sensor
- `M365/Exchange/` — mail-flow/transport-rule interactions with Attack Simulation Training, reported-phish routing, and Safe Links/Safe Attachments (which sit downstream of EOP anti-spam/anti-malware in the same pipeline — see `M365/Exchange/EOP-AntiSpam-A.md` for the layer that runs first)
- `Security/Purview/` — Insider Risk and Communication Compliance are adjacent but separate Purview workloads, not part of this folder
- `Azure/Arc/` — Defender for Cloud (CSPM) posture data for on-prem/hybrid servers depends on the machine being Arc-connected first; Arc agent health itself is out of scope for this folder
- `Security/Sentinel/` — Defender for Cloud alerts/recommendations feed into Sentinel via a data connector, distinct from Defender XDR's own alert queue

## Folder contents

| File | What it covers |
|------|---------------|
| `_AGENT.md` | This file — routing and orientation |
| `MDE-Onboarding-B.md` / `-A.md` | Devices not appearing in MDE portal, onboarding failures, sensor health — **Windows-only** (SENSE service, registry-based state); for macOS see `macOS/Troubleshooting/MDE-macOS-A.md`/`-B.md` |
| `ASR-Rules-B.md` / `-A.md` | ASR rule blocking legitimate apps, false positives, audit vs. block mode |
| `Tamper-Protection-B.md` | Tamper Protection preventing policy changes, locked sensor state |
| `CloudProtection-B.md` | Defender cloud-delivered protection / MAPS connectivity issues |
| `DefenderVulnMgmt-B.md` | Defender Vulnerability Management scanning/reporting issues |
| `MDA-B.md` | Microsoft Defender for Cloud Apps (MCAS) connector/policy issues |
| `MDI-B.md` | Microsoft Defender for Identity sensor/health issues |
| `NetworkProtection-B.md` | Network Protection blocking legitimate connections, indicator/exclusion issues |
| `WDAC-B.md` / `-A.md` | Windows Defender Application Control policy conflicts and blocked binaries |
| `AttackSimulationTraining-B.md` / `-A.md` | Phishing simulation delivery, reporting, and training-assignment issues (Defender for Office 365 Plan 2) |
| `SafeLinksAttachments-B.md` / `-A.md` | Defender for Office 365 Safe Links (URL rewrite/time-of-click) and Safe Attachments (detonation) — policy precedence, Teams/Office app coverage, SPO/OneDrive/Teams separate toggle, quarantine visibility |
| `DefenderForCloud-B.md` / `-A.md` | Defender for Cloud (CSPM) — Secure Score, unhealthy recommendations, multicloud (AWS/GCP) connector onboarding, agentless scanning, regulatory compliance dashboard |
| `CIEM-B.md` / `-A.md` | Cloud Infrastructure Entitlement Management — Defender CSPM sub-feature for multicloud (Azure/AWS/GCP) identity/permission risk, overprivileged/inactive identity recommendations, Cloud Security Explorer, Attack Path Analysis; also covers the Oct 2025 retirement of standalone Microsoft Entra Permissions Management and what that means for existing clients |
| `DeviceControl-B.md` / `-A.md` | Device control (USB/removable media/printer/Bluetooth/WPD) — Policy→Rules→Groups→Entries model, fall-through to default enforcement, distinct from Windows Device Installation Restrictions and Purview Endpoint DLP |
| `SecureScore-B.md` / `-A.md` | Microsoft Secure Score (tenant-wide, security.microsoft.com/securescore) — Identity/Device/Apps/Data scoring model, regression triage, EnabledServices licensing gate, manual override reconciliation, RBAC (Unified RBAC vs. legacy Entra roles vs. Graph API access), explicitly disambiguated from Defender for Cloud's Azure-resource CSPM Secure Score and from TVM's per-device exposure score |
| `Scripts/Get-MDEDeviceStatus.ps1` | Graph-based MDE device health/risk/sensor report |
| `Scripts/Get-TamperProtectionStatus.ps1` | Tamper Protection state audit |
| `Scripts/Get-ASRRuleStatus.ps1` | ASR rule state/mode audit |
| `Scripts/Get-CloudProtectionStatus.ps1` | Cloud-delivered protection connectivity audit |
| `Scripts/Get-DefenderVulnMgmtStatus.ps1` | Vulnerability Management coverage audit |
| `Scripts/Get-MDAStatus.ps1` | Defender for Cloud Apps connector/policy audit |
| `Scripts/Get-MDIStatus.ps1` | Defender for Identity sensor health audit |
| `Scripts/Get-NetworkProtectionStatus.ps1` | Network Protection state/exclusion audit |
| `Scripts/Get-WDACPolicyStatus.ps1` | WDAC policy deployment/enforcement audit |
| `Scripts/Get-AttackSimulationCampaignAudit.ps1` | Graph-based Attack Simulation Training campaign health audit — stuck/stale simulations, audit-logging gate, transport-rule interference, per-user licensing gaps |
| `Scripts/Get-SafeLinksAttachmentsPolicyAudit.ps1` | Safe Links/Safe Attachments policy+rule audit — precedence conflicts, non-blocking Action settings, silent quarantine tags, SPO/OneDrive/Teams toggle state, possible upstream gateway conflicts |
| `Scripts/Get-DefenderForCloudPostureAudit.ps1` | Fleet-wide CSPM audit — plan tiers, Secure Score, unhealthy assessments, multicloud connector coverage, connector resource locks |
| `Scripts/Get-DeviceControlPolicyAudit.ps1` | Local device control readiness audit — onboarding/AM version, policy delivery, PnP device Hardware ID/Instance Path inventory for group cross-referencing, Device Installation Restriction layer check |
| `Scripts/Get-SecureScoreReport.ps1` | Graph-based tenant-wide Secure Score audit — regression/category-regression detection, EnabledServices-vs-license gap check, stale manual override flagging, quick-win candidate ranking, device-category informational routing |
| `Scripts/Get-CIEMRecommendationAudit.ps1` | CIEM readiness audit — Defender CSPM plan tier, Azure CIEM recommendation state, multicloud connector inventory flagged for manual "was Configure access re-run" verification (the CIEM on/off toggle itself is portal-only and not read by this script) |

## Common entry points

- "Device not showing in Defender portal" → `MDE-Onboarding-B.md` — Check onboarding status and sensor health
- "Application blocked by Defender / false positive" → `ASR-Rules-B.md` — Diagnose ASR rule ID, add exclusion
- "Can't change Defender settings / policy not applying" → `Tamper-Protection-B.md` — Tamper Protection state check
- "MDE showing unhealthy sensor" → `MDE-Onboarding-B.md` — Sensor health triage section
- "ASR blocking Office macros / LOB app" → `ASR-Rules-B.md` — Per-rule exclusion and audit mode
- "Onboarding package not working" → `MDE-Onboarding-B.md` — Package validation and re-onboarding steps (Windows). On a Mac, go straight to `macOS/Troubleshooting/MDE-macOS-B.md` instead — the onboarding mechanism is entirely different (no SENSE service/registry key)
- "WDAC / Application Control blocking a signed app" → `WDAC-B.md` — Policy conflict and audit-mode triage
- "Phishing simulation didn't reach all users" / "training assigned incorrectly" / "reports are empty" → `AttackSimulationTraining-B.md` — Licensing, audit-log, target-group hygiene, and reporting-mailbox triage
- "Reported phishing email never shows in simulation reports" → `AttackSimulationTraining-B.md` Fix 6 — transport rule interference with submission addresses
- "Secure Score dropped / recommendation shows unhealthy" → `DefenderForCloud-B.md` — Secure Score/assessment triage
- "AWS/GCP account shows no data in Defender for Cloud" / connector onboarding failed → `DefenderForCloud-B.md` Fix 3
- "Attack path analysis / agentless scanning / regulatory compliance is missing" → `DefenderForCloud-B.md` Fix 1 — check plan tier (Foundational vs. Defender CSPM) first
- "GCP agentless VM scan results empty" → `DefenderForCloud-B.md` Fix 4 — check the disk-scanning org policy
- "Link in email isn't blue/wrapped / phishing link got through" / "attachment wasn't scanned or delayed" → `SafeLinksAttachments-B.md` — check policy precedence first (preset always wins over custom)
- "Teams link protection not working after I turned it on" → `SafeLinksAttachments-B.md` Fix 4 — allow up to 24h for Teams policy changes
- "File uploaded to SharePoint/OneDrive/Teams wasn't scanned even though mail Safe Attachments is set to Block" → `SafeLinksAttachments-B.md` Fix 1 — separate `EnableATPForSPOTeamsODB` toggle
- "USB drive blocked, can't read/write files, printer suddenly blocked" → `DeviceControl-B.md` — first confirm it's this layer and not Windows Device Installation Restrictions (device fully absent vs. installed-but-restricted)
- "Policy says Allow but device is still denied" → `DeviceControl-B.md` Fix 3 — device likely fell through to default enforcement, check Advanced Hunting `RemovableStoragePolicy` field for the actual rule name
- "Secure Score dropped" / "recommendation stuck at To address" (M365 tenant-wide, NOT an Azure subscription) → `SecureScore-B.md` — first confirm it's this score and not Defender for Cloud's CSPM score of the same name
- "Fixed it but the score didn't move" → `SecureScore-B.md` Fix 3 — 24–48h refresh delay (weekly/monthly for Teams/Entra specifically)
- "Third-party MFA/DLP tool covers this, why is it still unresolved" → `SecureScore-B.md` Fix 4 — manually set "Resolved through third party"
- "Device category recommendation won't let me change status" → `SecureScore-B.md` Fix 5 — routes through Defender Vulnerability Management; Global exception updates the score, per-device-group exception does not
- "Graph script gets 403 on Secure Score but the portal works fine for that user" → `SecureScore-B.md` Fix 6 — Graph API access is still legacy-Entra-role-gated, not yet covered by Unified RBAC custom roles
- "Where did our Entra Permissions Management dashboard go?" / "we used to have CIEM, now it's missing" → `CIEM-B.md` Fix 4 — standalone product retired Oct 1 2025, this is a fresh onboarding into Defender for Cloud's CIEM sub-feature, not a migration
- "Defender CSPM is enabled but we see no overprivileged/inactive identity recommendations" → `CIEM-B.md` Fix 1 — CIEM has its own sub-toggle separate from the Defender CSPM plan itself
- "AWS/GCP shows no CIEM data" → `CIEM-B.md` Fix 2/3 — the connector's CIEM-specific access-configuration step (CloudFormation/Terraform) needs a separate re-run from base connector onboarding

## Key diagnostic commands

```powershell
# Check MDE onboarding state
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"

# Check sensor service health
Get-Service -Name "Sense" | Select-Object Name, Status, StartType

# Check ASR rules state (requires MpCmdRun or PowerShell module)
Get-MpPreference | Select-Object AttackSurfaceReductionRules_Ids, AttackSurfaceReductionRules_Actions

# Check Tamper Protection state
Get-MpComputerStatus | Select-Object TamperProtectionSource, IsTamperProtected

# Run MDE health check
& "C:\Program Files\Windows Defender Advanced Threat Protection\MsSense.exe" -health 2>&1

# Check Defender for Cloud (CSPM) plan tiers
Get-AzSecurityPricing | Select-Object Name, PricingTier

# Pull Defender for Cloud's Azure-resource Secure Score (Az.Security — a DIFFERENT score, see DefenderForCloud-A.md)
Get-AzSecuritySecureScore | Select-Object DisplayName, @{N="Current";E={$_.Score.Current}}, @{N="Max";E={$_.Score.Max}}

# Find multicloud (AWS/GCP) connectors tenant-wide
Search-AzGraph -Query "resources | where type =~ 'microsoft.security/securityconnectors'"

# Pull the M365 tenant-wide Secure Score (Microsoft Graph — a DIFFERENT score, see SecureScore-A.md)
Connect-MgGraph -Scopes "SecurityEvents.Read.All"
Get-MgSecuritySecureScore -Top 1 | Select-Object CreatedDateTime, CurrentScore, MaxScore, EnabledServices
```

## Key dependency chain

```
Azure AD / Entra ID (device identity)
    └── Intune (policy delivery channel)
            └── MDE Onboarding Package (MDM or GPO)
                    └── SENSE Service (sensor process)
                            ├── MDE Portal (cloud telemetry)
                            ├── ASR Engine (kernel-level rules)
                            └── Tamper Protection (self-defence layer)

Defender for Cloud (CSPM) — separate chain, resource/subscription-scoped, not device-scoped:
Entra ID tenant + Azure subscription
    └── Azure Policy (MCSB assignment) ── Foundational CSPM (free, always on)
            └── Defender CSPM (paid, opt-in) ── agentless scanning, attack path,
                    governance rules, regulatory compliance
    └── Multicloud connectors: AWS (CloudFormation/IAM role) | GCP (Workload
            Identity Federation) | on-prem/hybrid (Azure Arc agent — see Azure/Arc/)

Microsoft Secure Score (tenant-wide) — a THIRD, separate chain, M365-workload-scoped:
Licensed & provisioned workload (Entra/Exchange/SPO/Teams/MDE/MDI/MDCA/Purview IP/
non-Microsoft apps) ── must appear in EnabledServices or the whole category is absent
    └── secureScoreControlProfiles evaluated against live config
            └── controlScores aggregated into currentScore/maxScore
                    └── RBAC gate: Unified RBAC "Exposure Management" (portal) OR
                            legacy Entra global role (portal AND currently the
                            only path for Graph API access)
```

## Response format reminder

Always answer in 3 layers:
1. **Immediate** — what to run right now (copy-paste command)
2. **Root cause** — why this happens in a managed environment
3. **Prevention** — how to stop it recurring (policy, monitoring, or exclusion)
