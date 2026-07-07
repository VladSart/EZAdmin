# Azure — Agent Instructions

## What's in this folder

Azure infrastructure runbooks and scripts for MSP engineers managing Azure environments on behalf of clients. Covers **Azure Virtual Desktop (AVD)** (session host management, FSLogix profile containers, MSIX App Attach, network connectivity), **Azure Files** (direct SMB/NFS shares, identity-based auth, Azure File Sync), **Windows 365 Cloud PC** (provisioning, Azure Network Connections, licensing, resize/reprovision), and **Azure Arc-enabled servers** (Connected Machine agent onboarding, connectivity/heartbeat, identity model, prerequisite layer for Sentinel/Defender for Cloud on non-Azure servers).

---

## Before responding, also check

- **Entra ID** (`EntraID/`) — AVD requires Entra-joined or Hybrid-joined session hosts; SSO and identity issues often originate there
- **Intune** (`Intune/`) — Session hosts managed via Intune need compliance and configuration policy review
- **Windows** (`Windows/Troubleshooting/`) — RDP, networking, Kerberos, and profile issues apply to AVD session hosts
- **Security/ConditionalAccess** — CA policies frequently block AVD users; cross-reference sign-in logs
- **Security/Defender** — MDE is deployed on AVD hosts; ASR rules and Tamper Protection can affect session host behaviour

---

## Folder contents

| File | What it covers |
|------|----------------|
| `AVD/AVD-B.md` | AVD hotfix runbook — session host not available, users can't connect |
| `AVD/AVD-A.md` | AVD deep dive — full architecture, host pool types, scaling plans, diagnostics |
| `AVD/AVD-Connectivity-B.md` | AVD network connectivity hotfix — RDP transport, reverse connect, firewall URLs |
| `AVD/AVD-Connectivity-A.md` | AVD connectivity deep dive — Azure Private Link, NSG rules, RDP shortpath |
| `AVD/FSLogix-B.md` | FSLogix profile container hotfix — profile not loading, VHD/VHDX locked |
| `AVD/FSLogix-A.md` | FSLogix deep dive — storage backend (Azure Files/ANF), Cloud Cache, redirection rules |
| `AVD/AppAttach-B.md` | MSIX App Attach hotfix — app not available in session, package not mounting |
| `AVD/Scripts/Get-AVDSessionHealth.ps1` | Reports session host availability, drain mode, session counts across host pools |
| `AVD/Scripts/Test-AVDConnectivity.ps1` | Tests connectivity to required AVD/Entra/licensing/CRL endpoints; optional RDP Shortpath and FSLogix share checks |
| `Files/AzureFiles-B.md` | Azure Files hotfix runbook — can't mount share, access denied, quota exhausted |
| `Files/AzureFiles-A.md` | Azure Files deep dive — direct mount vs Azure File Sync, identity auth models, RBAC vs NTFS |
| `Files/Scripts/Get-AzureFileShareHealth.ps1` | Reports share quota/usage, identity auth config, network rules, RBAC assignments |
| `Windows365/Windows365-B.md` | Windows 365 hotfix runbook — provisioning failures, ANC issues, resize/reprovision, client connectivity |
| `Windows365/Windows365-A.md` | Windows 365 deep dive — provisioning policy pipeline, ANC architecture, licensing model, Frontline shared pools |
| `Windows365/Scripts/Get-CloudPcFleetStatus.ps1` | Fleet-wide Cloud PC provisioning status, ANC health, and license consumption report |
| `Arc/AzureArc-B.md` | Azure Arc hotfix runbook — agent disconnected, onboarding fails, HIMDS crash-looping, expired identity |
| `Arc/AzureArc-A.md` | Azure Arc deep dive — onboarding architecture, identity model, AZCM error code map, MSP fleet playbooks |
| `Arc/Scripts/Get-AzureArcAgentHealth.ps1` | Local agent health report — connection status, service state, recent AZCM errors, days-since-heartbeat vs expiry |

---

## Common entry points

- **"Users can't connect to AVD"** → `AVD/AVD-B.md` (triage first), then `AVD/AVD-Connectivity-B.md` if RDP transport is the issue
- **"AVD profile not loading / missing desktop"** → `AVD/FSLogix-B.md`
- **"App not showing in AVD"** → `AVD/AppAttach-B.md`
- **"Session host showing unavailable in portal"** → `AVD/AVD-B.md` → check agent health and drain mode
- **"AVD performance issues / high latency"** → `AVD/AVD-Connectivity-A.md` (RDP Shortpath section)
- **"FSLogix profile disk growing too large"** → `AVD/FSLogix-A.md` (redirection and exclusion rules)
- **"Collect host pool health for a ticket"** → `AVD/Scripts/Get-AVDSessionHealth.ps1`
- **"Rule out network as the cause before escalating"** → `AVD/Scripts/Test-AVDConnectivity.ps1`
- **"Cloud PC stuck provisioning / failed"** → `Windows365/Windows365-B.md`
- **"Windows 365 vs AVD — which do I use for this issue"** → `Windows365/Windows365-A.md` (comparison table)
- **"Fleet-wide Cloud PC health for a ticket/report"** → `Windows365/Scripts/Get-CloudPcFleetStatus.ps1`
- **"Server shows Disconnected in Azure Arc"** → `Arc/AzureArc-B.md`
- **"Can't reconnect a server that's been offline for weeks"** → `Arc/AzureArc-A.md` (Playbook 2 — 45-90 day expiry cliff)
- **"Onboarding a batch of servers to Arc across client tenants"** → `Arc/AzureArc-A.md` (Playbook 1)

---

## Key diagnostic commands

```powershell
# List all session hosts and their status across all host pools in a resource group
Get-AzWvdSessionHost -ResourceGroupName <rg> -HostPoolName <hostpool>

# Check AVD agent health on a session host (run on the host):
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' | Select-Object AgentVersion, IsRegistered, RegistrationToken

# Check FSLogix service on a session host:
Get-Service frxsvc, frxccds | Select-Object Name, Status, StartType

# Check FSLogix profile status for a user:
Get-ItemProperty 'HKLM:\SOFTWARE\FSLogix\Profiles' | Select-Object Enabled, VHDLocations, VolumeType

# Query FSLogix event log for errors:
Get-WinEvent -LogName 'Microsoft-FSLogix-Apps/Operational' -MaxEvents 50 | Where-Object { $_.LevelDisplayName -eq 'Error' }

# Check MSIX App Attach package status:
Get-AppxPackage -AllUsers | Where-Object { $_.PackageFullName -like '*<AppName>*' }
```

---

## Key dependency chain

```
End User
    │
    └── AVD Web Client / Remote Desktop Client
            │
            └── Azure Virtual Desktop Service (control plane)
                    │
                    ├── Host Pool → Session Hosts (Azure VMs)
                    │       │
                    │       ├── AVD Agent (RDAgent)
                    │       ├── AVD Boot Loader
                    │       ├── FSLogix (profile container)
                    │       ├── MSIX App Attach (app packages)
                    │       └── MDE / Defender AV
                    │
                    ├── Azure Storage (Azure Files / ANF)
                    │       └── FSLogix VHD(X) containers
                    │
                    └── Entra ID
                            └── SSO / Token issuance for AVD
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — what to do right now to unblock the user (Mode B)
2. **Root cause** — why it happened and what's misconfigured (Mode A)
3. **Prevention** — monitoring, alerting, and policy changes to stop recurrence
