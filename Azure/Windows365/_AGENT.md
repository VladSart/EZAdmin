# Windows 365 Cloud PC — Agent Instructions

## What's in this folder

Windows 365 Cloud PC troubleshooting runbooks and a fleet-wide diagnostic script for MSP engineers. Covers provisioning policy pipeline, licensing (Enterprise/Business/Frontline), Azure Network Connections (ANC) for hybrid/AD DS domain-joined Cloud PCs, Intune enrollment of Cloud PCs as managed endpoints, resize vs. reprovision operations, and end-user client connectivity.

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
| `Windows365-A.md` | Deep-dive reference — provisioning policy pipeline, domain join models (Entra ID/Hybrid/AD DS), licensing model, Frontline shared-pool ratio licensing, Windows 365 vs. AVD ownership model |
| `Scripts/Get-CloudPcFleetStatus.ps1` | Fleet-wide report: provisioning status (flags stuck/failed), ANC health, Intune enrollment gaps, and per-SKU license consumption — read-only, no remediation |

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

# Resize (non-destructive) vs. Reprovision (destructive — wipes OS disk)
Invoke-MgBetaResizeDeviceManagementVirtualEndpointCloudPc -CloudPcId "<id>" -TargetServicePlanId "<plan-id>"
Invoke-MgBetaReprovisionDeviceManagementVirtualEndpointCloudPc -CloudPcId "<id>"
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
