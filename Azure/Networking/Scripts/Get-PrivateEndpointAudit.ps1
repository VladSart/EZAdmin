<#
.SYNOPSIS
    Audits Azure Private Endpoints fleet-wide — connection approval state, DNS Zone Group
    presence, private DNS zone link coverage, and subnet network policy posture.

.DESCRIPTION
    Companion script to Azure/Networking/PrivateLink-B.md and PrivateLink-A.md.
    Gathers, in one pass, everything the runbooks' triage and diagnosis steps ask for:
    - Connection approval state per Private Endpoint (flags anything not Approved — the
      single most common "looks deployed but carries zero traffic" root cause)
    - Private DNS Zone Group presence (flags endpoints with no automated DNS management at all)
    - Cross-references each Zone Group's target zone(s) against the zone's actual Virtual
      Network Links, flagging when the Private Endpoint's own VNet isn't linked
    - Best-effort live DNS resolution check comparing the resolved IP against the endpoint's
      actual assigned private IP (flags public-IP-still-resolving as an explicit finding)
    - Cross-service zone contamination check — flags a private DNS zone whose record set
      contains entries inconsistent with a single expected service naming pattern
    - Subnet PrivateEndpointNetworkPolicies state (informational — disabled is the platform
      default, not inherently a finding, but surfaced since it explains "NSG has no effect"
      tickets)

    Produces a console summary with pass/fail/flag per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Fixing any detected issue (that's PrivateLink-B.md Fix 1-8 / PrivateLink-A.md
      Playbooks 1-4 — this script only detects)
    - On-premises DNS forwarder/Private Resolver configuration correctness — this script
      can only confirm the Azure-side zone/link state, not what an on-prem DNS server is
      actually configured to forward; on-prem-specific validation remains a manual step
    - Private Link Service (provider-side) configuration — this script audits the
      CONSUMER side (Private Endpoints) only
    - Per-service subresource completeness (e.g., confirming every Storage subresource
      that SHOULD have its own Private Endpoint actually does) — flagged as a script
      limitation since there's no reliable way to infer "should exist" from what's deployed

.PARAMETER ResourceGroupName
    Resource group to scope the audit to. If omitted, audits every Private Endpoint
    the current context can see across all resource groups.

.PARAMETER PrivateEndpointName
    Specific Private Endpoint name to audit. If omitted, audits every endpoint found in scope.

.PARAMETER SkipDnsResolutionCheck
    Skip the live Resolve-DnsName check (useful when running from a machine without
    the correct VNet-based DNS resolution path — e.g., a jump box outside the target VNet
    would produce a false-positive "resolves to public IP" finding).

.PARAMETER ExportPath
    Path for CSV export. Default: .\PrivateEndpointAudit-<timestamp>.csv

.EXAMPLE
    .\Get-PrivateEndpointAudit.ps1
    Audits every Private Endpoint visible in the current Az context, including live DNS checks.

.EXAMPLE
    .\Get-PrivateEndpointAudit.ps1 -ResourceGroupName rg-prod-network -SkipDnsResolutionCheck
    Audits only endpoints in one resource group, skipping DNS resolution (e.g., running
    from outside the relevant VNet where a resolution check would be unreliable).

.NOTES
    Requires: Az.Network, Az.PrivateDns modules; Windows PowerShell 5.1+ or PowerShell 7+
    Run-as: Account with Reader (minimum) on the target resource group(s)
    Safe: Fully read-only. No approval, DNS record, Zone Group, or NSG changes.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName,

    [string]$PrivateEndpointName,

    [switch]$SkipDnsResolutionCheck,

    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Test-PrivateIpAddress {
    param([string]$IpAddress)
    if ([string]::IsNullOrWhiteSpace($IpAddress)) { return $false }
    try {
        $ip = [System.Net.IPAddress]::Parse($IpAddress)
        $bytes = $ip.GetAddressBytes()
        if ($bytes[0] -eq 10) { return $true }
        if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $true }
        if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $true }
        return $false
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Status "Starting Private Endpoint audit" "INFO"

$requiredModules = @('Az.Network', 'Az.PrivateDns')
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Required module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" "ERROR"
    }
}

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Status "No active Az context. Run Connect-AzAccount first." "ERROR"
    return
}
Write-Status "Running as $($context.Account.Id) in subscription $($context.Subscription.Name)" "OK"

