# Microsoft Defender — Agent Instructions

## What's in this folder
Runbooks and scripts for Microsoft Defender for Endpoint (MDE), Defender for Cloud Apps (MDA), Defender for Identity (MDI), Defender Vulnerability Management, Attack Surface Reduction (ASR), Network Protection, Cloud Protection, Tamper Protection, WDAC (Windows Defender Application Control), and Attack Simulation Training troubleshooting in MSP/enterprise environments. Covers onboarding, policy conflicts, sensor health, and incident response workflows across the Defender XDR suite plus the Defender for Office 365 phishing-simulation product.

## Before responding, also check
- `Security/ConditionalAccess/` — CA policies often interact with MDE compliance signals
- `Intune/Troubleshooting/Policy-Conflict-A.md` — MDE/WDAC policies are delivered via Intune; conflicts surface there
- `EntraID/Troubleshooting/HybridJoin-A.md` — Hybrid-joined devices require correct AAD join state for MDE tagging
- `Windows/Troubleshooting/` — OS-level issues (WMI, services) can break MDE sensor
- `M365/Exchange/` — mail-flow/transport-rule interactions with Attack Simulation Training and reported-phish routing
- `Security/Purview/` — Insider Risk and Communication Compliance are adjacent but separate Purview workloads, not part of this folder

## Folder contents

| File | What it covers |
|------|---------------|
| `_AGENT.md` | This file — routing and orientation |
| `MDE-Onboarding-B.md` / `-A.md` | Devices not appearing in MDE portal, onboarding failures, sensor health |
| `ASR-Rules-B.md` / `-A.md` | ASR rule blocking legitimate apps, false positives, audit vs. block mode |
| `Tamper-Protection-B.md` | Tamper Protection preventing policy changes, locked sensor state |
| `CloudProtection-B.md` | Defender cloud-delivered protection / MAPS connectivity issues |
| `DefenderVulnMgmt-B.md` | Defender Vulnerability Management scanning/reporting issues |
| `MDA-B.md` | Microsoft Defender for Cloud Apps (MCAS) connector/policy issues |
| `MDI-B.md` | Microsoft Defender for Identity sensor/health issues |
| `NetworkProtection-B.md` | Network Protection blocking legitimate connections, indicator/exclusion issues |
| `WDAC-B.md` / `-A.md` | Windows Defender Application Control policy conflicts and blocked binaries |
| `AttackSimulationTraining-B.md` / `-A.md` | Phishing simulation delivery, reporting, and training-assignment issues (Defender for Office 365 Plan 2) |
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

## Common entry points

- "Device not showing in Defender portal" → `MDE-Onboarding-B.md` — Check onboarding status and sensor health
- "Application blocked by Defender / false positive" → `ASR-Rules-B.md` — Diagnose ASR rule ID, add exclusion
- "Can't change Defender settings / policy not applying" → `Tamper-Protection-B.md` — Tamper Protection state check
- "MDE showing unhealthy sensor" → `MDE-Onboarding-B.md` — Sensor health triage section
- "ASR blocking Office macros / LOB app" → `ASR-Rules-B.md` — Per-rule exclusion and audit mode
- "Onboarding package not working" → `MDE-Onboarding-B.md` — Package validation and re-onboarding steps
- "WDAC / Application Control blocking a signed app" → `WDAC-B.md` — Policy conflict and audit-mode triage
- "Phishing simulation didn't reach all users" / "training assigned incorrectly" / "reports are empty" → `AttackSimulationTraining-B.md` — Licensing, audit-log, target-group hygiene, and reporting-mailbox triage
- "Reported phishing email never shows in simulation reports" → `AttackSimulationTraining-B.md` Fix 6 — transport rule interference with submission addresses

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
```

## Response format reminder

Always answer in 3 layers:
1. **Immediate** — what to run right now (copy-paste command)
2. **Root cause** — why this happens in a managed environment
3. **Prevention** — how to stop it recurring (policy, monitoring, or exclusion)
