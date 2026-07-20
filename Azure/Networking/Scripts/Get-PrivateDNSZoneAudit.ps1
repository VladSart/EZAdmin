<#
.SYNOPSIS
    Audits Azure Private DNS zones for the most common causes of resolution failures: missing
    VNet links for peered networks, missing/misconfigured Private Endpoint DNS Zone Groups, and
    stale autoregistered records left behind by deleted VMs.

.DESCRIPTION
    Produces a read-only report covering four independent checks per zone in scope:

      1. ORPHANED ZONE — zone has zero VNet links at all (completely inert, cannot be queried
         by anything). Flags ZONE_NO_LINKS.

      2. PEERED-BUT-UNLINKED VNETS — for each VNet linked to a zone, checks that VNet's peerings
         and flags any peered VNet that is NOT itself linked to the same zone. This is the
         single most common root cause behind "works in the hub, not the spoke" tickets, since
         peering never implies a DNS zone link. Flags PEERED_VNET_NOT_LINKED.

      3. PRIVATE ENDPOINT ZONE GROUP COVERAGE — enumerates every Private Endpoint in the scoped
         resource group(s) and flags any endpoint with no DNS Zone Group at all
         (PE_NO_ZONE_GROUP) or a zone group whose provisioning state is not Succeeded
         (PE_ZONE_GROUP_NOT_HEALTHY).

      4. STALE AUTOREGISTERED RECORDS — for zones with at least one registration-enabled VNet
         link, cross-references A records in the zone against the current VM inventory across
         all linked VNets and flags records with no matching live VM as STALE_RECORD
         (informational — always reviewed manually before deletion, never auto-removed by
         this script).

    This is a fleet-wide inventory/hygiene sweep intended for periodic environment review, not
    a single-ticket diagnostic tool — for troubleshooting one specific FQDN, use the Diagnosis &
    Validation Flow in PrivateDNS-B.md instead.

.PARAMETER ZoneResourceGroup
    Resource group containing the Private DNS zone(s) to audit. If omitted, audits every
    Private DNS zone visible in the current subscription context.

.PARAMETER ZoneName
    Optional. Scopes the audit to a single named zone instead of all zones in scope.

.PARAMETER PrivateEndpointResourceGroup
    Resource group to scan for Private Endpoints when checking Zone Group coverage. If omitted,
    scans every resource group in the current subscription context. Can be slow on large
    subscriptions — narrow this when possible.

.PARAMETER SkipStaleRecordCheck
    Switch. Skips the stale autoregistered record cross-reference, which requires
    subscription-wide VM enumeration and can be slow in large environments.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\PrivateDNSZoneAudit_<timestamp>.csv.

.EXAMPLE
    .\Get-PrivateDNSZoneAudit.ps1 -ZoneResourceGroup 'rg-dns-prod'

.EXAMPLE
    .\Get-PrivateDNSZoneAudit.ps1 -ZoneName 'privatelink.blob.core.windows.net' -SkipStaleRecordCheck
    Audits a single reserved zone and skips the (slower) stale-record cross-reference.

.NOTES
    Requires: Az.PrivateDns, Az.Network, Az.Compute modules and prior Connect-AzAccount context.
    Read-only — makes no changes. Safe to run in production at any time.
    Run-as: any account with Reader access to the scoped resource group(s)/subscription.
#>

[CmdletBinding()]
param(
    [string]$ZoneResourceGroup,
    [string]$ZoneName,
    [string]$PrivateEndpointResourceGroup,
    [switch]$SkipStaleRecordCheck,
    [string]$ExportPath = "C:\Temp\PrivateDNSZoneAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Finding {
    param($Category, $Resource, $Finding, $Detail, $Severity = "Info")
    $results.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Category  = $Category
        Resource  = $Resource
        Finding   = $Finding
        Detail    = $Detail
        Severity  = $Severity
    })
}

# --- Preflight ---
Write-Status "Checking required modules..."
foreach ($mod in @('Az.PrivateDns','Az.Network','Az.Compute')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Required module '$mod' not found. Install with: Install-Module $mod" "ERROR"
        return
    }
}

try {
    $ctx = Get-AzContext
    if (-not $ctx) { throw "No Az context. Run Connect-AzAccount first." }
    Write-Status "Running as $($ctx.Account.Id) against subscription $($ctx.Subscription.Name)" "OK"
} catch {
    Write-Status $_.Exception.Message "ERROR"
    return
}

# --- Detect zones in scope ---
Write-Status "Enumerating Private DNS zones in scope..."
$zoneParams = @{}
if ($ZoneResourceGroup) { $zoneParams['ResourceGroupName'] = $ZoneResourceGroup }

$zones = if ($ZoneResourceGroup) {
    Get-AzPrivateDnsZone @zoneParams
} else {
    Get-AzPrivateDnsZone
}

if ($ZoneName) {
    $zones = $zones | Where-Object { $_.Name -eq $ZoneName }
}

if (-not $zones) {
    Write-Status "No Private DNS zones found in scope." "WARN"
    return
}
Write-Status "Found $($zones.Count) zone(s) to audit." "OK"

# --- Check 1 & 2: links, orphans, peered-but-unlinked ---
$vnetLinkMap = @{}   # zoneName -> list of linked VNet resource IDs

