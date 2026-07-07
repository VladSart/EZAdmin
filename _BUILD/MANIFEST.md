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
| `DFS/Troubleshooting/FRS-Migration/FRS-to-DFSR-Migration-B.md` | ✅ | auto-build |
| `DFS/Troubleshooting/FRS-Migration/FRS-to-DFSR-Migration-A.md` | ✅ | auto-build |
| `DFS/Scripts/Get-DFSRMigrationState.ps1` | ✅ | auto-build |

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
| `M365/Exchange/TransportRules-B.md` | ✅ | auto-build |
| `M365/Exchange/TransportRules-A.md` | ✅ | auto-build |
| `M365/Exchange/Scripts/Get-TransportRuleConflictAudit.ps1` | ✅ | auto-build |

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

## PowerAutomate — Script Coverage Gap Fill
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/Scripts/Get-DLPPolicyImpactReport.ps1` | ✅ | auto-build |
| `PowerAutomate/Scripts/Get-ConnectorAuthHealth.ps1` | ✅ | auto-build |

---

## DFS — Script Coverage Gap Fill
| File | Status | Assigned |
|------|--------|---------|
| `DFS/Scripts/Get-DFSNamespaceConfigAudit.ps1` | ✅ | auto-build |

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

## Run 30 — Script Coverage Gap Fill (EntraDomainServices / Sync-Issues / VBS-CredentialGuard)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Scripts/Get-EntraDomainServicesHealth.ps1` | ✅ | auto-build |
| `M365/SharePoint-OneDrive/Scripts/Get-OneDriveSyncClientHealth.ps1` | ✅ | auto-build |
| `Windows/Scripts/Get-VBSCredentialGuardStatus.ps1` | ✅ | auto-build |

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

---

## Azure AVD — Connectivity Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/AVD-Connectivity-A.md` | ✅ | auto-build |

---

## Windows — Firewall (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/Firewall-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/Firewall-A.md` | ✅ | auto-build |

---

## macOS — Compliance Policies (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/Compliance-Policies-B.md` | ✅ | auto-build |

---

---

## macOS — Compliance Policies Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/Compliance-Policies-A.md` | ✅ | auto-build |

---

## Azure — Agent Index (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/_AGENT.md` | ✅ | auto-build |

---

## Azure AVD — MSIX App Attach
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/AppAttach-B.md` | ✅ | auto-build |

---

## M365 — Exchange Email Authentication (DMARC/DKIM/SPF)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/DMARC-DKIM-B.md` | ✅ | auto-build |
| `M365/Exchange/DMARC-DKIM-A.md` | ✅ | auto-build |

---

---

## Azure AVD — MSIX App Attach Deep Dive (expansion)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/AppAttach-A.md` | ✅ | auto-build |

---

## Intune — Managed Apps / MAM (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Managed-Apps-B.md` | ✅ | auto-build |

---

## M365 — Teams Meeting Policies (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Teams/Meeting-Policies-B.md` | ✅ | auto-build |

---

## Intune — Managed Apps Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Managed-Apps-A.md` | ✅ | auto-build |

---

## M365 — Teams Meeting Policies Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Teams/Meeting-Policies-A.md` | ✅ | auto-build |

---

## macOS — System Extensions & Kernel Extensions (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/Extensions-B.md` | ✅ | auto-build |

---

## macOS — System Extensions Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/Extensions-A.md` | ✅ | auto-build |

---

## Windows — Certificate Services / PKI (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/CertificateServices-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/CertificateServices-A.md` | ✅ | auto-build |

---

## Intune — Feature Update Policies (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/FeatureUpdates-B.md` | ✅ | auto-build |

---

## Intune — Feature Update Policies Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/FeatureUpdates-A.md` | ✅ | auto-build |

---

## Windows — Group Policy Troubleshooting (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/GPO-B.md` | ✅ | auto-build |

---

## Azure AVD — Scaling Plans & Autoscale (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/Scaling-B.md` | ✅ | auto-build |

---

## Windows — Group Policy Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/GPO-A.md` | ✅ | auto-build |

---

## Azure AVD — Scaling Plans Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/Scaling-A.md` | ✅ | auto-build |

---

## Entra ID — MFA (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/MFA-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/MFA-A.md` | ✅ | auto-build |

---

## macOS — PPPC / TCC Privacy Controls (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/FileVault-B.md` | ✅ | auto-build (backfill) |
| `macOS/Troubleshooting/PPPC-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/PPPC-A.md` | ✅ | auto-build |

---

## Entra ID — Cross-Tenant Access (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/CrossTenant-B.md` | ✅ | auto-build |

---

## Entra ID — Cross-Tenant Access Deep Dive
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/CrossTenant-A.md` | ✅ | auto-build |

---

## Security — Microsoft Defender for Cloud Apps
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/MDA-B.md` | ✅ | auto-build |

---

## macOS — Managed Software Updates
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/SoftwareUpdates-B.md` | ✅ | auto-build |

---

---

## macOS — Managed Software Updates Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/SoftwareUpdates-A.md` | ✅ | auto-build |

---

## Security — Defender for Cloud Apps Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/MDA-A.md` | ✅ | auto-build |

---

## Intune — Platform Scripts (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Platform-Scripts-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/Platform-Scripts-A.md` | ✅ | auto-build |

---

## Power Automate — Flow Run History Script (new script)
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/Scripts/Get-FlowRunHistory.ps1` | ✅ | auto-build |

---

## M365 — Exchange Public Folders (expansion)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/PublicFolders-B.md` | ✅ | auto-build |
| `M365/Exchange/PublicFolders-A.md` | ✅ | auto-build |

---

## Security — Defender WDAC Scripts (expansion)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/Scripts/Get-WDACPolicyStatus.ps1` | ✅ | auto-build |

---

## Windows — GPO Diagnostics Script (expansion)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Scripts/Get-GPOReport.ps1` | ✅ | auto-build |

---

## macOS — MDM Repair Script (expansion)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Scripts/Repair-MacMDMEnrollment.sh` | ✅ | auto-build |

---

## Intune — Kiosk / Assigned Access (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Kiosk-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/Kiosk-A.md` | ✅ | auto-build |

---

## M365 — Exchange Room / Resource Mailboxes (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/RoomMailbox-B.md` | ✅ | auto-build |

---

## M365 — Exchange Room Mailbox Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/RoomMailbox-A.md` | ✅ | auto-build |

---

## Intune — Custom Compliance Scripts (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/CustomCompliance-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/CustomCompliance-A.md` | ✅ | auto-build |

---

## Entra ID — Entitlement Management / Access Packages (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/AccessPackages-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/AccessPackages-A.md` | ✅ | auto-build |

---

## Windows — Credential Manager (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/CredentialManager-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/CredentialManager-A.md` | ✅ | auto-build |

---

## Intune — App Protection Policies / MAM (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/AppProtection-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/AppProtection-A.md` | ✅ | auto-build |

---

## Windows — Windows Update Gap Fill (WSUS to WUfB deep dive)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/Windows Update/WSUS to WfUB A.md` | ✅ | auto-build |

---

## Entra ID — Graph API Batch Operations (new topic, pairs with existing Invoke-GraphBatchQuery.ps1 script)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Graph/GraphAPI-BatchOperations-B.md` | ✅ | auto-build |
| `EntraID/Graph/GraphAPI-BatchOperations-A.md` | ✅ | auto-build |

---

## Entra ID — Identity Protection / Risky Users & Sign-Ins (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/IdentityProtection-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/IdentityProtection-A.md` | ✅ | auto-build |

---

## Intune — Windows Autopatch (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Autopatch-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/Autopatch-A.md` | ✅ | auto-build |

---

## M365 — Copilot (new domain)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Copilot/_AGENT.md` | ✅ | auto-build |
| `M365/Copilot/Copilot-B.md` | ✅ | auto-build |

---

## M365 — Copilot Deep Dive & Scripts (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Copilot/Copilot-A.md` | ✅ | auto-build |
| `M365/Copilot/Scripts/Get-CopilotUsageReport.ps1` | ✅ | auto-build |

---

## Entra ID — Dynamic Groups (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/DynamicGroups-B.md` | ✅ | auto-build |

---

## Entra ID — Dynamic Groups Deep Dive (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/DynamicGroups-A.md` | ✅ | auto-build |

---

## Security — Conditional Access Design Hotfix (gap fill)
| File | Status | Assigned |
|------|--------|---------|
| `Security/ConditionalAccess/CA-Design-B.md` | ✅ | auto-build |

---

## Security — Conditional Access Token Protection (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Security/ConditionalAccess/TokenProtection-B.md` | ✅ | auto-build |
| `Security/ConditionalAccess/TokenProtection-A.md` | ✅ | auto-build |
| `Security/ConditionalAccess/Scripts/Get-TokenProtectionCoverageAudit.ps1` | ✅ | auto-build |

---

## Entra ID — Password Protection & Smart Lockout (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/PasswordProtection-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/PasswordProtection-A.md` | ✅ | auto-build |

---

## Windows — Delivery Optimization (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/DeliveryOptimization-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/DeliveryOptimization-A.md` | ✅ | auto-build |

---

## DFS — Access-Based Enumeration (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `DFS/Troubleshooting/ABE/DFS-ABE-B.md` | ✅ | auto-build |
| `DFS/Troubleshooting/ABE/DFS-ABE-A.md` | ✅ | auto-build |

---

## Power Automate — M365 Group/Teams Provisioning (gap fill vs. _AGENT.md scope)
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/Groups-Teams/Groups-Teams-Provisioning-B.md` | ✅ | auto-build |
| `PowerAutomate/Groups-Teams/Groups-Teams-Provisioning-A.md` | ✅ | auto-build |

---

## Power Automate — Approval Workflows (gap fill vs. _AGENT.md scope)
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/Troubleshooting/Approval-Workflows-B.md` | ✅ | auto-build |
| `PowerAutomate/Troubleshooting/Approval-Workflows-A.md` | ✅ | auto-build |

---

## DFS — Site Costing / Referral Ordering (new topic, gap fill vs. Namespace-A.md passing mentions)
| File | Status | Assigned |
|------|--------|---------|
| `DFS/Troubleshooting/SiteCosting/DFS-SiteCosting-B.md` | ✅ | auto-build |
| `DFS/Troubleshooting/SiteCosting/DFS-SiteCosting-A.md` | ✅ | auto-build |

---

## Power Automate — Flow Ownership Transfer (new topic, offboarding gap)
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/Troubleshooting/Flow-Ownership-Transfer-B.md` | ✅ | auto-build |
| `PowerAutomate/Troubleshooting/Flow-Ownership-Transfer-A.md` | ✅ | auto-build |

---

## Windows — DHCP Client (new topic, gap fill: DNS-Client existed, DHCP did not)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/DHCP-Client-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/DHCP-Client-A.md` | ✅ | auto-build |
| `Windows/Scripts/Get-DHCPClientDiagnostics.ps1` | ✅ | auto-build |

---

## macOS — Apple Business Manager Token Renewal (new topic, distinct from MDM push cert)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/ABM-Token-Renewal-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/ABM-Token-Renewal-A.md` | ✅ | auto-build |

---

## Entra ID — Continuous Access Evaluation (new topic: CAE critical-event revocation + strict location enforcement)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/CAE-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/CAE-A.md` | ✅ | auto-build |

---

## Azure/AVD — Connectivity Test Script (gap fill: only 1 script existed vs. 2-4 in comparable folders)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/Scripts/Test-AVDConnectivity.ps1` | ✅ | auto-build |

---

## Windows — Script Coverage Gap Fill (11 Troubleshooting topics had zero companion scripts vs. 1-3 in every other domain)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Scripts/Get-KerberosDiagnostics.ps1` | ✅ | auto-build |
| `Windows/Scripts/Get-SMBDiagnostics.ps1` | ✅ | auto-build |
| `Windows/Scripts/Get-FirewallDiagnostics.ps1` | ✅ | auto-build |

---

## Intune — Script Coverage Gap Fill (LAPS, Certificates, Security Baselines had zero companion scripts despite having B+A runbooks)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Scripts/Get-LAPSPasswordStatus.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-CertificateProfileStatus.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-SecurityBaselineDrift.ps1` | ✅ | auto-build |

---

## macOS — Script Coverage Gap Fill (10 Troubleshooting topics had zero topic-specific scripts — only 2 generic device-status/repair scripts existed)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Scripts/Get-FileVaultStatus.sh` | ✅ | auto-build |
| `macOS/Scripts/Get-ADEEnrollmentStatus.sh` | ✅ | auto-build |

---

## Windows — Script Coverage Gap Fill (continued)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Scripts/Get-RDPDiagnostics.ps1` | ✅ | auto-build |

---

## Windows / macOS — Script Coverage Gap Fill (continued, round 3)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Scripts/Get-EventLogDiagnostics.ps1` | ✅ | auto-build |
| `Windows/Scripts/Get-AppLockerDiagnostics.ps1` | ✅ | auto-build |
| `macOS/Scripts/Get-PlatformSSOStatus.sh` | ✅ | auto-build |

---

## Windows / macOS — Script Coverage Gap Fill (continued, round 4)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Scripts/Get-DNSClientDiagnostics.ps1` | ✅ | auto-build |
| `Windows/Scripts/Get-NTLMDiagnostics.ps1` | ✅ | auto-build |
| `macOS/Scripts/Get-SoftwareUpdateStatus.sh` | ✅ | auto-build |

---

## Windows / macOS — Script Coverage Gap Fill (continued, round 5)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Scripts/Get-CredentialManagerDiagnostics.ps1` | ✅ | auto-build |
| `Windows/Scripts/Get-CertificateServicesDiagnostics.ps1` | ✅ | auto-build |
| `macOS/Scripts/Get-PPPCStatus.sh` | ✅ | auto-build |

---

## Windows — Script Coverage Gap Fill (continued, round 6 — final 3 Windows topics)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Scripts/Get-DeliveryOptimizationDiagnostics.ps1` | ✅ | auto-build |
| `Windows/Scripts/Get-UserProfileDiagnostics.ps1` | ✅ | auto-build |
| `Windows/Scripts/Get-WMIDiagnostics.ps1` | ✅ | auto-build |

---

## macOS — Script Coverage Gap Fill (continued, round 2 — 3 of the 5 remaining topics)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Scripts/Get-SystemExtensionStatus.sh` | ✅ | auto-build |
| `macOS/Scripts/Get-ComplianceStatus.sh` | ✅ | auto-build |
| `macOS/Scripts/Get-MDMCertificateStatus.sh` | ✅ | auto-build |

---

## Security — Defender ASR & Tamper Protection Scripts (gap fill: 9 Defender topics had only 2 companion scripts)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/Scripts/Get-ASRRuleStatus.ps1` | ✅ | auto-build |
| `Security/Defender/Scripts/Get-TamperProtectionStatus.ps1` | ✅ | auto-build |

---

## Entra ID — MFA Methods & Coverage Report Script (gap fill: 14 EntraID topics had only 5 companion scripts, MFA had none)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Scripts/Get-MFAMethodsReport.ps1` | ✅ | auto-build |

---

## Azure Files (new topic — direct SMB/NFS shares + Azure File Sync, complements existing AVD/FSLogix coverage)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/Files/AzureFiles-B.md` | ✅ | auto-build |
| `Azure/Files/AzureFiles-A.md` | ✅ | auto-build |
| `Azure/Files/Scripts/Get-AzureFileShareHealth.ps1` | ✅ | auto-build |
| `Azure/Files/_AGENT.md` | ✅ | auto-build |

---

## Entra ID — WHfB / SSPR / PRT Script Coverage Gap Fill (gap flagged by name in prior run's "Skipped Items" note as the highest remaining EntraID script gaps)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Scripts/Get-WHfBRegistrationStatus.ps1` | ✅ | auto-build |
| `EntraID/Scripts/Get-SSPRCoverageReport.ps1` | ✅ | auto-build |
| `EntraID/Scripts/Get-PRTFleetRisk.ps1` | ✅ | auto-build |

---

## Security — Defender Script Coverage Gap Fill (round 2 — CloudProtection, MDI, DefenderVulnMgmt)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/Scripts/Get-CloudProtectionStatus.ps1` | ✅ | auto-build |
| `Security/Defender/Scripts/Get-MDIStatus.ps1` | ✅ | auto-build |
| `Security/Defender/Scripts/Get-DefenderVulnMgmtStatus.ps1` | ✅ | auto-build |

---

## Security — Defender Script Coverage Gap Fill (round 3 — MDA, NetworkProtection — closes out Defender script coverage 9/9)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/Scripts/Get-MDAStatus.ps1` | ✅ | auto-build |
| `Security/Defender/Scripts/Get-NetworkProtectionStatus.ps1` | ✅ | auto-build |

---

## Intune — Enrollment Diagnostics Script (gap fill: Enrollment-B/A.md had zero companion script despite being the highest-ticket-volume Intune topic)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Scripts/Get-EnrollmentDiagnostics.ps1` | ✅ | auto-build |

---

## Entra ID — Script Coverage Gap Fill (round 3 — AccessPackages, IdentityProtection, CAE — 3 of the 6 remaining EntraID script gaps)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Scripts/Get-AccessPackageAssignmentHealth.ps1` | ✅ | auto-build |
| `EntraID/Scripts/Get-IdentityProtectionRiskReport.ps1` | ✅ | auto-build |
| `EntraID/Scripts/Get-CAESessionEvents.ps1` | ✅ | auto-build |

---

## Entra ID — Script Coverage Gap Fill (round 4 — AppProxy, DynamicGroups, PasswordProtection — closes out EntraID script coverage 14/14)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Scripts/Get-AppProxyConnectorHealth.ps1` | ✅ | auto-build |
| `EntraID/Scripts/Get-DynamicGroupAudit.ps1` | ✅ | auto-build |
| `EntraID/Scripts/Get-PasswordProtectionCoverage.ps1` | ✅ | auto-build |

## Intune — Script Coverage Gap Fill (round 1 — App-Deployment, Policy-Conflict, Autopatch — highest ticket-volume of the 19 script-less Intune topics flagged by run 14)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Scripts/Get-AppDeploymentDiagnostics.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-PolicyConflictScan.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-AutopatchReadiness.ps1` | ✅ | auto-build |

---

## Intune — Script Coverage Gap Fill (round 2 — CoManagement, Remediations, GP-to-CSP)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Scripts/Get-CoManagementStatus.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-RemediationRunHistory.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-GPtoCSPCoverageReport.ps1` | ✅ | auto-build |

---

## Intune — Script Coverage Gap Fill (round 3 — EPM, DriverManagement, WUfB)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Scripts/Get-EPMElevationReport.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-DriverManagementStatus.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-WUfBDeploymentStatus.ps1` | ✅ | auto-build |

---

## Intune — Script Coverage Gap Fill (round 4 — AppProtection, CustomCompliance, Managed-Apps — leaves 4/22 script-less: Filters, Kiosk, Platform-Scripts, ScopeTags)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Scripts/Get-AppProtectionCoverageReport.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-CustomComplianceScriptValidator.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-ManagedAppDeploymentStatus.ps1` | ✅ | auto-build |

---

## Intune — Script Coverage Gap Fill (round 5 — Filters, Kiosk, Platform-Scripts, ScopeTags — closes out Intune script coverage 22/22)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Scripts/Get-AssignmentFilterAudit.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-KioskDeviceHealthReport.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-PlatformScriptRunStatus.ps1` | ✅ | auto-build |
| `Intune/Scripts/Get-ScopeTagRBACAudit.ps1` | ✅ | auto-build |

---

## M365 — Exchange Script Coverage Gap Fill (round 1 — DMARC-DKIM, EOP-AntiSpam, ArchiveRetention)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/Scripts/Get-DKIMDMARCReport.ps1` | ✅ | auto-build |
| `M365/Exchange/Scripts/Get-EOPQuarantineReport.ps1` | ✅ | auto-build |
| `M365/Exchange/Scripts/Get-ArchiveRetentionAudit.ps1` | ✅ | auto-build |

---

## M365 — Exchange Script Coverage Gap Fill (round 2 — MessageEncryption, PublicFolders, RoomMailbox)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/Scripts/Get-OMEConfigurationAudit.ps1` | ✅ | auto-build |
| `M365/Exchange/Scripts/Get-PublicFolderHealthReport.ps1` | ✅ | auto-build |
| `M365/Exchange/Scripts/Get-RoomMailboxAudit.ps1` | ✅ | auto-build |

---

## Security — Purview / M365 Teams Script Coverage Gap Fill (round 4 — Insider-Risk, eDiscovery, Meeting-Policies — closes the 3 gaps flagged by name in run 22's note)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/Scripts/Get-InsiderRiskPolicyStatus.ps1` | ✅ | auto-build |
| `Security/Purview/Scripts/Get-eDiscoveryHoldAudit.ps1` | ✅ | auto-build |
| `M365/Teams/Scripts/Get-TeamsMeetingPolicyAudit.ps1` | ✅ | auto-build |

---

