# EZAdmin — Build Manifest
> Tracks what has been built, what's in progress, and what's queued.
> Updated automatically by each build agent/task. Do not edit manually.

---

## Status Key
- ✅ Done
- 🔄 In Progress
- ⬜ Queued
- ⭐ High Priority

---

## Foundation
| File | Status |
|------|--------|
| `AGENT_INDEX.md` | ✅ |
| `DFS/_AGENT.md` | ✅ |
| `PowerAutomate/_AGENT.md` | ✅ |
| `Intune/_AGENT.md` | ✅ |
| `EntraID/_AGENT.md` | ✅ |
| `Security/ConditionalAccess/_AGENT.md` | ✅ |
| `Autopilot/_AGENT.md` | ✅ |
| `Windows/_AGENT.md` | ✅ |
| `M365/_AGENT.md` | ✅ |
| `macOS/_AGENT.md` | ✅ |

---

## DFS
| File | Status | Assigned |
|------|--------|---------|
| `DFS/Troubleshooting/Namespace/Namespace-B.md` | ✅ | - |
| `DFS/Troubleshooting/Namespace/Namespace-A.md` | ✅ | - |
| `DFS/Troubleshooting/Replication/Replication-B.md` | ✅ | - |
| `DFS/Troubleshooting/Replication/Replication-A.md` | ✅ | - |
| `DFS/Scripts/Test-DFSHealth.ps1` | ✅ | - |
| `DFS/Scripts/Get-DFSRBacklog.ps1` | ✅ | - |

---

## Power Automate
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/SharePoint/SharePoint-Site-Provisioning-B.md` | ✅ | - |
| `PowerAutomate/SharePoint/SharePoint-Site-Provisioning-A.md` | ✅ | Task-7 |
| `PowerAutomate/SharePoint/Permission-Management-B.md` | ✅ | - |
| `PowerAutomate/Troubleshooting/Connector-Auth-B.md` | ✅ | - |
| `PowerAutomate/Troubleshooting/Throttling-Limits-B.md` | ✅ | - |
| `PowerAutomate/Scripts/New-SharePointSiteViaGraph.ps1` | ✅ | - |
| `PowerAutomate/Scripts/Set-SharePointSitePermissions.ps1` | ✅ | Task-7 |

---

## Intune
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Enrollment-B.md` | ✅ | - |
| `Intune/Troubleshooting/Enrollment-A.md` | ✅ | Task-2 |
| `Intune/Troubleshooting/Policy-Conflict-B.md` | ✅ | - |
| `Intune/Troubleshooting/Policy-Conflict-A.md` | ✅ | - |
| `Intune/Troubleshooting/App-Deployment-B.md` | ✅ | - |
| `Intune/Troubleshooting/App-Deployment-A.md` | ✅ | auto-build |
| `Intune/Scripts/Get-IntuneDeviceStatus.ps1` | ✅ | Agent-1 |
| `Intune/Scripts/Invoke-IntuneSync.ps1` | ✅ | Task-1 |
| `Intune/Reporting/Get-NonCompliantDevices.ps1` | ✅ | Task-1 |

---

## Entra ID
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/HybridJoin-B.md` | ✅ | - |
| `EntraID/Troubleshooting/HybridJoin-A.md` | ✅ | - |
| `EntraID/Troubleshooting/PRT-Issues-B.md` | ✅ | - |
| `EntraID/Scripts/Get-EntraDeviceHealth.ps1` | ✅ | - |
| `EntraID/Scripts/Get-EntraConnectSyncErrors.ps1` | ✅ | - |
| `EntraID/Graph/Useful-Queries.md` | ✅ | - |

---

## Windows
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Scripts/WindowsUpdateTool-25h2-A.ps1` | ✅ | - |
| `Windows/Troubleshooting/Time/` (existing) | ✅ | - |
| `Windows/Troubleshooting/Windows Update/` (existing) | ✅ | - |
| `Windows/Troubleshooting/BitLocker/BitLocker-B.md` | ✅ | - |
| `Windows/Troubleshooting/BitLocker/BitLocker-A.md` | ✅ | - |
| `Windows/Troubleshooting/VBS-CredentialGuard-B.md` | ✅ | Task-4 |
| `Windows/Scripts/Get-BitLockerStatus.ps1` | ✅ | auto-build |
| `Windows/Troubleshooting/DNS-Client-B.md` | ✅ | auto-build |

