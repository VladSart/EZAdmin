# Windows 365 Cloud PC — Agent Instructions

## What's in this folder

Windows 365 Cloud PC troubleshooting runbooks and fleet-wide diagnostic scripts for MSP engineers. Covers provisioning policy pipeline, licensing (Enterprise/Business, and Windows 365 Flex — renamed from Frontline on 2026-05-08, same product), Azure Network Connections (ANC) for hybrid/AD DS domain-joined Cloud PCs, Intune enrollment of Cloud PCs as managed endpoints, resize vs. reprovision operations, and end-user client connectivity. Flex's pooled-license Dedicated/Shared modes and their concurrency mechanics are covered separately in `Flex-A.md`/`Flex-B.md` since they diverge materially from the Enterprise/Business model in `Windows365-A.md`/`Windows365-B.md`. Windows 365 Cloud Apps (published-application delivery layered on Flex Shared mode) is covered separately in `CloudApps-A.md`/`CloudApps-B.md` — it introduces no separate licensing/compute model of its own, only a policy property pairing and an app discovery/publish lifecycle. **Windows 365 Reserve** (short-term, on-demand Cloud PC access — up to 10 days/user/year — for users whose physical device is temporarily unavailable) is covered separately in `Reserve-A.md`/`Reserve-B.md` — a standalone offering with its own licensing/eligibility/deprovisioning model, architecturally unrelated to Windows 365 Cross-region Disaster Recovery / Disaster Recovery Plus (add-ons covered in `Flex-A.md` that protect an *existing* Enterprise/Flex Cloud PC, not a substitute for a user with none). **Windows 365 Link** (the purpose-built Cloud PC hardware thin-client device — a physical appliance running the minimal Windows CPC OS, GA since 2025-03-31) is covered separately in `Link-A.md`/`Link-B.md` — it is a *client device* layer, architecturally distinct from every other topic in this folder, which all cover Cloud PC provisioning/licensing/compute. Link connects to Cloud PCs provisioned under any of Enterprise, Business, or Flex, and is fully compatible with both Windows 365 Reserve and Windows 365 Boot. **Windows 365 for Agents** (a distinct, pool-based Cloud PC class for AI agent workloads — Copilot Studio computer use, Project Opal, Researcher, Agent 365 agents) is covered separately in `Agents-A.md`/`Agents-B.md` — it shares the underlying HOBO provisioning fabric with every other topic in this folder but diverges completely on management model (pool-focused, not device-focused), persistence (reset-after-use, not persistent), billing (consumption-based, not license-based), and access (agentic API/chat UX, not the Windows App client).

---

## Before responding, also check

| Also check | Why |
|---|---|
| `Azure/AVD/AVD-A.md` | Windows 365 runs on the same AVD connection broker/gateway infrastructure — client connectivity failures often share root cause with AVD |
| `Intune/Troubleshooting/Enrollment-B.md` | Windows 365 is Intune-mandatory — a Cloud PC that provisions but never enrolls behaves like any other stuck Autopilot/ESP enrollment |
| `EntraID/Troubleshooting/HybridJoin-B.md` | Hybrid/AD DS domain-joined Cloud PCs depend on the same Entra Connect sync timing as any other hybrid-joined device |
| `M365/Licensing/_AGENT.md` | Windows 365 SKU assignment (direct or group-based) is the trigger for provisioning — license processing lag shows up here first |
| `Security/ConditionalAccess/` | CA policies scoped to the "Windows 365" or "Azure Virtual Desktop" cloud apps can block the Cloud PC, the local client device, or both independently |

---

## Folder contents

