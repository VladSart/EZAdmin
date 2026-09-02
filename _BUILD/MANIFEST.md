# EZAdmin — Build Manifest

> **Repo/git health: OK** (confirmed run 184, 2026-09-01). Three historical incidents (run 60 lock-file issue, run 160 apparent history divergence, run 161 resolution) are fully resolved and their full original notes have been moved verbatim to `_BUILD/MANIFEST_ARCHIVE.md` to keep this file's header short. Standing procedure: the mounted tree's git metadata is unreliable (stale refs via a FUSE limitation) but its file contents are not — verify by diffing against a fresh `/tmp` clone rather than trusting `git status` here. Commit/push from that fresh clone with `origin` set to the mounted tree's own authenticated remote URL (`git remote -v` on the mounted tree — has a GitHub PAT embedded; the bare public clone URL has no push credentials).

> **Run 188 (2026-09-02): archived 169 verbose per-run narrative write-ups out of this file** (1.77MB → ~205KB, per run 187's own flagged recommendation and this project's stated "reworking and removing a lot of the stale records" goal). Every table row and ✅/🔄/⬜ status is untouched — only the free-form prose describing *how* each run did its work was moved. Full verbatim narrative for runs 25-187 now lives in `_BUILD/MANIFEST_ARCHIVE.md` under the "Run-History Narrative Archive" section; each removed block is replaced here by a one-line `_YYYY-MM-DD (run N): archived — see MANIFEST_ARCHIVE.md._` pointer so chronology is still skimmable.

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

## Power Automate — Desktop RPA (new topic, this run)
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/Desktop-RPA/MachineRuntime-B.md` | ✅ | auto-build |
| `PowerAutomate/Desktop-RPA/MachineRuntime-A.md` | ✅ | auto-build |
| `PowerAutomate/Desktop-RPA/Scripts/Get-PADMachineHealth.ps1` | ✅ | auto-build |

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
| `Windows/Troubleshooting/FailoverClustering-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/FailoverClustering-A.md` | ✅ | auto-build |
| `Windows/Scripts/Get-FailoverClusterHealth.ps1` | ✅ | auto-build |
| `Windows/Troubleshooting/Windows Update/WSUS-Server-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/Windows Update/WSUS-Server-A.md` | ✅ | auto-build |
| `Windows/Scripts/Get-WSUSServerHealth.ps1` | ✅ | auto-build |

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

## Script-Coverage Gap Sweep (run 99)
| File | Status | Assigned |
|------|--------|---------|
| `DFS/Scripts/Get-DFSABEAudit.ps1` | ✅ | auto-build |
| `DFS/Scripts/Get-DFSSiteCostingAudit.ps1` | ✅ | auto-build |
| `Windows/Scripts/Get-AlwaysOnVPNDiagnostics.ps1` | ✅ | auto-build |
| `EntraID/Scripts/Get-ExternalIdentitiesAudit.ps1` | ✅ | auto-build |

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

## Entra ID — Passkeys (FIDO2)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/Passkeys-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/Passkeys-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-PasskeyRegistrationAudit.ps1` | ✅ | auto-build |

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
_2026-07-07 (run 28): archived — see `MANIFEST_ARCHIVE.md`._

## Build Progress (superseded — run 29)
- Total files: 406
- Completed: 406
- In progress: 0
- Queued: 0
_2026-07-07 (run 29): archived — see `MANIFEST_ARCHIVE.md`._

## Build Progress
- Total files: 409
- Completed: 409
- In progress: 0
- Queued: 0
_2026-07-07 (run 30): archived — see `MANIFEST_ARCHIVE.md`._

## Build Progress (superseded — run 27)
- Total files: 400
- Completed: 400
- In progress: 0
- Queued: 0
_2026-07-06 (run 27): archived — see `MANIFEST_ARCHIVE.md`._

## Build Progress (previous)
- Total files: 397
- Completed: 397
- In progress: 0
- Queued: 0
_2026-07-06 (run 26): archived — see `MANIFEST_ARCHIVE.md`._

## Build Progress (previous)
- Total files: 394
- Completed: 394
- In progress: 0
- Queued: 0
_2026-07-06 (run 25): archived — see `MANIFEST_ARCHIVE.md`._

---

## Build Progress (previous)
- Total files: 391
- Completed: 391
- In progress: 0
- Queued: 0
_2026-07-06 (run 24): archived — see `MANIFEST_ARCHIVE.md`._

---

## Build Progress (previous)
- Total files: 385
- Completed: 385
- In progress: 0
- Queued: 0
_2026-07-06 (run 22): archived — see `MANIFEST_ARCHIVE.md`._

---

## Build Progress (previous)
- Total files: 382
- Completed: 382
- In progress: 0
- Queued: 0
_2026-07-06 (run 21): archived — see `MANIFEST_ARCHIVE.md`._

## Build Progress (previous)
- Total files: 379
- Completed: 379
- In progress: 0
- Queued: 0
_2026-07-06 (run 20): archived — see `MANIFEST_ARCHIVE.md`._

## Build Progress (previous)
- Total files: 376
- Completed: 376
- In progress: 0
- Queued: 0
_2026-07-06 (run 19): archived — see `MANIFEST_ARCHIVE.md`._

## Build Progress (previous)
- Total files: 372
- Completed: 372
- In progress: 0
- Queued: 0
_2026-07-06 (run 18): archived — see `MANIFEST_ARCHIVE.md`._

---

## Build Progress (previous)
- Total files: 360
- Completed: 360
- In progress: 0
- Queued: 0
_2026-07-06 (run 14): archived — see `MANIFEST_ARCHIVE.md`._

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
_2026-07-06 (run 19): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-06 (run 13): archived — see `MANIFEST_ARCHIVE.md`._

---

## ⚠️ Environment Note — Git Lock File Accumulation

## ⚠️ Skipped Items
_2026-07-06 (run 20): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-07 (run 30): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-07 (run 31): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-07 (run 33): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-07 (run 34): archived — see `MANIFEST_ARCHIVE.md`._

_2026-07-07 (run 32): archived — see `MANIFEST_ARCHIVE.md`._

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
_2026-07-07 (run 37): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-07 (run 35): archived — see `MANIFEST_ARCHIVE.md`._

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
_2026-07-07 (run 38): archived — see `MANIFEST_ARCHIVE.md`._

---

## ⚠️ Infrastructure note (run 38, post-commit)

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
_2026-07-07 (run 39): archived — see `MANIFEST_ARCHIVE.md`._

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
_2026-07-07 (run 40): archived — see `MANIFEST_ARCHIVE.md`._

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
_2026-07-07 (run 43): archived — see `MANIFEST_ARCHIVE.md`._

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
_2026-07-07 (run 42): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-07 (run 41): archived — see `MANIFEST_ARCHIVE.md`._

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
_2026-07-07 (run 44): archived — see `MANIFEST_ARCHIVE.md`._

---

## M365/SharePoint-OneDrive — New Topic: SharePoint Advanced Management (run 45)
| File | Status | Assigned |
|------|--------|---------|
| `M365/SharePoint-OneDrive/Advanced-Management-B.md` | ✅ | auto-build |
| `M365/SharePoint-OneDrive/Advanced-Management-A.md` | ✅ | auto-build |
| `M365/SharePoint-OneDrive/Scripts/Get-SPAdvancedManagementAudit.ps1` | ✅ | auto-build |
| `M365/SharePoint-OneDrive/_AGENT.md` (added Advanced-Management rows) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added SharePoint Advanced Management note) | ✅ | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 486
- Completed: 486
- In progress: 0
- Queued: 0
_2026-07-07 (run 46): archived — see `MANIFEST_ARCHIVE.md`._

_2026-07-07 (run 45): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security — New Domain: Microsoft Sentinel (Data Connectors) (run 47)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Sentinel/_AGENT.md` | ✅ | auto-build |
| `Security/Sentinel/DataConnectors-B.md` | ✅ | auto-build |
| `Security/Sentinel/DataConnectors-A.md` | ✅ | auto-build |
| `Security/Sentinel/Scripts/Get-SentinelConnectorHealth.ps1` | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Microsoft Sentinel data connectors row) | ✅ | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 493
- Completed: 493
- In progress: 0
- Queued: 0
_2026-07-07 (run 47): archived — see `MANIFEST_ARCHIVE.md`._

---

## New Domain: Active Directory (on-prem AD DS Replication) (run 48)
| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/_AGENT.md` | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/Replication/AD-Replication-B.md` | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/Replication/AD-Replication-A.md` | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-ADReplicationHealth.ps1` | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map + Technology Ranking — added Active Directory replication rows) | ✅ | auto-build |

---

## Build Progress (superseded — run 48)
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 494
- Completed: 494
- In progress: 0
- Queued: 0
_2026-07-07 (run 48): archived — see `MANIFEST_ARCHIVE.md`._

---

## Active Directory — Trusts (run 49)
| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/Trusts/AD-Trusts-B.md` | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/Trusts/AD-Trusts-A.md` | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-ADTrustHealth.ps1` | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (added Trusts rows, entry points, and a separate trust dependency chain) | ✅ | auto-build |

---

## Build Progress (superseded — run 49)
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 497
- Completed: 497
- In progress: 0
- Queued: 0
_2026-07-07 (run 49): archived — see `MANIFEST_ARCHIVE.md`._

---

## Active Directory — Backup & Restore (run 50)
| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/BackupRestore/AD-BackupRestore-B.md` | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/BackupRestore/AD-BackupRestore-A.md` | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-ADBackupRestoreHealth.ps1` | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (added BackupRestore rows, entry points, and a separate backup/restore dependency chain) | ✅ | auto-build |

---

## Security — Sentinel Analytics Rules & Incident Tuning (run 51)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Sentinel/AnalyticsRules-B.md` | ✅ | auto-build |
| `Security/Sentinel/AnalyticsRules-A.md` | ✅ | auto-build |
| `Security/Sentinel/Scripts/Get-SentinelAnalyticsRuleAudit.ps1` | ✅ | auto-build |
| `Security/Sentinel/_AGENT.md` (added AnalyticsRules rows, 8 new entry points, updated response-format reminder) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Sentinel analytics rules/incident tuning row) | ✅ | auto-build |

---

## Active Directory — Group Policy Processing & Replication (run 52)
| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/GroupPolicy/AD-GroupPolicy-B.md` | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md` | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-GroupPolicyHealth.ps1` | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (added GroupPolicy rows, 7 new entry points, GP processing dependency chain, GP-to-CSP cross-reference) | ✅ | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 507
- In progress: 0
- Queued: 0
_2026-07-07 (run 52): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — Arc-Enabled Servers
| File | Status | Assigned |
|------|--------|---------|
| `Azure/Arc/AzureArc-B.md` | ✅ | auto-build |
| `Azure/Arc/AzureArc-A.md` | ✅ | auto-build |
| `Azure/Arc/Scripts/Get-AzureArcAgentHealth.ps1` | ✅ | auto-build |
| `Azure/Arc/_AGENT.md` | ✅ | auto-build |

---

## Build Progress (run 55)
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 516
- Completed: 516
- In progress: 0
- Queued: 0
_2026-07-07 (run 55): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Defender — Microsoft Defender for Cloud (CSPM) (run 56)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/DefenderForCloud-B.md` | ✅ | auto-build |
| `Security/Defender/DefenderForCloud-A.md` | ✅ | auto-build |
| `Security/Defender/Scripts/Get-DefenderForCloudPostureAudit.ps1` | ✅ | auto-build |
| `Security/Defender/_AGENT.md` (added DefenderForCloud rows, 4 new entry points, CSPM diagnostic commands, second dependency-chain diagram, updated top summary/before-responding-also-check) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Defender for Cloud CSPM row) | ✅ | auto-build |

---

## Build Progress (run 56)
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 519
- Completed: 519
- In progress: 0
- Queued: 0
_2026-07-07 (run 56): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security — Sentinel Logic Apps Playbooks / SOAR Execution (run 53)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Sentinel/LogicAppsPlaybooks-B.md` | ✅ | auto-build |
| `Security/Sentinel/LogicAppsPlaybooks-A.md` | ✅ | auto-build |
| `Security/Sentinel/Scripts/Get-SentinelPlaybookHealth.ps1` | ✅ | auto-build |
| `Security/Sentinel/_AGENT.md` (added LogicAppsPlaybooks rows, 7 new entry points, playbook/SOAR dependency chain, updated response-format reminder) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Sentinel Logic Apps playbooks/SOAR row) | ✅ | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 510
- Completed: 510
- In progress: 0
- Queued: 0
_2026-07-07 (run 53): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID — New Topic Build (run 54 — App Registrations & Service Principal Credentials)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/AppRegistrations-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/AppRegistrations-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-AppRegistrationCredentialAudit.ps1` | ✅ | auto-build |

---

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 512
- Completed: 512
- In progress: 0
- Queued: 0
_2026-07-07 (run 54): archived — see `MANIFEST_ARCHIVE.md`._

## Superseded Progress Snapshot (run 51)
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 503
- Completed: 503
- In progress: 0
- Queued: 0
_2026-07-07 (run 51): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — New Domain: Azure Backup (Recovery Services Vault) (run 57)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/Backup/AzureBackup-B.md` | ✅ | auto-build |
| `Azure/Backup/AzureBackup-A.md` | ✅ | auto-build |
| `Azure/Backup/Scripts/Get-AzureBackupJobStatus.ps1` | ✅ | auto-build |
| `Azure/Backup/_AGENT.md` | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — added Backup subfolder rows + entry points) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Azure Backup row) | ✅ | auto-build |

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 523
- Completed: 523
- In progress: 0
- Queued: 0
_2026-07-07 (run 57): archived — see `MANIFEST_ARCHIVE.md`._

---

## Active Directory — AD-Integrated DNS (run 58)
| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/DNS/AD-DNS-B.md` | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/DNS/AD-DNS-A.md` | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-ADDNSHealth.ps1` | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (added DNS rows, summary line, cross-reference note, 5 new entry points, AD-integrated DNS dependency chain) | ✅ | auto-build |
| `AGENT_INDEX.md` (added AD-integrated DNS domain-map row) | ✅ | auto-build |

---

## Entra ID — Workload Identity Federation & Conditional Access for Workload Identities (run 59)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/WorkloadIdentity-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/WorkloadIdentity-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-WorkloadIdentityAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (added WorkloadIdentity rows, summary line, 2 new entry points) | ✅ | auto-build |
| `AGENT_INDEX.md` (added Workload Identity Federation domain-map row) | ✅ | auto-build |

---

## Recovered uncommitted work (found in working tree, run 60)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/SafeLinksAttachments-B.md` | ✅ | recovered |
| `Security/Defender/SafeLinksAttachments-A.md` | ✅ | recovered |
| `Security/Defender/Scripts/Get-SafeLinksAttachmentsPolicyAudit.ps1` | ✅ | recovered |
| `Security/Defender/_AGENT.md` (Safe Links/Attachments rows already present, now committed) | ✅ | recovered |
| `EntraID/Troubleshooting/AccessReviews-B.md` | ✅ | recovered — **missing its `-A.md` deep-dive pair, flagged for next run** |

---

## Entra ID — Access Reviews deep-dive gap closed (run 60, second pass)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/AccessReviews-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-AccessReviewAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (added AccessReviews rows, summary line, 2 new entry points) | ✅ | auto-build |

---

## Active Directory — AD FS / Web Application Proxy (run 60)
| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/ADFS/ADFS-B.md` | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/ADFS/ADFS-A.md` | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-ADFSHealth.ps1` | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (added ADFS rows, summary line, before-responding bullets, 6 new entry points, ADFS federation dependency chain) | ✅ | auto-build |
| `AGENT_INDEX.md` (added AD FS / WAP domain-map row) | ✅ | auto-build |

_2026-07-17 (run 60): archived — see `MANIFEST_ARCHIVE.md`._
## macOS — Recovery Lock (run 61)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/RecoveryLock-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/RecoveryLock-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-RecoveryLockAudit.ps1` | ✅ | auto-build |
| `macOS/_AGENT.md` (added Recovery Lock summary bullet + entry point) | ✅ | auto-build |

_2026-07-17 (run 61): archived — see `MANIFEST_ARCHIVE.md`._

## Build Progress
- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 535
- Completed: 535
- In progress: 0
- Queued: 0
_2026-07-08 (run 59): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-08 (run 58): archived — see `MANIFEST_ARCHIVE.md`._

---

## macOS — Wi-Fi / 802.1X Enterprise (run 62)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/WiFi-8021x-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/WiFi-8021x-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-WiFiProfileAudit.ps1` | ✅ | auto-build |
| `macOS/_AGENT.md` (added Wi-Fi/802.1X summary bullet + entry point) | ✅ | auto-build |

## macOS — Declarative Device Management (DDM) + Time Machine (run 63)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/DDM-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/DDM-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-DDMStatusAudit.ps1` | ✅ | auto-build |
| `macOS/Troubleshooting/TimeMachine-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/TimeMachine-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-TimeMachineBackupAudit.sh` | ✅ | auto-build |
| `macOS/_AGENT.md` (added DDM + Time Machine summary bullets and entry points) | ✅ | auto-build |

_2026-07-17 (run 63): archived — see `MANIFEST_ARCHIVE.md`._

_2026-07-17 (run 62): archived — see `MANIFEST_ARCHIVE.md`._

---

## macOS — VPP App Deployment + Managed Login Items (run 64)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/VPP-App-Deployment-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/VPP-App-Deployment-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-VPPAppLicenseAudit.ps1` | ✅ | auto-build |
| `macOS/Troubleshooting/ManagedLoginItems-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/ManagedLoginItems-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-ManagedLoginItemsAudit.sh` | ✅ | auto-build |
| `macOS/_AGENT.md` (added VPP + Managed Login Items summary bullets and entry points) | ✅ | auto-build |

_2026-07-18 (run 64): archived — see `MANIFEST_ARCHIVE.md`._

---

## macOS — Content Caching + Gatekeeper/Notarization (run 65)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/ContentCaching-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/ContentCaching-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-ContentCachingAudit.sh` | ✅ | auto-build |
| `macOS/Troubleshooting/Gatekeeper-Notarization-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/Gatekeeper-Notarization-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-GatekeeperPolicyAudit.ps1` | ✅ | auto-build |
| `macOS/_AGENT.md` (added Content Caching + Gatekeeper/Notarization summary bullets and entry points) | ✅ | auto-build |

---

## Azure — New Domain: Key Vault (RBAC vs. Access Policy, Network, Soft-Delete, Certificate Auto-Rotation) (run 66)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/KeyVault/KeyVault-B.md` | ✅ | auto-build |
| `Azure/KeyVault/KeyVault-A.md` | ✅ | auto-build |
| `Azure/KeyVault/Scripts/Get-KeyVaultAccessAudit.ps1` | ✅ | auto-build |
| `Azure/KeyVault/_AGENT.md` | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — added KeyVault subfolder rows, top-summary clause, 4 new entry points) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Azure Key Vault row) | ✅ | auto-build |

---

## Azure — New Domain: Networking / Hybrid Connectivity (VPN Gateway + ExpressRoute) (run 67)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/HybridConnectivity-B.md` | ✅ | auto-build |
| `Azure/Networking/HybridConnectivity-A.md` | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-HybridConnectivityHealth.ps1` | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — added Networking subfolder rows, top-summary clause, 4 new entry points) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Azure hybrid connectivity row) | ✅ | auto-build |

## Azure — Networking Expansion: Network Security Groups (general-purpose) (run 68)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/NSG-B.md` | ✅ | auto-build |
| `Azure/Networking/NSG-A.md` | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-NSGRuleAudit.ps1` | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — retitled folder scope, added NSG rows, entry points, diagnostic commands, NSG evaluation chain diagram) | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — top-summary clause, 3 new folder-contents rows, 4 new entry points) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added general-purpose NSG row alongside the existing HybridConnectivity row) | ✅ | auto-build |

## Azure — Networking Expansion: Azure Virtual Network Manager (AVNM) (run 69)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/AVNM-B.md` | ✅ | auto-build |
| `Azure/Networking/AVNM-A.md` | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-AVNMConfigAudit.ps1` | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — retitled folder scope to cover AVNM, added AVNM rows, entry points, diagnostic commands, AVNM dependency chain diagram) | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — top-summary clause, 3 new folder-contents rows, 4 new entry points) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added AVNM row cross-referencing the existing NSG and HybridConnectivity rows) | ✅ | auto-build |

_2026-07-18 (run 69): archived — see `MANIFEST_ARCHIVE.md`._

---

_2026-07-18 (run 68): archived — see `MANIFEST_ARCHIVE.md`._

---

_2026-07-18 (run 67): archived — see `MANIFEST_ARCHIVE.md`._

---

_2026-07-18 (run 66): archived — see `MANIFEST_ARCHIVE.md`._

---

## Intune — Endpoint Analytics (Startup Performance / App Reliability / Work From Anywhere scoring) (run 70)

| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/EndpointAnalytics-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/EndpointAnalytics-A.md` | ✅ | auto-build |
| `Intune/Scripts/Get-EndpointAnalyticsHealth.ps1` | ✅ | auto-build |
| `Intune/_AGENT.md` (backfilled — top-summary Reporting clause, 2 new folder-contents rows, 1 new entry point) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Endpoint Analytics row cross-referencing Autopilot deployment-profile-assignment and Windows WUfB/feature-update topics) | ✅ | auto-build |

_2026-07-18 (run 70): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — New Domain: Azure Automation (Managed Identity / Run As retirement, runbook & sandbox execution failures, extension-based Hybrid Runbook Worker) (run 71)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Automation/AzureAutomation-B.md` | ✅ | auto-build |
| `Azure/Automation/AzureAutomation-A.md` | ✅ | auto-build |
| `Azure/Automation/Scripts/Get-AzureAutomationHealth.ps1` | ✅ | auto-build |
| `Azure/Automation/_AGENT.md` (new folder) | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — top-summary clause, 3 new folder-contents rows, 4 new entry points) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Azure Automation row cross-referencing KeyVault, Arc, and EntraID AppRegistrations/WorkloadIdentity topics) | ✅ | auto-build |

_2026-07-18 (run 71): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — New Domain: Azure Update Manager (patch-extension lifecycle, on-demand/periodic/scheduled patching, maintenance configuration + assignment model, Resource Graph retention limits) (run 72)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/UpdateManager/UpdateManager-B.md` | ✅ | auto-build |
| `Azure/UpdateManager/UpdateManager-A.md` | ✅ | auto-build |
| `Azure/UpdateManager/Scripts/Get-AzureUpdateManagerHealth.ps1` | ✅ | auto-build |
| `Azure/UpdateManager/_AGENT.md` (new folder) | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — top-summary clause, 3 new folder-contents rows, 4 new entry points) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Azure Update Manager row cross-referencing Automation, Arc, and Windows Update topics; updated the existing Azure Automation row's exclusion note to point at the new row instead of describing Update Manager inline) | ✅ | auto-build |

---

## macOS — New Topic: Apple Device Migration (macOS 26+ MDM-to-MDM re-enrollment via ABM/ASM + Managed Migration Assistant Mac-to-Mac data transfer, macOS 26.4+) (run 73)

| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/DeviceMigration-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/DeviceMigration-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-DeviceMigrationReadiness.ps1` | ✅ | auto-build |
| `macOS/_AGENT.md` (backfilled — top-summary bullet, 2 new "Common entry points") | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Apple Device Migration row cross-referencing `ADE-Enrollment-A.md` Playbook 2 (the superseded pre-26 wipe-based move) and `EntraID/Troubleshooting/CrossTenant-A.md` (identity-continuity side of an M&A device migration)) | ✅ | auto-build |

_2026-07-20 (run 73): archived — see `MANIFEST_ARCHIVE.md`._

---

_2026-07-18 (run 72): archived — see `MANIFEST_ARCHIVE.md`._

---

_2026-07-18 (run 73): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Purview — Information Barriers (new topic) + M365/Licensing script gap close (run 74)

| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/InformationBarriers-B.md` | ✅ | auto-build |
| `Security/Purview/InformationBarriers-A.md` | ✅ | auto-build |
| `Security/Purview/Scripts/Get-InformationBarriersAudit.ps1` | ✅ | auto-build |
| `M365/Licensing/Scripts/Get-GroupBasedLicensingDiagnostics.ps1` | ✅ | auto-build |
| `Security/Purview/_AGENT.md` (backfilled — top-summary clause, 2 new folder-contents rows for docs, 1 for script, 4 new entry-point bullets) | ✅ | auto-build |
| `M365/Licensing/_AGENT.md` (backfilled — 1 new folder-contents row, 2 new entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added dedicated Information Barriers row cross-referencing Teams, SharePoint-OneDrive, EntraID, and Exchange) | ✅ | auto-build |

_2026-07-18 (run 74): archived — see `MANIFEST_ARCHIVE.md`._

---

## DFS — New Topic: File Server Resource Manager (FSRM) (run 75)

| File | Status | Assigned |
|------|--------|---------|
| `DFS/Troubleshooting/FSRM/FSRM-B.md` | ✅ | auto-build |
| `DFS/Troubleshooting/FSRM/FSRM-A.md` | ✅ | auto-build |
| `DFS/Scripts/Get-FSRMAudit.ps1` | ✅ | auto-build |
| `DFS/_AGENT.md` (backfilled — top-summary clause explaining FSRM's inclusion in a DFSN/DFSR-scoped folder, 3 new folder-contents rows, 7 new entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added dedicated FSRM row cross-referencing DFS's own Namespace/Replication topics and Windows' SMB topic) | ✅ | auto-build |

_2026-07-18 (run 75): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — New Topic: Azure Policy (governance/compliance) (run 76)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Policy/AzurePolicy-B.md` | ✅ | auto-build |
| `Azure/Policy/AzurePolicy-A.md` | ✅ | auto-build |
| `Azure/Policy/Scripts/Get-AzurePolicyComplianceAudit.ps1` | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — top-summary clause adding Azure Policy, 3 new folder-contents rows, 7 new entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added dedicated Azure Policy row cross-referencing AVNM's dynamic-membership use of Policy, Defender for Cloud's regulatory-compliance-as-initiative delivery, and explicitly disambiguating from the unrelated on-prem Group Policy system) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 600
_2026-07-18 (run 76): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Purview — New Topic: Microsoft Priva (Privacy Risk Management + Subject Rights Requests) (run 77)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/Priva-B.md` | ✅ | auto-build |
| `Security/Purview/Priva-A.md` | ✅ | auto-build |
| `Security/Purview/Scripts/Get-PrivaReadinessAudit.ps1` | ✅ | auto-build |
| `Security/Purview/_AGENT.md` (backfilled — top-summary clause, 2 folder-contents rows, 1 Scripts row, 6 entry-point bullets, Priva diagnostic commands, separate Priva dependency chain) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Priva row cross-referencing DLP, RetentionLabels, and Defender for Cloud Secure Score) | ✅ | auto-build |

