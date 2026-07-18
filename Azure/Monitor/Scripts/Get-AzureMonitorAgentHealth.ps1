<#
.SYNOPSIS
    Read-only fleet-wide health audit of the Azure Monitor Agent (AMA) telemetry pipeline —
    legacy-agent detection, managed identity, extension provisioning, DCR association, and
    Data Collection Endpoint coverage — across Azure VMs (optionally including Arc-enabled servers).

.DESCRIPTION
    Produces a per-machine report covering:
      - LEGACY AGENT DETECTION: flags any machine still running the retired MicrosoftMonitoringAgent
        (MMA/OMS) extension as CRITICAL — its backend was shut down 2 Mar 2026 and it uploads nothing.
      - MANAGED IDENTITY: flags NO_IDENTITY for any machine with no system- or user-assigned identity,
        since AMA cannot authenticate to retrieve its Data Collection Rule (DCR) without one.
      - AMA EXTENSION STATE: reports ProvisioningState for AzureMonitorWindowsAgent/
        AzureMonitorLinuxAgent, flagging EXTENSION_NOT_INSTALLED, EXTENSION_FAILED, and
        EXTENSION_SUCCEEDED_UNVERIFIED (installed, but this script cannot confirm on-machine config
        receipt remotely — that requires the on-machine check documented in LogAnalytics-A.md's
        Evidence Pack; flagged here as a reminder, not a false pass).
      - DCR ASSOCIATION: flags NO_DCR_ASSOCIATION for any machine with an installed, provisioned
        AMA extension but zero associated Data Collection Rules — the single most common
        "AMA installed, no data" root cause.
      - DUPLICATE DATA SOURCE RISK: for machines with 2+ DCR associations, cross-references each
        DCR's declared data flow streams and flags POSSIBLE_DUPLICATE_STREAM when the same stream
        type (e.g. Microsoft-Perf) appears in more than one associated DCR — a likely double-billing
        pattern, reported for manual review since the script cannot see per-counter/per-query filters.
      - DATA COLLECTION ENDPOINT CHECK: best-effort — reports whether any DCR referenced by the
        machine specifies a Data Collection Endpoint, and if so, whether that DCE's region matches
        the machine's region (a hard requirement; a mismatch means the DCE cannot serve that agent).

    Does not modify anything — no extensions installed/removed, no DCR associations created or
    changed, no identities added. Safe to run at any time.

.PARAMETER ResourceGroupName
    Optional. Scope the audit to a single resource group. Defaults to every VM in the current
    subscription context if omitted.

.PARAMETER SubscriptionId
    Optional. Subscription to audit. Defaults to the current Az context's subscription if omitted.

.PARAMETER IncludeArc
    Switch. Also audits Azure Arc-enabled servers (Microsoft.HybridCompute/machines) in the same
    scope, using the equivalent extension/identity/DCR-association checks.

.PARAMETER ExportPath
    Path to export the CSV summary. Defaults to .\AzureMonitorAgentHealth_<timestamp>.csv in the
    current directory.

.EXAMPLE
    .\Get-AzureMonitorAgentHealth.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    .\Get-AzureMonitorAgentHealth.ps1 -ResourceGroupName "rg-client-prod" -IncludeArc

.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Monitor, Az.ConnectedMachine (only if -IncludeArc) modules
    Install:  Install-Module Az.Accounts, Az.Compute, Az.Monitor, Az.ConnectedMachine -Scope CurrentUser
    Permissions: Reader is sufficient for every check in this script.
    Safe to run: Fully read-only. Does not query Log Analytics workspace data (Heartbeat) directly —
                 this script audits the CONFIGURATION layer (identity/extension/DCR association) only.
                 Cross-reference findings against a live Heartbeat KQL query per LogAnalytics-A.md's
                 Validation Steps before declaring a machine fully healthy end to end.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$SubscriptionId,
    [switch]$IncludeArc,
    [string]$ExportPath = ".\AzureMonitorAgentHealth_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "CRITICAL" { "Red" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Checking Az module connectivity..."
$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Status "No active Az context found. Run Connect-AzAccount first." -Status ERROR
    throw "Not connected to Azure."
}
if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}
Write-Status "Connected as $($context.Account.Id) — Subscription: $((Get-AzContext).Subscription.Name)" -Status OK

$results = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Gather target VMs
# ---------------------------------------------------------------------------
Write-Status "Enumerating target Azure VMs..."
$vmParams = @{}
if ($ResourceGroupName) { $vmParams["ResourceGroupName"] = $ResourceGroupName }
$vms = Get-AzVM @vmParams
Write-Status "Found $($vms.Count) Azure VM(s) in scope." -Status OK