| File | What it covers |
|---|---|
| `Windows365-B.md` | Hotfix runbook — stuck/failed provisioning, ANC unhealthy, license missing, client can't connect, resize vs. reprovision |
| `Windows365-A.md` | Deep-dive reference — provisioning policy pipeline, domain join models (Entra ID/Hybrid/AD DS), Enterprise/Business licensing model, Windows 365 vs. AVD ownership model |
| `Flex-B.md` | Hotfix runbook — Windows 365 Flex (formerly Frontline): Shared-mode pool exhaustion, Dedicated-mode concurrency buffer blocks, cold-start/power-state confusion, Resize-not-supported, naming confusion |
| `Flex-A.md` | Deep-dive reference — Flex pooled licensing model, Dedicated mode (up to 3 Cloud PCs/license, concurrency buffer, intelligent prestart) vs. Shared mode (1 Cloud PC/license, no persistence, no buffer), the May 2026 Frontline→Flex rename, feature gaps vs. Enterprise/Business |
| `Scripts/Get-CloudPcFleetStatus.ps1` | Fleet-wide report: provisioning status (flags stuck/failed), ANC health, Intune enrollment gaps, and per-SKU license consumption — read-only, no remediation. Enterprise/Business focused |
| `Scripts/Get-Windows365FlexAudit.ps1` | Flex-specific audit: mode distribution, Shared-mode pool capacity signal, Dedicated-mode group-oversizing check, deprecated `provisioningType eq 'shared'` filter risk — read-only, no remediation |
| `CloudApps-B.md` | Hotfix runbook — Windows 365 Cloud Apps: invalid policy property pairing, app discovery failures (custom image/APPX-MSIX/Autopilot), Failed/stuck publish states, concurrency exhaustion, expected cross-app launch behavior |
| `CloudApps-A.md` | Deep-dive reference — Cloud Apps as a policy-property pairing on Flex Shared mode (not a separate product), app discovery/publish lifecycle, inherited Flex licensing/concurrency model, Application Control for Windows as the only launch-restriction mechanism |
| `Scripts/Get-Windows365CloudAppsAudit.ps1` | Cloud Apps audit: invalid property-pairing detection, custom-image discovery risk flag, zero-provisioned-Cloud-PC detection, concurrency-at-capacity check — read-only, no remediation |
| `Reserve-B.md` | Hotfix runbook — Windows 365 Reserve: 7-day activation-delay blocks, 1-active-Cloud-PC-per-user limit, first-assigned-policy-wins reporting gap, disaster-recovery-add-on expectation mismatch, no-capacity-guarantee during large-scale events, no-snapshot-on-manual-deprovision data loss, bulk-provisioning rate limit |
| `Reserve-A.md` | Deep-dive reference — Reserve's standalone licensing/eligibility model (7-day delay, non-poolable, 1-per-user), no-capacity-preallocation architecture (vs. Disaster Recovery Plus), fixed 4vCPU/16GB/128GB spec, geography-only targeting, deprovisioning asymmetry (natural expiry snapshots, manual Return doesn't), full unsupported-feature boundary |
| `Scripts/Get-Windows365ReserveAudit.ps1` | Reserve audit: active Reserve Cloud PC inventory with status, duplicate-active-Reserve-PC detection (should never occur under the 1-per-user rule), provisioning policy cross-reference — read-only; cannot evaluate the 7-day eligibility delay (portal-only) |
| `Link-B.md` | Hotfix runbook — Windows 365 Link hardware device: automatic-enrollment not occurring, Entra join blocked, SSO-not-enabled connection error, SSO consent prompt loop, Intune features that don't apply (app mgmt/malware scan/remediation), Autopilot-not-supported, disconnected-standby-vs-stuck-remote-action, wipe/reset/BMR decision tree, restricted-network (MAC-filtered/certificate) onboarding |
| `Link-A.md` | Deep-dive reference — Link's Windows CPC minimal-OS architecture, non-configurable secure-by-design posture, Entra-join + automatic-enrollment-only onboarding model (no Autopilot/bulk provisioning), the deliberately narrow Intune management surface (Device health-only compliance), SSO-mandatory connectivity and the consent-prompt gap, update behavior, restricted-network deployment model, and the four-tier recovery/service/self-repair model including Bare Metal Recovery |
| `Scripts/Get-Windows365LinkAudit.ps1` | Link audit: device inventory with compliance/stale-checkin flags, tenant-wide SSO-readiness check across all provisioning policies (flags any policy that will hard-fail Link connections), optional app-policy-misassignment cross-reference against known Link device groups — read-only, no remediation |
| `Agents-B.md` | Hotfix runbook — Windows 365 for Agents: pool status Failed/Available with warning, session-capacity exhaustion, provisioning policy edits not taking effect (no auto-reprovision), CPCA-* device visibility gap in the legacy device view, read-only partner-solution (Copilot Studio/Project Opal/Researcher) policies, assignment targeting for non-persistent pool devices |
| `Agents-A.md` | Deep-dive reference — the four-subsystem architecture (Computer-Create/Get/Do/See), Cloud PC agent pool lifecycle and status model, pool-vs-Enterprise Cloud PC comparison (management/assignment/persistence/billing/access), self-managed vs. partner-solution provisioning policy ownership, session accounting (Active+Available=Always available count) |
| `Scripts/Get-Windows365AgentsAudit.ps1` | Agents audit: provisioning-policy(agents) enumeration, CPCA-* device inventory with staleness and model-mismatch flags, Cloud PC status distribution per policy as a session-pressure proxy — read-only, no remediation, cannot read live check-out/check-in session state or change pool sizing |

