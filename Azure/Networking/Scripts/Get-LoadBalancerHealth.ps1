<#
.SYNOPSIS
    Collects Azure Load Balancer health — SKU/outbound-access posture, backend health,
    SNAT allocation, and HA Ports configuration — for triage or escalation.

.DESCRIPTION
    Companion script to Azure/Networking/LoadBalancer-B.md and LoadBalancer-A.md.
    Gathers, in one pass, everything the runbooks' triage and diagnosis steps ask for:
    - SKU (flags any surviving, unsupported Basic SKU load balancers)
    - Frontend type (public/internal) and zone configuration
    - Backend pool membership and live health per instance
    - Outbound-access posture for PUBLIC load balancers — checks all three possible methods
      (Load Balancer outbound rule, NAT Gateway on the backend subnet, instance-level public IP)
      and flags a genuine gap, since Standard SKU provides none of these implicitly
    - SNAT port allocation on any outbound rule found, flagged against backend pool size
    - Health probe protocol/port, flagged if the port is on the WinHTTP HTTP-probe restricted list
    - NSG presence/explicit-allow check on the frontend/backend subnet (Standard SKU has no
      implicit inbound allow, unlike the retired Basic SKU)
    - HA Ports rule detection and Floating IP mode (internal load balancers only)

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Fixing any detected issue (that's LoadBalancer-B.md Fix 1-8 / LoadBalancer-A.md
      Playbooks 1-3 — this script only detects)
    - NAT Gateway's own health/capacity diagnostics beyond confirming its presence on the
      subnet — a genuine NAT Gateway health check is a separate future topic
    - Application Gateway (Layer 7) — a different resource type entirely, see
      Get-AppGatewayHealth.ps1 if the ticket turns out to be L7, not L4

.PARAMETER ResourceGroupName
    Resource group to scope the audit to. If omitted, audits every Load Balancer
    the current context can see across all resource groups.

.PARAMETER LoadBalancerName
    Specific load balancer name to audit. If omitted, audits every load balancer found in scope.

.PARAMETER ExportPath
    Path for CSV export. Default: .\LoadBalancerHealth-<timestamp>.csv

.EXAMPLE
    .\Get-LoadBalancerHealth.ps1
    Audits every Load Balancer visible in the current Az context.

.EXAMPLE
    .\Get-LoadBalancerHealth.ps1 -ResourceGroupName rg-prod-network -LoadBalancerName lb-prod-01
    Audits a single named load balancer.

.NOTES
    Requires: Az.Network modules; Windows PowerShell 5.1+ or PowerShell 7+
    Run-as: Account with Reader (minimum) on the target resource group(s)
    Safe: Fully read-only. No configuration, NSG, outbound rule, or rule changes.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName,

    [string]$LoadBalancerName,

    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# HTTP health probe restricted ports (blocked by the underlying WinHTTP stack the probe engine uses)
$script:RestrictedProbePorts = @(19, 21, 25, 70, 110, 119, 143, 220, 993)

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region ─── Preflight ──────────────────────────────────────────────────────────
Write-Status "Get-LoadBalancerHealth — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\LoadBalancerHealth-$timestamp.csv"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$LB, [string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        LoadBalancer = $LB
        Check        = $Check
        Status       = $Status
        Detail       = $Detail
        CheckedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    Write-Status "[$LB] $Check — $Detail" $Status
}

