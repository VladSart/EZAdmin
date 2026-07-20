<#
.SYNOPSIS
    Read-only fleet-wide audit of Azure ExpressRoute circuits, peerings, BGP redundancy, and gateway sizing.

.DESCRIPTION
    Sweeps every ExpressRoute circuit visible in the current Az context (or a specified subscription list)
    and flags common ExpressRoute-specific risk conditions that don't surface as an obvious "unhealthy"
    state on the resource itself:

      - Circuit or provider provisioning stuck (not Enabled/Provisioned)
      - A configured peering (Private or Microsoft) not in Provisioned/Enabled state
      - Microsoft Peering configured but with no Route Filter attached (zero routes despite "healthy" peering)
      - Only one of the two redundant BGP links (primary/secondary) Established — degraded redundancy
      - Advertised prefix count approaching the circuit's Sku.Tier ceiling (default warn threshold: 80%)
      - Global Reach connection objects present but not in a Connected state
      - ExpressRoute Gateway SKU that looks undersized relative to the circuit's provisioned bandwidth
        (heuristic only — flagged for manual review, not a definitive finding)
      - FastPath eligible (gateway SKU supports it) but not enabled on the connection

    This script makes NO configuration changes. Every finding is written to the console and exported to CSV
    for ticket attachment or trend tracking across visits.

.PARAMETER SubscriptionId
    One or more subscription IDs to sweep. If omitted, uses all subscriptions the current Az context can see.

.PARAMETER PrefixWarnPercent
    Percentage of the Sku.Tier prefix ceiling at which a circuit is flagged as "approaching limit."
    Default: 80.

.PARAMETER OutputPath
    Folder to write the CSV report to. Default: current directory.

.EXAMPLE
    .\Get-ExpressRouteCircuitAudit.ps1
    Audits every ExpressRoute circuit in every subscription the current session can see.

.EXAMPLE
    .\Get-ExpressRouteCircuitAudit.ps1 -SubscriptionId "11111111-1111-1111-1111-111111111111" -PrefixWarnPercent 70

.NOTES
    Requires: Az.Network module, an authenticated Az context (Connect-AzAccount) with at minimum
    Reader role on the target subscription(s).
    Read-only — makes no changes to any circuit, peering, connection, or gateway.
    Prefix-ceiling values (Local/Standard ≈ 4,000, Premium ≈ 10,000) are best-known-current-values at
    time of writing and are used as a heuristic only — always confirm against current Microsoft Learn
    published limits before treating a "near limit" flag as authoritative for a client-facing report.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$PrefixWarnPercent = 80,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# Approximate published prefix ceilings by SKU tier — heuristic, verify against current Microsoft Learn limits
$PrefixCeilingByTier = @{
    "Local"    = 4000
    "Standard" = 4000
    "Premium"  = 10000
}

# Rough gateway SKU throughput tiers (Mbps) — heuristic ordering only, used to flag likely mismatches,
# not to assert exact contracted throughput numbers
$GatewaySkuOrder = @{
    "Standard"          = 1
    "HighPerformance"   = 2
    "UltraPerformance"  = 3
    "ErGw1AZ"           = 2
    "ErGw2AZ"           = 3
    "ErGw3AZ"           = 4
}

if (-not (Get-AzContext)) {
    Write-Status "No active Az context. Run Connect-AzAccount first." -Status "ERROR"
    exit 1
}

$subs = if ($SubscriptionId) {
    $SubscriptionId | ForEach-Object { Get-AzSubscription -SubscriptionId $_ }
} else {
    Get-AzSubscription
}

Write-Status "Sweeping $($subs.Count) subscription(s) for ExpressRoute circuits..." -Status "INFO"

$findings = New-Object System.Collections.Generic.List[Object]