---

## Security — Conditional Access
| File | Status | Assigned |
|------|--------|---------|
| `Security/ConditionalAccess/CA-Troubleshooting-B.md` | ✅ | - |
| `Security/ConditionalAccess/CA-Design-A.md` | ✅ | Task-4 |
| `Security/ConditionalAccess/Scripts/Get-CASignInAnalysis.ps1` | ✅ | Task-4 |
| `Security/ConditionalAccess/CA-Filters-B.md` | ✅ | auto-build |

---

## Security — Defender
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/_AGENT.md` | ✅ | Task-3 |
| `Security/Defender/MDE-Onboarding-B.md` | ✅ | Task-3 |
| `Security/Defender/ASR-Rules-B.md` | ✅ | Task-3 |
| `Security/Defender/Tamper-Protection-B.md` | ✅ | Task-3 |

---

## Security — Purview
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/_AGENT.md` | ✅ | Task-4 |
| `Security/Purview/DLP-Policy-B.md` | ✅ | Task-4 |

---

## M365 — Exchange
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/_AGENT.md` | ✅ | - |
| `M365/Exchange/Mail-Flow-B.md` | ✅ | - |
| `M365/Exchange/Mail-Flow-A.md` | ✅ | Task-6 |
| `M365/Exchange/SharedMailbox-B.md` | ✅ | - |
| `M365/Exchange/SharedMailbox-A.md` | ✅ | auto-build |
| `M365/Exchange/Hybrid-Coexistence-B.md` | ✅ | Task-6 |
| `M365/Exchange/Scripts/Get-ExchangeHybridHealth.ps1` | ✅ | auto-build |

---

## M365 — SharePoint & OneDrive
| File | Status | Assigned |
|------|--------|---------|
| `M365/SharePoint-OneDrive/_AGENT.md` | ✅ | Task-6 |
| `M365/SharePoint-OneDrive/Sync-Issues-B.md` | ✅ | Task-6 |
| `M365/SharePoint-OneDrive/Permissions-B.md` | ✅ | Task-6 |

---

## M365 — Teams
| File | Status | Assigned |
|------|--------|---------|
| `M365/Teams/_AGENT.md` | ✅ | Task-6 |
| `M365/Teams/Calling-B.md` | ✅ | Task-6 |
| `M365/Teams/Device-Policies-B.md` | ✅ | Task-6 |

---

## M365 — Licensing
| File | Status | Assigned |
|------|--------|---------|
| `M365/Licensing/_AGENT.md` | ✅ | Task-6 |
| `M365/Licensing/License-Assignment-B.md` | ✅ | Task-6 |
| `M365/Licensing/Group-Based-Licensing-B.md` | ✅ | Task-6 |

---

## Autopilot
| File | Status | Assigned |
|------|--------|---------|
| `Autopilot/Scripts/Get-EnrollmentLogs.ps1` | ✅ | - |
| `Autopilot/Scripts/Upload-AutopilotDiagnostics.ps1` | ✅ | - |
| `Autopilot/Scripts/Upload-Hash-Enroll2Autopilot.ps1` | ✅ | - |
| `Autopilot/Troubleshooting/Autopilot-Network-Connectivity.ps1` | ✅ | - |
| `Autopilot/Troubleshooting/Profile-Not-Assigned-B.md` | ✅ | - |
| `Autopilot/Troubleshooting/ESP-Stuck-B.md` | ✅ | - |
| `Autopilot/Troubleshooting/HybridJoin-Autopilot-B.md` | ✅ | Task-5 |
| `Autopilot/Troubleshooting/TPM-Attestation-B.md` | ✅ | Task-5 |
| `Autopilot/Scripts/Get-AutopilotDeviceStatus.ps1` | ✅ | Task-5 |

---

## macOS
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/ADE-Enrollment-B.md` | ✅ | Task-5 |
| `macOS/Troubleshooting/Shell-Script-Failures-B.md` | ✅ | auto-build |
| `macOS/Scripts/Get-MacIntuneStatus.sh` | ✅ | auto-build |