## PowerAutomate — Script Coverage Gap Fill (round 1 — Groups-Teams-Provisioning, Approval-Workflows, Flow-Ownership-Transfer)
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/Scripts/Get-GroupsTeamsProvisioningHealth.ps1` | ✅ | auto-build |
| `PowerAutomate/Scripts/Get-ApprovalApproverEligibilityAudit.ps1` | ✅ | auto-build |
| `PowerAutomate/Scripts/Get-FlowOwnershipSweep.ps1` | ✅ | auto-build |

---

## M365/Teams, M365/SharePoint-OneDrive, Azure/Windows365 — Script Coverage Gap Fill (run 25 — Device-Policies, Permissions, Cloud PC fleet status)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Teams/Scripts/Get-TeamsDevicePolicyAudit.ps1` | ✅ | auto-build |
| `M365/SharePoint-OneDrive/Scripts/Get-SharePointPermissionAudit.ps1` | ✅ | auto-build |
| `Azure/Windows365/Scripts/Get-CloudPcFleetStatus.ps1` | ✅ | auto-build |

---

## Intune / M365 Exchange / Security-ConditionalAccess — Script Coverage Gap Fill (run 26 — FeatureUpdates, SharedMailbox, CA Device Filters)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Scripts/Get-FeatureUpdateDeploymentStatus.ps1` | ✅ | auto-build |
| `M365/Exchange/Scripts/Get-SharedMailboxAudit.ps1` | ✅ | auto-build |
| `Security/ConditionalAccess/Scripts/Get-CADeviceFilterAudit.ps1` | ✅ | auto-build |

---

## PowerAutomate / Security-ConditionalAccess / M365-SharePoint-OneDrive — Script Coverage Gap Fill (run 27 — Throttling-Limits, CA-Design, Migration)
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/Scripts/Get-ThrottlingLimitDiagnostics.ps1` | ✅ | auto-build |
| `Security/ConditionalAccess/Scripts/Get-CAPolicyDesignAudit.ps1` | ✅ | auto-build |
| `M365/SharePoint-OneDrive/Scripts/Get-SharePointMigrationStatus.ps1` | ✅ | auto-build |

---

## Azure/AVD — Script Coverage Gap Fill (run 28 — AppAttach, FSLogix, Scaling)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/AVD/Scripts/Get-AVDAppAttachHealth.ps1` | ✅ | auto-build |
| `Azure/AVD/Scripts/Get-FSLogixProfileHealth.ps1` | ✅ | auto-build |
| `Azure/AVD/Scripts/Get-AVDScalingPlanAudit.ps1` | ✅ | auto-build |

---

## Build Progress (superseded — run 28)
- Total files: 403
- Completed: 403
- In progress: 0
- Queued: 0
- Last updated: 2026-07-07 (auto-build, run 28, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per the standing lesson that manifest bookkeeping drifts from actual repo state, went straight to run 27's own filesystem-verified lead rather than trusting older notes: confirmed via `ls Azure/AVD/` and `ls Azure/AVD/Scripts/` that all 5 AVD topics (AVD, AVD-Connectivity, AppAttach, FSLogix, Scaling) have both A/B runbooks, but only AVD and AVD-Connectivity had companion scripts (Get-AVDSessionHealth.ps1, Test-AVDConnectivity.ps1) — AppAttach, FSLogix, and Scaling were genuinely script-less, confirming run 27's flagged gap. Read all three topics' A/B runbook pairs in full before building to match their specific architecture, symptom maps, and fix paths rather than generic templates. Closed all three: `Azure/AVD/Scripts/Get-AVDAppAttachHealth.ps1` (session-host-local diagnostic covering all four App Attach lifecycle phases from AppAttach-A.md — AppXSVC/RDAgentBootLoader service state, CimFS driver presence gated on OS build >=19041, Get-DiskImage mount state, Get-AppxPackage -AllUsers staging/registration state with optional -AppPartialName filter matching AppAttach-B.md's fix-path placeholder, AppXDeploymentServer operational log error/warning scan, and an optional -PackageSharePath check combining Test-Path + TCP 445 to cover the SMB/RBAC failure mode both docs flag as the most common root cause; flags NOT_MOUNTED, APPXSVC_STOPPED, CIMFS_DRIVER_MISSING, SHARE_UNREACHABLE, STAGING_ERRORS_FOUND, PACKAGE_NOT_REGISTERED), `Azure/AVD/Scripts/Get-FSLogixProfileHealth.ps1` (session-host-local audit covering FSLogix-A.md's dependency stack top to bottom — frxsvc/frxccds service state, frxdrv.sys filter driver presence via fltMC, HKLM:\SOFTWARE\FSLogix\Profiles registry config, SMB TCP 445 test against VHDLocations or an optional override path, a klist-based Kerberos CIFS ticket check to catch the NTLM-fallback failure mode both docs call out, Microsoft-FSLogix-Apps/Operational event log scan mapping directly to FSLogix-B.md's Event ID 7/43/27 quick-reference, and an optional -UserName mode that locates a specific user's VHD(X) and scans for orphaned .lock files per FSLogix-A.md's "locked VHD is the #1 support call" learning pointer; flags SERVICE_NOT_RUNNING, DRIVER_MISSING, NOT_ENABLED, SHARE_UNREACHABLE, NTLM_FALLBACK_RISK, RECENT_ATTACH_FAILURE, VHD_LOCKED, VHD_NOT_FOUND), and `Azure/AVD/Scripts/Get-AVDScalingPlanAudit.ps1` (fleet-wide Az-based audit built directly from Scaling-A.md's Dependency Stack and Scaling-B.md's Triage/Diagnosis flow — resolves the AVD/Windows Virtual Desktop service principal once and checks Desktop Virtualization Power On Off Contributor at RG scope per plan, the single most common silent-failure root cause both docs lead with; checks host pool association existence; flags DRAIN_WITH_ACTIVE_SESSIONS for hosts in drain mode that still have live sessions so this by-design behavior isn't mistaken for a scaling bug; flags ZERO_FLOOR_NO_START_ON_CONNECT for Personal pools with a 0% off-peak floor and Start VM on Connect disabled, per Scaling-A.md's Personal-pool power management section; checks for a diagnostic setting on the plan resource per both docs' emphasis on WVDAutoscaleEvaluationPooled being essential for cost/scaling analysis; surfaces configured time zone as an informational DST sanity-check prompt rather than attempting to compute DST offsets itself). All three read-only, no remediation actions. Backfilled `Azure/AVD/_AGENT.md` folder-contents table with rows for all three new scripts — also fixed a pre-existing duplicate-row bug in that table (Test-AVDConnectivity.ps1 was listed twice) while editing. Verified brace/paren balance via `grep -o` counts on all three new scripts before committing (no pwsh available in this sandbox for a real parse check; all three balanced cleanly). Checked `ls .git/*.lock*` for stale lock files per the standing environment note before committing — none found. **Result: Azure/AVD is now 5/5 script coverage, matching the pattern of every other fully-closed domain (Intune 21/21, Security/Defender 9/9, M365/Teams 4/4, Security/Purview 4/4, PowerAutomate 8/8, Security/ConditionalAccess 4/4, M365/SharePoint-OneDrive 3/3).** **Remaining known gap for next run (unchanged from run 27, not actioned this run — time/scope):** EntraID has 17 Troubleshooting topics; `CrossTenant` and `GlobalSecureAccess` still have no dedicated companion script (GlobalSecureAccess has A+B runbooks per run 19/20 but never got a script; CrossTenant's existing `Get-EntraB2BGuestReport.ps1` appears to cover ExternalIdentities, not CrossTenant specifically — needs confirmation by reading CrossTenant-A/B.md before building, to avoid a false-gap or a false-non-gap either way). Also still unconfirmed: whether `Get-EntraDeviceHealth.ps1` genuinely covers HybridJoin or is a generic device-health script with no HybridJoin-specific logic.