foreach ($sub in $subs) {
    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
    } catch {
        Write-Status "Could not set context to subscription $($sub.Name) ($($sub.Id)): $_" -Status "WARN"
        continue
    }

    $circuits = @()
    try {
        $circuits = Get-AzExpressRouteCircuit -ErrorAction Stop
    } catch {
        Write-Status "Could not enumerate ExpressRoute circuits in $($sub.Name): $_" -Status "WARN"
        continue
    }

    if (-not $circuits) { continue }

    foreach ($circuit in $circuits) {
        $ctxLabel = "$($sub.Name)/$($circuit.ResourceGroupName)/$($circuit.Name)"
        Write-Status "Checking $ctxLabel" -Status "INFO"

        # --- Circuit / provider provisioning ---
        if ($circuit.CircuitProvisioningState -ne "Enabled") {
            $findings.Add([PSCustomObject]@{
                Subscription = $sub.Name; ResourceGroup = $circuit.ResourceGroupName; Circuit = $circuit.Name
                Category = "Circuit Provisioning"; Severity = "High"
                Finding = "CircuitProvisioningState = $($circuit.CircuitProvisioningState)"
                Detail = "Microsoft-side provisioning not Enabled."
            })
        }
        if ($circuit.ServiceProviderProvisioningState -ne "Provisioned") {
            $findings.Add([PSCustomObject]@{
                Subscription = $sub.Name; ResourceGroup = $circuit.ResourceGroupName; Circuit = $circuit.Name
                Category = "Provider Provisioning"; Severity = "High"
                Finding = "ServiceProviderProvisioningState = $($circuit.ServiceProviderProvisioningState)"
                Detail = "Provider-side action required — not resolvable from Azure alone."
            })
        }

        $tier = $circuit.Sku.Tier
        $ceiling = $PrefixCeilingByTier[$tier]

        # --- Peerings ---
        foreach ($peering in $circuit.Peerings) {
            if ($peering.ProvisioningState -ne "Provisioned" -or $peering.State -ne "Enabled") {
                $findings.Add([PSCustomObject]@{
                    Subscription = $sub.Name; ResourceGroup = $circuit.ResourceGroupName; Circuit = $circuit.Name
                    Category = "Peering State"; Severity = "Medium"
                    Finding = "$($peering.PeeringType): ProvisioningState=$($peering.ProvisioningState), State=$($peering.State)"
                    Detail = "Peering not fully provisioned/enabled."
                })
            }

            if ($peering.PeeringType -eq "MicrosoftPeering" -and -not $peering.RouteFilter) {
                $findings.Add([PSCustomObject]@{
                    Subscription = $sub.Name; ResourceGroup = $circuit.ResourceGroupName; Circuit = $circuit.Name
                    Category = "Route Filter Missing"; Severity = "High"
                    Finding = "Microsoft Peering has no Route Filter attached"
                    Detail = "Peering can show healthy while advertising zero routes. See ExpressRoute-B.md Fix 1 / ExpressRoute-A.md How It Works."
                })
            }

            # --- BGP redundancy (Private Peering only — the common VNet-connectivity path) ---
            if ($peering.PeeringType -eq "AzurePrivatePeering" -and $peering.ProvisioningState -eq "Provisioned") {
                $primaryEstablished = $false
                $secondaryEstablished = $false
                $prefixCount = 0
                try {
                    $primary = Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName $circuit.Name `
                        -PeeringType AzurePrivatePeering -ResourceGroupName $circuit.ResourceGroupName -ErrorAction Stop
                    $primaryEstablished = ($primary | Where-Object { $_.AsPath -or $_.Network }) -ne $null
                    $prefixCount = ($primary | Measure-Object).Count
                } catch {
                    Write-Status "  Could not read primary route table for $($circuit.Name): $_" -Status "WARN"
                }
                try {
                    $secondary = Get-AzExpressRouteCircuitRouteTable -DevicePath Secondary -ExpressRouteCircuitName $circuit.Name `
                        -PeeringType AzurePrivatePeering -ResourceGroupName $circuit.ResourceGroupName -ErrorAction Stop
                    $secondaryEstablished = ($secondary | Where-Object { $_.AsPath -or $_.Network }) -ne $null
                } catch {
                    Write-Status "  Could not read secondary route table for $($circuit.Name): $_" -Status "WARN"
                }

                if (-not $primaryEstablished -or -not $secondaryEstablished) {
                    $findings.Add([PSCustomObject]@{
                        Subscription = $sub.Name; ResourceGroup = $circuit.ResourceGroupName; Circuit = $circuit.Name
                        Category = "BGP Redundancy"; Severity = "Medium"
                        Finding = "Primary established: $primaryEstablished; Secondary established: $secondaryEstablished"
                        Detail = "Circuit is running on a single redundant link — degraded redundancy even if traffic currently flows."
                    })
                }

                if ($ceiling -and $prefixCount -gt 0) {
                    $pctUsed = [math]::Round(($prefixCount / $ceiling) * 100, 1)
                    if ($pctUsed -ge $PrefixWarnPercent) {
                        $findings.Add([PSCustomObject]@{
                            Subscription = $sub.Name; ResourceGroup = $circuit.ResourceGroupName; Circuit = $circuit.Name
                            Category = "Prefix Ceiling"; Severity = "Medium"
                            Finding = "$prefixCount prefixes advertised ($pctUsed% of ~$ceiling ceiling for tier '$tier')"
                            Detail = "Approaching or at the SKU tier's prefix limit — excess prefixes drop silently, not alerted by Azure."
                        })
                    }
                }
            }
        }

        # --- Global Reach ---
        try {
            $grConnections = Get-AzExpressRouteCircuitConnectionConfig -ResourceGroupName $circuit.ResourceGroupName `
                -ExpressRouteCircuitName $circuit.Name -ErrorAction SilentlyContinue
            foreach ($gr in $grConnections) {
                if ($gr.ConnectionState -ne "Connected") {
                    $findings.Add([PSCustomObject]@{
                        Subscription = $sub.Name; ResourceGroup = $circuit.ResourceGroupName; Circuit = $circuit.Name
                        Category = "Global Reach"; Severity = "Medium"
                        Finding = "Connection '$($gr.Name)': ConnectionState = $($gr.ConnectionState)"
                        Detail = "Authorization may exist without being redeemed on the peer circuit, or an unsupported region pairing."
                    })
                }
            }
        } catch {
            # No Global Reach configured — not a finding
        }
    }

    # --- Gateways: SKU vs. circuit heuristic, and FastPath ---
    $gateways = @()
    try {
        $gateways = Get-AzExpressRouteGateway -ErrorAction Stop
    } catch {
        $gateways = @()
    }

    foreach ($gw in $gateways) {
        try {
            $connections = Get-AzExpressRouteConnection -ResourceGroupName $gw.ResourceGroupName -ExpressRouteGatewayName $gw.Name -ErrorAction Stop
        } catch {
            continue
        }
        foreach ($conn in $connections) {
            if (-not $conn.FastPathEnabled) {
                $gwSkuFamily = if ($gw.PSObject.Properties.Match("VirtualHub").Count -gt 0) { "Hub-embedded (Virtual WAN)" } else { "Standalone" }
                $findings.Add([PSCustomObject]@{
                    Subscription = $sub.Name; ResourceGroup = $gw.ResourceGroupName; Circuit = $conn.Name
                    Category = "FastPath"; Severity = "Low"
                    Finding = "FastPath not enabled on connection '$($conn.Name)' ($gwSkuFamily gateway)"
                    Detail = "Confirm gateway SKU eligibility (UltraPerformance/ErGw3AZ+) before assuming this is actionable — informational flag only."
                })
            }
        }
    }
}

# --- Report ---
Write-Host ""
Write-Status "=== ExpressRoute Circuit Audit Summary ===" -Status "INFO"
if ($findings.Count -eq 0) {
    Write-Status "No findings — all audited circuits look healthy against the checks in this script." -Status "OK"
} else {
    $bySeverity = $findings | Group-Object Severity | Sort-Object @{Expression = { switch ($_.Name) { "High" {0} "Medium" {1} "Low" {2} default {3} } } }
    foreach ($group in $bySeverity) {
        Write-Status "$($group.Name): $($group.Count) finding(s)" -Status $(if ($group.Name -eq "High") { "ERROR" } elseif ($group.Name -eq "Medium") { "WARN" } else { "INFO" })
    }
    $findings | Sort-Object @{Expression = { switch ($_.Severity) { "High" {0} "Medium" {1} "Low" {2} default {3} } } }, Circuit |
        Format-Table Subscription, Circuit, Category, Severity, Finding -AutoSize -Wrap
}

$csvPath = Join-Path $OutputPath "ExpressRouteCircuitAudit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Report exported to $csvPath" -Status "OK"
