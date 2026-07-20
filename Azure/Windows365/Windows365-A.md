# Windows 365 Cloud PC — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This runbook covers Windows 365 Cloud PC — Enterprise and Business editions — including:
- Provisioning policies, images, and domain join models
- Azure Network Connections (ANC) for hybrid/AD DS-joined Cloud PCs
- Licensing (per-user and group-based assignment)
- Resize and reprovision operations
- Intune enrollment and management of Cloud PCs as endpoints
- Client connectivity (Windows App, web client)

**Assumes:**
- Microsoft Graph PowerShell SDK (beta module) installed: `Install-Module Microsoft.Graph.Beta -Scope CurrentUser`
- Authenticated with `Connect-MgGraph` and `CloudPC.ReadWrite.All`, `DeviceManagementConfiguration.Read.All` scopes
- Tenant has at least one active Windows 365 Enterprise or Business subscription

**Not covered:** Windows 365 Flex (formerly Frontline, renamed 2026-05-08) pooled-licensing internals, Dedicated/Shared mode mechanics, and concurrency buffer — see `Flex-A.md`/`Flex-B.md` for full coverage; Windows 365 Government/GCC-specific network requirements; deep AVD broker internals (see `Azure/AVD/AVD-A.md`).

---
## How It Works

<details><summary>Full architecture</summary>

### What Windows 365 actually is

Windows 365 is a managed service layer on top of the same Azure Virtual Desktop (AVD) control plane, gateway, and broker infrastructure — but with a fundamentally different ownership and lifecycle model than self-managed AVD:

| Aspect | Windows 365 | Self-managed AVD |
|--------|-------------|-------------------|
| VM ownership | Microsoft-managed subscription (customer never sees the VM in their own Azure subscription, except with "Azure Network Connection" for domain join) | Customer's own Azure subscription |
| Assignment model | 1:1 dedicated Cloud PC per user (except Windows 365 Flex, formerly Frontline: pooled — see `Flex-A.md`) | 1:N pooled or 1:1 personal host pools |
| Profile management | OS disk itself persists — no FSLogix needed | FSLogix required for pooled; optional for personal |
| Licensing | Per-user monthly SKU (fixed vCPU/RAM/storage tier) | Pay-as-you-go compute + separate AVD access rights |
| Provisioning | Automatic on license assignment via Provisioning Policy | Manual VM deployment (ARM/Bicep/Portal) |
| Scaling | Resize action changes tier; no autoscale plans | Autoscale plans control host pool size |

### Provisioning Policy pipeline

1. A **Provisioning Policy** defines: source image (Microsoft-managed gallery image or custom image from Azure Compute Gallery), domain join configuration, naming template, language/region, and Windows Autopatch enrollment.
2. The policy is **assigned** to a user or group (Entra ID security group).
3. When a licensed user falls into scope of an assigned policy, the **Cloud PC Management Service** creates a Cloud PC object and triggers VM creation in a Microsoft-managed subscription.
4. **Domain join configuration** determines what happens next:
   - **Entra ID joined** (cloud-native): no on-prem dependency; VM joins Entra ID directly; fastest and simplest path, Microsoft's recommended default since 2023.
   - **Entra hybrid joined**: requires an **Azure Network Connection (ANC)** that peers/VPNs into the customer's on-prem network so the VM can complete a domain join against an on-prem or IaaS domain controller, then Entra Connect sync brings the device object into Entra ID.
   - **AD DS joined only** (legacy, being phased toward hybrid): same ANC requirement, but the device does not register in Entra ID directly — since this limits Conditional Access enforcement, it is not recommended for new deployments.
5. After OS provisioning, the Cloud PC **enrolls into Intune automatically** as a managed device (Windows 365 requires Intune — there is no unmanaged Windows 365 model).
6. The Windows 365 agent installs, registers with the AVD-based connection broker, and the Cloud PC becomes available in `windows365.microsoft.com` and the Windows App.

### Licensing model

Windows 365 Enterprise and Business SKUs are named `Windows 365 <Enterprise|Business> <vCPU>vCPU/<RAM>GB/<Storage>GB`. Each SKU is a **fixed-size** allocation — there is no separate compute billing. Assigning the license is what triggers provisioning; removing/deprovisioning triggers a grace period before the Cloud PC and its data are deleted (default 7 days after license removal, configurable).