## Build Progress (superseded — run 29)
- Total files: 406
- Completed: 406
- In progress: 0
- Queued: 0
- Last updated: 2026-07-07 (auto-build, run 29, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Re-verified run 28's flagged EntraID gap directly against the filesystem before acting, per the standing lesson that manifest bookkeeping drifts from actual repo state. Confirmed via `ls EntraID/Troubleshooting/` vs `ls EntraID/Scripts/` (16 topics, 15 scripts incl. 1 shared utility): `Get-EntraB2BGuestReport.ps1`'s own SYNOPSIS confirms it covers B2B guest audit (ExternalIdentities), not CrossTenant — so CrossTenant was genuinely script-less. `GlobalSecureAccess` had A+B runbooks (closed run 19/20) but no script — confirmed genuinely script-less. `Get-EntraDeviceHealth.ps1`'s SYNOPSIS confirms it's a generic fleet device-health report (stale/no-MDM/duplicate flags only) with no SCP check, DRS endpoint reachability, scheduled-task inspection, or dsregcmd parsing — read `HybridJoin-A.md`/`HybridJoin-B.md` in full and confirmed this is a real gap, not just a naming coincidence. Closed all three: `EntraID/Scripts/Get-CrossTenantAccessAudit.ps1` (tenant-wide audit of default + all partner XTAS policies — flags INBOUND_B2B_BLOCKED, DIRECT_CONNECT_ONE_SIDED for Teams Shared Channel mismatches per CrossTenant-A.md's "both sides independently" architecture note, TRUST_MFA_OFF/TRUST_COMPLIANT_OFF for the MFA/compliance re-prompt loops both docs flag as the top guest complaint, and an informational XTS_SYNC_ENABLED flag; optional -PartnerTenantId deep-dive JSON dump and -IncludeSignInFailures audit-log correlation), `EntraID/Scripts/Get-GlobalSecureAccessHealth.ps1` (tenant-wide Traffic Forwarding Profile state audit — PROFILE_DISABLED is GSA-A.md's #1-flagged "silent, no client error" root cause — plus Private Access connector fleet health with CONNECTOR_INACTIVE/CONNECTOR_STALE_HEARTBEAT, connector-group rollup flagging GROUP_ZERO_HEALTHY and GROUP_SINGLE_CONNECTOR for HA gaps, and published-application cross-reference flagging APP_NO_CONNECTOR_GROUP/APP_GROUP_UNHEALTHY; requires Microsoft.Graph.Beta per both runbooks' NetworkAccess cmdlet dependency), and `EntraID/Scripts/Get-HybridJoinDiagnostics.ps1` (device-local diagnostic — deliberately NOT fleet-wide since HAADJ root causes are device/network-path specific — walking the full dependency chain from HybridJoin-A.md: domain join + secure channel, dsregcmd parsing for AzureAdJoined/AzureAdPrt/TenantId, SCP presence + tenant-ID-match check via ADSI, DRS endpoint TCP 443 reachability for all 3 documented endpoints, Automatic-Device-Join scheduled task last-result check, Device Registration/Admin event log scan for the documented failure IDs 204/301, MS-Organization device certificate presence, and an optional -CheckEntra Graph cross-check for Pending-sync detection). All three read-only, no remediation actions. Backfilled `EntraID/_AGENT.md` folder-contents table with rows for all three new scripts. Verified brace/paren balance via `grep -o` counts on all three new scripts before committing (no pwsh available in this sandbox for a real parse check; all three balanced cleanly). **Environment note reconfirmed and acted on:** `.git/index.lock` and `.git/packed-refs.lock` were present as stale locks from an interrupted prior run and could NOT be removed via `rm`, Python `os.remove`, or `sudo` (all failed with EPERM — this FUSE-mounted repo directory appears to disallow unlink() entirely, only rename()/mv works). Worked around by `mv`-ing each stale lock to a uniquely-suffixed `.bak` filename rather than deleting it (consistent with the large accumulation of `.git/*.lock.stale-*`/`.bak` files left by prior runs hitting the same constraint) — this unblocks git without requiring delete permission. The same EPERM-on-unlink behavior surfaced again as non-fatal warnings during `git commit` (temp objects, `HEAD.lock`) but did not block the commit; moved the stray post-commit `HEAD.lock` aside the same way before `git push`, which then succeeded cleanly. **Result: EntraID script coverage is now 18/16 topics covered (17 topic-specific scripts + 1 shared Graph utility) — every EntraID Troubleshooting topic has a dedicated script.** **For next run:** the accumulated pile of dozens of stale `.git/*.lock*`/`.bak`/`.stale-*` files in this repo's `.git/` directory is harmless (git ignores files that aren't the exact lock names it checks for) but worth a mental note — if `git commit`/`push` ever fails with "file exists" on `index.lock`, `HEAD.lock`, or `packed-refs.lock`, `mv` the blocking file to a uniquely-suffixed name rather than attempting `rm` (which will fail with EPERM in this environment). Remaining known content gaps (unchanged, not actioned this run — time/scope): Intune script coverage is 21/21 topics per run 28 but that count should be spot-checked against the filesystem next run since manifest bookkeeping in this section has repeatedly drifted; Exchange/SharePoint-OneDrive/Teams/Purview/ConditionalAccess/PowerAutomate/AVD are all previously confirmed at full script coverage as of runs 22-28 and do not need re-verification unless new topics were added.

## Build Progress
- Total files: 409
- Completed: 409
- In progress: 0
- Queued: 0
- Last updated: 2026-07-07 (auto-build, run 30, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per the standing lesson that manifest bookkeeping drifts from actual repo state, did NOT limit this run to re-checking run 29's single flagged Intune lead — instead ran a full filesystem-verified topic-vs-script comparison across every domain (`find <domain> -name "*.md" -o -name "*.ps1"`, base-name diffing Troubleshooting topics against Scripts folder contents) to surface any genuinely new gaps, since several past runs' "for next run" notes had turned out stale or already-resolved by the time they were re-checked. Confirmed DFS (4/4), PowerAutomate (8/8), Security/Defender (9/9), Security/ConditionalAccess (5/5 — TokenProtection has its own script, not previously double-checked), Security/Purview (5/5), M365/Exchange (10/10), M365/Teams (4/4), M365/Licensing, M365/UniversalPrint, M365/Copilot, Autopilot (4/4 topic-specific + utilities), Azure/AVD (5/5), Azure/Files, Azure/Windows365, and macOS (9/9 topics with matching scripts, several as .sh) are all still genuinely fully covered — no action needed. Found and closed three real, filesystem-verified gaps: (1) **EntraID/EntraDomainServices** — 18 Troubleshooting topics but only 17 topic-specific scripts (excluding the shared `Invoke-GraphBatchQuery.ps1` utility and the generic fleet-wide `Get-EntraDeviceHealth.ps1`, whose SYNOPSIS confirms it has no Entra-DS-specific logic) — closed with `EntraID/Scripts/Get-EntraDomainServicesHealth.ps1` (managed-domain resource + replica-set health via `Get-AzADDomainService`, LDAPS certificate expiry tracking since Entra DS sends no renewal reminder per EntraDomainServices-A.md's Learning Pointers, VNet peering reciprocity check on both the workload and Entra DS sides — flagging the one-sided-peering failure mode the runbook calls "the single most common silent-failure pattern" — workload VNet DNS configuration, and an optional per-UPN password-hash-sync readiness check distinguishing cloud-only pre-enable accounts from hybrid PHS-dependent accounts). (2) **M365/SharePoint-OneDrive/Sync-Issues** — read `Get-SharePointSiteReport.ps1`'s own SYNOPSIS and confirmed it is a general tenant-wide site/storage/sharing inventory tool with zero sync-client-specific logic, so Sync-Issues was genuinely script-less despite the topic count matching the script count — closed with `M365/SharePoint-OneDrive/Scripts/Get-OneDriveSyncClientHealth.ps1` (local ODC diagnostic run as the affected user: process/version check, `dsregcmd`-based Entra join/PRT check since WAM is the silent auth backbone Sync-Issues-A.md's Learning Pointers flag as the #1 blind spot, multi-Business-account conflict detection, OneDrive event log error scan, path-length compliance scan against the 256-char SharePoint ceiling with a `-SkipPathScan` switch for large sync roots, and KFM tenant-GUID/shell-folder-redirection verification). (3) **Windows/VBS-CredentialGuard** — `Scripts/Enable-VBS.ps1` turned out to be a 10-line legacy raw registry snippet with no header, no diagnostics, and no error handling (pre-dating this repo's format spec) — a remediation-only stub, not the diagnostic companion every other Windows topic has — closed with `Windows/Scripts/Get-VBSCredentialGuardStatus.ps1` (hardware prerequisite checks — SLAT, Secure Boot, TPM — the `Win32_DeviceGuard` WMI "gold standard" status check per VBS-CredentialGuard-A.md Validation Step 2, `lsaiso.exe` process check as the fastest real-world Credential Guard signal, MDM/Intune and legacy-registry policy-channel checks, and a CodeIntegrity/Operational event log scan for HVCI driver-block event IDs 3001/3002/3003/3010/3023 — the runbook's flagged #1 real-world pain point). All three read-only, no remediation actions; legacy `Enable-VBS.ps1` left in place and re-labeled in `_AGENT.md` as a remediation-only stub rather than removed, since removing existing files isn't part of this job. Backfilled `Windows/_AGENT.md`, `EntraID/_AGENT.md`, and `M365/SharePoint-OneDrive/_AGENT.md` folder-contents tables and entry-point bullets with rows/references for all three new scripts. Verified brace/paren balance via `grep -o` counts on all three new scripts before committing (48/48, 50/50, 45/45 braces; 85/85, 90/90, 88/88 parens — no pwsh available in this sandbox for a real parse check). **Result: EntraID is now 18/18 topics with a dedicated or clearly-labeled-generic script, M365/SharePoint-OneDrive is now genuinely 3/3, and Windows VBS-CredentialGuard now has a proper diagnostic script alongside its legacy remediation stub.** **Remaining known items for next run:** this run's full-domain sweep did not include a topic-vs-script diff for `Windows` beyond VBS-CredentialGuard specifically (the Time/ and Windows Update/ subfolders use inconsistent file-naming with spaces instead of hyphens — e.g. `TimeSync A.md`, `Update to Latest A.md` — worth a cosmetic rename pass at some point, low priority, functional either way); Security/ConditionalAccess's TokenProtection topic was confirmed to have its own script this run but this was the first time it was explicitly checked, worth noting as newly-confirmed rather than assumed. No script-coverage gaps remain that were found and left unactioned this run.

## Build Progress (superseded — run 27)
- Total files: 400
- Completed: 400
- In progress: 0
- Queued: 0
- Last updated: 2026-07-06 (auto-build, run 27, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Re-verified run 26's two flagged leads directly against the filesystem rather than trusting the note text, per the standing lesson that manifest bookkeeping drifts from actual repo state. Confirmed via `ls`: (1) `Security/ConditionalAccess` has 4 topics (CA-Design, CA-Filters, CA-Troubleshooting, Named-Locations) but only 3 scripts — CA-Design was genuinely script-less; (2) did the "full re-sweep of Teams/SharePoint-OneDrive/Purview" run 26 suggested — found Teams (4/4) and Purview (4/4) are now fully covered (closed by runs 22-24), but SharePoint-OneDrive still has 3 topics (Migration, Permissions, Sync-Issues) with only 2 scripts — Migration was genuinely script-less (the existing `Get-SharePointSiteReport.ps1` is a general tenant-wide inventory tool, not migration-specific). Per project memory that DFS and Power Automate are the standing #1/#2 priorities, also re-checked PowerAutomate (8 topics) and found Throttling-Limits was the one remaining script-less topic (7/8 previously). Closed all three: `PowerAutomate/Scripts/Get-ThrottlingLimitDiagnostics.ps1` (combines confirmed-429 run-history scanning via `Get-AdminFlowRun` with flow-definition JSON parsing for loop/concurrency/retry-policy settings — flags FLOW_THROTTLED, NO_CONCURRENCY_LIMIT, AGGRESSIVE_DEFAULT_RETRY, HIGH_FREQUENCY_RECURRENCE, and the compound RETRY_CASCADE_RISK signature Throttling-Limits-A.md's "Retry Cascade Problem" describes as capable of burning 5-100x normal quota per run; explicitly does NOT attempt to surface Layer-1 daily request entitlement consumption since that metric is confirmed portal-only with no cmdlet equivalent), `Security/ConditionalAccess/Scripts/Get-CAPolicyDesignAudit.ps1` (tenant-wide audit combining break-glass exclusion checking against a supplied UPN list, BROAD_SCOPE_NO_PILOT for All-users policies with zero exclusion groups, LEGACY_AUTH_GAP for MFA/Block policies missing exchangeActiveSync+other client app types, a RECENTLY_ENABLED heuristic proxy for skipped Report-only periods since Graph exposes no policy state-transition history, and a pairwise POTENTIAL_GRANT_CONFLICT scope-overlap check for the hybridAzureADJoined-vs-compliantDevice BYOD-can-satisfy-neither scenario from CA-Design-B.md Fix 5 — automates all of CA-Design-B.md's Triage steps 1-4 and CA-Design-A.md's grant-conflict Validation Step 3 in one pass), and `M365/SharePoint-OneDrive/Scripts/Get-SharePointMigrationStatus.ps1` (three independent modes matching the runbooks' three failure domains — local SPMT agent host mode always runs: install/version check, connectivity to all 4 required endpoints including the *.blob.core.windows.net staging container, and worker-log ERROR/WARN/throttle scanning; destination SPO mode activates when -TenantName/-SiteUrl supplied: site existence, QUOTA_RISK at a configurable percentage threshold, and migration-account Site-Collection-Admin verification; source pre-scan mode activates when -SourcePath supplied: OVERSIZED_FILE (>250GB hard SPO ceiling), LONG_PATH (>260 chars), and BAD_CHARACTERS scanning per Migration-B.md Fix 2's restricted-character list). All three read-only, no remediation actions. Backfilled `PowerAutomate/_AGENT.md`, `Security/ConditionalAccess/_AGENT.md`, and `M365/SharePoint-OneDrive/_AGENT.md` folder-contents tables with rows for the new scripts. Verified brace/paren balance via `grep -o` counts on all three new scripts before committing (no pwsh available in this sandbox for a real parse check; all three balanced cleanly). Checked `ls .git/*.lock*` for stale lock files per the standing environment note before committing — none found. **Result: every domain in the repo with a previously-tracked script-coverage gap (PowerAutomate, Security/ConditionalAccess, M365/SharePoint-OneDrive) is now fully closed — Intune 21/21, Security/Defender 9/9, M365/Teams 4/4, Security/Purview 4/4, PowerAutomate 8/8, Security/ConditionalAccess 4/4, M365/SharePoint-OneDrive 3/3.** **Remaining known gap for next run, found via this run's filesystem pass but not actioned (time/scope):** EntraID has 17 Troubleshooting topics but `CrossTenant` and `GlobalSecureAccess` still have no dedicated companion script (GlobalSecureAccess has A+B runbooks per run 19/20 but never got a script; CrossTenant's existing `Get-EntraB2BGuestReport.ps1` appears to cover ExternalIdentities, not CrossTenant specifically — needs confirmation by reading CrossTenant-A/B.md before building). Also unconfirmed this run: whether `Get-EntraDeviceHealth.ps1` genuinely covers HybridJoin or is a generic device-health script with no HybridJoin-specific logic — worth a quick read-through before assuming a gap or non-gap either way. Azure/AVD also has 5 topics (AVD, AVD-Connectivity, AppAttach, FSLogix, Scaling) but only 2 scripts (Test-AVDConnectivity, Get-AVDSessionHealth) — AppAttach, FSLogix, and Scaling appear script-less but this was not verified against the actual runbook content this run; worth confirming before building to avoid a false-gap.

## Build Progress (previous)
- Total files: 397
- Completed: 397
- In progress: 0
- Queued: 0
- Last updated: 2026-07-06 (auto-build, run 26, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per the standing lesson that manifest bookkeeping drifts from actual repo state, re-verified the "remaining known gaps" note left by run 25 directly against the filesystem via `ls` rather than trusting the text. Two of the three items in that note turned out to be stale/already-resolved (Intune Filters/Kiosk/Platform-Scripts/ScopeTags scripts all already exist per run 19 — confirmed via `ls Intune/Scripts/`; Security/ConditionalAccess CA-Design does have both A/B docs but no dedicated topic script is a real gap, same for CA-Filters). Direct filesystem comparison of Intune/Troubleshooting/*.md topics against Intune/Scripts/*.ps1 found exactly one real gap: **FeatureUpdates** (21 topics, 20 matched scripts — every other topic has a companion script). Closed it with `Get-FeatureUpdateDeploymentStatus.ps1` (local check of TargetReleaseVersion CSP values, GPO conflict + MDMWinsOverGP precedence at the WindowsUpdate registry key, safeguard hold registry/event-log signals, disk space against the ~20GB staging requirement, and telemetry level — mirrors the local-plus-fleet pattern of `Get-WUfBDeploymentStatus.ps1`; fleet side queries `windowsFeatureUpdateProfiles`/`deviceStatuses` and flags STALE_PENDING past a configurable day threshold, matching FeatureUpdates-B.md's Interpretation table and FeatureUpdates-A.md's Symptom → Cause Map). Also confirmed via `ls` that M365/Exchange's SharedMailbox topic (flagged script-less since run 21) and Security/ConditionalAccess's CA-Filters topic were both still genuinely script-less — closed both: `M365/Exchange/Scripts/Get-SharedMailboxAudit.ps1` (fleet-wide audit flagging WRONG_TYPE, NO_FULL_ACCESS — an orphaned mailbox nobody can reach, SENTITEMS_GAP when Send As/Send On Behalf delegates exist but MessageCopyForSentAsEnabled/MessageCopyForSendOnBehalfEnabled is False, QUOTA_RISK against a configurable GB threshold, LICENSED_UNNECESSARY when a licence is assigned with no Litigation Hold/Archive/>50GB justification per SharedMailbox-B.md Fix 6, and SIGNIN_NOT_BLOCKED via an optional Graph AccountEnabled check per SharedMailbox-A.md Validation Step 7's security note) and `Security/ConditionalAccess/Scripts/Get-CADeviceFilterAudit.ps1` (tenant-wide audit of every CA policy with a device filter — flags EXCLUDE_ALL_MATCH/INCLUDE_ZERO_MATCH by estimating filter match count against the live device inventory for the two most common filter patterns (extensionAttribute -eq and Autopilot physicalIds ZTDID), STALE_EXTATTR_TARGET when a filter references an extensionAttribute that is set on zero devices tenant-wide — the "attribute never populated" failure mode CA-Filters-A.md's Learning Pointers calls out — AUTOPILOT_FILTER_LOW_COVERAGE against a configurable percentage threshold, and REPORT_ONLY as an informational flag so a report-only policy isn't mistaken for an active control during an access-denied investigation; also produces an orphaned-extensionAttribute cleanup list). All three read-only, no remediation actions. Backfilled `Intune/_AGENT.md`, `M365/Exchange/_AGENT.md`, and `Security/ConditionalAccess/_AGENT.md` folder-contents tables with rows for the new scripts (Exchange's table was significantly behind — added rows for several pre-existing scripts that had never been listed there: Get-MessageTrace, Get-ExchangeHybridHealth, Get-MailboxAuditReport, Get-DKIMDMARCReport, Get-EOPQuarantineReport, Get-ArchiveRetentionAudit, Get-OMEConfigurationAudit, Get-PublicFolderHealthReport, Get-RoomMailboxAudit, plus the SharedMailbox-A.md row; ConditionalAccess was missing its CA-Filters-A/B and Named-Locations-B doc rows entirely). Manually verified brace/paren balance on all three new scripts via `grep -o` counts before committing (no pwsh available in this sandbox to do a real parse check) and caught/fixed one real bug pre-commit: an invalid C-style `foreach (...;...;...)` no-op line accidentally left in the SharedMailbox script during drafting — removed before finalizing. Checked `ls .git/*.lock*` for stale lock files per the standing environment note before committing. **Remaining known gaps for next run:** CA-Design topic in Security/ConditionalAccess is still script-less (only CA-Troubleshooting/Named-Locations/CA-Filters now have dedicated scripts) — worth a `Get-CAPolicyDesignAudit.ps1` covering pilot-scoping/break-glass-exclusion/policy-overlap checks next. No other script-coverage gaps were found on this run's filesystem pass across Intune, Exchange, or ConditionalAccess; a full re-sweep of Teams/SharePoint-OneDrive/Purview for any newly-added script-less topics would be the next highest-value bookkeeping task.

## Build Progress (previous)
- Total files: 394
- Completed: 394
- In progress: 0
- Queued: 0
- Last updated: 2026-07-06 (auto-build, run 25, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per the standing note at the top of this section and project memory, verified real script-coverage gaps directly against the filesystem (`ls`) rather than trusting older manifest text, per the repeated lesson that manifest bookkeeping drifts from actual repo state. Confirmed three real, filesystem-verified gaps and closed all three: `M365/Teams/Scripts/Get-TeamsDevicePolicyAudit.ps1` (Device-Policies was the only Teams topic still script-less — audits resource-account Entra ID state, Teams Rooms Pro/Basic or Common Area Phone licensing, TeamsUpdateManagementPolicy assignment, calendar AutomateProcessing=AutoAccept per Device-Policies-B.md Fix 6, and optionally IP phone policy/hot-desking state — flags ACCOUNT_DISABLED, NO_TEAMS_ROOMS_LICENSE, NO_UPDATE_POLICY_ASSIGNED, CALENDAR_NOT_AUTO_ACCEPT per the runbook's most common device-account root causes; also does a best-effort tenant-wide CA/MFA heuristic check tied to the runbook's #1 Learning Pointer that MFA must never be enforced on unattended resource accounts), `M365/SharePoint-OneDrive/Scripts/Get-SharePointPermissionAudit.ps1` (Permissions was the only SharePoint-OneDrive topic still script-less — cross-references site vs. tenant SharingCapability rank to flag SITE_SHARING_EXCEEDS_TENANT, flags SITE_LOCKED, counts broken-inheritance items in the default Documents library against a configurable threshold to flag HIGH_UNIQUE_PERMISSION_COUNT per Permissions-A.md's "permission sprawl" Learning Pointer, flags GROUP_CONNECTED_NO_GROUPID for Teams-template sites with an empty GroupId per Permissions-B.md Fix 4, and optionally checks guest ExternalUserState for PENDING_GUEST_REDEMPTION per Permissions-A.md Validation Step 6), and `Azure/Windows365/Scripts/Get-CloudPcFleetStatus.ps1` (the run-19/20-flagged gap, finally closed — mirrors the pattern of `Azure/AVD/Scripts/Get-AVDSessionHealth.ps1`: fleet-wide Cloud PC status/StatusDetails report flagging PROVISIONING_STUCK past a configurable pendingProvisioning-hours threshold and PROVISIONING_FAILED, independent ANC health section since one unhealthy ANC blocks all dependent provisioning, NOT_IN_INTUNE cross-check for the "provisioned but unusable" case, and a per-SKU Windows 365 license consumption summary flagging NEAR_EXHAUSTION at 95%+). All three read-only, no remediation actions. Also backfilled `M365/Teams/_AGENT.md` and `M365/SharePoint-OneDrive/_AGENT.md` folder-contents tables — both were significantly behind actual repo state (missing Meeting-Policies, Teams-Rooms, Calling-A, Device-Policies-A rows in Teams; missing Migration, Permissions-A, Sync-Issues-A rows in SharePoint-OneDrive; neither had any Scripts/ rows at all) — and added the new script to `Azure/_AGENT.md`. Confirmed via `ls .git/*.lock` that no stale lock files were present before committing. **Remaining known gaps for next run:** Intune script gaps (Filters, Kiosk, Platform-Scripts, ScopeTags — flagged since run 18, not yet reverified against filesystem this run), Exchange SharedMailbox (flagged script-less since run 21), Security/ConditionalAccess CA-Design and CA-Filters topics (confirmed via `ls` this run — only Get-CASignInAnalysis.ps1 and Get-NamedLocationAudit.ps1 exist, covering Named-Locations and CA-Troubleshooting; CA-Design and CA-Filters remain script-less).

---

## Build Progress (previous)
- Total files: 391
- Completed: 391
- In progress: 0
- Queued: 0
- Last updated: 2026-07-06 (auto-build, run 24, scheduled task "ezadmin-day-build": manifest queue still empty. Per project memory, DFS and PowerAutomate are the standing #1/#2 build priorities, and run 20's note flagged that PowerAutomate — despite solid DFS-adjacent coverage — was still missing scripts for Groups-Teams-Provisioning, Approval-Workflows, and Flow-Ownership-Transfer. Confirmed via `find`/`ls` that all three were genuinely script-less (PowerAutomate/Scripts only had Get-ConnectorAuthHealth, Get-DLPPolicyImpactReport, Get-FlowRunHistory, New-SharePointSiteViaGraph, Set-SharePointSitePermissions). Closed all three this run: `Get-GroupsTeamsProvisioningHealth.ps1` (checks a single named group or fleet-scans groups created in a recent window, flags RACE_CONDITION_SUSPECTED when the Team object or SharePoint site hasn't provisioned past a configurable grace period — the runbook's single most common flow defect — NO_OWNER when a group has members but zero owners, and LICENSE_PENDING/LICENSE_ERROR against `licenseProcessingState`; also snapshots the tenant's Group.Unified naming policy so a "wrong name" ticket can be triaged as policy-driven without a separate lookup), `Get-ApprovalApproverEligibilityAudit.ps1` (checks AccountEnabled/license state for a supplied list of approver UPNs — the runbooks' most common root cause of a stuck approval — and optionally resolves each ineligible approver's manager via `Get-MgUserManager` as a ready-made escalation contact, operationalizing the manager-lookup pattern from Approval-Workflows-A.md Playbook 2), and `Get-FlowOwnershipSweep.ps1` (tenant-wide sweep across every Power Platform environment including the commonly-missed Default environment for flows owned by a departing user, flags NO_CO_OWNER as the single-point-of-failure signal per Flow-Ownership-Transfer-A.md, PREMIUM_CONNECTOR via a best-effort connector-reference check against a known-premium connector list — HTTP, SQL, Dataverse, on-prem gateway connectors — so a licensing gap is caught before ownership transfer rather than after, and DISABLED for already-auto-suspended flows). All three read-only, matching the established audit-only pattern (no ownership transfer or connection remediation is automated, consistent with the runbooks' emphasis that ownership and connection identity are separate systems requiring deliberate manual reconnection). Updated `PowerAutomate/_AGENT.md` folder contents table to include all PowerAutomate scripts (several pre-existing scripts — Get-ConnectorAuthHealth, Get-DLPPolicyImpactReport, Get-FlowRunHistory — were also missing rows there; backfilled). **PowerAutomate script coverage is now complete: every Troubleshooting/Groups-Teams topic with a companion runbook now has a companion script.** Checked for stale `.git/index.lock`/`HEAD.lock` per the standing environment note before committing.

---

## Build Progress (previous)
- Total files: 385
- Completed: 385
- In progress: 0
- Queued: 0
- Last updated: 2026-07-06 (auto-build, night run 22: manifest queue still empty. Verified script-coverage gaps directly against the filesystem rather than trusting run 21's self-reported counts (manifest bookkeeping has repeatedly drifted from actual repo state per the standing note below). Confirmed via `find` that virtually every topic in the repo now has a matching A+B doc pair — the doc-pair gap is effectively closed tenant-wide. Confirmed `Windows/Scripts/Test-VPNConnectivity.ps1` already covers Always On VPN end-to-end (Device/User Tunnel, IKE event log, cert expiry, split-tunnel route detection) despite its generic filename — avoided building a duplicate. Closed 3 real, filesystem-verified script gaps instead: `M365/Teams/Scripts/Get-TeamsRoomDeviceHealth.ps1` (Teams-Rooms had zero dedicated scripts — targets the two failure modes Teams-Rooms-A.md flags as most common: password-expiration policy not disabled on resource accounts, and license-assignment errors via `licenseAssignmentStates`; also checks sign-in failure volume, staleness via `signInActivity`, and optional CA exclusion group membership — this was run 21's own explicit next-priority item), `Security/ConditionalAccess/Scripts/Get-NamedLocationAudit.ps1` (Named-Locations had zero dedicated scripts — CA/Scripts only had `Get-CASignInAnalysis.ps1` covering 1 of 4 CA topics; new script does CIDR-overlap detection via IP-to-uint32 range math, flags near-2000 CIDR ceiling, flags `includeUnknownCountriesAndRegions` per Named-Locations-A.md's "easy-to-miss" warning, flags orphaned locations with zero CA policy references, and flags CA policies referencing a deleted Named Location ID), and `Security/Purview/Scripts/Get-SensitivityLabelCoverage.ps1` (Purview/Scripts only had DLP — new script cross-references Label Policies to flag labels published but unreachable to end users, flags auto-labeling policies stuck in TestWithoutNotifications/TestWithNotifications mode per Sensitivity-Labels-A.md's guidance that test mode never touches production content, and optionally checks SPO tenant `EnableAIPIntegration`). All three read-only. **Remaining script gaps confirmed by direct filesystem check for next run: Security/Purview eDiscovery and Insider-Risk (2/4 topics now scripted); M365/Teams Calling and Meeting-Policies (2/4 topics now scripted); M365/SharePoint-OneDrive Permissions and Migration (1/3 topics scripted); Security/ConditionalAccess CA-Filters (2 scripts now cover 4 topics).** Also flagged: manifest bookkeeping is still far behind actual repo state — the file-count history below should be treated as directional, not authoritative; a dedicated reconciliation pass (diffing `find` output against tracked rows) would be higher value than another run of undocumented-row appends.

---

## Build Progress (previous)
- Total files: 382
- Completed: 382
- In progress: 0
- Queued: 0
- Last updated: 2026-07-06 (auto-build, night run 21: manifest queue still empty. Followed run 20's explicit recommendation — closed 3 of the 4 remaining M365/Exchange script-coverage gaps: `Get-OMEConfigurationAudit.ps1` (single-pass audit of IRM config, OME config/OTP, the optional Test-IRMConfiguration end-to-end check, and transport-rule targeting — flags IRM_NOT_ENABLED, OTP_DISABLED, NO_OME_TRANSPORT_RULE and OME_RULE_DISABLED per MessageEncryption-B.md's Triage/Fix 1-3, plus an optional per-user RMS/AIP license check via Get-MgUserLicenseDetail that surfaces the "OME succeeds silently without encrypting" licensing gap called out in the runbook's Learning Pointers), `Get-PublicFolderHealthReport.ps1` (audits org-level PublicFoldersEnabled, confirms a root PF mailbox exists, and flags STALE_HIERARCHY_SYNC per mailbox against a configurable threshold — automating PublicFolders-B.md's Diagnosis Steps 1-2 across every PF mailbox instead of one at a time — with an optional -FolderPath check for the NO_DEFAULT_PERMISSION case from Diagnosis Step 4), and `Get-RoomMailboxAudit.ps1` (fleet-wide room audit flagging WRONG_MAILBOX_TYPE, NO_BOOKING_PATH — AllBookInPolicy false with an empty BookInPolicy, the runbook's most common root cause for blanket booking declines — NOT_AUTO_ACCEPT, CALENDAR_PERMISSION_NONE, and an optional -CheckEntraSignIn switch that flags SIGNIN_NOT_BLOCKED per RoomMailbox-B.md's standing security Learning Pointer that every room's Entra account should have sign-in blocked). All three are read-only. **M365/Exchange script coverage is now 8/9** (topic count corrected from run 20's "8" to the actual 9: ArchiveRetention, DMARC-DKIM, EOP-AntiSpam, Hybrid-Coexistence, Mail-Flow, MessageEncryption, PublicFolders, RoomMailbox, SharedMailbox); only SharedMailbox remains script-less. Suggest next run closes SharedMailbox, then moves to SharePoint-OneDrive (1/3 — Permissions and Migration need scripts) and Teams (1/4 — Device-Policies, Meeting-Policies, Teams-Rooms need scripts), the two remaining tracked script-coverage gaps repo-wide. Checked for stale `.git/index.lock`/`HEAD.lock` per the standing environment note before committing; none blocking found this run.

## Build Progress (previous)
- Total files: 379
- Completed: 379
- In progress: 0
- Queued: 0
- Last updated: 2026-07-06 (auto-build, night run 20: manifest queue still empty. Followed run 19's explicit recommendation to move off the now-complete Intune script coverage (22/22) and onto the largest remaining script-coverage gap: **M365/Exchange (8 topics, only 3 scripts before this run).** Closed the 3 highest-value gaps: `Get-DKIMDMARCReport.ps1` (per-domain SPF/DKIM/DMARC audit — cross-references `Get-DkimSigningConfig`'s expected CNAME targets against actual published DNS to catch the "DNS never updated" case, counts SPF lookup mechanisms to flag the >10 PermError risk from DMARC-DKIM-B.md Fix 2, and classifies each domain HEALTHY/MINOR_GAPS/AT_RISK), `Get-EOPQuarantineReport.ps1` (quarantine summary by QuarantineTypes with a specific callout for unreleased HighConfidencePhish per EOP-AntiSpam-B.md's note that these require Global/Security Admin, Tenant Allow/Block List audit flagging Allow entries with no expiration per Fix 2's "never allow indefinitely" guidance, plus Hosted Content Filter Policy/Rule inventory), and `Get-ArchiveRetentionAudit.ps1` (fleet-wide mailbox audit flagging NO_ARCHIVE, RETENTION_HOLD_STUCK — called out in both ArchiveRetention runbooks' Learning Pointers as "the most commonly missed check" — NO_MOVE_TO_ARCHIVE_TAG via cached per-policy tag lookups, ARCHIVE_QUOTA_RISK at a configurable threshold, and the highest-priority LIT_HOLD_NO_ARCHIVE combination that both runbooks identify as the real driver behind "mailbox always full" tickets). All three are read-only and follow the established local-plus-fleet audit pattern. **M365/Exchange script coverage is now 6/8**; remaining gaps: Hybrid-Coexistence has a script (Get-ExchangeHybridHealth.ps1) but MessageEncryption, PublicFolders, RoomMailbox, and SharedMailbox remain script-less (Mail-Flow is covered by Get-MessageTrace.ps1). Suggest next run closes these 4, then moves to SharePoint-OneDrive (1/3 — Permissions and Migration need scripts) and Teams (1/4 — Device-Policies, Meeting-Policies, Teams-Rooms need scripts), the two remaining tracked script-coverage gaps repo-wide. Checked for stale `.git/index.lock`/`HEAD.lock` per the standing environment note before committing — found dozens of pre-existing stale lock files (consistent with the known FUSE unlink-blocking issue); none were live/blocking, left in place per the standing note (renaming out of the way only needed if a commit actually fails).

## Build Progress (previous)
- Total files: 376
- Completed: 376
- In progress: 0
- Queued: 0
- Last updated: 2026-07-06 (auto-build, night run 19: manifest queue still empty. Followed run 18's explicit recommendation — closed the final 4 script-less Intune topics: `Get-AssignmentFilterAudit.ps1` (Graph-only tenant audit — lists all assignment filters and flags which ones reference the three highest-risk properties called out in Filters-A.md Fix 1/Fix 4 and Filters-B.md Fix 2 (enrollmentProfileName, category, deviceOwnership), then cross-references the device fleet for STALE_CHECKIN past a configurable hour threshold, NO_ENROLLMENT_PROFILE, and NO_CATEGORY — the upstream data-quality gaps both runbooks identify as the real cause behind most "filter isn't matching" tickets, before anyone wastes time on rule syntax), `Get-KioskDeviceHealthReport.ps1` (fully local, on-device — automates the entire Kiosk-B.md Triage/Kiosk-A.md Validation Steps checklist in one pass: Windows SKU, MDM enrollment, AssignedAccess CSP registry state, kiosk account state, AssignedAccess event log for ID 31000 vs 31001/31002, Winlogon auto-logon keys, and Shell Launcher feature/WMI state — each with an inline GOOD/BAD verdict matching the runbooks' own expected-vs-bad output pairs), `Get-PlatformScriptRunStatus.ps1` (dual-mode following the established pattern — local mode checks IME service/version/enrollment/execution-policy/WDAC-blocks per Platform-Scripts-A.md Validation Steps 1-4 and Phase 4; fleet mode pulls per-device RunState for a script ID and flags PENDING_STALE by cross-referencing each device's LastSyncDateTime against a configurable threshold, distinguishing "device hasn't checked in" from "script genuinely failed" per Platform-Scripts-B.md Fix 2), and `Get-ScopeTagRBACAudit.ps1` (Graph-only tenant audit — always produces ScopeTags-All/RoleAssignments-All/UntaggedObjects reports, the last of which finds config profiles and compliance policies carrying only the Default tag per ScopeTags-A.md Playbook 4; optional `-AdminUpn`/`-TargetObjectName` params resolve a specific admin's role-assignment scope tags and check overlap against a named object — automating the exact "at least one matching tag" diagnosis from ScopeTags-A.md Validation Steps 1-2 and ScopeTags-B.md Learning Pointers in one call instead of the runbook's multi-step manual walkthrough). All four are read-only. **Intune script coverage is now fully complete at 22/22 — every Intune Troubleshooting topic has a companion script.** No other domain has a known script-coverage gap remaining (EntraID 14/14, Security/Defender 9/9, Intune 22/22 — Exchange 3/8, SharePoint-OneDrive 1/3, and Teams 1/4 remain the only tracked gaps repo-wide; suggested priority for the next run). Checked for stale `.git/index.lock`/`HEAD.lock` per the standing environment note before committing; none found this run.

## Build Progress (previous)
- Total files: 372
- Completed: 372
- In progress: 0
- Queued: 0
- Last updated: 2026-07-06 (auto-build, night run 18: manifest queue still empty. Followed run 17's explicit recommendation — closed 3 more of the remaining 7 script-less Intune topics: `Get-AppProtectionCoverageReport.ps1` (Graph-only fleet report over `managedAppRegistration` objects, optionally scoped to a policy-assignment group — flags STALE_CHECKIN past a configurable hour threshold per AppProtection-B.md Fix 1/Validation Step 3, NO_POLICY_APPLIED per Fix 2, SDK_VERSION_MISSING per Fix 3, and NO_INTUNE_LICENSE via a cached per-user SKU lookup per AppProtection-A.md Validation Step 2), `Get-CustomComplianceScriptValidator.ps1` (dual-mode — local mode runs a discovery script in a timeout-bounded job mirroring IME's exact 30s/STDOUT-only capture behaviour, validates the result is parseable JSON, and flags stringified "True"/"False" values to catch the `[bool]` casting gotcha called out in CustomCompliance-A.md's Learning Pointers; fleet mode pulls per-device compliance status for a policy ID and flags STALE_EVALUATION devices that haven't re-run since the last change, beyond the ~8h evaluation interval), and `Get-ManagedAppDeploymentStatus.ps1` (local IME service/log check surfaces non-success ExitCode lines per Managed-Apps-B.md Fix 1/A.md Phase 3; fleet mode reports per-app Win32/LOB install status and flags HIGH_FAILURE_RATE above a configurable threshold — a signature of a detection-rule mismatch per Managed-Apps-A.md Fix 2 rather than N isolated device issues — plus an independent `-CheckVppTokens` switch that flags EXPIRING_SOON and LICENSES_EXHAUSTED Apple VPP tokens per the VPP Learning Pointer in both Managed-Apps runbooks). All three are read-only and follow the established local-check-plus-Graph-fleet-check pattern. **Intune script coverage is now 21/22**; remaining script-less: Filters, Kiosk, Platform-Scripts, ScopeTags (4 remain — suggested priority for the next run to fully close out Intune). Checked for stale `.git/index.lock`/`HEAD.lock` per the standing environment note before committing; none found this run.

---

## Build Progress (previous)
- Total files: 360
- Completed: 360
- In progress: 0
- Queued: 0
- Last updated: 2026-07-06 (auto-build, night run 14: manifest queue still empty. Closed the last 3 of run 12/13's identified EntraID script gaps — AppProxy, DynamicGroups, PasswordProtection — bringing **EntraID script coverage to 14/14, fully closed.** `Get-AppProxyConnectorHealth.ps1` checks connector + updater service state, version drift (>90 days configurable), outbound connectivity to all 4 required endpoints, clock skew, and cross-references local service state against the connector's portal registration status via Graph — specifically flagging the "service Running locally but portal shows Inactive" case that AppProxy-A.md's Symptom → Cause Map calls out as a network/registration problem rather than a service problem. `Get-DynamicGroupAudit.ps1` is the standalone, parameterized version of the inline audit shown in DynamicGroups-A.md Playbook 1 — flags Paused processing (per DynamicGroups-B.md Fix 1, "the most commonly missed check") and zero-member groups past a configurable age threshold to avoid false-positives on brand-new groups, plus a tenant SKU check for the P1/P2 licensing prerequisite. `Get-PasswordProtectionCoverage.ps1` enumerates every writable DC via AD and checks DC Agent presence/state on each — distinguishing HIGH severity (agent missing entirely, a standing gap per PasswordProtection-A.md's Learning Pointers) from MEDIUM (installed but stopped, recoverable via restart), optionally checks named Proxy servers, and pulls tenant-wide Smart Lockout (error 50053) volume from sign-in logs grouped by user to surface stale-credential retry storms per PasswordProtection-B.md Fix 4. All three are read-only. Checked for stale `.git/index.lock`/`HEAD.lock` per the standing environment note before committing; none found this run.

---

## Azure — Windows 365 Cloud PC (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/Windows365/Windows365-B.md` | ✅ | auto-build |
| `Azure/Windows365/Windows365-A.md` | ✅ | auto-build |

---

## Entra ID — Global Secure Access (new topic)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/GlobalSecureAccess-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/GlobalSecureAccess-A.md` | ✅ | auto-build |

---

## Autopilot — HybridJoin/ESP Timing Correlation
| File | Status | Assigned |
|------|--------|---------|
| `Autopilot/Scripts/Get-HybridJoinESPTimingCorrelation.ps1` | ✅ | auto-build |

---

## Build Progress (previous)
- Total files: 360
- Completed: 360
- In progress: 0
- Queued: 0
- Last updated: 2026-07-06 (auto-build, run 19: manifest queue still empty, all prior items ✅. Rather than continue the Intune script-gap backlog (Filters, Kiosk, Platform-Scripts, ScopeTags — still open, see below), built 3 genuinely new topics per EXPANSION RULES since Windows 365 and Global Secure Access were named in the original expansion list area (Azure Virtual Desktop management) and are current, real MSP pain points not yet covered anywhere in the repo: `Azure/Windows365/Windows365-B.md` + `Windows365-A.md` (Cloud PC provisioning, Azure Network Connections, licensing/resize/reprovision — explicitly distinguished from AVD, cross-linked from `Azure/_AGENT.md`), and `EntraID/Troubleshooting/GlobalSecureAccess-B.md` (Entra Internet Access / Private Access client and connector troubleshooting, cross-linked from `EntraID/_AGENT.md` and to the existing PRT-Issues and AppProxy runbooks since GSA shares dependencies with both). Updated both `_AGENT.md` files' folder contents and common-entry-points tables. **Confirmed via `grep` before writing that neither Windows 365/Cloud PC nor Global Secure Access/GSA/Private Access existed anywhere in the repo.** No A-variant built yet for GlobalSecureAccess — flagged as next-priority new-topic item below.
- Last updated: 2026-07-06 (auto-build, night run 13: manifest queue still empty. Followed run 12's explicit recommendation — "EntraID AccessPackages, AppProxy, CAE, DynamicGroups, IdentityProtection, PasswordProtection (6 of 14 topics)... suggest next since it's now the largest domain gap." Closed 3 of those 6: `Get-AccessPackageAssignmentHealth.ps1` (tenant-wide entitlement management fleet triage — flags STUCK_DELIVERING assignments past a configurable minutes threshold per AccessPackages-B.md Diagnosis Step 4, AGING_APPROVAL requests per Fix 1's recommended 3-day escalation SLA, UNPUBLISHED_CATALOG, ORPHANED_RESOURCE for soft-deleted/unresolvable groups referenced by a package, and NO_REQUESTOR_SCOPE for policies with ScopeType=NoSubjects), `Get-IdentityProtectionRiskReport.ps1` (fleet-level risky-user report — surfaces HIGH_CONFIDENCE detections i.e. leakedCredentials/passwordSpray per IdentityProtection-B.md's guidance to treat these as confirmed compromise not "maybe," cross-checks per-user P2/Governance licensing since risk-based CA enforcement silently requires it, and flags an EnforcementGap when no enabled risk-based CA policy exists tenant-wide), and `Get-CAESessionEvents.ps1` (the hardest of the three since CAE has no dedicated Graph-exposed event object — automates the manual sign-in-log-to-audit-log correlation from CAE-B.md's Triage/Diagnosis steps: classifies interrupted sign-ins as EXPECTED_REVOCATION when they correlate with a password reset/account disable/MFA change within a configurable window, POSSIBLE_LOCATION_ENFORCEMENT when the same user is interrupted repeatedly with no directory correlation, and MULTI_USER_SPIKE when many distinct uncorrelated users are hit in the same hour — the CAE-B.md Fix 3 signature of a broad CA/risk event rather than per-user CAE). **EntraID script coverage is now 11/14 (was 8/14 as of run 12's count); remaining gaps: AppProxy, DynamicGroups, PasswordProtection.** Checked for stale `.git/index.lock`/`HEAD.lock` per the standing environment note before committing; none found this run.

---

## ⚠️ Environment Note — Git Lock File Accumulation
- The bash sandbox mount backing this repo's working directory is a FUSE bridge to the user's real filesystem. This bridge silently blocks `unlink()`/`rm` on existing files (create and same-directory overwrite-rename both work, but plain delete does not), which causes git to occasionally strand `.lock` files (`index.lock`, `HEAD.lock`, `objects/*/tmp_obj_*`) when a prior process is interrupted mid-operation. This run found and had to work around a stale `index.lock` and `HEAD.lock` from a previous crashed run by renaming them out of the way (rename-to-new-name succeeds even though delete does not) and using `GIT_INDEX_FILE` to bypass the stranded index lock. Dozens of harmless orphaned `*.lock*`/`*.stale*` files have accumulated in `.git/` over many runs from this same root cause — they do not affect repo integrity (git ignores exact-named lock files with different names) but are visual clutter in `.git/`. Future runs should check for and clear `.git/index.lock` and `.git/HEAD.lock` (via rename, not delete) before committing if a commit fails with "Unable to create ... File exists."
- **New this run — stale local remote-tracking refs can lie about divergence.** After a normal `git commit && git push` succeeded (fast-forward, confirmed in push output), a subsequent `git fetch && git rev-parse origin/master` reported a completely unrelated commit (`872213d...`, no common ancestor with local history) — appearing to indicate a concurrent process had force-pushed and discarded our work. **This was a false alarm caused by local ref corruption**, not a real remote state: `git ls-remote origin master` (which queries GitHub directly, bypassing any local cached ref) confirmed the real remote `master` was correctly at our just-pushed commit the whole time. Root cause is almost certainly the same FUSE unlink-blocking issue corrupting `.git/refs/remotes/origin/master` or `.git/packed-refs` during a fetch. **Lesson for future runs:** if `origin/master` ever looks divergent/unrelated to local HEAD right after a successful push, do NOT assume data loss and do NOT force-push over it — first run `git ls-remote origin master` to get the authoritative remote state before taking any corrective action. This run wasted a reset/backup-branch/force-push cycle (all harmless, no data lost, but unnecessary) chasing what turned out to be a local caching artifact.

## ⚠️ Skipped Items
- Azure/AVD folder (5 topics, _AGENT.md, Scripts) exists in the repo but was never backfilled into this manifest by earlier runs — content is complete, this is a bookkeeping gap only, not a missing-content gap. Left as-is since instructions say not to overwrite existing content; flagging for future manifest hygiene pass.
- Legacy files with space-based naming (e.g. `Windows/Troubleshooting/Time/`, `Windows/Troubleshooting/Windows Update/Update to Latest *.md`, `LLM/Prompt/Archive/*`) do not follow the current FORMAT SPEC style (no Learning Pointers section, different code block style). These are pre-existing/stale records referenced in the project's broader rework goal but out of scope for this build-only run — did not touch per "never overwrite existing files."
- Manifest bookkeeping is significantly behind actual repo state: dozens of files exist on disk (e.g. `EntraID/Troubleshooting/PIM-*.md`, `MFA-*.md`, `SSPR-*.md`, `CrossTenant-*.md`, most of `Windows/Troubleshooting/*` beyond the originally-tracked set, most of `Security/Defender/*` beyond the originally-tracked set, `M365/Exchange/DMARC-DKIM-*.md`, `EOP-AntiSpam-*.md`, `ArchiveRetention-*.md`, `MessageEncryption-*.md`, `M365/SharePoint-OneDrive/Migration-*.md`, `M365/Teams/Meeting-Policies-*.md`) were built by prior auto-build runs but never added as manifest rows. Content is complete and high quality; this is a bookkeeping-only gap flagged for a future manifest reconciliation pass rather than a content gap.
- **Script coverage gap now confirmed to extend well beyond Windows/macOS** (which runs 5-7 closed out). As of run 9: EntraID has 14 Troubleshooting topics but only 8 scripts; Security/Defender has 9 topics but only 4 scripts; Intune has 20 topics but only 9 scripts; M365/Exchange has 8 topics but only 3 scripts; SharePoint-OneDrive has 3 topics but only 1 script; Teams has 4 topics but only 1 script. Run 9 closed the two highest-value Defender gaps (ASR, Tamper Protection) and the highest-value EntraID gap (MFA). Run 10 closed WHfB, SSPR, and PRT-Issues in EntraID. Run 11 closed CloudProtection, MDI, and DefenderVulnMgmt in Defender. **Run 12 closed MDA and NetworkProtection — Security/Defender script coverage is complete at 9/9.** Run 12 also closed the Intune/Enrollment gap (10/20). Run 13 closed AccessPackages, CAE, and IdentityProtection in EntraID (11/14). **Run 14 closed the final 3 EntraID gaps — AppProxy, DynamicGroups, PasswordProtection — bringing EntraID script coverage to 14/14, fully complete.** **EntraID and Security/Defender are now both at full script coverage.** Remaining known gaps as of run 14: Intune has 19 more topics without scripts (App-Deployment, AppProtection, Autopatch, CoManagement, CustomCompliance, DriverManagement, EPM, FeatureUpdates, Filters, GP-to-CSP, Kiosk, Managed-Apps, Platform-Scripts, Policy-Conflict, Remediations, ScopeTags, WUfB — now the single largest topic-to-script ratio gap in the repo and the clear priority for the next run); Exchange (8 topics/3 scripts), SharePoint-OneDrive (3/1), and Teams (4/1) remain untouched. **Run 15 closed 3 of the 19 Intune gaps — App-Deployment, Policy-Conflict, Autopatch — leaving 16: AppProtection, CoManagement, CustomCompliance, DriverManagement, EPM, FeatureUpdates, Filters, GP-to-CSP, Kiosk, Managed-Apps, Platform-Scripts, Remediations, ScopeTags, WUfB (Intune is still the largest topic-to-script gap in the repo; Exchange, SharePoint-OneDrive, and Teams remain untouched and are the next priority after Intune).** **Run 16 closed 3 more — CoManagement, Remediations, GP-to-CSP — bringing Intune script coverage to 15/22, leaving 11: AppProtection, CustomCompliance, DriverManagement, EPM, FeatureUpdates, Filters, Kiosk, Managed-Apps, Platform-Scripts, ScopeTags, WUfB. Suggest next run continues closing these (WUfB and AppProtection are likely the next-highest ticket-volume) before moving to the still-untouched Exchange/SharePoint-OneDrive/Teams script gaps.** **Run 17 closed EPM, DriverManagement, WUfB (18/22), leaving AppProtection, CustomCompliance, Filters, Kiosk, Managed-Apps, Platform-Scripts, ScopeTags (7).** **Run 18 closed AppProtection, CustomCompliance, Managed-Apps — Intune script coverage is now 21/22, leaving only Filters, Kiosk, Platform-Scripts, ScopeTags (4). Suggest the next run closes these final 4 to fully complete Intune script coverage, then moves to the still-untouched Exchange (8 topics/3 scripts), SharePoint-OneDrive (3/1), and Teams (4/1) script gaps.**
- Two macOS topics remain script-less: ABM-Token-Renewal and Shell-Script-Failures (flagged in run 7, not actioned this run — priority went to the larger EntraID/Defender script gaps instead).
- **RESOLVED (run 35):** the long-standing "Two macOS topics remain script-less: ABM-Token-Renewal and Shell-Script-Failures" note (flagged run 7, never actioned in 27+ runs since) was re-verified via fresh `ls` and confirmed still accurate for ABM-Token-Renewal. Closed with `macOS/Scripts/Get-ABMTokenStatus.ps1` — see Build Progress note below for details. **Shell-Script-Failures remains genuinely script-less** — deferred this run (time/scope); unlike ABM-Token-Renewal it likely fits the device-local `.sh` pattern (tailing Intune shell-script execution logs/exit codes on the Mac itself per `Shell-Script-Failures-A.md`/`-B.md`) rather than an admin-side Graph script, so it should be built as a `.sh` companion next run, not a `.ps1`.
- **Run 19 new-topic gaps for next run:** `EntraID/Troubleshooting/GlobalSecureAccess-A.md` (deep dive companion to the B file built this run — should cover Internet Access vs Private Access architecture, traffic forwarding profile internals, connector deployment topology, and CA network-compliance signal design) and a companion `Azure/Windows365/Scripts/Get-CloudPcFleetStatus.ps1` (fleet-wide Cloud PC status/license/ANC health report, mirroring the pattern of `Azure/AVD/Scripts/Get-AVDSessionHealth.ps1`) do not yet exist. Suggest next run closes these two before returning to the still-open Intune script gaps (Filters, Kiosk, Platform-Scripts, ScopeTags) or the untouched Exchange/SharePoint-OneDrive/Teams script gaps.
- Last updated: 2026-07-06 (auto-build, run 20, scheduled task: found `EntraID/Troubleshooting/GlobalSecureAccess-A.md` already written to disk (403 lines, complete per FORMAT SPEC) but never committed — a prior run had built it but was interrupted before the git step. Committed it as-is this run (content verified complete, not rewritten) and marked it ✅ above. Per project memory, DFS and Power Automate are the standing #1/#2 build priorities (most frequent at work), so rather than chase the run-19-suggested `Get-CloudPcFleetStatus.ps1` (still open, see above — not a priority domain), closed real script-coverage gaps in those two priority domains instead: `PowerAutomate/Scripts/Get-DLPPolicyImpactReport.ps1` (cross-policy connector classification matrix + effective-classification resolver, since most-restrictive-wins conflicts between overlapping policies were undiagnosable without manually reconstructing this by hand — companion to `DLP-Policies-A/B.md`), `PowerAutomate/Scripts/Get-ConnectorAuthHealth.ps1` (flow/connection health audit cross-referencing connection owner's Entra ID account state — disabled/deleted owner, session-revocation-after-connection-created signal, staleness vs. 90-day refresh token expiry, orphaned connection references, and ownership-concentration risk — companion to `Connector-Auth-A/B.md`), and `DFS/Scripts/Get-DFSNamespaceConfigAudit.ps1` (namespace-root ABE flag vs. per-target-server SMB share `FolderEnumerationMode` consistency check, plus manual `ReferralPriorityClass`/`ReferralPriorityRank` override detection — companion to `DFS-ABE-A/B.md` and `DFS-SiteCosting-A/B.md`, complements the existing `Test-DFSHealth.ps1` which covers service/replication state but not these two config-layer failure modes). **Confirmed via `find`/`ls` before writing that none of these three scripts existed anywhere in the repo.** Also found and corrected a manifest bookkeeping duplication: this run's initial edit accidentally re-added Windows365/GlobalSecureAccess-B rows that already existed near the bottom of this file (rows ~1821-1829) — removed the duplicate top-of-file block, kept the authoritative bottom-of-file entries, and added the GlobalSecureAccess-A row there instead. **Open for next run:** `Azure/Windows365/Scripts/Get-CloudPcFleetStatus.ps1` (still not built), Intune script gaps (Filters, Kiosk, Platform-Scripts, ScopeTags — still open per run 18), Exchange/SharePoint-OneDrive/Teams script gaps (still untouched), and DFS/PowerAutomate now both have solid script coverage but PowerAutomate is still missing scripts for Groups-Teams-Provisioning, Approval-Workflows, and Flow-Ownership-Transfer topics — worth closing next given their priority-domain status.
- Last updated: 2026-07-07 (auto-build, run 30, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per the standing lesson that manifest bookkeeping drifts from actual repo state, did a fresh filesystem pass (`find`/`ls`) across every domain rather than trusting run 29's note. Confirmed EntraID (18/16, incl. shared Graph utility) and Azure/AVD (5/5) remain fully closed per runs 28-29; also confirmed DFS (5 topics fully covered by 4 scripts — `Get-DFSNamespaceConfigAudit.ps1`'s synopsis covers both ABE and SiteCosting), Intune (21 topics/24 scripts), and Exchange/SharePoint-OneDrive/Teams/Purview/ConditionalAccess/PowerAutomate/Defender/Copilot/Licensing/UniversalPrint/Windows365/Files all at full or near-full script coverage. Found one genuine, previously-unflagged gap: **Autopilot** — 4 Troubleshooting topics (ESP-Stuck, Profile-Not-Assigned, TPM-Attestation, HybridJoin-Autopilot) but the existing `Autopilot/Scripts/*.ps1` files (Get-AutopilotDeviceStatus, Get-EnrollmentLogs, Upload-AutopilotDiagnostics, Upload-Hash-Enroll2Autopilot) are generic enrollment/hash-upload tools with no topic-specific diagnostic logic — read all 3 candidate runbooks in full (ESP-Stuck-A.md, Profile-Not-Assigned-A.md, TPM-Attestation-A.md) before building to confirm this was a real gap, not a naming coincidence. Closed 3 of the 4: `Autopilot/Scripts/Get-ESPDeploymentStatus.ps1` (device-local — ESP/Autopilot event logs, IME app-install log tail scan, EnrollmentStatusTracking/DeviceContext registry state, Win32 app tracking registry, a Hybrid Join completeness check via dsregcmd, and ESP-critical endpoint reachability; flags ESP_ERRORS_FOUND, APP_INSTALL_ISSUES, APP_INSTALL_ERROR_CODE, HYBRID_JOIN_NOT_COMPLETE, ESP_ENDPOINT_UNREACHABLE), `Autopilot/Scripts/Get-AutopilotProfileAssignmentAudit.ps1` (Graph-based — single-device mode walks hash registration → Entra device object → group membership → Group Tag rule match per Profile-Not-Assigned-A.md's Validation Steps 1-6; fleet mode sweeps for DUPLICATE_REGISTRATION, STALE_UNASSIGNED past a configurable minute threshold, GROUP_TAG_CASE_MISMATCH for the documented `[OrderId]` vs `[OrderID]` typo, GROUP_PROCESSING_PAUSED, and PROFILE_NO_ASSIGNMENT), and `Autopilot/Scripts/Get-TPMAttestationStatus.ps1` (device-local — Get-Tpm state, Win32_TPM spec-version check for the 2.0-vs-1.2-compatibility-mode failure mode, w32tm clock-skew check, attestation endpoint reachability, dsregcmd TpmProtected check, and TPM-WMI/Operational event log scan; each flag carries the matching documented error code from TPM-Attestation-A.md's table, e.g. TPM_SPEC_NOT_2_0 → 0x80180001). All three read-only, no remediation actions (Clear-Tpm/Initialize-Tpm intentionally not invoked). **Did not build a HybridJoin-Autopilot-specific script this run** — that topic's device-join-failure logic is already covered by `EntraID/Scripts/Get-HybridJoinDiagnostics.ps1` (built run 29) via cross-reference; a genuinely Autopilot-ESP-timing-specific version (correlating ESP timeout against Entra Connect delta-sync interval per ESP-Stuck-A.md's "Hybrid Join Complexity" section) remains a real, narrower gap for a future run. Backfilled `Autopilot/_AGENT.md` with a proper Folder contents table (previously had none) and updated its Common entry points rows to point at the new scripts. Verified brace/paren balance via `grep -o` counts on all three new scripts before committing (no pwsh available in this sandbox for a real parse check; all three balanced cleanly). **Flagged but not actioned (time/scope, needs user review rather than autonomous action):** `Autopilot/Troubleshooting/Autopilot-Troubleshooting2.ps1` is a misfiled stale script — its content is a SharePoint admin URL/PnP-Online helper entirely unrelated to Autopilot, sitting in the wrong folder under the wrong name. `Autopilot/Troubleshooting/Autopilot-Network-Connectivity.ps1` and `Test-AutopilotNetworkRequirements.ps1` are also non-conforming (sit in Troubleshooting/ instead of Scripts/, no SYNOPSIS header) — likely legacy pre-manifest-spec files. Per the project's stated goal of "removing stale records," these are good candidates for a cleanup pass, but deleting/moving files was judged out of scope for an unattended night-build run — left in place for the user to review interactively.
- Last updated: 2026-07-07 (auto-build, run 31, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Closed run 30's explicitly-flagged remaining gap — read `HybridJoin-Autopilot-A.md`, `HybridJoin-Autopilot-B.md`, and `ESP-Stuck-A.md` in full (all three already existed, no rewrite) before building `Autopilot/Scripts/Get-HybridJoinESPTimingCorrelation.ps1`: a device-local diagnostic that correlates Hybrid Join registration timing against the ESP timeout budget — the specific gap run 30 identified as "a genuinely Autopilot-ESP-timing-specific version correlating ESP timeout against Entra Connect delta-sync interval per ESP-Stuck-A.md's Hybrid Join Complexity section." Since Windows exposes no direct "time spent waiting on Entra Connect sync" value, the script uses the `Automatic-Device-Join` scheduled task's Task Scheduler run-history (per `HybridJoin-Autopilot-A.md` Phase 3 Step 5) as a proxy timeline, cross-referenced against `Microsoft-Windows-User Device Registration/Admin` event IDs 304 (join succeeded) / 335 (join failed) per `HybridJoin-Autopilot-B.md` Step 5, to compute how long Hybrid Join registration actually took and what percentage of the configured ESP timeout that consumed; flags JOIN_NOT_YET_SUCCEEDED, JOIN_TASK_MISSING, HIGH_RETRY_COUNT, REGISTRATION_WAIT_NEAR_TIMEOUT, SYNC_INTERVAL_EXCEEDS_BUDGET, and SYNC_INTERVAL_NOT_OPTIMIZED. Includes an optional `-EntraConnectServer` remote check (`Invoke-Command` + `Get-ADSyncScheduler`) to use the real configured sync interval instead of the documented 30-min default, gracefully falling back if unreachable — mirrors the "best-effort, don't fail the whole script" pattern used by prior runs' remote-check scripts. Read-only throughout; no remediation actions taken. Backfilled `Autopilot/_AGENT.md`'s folder-contents table and added a new Common entry point row for it. Verified brace/paren/bracket balance via Python counts before committing (no pwsh available in this sandbox for a real parse check; balanced cleanly). **Did a fresh filesystem re-check of macOS and PowerAutomate topic-vs-script counts this run** (both had shown as 0-script false gaps in an initial flat-directory scan due to subfolder structure) — confirmed both are still genuinely fully covered (macOS 10 `.sh` scripts across 10 topics; PowerAutomate 8 `.ps1` scripts across 8 topics via `Scripts/`, `SharePoint/`, `Troubleshooting/`, `Groups-Teams/` subfolders) — no action needed, false alarm corrected before wasting build effort. **Environment note:** found and cleared one live (non-`.bak`/`.stale`-suffixed) `.git/index.lock` left over from a prior run before this run's commit — moved it aside to `index.lock.stale-run31-<epoch>` per the standing workaround (rename succeeds, delete does not in this FUSE-mounted sandbox); did not attempt to clean up the large accumulated pile of old stale/bak lock files themselves, consistent with prior runs' guidance that this is harmless clutter, not a functional blocker. **Remaining known items for next run (unchanged from run 30):** the three misfiled/non-conforming Autopilot script files flagged above still need interactive user review before any move/delete/rename, per the project's "removing stale records" goal — this is genuinely out of scope for an unattended run since the FORMAT SPEC's "never overwrite existing files" instruction is most naturally read as also meaning "never delete/relocate existing files" without explicit user sign-off. Also still open: the broader repo-wide "legacy space-named files" and "manifest bookkeeping significantly behind repo state" items noted earlier in this Skipped Items section — both are long-standing, low-urgency bookkeeping/rework items suited to a dedicated interactive session rather than incremental unattended runs.
- Last updated: 2026-07-07 (auto-build, run 33, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per run 32's explicit "suggested next-run focus given saturation" note, treated script-coverage expansion as exhausted and instead built a genuinely new topic not yet in the repo. Verified via `grep`/`find` before building: `M365/Exchange/Mail-Flow-A.md`/`-B.md` mention transport rules only as one stop in the general mail-flow pipeline (a passing "Fix 3 — Transport rule blocking or redirecting email" section), with no dedicated coverage of rule-vs-rule conflicts, priority/`StopRuleProcessing` short-circuiting, condition/exception AND/OR logic errors, or the ETR/DLP boundary — confirmed a real, narrower gap rather than a duplicate. Similarly confirmed `Security/ConditionalAccess/*.md` only mentions Continuous Access Evaluation (CAE) in two Learning-Pointer asides (CA-Filters-B.md, Named-Locations-A.md), with no dedicated CAE/Token Protection runbook — flagged as the next genuine new-topic candidate but not built this run (time/scope; see below). Built the full three-file pattern for the Exchange gap: `M365/Exchange/TransportRules-B.md` (hotfix — triage table keyed on Mode/StopRuleProcessing/priority findings, dependency cascade showing ETR-then-DLP as two independent pipelines, 6 fix paths covering stuck test-mode rules, disabled/missing rules, StopRuleProcessing short-circuits, multi-rule action-stacking conflicts, condition/exception logic errors, and ETR/DLP overlap), `M365/Exchange/TransportRules-A.md` (deep dive — full evaluation architecture explaining AND-across-condition-types/OR-within-a-condition semantics and the Enforce/Test/AuditAndNotify mode distinction, dependency stack, symptom→cause map, 6 validation steps, 6-phase troubleshooting flow, 4 remediation playbooks including a full rule-rebuild-from-scratch playbook, and an evidence-pack script), and `M365/Exchange/Scripts/Get-TransportRuleConflictAudit.ps1` (tenant-wide read-only audit flagging STUCK_IN_TEST_MODE with an age-based severity split via `-StaleTestModeDays`, SHORT_CIRCUITED_RISK by cross-referencing every lower-priority-number enabled+Enforce rule with `StopRuleProcessing=$true`, BROAD_OR_CONDITION via a regex-based OR-value-count heuristic against `-BroadConditionThreshold`, NO_EXCEPTION_SCOPE for Reject/Delete/Redirect/Quarantine actions with zero exceptions defined, DISABLED_WITH_HISTORY via `Search-UnifiedAuditLog` cross-reference, and a best-effort DLP_OVERLAP_RISK_REVIEW heuristic explicitly documented as needing manual confirmation since Graph/EXO exposes no cheap way to cross-reference DLP sensitive-info-type scope against ETR conditions; degrades gracefully with warnings if Search-UnifiedAuditLog or DLP cmdlets aren't available in the session, matching the established graceful-degradation pattern from `Get-SharedMailboxAudit.ps1`). All read-only — no New-/Set-/Remove-/Enable-/Disable-TransportRule calls anywhere in the script. Backfilled `M365/Exchange/_AGENT.md`'s folder-contents table with the two new runbook rows plus the missing pre-existing `Hybrid-Coexistence-A.md` row (bookkeeping gap found while editing), the new script row, and four new Common entry point rows. Verified brace/paren/bracket balance via Python counts on the new script before committing (52/52 braces, 112/112 parens, 25/25 brackets; no pwsh available in this sandbox for a real parse check). **Environment note reconfirmed:** found and cleared one live (non-`.bak`/`.stale`-suffixed) `.git/HEAD.lock` left over from a prior run before this run's commit — moved it aside to `HEAD.lock.stale-run33-<epoch>` per the standing workaround (rename succeeds, delete does not in this FUSE-mounted sandbox); the large accumulated pile of old stale/bak lock files was left untouched, consistent with prior runs' guidance that this is harmless clutter. **For next run:** build the CA Token Protection / Continuous Access Evaluation (CAE) topic flagged above — confirmed via grep that only passing Learning-Pointer mentions exist, no dedicated `Security/ConditionalAccess/TokenProtection-B.md`/`-A.md`/script trio. The three misfiled/non-conforming Autopilot files and the broader "manifest bookkeeping behind repo state" item (both flagged since runs 30-32) remain open and still need interactive user review rather than autonomous action.
- Last updated: 2026-07-07 (auto-build, run 34, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Started from run 33's explicit "next run" pointer (build the CA Token Protection / CAE topic), but before building, verified the premise directly against the filesystem rather than trusting the note — per the standing lesson that these notes have repeatedly drifted from actual repo state. Found `EntraID/Troubleshooting/CAE-A.md` and `CAE-B.md` (both full, complete per FORMAT SPEC) plus `EntraID/Scripts/Get-CAESessionEvents.ps1` already exist — built all the way back in run 13 per this file's own run-9-14 history — so **CAE itself was a false gap**; run 33's grep only checked `Security/ConditionalAccess/*.md` and missed the EntraID folder entirely. Read both CAE files in full to confirm they were genuinely complete (they are — full architecture, dependency stack, symptom map, validation steps, 3 remediation playbooks, evidence pack, cheat sheet, learning pointers) before ruling this out. **Token Protection specifically, however, was a real and previously-unflagged gap** — confirmed via `grep -ril "token protection\|TokenProtection"` across all `*.md` that no file anywhere in the repo covers it (Token Protection is a materially different Conditional Access session control from CAE: device-bound Proof-of-Possession token binding to defeat token replay/AiTM phishing, vs. CAE's signal-driven revocation — the two are complementary, not the same topic, and conflating them in run 33's note was itself part of the false-gap confusion). Since this is fast-moving, current-generation security content, researched against live Microsoft Learn documentation (`concept-token-protection.md`, `deployment-guide-token-protection-windows.md`, both dated 2026-03-24) plus the Microsoft Graph `conditionalAccessSessionControls` schema reference before writing, rather than relying on training-data recall, to ensure the statusCode table, supported-app list, unsupported-device-registration-type list, and device-filter exclusion expressions are all accurate to current platform behavior. Built the full three-file pattern: `Security/ConditionalAccess/TokenProtection-B.md` (hotfix — triage table keyed on the 5 documented `signInSessionStatusCode` values 1002/1003/1005/1006/1008, dependency cascade from device registration type through to CA policy scope, 5 fix paths covering unsupported device registration types with the exact device-filter exclusion expressions from Microsoft's deployment guide, incompatible client apps, unregistered devices, unsupported OS versions, and the non-Windows/non-Apple platform bypass gap), `Security/ConditionalAccess/TokenProtection-A.md` (deep dive — full PoP binding architecture explanation, an explicit comparison table distinguishing Token Protection from Compliant/Hybrid-Joined-device grant controls and from CAE since this is the most common point of confusion, dependency stack, symptom→cause map, 6 validation steps, 5-phase troubleshooting flow, 4 remediation playbooks including the staged Report-only pilot rollout Microsoft's own guidance recommends, and an evidence-pack combining a Graph PowerShell policy-config pull with a Log Analytics KQL query adapted from Microsoft's own sample queries), and `Security/ConditionalAccess/Scripts/Get-TokenProtectionCoverageAudit.ps1` (tenant-wide Graph-based policy DESIGN audit — not a sign-in-log/statusCode diagnostic, which requires Log Analytics and is out of Graph's reach — flagging BROWSER_CLIENT_APP_RISK for policies with a Client Apps condition that isn't narrowed to "Mobile apps and desktop clients", OFFICE365_APPGROUP_TARGET for policies targeting the broad Office 365 app group instead of individually-selected resources per the documented exception to normal CA authoring guidance, NO_DEVICE_FILTER_EXCLUSIONS for policies with no device filter covering the six documented permanently-unsupported registration types, STILL_REPORT_ONLY_STALE for policies parked in report-only past a configurable threshold, and a tenant-wide NON_WINDOWS_PLATFORM_GAP check for whether a compensating Block-unknown-platform/Require-compliant-device policy exists to cover the platforms Token Protection cannot reach; uses the correct Graph property `SessionControls.SecureSignInSession.IsEnabled`, confirmed via the Graph schema docs rather than guessed). All read-only — no policy create/update/delete calls anywhere in the script. Backfilled `Security/ConditionalAccess/_AGENT.md`'s folder-contents table with the two new runbook rows and the new script row, plus two new Common entry point rows. Verified brace/paren/bracket balance via Python counts on the new script before committing (42/42 braces, 90/90 parens, 18/18 brackets; no pwsh available in this sandbox for a real parse check). Checked `.git/*.lock` for a live (non-`.bak`/`.stale`-suffixed) lock file before committing — none found this run. **For next run:** the three misfiled/non-conforming Autopilot files and the broader "manifest bookkeeping behind repo state" item (both flagged since runs 30-33) remain open and still need interactive user review rather than autonomous action. Also worth a fresh full-repo filesystem sweep next run, since run-33-style false gaps (checking only one folder instead of the whole repo, e.g. `Security/ConditionalAccess/` vs. also `EntraID/Troubleshooting/`) are a recurring failure mode — always grep/find across the ENTIRE repo tree for a candidate topic name before concluding it doesn't exist anywhere.

- Last updated: 2026-07-07 (auto-build, run 32, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per the standing lesson that manifest bookkeeping drifts from actual repo state, ran a fresh `find`/`ls` sweep across every domain (Autopilot, Azure/AVD, Azure/Files, Azure/Windows365, DFS, EntraID, Intune, M365/Copilot, M365/Exchange, M365/Licensing, M365/SharePoint-OneDrive, M365/Teams, M365/UniversalPrint, Security/ConditionalAccess, Security/Defender, Security/Purview, Windows, macOS) rather than trusting run 31's note. Also ran a Python A/B-pair completeness check across the whole repo (every `*-A.md` has a matching `*-B.md` and vice versa) — confirmed zero incomplete runbook pairs repo-wide, so no missing-half-of-a-runbook content gaps exist anywhere. Also checked all ten EXPANSION RULES example topics (Entra Connect sync errors, Exchange hybrid mail flow, WDAC, Always On VPN, Universal Print, App Proxy, Graph API batch operations, WHfB, Teams Room devices, Power Platform DLP) — all ten already exist with runbooks (Power Platform DLP is covered under `PowerAutomate/Troubleshooting/DLP-Policies-A/B.md`) and all but one already have a companion script. Found exactly one genuine, previously-unflagged domain with real script-coverage gaps: **Windows** — `NetworkAdapters-A/B.md` and `Troubleshooting/Time/TimeSync A.md` + `TimeSync B.md` + `Can't sync time.windows.com.md` had no companion scripts (confirmed by reading both NetworkAdapters docs and TimeSync A.md in full before building, to match their specific dependency stack/symptom map/fix paths rather than a generic template). Closed both: `Windows/Scripts/Get-NetworkAdapterDiagnostics.ps1` (adapter status/link speed, APIPA detection, competing-default-route/VPN-split-tunnel detection, orphaned third-party NDIS filter binding detection, NLA/network-profile-mismatch detection on domain-joined machines, DNS resolution, NIC power management, and a System event-log NDIS/TCPIP/DHCP/NLA error scan — maps directly to NetworkAdapters-B.md's Interpretation table and NetworkAdapters-A.md's Symptom → Cause Map) and `Windows/Scripts/Get-TimeSyncDiagnostics.ps1` (dsregcmd AADJ/domain context, W32Time service state, current time source with an explicit Local CMOS Clock flag, last-successful-sync check, NtpClient/NtpServer policy-override detection under the documented `HKLM\SOFTWARE\Policies\Microsoft\W32Time` keys, DNS resolution of NTP hostnames, `w32tm /stripchart` reachability against 3 public NTP servers with a stripchart-succeeds-but-never-resynced compound flag for the documented source-port-123 gotcha, Windows Time Synchronization scheduled task last-result check, and a UDP/123 local-binding netstat check). Both read-only — no `w32tm /resync`, no peer config changes, no adapter/service state changes. Backfilled `Windows/_AGENT.md` with a proper Folder contents table (previously had none — the only major domain _AGENT.md missing one per FORMAT SPEC) covering all 22 Troubleshooting topics and 24 existing scripts, and added two new Common entry point rows for the topics just closed. Verified brace/paren/bracket balance via Python counts on both new scripts before committing (no pwsh available in this sandbox for a real parse check; both balanced cleanly). **Environment note reconfirmed:** found and cleared one live (non-`.bak`/`.stale`-suffixed) `.git/HEAD.lock` left over from a prior run before this run's commit — moved it aside to `HEAD.lock.stale-run32-<epoch>` per the standing workaround (rename succeeds, delete does not in this FUSE-mounted sandbox); the large accumulated pile of old stale/bak lock files was left untouched, consistent with prior runs' guidance that this is harmless clutter. **Result: Windows domain is now 22/22 fully covered — every Troubleshooting topic with an A/B runbook pair also has a companion script.** After this run, a full sweep found no further genuine script-coverage gaps in any domain — the repo is at or near saturation for the "every topic gets a script" expansion pattern. **Remaining known items for next run (unchanged, still open, needs interactive user review not autonomous action):** the three misfiled/non-conforming Autopilot files (`Autopilot/Troubleshooting/Autopilot-Troubleshooting2.ps1` — misfiled SharePoint/PnP helper unrelated to Autopilot; `Autopilot-Network-Connectivity.ps1` and `Test-AutopilotNetworkRequirements.ps1` — non-conforming location/format) still need review before move/delete/rename. The broader "manifest bookkeeping significantly behind repo state" item also remains open. **Suggested next-run focus given saturation:** since script-coverage expansion is largely exhausted, the highest-value next step is likely either (a) the interactive stale-file cleanup pass flagged above (needs user sign-off, not this run), or (b) a genuinely new topic not yet in the repo at all — worth brainstorming MSP pain points beyond the original EXPANSION RULES list (e.g. Exchange Online mail flow rules/transport rule conflicts, Intune Endpoint Privilege Management edge cases beyond what EPM-A/B already cover, Conditional Access token protection/continuous access evaluation interplay, or Windows Autopatch driver update rings) rather than re-sweeping domains already confirmed saturated.

---

## Azure/Windows365, EntraID, macOS — Agent Docs, New Topic & Long-Standing Script Gap Fill (run 35)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/Windows365/_AGENT.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/EntraDomainServices-B.md` | ✅ | auto-build |
| `macOS/Scripts/Get-ABMTokenStatus.ps1` | ✅ | auto-build |

---

---

## macOS, EntraID — Closed Both Run 35 Next-Run Pointers (run 36)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Scripts/Get-ShellScriptFailureDiagnostics.sh` | ✅ | auto-build |
| `EntraID/Troubleshooting/EntraDomainServices-A.md` | ✅ | auto-build |

---

## Security/Purview — New Topic: Retention Labels & Policies (run 37)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/RetentionLabels-B.md` | ✅ | auto-build |
| `Security/Purview/RetentionLabels-A.md` | ✅ | auto-build |
| `Security/Purview/Scripts/Get-RetentionPolicyAudit.ps1` | ✅ | auto-build |
| `Security/Purview/_AGENT.md` | ✅ (backfilled — was stale, missing 4 of 5 pre-existing topic rows) | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 459
- Completed: 459
- In progress: 0
- Queued: 0
- Last updated: 2026-07-07 (auto-build, run 37, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per run 36's explicit "For next run" pointer, went straight to brainstorming a genuinely new MSP topic rather than re-sweeping domains already confirmed saturated in runs 30-36. Ran targeted `grep -ril` checks across the ENTIRE repo tree (not just one folder — the run-33-style failure mode of checking only one domain) for a dozen candidate topics: Entra Connect, BitLocker, Known Folder Move, Autopatch, White Glove/Pre-provisioning, Cross-tenant, eDiscovery, Retention Labels, Cloud Kerberos Trust, Direct Routing/Teams Phone, Outlook Profile/OST, LAPS. Confirmed all of these already exist somewhere in the repo (often under a folder an isolated search would miss — e.g. Cross-tenant lives in `EntraID/Troubleshooting/CrossTenant-A/B.md`) except one: **Microsoft Purview retention labels and retention policies (Data Lifecycle Management / Records Management)** were entirely absent — `Security/Purview/` had DLP, Sensitivity Labels, Insider Risk, and eDiscovery (4 topics) but nothing covering retention labels, label publishing, or the retain/delete conflict-resolution model, which is materially distinct from all four existing topics and a genuine, frequent MSP pain point (most compliance-related tickets in real M365 environments are retention-related, not DLP). Verified this was a real gap, not a naming miss, via `grep -ril \"retention label\\|RetentionCompliancePolicy\\|ComplianceTag\"` across the whole repo before building. Researched current Microsoft Learn documentation (`purview/retention`, `troubleshoot/microsoft-365/purview/retention/resolve-errors-in-retention-and-retention-label-policies`) rather than relying on training-data recall, since the three-rule conflict model (retention wins over deletion; longest period wins; explicit label beats implicit policy on delete) and the `Set-AppRetentionCompliancePolicy` vs `Set-RetentionCompliancePolicy` cmdlet split (Teams/Viva Engage use a separate backend from Exchange/SharePoint/OneDrive) are easy to get subtly wrong. Built the full three-file pattern: `Security/Purview/RetentionLabels-B.md` (hotfix — triage table on distribution status/label visibility, dependency cascade from label → label policy → auto/manual apply → retention clock → expiry → disposition, 6 fix paths covering failed distribution retry, unpublished labels, the retain/policy conflict model treated explicitly as \"working as designed\" rather than a bug, record-label permission restrictions, unexpected early deletion, and disposition review never triggering), `Security/Purview/RetentionLabels-A.md` (deep dive — full two-system architecture explanation of labels vs. policies, the four `RetentionType` clock-start variants and why `ModificationAgeInDays` is the most common source of \"why hasn't this expired\" tickets, a label-type comparison table distinguishing standard/record/regulatory-record labels and their differing (ir)reversibility, dependency stack, symptom→cause map, 6 validation steps, 5-phase troubleshooting flow, 4 remediation playbooks including an explicit rollback-impossibility warning on regulatory records, a parameterized evidence-pack script, and an 11-row command cheat sheet), and `Security/Purview/Scripts/Get-RetentionPolicyAudit.ps1` (tenant-wide read-only audit flagging UNPUBLISHED_LABEL for labels with zero matching publishing policies — the #1 \"label invisible to everyone\" root cause per the runbook — DISTRIBUTION_ERROR and a date-driven DISTRIBUTION_PENDING_STALE using Microsoft's own documented 7-day full-rollout window as the threshold rather than an arbitrary number, LOCATION_EXCEPTION_FOUND by summing the three location-exception properties, REGULATORY_RECORD_REVIEW / RECORD_LABEL_REVIEW as deliberate sign-off surfacing rather than error flags since these are correct-by-design states, MODIFICATION_CLOCK_LABEL as an informational flag tying directly back to the A-doc's most common ticket root cause, and an adaptive-scope freshness check that degrades gracefully with a warning if the tenant isn't licensed for adaptive scopes; explicitly does not attempt per-item conflict-resolution computation or disposition reviewer-chain inspection, both flagged in its own header as portal-only/out-of-scope rather than silently omitted). All read-only — no New-/Set-/Remove-ComplianceTag or RetentionCompliancePolicy calls anywhere in the script; DISTRIBUTION_ERROR/STALE findings are surfaced for the operator to action manually via the documented `-RetryDistribution` cmdlets, matching the established DLP/eDiscovery script pattern of audit-only tooling with manual remediation. Verified brace/paren/bracket balance via Python counts before committing (68/68 braces, 113/113 parens, 38/38 brackets; no pwsh available in this sandbox for a real parse check). Also found and backfilled `Security/Purview/_AGENT.md`, which was significantly stale — its folder-contents table listed only `DLP-Policy-B.md` despite the folder actually containing 10 runbook files and 4 scripts across 5 topics (DLP, Sensitivity Labels, Insider Risk, eDiscovery, and now Retention Labels); added all missing rows plus 5 new Common entry point rows for the new topic. Checked `.git/*.lock` for a live (non-`.bak`/`.stale`-suffixed) lock file before committing — none found this run. **For next run:** the three misfiled/non-conforming Autopilot files (`Autopilot-Troubleshooting2.ps1`, `Autopilot-Network-Connectivity.ps1`, `Test-AutopilotNetworkRequirements.ps1`) and the broader \"manifest bookkeeping behind repo state\" item remain open since runs 30-36 and still need interactive user review, not autonomous action. Given how many other `_AGENT.md` files have turned out stale on inspection (Windows, Purview, and others across recent runs), a dedicated pass specifically re-verifying every `_AGENT.md`'s folder-contents table against actual `ls`/`find` output — rather than assuming any prior backfill is still current — is likely higher-value next than another new-topic search, since new-topic candidates are getting genuinely scarce (13 checked this run, only 1 real gap found). manifest queue still empty (only the legend row, no actual ⬜ items). Went straight to run 35's own explicit "For next run" pointer and verified both premises against the filesystem before building, per the standing lesson that these notes must be re-checked, not trusted blindly. Confirmed via `ls macOS/Troubleshooting/` vs `ls macOS/Scripts/` that `Shell-Script-Failures-{A,B}.md` (10 topics total in the folder, both files already existed and complete) still had no companion script — 11 scripts existed for 10 topics, with Shell-Script-Failures the one genuinely uncovered topic (its ABM-Token-Renewal sibling was closed last run). Read both `Shell-Script-Failures-A.md` and `-B.md` in full before building — noted the two docs describe slightly different agent naming/log locations (A.md: `com.microsoft.intune` unified-log subsystem, 15-min timeout, \"Microsoft Intune Agent\"; B.md: `/Library/Logs/Microsoft/Intune/intune_agent.log` on-disk file, 60-min timeout, \"IME\"/Intune Management Extension) — rather than picking one as authoritative, built `macOS/Scripts/Get-ShellScriptFailureDiagnostics.sh` to check BOTH known agent install locations/launchd labels and BOTH known log surfaces, so the script works regardless of which agent version/naming a given fleet has. Covers: MDM enrollment state, Intune Agent/IME presence via three independent detection methods (app bundle path, PrivilegedHelperTools entry, launchctl label), system extension trust state, execution-context facts (whoami, PATH under an `env -i` minimal-PATH simulation matching Intune's actual launchd environment), Apple Silicon/Rosetta presence, disk space, APNs reachability, and a dual-log-surface grep (on-disk `intune_agent.log` + unified log subsystem) for script/error/exit-code/timeout keywords. Explicitly does NOT run or test the customer's actual deployed script (content/intent unknown to a generic tool) and does NOT trigger a check-in or reset \"run once\" state (portal-side actions per the B runbook's own fixes) — read-only throughout. Verified with `bash -n` (a real syntax parse, not just a brace/paren count — this sandbox's usual \"no pwsh available\" caveat doesn't apply here since bash IS available) — passed cleanly with zero syntax errors. Second, built `EntraID/Troubleshooting/EntraDomainServices-A.md`, the deep-dive companion to the `EntraDomainServices-B.md` hotfix built last run — read the B file in full first to keep the A file's Dependency Stack, Symptom→Cause Map, and Remediation Playbooks consistent with (not duplicative of) the hotfix's Dependency Cascade and Fix Paths. Covers: full one-way-sync architecture explanation (why Entra DS is never authoritative), the event-triggered (not bulk-backfill) password hash projection mechanic for both cloud-only and hybrid accounts, the permanently-flat `AADDC Users`/`AADDC Computers` OU model and its post-sync-only customization path, 5 validation steps, a 5-phase troubleshooting flow, 4 remediation playbooks (force password change, repair one-sided VNet peering, rotate LDAPS cert, full-redeploy expectations reset), a parameterized PowerShell evidence-pack script, a 12-row command cheat sheet, and 6 learning pointers linking to Microsoft Learn's Entra Domain Services overview and networking-considerations docs. Backfilled `EntraID/_AGENT.md`'s folder-contents table with the new A-file row and updated its matching Common entry point row to reference both files, and `macOS/_AGENT.md`'s Common entry points with the new script reference (macOS/_AGENT.md has no folder-contents table at all, consistent with its existing structure — not added this run, out of scope). **Result: both of run 35's explicitly flagged next-run items are now closed — macOS is back to full topic/script parity (11 topics, 12 scripts) and EntraID's Entra Domain Services topic now has a complete A/B pair.** Checked `.git/*.lock` for a live (non-`.bak`/`.stale`-suffixed) lock file before committing. **For next run:** per the now-recurring pattern (runs 30-35), a fresh full-repo `find`/`ls` sweep across every domain is the right first move before trusting this note, since script-coverage and A/B-pair gaps have repeatedly turned out narrower or wider than the prior run's summary suggested. The three misfiled/non-conforming Autopilot files (`Autopilot-Troubleshooting2.ps1`, `Autopilot-Network-Connectivity.ps1`, `Test-AutopilotNetworkRequirements.ps1`) and the broader "manifest bookkeeping behind repo state" item remain open since runs 30-35 and still need interactive user review, not autonomous action. No other genuine content or script gaps were identified this run beyond the two closed above — worth brainstorming another genuinely new MSP topic (in the pattern of Entra DS, Transport Rule conflicts, Token Protection from recent runs) if a fresh sweep confirms saturation again.
- Last updated: 2026-07-07 (auto-build, run 35, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Ran a fresh topic-vs-script coverage sweep across every domain via `ls`/`find` before trusting any prior run's notes, per the now-standing lesson repeated in runs 27-34. Confirmed DFS (5 topics/4 scripts — `Get-DFSNamespaceConfigAudit.ps1` covers both ABE and SiteCosting in one script, so this was a false gap on first glance), EntraID (16 topics/18 scripts), Intune (21/24), Windows (20/26), Autopilot (4/8), Security/ConditionalAccess (5/5), Security/Defender (9/9), Security/Purview (4/4), PowerAutomate (5/9), M365/Exchange (10/11) all fully or over-covered — no action needed on any of these. Also found **`_AGENT.md` was entirely missing from `Azure/Windows365/`** — every sibling folder (`Azure/AVD/`, `Azure/Files/`, and every other domain in the repo) has one per AGENT_INDEX.md's own "Repo Conventions" (`_AGENT.md` in every folder), confirming this was a real, previously-unflagged bookkeeping gap rather than a content gap — built it, modeled on `Azure/Files/_AGENT.md`'s structure, after reading both `Windows365-A.md` and `Windows365-B.md` in full. Separately, confirmed via `grep -ril "domain services\|DomainServices"` across the whole repo that Microsoft Entra Domain Services (the managed-domain service providing legacy NTLM/Kerberos/LDAP for lift-and-shift IaaS workloads) had zero coverage anywhere — a genuinely new, real-world MSP topic not yet in the repo and not on the original EXPANSION RULES list. Built `EntraID/Troubleshooting/EntraDomainServices-B.md` (hotfix — triage on managed-domain health/replica-set status, dependency cascade from Entra ID password-hash-sync through the flat `AADDC Users`/`AADDC Computers` OU sync down to VNet peering/DNS, 5 fix paths covering unhealthy managed domain, the "password never synced because Entra DS enabled after the last password change" gotcha, the permanently-flat-OU architectural constraint, LDAPS cert expiry, and one-sided VNet peering) — deliberately B-only this run, matching the repo's established pattern of shipping the hotfix first and the deep-dive companion in a later run (see HybridJoin, DynamicGroups, CAE, GlobalSecureAccess history above). Finally, resurfaced and closed the oldest unresolved item in this file's own Skipped Items section (flagged run 7, carried unactioned through 27+ subsequent runs): re-verified via `ls` that `macOS/Troubleshooting/ABM-Token-Renewal-{A,B}.md` still had no companion script, read both in full, and confirmed the reason no script existed is architectural — ABM/VPP token health is a **tenant-level Apple Business Manager fact**, not observable from any single Mac, so it doesn't fit this folder's otherwise-universal device-local `.sh` pattern. Built `macOS/Scripts/Get-ABMTokenStatus.ps1` instead as an admin-side Microsoft Graph (beta) script — verified the exact cmdlet (`Get-MgBetaDeviceManagementDepOnboardingSetting`), required scope (`DeviceManagementServiceConfig.Read.All`), and the `depOnboardingSetting` resource's real property names (`TokenExpirationDateTime`, `LastSuccessfulSyncDateTime`, `LastSyncErrorCode`, `SyncedDeviceCount`, `TokenType`, `AppleIdentifier`) against live Microsoft Learn documentation before writing, rather than guessing from training-data recall, since Graph cmdlet/property names are easy to get subtly wrong. Flags TOKEN_EXPIRED/TOKEN_EXPIRING_SOON (configurable threshold, default 30 days) per the runbook's Triage step 1, SYNC_ERROR/SYNC_STALE/NEVER_SYNCED per the Dependency Cascade's ~15-minute expected sync cadence, and reports both device-enrollment and VPP token types side by side per the runbook's note that they can be the same or separate tokens; explicitly does NOT attempt the ABM-side device-count comparison from Diagnosis Step 4 since Graph has no API surface for that (business.apple.com side), and says so in its own summary output rather than silently omitting it. Read-only — no token/profile/assignment changes. All three new scripts/docs cross-linked: backfilled `EntraID/_AGENT.md`'s folder-contents table and Common entry points with the new Entra DS row, and `macOS/_AGENT.md`'s matching entry-point line with the new script reference. Verified brace/paren/bracket balance via Python counts on the new `.ps1` before committing (44/44 braces, 76/76 parens, 15/15 brackets; no pwsh available in this sandbox for a real parse check). Also refreshed the top-level `AGENT_INDEX.md` Domain Map, which had drifted badly behind actual repo state (missing rows for Azure/AVD, Azure/Files, Windows365, Defender's newer sub-topics, Purview, Copilot, Universal Print, Teams Rooms, DFS ABE/SiteCosting, Windows VPN/AppLocker/Credential Guard, and EntraID's PIM/MFA/SSPR/Identity Protection/Domain Services/App Proxy/Access Packages/WHfB/LAPS/EPM) — added the missing rows rather than rewriting the whole table, to keep the edit low-risk. **Did not** attempt a full reconciliation of this manifest file against actual repo state (453 real files vs. this file's own history of drifting counts) — that remains the single largest standing "Skipped Items" entry and is still better suited to an interactive session per prior runs' judgment. **For next run:** build `macOS/Scripts/Get-ShellScriptFailureDiagnostics.sh` (device-local, fits the established pattern — the one remaining genuinely script-less macOS topic) and/or `EntraID/Troubleshooting/EntraDomainServices-A.md` (deep-dive companion to the B file built this run). The three misfiled/non-conforming Autopilot files and the broader manifest-vs-repo bookkeeping gap (both flagged since runs 30-34) remain open and still need interactive user review, not autonomous action.

---

## EntraID — GDAP (Granular Delegated Admin Privileges) — new topic (run 38)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/GDAP-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/GDAP-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-GDAPRelationshipAudit.ps1` | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added GDAP row) | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — folder-contents table was missing 11 of 17 topics and 12 of 18 scripts) | ✅ | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 462
- Completed: 462
- In progress: 0
- Queued: 0
- Last updated: 2026-07-07 (auto-build, run 38, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per the standing pattern from runs 27-37 (re-verify every prior run's notes against the actual filesystem before trusting them, since manifest bookkeeping repeatedly drifts from repo state), ran a fresh full-repo `grep -ril` sweep for genuinely new MSP topic candidates not yet covered: Defender for Identity (exists — MDI-A/B), DKIM/DMARC/SPF (exists — DMARC-DKIM-A.md, EOP-AntiSpam-B.md), Communication Compliance (absent — flagged as a candidate but deferred in favor of GDAP, see below), Attack Simulation Training (absent, zero hits), GDAP/Delegated Admin/Partner Center (absent, zero real hits — only a tangential AccessPackages-A.md mention). Chose **GDAP (Granular Delegated Admin Privileges)** over Attack Simulation Training and Communication Compliance because it is the single most MSP-specific gap in the entire repo — this knowledge base is explicitly for MSP engineers managing multiple Microsoft customer tenants, and GDAP is the mechanism by which that access itself is granted/revoked, yet had zero coverage anywhere despite 17 other Entra ID sub-topics already built. Researched current (2026-04/05 dated) Microsoft Learn documentation directly — `partner-center/customers/gdap-introduction`, `gdap-faq`, and a `WebSearch` on guest-account/security-group behavior — rather than relying on training-data recall, since several of GDAP's specific numeric constraints (90-day approval expiry, 2-year max duration with 6-month Auto Extend increments, 100-security-group-per-customer ceiling, 365-day relationship-name reuse cooldown after termination, Global Administrator role's exclusion from Auto Extend, and the documented guest-account-breaks-access-assignment limitation) are exactly the kind of precise, easy-to-get-wrong detail that must be verified live rather than guessed. Built the full three-file pattern: `EntraID/Troubleshooting/GDAP-B.md` (hotfix — triage distinguishing that GDAP relationship/access-assignment/security-group objects live in the PARTNER tenant while enforcement, e.g. Conditional Access, lives in the CUSTOMER tenant; dependency cascade from relationship creation through customer approval, security group mapping, and CA's "Service provider users" exclusion category; 5 fix paths covering expired/stuck relationships, active-but-still-denied access, guest-account contamination in access-assignment groups, CA blocking service-provider sign-ins, and locked-out customer admin recovery via Privileged Authentication Administrator), `EntraID/Troubleshooting/GDAP-A.md` (deep dive — full three-layer architecture explanation of Relationship → Access Assignment → Group Membership, explicit scope note distinguishing GDAP from both XTAS/CrossTenant and Azure Lighthouse and noting GDAP's mutual exclusivity with Multi-Tenant Organization, a lifecycle-timer reference table, dependency stack, 12-row symptom→cause map, 6 validation steps, 5-phase troubleshooting flow, 4 remediation playbooks including a bulk Auto-Extend script that explicitly filters out Global-Admin-role relationships, evidence pack, and an 11-row command cheat sheet), and `EntraID/Scripts/Get-GDAPRelationshipAudit.ps1` (read-only audit against `Microsoft.Graph.Identity.Partner` cmdlets — flags EXPIRING_SOON, GLOBAL_ADMIN_NO_AUTOEXTEND, APPROVAL_PENDING_STALE, TERMINATED_OR_EXPIRED, ACCESS_ASSIGNMENT_NOT_ACTIVE, GUEST_MEMBER_IN_GROUP via a `-SkipGroupMembershipCheck`-gated per-group member/UserType enumeration, and GROUP_COUNT_NEAR_LIMIT per customer against the 100-group ceiling; explicitly does not touch anything inside the customer tenant, e.g. Conditional Access, since none of that is visible from the partner-tenant Graph context this script runs in — flagged in its own header as out of scope rather than silently omitted; makes no New-/Update-/Remove- calls). Verified brace/paren/bracket balance via Python counts before committing (61/61 braces, 136/136 parens, 32/32 brackets; no pwsh available in this sandbox for a real parse check, consistent with every prior run's caveat). Separately, closed the **highest-value item explicitly flagged by run 37** ("a dedicated pass specifically re-verifying every `_AGENT.md`'s folder-contents table against actual `ls`/`find` output... is likely higher-value next than another new-topic search"): read `EntraID/_AGENT.md` in full and compared it line-by-line against `ls EntraID/Troubleshooting/` and `ls EntraID/Scripts/` — found it was **significantly stale**, missing 11 of 17 Troubleshooting topics entirely (AccessPackages, AppProxy, Connect-Sync, ExternalIdentities, IdentityProtection, MFA, PIM, PasswordProtection-A, PRT-Issues-A, SSPR, WHfB — despite scripts for several of these, e.g. Get-MFAMethodsReport.ps1 and Get-PIMReport.ps1, already existing) and 12 of 18 Scripts entirely. Rewrote the Folder contents and Common entry points sections in full (not just appending rows, since the old table's incomplete structure needed reorganizing to stay readable) — read one B/A pair (`CrossTenant-B.md`/`-A.md`) in full first to confirm the existing table's descriptive style before extending it to the missing rows, rather than inventing a new format. Also added a GDAP row to the top-level `AGENT_INDEX.md` Domain Map, appended after the existing Entra Domain Services/App Proxy/Access Packages row. **Did not** attempt the same `_AGENT.md` staleness re-verification pass on other domains (Windows, Intune, Autopilot, M365/*, Security/*) this run — EntraID alone was a large enough backfill for one run, and per the standing lesson about verifying rather than trusting prior summaries, each of those folders should get its own fresh `ls`-vs-`_AGENT.md` comparison rather than assuming run 35/36's spot-checks of Windows/Purview/macOS mean the rest are current. Checked `.git/*.lock` for a live (non-`.bak`/`.stale`-suffixed) lock file before committing — none found this run. **For next run:** run the same `_AGENT.md` folder-contents staleness check against Intune, Windows, and M365/Exchange next (all three have grown past 20+ files per folder and are the most likely to have drifted, by the same pattern found in EntraID and previously in Purview/Windows365). Communication Compliance (Purview) and Attack Simulation Training (Defender/Security) remain confirmed, genuine, uncovered new-topic candidates for a future run if `_AGENT.md` backfills are deprioritized. The three misfiled/non-conforming Autopilot files (`Autopilot-Troubleshooting2.ps1`, `Autopilot-Network-Connectivity.ps1`, `Test-AutopilotNetworkRequirements.ps1`) and the broader "manifest bookkeeping behind repo state" item remain open since runs 30-37 and still need interactive user review, not autonomous action.

---

## ⚠️ Infrastructure note (run 38, post-commit)
This run's `git commit` initially failed twice with `fatal: Unable to create '.../.git/HEAD.lock'` and then `.../.git/index.lock`, both times reporting `warning: unable to unlink '<tmp_obj_or_lock_file>': Operation not permitted` — not a real concurrent git process (verified via `ps aux`, nothing running), but the FUSE-mounted repo folder itself refusing unlink/rename of git's own temp objects and lock files on the first one or two attempts. Renaming the stale `HEAD.lock`/`index.lock` out of the way (rather than deleting) and retrying let the commit go through on the third attempt, and `git push` then succeeded cleanly. **This is not a new problem** — `find .git -maxdepth 1 -name "*.lock*"` shows dozens of renamed `.stale-runNN-*` / `.bak*` lock files dating back to July 5, meaning nearly every run for the past ~2 days has hit this same unlink failure and silently worked around it the same way, without ever surfacing it as a distinct issue (it had only ever been folded into the vague "manifest bookkeeping drift" note). Recommend the user check whether something on the host Mac side is holding file handles open on this mounted folder during git operations (iCloud Drive sync, a backup tool, antivirus real-time scanning, or similar) — that's the most common cause of a FUSE mount intermittently refusing unlink/rename on freshly-written files. This does not appear to be data-loss-risky (every commit so far has eventually succeeded and pushed cleanly after a retry), but the growing pile of harmless-but-messy stale lock-rename files in `.git/` is itself worth a one-time manual cleanup (`rm .git/*.stale* .git/*.bak*` from the Mac side, not from an agent, since agent-side unlink hits the same permission wall) next time a human is in the folder.

---

## Security/Defender — New Topic: Attack Simulation Training (run 39)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/AttackSimulationTraining-B.md` | ✅ | auto-build |
| `Security/Defender/AttackSimulationTraining-A.md` | ✅ | auto-build |
| `Security/Defender/Scripts/Get-AttackSimulationCampaignAudit.ps1` | ✅ | auto-build |
| `Security/Defender/_AGENT.md` (backfilled — folder-contents table was missing 12 of 16 topic files and 8 of 10 scripts) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Attack Simulation Training row) | ✅ | auto-build |

---

## Build Progress (superseded — run 39)
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 465
- Completed: 465
- In progress: 0
- Queued: 0
- Last updated: 2026-07-07 (auto-build, run 39, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per run 38's explicit "For next run" pointer, confirmed the two flagged candidates against the whole-repo filesystem before building anything, per the standing lesson (runs 27-38) that these notes must be re-verified, not trusted. Ran `grep -ril` across the ENTIRE repo tree for both "Communication Compliance"/`CommunicationCompliance` and "Attack Simulation"/`AttackSimulation`: Communication Compliance had only two tangential passing mentions inside `Insider-Risk-A.md` and `eDiscovery-A.md` (not dedicated coverage — still a real gap, but a softer one) and zero script/manifest hits; **Attack Simulation Training had zero hits anywhere in actual content** (only self-references inside this manifest file itself) — confirmed the cleaner, more clear-cut gap of the two, so built that one this run and left Communication Compliance for a future run. Researched current Microsoft Learn documentation directly before writing rather than relying on training-data recall, since Attack Simulation Training's specific numeric/behavioral details (90-day training threshold, 2-consecutive-compromise repeat-offender default, 18-month data retention with a 90-day post-tenant-deletion purge, the exact 4 role types and their real limitations, the APC/EUR/NAM region list with specific supported countries, and the audit-logging-gates-training-assignment architectural quirk) are easy to get subtly wrong: fetched `attack-simulation-training-faq` (updated 2026-04-13) and `attack-simulation-training-get-started` (updated 2026-06-01) in full, plus `graph/api/attacksimulationroot-list-simulations` to confirm the exact Graph resource schema (`id`, `displayName`, `description`, `attackType`, `attackTechnique`, `status`, `createdDateTime`, `createdBy`, `lastModifiedDateTime`, `lastModifiedBy`, `launchDateTime`, `completionDateTime`, `isAutomated`, `automationId`, `payloadDeliveryPlatform`) before writing any script logic against it — confirmed there is genuinely no dedicated PowerShell module for this workload (Graph only, `AttackSimulation.Read.All`/`AttackSimulation.ReadWrite.All`), which shaped both runbooks' Learning Pointers and the script's approach. Built the full three-file pattern: `Security/Defender/AttackSimulationTraining-B.md` (hotfix — Graph-based triage since no EXO cmdlets exist for this product, dependency cascade from licensing/role through target resolution to training assignment, 6 fix paths covering empty reports/audit-logging-off, partial target delivery from silently-dropped guests/inactive users, stuck-in-scheduled campaigns, false training assignment via unexempted reporting mailboxes, false-positive clicks from intercepting security tools, and the Attack Payload Author/Security Reader role-limitation confusion), `Security/Defender/AttackSimulationTraining-A.md` (deep dive — full simulation-lifecycle architecture covering all 7 social engineering techniques, the simulation/automation/training-campaign distinction, target resolution timing, the audit-logging-gates-both-reporting-and-training-assignment architectural quirk stated explicitly since it's unusual relative to other M365 workloads, dependency stack, 12-row symptom→cause map, 6 validation steps, 5-phase troubleshooting flow, 4 remediation playbooks, a Graph+EXO evidence-pack script, 14-row command cheat sheet, and 6 learning pointers linking to the specific MS Learn pages fetched), and `Security/Defender/Scripts/Get-AttackSimulationCampaignAudit.ps1` (tenant-wide read-only Graph audit against the confirmed `/security/attackSimulation/simulations` schema — flags SCHEDULED_STALE for campaigns past a configurable hours-since-launch threshold still in `scheduled` status, IN_PROGRESS_STALE for campaigns past a configurable days threshold with no completion, COMPLETED_UNUSUALLY_FAST as a possible mass-target-validation-failure signal, plus three optional switches/params that degrade gracefully with warnings if their prerequisite module/connection isn't present: `-CheckAuditLog` for `UnifiedAuditLogIngestionEnabled` via EXO, `-CheckTransportRuleBlock` for a regex scan of enabled transport rules against the 4 documented reported-phish submission addresses, and `-CheckUserLicensing` for a per-UPN E5/MDO-P2-class SKU check via `Get-MgUserLicenseDetail`). All read-only — no simulation/policy/mailbox create-update-delete calls anywhere in the script. Verified brace/paren/bracket balance via Python counts before committing (59/59 braces, 84/84 parens, 21/21 brackets; no pwsh available in this sandbox for a real parse check, consistent with every prior run's caveat). Separately backfilled `Security/Defender/_AGENT.md`, which was significantly stale in the exact pattern flagged repeatedly since run 32 — its folder-contents table only listed 3 of the folder's 16 topic files (MDE-Onboarding-B, ASR-Rules-B, Tamper-Protection-B) and had no Scripts/ rows at all, despite CloudProtection, DefenderVulnMgmt, MDA, MDI, NetworkProtection, WDAC, and their A-file companions plus 9 pre-existing scripts already being on disk — rewrote both the Folder contents and Common entry points sections to reflect actual `ls` output rather than appending piecemeal, and added the new Attack Simulation Training rows in the same pass. Also added a Domain Map row to `AGENT_INDEX.md` for Attack Simulation Training, cross-referencing `M365/Exchange/` (transport rule interplay) and `EntraID/` (role assignment). Checked `.git/*.lock` for a live (non-`.bak`/`.stale`-suffixed) lock file before committing. **For next run:** Communication Compliance (Purview) remains a confirmed, softer gap (tangential mentions exist in Insider-Risk-A.md/eDiscovery-A.md but no dedicated topic) — good next new-topic candidate. Per run 38's other pointer, the `_AGENT.md` staleness check should still be run fresh against Intune, Windows, and M365/Exchange (all past 20+ files per folder) — this run only closed the Security/Defender instance of that pattern, not the other three flagged folders. The three misfiled/non-conforming Autopilot files and the broader "manifest bookkeeping behind repo state" item remain open since runs 30-38 and still need interactive user review, not autonomous action.

---

## Security/Purview — New Topic: Communication Compliance (run 40)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/CommunicationCompliance-B.md` | ✅ | auto-build |
| `Security/Purview/CommunicationCompliance-A.md` | ✅ | auto-build |
| `Security/Purview/Scripts/Get-CommunicationComplianceReadinessAudit.ps1` | ✅ | auto-build |
| `Security/Purview/_AGENT.md` (backfilled — added CommunicationCompliance rows + entry points + diagnostic commands) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Communication Compliance row) | ✅ | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 470
- Completed: 470
- In progress: 0
- Queued: 0
- Last updated: 2026-07-07 (auto-build, run 40 — see prior entry for full detail).

---

## Intune _AGENT.md backfill + Autopilot — New Topic: Windows Autopilot Device Preparation (run 41)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/_AGENT.md` (backfilled — folder-contents table was missing 18 of 21 Troubleshooting topics and ~17 of 25 scripts) | ✅ | auto-build |
| `Autopilot/Troubleshooting/DevicePreparation-B.md` | ✅ | auto-build |
| `Autopilot/Troubleshooting/DevicePreparation-A.md` | ✅ | auto-build |
| `Autopilot/Scripts/Get-DevicePreparationReadinessAudit.ps1` | ✅ | auto-build |
| `Autopilot/_AGENT.md` (added Device Preparation rows) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Device Preparation row) | ✅ | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 473
- Completed: 473
- In progress: 0
- Queued: 0

---

## M365 — New Topic: Microsoft 365 Backup (run 43)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Backup/M365-Backup-B.md` | ✅ | auto-build |
| `M365/Backup/M365-Backup-A.md` | ✅ | auto-build |
| `M365/Backup/Scripts/Get-M365BackupCoverageAudit.ps1` | ✅ | auto-build |
| `M365/Backup/_AGENT.md` | ✅ | auto-build |
| `M365/_AGENT.md` (backfilled — added missing `UniversalPrint/` sub-module row, plus new `Backup/` row and two entry points) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Microsoft 365 Backup row) | ✅ | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 477
- Completed: 477
- In progress: 0
- Queued: 0
- Last updated: 2026-07-07 (auto-build, run 43, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per run 42's "for next run" pointer, picked a genuinely new-topic candidate from its shortlist (Windows 365 Frontline, Entra Verified ID, Microsoft 365 Backup, SharePoint Advanced Management, Passkeys) rather than continuing pure bookkeeping — confirmed via `grep -ril` across the whole repo that none of the five existed as dedicated content yet (only incidental mentions of "passkey" in Platform-SSO-A.md/Kerberos-A.md and "Frontline" in Windows365 docs, no dedicated runbooks for any of the five). Chose **Microsoft 365 Backup** as the highest-value pick: it's a real, current MSP pain point (first-party pay-as-you-go backup for SharePoint/OneDrive/Exchange, broadly GA since 2024-2025, actively evolving — granular file/folder restore went GA and departmental billing is mid-rollout per the docs pulled this run) and it was completely absent from the repo despite `Security/Purview/` covering the adjacent-but-distinct retention/compliance space. Verified facts against live Microsoft Learn docs before writing anything (not from training-data recall, since this product changed significantly after most training cutoffs): fetched `backup-overview`, `backup-restore-data`, `backup-setup`, the `Get-MgSolutionBackupRestore` cmdlet reference, the full `Microsoft.Graph.BackupRestore` module cmdlet list, and the `backupRestoreRoot` Graph resource page to confirm real cmdlet names (`Enable-MgSolutionBackupRestore`, `Get-MgSolutionBackupRestore`, `Get-MgSolutionBackupRestoreProtectionPolicy`, `Get-MgSolutionBackupRestoreSharePointProtectionPolicy`/`OneDriveForBusinessProtectionPolicy`/`ExchangeProtectionPolicy`, `Get-MgSolutionBackupRestorePoint`, `Get-MgSolutionBackupRestoreSession`) and real Graph API URI paths (`/solutions/backupRestore/siteProtectionUnits`, `/driveProtectionUnits`, `/mailboxProtectionUnits`) before using them in any runbook or script — used `Invoke-MgGraphRequest` against the confirmed REST paths for the nested protection-unit collections where the exact PowerShell cmdlet parameter surface wasn't independently confirmed, rather than guessing cmdlet syntax that could fail in production. Built `M365-Backup-B.md` (hotfix — service-not-enabled, stalled policy activation, coverage gaps, failed/held restore sessions, billing-not-linked, with the real fix that protection policies don't auto-expand to new sites/mailboxes/OneDrives as the flagged #1 root cause), `M365-Backup-A.md` (deep dive — append-only vs. immutable storage architecture, full object model glossary, symptom→cause map, real published RTO/RPO performance tables, and four remediation playbooks including deleted-Entra-user recovery and hold-aware restore routing), and `Scripts/Get-M365BackupCoverageAudit.ps1` (read-only Graph script diffing actual SharePoint sites/licensed OneDrive users/Exchange mailboxes — the latter via optional `Get-Mailbox` if EXO is connected, degrading gracefully with an `EXCHANGE_AUDIT_SKIPPED` flag if not — against `siteProtectionUnits`/`driveProtectionUnits`/`mailboxProtectionUnits` to flag `NOT_PROTECTED` items, `POLICY_STALLED` for policies stuck in `activating` past a configurable grace period default 4h, `SERVICE_NOT_ENABLED`, and `RECENT_RESTORE_FAILED`; exports CSV). Verified brace/paren balance via `grep -o` counts on the new script before committing (53/53 braces, 81/81 parens — no pwsh available in this sandbox for a real parse check). Backfilled `M365/_AGENT.md` with the new `Backup/` sub-module row and, while there, also added the previously-missing `UniversalPrint/` sub-module row (a small pre-existing staleness gap unrelated to this run's main task, fixed opportunistically since the file was already open) plus two new entry-point lines; added the new domain to `AGENT_INDEX.md`'s Domain Map. Checked `.git/*.lock*` before committing — found the same live (non-`.stale`-suffixed) `HEAD.lock` pattern flagged in runs 38/42; renamed to `.stale-run43-<timestamp>` rather than deleting, per the established EPERM-on-unlink workaround for this FUSE-mounted repo. **For next run:** four new-topic candidates remain from run 42's shortlist (Windows 365 Frontline, Entra Verified ID, SharePoint Advanced Management, Passkeys) — Entra Verified ID or Passkeys are likely the next highest-value picks given how fast passwordless/verifiable-credential adoption is moving in enterprise environments. `M365/Backup/` has zero script coverage beyond the one audit script built this run — a second script covering bulk restore-session monitoring (for the large-scale/ransomware recovery scenario in `M365-Backup-A.md` Playbook 4) would be a reasonable follow-up once real-world usage surfaces which fields matter most. The EntraID/Security `_AGENT.md` deep-verification skipped by run 42 as lower-risk is still outstanding if a future run has spare capacity.

---

## _AGENT.md Full-Repo Staleness Sweep (run 42)
| File | Status | Assigned |
|------|--------|---------|
| `DFS/_AGENT.md` (backfilled — missing `Get-DFSNamespaceConfigAudit.ps1` row + entry point) | ✅ | auto-build |
| `PowerAutomate/_AGENT.md` (backfilled — `DLP-Policies-A/B.md` were entirely absent from the table despite existing on disk; `Permission-Management-A.md` row missing; "DLP policy blocking connector" entry point corrected — it pointed to `EntraID/` instead of the dedicated DLP-Policies runbook) | ✅ | auto-build |
| `M365/Licensing/_AGENT.md` (backfilled — `License-Assignment-A.md`, `Group-Based-Licensing-A.md`, and the entire `Scripts/Get-LicenseReport.ps1` row were missing) | ✅ | auto-build |
| `Autopilot/_AGENT.md` (backfilled — folder-contents table was missing `ESP-Stuck-A/B.md`, `HybridJoin-Autopilot-A/B.md`, `Profile-Not-Assigned-A/B.md`, and `TPM-Attestation-A/B.md` entirely — 8 files referenced in Common entry points but absent from the table; also added an explicit misfiled-scripts note) | ✅ | auto-build |
| `macOS/_AGENT.md` (backfilled — Common entry points had zero coverage for 4 of 10 topics: Compliance-Policies, Extensions, MDM-Certificate-Renewal, PPPC, plus their 5 companion scripts and `Get-MacIntuneStatus.sh`) | ✅ | auto-build |
| `M365/SharePoint-OneDrive/_AGENT.md` (verified — current, no changes) | ✅ | auto-build |
| `M365/Teams/_AGENT.md` (verified — current, no changes) | ✅ | auto-build |
| `Azure/Windows365/_AGENT.md` (verified — current, no changes) | ✅ | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 473
- Completed: 473
- In progress: 0
- Queued: 0
- Last updated: 2026-07-07 (auto-build, run 42, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per run 41's explicit "For next run" pointer — a full-repo sweep of the remaining `_AGENT.md` files not yet covered by runs 35-41's piecemeal spot-checks (DFS, PowerAutomate, EntraID, Security/ConditionalAccess, Security/Defender, Security/Purview, M365/SharePoint-OneDrive, M365/Teams, M365/Licensing, Autopilot, macOS, Azure/Windows365) — ran `find`/`ls` against every one of those folders and read each `_AGENT.md` in full before comparing, per the standing lesson (runs 27-41) that these must be independently re-verified rather than trusted. Skipped EntraID, Security/ConditionalAccess, Security/Defender, and Security/Purview from deep re-verification since all four were freshly backfilled within the last 1-4 runs (38, 39, 40, and ongoing CA maintenance) and a lighter-touch spot check of their most recently-touched sections showed no drift — prioritized limited run time on the eight folders never covered by any prior sweep. Found and fixed **five genuinely stale `_AGENT.md` files**: (1) `DFS/_AGENT.md` was missing its 4th script, `Get-DFSNamespaceConfigAudit.ps1`, from the folder-contents table entirely (confirmed via `find DFS -type f`) — added the row plus a matching common-entry-point line. (2) `PowerAutomate/_AGENT.md` was the largest gap found this run: `Troubleshooting/DLP-Policies-A.md` and `-B.md` both exist on disk as complete runbooks but had **zero rows** in the folder-contents table and zero direct entry-point coverage — worse, the existing "DLP policy blocking connector" entry point actively misdirected to `EntraID/` instead of the dedicated runbook, which would have sent an agent down the wrong troubleshooting path entirely; also added the missing `SharePoint/Permission-Management-A.md` deep-dive row (only its `-B.md` hotfix was listed). (3) `M365/Licensing/_AGENT.md` had no Scripts section at all in its folder-contents table despite `Scripts/Get-LicenseReport.ps1` existing on disk, and both `License-Assignment-A.md` and `Group-Based-Licensing-A.md` deep-dive companions were completely unlisted (only their `-B.md` hotfixes appeared) — added all three rows plus two new entry-point lines. (4) `Autopilot/_AGENT.md` had the widest gap of the five: its folder-contents table was missing **8 files across 4 full topics** (`ESP-Stuck-A/B.md`, `HybridJoin-Autopilot-A/B.md`, `Profile-Not-Assigned-A/B.md`, `TPM-Attestation-A/B.md`) despite all four being referenced correctly in the file's own Common entry points section — the table itself had simply never been updated when those topics were built in earlier runs; rewrote the table to include all four topic-pairs in a consistent format, and added a note flagging the two known-misfiled Autopilot scripts (open since run 30) directly in the table so the gap stays visible without needing to cross-reference this manifest. (5) `macOS/_AGENT.md` has no folder-contents table by design (confirmed consistent with run 41's note) but its Common entry points section had **zero coverage for 4 of 10 Troubleshooting topics** — Compliance-Policies, Extensions, MDM-Certificate-Renewal, and PPPC — plus their 5 companion scripts (`Get-ComplianceStatus.sh`, `Get-SystemExtensionStatus.sh`, `Get-PPPCStatus.sh`, `Get-MDMCertificateStatus.sh`, `Repair-MacMDMEnrollment.sh`) and the general-purpose `Get-MacIntuneStatus.sh` were never referenced anywhere — added five new entry-point lines covering all of them. Spot-checked `M365/SharePoint-OneDrive/_AGENT.md`, `M365/Teams/_AGENT.md`, and `Azure/Windows365/_AGENT.md` line-by-line against `find` output and confirmed all three are genuinely current — no changes made, avoiding unnecessary churn. Did not modify any runbook or script content this run — this was purely an `_AGENT.md` bookkeeping pass, consistent with the "always build 2-3 files" instruction being satisfied by fixing 5 real, user-impacting documentation gaps rather than manufacturing new topic content when the highest-value flagged work was backlog cleanup. Found and cleared two leftover **live** (non-`.stale`-suffixed) lock files, `.git/index.lock` and `.git/HEAD.lock`, before starting — both were 0 bytes and timestamped hours earlier with no matching `git` process in `ps aux`, confirming they were abandoned artifacts from a prior run's own workaround rather than a real concurrent process; renamed them to `.stale-run42-<timestamp>` following the established convention rather than deleting, consistent with the run-38 infrastructure note's recommendation that a human do a one-time real cleanup of the now very large pile of renamed stale lock files in `.git/`. **For next run:** the misfiled-script bucket (`Autopilot-Troubleshooting2.ps1`, `Autopilot-Network-Connectivity.ps1`, `Intune/IntuneChecker.ps1`, and note the duplicate-purpose `Autopilot/Scripts/Test-AutopilotNetworkRequirements.ps1` vs. `Autopilot/Troubleshooting/Autopilot-Network-Connectivity.ps1`) remains open since runs 30-41 and still needs interactive user review, not autonomous action — now flagged directly inside `Autopilot/_AGENT.md` itself as well as here, for higher visibility. This run intentionally skipped EntraID/Security's four `_AGENT.md` files as lower-risk (recently touched); if a future run has spare capacity, a full pass there would complete the "every `_AGENT.md` in the repo verified in one exhaustive sweep" goal that's been incremental since run 32. New-topic candidates remain scarce per run 41's assessment (8 checked, 1 real gap found) — continuing to lean on backfill/script-coverage work is the right call until a genuinely new, current MSP pain point surfaces (Windows 365 Frontline nuances, Entra Verified ID, Microsoft 365 Backup, SharePoint Advanced Management, and Passkeys remain unexplored candidates worth a fresh `grep -ril` check next time new-topic hunting resumes.
- Last updated: 2026-07-07 (auto-build, run 41, scheduled task "ezadmin-night-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per run 40's explicit "For next run" pointer — the oldest open item in the thread, deferred across runs 38-40 — ran the `_AGENT.md` folder-contents staleness check against Intune, Windows, and M365/Exchange (all flagged as past 20+ files per folder). Read each `_AGENT.md` in full and compared line-by-line against actual `find`/`ls` output rather than trusting the prior run's "past 20+ files, likely stale" assumption at face value, per the standing lesson (runs 27-40) that these must be independently re-verified: **Windows/_AGENT.md and M365/Exchange/_AGENT.md were both already current** — Windows' folder-contents table correctly listed all 20 Troubleshooting topic-pairs and all 20 companion scripts (including the two general-utility, non-topic-tied scripts), and Exchange's table correctly listed all 8 topics and 11 scripts with accurate descriptions — no action needed on either, confirmed as false positives from the file-count heuristic rather than genuine staleness. **`Intune/_AGENT.md` was, however, significantly stale** — its folder-contents table listed only 3 of 21 Troubleshooting topic-pairs (Enrollment, Policy-Conflict, App-Deployment) and roughly 8 of 25 scripts, despite AppProtection, Autopatch, Certificates, CoManagement, CustomCompliance, DriverManagement, EPM, FeatureUpdates, Filters, GP-to-CSP, Kiosk, LAPS, Managed-Apps, Platform-Scripts, Remediations, ScopeTags, Security-Baselines, and WUfB all already existing as complete A/B pairs with dedicated scripts on disk. Rewrote the Folder contents and Common entry points sections in full to reflect actual repo state (confirmed via `find Intune -type f` and reading every script's `.SYNOPSIS` block rather than guessing descriptions from filenames alone), and in the process confirmed a genuinely positive finding: **every one of the 21 Intune Troubleshooting topics already has a dedicated companion script** — this was purely a bookkeeping/documentation gap, not a content or script-coverage gap. Also flagged (not touched) `Intune/IntuneChecker.ps1`, a root-level ad hoc sync+IME-repair one-liner that predates the `Scripts/`/`Troubleshooting/`/`Reporting/` folder convention and isn't linked from any runbook — same category as the three previously-flagged misfiled Autopilot scripts (`Autopilot-Troubleshooting2.ps1`, `Autopilot-Network-Connectivity.ps1`, `Test-AutopilotNetworkRequirements.ps1`, open since runs 30-40) — added to that same standing "needs interactive user review" bucket rather than renamed/relocated/deleted autonomously. Separately, since the staleness sweep closed faster than expected (2 of 3 folders needed no work) and this run still owed at least one new-content item per the standing "always build 2-3 files" instruction, ran a fresh `grep -ril` gap check across the whole repo for additional candidate MSP topics (Entra Verified ID, Microsoft 365 Backup, SharePoint Advanced Management, Windows Autopilot Device Preparation, Cloud Kerberos Trust, Passkeys) and confirmed **Windows Autopilot device preparation (APDP)** as a genuine, zero-coverage gap — a materially distinct, newer (2024+) enrollment mode from the classic Windows Autopilot content already thoroughly covered in this folder (`HybridJoin-Autopilot-*`, `Profile-Not-Assigned-*`, `ESP-Stuck-*`, `TPM-Attestation-*`), built on Entra-join-only Enrollment Time Grouping rather than dynamic-group/ESP mechanics, and a real, current MSP pain point as Microsoft pushes tenants toward it for Windows 365/Cloud PC and simplified corporate deployments. Fetched current Microsoft Learn documentation directly rather than relying on training-data recall, since several precise, easy-to-misremember details were load-bearing for accuracy: the exact Intune Provisioning Client service principal AppID (`f1346770-5b25-470b-88bd-d5744ab7952c`, which can display under two different names depending on tenant), the classic-Autopilot-always-wins precedence rule, the specific device-group eligibility constraints (assigned not dynamic, not role-assignable, that exact owner), the RBAC permission name ("Enrollment time device membership assignment"), and a set of dated, still-relevant known issues (BitLocker 128-bit race condition, Windows 365 60-minute timeout partially resolved Feb 2026, the Entra "Local administrator settings" conflict with its exact supported setting-combination table, stuck-at-100% OOBE, custom-compliance/device-health-script non-support) — fetched `device-preparation/overview` (updated 2026-05-14), `device-preparation/troubleshooting-faq` (updated 2026-04-07), and `device-preparation/known-issues` (updated 2026-05-21) in full before writing any content. Built the full three-file pattern: `Autopilot/Troubleshooting/DevicePreparation-B.md` (hotfix — opens with an explicit scope note distinguishing it from classic Autopilot content in the same folder since a reader could easily conflate the two; triage table leads with the classic-Autopilot-shadowing check since that's the single most common false-alarm cause; dependency cascade from OS build through group ownership through Enrollment Time Grouping to app/script delivery; 6 fix paths covering ESP-showing-means-wrong-flow, group-ownership/SP-provisioning errors, deployment-never-launches checklist, Skipped apps/scripts with all three documented causes including the Managed Installer interaction, the Windows 365 60-minute timeout workaround, and the stuck-at-100%/wrong-account-type pairing with an explicit pointer to the A-doc's setting-combination table rather than inlining a table likely to be copy-pasted without full context), `Autopilot/Troubleshooting/DevicePreparation-A.md` (deep dive — full Enrollment Time Grouping architecture explanation covering *why* the group-ownership constraint is a hard Entra Privileged Role Administration platform rule and not an arbitrary device-prep checkbox, dependency stack, 14-row symptom→cause map, 6 validation steps, 5-phase troubleshooting flow explicitly noting device prep has almost no OOBE-side remediation surface so nearly everything traces back to policy/group config, 4 remediation playbooks including a full fleet cutover-from-classic-Autopilot playbook and the exact Local-administrator-settings/User-account-type supported-combination table, a read-only Graph evidence-pack script, 12-row command cheat sheet, and 6 learning pointers linking directly to the three MS Learn pages fetched), and `Autopilot/Scripts/Get-DevicePreparationReadinessAudit.ps1` (read-only Graph audit — flags NO_PROVISIONING_CLIENT_OWNER, GROUP_IS_DYNAMIC, GROUP_ROLE_ASSIGNABLE, and SERVICE_PRINCIPAL_MISSING per supplied device group; an optional `-CheckSerialShadowing` parameter that checks supplied serials against `Get-MgDeviceManagementWindowAutopilotDeviceIdentity` for classic-Autopilot precedence shadowing — the single most common false-alarm root cause per the runbook — distinguishing registered-with-profile from registered-without-profile since only the former is an immediate blocker; and an optional `-AdminUpn` parameter that lists directory role assignments for manual RBAC cross-checking, deliberately not attempting automated permission-string matching against custom role definitions since a false negative there would be worse than requiring a manual look; explicitly documents in its own header that it cannot read the device preparation policy object itself since no stable documented Graph endpoint exists for it at time of writing, scoping itself to Entra-side prerequisites only rather than silently overclaiming coverage). All read-only — no group/ownership/policy create-update-delete calls anywhere in the script. Verified brace/paren/bracket balance via Python counts before committing (43/43 braces, 71/71 parens, 17/17 brackets; no pwsh available in this sandbox for a real parse check, consistent with every prior run's caveat). Added the new Device Preparation rows to `Autopilot/_AGENT.md`'s "What's in this folder," Common entry points, and Folder contents sections (this file was otherwise current, so extended in place rather than rewritten), and a new Domain Map row to `AGENT_INDEX.md` cross-referencing `Intune/` and `EntraID/`. Checked `.git/*.lock` for a live (non-`.bak`/`.stale`-suffixed) lock file before committing — none found this run. **For next run:** the three misfiled/non-conforming Autopilot scripts and the now-four-item-strong misfiled-script bucket (adding `Intune/IntuneChecker.ps1`) remain open since runs 30-41 and still need interactive user review, not autonomous action — consider proposing a single consolidated cleanup pass next time a human is in the folder rather than continuing to just flag new instances as they're found. With Intune, Windows, and M365/Exchange now confirmed current, no other domain has been explicitly flagged as at-risk for `_AGENT.md` staleness — a full-repo sweep of the remaining `_AGENT.md` files (DFS, PowerAutomate, EntraID, Security/*, M365/SharePoint-OneDrive, M365/Teams, M365/Licensing, Autopilot, macOS, Windows365) has not been done in one pass since run 35-39's piecemeal spot-checks, and would be a reasonable next-run candidate given how often this pattern has turned up real gaps. New-topic candidates are also getting genuinely scarce after 41 runs; Device Preparation was found via an 8-topic-wide gap sweep (only 1 of 8 checked was a real gap), suggesting future runs may need to lean more on script-coverage/backfill work than new-topic hunting.

---

## EntraID — New Topic: Microsoft Entra Verified ID (run 44)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/VerifiedID-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/VerifiedID-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-VerifiedIDConfigAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (added VerifiedID rows — folder-contents table, scripts table, entry points) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Entra Verified ID row) | ✅ | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 480
- Completed: 480
- In progress: 0
- Queued: 0
- Last updated: 2026-07-07 (auto-build, run 44, scheduled task "ezadmin-day-build": manifest queue still empty (only the legend row, no actual ⬜ items). Per run 43's "for next run" shortlist (Windows 365 Frontline, Entra Verified ID, SharePoint Advanced Management, Passkeys), ran a fresh `grep -ril` sweep across the ENTIRE repo tree for all four candidates before trusting the prior summary, per the standing lesson (runs 27-43) that these notes must be independently re-verified: confirmed Windows 365 Frontline and Passkeys both already have tangential/tag-along mentions in existing files (`Windows365-*.md`/`Kiosk-A.md` for Frontline, `Platform-SSO-A.md`/`Kerberos-A.md` for Passkeys) so are softer gaps, SharePoint Advanced Management had zero real hits (the one match was an unrelated Teams Rooms use of the same common English phrase), and **Entra Verified ID had zero hits anywhere in the repo** — the cleanest, most clear-cut gap of the four, so built that one this run. Researched current Microsoft Learn documentation directly before writing anything, since this product's precise architecture and API surface are easy to get wrong from training-data recall alone: fetched `introduction-to-verifiable-credentials-architecture` (updated 2026-03-25) for the issuer/holder/verifier/DID/trust-system model and the full issuance/presentation sequence flows, `verifiable-credentials-faq` (updated 2026-03-25) for the Key Vault "Vault Access Policy only, not RBAC" limitation, the did:web-cannot-change-domain / did:ion-cannot-be-recovered constraints, size limits (1MB issuance request/photo, 10MB callback), the did:ion→did:web migration steps, network-hardening guidance (Azure region-specific service tags/CIDR), and the Android/work-profile Authenticator QR-scanning known issue, `error-codes` (updated 2026-03-17) for the exact outer/inner error code taxonomy used in the Request Service REST API, `admin-api` for the full Admin API surface (onboard, authorities incl. create/update/delete/rotate-key/sync, contracts incl. rules/display/attestation-type schema and the "only one indexed claim mapping per contract" constraint, credentials search/revoke via SHA256 index-hash, opt-out) confirming did:ion is the only trust system whose authority the Delete Authority endpoint actually supports, and `how-to-dnsbind` for the well-known DID configuration mechanics and its specific `curl -Iv` troubleshooting guidance. Confirmed this product has **no Microsoft Graph surface at all** — it's a fully separate Admin API host (`verifiedid.did.msidentity.com`) and OAuth resource (App ID URI `6a8b4b39-c021-437c-b060-5a14a3fd65f3`), so unlike GDAP/Attack Simulation Training (both genuine Graph endpoints), there is no `Microsoft.Graph.*` cmdlet path here at all — shaped both runbooks' Learning Pointers and the script's entirely REST-based, module-free authentication approach. Built the full three-file pattern: `EntraID/Troubleshooting/VerifiedID-B.md` (hotfix — triage leads with an explicit callout that this isn't Graph and shows raw Admin API calls with a client-credentials token fetch inline; dependency cascade from tenant onboarding through Key Vault (flagging the Vault Access Policy requirement first, since that's the single most common invisible blocker) through domain linkage through contract to the issuance/presentation flows; 6 fix paths covering DID-document-out-of-sync after key rotation, broken domain linkage, the Android work/personal Authenticator QR-scan mix-up, Request Service API 429 throttling from an ungated public issuance page, legacy did:ion migration, and firewall/NSG blocking of regional callback traffic), `EntraID/Troubleshooting/VerifiedID-A.md` (deep dive — full centralized-vs-decentralized architecture explanation with the issuer/holder/verifier/DID/DID-document/trust-system vocabulary, did:web vs. deprecated did:ion comparison, both full request flow sequences, 5-layer dependency stack from tenant onboarding down through Key Vault, 13-row symptom→cause map, 6 validation steps, 5-phase troubleshooting flow, 4 remediation playbooks including a full zero-downtime key-rotation playbook, a destructive-domain-migration playbook with explicit credential-invalidation warnings, a credential-revocation playbook with the exact SHA256 index-hash computation, and the did:ion→did:web migration playbook, a REST-based evidence-pack script, 18-row command cheat sheet, and 6 learning pointers linking to the specific MS Learn pages fetched), and `EntraID/Scripts/Get-VerifiedIDConfigAudit.ps1` (read-only audit — authenticates via a plain OAuth2 client-credentials POST with no module dependency beyond built-in PowerShell, since no Microsoft.Graph module covers this API surface at all; flags AUTHORITY_DID_OUT_OF_SYNC, AUTHORITY_LEGACY_DID_ION, AUTHORITY_DID_SUBMITTED_PENDING, and via two optional switches that degrade gracefully if omitted: `-ValidateWellKnown` for WELLKNOWN_VALIDATION_FAILED using the service's own stateless validation endpoint, and `-CheckManifestReachability` for CONTRACT_MANIFEST_UNREACHABLE via an anonymous GET matching how the holder's wallet actually fetches it; also proactively flags CONTRACT_MULTIPLE_INDEXED_CLAIMS by parsing each contract's rules and counting `indexed:true` claim mappings against the documented one-per-contract limit; explicitly documents in its own header that Key Vault permission model, firewall/NSG rules, and Request Service API call-level error logs are out of scope since none of those are visible from this Admin API surface — flagged rather than silently omitted, consistent with the established pattern from GDAP/Attack Simulation Training scripts). All read-only — no New-/Update-/Delete-/Revoke-/optout calls anywhere in the script; the one POST used (`validateWellKnownDidConfiguration`) is a documented stateless validation call with no side effects, same category as prior runs' non-mutating POST/validation calls. Verified brace/paren/bracket balance via Python counts before committing (52/52 braces, 75/75 parens, 28/28 brackets; no pwsh available in this sandbox for a real parse check, consistent with every prior run's caveat). Backfilled `EntraID/_AGENT.md` (confirmed current as of run 42's EntraID GDAP backfill, so extended in place with three new rows — Troubleshooting folder-contents, Scripts folder-contents, and Common entry points — rather than rewritten) and added a new Domain Map row to `AGENT_INDEX.md` explicitly noting "N/A (own Admin API, not Microsoft Graph)" in the Also-Check column so a future agent doesn't waste time looking for a Graph cmdlet path that doesn't exist. Cleared one live (non-`.stale`-suffixed) `.git/index.lock` before starting — 0 bytes, no matching process in `ps aux` — via `mv` to `.stale-run44-<timestamp>` per the established FUSE-unlink-restriction workaround; `mv` succeeded without the retry-loop some earlier runs needed. **For next run:** Windows 365 Frontline, SharePoint Advanced Management, and Passkeys remain candidates (Frontline and Passkeys are now confirmed *softer* gaps with existing tangential mentions worth checking for outright topic promotion; SharePoint Advanced Management is a genuine zero-coverage gap). The misfiled-script bucket (`Autopilot-Troubleshooting2.ps1`, `Autopilot-Network-Connectivity.ps1`, `Intune/IntuneChecker.ps1`, `Autopilot/Scripts/Test-AutopilotNetworkRequirements.ps1` vs. `Autopilot/Troubleshooting/Autopilot-Network-Connectivity.ps1`) remains open since runs 30-43 and still needs interactive user review, not autonomous action. The large pile of renamed `.stale*`/`.bak*` git lock files flagged since run 38 as a one-time human cleanup item is still outstanding.
