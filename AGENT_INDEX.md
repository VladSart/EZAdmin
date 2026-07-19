# EZAdmin — Agent Index & Master Routing

> **For AI agents:** Read this file first. It tells you where to go, how to respond, and what to check across modules before answering any question.

---

## Universal Response Format

Every response in this repo follows three layers. **Never skip any layer.**

### Layer 1 — Hotfix Mode
> Used when: someone needs this fixed NOW. Client is down, ticket is open.

Structure:
1. **Triage** — 3–5 commands to confirm the break in under 60 seconds
2. **Fix** — ordered steps, highest-probability cause first
3. **Validate** — proof commands that confirm it's actually fixed

Rules: No theory. No history. Every command has a reason. Strong "if X → do Y" language.

---

### Layer 2 — Deep Dive Mode
> Used when: understanding the system, writing a post-mortem, building something, or the hotfix didn't work.

Structure:
1. Full dependency chain (what must be true for this to work)
2. How the system actually works in this environment
3. Symptom → cause map
4. All remediation paths with rollback notes
5. Community findings (Reddit r/sysadmin, r/Intune, r/Office365, Spiceworks, MS Tech Community)
6. Evidence pack for escalation

Rules: Explain why, not just what. Include architecture. Flag policy override risks (Intune/GPO always win).

---

### Layer 3 — Learning Pointers
> Always appended after any Hotfix or Deep Dive response.

Format: 3–6 bullet points. Each one is a concept, topic, or resource tied directly to what just happened — not generic study advice. Goal: you get better every time you close a ticket.

---

## Domain Map — Where to Route