Group-based licensing works exactly like any other Entra ID group-based license assignment — group membership changes must propagate through Entra ID's license processing pipeline before Windows 365 provisioning starts, which is a common source of "why hasn't the Cloud PC shown up yet" tickets.

### Windows 365 Flex (formerly Frontline) — aside

Windows 365 Frontline was renamed to **Windows 365 Flex** on 2026-05-08 (same product, no functional change, no migration required — the Intune admin center's own "Frontline Type" device property column had not yet been renamed to match as of this writing). Flex uses a pooled, ratio-based licensing model across two modes — Dedicated (up to 3 Cloud PCs per license, 1 concurrent session, with a limited concurrency buffer) and Shared (1 Cloud PC per license, shared non-concurrently, no buffer, no persistence). "No Cloud PC available" errors under Flex reflect pool/concurrency exhaustion, not per-user misconfiguration. Full coverage: `Flex-A.md` (deep dive) and `Flex-B.md` (hotfix).

</details>

---
## Dependency Stack

```
Entra ID (Identity)
  └── User account + Windows 365 license (direct or group-based)
        └── Provisioning Policy (assigned to user/group)
              ├── Source Image (Gallery or Custom via Azure Compute Gallery)
              ├── Naming template + region
              ├── Windows Autopatch enrollment (optional)
              └── Domain Join Configuration
                    ├── Entra ID Joined — no further network dependency
                    ├── Entra Hybrid Joined ─┐
                    └── AD DS Joined ─────────┴── Azure Network Connection (ANC)
                                                    ├── VNET peered/VPN/ExpressRoute to on-prem
                                                    ├── DNS resolution to AD domain
                                                    ├── Outbound 443 to Windows 365 / AVD service tags
                                                    └── Health checks: identity, DNS, NSG, UDR, subnet capacity
                                                          └── Cloud PC VM (Microsoft-managed subscription)
                                                                ├── Windows 365 Agent
                                                                ├── Intune Enrollment (mandatory)
                                                                │     └── Compliance Policy + Configuration Profiles
                                                                ├── Windows Autopatch (if enrolled)
                                                                └── AVD Connection Broker registration
                                                                      └── User's local device/client
                                                                            ├── Windows App / Remote Desktop client / Browser
                                                                            ├── Outbound 443 to windows365.microsoft.com, *.wvd.microsoft.com
                                                                            └── Conditional Access evaluation (local device + Cloud PC both in scope potentially)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| No Cloud PC created after license assignment | Group-based license processing lag; provisioning policy not assigned to user's scope | `Get-MgUserLicenseDetail`; provisioning policy assignments |
| Status `pendingProvisioning` for hours | Policy assignment misconfigured; capacity constraints in region | Provisioning policy assignment; try alternate region |
| Status `failed` — `networkConfigurationError` | ANC unhealthy (hybrid/AD DS join only) | ANC health check status |
| Status `failed` — `internalServerError` | Transient service-side issue | Retry reprovision; if repeats, open MS support case |
| Cloud PC provisioned but not in Intune | Enrollment failed post-VM-creation, often Autopilot/ESP profile gating | `Get-MgDeviceManagementManagedDevice`; Intune enrollment logs |
| Domain join succeeded but Entra ID device object missing | Entra Connect sync cycle hasn't run, or hybrid join Entra Connect config broken | Entra Connect sync status; `dsregcmd /status` on Cloud PC |
| User can't connect — backend healthy | Local device Conditional Access block; stale client cache; local network egress blocked | CA sign-in logs scoped to Windows 365 app; client cache reset |
| Resize action fails | Target service plan not licensed to user; Cloud PC not in stable `provisioned` state | License assignment; Cloud PC status before resize |
| Reprovision doesn't fix issue | Underlying ANC/network problem persists — rebuilding the VM doesn't fix network path | Re-check ANC health independently of Cloud PC status |
| User reports data loss after "fix" | Reprovision was used instead of resize/restart | Confirm exact action taken; this is not reversible |

---
## Validation Steps

**1. Confirm Graph connection and required scopes**
```powershell
Connect-MgGraph -Scopes "CloudPC.ReadWrite.All","DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All"
Get-MgContext | Select-Object Scopes
```
Expected: All three scopes present.

**2. Enumerate all Cloud PCs and status**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Select-Object DisplayName, UserPrincipalName, Status, ProvisioningType, ServicePlanName |
    Sort-Object Status | Format-Table -AutoSize
```
Expected: Majority `provisioned`. Any `failed`/`pendingProvisioning` clusters point to a systemic issue (policy or ANC), not a per-user issue.

**3. Validate provisioning policy assignment scope**
```powershell
$policies = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy
foreach ($p in $policies) {
    Write-Host "Policy: $($p.DisplayName)"
    Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId $p.Id |
        Select-Object Target
}
```
Expected: Every production user group is covered by exactly one policy. Overlapping assignments across policies causes ambiguous provisioning behavior.

**4. Validate ANC health (hybrid/AD DS only)**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointOnPremisesConnection |
    Select-Object DisplayName, HealthCheckStatus, ErrorType
```
Expected: `healthy`. Run health check on demand if stale:
```powershell
Invoke-MgBetaDeviceManagementVirtualEndpointOnPremisesConnectionHealthCheck -OnPremisesConnectionId "<anc-id>"
```

**5. Validate Cloud PC is a managed Intune device**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" |
    Where-Object { $_.DeviceName -like "*CloudPC*" -or $_.Model -like "*Cloud PC*" } |
    Select-Object DeviceName, ComplianceState, LastSyncDateTime
```
Expected: Compliant, recent sync. Absence here after `provisioned` status means enrollment failed silently — check Intune enrollment failure logs.

**6. Validate client-side connectivity**
```powershell
$endpoints = @("windows365.microsoft.com","rdweb.wvd.microsoft.com","rdbroker.wvd.microsoft.com","login.microsoftonline.com")
foreach ($ep in $endpoints) {
    $t = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    "$ep`:443 — $(if($t.TcpTestSucceeded){'OK'}else{'FAIL'})"
}
```
Expected: All `OK` from the user's local device.

---
## Troubleshooting Steps (by phase)

### Phase 1: Pre-Provisioning (license assigned, no Cloud PC appears)

1. Confirm the license SKU is actually consumed, not just assigned-pending — check `AssignedLicenses` vs `LicenseDetails`
2. Confirm the user (or their group) falls within a Provisioning Policy assignment
3. If group-based, check group membership propagation timing — this can lag several hours
4. Check regional capacity — some Azure regions have Windows 365 provisioning capacity constraints during peak periods

### Phase 2: Provisioning (Cloud PC object exists, stuck or failed)

1. Read the exact `StatusDetails` error code — do not guess; the code determines the fix path
2. If `networkConfigurationError` — jump to ANC health check (this is not fixed by reprovisioning)
3. If `internalServerError` — retry once via reprovision; if it recurs 2+ times, this needs a Microsoft support case, not further local troubleshooting
4. Confirm the source image itself is valid and not deprecated (custom images from Azure Compute Gallery can go stale)

### Phase 3: Post-Provisioning (Cloud PC shows provisioned, but unusable)

1. Confirm Intune enrollment completed — a provisioned-but-unenrolled Cloud PC cannot receive compliance/config policies and may be blocked by CA
2. Check Windows Autopatch enrollment status if the tenant uses it — patching gaps show up here first
3. Validate `dsregcmd /status` on the Cloud PC itself (via Remote Help or a working session) for hybrid-joined devices — confirm `AzureAdJoined` and `DomainJoined` are both `YES` if hybrid

### Phase 4: Client / Connection Issues (backend fully healthy)

1. Check Conditional Access sign-in logs scoped to the "Windows 365" and "Azure Virtual Desktop" cloud apps separately — they are evaluated independently
2. Reset local client cache (Windows App / RD client) before assuming a backend fault
3. Confirm the local device meets any CA compliance requirement if such a policy targets the local device rather than (or in addition to) the Cloud PC

---
## Remediation Playbooks

<details><summary>Playbook 1 — Systemic Provisioning Failure Across Multiple Users</summary>

Use when: More than one user in the same provisioning policy is failing with the same error code.

```powershell
# Step 1: Confirm it's policy-wide, not isolated
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object Status -eq "failed" |
    Select-Object UserPrincipalName, StatusDetails

