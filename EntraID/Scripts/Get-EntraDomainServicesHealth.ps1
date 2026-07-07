<#
.SYNOPSIS
    Audits Microsoft Entra Domain Services (Entra DS) managed domain health, network path, and
    per-user password-hash-sync readiness.

.DESCRIPTION
    Companion script to EntraID/Troubleshooting/EntraDomainServices-A.md and -B.md. Automates the
    runbook's Validation Steps in a single pass:
      - Managed domain resource health (Get-AzADDomainService) and replica set status
      - VNet peering reciprocity between the workload VNet and the Entra DS VNet — a one-sided
        peering (Connected on only one side) is called out in the runbook as the single most common
        "worked yesterday, broken today" root cause for domain-join/DNS failures
      - Workload VNet DNS configuration (DhcpOptions) — must point at the Entra DS replica set IPs
      - LDAPS certificate presence/expiry, since Entra DS has no service-side renewal reminder
      - Optional per-user password-hash-sync readiness check (cloud-only vs. hybrid distinction that
        drives the #1 "new managed domain, can't log into the domain-joined VM" ticket pattern)

    This script is read-only. It does not create peerings, rotate certificates, or force password
    changes — see the runbook's Remediation Playbooks for those actions.

.PARAMETER ResourceGroupName
    Resource group containing the Entra Domain Services resource.

.PARAMETER DomainServiceName
    Name of the Entra Domain Services resource (the managed domain name).

.PARAMETER WorkloadVNetName
    Optional. Name of the workload VNet peered to the Entra DS VNet, to check peering reciprocity
    and DNS configuration.

.PARAMETER EntraDSVNetName
    Optional. Name of the Entra DS VNet itself, to check the reciprocal side of the peering.

.PARAMETER AffectedUserUpn
    Optional. UPN of a specific user experiencing an authentication issue, to check their
    on-premises sync state (cloud-only vs. hybrid password hash sync readiness).

.PARAMETER OutputPath
    Folder to write the CSV report to. Default: $env:TEMP.

.EXAMPLE
    .\Get-EntraDomainServicesHealth.ps1 -ResourceGroupName "rg-identity" -DomainServiceName "contoso.com"
    Checks managed domain resource health only.

.EXAMPLE
    .\Get-EntraDomainServicesHealth.ps1 -ResourceGroupName "rg-identity" -DomainServiceName "contoso.com" `
        -WorkloadVNetName "vnet-workload" -EntraDSVNetName "vnet-entradś" -AffectedUserUpn "jdoe@contoso.com"
    Full check including VNet peering reciprocity, DNS, and a specific user's sync state.

.NOTES
    Requires: Az.ADDomainServices, Az.Network, Az.Accounts, Microsoft.Graph.Users modules.
    Auth: Connect-AzAccount and, if -AffectedUserUpn is supplied, Connect-MgGraph -Scopes "User.Read.All".
    Safe: Read-only. No configuration changes, no certificate uploads, no password resets.
    Companion runbooks: EntraID/Troubleshooting/EntraDomainServices-A.md (deep dive),
                         EntraID/Troubleshooting/EntraDomainServices-B.md (hotfix triage).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$DomainServiceName,
    [string]$WorkloadVNetName,
    [string]$EntraDSVNetName,
    [string]$AffectedUserUpn,
    [string]$OutputPath = $env:TEMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

foreach ($mod in @("Az.ADDomainServices", "Az.Network")) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" "ERROR"
        return
    }
}

$findings = New-Object System.Collections.Generic.List[string]
$report = [ordered]@{
    DomainServiceName = $DomainServiceName
    ResourceGroupName = $ResourceGroupName
    CheckedAt         = (Get-Date)
}

# ---- Preflight / Detect: managed domain resource health ----
Write-Status "Checking Entra Domain Services managed domain resource..." "INFO"

try {
    $domainSvc = Get-AzADDomainService -ResourceGroupName $ResourceGroupName -Name $DomainServiceName -ErrorAction Stop
    $report["DomainConfigurationType"] = $domainSvc.DomainConfigurationType
    $report["DeploymentId"]            = $domainSvc.DeploymentId

    if ($domainSvc.ReplicaSets) {
        $unhealthyReplicas = $domainSvc.ReplicaSets | Where-Object { $_.ServiceStatus -ne "Running" }
        $report["ReplicaSetCount"]     = $domainSvc.ReplicaSets.Count
        $report["UnhealthyReplicaSetCount"] = ($unhealthyReplicas | Measure-Object).Count

        if ($unhealthyReplicas) {
            Write-Status "$($unhealthyReplicas.Count) replica set(s) not in 'Running' state. This affects every downstream consumer — resolve before chasing single-user/single-VM theories." "ERROR"
            $findings.Add("REPLICA_SET_UNHEALTHY")
        } else {
            Write-Status "All $($domainSvc.ReplicaSets.Count) replica set(s) report ServiceStatus = Running." "OK"
        }
    } else {
        Write-Status "No replica set information returned — check the resource in the Azure portal Health blade directly." "WARN"
        $findings.Add("NO_REPLICA_SET_DATA")
    }

    # LDAPS certificate check
    if ($domainSvc.LdapsSettings) {
        $report["LdapsEnabled"] = $domainSvc.LdapsSettings.Ldaps
        $certExpiry = $domainSvc.LdapsSettings.CertificateExpiryDate
        if ($certExpiry) {
            $report["LdapsCertificateExpiry"] = $certExpiry
            $daysToExpiry = ([datetime]$certExpiry - (Get-Date)).Days
            if ($daysToExpiry -le 30) {
                Write-Status "LDAPS certificate expires in $daysToExpiry day(s) ($certExpiry). Entra DS does not send a renewal reminder — rotate proactively." "WARN"
                $findings.Add("LDAPS_CERT_EXPIRING_SOON")
            } else {
                Write-Status "LDAPS certificate valid for $daysToExpiry more day(s)." "OK"
            }
        } elseif ($domainSvc.LdapsSettings.Ldaps -eq "Enabled") {
            Write-Status "LDAPS is enabled but certificate expiry was not exposed by this module version — check the portal's Secure LDAP blade directly." "WARN"
        }
    } else {
        Write-Status "Secure LDAP (LDAPS) is not configured on this managed domain." "INFO"
    }
} catch {
    Write-Status "Failed to query Get-AzADDomainService: $($_.Exception.Message)" "ERROR"
    $findings.Add("DOMAIN_SERVICE_QUERY_FAILED")
}

# ---- Execute: VNet peering reciprocity ----
if ($WorkloadVNetName) {
    Write-Status "Checking workload VNet peering ('$WorkloadVNetName')..." "INFO"
    try {
        $workloadPeerings = Get-AzVirtualNetworkPeering -ResourceGroupName $ResourceGroupName -VirtualNetworkName $WorkloadVNetName -ErrorAction Stop
        $report["WorkloadVNet_PeeringStates"] = ($workloadPeerings | ForEach-Object { "$($_.Name):$($_.PeeringState)/$($_.PeeringSyncLevel)" }) -join "; "

        $badWorkloadPeering = $workloadPeerings | Where-Object { $_.PeeringState -ne "Connected" -or $_.PeeringSyncLevel -ne "FullyInSync" }
        if ($badWorkloadPeering) {
            Write-Status "Workload VNet has a peering not in Connected/FullyInSync state." "WARN"
            $findings.Add("WORKLOAD_PEERING_NOT_FULLY_SYNCED")
        } else {
            Write-Status "Workload VNet peering(s) Connected and FullyInSync." "OK"
        }

        $workloadVNet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $WorkloadVNetName -ErrorAction Stop
        $dnsServers = $workloadVNet.DhcpOptions.DnsServers
        $report["WorkloadVNet_DnsServers"] = ($dnsServers -join ", ")
        if (-not $dnsServers -or $dnsServers.Count -eq 0) {
            Write-Status "Workload VNet has no custom DNS servers configured (using Azure-provided DNS) — this will NOT resolve the Entra DS managed domain. DNS must point at the Entra DS replica set IPs." "WARN"
            $findings.Add("WORKLOAD_VNET_DNS_NOT_SET")
        } else {
            Write-Status "Workload VNet DNS servers configured: $($dnsServers -join ', ') — confirm these match the Entra DS replica set IPs." "OK"
        }
    } catch {
        Write-Status "Failed to check workload VNet '$WorkloadVNetName': $($_.Exception.Message)" "ERROR"
        $findings.Add("WORKLOAD_VNET_CHECK_FAILED")
    }
}

if ($EntraDSVNetName) {
    Write-Status "Checking Entra DS VNet peering ('$EntraDSVNetName') for reciprocity..." "INFO"
    try {
        $entraDsPeerings = Get-AzVirtualNetworkPeering -ResourceGroupName $ResourceGroupName -VirtualNetworkName $EntraDSVNetName -ErrorAction Stop
        $report["EntraDSVNet_PeeringStates"] = ($entraDsPeerings | ForEach-Object { "$($_.Name):$($_.PeeringState)/$($_.PeeringSyncLevel)" }) -join "; "

        $badEntraDsPeering = $entraDsPeerings | Where-Object { $_.PeeringState -ne "Connected" -or $_.PeeringSyncLevel -ne "FullyInSync" }
        if ($badEntraDsPeering) {
            Write-Status "Entra DS VNet side of the peering is NOT Connected/FullyInSync. This is the classic one-sided-peering failure — workload side may look fine while this side silently breaks domain join/DNS." "ERROR"
            $findings.Add("ENTRADS_PEERING_ONE_SIDED")
        } else {
            Write-Status "Entra DS VNet peering(s) Connected and FullyInSync." "OK"
        }
    } catch {
        Write-Status "Failed to check Entra DS VNet '$EntraDSVNetName': $($_.Exception.Message)" "ERROR"
        $findings.Add("ENTRADS_VNET_CHECK_FAILED")
    }
}

if ($WorkloadVNetName -and $EntraDSVNetName -and
    $report.Contains("WorkloadVNet_PeeringStates") -and $report.Contains("EntraDSVNet_PeeringStates") -and
    -not $findings.Contains("WORKLOAD_PEERING_NOT_FULLY_SYNCED") -and -not $findings.Contains("ENTRADS_PEERING_ONE_SIDED")) {
    Write-Status "Peering is reciprocal and fully synced on both sides." "OK"
}

# ---- Execute: optional per-user password-hash-sync readiness ----
if ($AffectedUserUpn) {
    Write-Status "Checking sync state for '$AffectedUserUpn'..." "INFO"
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
        Write-Status "Microsoft.Graph.Users module not found — skipping user check. Install with: Install-Module Microsoft.Graph.Users -Scope CurrentUser" "WARN"
    } else {
        try {
            if (-not (Get-MgContext)) { Connect-MgGraph -Scopes "User.Read.All" -NoWelcome }
            $user = Get-MgUser -UserId $AffectedUserUpn -Property DisplayName, OnPremisesSyncEnabled, OnPremisesLastSyncDateTime -ErrorAction Stop
            $report["AffectedUser_DisplayName"]  = $user.DisplayName
            $report["AffectedUser_IsHybrid"]     = [bool]$user.OnPremisesSyncEnabled
            $report["AffectedUser_LastSync"]     = $user.OnPremisesLastSyncDateTime

            if ($user.OnPremisesSyncEnabled) {
                Write-Status "User is hybrid-synced. Confirm Entra Connect Password Hash Sync (PHS) is enabled and healthy in Entra Connect Health — PTA/Federation alone will never populate the hash Entra DS needs." "INFO"
                $findings.Add("USER_IS_HYBRID_VERIFY_PHS")
            } else {
                Write-Status "User is cloud-only. Confirm whether they have changed/set their password since Entra DS was enabled on the tenant — if not, this is expected behavior (no bulk hash backfill), not a bug. Remediation: force a password change." "INFO"
                $findings.Add("USER_IS_CLOUDONLY_CHECK_PWD_CHANGE_HISTORY")
            }
        } catch {
            Write-Status "Failed to query user '$AffectedUserUpn': $($_.Exception.Message)" "ERROR"
            $findings.Add("USER_QUERY_FAILED")
        }
    }
}

# ---- Report ----
Write-Status "Writing report..." "INFO"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = Join-Path $OutputPath "EntraDomainServices-Health-$timestamp.csv"

[PSCustomObject]$report | Export-Csv -Path $csvPath -NoTypeInformation -Force
Write-Status "Report written: $csvPath" "OK"

Write-Host ""
Write-Status "=== SUMMARY ===" "INFO"
if ($findings.Count -eq 0) {
    Write-Status "No issues flagged." "OK"
} else {
    Write-Status "Flags raised: $($findings -join ', ')" "WARN"
}
Write-Host ""

[PSCustomObject]$report | Format-List