---

## Modules
| File | Status | Assigned |
|------|--------|---------|
| `Modules/PsAdminModules.ps1` | ✅ | - |

---

## Intune — Expansion
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/LAPS-B.md` | ✅ | auto-build |

---

## Entra ID — Expansion
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/Connect-Sync-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/Connect-Sync-A.md` | ✅ | auto-build |

---

## Windows — Expansion
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/AlwaysOnVPN-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/AlwaysOnVPN-A.md` | ✅ | auto-build |

---

## Security — Defender Expansion
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/WDAC-B.md` | ✅ | auto-build |
| `Security/Defender/WDAC-A.md` | ✅ | auto-build |

---

## Intune — Expansion (continued)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/GP-to-CSP-B.md` | ✅ | auto-build |

---

## M365 — Universal Print
| File | Status | Assigned |
|------|--------|---------|
| `M365/UniversalPrint/Universal-Print-B.md` | ✅ | auto-build |
| `M365/UniversalPrint/Universal-Print-A.md` | ✅ | auto-build |

---

## Entra ID — WHfB
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/WHfB-B.md` | ✅ | auto-build |

---

## Intune — EPM
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/EPM-B.md` | ✅ | auto-build |

---

## Entra ID — App Proxy
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/AppProxy-B.md` | ✅ | auto-build |

---

## M365 — Teams Rooms
| File | Status | Assigned |
|------|--------|---------|
| `M365/Teams/Teams-Rooms-B.md` | ✅ | auto-build |

---

## Intune — Co-Management
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/CoManagement-B.md` | ✅ | auto-build |

---

## Entra ID — WHfB Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/WHfB-A.md` | ✅ | auto-build |

---

## Security — Purview DLP Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/DLP-Policy-A.md` | ✅ | auto-build |

---

## Intune — LAPS Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/LAPS-A.md` | ✅ | auto-build |

---

## Intune — Remediations
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Remediations-B.md` | ✅ | auto-build |

---

## Security — Defender MDE Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/MDE-Onboarding-A.md` | ✅ | auto-build |

---

## M365 — Exchange Hybrid Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/Hybrid-Coexistence-A.md` | ✅ | auto-build |

---

## Security — Defender ASR Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/ASR-Rules-A.md` | ✅ | auto-build |

---

## Intune — Co-Management Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/CoManagement-A.md` | ✅ | auto-build |

---

## Entra ID — B2B Guest Scripts
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Scripts/Get-EntraB2BGuestReport.ps1` | ✅ | auto-build |

---

## Entra ID — PRT Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/PRT-Issues-A.md` | ✅ | auto-build |

---

## Intune — Remediations Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Remediations-A.md` | ✅ | auto-build |

---

## Security — Defender Scripts
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/Scripts/Get-MDEDeviceStatus.ps1` | ✅ | auto-build |

---

## Windows — VBS Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/VBS-CredentialGuard-A.md` | ✅ | auto-build |

---

## Intune — EPM Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/EPM-A.md` | ✅ | auto-build |

---

## macOS — Platform SSO
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/Platform-SSO-B.md` | ✅ | auto-build |

---

## M365 — Exchange Scripts
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/Scripts/Get-MailboxAuditReport.ps1` | ✅ | auto-build |

---

## M365 — SharePoint & OneDrive Deep Dives
| File | Status | Assigned |
|------|--------|---------|
| `M365/SharePoint-OneDrive/Sync-Issues-A.md` | ✅ | auto-build |