---

## Common entry points

| User question | Start here |
|---|---|
| "Cloud PC stuck in pendingProvisioning" | `Windows365-B.md` → Triage → Fix 2 (policy & license) |
| "Cloud PC status shows failed" | `Windows365-B.md` → Fix 1 (retry/reprovision) — check `StatusDetails` error code first |
| "User has no Cloud PC at all after license assignment" | `Windows365-B.md` → Fix 2 — check group-based licensing propagation lag |
| "ANC / Azure Network Connection unhealthy" | `Windows365-B.md` → Fix 3 |
| "Cloud PC shows provisioned but user can't connect" | `Windows365-B.md` → Fix 4 (client-side, not backend) |
| "User needs more CPU/RAM/storage" | `Windows365-B.md` → Fix 5 — resize, not reprovision (non-destructive) |
| "Accidentally reprovisioned and user lost data" | `Windows365-A.md` → Playbook 3 (data-loss mitigation, no true recovery) |
| "How does Windows 365 provisioning actually work end to end" | `Windows365-A.md` → How It Works |
| "Should this be Windows 365 or AVD for this client" | `Windows365-A.md` → How It Works comparison table |
| "Fleet-wide Cloud PC health for a report or ticket" | `Scripts/Get-CloudPcFleetStatus.ps1` |
| "Ticket says Frontline but nothing by that name exists in the portal" | `Flex-B.md` → Fix 6 — renamed to Windows 365 Flex on 2026-05-08, same product |
| "Shared-mode Flex pool says no Cloud PC available" | `Flex-B.md` → Fix 1 (pool exhaustion — no concurrency buffer in Shared mode) |
| "Dedicated-mode Flex user can't connect during shift overlap" | `Flex-B.md` → Fix 2 (concurrency buffer temporarily/permanently blocked) |
| "Resize option missing/fails on a Flex Cloud PC" | `Flex-B.md` → Fix 4 — not a supported feature for Flex, unlike Enterprise/Business |
| "Should this be Enterprise/Business or Flex for this client" | `Flex-A.md` → Remediation Playbooks → Playbook 4 (decision guide) |
| "Cloud Apps policy won't create / property pairing error" | `CloudApps-B.md` → Fix 1 — `cloudApp` only pairs with `sharedByEntraGroup`, neither changeable after creation |
| "No apps ever show up as Ready to publish" | `CloudApps-B.md` → Fix 2 (custom image discovery) or Fix 6 (Autopilot Device Prep checkbox) |
| "App stuck in Failed or Preparing in All Cloud Apps" | `CloudApps-B.md` → Fix 4 (Failed — unpublish/republish) or Fix 5 (Preparing — reprovision) |
| "Outlook opened Edge and nobody published Edge — is that a bug?" | `CloudApps-B.md` → Fix 8 — expected cross-app launch behavior, not a fault |
| "User's laptop was stolen/broken, needs temporary access from another device" | `Reserve-B.md` → Triage — confirm 7-day activation delay and existing active Reserve Cloud PC first |
| "License assigned today but Reserve Cloud PC won't provision" | `Reserve-B.md` → Fix 1 — mandatory, non-bypassable 7-day activation delay |
| "Client wants Reserve to behave like disaster recovery / guarantee capacity" | `Reserve-B.md` → Fix 4 — Reserve is not a DR add-on, see `Flex-A.md` for Cross-region DR/DR Plus instead |
| "User Returned their Reserve Cloud PC and lost data" | `Reserve-B.md` → Fix 6 — manual deprovision takes no snapshot, unlike natural 10-day expiry |
| "Windows 365 Link device never shows up in Intune after setup" | `Link-B.md` → Fix 1 — check MDM user scope and joining user's Entra ID P1 license |
| "Link user gets 'Cloud PC doesn't support Entra ID single sign-on'" | `Link-B.md` → Fix 3 — SSO not enabled on the target provisioning policy, no fallback exists |
| "Link connection fails only after ~30 days or right after reprovisioning" | `Link-B.md` → Fix 4 — SSO consent-prompt loop; suppress via `Link-A.md` Playbook 4 |
| "App/remediation/scan action stuck or failing on a Link device" | `Link-B.md` → Fix 5 — these Intune features don't apply to Link at all, not a fault |
| "Someone tried to Autopilot-enroll a Windows 365 Link device" | `Link-B.md` → Fix 6 — Autopilot is not supported in any form for Link |
| "Link device won't boot / needs factory reset" | `Link-B.md` → Fix 8 — decision tree across Wipe/Company Portal/WinRE/Bare Metal Recovery |
| "Agent pool status shows Failed / no Cloud PCs for Agents available" | `Agents-B.md` → Fix 1 — same root-cause classes as Enterprise provisioning failure, evaluated at pool scope |
| "Can't get an agent to check out a Cloud PC, no capacity" | `Agents-B.md` → Fix 3 — check Active+Available sessions against the Always available Cloud PCs ceiling |
| "Edited a provisioning policy (agents) but nothing changed" | `Agents-B.md` → Fix 4 — most properties require a manual reprovision, not automatic |
| "CPCA-* device shows no details in Devices > All devices" | `Agents-B.md` → Fix 5 — turn on Preview new device view, a documented legacy-view gap |
| "Can't edit a Copilot Studio / Project Opal / Researcher Cloud PC pool policy in Intune" | `Agents-B.md` → Fix 6 — read-only by design, edit in the owning partner portal |

