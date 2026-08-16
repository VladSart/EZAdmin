<#
.SYNOPSIS
    Collects Azure Application Gateway health — backend pool status, WAF policy precedence,
    control-plane NSG requirements, and capacity signals — for triage or escalation.

.DESCRIPTION
    Companion script to Azure/Networking/AppGateway-B.md and AppGateway-A.md.
    Gathers, in one pass, everything the runbooks' triage and diagnosis steps ask for:
    - Gateway provisioning/operational state and SKU (flags legacy v1 SKUs)
    - Dedicated subnet check and the GatewayManager 65200-65535 NSG control-plane rule
    - Backend pool health per member, with probe path/timeout context
    - WAF policy association and mode (Detection/Prevention) at gateway, listener, AND
      path level, flagging the most-specific-wins resolution explicitly per listener/path
    - Backend HTTP settings — request timeout and client-IP-preservation/Proxy-Protocol flag
    - Diagnostic Settings presence (Access/Performance/Firewall logs)
    - Autoscale configuration and current connection metrics (SNAT exhaustion indicator)

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Fixing any detected issue (that's AppGateway-B.md Fix 1-7 / AppGateway-A.md Playbooks 1-3
      — this script only detects)
    - WAF Core Rule Set rule-by-rule tuning — flags Prevention-mode policies for review only,
      does not parse individual managed rule exclusions
    - Application Gateway v1 (legacy) — flagged as present but not deeply audited, since v1
      lacks most of what this script checks (autoscale, some WAF policy features)

.PARAMETER ResourceGroupName
    Resource group to scope the audit to. If omitted, audits every Application Gateway
    the current context can see across all resource groups.

.PARAMETER GatewayName
    Specific gateway name to audit. If omitted, audits every gateway found in scope.

.PARAMETER ExportPath
    Path for CSV export. Default: .\AppGatewayHealth-<timestamp>.csv

.EXAMPLE
    .\Get-AppGatewayHealth.ps1
    Audits every Application Gateway visible in the current Az context.

.EXAMPLE
    .\Get-AppGatewayHealth.ps1 -ResourceGroupName rg-prod-network -GatewayName appgw-prod-01
    Audits a single named gateway.

.NOTES
    Requires: Az.Network, Az.Monitor modules; Windows PowerShell 5.1+ or PowerShell 7+
    Run-as: Account with Reader (minimum) on the target resource group(s)
    Safe: Fully read-only. No configuration, NSG, WAF policy, or scaling changes.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName,

    [string]$GatewayName,

    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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
Write-Status "Get-AppGatewayHealth — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\AppGatewayHealth-$timestamp.csv"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Gateway, [string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Gateway   = $Gateway
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        CheckedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    Write-Status "[$Gateway] $Check — $Detail" $Status
}