# Step 2: Check the shared dependency — ANC health first (most common systemic cause)
Get-MgBetaDeviceManagementVirtualEndpointOnPremisesConnection | Select-Object DisplayName, HealthCheckStatus

# Step 3: If ANC unhealthy, fix networking (VPN/ExpressRoute/DNS/NSG) BEFORE retrying any Cloud PC
# Reprovisioning individual Cloud PCs while ANC is unhealthy will fail again — fix the shared dependency first

# Step 4: Once ANC healthy, bulk retry
$failed = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All | Where-Object Status -eq "failed"
foreach ($cpc in $failed) {
    Invoke-MgBetaReprovisionDeviceManagementVirtualEndpointCloudPc -CloudPcId $cpc.Id
    Start-Sleep -Seconds 5
}
```

**Rollback:** N/A for diagnosis steps. Reprovisioning remains destructive per-Cloud PC — communicate to affected users before bulk action.

</details>

<details><summary>Playbook 2 — Migrate a Cloud PC from AD DS Join to Entra Hybrid or Entra ID Join</summary>

Use when: Reducing on-prem dependency, improving Conditional Access coverage, or ANC issues are chronic.

```powershell
# Step 1: Create a new provisioning policy with the desired join type
New-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -BodyParameter @{
    displayName = "Cloud PC - Entra ID Joined"
    domainJoinConfigurations = @(
        @{ domainJoinType = "azureADJoin" }
    )
    imageId = "<gallery-image-id>"
}