---

## Key diagnostic commands

```powershell
# Connect with the scopes this domain needs
Connect-MgGraph -Scopes "CloudPC.ReadWrite.All","DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All"

# Cloud PC status for a specific user
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '<user@domain.com>'" |
    Select-Object DisplayName, Status, ProvisioningType, StatusDetails

# ANC health (hybrid/AD DS domain-joined only)
Get-MgBetaDeviceManagementVirtualEndpointOnPremisesConnection |
    Select-Object DisplayName, HealthCheckStatus, ErrorType

# Confirm Cloud PC license SKU assignment
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Select-Object SkuPartNumber, ServicePlans

# Confirm the Cloud PC actually enrolled into Intune
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<cloudpc-name>'" |
    Select-Object DeviceName, ComplianceState, LastSyncDateTime

# Resize (non-destructive) vs. Reprovision (destructive — wipes OS disk) — Enterprise/Business only,
# Resize is NOT supported for Windows 365 Flex as of this writing (see Flex-A.md/Flex-B.md Fix 4)
Invoke-MgBetaResizeDeviceManagementVirtualEndpointCloudPc -CloudPcId "<id>" -TargetServicePlanId "<plan-id>"
Invoke-MgBetaReprovisionDeviceManagementVirtualEndpointCloudPc -CloudPcId "<id>"

# Distinguish Flex (formerly Frontline) Cloud PCs from Enterprise/Business — see Flex-A.md Validation Steps
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All | Select DisplayName,ProvisioningType
Get-MgBetaDeviceManagementVirtualEndpointFrontLineServicePlan | Select DisplayName,VCpuCount,RamInGB

# Identify Cloud Apps policies and confirm the validated property pairing — see CloudApps-A.md How It Works
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All |
    Where-Object { $_.UserExperienceType -eq 'cloudApp' } | Select DisplayName,UserExperienceType,ProvisioningType

# Inventory Windows 365 Link hardware devices and confirm SSO readiness of what they connect to — see Link-A.md
Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" | Select DeviceName,SerialNumber,ComplianceState
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy | Select DisplayName,MicrosoftEntraSingleSignOnStatus
```

---

## Key dependency chain

```
Entra ID — user licensed (direct or group-based Windows 365 SKU)
    │
    └── Provisioning Policy (assigned to user/group)
            ├── Source image (Gallery or custom via Azure Compute Gallery)
            └── Domain join configuration
                    ├── Entra ID joined — no further network dependency
                    ├── Entra hybrid joined ─┐
                    └── AD DS joined ────────┴── Azure Network Connection (ANC)
                                                    ├── VNET peered/VPN/ExpressRoute to on-prem
                                                    ├── DNS resolution to AD domain
                                                    └── Health check: identity, DNS, NSG, UDR
                                                            │
                                                            └── Cloud PC VM (Microsoft-managed subscription)
                                                                    ├── Windows 365 agent
                                                                    ├── Intune enrollment (mandatory)
                                                                    └── AVD connection broker registration
                                                                            └── User's local client (Windows App / web / RDP)
                                                                                    └── Conditional Access evaluation
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — what to run right now to unblock the user (Mode B triage)
2. **Root cause** — why it happened (provisioning pipeline, ANC, or licensing layer)
3. **Fix + validation** — resolve, then confirm with a status/compliance check; flag if the fix (reprovision) is destructive before running it
