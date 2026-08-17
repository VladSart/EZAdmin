# Azure — Agent Instructions

## What's in this folder

Azure infrastructure runbooks and scripts for MSP engineers managing Azure environments on behalf of clients. Covers **Azure Virtual Desktop (AVD)** (session host management, FSLogix profile containers, MSIX App Attach, network connectivity), **Azure Files** (direct SMB/NFS shares, identity-based auth, Azure File Sync), **Windows 365 Cloud PC** (provisioning, Azure Network Connections, licensing, resize/reprovision), **Azure Arc-enabled servers** (Connected Machine agent onboarding, connectivity/heartbeat, identity model, prerequisite layer for Sentinel/Defender for Cloud on non-Azure servers), **Azure Backup** (Recovery Services Vault — Azure VM disk backup job failures, recovery point consistency, restores, soft delete, immutability), **Azure Key Vault** (RBAC vs. legacy Access Policy authorization model, network/private-endpoint access denials, soft-delete and purge-protection recovery, certificate auto-rotation failures), **Azure Networking / Hybrid Connectivity** (VPN Gateway site-to-site IPsec/BGP, ExpressRoute circuit provisioning and eBGP peering across the customer/provider/Microsoft three-zone model), **Network Security Groups** (general-purpose rule precedence, dual subnet/NIC-layer evaluation, service tags, Application Security Groups, and Security Admin Rules via Azure Virtual Network Manager — the shared data-plane layer underneath every other Azure connectivity topic in this folder), **Azure Virtual Network Manager** (centralized network group/connectivity-configuration governance — scope and delegation, static vs. dynamic membership, mesh/hub-and-spoke topologies via the connected-group construct, and the goal-state deployment model that silently drops unlisted configurations on redeploy), **Azure Automation** (managed identity authentication and the 30-Sept-2023 Run As account retirement, runbook job/sandbox execution failures, and extension-based Hybrid Runbook Worker connectivity — agent-based workers retired 31 Aug 2024), **Azure Update Manager** (native, non-Automation-dependent patch management for Azure VMs and Arc-enabled servers — patch-extension lifecycle, on-demand/periodic/scheduled patching, maintenance configuration and configuration assignment resources, and maintenance-window arithmetic), **Azure Policy** (resource governance/compliance — deny/audit/deployIfNotExists/modify effect model with no cross-assignment precedence, remediation task and managed-identity RBAC dependency, exemptions vs. notScopes, and the phased Azure Blueprints retirement beginning 31 July 2026), **Azure Monitor Agent / Log Analytics** (the telemetry pipeline underneath Sentinel, Defender for Cloud, AVD, and every other domain in this folder that references diagnostic/monitoring data — managed-identity/IMDS authentication, Data Collection Rule-driven configuration with no agent-side defaults, optional Private-Link-only Data Collection Endpoints, and Analytics/Basic/Auxiliary table-plan cost/query trade-offs; explicitly distinguishes the retired legacy Log Analytics/MMA/OMS agent — backend shut down 2 Mar 2026 — from the current AMA extension model), **Microsoft Entra Domain Services** (formerly Azure AD Domain Services/AADDS — the managed, platform-owned domain-controller pair providing domain join, Group Policy, LDAP, and Kerberos/NTLM for legacy lift-and-shift workloads without deploying or patching DCs in Azure; one-way sync architecture from Microsoft Entra ID, dedicated-subnet/platform-managed-NSG networking model, the federation-without-PHS hard blocker, and the cloud-only-user-never-changed-password sync gap that drives most "new hire can't domain-join" tickets), and **Azure Virtual Machines / Compute — VM Extensions & Boot Diagnostics** (the VM Agent — Windows Guest Agent/WaAppAgent.exe/RdAgent, Linux waagent — as the mandatory prerequisite layer underneath every extension; the WireServer 168.63.129.16:80/32526 control channel whose blockage silently breaks the Agent, every extension, AND Run Command at once; VMExtensionProvisioningError/VMExtensionHandlerNonTransientError/stuck-Transitioning extensions; CustomScriptExtension download-vs-execution failure classes; the Microsoft Antimalware extension's replace-not-merge exclusion behavior; boot diagnostics as a hypervisor-level capability architecturally independent of the Guest Agent and explicitly incompatible with Premium/ZRS storage accounts; Serial Console's hard dependency on boot diagnostics being enabled first; and Run Command as a VM-Agent-dependent, not out-of-band, recovery path), and **Azure Virtual Machines / Compute — VM Boot & Disk Repair** (the OS-level layer directly beneath VM Extensions & Boot Diagnostics — offline repair of Windows boot failures via the industry-standard snapshot/attach-to-repair-VM pattern; INACCESSIBLE_BOOT_DEVICE and Boot Configuration Data repair with Generation-1-vs-2 command syntax branching; stuck offline Check Disk; the three architecturally distinct causes of a reboot loop — critical-service ErrorControl, a bad update/LKGC recovery, and registry hive corruption via `regback` as a documented last resort; the automated `az vm repair create/run/restore` CLI flow versus the manual disk-copy procedure; and Azure Disk Encryption's single-pass (v2+, automatable) vs. dual-pass (v1, manual-KEK-unwrap-only) version split as the actual gate on which unlock method is even possible for an encrypted OS disk), and **Azure Site Recovery (Azure-to-Azure disaster recovery)** (continuous block-level replication between Azure regions — two architecturally independent recovery-point tracks, crash-consistent every 5 minutes vs. app-consistent VSS-based on a configurable policy frequency, whose independent failure explains why Error 153007 and 153006 have zero remediation overlap; the cache storage account as the actual source-region data-plane bottleneck for churn/network tickets, not the vault or target region; data churn limits keyed to disk SIZE not performance tier, with Premium SSD v2/Ultra Disk VMs requiring Premium Block Blob High Churn cache storage with no non-High-Churn alternative; disk tier/SKU changes silently invalidating older recovery points via snapshot-bookmark regeneration, surfacing as a `BookmarkNotFound` failover failure; and the four-stage failover/reprotect/failback/reprotect-again state machine, where skipping the mandatory-but-not-automatic reprotection step after a failover is this topic's single most common real-world gap), and **Azure Storage Accounts (Blob/Queue/Table)** (the network → authentication → authorization gate model each request must pass independently; Shared Key vs. Account/Service SAS vs. User Delegation SAS vs. Microsoft Entra ID auth; the control-plane-vs-data-plane RBAC split where Owner/Contributor grants zero `Storage Blob/Queue/Table Data *` access — the most common source of "I have full access but get 403" tickets; soft delete, blob versioning, and immutability/WORM policies as three independent, stackable protections, the last of which blocks even the account Owner once locked; and lifecycle management tiering with its ~daily-not-instant transition cadence), and **On-Premises to Azure Disaster Recovery (VMware & Hyper-V)** (two architecturally unrelated on-premises component stacks under one product name — VMware routes everything through a single ASR replication appliance while Hyper-V installs a Provider + Recovery Services agent directly on the host or VMM server with no appliance at all; the Classic VMware experience's hard retirement — new-replication blocked 31 Jan 2026, support ends 15 Mar 2026, capability retires 30 Mar 2026 — and the one-way-door requirement that a Modernized appliance register against a brand-new vault, never a reused Classic one; Hyper-V's explicit non-recoverable-vs-recoverable error classification, where non-recoverable errors get zero automatic retry; and the asymmetric outbound authentication-proxy support between the two platforms, supported on VMware Modernized and entirely unsupported on Hyper-V).