---

## Autopilot — ESP Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Autopilot/Troubleshooting/ESP-Stuck-A.md` | ✅ | auto-build |

---

## M365 — Teams Scripts
| File | Status | Assigned |
|------|--------|---------|
| `M365/Teams/Scripts/Get-TeamsCallQuality.ps1` | ✅ | auto-build |

---

---

## Intune — Certificate Deployment
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Certificates-B.md` | ✅ | auto-build |

---

## macOS — ADE Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/ADE-Enrollment-A.md` | ✅ | auto-build |

---

## Security — Purview Scripts
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/Scripts/Get-PurviewDLPReport.ps1` | ✅ | auto-build |

---

## Intune — Certificate Deployment Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Certificates-A.md` | ✅ | auto-build |

---

## macOS — Platform SSO Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/Platform-SSO-A.md` | ✅ | auto-build |

---

## Entra ID — Graph API Batch Operations
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Scripts/Invoke-GraphBatchQuery.ps1` | ✅ | auto-build |

---

## M365 — Licensing Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `M365/Licensing/License-Assignment-A.md` | ✅ | auto-build |

---

## Autopilot — TPM Attestation Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Autopilot/Troubleshooting/TPM-Attestation-A.md` | ✅ | auto-build |

---

## macOS — Shell Script Failures Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/Shell-Script-Failures-A.md` | ✅ | auto-build |

---

---

## Entra ID — App Proxy Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/AppProxy-A.md` | ✅ | auto-build |

---

## M365 — SharePoint Permissions Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `M365/SharePoint-OneDrive/Permissions-A.md` | ✅ | auto-build |

---

## Security — Purview Sensitivity Labels
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/Sensitivity-Labels-B.md` | ✅ | auto-build |
| `Security/Purview/Sensitivity-Labels-A.md` | ✅ | auto-build |

---

## M365 — Teams Calling Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `M365/Teams/Calling-A.md` | ✅ | auto-build |

---

## Intune — GP-to-CSP Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/GP-to-CSP-A.md` | ✅ | auto-build |

---

## M365 — Licensing Deep Dive (A variant)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Licensing/Group-Based-Licensing-A.md` | ✅ | auto-build |

---

## Security — Defender Tamper Protection Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/Tamper-Protection-A.md` | ✅ | auto-build |

---

## M365 — Teams Rooms Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `M365/Teams/Teams-Rooms-A.md` | ✅ | auto-build |

---

## Power Automate — Throttling Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/Troubleshooting/Throttling-Limits-A.md` | ✅ | auto-build |

---

## macOS — FileVault Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/FileVault-A.md` | ✅ | auto-build |

---

## M365 — SharePoint Scripts
| File | Status | Assigned |
|------|--------|---------|
| `M365/SharePoint-OneDrive/Scripts/Get-SharePointSiteReport.ps1` | ✅ | auto-build |

---

## Autopilot — Profile Not Assigned Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Autopilot/Troubleshooting/Profile-Not-Assigned-A.md` | ✅ | auto-build |

---

## Entra ID — External Identities Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/ExternalIdentities-A.md` | ✅ | auto-build |

---

## M365 — Universal Print Scripts
| File | Status | Assigned |
|------|--------|---------|
| `M365/UniversalPrint/Scripts/Get-UniversalPrintReport.ps1` | ✅ | auto-build |

---

---

## Security — Conditional Access Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Security/ConditionalAccess/CA-Troubleshooting-A.md` | ✅ | auto-build |

---

## Autopilot — Hybrid Join Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Autopilot/Troubleshooting/HybridJoin-Autopilot-A.md` | ✅ | auto-build |

---

## M365 — Licensing Scripts
| File | Status | Assigned |
|------|--------|---------|
| `M365/Licensing/Scripts/Get-LicenseReport.ps1` | ✅ | auto-build |

---