foreach ($zone in $zones) {
    Write-Status "Auditing zone: $($zone.Name)"
    $links = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $zone.ResourceGroupName -ZoneName $zone.Name

    if (-not $links -or $links.Count -eq 0) {
        Add-Finding -Category "ORPHANED_ZONE" -Resource $zone.Name `
            -Finding "ZONE_NO_LINKS" -Detail "Zone has zero VNet links; no VNet can resolve records in it." `
            -Severity "Warn"
        continue
    }

    $linkedVnetIds = $links | Select-Object -ExpandProperty VirtualNetworkId
    $vnetLinkMap[$zone.Name] = $linkedVnetIds

    foreach ($link in $links) {
        if (-not $link.VirtualNetworkId) { continue }
        try {
            $vnet = Get-AzResource -ResourceId $link.VirtualNetworkId -ErrorAction Stop
            $vnetObj = Get-AzVirtualNetwork -ResourceGroupName $vnet.ResourceGroupName -Name $vnet.Name -ErrorAction Stop
        } catch {
            Add-Finding -Category "LINK_HEALTH" -Resource $zone.Name `
                -Finding "LINKED_VNET_NOT_FOUND" -Detail "Linked VNet ID $($link.VirtualNetworkId) could not be resolved (deleted?)." `
                -Severity "Warn"
            continue
        }

        foreach ($peering in ($vnetObj.VirtualNetworkPeerings)) {
            if ($peering.PeeringState -ne 'Connected') { continue }
            $peerVnetId = $peering.RemoteVirtualNetwork.Id
            if ($peerVnetId -notin $linkedVnetIds) {
                Add-Finding -Category "PEERING_DNS_GAP" -Resource $zone.Name `
                    -Finding "PEERED_VNET_NOT_LINKED" `
                    -Detail "VNet '$($vnetObj.Name)' is linked and peered to '$($peering.Name)' (remote: $peerVnetId), but the peer is NOT linked to this zone." `
                    -Severity "Warn"
            }
        }
    }
}

# --- Check 3: Private Endpoint Zone Group coverage ---
Write-Status "Auditing Private Endpoint DNS Zone Group coverage..."
$peParams = @{}
if ($PrivateEndpointResourceGroup) { $peParams['ResourceGroupName'] = $PrivateEndpointResourceGroup }
$privateEndpoints = Get-AzPrivateEndpoint @peParams -ErrorAction SilentlyContinue

foreach ($pe in $privateEndpoints) {
    if (-not $pe.PrivateDnsZoneGroup) {
        Add-Finding -Category "PE_DNS_COVERAGE" -Resource $pe.Name `
            -Finding "PE_NO_ZONE_GROUP" -Detail "Private Endpoint has no DNS Zone Group — FQDN will resolve to public IP for any client not otherwise overriding DNS." `
            -Severity "Warn"
        continue
    }
    if ($pe.PrivateDnsZoneGroup.ProvisioningState -and $pe.PrivateDnsZoneGroup.ProvisioningState -ne 'Succeeded') {
        Add-Finding -Category "PE_DNS_COVERAGE" -Resource $pe.Name `
            -Finding "PE_ZONE_GROUP_NOT_HEALTHY" -Detail "Zone group provisioning state: $($pe.PrivateDnsZoneGroup.ProvisioningState)" `
            -Severity "Error"
    }
}

# --- Check 4: stale autoregistered records ---
if (-not $SkipStaleRecordCheck) {
    Write-Status "Cross-referencing autoregistered records against live VM inventory (this can take a while)..."
    $allVmNames = (Get-AzVM -Status -ErrorAction SilentlyContinue) | Select-Object -ExpandProperty Name

    foreach ($zone in $zones) {
        $links = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $zone.ResourceGroupName -ZoneName $zone.Name
        $hasRegistrationLink = $links | Where-Object { $_.RegistrationEnabled }
        if (-not $hasRegistrationLink) { continue }   # no autoregistration in play for this zone

        $records = Get-AzPrivateDnsRecordSet -ResourceGroupName $zone.ResourceGroupName -ZoneName $zone.Name -RecordType A
        foreach ($rec in $records) {
            if ($rec.Name -eq '@') { continue }   # zone apex, not a VM record
            if ($rec.Name -notin $allVmNames) {
                Add-Finding -Category "STALE_RECORD" -Resource $zone.Name `
                    -Finding "STALE_RECORD" -Detail "Record '$($rec.Name)' has no matching live VM in current subscription — verify manually before removal." `
                    -Severity "Info"
            }
        }
    }
} else {
    Write-Status "Stale record check skipped (-SkipStaleRecordCheck)." "WARN"
}

# --- Report ---
Write-Status "Audit complete. $($results.Count) finding(s)." "OK"

if ($results.Count -gt 0) {
    $results | Sort-Object Severity, Category | Format-Table Category, Resource, Finding, Severity -AutoSize
    $exportDir = Split-Path $ExportPath -Parent
    if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }
    $results | Export-Csv -Path $ExportPath -NoTypeInformation
    Write-Status "Full report exported to $ExportPath" "OK"
} else {
    Write-Status "No findings — all scoped zones, links, and Private Endpoints look healthy." "OK"
}