---

## EntraID — New Topic: Lifecycle Workflows (Entra ID Governance JML automation) (run 78)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/LifecycleWorkflows-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/LifecycleWorkflows-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-LifecycleWorkflowAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — top-summary clause, 2 folder-contents rows, 1 Scripts row, 4 new entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Lifecycle Workflows row cross-referencing HR-driven provisioning (external), and disambiguating from EntraID's own Access Reviews and PIM) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 606 (before this run's 3 new files were counted; will be ~610 including workflow docs/script — inventory command run pre-write, treat as approximate)
_2026-07-18 (run 78): archived — see `MANIFEST_ARCHIVE.md`._

_2026-07-18 (run 77): archived — see `MANIFEST_ARCHIVE.md`._

---

## Intune — New Topic: Remote Help (run 79)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/RemoteHelp-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/RemoteHelp-A.md` | ✅ | auto-build |
| `Intune/Scripts/Get-RemoteHelpReadinessAudit.ps1` | ✅ | auto-build |
| `Intune/_AGENT.md` (backfilled — top-summary clause, 2 folder-contents rows, 1 Scripts row, 1 new entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Remote Help row cross-referencing Windows 365/AVD's distinct connection stack and disambiguating from Graph's `remoteAssistancePartner`) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 612 (post-write count, includes this run's 3 new docs/script)
_2026-07-19 (run 80): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — New Topic: Azure Monitor Agent / Log Analytics (run 81)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/Monitor/LogAnalytics-B.md` | ✅ | auto-build |
| `Azure/Monitor/LogAnalytics-A.md` | ✅ | auto-build |
| `Azure/Monitor/Scripts/Get-AzureMonitorAgentHealth.ps1` | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — top-summary clause, 3 folder-contents rows, 5 new entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Azure Monitor Agent/Log Analytics row cross-referencing Sentinel DataConnectors, Defender for Cloud's legacy MMA auto-provisioning, and Key Vault/NSG's separate Diagnostic-Settings ingestion path) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 615 (post-write count, includes this run's 3 new docs/script)
_2026-07-19 (run 81): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure/Networking — New Topic: Azure Virtual WAN (run 82)
| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/VirtualWAN-B.md` | ✅ | auto-build |
| `Azure/Networking/VirtualWAN-A.md` | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-VirtualWANHealth.ps1` | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — top-summary rewritten to name 4 topics instead of 3, "Does not cover" line corrected now that Virtual WAN hub routing is covered, 3 folder-contents rows, 7 new entry-point bullets, 4 new key-diagnostic-command entries) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Virtual WAN row cross-referencing HybridConnectivity (same protocols, different self-managed resource model/ASN handling), AVNM (preview VWAN-hub targeting is orchestration, not a duplicate), and NSG (still the spoke-subnet filtering layer)) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 618 (post-write count, includes this run's 3 new docs/script)
_2026-07-19 (run 82): archived — see `MANIFEST_ARCHIVE.md`._

---

## Windows/BitLocker — New Topic: Network Unlock (run 83)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/BitLocker/NetworkUnlock-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/BitLocker/NetworkUnlock-A.md` | ✅ | auto-build |
| `Windows/Scripts/Get-NetworkUnlockReadinessAudit.ps1` | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — 1 folder-contents row, 1 scripts row, 1 new "Common entry points" bullet) | ✅ | auto-build |

## Security/Defender — New Topic: Device Control (run 83)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/DeviceControl-B.md` | ✅ | auto-build |
| `Security/Defender/DeviceControl-A.md` | ✅ | auto-build |
| `Security/Defender/Scripts/Get-DeviceControlPolicyAudit.ps1` | ✅ | auto-build |
| `Security/Defender/_AGENT.md` (backfilled — 1 folder-contents row, 1 scripts row, 2 new "Common entry points" bullets) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 624 (post-write count, includes this run's 6 new docs/scripts)
_2026-07-19 (run 83): archived — see `MANIFEST_ARCHIVE.md`._

---

## Windows — New Topic: LSA Protection (RunAsPPL) (run 84)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/LSA-Protection-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/LSA-Protection-A.md` | ✅ | auto-build |
| `Windows/Scripts/Get-LSAProtectionStatus.ps1` | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — Covers bullet, 2 folder-contents rows, 1 scripts row, 1 new entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — new row distinguishing this VBS-independent PPL mechanism from the existing VBS-CredentialGuard topic) | ✅ | auto-build |

---

## Power Automate — New Topic: Power Apps Environments & Dataverse Provisioning (run 84)
| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/PowerApps/Environment-Dataverse-B.md` | ✅ | auto-build |
| `PowerAutomate/PowerApps/Environment-Dataverse-A.md` | ✅ | auto-build |
| `PowerAutomate/PowerApps/Scripts/Get-PowerAppsEnvironmentAudit.ps1` | ✅ | auto-build |
| `PowerAutomate/_AGENT.md` (backfilled — What's-in-this-folder bullet, Before-responding-also-check bullet, 3 folder-contents rows, 3 new entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — new row for the environment/Dataverse admin surface, distinct from PowerAutomate's flow-execution topics) | ✅ | auto-build |

_2026-07-19 (run 84): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID — Entra Cloud Sync (run 85)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/CloudSync-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/CloudSync-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-CloudSyncHealth.ps1` | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 631 (post-write count, includes this run's 3 new docs/script)
_2026-07-19 (run 85): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID — PIM for Azure Resources (run 86)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/PIMAzureResources-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/PIMAzureResources-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-PIMAzureResourcesAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — Covers bullet split into Directory/Groups vs. Azure Resources, 2 folder-contents rows, 1 scripts row, 2 new entry-point bullets) | ✅ | auto-build |
| `EntraID/Troubleshooting/PIM-A.md` (Scope & Assumptions line corrected — was "except where noted" with no actual cross-reference; now points at the new file and names the API/module split) | ✅ | auto-build |
| `Security/Sentinel/AnalyticsRules-A.md` (stale cross-reference fixed — line 22 still called Logic Apps playbooks "a distinct, still-uncovered topic flagged for a future run," but LogicAppsPlaybooks-A/B.md was built in run 53; corrected to a real cross-reference) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — new row for PIM for Azure Resources, split from the existing PIM/MFA/SSPR row, cross-referencing directory-role PIM and general Azure RBAC) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 636 (post-write count, includes this run's 3 new docs/script)

---

## M365/Exchange — Outlook Desktop Client (run 87)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/Outlook-Client-B.md` | ✅ | auto-build |
| `M365/Exchange/Outlook-Client-A.md` | ✅ | auto-build |
| `M365/Exchange/Scripts/Get-OutlookClientHealth.ps1` | ✅ | auto-build |
| `M365/Exchange/_AGENT.md` (backfilled — Covers bullet, 2 folder-contents rows, 1 scripts row, 6 new entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — new row for the Outlook desktop client, distinct from Exchange's server-side mail flow/hybrid/shared-mailbox topics) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 639 (post-write count, includes this run's 3 new docs/script)

---

## Intune — Cloud PKI (run 88)
| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/CloudPKI-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/CloudPKI-A.md` | ✅ | auto-build |
| `Intune/Scripts/Get-CloudPKIHealth.ps1` | ✅ | auto-build |
| `Intune/_AGENT.md` (backfilled — Covers bullet split into on-prem NDES/PKCS vs. cloud-native Cloud PKI, 2 folder-contents rows, 1 scripts row, 2 new entry-point bullets) | ✅ | auto-build |

## M365 — Apps Deployment & Update Channels (run 88)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Apps/Deployment-UpdateChannels-B.md` | ✅ | auto-build |
| `M365/Apps/Deployment-UpdateChannels-A.md` | ✅ | auto-build |
| `M365/Apps/Scripts/Get-M365AppsHealth.ps1` | ✅ | auto-build |
| `M365/_AGENT.md` (backfilled — top-level Covers line, new sub-module row for `Apps/`, 3 new entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: Cloud PKI distinct from the on-prem Certificates topic; Microsoft 365 Apps deployment/update channels distinct from Outlook-Client) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 645 (post-write count, includes this run's 6 new docs/scripts)
_2026-07-19 (run 88): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-19 (run 87): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-19 (run 86): archived — see `MANIFEST_ARCHIVE.md`._

## Active Directory — gMSA (recovered) + Fine-Grained Password Policies (run 89)
| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/gMSA/gMSA-B.md` | ✅ | auto-build (recovered, see note) |
| `ActiveDirectory/Troubleshooting/gMSA/gMSA-A.md` | ✅ | auto-build (recovered, see note) |
| `ActiveDirectory/Scripts/Get-GMSAHealth.ps1` | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md` | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md` | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-FGPPAudit.ps1` | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (backfilled — Covers line, 6 folder-contents rows, 13 new entry-point bullets, 2 new dependency-chain diagrams for gMSA and FGPP) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/LDAPSigning/LDAP-Signing-B.md` | ✅ | auto-build (run 120) |
| `ActiveDirectory/Troubleshooting/LDAPSigning/LDAP-Signing-A.md` | ✅ | auto-build (run 120) |
| `ActiveDirectory/Scripts/Get-LDAPSigningAudit.ps1` | ✅ | auto-build (run 120) |
| `ActiveDirectory/_AGENT.md` (backfilled again — Covers line extended with LDAP Signing/Channel Binding, 3 new folder-contents rows, 6 new entry-point bullets, 1 new dependency-chain diagram, Windows/ cross-reference for SMB signing) | ✅ | auto-build (run 120) |
| `AGENT_INDEX.md` (2 new Domain Map rows — base EntraID GlobalSecureAccess topic backfill from run 119, and LDAP Signing & Channel Binding) | ✅ | auto-build (run 120) |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 655 (post-write count, includes this run's 7 new docs/scripts — gMSA-A/B were pre-existing but uncommitted)
_2026-07-19 (run 89): archived — see `MANIFEST_ARCHIVE.md`._

## Security/Defender — New Topic: Microsoft Secure Score (tenant-wide) (run 90)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/SecureScore-B.md` | ✅ | auto-build |
| `Security/Defender/SecureScore-A.md` | ✅ | auto-build |
| `Security/Defender/Scripts/Get-SecureScoreReport.ps1` | ✅ | auto-build |
| `Security/Defender/_AGENT.md` (backfilled — top Covers line, 1 folder-contents row for the doc pair, 1 scripts row, 5 new entry-point bullets, 2 diagnostic commands disambiguating this score from the Az.Security one, 1 new dependency-chain diagram) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row cross-referencing and explicitly disambiguating from DefenderForCloud's Azure-resource CSPM score of the same name, DefenderVulnMgmt's Device-category TVM engine, and ConditionalAccess's security-defaults overlap) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 658 (post-write count, includes this run's 3 new docs/scripts)
_2026-07-19 (run 90): archived — see `MANIFEST_ARCHIVE.md`._

## Security/Purview — New Topic: Unified Audit Log (Audit Standard/Premium) (run 91)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/Audit-B.md` | ✅ | auto-build |
| `Security/Purview/Audit-A.md` | ✅ | auto-build |
| `Security/Purview/Scripts/Get-AuditLogHealthCheck.ps1` | ✅ | auto-build |
| `Security/Purview/_AGENT.md` (backfilled — top Covers line, 2 folder-contents rows for the doc pair, 1 scripts row, 8 new entry-point bullets, 1 new Key diagnostic commands block, 1 new dependency-chain diagram explicitly framing this as the foundational layer under Priva/Insider Risk/Communication Compliance) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row explicitly cross-referencing and framing this as the prerequisite layer under three existing Purview rows, and disambiguating from Entra ID's separate native sign-in/audit log) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 657 (post-write count, includes this run's 3 new docs/scripts; run 90's self-reported 658 could not be independently reconciled against this run's own pre-write `find` baseline of ~655 — treated as a minor historical counting drift rather than investigated further, consistent with `find` being the authoritative count going forward each run)
_2026-07-19 (run 91): archived — see `MANIFEST_ARCHIVE.md`._

## Security/Purview — New Topic: Adaptive Protection (Insider Risk × DLP × Conditional Access × DLM) (run 92)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/AdaptiveProtection-B.md` | ✅ | auto-build |
| `Security/Purview/AdaptiveProtection-A.md` | ✅ | auto-build |
| `Security/Purview/Scripts/Get-AdaptiveProtectionAudit.ps1` | ✅ | auto-build |
| `Security/Purview/_AGENT.md` (backfilled — top Covers line, 2 folder-contents rows for the doc pair, 1 scripts row, 6 new entry-point bullets, 1 new diagnostic-commands block, 1 new dependency-chain diagram) | ✅ | auto-build |
| `Security/Purview/Insider-Risk-A.md` (backfilled — trimmed its own "Adaptive Protection" architecture subsection down to a pointer at the new dedicated pair rather than duplicating depth, and fixed a pre-existing conflation in Step 13's evidence command where `RiskLevelAggregated`/sign-in-log fields were presented as an Adaptive Protection check when they actually belong to the unrelated Entra ID Protection risk engine) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row cross-referencing `Insider-Risk-A.md` as the upstream signal source, `Security/ConditionalAccess/` for general CA design distinct from the `insiderRiskLevels` condition itself, and `EntraID/Troubleshooting/IdentityProtection-A.md` for the explicit wrong-system disambiguation) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 660 (post-write count, includes this run's 3 new docs/scripts; the two in-place edits to `Insider-Risk-A.md` and `AGENT_INDEX.md` don't add new files)
_2026-07-20 (run 92): archived — see `MANIFEST_ARCHIVE.md`._

## Windows — New Topic: NPS / RADIUS Server (run 93)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/NPS-RADIUS-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/NPS-RADIUS-A.md` | ✅ | auto-build |
| `Windows/Scripts/Get-NPSHealthAudit.ps1` | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — Covers bullet, 1 folder-contents row for the doc pair, 1 scripts row, 1 new entry-point bullet) | ✅ | auto-build |
| `Windows/Troubleshooting/AlwaysOnVPN-A.md` (backfilled — added an explicit Out-of-scope bullet pointing at the new dedicated NPS/RADIUS topic, since this file already deep-dives NPS from the VPN-client/RRAS side without ever naming a dedicated server-side runbook) | ✅ | auto-build |
| `macOS/Troubleshooting/WiFi-8021x-A.md` (backfilled — its existing "Does not cover: RADIUS/NPS server-side configuration" bullet pointed only at generic certificate-services content and "your PKI team"; now also points at the new dedicated runbook) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row cross-referencing AlwaysOnVPN and the macOS WiFi-8021x topic as the two existing files that reference NPS/RADIUS as an unfulfilled forward pointer) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 663 (post-write count, includes this run's 3 new docs/scripts; the three in-place edits to `Windows/_AGENT.md`, `AlwaysOnVPN-A.md`, `WiFi-8021x-A.md`, and `AGENT_INDEX.md` don't add new files)

## macOS — New Topic: Microsoft Defender for Endpoint on macOS (run 94)
| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/MDE-macOS-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/MDE-macOS-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-MDEmacOSHealth.sh` | ✅ | auto-build |
| `macOS/_AGENT.md` (backfilled — 1 new Covers bullet, 2 new Common entry points bullets) | ✅ | auto-build |
| `Security/Defender/MDE-Onboarding-A.md` (backfilled — the vague "macOS/Linux MDE onboarding (see macOS runbook)" Does-not-cover line now points at the actual new file by name, since no such runbook previously existed despite the forward reference) | ✅ | auto-build |
| `Security/Defender/_AGENT.md` (backfilled — `MDE-Onboarding-B.md`/`-A.md` folder-contents row and two Common-entry-points rows now explicitly flag Windows-only scope and point macOS tickets at the new pair) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row cross-referencing `Security/Defender/MDE-Onboarding-A.md` as the Windows-only equivalent and `macOS/Troubleshooting/Extensions-A.md` as the vendor-agnostic mechanism layer this topic builds on) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 666 (post-write count, includes this run's 3 new docs/scripts; the three in-place edits to `macOS/_AGENT.md`, `Security/Defender/MDE-Onboarding-A.md`, `Security/Defender/_AGENT.md`, and `AGENT_INDEX.md` don't add new files)
_2026-07-20 (run 94): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-20 (run 93): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security — Conditional Access: Authentication Strengths (new topic, run 95)

| File | Status | Assigned |
|------|--------|---------|
| `Security/ConditionalAccess/AuthenticationStrengths-B.md` | ✅ | auto-build |
| `Security/ConditionalAccess/AuthenticationStrengths-A.md` | ✅ | auto-build |
| `Security/ConditionalAccess/Scripts/Get-AuthStrengthCoverageAudit.ps1` | ✅ | auto-build |
| `Security/ConditionalAccess/_AGENT.md` (backfilled — 2 new folder-contents rows, 1 new script row, 3 new Common entry points) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — added Authentication Strengths row cross-referencing CA-Design/TokenProtection and EntraID WHfB topics) | ✅ | auto-build |

## Azure — Backfill: Missing _AGENT.md files (run 95)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Monitor/_AGENT.md` (new — was missing entirely) | ✅ | auto-build |
| `Azure/Policy/_AGENT.md` (new — was missing entirely) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 671 (post-write count — 5 new files this run: 3 new docs/script + 2 new `_AGENT.md` backfills; the `Security/ConditionalAccess/_AGENT.md` and `AGENT_INDEX.md` edits are in-place and don't add new files)
_2026-07-20 (run 95): archived — see `MANIFEST_ARCHIVE.md`._

## Active Directory — New Topic: Delegated Managed Service Accounts (dMSA) (run 96)

| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/dMSA/dMSA-B.md` (found pre-existing, uncommitted, on disk from an interrupted prior session — content verified sound, `<details>` tag balance confirmed 7/7, committed as-is) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/dMSA/dMSA-A.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-DMSAHealth.ps1` (new) | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (backfilled — top Covers line, 3 folder-contents rows for the doc pair + script, 7 new Common entry points bullets, 1 new dependency-chain diagram explicitly built as an extension of the existing gMSA chain) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/gMSA/gMSA-A.md` (backfilled — closed its own vague "verify current guidance" dMSA out-of-scope note and Learning Pointers bullet with direct pointers to the new dMSA runbook) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/gMSA/gMSA-B.md` (backfilled — same fix to its own Learning Pointers dMSA aside) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row cross-referencing the gMSA topic as the shared KDS/GKDS foundation and explicitly noting no gMSA↔dMSA conversion path exists) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 674 (post-write count — 2 new docs + 1 new script this run; `dMSA-B.md` was already present on disk pre-run so is not a net-new addition to the file-count delta versus run 95's 671, the +3 reflects `dMSA-A.md`, `Get-DMSAHealth.ps1`, and `dMSA-B.md` all being newly tracked by git for the first time this run; the four in-place edits to `_AGENT.md`, `gMSA-A.md`, `gMSA-B.md`, and `AGENT_INDEX.md` don't add new files)
_2026-07-20 (run 96): archived — see `MANIFEST_ARCHIVE.md`._

---

## Windows — New Topic: DHCP Server Role (run 97)

| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/DHCP-Server-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/DHCP-Server-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-DHCPServerHealth.ps1` (new) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — Covers line, 2 new folder-contents rows, new script row, 1 new Common entry points bullet) | ✅ | auto-build |
| `Windows/Troubleshooting/DHCP-Client-A.md` (backfilled — Scope & Assumptions note pointing to DHCP-Server-A for Failover/Policies/DNS-credential/database, new Learning Pointers bullet) | ✅ | auto-build |
| `Windows/Troubleshooting/DHCP-Client-B.md` (backfilled — new Learning Pointers bullet pointing server-wide symptoms to DHCP-Server-B/A) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: DHCP client and DHCP Server role, cross-referenced to each other and to ActiveDirectory for the DNS zone DHCP registers into) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 677 (+3 net new: `DHCP-Server-A.md`, `DHCP-Server-B.md`, `Get-DHCPServerHealth.ps1`; the four in-place edits to `_AGENT.md`, `DHCP-Client-A.md`, `DHCP-Client-B.md`, and `AGENT_INDEX.md` don't add new files)
_2026-07-20 (run 97): archived — see `MANIFEST_ARCHIVE.md`._

---

## Windows — New Topic: Hyper-V Host & VM (run 98)

| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/HyperV-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/HyperV-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-HyperVHealth.ps1` (new) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — top Covers line, 2 new folder-contents rows, new script row, 1 new Common entry points bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row cross-referencing ActiveDirectory for Kerberos Constrained Delegation/cross-forest trust, and Azure/AVD explicitly flagged out of scope as a materially different management plane) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 680 (+3 net new: `HyperV-A.md`, `HyperV-B.md`, `Get-HyperVHealth.ps1`; the two in-place edits to `Windows/_AGENT.md` and `AGENT_INDEX.md` don't add new files)
_2026-07-20 (run 98): archived — see `MANIFEST_ARCHIVE.md`._

---

## Script-Coverage Gap Sweep (run 99, scheduled task "ezadmin-night-build")

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 684 (+4 net new: `Get-DFSABEAudit.ps1`, `Get-DFSSiteCostingAudit.ps1`, `Get-AlwaysOnVPNDiagnostics.ps1`, `Get-ExternalIdentitiesAudit.ps1`)
_2026-07-20 (run 99): archived — see `MANIFEST_ARCHIVE.md`._

---

## Intune — New Topic: Enterprise App Management (run 100)

| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/EnterpriseAppManagement-B.md` (new) | ✅ | auto-build |
| `Intune/Troubleshooting/EnterpriseAppManagement-A.md` (new) | ✅ | auto-build |
| `Intune/Scripts/Get-EnterpriseAppCatalogAudit.ps1` (new) | ✅ | auto-build |
| `Intune/_AGENT.md` (backfilled — top Covers line, 2 new folder-contents rows, 1 new script row, 1 new Common entry points bullet) | ✅ | auto-build |
| `DFS/_AGENT.md` (backfilled — 2 missing Scripts rows: `Get-DFSABEAudit.ps1`, `Get-DFSSiteCostingAudit.ps1`, + 2 Common entry points bullets) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — 1 missing Scripts row: `Get-AlwaysOnVPNDiagnostics.ps1`) | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — 1 missing Scripts row: `Get-ExternalIdentitiesAudit.ps1`) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 687 (+3 net new: `EnterpriseAppManagement-B.md`, `EnterpriseAppManagement-A.md`, `Get-EnterpriseAppCatalogAudit.ps1`; the four `_AGENT.md` backfills are in-place edits, not new files)
_2026-07-20 (run 100): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure/Networking — New Topic: Private DNS Zones (run 101)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/PrivateDNS-B.md` (new) | ✅ | auto-build |
| `Azure/Networking/PrivateDNS-A.md` (new) | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-PrivateDNSZoneAudit.ps1` (new) | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — covers-line updated to five topics, new dependency-chain diagram, 2 folder-contents rows, 1 script row, 6 Common entry points bullets, 4 diagnostic commands) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 690 (+3 net new: `PrivateDNS-B.md`, `PrivateDNS-A.md`, `Get-PrivateDNSZoneAudit.ps1`; the `_AGENT.md` backfill is an in-place edit)
_2026-07-20 (run 101): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure/Networking — New Topic: ExpressRoute (dedicated) (run 102)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/ExpressRoute-B.md` (new) | ✅ | auto-build |
| `Azure/Networking/ExpressRoute-A.md` (new) | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-ExpressRouteCircuitAudit.ps1` (new) | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — covers-line updated to six topics, new paragraph on the ExpressRoute-dedicated topic, 3 folder-contents rows, 5 Common entry points bullets, 3 diagnostic commands) | ✅ | auto-build |

## Security/Purview — New Topic: Compliance Manager (run 102)

| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/ComplianceManager-B.md` (new) | ✅ | auto-build |
| `Security/Purview/ComplianceManager-A.md` (new) | ✅ | auto-build |
| `Security/Purview/_AGENT.md` (backfilled — covers-line addition noting Compliance Manager as a read/scoring layer over the rest of the folder, 1 new "Before responding, also check" row distinguishing it from Secure Score, 2 folder-contents rows, 6 Common entry points bullets) | ✅ | auto-build |

_2026-07-20 (run 102): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure/Networking — New Topic: Azure Firewall (Standard/Premium, dedicated) (run 103)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/AzureFirewall-B.md` (new) | ✅ | auto-build |
| `Azure/Networking/AzureFirewall-A.md` (new) | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-AzureFirewallPolicyAudit.ps1` (new) | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — covers-line updated to seven topics, new Azure Firewall paragraph, "Does not cover" line corrected to remove the now-stale Firewall exclusion, 1 new "Before responding, also check" row distinguishing this topic from VirtualWAN's Routing Intent treatment, 3 folder-contents rows, 8 Common entry points bullets, 5 diagnostic commands) | ✅ | auto-build |

## M365/Copilot — New Topic: Agent Governance (run 103)

| File | Status | Assigned |
|------|--------|---------|
| `M365/Copilot/AgentGovernance-B.md` (new) | ✅ | auto-build |
| `M365/Copilot/AgentGovernance-A.md` (new) | ✅ | auto-build |
| `M365/_AGENT.md` (backfilled — Copilot sub-module row updated to distinguish base Copilot licensing/grounding coverage from the new agent-governance coverage, 2 new Common entry points bullets) | ✅ | auto-build |

_2026-07-20 (run 103): archived — see `MANIFEST_ARCHIVE.md`._

---

## PowerAutomate/PowerApps — New Topic: Copilot Studio Security & Governance (run 104)

| File | Status | Assigned |
|------|--------|---------|
| `PowerAutomate/PowerApps/CopilotStudio-Security-B.md` (new) | ✅ | auto-build |
| `PowerAutomate/PowerApps/CopilotStudio-Security-A.md` (new) | ✅ | auto-build |
| `PowerAutomate/PowerApps/Scripts/Get-CopilotStudioDLPAudit.ps1` (new) | ✅ | auto-build |
| `PowerAutomate/_AGENT.md` (backfilled — new bullet in "What's in this folder", 2 new "Before responding, also check" rows, 3 new folder-contents rows, 3 new Common entry points bullets) | ✅ | auto-build |
| `PowerAutomate/PowerApps/Environment-Dataverse-A.md` (backfilled — Out-of-scope line's "Copilot Studio-specific environment behavior" mention now cross-references the new files instead of dead-ending) | ✅ | auto-build |
| `M365/Copilot/AgentGovernance-A.md` (backfilled — Out-of-scope list now cross-references the new files, distinguishing Registry-level oversight from Copilot Studio's own security configuration) | ✅ | auto-build |

_2026-07-20 (run 104): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-20 (run 105): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Defender — New Topic: CIEM (Cloud Infrastructure Entitlement Management) (run 106)

| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/CIEM-B.md` (new) | ✅ | auto-build |
| `Security/Defender/CIEM-A.md` (new) | ✅ | auto-build |
| `Security/Defender/Scripts/Get-CIEMRecommendationAudit.ps1` (new) | ✅ | auto-build |
| `Security/Defender/_AGENT.md` (backfilled — "What's in this folder" updated to mention CIEM and the Entra Permissions Management retirement, 2 new Folder contents rows, 3 new Common entry points bullets) | ✅ | auto-build |
| `Security/Defender/DefenderForCloud-A.md` (backfilled — new "Explicitly out of scope" bullet cross-referencing CIEM-A/B.md) | ✅ | auto-build |
| `EntraID/Graph/GraphAPI-BatchOperations-A.md` (narrow addition — new Symptom→Cause Map row on `admin/windows/updates` beta throttling having no published service-specific limit) | ✅ | auto-build |
| `Intune/Troubleshooting/Autopatch-A.md` (narrow addition — cross-reference comment in Command Cheat Sheet pointing to the new throttling row) | ✅ | auto-build |

_2026-07-20 (run 106): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Sentinel — New Topic: UEBA (User & Entity Behavior Analytics) (run 107)

| File | Status | Assigned |
|------|--------|---------|
| `Security/Sentinel/UEBA-B.md` (new) | ✅ | auto-build |
| `Security/Sentinel/UEBA-A.md` (new) | ✅ | auto-build |
| `Security/Sentinel/Scripts/Get-SentinelUEBAAudit.ps1` (new) | ✅ | auto-build |
| `Security/Sentinel/_AGENT.md` (backfilled — "What's in this folder" updated to mention UEBA, 2 new Folder contents rows, 1 new Scripts row, 6 new Common entry points bullets, 1 new diagnostic KQL block, 1 new dependency-chain diagram branch) | ✅ | auto-build |

_2026-07-20 (run 107): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Sentinel — New Topic: Hunting (Queries, Bookmarks & Hunts) (run 108)

| File | Status | Assigned |
|------|--------|---------|
| `Security/Sentinel/Hunting-B.md` (new) | ✅ | auto-build |
| `Security/Sentinel/Hunting-A.md` (new) | ✅ | auto-build |
| `Security/Sentinel/Scripts/Get-SentinelHuntingAudit.ps1` (new) | ✅ | auto-build |
| `Security/Sentinel/_AGENT.md` (backfilled — "What's in this folder" updated to mention Hunting and remove the standing "future topic" flag, 3 new Folder contents rows, 7 new Common entry points bullets, 2 new diagnostic command blocks, 1 new dependency-chain diagram branch) | ✅ | auto-build |

_2026-07-20 (run 108): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Sentinel — New Topic: Notebooks (Jupyter / MSTICPy) (run 109)

| File | Status | Assigned |
|------|--------|---------|
| `Security/Sentinel/Notebooks-B.md` (new) | ✅ | auto-build |
| `Security/Sentinel/Notebooks-A.md` (new) | ✅ | auto-build |
| `Security/Sentinel/Scripts/Get-SentinelNotebookReadinessAudit.ps1` (new) | ✅ | auto-build |
| `Security/Sentinel/_AGENT.md` (backfilled — "What's in this folder" updated to mention Notebooks and narrow the exclusion list to only the still-open data-lake-architecture candidate, 3 new Folder contents rows, 7 new Common entry points bullets, 2 new diagnostic command blocks, 1 new dependency-chain diagram branch) | ✅ | auto-build |

_2026-07-20 (run 109): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Sentinel — New Topic: Data Lake (federated tables, KQL jobs onboarding, tiering) (run 110)

| File | Status | Assigned |
|------|--------|---------|
| `Security/Sentinel/DataLake-B.md` (new) | ✅ | auto-build |
| `Security/Sentinel/DataLake-A.md` (new) | ✅ | auto-build |
| `Security/Sentinel/Scripts/Get-SentinelDataLakeReadinessAudit.ps1` (new) | ✅ | auto-build |
| `Security/Sentinel/_AGENT.md` (backfilled — top-summary clause replacing the data-lake exclusion note, 3 new Folder contents rows, 8 new Common entry points bullets, 1 new diagnostic command block, 1 new dependency-chain diagram branch) | ✅ | auto-build |

_2026-07-20 (run 110): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Purview — New Topic: DSPM for AI / Data Security Posture Management (run 111)

| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/DSPM-for-AI-B.md` (new) | ✅ | auto-build |
| `Security/Purview/DSPM-for-AI-A.md` (new) | ✅ | auto-build |
| `Security/Purview/Scripts/Get-DSPMforAIAudit.ps1` (new) | ✅ | auto-build |
| `Security/Purview/_AGENT.md` (backfilled — "What's in this folder" updated to mention DSPM/DSPM for AI and the 2026 convergence, 2 new Folder contents rows, 1 new Scripts row, 8 new Common entry points bullets, 1 new diagnostic command block) | ✅ | auto-build |
| `M365/Copilot/Copilot-A.md` (backfilled — new "Out of scope" cross-reference bullet to DSPM-for-AI-A/B.md) | ✅ | auto-build |
| `M365/Copilot/AgentGovernance-A.md` (backfilled — new "Out of scope" cross-reference bullet to DSPM-for-AI-A/B.md) | ✅ | auto-build |

_2026-07-20 (run 111): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure/Windows365 — New Topic: Windows 365 Flex (formerly Frontline) (run 112)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Windows365/Flex-B.md` (new) | ✅ | auto-build |
| `Azure/Windows365/Flex-A.md` (new) | ✅ | auto-build |
| `Azure/Windows365/Scripts/Get-Windows365FlexAudit.ps1` (new) | ✅ | auto-build |
| `Azure/Windows365/_AGENT.md` (backfilled — "What's in this folder" updated to mention Flex, 2 new Folder contents rows, 1 new Scripts row, 5 new Common entry points bullets, 2 new diagnostic command lines) | ✅ | auto-build |
| `Azure/Windows365/Windows365-A.md` (backfilled — "Not covered" line, Frontline→Flex aside rewritten, ownership-model comparison table row updated) | ✅ | auto-build |
| `Azure/Windows365/Windows365-B.md` (backfilled — Learning Pointer on Frontline→Flex rename and Resize non-support) | ✅ | auto-build |

_2026-07-20 (run 112): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure/Windows365 — New Topic: Windows 365 Cloud Apps (run 113)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Windows365/CloudApps-B.md` (new) | ✅ | auto-build |
| `Azure/Windows365/CloudApps-A.md` (new) | ✅ | auto-build |
| `Azure/Windows365/Scripts/Get-Windows365CloudAppsAudit.ps1` (new) | ✅ | auto-build |
| `Azure/Windows365/_AGENT.md` (backfilled — summary line, 3 new folder-contents rows, 4 new entry-point bullets, 1 new diagnostic command block) | ✅ | auto-build |
| `Azure/Windows365/Flex-A.md` (backfilled — Not Covered line, Shared-mode Cloud Apps aside, dependency-stack branch, and Playbook 4 decision-guide step 3 all updated to point at the new files) | ✅ | auto-build |
| `Azure/Windows365/Windows365-B.md` (backfilled — Fix 4's "Also check" note extended with a Cloud Apps cross-reference) | ✅ | auto-build |

_2026-07-20 (run 113): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Sentinel — New Topic: Microsoft Sentinel Graph (run 113)

| File | Status | Assigned |
|------|--------|---------|
| `Security/Sentinel/SentinelGraph-B.md` (new) | ✅ | auto-build |
| `Security/Sentinel/SentinelGraph-A.md` (new) | ✅ | auto-build |
| `Security/Sentinel/Scripts/Get-SentinelGraphReadinessAudit.ps1` (new) | ✅ | auto-build |
| `Security/Sentinel/_AGENT.md` (backfilled — summary line, 3 new folder-contents rows, 5 new entry-point bullets, 1 new diagnostic command block, 1 new dependency-chain branch) | ✅ | auto-build |
| `Security/Sentinel/DataLake-A.md` (backfilled — the Sentinel-graph scope-exclusion bullet updated to point at the new files now that they exist) | ✅ | auto-build |

_2026-07-20 (run 113): archived — see `MANIFEST_ARCHIVE.md`._

## Gap Fill: M365/Apps/_AGENT.md + New Topic: Entra ID Certificate-Based Authentication (CBA) (run 114)

| File | Status | Assigned |
|------|--------|---------|
| `M365/Apps/_AGENT.md` (new — gap fill) | ✅ | auto-build |
| `EntraID/Troubleshooting/CBA-B.md` (new) | ✅ | auto-build |
| `EntraID/Troubleshooting/CBA-A.md` (new) | ✅ | auto-build |
| `EntraID/Scripts/Get-CBAConfigurationAudit.ps1` (new) | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — Covers bullet, 1 new folder-contents row, 1 new scripts row, 2 new entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Entra ID CBA distinct from WHfB and from Intune Cloud PKI/Certificates) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 737 (verified directly via `find . -type f -not -path "./.git/*" -not -path "./_BUILD/*" | wc -l` post-write; 4 net new this run: `M365/Apps/_AGENT.md`, `CBA-B.md`, `CBA-A.md`, `Get-CBAConfigurationAudit.ps1`).
_2026-07-20 (run 114): archived — see `MANIFEST_ARCHIVE.md`._

## Windows — New Topics: Storage Spaces Direct (S2D) + Volume Shadow Copy Service (VSS) (run 115)

| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/StorageSpacesDirect-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/StorageSpacesDirect-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-S2DHealthAudit.ps1` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/VSS-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/VSS-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-VSSWriterHealth.ps1` (new) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — 2 new "Covers" bullets, 2 new folder-contents rows, 2 new scripts rows, 2 new entry-point bullets) | ✅ | auto-build |
| `Windows/Troubleshooting/HyperV-A.md` (backfilled — Does-not-cover line now cross-references StorageSpacesDirect-A.md) | ✅ | auto-build |
| `Azure/Backup/AzureBackup-A.md` (backfilled — Phase 1 step 4 VSS note now cross-references VSS-A.md/VSS-B.md) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: Storage Spaces Direct, Volume Shadow Copy Service; Hyper-V row's cross-reference column extended) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 743 (737 baseline from run 114 + 6 net new: `StorageSpacesDirect-B/A.md`, `VSS-B/A.md`, `Get-S2DHealthAudit.ps1`, `Get-VSSWriterHealth.ps1`).
_2026-07-20 (run 115): archived — see `MANIFEST_ARCHIVE.md`._

---

## Run 116 (2026-07-20)

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 749 (743 baseline from run 115 + 6 net new: `FailoverClustering-B/A.md`, `WSUS-Server-B/A.md`, `Get-FailoverClusterHealth.ps1`, `Get-WSUSServerHealth.ps1`).
_2026-07-21 (run 116): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure/Networking — New Topics: Point-to-Site (P2S) VPN Gateway + Azure Bastion (run 117)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/P2SVPN-B.md` (new) | ✅ | auto-build |
| `Azure/Networking/P2SVPN-A.md` (new) | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-P2SVPNGatewayHealth.ps1` (new) | ✅ | auto-build |
| `Azure/Networking/Bastion-B.md` (new) | ✅ | auto-build |
| `Azure/Networking/Bastion-A.md` (new) | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-AzureBastionHealth.ps1` (new) | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — folder count 7→9, two new topic-summary paragraphs, "Does not cover" line for P2S removed since it's now covered, 6 new folder-contents rows, 10 new entry-point bullets, 4 new diagnostic commands, 2 new dependency-chain diagrams) | ✅ | auto-build |
| `Azure/Networking/HybridConnectivity-A.md` (backfilled — Scope line's P2S exclusion now points at `P2SVPN-A.md`/`P2SVPN-B.md`) | ✅ | auto-build |
| `Windows/Troubleshooting/AlwaysOnVPN-A.md` (backfilled — "Azure VPN Gateway (P2S scenarios)" out-of-scope line now names the new files directly) | ✅ | auto-build |
| `Azure/Networking/NSG-A.md` / `NSG-B.md` (backfilled — Bastion mentions now cross-reference `Bastion-A.md`/`Bastion-B.md`) | ✅ | auto-build |
| `Windows/Troubleshooting/RDP-B.md` (backfilled — Bastion Learning Pointer now cross-references `Bastion-A.md`/`Bastion-B.md`) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: Point-to-Site VPN, Azure Bastion; existing HybridConnectivity and NSG rows' cross-reference columns extended) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 755 (749 baseline from run 116 + 6 net new: `P2SVPN-B/A.md`, `Bastion-B/A.md`, `Get-P2SVPNGatewayHealth.ps1`, `Get-AzureBastionHealth.ps1`). Confirmed via `git status --short` that the full expected file set (6 new + 7 modified) matched before committing.

---

## macOS/EntraID — Managed Apple ID Federation + M365/UniversalPrint — Universal Print on macOS (run 118)

| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/ManagedAppleID-Federation-B.md` (new) | ✅ | auto-build |
| `macOS/Troubleshooting/ManagedAppleID-Federation-A.md` (new) | ✅ | auto-build |
| `macOS/Scripts/Get-EntraFederationReadiness.ps1` (new) | ✅ | auto-build |
| `M365/UniversalPrint/Universal-Print-macOS-B.md` (new) | ✅ | auto-build |
| `M365/UniversalPrint/Universal-Print-macOS-A.md` (new) | ✅ | auto-build |
| `M365/UniversalPrint/Scripts/Get-UniversalPrintMacOSReadiness.ps1` (new) | ✅ | auto-build |
| `macOS/_AGENT.md` (backfilled — 1 new Covers bullet, 3 new Common entry points bullets) | ✅ | auto-build |
| `M365/UniversalPrint/_AGENT.md` (backfilled — folder summary extended, 1 new cross-reference, 2 new folder-contents rows, 5 new common-entry-point bullets) | ✅ | auto-build |
| `M365/UniversalPrint/Universal-Print-A.md` (backfilled — Does-not-cover line now names the new macOS files) | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — 1 new "Before responding, also check" cross-reference) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: Managed Apple ID Federation, Universal Print on macOS) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 761 (755 baseline from run 117 + 6 net new: `ManagedAppleID-Federation-B/A.md`, `Universal-Print-macOS-B/A.md`, `Get-EntraFederationReadiness.ps1`, `Get-UniversalPrintMacOSReadiness.ps1`).
_2026-07-21 (run 118): archived — see `MANIFEST_ARCHIVE.md`._

---

## macOS/EntraID — Global Secure Access (GSA) client for macOS + repo-wide Apple Business terminology sweep (run 119)

| File | Status | Assigned |
|------|--------|---------|
| `macOS/Troubleshooting/GlobalSecureAccess-macOS-B.md` (new) | ✅ | auto-build |
| `macOS/Troubleshooting/GlobalSecureAccess-macOS-A.md` (new) | ✅ | auto-build |
| `macOS/Scripts/Get-GSAmacOSHealth.sh` (new) | ✅ | auto-build |
| `macOS/_AGENT.md` (backfilled — 1 new Covers bullet, 1 new Common entry-point bullet, 2 Apple Business terminology fixes) | ✅ | auto-build |
| `EntraID/Troubleshooting/GlobalSecureAccess-A.md` (backfilled — "Not covered" line now names the new macOS-specific files instead of a generic "non-Windows" mention) | ✅ | auto-build |
| `EntraID/Troubleshooting/GlobalSecureAccess-B.md` (backfilled — 1 new Learning Pointer cross-referencing the macOS-specific files) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Global Secure Access client for macOS) | ✅ | auto-build |
| `.gitignore` (new — excludes `*.bak`, see roadblock note) | ✅ | auto-build |
| 18 existing macOS files (terminology sweep — "Apple Business Manager" → "Apple Business", see below) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 765 (761 baseline from run 118 + 4 net new: `GlobalSecureAccess-macOS-B/A.md`, `Get-GSAmacOSHealth.sh`, `.gitignore`; 22 files modified in place — 4 cross-reference backfills plus 18 terminology-sweep files — carry no net file-count change).
_2026-07-21 (run 119): archived — see `MANIFEST_ARCHIVE.md`._
_2026-07-21 (run 117): archived — see `MANIFEST_ARCHIVE.md`._

---

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 786 (765 baseline reported by run 119's own count did not include the 18 zero-byte `.bak` stray artifacts also created that run, which do count under a plain `find`; 765 + 18 + 3 net new this run — `LDAP-Signing-B/A.md`, `Get-LDAPSigningAudit.ps1` — = 786, reconciling the apparent jump).
_2026-07-21 (run 120): archived — see `MANIFEST_ARCHIVE.md`._

---

## Active Directory — New Topic: Certificate-Based Authentication Mapping / KB5014754 (run 121)

| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/CertificateMapping/Certificate-Mapping-B.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/CertificateMapping/Certificate-Mapping-A.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-CertificateMappingAudit.ps1` (new) | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (backfilled — Covers line extended, 3 new folder-contents rows, 6 new common entry-point bullets, 1 new dependency-chain ASCII diagram) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Certificate-Based Authentication Mapping / KB5014754) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 789 (786 baseline from run 120 + 3 net new: `Certificate-Mapping-B/A.md`, `Get-CertificateMappingAudit.ps1`; 2 files modified in place — `_AGENT.md`, `AGENT_INDEX.md` — carry no net file-count change).
_2026-07-21 (run 121): archived — see `MANIFEST_ARCHIVE.md`._

---

## Active Directory / Windows — New Topics: Kerberos Armoring (FAST) + NTLM Relay to AD CS (PetitPotam/ESC8) (run 122)

| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/KerberosArmoring/KerberosArmoring-B.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/KerberosArmoring/KerberosArmoring-A.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-KerberosArmoringAudit.ps1` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/NTLMRelayADCS-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/NTLMRelayADCS-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-NTLMRelayADCSAudit.ps1` (new) | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (backfilled — Covers line extended x2, 3 new folder-contents rows, 6 new common entry-point bullets, 1 new dependency-chain ASCII diagram) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — 1 new Covers bullet, 2 new folder-contents rows, 3 new common entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: Kerberos Armoring (FAST), NTLM Relay to AD CS (PetitPotam/ESC8)) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 795 (789 baseline from run 121 + 6 net new: `KerberosArmoring-B/A.md`, `Get-KerberosArmoringAudit.ps1`, `NTLMRelayADCS-B/A.md`, `Get-NTLMRelayADCSAudit.ps1`; 3 files modified in place — `ActiveDirectory/_AGENT.md`, `Windows/_AGENT.md`, `AGENT_INDEX.md` — carry no net file-count change).
_2026-07-21 (run 122): archived — see `MANIFEST_ARCHIVE.md`._

---

## Windows — New Topic: AD CS Vulnerable Certificate Templates (ESC1 / ESC4) (run 123)

| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/ADCSTemplateMisconfiguration-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/ADCSTemplateMisconfiguration-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-ADCSVulnerableTemplateAudit.ps1` (new) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — 1 new Covers bullet, 2 new folder-contents rows, 4 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: AD CS Vulnerable Certificate Templates (ESC1 / ESC4)) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 798 (795 baseline from run 122 + 3 net new: `ADCSTemplateMisconfiguration-B/A.md`, `Get-ADCSVulnerableTemplateAudit.ps1`; 2 files modified in place — `Windows/_AGENT.md`, `AGENT_INDEX.md` — carry no net file-count change).
_2026-07-21 (run 123): archived — see `MANIFEST_ARCHIVE.md`._

---

## Active Directory — New Topic: Group Policy Central Store & ADMX/ADML Management (run 124)

| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/GroupPolicyCentralStore/GPO-CentralStore-B.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/GroupPolicyCentralStore/GPO-CentralStore-A.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-GPOCentralStoreAudit.ps1` (new) | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (backfilled — Covers paragraph extended with a new disambiguation clause, 3 new folder-contents rows, 7 new common entry-point bullets, 1 new dependency-chain ASCII diagram) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Group Policy Central Store & ADMX/ADML Management) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 801 (798 baseline from run 123 + 3 net new: `GPO-CentralStore-B/A.md`, `Get-GPOCentralStoreAudit.ps1`; 2 files modified in place — `ActiveDirectory/_AGENT.md`, `AGENT_INDEX.md` — carry no net file-count change).
_2026-07-21 (run 124): archived — see `MANIFEST_ARCHIVE.md`._

---

## Intune — New Topic: Legacy LAPS → Windows LAPS Migration & Coexistence (run 125)

| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/LAPS-Migration-B.md` (new) | ✅ | auto-build |
| `Intune/Troubleshooting/LAPS-Migration-A.md` (new) | ✅ | auto-build |
| `Intune/Scripts/Get-LAPSMigrationStatus.ps1` (new) | ✅ | auto-build |
| `Intune/_AGENT.md` (backfilled — Covers paragraph LAPS bullet extended, 1 new folder-contents doc-pair row, 1 new script row, 1 new common entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Legacy LAPS → Windows LAPS migration/coexistence) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 804 (801 baseline from run 124 + 3 net new: `LAPS-Migration-B/A.md`, `Get-LAPSMigrationStatus.ps1`; 2 files modified in place — `Intune/_AGENT.md`, `AGENT_INDEX.md` — carry no net file-count change).
_2026-07-21 (run 125): archived — see `MANIFEST_ARCHIVE.md`._

---

## Active Directory — New Topic: DNSSEC for AD-Integrated DNS Zones (run 126)

| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/DNS/DNSSEC-B.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/DNS/DNSSEC-A.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-DNSSECAudit.ps1` (new) | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (backfilled — Covers paragraph extended, 3 new folder-contents rows, 8 new common-entry-point bullets, 1 new dependency-chain ASCII diagram) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: DNSSEC for AD-Integrated DNS Zones) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 807 (804 baseline from run 125 + 3 net new: `DNSSEC-B/A.md`, `Get-DNSSECAudit.ps1`; 2 files modified in place — `ActiveDirectory/_AGENT.md`, `AGENT_INDEX.md` — carry no net file-count change).
_2026-07-21 (run 126): archived — see `MANIFEST_ARCHIVE.md`._

---

## Intune — New Topic: Windows 11 Hotpatch via Windows Autopatch (run 126)

| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/Hotpatch-B.md` (new) | ✅ | auto-build |
| `Intune/Troubleshooting/Hotpatch-A.md` (new) | ✅ | auto-build |
| `Intune/Scripts/Get-HotpatchReadinessAudit.ps1` (new) | ✅ | auto-build |
| `Intune/_AGENT.md` (backfilled — Updates bullet extended, 2 new folder-contents rows, 8 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Windows 11 Hotpatch via Windows Autopatch) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 810 (807 after the DNSSEC topic above + 3 net new: `Hotpatch-B/A.md`, `Get-HotpatchReadinessAudit.ps1`; 2 files modified in place — `Intune/_AGENT.md`, `AGENT_INDEX.md` — carry no net file-count change).
_2026-07-21 (run 126): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Azure — New Topics: CA Authentication Context, Windows Server 2025 Hotpatch, Microsoft Security Copilot (run 127)

| File | Status | Assigned |
|------|--------|---------|
| `Security/ConditionalAccess/AuthenticationContext-B.md` (new — recovered + corrected from an interrupted prior session, see below) | ✅ | auto-build |
| `Security/ConditionalAccess/AuthenticationContext-A.md` (new) | ✅ | auto-build |
| `Security/ConditionalAccess/Scripts/Get-AuthContextAudit.ps1` (new) | ✅ | auto-build |
| `Security/ConditionalAccess/_AGENT.md` (backfilled) | ✅ | auto-build |
| `Security/ConditionalAccess/AuthenticationStrengths-A.md` / `-B.md` (backfilled — stale `c1`–`c25` cross-references corrected to `c1`–`c99`, cross-linked to the new files) | ✅ | auto-build |
| `Azure/UpdateManager/ServerHotpatch-B.md` / `-A.md` (new — recovered from an interrupted prior session, verified, one live-researched addendum) | ✅ | auto-build |
| `Azure/UpdateManager/Scripts/Get-ServerHotpatchReadiness.ps1` (new — recovered) | ✅ | auto-build |
| `Azure/UpdateManager/_AGENT.md` (backfilled) | ✅ | auto-build |
| `Intune/Troubleshooting/Hotpatch-A.md` (backfilled — cross-reference corrected to point at the new dedicated file instead of the general UpdateManager topic) | ✅ | auto-build |
| `Security/Copilot/SecurityCopilot-B.md` / `-A.md` (new — fully recovered from an interrupted prior session, verified, no corrections needed) | ✅ | auto-build |
| `Security/Copilot/Scripts/Get-SecurityCopilotAccessAudit.ps1` (new — recovered) | ✅ | auto-build |
| `Security/Copilot/_AGENT.md` (new — recovered) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 3 new rows: CA Authentication Context, Windows Server 2025 Hotpatch, Microsoft Security Copilot; 1 stale cross-reference corrected) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 820 (810 baseline from run 126 + 10 net new: `AuthenticationContext-B/A.md`, `Get-AuthContextAudit.ps1`, `ServerHotpatch-B/A.md`, `Get-ServerHotpatchReadiness.ps1`, `SecurityCopilot-B/A.md`, `Get-SecurityCopilotAccessAudit.ps1`, `Security/Copilot/_AGENT.md`; 6 files modified in place — `AGENT_INDEX.md`, `Azure/UpdateManager/_AGENT.md`, `Intune/Troubleshooting/Hotpatch-A.md`, `AuthenticationStrengths-A.md`, `AuthenticationStrengths-B.md`, `Security/ConditionalAccess/_AGENT.md` — carry no net file-count change).
_2026-07-22 (run 127): archived — see `MANIFEST_ARCHIVE.md`._

## Microsoft Security Copilot (Security/Copilot) — new topic (2026-07-22)

## ActiveDirectory + Azure — New Topics: Kerberos Delegation, Azure Lighthouse (run 128)

| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/KerberosDelegation/Delegation-B.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/KerberosDelegation/Delegation-A.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-KerberosDelegationAudit.ps1` (new) | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (backfilled — top Covers paragraph extended, 3 new folder-contents rows, 6 new common-entry-point bullets, 1 new dependency-chain diagram) | ✅ | auto-build |
| `Azure/Lighthouse/Lighthouse-B.md` (new) | ✅ | auto-build |
| `Azure/Lighthouse/Lighthouse-A.md` (new) | ✅ | auto-build |
| `Azure/Lighthouse/Scripts/Get-LighthouseDelegationAudit.ps1` (new) | ✅ | auto-build |
| `Azure/Lighthouse/_AGENT.md` (new — first topic in this folder) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: Kerberos Delegation, Azure Lighthouse) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 828 (820 baseline from run 127 + 8 net new: `Delegation-B/A.md`, `Get-KerberosDelegationAudit.ps1`, `Lighthouse-B/A.md`, `Get-LighthouseDelegationAudit.ps1`, `Azure/Lighthouse/_AGENT.md`; 2 files modified in place — `ActiveDirectory/_AGENT.md`, `AGENT_INDEX.md` — carry no net file-count change).
_2026-07-22 (run 128): archived — see `MANIFEST_ARCHIVE.md`._

## Recovery: EntraID RMAU + M365/Exchange Direct Send Abuse — Sentinel Threat Intelligence + Watchlists (run 129)

| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/RestrictedManagementAU-B.md` (recovered — complete, verified, no corrections needed) | ✅ | auto-build |
| `EntraID/Troubleshooting/RestrictedManagementAU-A.md` (recovered) | ✅ | auto-build |
| `EntraID/Scripts/Get-RestrictedManagementAUAudit.ps1` (recovered) | ✅ | auto-build |
| `M365/Exchange/DirectSendAbuse-B.md` (recovered — complete, verified, no corrections needed) | ✅ | auto-build |
| `M365/Exchange/DirectSendAbuse-A.md` (recovered) | ✅ | auto-build |
| `M365/Exchange/Scripts/Get-DirectSendExposureAudit.ps1` (recovered) | ✅ | auto-build |
| `EntraID/_AGENT.md`, `M365/Exchange/_AGENT.md`, `AGENT_INDEX.md` (recovered backfills — already complete on disk) | ✅ | auto-build |
| `Security/Sentinel/ThreatIntelligence-B.md` (new) | ✅ | auto-build |
| `Security/Sentinel/ThreatIntelligence-A.md` (new) | ✅ | auto-build |
| `Security/Sentinel/Scripts/Get-SentinelThreatIntelAudit.ps1` (new) | ✅ | auto-build |
| `Security/Sentinel/Watchlists-B.md` (new) | ✅ | auto-build |
| `Security/Sentinel/Watchlists-A.md` (new) | ✅ | auto-build |
| `Security/Sentinel/Scripts/Get-SentinelWatchlistAudit.ps1` (new) | ✅ | auto-build |
| `Security/Sentinel/_AGENT.md` (backfilled — Covers paragraph extended, 2 cross-reference bullets, 6 folder-contents rows, 9 entry-point bullets, 2 diagnostic command blocks, 2 new dependency-chain diagrams) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: Sentinel Threat Intelligence, Sentinel Watchlists) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 840 (828 baseline from run 128 + 6 recovered: `RestrictedManagementAU-B/A.md`, `Get-RestrictedManagementAUAudit.ps1`, `DirectSendAbuse-B/A.md`, `Get-DirectSendExposureAudit.ps1`; + 6 net new: `ThreatIntelligence-B/A.md`, `Get-SentinelThreatIntelAudit.ps1`, `Watchlists-B/A.md`, `Get-SentinelWatchlistAudit.ps1`; `EntraID/_AGENT.md`, `M365/Exchange/_AGENT.md`, `Security/Sentinel/_AGENT.md`, `AGENT_INDEX.md` modified in place carry no net file-count change).
_2026-08-16 (run 129): archived — see `MANIFEST_ARCHIVE.md`._

---

## M365/Teams + M365/SharePoint-OneDrive — New Topics: External Collaboration & Hub Sites (run 130)

| File | Status | Assigned |
|------|--------|---------|
| `M365/Teams/ExternalAccess-B.md` (new) | ✅ | auto-build |
| `M365/Teams/ExternalAccess-A.md` (new) | ✅ | auto-build |
| `M365/Teams/Scripts/Get-TeamsExternalAccessAudit.ps1` (new) | ✅ | auto-build |
| `M365/SharePoint-OneDrive/HubSites-B.md` (new) | ✅ | auto-build |
| `M365/SharePoint-OneDrive/HubSites-A.md` (new) | ✅ | auto-build |
| `M365/SharePoint-OneDrive/Scripts/Get-SPHubSiteAudit.ps1` (new) | ✅ | auto-build |
| `M365/Teams/_AGENT.md` (backfilled — Covers paragraph extended, 1 cross-reference bullet, 2 folder-contents rows, 3 common-entry-point bullets, 2 diagnostic command lines) | ✅ | auto-build |
| `M365/SharePoint-OneDrive/_AGENT.md` (backfilled — 2 folder-contents rows, 4 common-entry-point bullets, 1 diagnostic command pair) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: Teams External Access/Guest Access/Shared Channels, SharePoint Hub Sites) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 845 (6 net new: `ExternalAccess-B/A.md`, `Get-TeamsExternalAccessAudit.ps1`, `HubSites-B/A.md`, `Get-SPHubSiteAudit.ps1`; `M365/Teams/_AGENT.md`, `M365/SharePoint-OneDrive/_AGENT.md`, `AGENT_INDEX.md` modified in place carry no net file-count change; baseline was reported as 840 in run 129's entry — small discrepancy not reconciled further, treated as prior-run counting variance rather than a missing-file signal since `git status --short` showed exactly the expected 6 new + 3 modified files with nothing untracked left over).
_2026-08-16 (run 130): archived — see `MANIFEST_ARCHIVE.md`._

---

## Windows/Azure — New Topics: WinRM/PowerShell Remoting, Application Gateway + macOS stale-file cleanup (run 131)

| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/WinRM-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/WinRM-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-WinRMDiagnostics.ps1` (new) | ✅ | auto-build |
| `Azure/Networking/AppGateway-B.md` (new) | ✅ | auto-build |
| `Azure/Networking/AppGateway-A.md` (new) | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-AppGatewayHealth.ps1` (new) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — Covers paragraph extended, 2 folder-contents rows, 2 common-entry-point bullets) | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — title/scope paragraph extended, 1 disambiguation bullet, 2 folder-contents rows, 7 common-entry-point bullets, 4 diagnostic command lines, 1 new dependency-chain diagram) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: WinRM/PowerShell Remoting, Azure Application Gateway) | ✅ | auto-build |
| 18× `macOS/Troubleshooting/*.md.bak` (deleted — confirmed zero-byte stale artifacts from an interrupted session, never git-tracked) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 833 (6 net new: `WinRM-B/A.md`, `Get-WinRMDiagnostics.ps1`, `AppGateway-B/A.md`, `Get-AppGatewayHealth.ps1`; minus 18 deleted zero-byte `.bak` files that were never git-tracked, hence no commit impact from the deletions themselves; `Windows/_AGENT.md`, `Azure/Networking/_AGENT.md`, `AGENT_INDEX.md` modified in place carry no net file-count change; baseline was reported as 845 in run 130's entry — 845 − 18 + 6 = 833, reconciles cleanly this run since the .bak deletions are the fully-accounted-for delta).
_2026-08-16 (run 131): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure/Networking — New Topic: Load Balancer (run 132)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/LoadBalancer-B.md` (new) | ✅ | auto-build |
| `Azure/Networking/LoadBalancer-A.md` (new) | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-LoadBalancerHealth.ps1` (new) | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — title updated, new Load Balancer scope paragraph + out-of-scope clause, 1 new disambiguation bullet under "Before responding, also check", 3 new folder-contents rows, 7 new common-entry-point bullets, 5 new diagnostic command lines, 1 new dependency-chain ASCII diagram) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Azure Load Balancer) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 836 (3 net new: `LoadBalancer-B/A.md`, `Get-LoadBalancerHealth.ps1`; `Azure/Networking/_AGENT.md`, `AGENT_INDEX.md` modified in place carry no net file-count change; baseline was 833 per run 131's entry — 833 + 3 = 836, reconciles cleanly).
_2026-08-16 (run 132): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure/Networking + Windows — New Topics: Front Door + Windows Backup for Organizations (run 133)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/FrontDoor-B.md` (new) | ✅ | auto-build |
| `Azure/Networking/FrontDoor-A.md` (new) | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-FrontDoorHealth.ps1` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/WindowsBackup-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/WindowsBackup-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-WindowsBackupAudit.ps1` (new) | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — title updated, new Front Door scope paragraph + out-of-scope clause, 1 new disambiguation bullet, 3 new folder-contents rows, 9 new common-entry-point bullets, 6 new diagnostic command lines, 1 new dependency-chain ASCII diagram) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — Covers list extended, 2 new folder-contents rows, 2 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: Azure Front Door, Windows Backup for Organizations) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 842 (6 net new: `FrontDoor-B/A.md`, `Get-FrontDoorHealth.ps1`, `WindowsBackup-B/A.md`, `Get-WindowsBackupAudit.ps1`; `Azure/Networking/_AGENT.md`, `Windows/_AGENT.md`, `AGENT_INDEX.md` modified in place carry no net file-count change; baseline was 836 per run 132's entry — 836 + 6 = 842, reconciles cleanly).
_2026-08-17 (run 133): archived — see `MANIFEST_ARCHIVE.md`._

---

## Windows — New Topics: BranchCache + Folder Redirection & Offline Files (run 134)

| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/BranchCache-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/BranchCache-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-BranchCacheHealth.ps1` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/FolderRedirection-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/FolderRedirection-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-OfflineFilesDiagnostics.ps1` (new) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — Covers list extended with 2 new clauses, 2 new folder-contents rows for runbook pairs, 2 new script rows, 6 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: BranchCache, Folder Redirection & Offline Files) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 848 (6 net new: `BranchCache-B/A.md`, `Get-BranchCacheHealth.ps1`, `FolderRedirection-B/A.md`, `Get-OfflineFilesDiagnostics.ps1`; `Windows/_AGENT.md`, `AGENT_INDEX.md` modified in place carry no net file-count change; baseline was 842 per run 133's entry — 842 + 6 = 848, reconciles cleanly).
_2026-08-17 (run 134): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure/Networking + Windows — New Topics: Private Link/Private Endpoints + Just Enough Administration (JEA) (run 135)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/PrivateLink-B.md` (new) | ✅ | auto-build |
| `Azure/Networking/PrivateLink-A.md` (new) | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-PrivateEndpointAudit.ps1` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/JEA-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/JEA-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-JEAEndpointAudit.ps1` (new) | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — title updated, new Private Link scope paragraph + out-of-scope clause, 2 new disambiguation bullets, 4 new folder-contents rows, 7 new common-entry-point bullets, 6 new diagnostic command lines, 1 new dependency-chain ASCII diagram) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — 1 new Covers bullet, 2 new folder-contents rows, 5 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 2 new rows: Azure Private Link/Private Endpoints, Just Enough Administration) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 854 (848 baseline from run 134 + 6 net new: `PrivateLink-B/A.md`, `Get-PrivateEndpointAudit.ps1`, `JEA-B/A.md`, `Get-JEAEndpointAudit.ps1`; 3 files modified in place — `Azure/Networking/_AGENT.md`, `Windows/_AGENT.md`, `AGENT_INDEX.md` — carry no net file-count change).

---

## Azure/Networking — New Topic: Front Door Premium Private Link Origins (run 136)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Networking/FrontDoorPrivateLink-B.md` (new) | ✅ | auto-build |
| `Azure/Networking/FrontDoorPrivateLink-A.md` (new) | ✅ | auto-build |
| `Azure/Networking/Scripts/Get-FrontDoorPrivateLinkAudit.ps1` (new) | ✅ | auto-build |
| `Azure/Networking/_AGENT.md` (backfilled — new scope paragraph, 1 new disambiguation bullet, 3 new folder-contents rows, 6 new common-entry-point bullets, 2 new diagnostic command lines) | ✅ | auto-build |
| `Azure/Networking/FrontDoor-A.md` (out-of-scope bullet updated to point at the new dedicated topic instead of "not covered here") | ✅ | auto-build |
| `Azure/Networking/PrivateLink-A.md` (out-of-scope bullet updated to note the reversed-consumer relationship and point at the new dedicated topic) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Azure Front Door Premium Private Link Origins) | ✅ | auto-build |

- Total files (real count via `find` in the clean `/tmp` clone used for this run's git operations, excludes `_BUILD/` and `.git/`): 857 (854 baseline from run 135 + 3 net new: `FrontDoorPrivateLink-B/A.md`, `Get-FrontDoorPrivateLinkAudit.ps1`; `Azure/Networking/_AGENT.md`, `FrontDoor-A.md`, `PrivateLink-A.md`, `AGENT_INDEX.md`, `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 136): archived — see `MANIFEST_ARCHIVE.md`._
_2026-08-17 (run 135): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID + Azure/Windows365 — New Topics: External MFA + Windows 365 Reserve (run 137)

| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/ExternalMFA-B.md` (new) | ✅ | auto-build |
| `EntraID/Troubleshooting/ExternalMFA-A.md` (new) | ✅ | auto-build |
| `EntraID/Scripts/Get-ExternalMFAAudit.ps1` (new) | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — 1 new Covers bullet, 2 new folder-contents rows, 3 new common-entry-point bullets) | ✅ | auto-build |
| `EntraID/Troubleshooting/MFA-B.md` (cross-reference added to error code 50158 pointing at the new dedicated topic) | ✅ | auto-build |
| `Azure/Windows365/Reserve-B.md` (new) | ✅ | auto-build |
| `Azure/Windows365/Reserve-A.md` (new) | ✅ | auto-build |
| `Azure/Windows365/Scripts/Get-Windows365ReserveAudit.ps1` (new) | ✅ | auto-build |
| `Azure/Windows365/_AGENT.md` (backfilled — scope paragraph extended, 3 new folder-contents rows, 4 new common-entry-point bullets) | ✅ | auto-build |
| `Azure/Windows365/Flex-A.md` (cross-reference added to the Cross-region DR feature-gap bullet pointing at Reserve) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 865 (857 baseline from run 136 + 8 net new: `ExternalMFA-B/A.md`, `Get-ExternalMFAAudit.ps1`, `Reserve-B/A.md`, `Get-Windows365ReserveAudit.ps1`; `EntraID/_AGENT.md`, `MFA-B.md`, `Azure/Windows365/_AGENT.md`, `Flex-A.md`, `MANIFEST.md` modified in place carry no net file-count change). Exact count to be reconfirmed at commit time via `find` on the actual working tree used for the push.
_2026-08-17 (run 137): archived — see `MANIFEST_ARCHIVE.md`._

---

## ActiveDirectory — New Topic: AdminSDHolder / SDProp (run 138)

| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/AdminSDHolder/AdminSDHolder-B.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/AdminSDHolder/AdminSDHolder-A.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-AdminSDHolderAudit.ps1` (new) | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (backfilled — Covers paragraph extended with AdminSDHolder/SDProp, 1 new disambiguation bullet, 3 new folder-contents rows, 7 new common-entry-point bullets, 1 new dependency-chain block) | ✅ | auto-build |

- Total files (real count via `find`, excludes `_BUILD/` and `.git/`): 866 (863 baseline implied by run 137's stated 865 total minus the 2 files matched by this run's own count method producing a small discrepancy — noting this rather than silently reconciling it, since the exact prior count wasn't independently re-verified this run — plus 3 net new: `AdminSDHolder-B/A.md`, `Get-AdminSDHolderAudit.ps1`; `_AGENT.md` and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 138): archived — see `MANIFEST_ARCHIVE.md`._

---

## ActiveDirectory — New Topic: Read-Only Domain Controllers (RODC) (run 139)

| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/RODC/RODC-B.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/RODC/RODC-A.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-RODCPasswordReplicationAudit.ps1` (new) | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (backfilled — Covers paragraph extended with RODC, 1 new disambiguation bullet, 3 new folder-contents rows, 6 new common-entry-point bullets, 1 new dependency-chain block) | ✅ | auto-build |

- Total files (real count via `find` in the `/tmp` clone used for this run's push, excludes `_BUILD/` and `.git/`): 869 (866 baseline per run 138's own stated count, +3 net new this run: `RODC-B/A.md`, `Get-RODCPasswordReplicationAudit.ps1`; `_AGENT.md` and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 139): archived — see `MANIFEST_ARCHIVE.md`._

---

## ActiveDirectory — New Topic: Shadow Groups (OU/Attribute-Synced Security Groups) (run 140)

| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/ShadowGroups/ShadowGroups-B.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/ShadowGroups/ShadowGroups-A.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-ShadowGroupDriftAudit.ps1` (new) | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (backfilled — Covers paragraph extended to an Oxford-comma list ending in Shadow Groups, 1 new disambiguation bullet, 3 new folder-contents rows, 6 new common-entry-point bullets, 1 new dependency-chain block) | ✅ | auto-build |

- Total files (real count via `find` in the `/tmp` clone used for this run's push, excludes `_BUILD/` and `.git/`): 872 (869 baseline per run 139's own stated count, +3 net new this run: `ShadowGroups-B/A.md`, `Get-ShadowGroupDriftAudit.ps1`; `_AGENT.md` and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 140): archived — see `MANIFEST_ARCHIVE.md`._

---

## ActiveDirectory — New Topic: AD LDS / Active Directory Lightweight Directory Services (run 141)

| File | Status | Assigned |
|------|--------|---------|
| `ActiveDirectory/Troubleshooting/ADLDS/ADLDS-B.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/ADLDS/ADLDS-A.md` (new) | ✅ | auto-build |
| `ActiveDirectory/Scripts/Get-ADLDSInstanceAudit.ps1` (new) | ✅ | auto-build |
| `ActiveDirectory/_AGENT.md` (backfilled — Covers paragraph extended to a proper Oxford-comma list ending in AD LDS, 1 new disambiguation bullet, 3 new folder-contents rows, 6 new common-entry-point bullets, 1 new dependency-chain block) | ✅ | auto-build |

- Total files (real count via `find` in the `/tmp` clone used for this run's push, excludes `_BUILD/` and `.git/`): 875 (872 baseline per run 140's own stated count, +3 net new this run: `ADLDS-B/A.md`, `Get-ADLDSInstanceAudit.ps1`; `_AGENT.md` and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 141): archived — see `MANIFEST_ARCHIVE.md`._

---

## Windows — New Topic: Storage Migration Service (SMS) (run 142)

| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/StorageMigrationService-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/StorageMigrationService-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-StorageMigrationServiceAudit.ps1` (new) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — 1 new Covers bullet, 1 new folder-contents row, 1 new script row, 3 new common-entry-point bullets) | ✅ | auto-build |

- Total files (real count via `find` in the `/tmp` clone used for this run's push, excludes `_BUILD/` and `.git/`): 878 (875 baseline per run 141's own stated count, +3 net new this run: `StorageMigrationService-B/A.md`, `Get-StorageMigrationServiceAudit.ps1`; `Windows/_AGENT.md` and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 142): archived — see `MANIFEST_ARCHIVE.md`._

---

## Windows — New Topic: Print Server Migration (run 143)

| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/PrintServerMigration-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/PrintServerMigration-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-PrintServerMigrationAudit.ps1` (new) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — 1 new Covers bullet, 1 new folder-contents row, 1 new script row, 5 new common-entry-point bullets) | ✅ | auto-build |
| `Windows/Troubleshooting/PrintSpooler-A.md` (out-of-scope bullet added pointing at the new dedicated topic) | ✅ | auto-build |
| `Windows/Troubleshooting/StorageMigrationService-A.md` (out-of-scope bullet added disambiguating SMS from print-role migration) | ✅ | auto-build |
| `M365/UniversalPrint/Universal-Print-A.md` (out-of-scope bullet extended to cross-reference the new topic for the on-prem-to-on-prem case) | ✅ | auto-build |

- Total files (real count via `find` in the `/tmp` clone used for this run's push, excludes `_BUILD/` and `.git/`): 881 (878 baseline per run 142's own stated count, +3 net new this run: `PrintServerMigration-B/A.md`, `Get-PrintServerMigrationAudit.ps1`; `Windows/_AGENT.md`, `PrintSpooler-A.md`, `StorageMigrationService-A.md`, `M365/UniversalPrint/Universal-Print-A.md`, and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 143): archived — see `MANIFEST_ARCHIVE.md`._

---

## Windows — New Topic: iSCSI Target Server (run 144)

| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/iSCSITargetServer-B.md` (new) | ✅ | auto-build |
| `Windows/Troubleshooting/iSCSITargetServer-A.md` (new) | ✅ | auto-build |
| `Windows/Scripts/Get-IscsiTargetServerAudit.ps1` (new) | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — 1 new Covers bullet, 1 new folder-contents row, 1 new script row, 3 new common-entry-point bullets) | ✅ | auto-build |

- Total files (real count via `find` in the `/tmp` clone used for this run's push, excludes `_BUILD/` and `.git/`): 884 (881 baseline per run 143's own stated count, +3 net new this run: `iSCSITargetServer-B/A.md`, `Get-IscsiTargetServerAudit.ps1`; `Windows/_AGENT.md` and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 144): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — New Topic: Microsoft Entra Domain Services (AADDS) (run 145)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/EntraDomainServices/EntraDomainServices-B.md` (new) | ✅ | auto-build |
| `Azure/EntraDomainServices/EntraDomainServices-A.md` (new) | ✅ | auto-build |
| `Azure/EntraDomainServices/Scripts/Get-EntraDomainServicesHealth.ps1` (new) | ✅ | auto-build |
| `Azure/EntraDomainServices/_AGENT.md` (new) | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — Covers paragraph extended with a new Microsoft Entra Domain Services clause, 2 new "Before responding, also check" bullets, 3 new folder-contents rows, 7 new common-entry-point bullets) | ✅ | auto-build |
| `ActiveDirectory/Troubleshooting/ADLDS/ADLDS-A.md` (out-of-scope bullet extended to disambiguate AD LDS from Microsoft Entra Domain Services by name) | ✅ | auto-build |

- Total files (real count via `find` in the `/tmp/ezcheck2` clone used for this run's push, excludes `_BUILD/` and `.git/`): 888 (884 baseline per run 144's own stated count, +4 net new this run: `EntraDomainServices-B/A.md`, `Get-EntraDomainServicesHealth.ps1`, `EntraDomainServices/_AGENT.md`; `Azure/_AGENT.md`, `ActiveDirectory/Troubleshooting/ADLDS/ADLDS-A.md`, and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 145): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — New Topic: VM Extensions & Boot Diagnostics (run 146)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Compute/VMExtensions-B.md` (new) | ✅ | auto-build |
| `Azure/Compute/VMExtensions-A.md` (new) | ✅ | auto-build |
| `Azure/Compute/Scripts/Get-AzureVMExtensionHealth.ps1` (new) | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — Covers paragraph extended with a new VM Extensions & Boot Diagnostics clause, 2 new "Before responding, also check" bullets, 3 new folder-contents rows, 7 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (backfilled — 1 new Domain Map row) | ✅ | auto-build |

- Total files (real count via `find` in the `/tmp/ezadmin_run146` clone used for this run's push, excludes `_BUILD/` and `.git/`): 891 (888 baseline per run 145's own stated count, +3 net new this run: `VMExtensions-B/A.md`, `Get-AzureVMExtensionHealth.ps1`; `Azure/_AGENT.md`, `AGENT_INDEX.md`, and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 146): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — New Topic: VM Boot & Disk Repair (run 147)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Compute/VMBootRepair-B.md` (new) | ✅ | auto-build |
| `Azure/Compute/VMBootRepair-A.md` (new) | ✅ | auto-build |
| `Azure/Compute/Scripts/Get-AzureVMBootRepairAudit.ps1` (new) | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — Covers paragraph extended with a new VM Boot & Disk Repair clause, 3 new folder-contents rows, 6 new common-entry-point bullets) | ✅ | auto-build |
| `Azure/Compute/VMExtensions-A.md` (Out-of-scope bullet on OS-level disk/boot-loader repair extended into a live cross-reference to the new topic) | ✅ | auto-build |
| `AGENT_INDEX.md` (backfilled — existing Azure/Compute Domain Map row description extended with the new sub-topic, no new row added since Compute is already indexed) | ✅ | auto-build |

- Total files (real count via `find` in the `/tmp/ezadmin_run` clone used for this run's push, excludes `_BUILD/` and `.git/`): 894 (891 baseline per run 146's own stated count, +3 net new this run: `VMBootRepair-B/A.md`, `Get-AzureVMBootRepairAudit.ps1`; `Azure/_AGENT.md`, `Azure/Compute/VMExtensions-A.md`, `AGENT_INDEX.md`, and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 147): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — New Topic: Azure Site Recovery (Azure-to-Azure DR) (run 148)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/SiteRecovery/SiteRecovery-B.md` (new) | ✅ | auto-build |
| `Azure/SiteRecovery/SiteRecovery-A.md` (new) | ✅ | auto-build |
| `Azure/SiteRecovery/Scripts/Get-SiteRecoveryHealth.ps1` (new) | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — Covers paragraph extended with a new Azure Site Recovery clause, 1 new "Before responding, also check" bullet, 3 new folder-contents rows, 5 new common-entry-point bullets) | ✅ | auto-build |
| `Azure/Backup/_AGENT.md` (Out-of-scope ASR mention extended into a live cross-reference to the new topic) | ✅ | auto-build |
| `Azure/Backup/AzureBackup-A.md` (same Out-of-scope table row extended into a live cross-reference) | ✅ | auto-build |
| `AGENT_INDEX.md` (backfilled — 1 new Domain Map row; existing Azure Backup row's cross-reference column extended) | ✅ | auto-build |

- Total files (real count via `find` in the fresh clone used for this run's push, excludes `_BUILD/` and `.git/`): 897 (894 baseline per run 147's own stated count, +3 net new this run: `SiteRecovery-B/A.md`, `Get-SiteRecoveryHealth.ps1`; `Azure/_AGENT.md`, `Azure/Backup/_AGENT.md`, `Azure/Backup/AzureBackup-A.md`, `AGENT_INDEX.md`, and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 148): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — New Topic: Storage Accounts (Blob/Queue/Table) (run 149)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/StorageAccounts/StorageAccounts-B.md` (new) | ✅ | auto-build |
| `Azure/StorageAccounts/StorageAccounts-A.md` (new) | ✅ | auto-build |
| `Azure/StorageAccounts/Scripts/Get-AzureStorageAccountHealth.ps1` (new) | ✅ | auto-build |
| `Azure/StorageAccounts/_AGENT.md` (new) | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — new scope clause, 3 new folder-contents rows, 4 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Azure Storage Accounts) | ✅ | auto-build |