# Step 2: Reassign affected users' license/group to the new policy scope
# (This requires removing them from the old policy's assigned group and adding to the new one)

# Step 3: Existing Cloud PC is NOT automatically migrated — user's data must be migrated manually
# (OneDrive Known Folder Move should already be covering user data if profile redirection is configured)

# Step 4: Once the new Cloud PC provisions and user confirms data access, deprovision the old one
# by removing the old license assignment
```

**Rollback:** Keep the old Cloud PC provisioned until the new one is validated by the end user — do not remove the old license until confirmed, since deprovisioning starts an irreversible grace-period deletion countdown.

</details>

<details><summary>Playbook 3 — Recover from Accidental Reprovision (Data Loss Mitigation)</summary>

Use when: A technician reprovisioned a Cloud PC by mistake and the user lost local data.

```powershell
# There is no way to recover a reprovisioned OS disk — Windows 365 does not retain
# the previous disk after reprovision starts. Recovery options are limited to:

# 1. Check if OneDrive Known Folder Move (KFM) was enabled — Desktop/Documents/Pictures
#    may be recoverable from OneDrive version history even though the local Cloud PC disk is gone
# Get-MgUserDrive -UserId "<user@domain.com>"

# 2. Check for any file server / DFS redirected folders if configured via GPO/Intune ADMX
#    (redirected folders, unlike KFM, live outside the OS disk entirely)