## M365 — Universal Print Agent
| File | Status | Assigned |
|------|--------|---------|
| `M365/UniversalPrint/_AGENT.md` | ✅ | auto-build |

---

## Windows — Print Spooler
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/PrintSpooler-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/PrintSpooler-A.md` | ✅ | auto-build |
| `Windows/Scripts/Get-PrinterDiagnostics.ps1` | ✅ | auto-build |

---

## Entra ID — SSPR
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/SSPR-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/SSPR-A.md` | ✅ | auto-build |

---

## Power Automate — SharePoint Permission Management Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/SharePoint/Permission-Management-A.md` | ✅ | auto-build |

---

## M365 — Exchange Online Protection (EOP)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/EOP-AntiSpam-B.md` | ✅ | auto-build |

---

## Windows — Always On VPN Scripts
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Scripts/Test-VPNConnectivity.ps1` | ✅ | auto-build |

---

## M365 — Exchange Online Protection Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/EOP-AntiSpam-A.md` | ✅ | auto-build |

---

## Intune — Assignment Filters
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Filters-B.md` | ✅ | auto-build |

---

## Security — Conditional Access Named Locations
| File | Status | Assigned |
|------|--------|---------|
| `Security/ConditionalAccess/Named-Locations-B.md` | ✅ | auto-build |

---

## Intune — Assignment Filters Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Filters-A.md` | ✅ | auto-build |

---

## Security — Conditional Access Named Locations Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Security/ConditionalAccess/Named-Locations-A.md` | ✅ | auto-build |

---

## Intune — Assignment Report Script
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Scripts/Get-IntuneAssignmentReport.ps1` | ✅ | auto-build |

---

## macOS — MDM Certificate Renewal
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/MDM-Certificate-Renewal-B.md` | ✅ | auto-build |

---

## Windows — AppLocker
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/AppLocker-B.md` | ✅ | auto-build |

---

## Windows — AppLocker Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/AppLocker-A.md` | ✅ | auto-build |

---

## macOS — MDM Certificate Renewal Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/MDM-Certificate-Renewal-A.md` | ✅ | auto-build |

---

## M365 — SharePoint On-Premises to SPO Migration
| File | Status | Assigned |
|------|--------|---------|
| `M365/SharePoint-OneDrive/Migration-B.md` | ✅ | auto-build |

---

## Windows — DNS Client
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/DNS-Client-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/DNS-Client-A.md` | ✅ | auto-build |

---

## Security — Defender Network Protection
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/NetworkProtection-B.md` | ✅ | auto-build |
| `Security/Defender/NetworkProtection-A.md` | ✅ | auto-build |

---

## Windows — Event Log
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/EventLog-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/EventLog-A.md` | ✅ | auto-build |

---

## Intune — Scope Tags & RBAC
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/ScopeTags-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/ScopeTags-A.md` | ✅ | auto-build |

---

## Windows — Network Adapters
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/NetworkAdapters-B.md` | ✅ | auto-build |

---

## M365 — Exchange Scripts (Message Trace)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/Scripts/Get-MessageTrace.ps1` | ✅ | auto-build |

---

## Security — Defender Vulnerability Management (untracked backfill)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/DefenderVulnMgmt-B.md` | ✅ | auto-build |
| `Security/Defender/DefenderVulnMgmt-A.md` | ✅ | auto-build |

---

---

## Windows — Network Adapters Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/NetworkAdapters-A.md` | ✅ | auto-build |

---

## M365 — SharePoint Migration Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `M365/SharePoint-OneDrive/Migration-A.md` | ✅ | auto-build |

---

## Security — Purview Insider Risk Management
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/Insider-Risk-B.md` | ✅ | auto-build |

---

## Security — Purview Insider Risk Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/Insider-Risk-A.md` | ✅ | auto-build |

---

## Security — Defender for Identity
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/MDI-B.md` | ✅ | auto-build |

---

## Intune — Windows Update for Business
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/WUfB-B.md` | ✅ | auto-build |

---

---