$arcMachines = @()
if ($IncludeArc) {
    Write-Status "Enumerating target Azure Arc-enabled servers..."
    try {
        $arcParams = @{}
        if ($ResourceGroupName) { $arcParams["ResourceGroupName"] = $ResourceGroupName }
        $arcMachines = Get-AzConnectedMachine @arcParams -ErrorAction Stop
        Write-Status "Found $($arcMachines.Count) Arc-enabled machine(s) in scope." -Status OK
    } catch {
        Write-Status "Could not enumerate Arc machines (Az.ConnectedMachine module missing or no permission): $($_.Exception.Message)" -Status WARN
    }
}

# ---------------------------------------------------------------------------
# Cache all DCRs and DCEs once up front (avoid repeated calls per machine)
# ---------------------------------------------------------------------------
Write-Status "Caching Data Collection Rules and Endpoints for cross-reference..."
$allDCRs = @{}
try {
    Get-AzDataCollectionRule -ErrorAction Stop | ForEach-Object { $allDCRs[$_.Id] = $_ }
} catch {
    Write-Status "Could not enumerate Data Collection Rules tenant/subscription-wide: $($_.Exception.Message)" -Status WARN
}

$allDCEs = @{}
try {
    Get-AzDataCollectionEndpoint -ErrorAction Stop | ForEach-Object { $allDCEs[$_.Id] = $_ }
} catch {
    Write-Status "Could not enumerate Data Collection Endpoints: $($_.Exception.Message)" -Status WARN
}

# ---------------------------------------------------------------------------
# Helper — audits one machine (Azure VM or Arc machine) given a resource ID/name/RG/location/identity/extensions
# ---------------------------------------------------------------------------
function Test-MonitorAgentHealth {
    param(
        [string]$MachineName,
        [string]$MachineType,   # "AzureVM" or "ArcMachine"
        [string]$ResourceGroup,
        [string]$Location,
        [string]$ResourceId,
        [string]$IdentityType,
        [array]$Extensions
    )

    $flags = [System.Collections.Generic.List[string]]::new()

    # --- Legacy agent detection ---
    $legacyExt = $Extensions | Where-Object { $_.ExtensionType -eq "MicrosoftMonitoringAgent" -or $_.Name -eq "MMAExtension" }
    if ($legacyExt) {
        $flags.Add("LEGACY_AGENT_PRESENT_CRITICAL")
    }

    # --- Managed identity ---
    if (-not $IdentityType -or $IdentityType -eq "None") {
        $flags.Add("NO_IDENTITY")
    }

    # --- AMA extension state ---
    $amaExt = $Extensions | Where-Object { $_.ExtensionType -match "AzureMonitor(Windows|Linux)Agent" }
    $amaState = "EXTENSION_NOT_INSTALLED"
    if ($amaExt) {
        $state = $amaExt[0].ProvisioningState
        if ($state -eq "Succeeded") {
            $amaState = "EXTENSION_SUCCEEDED_UNVERIFIED"
        } else {
            $amaState = "EXTENSION_FAILED"
            $flags.Add("EXTENSION_FAILED")
        }
    } else {
        $flags.Add("EXTENSION_NOT_INSTALLED")
    }

    # --- DCR association ---
    $associatedDCRIds = @()
    $dceIds = @()
    try {
        $assocs = Get-AzDataCollectionRuleAssociation -TargetResourceId $ResourceId -ErrorAction Stop
        $associatedDCRIds = $assocs | Where-Object { $_.DataCollectionRuleId } | Select-Object -ExpandProperty DataCollectionRuleId
    } catch {
        # Non-fatal — association lookup can fail on resources with no associations at all in some API versions
    }

    if ($amaExt -and $associatedDCRIds.Count -eq 0) {
        $flags.Add("NO_DCR_ASSOCIATION")
    }

    # --- Duplicate stream risk + DCE region check ---
    $streamCounts = @{}
    foreach ($dcrId in $associatedDCRIds) {
        $dcr = $allDCRs[$dcrId]
        if (-not $dcr) { continue }

        foreach ($flow in ($dcr.DataFlow | Where-Object { $_ })) {
            foreach ($stream in $flow.Stream) {
                if (-not $streamCounts.ContainsKey($stream)) { $streamCounts[$stream] = 0 }
                $streamCounts[$stream]++
            }
        }

        if ($dcr.DataCollectionEndpointId) {
            $dceIds += $dcr.DataCollectionEndpointId
            $dce = $allDCEs[$dcr.DataCollectionEndpointId]
            if ($dce -and $dce.Location -and $Location -and ($dce.Location -ne $Location)) {
                $flags.Add("DCE_REGION_MISMATCH")
            }
        }
    }
    $duplicateStreams = $streamCounts.GetEnumerator() | Where-Object { $_.Value -gt 1 } | ForEach-Object { $_.Key }
    if ($duplicateStreams) {
        $flags.Add("POSSIBLE_DUPLICATE_STREAM:$($duplicateStreams -join '|')")
    }

    if ($flags.Count -eq 0) {
        $flags.Add("OK")
    }

    [PSCustomObject]@{
        MachineName         = $MachineName
        MachineType         = $MachineType
        ResourceGroup       = $ResourceGroup
        Location            = $Location
        IdentityType        = $IdentityType
        AMAExtensionState   = $amaState
        DCRAssociationCount = $associatedDCRIds.Count
        DCEReferenced       = [bool]$dceIds.Count
        Flags               = ($flags -join "; ")
        Severity            = if ($flags -contains "LEGACY_AGENT_PRESENT_CRITICAL") { "CRITICAL" }
                               elseif ($flags | Where-Object { $_ -match "^(NO_IDENTITY|EXTENSION_FAILED|EXTENSION_NOT_INSTALLED|NO_DCR_ASSOCIATION|DCE_REGION_MISMATCH)$" }) { "WARN" }
                               elseif ($flags -match "POSSIBLE_DUPLICATE_STREAM") { "WARN" }
                               else { "OK" }
    }
}