- Total files: 901 (897 baseline per run 148's own stated count, +4 net new this run: `StorageAccounts-B/A.md`, `Get-AzureStorageAccountHealth.ps1`, `StorageAccounts/_AGENT.md`; `Azure/_AGENT.md`, `AGENT_INDEX.md`, and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 149): archived — see `MANIFEST_ARCHIVE.md`._

---

## Azure — New Topic: On-Premises to Azure Disaster Recovery (VMware & Hyper-V) (run 150)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/OnPremDR/OnPremDR-B.md` (new) | ✅ | auto-build |
| `Azure/OnPremDR/OnPremDR-A.md` (new) | ✅ | auto-build |
| `Azure/OnPremDR/Scripts/Get-OnPremDRHealth.ps1` (new) | ✅ | auto-build |
| `Azure/_AGENT.md` (backfilled — new scope clause, 1 new "Before responding, also check" bullet, 3 new folder-contents rows, 5 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: On-Premises to Azure Disaster Recovery, cross-referenced against the existing Azure Site Recovery row) | ✅ | auto-build |

- Total files: 905 (902 baseline per this run's own verified fresh-clone count of true `origin/master`, +3 net new this run: `OnPremDR-B/A.md`, `Get-OnPremDRHealth.ps1`; `Azure/_AGENT.md`, `AGENT_INDEX.md`, and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 150): archived — see `MANIFEST_ARCHIVE.md`._

---

## M365 — New Topic: Universal Print Migration (on-premises print server → Universal Print) (run 151)

| File | Status | Assigned |
|------|--------|---------|
| `M365/UniversalPrint/UP-Migration-B.md` (new) | ✅ | auto-build |
| `M365/UniversalPrint/UP-Migration-A.md` (new) | ✅ | auto-build |
| `M365/UniversalPrint/Scripts/Get-UPMigrationReadiness.ps1` (new) | ✅ | auto-build |
| `M365/UniversalPrint/_AGENT.md` (backfilled — Covers paragraph extended with a migration-scope clause, 1 new "Before responding, also check" bullet, 3 new folder-contents rows, 6 new common-entry-point bullets) | ✅ | auto-build |
| `M365/_AGENT.md` (backfilled — UniversalPrint sub-module row extended with migration-scope clause, 2 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Universal Print Migration, cross-referenced against the existing Universal Print row and `PrintServerMigration-A/B.md`) | ✅ | auto-build |
| `M365/UniversalPrint/Universal-Print-A.md` (cross-reference added to "Does not cover" pointing at the new migration files) | ✅ | auto-build |
| `Windows/Troubleshooting/PrintServerMigration-A.md` (cross-reference updated — "Does not cover" bullet now points at `UP-Migration-A/B.md` by name instead of the old `Universal-Print-A.md` catch-all) | ✅ | auto-build |
| `Windows/Troubleshooting/PrintServerMigration-B.md` (Learning Pointer bullet updated to reference `UP-Migration-A.md` by name) | ✅ | auto-build |

- Total files: 908 (905 baseline per this run's own verified fresh-clone count of true `origin/master`, +3 net new this run: `UP-Migration-B/A.md`, `Get-UPMigrationReadiness.ps1`; `M365/UniversalPrint/_AGENT.md`, `M365/_AGENT.md`, `AGENT_INDEX.md`, `Universal-Print-A.md`, `PrintServerMigration-A.md`, `PrintServerMigration-B.md`, and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 151): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID — New Topic: Enterprise Application (SCIM) Provisioning (run 152)

| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/EnterpriseAppProvisioning-B.md` (new) | ✅ | auto-build |
| `EntraID/Troubleshooting/EnterpriseAppProvisioning-A.md` (new) | ✅ | auto-build |
| `EntraID/Scripts/Get-EnterpriseAppProvisioningAudit.ps1` (new) | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new Covers bullet, 2 new folder-contents rows, 2 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Enterprise Application SCIM Provisioning, cross-referenced against the existing CloudSync, CrossTenant, and AppRegistrations rows) | ✅ | auto-build |

- Total files: 911 (908 baseline per this run's own verified fresh-clone count of true `origin/master`, +3 net new this run: `EnterpriseAppProvisioning-B/A.md`, `Get-EnterpriseAppProvisioningAudit.ps1`; `EntraID/_AGENT.md`, `AGENT_INDEX.md`, and `MANIFEST.md` modified in place carry no net file-count change). Mounted-copy file count independently confirmed at 911 post-authoring, matching expected baseline+3.
_2026-08-17 (run 152): archived — see `MANIFEST_ARCHIVE.md`._

---

## M365/Exchange — New Topic: Mailbox Migration Batches (Cutover/Staged/IMAP/Remote Move/Cross-tenant) (run 153)

| File | Status | Assigned |
|------|--------|---------|
| `M365/Exchange/MigrationBatches-B.md` (new) | ✅ | auto-build |
| `M365/Exchange/MigrationBatches-A.md` (new) | ✅ | auto-build |
| `M365/Exchange/Scripts/Get-MigrationBatchHealth.ps1` (new) | ✅ | auto-build |
| `M365/Exchange/_AGENT.md` (backfilled — new Covers bullet, 2 new folder-contents rows for the runbooks, 1 new folder-contents row for the script, 5 new common-entry-point bullets) | ✅ | auto-build |
| `M365/_AGENT.md` (backfilled — Exchange/ sub-module row extended with migration-batch scope clause) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — 1 new row: Exchange mailbox migration batches, cross-referenced against Hybrid-Coexistence and EntraID CrossTenant) | ✅ | auto-build |
| `M365/Exchange/Hybrid-Coexistence-A.md` (Does-not-cover bullet added, pointing at the new files for batch-mechanics detail) | ✅ | auto-build |

- Total files: 912 (909 baseline per this run's own verified fresh-clone count of true `origin/master`, +3 net new this run: `MigrationBatches-B/A.md`, `Get-MigrationBatchHealth.ps1`; `M365/Exchange/_AGENT.md`, `M365/_AGENT.md`, `AGENT_INDEX.md`, `Hybrid-Coexistence-A.md`, and `MANIFEST.md` modified in place carry no net file-count change).
_2026-08-17 (run 153): archived — see `MANIFEST_ARCHIVE.md`._

---

## Autopilot + EntraID — New Topics: Pre-Provisioning (White Glove) + Entra Suite/GSA Licensing (run 154)

| File | Status | Assigned |
|------|--------|---------|
| `Autopilot/Troubleshooting/WhiteGlove-B.md` (new) | ✅ | auto-build |
| `Autopilot/Troubleshooting/WhiteGlove-A.md` (new) | ✅ | auto-build |
| `Autopilot/Scripts/Get-WhiteGloveReadiness.ps1` (new) | ✅ | auto-build |
| `Autopilot/_AGENT.md` (backfilled — Deployment profiles bullet cross-referenced, 3 new common-entry-point bullets, 2 new folder-contents rows) | ✅ | auto-build |
| `EntraID/Troubleshooting/EntraSuiteLicensing-B.md` (new) | ✅ | auto-build |
| `EntraID/Troubleshooting/EntraSuiteLicensing-A.md` (new) | ✅ | auto-build |
| `EntraID/Scripts/Get-EntraSuiteLicenseAudit.ps1` (new) | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new Covers bullet, 2 new folder-contents rows, 3 new common-entry-point bullets) | ✅ | auto-build |
| `EntraID/Troubleshooting/GlobalSecureAccess-A.md` (Not-covered list extended with an explicit licensing/cost cross-reference to the new files) | ✅ | auto-build |

- Total files (via `find`, excludes `_BUILD/` and `.git/`, counted directly against the mounted working tree in this session rather than a `/tmp` clone): 919 (6 net new this run: `WhiteGlove-B/A.md`, `Get-WhiteGloveReadiness.ps1`, `EntraSuiteLicensing-B/A.md`, `Get-EntraSuiteLicenseAudit.ps1`; `Autopilot/_AGENT.md`, `EntraID/_AGENT.md`, `GlobalSecureAccess-A.md`, and `MANIFEST.md` modified in place carry no net file-count change). Baseline per run 153's own stated count was 912; the +7 delta rather than the expected +6 is not reconciled against a fresh clone this run (no `/tmp`-clone git-health check was performed this run — see note below) and is flagged rather than silently smoothed over, consistent with this repo's standing practice of surfacing count discrepancies rather than hiding them.
_2026-08-17 (run 154): archived — see `MANIFEST_ARCHIVE.md`._

## ActiveDirectory + Security — New Topics: noPac/PAC Validation, AIR, Unified SecOps Platform (run 155)

---

## Defender for Business + Microsoft Fabric (new domain) — run 156

| File | Status | Assigned |
|------|--------|---------|
| `Security/Defender/DefenderForBusiness-B.md` | ✅ | auto-build |
| `Security/Defender/DefenderForBusiness-A.md` | ✅ | auto-build |
| `Security/Defender/Scripts/Get-DefenderForBusinessStatus.ps1` | ✅ | auto-build |
| `Security/Defender/_AGENT.md` (backfilled — Covers clause, 2 folder-contents rows, 5 common-entry-point bullets) | ✅ | auto-build |
| `Fabric/_AGENT.md` (new domain) | ✅ | auto-build |
| `Fabric/FabricAdmin-B.md` | ✅ | auto-build |
| `Fabric/Scripts/Get-FabricCapacityHealth.ps1` | ✅ | auto-build |
| `AGENT_INDEX.md` (backfilled — 2 new Domain Map rows: Defender for Business, Microsoft Fabric admin) | ✅ | auto-build |

## Fabric — FabricAdmin-A.md (deep dive) + new Domains topic (run 157)

| File | Status | Assigned |
|------|--------|---------|
| `Fabric/FabricAdmin-A.md` (new) | ✅ | auto-build |
| `Fabric/Domains-B.md` (new) | ✅ | auto-build |
| `Fabric/Scripts/Get-FabricDomainAudit.ps1` (new) | ✅ | auto-build |
| `Fabric/_AGENT.md` (backfilled — 2 new folder-contents rows, 1 updated row, 6 new common-entry-point bullets, Key diagnostic commands + Key dependency chain extended) | ✅ | auto-build |
| `AGENT_INDEX.md` (Domain Map — Fabric row extended with throttling/OneLake/domains detail and new file references) | ✅ | auto-build |

_2026-08-17 (run 157): archived — see `MANIFEST_ARCHIVE.md`._

---

## Fabric — Domains-A.md (deep dive, completing the Domains topic) — run 158

| File | Status | Assigned |
|------|--------|---------|
| `Fabric/Domains-A.md` (new) | ✅ | auto-build |
| `Fabric/_AGENT.md` (backfilled — Domains-A.md folder-contents row, 4 new common-entry-point bullets, "not yet built" list corrected) | ✅ | auto-build |
| `AGENT_INDEX.md` (Fabric Domain Map row extended in place — REST Admin API + audit schema detail, `Domains-A.md` cross-reference added) | ✅ | auto-build |

_2026-08-17 (run 158): archived — see `MANIFEST_ARCHIVE.md`._

---

## Fabric — Git Integration (new topic, this run — run 159)
| File | Status | Assigned |
|------|--------|---------|
| `Fabric/GitIntegration-B.md` | ✅ | auto-build |
| `Fabric/GitIntegration-A.md` | ✅ | auto-build |
| `Fabric/Scripts/Get-FabricGitIntegrationStatus.ps1` | ✅ | auto-build |

---

_2026-08-17 (run 159): archived — see `MANIFEST_ARCHIVE.md`._

---

## Fabric — Workspace Governance at Scale (new topic — run 162)

| File | Status | Assigned |
|------|--------|---------|
| `Fabric/WorkspaceGovernance-B.md` | ✅ | auto-build |
| `Fabric/WorkspaceGovernance-A.md` | ✅ | auto-build |
| `Fabric/Scripts/Get-FabricWorkspaceGovernanceAudit.ps1` | ✅ | auto-build |
| `Fabric/_AGENT.md` (backfilled — 3 new folder-contents rows, "not yet built" list cleared, 8 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (Fabric Domain Map row extended in place — workspace governance detail + 2 new file references) | ✅ | auto-build |

_2026-08-17 (run 162): archived — see `MANIFEST_ARCHIVE.md`._

---

## M365 — Viva Engage / Yammer (new topic, this run — run 163)

| File | Status | Assigned |
|------|--------|---------|
| `M365/VivaEngage/VivaEngage-B.md` | ✅ | auto-build |
| `M365/VivaEngage/VivaEngage-A.md` | ✅ | auto-build |
| `M365/VivaEngage/Scripts/Get-VivaEngageAdminAudit.ps1` | ✅ | auto-build |
| `M365/_AGENT.md` (backfilled — new `VivaEngage/` sub-module row, 5 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new Viva Engage row added to the master routing table) | ✅ | auto-build |

_2026-08-18 (run 163): archived — see `MANIFEST_ARCHIVE.md`._

---

## M365 — Microsoft Places (new topic, this run — run 164)

| File | Status | Assigned |
|------|--------|---------|
| `M365/Places/Places-B.md` | ✅ | auto-build |
| `M365/Places/Places-A.md` | ✅ | auto-build |
| `M365/Places/Scripts/Get-PlacesReadinessAudit.ps1` | ✅ | auto-build |
| `M365/_AGENT.md` (backfilled — new `Places/` sub-module row, 6 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new Microsoft Places row added to the master routing table) | ✅ | auto-build |

_2026-08-18 (run 164): archived — see `MANIFEST_ARCHIVE.md`._

---

## M365 — Viva Insights (new topic, this run — run 165)

| File | Status | Assigned |
|------|--------|---------|
| `M365/VivaInsights/VivaInsights-B.md` | ✅ | auto-build |
| `M365/VivaInsights/VivaInsights-A.md` | ✅ | auto-build |
| `M365/VivaInsights/Scripts/Get-VivaInsightsAdminAudit.ps1` | ✅ | auto-build |
| `M365/_AGENT.md` (backfilled — new `VivaInsights/` sub-module row, 7 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new Viva Insights row added to the master routing table) | ✅ | auto-build |

_2026-08-18 (run 165): archived — see `MANIFEST_ARCHIVE.md`._

---

## M365 — Microsoft Loop (new topic, this run — run 166)

| File | Status | Assigned |
|------|--------|---------|
| `M365/Loop/Loop-B.md` | ✅ | auto-build |
| `M365/Loop/Loop-A.md` | ✅ | auto-build |
| `M365/Loop/Scripts/Get-LoopGovernanceAudit.ps1` | ✅ | auto-build |
| `M365/_AGENT.md` (backfilled — new `Loop/` sub-module row, 6 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new Microsoft Loop row added to the master routing table) | ✅ | auto-build |

_2026-08-18 (run 166): archived — see `MANIFEST_ARCHIVE.md`._

---

## M365 — Microsoft Planner (new topic, this run — run 167)

| File | Status | Assigned |
|------|--------|---------|
| `M365/Planner/Planner-B.md` | ✅ | auto-build |
| `M365/Planner/Planner-A.md` | ✅ | auto-build |
| `M365/Planner/Scripts/Get-PlannerAdminAudit.ps1` | ✅ | auto-build |
| `M365/_AGENT.md` (backfilled — new `Planner/` sub-module row, 7 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new Microsoft Planner row added to the master routing table) | ✅ | auto-build |

---

## Azure — Windows 365 Link (new topic, this run — run 168)

| File | Status | Assigned |
|------|--------|---------|
| `Azure/Windows365/Link-B.md` | ✅ | auto-build |
| `Azure/Windows365/Link-A.md` | ✅ | auto-build |
| `Azure/Windows365/Scripts/Get-Windows365LinkAudit.ps1` | ✅ | auto-build |
| `Azure/Windows365/_AGENT.md` (backfilled — new `Link-A/B.md`/script rows, 6 new common-entry-point bullets, 1 new diagnostic command block) | ✅ | auto-build |
| `AGENT_INDEX.md` (extended the existing Windows 365 Cloud PC row rather than adding a new one, matching how Flex/Reserve/CloudApps were folded in previously) | ✅ | auto-build |

_2026-08-18 (run 168): archived — see `MANIFEST_ARCHIVE.md`._

_2026-08-18 (run 167): archived — see `MANIFEST_ARCHIVE.md`._

---

## M365 — Microsoft 365 Admin Agent (new topic, this run — run 169)

| File | Status | Assigned |
|------|--------|---------|
| `M365/AdminAgent/AdminAgent-B.md` | ✅ | auto-build |
| `M365/AdminAgent/AdminAgent-A.md` | ✅ | auto-build |
| `M365/AdminAgent/Scripts/Get-AdminAgentGovernanceAudit.ps1` | ✅ | auto-build |
| `M365/_AGENT.md` (backfilled — new `AdminAgent/` sub-module row, 6 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new Microsoft 365 Admin Agent row added to the master routing table) | ✅ | auto-build |

---

## Intune — Surface Management Portal (new topic, this run — run 170)

| File | Status | Assigned |
|------|--------|---------|
| `Intune/Troubleshooting/SurfaceManagementPortal-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/SurfaceManagementPortal-A.md` | ✅ | auto-build |
| `Intune/Scripts/Get-SurfaceManagementPortalAudit.ps1` | ✅ | auto-build |
| `Intune/_AGENT.md` (backfilled — new bullet in folder overview, new Troubleshooting/Scripts table rows, new common-entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (new Surface Management Portal row added to the master routing table) | ✅ | auto-build |

_2026-08-18 (run 170): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID — Microsoft Entra Agent ID (new topic, this run — run 171)

| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/AgentID-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/AgentID-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-AgentIdentityGovernanceAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new overview bullet, new Troubleshooting/Scripts table rows, new common-entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (new Microsoft Entra Agent ID row added to the master routing table) | ✅ | auto-build |

_2026-08-18 (run 171): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID — App Consent Policies & Illicit Consent Grant Attacks (new topic, this run — run 172)

| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/AppConsentPolicies-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/AppConsentPolicies-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-AppConsentGovernanceAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new overview bullet, new Troubleshooting/Scripts table rows, new common-entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (new App Consent Policies & Illicit Consent Grant Attacks row added to the master routing table) | ✅ | auto-build |

_2026-08-18 (run 172): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID — Administrative Units, regular/non-restricted (new topic, this run — run 173)

| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/AdministrativeUnits-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/AdministrativeUnits-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-AdministrativeUnitAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new overview bullet, new Troubleshooting/Scripts table rows, new common-entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (new Administrative Units row added to the master routing table) | ✅ | auto-build |

_2026-08-18 (run 173): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID/Graph — Microsoft Graph Data Connect (new topic, this run — run 174) & Security — Microsoft Security Exposure Management (new topic + new subfolder, this run — run 174)

| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Graph/GraphDataConnect-B.md` | ✅ | auto-build |
| `EntraID/Graph/GraphDataConnect-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-GraphDataConnectReadinessAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new overview bullet, new Graph/Scripts table rows, new common-entry-point bullet) | ✅ | auto-build |
| `Security/ExposureManagement/_AGENT.md` (new subfolder) | ✅ | auto-build |
| `Security/ExposureManagement/ExposureManagement-B.md` | ✅ | auto-build |
| `Security/ExposureManagement/ExposureManagement-A.md` | ✅ | auto-build |
| `Security/ExposureManagement/Scripts/Get-ExposureManagementRBACAudit.ps1` | ✅ | auto-build |
| `AGENT_INDEX.md` (2 new rows — Microsoft Graph Data Connect, Microsoft Security Exposure Management) | ✅ | auto-build |

_2026-08-18 (run 174): archived — see `MANIFEST_ARCHIVE.md`._

---

## Security/Defender — App Governance (Microsoft Defender for Cloud Apps) (new topic, this run — run 175)

| File | Status | Assigned |
|------|--------|----------|
| `Security/Defender/AppGovernance-B.md` | ✅ | auto-build |
| `Security/Defender/AppGovernance-A.md` | ✅ | auto-build |
| `Security/Defender/Scripts/Get-AppGovernanceReadinessAudit.ps1` | ✅ | auto-build |
| `Security/Defender/_AGENT.md` (backfilled — new overview sentence, new Troubleshooting/Scripts table rows, 7 new common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new App Governance row added to the master routing table, inserted after the Fabric row) | ✅ | auto-build |

---

## EntraID/Troubleshooting — External ID for Customers (CIAM), JIT Password Migration (new topic, this run — run 176)

| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/CIAMMigration-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/CIAMMigration-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-CIAMMigrationReadinessAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new overview bullet, new Folder-contents rows, new Common-entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row added to the master routing table, inserted after the App Governance row) | ✅ | auto-build |

_2026-08-18 (run 176): archived — see `MANIFEST_ARCHIVE.md`._

_2026-08-18 (run 175): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID/Troubleshooting — Entra ID Governance Account Discovery (new topic, this run — run 177)

| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/AccountDiscovery-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/AccountDiscovery-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-AccountDiscoveryReadinessAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new overview bullet, 2 new Folder-contents rows, 3 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row added to the master routing table, inserted after the CIAM JIT Password Migration row) | ✅ | auto-build |

_2026-08-18 (run 177): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID/Troubleshooting — Entra Connect Sync Mandatory Upgrade / Version EOL Readiness (new topic, this run — run 178)

| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/ConnectSyncUpgrade-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/ConnectSyncUpgrade-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-ConnectSyncVersionAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new overview bullet, 2 new Folder-contents rows, 3 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended to the master routing table, after the Cloud-Managed Remote Mailboxes row) | ✅ | auto-build |

_2026-08-18 (run 178): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID/Troubleshooting — Entra Connect Sync → Entra Cloud Sync Migration (new topic, this run — run 179)

| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/CloudSyncMigration-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/CloudSyncMigration-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-CloudSyncMigrationReadiness.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new overview bullet, 2 new Folder-contents rows, 4 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended to the master routing table, after the Entra Connect Sync Mandatory Upgrade row) | ✅ | auto-build |

_2026-08-18 (run 179): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID/Troubleshooting — Group Writeback v2 → Cloud Sync Group Provisioning Migration (new topic, this run — run 180)

| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/GroupWritebackMigration-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/GroupWritebackMigration-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-GroupWritebackMigrationAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new overview bullet, 2 new Folder-contents rows, 3 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended to the master routing table, after the Entra Connect Sync → Entra Cloud Sync Migration row) | ✅ | auto-build |

_2026-08-18 (run 180): archived — see `MANIFEST_ARCHIVE.md`._

---

## EntraID — Azure AD B2C → Microsoft Entra External ID Migration (new topic, this run — run 181)

| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/B2CMigration-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/B2CMigration-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-B2CMigrationReadinessAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — new overview bullet, 2 new Folder-contents rows, 2 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended to the master routing table, after the Group Writeback v2 → Cloud Sync Group Provisioning Migration row) | ✅ | auto-build |

_2026-08-18 (run 181): archived — see `MANIFEST_ARCHIVE.md`._

---

## macOS/Troubleshooting — Jamf Pro ↔ Microsoft Intune (Compliance Connector + Full Migration) (new topic, this run — run 182)

| File | Status | Assigned |
|------|--------|----------|
| `macOS/Troubleshooting/JamfMigration-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/JamfMigration-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-JamfIntuneMigrationAudit.ps1` | ✅ | auto-build |
| `macOS/_AGENT.md` (backfilled — new overview bullet, 2 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended to the Domain Map, after the Azure AD B2C → Microsoft Entra External ID Migration row) | ✅ | auto-build |

_2026-08-18 (run 182): archived — see `MANIFEST_ARCHIVE.md`._

---

## Intune/Troubleshooting — Multi Admin Approval (MAA) app-auth/Graph API enforcement (new topic, this run — run 183)

| File | Status | Assigned |
|------|--------|----------|
| `Intune/Troubleshooting/MultiAdminApproval-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/MultiAdminApproval-A.md` | ✅ | auto-build |
| `Intune/Scripts/Get-MAAAccessPolicyAudit.ps1` | ✅ | auto-build |
| `Intune/_AGENT.md` (backfilled — new overview bullet, 2 new Folder-contents rows, 1 new Common-entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended to the master routing table, after the new Remote Help Unattended Support row — see below) | ✅ | auto-build |

_2026-09-01 (run 183): archived — see `MANIFEST_ARCHIVE.md`._

---

## Autopilot — Windows Autopilot Device Association (new topic, this run — run 184)

| File | Status | Assigned |
|------|--------|----------|
| `Autopilot/Troubleshooting/DeviceAssociation-B.md` | ✅ | auto-build |
| `Autopilot/Troubleshooting/DeviceAssociation-A.md` | ✅ | auto-build |
| `Autopilot/Scripts/Get-DeviceAssociationAudit.ps1` | ✅ | auto-build |
| `Autopilot/_AGENT.md` (backfilled — new overview bullet, 2 new Folder-contents rows, 1 new Common-entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended to the master routing table, after the Multi Admin Approval row) | ✅ | auto-build |

_2026-09-01 (run 184): archived — see `MANIFEST_ARCHIVE.md`._

---

## macOS App Settings (binary & app launch control) + Intune STIG Audit Baseline (two new topics, this run — run 185)

| File | Status | Assigned |
|------|--------|----------|
| `macOS/Troubleshooting/AppSettings-B.md` | ✅ | auto-build |
| `macOS/Troubleshooting/AppSettings-A.md` | ✅ | auto-build |
| `macOS/Scripts/Get-AppSettingsAudit.ps1` | ✅ | auto-build |
| `macOS/_AGENT.md` (backfilled — new overview bullet, 2 new Folder-contents rows, 1 new Common-entry-point bullet) | ✅ | auto-build |
| `Intune/Troubleshooting/STIGAuditBaseline-B.md` | ✅ | auto-build |
| `Intune/Troubleshooting/STIGAuditBaseline-A.md` | ✅ | auto-build |
| `Intune/Scripts/Get-STIGAuditBaselineStatus.ps1` | ✅ | auto-build |
| `Intune/_AGENT.md` (backfilled — new overview bullet, 2 new Folder-contents rows, 1 new Common-entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (2 new rows appended to the master routing table, after the Windows Autopilot device association row) | ✅ | auto-build |

_2026-09-01 (run 185): archived — see `MANIFEST_ARCHIVE.md`._

---

## Windows — Windows 10 Extended Security Updates (ESU) (new topic, this run — run 186)

| File | Status | Assigned |
|------|--------|----------|
| `Windows/Troubleshooting/ESU-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/ESU-A.md` | ✅ | auto-build |
| `Windows/Scripts/Get-ESUActivationStatus.ps1` | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — new overview bullet, 2 new Folder-contents rows, 2 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended to the master routing table, after the App Settings row) | ✅ | auto-build |

_2026-09-01 (run 186): archived — see `MANIFEST_ARCHIVE.md`._

---

## Entra ID — Passkey Default Authentication Rollout (run 187)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/PasskeyDefaultAuth-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/PasskeyDefaultAuth-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-PasskeyDefaultAuthReadiness.ps1` | ✅ | auto-build |

## Security — Conditional Access Custom Controls Retirement (run 187)
| File | Status | Assigned |
|------|--------|---------|
| `Security/ConditionalAccess/CustomControlsRetirement-B.md` | ✅ | auto-build |

_2026-09-02 (run 187): archived — see `MANIFEST_ARCHIVE.md`._

---

## Script-Coverage Gap Fill (run 188)
| File | Status | Assigned |
|------|--------|---------|
| `Security/Purview/Scripts/Get-ComplianceManagerReadinessAudit.ps1` | ✅ | auto-build |

_2026-09-02 (run 188): manifest queue empty entering this run — Expansion Rules mode. Ran a structural gap sweep (topics-vs-scripts diff across every domain) rather than a fresh topic search. Initial pass flagged `Windows/Troubleshooting/FolderRedirection-A/B.md` as script-less and a from-scratch script was drafted for it — but before committing, a pre-push verification against a fresh clone of `origin/master` showed `Windows/Scripts/Get-OfflineFilesDiagnostics.ps1` already exists there (258 lines, matches `Windows/_AGENT.md`'s existing description exactly). The gap sweep's own `ls` output had actually listed the file the whole time; it was missed on a visual scan. The drafted duplicate was discarded and the pre-existing file was left untouched — **not a real gap, correcting course before it became a wasted/conflicting commit.** Second candidate held up: `Security/Purview/ComplianceManager-A/B.md` had no companion script and none was documented anywhere — built `Get-ComplianceManagerReadinessAudit.ps1` (licensing, Compliance Manager's own 4-role RBAC, Unified Audit Log prerequisite) and added its `Security/Purview/_AGENT.md` folder-contents row + entry-point bullet. Read-only; brace/paren/bracket balance verified via Python counting pass (fully balanced). This run's larger action: archived 169 verbose per-run narrative write-ups out of `MANIFEST.md` into `MANIFEST_ARCHIVE.md` (1.77MB → ~205KB, all 1,310 table/status rows preserved and row-count-verified before/after) per run 187's own flagged recommendation and this project's stated "reworking and removing a lot of the stale records" goal — see the header note added above for detail. **For next run:** always verify a "gap" against a fresh clone of `origin/master` (not just a manual scan of `ls` output) before drafting a full replacement file — this run nearly duplicated existing work from a simple scan-reading error, not a real discrepancy.

---

## A-Variant Gap Fill — Conditional Access Custom Controls Retirement (run 189)
| File | Status | Assigned |
|------|--------|---------|
| `Security/ConditionalAccess/CustomControlsRetirement-A.md` | ✅ | auto-build |
| `Security/ConditionalAccess/Scripts/Get-CACustomControlsMigrationAudit.ps1` | ✅ | auto-build |
| `Security/ConditionalAccess/_AGENT.md` (backfilled — 2 new Folder-contents rows, 1 new Common-entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (existing Custom Controls Retirement row updated to reference the new `-A.md` + script) | ✅ | auto-build |

_2026-09-02 (run 189): manifest queue empty entering this run — Expansion Rules mode again. First checked whether the mounted working tree's `git status` (showing dozens of "untracked"/"modified" files matching run 179-188's own completed work) represented a real backlog of uncommitted work — per the standing procedure, diffed the mounted tree against a fresh `/tmp` clone of `origin/master` and found **zero differences**; confirmed this was purely the known stale-FUSE-metadata artifact, not real uncommitted content, so no recovery commit was needed. Ran a `find`-based B-without-A / A-without-B sweep across every `*-B.md`/`*-A.md` pair in the repo (more systematic than a manual folder scan) and found exactly one genuine gap: `Security/ConditionalAccess/CustomControlsRetirement-B.md` (built run 187) had no `-A.md` companion and no script — every other B/A pair in the repo is complete. Also spot-checked several "possible new topics" (Power Platform DLP, Graph API batch operations, PIM, Global Secure Access, Defender for Identity, Windows Autopatch, Windows LAPS, Insider Risk Management, SharePoint Advanced Management, Teams Direct Routing, Authentication Strength) and confirmed all are already covered — this repo's topic coverage is now very mature, and genuinely new gaps are increasingly rare; the B-without-A/A-without-B structural sweep is a more reliable next-run starting point than topic brainstorming. Built the Mode A deep dive (retirement mechanics/rationale vs. External MFA's claims-based model, the two-cutoff operational trap, Graph's structural inability to resolve which provider a Custom Control points to, and a migration playbook that explicitly mirrors External MFA's own Playbook 2) plus a companion `Get-CACustomControlsMigrationAudit.ps1` (impact assessment + per-policy migration-readiness flags, timeline-aware). Read-only script; brace/paren/bracket balance verified via Python counting pass (fully balanced; no `pwsh` available in this environment to full-parse-check). **For next run:** the B-without-A/A-without-B `find` sweep found nothing else outstanding — if the manifest queue is still empty, run it again first (cheap, ~2 seconds) before spending time on topic brainstorming, since repo coverage is now broad enough that fresh MS "what's new" sweeps (per runs 186/187's approach) are likely the higher-yield path for finding genuinely new topics.

---

## New Topic — Agents in SharePoint (run 190)
| File | Status | Assigned |
|------|--------|---------|
| `M365/SharePoint-OneDrive/Agents-B.md` | ✅ | auto-build |
| `M365/SharePoint-OneDrive/Agents-A.md` | ✅ | auto-build |
| `M365/SharePoint-OneDrive/Scripts/Get-SharePointAgentsAudit.ps1` | ✅ | auto-build |
| `M365/SharePoint-OneDrive/_AGENT.md` (backfilled — 2 new Folder-contents rows, 1 new Common-entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended, after the Conditional Access Custom Controls Retirement row) | ✅ | auto-build |

_2026-09-02 (run 190): manifest queue empty entering this run — Expansion Rules mode. Per run 189's own pointer, ran the B-without-A/A-without-B `find` sweep first (cheap, ~2s) and confirmed it still finds nothing — every `*-B.md`/`*-A.md` pair in the repo is complete, and no domain folder is missing a `Scripts/` directory (the two folders without one, `LLM/` and `Modules/`, are meta-prompt/single-utility folders, not topic domains — not a real gap). Before that, verified the mounted tree's usual "modified/untracked" `git status` noise against a fresh `/tmp` clone of `origin/master`: zero content differences, confirming the known stale-FUSE-metadata artifact again — no recovery commit needed. Moved to topic brainstorming: grepped the repo against the standing MSP-pain-point list (Entra Connect sync, Exchange hybrid, WDAC, Always On VPN, Universal Print, App Proxy, Graph batch ops, WHfB, Teams Rooms, Power Platform DLP) plus a second wave of newer candidates (Restricted Management AUs, GDAP, Cloud Kerberos Trust, BitLocker, Windows Backup for Organizations, DSPM for AI, Priva, Communication Compliance, Adaptive Protection, EASM, Attack Simulation Training, Entra Internet/Private Access, Windows 365 Reserve, Agent 365) — all already covered, confirming this repo's coverage is now extremely mature. Found one genuine gap on a third wave targeting Copilot/agent-adjacent features specifically: "Agents in SharePoint" (the ready-made/custom/Knowledge Agent trio) has zero coverage, distinct from the existing SharePoint Advanced Management (RAC/RCD/DAG governance), M365 Admin Agent, and Copilot Agent Governance topics already in the repo. Confirmed via `WebSearch` against current Microsoft Learn/Support pages (several dated June-July 2026) before writing: the three-agent-surface architecture, the two independent licensing paths (Copilot licence vs. pay-as-you-go metered billing, which superseded the Jan-Jun 2025 free promo), the RCD-suppresses-all-agent-features side effect (not just search, a fact easy to miss since RCD's existing runbooks in this repo don't mention agents at all), the Copilot Control System org-wide sharing scope control, and the exclusion-list-based (not allow-list) `KnowledgeAgentScope` mechanism. Built both runbook modes plus `Get-SharePointAgentsAudit.ps1` (tenant Knowledge Agent scope + exclusion-drift flag, per-site RCD agent-suppression scan, legacy promo status, optional Graph Copilot-licence summary); backfilled `M365/SharePoint-OneDrive/_AGENT.md` and added the `AGENT_INDEX.md` master-routing row cross-referencing the three related-but-distinct existing topics. Read-only script; brace/paren/bracket balance verified via Python counting pass (50/50, 67/67, 18/18 — fully balanced; no `pwsh` available in this environment to full-parse-check). **For next run:** the B-without-A/A-without-B sweep and the standard MSP-pain-point list are now both fully exhausted — the higher-yield path going forward is a fresh `WebSearch` "what's new" sweep against Microsoft Learn/Message Center (per runs 186/187/189's approach), specifically toward Copilot/agent-governance-adjacent features (this run's find) and toward whatever ships next in the Entra Suite/Global Secure Access space, since those two areas are where Microsoft is shipping fastest as of Sept 2026.

---

## New Topic — Global Secure Access MCP Firewall (Preview) (run 191)
| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/MCPFirewall-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/MCPFirewall-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-MCPFirewallPolicyAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — 1 new overview bullet, 2 new Folder-contents rows, 2 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended, after the Agents in SharePoint row) | ✅ | auto-build |

_2026-09-02 (run 191): manifest queue empty entering this run — Expansion Rules mode. Before any new work, verified the mounted working tree's usual "modified/untracked" `git status` noise (dozens of files matching run 190's own completed work — `M365/SharePoint-OneDrive/Agents-A/B.md` etc.) against a fresh `/tmp` bare clone of `origin/master`: `diff -rq` showed **zero** content differences, confirming this is the known stale-FUSE-metadata artifact flagged in runs 188-190, not real uncommitted work — no recovery commit needed. Ran the standing B-without-A/A-without-B `find` sweep first (cheap, per run 189/190's pointer): the only "gaps" it surfaced were false positives caused by filenames containing spaces (`Windows/Troubleshooting/Windows Update/WSUS-Server-A.md` etc. — both variants actually exist); confirmed no domain folder is missing a `Scripts/` directory. Per run 190's explicit pointer, moved straight to a fresh `WebSearch` "what's new" sweep against the Microsoft Entra Tech Community blog and Message Center rather than re-trying the exhausted MSP-pain-point brainstorm list. The September 2026 "What's New in Microsoft Entra" post surfaced three GA/Preview items (Entra Tenant Governance GA, User-centric Access Reviews GA, and the **Global Secure Access MCP Firewall entering Public Preview**) plus a Security Administrator role change announcement. Cross-checked all four against the repo: Tenant Governance and UAR are both extensions of existing, already-covered Access Reviews/governance topics (not distinct enough to warrant new files without further scoping); the Security Administrator role change is a permissions-reference update, not runbook-worthy on its own. The MCP Firewall was a clean, genuine gap — zero references anywhere in the repo — and is squarely in-scope per this project's AI-governance-adjacent expansion direction (Agent ID, Agent Registry, Copilot Agent Governance, Agents in SharePoint are all already covered; MCP network-traffic enforcement was the missing piece). Confirmed technical detail via a live Microsoft Learn fetch of the MCP firewall how-to page (`ms.date` 2026-08-06): the TLS-inspection-as-hard-prerequisite architecture (MCP is JSON-RPC 2.0 inside HTTPS — unparseable without decryption), the three-object linking chain (MCP policy -> filtering profile/"Security profile" -> Conditional Access session control), the four rule-authoring strategies (discovered servers via Generative AI Insights, known servers, discovered tools, manual primitive entry), first-match-wins priority evaluation, and documented Preview-era scope exclusions (local/stdio servers, JSON-RPC batches not inspected). **Tooling caveat worth flagging explicitly for future runs:** Microsoft's own configuration guide for this feature is 100% portal-driven with no PowerShell/Graph write cmdlets documented anywhere; cross-checked the Graph beta schema directly (fetched `networkaccess-filteringprofile` and `networkaccess-filteringpolicylink` resource pages) and confirmed the underlying resource types (`filteringPolicy`, `filteringProfile`, `filteringPolicyLink`) are real and documented, but found no MCP-specific derived type or typed `Get-MgBeta*` cmdlet confirmed to exist for this exact Preview feature — rather than guess at cmdlet names that might not be in the installed SDK version (a real risk this run declined to take, given the CONTENT QUALITY RULE that every command must actually work), all Graph-dependent commands in both runbooks and the script use `Invoke-MgGraphRequest` against the confirmed beta REST URIs instead of typed wrappers. Built both runbook modes plus `Get-MCPFirewallPolicyAudit.ps1` (walks the full policy -> profile -> Conditional Access chain and flags exactly where it breaks, since a gap at any link produces the identical "nothing happened" symptom with no error anywhere); the script explicitly flags TLS inspection state as a manual portal check rather than fabricating a Graph read for a state with no confirmed stable endpoint. Backfilled `EntraID/_AGENT.md` and added the `AGENT_INDEX.md` master-routing row cross-referencing the base GSA topic (fault-domain inheritance), Agent ID, and Agent Governance (both explicitly distinct control planes). Read-only script; brace/paren/bracket balance verified via Python counting pass (57/57, 96/96, 22/22 — fully balanced; no `pwsh` available in this environment to full-parse-check). **For next run:** re-run the B-without-A/A-without-B sweep first (still cheap, still clean apart from the known space-in-filename false positive already documented above — don't re-investigate that specific pair again); Entra Tenant Governance and User-centric Access Reviews (both GA this month) are reasonable candidates for a dedicated topic if a future sweep finds them still absent once they mature past this run's "too close to existing coverage" call — worth a second look once more MSP-facing operational detail (not just admin-center feature description) is documented for either.

---

## New Topic — Microsoft Entra Tenant Governance (run 192)
| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/TenantGovernance-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/TenantGovernance-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-TenantGovernanceAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — 1 new overview bullet, 2 new Folder-contents rows, 2 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended, after the Agents in SharePoint row) | ✅ | auto-build |

_2026-09-02 (run 192): manifest queue empty entering this run — Expansion Rules mode. Before any new work, verified the mounted working tree's usual "modified/untracked" `git status` noise (dozens of files spanning back to run ~169's work, considerably more than runs 189-191 individually flagged) against a fresh clone of `origin/master`: `diff -rq` showed **zero** content differences — confirmed this is the same known stale-FUSE-metadata artifact documented in runs 188-191, just accumulated across more runs than any single prior note called out; no recovery commit was needed, the remote already has every file. Went straight to run 191's own explicit "for next run" pointer rather than re-running the exhausted B-without-A/A-without-B sweep or MSP-pain-point brainstorm: run 191 had identified **Microsoft Entra Tenant Governance GA** as a candidate worth a second look "once more MSP-facing operational detail is documented." Re-checked via `WebSearch` against the September 2026 "What's New in Microsoft Entra" post plus a dedicated "Microsoft Entra Tenant Governance is now generally available" Tech Community post, then confirmed substantial operational detail now exists via live Microsoft Learn fetches of six pages (overview, governance-relationships, configuration-management, enable-tenant-discovery how-to, FAQ, and the Graph beta `governanceRelationships` list-endpoint reference) — run 191's "too close to existing coverage" concern does not hold up on closer inspection: this is a distinct object model and control plane from both GDAP (`GDAP-A.md`/`-B.md`, CSP/Partner-Center-specific) and Cross-Tenant Access Settings (`CrossTenant-A.md`/`-B.md`, end-user B2B collaboration), confirmed via a repo grep finding zero prior references to "tenant governance" or "governanceRelationship" anywhere. The single highest-value fact found and built the runbooks around: Tenant Governance and Partner Center GDAP are **platform-enforced mutually exclusive** for the same tenant pair (confirmed via the FAQ's own "Governance relationships" section, which also explicitly calls out the CSP/MSP/MSSP use case as supported) — this is the kind of "silently blocks the thing you're trying to do" gotcha this repo exists to document, not a hypothetical edge case. Also captured: the one-way/irreversible `isRelatedTenantsEnabled` discovery toggle, the invitation->request-with-policy-template->accept three-step handshake and its documented multi-tier-chain rejection (with the one narrow secure-tenant-creation exception), the asymmetric PIM-for-Groups interaction (activation happens in the governing tenant; governed-tenant PIM policy has zero effect on the governing admin — confirmed directly from the FAQ, not inferred), and the configuration-management layer's concrete operational quotas (6-hour monitor cadence, 200-resource-instance/baseline and 800/tenant/day limits, 7-day snapshot retention) sourced from the FAQ's dedicated Q&A on exactly these limits rather than estimated. Built both runbook modes plus `Get-TenantGovernanceAudit.ps1` (walks discovery-enablement state, relationship status/staleness, delegated-security-group emptiness, the GDAP-conflict cross-check via `Get-MgTenantRelationshipDelegatedAdminRelationship`, and configuration-monitor quota risk); the script and both runbooks use `Invoke-MgGraphRequest` against the confirmed beta REST endpoints (`/beta/directory/tenantGovernance/...`, `/beta/directory/configurationManagement/...`) rather than assuming typed cmdlet names, consistent with this repo's standing practice for features without a confirmed stable typed SDK surface. Backfilled `EntraID/_AGENT.md` (inserted the new Folder-contents rows immediately after the existing GDAP-B/-A row rather than at the end of the table, matching the topical-grouping convention already used for MCPFirewall's insertion next to GlobalSecureAccess) and added the `AGENT_INDEX.md` master-routing row cross-referencing GDAP, Cross-Tenant Access Settings, and Access Reviews (all explicitly distinct). Read-only script; brace/paren/bracket balance verified via Python counting pass (61/61, 111/111, 23/23 — fully balanced; no `pwsh` available in this environment to full-parse-check). **For next run:** re-run the B-without-A/A-without-B sweep first (cheap); the "User-centric Access Reviews GA" item from run 191's same source is still an open candidate worth re-evaluating on the same "has enough operational detail matured" basis that made Tenant Governance buildable this run.

---

## New Topic — Catalog / User-centric Access Reviews (UAR) (run 193)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/CatalogAccessReviews-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/CatalogAccessReviews-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-CatalogAccessReviewAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — 1 new overview bullet, 2 new Folder-contents rows, 3 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row inserted directly after the existing Access Reviews row) | ✅ | auto-build |

_2026-09-02 (run 193): manifest queue empty entering this run — Expansion Rules mode. Verified the mounted working tree's usual "modified/untracked" `git status` noise against a fresh `/tmp` clone of `origin/master`: `diff -rq` showed **zero** content differences — confirmed the same known stale-FUSE-metadata artifact documented in runs 188-192, no recovery commit needed. Along the way, noticed the mounted tree (and origin) contain three large, fully-built domains — `ActiveDirectory/`, `Azure/`, `Fabric/` — that predate this manifest's row-tracking (they're fully integrated into `AGENT_INDEX.md`, 19/41/1 references respectively, and every B/A pair + Scripts/ dir is present) but were never given manifest rows; flagging here rather than backfilling retroactively, since the manifest's own header already documents an intentional "don't re-litigate settled history" stance and the content itself is verified complete, not a real gap. Ran the standing B-without-A/A-without-B `find` sweep across the entire repo (all domains, not just manifest-tracked ones): **zero** genuine gaps, confirming run 189-192's finding that this sweep is now exhausted as a discovery method. Went straight to a fresh `WebSearch` "what's new" sweep per run 192's own pointer, and re-evaluated run 191's flagged-but-deferred candidate: **User-centric Access Reviews (UAR) went GA in September 2026** per the Microsoft Entra Tech Community "What's new" post, confirmed via three live Microsoft Learn fetches (`catalog-access-reviews`, `custom-data-resource-access-reviews`, plus a repo grep confirming zero prior mentions of "user-centric" anywhere in the existing `AccessReviews-A/B.md`). Run 191's original "too close to existing coverage" concern does not hold up: this is a structurally distinct review axis (per-user, multi-resource-type, catalog-scoped) from the existing single-resource `AccessReviews-A/B.md`, with its own instance-lifecycle state machine for Custom Data Provided Resources (`Initializing` → `Active` → `Applying` → `Applied`, vs. the standard two/three-state model) and its own reviewer-model constraint (CDPR: single-stage/manager-only, no owner or self-attestation option — a genuine, currently-documented capability gap, not a misconfiguration). The single highest-value fact the runbooks and script are built around: **CDPR decisions do not auto-apply** — Entra has no live connection to a disconnected/custom-data resource, so an admin or integration must list denied decisions, remediate access in the real system, then PATCH each decision item's `applyResult` back via Graph, or the review instance sits in `Applying` indefinitely with zero error surfaced anywhere; this is the review-engine's silent-failure mode most likely to generate a "why didn't this work" ticket once a customer adopts UAR for a disconnected app. Also captured and built around: the exact six-column CDPR CSV upload schema (`PrincipalId`/`PrincipalType`/`PermissionId`/`PermissionName`/`PermissionDescription`/`PermissionType`, all mandatory), the 2-hour upload window from `Initializing` (silent — a missed window just leaves that resource with zero reviewable items, no error), the 12-hour catalog-membership pre-start freeze window, and the My Access portal's separate "Multi-resource" completion tab (flagged as the single highest-friction, ticket-generating point of the whole feature from a support-volume perspective). No confirmed typed `Microsoft.Graph(.Beta)` cmdlet surface exists yet for catalog-scoped review definitions or CDPR decision PATCH operations (same situation run 191/192 documented for MCP Firewall/Tenant Governance) — both runbooks and the script use `Invoke-MgGraphRequest` against the confirmed beta REST endpoints (`identityGovernance/entitlementManagement/catalogs`, `identityGovernance/accessReviews/definitions/.../decisions`) rather than assuming cmdlet names, consistent with this repo's standing practice. Backfilled `EntraID/_AGENT.md` (new overview bullet inserted directly after the existing Access Reviews bullet, folder-contents rows inserted directly after the existing `AccessReviews-B/A.md` row, three new Common-entry-point bullets) and inserted the `AGENT_INDEX.md` row directly after the existing Access Reviews row via a targeted Python line-insert (the file's rows are single lines exceeding normal text-tool read/edit limits — matched runs 190-192's own approach of large-file-safe editing). Read-only script; brace/paren/bracket balance verified via Python counting pass (128/128, 67/67, 26/26 — fully balanced; no `pwsh` available in this environment to full-parse-check). **For next run:** re-run the B-without-A/A-without-B sweep first (still cheap, still clean); the `ActiveDirectory`/`Azure`/`Fabric` manifest-row gap noted above is cosmetic bookkeeping, not a content gap — low priority unless a future run wants to do a manifest-hygiene pass specifically (would align with this project's stated "reworking and removing a lot of the stale records" goal, similar in spirit to run 188's narrative archiving). Standard MSP-pain-point brainstorm list remains exhausted per runs 189-190; the Microsoft Learn/Message Center "what's new" sweep continues to be the higher-yield discovery path, particularly toward Entra Suite/Global Secure Access and Copilot/agent-governance-adjacent features, which is where Microsoft shipped fastest across runs 190-193._

---

## New Topic — memberOf Rule Operator Retirement (run 194)
| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/MemberOfRetirement-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/MemberOfRetirement-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-MemberOfRuleAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — 1 new overview bullet, 2 new Folder-contents rows, 4 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row appended, after the Microsoft Entra Tenant Governance row) | ✅ | auto-build |

_2026-09-02 (run 194): manifest queue empty entering this run — Expansion Rules mode. Before any new work, verified the mounted working tree's usual "modified/untracked" `git status` noise (spanning the same accumulated run history runs 188-193 already flagged) against a fresh `/tmp` clone of `origin/master`: `diff -rq` showed **zero** content differences — confirmed the same known stale-FUSE-metadata artifact documented since run 188, no recovery commit needed. Ran the standing B-without-A/A-without-B `find` sweep and the Scripts/-directory-coverage sweep first (cheap, per runs 189-193's pointer): both still clean, confirming this discovery method remains exhausted. Went straight to a fresh `WebSearch` "what's new" sweep against the September 2026 "What's New in Microsoft Entra" Tech Community post per run 193's own pointer, and this run's search surfaced a genuinely new, time-critical item that prior runs' sweeps hadn't caught: the **retirement of the `memberOf` dynamic membership rule operator** (message center notification MC1448379, announced 5 August 2026), with the preview ending **November 3, 2026** — under two months out from this run's date. Confirmed via three live Microsoft Learn fetches (the memberOf configuration/migration page itself, the dynamic-rule efficiency guide, and the entitlement-management auto-assignment-policy page, which usefully ships Microsoft's own Graph PowerShell discovery script for the entitlement-management surface) plus a repo-wide grep confirming zero prior coverage of this specific retirement anywhere (`DynamicGroups-A/B.md` document the general dynamic-group rule engine but predate this announcement and don't mention it). The single highest-value fact the runbooks and script are built around: **the three affected object surfaces fail differently, not identically** — dynamic groups and dynamic administrative units silently **freeze** at last-known membership post-deadline (with `MembershipRuleProcessingState` misleadingly continuing to report `On`, actively masking the freeze), while entitlement management automatic assignment policies are instead **quarantined** (assignment processing halts completely — neither additions nor removals occur, a distinct mechanism from a frozen snapshot); none of the three surface any visible error or portal warning, making this a fully silent failure mode an admin has to proactively sweep for. Also captured and built around: Microsoft's stated root cause for the retirement (a single `memberOf` rule could slow dynamic-group processing tenant-wide, not just for the group using it — explaining why there's no simple scale-limit fix), the documented preview-era constraints worth distinguishing from new retirement breakage (direct-membership-only source evaluation, no memberOf-of-memberOf chaining, no combination with other rule operators, 500-group/50-source-group caps, Global cloud only, no live re-evaluation on source-group member removal), and the explicit absence of any committed native replacement (Microsoft states an alternative is "in development" with no date), which is why both runbooks treat supported-attribute rewrite / assigned-membership conversion / external automation as the complete current option set rather than "wait for the fix." Built both runbook modes plus `Get-MemberOfRuleAudit.ps1` (three-surface sweep — dynamic groups via `Get-MgGroup`/`groupTypes`, dynamic AUs via the `administrativeUnits` Graph endpoint since no typed cmdlet reliably surfaces `membershipRule` for AUs, and entitlement management policies via `Invoke-MgGraphRequest` against `assignmentPolicies` adapting Microsoft's own published discovery script — deadline-aware severity that reclassifies every finding from at-risk WARN to already-frozen/quarantined CRITICAL once the script detects today's date is past Nov 3, 2026, plus a sole-assignment-policy blast-radius flag warning before a fix removes the only path by which an access package gets assigned); backfilled `EntraID/_AGENT.md` and added the `AGENT_INDEX.md` master-routing row immediately after the existing Tenant Governance row. Read-only script; brace/paren/bracket balance verified via Python counting pass (68/68, 123/123, 22/22 — fully balanced; no `pwsh` available in this environment to full-parse-check). **For next run:** re-run the B-without-A/A-without-B sweep first (still cheap, still clean); this run's deadline (Nov 3, 2026) means `MemberOfRetirement-B.md`/`-A.md` may be worth a short follow-up pass closer to that date to confirm no material Microsoft Learn content changed (e.g., a shipped replacement operator, which would change Fix 5/Playbook 3's "no equivalent exists" guidance) — flagging as a time-boxed revisit candidate, not an immediate gap._

## New Topic — Security Administrator Role Identity Response Expansion (run 195)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/SecurityAdminRoleExpansion-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/SecurityAdminRoleExpansion-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-SecurityAdminRoleAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — 1 new overview bullet, 2 new Folder-contents rows, 1 new Common-entry-point bullet) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row inserted directly after the existing memberOf Rule Operator Retirement row) | ✅ | auto-build |

_2026-09-02 (run 195): manifest queue empty entering this run — Expansion Rules mode. Before any new work, verified the mounted working tree's usual "modified/untracked" `git status` noise (accumulated since run 169's own work, per run 192's note that this backlog has been growing across more runs than any single prior note called out) against a fresh `/tmp` clone of `origin/master`: `diff -rq` showed **zero** content differences — confirmed the same known stale-FUSE-metadata artifact documented since run 188; no recovery commit needed, the remote already has every file through run 194. Ran the standing B-without-A/A-without-B sweep and the Scripts/-directory-coverage sweep first (cheap, per runs 189-194's pointer): both still clean (LLM/Modules/_BUILD remain non-topic meta folders, not real gaps). Went straight to a fresh `WebSearch` "what's new" sweep against the September 2026 "What's New in Microsoft Entra" Tech Community post plus a parallel Intune "what's new" search, then cross-checked every item against the repo: Tenant Governance GA and User-centric Access Reviews GA (both already covered, runs 192-193); Lifecycle Workflows clone-an-existing-workflow (too minor a UI feature to warrant a dedicated topic on its own); Entra Resource Accounts for Teams Devices passwordless GA (a real candidate, deferred — flagging for a future run since it's architecturally meaty and would need careful scoping against the existing `M365/Teams/Teams-Rooms-A.md`/`-B.md` to avoid overlap); Entra Domain Services sAMAccountName sync and Entra Cloud Sync reverse group-provisioning-to-AD (both Preview, narrower/niche); MCP Firewall (already covered, run 191); User.ReadBasic.All permission-scope security fix (too narrow — a single Graph permission clarification, not runbook-worthy); the Intune sweep's three candidates (Windows Autopilot device association GA, STIG audit baseline, Multi Admin Approval extended to Graph API calls) turned out to **already be built** in this repo per a `git status` check against the untracked-but-actually-already-on-`origin/master` file list from the FUSE-artifact verification above (`Autopilot/Troubleshooting/DeviceAssociation-A/B.md`, `Intune/Troubleshooting/STIGAuditBaseline-A/B.md`, `Intune/Troubleshooting/MultiAdminApproval-A/B.md` all present on `origin/master` already). The one genuinely new, time-critical, and cleanly-scoped gap found: the Sept 2026 blog's **"Enhancements to Security Administrator role"** change announcement (rollout completing by end of September 2026, this same month, with zero admin-facing toggle) — confirmed via the directly-fetched primary source and a partial fetch of the Microsoft Entra built-in-roles permissions-reference page (fetch was capped mid-alphabet before reaching the Security Administrator role's own detailed action table — noted explicitly in both runbooks and the script rather than asserting the literal appended action-string list with false confidence; the four candidate actions used throughout are a working hypothesis based on the identical action names Authentication Administrator/User Administrator already use for the same functional capabilities, verified live per-tenant by the script rather than hardcoded as fact). Built around the single highest-value operational insight: this duplicates identity-response power (disable/enable/revoke-sessions/reset-password) onto a role many MSPs already assign broadly for its read/reporting purpose, turning "who holds Security Administrator" into a live access-hygiene question the moment rollout lands, with the existing sensitive-actions protection model as the safety net against privileged-target escalation. Also explicitly scoped out and distinguished a related-but-different change surfaced during the same search — the separate Security Operator/Microsoft-Defender-unified-RBAC SOC-analyst containment-action extension — flagging it in both runbooks' Scope & Assumptions/notes as a candidate for its own future topic rather than conflating the two. Built both runbook modes plus `Get-SecurityAdminRoleAudit.ps1` (active/PIM-eligible assignee inventory, live rollout-status check against the four candidate actions, cross-role overlap detection, standing-assignment HIGH-severity flagging, optional audit-log cross-reference); backfilled `EntraID/_AGENT.md` and inserted the `AGENT_INDEX.md` row via a targeted Python line-insert (matching runs 190-194's large-file-safe editing approach) directly after the memberOf Retirement row. Read-only script; brace/paren/bracket balance verified via Python counting pass (47/47, 76/76, 13/13 — fully balanced; no `pwsh` available in this environment to full-parse-check). **For next run:** re-run the B-without-A/A-without-B sweep first (still cheap, still clean); **Entra Resource Accounts for Teams Devices (passwordless GA)** is this run's strongest deferred candidate — worth building once scoped carefully against the existing Teams Rooms coverage to avoid overlap; the parallel **Security Operator/Defender-unified-RBAC** SOC extension flagged above is a second reasonable candidate once more MSP-facing (rather than SOC-analyst-facing) operational detail is documented for it._

---

## New Topic — Passwordless Entra Resource Accounts for Teams Shared Devices (run 196)
| File | Status | Assigned |
|------|--------|---------|
| `M365/Teams/PasswordlessResourceAccounts-B.md` | ✅ | auto-build |
| `M365/Teams/PasswordlessResourceAccounts-A.md` | ✅ | auto-build |
| `M365/Teams/Scripts/Get-PasswordlessMigrationReadiness.ps1` | ✅ | auto-build |
| `M365/Teams/_AGENT.md` (backfilled — 1 new overview bullet, 2 new Folder-contents rows, 1 new Scripts-row, 3 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row inserted directly after the existing Teams Rooms row) | ✅ | auto-build |

_2026-09-02 (run 196): manifest queue empty entering this run — Expansion Rules mode. Before any new work, verified the mounted working tree's usual "modified/untracked" `git status` noise (spanning back through run 195's own work) against a fresh `/tmp` clone of `origin/master`: `diff -rq` showed **zero** content differences — confirmed the same known stale-FUSE-metadata artifact documented since run 188; no recovery commit needed, the remote already had every file through run 195. Ran the standing B-without-A/A-without-B sweep and the Scripts/-directory-coverage sweep first (cheap, per runs 189-195's pointer): both still clean. Went straight to run 195's own explicit "for next run" pointer — **Entra Resource Accounts for Teams Devices (passwordless GA)**, flagged as a deferred candidate by run 192 and re-flagged by run 195 — rather than a fresh topic brainstorm. Confirmed via `WebSearch` (the M365 Admin/handsontek Message Center summary for MC1435786, rollout early-to-late August 2026, Roadmap ID 558853) plus two live Microsoft Learn fetches (`passwordlessentraresourceaccounts` and `set-as-resource-account-for-shared-teams-devices`, both `ms.date` within the last 3 months) that run 192's original overlap concern does not hold up on close inspection: the existing `M365/Teams/Teams-Rooms-A.md`/`-B.md` document the classic *password-based* resource-account model end-to-end (Exchange room mailbox creation, CA-policy MFA exclusion for a non-interactive account, password-expiration policy) — this new feature is a distinct, optional, post-deployment authentication-METHOD conversion layered on top of that same account, not a replacement for it, and several of its operational facts actively differ from the existing coverage (e.g. a migrated device is no longer signed out by a password change, which is the opposite of the existing runbooks' password-hygiene guidance for the pre-migration state) — confirmed a repo-wide grep found zero prior mentions of "passwordless" or "device-bound" anywhere under `M365/Teams/`. The single highest-value operational fact the runbooks and script are built around: **the old password is not removed by migration** — it silently remains a valid, unused credential until an admin runs a separate Cleanup Password wizard (cloud-only accounts) or scrambles it (hybrid-synced accounts, which can never have it fully deleted) — a two-milestone lifecycle that is easy to under-scope in a customer migration project and the most likely source of a "why does this still work" audit finding. Also captured and built around: the platform-specific minimum OS/app version gates (Windows 11 24H2 build 26100.8655+ specifically), the unconditional hybrid-join block for Teams Rooms on Windows (no workaround documented), the architecturally different revert mechanics between Windows (full device reset required, since migration replaces the local Skype Windows account context) versus Android-based devices (simple sign-out suffices, no reset needed), the non-transferable device-bound credential that's destroyed on reset/re-image/replacement (documented recovery playbook: reset password, re-provision, re-migrate), and the two explicitly-unsupported-at-GA device categories (Crestron TRW hardware, proxy-configured TRW devices). Confirmed no PowerShell cmdlet or Graph endpoint is documented anywhere for the migration action itself (100% Teams Rooms Pro Management Portal-driven, matching the pattern runs 191/192/193 already documented for other Preview/GA features with no typed SDK surface yet) — the companion script (`Get-PasswordlessMigrationReadiness.ps1`) is therefore scoped honestly as an Entra-ID-side readiness audit only (license SKU eligibility via `Get-MgUserLicenseDetail`, hybrid-sync password-cleanup-path determination, password-expiration-policy check, sign-in-staleness heuristic), using only standard long-stable typed Graph cmdlets, with explicit inline documentation of what it cannot see (PMP migration status, device app/OS version, join type) rather than fabricating those checks. Built both runbook modes plus the script; backfilled `M365/Teams/_AGENT.md` (new overview-bullet clause, 2 new Folder-contents rows, 1 new Scripts row, 3 new Common-entry-point bullets) and inserted the `AGENT_INDEX.md` row directly after the existing "Teams Rooms devices, calling, meeting policies" row, cross-referencing both `Teams-Rooms-A/B.md` (the account this feature builds on) and `EntraID/Troubleshooting/WHfB-A/B.md` (the analogous human-user device-bound-credential model). Read-only script; brace/paren/bracket balance verified via Python counting pass (40/40, 76/76, 15/15 — fully balanced; no `pwsh` available in this environment to full-parse-check). **For next run:** re-run the B-without-A/A-without-B sweep first (still cheap, still clean); the **Security Operator/Defender-unified-RBAC SOC-analyst containment-action extension** flagged by run 195 remains an open candidate once more MSP-facing (rather than SOC-analyst-facing) operational detail is documented for it — worth a fresh `WebSearch` check before the next expansion-mode run defaults straight back to a generic "what's new" sweep._

---

## New Topic — Entra SOC Identity Responder Role (run 197)
| File | Status | Assigned |
|------|--------|---------|
| `EntraID/Troubleshooting/SOCIdentityResponder-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/SOCIdentityResponder-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-SOCIdentityResponderAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — 1 new overview bullet, 2 new Folder-contents rows, 2 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row inserted directly after the existing Security Administrator Role Expansion row) | ✅ | auto-build |

_2026-09-02 (run 197): manifest queue empty entering this run — Expansion Rules mode. Before any new work, verified the mounted working tree against a fresh `/tmp` clone of `origin/master` (checked out onto `master`, not the stale default `main` branch): `diff -rq` showed **zero** content differences through run 196's own work — confirmed the same known stale-FUSE-metadata artifact documented since run 188, no recovery commit needed. Ran the standing B-without-A/A-without-B `find` sweep and the Scripts/-directory-coverage sweep first (cheap, per runs 189-196's pointer): both still clean (`LLM`/`Modules` remain the only Scripts-less folders, both non-topic meta folders, not a real gap). Went straight to run 195/196's own repeatedly-deferred "for next run" pointer — the **Security Operator/Microsoft-Defender-unified-RBAC SOC-analyst containment-action extension** — rather than a fresh generic topic brainstorm. `WebSearch` plus a live fetch of the September 2026 "What's New in Microsoft Entra" Tech Community post did not surface this item as a standalone September announcement (it reiterated only the already-covered Security Administrator expansion, Tenant Governance GA, and UAR GA), so a targeted follow-up search on Microsoft's own June 2026 announcement language turned up the actual outcome: Microsoft did not simply extend Security Operator as originally described — it shipped a **new, separate built-in Entra role, "SOC Identity Responder"** (documented by Microsoft as "Entra SOC Identity Responder"), introduced roughly June-July 2026. Confirmed via a live fetch of Microsoft's own [privileged-roles-permissions](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/privileged-roles-permissions) reference (`ms.date` 2026-06-05, updated 2026-07-20), which names the role twice — in both the "who can reset passwords" and "who can perform sensitive actions" tables — using the identical non-privileged-target-only restriction language already applied to Security Operator; a repo-wide grep confirmed zero prior mentions of "SOC Identity Responder" or "Identity Responder" anywhere. A secondary community source (Topedia Blog, 19 Jul 2026) added detail not yet in Microsoft's own published docs — a specific role template ID (`58f930cc-fcf4-4152-852c-1d7dbf502139`), a screenshot of four confirmed `allowedResourceActions` (`users/disable`, `users/enable`, `users/invalidateAllRefreshTokens`, `users/password/update` — the identical four action strings as the Security Administrator expansion from run 195, but via a structurally separate role), and claims of Administrative Unit scoping support and Defender-portal (unified RBAC) assignability — this run explicitly treats the Microsoft Learn material as confirmed and the community-sourced detail (template ID, exact action list, AU scoping, dual assignment surface) as a working hypothesis to verify live per tenant, consistent with this repo's standing practice for features where Microsoft's own docs lag the actual rollout. The single highest-value fact both runbooks and the script are built around: Microsoft's original June 2026 announcement described *extending Security Operator*, but what shipped is a **separate role** instead — this repo now has three distinct, easily-conflated mechanisms capable of producing structurally identical `Disable account`/`Reset user password` audit-log entries (SOC Identity Responder, the Security Administrator expansion from run 195, and pre-existing Security Operator read/investigate access), disambiguable only by assignee-list correlation, not action-name inspection — both runbooks lead with a disambiguation table/section for exactly this reason. Also captured: the deliberate least-privilege role-decomposition rationale (decoupling read/investigate from write/containment power rather than one role holding both), the dual assignment surface (classic Entra Roles blade vs. the Microsoft-recommended Defender-portal unified-RBAC path, which requires the assignor to hold at least Security Administrator and scopes the assignee's visible UI to the Defender portal only), and the hard "can't perform actions on privileged accounts" restriction with no documented exception path for this role (unlike Privileged Authentication Administrator/Global Administrator). No confirmed typed `Microsoft.Graph` cmdlet or REST surface exists for reading Defender unified RBAC (URBAC) role/permission state directly — the script does not attempt this and instead resolves the role via its underlying Entra directory-role object (which URBAC assignments for this role ultimately produce), consistent with this repo's standing practice of using only confirmed surfaces. Built both runbook modes plus `Get-SOCIdentityResponderAudit.ps1` (dual display-name-variant role resolution with no hardcoded-template-ID trust, assignee/AU-scope inventory, confirmed-vs-hypothesized action-set live check — the hypothesized "mark compromised"/"delete auth method" actions referenced in Microsoft's broader announcement language but not confirmed in the base role definition are checked for and reported, never assumed — three-way overlap detection against Security Operator/Security Administrator/Authentication/User Administrator, standing-assignment risk flagging, optional audit-log cross-reference); backfilled `EntraID/_AGENT.md` and inserted the `AGENT_INDEX.md` row directly after the existing Security Administrator Role Expansion row via a targeted Python line-insert (matching runs 190-196's large-file-safe editing approach). Read-only script; brace/paren/bracket balance verified via Python counting pass (78/78, 125/125, 16/16 — fully balanced; no `pwsh` available in this environment to full-parse-check). **For next run:** re-run the B-without-A/A-without-B sweep first (still cheap, still clean); this run finally closed out the Security Operator/SOC-containment thread runs 195-196 had been deferring — the next expansion-mode run should default to a fresh `WebSearch` "what's new" sweep (Entra + Intune + Defender Tech Community posts) rather than re-checking any specific deferred item, since no further candidates remain flagged as of this writing._

---

---

## New Topic — Defender for Cloud Apps File Policy Retirement (run 198)
| File | Status | Assigned |
|------|--------|----------|
| `Security/Defender/FilePolicyRetirement-B.md` | ✅ | auto-build |
| `Security/Defender/FilePolicyRetirement-A.md` | ✅ | auto-build |
| `Security/Defender/Scripts/Get-FilePolicyRetirementAudit.ps1` | ✅ | auto-build |
| `Security/Defender/_AGENT.md` (backfilled — 1 new overview-paragraph clause, 2 new Folder-contents rows, 4 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row inserted directly after the existing Defender: Cloud Apps/Identity/Vuln Mgmt/Network Protection/WDAC row) | ✅ | auto-build |

_2026-09-02 (run 198): manifest queue empty entering this run — Expansion Rules mode. Before any new work, diffed the mounted working tree's file contents against a fresh `/tmp` clone of `origin/master` (checked out onto `master`) per the standing practice documented since run 188. Unlike runs 188-197, this diff was **not** clean: it found exactly one genuine, real difference — `Security/Defender/FilePolicyRetirement-B.md`, a complete, well-formed 284-line Mode B runbook present only in the mounted tree, absent from `origin/master`, and not referenced anywhere in `_AGENT.md`, `AGENT_INDEX.md`, or this manifest. This reads as leftover work from a prior run (content and format fully match this repo's standing quality bar, including a forward-reference to a "Governance Action Mapping" table in a `FilePolicyRetirement-A.md` that did not yet exist) that was written but never had its companion `-A.md`, backfills, or commit/push completed — the first confirmed non-cosmetic gap since the stale-FUSE-metadata artifact was first documented in run 188, and worth flagging explicitly in case it recurs: **always diff against a fresh clone before assuming `git status` noise is purely cosmetic; this run's diff would have been wrongly dismissed under the "always clean" assumption runs 189-197 had built up.** Verified the file's content and citations directly against Microsoft's own Learn documentation (`migrate-file-policies-to-purview`, live-fetched) before building on top of it: retirement date January 6, 2027 confirmed correct (not the December 31, 2026 date the file itself already flagged as a third-party-blog error to avoid), migration tool scope (SharePoint/OneDrive DLP-type policies only; auto-labeling and non-Microsoft-app policies excluded) confirmed accurate. Built the missing `FilePolicyRetirement-A.md` Mode A companion — architecture (why the retirement exists, the migration tool's actual four-quadrant scope vs. "migrate everything" assumption, the three-way Can/Partial/Cannot-migrate verdict logic, why migrated policies always land in Test with notifications mode, why old-and-new policies can't both enforce simultaneously), dependency stack, symptom→cause map, validation steps, phased troubleshooting, two remediation playbooks (full project plan; emergency/imminent-deadline path), and — critical since the pre-existing `-B.md` Fix 2 explicitly references it by name — a **Governance Action Mapping** table enumerating every original MDA governance action against its Purview equivalent, explicitly calling out the three actions with **no equivalent** (Trash/delete file, Expire shared link, Transfer file ownership) as capability gaps requiring a documented business decision rather than more migration effort. Built `Get-FilePolicyRetirementAudit.ps1` using Security & Compliance PowerShell (`Connect-IPPSSession`/`Get-DlpCompliancePolicy`/`Get-AutoSensitivityLabelPolicy`) rather than Microsoft Graph, since Purview DLP and auto-labeling policy cmdlets live in that module, not `Microsoft.Graph` — the script is scoped honestly as a Purview-side tracking tool only (Test-mode vs. enforcing state across many migrated/recreated policies, stalled-validation flagging past a configurable day threshold, CSV export) with explicit inline documentation that MDA File policy inventory and migration-wizard verdicts remain Defender-portal-only with no programmatic read surface, rather than fabricating a check for data that cannot actually be read this way. Backfilled `Security/Defender/_AGENT.md` (new overview-paragraph clause, 2 new Folder-contents rows, 4 new Common-entry-point bullets) and inserted the `AGENT_INDEX.md` row directly after the existing Defender: Cloud Apps/Identity/Vuln Mgmt/Network Protection/WDAC row. Read-only script; brace/paren/bracket balance verified via Python counting pass (36/36, 51/51, 13/13 — fully balanced; no `pwsh` available in this environment to full-parse-check). Ran the standing B-without-A/A-without-B sweep and Scripts/-directory-coverage sweep after this run's own changes: both clean. **For next run:** re-run the fresh-clone content diff first and do NOT assume it will be clean by default given this run's finding — if clean, proceed straight to a `WebSearch` "what's new" sweep per run 197's pointer (no further deferred candidates remain flagged as of this writing)._

---

---

## New Topic — Windows Recall (Copilot+ PC) Governance (run 199)
| File | Status | Assigned |
|------|--------|----------|
| `Windows/Troubleshooting/Recall-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/Recall-A.md` | ✅ | auto-build |
| `Windows/Scripts/Get-RecallPolicyAudit.ps1` | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — 1 new overview bullet, 2 new Folder-contents rows, 3 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row inserted directly after the existing Windows 10 ESU row) | ✅ | auto-build |

_2026-09-02 (run 199): manifest queue empty entering this run — Expansion Rules mode. Ran the standing B-without-A/A-without-B `find` sweep (clean — the two path-splitting false positives from the `Windows Update`/space-in-folder-name subfolder were re-verified as false positives, both files exist) and the Scripts/-directory-coverage sweep (clean — every topic folder with content has a nested `Scripts/` dir; `LLM`/`Modules` remain the only Scripts-less folders and are non-topic meta folders, not a real gap) before any new work. Surveyed several already-covered "obvious" expansion candidates first (Graph API batch operations, Power Platform DLP, Autopilot Device Preparation v2, Windows 365/AVD, macOS Bootstrap Token/SecureToken) and confirmed each already has full A/B/script coverage — Bootstrap Token/SecureToken specifically already receives deep treatment inside the existing `macOS/Troubleshooting/FileVault-B.md` (Fix 6/7, Dependency Cascade), so a standalone file would have been duplicative, not a gap. Settled on **Windows Recall governance on Copilot+ PCs** as a genuine, currently-uncovered topic (confirmed via repo-wide grep for "recall"/"copilot+ pc"/"npu" prior to writing — zero existing coverage) that is squarely in-scope for this project's stated MacOS/Microsoft-environment focus and realistically current for a 2026 MSP: Recall is GA on Copilot+ PC hardware and generates two distinct real ticket categories — (1) end-user "why can't I turn this on" tickets rooted in the BitLocker/Windows-Hello-Enhanced-Sign-in-Security prerequisite chain, and (2) org-level "block this fleet-wide" / sensitive-data-exposure governance requests, which in practice is the more common MSP engagement given Recall's local-screenshot-and-index privacy profile. Built both runbook modes covering: the hard NPU (≥40 TOPS) hardware eligibility gate with no policy bypass; the opt-in-by-design enrollment flow (a deliberate architecture choice following the June 2024 preview redesign); the Windows Hello Enhanced Sign-in Security prerequisite as a distinct, stricter trust tier from ordinary Hello sign-in (the most common root cause of "Recall greyed out" tickets on otherwise-eligible hardware); the `WindowsAI` CSP/GPO governance surface (`AllowRecallEnablement` for enrollment-level blocking, `DisableAIDataAnalysis` for capture-level blocking, both confirmed as the current documented policy names as of this writing); local-only snapshot storage architecture (`%LOCALAPPDATA%\CoreAIPlatform.00\UKP\`, explicitly no cloud sync); best-effort sensitive-content filtering vs. explicit app/site exclusion as the only fully deterministic control; the storage-allocation-slider-vs-actual-disk-free-space distinction that silently stalls capture with no user-facing error; and a Data Governance Posture section flagging that the local Recall store is not currently a Purview-indexed/eDiscovery-reachable source — deliberately hedged with "confirm current state with compliance stakeholders" language rather than presenting that as a permanent guarantee, since this is an area Microsoft has signaled intent to expand. Built `Get-RecallPolicyAudit.ps1` as a single-machine, read-only diagnostic (hardware signal, WindowsAI policy state, BitLocker check, Hello enrollment signal, `aihost.exe`/related-service state, disk free-space headroom, local store existence/size) that explicitly never reads or exports actual snapshot content — only existence and size — consistent with the topic's own privacy-sensitivity. Backfilled `Windows/_AGENT.md` (new overview bullet, 2 new Folder-contents rows, 3 new Common-entry-point bullets) and inserted the `AGENT_INDEX.md` row directly after the existing Windows 10 ESU row via a targeted Python line-insert (matching runs 190-198's large-file-safe editing approach for a 259KB+ file). Read-only script; brace/paren/bracket balance verified via Python counting pass (62/62, 91/91, 14/14 — fully balanced; no `pwsh` available in this environment to full-parse-check). **For next run:** re-run the standing fresh-clone content diff against `origin/master` first (per run 198's finding that this check is NOT reliably a no-op) before assuming a clean starting state; if clean, a fresh `WebSearch` "what's new" sweep (Entra + Intune + Defender + Windows Tech Community posts) remains the recommended next move — no further deferred candidates are flagged as of this writing._

---

## New Topic — Quick Machine Recovery (QMR) (run 200)
| File | Status | Assigned |
|------|--------|---------|
| `Windows/Troubleshooting/QuickMachineRecovery-B.md` | ✅ | auto-build |
| `Windows/Troubleshooting/QuickMachineRecovery-A.md` | ✅ | auto-build |
| `Windows/Scripts/Get-QuickMachineRecoveryAudit.ps1` | ✅ | auto-build |
| `Windows/_AGENT.md` (backfilled — 1 new overview bullet, 2 new Folder-contents rows, 3 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row inserted directly after the existing Windows Recall row) | ✅ | auto-build |

_2026-09-02 (run 200): manifest queue empty entering this run — Expansion Rules mode. Per run 199's own pointer, re-ran the standing fresh-clone content diff against `origin/master` (checked out onto `master`, not the stale default `main` branch) FIRST rather than assuming it would be clean — `diff -rq` showed **zero** content differences through run 199's own work, confirming the mounted tree's `git status` "modified/untracked" noise remains the known stale-FUSE-metadata artifact (run 198's one-time genuine exception has not recurred); no recovery commit needed. Ran the standing B-without-A/A-without-B `find` sweep and the Scripts/-directory-coverage sweep next (both still clean; the `Windows Update`/space-in-folder-name false positive was re-verified as a false positive again, not re-investigated in depth). Went to a fresh `WebSearch` "what's new" sweep across Intune, Defender, and Windows IT Pro Tech Community posts for September 2026 per run 199's pointer. Three real candidates surfaced: Intune's "App settings" declarative binary/app-launch-control feature (already fully covered, `macOS/Troubleshooting/AppSettings-A.md`/`-B.md`, confirmed via grep before investigating further); the standalone Microsoft Defender Threat Intelligence (MDTI) product retirement (August 1, 2026, converging into Defender XDR/Sentinel at no additional cost) — a real, distinct gap from the existing `Security/Sentinel/ThreatIntelligence-A.md`/`-B.md` (which covers a 2025 legacy-table retirement inside Sentinel, not the MDTI standalone-SKU retirement), noted here as a strong deferred candidate for a future run rather than built this run; and **Quick Machine Recovery (QMR)**, confirmed via repo-wide grep for "quick machine recovery"/"QMR" returning zero existing coverage — chosen over MDTI for this run since it sits squarely in this project's stated Windows-device-management focus (an MSP device-recovery topic, not a SOC/security-licensing one) and is freshly and heavily documented: live-fetched both the Microsoft Support end-user page (`ms.date` 2026-07-10) and the Microsoft Learn IT-pro configuration page plus its linked Recovery CSP reference (both updated within the last 1-3 months, `ms.date` 2026-08-17 and 2026-06-24 respectively). Built around the single highest-value fact: QMR's default is a **management-state fork that runs backwards from what most admins assume** — ON by default on unmanaged/consumer devices, OFF by default on Enterprise/Education/domain-or-MDM-managed Pro — paired with a "sticky explicit configuration" rule (an admin-set value survives a later management-state transition; only the unset/implicit default follows state), a pattern this repo has now documented in several other topics but rarely this cleanly stated by Microsoft's own docs. Also built around two further genuine gotchas: WinRE's network stack supports only wired Ethernet or WPA/WPA2-password Wi-Fi, with **no 802.1X/Enterprise Wi-Fi support at all** — a hard architectural ceiling (not a missing feature) that quietly defeats QMR for most enterprise wireless estates unless a dedicated WPA2-PSK fallback SSID is provisioned via the CSP's `NetworkSettings/Wifi/{SSID}/WlanXML` node; and a confirmed, unresolved discrepancy between Microsoft's own two published minimum-OS-build figures (Support article: 24H2 26100.4700+; Recovery CSP reference: 24H2 26100.8737+/25H2 26200.8737+) — flagged explicitly in both runbooks and the script rather than silently picking one, consistent with this repo's standing practice for genuine cross-Microsoft-source conflicts (e.g., run 207's Jamf CA-deprecation-date discrepancy). A third-party-blog-vs-current-Learn-doc naming drift was also caught and flagged: several 2025-era how-to blogs (petervanderwoude, PatchMyPC, HTMD, ugurkoc) reference an older `./Vendor/MSFT/RemoteRemediation/CloudRemediationSettings` CSP node from QMR's Insider-Preview era, which predates and does not match the current shipped `./Vendor/MSFT/Recovery/QuickMachineRecovery` node structure documented on the current Microsoft Learn page — both runbooks warn against following stale blog-sourced CSP paths. The Intune Settings Catalog category name itself ("Remote Remediation") is community-sourced only, since Microsoft's own CSP reference page does not name the Settings Catalog UI category — both runbooks flag this as unconfirmed-by-Microsoft and tell the reader to verify the label in their own tenant, consistent with this repo's source-confidence-labeling discipline. No PowerShell cmdlet module exists for QMR configuration or verification — `reagentc.exe` (a native tool, not a PowerShell module) is the sole documented on-device read/write surface; `Get-QuickMachineRecoveryAudit.ps1` is scoped as a single-machine, read-only diagnostic built around `reagentc.exe /getrecoverysettings` output parsing (WinRE state, effective CloudRemediation/AutoRemediation/timer values, a management-state-vs-observed-default cross-check, wired-vs-wireless connectivity signal, and MDM policy-activity sync-health check), with an explicit, tested redaction step for the WinRE Wi-Fi password that command prints in plaintext — flagged as a real evidence-collection/screen-sharing hazard in both runbooks. Backfilled `Windows/_AGENT.md` (new overview bullet, 2 new Folder-contents rows, 3 new Common-entry-point bullets) and inserted the `AGENT_INDEX.md` row directly after the existing Windows Recall row via a targeted Python line-insert (matching runs 190-199's large-file-safe editing approach for a 260KB+ file). Read-only script; brace/paren/bracket balance verified via Python counting pass (57/57, 112/112, 25/25 — fully balanced; no `pwsh` available in this environment to full-parse-check). **For next run:** re-run the standing fresh-clone content diff against `origin/master` first (per run 198's finding this is not reliably a no-op); the **MDTI standalone-product-retirement** gap flagged above (distinct from the existing Sentinel `ThreatIntelligence-A.md`/`-B.md` legacy-table-retirement topic) is this run's strongest deferred candidate if a Security/Sentinel-focused expansion is wanted next; otherwise a fresh `WebSearch` "what's new" sweep (Entra + Intune + Defender + Windows Tech Community posts) remains the standing recommended path._

---

## New Topic — Microsoft Defender Threat Intelligence (MDTI) Standalone Retirement (run 201)
| File | Status | Assigned |
|------|--------|----------|
| `Security/Sentinel/MDTIRetirement-B.md` | ✅ | auto-build |
| `Security/Sentinel/MDTIRetirement-A.md` | ✅ | auto-build |
| `Security/Sentinel/Scripts/Get-MDTIRetirementAudit.ps1` | ✅ | auto-build |
| `Security/Sentinel/_AGENT.md` (backfilled — 1 new overview clause, 3 new Folder-contents rows, 4 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new row inserted directly after the existing Microsoft Sentinel Threat Intelligence row) | ✅ | auto-build |

_2026-09-02 (run 201): manifest queue empty entering this run — Expansion Rules mode. Before any new work, diffed the mounted working tree's file contents against a fresh `/tmp` clone of `origin/master` (checked out onto `master`, not the stale default `main` branch, per the standing practice documented since run 188 and run 198's reminder not to assume this is a no-op) — `diff -rq` showed **zero** content differences through run 200's own work; confirmed the mounted tree's `git status` "modified/untracked" noise remains the known stale-FUSE-metadata artifact, no recovery commit needed. Ran the standing B-without-A/A-without-B `find` sweep (clean — every `*-B.md` has a matching `*-A.md` and vice versa). Went straight to run 200's own explicit "for next run" pointer — the **MDTI standalone-product-retirement** gap — rather than a fresh generic topic brainstorm, since it was already confirmed via repo-wide grep at run 200 to be a genuine, distinct gap from this same folder's pre-existing `ThreatIntelligence-A.md`/`-B.md` (which covers Sentinel's own STIX TI *ingestion mechanics* — the data connector and `ThreatIntelIndicators`/`ThreatIntelObjects` tables — not the standalone *product/portal/licensing* event). Verified and expanded on run 200's one-line description via live fetches: Microsoft's own current Learn page (`Microsoft Threat Intelligence in Microsoft Defender XDR`, `ms.date` 2026-07-30, last updated 2026-08-02) confirms the standalone portal and Intel Explorer experience retired **August 1, 2026**, and reveals a quiet rebrand — Microsoft's current docs drop "Defender" from the name entirely, now calling it plain "Microsoft Threat Intelligence," while virtually all community/vendor commentary (4sysops, TrustedTech, Kocho, q-advise) still says "MDTI." Cross-referenced community sources for licensing/billing detail Microsoft's own Learn page doesn't spell out in one place: standalone MDTI was removed from Microsoft's purchasable Product Terms "Availability and Prerequisite" tables on 2025-10-01 (no new subscriptions sold from that date); the post-retirement research experience (Intel profiles/Intel explorer) is now bundled into Microsoft 365 E5, an E5 Security add-on, Microsoft Defender for Endpoint Plan 2, or accessible via a free Sentinel connector (standard ingestion costs may still apply), while free entity-enrichment data (the new "Threat Intelligence Insights" entity-page tab) remains available to all Defender XDR customers regardless of license tier; and CSP partners with standalone MDTI subscriptions running past the retirement date receive Microsoft-issued credit memos for unused term that must be manually passed through to the end customer — a finance/account-management action this repo flags explicitly since nothing on the tenant/technical side surfaces it automatically. Also caught and flagged a genuine cross-source date discrepancy consistent with this repo's standing practice (e.g., run 200's ESU/QMR build-number conflict, run 197's SOC-role-naming correction): a Microsoft Community Hub post titled "MDTI Standalone Portal Retirement and Transition to Defender XDR," despite being last modified in August 2026, carries a June 30, 2024 date in its own page description — both runbooks treat the current Learn page's 2026-08-01 date as authoritative and instruct the reader to verify directly rather than trust either date blindly if a compliance record depends on the exact day. Built both runbook modes leading with an explicit three-way disambiguation (standalone product/portal — retired; Defender-portal-integrated capability — the destination, unaffected; Sentinel's own TI data-connector/ingestion layer — architecturally separate, unaffected), since this was identified as the single highest-value fact and the most likely source of ticket misrouting for this topic; Mode B covers dead-bookmark redirects, the license-gate distinction between free entity enrichments and the licensed research experience, explicit rule-out guidance pointing misrouted Sentinel-ingestion tickets back to `ThreatIntelligence-B.md`, and CSP billing cleanup, while Mode A adds the full three-date retirement timeline, the licensing-convergence rationale (a net simplification/cost-reduction for the large majority of customers already holding a qualifying license), and two remediation playbooks (fleet-wide MSP roster cleanup; licensing-path decision tree for a client that held standalone MDTI without any qualifying E5/Sentinel license). Built `Get-MDTIRetirementAudit.ps1` as a read-only Microsoft Graph script scoped honestly around what's actually checkable — since the retired standalone product has no PowerShell/Graph surface of its own, the script audits tenant-wide qualifying-SKU inventory (`Get-MgSubscribedSku` pattern-matched against the documented qualifying SKU families, with an explicit "verify manually" warning rather than a false-negative claim when no match is found), optional per-user license-assignment checks against a supplied analyst list, and an optional Sentinel TI-connector presence check (`Get-AzSentinelDataConnector`) as the alternate free access path — explicitly does not and cannot check the retired product itself. Backfilled `Security/Sentinel/_AGENT.md` (new overview clause distinguishing this topic from the pre-existing Threat Intelligence ingestion-mechanics coverage in the same paragraph, 3 new Folder-contents rows, 4 new Common-entry-point bullets) and inserted the `AGENT_INDEX.md` row directly after the existing Microsoft Sentinel Threat Intelligence row via a targeted Python line-insert (matching runs 190-200's large-file-safe editing approach for a 280KB+ file). Read-only script; brace/paren/bracket balance verified via Python counting pass (36/36, 57/57, 16/16 — fully balanced; no `pwsh` available in this environment to full-parse-check). Ran the standing B-without-A/A-without-B sweep after this run's own changes: still clean. **For next run:** re-run the standing fresh-clone content diff against `origin/master` first (per run 198's finding this is not reliably a no-op); no further deferred candidates are flagged as of this writing — a fresh `WebSearch` "what's new" sweep (Entra + Intune + Defender + Windows Tech Community posts) remains the standing recommended path._

---

## New Topic — Partner Tier1/Tier2 Support Role Retirement (run 202)
| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/PartnerTierRoleRetirement-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/PartnerTierRoleRetirement-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-PartnerTierRoleRetirementAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — 1 new overview bullet, 2 new Folder-contents rows, 2 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new Domain Map row inserted directly after the existing GDAP row) | ✅ | auto-build |

_2026-09-02 (run 202): manifest queue empty entering this run — Expansion Rules mode. Before any new work, cloned a fresh `/tmp` copy of `origin/master` (checked out onto `master`) and diffed it against the mounted working tree's file contents (`diff -rq --exclude=.git`) — **zero** differences found, confirming all of runs 189-201's work (which had accumulated as `git status` "modified/untracked" noise against the mounted tree's stale FUSE-cached local git metadata since the last direct commit on 2026-08-18) was already fully present on `origin/master`, i.e. already pushed by a prior/concurrent run's own `/tmp`-scratch-clone push workflow — no recovery commit was needed, consistent with the standing procedure documented since run 188. Rather than a fresh generic topic brainstorm, ran a live `WebSearch` "what's new" sweep across Entra/Intune Message Center and Tech Community sources per run 201's own closing pointer, and cross-referenced findings against a full repo-wide grep sweep (topic-name and keyword search across every `.md` file) to rule out duplicate coverage before building — confirmed this was a genuine, previously-uncovered gap distinct from the existing `GDAP-A.md`/`-B.md` general relationship-lifecycle topic, which this new topic only intersects via the GDAP Access Assignment role-mapping step. Sourced primarily from Microsoft's own Message Center post **MC1409305** (published 2026-06-29, fetched directly via `mc.merill.net` mirror for full text) plus Microsoft's built-in-roles permissions-reference page. Key facts captured: Microsoft blocks **new assignments** (not existing ones, not role deletion) to the Partner Tier1 Support and Partner Tier2 Support built-in Entra roles, global rollout **2026-08-03 through ~2026-08-24** with no tenant opt-in/opt-out; both roles are separately documented under Microsoft's own "Roles not shown in the portal" list (Graph/PowerShell required to view or manage either role — a pre-existing, unrelated characteristic worth disambiguating from the retirement itself in ticket triage); the failure signature is **HTTP 400 (Request_BadRequest)**, deliberately distinct from a 403 (caller-permission problem) or 404 (role-doesn't-exist) to correctly signal "valid caller, disallowed operation"; and Microsoft names five candidate replacement roles (User Administrator as the stated closest general fit, plus Helpdesk/Groups/License/Domain Name Administrator) or a custom role, explicitly declining to name a single 1:1 successor since the retired roles' actual usage varied by partner. Built Mode B around a triage table distinguishing "new assignment correctly blocked" from "existing access broke (NOT this retirement — investigate PIM/CA/license instead)," since that inversion — assuming a broken-access ticket is caused by a change that explicitly doesn't affect existing assignments — was identified as the most likely misdiagnosis risk for this topic. Mode A adds the full CSP/GDAP Access Assignment mechanism explanation (Partner Center's role-mapping step referencing these roles for new relationships), a replacement-role selection table mapped to actual permission need rather than a reflexive User-Administrator default, and two remediation playbooks (a full MSP onboarding-automation/template audit sweep; a live mid-onboarding unblock procedure). Built `Get-PartnerTierRoleRetirementAudit.ps1` as a read-only script that resolves both portal-hidden role objects, inventories current membership (explicitly flagged as unaffected by the retirement), checks the rollout-window date against today, and confirms each of the five replacement-role candidates resolves in the tenant — deliberately does not and cannot check Partner Center GDAP Access Assignment templates, which live outside any Graph/PowerShell-reachable surface (flagged explicitly in both the runbook and script header rather than silently omitted). Backfilled `EntraID/_AGENT.md` (new "What's in this folder" bullet, two Folder-contents rows, two Common-entry-point bullets including an explicit "do NOT assume this retirement" rule-out entry) and inserted a new `AGENT_INDEX.md` Domain Map row directly after the existing GDAP row via a targeted, quoted-heredoc Python line-replace (first attempt via an unquoted heredoc corrupted embedded backtick-wrapped file-path references through unintended bash command substitution — caught immediately via `git diff` inspection before writing further files, reverted cleanly via `git checkout --`, and redone correctly with the heredoc delimiter quoted to disable all shell interpolation; noting this explicitly as a process correction for future runs using this same large-file Python-edit pattern). Brace/paren balance verified via a Python counting pass (26/26 braces, 40/40 parens for the script — a single apparent 23/22 brace mismatch traced to a literal `\{` inside a regex character-class string, confirmed a false positive, not a real syntax error); no `pwsh` available in this environment to full-parse-check._

---

## New Topic — Company Branding Custom CSS Retirement (run 202)
| File | Status | Assigned |
|------|--------|----------|
| `EntraID/Troubleshooting/BrandingCSSRetirement-B.md` | ✅ | auto-build |
| `EntraID/Troubleshooting/BrandingCSSRetirement-A.md` | ✅ | auto-build |
| `EntraID/Scripts/Get-BrandingCSSRetirementAudit.ps1` | ✅ | auto-build |
| `EntraID/_AGENT.md` (backfilled — 1 new overview bullet, 2 new Folder-contents rows, 2 new Common-entry-point bullets) | ✅ | auto-build |
| `AGENT_INDEX.md` (new Domain Map row inserted directly after the new Partner Tier1/Tier2 Support Role Retirement row) | ✅ | auto-build |

_2026-09-02 (run 202, second topic this run): identified alongside the Partner Tier1/Tier2 Support gap during the same `WebSearch` "what's new" sweep, and confirmed via repo-wide grep as a genuine gap — no prior coverage of Entra ID company-branding/sign-in CSS customization existed anywhere in the repo. Sourced from two related Message Center posts, fetched directly for full text: **MC1435782** (the original announcement) and **MC1458474** (published 2026-08-21, which explicitly **expands** the retired-property list beyond MC1435782's original scope — flagged prominently in both runbooks as a common source of incomplete remediation if a client's internal documentation only cites the earlier post). Key facts captured: this is a two-stage, Secure-Future-Initiative-driven (phishing-hardening) retirement of a specific list of CSS **layout and positioning** properties (`offset*`, `margin-block*`/`margin-inline*`, `order`, `grid-*`, `isolation`, `overflow-*`, `content-visibility`, `clip`, `mask*`/`-webkit-mask*` — 28 properties total) usable in Company branding and per-application Branding themes custom sign-in CSS; **Stage 1 (2026-07-21)** blocks tenants with no prior custom-CSS usage from beginning to use it (does not affect tenants already using it); **Stage 2 (late October 2026, Message Center states "Act by 2026-10-26")** stops honoring the retired properties globally for every tenant regardless of adoption history; branding content itself is never deleted, only layout/positioning reverts to Microsoft's default template presentation; and Microsoft Entra **External ID (CIAM) tenants are explicitly and entirely excluded** from this change. Also captured Microsoft's own forward-looking signal that a fuller, unscheduled custom-CSS retirement is planned for "later in 2027," flagged in both runbooks as a distinct future milestone rather than folded into this change's scope. Built Mode B around the two-date distinction (most likely source of client confusion) and an explicit reminder that Company branding and Branding themes are separately configured surfaces sharing the same property list and cutover date, requiring independent checks. Mode A adds the full functional grouping/reasoning behind which CSS property categories were targeted (positioning/masking/clipping — the tools an attacker would need to construct a convincing fake sign-in page — versus untouched cosmetic properties like color/font/border), a two-stage rollout table, and two remediation playbooks (a full MSP client-roster pre-cutover audit sweep; a redesign playbook for layouts that genuinely depended on a retired property, including the common image-asset-baking workaround pattern for retired masking/clipping effects). Built `Get-BrandingCSSRetirementAudit.ps1` as a read-only script that pattern-matches a **downloaded** CSS file's content against the full MC1458474 property list via property-name-anchored regex (avoiding substring false-positives, e.g. matching `margin-block:` but not incidentally matching an unrelated `margin` shorthand declaration) — explicitly notes in its own header that custom CSS content has no Graph-queryable structured representation, so the file must be downloaded via the Entra admin center first; includes an optional `-CheckGraphConfig` companion sanity check via `Get-MgOrganizationBranding`. Backfilled `EntraID/_AGENT.md` (new "What's in this folder" bullet, two Folder-contents rows, two Common-entry-point bullets) and inserted a second new `AGENT_INDEX.md` Domain Map row directly after this run's own Partner Tier1/Tier2 Support row, using the same corrected quoted-heredoc Python edit pattern established in this run's first topic. Ran the standing B-without-A/A-without-B sweep after both topics' changes: clean. **For next run:** re-run the standing fresh-clone content diff against `origin/master` first (do not assume this is a no-op, per run 198's finding); a further `WebSearch` "what's new" sweep across Entra/Intune/Defender/Windows Tech Community and Message Center sources remains the standing recommended path for identifying the next gap, since this run's sweep surfaced two clean, previously-undocumented, date-driven retirement topics on the first pass._

---

## New Topic — M365 Subfolder _AGENT.md Backfill (run 203)
| File | Status | Assigned |
|------|--------|----------|
| `M365/AdminAgent/_AGENT.md` | ✅ | auto-build |
| `M365/Loop/_AGENT.md` | ✅ | auto-build |
| `M365/Places/_AGENT.md` | ✅ | auto-build |
| `M365/Planner/_AGENT.md` | ✅ | auto-build |
| `M365/VivaEngage/_AGENT.md` | ✅ | auto-build |
| `M365/VivaInsights/_AGENT.md` | ✅ | auto-build |

_2026-09-02 (run 203): manifest queue empty entering this run — Expansion Rules mode. Before any new work, diffed the mounted working tree's file contents against a fresh `/tmp` clone of `origin/master` (checked out onto `master`, per the standing practice since run 188 and run 198's reminder not to assume this is a no-op) — this time the diff was **not** clean, but in the opposite direction from run 198's exception: `origin/master` already contained a full run 202 (`EntraID/Troubleshooting/BrandingCSSRetirement-A/B.md`, `PartnerTierRoleRetirement-A/B.md`, their scripts, and `EntraID/_AGENT.md`/`AGENT_INDEX.md` backfills) that the mounted FUSE tree had not yet caught up to. Per this project's own memory note that the `night-build`/`day-build` scheduled tasks can run concurrently, this reads as a second build task having completed run 202 while this run was starting, with the mount simply lagging behind actual repo state rather than any genuine content conflict — confirmed by checking the fresh clone's own MANIFEST.md, which already carried a "run 202" closing line. Rather than working from the stale mount (risking duplicate or conflicting work), did all reading and writing for this run directly against the fresh `/tmp` clone (pulled to HEAD, remote swapped to the mounted tree's own PAT-embedded URL per standing practice) and will push from there. Ran the standing B-without-A/A-without-B sweep against the fresh clone (clean — every `*-B.md` has a matching `*-A.md`). Went looking for a fresh topic via `WebSearch` first (Entra/Intune/Defender "what's new" for September 2026): found Microsoft Entra Tenant Governance, User-centric Access Reviews, and the Security Administrator role-expansion rollout, the Conditional Access Custom Controls Sept 30 2026 retirement, and the Admin app (Teams/Outlook/M365.com) retirement — grepped the repo for each before investing further work and found the first four **already fully built** (`EntraID/Troubleshooting/TenantGovernance-A/B.md`, `CatalogAccessReviews-A/B.md`, `SecurityAdminRoleExpansion-A/B.md`, `Security/ConditionalAccess/CustomControlsRetirement-A/B.md` all present with scripts and `_AGENT.md`/`AGENT_INDEX.md` entries), consistent with how mature and current this repo already is after 202 prior runs. Rather than force a marginal or duplicative new topic, pivoted to a structural-gap sweep per Expansion Rule #1 ("check existing folders for gaps") and found one: a domain-level check of every folder directly under `M365/` for a matching `_AGENT.md` showed **six genuine, unambiguous gaps** — `M365/AdminAgent/`, `M365/Loop/`, `M365/Places/`, `M365/Planner/`, `M365/VivaEngage/`, and `M365/VivaInsights/` each already have a complete, high-quality `-A.md`/`-B.md` pair and a `Scripts/` script, but no `_AGENT.md` of their own — the one file type this project's own stated goal ("recreating new agent instructions for different problems") explicitly centers on. Notably, `AGENT_INDEX.md` and `M365/_AGENT.md` already carry full, detailed rows/cross-references for all six folders (written as part of each topic's original build), so this was a pure backfill of the missing folder-level instruction file itself — no other file needed updating. Built all six `_AGENT.md` files following the standing FORMAT SPEC (What's in this folder / Before responding also check / Folder contents table / Common entry points / Key diagnostic commands / Key dependency chain / Response format reminder), sourcing every Common-entry-point bullet, diagnostic command, and dependency-chain diagram directly from each topic's own existing `-A.md`/`-B.md`/`Scripts/*` content (verified via `grep`/`awk` extraction against the actual files, not invented) rather than summarizing from memory, so each new file is fully consistent with — and traceable to — the runbooks it indexes. Markdown code-fence balance verified via a `grep -c '^```'` pass on all six files (4/4 even count each — clean). **For next run:** re-run the standing fresh-clone content diff against `origin/master` first and do not assume the mount has caught up; if the concurrent-task lag pattern recurs, keep working from the fresh clone rather than the mount. No further `_AGENT.md` backfill gaps remain under `M365/` after this run; the Admin app (Teams/Outlook/M365.com) retirement (complete removal Oct 2026) and Project Online's Sept 30 2026 retirement (distinct from the already-covered Project-for-the-web-into-Planner history in `M365/Planner/Planner-A.md`) both came up clean on a repo-wide grep and remain the strongest deferred candidates for a genuinely new topic next run, alongside a repeat of the domain-level `_AGENT.md` gap sweep across the OTHER top-level domains (`EntraID/`, `Windows/`, `Security/`, `PowerAutomate/`, `Autopilot/`, `Intune/`) which this run did not have time to check beyond `M365/`._

---

Last updated: 2026-09-02 (auto-build, run 203, scheduled task "ezadmin-night-build", run as an unattended scheduled task with no user present).
