# Entra ID — Agent Instructions

## What's in this folder

Microsoft Entra ID (formerly Azure Active Directory) — the identity foundation everything else depends on.

Covers:
- **Device join** — Entra join, Hybrid join, PRT (Primary Refresh Token) issues
- **User identity** — UPN conflicts, sync issues, guest accounts, B2B
- **Conditional Access** — policy design, break-glass, legacy auth, named locations
- **App registrations + service principals** — OAuth flows, client secrets, API permissions
- **Workload identity federation + Conditional Access for workload identities** — federated credentials (GitHub Actions/Azure DevOps/Kubernetes OIDC trust), CA policies scoped to service principals, workload identity risk (leaked credentials/anomalous token)
- **Entra Connect Sync** — attribute conflicts, password hash sync, staging mode (legacy on-prem sync-engine model)
- **Entra Cloud Sync** — lightweight provisioning-agent model, gMSA auth, multi-agent HA, disconnected forest sync, quarantine handling, and Group Provisioning to AD DS (the reverse direction) — architecturally distinct from Entra Connect Sync, see `Troubleshooting/CloudSync-B.md`/`-A.md`
- **Privileged Identity Management (PIM) for Directory Roles/Groups** — role/group activation via Microsoft Graph
- **Privileged Identity Management (PIM) for Azure Resources** — JIT activation of Azure RBAC roles (Owner/Contributor/UAA/custom) at management group/subscription/RG/resource scope, via the Azure Resource Manager API and `Az.Resources` — architecturally distinct from directory-role PIM despite sharing a portal shell, see `Troubleshooting/PIMAzureResources-B.md`/`-A.md`
- **Access Reviews** — periodic recertification of group/app/access-package membership and Entra/Azure role assignments (distinct from PIM activation and from entitlement management delivery)
- **Lifecycle Workflows** — Entra ID Governance joiner-mover-leaver (JML) task automation (welcome email, license/group assignment, account enable/disable/delete, Temporary Access Pass, custom Logic App tasks) — distinct from HR-driven provisioning (creates the account), Access Reviews (recertification), and PIM (role activation)
- **Graph API** — scripting against Entra, batch queries, permissions model
- **Certificate-Based Authentication (CBA)** — native (non-ADFS) X.509 certificate sign-in, CA trust chain, CRL revocation checking, certificate-to-user binding (high-affinity vs. legacy low-affinity), authentication strength mapping — distinct from Windows Hello for Business (device-bound key/cert, see `Troubleshooting/WHfB-B.md`/`-A.md`) and from Intune Cloud PKI (certificate *issuance*, not sign-in validation, see `Intune/Troubleshooting/CloudPKI-A.md`)
- **Restricted Management Administrative Units (RMAU)** — the special-cased AU (`isMemberManagementRestricted = true`) that blocks even Global Administrator/Privileged Role Administrator from directly modifying member Users/Devices/Security Groups without an RMAU-scoped role assignment; direct-membership-only (no cascade), permanent restricted setting at creation, hard incompatibility with PIM/Entitlement Management/Lifecycle Workflows/Access Reviews — distinct from a regular (non-restricted) AU, which only scopes role applicability without blocking tenant-scoped admins
- **External MFA (formerly External Authentication Methods/EAM)** — delegating the MFA second factor entirely to a non-Microsoft OIDC provider (e.g., Cisco Duo); the two-role admin-consent gate (Authentication Policy Administrator creates the method, only Privileged Role Administrator can consent the provider's app), the hard incompatibility with authentication-strength grant controls, acr/amr claim type-mapping as the actual "was this really MFA" trust check, and Custom-Control-to-External-MFA migration via mutually exclusive parallel Conditional Access policies — distinct from native Microsoft methods (see `Troubleshooting/MFA-B.md`/`-A.md`), Passkeys (see `Troubleshooting/Passkeys-B.md`/`-A.md`), and cross-tenant B2B MFA trust (see `Security/ConditionalAccess/`)
- **Enterprise Application (SCIM) Provisioning** — outbound automatic user/group provisioning from Entra ID to third-party SaaS apps via SCIM 2.0 (or the on-prem provisioning agent for LDAP/SQL/REST-SOAP/PowerShell/ECMA targets); assignment-based vs. attribute-based scoping (nested groups never read, only direct members), the matching-attribute join key, initial-vs-incremental cycle/watermark mechanics, quarantine/escrow thresholds, and disable-vs-delete deprovisioning — architecturally the same provisioning engine as Entra Cloud Sync but the reverse direction and a distinct configuration surface, see `Troubleshooting/EnterpriseAppProvisioning-B.md`/`-A.md`
- **Microsoft Entra Suite / Global Secure Access licensing and cost allocation** — the P1/P2-mandatory-base-plus-Suite licensing stack, standalone Internet Access/Private Access add-ons, the guest Monthly Active User (MAU) billing model (and why the free-50K-external-MAU allowance doesn't cover GSA/Governance for guests), the feature-to-license-tier mapping, the remote-network 50-combined-license floor, and a cohort-based Suite-vs-standalone-vs-base-only allocation framework — distinct from GSA client/connector technical troubleshooting (see `Troubleshooting/GlobalSecureAccess-B.md`/`-A.md`), see `Troubleshooting/EntraSuiteLicensing-B.md`/`-A.md`
- **Microsoft Entra Agent ID** — the identity/security framework (GA April 2026) extending Entra's identity, access, and governance model to AI agents as first-class nonhuman identities: the four-object model (agent identity blueprint → optional blueprint principal for multitenant agents → agent identity → optional 1:1 agent user), the Owner/Sponsor/Manager administrative model (a deliberate separation of technical vs. business-accountability vs. org-hierarchy concerns, distinct from and layered on top of ordinary RBAC roles), the documented Agent ID Administrator/AI Administrator role overlap for full agent-identity CRUD, entitlement-management access packages requiring an explicit agent-identity requestor scope, and Conditional Access/Identity Protection extension to agents (Agent 365 licensing gated) — architecturally distinct from the M365 admin center **Agent Registry** catalog/publish/governance layer covered in `M365/Copilot/AgentGovernance-A.md`/`-B.md` (an agent can be fully Registry-approved with no Entra Agent ID, or vice versa — the Registry's "Shadow agent" risk fires on either gap), see `Troubleshooting/AgentID-B.md`/`-A.md`
- **App Consent Policies & Illicit Consent Grant Attacks** — the two-layer consent-governance model (tenant-wide `authorizationPolicy` default plus built-in/custom `permissionGrantPolicies` with include/exclude condition sets, evaluated as a logical OR across every policy a user holds), the admin consent workflow (reviewer *listing* ≠ reviewer *RBAC* — only Global Administrator/Privileged Role Administrator can approve Microsoft Graph application-permission requests), and detection/remediation of illicit consent grant / OAuth-phishing attacks (survives password resets and MFA changes since the attacker never needed the victim's credentials) — distinct from `Troubleshooting/AppRegistrations-A.md`/`-B.md` (assumes consent already exists and something else is broken); see `Troubleshooting/AppConsentPolicies-B.md`/`-A.md`
- **Administrative Units (regular, non-restricted)** — the base delegation-scoping model: `directoryScopeId`-based AU-scoped role assignment (Authentication/Groups/Helpdesk/License/Password/User Administrator and others), the "adding a group to an AU manages the group, never its members" rule, static vs. dynamic (rule-based, single-object-type, P1-per-member) membership, and the anti-escalation carve-out blocking AU-scoped Helpdesk/Password/User Administrator from acting on any target who holds any directory role at all — architecturally the same role-assignment mechanism the existing **Restricted Management Administrative Unit (RMAU)** topic (`Troubleshooting/RestrictedManagementAU-B.md`/`-A.md`) builds its hard tenant-wide-role block on top of; see `Troubleshooting/AdministrativeUnits-B.md`/`-A.md` for the regular-AU mechanics, and go to the RMAU files directly for anything involving `isMemberManagementRestricted`
- **Microsoft Graph Data Connect (MGDC)** — the bulk, at-scale Microsoft 365 data-export service (into Microsoft Fabric/Azure Synapse/Azure Data Factory) for enterprise analytics; the granular dataset+column+user+sink consent model (distinct from Graph API's entity-level grant/deny), the five-stage onboarding chain (tenant toggle → app registration with a non-guest mailbox+E5-licensed owner → dataset/column scope registration → Global-Admin-only, self-approval-blocked consent → pipeline run), the `Microsoft.GraphServices` resource-provider billing gate, per-run (not per-row) fraction-rounded billing, the single-Office-region-per-pipeline constraint for multi-geo tenants, and the same-Entra-tenant-only boundary with no cross-tenant support — architecturally unrelated to the transactional Microsoft Graph API covered in `Graph/GraphAPI-BatchOperations-A.md`/`-B.md` despite accessing the same underlying data; see `Graph/GraphDataConnect-B.md`/`-A.md`
- **Entra External ID for Customers (CIAM) — JIT Password Migration** — migrating end-user credentials from a legacy identity provider (or a retiring Azure AD B2C tenant) to an External ID *for customers* tenant without a bulk password reset, via a customer-hosted `OnPasswordSubmit` custom authentication extension (RSA-JWE-encrypted password payload, Key-Vault-held private key, four response actions — MigratePassword/UpdatePassword/Retry/Block) wired in through a listener policy; covers the `disableStrongPassword` time-boxed complexity-coexistence trade-off, throttling/timeout tuning for large migration waves, and the `keyId`/`tokenEncryptionKeyId` consistency requirement — a completely different tenant configuration and topic from workforce B2B guest collaboration, see `Troubleshooting/CIAMMigration-B.md`/`-A.md`
- **Entra ID Governance — Account Discovery** — retrieves the full user account list from an already-provisioned Enterprise Application and classifies each against Entra ID as uncorrelated ("Local accounts"), correlatedNotAssigned ("Unassigned users"), correlatedAssigned ("Assigned users"), or the Graph-only `failToCorrelate` status; reuses the provisioning job's own matching attribute (must be a DIRECT mapping — Expression-type matching attributes fail correlation with `MissingJoiningProperty` even though they work fine for ordinary provisioning), gated by the Entra ID Governance add-on/Entra Suite license plus Application/Cloud Application/Hybrid Identity Administrator RBAC to trigger a run (broader RBAC can read a completed report), portal-trigger-only with no Graph write/start endpoint, and an explicit unsupported-connector list that includes Cloud Sync and Cross-tenant sync from this same folder; bulk remediation via Microsoft's `Assign-CorrelatedUsers.ps1` — architecturally layered on top of, and sharing failure modes with, `Troubleshooting/EnterpriseAppProvisioning-B.md`/`-A.md`, see `Troubleshooting/AccountDiscovery-B.md`/`-A.md`

---

## Before responding, also check

- `Security/ConditionalAccess/` — CA policy is a sub-domain of Entra but complex enough to have its own module
- `Intune/` — most device compliance issues loop back to Entra join state
- `Autopilot/` — Autopilot enrollment failures are almost always Entra + Intune combined
- `EntraID/Graph/` — for automating anything against Entra via PowerShell or flows
- `macOS/Troubleshooting/ManagedAppleID-Federation-A.md`/`-B.md` — if the question is about an Apple device's **Managed Apple Account** being backed by Entra ID (Apple Business/Apple Business Manager federation and directory sync), not device join/Entra registration itself — a distinct identity plane covered there, not here

---

## Key first commands (always run first)

```powershell
# On the device — everything about device identity
dsregcmd /status

# Key fields:
#   AzureAdJoined      = YES/NO (direct Entra join)
#   DomainJoined       = YES/NO (on-prem AD)
#   AzureAdPrt         = YES/NO (token for SSO — if NO, user can't SSO)
#   AzureAdPrtExpiry   = token expiry time
#   DeviceId           = Entra device object ID

# Force PRT refresh (if AzureAdPrt = NO)
# Lock screen → unlock → PRT refreshes on sign-in

# Check sign-in logs for a user (requires Graph or Entra portal)
Get-MgAuditLogSignIn -Filter "userPrincipalName eq 'user@contoso.com'" -Top 10 |
  Select CreatedDateTime, AppDisplayName, Status, ConditionalAccessStatus
```

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Troubleshooting/HybridJoin-B.md` / `-A.md` | Hotfix + deep dive: HAADJ two-phase registration, SCP, Entra Connect sync timing |
| `Troubleshooting/PRT-Issues-B.md` / `-A.md` | Hotfix + deep dive: PRT missing, SSO broken, CA failing |
| `Troubleshooting/DynamicGroups-B.md` / `-A.md` | Hotfix + deep dive: dynamic group membership rule not evaluating, paused processing, evaluation pipeline, sync lag |
| `Troubleshooting/PasswordProtection-B.md` / `-A.md` | Hotfix + deep dive: Smart Lockout, banned password rejections, hybrid writeback/on-prem agent issues |
| `Troubleshooting/CAE-B.md` / `-A.md` | Hotfix + deep dive: Continuous Access Evaluation — unexpected sign-outs, critical event revocation, claims challenges, strict location enforcement |
| `Troubleshooting/GlobalSecureAccess-B.md` / `-A.md` | Hotfix + deep dive: Global Secure Access (Internet Access/Private Access) client not tunneling, connector down, traffic forwarding profiles, connector topology |
| `Troubleshooting/CrossTenant-B.md` / `-A.md` | Hotfix + deep dive: XTAS default/partner policies, B2B Direct Connect, cross-tenant sync |
| `Troubleshooting/EntraDomainServices-B.md` / `-A.md` | Hotfix + deep dive: managed domain (Entra DS) health, one-way sync architecture, password hash projection, flat OU model, LDAPS, VNet peering/DNS |
| `Troubleshooting/AccessPackages-B.md` / `-A.md` | Hotfix + deep dive: entitlement management access package assignment/delivery failures, approval workflow, connected org sync |
| `Troubleshooting/AppProxy-B.md` / `-A.md` | Hotfix + deep dive: Microsoft Entra Application Proxy connector health, pre-authentication failures, backend connectivity |
| `Troubleshooting/Connect-Sync-B.md` / `-A.md` | Hotfix + deep dive: Entra Connect Sync (legacy on-prem sync-engine model) — sync errors, attribute conflicts, staging mode |
| `Troubleshooting/CloudSync-B.md` / `-A.md` | Hotfix + deep dive: Entra Cloud Sync — provisioning agent install/health, gMSA auth, multi-agent HA, quarantine handling, error-code mapping, Group Provisioning to AD DS scale limits |
| `Troubleshooting/ExternalIdentities-B.md` / `-A.md` | Hotfix + deep dive: B2B guest invitation/redemption failures, external collaboration settings |
| `Troubleshooting/IdentityProtection-B.md` / `-A.md` | Hotfix + deep dive: risk-based Conditional Access, user/sign-in risk detections, risk remediation |
| `Troubleshooting/MFA-B.md` / `-A.md` | Hotfix + deep dive: MFA registration/challenge failures, method management, CA integration, token claims |
| `Troubleshooting/PIM-B.md` / `-A.md` | Hotfix + deep dive: Privileged Identity Management role activation failures, access reviews, eligible vs. active assignments |
| `Troubleshooting/SSPR-B.md` / `-A.md` | Hotfix + deep dive: Self-Service Password Reset registration/reset failures, authentication method gaps |
| `Troubleshooting/WHfB-B.md` / `-A.md` | Hotfix + deep dive: Windows Hello for Business provisioning failures, key trust/cert trust, TPM issues |
| `Troubleshooting/Passkeys-B.md` / `-A.md` | Hotfix + deep dive: Passkey (FIDO2) — passkey profiles, device-bound vs. synced, attestation, TAP-based registration bootstrap/lockout loop, AAGUID key restrictions |
| `Troubleshooting/GDAP-B.md` / `-A.md` | Hotfix + deep dive: Granular Delegated Admin Privileges (CSP/partner relationships) — relationship lifecycle, Access Assignment/security group mapping, guest-account contamination, Conditional Access "Service provider users" interaction |
| `Troubleshooting/VerifiedID-B.md` / `-A.md` | Hotfix + deep dive: Microsoft Entra Verified ID — issuer/holder/verifier architecture, DID/DID document, did:web vs. deprecated did:ion, Key Vault signing key lifecycle, domain linkage (.well-known DID configuration), Admin API + Request Service API |
| `Troubleshooting/AppRegistrations-B.md` / `-A.md` | Hotfix + deep dive: App Registration + Service Principal architecture, client secret/certificate expiry, AADSTS7000215/7000222/700027/500011/65001 error mapping, zero-owner notification gap, multi-tenant consent provisioning, federated credential migration |
| `Troubleshooting/WorkloadIdentity-B.md` / `-A.md` | Hotfix + deep dive: workload identity federation (OIDC subject/issuer/audience matching for GitHub Actions/Azure DevOps/Kubernetes), AADSTS700211/700213/70021/700223/700238/70025 error mapping, Conditional Access for workload identities (direct-SP targeting only, no group enforcement, Workload Identities Premium licensing), risky workload identity remediation |
| `Troubleshooting/AccessReviews-B.md` / `-A.md` | Hotfix + deep dive: periodic access recertification (groups/apps/access packages/Entra roles/Azure resource roles), reviewer-type/auto-apply/on-prem-sync remediation gaps, resource-type-specific RBAC permission model, Graph API coverage gap for Azure resource roles |
| `Troubleshooting/CBA-B.md` / `-A.md` | Hotfix + deep dive: native Certificate-Based Authentication — CA trust chain upload, CRL/CDP reachability (cloud-side validator, not client-network-side), high- vs. low-affinity certificate-to-user binding, authentication strength/OID mapping for Conditional Access MFA satisfaction |
| `Troubleshooting/RestrictedManagementAU-B.md` / `-A.md` | Hotfix + deep dive: RMAU — Global Admin/Privileged Role Admin blocked from direct member modification, AU-scoped role assignment model, direct-membership-only (no cascade), the Global-Admin-as-RMAU-member dead end, PIM/Governance-feature incompatibility |
| `Scripts/Get-EntraDeviceHealth.ps1` | Device join state, PRT, compliance across fleet |
| `Scripts/Get-EntraConnectSyncErrors.ps1` | Export sync errors, attribute conflicts |
| `Scripts/Get-CrossTenantAccessAudit.ps1` | XTAS default + partner policy audit, Direct Connect mismatch, MFA/compliance trust gaps |
| `Scripts/Get-GlobalSecureAccessHealth.ps1` | Traffic forwarding profile state, Private Access connector/group health, app-to-connector mapping |
| `Scripts/Get-HybridJoinDiagnostics.ps1` | Device-local HAADJ chain check: domain join, SCP, DRS reachability, scheduled task, device cert |
| `Scripts/Get-EntraDomainServicesHealth.ps1` | Entra DS managed domain health: replica set status, LDAPS cert expiry, VNet peering reciprocity, DNS config, optional per-user password-hash-sync readiness |
| `Scripts/Get-AccessPackageAssignmentHealth.ps1` | Entitlement management access package assignment status/expiry audit |
| `Scripts/Get-AppProxyConnectorHealth.ps1` | Application Proxy connector group health, connector version/reachability audit |
| `Scripts/Get-CAESessionEvents.ps1` | Continuous Access Evaluation critical event and session revocation audit |
| `Scripts/Get-DynamicGroupAudit.ps1` | Dynamic group rule validation, processing status, membership drift |
| `Scripts/Get-EntraB2BGuestReport.ps1` | Guest account inventory, redemption status, external collaboration audit |
| `Scripts/Get-GDAPRelationshipAudit.ps1` | GDAP relationship lifecycle audit, Auto Extend/expiry flags, Access Assignment health, guest-in-security-group detection |
| `Scripts/Get-VerifiedIDConfigAudit.ps1` | Entra Verified ID authority/contract audit — DID sync state, legacy did:ion detection, domain linkage validation, manifest reachability, indexed-claim contract misconfiguration |
| `Scripts/Get-IdentityProtectionRiskReport.ps1` | User/sign-in risk detections export, risk-level summary |
| `Scripts/Get-MFAMethodsReport.ps1` | Per-user MFA method registration coverage audit |
| `Scripts/Get-PIMReport.ps1` | PIM eligible/active role assignment and activation history audit |
| `Scripts/Get-PasswordProtectionCoverage.ps1` | Smart Lockout / banned password list policy coverage audit |
| `Scripts/Get-PRTFleetRisk.ps1` | Fleet-wide PRT health and risk flagging |
| `Scripts/Get-SSPRCoverageReport.ps1` | SSPR registration coverage and authentication method gap audit |
| `Scripts/Get-WHfBRegistrationStatus.ps1` | Windows Hello for Business registration/provisioning status across fleet |
| `Scripts/Get-PasskeyRegistrationAudit.ps1` | Passkey (FIDO2) tenant policy state, per-user registration/AAGUID inventory, CA bootstrap-lockout risk scan |
| `Scripts/Invoke-GraphBatchQuery.ps1` | Generic Graph API batch query helper for large-object-set reporting |
| `Scripts/Get-AppRegistrationCredentialAudit.ps1` | Tenant-wide App Registration secret/cert expiry audit, zero-owner detection, Service Principal existence/enablement cross-check, per-app risk scoring |
| `Scripts/Get-WorkloadIdentityAudit.ps1` | Tenant-wide federated credential inventory, non-standard audience detection, Conditional Access workload-identity targeting cross-check, Workload Identities Premium license consumption |
| `Scripts/Get-AccessReviewAudit.ps1` | Access review definition/instance audit — auto-apply gaps, stalled instances, on-prem-synced-group remediation gaps, app reviewability gate, recent audit log activity |
| `Scripts/Get-CloudSyncHealth.ps1` | Cloud Sync provisioning agent host health (services, OS/Server-2025-KB check, TLS/.NET/execution-policy prereqs, gMSA, network reachability, optional GPAD LDAP/GC check) plus optional cloud-side agent/job/quarantine status via AADCloudSyncTools |
| `Troubleshooting/PIMAzureResources-B.md` / `-A.md` | Hotfix + deep dive: PIM for Azure Resources — Azure RBAC JIT activation via ARM API/`Az.Resources` (not Graph), MS-PIM service principal as scope-wide single point of failure, one-way onboarding, per-scope (non-inherited) policy model, static-vs-PIM assignment coexistence and duplicate-conflict traps |
| `Scripts/Get-PIMAzureResourcesAudit.ps1` | Fleet-wide (multi-subscription) PIM for Azure Resources audit — MS-PIM permission health, scope onboarding state, no-expiry eligible assignments, expiring-soon active assignments, static-assignment-duplicates-eligible cross-reference |
| `Troubleshooting/LifecycleWorkflows-B.md` / `-A.md` | Hotfix + deep dive: Lifecycle Workflows — enable-vs-scheduled two-switch gotcha, 3-day catch-up window, case-sensitive rule/custom-security-attribute matching, AD DS-synced Enable/Disable/Delete task prerequisites (provisioning agent version, extension mode, gMSA rights, AD Recycle Bin), Logic Apps task extensibility model |
| `Scripts/Get-LifecycleWorkflowAudit.ps1` | Workflow inventory (enabled/scheduled state), recent run failure/no-run detection, AD DS account-task prerequisite risk flagging, deactivated custom security attribute detection, license check, optional per-user processing result lookup |
| `Scripts/Get-ExternalIdentitiesAudit.ps1` | Read-only tenant-wide B2B guest audit — stuck-PendingAcceptance (default 14-day threshold), disabled, and stale/inactive (default 90-day threshold) guest flagging, plus full Cross-Tenant Access Settings partner-policy dump; defers all cleanup to `ExternalIdentities-A.md` Playbook 3 |
| `Graph/Useful-Queries.md` | Common Graph API queries for MSP reporting |
| `Scripts/Get-CBAConfigurationAudit.ps1` | CBA policy state/scope, trusted CA + CRL-configured audit, binding priority/affinity type, per-user certificateUserIds/UPN binding-readiness check |
| `Scripts/Get-RestrictedManagementAUAudit.ps1` | Tenant-wide RMAU inventory — member type breakdown per RMAU, scoped role assignment audit with orphaned-principal detection, PIM eligible-assignment conflict cross-check |
| `Troubleshooting/ExternalMFA-B.md` / `-A.md` | Hotfix + deep dive: External MFA (third-party OIDC provider satisfying MFA) — two-role admin-consent gate, authentication-strength incompatibility, acr/amr claim type-mapping validation, Custom-Control migration, Windows 10 OOBE limitation, provider signing-key rollover/24h metadata cache |
| `Scripts/Get-ExternalMFAAudit.ps1` | External MFA method state/consent audit (service-principal-existence-as-consent-proxy), Conditional Access authentication-strength conflict scan, optional live provider discovery-endpoint reachability check |
| `Troubleshooting/EnterpriseAppProvisioning-B.md` / `-A.md` | Hotfix + deep dive: Enterprise Application SCIM provisioning to SaaS apps — quarantine (invalid credentials/escrow threshold/SCIM compliance) triage, "not effectively entitled" and scoping-filter skip resolution, nested-group non-support, matching-attribute rebuild, deprovisioning (disable vs. delete) behavior |
| `Scripts/Get-EnterpriseAppProvisioningAudit.ps1` | Tenant-wide provisioning job inventory — status/quarantine-reason flagging, stale-last-success detection, per-app recent-failure-reason grouping from provisioning logs |
| `Troubleshooting/EntraSuiteLicensing-B.md` / `-A.md` | Hotfix / deep dive: Microsoft Entra Suite / Global Secure Access licensing — P1/P2 mandatory base, Suite vs. standalone Internet Access/Private Access add-ons, guest MAU billing model, feature-to-tier mapping, remote-network 50-license floor, cohort-based cost-allocation framework |
| `Scripts/Get-EntraSuiteLicenseAudit.ps1` | Tenant-wide GSA/Suite license inventory — P1/P2 base presence, Suite/standalone SKU consumption, per-user assignment split by Member/Guest, remote-network 50-license floor check, optional sign-in-activity cross-reference to flag licensed-but-inactive users |
| `Troubleshooting/AgentID-B.md` / `-A.md` | Hotfix + deep dive: Microsoft Entra Agent ID — four-object model (blueprint/blueprint principal/identity/agent user), Owner/Sponsor/Manager administrative model, sponsor group-type validity rules, AI Administrator vs. Agent ID Administrator role overlap, entitlement-management access package agent-identity scoping, Conditional Access/Identity Protection extension to agents, and cross-reference to the M365 admin center Agent Registry's Shadow-agent risk |
| `Scripts/Get-AgentIdentityGovernanceAudit.ps1` | Tenant-wide agent identity/blueprint ownership and sponsorship hygiene audit (no-owner, single-owner succession risk, no-sponsor drift, invalid sponsor group type), Agent ID role assignment inventory + AI Administrator/Agent ID Administrator overlap flagging, optional access package agent-scope gap check |
| `Troubleshooting/AppConsentPolicies-B.md` / `-A.md` | Hotfix + deep dive: App Consent Policies & Illicit Consent Grant Attacks — `authorizationPolicy`/`permissionGrantPolicies` two-layer model, built-in policy catalog, admin consent workflow reviewer-RBAC gap (Graph app-role approval requires Global Administrator/Privileged Role Administrator specifically), illicit consent grant detection (audit log `IsAdminConsent`, `ConsentType: AllPrincipals`) and revocation |
| `Scripts/Get-AppConsentGovernanceAudit.ps1` | Tenant-wide consent governance audit — tenant default policy check, admin-consent-workflow reviewer RBAC validation (flags reviewers who can't actually approve), tenant-wide high-risk/unverified-publisher OAuth grant sweep (delegated + application), zero-owner-on-flagged-app cross-check |
| `Troubleshooting/AdministrativeUnits-B.md` / `-A.md` | Hotfix + deep dive: regular Administrative Units — `directoryScopeId`-scoped role assignment model, AU-scope-eligible role list, group-in-AU-manages-the-group-not-its-members rule, static vs. dynamic (rule-based) membership constraints, the non-admin-only anti-escalation carve-out, and the service principal/guest supplementary-Directory-Readers gap; defers all RMAU-specific procedure to `RestrictedManagementAU-B.md`/`-A.md` |
| `Scripts/Get-AdministrativeUnitAudit.ps1` | Tenant-wide AU inventory (regular + restricted) — zero-scoped-role-assignment gap detection (HIGH severity for RMAUs), service principal/guest missing-supplementary-read-role flagging, dynamic-AU paused-processing/zero-member health checks; defers orphaned-principal/PIM-conflict RMAU checks to `Get-RestrictedManagementAUAudit.ps1` |
| `Graph/GraphDataConnect-B.md` / `-A.md` | Hotfix + deep dive: Microsoft Graph Data Connect (MGDC) — bulk M365 data export to Fabric/Synapse/ADF, five-stage onboarding chain, `Microsoft.GraphServices` billing-provider gate, non-guest mailbox+E5-licensed app-owner requirement, Global-Admin-only self-approval-blocked consent, per-run fraction-rounded billing, single-Office-region-per-pipeline constraint, same-tenant-only boundary |
| `Scripts/Get-GraphDataConnectReadinessAudit.ps1` | Read-only MGDC onboarding-readiness audit — tenant/subscription boundary alignment, `Microsoft.GraphServices` registration state, app-owner eligibility (guest/mailbox/license) per app, service-principal storage RBAC, storage network rule posture; explicitly flags the portal-only pieces (tenant toggle, consent status, pipeline history) it cannot read |
| `Troubleshooting/CIAMMigration-B.md` / `-A.md` | Hotfix + deep dive: Entra External ID for customers (CIAM) JIT password migration — `OnPasswordSubmit` custom authentication extension architecture, listener policy priority/scope, RSA-JWE encryption key (`keyId`/`tokenEncryptionKeyId`) consistency, `disableStrongPassword` coexistence trade-off, throttling/timeout tuning for large migration waves, cert rotation playbook — distinct from workforce B2B/`ExternalIdentities-B.md`/`-A.md` |
| `Scripts/Get-CIAMMigrationReadinessAudit.ps1` | Read-only JIT migration readiness audit — extension existence + `targetUrl` shape check, listener policy priority-conflict detection, encryption key/cert consistency, admin consent grant verification, RBAC role-holder inventory for the three required roles, `disableStrongPassword` state flagging; explicitly flags per-user flag distribution and Function-side logs as portal/Application-Insights-only |
| `Troubleshooting/AccountDiscovery-B.md` / `-A.md` | Hotfix + deep dive: Entra ID Governance Account Discovery — matching-attribute Direct-vs-Expression correlation failure (`MissingJoiningProperty`), license/RBAC dual-gate (trigger vs. read), portal-trigger-only execution model (no Graph start endpoint), four-status classification (`uncorrelated`/`correlatedNotAssigned`/`correlatedAssigned`/`failToCorrelate`), explicit unsupported-connector list, bulk remediation via `Assign-CorrelatedUsers.ps1` |
| `Scripts/Get-AccountDiscoveryReadinessAudit.ps1` | Read-only tenant-wide readiness audit — best-effort license SKU check, trigger-RBAC role-holder inventory, per-app matching-attribute-type flagging (Direct vs. Expression), existing correlation report summary with high-uncorrelated-ratio and report-error flagging; explicitly flags discovery-triggering and connector-type support as portal-only/manual-verification |

---

## Common entry points

- "User getting MFA prompt every time / SSO not working" → `Troubleshooting/PRT-Issues-B.md`
- "Hybrid join not completing" → `Troubleshooting/HybridJoin-B.md`
- "Device in Entra but Intune shows not enrolled" → `Intune/Troubleshooting/Enrollment-B.md`
- "Conditional Access blocking access incorrectly" → `Security/ConditionalAccess/`
- "Entra Connect attribute conflict / user not syncing" (classic on-prem Entra Connect Sync server) → `Troubleshooting/Connect-Sync-B.md`
- "Provisioning agent won't start / shows inactive in portal / job in quarantine" / "Cloud Sync" by name → `Troubleshooting/CloudSync-B.md` + `Scripts/Get-CloudSyncHealth.ps1`
- "Cloud-created group needs to show up in on-prem AD for a legacy app" / "Group Provisioning to AD DS" / "GPAD" → `Troubleshooting/CloudSync-A.md` Playbook 4 (scoping-mode scale limits) + Dependency Stack (reverse-flow branch)
- "Service principal client secret expired (flow/app broken)" / "AADSTS7000215 or AADSTS7000222" / "automation stopped authenticating overnight" → `Troubleshooting/AppRegistrations-B.md` + `Scripts/Get-AppRegistrationCredentialAudit.ps1`
- "Multi-tenant app works in one customer tenant but fails with AADSTS500011 in another" / "AADSTS700027 certificate auth failing" → `Troubleshooting/AppRegistrations-B.md` Fix 3 / Fix 4
- "GitHub Actions / Azure DevOps pipeline suddenly can't get a token, no secret involved" / "AADSTS700211, 700213, 70021, 700223, 700238, or 70025" → `Troubleshooting/WorkloadIdentity-B.md` + `Scripts/Get-WorkloadIdentityAudit.ps1`
- "Service principal blocked with no federation error" / "want to add Conditional Access to a CI/CD automation account" / "Workload Identities Premium license question" → `Troubleshooting/WorkloadIdentity-B.md` Fix 4 / `Troubleshooting/WorkloadIdentity-A.md` Playbook 2
- "Guest user can't access SharePoint / B2B invite won't redeem" → `Troubleshooting/ExternalIdentities-B.md` + `M365/SharePoint-OneDrive/`
- "Dynamic group not picking up new members / license not assigning" → `Troubleshooting/DynamicGroups-B.md`
- "User locked out repeatedly / new password keeps getting rejected" → `Troubleshooting/PasswordProtection-B.md`
- "User randomly signed out mid-session" / "session ended after password reset or VPN change" → `Troubleshooting/CAE-B.md`
- "Traffic not tunneling / Private Access app unreachable / GSA client won't connect" → `Troubleshooting/GlobalSecureAccess-B.md`
- "Guest from partner org keeps getting MFA prompts / Teams Shared Channel not available to external member" → `Troubleshooting/CrossTenant-B.md`
- "Device domain-joined but stuck in Entra as Pending / dsregcmd shows AzureAdJoined: NO" → `Troubleshooting/HybridJoin-B.md` + `Scripts/Get-HybridJoinDiagnostics.ps1`
- "Can't domain-join a VM to our managed domain / LDAPS broken / new cloud-only user can't log into the domain-joined server" → `Troubleshooting/EntraDomainServices-B.md` + `Troubleshooting/EntraDomainServices-A.md` (architecture: one-way sync, flat OU model, VNet peering) + `Scripts/Get-EntraDomainServicesHealth.ps1`
- "Access package request stuck / approval not delivering the group membership" → `Troubleshooting/AccessPackages-B.md`
- "On-prem app published via App Proxy unreachable / pre-auth failing" → `Troubleshooting/AppProxy-B.md`
- "Risky sign-in blocking a user who says it's legitimate" → `Troubleshooting/IdentityProtection-B.md`
- "User can't register for MFA / stuck in method-registration loop" → `Troubleshooting/MFA-B.md`
- "PIM role activation failing / approval never arrives" (Entra directory role or group) → `Troubleshooting/PIM-B.md`
- "PIM for Azure resources" / "Owner or Contributor eligible assignment on a subscription" / "Global Admin can't see any subscriptions in PIM" / "MS-PIM service principal" → `Troubleshooting/PIMAzureResources-B.md` + `Scripts/Get-PIMAzureResourcesAudit.ps1`
- "Removed someone from PIM but they still have access to the subscription" → `Troubleshooting/PIMAzureResources-B.md` Fix 6 (static assignment coexists with, and outlives, PIM eligibility)
- "User can't reset their own password / SSPR registration incomplete" → `Troubleshooting/SSPR-B.md`
- "Windows Hello for Business won't provision / stuck on TPM or cert enrollment" → `Troubleshooting/WHfB-B.md`
- "User can't register a passkey / TAP rejected / locked out of Security info trying to add a passkey" → `Troubleshooting/Passkeys-B.md` + `Scripts/Get-PasskeyRegistrationAudit.ps1`
- "Our MSP/partner suddenly can't get into a customer tenant / GDAP relationship expired" → `Troubleshooting/GDAP-B.md` + `Scripts/Get-GDAPRelationshipAudit.ps1`
- "Verified ID / verifiable credential won't issue or verify / Authenticator shows unverified warning" → `Troubleshooting/VerifiedID-B.md` + `Scripts/Get-VerifiedIDConfigAudit.ps1`
- "Salesforce/Workday/ServiceNow (or any SaaS app) provisioning job in quarantine" / "users not showing up in a SaaS app" / "SCIM provisioning stopped working" → `Troubleshooting/EnterpriseAppProvisioning-B.md` + `Scripts/Get-EnterpriseAppProvisioningAudit.ps1`
- "User shows as 'skipped, not effectively entitled' in provisioning logs" / "group member never provisions to a SaaS app despite being in the group" (nested-group gap) → `Troubleshooting/EnterpriseAppProvisioning-B.md` Fix 4 / Fix 7
- "Access review completed but the person still has access" / "reviewer never got notified" / "can't find this app to review it" → `Troubleshooting/AccessReviews-B.md` + `Scripts/Get-AccessReviewAudit.ps1`
- "I have Global Reader but can't create an access review" / "group owner can't review their own group" → `Troubleshooting/AccessReviews-B.md` Fix 5 / `Troubleshooting/AccessReviews-A.md` resource-type permission table
- "Built a Lifecycle Workflow and nothing runs automatically" / "workflow is enabled but never fires" → `Troubleshooting/LifecycleWorkflows-B.md` Fix 1 (check `IsSchedulingEnabled` — separate switch from `IsEnabled`)
- "New hire's welcome email/license never arrived even though start date passed" / "leaver workflow ran late" → `Troubleshooting/LifecycleWorkflows-B.md` (3-day catch-up window) + `Scripts/Get-LifecycleWorkflowAudit.ps1`
- "Workflow says the Disable/Delete task succeeded but the AD account is still active" → `Troubleshooting/LifecycleWorkflows-B.md` Fix 3 / `Troubleshooting/LifecycleWorkflows-A.md` Playbook 2 (provisioning agent version, extension mode, gMSA rights, AD Recycle Bin)
- "Lifecycle Workflow rule shows a red error icon / invalid properties" → `Troubleshooting/LifecycleWorkflows-B.md` Fix 4 (deactivated custom security attribute)
- "Discover identities button is missing or greyed out" / "Account Discovery" by name / "want to find local/orphan accounts in a SaaS app before turning on provisioning" → `Troubleshooting/AccountDiscovery-B.md` + `Scripts/Get-AccountDiscoveryReadinessAudit.ps1`
- "Account Discovery report shows 0 results" / "MissingJoiningProperty error" / "everyone shows up as a Local account even though provisioning has been running fine" → `Troubleshooting/AccountDiscovery-B.md` Fix 3 / Fix 4 (matching attribute is Expression-type, not Direct)
- "Trying to script/automate Account Discovery and nothing triggers" → `Troubleshooting/AccountDiscovery-A.md` How It Works (portal-trigger-only, no Graph start endpoint) — this is a documented product gap, not a misconfiguration
- "Smart card sign-in says certificate not trusted / not revoked but Entra says it is / signs in as the wrong user" → `Troubleshooting/CBA-B.md` + `Scripts/Get-CBAConfigurationAudit.ps1`
- "Cert-based sign-in works but Conditional Access still demands MFA" → `Troubleshooting/CBA-B.md` Fix 6 (authentication strength OID mapping)
- "Global Admin can't reset this exec's password / can't edit this group's membership, no obvious reason" → `Troubleshooting/RestrictedManagementAU-B.md` (check `isMemberManagementRestricted` first)
- "PIM eligible assignment / access review / Lifecycle Workflow silently doesn't apply to a specific user or group" → `Troubleshooting/RestrictedManagementAU-B.md` Fix 6 (confirm RMAU membership before troubleshooting the Governance feature)
- "Nobody can reset a Global Administrator's own password" → `Troubleshooting/RestrictedManagementAU-B.md` Fix 5 (must be removed from the RMAU first)
- "Third-party MFA (Duo, etc.) stopped satisfying Conditional Access" / "external MFA method stuck disabled" / error code 50158 → `Troubleshooting/ExternalMFA-B.md` + `Scripts/Get-ExternalMFAAudit.ps1`
- "External MFA enabled tenant-wide but still blocked by a phishing-resistant/authentication-strength policy" → `Troubleshooting/ExternalMFA-B.md` Fix 2 / `Troubleshooting/ExternalMFA-A.md` (hard incompatibility, not a config gap)
- "User redirected to Duo/provider twice during sign-in" → `Troubleshooting/ExternalMFA-B.md` Fix 5 (overlapping Custom Control + External MFA policies)
- "Should we buy the Entra Suite or the individual GSA add-ons" / "GSA feature greyed out, is it a licensing gap" / "guest user billing for Global Secure Access" → `Troubleshooting/EntraSuiteLicensing-B.md` + `Scripts/Get-EntraSuiteLicenseAudit.ps1`
- "Remote network / branch connectivity option won't enable in GSA" → `Troubleshooting/EntraSuiteLicensing-B.md` Fix 6 (50-combined-license floor)
- "We're under the 50K free external MAU tier, why did we get billed for guest GSA access" → `Troubleshooting/EntraSuiteLicensing-B.md` Fix 4 (free MAU allowance doesn't extend to GSA/Governance for guests)
- "Creating an AI agent identity fails, says sponsor required" / "assigned a group as sponsor and it doesn't work" / "which role do I give someone to manage agent identities, AI Administrator or Agent ID Administrator" / "our agent can't get an access package" / "agent shows Shadow agent risk in M365 admin center" → `Troubleshooting/AgentID-B.md` + `Scripts/Get-AgentIdentityGovernanceAudit.ps1` — for the Registry/catalog side of an agent question instead (approval, publishing, ownership in M365 admin center), go to `M365/Copilot/AgentGovernance-B.md` instead
- "User stuck on 'Need admin approval' and nothing happens" / "app blocked, AADSTS90094 or AADSTS65001" / "reviewer added to admin consent workflow but can't approve" / "suspicious OAuth consent grant, possible phishing" / "illicit consent grant attack" / "custom app consent policy not working as expected" → `Troubleshooting/AppConsentPolicies-B.md` + `Scripts/Get-AppConsentGovernanceAudit.ps1`
- "AU-scoped admin can't manage a specific user even though their group is in the AU" / "Helpdesk/Password/User Administrator can't reset one person's password, works for everyone else" / "dynamic AU rule won't save or shows zero members" / "can't manually add a member to an AU" / "automation account or guest has an AU-scoped role but every Graph call still fails" → `Troubleshooting/AdministrativeUnits-B.md` + `Scripts/Get-AdministrativeUnitAudit.ps1` — if the AU is Restricted Management (`isMemberManagementRestricted = true`), go to `Troubleshooting/RestrictedManagementAU-B.md` instead
- "App registration for a data-export pipeline stuck at Pre-consent" / "Data Connect app can't be found in the Azure portal" / "no authorization creating a Microsoft.GraphServices resource" / "Developer email not found registering an MGDC app" / "bulk M365 data extraction to Fabric/Synapse/Data Factory" / "why is my Data Connect bill higher than expected" → `Graph/GraphDataConnect-B.md` + `Scripts/Get-GraphDataConnectReadinessAudit.ps1`
- "Migrating customer users off our old identity provider / B2C and they keep getting stuck resetting their password" / "custom authentication extension not being called during sign-in" / "CustomExtensionThrottlingError or CustomExtensionTimedOut" / "every migrating user gets a Block screen" / "JIT password migration" → `Troubleshooting/CIAMMigration-B.md` + `Scripts/Get-CIAMMigrationReadinessAudit.ps1` — this is an External ID *for customers* (CIAM) tenant topic, not workforce B2B; for guest/partner invitations go to `Troubleshooting/ExternalIdentities-B.md` instead

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — `dsregcmd /status` → identify the broken Entra layer → fix → validate
2. **Deep Dive** — identity architecture, token model, sync topology
3. **Learning Pointers** — what to go deeper on after the ticket is closed
