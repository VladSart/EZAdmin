# Azure Virtual Desktop — Agent Instructions

## What's in this folder

Azure Virtual Desktop (AVD) troubleshooting runbooks and diagnostic scripts for MSP engineers. Covers session host health, user connectivity, FSLogix profile containers, image management, and host pool configuration issues.

---

## Before responding, also check

| Also check | Why |
|---|---|
| `Intune/Troubleshooting/` | AVD session hosts are often Intune-enrolled; policy conflicts affect them |
| `EntraID/Troubleshooting/HybridJoin-B.md` | Hybrid-joined session hosts have Entra ID dependency |
| `Security/ConditionalAccess/` | CA policies blocking AVD workspace access are a common ticket |
| `EntraID/Troubleshooting/PRT-Issues-B.md` | SSO into AVD relies on PRT — PRT failures cause auth loops |
| `macOS/Troubleshooting/` | Mac clients connecting to AVD via MSRDP client have distinct issues |

---

## Folder contents

| File | What it covers |
|---|---|
| `AVD-B.md` | Hotfix runbook — diagnose and resolve AVD session/connectivity issues in under 10 minutes |
| `AVD-A.md` | Deep-dive reference — host pool architecture, session brokering, FSLogix, image lifecycle |
| `Scripts/Get-AVDSessionHealth.ps1` | Reports session host health, active sessions, drain mode, and FSLogix VHD status |
| `Scripts/Test-AVDConnectivity.ps1` | Tests required AVD/Entra/licensing/CRL endpoint connectivity; optional RDP Shortpath and FSLogix share checks |
| `Scripts/Get-AVDAppAttachHealth.ps1` | Audits MSIX App Attach on a session host — mount state, AppX registration, AppXSVC/CimFS driver, optional package share connectivity |
| `Scripts/Get-FSLogixProfileHealth.ps1` | Audits FSLogix profile containers on a session host — service/driver, registry config, SMB/Kerberos auth, locked VHD(X) detection |
| `Scripts/Get-AVDScalingPlanAudit.ps1` | Fleet audit of Scaling Plans — RBAC prerequisite, host pool assignment, drain/active-session conflicts, zero-floor Personal pools, diagnostic settings |

---

## Common entry points

| User question | Start here |
|---|---|
| "Users can't connect to AVD" | `AVD-B.md` → Triage section |
| "AVD session is slow / freezing" | `AVD-B.md` → Performance Fix Paths |
| "Black screen after connecting" | `AVD-B.md` → Black Screen fix path |
| "FSLogix profile not loading in AVD" | `AVD-B.md` → FSLogix section; then `AVD-A.md` → FSLogix architecture |
| "How does AVD session brokering work?" | `AVD-A.md` → How It Works |
| "Session host is showing unavailable" | `AVD-B.md` → Triage; run `Get-AVDSessionHealth.ps1` |
| "Need to drain a host for patching" | `AVD-A.md` → Remediation Playbooks → Drain Mode |
| "Custom image not deploying" | `AVD-A.md` → Image Management section |
| "Users get 'No resources available'" | `AVD-B.md` → Host Pool Capacity section |

---

## Key diagnostic commands

```powershell
# List all session hosts and their status
Get-AzWvdSessionHost -ResourceGroupName '<rg>' -HostPoolName '<pool>'

# List active user sessions
Get-AzWvdUserSession -ResourceGroupName '<rg>' -HostPoolName '<pool>' -SessionHostName '<host>'

# Enable drain mode on a host (for patching)
Update-AzWvdSessionHost -ResourceGroupName '<rg>' -HostPoolName '<pool>' `
    -Name '<host>' -AllowNewSession:$false

# Force disconnect and log off all sessions on a host
Get-AzWvdUserSession -ResourceGroupName '<rg>' -HostPoolName '<pool>' -SessionHostName '<host>' |
    ForEach-Object { Remove-AzWvdUserSession -ResourceGroupName '<rg>' -HostPoolName '<pool>' `
        -SessionHostName '<host>' -Id $_.Name.Split('/')[-1] -Force }

# Check FSLogix VHD mount on session host (run locally on host)
Get-WinEvent -LogName 'Microsoft-FSLogix-Apps/Operational' -MaxEvents 50 |
    Where-Object { $_.LevelDisplayName -eq 'Error' }
```

---

## Key dependency chain

```
User (client device: Windows / Mac / Browser)
    │
    ▼
AVD Client (MSRDP app or HTML5 web client)
    │
    ▼
AVD Gateway (Microsoft-managed, global)
    │
    ▼
AVD Broker (session routing, load balancing)
    │
    ├── Entra ID authentication (SSO via PRT or interactive)
    │
    └── Host Pool
            │
            ├── Session Host VMs (Azure IaaS)
            │       ├── RD Agent + Bootloader (must be current)
            │       ├── Intune / GPO policies applied
            │       └── FSLogix filter driver (if profile containers used)
            │
            └── FSLogix Profile Share (Azure Files / NetApp)
                    └── SMB 3.0, Kerberos auth (NTLM fallback)
```

---

## Response format reminder

Always respond in 3 layers:
1. **Immediate action** — what to run right now (triage command)
2. **Root cause** — why it's happening (architecture context)
3. **Fix + validation** — how to resolve and verify it's resolved
