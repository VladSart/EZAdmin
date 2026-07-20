# Windows 365 Cloud PC — Agent Instructions

## What's in this folder

Windows 365 Cloud PC troubleshooting runbooks and fleet-wide diagnostic scripts for MSP engineers. Covers provisioning policy pipeline, licensing (Enterprise/Business, and Windows 365 Flex — renamed from Frontline on 2026-05-08, same product), Azure Network Connections (ANC) for hybrid/AD DS domain-joined Cloud PCs, Intune enrollment of Cloud PCs as managed endpoints, resize vs. reprovision operations, and end-user client connectivity. Flex's pooled-license Dedicated/Shared modes and their concurrency mechanics are covered separately in `Flex-A.md`/`Flex-B.md` since they diverge materially from the Enterprise/Business model in `Windows365-A.md`/`Windows365-B.md`.

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
