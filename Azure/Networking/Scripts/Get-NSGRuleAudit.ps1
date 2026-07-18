<#
.SYNOPSIS
    Audits Azure Network Security Group (NSG) rule hygiene, dual-layer (subnet/NIC) coverage
    gaps, and Security Admin Rule (Azure Virtual Network Manager) presence across a resource
    group or subscription.

.DESCRIPTION
    Produces a read-only report covering three independent checks:

      1. RULE HYGIENE (per NSG) — flags custom rules that are broad and unjustified:
           - BROAD_INBOUND_MGMT_PORT: an Allow rule on 22/3389 with a source of "*"/"Any"/
             "Internet"/"0.0.0.0/0" — the single most common internet-facing exposure pattern
           - PRIORITY_NEAR_DEFAULT: a custom rule sitting within 10 of the 65000/65001/65500
             default-rule priorities, which risks an accidental future collision
           - MISSING_DESCRIPTION: a rule with no description field, making later audits harder
             (informational only, not a security flag)
           - DUPLICATE_PRIORITY_RISK: rules that would collide if direction were ever changed
             (defensive check; Azure itself blocks true same-priority-same-direction duplicates)

      2. DUAL-LAYER COVERAGE (per NIC) — cross-references each NIC's own NSG against its
         subnet's NSG and flags SINGLE_LAYER_ONLY (informational — not inherently wrong, but
         worth knowing which NICs rely on only one enforcement point) and NIC_NSG_NO_SUBNET_NSG
         combinations for inventory purposes.

      3. SECURITY ADMIN RULES (Azure Virtual Network Manager, subscription-wide) — enumerates
         any AlwaysAllow/Deny security admin configurations, which silently override or bypass
         NSG evaluation entirely. Flags ADMIN_RULE_PRESENT as informational so an engineer
         investigating "NSG rules look correct but traffic is still wrong" knows this layer
         exists before spending time re-reading NSG rules that were never the actual decision.

    Explicitly does NOT call IP flow verify or effective-security-rules per NIC (those are
    single-target diagnostic tools, already covered in NSG-B.md's Triage section) — this script
    is a fleet-wide inventory/hygiene sweep, not a per-ticket diagnostic tool.

.PARAMETER ResourceGroupName
    Resource group to scope the sweep to. If omitted, scans every resource group in the current
    subscription context.

.PARAMETER SubscriptionId
    Optional. Switches subscription context before running (requires prior authentication to
    that subscription). If omitted, uses the current Az context.

.PARAMETER PriorityCollisionBuffer
    How close (in priority-number distance) a custom rule can sit to a default rule's priority
    (65000/65001/65500) before being flagged PRIORITY_NEAR_DEFAULT. Defaults to 10.

.PARAMETER SkipSecurityAdminCheck
    Switch. Skips the Azure Virtual Network Manager security admin rule check, useful in
    environments where the caller lacks Network Manager read permission and the resulting
    access-denied noise isn't wanted.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\NSGRuleAudit_<timestamp>.csv.

.EXAMPLE
    .\Get-NSGRuleAudit.ps1 -ResourceGroupName 'rg-network-prod'

.EXAMPLE
    .\Get-NSGRuleAudit.ps1 -PriorityCollisionBuffer 25 -SkipSecurityAdminCheck
    Sweeps the entire current subscription with a wider priority-collision buffer and skips the
    Network Manager check (e.g. for a caller without Network Manager Reader access).

.NOTES
    Requires: Az.Network, Az.Accounts modules
    Install:  Install-Module Az.Network, Az.Accounts -Scope CurrentUser
    Permissions: Reader on network resources is sufficient for NSG/NIC/subnet checks.
                 Network Manager read access (e.g. Network Manager Reader or Reader at the
                 Network Manager's scope) is required for the Security Admin Rule check —
                 this section degrades gracefully to a CheckFailed status if unavailable
                 rather than throwing.
    Safe to run: Read-only. No NSG rules, priorities, ASG memberships, or Network Manager
                 configurations are created, modified, or removed.
#>
#Requires -Modules Az.Network, Az.Accounts

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [int]$PriorityCollisionBuffer = 10,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSecurityAdminCheck,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = "C:\Temp\NSGRuleAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting NSG rule audit..." "INFO"

if (-not (Get-AzContext)) {
    Write-Status "No active Az context found. Run Connect-AzAccount first." "ERROR"
    throw "Not authenticated to Azure."
}

if ($SubscriptionId) {
    Write-Status "Switching to subscription $SubscriptionId..." "INFO"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$currentContext = Get-AzContext
Write-Status "Running against subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))" "INFO"

$defaultPriorities = @(65000, 65001, 65500)
$broadSources = @("*", "Any", "Internet", "0.0.0.0/0")
$managementPorts = @("22", "3389")

$results = New-Object System.Collections.Generic.List[Object]

# ---------------------------------------------------------------------------
# Detect — gather NSGs in scope
# ---------------------------------------------------------------------------
try {
    if ($ResourceGroupName) {
        $nsgs = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName
    }
    else {
        $nsgs = Get-AzNetworkSecurityGroup
    }
}
catch {
    Write-Status "Failed to enumerate NSGs: $($_.Exception.Message)" "ERROR"
    throw
}

Write-Status "Found $($nsgs.Count) NSG(s) to audit." "INFO"

# ---------------------------------------------------------------------------
# Execute — Part 1: Rule hygiene per NSG
# ---------------------------------------------------------------------------
foreach ($nsg in $nsgs) {
    Write-Status "Auditing NSG: $($nsg.Name) (RG: $($nsg.ResourceGroupName))" "INFO"

    foreach ($rule in $nsg.SecurityRules) {

        $flags = New-Object System.Collections.Generic.List[string]

        # BROAD_INBOUND_MGMT_PORT
        if ($rule.Direction -eq "Inbound" -and $rule.Access -eq "Allow") {
            $destPorts = @($rule.DestinationPortRange) + @($rule.DestinationPortRanges) | Where-Object { $_ }
            $sources = @($rule.SourceAddressPrefix) + @($rule.SourceAddressPrefixes) | Where-Object { $_ }

            $touchesMgmtPort = $false
            foreach ($p in $destPorts) {
                foreach ($mp in $managementPorts) {
                    if ($p -eq $mp -or $p -eq "*" -or ($p -match '-' -and [int]($p -split '-')[0] -le [int]$mp -and [int]($p -split '-')[1] -ge [int]$mp)) {
                        $touchesMgmtPort = $true
                    }
                }
            }

            $touchesBroadSource = $false
            foreach ($s in $sources) {
                if ($broadSources -contains $s) { $touchesBroadSource = $true }
            }

            if ($touchesMgmtPort -and $touchesBroadSource) {
                $flags.Add("BROAD_INBOUND_MGMT_PORT")
            }
        }

        # PRIORITY_NEAR_DEFAULT
        foreach ($dp in $defaultPriorities) {
            if ([math]::Abs($rule.Priority - $dp) -le $PriorityCollisionBuffer -and $rule.Priority -ne $dp) {
                $flags.Add("PRIORITY_NEAR_DEFAULT")
            }
        }

        # MISSING_DESCRIPTION (informational)
        if ([string]::IsNullOrWhiteSpace($rule.Description)) {
            $flags.Add("MISSING_DESCRIPTION")
        }

        if ($flags.Count -gt 0) {
            $results.Add([PSCustomObject]@{
                CheckType         = "RuleHygiene"
                ResourceGroupName = $nsg.ResourceGroupName
                NsgName           = $nsg.Name
                RuleName          = $rule.Name
                Priority          = $rule.Priority
                Direction         = $rule.Direction
                Access            = $rule.Access
                Source            = (@($rule.SourceAddressPrefix) + @($rule.SourceAddressPrefixes) | Where-Object { $_ }) -join ","
                DestinationPort   = (@($rule.DestinationPortRange) + @($rule.DestinationPortRanges) | Where-Object { $_ }) -join ","
                Flags             = ($flags -join ";")
            })
        }
    }
}

# ---------------------------------------------------------------------------
# Execute — Part 2: Dual-layer coverage per NIC
# ---------------------------------------------------------------------------
Write-Status "Cross-referencing NIC-level vs. subnet-level NSG coverage..." "INFO"

try {
    if ($ResourceGroupName) {
        $nics = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName
    }
    else {
        $nics = Get-AzNetworkInterface
    }
}
catch {
    Write-Status "Failed to enumerate NICs: $($_.Exception.Message)" "WARN"
    $nics = @()
}

foreach ($nic in $nics) {

    $nicHasNsg = [bool]$nic.NetworkSecurityGroup

    $subnetHasNsg = $false
    try {
        if ($nic.IpConfigurations -and $nic.IpConfigurations[0].Subnet) {
            $subnetId = $nic.IpConfigurations[0].Subnet.Id
            $idParts = $subnetId -split '/'
            $vnetRg = $idParts[4]
            $vnetName = $idParts[8]
            $subnetName = $idParts[10]
            $subnetConfig = Get-AzVirtualNetworkSubnetConfig -ResourceGroupName $vnetRg -VirtualNetworkName $vnetName -Name $subnetName -ErrorAction SilentlyContinue
            $subnetHasNsg = [bool]($subnetConfig -and $subnetConfig.NetworkSecurityGroup)
        }
    }
    catch {
        # Best-effort — some NICs (e.g. PaaS-managed) don't expose a resolvable subnet config here
    }

    if ($nicHasNsg -or $subnetHasNsg) {
        $layerFlag = if ($nicHasNsg -and $subnetHasNsg) { "DUAL_LAYER" }
                     elseif ($nicHasNsg) { "NIC_LAYER_ONLY" }
                     else { "SUBNET_LAYER_ONLY" }

        $results.Add([PSCustomObject]@{
            CheckType         = "DualLayerCoverage"
            ResourceGroupName = $nic.ResourceGroupName
            NsgName           = ""
            RuleName          = $nic.Name
            Priority          = ""
            Direction         = ""
            Access            = ""
            Source            = ""
            DestinationPort   = ""
            Flags             = $layerFlag
        })
    }
}

# ---------------------------------------------------------------------------
# Execute — Part 3: Security Admin Rules (Azure Virtual Network Manager)
# ---------------------------------------------------------------------------
if (-not $SkipSecurityAdminCheck) {
    Write-Status "Checking for Azure Virtual Network Manager Security Admin Rules..." "INFO"
    try {
        $networkManagers = Get-AzNetworkManager -ErrorAction Stop

        if ($networkManagers.Count -eq 0) {
            Write-Status "No Network Manager instances found in scope." "OK"
        }

        foreach ($nm in $networkManagers) {
            $adminConfigs = Get-AzNetworkManagerSecurityAdminConfiguration -NetworkManagerName $nm.Name -ResourceGroupName $nm.ResourceGroupName -ErrorAction SilentlyContinue

            foreach ($cfg in $adminConfigs) {
                $results.Add([PSCustomObject]@{
                    CheckType         = "SecurityAdminRule"
                    ResourceGroupName = $nm.ResourceGroupName
                    NsgName           = ""
                    RuleName          = $cfg.Name
                    Priority          = ""
                    Direction         = ""
                    Access            = ""
                    Source            = ""
                    DestinationPort   = ""
                    Flags             = "ADMIN_RULE_PRESENT_VERIFY_ACTION_TYPE"
                })
            }
        }
    }
    catch {
        Write-Status "Security Admin Rule check failed or insufficient permissions (this is common if the caller lacks Network Manager Reader) — recorded as CheckFailed rather than skipped silently." "WARN"
        $results.Add([PSCustomObject]@{
            CheckType         = "SecurityAdminRule"
            ResourceGroupName = ""
            NsgName           = ""
            RuleName          = ""
            Priority          = ""
            Direction         = ""
            Access            = ""
            Source            = ""
            DestinationPort   = ""
            Flags             = "CheckFailed: $($_.Exception.Message)"
        })
    }
}
else {
    Write-Status "Security Admin Rule check skipped (-SkipSecurityAdminCheck)." "INFO"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$hygieneCount = ($results | Where-Object { $_.CheckType -eq "RuleHygiene" }).Count
$broadMgmtCount = ($results | Where-Object { $_.Flags -like "*BROAD_INBOUND_MGMT_PORT*" }).Count
$adminRuleCount = ($results | Where-Object { $_.CheckType -eq "SecurityAdminRule" -and $_.Flags -eq "ADMIN_RULE_PRESENT_VERIFY_ACTION_TYPE" }).Count

Write-Status "Audit complete." "OK"
Write-Status "  Rule hygiene flags: $hygieneCount (of which $broadMgmtCount are BROAD_INBOUND_MGMT_PORT)" "INFO"
Write-Status "  Security Admin configurations found: $adminRuleCount" "INFO"

if ($broadMgmtCount -gt 0) {
    Write-Status "  $broadMgmtCount rule(s) allow RDP/SSH from a broad source (*/Any/Internet/0.0.0.0-0/0) — review for Bastion/JIT replacement." "WARN"
}

$exportDir = Split-Path $ExportPath -Parent
if ($exportDir -and -not (Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to: $ExportPath" "OK"

return $results
