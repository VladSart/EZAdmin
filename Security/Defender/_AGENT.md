# Microsoft Defender — Agent Instructions

## What's in this folder
Runbooks and scripts for Microsoft Defender for Endpoint (MDE), Attack Surface Reduction (ASR), and Tamper Protection troubleshooting in MSP/enterprise environments. Covers onboarding, policy conflicts, sensor health, and incident response workflows.

## Before responding, also check
- `Security/ConditionalAccess/` — CA policies often interact with MDE compliance signals
- `Intune/Troubleshooting/Policy-Conflict-A.md` — MDE policies are delivered via Intune; conflicts surface there
- `EntraID/Troubleshooting/HybridJoin-A.md` — Hybrid-joined devices require correct AAD join state for MDE tagging
- `Windows/Troubleshooting/` — OS-level issues (WMI, services) can break MDE sensor

## Folder contents

| File | What it covers |
|------|---------------|
| `_AGENT.md` | This file — routing and orientation |
| `MDE-Onboarding-B.md` | Hotfix runbook: devices not appearing in MDE portal, onboarding failures |
| `ASR-Rules-B.md` | Hotfix runbook: ASR rule blocking legitimate apps, false positives, audit vs. block mode |
| `Tamper-Protection-B.md` | Hotfix runbook: Tamper Protection preventing policy changes, locked sensor state |

## Common entry points

- "Device not showing in Defender portal" → `MDE-Onboarding-B.md` — Check onboarding status and sensor health
- "Application blocked by Defender / false positive" → `ASR-Rules-B.md` — Diagnose ASR rule ID, add exclusion
- "Can't change Defender settings / policy not applying" → `Tamper-Protection-B.md` — Tamper Protection state check
- "MDE showing unhealthy sensor" → `MDE-Onboarding-B.md` — Sensor health triage section
- "ASR blocking Office macros / LOB app" → `ASR-Rules-B.md` — Per-rule exclusion and audit mode
- "Onboarding package not working" → `MDE-Onboarding-B.md` — Package validation and re-onboarding steps

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
