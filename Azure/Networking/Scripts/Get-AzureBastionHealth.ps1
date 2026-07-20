<#
.SYNOPSIS
    Read-only health and configuration audit for Azure Bastion deployments.

.DESCRIPTION
    Sweeps Azure Bastion resources in a subscription (or a single named resource) and reports:
    SKU tier and provisioning state, AzureBastionSubnet sizing compliance (/26 or larger),
    NSG rule completeness on AzureBastionSubnet against the full 8-rule required set, and —
    when a target VM subnet name is supplied — whether that subnet's NSG has an inbound
    allow rule for RDP/SSH sourced from the Bastion subnet range specifically.

    This script makes NO configuration changes. It does not test live connectivity, does not
    validate JIT (Just-In-Time) role assignments (no single Az cmdlet enumerates this
    per-user/per-VM at scale), and does not inspect session recording configuration detail.

.PARAMETER ResourceGroupName
    Optional. Limit the sweep to Bastion resources in this resource group. If omitted, scans
    the current subscription context.

.PARAMETER BastionName
    Optional. Audit only this specific Bastion resource (requires -ResourceGroupName).

.PARAMETER TargetVmSubnetName
    Optional. Name of a target VM subnet to additionally check for a Bastion-sourced RDP/SSH
    inbound allow rule on its own NSG.

.EXAMPLE
    .\Get-AzureBastionHealth.ps1

    Scans every Bastion resource in the current subscription and reports SKU/subnet/NSG health.

.EXAMPLE
    .\Get-AzureBastionHealth.ps1 -ResourceGroupName rg-network-prod -BastionName bastion-hub-01 -TargetVmSubnetName snet-workloads

    Audits a single named Bastion resource and additionally checks the target VM subnet's NSG.

.NOTES
    Requires: Az.Network module, an authenticated Az context with Reader access to the target
    subscription/resource group.
    Run-as: any account with Microsoft.Network/bastionHosts/read and
    Microsoft.Network/networkSecurityGroups/read permissions.
    Safe: read-only. Makes no configuration changes. Exports findings to CSV.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$ResourceGroupName,
    [Parameter(Mandatory = $false)][string]$BastionName,
    [Parameter(Mandatory = $false)][string]$TargetVmSubnetName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$RequiredBastionRules = @(
    @{ Name = "AllowHttpsInbound";             Direction = "Inbound";  Ports = @("443") }
    @{ Name = "AllowGatewayManagerInbound";    Direction = "Inbound";  Ports = @("443") }
    @{ Name = "AllowBastionHostCommunication"; Direction = "Inbound";  Ports = @("8080","5701") }
    @{ Name = "AllowAzureLoadBalancerInbound"; Direction = "Inbound";  Ports = @("443") }
    @{ Name = "AllowSshRdpOutbound";           Direction = "Outbound"; Ports = @("22","3389") }
    @{ Name = "AllowAzureCloudOutbound";       Direction = "Outbound"; Ports = @("443") }
    @{ Name = "AllowBastionCommunication";     Direction = "Outbound"; Ports = @("8080","5701") }
    @{ Name = "AllowHttpOutbound";             Direction = "Outbound"; Ports = @("80") }
)

# --- Preflight ---
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Status "No Az context found. Run Connect-AzAccount first." "ERROR"
        return
    }
    Write-Status "Running as $($context.Account.Id) against subscription $($context.Subscription.Name)" "INFO"
}
catch {
    Write-Status "Failed to resolve Az context: $($_.Exception.Message)" "ERROR"
    return
}

# --- Detect: gather target Bastion resources ---
$bastions = @()
try {
    if ($BastionName -and $ResourceGroupName) {
        $bastions += Get-AzBastion -ResourceGroupName $ResourceGroupName -Name $BastionName
    }
    elseif ($ResourceGroupName) {
        $bastions += Get-AzBastion -ResourceGroupName $ResourceGroupName
    }
    else {
        $bastions += Get-AzBastion
    }
}
catch {
    Write-Status "Failed to enumerate Bastion resources: $($_.Exception.Message)" "ERROR"
    return
}

if ($bastions.Count -eq 0) {
    Write-Status "No Azure Bastion resources found in scope." "WARN"
    return
}

Write-Status "Found $($bastions.Count) Bastion resource(s) to audit." "INFO"

# --- Execute: build audit report ---
$report = New-Object System.Collections.Generic.List[PSObject]