# ---------------------------------------------------------------------------
# Audit Azure VMs
# ---------------------------------------------------------------------------
$vmCount = $vms.Count
$i = 0
foreach ($vm in $vms) {
    $i++
    Write-Progress -Activity "Auditing Azure VMs" -Status "$($vm.Name) ($i of $vmCount)" -PercentComplete (($i / [math]::Max($vmCount,1)) * 100)

    $extensions = @()
    try {
        $extensions = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -ErrorAction Stop
    } catch {
        Write-Status "Could not enumerate extensions for $($vm.Name): $($_.Exception.Message)" -Status WARN
    }

    $identityType = if ($vm.Identity) { $vm.Identity.Type } else { "None" }

    $results.Add((Test-MonitorAgentHealth -MachineName $vm.Name -MachineType "AzureVM" `
        -ResourceGroup $vm.ResourceGroupName -Location $vm.Location -ResourceId $vm.Id `
        -IdentityType $identityType -Extensions $extensions))
}
Write-Progress -Activity "Auditing Azure VMs" -Completed

# ---------------------------------------------------------------------------
# Audit Arc-enabled servers (optional)
# ---------------------------------------------------------------------------
if ($IncludeArc -and $arcMachines.Count -gt 0) {
    $arcCount = $arcMachines.Count
    $j = 0
    foreach ($arc in $arcMachines) {
        $j++
        Write-Progress -Activity "Auditing Arc-enabled servers" -Status "$($arc.Name) ($j of $arcCount)" -PercentComplete (($j / [math]::Max($arcCount,1)) * 100)

        $extensions = @()
        try {
            $extensions = Get-AzConnectedMachineExtension -ResourceGroupName $arc.ResourceGroupName -MachineName $arc.Name -ErrorAction Stop
        } catch {
            Write-Status "Could not enumerate extensions for Arc machine $($arc.Name): $($_.Exception.Message)" -Status WARN
        }

        $identityType = if ($arc.Identity) { $arc.Identity.Type } else { "None" }

        $results.Add((Test-MonitorAgentHealth -MachineName $arc.Name -MachineType "ArcMachine" `
            -ResourceGroup $arc.ResourceGroupName -Location $arc.Location -ResourceId $arc.Id `
            -IdentityType $identityType -Extensions $extensions))
    }
    Write-Progress -Activity "Auditing Arc-enabled servers" -Completed
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$critical = $results | Where-Object { $_.Severity -eq "CRITICAL" }
$warn = $results | Where-Object { $_.Severity -eq "WARN" }
$ok = $results | Where-Object { $_.Severity -eq "OK" }

Write-Host ""
Write-Status "=== Azure Monitor Agent Health Summary ===" -Status INFO
Write-Status "Total machines audited: $($results.Count)" -Status INFO
Write-Status "CRITICAL (legacy agent still active — zero data since 2 Mar 2026): $($critical.Count)" -Status $(if ($critical.Count -gt 0) { "CRITICAL" } else { "OK" })
Write-Status "WARN (identity/extension/DCR/DCE gaps): $($warn.Count)" -Status $(if ($warn.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "OK: $($ok.Count)" -Status OK
Write-Host ""

if ($critical.Count -gt 0) {
    Write-Status "CRITICAL machines (act on these first):" -Status CRITICAL
    $critical | Format-Table MachineName, ResourceGroup, Flags -AutoSize
}
if ($warn.Count -gt 0) {
    Write-Status "WARN machines:" -Status WARN
    $warn | Format-Table MachineName, ResourceGroup, Flags -AutoSize
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Full report exported to: $ExportPath" -Status OK
Write-Status "Reminder: this script audits the CONFIGURATION layer only. Confirm end-to-end delivery with a live 'Heartbeat' KQL query per LogAnalytics-A.md's Validation Steps before declaring any machine fully healthy." -Status INFO