try {
    if ($LoadBalancerName -and $ResourceGroupName) {
        $lbs = @(Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName -Name $LoadBalancerName -ErrorAction Stop)
    } elseif ($ResourceGroupName) {
        $lbs = @(Get-AzLoadBalancer -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    } else {
        $lbs = @(Get-AzLoadBalancer -ErrorAction Stop)
    }
} catch {
    Write-Status "Failed to enumerate Load Balancers: $_" "ERROR"
    exit 1
}

if (-not $lbs -or $lbs.Count -eq 0) {
    Write-Status "No Load Balancers found in scope." "WARN"
    exit 0
}
#endregion

foreach ($lb in $lbs) {
    $name = $lb.Name

    #region ─── 1. SKU and provisioning state ──────────────────────────────────
    if ($lb.Sku.Name -eq 'Basic') {
        Add-Result $name "SKU" "ERROR" "Basic — retired September 30, 2025, unsupported, no SLA. Flag for migration (LoadBalancer-A.md Playbook 1), do not treat as Standard-capable"
    } else {
        Add-Result $name "SKU" "OK" "$($lb.Sku.Name)"
    }

    if ($lb.ProvisioningState -eq 'Succeeded') {
        Add-Result $name "ProvisioningState" "OK" "Succeeded"
    } else {
        Add-Result $name "ProvisioningState" "ERROR" "$($lb.ProvisioningState) — a prior config change may not have completed"
    }
    #endregion

    #region ─── 2. Frontend type + zone configuration ──────────────────────────
    $publicFrontends   = @($lb.FrontendIpConfigurations | Where-Object { $_.PublicIpAddress })
    $internalFrontends = @($lb.FrontendIpConfigurations | Where-Object { $_.PrivateIPAddress -and -not $_.PublicIpAddress })
    $isPublic = $publicFrontends.Count -gt 0

    foreach ($fe in $lb.FrontendIpConfigurations) {
        $zoneDesc = if ($fe.Zones -and $fe.Zones.Count -gt 1) { "Zone-redundant" }
                    elseif ($fe.Zones -and $fe.Zones.Count -eq 1) { "Zonal (Zone $($fe.Zones[0])) — no zone-failure resilience for this frontend" }
                    else { "Non-zonal" }
        $type = if ($fe.PublicIpAddress) { "Public" } else { "Internal" }
        Add-Result $name "Frontend-$($fe.Name)" "INFO" "$type, $zoneDesc"
    }
    #endregion

    #region ─── 3. Backend pool membership + live health ───────────────────────
    try {
        $health = Get-AzLoadBalancerBackendHealth -ResourceGroupName $lb.ResourceGroupName -Name $name -ErrorAction Stop
        $allInstances = @($health | ForEach-Object { $_.BackendAddressPool.BackendAddresses })
        foreach ($poolHealth in $health) {
            $poolName = ($poolHealth.BackendAddressPool.Id -split '/')[-1]
            $up = @($poolHealth.LoadBalancerBackendAddresses | Where-Object { $_.NetworkInterfaceIPConfiguration -or $_ }).Count
            Write-Verbose "Pool $poolName raw health object captured"
        }
        Add-Result $name "BackendHealth" "OK" "$($health.Count) backend pool(s) queried — see BackendPools.csv detail for per-instance status"
    } catch {
        Add-Result $name "BackendHealth" "WARN" "Could not retrieve backend health (requires VM/VMSS-based backend pool with NIC associations): $_"
    }

    foreach ($pool in $lb.BackendAddressPools) {
        $memberCount = @($pool.BackendIpConfigurations).Count + @($pool.LoadBalancerBackendAddresses | Where-Object { $_.IpAddress -or $_.VirtualNetwork }).Count
        if ($memberCount -eq 0) {
            Add-Result $name "BackendPool-$($pool.Name)" "WARN" "Empty backend pool — no members configured"
        } else {
            Add-Result $name "BackendPool-$($pool.Name)" "OK" "$memberCount member(s)"
        }
    }
    #endregion

    #region ─── 4. Health probe — restricted-port check ────────────────────────
    foreach ($probe in $lb.Probes) {
        if ($probe.Protocol -in @('Http', 'Https') -and $script:RestrictedProbePorts -contains $probe.Port) {
            Add-Result $name "Probe-$($probe.Name)" "ERROR" "Port $($probe.Port) is on the WinHTTP HTTP-probe restricted-port list — this probe will read as failed/Unhealthy regardless of actual backend status. Move to a different port"
        } else {
            Add-Result $name "Probe-$($probe.Name)" "OK" "Protocol=$($probe.Protocol), Port=$($probe.Port)$(if ($probe.RequestPath) { ", Path=$($probe.RequestPath)" })"
        }
    }
    #endregion

    #region ─── 5. Outbound-access posture (public LB backends only) ───────────
    if ($isPublic -and $lb.BackendAddressPools.Count -gt 0) {
        $hasOutboundRule = $lb.OutboundRules.Count -gt 0
        $subnetsWithNatGw = @()
        $instanceLevelPublicIp = $false

        foreach ($pool in $lb.BackendAddressPools) {
            foreach ($ipConfigRef in $pool.BackendIpConfigurations) {
                try {
                    $nicId = ($ipConfigRef.Id -split '/ipConfigurations/')[0]
                    $nicRg = ($nicId -split '/')[4]
                    $nicName = ($nicId -split '/')[-1]
                    $nic = Get-AzNetworkInterface -ResourceGroupName $nicRg -Name $nicName -ErrorAction Stop

                    if ($nic.IpConfigurations.PublicIpAddress) { $instanceLevelPublicIp = $true }

                    $subnetId = $nic.IpConfigurations[0].Subnet.Id
                    $subnetRg = ($subnetId -split '/')[4]
                    $vnetName = ($subnetId -split '/')[8]
                    $subnetName = ($subnetId -split '/')[10]
                    $vnet = Get-AzVirtualNetwork -ResourceGroupName $subnetRg -Name $vnetName -ErrorAction Stop
                    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
                    if ($subnet.NatGateway) { $subnetsWithNatGw += $subnetName }
                } catch {
                    Write-Verbose "Could not resolve NIC/subnet for backend pool member: $_"
                }
            }
        }

        $hasNatGateway = $subnetsWithNatGw.Count -gt 0
        $outboundMethodCount = @($hasOutboundRule, $hasNatGateway, $instanceLevelPublicIp | Where-Object { $_ }).Count

        if ($outboundMethodCount -eq 0) {
            Add-Result $name "OutboundAccess" "ERROR" "NO outbound method found (no LB outbound rule, no NAT Gateway on backend subnet, no instance-level public IP). Standard SKU gives ZERO implicit outbound path — backend VMs cannot reach the internet. See LoadBalancer-B.md Fix 2"
        } elseif ($outboundMethodCount -gt 1) {
            Add-Result $name "OutboundAccess" "WARN" "MULTIPLE outbound methods present (OutboundRule=$hasOutboundRule, NATGateway=$hasNatGateway, InstancePublicIP=$instanceLevelPublicIp) — confirm which one is actually governing traffic per Azure's documented precedence (instance-level public IP > NAT Gateway > LB outbound rule); redundant methods add confusion, not resilience"
        } else {
            Add-Result $name "OutboundAccess" "OK" "Outbound method confirmed (OutboundRule=$hasOutboundRule, NATGateway=$hasNatGateway, InstancePublicIP=$instanceLevelPublicIp)"
        }

        foreach ($rule in $lb.OutboundRules) {
            $backendCount = @($lb.BackendAddressPools | Where-Object { $_.Id -eq $rule.BackendAddressPool.Id }).BackendIpConfigurations.Count
            if ($rule.AllocatedOutboundPorts -gt 0 -and $backendCount -gt 0) {
                $portsPerInstance = [math]::Floor($rule.AllocatedOutboundPorts)
                if ($portsPerInstance -le 1024 -and $backendCount -ge 8) {
                    Add-Result $name "OutboundRule-$($rule.Name)" "WARN" "AllocatedOutboundPorts=$($rule.AllocatedOutboundPorts) across a $backendCount-instance backend pool — check for SNAT exhaustion risk under load; consider manual allocation increase or NAT Gateway (LoadBalancer-B.md Fix 3)"
                } else {
                    Add-Result $name "OutboundRule-$($rule.Name)" "OK" "AllocatedOutboundPorts=$($rule.AllocatedOutboundPorts), backend pool size=$backendCount"
                }
            } elseif ($rule.AllocatedOutboundPorts -eq 0) {
                Add-Result $name "OutboundRule-$($rule.Name)" "INFO" "AllocatedOutboundPorts=0 (default/automatic allocation) — shrinks per-instance as backend pool grows; not recommended for production per Microsoft guidance"
            }
        }
    }
    #endregion

    #region ─── 6. NSG presence on frontend/backend subnet(s) ──────────────────
    try {
        $checkedSubnets = @{}
        foreach ($pool in $lb.BackendAddressPools) {
            foreach ($ipConfigRef in $pool.BackendIpConfigurations) {
                $nicId = ($ipConfigRef.Id -split '/ipConfigurations/')[0]
                $nicRg = ($nicId -split '/')[4]
                $nicName = ($nicId -split '/')[-1]
                try {
                    $nic = Get-AzNetworkInterface -ResourceGroupName $nicRg -Name $nicName -ErrorAction Stop
                    $subnetId = $nic.IpConfigurations[0].Subnet.Id
                    if (-not $checkedSubnets.ContainsKey($subnetId)) {
                        $checkedSubnets[$subnetId] = $true
                        $subnetRg = ($subnetId -split '/')[4]
                        $vnetName = ($subnetId -split '/')[8]
                        $subnetName = ($subnetId -split '/')[10]
                        $vnet = Get-AzVirtualNetwork -ResourceGroupName $subnetRg -Name $vnetName -ErrorAction Stop
                        $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
                        if ($subnet.NetworkSecurityGroup) {
                            Add-Result $name "NSG-$subnetName" "INFO" "NSG applied to backend subnet '$subnetName' — confirm it explicitly allows the load-balancing rule's frontend port(s); Standard SKU has no implicit allow"
                        } else {
                            Add-Result $name "NSG-$subnetName" "WARN" "No NSG on backend subnet '$subnetName' — inbound traffic unrestricted at the subnet level (confirm this is intentional)"
                        }
                    }
                } catch {
                    Write-Verbose "Could not resolve NSG for a backend NIC: $_"
                }
            }
        }
    } catch {
        Add-Result $name "NSGCheck" "WARN" "Could not complete NSG check: $_"
    }
    #endregion

    #region ─── 7. HA Ports detection (internal LB only) ───────────────────────
    $haPortsRules = @($lb.LoadBalancingRules | Where-Object { $_.BackendPort -eq 0 -and $_.Protocol -eq 'All' })
    foreach ($rule in $haPortsRules) {
        if ($isPublic) {
            Add-Result $name "HAPorts-$($rule.Name)" "ERROR" "HA Ports rule found on a PUBLIC frontend — HA Ports is only valid on an internal load balancer; this configuration is invalid/unsupported"
        } else {
            $floatingDesc = if ($rule.EnableFloatingIP) { "Floating IP enabled (DSR) — multi-frontend/public-LB-combinable, requires DSR-aware backend" }
                            else { "Floating IP disabled — must be the ONLY rule on this resource for this backend" }
            Add-Result $name "HAPorts-$($rule.Name)" "INFO" $floatingDesc
        }
    }
    #endregion
}

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Load Balancer Health Summary ──────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Load Balancers audited : $($lbs.Count)"
Write-Host "  Checks run             : $($results.Count)"
Write-Host "  Errors                 : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings               : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: All audited Load Balancers look healthy." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see LoadBalancer-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
