# Windows — Agent Instructions

## What's in this folder

Windows OS-level issues — update management, security features, performance, networking, and peripheral management.

Covers:
- **Windows Update / WfUB** — WSUS conflicts, dual-scan, update rings, stuck updates, 24H2 upgrade issues
- **BitLocker** — key escrow to Entra, recovery, policy enforcement, suspension
- **VBS / Credential Guard / HVCI** — enabling, conflicts with legacy apps/hypervisors
- **LSA Protection (RunAsPPL)** — VBS-independent PPL protection for lsass.exe, Windows 11 22H2+ silent auto-enablement, blocked smart card/VPN/password-filter plug-ins
- **AppLocker / WDAC** — application control, policy audit mode, blocking legitimate apps
- **Networking** — DNS, DHCP (client and Windows Server DHCP role), proxy, time sync, VPN coexistence
- **DHCP Server role** — scope/superscope architecture, DHCP Failover (hot standby/load balance, MCLT/split-brain safety), DHCP Policies, secure dynamic DNS update credential, JET database backup/repair, audit logging
- **NPS / RADIUS server** — Network Policy Server as RADIUS server/proxy for VPN (RRAS/AlwaysOnVPN) and 802.1X wired/wireless auth, connection request vs. network policy evaluation, NPS Extension for Entra MFA
- **Hyper-V host & VM** — standalone/clustered Hyper-V role, VM state and Integration Services, checkpoints/differencing disks (AVHDX), virtual switches, Live Migration (auth modes, Event ID 21502 family), Failover Clustering integration (CSV, quorum), Hyper-V Replica DR
- **Storage Spaces Direct (S2D)** — hyperconverged storage pool/virtual disk/physical disk health, cache-tier vs. capacity-tier architecture, resiliency types (mirror/parity/nested), Health Service auto-repair, drive replacement, storage-network (RDMA) dependency
- **Volume Shadow Copy Service (VSS)** — requestor/writer/provider snapshot architecture, writer state and freeze/thaw timeout failures, shadow storage exhaustion, SQL Server VSS writer isolation, "Previous Versions" and backup-product dependency
- **Windows Server Failover Clustering (WSFC)** — quorum theory and voting mechanics, disk/file share/cloud witness types, dynamic quorum management, cluster networking (heartbeat, Partitioned vs. Down), node quarantine (Health Service auto-isolation), cluster validation, Cluster-Aware Updating (CAU) — the foundation layer underneath Hyper-V clustering and Storage Spaces Direct
- **WSUS Server role** — SUSDB maintenance (WID vs. full SQL Server engine, reindex, decline-superseded, cleanup), content/metadata consistency (wsusutil checkhealth/reset), IIS WsusPool health (the most common real-world WSUS outage cause), multi-tier hierarchy maintenance ordering — server-side complement to the client-side WSUS-to-WfUB migration topic
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
| `Troubleshooting/LSA-Protection-A.md` / `B.md` | LSA Protection (RunAsPPL) — VBS-independent PPL mechanism, Win11 22H2+ silent auto-enablement (no registry trace), blocked smart card/VPN/password-filter plug-ins, UEFI-locked recovery |
| `Troubleshooting/AppLocker-A.md` / `B.md` | Application control policy, audit mode, blocked-app diagnosis |
| `Troubleshooting/DNS-Client-A.md` / `B.md` | Resolver chain, NRPT, DoH, cache/HOSTS issues |
| `Troubleshooting/DHCP-Client-A.md` / `B.md` | DHCP lease failure, APIPA, relay/scope architecture (client-side) |
| `Troubleshooting/DHCP-Server-A.md` / `B.md` | Windows Server DHCP role — scope/superscope exhaustion, DHCP Failover (hot standby/load balance, MCLT), DHCP Policies, secure dynamic DNS update credential expiry, JET database corruption/backup/restore, audit logging (server-side) |
| `Troubleshooting/NetworkAdapters-A.md` / `B.md` | NIC/driver/NDIS stack, routing conflicts, LBFO teaming, MTU issues |
| `Troubleshooting/AlwaysOnVPN-A.md` / `B.md` | Always On VPN device/user tunnel, IKEv2/SSTP negotiation |
| `Troubleshooting/NPS-RADIUS-A.md` / `B.md` | Network Policy Server as RADIUS server/proxy — connection request vs. network policy evaluation, RADIUS client registration, cross-forest proxy requirements, NPS Extension for Entra MFA (PAP vs. CHAPv2/EAP method gating) |
| `Troubleshooting/HyperV-A.md` / `B.md` | Hyper-V host & VM — VM state/Integration Services, checkpoint/AVHDX chain failures, virtual switch architecture, Live Migration (Kerberos/CredSSP, Event ID 21502 family), Failover Clustering (CSV, quorum, possible-owner nodes), Hyper-V Replica (HRL growth, resync) |
| `Troubleshooting/StorageSpacesDirect-A.md` / `B.md` | Storage Spaces Direct — pool/virtual disk/physical disk health states, cache-tier vs. capacity-tier, resiliency types (mirror/parity/nested), Health Service auto-repair, drive replacement, quorum (pool-level, distinct from cluster quorum), storage-network (RDMA) dependency |
| `Troubleshooting/VSS-A.md` / `B.md` | Volume Shadow Copy Service — requestor/writer/provider architecture, writer freeze/thaw timeout failures, shadow storage exhaustion, SQL Server VSS writer isolation (SQLWRITER/SQLVDI), "no writers listed" VSS/COM+ registration repair |
| `Troubleshooting/FailoverClustering-A.md` / `B.md` | Windows Server Failover Clustering (WSFC) — quorum voting mechanics, disk/file share/cloud witness types, dynamic quorum management, cluster networking (Partitioned vs. Down), node quarantine (Health Service auto-isolation, Event IDs 1641/1647/1649/7031), Cluster-Aware Updating |
| `Troubleshooting/Windows Update/WSUS-Server-A.md` / `B.md` | WSUS server role — SUSDB engine (WID vs. SQL Server) and maintenance (reindex, decline-superseded, cleanup), content/metadata consistency (wsusutil checkhealth/reset), IIS WsusPool memory-exhaustion crashes, hierarchy maintenance ordering |
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
| `Scripts/Get-DHCPServerHealth.ps1` | Companion script to DHCP-Server — authorization/service state, scope utilization exhaustion flagging, Failover relationship state, DHCP Policy inventory, DNS dynamic update credential password-expiry check, JET/database event log scan, audit log freshness check |
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
| `Scripts/Get-LSAProtectionStatus.ps1` | Diagnostic companion script to LSA-Protection — WinInit Event ID 12 ground-truth check (registry-independent), auto-enablement criteria evaluation, CodeIntegrity blocked/audit plug-in event scan, Smart App Control state |
| `Scripts/Test-VPNConnectivity.ps1` | Companion script to AlwaysOnVPN |
| `Scripts/Get-AlwaysOnVPNDiagnostics.ps1` | Automates AlwaysOnVPN-A.md's Validation Steps in one pass: BFE→IKEEXT→RasMan→RasAuto service chain, WAN Miniport adapter state, machine/user cert expiry (30-day warning), live ProfileXML read, recent VPN-Client/Operational events, optional gateway TCP-443 test, NAT-T registry state (client-side only) |
| `Scripts/Get-NPSHealthAudit.ps1` | Companion script to NPS-RADIUS — service/auditing state, RADIUS client and policy inventory, 6272/6273/6274/13/18 event summary, DC reachability, Entra MFA extension registry/connectivity check |
| `Scripts/Get-HyperVHealth.ps1` | Companion script to HyperV — VMMS/VM/Integration Services state, checkpoint chain depth and orphan detection, virtual switch inventory, cluster/quorum/CSV health, VM cluster resource possible-owner check, Replica health, VMMS/Worker event scan |
| `Scripts/Get-S2DHealthAudit.ps1` | Companion script to StorageSpacesDirect — S2D enablement, pool/virtual disk/physical disk health (cache-tier flagged separately), CannotPoolReason detection, storage job stall detection, cluster node and RDMA storage-network health, StorageSpaces-Driver event scan |
| `Scripts/Get-VSSWriterHealth.ps1` | Companion script to VSS — VSS/COM+ Event System service state, writer inventory and state (parsed from vssadmin), shadow storage headroom, provider inventory, VSS/SQLWRITER/SQLVDI Application-log error scan |
| `Scripts/Get-FailoverClusterHealth.ps1` | Companion script to FailoverClustering — node state/DynamicWeight/quarantine, quorum type and witness resource health, cluster network state (flags Partitioned distinctly from Down), quorum/quarantine/network/storage event scan, CAU role presence |
| `Scripts/Get-WSUSServerHealth.ps1` | Companion script to WSUS-Server — WsusService/W3SVC state, WsusPool state and memory-limit/rapid-fail configuration, SUSDB engine identification (WID vs. SQL Server), content volume disk space, optional wsusutil checkhealth, WSUS Application-log error scan |
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
- "Device on APIPA / no IP / DHCP not working" → `Troubleshooting/DHCP-Client-B.md` (hotfix) / `DHCP-Client-A.md` (deep dive, relay/scope architecture — client-side)
- "DHCP scope exhausted, Failover partner shows PartnerDown/CommunicationInterrupted, DNS records not registering for new devices, DHCP database corrupt / jetpack repair, superscope/split-scope imbalance" → `Troubleshooting/DHCP-Server-B.md` (hotfix — start here) / `DHCP-Server-A.md` (deep dive — Failover MCLT model, DHCP Policies, DnsServerDnsCredential, JET database internals) + `Scripts/Get-DHCPServerHealth.ps1`
- "NIC disabled/missing, adapter shows Limited Connectivity, VPN eating all traffic, MTU/jumbo frame issue" → `Troubleshooting/NetworkAdapters-B.md` (hotfix) / `NetworkAdapters-A.md` (deep dive — NDIS stack, LBFO teaming) + `Scripts/Get-NetworkAdapterDiagnostics.ps1`
- "USB device being blocked by policy" → Intune Device Control policy + Windows event log
- "VBS/Credential Guard not running, BSOD after enabling VBS, HVCI driver conflict" → `Troubleshooting/VBS-CredentialGuard-B.md` (hotfix) / `VBS-CredentialGuard-A.md` (deep dive) + `Scripts/Get-VBSCredentialGuardStatus.ps1` (diagnostic) / `Scripts/Enable-VBS.ps1` (legacy remediation-only registry snippet)
- "Smart card login / VPN client auth / password filter broken after a Windows 11 upgrade, registry shows RunAsPPL off but engineer suspects it's actually on, LSASS crash loop" → `Troubleshooting/LSA-Protection-B.md` (hotfix — start here, this is VBS-independent) / `LSA-Protection-A.md` (deep dive — PPL mechanism, auto-enablement, signing requirements) + `Scripts/Get-LSAProtectionStatus.ps1`
- "Kerberos auth failing / NTLM fallback" → `Troubleshooting/Kerberos-B.md` + `Scripts/Get-KerberosDiagnostics.ps1`
- "Can't access a file share / SMB errors" → `Troubleshooting/SMB-B.md` + `Scripts/Get-SMBDiagnostics.ps1`
- "App or port blocked by firewall" → `Troubleshooting/Firewall-B.md` + `Scripts/Get-FirewallDiagnostics.ps1`
- "Can't RDP / RDP connection refused or times out" → `Troubleshooting/RDP-B.md` + `Scripts/Get-RDPDiagnostics.ps1`
- "Events missing / log full / log corrupted" → `Troubleshooting/EventLog-B.md` + `Scripts/Get-EventLogDiagnostics.ps1`
- "App blocked, need to know which AppLocker rule / AppIDSvc stopped" → `Troubleshooting/AppLocker-B.md` + `Scripts/Get-AppLockerDiagnostics.ps1`
- "Name won't resolve / internal names fail but public works / DNS cache stale" → `Troubleshooting/DNS-Client-B.md` (hotfix) / `DNS-Client-A.md` (deep dive — resolver chain, NRPT, DoH) + `Scripts/Get-DNSClientDiagnostics.ps1`
- "NTLM auth failing / trust relationship broken / 0x80070005 Access Denied" → `Troubleshooting/NTLM-B.md` (hotfix) / `NTLM-A.md` (deep dive — NTLM protocol, secure channel, LM level hardening) + `Scripts/Get-NTLMDiagnostics.ps1`
- "VPN or 802.1X auth denied and it's not a client-side cert/ProfileXML problem, NPS event 6273/6274, RADIUS shared secret mismatch, Entra MFA extension error" → `Troubleshooting/NPS-RADIUS-B.md` (hotfix — start here, Reason Code lookup table) / `NPS-RADIUS-A.md` (deep dive — connection request vs. network policy model, RADIUS proxy/cross-forest requirements) + `Scripts/Get-NPSHealthAudit.ps1`
- "VM won't start / stuck / crashed, Live Migration fails (Event ID 21502), checkpoint won't merge, CSV shows Event ID 5120, Hyper-V Replica health Critical, cluster quorum lost taking VMs offline" → `Troubleshooting/HyperV-B.md` (hotfix — start here, Compare-VM first for migration issues) / `HyperV-A.md` (deep dive — CSV/quorum architecture, Live Migration auth modes, HRL mechanics) + `Scripts/Get-HyperVHealth.ps1`
- "S2D storage pool read-only / degraded, virtual disk Incomplete or Detached, drive shows Lost Communication, repair job stuck, new drive won't pool (CannotPoolReason)" → `Troubleshooting/StorageSpacesDirect-B.md` (hotfix — start here) / `StorageSpacesDirect-A.md` (deep dive — pool/cache-tier/resiliency architecture, pool quorum vs. cluster quorum) + `Scripts/Get-S2DHealthAudit.ps1`
- "Backup fails with a VSS error, vssadmin list writers shows a Failed writer, SQLWRITER/SQLVDI errors in the Application log, Previous Versions empty, shadow storage full" → `Troubleshooting/VSS-B.md` (hotfix — start here, restart the OWNING app service not VSS) / `VSS-A.md` (deep dive — requestor/writer/provider architecture, freeze/thaw timeout mechanics) + `Scripts/Get-VSSWriterHealth.ps1`
- "Cluster down / won't form quorum, a node is stuck Quarantined, witness resource offline, cluster network shows Partitioned, CAU run failing" → `Troubleshooting/FailoverClustering-B.md` (hotfix — start here) / `FailoverClustering-A.md` (deep dive — quorum voting math, witness types, node quarantine architecture) + `Scripts/Get-FailoverClusterHealth.ps1`
- "WSUS console won't open / unexpected error, clients stuck scanning or timing out (0x8024401C etc.), Cleanup Wizard always times out, content directory nearly full" → `Troubleshooting/Windows Update/WSUS-Server-B.md` (hotfix — start here, check WsusPool before SUSDB) / `WSUS-Server-A.md` (deep dive — SUSDB engine/maintenance, content/metadata consistency) + `Scripts/Get-WSUSServerHealth.ps1`

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — isolate to OS layer vs policy layer → apply fix → validate
2. **Deep Dive** — Windows architecture context, MDM vs GPO interaction, registry paths
3. **Learning Pointers** — what to explore to understand the system better