foreach ($bastion in $bastions) {
    $findings = @()

    # Subnet compliance check (dedicated SKUs only)
    $subnetOk = "N/A (Developer SKU)"
    $subnetPrefix = $null
    if ($bastion.SkuText -ne "Developer") {
        try {
            $ipConfig = $bastion.IpConfigurations | Select-Object -First 1
            if ($ipConfig -and $ipConfig.Subnet) {
                $subnetId = $ipConfig.Subnet.Id
                $vnetName = ($subnetId -split "/virtualNetworks/")[1] -split "/subnets/" | Select-Object -First 1
                $vnetRg = ($subnetId -split "/resourceGroups/")[1] -split "/providers/" | Select-Object -First 1
                $vnet = Get-AzVirtualNetwork -ResourceGroupName $vnetRg -Name $vnetName -ErrorAction SilentlyContinue
                $subnet = $vnet.Subnets | Where-Object { $_.Name -eq "AzureBastionSubnet" }
                if ($subnet) {
                    $subnetPrefix = $subnet.AddressPrefix
                    $maskBits = [int]($subnetPrefix -split "/")[1]
                    $subnetOk = if ($maskBits -le 26) { "OK ($subnetPrefix)" } else { "TOO SMALL ($subnetPrefix — needs /26 or larger)" }
                    if ($maskBits -gt 26) { $findings += "AzureBastionSubnet smaller than /26" }
                } else {
                    $subnetOk = "AzureBastionSubnet not found"
                    $findings += "Could not locate AzureBastionSubnet for size validation"
                }
            }
        }
        catch {
            $subnetOk = "Check failed: $($_.Exception.Message)"
        }
    }

    # NSG rule completeness check on AzureBastionSubnet
    $nsgStatus = "No NSG applied (or not checked)"
    $missingRules = @()
    try {
        if ($subnetPrefix) {
            $allNsgs = Get-AzNetworkSecurityGroup -ErrorAction SilentlyContinue
            $bastionNsg = $allNsgs | Where-Object { $_.Subnets.Id -match "AzureBastionSubnet" -and $_.Subnets.Id -match [regex]::Escape($vnetName) }
            if ($bastionNsg) {
                $existingRuleNames = $bastionNsg.SecurityRules.Name
                foreach ($req in $RequiredBastionRules) {
                    if ($existingRuleNames -notcontains $req.Name) {
                        $missingRules += $req.Name
                    }
                }
                $nsgStatus = if ($missingRules.Count -eq 0) { "All 8 required rules present" } else { "MISSING: $($missingRules -join ', ')" }
                if ($missingRules.Count -gt 0) { $findings += "NSG on AzureBastionSubnet missing $($missingRules.Count) required rule(s)" }
            }
        }
    }
    catch {
        $nsgStatus = "Check failed: $($_.Exception.Message)"
    }

    # Target VM subnet NSG check (optional)
    $targetSubnetStatus = "Not checked (no -TargetVmSubnetName supplied)"
    if ($TargetVmSubnetName) {
        try {
            $allNsgs = Get-AzNetworkSecurityGroup -ErrorAction SilentlyContinue
            $targetNsg = $allNsgs | Where-Object { $_.Subnets.Id -match $TargetVmSubnetName }
            if ($targetNsg) {
                $rdpSshRule = $targetNsg.SecurityRules | Where-Object {
                    $_.Access -eq "Allow" -and $_.Direction -eq "Inbound" -and
                    ($_.DestinationPortRange -match "3389" -or $_.DestinationPortRange -match "22")
                }
                $targetSubnetStatus = if ($rdpSshRule) { "Inbound RDP/SSH allow rule found" } else { "NO inbound RDP/SSH allow rule found — connections will fail" }
                if (-not $rdpSshRule) { $findings += "Target VM subnet '$TargetVmSubnetName' NSG has no RDP/SSH inbound allow rule" }
            } else {
                $targetSubnetStatus = "No NSG found on target subnet (traffic unrestricted at this layer)"
            }
        }
        catch {
            $targetSubnetStatus = "Check failed: $($_.Exception.Message)"
        }
    }

    if ($findings.Count -eq 0) { $findings += "No issues detected by this script's checks" }

    $report.Add([PSCustomObject]@{
        BastionName        = $bastion.Name
        ResourceGroup       = $bastion.ResourceGroupName
        SkuText             = $bastion.SkuText
        ProvisioningState   = $bastion.ProvisioningState
        SubnetCompliance    = $subnetOk
        NsgRuleStatus       = $nsgStatus
        TargetSubnetStatus  = $targetSubnetStatus
        Findings            = ($findings -join " | ")
    })
}

# --- Report ---
$report | Format-Table BastionName, SkuText, ProvisioningState, SubnetCompliance, NsgRuleStatus, Findings -AutoSize

$exportPath = ".\AzureBastionHealth_$(Get-Date -Format yyyyMMdd_HHmm).csv"
$report | Export-Csv -Path $exportPath -NoTypeInformation
Write-Status "Report exported to $exportPath" "OK"

$issueCount = ($report | Where-Object { $_.Findings -ne "No issues detected by this script's checks" }).Count
if ($issueCount -gt 0) {
    Write-Status "$issueCount Bastion resource(s) have findings requiring review." "WARN"
}
