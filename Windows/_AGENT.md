# Windows — Agent Instructions

## What's in this folder

Windows OS-level issues — update management, security features, performance, networking, and peripheral management.

Covers:
- **Windows Update / WfUB** — WSUS conflicts, dual-scan, update rings, stuck updates, 24H2 upgrade issues
- **BitLocker** — key escrow to Entra, recovery, policy enforcement, suspension
- **VBS / Credential Guard / HVCI** — enabling, conflicts with legacy apps/hypervisors
- **AppLocker / WDAC** — application control, policy audit mode, blocking legitimate apps
- **Networking** — DNS, DHCP, proxy, time sync, VPN coexistence
- **USB / Peripherals** — policy-driven control, driver management
- **Performance** — boot times, CPU/memory issues, storage health
- **Event log analysis** — systematic log collection and interpretation

---

## Folder contents

| File | What it covers |
|------|-----------------|
| `Troubleshooting/Windows Update/Update to Latest A.md` / `B.md` | Feature update deployment, stuck upgrades |
| `Troubleshooting/Windows Update/WSUS to WfUB A.md` / `B.md` | WSUS-to-Windows Update for Business migration, dual-scan conflicts |
| `Troubleshooting/BitLocker/BitLocker-A.md` / `B.md` | Recovery key escrow, policy enforcement, suspension |
| `Troubleshooting/BitLocker/NetworkUnlock-A.md` / `B.md` | On-prem AD/WDS-based PIN-prompt bypass on wired boot — GPO cert delivery, WDS provider role, subnet policy, no cloud/Entra equivalent |
| `Troubleshooting/VBS-CredentialGuard-A.md` / `B.md` | VBS/Credential Guard/HVCI enabling and app compatibility conflicts |
| `Troubleshooting/AppLocker-A.md` / `B.md` | Application control policy, audit mode, blocked-app diagnosis |
| `Troubleshooting/DNS-Client-A.md` / `B.md` | Resolver chain, NRPT, DoH, cache/HOSTS issues |
| `Troubleshooting/DHCP-Client-A.md` / `B.md` | DHCP lease failure, APIPA, relay/scope architecture |
| `Troubleshooting/NetworkAdapters-A.md` / `B.md` | NIC/driver/NDIS stack, routing conflicts, LBFO teaming, MTU issues |
| `Troubleshooting/AlwaysOnVPN-A.md` / `B.md` | Always On VPN device/user tunnel, IKEv2/SSTP negotiation |
| `Troubleshooting/RDP-A.md` / `B.md` | Remote Desktop connection failures |
| `Troubleshooting/SMB-A.md` / `B.md` | File share access, SMB protocol issues |
| `Troubleshooting/GPO-A.md` / `B.md` | Group Policy application and conflict diagnosis |
| `Troubleshooting/Kerberos-A.md` / `B.md` | Kerberos auth failures, NTLM fallback |
| `Troubleshooting/NTLM-A.md` / `B.md` | NTLM auth failures, secure channel, LM level hardening |
| `Troubleshooting/Firewall-A.md` / `B.md` | Windows Firewall rule/profile diagnosis |
| `Troubleshooting/WMI-A.md` / `B.md` | WMI repository/service diagnosis |
| `Troubleshooting/EventLog-A.md` / `B.md` | Event log collection, corruption, sizing |
| `Troubleshooting/CredentialManager-A.md` / `B.md` | Stored credential issues |
| `Troubleshooting/CertificateServices-A.md` / `B.md` | Certificate enrollment/renewal issues |
| `Troubleshooting/UserProfile-A.md` / `B.md` | Profile corruption, load failures |
| `Troubleshooting/PrintSpooler-A.md` / `B.md` | Print spooler crashes, queue issues |
| `Troubleshooting/DeliveryOptimization-A.md` / `B.md` | Peer-to-peer update distribution issues |
| `Troubleshooting/Time/TimeSync A.md` / `TimeSync B.md` | AADJ time sync — Local CMOS Clock, policy/network edge cases |
| `Troubleshooting/Time/Can't sync time.windows.com.md` | Specific "ping works, NTP doesn't" scenario walkthrough |
| `Scripts/Get-NetworkAdapterDiagnostics.ps1` | Companion script to NetworkAdapters — adapter/driver/routing/NLA sweep, CSV export |
| `Scripts/Get-TimeSyncDiagnostics.ps1` | Companion script to Time/TimeSync — W32Time/policy/NTP reachability sweep, CSV export |
| `Scripts/Get-DNSClientDiagnostics.ps1` | Companion script to DNS-Client |
| `Scripts/Get-DHCPClientDiagnostics.ps1` | Companion script to DHCP-Client |
| `Scripts/Get-RDPDiagnostics.ps1` | Companion script to RDP |
| `Scripts/Get-SMBDiagnostics.ps1` | Companion script to SMB |
| `Scripts/Get-FirewallDiagnostics.ps1` | Companion script to Firewall |
| `Scripts/Get-GPOReport.ps1` | Companion script to GPO |
| `Scripts/Get-KerberosDiagnostics.ps1` | Companion script to Kerberos |
| `Scripts/Get-NTLMDiagnostics.ps1` | Companion script to NTLM |
| `Scripts/Get-AppLockerDiagnostics.ps1` | Companion script to AppLocker |
| `Scripts/Get-WMIDiagnostics.ps1` | Companion script to WMI |
| `Scripts/Get-EventLogDiagnostics.ps1` | Companion script to EventLog |
| `Scripts/Get-CredentialManagerDiagnostics.ps1` | Companion script to CredentialManager |
| `Scripts/Get-CertificateServicesDiagnostics.ps1` | Companion script to CertificateServices |
| `Scripts/Get-UserProfileDiagnostics.ps1` | Companion script to UserProfile |
| `Scripts/Get-PrinterDiagnostics.ps1` | Companion script to PrintSpooler |
| `Scripts/Get-DeliveryOptimizationDiagnostics.ps1` | Companion script to DeliveryOptimization |
| `Scripts/Get-BitLockerStatus.ps1` | Companion script to BitLocker |
| `Scripts/Get-NetworkUnlockReadinessAudit.ps1` | Companion script to Network Unlock — auto-detects client vs. WDS server role and audits the relevant half of the dependency stack |
| `Scripts/Enable-VBS.ps1` | Legacy remediation-only snippet for VBS-CredentialGuard (enables VBS/Credential Guard via registry, no diagnostics) |
| `Scripts/Get-VBSCredentialGuardStatus.ps1` | Diagnostic companion script to VBS-CredentialGuard — hardware prerequisites, Win32_DeviceGuard WMI status, lsaiso.exe check, MDM/registry policy state, CodeIntegrity/Operational HVCI block-event scan |
| `Scripts/Test-VPNConnectivity.ps1` | Companion script to AlwaysOnVPN |
| `Scripts/WindowsUpdateModule.ps1` / `Update-AllWindows.ps1` / `WindowsUpdateTool-25h2-A.ps1` | Companion scripts to Windows Update topics |
| `Scripts/Setup-Apps.ps1` / `USB-Diagnostics.ps1` | General utility scripts (not tied to a single topic) |