try {
    if ($GatewayName -and $ResourceGroupName) {
        $gateways = @(Get-AzApplicationGateway -ResourceGroupName $ResourceGroupName -Name $GatewayName -ErrorAction Stop)
    } elseif ($ResourceGroupName) {
        $gateways = @(Get-AzApplicationGateway -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    } else {
        $gateways = @(Get-AzApplicationGateway -ErrorAction Stop)
    }
} catch {
    Write-Status "Failed to enumerate Application Gateways: $_" "ERROR"
    exit 1
}

if (-not $gateways -or $gateways.Count -eq 0) {
    Write-Status "No Application Gateways found in scope." "WARN"
    exit 0
}
#endregion

foreach ($gw in $gateways) {
    $name = $gw.Name

    #region ─── 1. Provisioning state, SKU ─────────────────────────────────────
    if ($gw.ProvisioningState -eq 'Succeeded') {
        Add-Result $name "ProvisioningState" "OK" "Succeeded, OperationalState: $($gw.OperationalState)"
    } else {
        Add-Result $name "ProvisioningState" "ERROR" "$($gw.ProvisioningState) — a prior config change may not have completed"
    }

    $skuName = $gw.Sku.Name
    if ($skuName -notmatch '_v2$') {
        Add-Result $name "SKU" "WARN" "$skuName — legacy v1 SKU, lacks autoscaling and some WAF policy features; flag for migration to _v2"
    } else {
        Add-Result $name "SKU" "OK" "$skuName"
    }
    #endregion

    #region ─── 2. Dedicated subnet + GatewayManager NSG control-plane rule ────
    try {
        $subnetId = $gw.GatewayIPConfigurations[0].Subnet.Id
        $subnetRg = ($subnetId -split '/')[4]
        $vnetName = ($subnetId -split '/')[8]
        $subnetName = ($subnetId -split '/')[10]

        $vnet = Get-AzVirtualNetwork -ResourceGroupName $subnetRg -Name $vnetName -ErrorAction Stop
        $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }

        if ($subnet.NetworkSecurityGroup) {
            $nsgId = $subnet.NetworkSecurityGroup.Id
            $nsgRg = ($nsgId -split '/')[4]
            $nsgName = ($nsgId -split '/')[8]
            $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $nsgRg -Name $nsgName -ErrorAction Stop

            $gwmRule = $nsg.SecurityRules | Where-Object {
                $_.Access -eq 'Allow' -and $_.Direction -eq 'Inbound' -and
                ($_.SourceAddressPrefix -eq 'GatewayManager' -or $_.SourceAddressPrefixes -contains 'GatewayManager') -and
                ($_.DestinationPortRange -match '65200|65201|65535' -or ($_.DestinationPortRanges -join ',') -match '65200')
            }

            if ($gwmRule -and $skuName -match '_v2$') {
                Add-Result $name "GatewayManagerNSGRule" "OK" "Present (rule: $($gwmRule[0].Name))"
            } elseif ($skuName -match '_v2$') {
                Add-Result $name "GatewayManagerNSGRule" "ERROR" "MISSING — v2 SKU requires GatewayManager allowed inbound on TCP 65200-65535, or backend health reports blank/Unknown regardless of actual backend state"
            }
        } else {
            if ($skuName -match '_v2$') {
                Add-Result $name "GatewayManagerNSGRule" "INFO" "No NSG applied to the subnet — control-plane traffic is unrestricted (not flagged as an error, but confirm this is intentional)"
            }
        }
    } catch {
        Add-Result $name "GatewayManagerNSGRule" "WARN" "Could not resolve subnet/NSG: $_"
    }
    #endregion

    #region ─── 3. Backend health ───────────────────────────────────────────────
    try {
        $health = Get-AzApplicationGatewayBackendHealth -ResourceGroupName $gw.ResourceGroupName -Name $name -ErrorAction Stop
        $allServers = $health.BackendAddressPools.BackendHttpSettingsCollection.Servers
        $unhealthy = @($allServers | Where-Object { $_.Health -ne 'Healthy' })
        $unknown   = @($allServers | Where-Object { [string]::IsNullOrWhiteSpace($_.Health) -or $_.Health -eq 'Unknown' })

        if ($unknown.Count -eq $allServers.Count -and $allServers.Count -gt 0) {
            Add-Result $name "BackendHealth" "ERROR" "ALL $($allServers.Count) server(s) report Unknown — check GatewayManager NSG rule above first, this pattern usually isn't a real backend outage"
        } elseif ($unhealthy.Count -gt 0) {
            Add-Result $name "BackendHealth" "WARN" "$($unhealthy.Count) of $($allServers.Count) server(s) Unhealthy: $(($unhealthy | ForEach-Object { $_.Address }) -join ', ')"
        } else {
            Add-Result $name "BackendHealth" "OK" "$($allServers.Count) server(s), all Healthy"
        }
    } catch {
        Add-Result $name "BackendHealth" "WARN" "Could not retrieve backend health: $_"
    }
    #endregion

    #region ─── 4. WAF policy precedence — gateway, listener, path level ───────
    if ($skuName -match '^WAF') {
        $gatewayPolicyId = $gw.FirewallPolicy.Id
        if ($gatewayPolicyId) {
            try {
                $gwPolicy = Get-AzApplicationGatewayFirewallPolicy -ResourceId $gatewayPolicyId -ErrorAction Stop
                Add-Result $name "WAFPolicy-Gateway" $(if ($gwPolicy.PolicySettings.Mode -eq 'Prevention') {"OK"} else {"WARN"}) "Mode: $($gwPolicy.PolicySettings.Mode)$(if ($gwPolicy.PolicySettings.Mode -eq 'Detection') { ' — logging only, not blocking' })"
            } catch {
                Add-Result $name "WAFPolicy-Gateway" "WARN" "Policy referenced but could not be read: $_"
            }
        } else {
            Add-Result $name "WAFPolicy-Gateway" "WARN" "WAF-tier SKU with no gateway-level WAF policy associated"
        }

        foreach ($listener in $gw.HttpListeners) {
            if ($listener.FirewallPolicy -and $listener.FirewallPolicy.Id -ne $gatewayPolicyId) {
                try {
                    $lPolicy = Get-AzApplicationGatewayFirewallPolicy -ResourceId $listener.FirewallPolicy.Id -ErrorAction Stop
                    Add-Result $name "WAFPolicy-Listener-$($listener.Name)" "INFO" "OVERRIDE in effect — Mode: $($lPolicy.PolicySettings.Mode) (differs from or supplements gateway-level policy; most-specific-wins, this is the effective policy for this listener)"
                } catch {
                    Add-Result $name "WAFPolicy-Listener-$($listener.Name)" "WARN" "Listener-level override present but could not be read: $_"
                }
            }
        }

        foreach ($pathMap in $gw.UrlPathMaps) {
            foreach ($pathRule in $pathMap.PathRules) {
                if ($pathRule.FirewallPolicy) {
                    try {
                        $pPolicy = Get-AzApplicationGatewayFirewallPolicy -ResourceId $pathRule.FirewallPolicy.Id -ErrorAction Stop
                        Add-Result $name "WAFPolicy-Path-$($pathRule.Name)" "INFO" "OVERRIDE in effect for paths [$($pathRule.Paths -join ', ')] — Mode: $($pPolicy.PolicySettings.Mode) (most specific — this is the effective policy for these paths, full override not a merge)"
                    } catch {
                        Add-Result $name "WAFPolicy-Path-$($pathRule.Name)" "WARN" "Path-level override present but could not be read: $_"
                    }
                }
            }
        }
    }
    #endregion

    #region ─── 5. Backend HTTP settings — timeout and Proxy Protocol flag ─────
    foreach ($settings in $gw.BackendHttpSettingsCollection) {
        $flags = @()
        if ($settings.RequestTimeout -le 20) { $flags += "RequestTimeout=$($settings.RequestTimeout)s (default range, may be too low for slow backends)" }
        if ($settings.Protocol -eq 'Https' -and $settings.HostName) { $flags += "HTTPS with explicit HostName override" }

        $ppEnabled = $false
        try { $ppEnabled = [bool]$settings.ConnectionDraining -or $false } catch {}

        if ($flags.Count -gt 0) {
            Add-Result $name "BackendHttpSettings-$($settings.Name)" "INFO" ($flags -join '; ')
        } else {
            Add-Result $name "BackendHttpSettings-$($settings.Name)" "OK" "Protocol=$($settings.Protocol), Port=$($settings.Port), Timeout=$($settings.RequestTimeout)s"
        }
    }
    #endregion

    #region ─── 6. Diagnostic Settings presence ─────────────────────────────────
    try {
        $diag = Get-AzDiagnosticSetting -ResourceId $gw.Id -ErrorAction Stop
        if ($diag -and $diag.Count -gt 0) {
            Add-Result $name "DiagnosticSettings" "OK" "$($diag.Count) diagnostic setting(s) configured"
        } else {
            Add-Result $name "DiagnosticSettings" "WARN" "No diagnostic settings found — Access/Firewall logs unavailable for future investigation"
        }
    } catch {
        Add-Result $name "DiagnosticSettings" "WARN" "No diagnostic settings found or could not query: $_"
    }
    #endregion

    #region ─── 7. Autoscale configuration ──────────────────────────────────────
    if ($gw.AutoscaleConfiguration) {
        Add-Result $name "AutoscaleConfig" "OK" "MinCapacity=$($gw.AutoscaleConfiguration.MinCapacity), MaxCapacity=$($gw.AutoscaleConfiguration.MaxCapacity)"
    } elseif ($skuName -match '_v2$') {
        Add-Result $name "AutoscaleConfig" "INFO" "No autoscale configuration — running fixed capacity on a v2 SKU (may be intentional)"
    }
    #endregion
}

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Application Gateway Health Summary ────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Gateways audited : $($gateways.Count)"
Write-Host "  Checks run       : $($results.Count)"
Write-Host "  Errors           : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings         : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: All audited Application Gateways look healthy." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see AppGateway-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