if (-not $ExportPath) {
    $ExportPath = ".\PrivateEndpointAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}

# ---------------------------------------------------------------------------
# Detect
# ---------------------------------------------------------------------------

$getParams = @{}
if ($ResourceGroupName) { $getParams['ResourceGroupName'] = $ResourceGroupName }

$endpoints = Get-AzPrivateEndpoint @getParams -ErrorAction SilentlyContinue
if ($PrivateEndpointName) {
    $endpoints = $endpoints | Where-Object { $_.Name -eq $PrivateEndpointName }
}

if (-not $endpoints -or $endpoints.Count -eq 0) {
    Write-Status "No Private Endpoints found in scope." "WARN"
    return
}

Write-Status "Found $($endpoints.Count) Private Endpoint(s) to audit" "INFO"

$results = @()
$zoneRecordCache = @{}   # cache zone -> record set so we only query each zone once
$zoneLinkCache = @{}     # cache zone -> vnet links so we only query each zone once

foreach ($pe in $endpoints) {

    Write-Status "Auditing: $($pe.Name) (RG: $($pe.ResourceGroupName))" "INFO"

    $findings = New-Object System.Collections.Generic.List[string]

    # --- Connection approval state ---
    $connection = $pe.PrivateLinkServiceConnections | Select-Object -First 1
    if (-not $connection) {
        $connection = $pe.ManualPrivateLinkServiceConnections | Select-Object -First 1
    }
    $connState = if ($connection) { $connection.PrivateLinkServiceConnectionState.Status } else { "Unknown" }
    if ($connState -ne "Approved") {
        $findings.Add("Connection state is '$connState', not Approved — endpoint sends NO traffic")
    }

    # --- Assigned private IP ---
    $assignedIp = $null
    if ($pe.NetworkInterfaces -and $pe.NetworkInterfaces.Count -gt 0) {
        $nicId = $pe.NetworkInterfaces[0].Id
        try {
            $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction SilentlyContinue
            $assignedIp = $nic.IpConfigurations[0].PrivateIpAddress
        } catch {
            $findings.Add("Could not resolve NIC to determine assigned private IP")
        }
    }

    # --- DNS Zone Group presence ---
    $zoneGroupConfigs = @()
    $hasZoneGroup = $false
    try {
        $zoneGroups = Get-AzPrivateDnsZoneGroup -ResourceGroupName $pe.ResourceGroupName -PrivateEndpointName $pe.Name -ErrorAction SilentlyContinue
        if ($zoneGroups) {
            $hasZoneGroup = $true
            foreach ($zg in $zoneGroups) {
                $zoneGroupConfigs += $zg.PrivateDnsZoneConfigs
            }
        }
    } catch {
        # Zone Group cmdlet not available or errored — fall back to null-check on the object property
        if ($pe.PSObject.Properties['PrivateDnsZoneGroups'] -and $pe.PrivateDnsZoneGroups) {
            $hasZoneGroup = $true
        }
    }

    if (-not $hasZoneGroup) {
        $findings.Add("No Private DNS Zone Group attached — DNS is unmanaged or manually scripted")
    }

    # --- Zone link coverage + record contamination (per zone referenced by this PE) ---
    $subnetId = $pe.Subnet.Id
    $vnetId = ($subnetId -split '/subnets/')[0]

    foreach ($zoneConfig in $zoneGroupConfigs) {
        $zoneId = $zoneConfig.PrivateDnsZoneId
        if (-not $zoneId) { continue }
        $zoneName = ($zoneId -split '/')[-1]
        $zoneRg = ($zoneId -split '/')[4]

        # Zone links — cache per zone
        if (-not $zoneLinkCache.ContainsKey($zoneId)) {
            try {
                $zoneLinkCache[$zoneId] = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $zoneRg -ZoneName $zoneName -ErrorAction SilentlyContinue
            } catch {
                $zoneLinkCache[$zoneId] = @()
            }
        }
        $links = $zoneLinkCache[$zoneId]
        $vnetLinked = $links | Where-Object { $_.VirtualNetworkId -eq $vnetId }
        if (-not $vnetLinked) {
            $findings.Add("Zone '$zoneName' has no Virtual Network Link for this endpoint's own VNet — peering does not create this automatically")
        }

        # Record contamination — cache per zone
        if (-not $zoneRecordCache.ContainsKey($zoneId)) {
            try {
                $zoneRecordCache[$zoneId] = Get-AzPrivateDnsRecordSet -ResourceGroupName $zoneRg -ZoneName $zoneName -RecordType A -ErrorAction SilentlyContinue
            } catch {
                $zoneRecordCache[$zoneId] = @()
            }
        }
        $records = $zoneRecordCache[$zoneId]
        $expectedRecordName = $pe.Name.ToLower()
        $unrelatedRecords = $records | Where-Object { $_.Name -ne $expectedRecordName -and $_.Name -ne '@' }
        if ($unrelatedRecords -and $unrelatedRecords.Count -gt 0) {
            $findings.Add("Zone '$zoneName' contains $($unrelatedRecords.Count) record(s) not matching this endpoint's name — verify no cross-service zone sharing")
        }
    }

    # --- Live DNS resolution check (best-effort) ---
    $resolvedIp = $null
    $resolvesPrivate = $null
    if (-not $SkipDnsResolutionCheck -and $connection -and $connection.PrivateLinkServiceId) {
        # Best-effort FQDN derivation is unreliable without per-service knowledge; skip unless
        # the zone name itself gives us the suffix to test against the endpoint's own record name.
        foreach ($zoneConfig in $zoneGroupConfigs) {
            $zoneId = $zoneConfig.PrivateDnsZoneId
            if (-not $zoneId) { continue }
            $zoneName = ($zoneId -split '/')[-1]
            $publicSuffix = $zoneName -replace '^privatelink\.', ''
            $testFqdn = "$($pe.Name).$publicSuffix"
            try {
                $dnsResult = Resolve-DnsName -Name $testFqdn -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
                if ($dnsResult) {
                    $resolvedIp = $dnsResult.IPAddress
                    $resolvesPrivate = Test-PrivateIpAddress -IpAddress $resolvedIp
                    if (-not $resolvesPrivate) {
                        $findings.Add("Best-effort FQDN test ($testFqdn) resolved to a NON-private IP ($resolvedIp) — DNS may not be redirecting to the Private Endpoint")
                    }
                }
            } catch {
                # Resolution failure is informational only — many services' actual FQDN pattern
                # differs from the simple <peName>.<suffix> guess this script uses as a heuristic
            }
        }
    }

    # --- Subnet network policy state (informational) ---
    $networkPolicyState = "Unknown"
    try {
        $subnetIdParts = $subnetId -split '/'
        $vnetName = $subnetIdParts[8]
        $subnetName = $subnetIdParts[10]
        $vnetRg = $subnetIdParts[4]
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $vnetRg -Name $vnetName -ErrorAction SilentlyContinue
        if ($vnet) {
            $subnetConfig = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
            if ($subnetConfig) {
                $networkPolicyState = $subnetConfig.PrivateEndpointNetworkPolicies
            }
        }
    } catch {
        # Non-fatal — informational field only
    }

    $results += [PSCustomObject]@{
        PrivateEndpoint       = $pe.Name
        ResourceGroup         = $pe.ResourceGroupName
        ConnectionState       = $connState
        TargetResource        = if ($connection) { ($connection.PrivateLinkServiceId -split '/')[-1] } else { "Unknown" }
        AssignedPrivateIp     = $assignedIp
        HasDnsZoneGroup       = $hasZoneGroup
        ZoneCount             = $zoneGroupConfigs.Count
        BestEffortResolvedIp  = $resolvedIp
        ResolvesToPrivateIp   = $resolvesPrivate
        SubnetNetworkPolicies = $networkPolicyState
        FindingCount          = $findings.Count
        Findings              = ($findings -join " | ")
        NeedsReview           = $findings.Count -gt 0
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=== Private Endpoint Audit Summary ===" -ForegroundColor Cyan
Write-Host "Total endpoints audited: $($results.Count)"
Write-Host "Endpoints with findings: $(($results | Where-Object NeedsReview).Count)"
Write-Host ""

$results | Where-Object NeedsReview | ForEach-Object {
    Write-Status "$($_.PrivateEndpoint): $($_.Findings)" "WARN"
}

$results | Where-Object { -not $_.NeedsReview } | ForEach-Object {
    Write-Status "$($_.PrivateEndpoint): No issues detected" "OK"
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Full detail exported to: $ExportPath" "INFO"
