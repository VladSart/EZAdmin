# Windows 365 Cloud PC — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run these first. Interpret results to choose a fix path.

```powershell
# 1. Check Cloud PC provisioning status for a user (requires Microsoft.Graph.Beta or Graph Explorer)
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '<user@domain.com>'" |
    Select-Object DisplayName, Status, ProvisioningType, ServicePlanName

# 2. Check provisioning policy assignment and health
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy |
    Select-Object DisplayName, Id, ProvisioningType, DomainJoinConfigurations

# 3. Check Azure network connection (ANC) health (Entra-joined / hybrid-joined deployments)
Get-MgBetaDeviceManagementVirtualEndpointOnPremisesConnection |
    Select-Object DisplayName, HealthCheckStatus, ErrorType

# 4. Check the user's license (Windows 365 Enterprise/Business SKU)
Get-MgUserLicenseDetail -UserId "<user@domain.com>" |
    Select-Object SkuPartNumber, ServicePlans

# 5. Check Cloud PC device health from the Intune blade (device must show up as a managed device)
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<cloudpc-name>'" |
    Select-Object DeviceName, ComplianceState, LastSyncDateTime, ManagementState
```

| Result | Action |
|--------|--------|
| Cloud PC Status = `provisionedWithWarnings` or `failed` | → [Fix 1 — Retry / Reprovision Cloud PC](#fix-1--retry--reprovision-cloud-pc) |
| Status = `pendingProvisioning` for >4 hours | → [Fix 2 — Check Provisioning Policy & License](#fix-2--check-provisioning-policy--license) |
| ANC HealthCheckStatus = `failed` | → [Fix 3 — Repair Azure Network Connection](#fix-3--repair-azure-network-connection) |
| User has no Windows 365 license assigned | → [Fix 2 — Check Provisioning Policy & License](#fix-2--check-provisioning-policy--license) |
| Cloud PC provisioned but user reports "can't connect" | → [Fix 4 — Client Connectivity / Frontend Issue](#fix-4--client-connectivity--frontend-issue) |
| User needs more resources (CPU/RAM/storage) | → [Fix 5 — Resize Cloud PC](#fix-5--resize-cloud-pc) |
| All triage clean, still failing | → Escalate — open a Microsoft 365 admin center service request under Windows 365 |

---
## Dependency Cascade

<details><summary>What must be true for a Cloud PC to provision and connect</summary>

```
Entra ID (Identity)
  └── User licensed (Windows 365 Enterprise or Business SKU)
        └── User in scope of a Provisioning Policy
              ├── Image (Gallery image or custom image from Azure Compute Gallery)
              ├── Domain join configuration
              │     ├── Entra ID joined (cloud-native) — no ANC required
              │     ├── Entra hybrid joined — requires Azure Network Connection (ANC)
              │     └── AD DS joined (legacy) — requires ANC + on-prem DC line-of-sight
              └── Azure Network Connection (if hybrid/AD DS joined)
                    ├── VNET with connectivity to on-prem (VPN/ExpressRoute)
                    ├── DNS resolution to on-prem DCs
                    ├── Outbound HTTPS (443) to Windows 365 service endpoints
                    └── Health check passing (identity, DNS, NSG, UDR checks)
                          └── Cloud PC VM provisioned in Microsoft-managed subscription
                                ├── Windows 365 agent installed
                                ├── Intune enrollment (Cloud PC = managed device)
                                └── Windows 365 web/app client connection
                                      └── User's local device (any OS) reaching windows365.microsoft.com
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm license assignment**
```powershell
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Select-Object SkuPartNumber
```
Expected: One of `CPC_E_*` (Enterprise) or `CPC_B_*` (Business) SKUs present. If missing → assign license, provisioning starts automatically within ~15 min (direct assignment) or on next sync (group-based).

**Step 2 — Check provisioning status in the Cloud PC blade**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '<user@domain.com>'" |
    Select-Object DisplayName, Status, ProvisioningType, LastModifiedDateTime, StatusDetails
```
Expected: `Status = provisioned`. If `failed`, `StatusDetails` will contain an error code — most common is `internalServerError` (transient, retry) or `networkConfigurationError` (ANC problem).

**Step 3 — Check Azure Network Connection health (hybrid/AD DS joined only)**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointOnPremisesConnection |
    Select-Object DisplayName, HealthCheckStatus, ErrorType, InboundOutboundNetworkCheck
```
Expected: `HealthCheckStatus = healthy`. Any `unhealthy` result blocks all new provisioning and reprovisioning through that connection.

**Step 4 — Confirm Cloud PC shows as a managed device in Intune**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<cloudpc-name>'" |
    Select-Object DeviceName, ComplianceState, LastSyncDateTime, OperatingSystem
```
Expected: Device present, `ComplianceState = compliant`, recent `LastSyncDateTime`. A provisioned Cloud PC that never appears in Intune indicates enrollment failed after VM creation — check Autopilot/ESP profile assignment for Cloud PCs if using Enrollment Status Page gating.

**Step 5 — Validate end-user connectivity path**
```powershell
# From the user's local device
Test-NetConnection -ComputerName "windows365.microsoft.com" -Port 443
Test-NetConnection -ComputerName "rdweb.wvd.microsoft.com" -Port 443
```
Expected: Both `TcpTestSucceeded = True`. Windows 365 uses the same AVD-based connection broker under the hood — the same outbound URL list applies on the client side.

---
## Common Fix Paths

<details><summary>Fix 1 — Retry / Reprovision Cloud PC</summary>

**When:** Status shows `failed` or `provisionedWithWarnings` and no ANC issue is present.

```powershell
# Get the Cloud PC ID
$cloudPc = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '<user@domain.com>'"

# Reprovision (rebuilds the Cloud PC from the image — destructive, wipes user data on the Cloud PC)
Invoke-MgBetaReprovisionDeviceManagementVirtualEndpointCloudPc -CloudPcId $cloudPc.Id

# Alternative: trigger a resync of the provisioning policy without a full rebuild
Invoke-MgBetaSyncDeviceManagementVirtualEndpointOnPremisesConnection -OnPremisesConnectionId "<anc-id>"
```

**Rollback:** Reprovisioning is destructive — local Cloud PC data (anything not in OneDrive/redirected folders) is lost. Warn the user first. There is no undo once reprovisioning starts; it typically completes in 30–60 minutes.

</details>

<details><summary>Fix 2 — Check Provisioning Policy & License</summary>

**When:** Cloud PC stuck in `pendingProvisioning`, or user has no Cloud PC object at all.

```powershell
# Confirm the user (or their group) is in scope of a provisioning policy
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy |
    ForEach-Object {
        Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId $_.Id
    }

# Confirm license is actually consumed (not just assigned pending sync)
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Select-Object SkuPartNumber, ServicePlans

# Force a manual license-triggered provisioning check via Graph (if group-based licensing lag suspected)
# No direct cmdlet — verify group membership propagation:
Get-MgGroupMember -GroupId "<w365-license-group-id>" | Where-Object Id -eq "<user-object-id>"
```

**Common miss:** User was added to the licensing group but Entra ID group-to-license processing can lag up to several hours in large tenants. Direct license assignment provisions faster than group-based for urgent cases.

**Rollback:** N/A — this is an assignment fix, not a destructive action.

</details>

<details><summary>Fix 3 — Repair Azure Network Connection</summary>

**When:** ANC `HealthCheckStatus = unhealthy`; affects hybrid or AD DS domain-joined Cloud PCs only.

```powershell
# Re-run health checks on the ANC
Invoke-MgBetaDeviceManagementVirtualEndpointOnPremisesConnectionHealthCheck -OnPremisesConnectionId "<anc-id>"

# Get detailed check results
Get-MgBetaDeviceManagementVirtualEndpointOnPremisesConnectionHealthCheckStatus -OnPremisesConnectionId "<anc-id>" |
    Select-Object DisplayName, AdditionalDetails, Status
```

**Common ANC failure causes (check in this order):**
1. VNET peering/VPN/ExpressRoute to on-prem is down — verify from Azure Network Watcher
2. DNS servers configured on the VNET can't resolve the AD domain — test with `Resolve-DnsName <domain.com> -Server <dns-ip>`
3. NSG or firewall blocking outbound 443 to Windows 365 service tags (`WindowsVirtualDesktop`, `AzureCloud`)
4. Service account used for domain join has expired password or insufficient permissions (needs "create computer objects" in the target OU)

**Rollback:** Non-destructive — health checks are read-only. Fixing the underlying network issue does not affect already-provisioned Cloud PCs; only new provisioning/reprovisioning is blocked while unhealthy.

</details>

<details><summary>Fix 4 — Client Connectivity / Frontend Issue</summary>

**When:** Cloud PC shows `provisioned` and healthy in the backend, but user cannot connect via windows365.microsoft.com or the Windows App.

```powershell
# From the user's local device — clear cached connection state
# Windows App / Remote Desktop client:
Get-Process "MSRDC","Windows365" -ErrorAction SilentlyContinue | Stop-Process -Force

# Clear the Remote Desktop client cache
Remove-Item "$env:LOCALAPPDATA\Microsoft\RdClientRadc" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:APPDATA\Microsoft\Windows365" -Recurse -Force -ErrorAction SilentlyContinue

# Re-launch and re-authenticate
```

**Also check:** Conditional Access policies scoped to "Windows 365" or "Azure Virtual Desktop" cloud apps — a CA policy requiring compliant device can block the *local* device from reaching the web client if it's unmanaged, even though the Cloud PC itself is compliant.

**Rollback:** Clearing client cache is non-destructive; user simply re-authenticates.

</details>

<details><summary>Fix 5 — Resize Cloud PC</summary>

**When:** User needs a different vCPU/RAM/storage configuration than currently provisioned.

```powershell
# List available Cloud PCs eligible for resize (via portal: Devices > Windows 365 > Resize)
# Graph resize action:
$cloudPc = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '<user@domain.com>'"

Invoke-MgBetaResizeDeviceManagementVirtualEndpointCloudPc -CloudPcId $cloudPc.Id `
    -TargetServicePlanId "<new-service-plan-id>"
```

**Note:** Resize requires a compatible target license (e.g., moving from a 2vCPU/8GB plan to 4vCPU/16GB plan) already assigned to the user, and the source Cloud PC must be in a `provisioned` state (not mid-reprovision). Resize is a managed operation — user is signed out during the process (~30 min) but data on the OS disk is preserved (unlike reprovisioning).

**Rollback:** Resize can be reversed by resizing back to the original license/service plan if the user already holds it.

</details>

---
## Escalation Evidence

Copy this template, fill in all fields, attach to ticket before escalating to Microsoft Support.

```
=== WINDOWS 365 ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Affected user(s): _______________
Tenant ID: _______________
Cloud PC Display Name: _______________
Provisioning Policy Name: _______________
Domain Join Type: [ ] Entra ID Joined  [ ] Entra Hybrid Joined  [ ] AD DS Joined

SYMPTOM:
[ ] Cloud PC stuck in pendingProvisioning
[ ] Provisioning failed
[ ] ANC unhealthy
[ ] Client cannot connect (backend healthy)
[ ] Resize failed
[ ] Other: _______________

TRIAGE RESULTS:
License SKU: _______________
Cloud PC Status: _______________
Status Details / Error Code: _______________
ANC Health Check Status: _______________
Managed Device Compliance State: _______________

ACTIONS TAKEN:
_______________

CORRELATION ID / Request ID: _______________
SERVICE PLAN ID: _______________
IMAGE NAME/VERSION: _______________
```

---
## 🎓 Learning Pointers

- **Windows 365 vs. AVD — same broker, different ownership model**: Windows 365 uses the same AVD connection broker and gateway infrastructure under the hood, but the VM is a fixed 1:1 dedicated Cloud PC per user, not a pooled multi-session host. This is why Windows 365 has no host pool load balancing concept and no FSLogix requirement — the OS disk itself persists per user. Reference: [Windows 365 vs. AVD](https://learn.microsoft.com/en-us/windows-365/enterprise/compare-windows-365-azure-virtual-desktop)
- **Reprovision vs. Resize — know the difference before you click**: Reprovision wipes the OS disk and rebuilds from the source image (destructive to local data); Resize changes compute/storage tier while preserving the OS disk. Confusing these is the single most common self-inflicted Windows 365 incident from support techs. Reference: [Reprovision and resize Cloud PCs](https://learn.microsoft.com/en-us/windows-365/enterprise/reprovision)
- **Azure Network Connections only matter for hybrid/AD DS join**: Fully Entra ID-joined Cloud PCs (the modern, recommended path) need no ANC and no on-prem line-of-sight at all — provisioning failures on these are almost always licensing or Intune enrollment related, not networking. Reference: [Azure network connections](https://learn.microsoft.com/en-us/windows-365/enterprise/azure-network-connection)
- **Group-based licensing lag is real**: For time-sensitive Cloud PC requests, direct license assignment provisions markedly faster than adding a user to a dynamic/assigned licensing group, since group processing itself can take hours before Windows 365 even sees the license. Reference: [Provision Cloud PCs](https://learn.microsoft.com/en-us/windows-365/enterprise/provision-assign-license)
- **Windows 365 Flex (formerly Frontline) vs. Enterprise/Business editions**: Frontline was renamed to Flex on 2026-05-08 — same product. Flex uses pooled licensing across Dedicated and Shared modes (fewer licenses than users, ratio-based) — a "no Cloud PC available" error there means the pool/concurrency is fully checked out, not that licensing is misconfigured, and Resize (Fix 5 above) is not a supported action for Flex. Full coverage: `Flex-A.md`/`Flex-B.md`. Reference: [What is Windows 365 Flex?](https://learn.microsoft.com/en-us/windows-365/enterprise/introduction-windows-365-flex)
- **Conditional Access scoping gotcha**: CA policies aimed at protecting the Cloud PC itself must target the "Windows 365" cloud app; policies aimed at controlling *access to* the web client from the local device must also account for the local device's own compliance state — these are two separate enforcement points and are frequently conflated during design.
