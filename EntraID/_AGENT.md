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

---

## Before responding, also check

- `Security/ConditionalAccess/` — CA policy is a sub-domain of Entra but complex enough to have its own module
- `Intune/` — most device compliance issues loop back to Entra join state
- `Autopilot/` — Autopilot enrollment failures are almost always Entra + Intune combined
- `EntraID/Graph/` — for automating anything against Entra via PowerShell or flows

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
- "Access review completed but the person still has access" / "reviewer never got notified" / "can't find this app to review it" → `Troubleshooting/AccessReviews-B.md` + `Scripts/Get-AccessReviewAudit.ps1`
- "I have Global Reader but can't create an access review" / "group owner can't review their own group" → `Troubleshooting/AccessReviews-B.md` Fix 5 / `Troubleshooting/AccessReviews-A.md` resource-type permission table
- "Built a Lifecycle Workflow and nothing runs automatically" / "workflow is enabled but never fires" → `Troubleshooting/LifecycleWorkflows-B.md` Fix 1 (check `IsSchedulingEnabled` — separate switch from `IsEnabled`)
- "New hire's welcome email/license never arrived even though start date passed" / "leaver workflow ran late" → `Troubleshooting/LifecycleWorkflows-B.md` (3-day catch-up window) + `Scripts/Get-LifecycleWorkflowAudit.ps1`
- "Workflow says the Disable/Delete task succeeded but the AD account is still active" → `Troubleshooting/LifecycleWorkflows-B.md` Fix 3 / `Troubleshooting/LifecycleWorkflows-A.md` Playbook 2 (provisioning agent version, extension mode, gMSA rights, AD Recycle Bin)
- "Lifecycle Workflow rule shows a red error icon / invalid properties" → `Troubleshooting/LifecycleWorkflows-B.md` Fix 4 (deactivated custom security attribute)

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — `dsregcmd /status` → identify the broken Entra layer → fix → validate
2. **Deep Dive** — identity architecture, token model, sync topology
3. **Learning Pointers** — what to go deeper on after the ticket is closed