## Azure Virtual Desktop
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/AVD-B.md` | ✅ | auto-build |
| `Azure/AVD/AVD-A.md` | ✅ | auto-build |

---

## Intune — WUfB Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/WUfB-A.md` | ✅ | auto-build |

---

## Security — Defender for Identity Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/MDI-A.md` | ✅ | auto-build |

---

## M365 — Exchange Message Encryption (OME)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/MessageEncryption-B.md` | ✅ | auto-build |

---

## Windows — WMI Corruption
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/WMI-B.md` | ✅ | auto-build |

---

## Windows — WMI Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/WMI-A.md` | ✅ | auto-build |

---

## M365 — Exchange Message Encryption Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/MessageEncryption-A.md` | ✅ | auto-build |

---

## Security — Conditional Access Filters Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Security/ConditionalAccess/CA-Filters-A.md` | ✅ | auto-build |

---

## Entra ID — PIM (Privileged Identity Management)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/PIM-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/PIM-A.md` | ✅ | auto-build |

---

## M365 — Exchange Archive & Retention
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/ArchiveRetention-B.md` | ✅ | auto-build |
| `M365/Exchange/ArchiveRetention-A.md` | ✅ | auto-build |

---

## Windows — User Profile Corruption
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/UserProfile-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/UserProfile-A.md` | ✅ | auto-build |

---

## Security — Purview eDiscovery
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/eDiscovery-B.md` | ✅ | auto-build |
| `Security/Purview/eDiscovery-A.md` | ✅ | auto-build |

---

## Power Automate — DLP Policies
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/Troubleshooting/DLP-Policies-B.md` | ✅ | auto-build |
| `PowerAutomate/Troubleshooting/DLP-Policies-A.md` | ✅ | auto-build |

---

## Windows — User Profile Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/UserProfile-A.md` | ✅ | auto-build |

---

## Azure Virtual Desktop — Agent & Scripts (expansion)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/_AGENT.md` | ✅ | auto-build |
| `Azure/AVD/Scripts/Get-AVDSessionHealth.ps1` | ✅ | auto-build |

---

## Windows — Kerberos Authentication (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/Kerberos-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/Kerberos-A.md` | ✅ | auto-build |

---

## Intune — Driver Management (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/DriverManagement-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/DriverManagement-A.md` | ✅ | auto-build |

---

## Windows — NTLM Authentication
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/NTLM-B.md` | ✅ | auto-build |

---

## Security — Defender Cloud Protection
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/CloudProtection-B.md` | ✅ | auto-build |

---

## Security — Defender Cloud Protection Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/CloudProtection-A.md` | ✅ | auto-build |

---

## Windows — NTLM Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/NTLM-A.md` | ✅ | auto-build |

---

## Windows — SMB File Share Access
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/SMB-B.md` | ✅ | auto-build |

---

## Windows — SMB Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/SMB-A.md` | ✅ | auto-build |

---

## Azure AVD — FSLogix Profiles
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/FSLogix-B.md` | ✅ | auto-build |

---

## Entra ID — PIM Audit Script
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Scripts/Get-PIMReport.ps1` | ✅ | auto-build |

---

## Azure AVD — FSLogix Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/FSLogix-A.md` | ✅ | auto-build |

---

## Windows — RDP Troubleshooting
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/RDP-B.md` | ✅ | auto-build |

---

## Intune — Security Baselines
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Security-Baselines-B.md` | ✅ | auto-build |

---

## Windows — RDP Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/RDP-A.md` | ✅ | auto-build |

---

## Intune — Security Baselines Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Security-Baselines-A.md` | ✅ | auto-build |

---

## Azure AVD — Network Connectivity (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/AVD-Connectivity-B.md` | ✅ | auto-build |

---

## Build Progress
- Total files: 218
- Completed: 218
- In progress: 0
- Queued: 0
- Last updated: 2026-06-27 (auto-build: RDP-A, Security-Baselines-A, AVD-Connectivity-B)