| Topic | Primary Folder | Also Check |
|-------|---------------|------------|
| DFS Namespace failures, referrals, access | `DFS/` | `EntraID/`, `Windows/` |
| DFS Replication backlog, SYSVOL, conflicts | `DFS/` | `Windows/` |
| Intune enrollment failures | `Intune/` | `Autopilot/`, `EntraID/` |
| Intune policy conflicts, compliance not applying | `Intune/` | `EntraID/`, `Windows/` |
| Endpoint analytics (Startup performance / App reliability / Work from anywhere scoring) | `Intune/` | `Autopilot/` (deployment profile assignment), `Windows/` (WUfB/feature updates) |
| Autopilot enrollment, hybrid join, hash upload | `Autopilot/` | `Intune/`, `EntraID/` |
| Windows Autopilot device preparation (APDP) — Entra-join-only enrollment mode | `Autopilot/` | `Intune/`, `EntraID/` |
| Entra ID join, PRT issues, device registration | `EntraID/` | `Intune/`, `Security/ConditionalAccess/` |
| Conditional Access policy conflicts, CA failures | `Security/ConditionalAccess/` | `EntraID/`, `Intune/` |
| Hybrid join (HAADJ), Entra Connect Sync (legacy on-prem sync-engine model) | `EntraID/` | `Security/ConditionalAccess/` |
| Entra Cloud Sync (provisioning-agent model — gMSA, multi-agent HA, disconnected forests, Group Provisioning to AD DS) | `EntraID/` | `ActiveDirectory/` (gMSA/schema prerequisites live in on-prem AD) |
| Windows Update, WfUB, WSUS conflicts | `Windows/` | `Intune/` |
| BitLocker, key escrow, recovery | `Windows/` | `Intune/`, `EntraID/` |
| Power Automate flows, connectors, licensing | `PowerAutomate/` | `M365/SharePoint-OneDrive/`, `EntraID/` |
| Power Automate Desktop (RPA) — machine registration/direct connectivity (gateways retired), attended/unattended session model, UIFlowService, machine groups, Process/Unattended RPA capacity licensing | `PowerAutomate/Desktop-RPA/` | `PowerAutomate/Troubleshooting/` (cloud-flow-side ownership/connector auth — a separate failure domain from the machine runtime), `Intune/` (if PAD is deployed via Intune, not a runtime issue) |
| SharePoint site creation, permissions via automation | `PowerAutomate/SharePoint/` | `EntraID/`, `M365/SharePoint-OneDrive/` |
| Exchange Online mail flow, rules, hybrid | `M365/Exchange/` | `EntraID/` |
| Outlook desktop client (classic vs. New Outlook, Autodiscover, profile/OST, connection status, credential loops) | `M365/Exchange/` | `EntraID/` (auth/token layer), `Security/ConditionalAccess/` (legacy-auth blocks surfacing as client sign-in loops) |
| SharePoint/OneDrive sync, permissions, migration | `M365/SharePoint-OneDrive/` | `PowerAutomate/` |
| Teams calling, policies, devices | `M365/Teams/` | `EntraID/` |
| M365 licensing, group-based, service plans | `M365/Licensing/` | `EntraID/` |
| Defender for Endpoint onboarding, ASR, alerts | `Security/Defender/` | `Intune/`, `EntraID/` |
| Defender: Cloud Apps (MDA), Identity (MDI), Vuln Mgmt, Network Protection, WDAC | `Security/Defender/` | `Intune/`, `EntraID/` |
| Attack Simulation Training (phishing simulations, training assignment, MDO Plan 2) | `Security/Defender/` | `M365/Exchange/`, `EntraID/` |
| Purview DLP, sensitivity labels, insider risk, eDiscovery | `Security/Purview/` | `M365/Exchange/`, `M365/SharePoint-OneDrive/` |
| Communication Compliance (message review policies — no PowerShell for policy CRUD) | `Security/Purview/` | `M365/Exchange/`, `M365/Teams/`, `EntraID/` |
| Information Barriers (segment/policy design, Teams/SharePoint/OneDrive communication restrictions, Address Book Policy conflicts, segment overlap, FwdSync propagation delay) | `Security/Purview/` | `M365/Teams/` (primary enforcement surface), `M365/SharePoint-OneDrive/`, `EntraID/` (attribute source for segment filters), `M365/Exchange/` (Address Book Policy conflict, and the separate ethical-wall mechanism for mail flow) |
| Microsoft Priva — Privacy Risk Management (data overexposure/transfer policies, Test-mode default, Alert→Issue→Remediation) and Subject Rights Requests (Access/Export/Tagged list/Delete, portal-only, no PowerShell equivalent, data-residency exclusions) | `Security/Purview/` | `Security/Purview/DLP-Policy-A.md` (related but distinct — loss-prevention blocking, not proactive risk visibility), `Security/Purview/RetentionLabels-A.md` (regulatory records/holds must be checked before an SRR Delete request), `Security/Defender/DefenderForCloud-A.md` (Secure Score is a Defender for Cloud CSPM concept, distinct from Priva) |
| Microsoft Purview Audit (Unified Audit Log) — Standard vs. Premium retention/licensing, the 100/5,000/50,000 `Search-UnifiedAuditLog` result tiers, mailbox audit bypass, Management Activity API for SIEM-scale ingestion | `Security/Purview/` | `Security/Purview/Priva-A.md`, `Security/Purview/Insider-Risk-A.md`, `Security/Purview/CommunicationCompliance-A.md` (all three depend on the audit log as a hard prerequisite — this is the foundational layer under them, not a peer feature), `EntraID/` (Entra ID sign-in/audit logs are a separate, Entra-native log — not the same store) |
| Graph API queries, automation, reporting | `EntraID/Graph/` | Any domain using Graph |
| macOS Intune enrollment, ADE, shell scripts | `macOS/` | `Intune/`, `EntraID/` |
| Entra ID PIM (directory roles/groups), MFA methods, SSPR, Identity Protection risk | `EntraID/` | `Security/ConditionalAccess/` |
| PIM for Azure Resources — JIT activation of Azure RBAC roles (Owner/Contributor/UAA/custom) at management group/subscription/RG/resource scope, via Azure Resource Manager API and `Az.Resources` (not Microsoft Graph) | `EntraID/` | `EntraID/` PIM for Directory Roles/Groups (shared portal shell, otherwise architecturally unrelated — different API, module, and permission model), general Azure RBAC (static/permanent assignments coexist with and can mask PIM-managed ones) |
| Entra Domain Services (managed domain), App Proxy, Access Packages | `EntraID/` | `Azure/`, `Security/ConditionalAccess/` |
| GDAP (Granular Delegated Admin Privileges) — CSP/partner relationship access, security group role delegation | `EntraID/` | Partner Center (external) |
| Lifecycle Workflows — Entra ID Governance JML task automation (enable/schedule two-switch model, 3-day catch-up window, AD DS-synced Enable/Disable/Delete task prerequisites, Logic Apps extensibility) | `EntraID/` | HR-driven provisioning (external, creates the account), `EntraID/` Access Reviews (recertification, distinct), `EntraID/` PIM (role activation, distinct) |
| Windows Hello for Business, LAPS, Endpoint Privilege Mgmt (EPM) | `EntraID/` (WHfB) / `Intune/` (LAPS, EPM) | `Security/ConditionalAccess/` |
| Azure Virtual Desktop (session hosts, FSLogix, App Attach) | `Azure/AVD/` | `Intune/`, `EntraID/`, `Windows/` |
| Azure Files (SMB/NFS shares, identity auth, Azure File Sync) | `Azure/Files/` | `DFS/`, `EntraID/` |
| Windows 365 Cloud PC (provisioning, ANC, resize/reprovision) | `Azure/Windows365/` | `Azure/AVD/`, `Intune/`, `M365/Licensing/` |
| Copilot for Microsoft 365 (licensing, data access, plugins) | `M365/Copilot/` | `M365/Licensing/`, `Security/Purview/` |
| Universal Print (queues, driverless printing) | `M365/UniversalPrint/` | `Intune/`, `EntraID/` |
| Teams Rooms devices, calling, meeting policies | `M365/Teams/` | `Intune/`, `EntraID/` |
| DFS Access-Based Enumeration, referral ordering / site costing | `DFS/` | `EntraID/`, `Windows/` |
| Windows Always On VPN, AppLocker, Credential Guard/VBS, Kerberos/NTLM | `Windows/` | `EntraID/`, `Security/ConditionalAccess/` |
| Intune Remote Help (helper/sharer remote assistance, tenant enablement, RBAC combo, licensing-both-sides, remote-launch notification delivery, elevation/unattended/CA) | `Intune/` | `Azure/Windows365/` (distinct connection stack — Remote Help can run *inside* a Cloud PC session but doesn't connect *to* one), `EntraID/` (Conditional Access service principal) — explicitly distinct from Graph's `remoteAssistancePartner` (third-party ISV onboarding) |
| Microsoft 365 Backup (SharePoint/OneDrive/Exchange protection policies, restore points, coverage gaps) | `M365/Backup/` | `Security/Purview/`, `M365/SharePoint-OneDrive/`, `M365/Exchange/`, `EntraID/` |
| Entra Verified ID (verifiable credentials — issuance/verification, DID/domain linkage, Admin API) | `EntraID/` | N/A (own Admin API, not Microsoft Graph) |
| SharePoint Advanced Management (SAM) — Restricted Access Control, Restricted Content Discovery, Site Lifecycle Management, Data Access Governance reports | `M365/SharePoint-OneDrive/` | `Security/Purview/` (sensitivity labels), `Security/ConditionalAccess/` (auth context, idle sign-out scoping) |
| Microsoft Sentinel data connectors (AMA/DCR, API/service, diagnostic-settings), ingestion gaps, workspace quota | `Security/Sentinel/` | `Security/Defender/` (XDR alert sources), `EntraID/` (sign-in/audit log diagnostic settings), `M365/Exchange/` (Unified Audit Log for O365 connector) |
| Microsoft Sentinel analytics rules & incident tuning (rule kinds, AUTO DISABLED, entity mapping, incident grouping, automation rules, false-positive tuning, Azure-vs-Defender-portal divergence) | `Security/Sentinel/` | `Security/Sentinel/` DataConnectors topic (data must be flowing before a rule can fire), `Security/Defender/` (Microsoft security rule kind sources) |
| Microsoft Sentinel Logic Apps playbooks / SOAR execution (automation rule → playbook handoff, permission/trigger-type model, connector auth, 3-layer throttling) | `Security/Sentinel/` | `Security/Sentinel/` AnalyticsRules topic (an incident/alert must exist before an automation rule can fire), `Security/Sentinel/` DataConnectors topic |
| On-prem AD DS replication (FSMO, repadmin/dcdiag, KCC/topology, lingering objects) | `ActiveDirectory/` | `DFS/` (SYSVOL is a separate replication system on the same DCs), `EntraID/` (Entra Connect sync depends on healthy on-prem AD) |
| AD-integrated DNS (zone replication scope, DC Locator SRV records, scavenging/aging, forwarders, split-brain) | `ActiveDirectory/` | `Windows/` (client-side DNS resolver config), `ActiveDirectory/` Replication topic (SRV records are a hard prerequisite for replication) |
| Azure Arc-enabled servers (Connected Machine agent onboarding, connectivity/heartbeat, 45-90 day identity expiry) | `Azure/Arc/` | `Security/Sentinel/` (Arc is a prerequisite for non-Azure server data connectors), `Security/Defender/` (CSPM/MDE on non-Azure servers), `EntraID/` (at-scale onboarding service principal credentials) |
| Microsoft Defender for Cloud (CSPM — Secure Score, recommendations, multicloud AWS/GCP connectors, agentless scanning, attack path analysis, regulatory compliance) | `Security/Defender/` | `Azure/Arc/` (on-prem/hybrid servers must be Arc-connected first), `Security/Sentinel/` (Defender for Cloud alerts feed Sentinel via data connector), `EntraID/` (subscription/tenant-scoped RBAC for Security Admin/Reader roles) |
| Azure Backup (Recovery Services Vault — Azure VM disk backup, recovery points, soft delete, immutability) | `Azure/Backup/` | `M365/Backup/` (distinct — SaaS data, not VM disks), `Azure/AVD/` (session hosts are VMs and use this same service) |
| Workload identity federation (GitHub Actions/Azure DevOps/Kubernetes OIDC trust, secretless CI/CD auth) + Conditional Access for workload identities (direct service-principal targeting, risk-based blocking, Workload Identities Premium) | `EntraID/` | `Security/ConditionalAccess/` (same policy engine, workload-identity-specific constraints), `EntraID/` AppRegistrations topic (secret/cert-based auth this migrates away from) |
| Defender for Office 365 Safe Links (URL rewrite/time-of-click) and Safe Attachments (detonation) — policy precedence, Teams/Office app coverage, SharePoint/OneDrive/Teams separate toggle | `Security/Defender/` | `M365/Exchange/` (runs downstream of EOP anti-spam/anti-malware), `Security/Defender/` AttackSimulationTraining topic (training tool, not real-time protection) |
| Microsoft Entra Access Reviews (periodic recertification of group/app/access-package membership and Entra/Azure role assignments) | `EntraID/` | `EntraID/` PIM topic (role activation vs. periodic role recertification are distinct), `EntraID/` AccessPackages topic (entitlement management delivery vs. its own review lifecycle) |
| AD FS / Web Application Proxy (on-prem claims-based federation for M365/SaaS — token-signing/decrypting certificate lifecycle, relying party trusts, claims rules, WAP proxy trust) | `ActiveDirectory/` | `EntraID/` (federation vs. Password Hash Sync/Pass-through Auth as the alternative identity model; HybridJoin/PRT-Issues topics for the post-token device auth path), `Security/ConditionalAccess/` (evaluated after AD FS issues a valid token) |
| Azure Key Vault (RBAC vs. legacy Access Policy authorization, network/private-endpoint access denials, soft-delete and purge-protection recovery, certificate auto-rotation) | `Azure/KeyVault/` | `EntraID/` AppRegistrations topic (client secrets as an alternative credential store), `EntraID/` WorkloadIdentity topic (federated credentials as a secretless alternative), `Security/Sentinel/` DataConnectors (vault diagnostic logs as a SIEM source) |
| Azure hybrid connectivity — VPN Gateway site-to-site (IPsec/BGP) and ExpressRoute (circuit provisioning, eBGP peering, customer/provider/Microsoft three-zone model) | `Azure/Networking/` | `Azure/AVD/` AVD-Connectivity topic (NSG rules scoped to AVD reachability specifically, not general hybrid connectivity), `Windows/` AlwaysOnVPN topic (a different, client-to-network VPN technology, not site-to-site) |
| Network Security Groups (general-purpose) — rule priority/evaluation order, dual subnet+NIC-level enforcement, service tags, Application Security Groups, Security Admin Rules via Azure Virtual Network Manager, NSG flow log retirement (Sept 30, 2027) | `Azure/Networking/` | `Azure/Networking/` HybridConnectivity topic (NSG as the shared final data-plane checkpoint both VPN and ExpressRoute converge on), `Azure/AVD/` AVD-Connectivity topic (NSG guidance scoped to AVD reachability specifically) |
| Azure Virtual Network Manager (AVNM) — centralized network governance: scope/delegation model, static vs. dynamic (Azure Policy-based) network groups, mesh/hub-and-spoke connectivity configurations via the connected-group construct, goal-state deployment model (redeploying one config can silently drop another) | `Azure/Networking/` | `Azure/Networking/` NSG topic (Security Admin Rules — a different AVNM configuration type, evaluated before NSGs, fully documented there rather than in AVNM-A.md), `Azure/Networking/` HybridConnectivity topic (the peerings/gateways AVNM's hub-and-spoke configurations ultimately provision) |
| Azure Automation — managed identity authentication and the 30-Sept-2023 Run As account retirement, runbook job/Azure sandbox execution limits, extension-based Hybrid Runbook Worker connectivity (agent-based retired 31 Aug 2024); explicitly excludes Azure Update Manager, now its own dedicated topic below (Automation's own legacy Update Management is retired) | `Azure/Automation/` | `Azure/KeyVault/` (a common Automation target resource — Automation is absent from Key Vault's trusted-services firewall bypass), `Azure/Arc/` (non-Azure Hybrid Runbook Workers require a healthy Arc agent first), `EntraID/` AppRegistrations and WorkloadIdentity topics (alternative/complementary identity models to Automation's own managed identity) |
| Azure Update Manager — native, non-Automation-dependent patch management for Azure VMs and Arc-enabled servers: patch-extension lifecycle (Windows/Linux, lazy first-use install), on-demand vs. periodic vs. scheduled patching, maintenance configuration + configuration assignment as two independent resources (assignments don't survive an RG/subscription move), maintenance-window reboot-reservation arithmetic, short Resource Graph retention (7/30 days) | `Azure/UpdateManager/` | `Azure/Automation/` (the retired legacy Update Management solution this replaces — different architecture entirely), `Azure/Arc/` (hard prerequisite for patching non-Azure machines), `Windows/` Windows Update topics (the underlying WUA/WSUS client this service drives, not replaces) |
| File Server Resource Manager (FSRM) — quota management (hard/soft, auto-apply, template propagation, nested-quota inheritance), file screening (file groups/templates/screens/exceptions, the Office .tmp save-then-rename gotcha), File Classification Infrastructure (USN Change Journal real-time vs. scheduled classification trade-off), file management jobs, storage reports | `DFS/` | `DFS/` Namespace and Replication topics (same file servers, architecturally separate role with no namespace/replication awareness), `Windows/` SMB topic (underlying share/NTFS permission layer FSRM sits on top of) |
| Azure Policy (resource governance/compliance — definition/initiative/assignment scope model, deny/denyAction/audit/auditIfNotExists/deployIfNotExists/modify effects with NO cross-assignment precedence, remediation task + managed-identity RBAC dependency, exemptions vs. notScopes, phased Azure Blueprints retirement beginning 31 July 2026) | `Azure/Policy/` | `Azure/Networking/` AVNM topic (dynamic network group membership uses Azure Policy-based conditions), `Security/Defender/` DefenderForCloud topic (regulatory compliance standards are themselves delivered as policy initiatives), `ActiveDirectory/` GroupPolicy topic (a different, unrelated "policy" system — same word, no shared architecture) |
| Azure Monitor Agent / Log Analytics (the telemetry pipeline underneath most of this repo's other Azure/Security monitoring topics — managed-identity/IMDS authentication, zero agent-side default config so collection is 100% Data Collection Rule-driven, Private-Link-only Data Collection Endpoints with a hard same-region requirement, Analytics/Basic/Auxiliary table-plan cost and query trade-offs; retired legacy Log Analytics/MMA/OMS agent backend shut down 2 Mar 2026 — any machine still on it has sent zero data since that date) | `Azure/Monitor/` | `Security/Sentinel/` DataConnectors topic (consumes data landed by this pipeline, but connector onboarding itself is documented there), `Security/Defender/` DefenderForCloud topic (its own legacy MMA-based auto-provisioning is a separate, mostly-superseded path from this pipeline), `Azure/KeyVault/` and `Azure/Networking/` NSG topics (send data via Diagnostic Settings directly to a workspace — a different ingestion path than the agent/DCR model documented here) |
| Azure Virtual WAN (Microsoft-managed global transit network — Basic/Standard SKU as a one-way capability upgrade, virtual hub with `ProvisioningState`/`RoutingState` as independent health signals, connection association/propagation via route tables and labels, Routing Intent/Routing Policies whose single biggest gotcha is silently taking over the Default route table and every connection's association on enable, secured virtual hub via Firewall Manager, VPN/ExpressRoute gateways sharing a fixed ASN 65515 inside every hub) | `Azure/Networking/` | `Azure/Networking/` HybridConnectivity topic (the same VPN/ExpressRoute protocols, but in the traditional self-managed hub-VNet model with different ASN handling and limits — not interchangeable with vWAN's embedded gateways), `Azure/Networking/` AVNM topic (can, in preview, target a Virtual WAN hub as its "hub" type — a governance layer orchestrating Virtual WAN, not a duplicate of its native routing model), `Azure/Networking/` NSG topic (still the filtering layer on spoke VNet subnets; a vWAN hub itself carries no customer-configurable NSG) |
| LSA Protection (RunAsPPL) — VBS-independent Protected Process Light isolation for lsass.exe, available since Windows 8.1/Server 2012 R2 with no SLAT/TPM/Hyper-V requirement; Windows 11 22H2+ silent auto-enablement writes no registry key (WinInit Event ID 12 is the only ground truth), Microsoft-signature + SDL-compliance gate for LSA plug-ins, audit (3065/3066) vs. enforcement (3033/3063) CodeIntegrity events, UEFI-locked configurations requiring the opt-out EFI tool to reverse | `Windows/` | `Windows/` VBS-CredentialGuard topic (complementary but independently-gated — a device can have either, both, or neither; do not conflate `lsaiso.exe`/HVCI troubleshooting with this topic), `Intune/` (Custom OMA-URI profile delivery path) |
| Microsoft Cloud PKI — fully cloud-hosted PKI for Intune (no NDES/Connector/on-prem CA), native and BYOCA (bring-your-own-CA anchored to a private root via CSR-sign-upload) deployment models, Microsoft-hosted SCEP registration authority, HSM- vs. software-backed keys, hard 3-CA-per-tenant capacity cap, bundled into Microsoft 365 E5 from 1 July 2026 | `Intune/` | `Intune/` Certificates topic (the older, architecturally opposite on-prem NDES/PKCS/Connector model — same end result, zero shared troubleshooting surface), `Azure/KeyVault/` (unrelated — Key Vault issues certs for Azure resources, not Intune-managed endpoints) |
| Microsoft 365 Apps deployment & update channels — Click-to-Run install architecture, Office Deployment Tool, Current/Monthly Enterprise/Semi-Annual Enterprise channel precedence (GPO > ODT > admin center > default), Shared Computer Activation, and the July 2026 SAC/MEC cadence unification | `M365/Apps/` | `M365/Exchange/` Outlook-Client topic (assumes this topic's Click-to-Run layer is healthy and covers Outlook-specific profile/Autodiscover issues only), `M365/Licensing/` (Entra ID license assignment, distinct from client-side activation) |
| Power Apps environments & Dataverse database administration (environment creation license/admin-role/capacity gates, the irreversible "Enable Dynamics 365 apps" database-creation decision, the three-portal — admin center/maker/Power Automate — independently-computed environment visibility model, solution import missing-dependency resolution for managed/unmanaged/deprecated components) | `PowerAutomate/PowerApps/` | `PowerAutomate/` flow-execution topics (a distinct failure domain — connector auth/throttling/DLP issues live there, not here), `EntraID/` (Entra ID group teams vs. legacy Dataverse owner teams for portal visibility) |
| Microsoft Secure Score (tenant-wide, security.microsoft.com/securescore — Identity/Device/Apps/Data category scoring, license-agnostic maxScore model, 24-48h/weekly/monthly refresh cadence variance, manual "resolved through third party"/"alternate mitigation" status overrides, Unified RBAC vs. legacy-Entra-role-gated Graph API access) | `Security/Defender/` | `Security/Defender/` DefenderForCloud topic (same name, entirely separate Azure-resource CSPM score via `Az.Security` — zero data overlap), `Security/Defender/` DefenderVulnMgmt topic (owns the Device category's underlying TVM exposure-score engine; this topic covers only how it rolls into the tenant score), `Security/ConditionalAccess/` (security-defaults-vs-custom-CA-policy overlap for the Identity category's MFA/legacy-auth controls) |

---

## Cross-Domain Rules

Before answering any identity-related question, check `EntraID/` — almost everything touches identity.

Before answering any device management question, check `Intune/` — policies flow from there.

Before answering any security/access question, check `Security/ConditionalAccess/` — CA overrides most other access logic.

If PowerShell is needed for a fix, look for an existing script in the relevant `Scripts/` folder first.

---

## Technology Ranking by MSP Frequency

Built from real-world MSP ticket patterns. Build order = priority order.

| Rank | Domain | Why it's here |
|------|--------|---------------|
| 1 | DFS | SMB/enterprise staple; replication failures = user impact immediately |
| 2 | Power Automate | SharePoint automation is in every org; permission flows break constantly |
| 3 | Intune | Every managed device touches this; policy conflicts are daily |
| 4 | Windows Update / WfUB | Perpetual pain; WSUS conflicts, update rings, dual-scan |
| 5 | Entra ID + Hybrid Join | Identity is the dependency for everything |
| 6 | Conditional Access | Policies break access silently; hardest to diagnose under pressure |
| 7 | Autopilot | Enrollment failures cost hours; TPM, hash, network all in play |
| 8 | Exchange Online | Mail flow rules, hybrid coexistence, shared mailboxes |
| 9 | BitLocker | Recovery key gaps, escrow failures discovered at worst time |
| 10 | SharePoint/OneDrive | Sync client issues, permission inheritance breaks, migration |
| 11 | Defender for Endpoint | ASR rules blocking legit apps, onboarding gaps |
| 12 | Teams | Calling plans, device policies, federation |
| 13 | Azure AD Connect / Entra Connect | Sync errors, attribute conflicts, password hash |
| 14 | M365 Licensing | Group-based licensing failures, service plan conflicts |
| 15 | macOS via Intune | ADE enrollment, profile delivery, shell script failures |
| 16 | Active Directory (on-prem AD DS) | Every other domain here depends on it; replication/FSMO failures cascade into DFS, hybrid join, Kerberos auth |

---

## Repo Conventions

- `_AGENT.md` in every folder — agent-specific instructions for that domain
- `Troubleshooting/Topic/Topic-B.md` — Hotfix runbook
- `Troubleshooting/Topic/Topic-A.md` — Deep Dive reference
- `Scripts/` — PowerShell scripts, named with `Verb-Noun.ps1` pattern
- All scripts follow: Preflight → Detect → Execute → Validate → Report

---

## Learning Pointers Trigger

After every resolved issue, append this section to your response:

```
## 🎓 Learning Pointers
Based on what just happened, here are things worth exploring:
- [concept] — why it matters here
- [tool/cmdlet] — what it does and when you'd reach for it
- [community resource] — thread/doc that goes deep on this edge case
```