---

## Before responding, also check

- **Entra ID** (`EntraID/`) — AVD requires Entra-joined or Hybrid-joined session hosts; SSO and identity issues often originate there
- **Intune** (`Intune/`) — Session hosts managed via Intune need compliance and configuration policy review
- **Windows** (`Windows/Troubleshooting/`) — RDP, networking, Kerberos, and profile issues apply to AVD session hosts
- **Security/ConditionalAccess** — CA policies frequently block AVD users; cross-reference sign-in logs
- **Security/Defender** — MDE is deployed on AVD hosts; ASR rules and Tamper Protection can affect session host behaviour
- **ActiveDirectory/Troubleshooting/ADLDS** — easily confused with Entra Domain Services by name alone; AD LDS is a standalone, on-premises-only, non-domain LDAP role with no cloud sync path, while Entra Domain Services is a fully managed, cloud-hosted, Entra-ID-synchronized domain. If the question involves Entra ID sync or NTLM/Kerberos in Azure, it belongs in `Windows365/`'s sibling folder here, not `ActiveDirectory/`.
- **EntraID/Troubleshooting/Connect-Sync** — Microsoft Entra Connect's password hash sync configuration is a hard prerequisite for Entra Domain Services authentication in hybrid/federated tenants; a sign-in failure that traces back to PHS belongs there for the Connect-side fix
- **Azure/Monitor/LogAnalytics** — the Azure Monitor Agent (AMA) extension shares the exact same VM Agent/extension-provisioning mechanics covered in `Compute/VMExtensions-A.md`; an AMA extension reporting `Succeeded` only confirms the extension layer, not Data Collection Rule association health, which is owned entirely by `Monitor/LogAnalytics-A.md`
- **Azure/Backup** — the Azure Backup VM extension (`AzureBackupWindowsIaasExtension`/`AzureBackupLinuxIaasExtension`) depends on the same healthy VM Agent covered in `Compute/VMExtensions-B.md`; a backup job failing on guest-agent/extension grounds should be triaged against Guest Agent health first, then handed to `Backup/AzureBackup-B.md` for the backup-specific VSS/snapshot failure modes
- **Azure/SiteRecovery** — shares the Recovery Services vault construct with `Azure/Backup` but is a completely different failure domain (continuous replication vs. scheduled snapshot backup); a "vault issue" ticket needs to be split between the two before troubleshooting starts. The Mobility Service replication agent is also a standard VM extension and depends on `Compute/VMExtensions-B.md`'s VM Agent/WireServer layer exactly like Azure Backup's own extension does
- **Azure/OnPremDR** — easily confused with `Azure/SiteRecovery` by product name alone; `SiteRecovery` is Azure-to-Azure (A2A) replication between two Azure regions, while `OnPremDR` covers on-premises VMware/Hyper-V replicating INTO Azure — different on-premises component stack, different retry/proxy behavior, and a different failback sequence. Confirm which direction the DR ticket is actually about before picking a file

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
| `Backup/AzureBackup-B.md` | Azure Backup hotfix runbook — backup job failures (guest agent, extension, VSS, stuck jobs, protection stopped) |
| `Backup/AzureBackup-A.md` | Azure Backup deep dive — recovery point tiers/consistency, soft delete, immutability, restore and bulk-remediation playbooks |
| `Backup/Scripts/Get-AzureBackupJobStatus.ps1` | Vault-wide report — protection status, failed jobs, guest prerequisite health, soft-deleted items pending |
| `KeyVault/KeyVault-B.md` | Key Vault hotfix runbook — authorization model mismatch, firewall/private-endpoint/DNS denials, soft-delete recovery, certificate renewal failures |
| `KeyVault/KeyVault-A.md` | Key Vault deep dive — RBAC vs. Access Policy architecture, network path evaluation, soft-delete/purge-protection lifecycle, certificate auto-rotation model, migration and recovery playbooks |
| `KeyVault/Scripts/Get-KeyVaultAccessAudit.ps1` | Read-only report across one or all vaults — authorization grants, network posture, soft-delete/purge-protection state, certificate expiry vs. auto-renew capability |
| `Networking/HybridConnectivity-B.md` | Hybrid connectivity hotfix runbook — IPsec tunnel down, BGP peer not connecting/flapping, ExpressRoute circuit/provider stuck, eBGP peering mismatch, routes present but traffic blocked |
| `Networking/HybridConnectivity-A.md` | Hybrid connectivity deep dive — VPN Gateway IPsec/BGP and ExpressRoute three-zone architecture, six-layer dependency stack, migration and provider-outage playbooks |
| `Networking/Scripts/Get-HybridConnectivityHealth.ps1` | Read-only sweep across VPN Gateways and ExpressRoute circuits — connection/BGP/peering state, near-prefix-limit warning, control-plane-vs-data-plane traffic check |
| `Networking/NSG-B.md` | NSG hotfix runbook — priority conflicts, subnet/NIC dual-layer conflicts, service tag and ASG misconfigurations, default-deny blocks, Security Admin Rule check |
| `Networking/NSG-A.md` | NSG deep dive — rule evaluation architecture, Security Admin Rules (AVNM), service tags, ASGs, augmented rules, flow log migration, dependency stack shared by every other Azure networking topic in this folder |
| `Networking/Scripts/Get-NSGRuleAudit.ps1` | Read-only fleet-wide sweep — broad management-port exposure, priority-collision risk, dual-layer NIC/subnet coverage inventory, Security Admin Rule presence |
| `Networking/AVNM-B.md` | AVNM hotfix runbook — scope/never-deployed VNet, dynamic membership lag, goal-state redeploy trap, "use hub as gateway" silent partial-peering, mesh IP-overlap drops |
| `Networking/AVNM-A.md` | AVNM deep dive — scope/delegation model, static/dynamic network groups, connectivity configuration architecture, goal-state deployment model, migration and fleet-audit playbooks |
| `Networking/Scripts/Get-AVNMConfigAudit.ps1` | Read-only sweep — network group membership, configurations defined but never deployed, multi-config goal-state risk regions, failed deployments, optional single-VNet effective-state check |
| `Automation/AzureAutomation-B.md` | Azure Automation hotfix runbook — retired Run As account failures, unassigned managed identity roles, stuck module imports, Hybrid Worker job queuing/suspension, expired webhooks |
| `Automation/AzureAutomation-A.md` | Azure Automation deep dive — managed identity architecture and Run As retirement, sandbox execution limits, extension-based Hybrid Runbook Worker architecture, migration and fleet-audit playbooks |
| `Automation/Scripts/Get-AzureAutomationHealth.ps1` | Read-only fleet sweep — identity presence, module provisioning state, Hybrid Worker heartbeat/purge risk, webhook expiry, recent job failure rate |
| `UpdateManager/UpdateManager-B.md` | Azure Update Manager hotfix runbook — extension missing/stuck, HRESULT update-agent errors, broken schedule assignment after a VM move, maintenance-window-exceeded failures, Linux sudo/root privilege failures |
| `UpdateManager/UpdateManager-A.md` | Azure Update Manager deep dive — patch-extension and guest-OS update-client architecture, on-demand/periodic/scheduled patching model, maintenance-window arithmetic, Resource Graph retention limits, fleet onboarding and legacy-Automation-migration playbooks |
| `UpdateManager/Scripts/Get-AzureUpdateManagerHealth.ps1` | Read-only fleet sweep — VM power state, extension-operations eligibility, patch extension health, optional Arc connection check, optional per-machine schedule-assignment check, orphaned-schedule detection |
| `Policy/AzurePolicy-B.md` | Azure Policy hotfix runbook — deployment blocked by deny/denyAction, NonCompliant flags, failed remediation tasks, expired/misscoped exemptions |
| `Policy/AzurePolicy-A.md` | Azure Policy deep dive — definition/initiative/assignment architecture, the no-precedence effect model, remediation task and managed-identity RBAC mechanics, exemption vs. notScopes design, fleet onboarding and Blueprint-migration playbooks |
| `Policy/Scripts/Get-AzurePolicyComplianceAudit.ps1` | Read-only subscription/RG sweep — assignment inventory, compliance breakdown by effect (self-healable vs. manual-only), remediation task status with identity RBAC scope sanity check, exemption expiry risk |
| `Monitor/LogAnalytics-B.md` | Azure Monitor Agent/Log Analytics hotfix runbook — legacy-agent detection, extension "Succeeded but no data," missing DCR association, no managed identity, missing Private Link DCE |
| `Monitor/LogAnalytics-A.md` | Azure Monitor Agent/Log Analytics deep dive — full AMA/DCR/DCE/workspace architecture, legacy-agent-retirement timeline, table-plan cost model, fleet migration and onboarding playbooks |
| `Monitor/Scripts/Get-AzureMonitorAgentHealth.ps1` | Read-only fleet sweep (optionally including Arc) — legacy agent detection, identity presence, extension state, DCR association count, duplicate-stream and DCE region-mismatch flags |
| `EntraDomainServices/EntraDomainServices-B.md` | Entra Domain Services hotfix runbook — enablement failures, tenant-wide auth blocker (federation/PHS), sync-lag sign-in failures, local lockout, autogenerated SAMAccountName, unsupported NSG edits, recycle-bin SID-restore breakage |
| `EntraDomainServices/EntraDomainServices-A.md` | Entra Domain Services deep dive — managed-domain/replica-set architecture, one-way sync model and attribute mapping, networking/NSG requirements, local password/lockout policy, forest-trust and fine-grained-policy playbooks |
| `EntraDomainServices/Scripts/Get-EntraDomainServicesHealth.ps1` | Read-only audit — control-plane state, tenant PHS/federation posture, NSG baseline deviation, unsupported UDR detection, stale enablement-blocking app registrations, optional in-domain PasswordLastSet/lockout sampling |
| `Compute/VMExtensions-B.md` | VM Extensions & Boot Diagnostics hotfix runbook — VM Agent not Ready, extension VMExtensionProvisioningError/stuck Transitioning, CustomScriptExtension download/exit-code failures, Microsoft Antimalware exclusion overwrite gotcha, boot diagnostics blank/stale screenshot, Serial Console unavailable, Run Command as a recovery path |
| `Compute/VMExtensions-A.md` | VM Extensions & Boot Diagnostics deep dive — VM Agent/WireServer/extension-handler architecture, boot diagnostics' hypervisor-level independence from the Guest Agent, Premium/ZRS storage incompatibility, Run Command action-vs-managed model, fleet-audit playbooks |
| `Compute/Scripts/Get-AzureVMExtensionHealth.ps1` | Read-only audit — VM power state, VM Agent status/version, per-extension provisioning state, boot diagnostics enablement and storage-tier support check, optional in-guest WireServer connectivity test via Run Command |
| `Compute/VMBootRepair-B.md` | VM Boot & Disk Repair hotfix runbook — classify INACCESSIBLE_BOOT_DEVICE/chkdsk-stuck/reboot-loop from a boot diagnostics screenshot, BCD repair (Gen 1/2), offline chkdsk, three reboot-loop fix paths, automated `az vm repair` flow, ADE-encrypted disk unlock |
| `Compute/VMBootRepair-A.md` | VM Boot & Disk Repair deep dive — full boot-sequence dependency stack, ADE single-pass/dual-pass unlock-method matrix, manual and automated repair-VM playbooks, reboot-loop root-cause architecture |
| `Compute/Scripts/Get-AzureVMBootRepairAudit.ps1` | Read-only audit — generation, ADE encryption state/version, managed vs. unmanaged OS disk, existing OS-disk snapshots, boot diagnostics enablement, computed recommended-repair-path per VM |
| `SiteRecovery/SiteRecovery-B.md` | Azure Site Recovery (A2A) hotfix runbook — classify Error 153007 (crash-consistent/churn) vs. 153006 (app-consistent/VSS), BookmarkNotFound after a disk tier change, cache storage account network throttling, expired Mobility Service tenant/client ID, stale Configuration Issues dashboard, reprotect-after-failover |
| `SiteRecovery/SiteRecovery-A.md` | Azure Site Recovery (A2A) deep dive — full replication pipeline architecture, crash- vs. app-consistent recovery-point tracks, disk-size-keyed churn limits, four-stage failover/reprotect/failback state machine, PowerShell setup/failover/reprotect playbooks |
| `SiteRecovery/Scripts/Get-SiteRecoveryHealth.ps1` | Read-only fleet audit — replication health/protection state, RPO vs. threshold, test-failover recency, app-consistent recovery point presence, recent failed jobs, across every fabric/container in one or all vaults |
| `StorageAccounts/StorageAccounts-B.md` | Storage Account (Blob/Queue/Table) hotfix runbook — 403 despite RBAC, expired/invalid SAS, firewall blocks, soft-deleted "missing" blobs, immutability write blocks |
| `StorageAccounts/StorageAccounts-A.md` | Storage Account deep dive — network/authn/authz gate model, Shared Key/SAS/Entra ID auth comparison, control-plane vs data-plane RBAC, soft delete/versioning/immutability, lifecycle management |
| `StorageAccounts/Scripts/Get-AzureStorageAccountHealth.ps1` | Reports account auth toggles, network posture, data-plane RBAC gaps, soft delete/versioning state, lifecycle policy presence across one or all accounts |
| `OnPremDR/OnPremDR-B.md` | On-premises to Azure DR (VMware & Hyper-V) hotfix runbook — identify platform/architecture first, Classic VMware retirement flag, appliance/Provider-agent heartbeat, Mobility Service port 9443 connectivity, Hyper-V non-recoverable error classification, asymmetric outbound proxy support, stuck failback |
| `OnPremDR/OnPremDR-A.md` | On-premises to Azure DR deep dive — two independent on-premises component architectures (VMware appliance vs. Hyper-V Provider+agent, with/without VMM), replication/resync process per platform, Hyper-V non-recoverable/recoverable retry model, Classic-to-Modernized migration timeline and playbook, per-platform failback sequences |
| `OnPremDR/Scripts/Get-OnPremDRHealth.ps1` | Read-only fleet audit across one or all vaults — per-item replication health/protection state, Classic VMware fabric detection, recent failed jobs, flagged for manual Hyper-V non-recoverable/recoverable error review |

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
- **"Backup job failed for a VM"** → `Backup/AzureBackup-B.md` (triage first — pull the actual error code)
- **"How do I restore a VM from backup"** → `Backup/AzureBackup-A.md` Playbook 2
- **"I deleted a backup item by mistake"** → `Backup/AzureBackup-A.md` Playbook 1 (soft delete, 14-day window)
- **"Collect vault backup health for a ticket/report"** → `Backup/Scripts/Get-AzureBackupJobStatus.ps1`
- **"I have a role assignment but still get access denied in Key Vault"** → `KeyVault/KeyVault-B.md` Fix 1 (check `EnableRbacAuthorization` first — RBAC and Access Policy are mutually exclusive)
- **"403 accessing Key Vault through a private endpoint"** → `KeyVault/KeyVault-B.md` Fix 2 — check DNS resolution before touching firewall rules
- **"Certificate stopped auto-renewing in Key Vault"** → `KeyVault/KeyVault-B.md` Fix 4 — confirm the CA is Key-Vault-partnered (DigiCert/GlobalSign) first
- **"Audit access across all our Key Vaults"** → `KeyVault/Scripts/Get-KeyVaultAccessAudit.ps1 -AllVaults`
- **"Site-to-site VPN won't connect"** → `Networking/HybridConnectivity-B.md` Fix 1 — confirm IPsec tunnel before touching BGP
- **"ExpressRoute circuit shows Not provisioned"** → `Networking/HybridConnectivity-B.md` Triage — split Microsoft-side vs. provider-side immediately
- **"BGP peering Active/Idle instead of Established"** → `Networking/HybridConnectivity-B.md` Fix 4
- **"Fleet-wide hybrid connectivity health check"** → `Networking/Scripts/Get-HybridConnectivityHealth.ps1`
- **"I added an NSG allow rule and traffic is still blocked"** → `Networking/NSG-B.md` Fix 1/Fix 2 — check for a priority conflict first, then confirm both subnet-level and NIC-level NSGs allow it
- **"NSG rules look correct but traffic is still wrong"** → `Networking/NSG-B.md` Triage step 5 — check for a Security Admin Rule (Azure Virtual Network Manager) silently overriding evaluation
- **"Client wants NSG flow logs enabled"** → `Networking/NSG-B.md` Learning Pointers — redirect to VNet flow logs (NSG flow logs can no longer be newly created, retiring Sept 30, 2027)
- **"Fleet-wide NSG hygiene / exposed management ports review"** → `Networking/Scripts/Get-NSGRuleAudit.ps1`
- **"AVNM config deployed but the VNet isn't getting it"** → `Networking/AVNM-B.md` Fix 1 — check scope first, then whether it was actually deployed to that region
- **"Can't find the peering for our AVNM mesh"** → `Networking/AVNM-B.md` Triage — mesh is a connected group, never a real peering resource
- **"AVNM connection broke after an unrelated config change"** → `Networking/AVNM-A.md` Playbook 2 — goal-state redeploy trap
- **"Fleet-wide AVNM configuration health check"** → `Networking/Scripts/Get-AVNMConfigAudit.ps1`
- **"Runbook fails with 'No certificate was found' or 'Login-AzureRMAccount to log in'"** → `Automation/AzureAutomation-B.md` Fix 1 — retired Run As account, migrate to managed identity
- **"Runbook stuck Queued or job exceeded the Hybrid Worker limit"** → `Automation/AzureAutomation-B.md` Fix 4 — check worker heartbeat first
- **"Client's Hybrid Runbook Worker hasn't been touched since before 2024"** → `Automation/AzureAutomation-A.md` Playbook 2 — likely still the retired agent-based model
- **"Onboarding a client's existing Automation estate"** → `Automation/Scripts/Get-AzureAutomationHealth.ps1`
- **"Machine shows Not assessed with a red exception"** → `UpdateManager/UpdateManager-B.md` Fix 2 — decode the HRESULT before assuming an Azure-side fault
- **"Scheduled patching stopped after we moved the VM to another RG/subscription"** → `UpdateManager/UpdateManager-B.md` Fix 3 — configuration assignments don't migrate automatically
- **"Client still has Update Management (no 'r') inside their Automation account"** → that's the retired legacy solution — flag for migration to `UpdateManager/UpdateManager-A.md` Playbook 2, not covered by `Automation/`
- **"Fleet-wide patching coverage audit for onboarding or a report"** → `UpdateManager/Scripts/Get-AzureUpdateManagerHealth.ps1 -IncludeArc -CheckVMAssignments`
- **"Deployment failed with RequestDisallowedByPolicy"** → `Policy/AzurePolicy-B.md` Fix 1 — pull the exact `policyAssignmentId` from the ARM error before assuming which policy fired
- **"Resource shows NonCompliant but nothing seems broken"** → `Policy/AzurePolicy-B.md` Triage step 4 — check the effect first, audit-only policies have no remediation path
- **"Policy remediation task keeps failing"** → `Policy/AzurePolicy-B.md` Fix 4 — check the managed identity's RBAC scope against the assignment scope first
- **"Client wants an emergency exception to a blocking policy"** → `Policy/AzurePolicy-A.md` Playbook 2 — scoped, time-bound exemption, never widen notScopes
- **"Onboarding a client's existing Azure estate to a new governance baseline"** → `Policy/AzurePolicy-A.md` Playbook 3 — audit-first rollout before enforcing deny
- **"Client still has Azure Blueprints deployed"** → `Policy/AzurePolicy-A.md` Playbook 4 — phased retirement starts 31 July 2026, migrate to Deployment Stacks/Template Specs + native Policy assignments
- **"Fleet-wide policy compliance and exemption-expiry audit for a ticket/report"** → `Policy/Scripts/Get-AzurePolicyComplianceAudit.ps1`
- **"Client's monitoring just stopped working"** → `Monitor/LogAnalytics-B.md` Triage step 1 first — check for the retired legacy agent (backend shut down 2 Mar 2026) before anything else
- **"AMA extension shows Succeeded but no data in the workspace"** → `Monitor/LogAnalytics-B.md` Fix 2 — "Succeeded" only confirms install, not health
- **"Installed AMA, still nothing in Log Analytics"** → `Monitor/LogAnalytics-B.md` Fix 3 — check for a missing DCR association, the most common root cause
- **"Log Analytics costs spiked with no new data source added"** → `Monitor/LogAnalytics-A.md` Symptom→Cause Map — duplicate DCR streams or a table-plan issue
- **"Fleet-wide AMA health/legacy-agent sweep for onboarding or a report"** → `Monitor/Scripts/Get-AzureMonitorAgentHealth.ps1 -IncludeArc`
- **"No one can sign in to our Entra Domain Services managed domain"** → `EntraDomainServices/EntraDomainServices-B.md` Triage step 2 — check federation/PHS posture before anything else, it's a tenant-wide blocker, not a per-user issue
- **"New hire can't domain-join their Azure VM"** → `EntraDomainServices/EntraDomainServices-B.md` Fix 1 — cloud-only user likely hasn't changed their password since Domain Services was enabled, so no hash has synced yet
- **"User says they're locked out but Entra ID shows nothing"** → `EntraDomainServices/EntraDomainServices-B.md` Fix 2 — lockout is local to the managed domain only, check there directly
- **"Enabling Entra Domain Services fails citing an application ID"** → `EntraDomainServices/EntraDomainServices-B.md` Fix 7 — stale app registration from a prior failed attempt
- **"User lost file access after being restored from the Entra ID recycle bin"** → `EntraDomainServices/EntraDomainServices-B.md` Fix 6 — restored users get a new SID in the managed domain, old ACLs are orphaned
- **"Should we use Entra Domain Services or deploy AD DS on Azure VMs?"** → `EntraDomainServices/EntraDomainServices-A.md` How It Works — managed/patched-by-Microsoft vs. self-managed trade-off
- **"Audit our Entra Domain Services config before a client review"** → `EntraDomainServices/Scripts/Get-EntraDomainServicesHealth.ps1`
- **"VM extension shows Provisioning failed / VMExtensionProvisioningError"** → `Compute/VMExtensions-B.md` Triage — confirm VM Agent status is Ready before troubleshooting the specific extension
- **"Extension stuck in Transitioning / Creating and never finishes"** → `Compute/VMExtensions-B.md` Fix 4 — VM Reapply first, then remove/reinstall
- **"Can't RDP/SSH into a VM to fix it"** → `Compute/VMExtensions-B.md` Fix 9 — Run Command (if the Agent is alive) or Serial Console (hypervisor-level, works even if the Agent is dead)
- **"Boot diagnostics screenshot is blank or looks stale"** → `Compute/VMExtensions-B.md` Fix 6 — check the guest display idle timeout first, then the storage account tier
- **"VM start fails with StorageAccountTypeNotSupported"** → `Compute/VMExtensions-A.md` Symptom→Cause Map — boot diagnostics storage account is Premium/ZRS, both unsupported
- **"CustomScriptExtension failed"** → `Compute/VMExtensions-B.md` Fix 5 — distinguish a download failure from a non-zero script exit code before assuming a network problem
- **"Fleet-wide VM Agent/extension/boot-diagnostics health check for onboarding or a report"** → `Compute/Scripts/Get-AzureVMExtensionHealth.ps1`
- **"VM won't boot, screenshot shows INACCESSIBLE_BOOT_DEVICE or 'Reboot and Select proper Boot device'"** → `Compute/VMBootRepair-B.md` Fix 2 — BCD repair, check VM generation before choosing command syntax
- **"VM stuck on 'Checking file system on C:' / 'Scanning and repairing drive' for a long time"** → `Compute/VMBootRepair-B.md` Fix 3 — offline chkdsk against the attached disk
- **"VM boot logo keeps repeating, never reaches sign-in"** → `Compute/VMBootRepair-B.md` Fix 4/5/6 — reboot loop has three distinct causes, check offline logs before picking one
- **"Disk shows locked with a padlock icon when attached to a repair VM"** → `Compute/VMBootRepair-B.md` Fix 7/8 — Azure Disk Encryption; confirm v1 (dual-pass, manual-only) vs. v2+ (single-pass, automatable) before choosing a method
- **"Need to attach a failed VM's OS disk to a second VM for offline repair"** → `Compute/VMBootRepair-A.md` Playbook 1 (manual, no public IP) or Playbook 2 (automated `az vm repair`, fastest when eligible)
- **"Which repair method applies to this VM before I start"** → `Compute/Scripts/Get-AzureVMBootRepairAudit.ps1` — computes a recommended path from encryption/generation/managed-disk state
- **"Site Recovery says no recovery point available for the VM"** → `SiteRecovery/SiteRecovery-B.md` Triage — check the exact error ID (153007 vs. 153006) before picking a fix, they're unrelated failure domains
- **"DR failover to a recovery point failed with BookmarkNotFound"** → `SiteRecovery/SiteRecovery-B.md` Fix 5 — the recovery point predates a disk tier/SKU change, pick a newer one
- **"We failed over for a DR test/real event, now what"** → `SiteRecovery/SiteRecovery-A.md` How It Works (four-stage state machine) — reprotection (Stage 2) is mandatory and does not happen automatically
- **"Is this a Backup vault issue or a Site Recovery vault issue"** → check both `Backup/AzureBackup-B.md` and `SiteRecovery/SiteRecovery-B.md` Triage — same vault, completely different failure domains (snapshot backup vs. continuous replication)
- **"Fleet-wide DR replication health check before a client review or audit"** → `SiteRecovery/Scripts/Get-SiteRecoveryHealth.ps1`
- **"On-prem VMware replication to Azure looks dead"** → `OnPremDR/OnPremDR-B.md` Triage — confirm Classic vs. Modernized first, then check the ASR replication appliance heartbeat
- **"Hyper-V VM has been stuck Critical for days with no active job"** → `OnPremDR/OnPremDR-B.md` Fix 5 — likely a non-recoverable error, which gets zero automatic retry by design
- **"DR replication broke right after a proxy/firewall change"** → `OnPremDR/OnPremDR-B.md` Fix 7 — Hyper-V has no outbound authentication-proxy support at all, unlike VMware Modernized
- **"Client is still on the old VMware Configuration Server setup"** → `OnPremDR/OnPremDR-B.md` Fix 1 — flag for migration; Classic retires 30 Mar 2026 and new-replication enablement is already blocked
- **"Fleet-wide on-prem DR health check across VMware and Hyper-V vaults"** → `OnPremDR/Scripts/Get-OnPremDRHealth.ps1`
- **"I have Owner/Contributor on the storage account but get 403 reading a blob"** → `StorageAccounts/StorageAccounts-B.md` Fix 5 — control-plane RBAC does not grant data-plane access, a separate `Storage Blob Data *` role is required
- **"Our script's storage connection string stopped working after a security review"** → `StorageAccounts/StorageAccounts-B.md` Fix 2 — check `AllowSharedKeyAccess` first
- **"The blob/container the client swears existed is just gone"** → `StorageAccounts/StorageAccounts-B.md` Fix 6 — check soft delete before treating as data loss
- **"Fleet-wide storage account access-posture check before a handoff or security review"** → `StorageAccounts/Scripts/Get-AzureStorageAccountHealth.ps1 -AllAccounts`

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