# 3. Document the incident and update SOP: reprovision requires explicit user data-loss
#    acknowledgment before running, going forward — this is a process fix, not a technical one
```

**Prevention:** Always confirm intended action (resize vs. reprovision vs. restart) verbally with the requester before executing; consider requiring a change ticket note explicitly stating "Reprovision approved — data loss acknowledged" before this specific Graph call is run.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Windows 365 diagnostic evidence for a specific user's Cloud PC
.NOTES     Requires Microsoft.Graph.Beta module and CloudPC.Read.All scope
#>

param(
    [Parameter(Mandatory)]
    [string]$UserPrincipalName
)

$outputPath = "C:\W365_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# Cloud PC object detail
$cloudPc = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '$UserPrincipalName'"
$cloudPc | ConvertTo-Json -Depth 5 | Out-File "$outputPath\cloudpc_detail.json"

# License detail
Get-MgUserLicenseDetail -UserId $UserPrincipalName |
    Select-Object SkuPartNumber, ServicePlans | Export-Csv "$outputPath\license_detail.csv" -NoTypeInformation

# Provisioning policy assignment
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy |
    Select-Object DisplayName, Id, ImageDisplayName | Export-Csv "$outputPath\provisioning_policies.csv" -NoTypeInformation

# ANC health (if applicable)
Get-MgBetaDeviceManagementVirtualEndpointOnPremisesConnection |
    Select-Object DisplayName, HealthCheckStatus, ErrorType | Export-Csv "$outputPath\anc_health.csv" -NoTypeInformation

# Managed device compliance
Get-MgDeviceManagementManagedDevice -Filter "userPrincipalName eq '$UserPrincipalName'" |
    Select-Object DeviceName, ComplianceState, LastSyncDateTime | Export-Csv "$outputPath\managed_device.csv" -NoTypeInformation

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# List all Cloud PCs with status
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All | Select DisplayName,UserPrincipalName,Status

# Get a specific user's Cloud PC
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '<upn>'"

# Reprovision (destructive — wipes OS disk)
Invoke-MgBetaReprovisionDeviceManagementVirtualEndpointCloudPc -CloudPcId "<id>"

# Resize (non-destructive — requires target license)
Invoke-MgBetaResizeDeviceManagementVirtualEndpointCloudPc -CloudPcId "<id>" -TargetServicePlanId "<plan-id>"

# List provisioning policies
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy

# List ANCs and health
Get-MgBetaDeviceManagementVirtualEndpointOnPremisesConnection | Select DisplayName,HealthCheckStatus

# Trigger ANC health check
Invoke-MgBetaDeviceManagementVirtualEndpointOnPremisesConnectionHealthCheck -OnPremisesConnectionId "<id>"

# Check license detail for a user
Get-MgUserLicenseDetail -UserId "<upn>"

# Check managed device (Cloud PC as Intune endpoint)
Get-MgDeviceManagementManagedDevice -Filter "userPrincipalName eq '<upn>'"

# Restart a Cloud PC (non-destructive, safe first step for hung sessions)
Invoke-MgBetaDeviceManagementVirtualEndpointCloudPcRestart -CloudPcId "<id>"

# End a stuck grace period / troubleshoot deprovisioning
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "status eq 'inGracePeriod'"
```

---
## 🎓 Learning Pointers

- **Windows 365 is Intune-mandatory, no exceptions**: Unlike AVD where management is optional, every Windows 365 Cloud PC auto-enrolls into Intune as a condition of the service. If Intune enrollment fails post-provisioning, the Cloud PC exists but cannot be governed by compliance/config policy — treat this as a P1, not a cosmetic gap. Reference: [Windows 365 and Intune](https://learn.microsoft.com/en-us/windows-365/enterprise/mdm-enroll)
- **The grace period is a safety net, not a delay**: When a license is removed, the Cloud PC enters a grace period (default 7 days, configurable up to longer for some SKUs) before deletion — use this window deliberately when troubleshooting license/assignment mistakes rather than immediately reprovisioning a replacement. Reference: [Manage grace period](https://learn.microsoft.com/en-us/windows-365/enterprise/grace-period)
- **ANC health is a leading indicator, not a lagging one**: An unhealthy ANC blocks *new* provisioning and reprovisioning but does not affect already-running Cloud PCs — don't assume user-reported "Cloud PC is slow" issues are ANC-related; check AVD-side session host telemetry for that instead (`Azure/AVD/AVD-A.md`). Reference: [Azure network connections](https://learn.microsoft.com/en-us/windows-365/enterprise/azure-network-connection)
- **Group-based licensing timing compounds with provisioning policy assignment timing**: Two separate propagation delays stack — group membership → license (Entra ID processing) and license → provisioning policy scope (Cloud PC service processing). For urgent onboarding, use direct license assignment to eliminate the first delay. Reference: [License Windows 365](https://learn.microsoft.com/en-us/windows-365/enterprise/provision-assign-license)
- **Windows Autopatch integration**: Cloud PCs can be enrolled into Windows Autopatch at the provisioning policy level — if patch compliance looks inconsistent across your Cloud PC fleet, check whether Autopatch enrollment was actually selected in the policy, not assumed from the general Autopatch tenant enrollment. Reference: [Windows Autopatch for Cloud PCs](https://learn.microsoft.com/en-us/windows/deployment/windows-autopatch/deploy/windows-autopatch-add-devices)
- **Resize is the underused, safer alternative**: Techs default to reprovisioning when a user needs more resources, destroying local data unnecessarily — resize should always be evaluated first since it preserves the OS disk. Build this into your standard triage script/checklist. Reference: [Resize a Cloud PC](https://learn.microsoft.com/en-us/windows-365/enterprise/resize)