---

## Before responding, also check

- `Intune/` — if the Windows setting is being managed via MDM policy
- `EntraID/` — if the issue is authentication or device join related
- `Security/Defender/` — if Windows security features (ASR, Tamper Protection) are involved

---

## Key first commands

```powershell
# System health baseline — run first on any Windows issue
Get-ComputerInfo | Select WindowsProductName, WindowsVersion, OsArchitecture, TotalPhysicalMemory

# Windows Update status
Get-WindowsUpdateLog
(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().GetTotalHistoryCount()

# Check what MDM policies are applied
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" |
  Where-Object { $_.Level -le 3 } | Select TimeCreated, Id, Message -First 10

# System event errors last 24h
Get-WinEvent -LogName System |
  Where-Object { $_.LevelDisplayName -in "Error","Critical" -and $_.TimeCreated -gt (Get-Date).AddHours(-24) } |
  Select TimeCreated, Id, ProviderName, Message | Format-Table -Wrap
```

---

## Common entry points

- "Windows Update stuck / won't install" → `Troubleshooting/Windows Update/`
- "WSUS conflict after moving to WfUB / Intune" → `Troubleshooting/Windows Update/WSUS to WfUB B.md`
- "BitLocker recovery key not in Entra" → check Intune BitLocker policy + device escrow
- "BitLocker still prompts for PIN on wired domain-joined desktops/servers even though Network Unlock is configured" → `Troubleshooting/BitLocker/NetworkUnlock-B.md` (hotfix) / `NetworkUnlock-A.md` (deep dive — on-prem AD/WDS only, no Entra equivalent) + `Scripts/Get-NetworkUnlockReadinessAudit.ps1`
- "App blocked after WDAC/AppLocker deployed" → audit logs, policy mode check
- "Time sync failing / source shows Local CMOS Clock / ping works but NTP doesn't" → `Troubleshooting/Time/TimeSync B.md` (hotfix) / `TimeSync A.md` (deep dive — W32Time architecture, policy layer, STS) + `Scripts/Get-TimeSyncDiagnostics.ps1`
- "Device on APIPA / no IP / DHCP not working" → `Troubleshooting/DHCP-Client-B.md` (hotfix) / `DHCP-Client-A.md` (deep dive, relay/scope architecture)
- "NIC disabled/missing, adapter shows Limited Connectivity, VPN eating all traffic, MTU/jumbo frame issue" → `Troubleshooting/NetworkAdapters-B.md` (hotfix) / `NetworkAdapters-A.md` (deep dive — NDIS stack, LBFO teaming) + `Scripts/Get-NetworkAdapterDiagnostics.ps1`
- "USB device being blocked by policy" → Intune Device Control policy + Windows event log
- "VBS/Credential Guard not running, BSOD after enabling VBS, HVCI driver conflict" → `Troubleshooting/VBS-CredentialGuard-B.md` (hotfix) / `VBS-CredentialGuard-A.md` (deep dive) + `Scripts/Get-VBSCredentialGuardStatus.ps1` (diagnostic) / `Scripts/Enable-VBS.ps1` (legacy remediation-only registry snippet)
- "Kerberos auth failing / NTLM fallback" → `Troubleshooting/Kerberos-B.md` + `Scripts/Get-KerberosDiagnostics.ps1`
- "Can't access a file share / SMB errors" → `Troubleshooting/SMB-B.md` + `Scripts/Get-SMBDiagnostics.ps1`
- "App or port blocked by firewall" → `Troubleshooting/Firewall-B.md` + `Scripts/Get-FirewallDiagnostics.ps1`
- "Can't RDP / RDP connection refused or times out" → `Troubleshooting/RDP-B.md` + `Scripts/Get-RDPDiagnostics.ps1`
- "Events missing / log full / log corrupted" → `Troubleshooting/EventLog-B.md` + `Scripts/Get-EventLogDiagnostics.ps1`
- "App blocked, need to know which AppLocker rule / AppIDSvc stopped" → `Troubleshooting/AppLocker-B.md` + `Scripts/Get-AppLockerDiagnostics.ps1`
- "Name won't resolve / internal names fail but public works / DNS cache stale" → `Troubleshooting/DNS-Client-B.md` (hotfix) / `DNS-Client-A.md` (deep dive — resolver chain, NRPT, DoH) + `Scripts/Get-DNSClientDiagnostics.ps1`
- "NTLM auth failing / trust relationship broken / 0x80070005 Access Denied" → `Troubleshooting/NTLM-B.md` (hotfix) / `NTLM-A.md` (deep dive — NTLM protocol, secure channel, LM level hardening) + `Scripts/Get-NTLMDiagnostics.ps1`

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — isolate to OS layer vs policy layer → apply fix → validate
2. **Deep Dive** — Windows architecture context, MDM vs GPO interaction, registry paths
3. **Learning Pointers** — what to explore to understand the system better
