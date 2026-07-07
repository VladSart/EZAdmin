# Azure Arc-Enabled Servers — Agent Instructions

## What's in this folder

Azure Arc-enabled servers (Connected Machine agent) troubleshooting runbooks and diagnostic scripts for MSP engineers. Covers onboarding failures (interactive and at-scale/service-principal), agent connectivity and heartbeat issues, the 45-90 day disconnect/expiry cliff, and the Arc connection as a prerequisite layer for extensions (AMA, MDE, Update Manager) and downstream Sentinel/Defender for Cloud coverage of non-Azure servers.

---

## Before responding, also check

| Also check | Why |
|---|---|
| `Security/Sentinel/DataConnectors-B.md` and `-A.md` | Arc connectivity is a prerequisite layer for Sentinel data connectors covering non-Azure servers — a healthy Arc connection doesn't guarantee data is flowing |
| `Security/Defender/_AGENT.md` | Defender for Cloud CSPM/server plans and MDE onboarding on non-Azure servers depend on a healthy Arc connection |
| `EntraID/Troubleshooting/AppRegistrations-B.md` and `-A.md` | At-scale onboarding uses a service principal — SPN secret expiry/rotation issues surface here, not in this folder |
| `Security/ConditionalAccess/` | CA policies targeting service principal sign-ins can block at-scale onboarding if not scoped to exclude the onboarding SPN |

---

## Folder contents

| File | What it covers |
|---|---|
| `AzureArc-B.md` | Hotfix runbook — agent disconnected, onboarding fails, HIMDS crash-looping, credential errors, expired identity |
| `AzureArc-A.md` | Deep-dive reference — full onboarding architecture, identity model (HIMDS/managed identity vs onboarding SPN), AZCM error code map, MSP fleet-scale playbooks |
| `Scripts/Get-AzureArcAgentHealth.ps1` | Local agent health report — `azcmagent show`/`check` output, core service status, recent AZCM error codes, days-since-heartbeat vs the expiry window; optional Azure-side resource check |

---

## Common entry points

| User question | Start here |
|---|---|
| "Server shows Disconnected in the Arc portal" | `AzureArc-B.md` → Triage → Fix 1 |
| "Onboarding fails with an AZCM error code" | `AzureArc-B.md` → Diagnosis Step 4, then `AzureArc-A.md` → Symptom → Cause Map |
| "Can't reconnect a server that's been offline a while" | `AzureArc-A.md` → Playbook 2 (45-90 day expiry cliff) |
| "At-scale/service-principal onboarding fails across multiple client tenants" | `AzureArc-A.md` → Playbook 1 |
| "How does Azure Arc actually authenticate without inbound access?" | `AzureArc-A.md` → How It Works |
| "Need a fleet-wide view of what's about to expire" | `AzureArc-A.md` → Playbook 3 |
| "Collect health data before opening a Microsoft ticket" | `Scripts/Get-AzureArcAgentHealth.ps1` |

---

## Key diagnostic commands

```powershell
# Local agent connection status and last heartbeat
azcmagent show

# Full built-in endpoint/connectivity probe
azcmagent check

# Core service status
Get-Service himds, GCArcService, ExtensionService

# Azure-side resource state
Get-AzConnectedMachine -ResourceGroupName "<rg>" -Name "<machineName>" |
    Select-Object Name, Status, LastStatusChange, AgentVersion

# Recent AZCM error codes from the verbose log
Get-Content "$env:ProgramData\AzureConnectedMachineAgent\Log\azcmagent.log" -Tail 200 | Select-String "AZCM\d{4}"
```

---

## Key dependency chain

```
Server (physical, on-prem VM, or VM on another cloud)
    │
    └── Connected Machine agent (azcmagent + HIMDS + Extension service)
            │
            └── Outbound HTTPS 443 only (Entra ID, ARM, *.his.arc.azure.com, *.guestconfiguration.azure.com, notifications)
                    │
                    └── HIMDS issues machine-scoped Entra managed identity (local, never transmitted)
                            │
                            └── Heartbeat every 5 min → Connected / Disconnected (15 min) / Expired (45-90 days, unrecoverable in place)
                                    │
                                    └── Extensions layered on top: AMA, MDE, Update Manager
                                            │
                                            └── Consumed by: Sentinel data connectors, Defender for Cloud CSPM
```

---

## Response format reminder

Always respond in 3 layers:
1. **Immediate action** — run `azcmagent show` and `azcmagent check` first, always
2. **Root cause** — distinguish network/endpoint, service-level, credential, and identity-expiry failure classes; each has a different fix
3. **Fix + validation** — apply the matching fix path, confirm with `azcmagent show` and, if applicable, `Get-AzConnectedMachine`
