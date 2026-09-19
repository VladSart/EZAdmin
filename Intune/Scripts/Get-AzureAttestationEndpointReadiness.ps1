<#
.SYNOPSIS
    Audits fleet scoping and network readiness ahead of Intune's Windows Health Attestation
    migration from Device Health Attestation (DHA) to Microsoft Azure Attestation (MC1473156 /
    MC1473600).

.DESCRIPTION
    Two things this script does NOT do automatically, and why:
      1. It does not read compliance-policy Settings Catalog payloads to confirm a device's
         assigned policy actually uses a Device Health setting (BitLocker/Secure Boot/Code
         Integrity) — Graph's Settings Catalog structure varies per template and per policy
         and is not reliably summarized in a single stable field. Use the portal checklist
         this script prints, or cross-reference DeviceManagementConfiguration.Read.All manually
         for your specific compliance policy set.
      2. It does not confirm actual per-tenant migration rollout status — no documented Graph
         field exists for this as of this writing (the migration is a Plan for Change targeted
         for end of Q1 CY2027 with no published per-tenant schedule).

    What it DOES do:
      - Enumerates managed Windows devices and flags likely-Windows-11 builds (the only
        in-scope OS for this migration) via OS build-number heuristic.
      - Tests outbound TCP/443 reachability to the full known set of regional Microsoft Azure
        Attestation endpoints (grouped North America / Europe / Asia Pacific — see NOTES on the
        Europe/Asia Pacific grouping caveat) plus the legacy DHA endpoint, which remains required
        for Windows 10 devices and GCC High/DoD tenants indefinitely.
      - Exports a combined CSV: device inventory rows + reachability rows + a portal-check
        checklist, for use in an escalation package or a pre-migration readiness review.

.PARAMETER DeviceName
    Optional. Limit device inventory to a single device name (exact match). If omitted, pulls
    the full managed Windows device population (paged).

.PARAMETER SkipReachabilityTest
    Optional switch. Skip the network reachability tests (e.g. when running centrally against
    Graph only, from a location that doesn't represent any real managed device's network path).

.PARAMETER OutputPath
    Optional. CSV output path. Defaults to a timestamped file in the current directory.

.EXAMPLE
    .\Get-AzureAttestationEndpointReadiness.ps1
    Full sweep: device inventory + reachability test against every known regional endpoint,
    run from the local machine's own network path.

.EXAMPLE
    .\Get-AzureAttestationEndpointReadiness.ps1 -DeviceName "CONTOSO-LT-042" -SkipReachabilityTest
    Device-inventory-only lookup for one device, no network test (e.g. running from an admin
    workstation whose network path doesn't represent the target device's own site).

.NOTES
    Read-only. Requires the Microsoft.Graph.DeviceManagement module and
    DeviceManagementManagedDevices.Read.All scope (DeviceManagementConfiguration.Read.All is
    NOT requested — this script does not attempt to read compliance policy payload content).

    Region-to-hostname grouping source: Microsoft Learn, "Network endpoints for Microsoft
    Intune" — Migrating device health attestation compliance policies to Microsoft Azure
    attestation (consolidated FQDN list, confirmed 2026-09-19). The live page's regional tabs
    render client-side; only the North America tab's endpoint bullets rendered on a direct
    fetch during authoring. The Europe/Asia Pacific groupings below are reconstructed from the
    page's separate, complete consolidated endpoint list using standard Azure region-code
    suffix conventions (neu/weu = Europe, jpe = Japan East/Asia Pacific) — treat as a reasonable
    inference, not a directly confirmed tab-to-region mapping, and re-verify against the live
    page or the tenant's own behavior before hard-coding into firewall automation.

    Safe to run unattended. Makes no configuration changes.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DeviceName,

    [switch]$SkipReachabilityTest,

    [string]$OutputPath = ".\AzureAttestationReadiness_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight -------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.DeviceManagement)) {
    Write-Status "Microsoft.Graph.DeviceManagement module not found. Install with: Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser" "ERROR"
    throw "Required module missing."
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# --- Detect: device inventory -----------------------------------------------

Write-Status "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" -NoWelcome
Write-Status "Connected." "OK"

Write-Status "Querying managed Windows devices$(if ($DeviceName) { " matching '$DeviceName'" })..."
$filter = "operatingSystem eq 'Windows'"
if ($DeviceName) { $filter += " and deviceName eq '$DeviceName'" }

$devices = Get-MgDeviceManagementManagedDevice -Filter $filter -All

foreach ($d in $devices) {
    # Windows 11 build numbers start at 10.0.22000; this is a heuristic, not authoritative —
    # cross-reference against the actual product name field if precision matters.
    $isLikelyWin11 = $false
    if ($d.OSVersion -match '10\.0\.(\d{5,})') {
        $build = [int]$Matches[1]
        $isLikelyWin11 = $build -ge 22000
    }

    $results.Add([PSCustomObject]@{
        RecordType        = "Device"
        DeviceName        = $d.DeviceName
        OSVersion         = $d.OSVersion
        LikelyWindows11   = $isLikelyWin11
        InScopeCandidate  = if ($isLikelyWin11) { "Possible — verify Device Health compliance setting + non-GCCH/DoD tenant" } else { "Unlikely (build suggests Windows 10 or older) — legacy DHA path expected" }
        ComplianceState   = $d.ComplianceState
        LastSyncDateTime  = $d.LastSyncDateTime
        Note              = ""
    })
}

Write-Status "Collected $($results.Count) Windows device record(s)." "OK"

# --- Execute: regional endpoint reachability --------------------------------

$endpointsByRegion = [ordered]@{
    "North America" = @(
        "intunemaape1.eus.attest.azure.net",
        "intunemaape2.eus2.attest.azure.net",
        "intunemaape3.cus.attest.azure.net",
        "intunemaape4.wus.attest.azure.net",
        "intunemaape5.scus.attest.azure.net",
        "intunemaape6.ncus.attest.azure.net"
    )
    "Europe (grouping inferred - verify)" = @(
        "intunemaape7.neu.attest.azure.net",
        "intunemaape8.neu.attest.azure.net",
        "intunemaape9.neu.attest.azure.net",
        "intunemaape10.weu.attest.azure.net",
        "intunemaape11.weu.attest.azure.net",
        "intunemaape12.weu.attest.azure.net"
    )
    "Asia Pacific (grouping inferred - verify)" = @(
        "intunemaape13.jpe.attest.azure.net",
        "intunemaape17.jpe.attest.azure.net",
        "intunemaape18.jpe.attest.azure.net",
        "intunemaape19.jpe.attest.azure.net"
    )
}

if (-not $SkipReachabilityTest) {
    Write-Status ""
    Write-Status "=== Testing regional Azure Attestation endpoint reachability (TCP/443) ===" "INFO"
    Write-Status "Note: reflects THIS machine's network path only — re-run from representative sites." "WARN"

    foreach ($region in $endpointsByRegion.Keys) {
        foreach ($endpoint in $endpointsByRegion[$region]) {
            try {
                $test = Test-NetConnection -ComputerName $endpoint -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
                $reachable = $test.TcpTestSucceeded
                $status = if ($reachable) { "OK" } else { "ERROR" }
                Write-Status "$region : $endpoint -> $reachable" $status
                $results.Add([PSCustomObject]@{
                    RecordType       = "Reachability"
                    DeviceName       = "N/A"
                    OSVersion        = ""
                    LikelyWindows11  = ""
                    InScopeCandidate = ""
                    ComplianceState  = ""
                    LastSyncDateTime = ""
                    Note             = "$region | $endpoint | TCP443Reachable=$reachable"
                })
            } catch {
                Write-Status "$region : $endpoint -> test failed to execute ($($_.Exception.Message))" "WARN"
                $results.Add([PSCustomObject]@{
                    RecordType       = "Reachability"
                    DeviceName       = "N/A"
                    OSVersion        = ""
                    LikelyWindows11  = ""
                    InScopeCandidate = ""
                    ComplianceState  = ""
                    LastSyncDateTime = ""
                    Note             = "$region | $endpoint | TEST_EXECUTION_FAILED"
                })
            }
        }
    }

    Write-Status ""
    Write-Status "=== Testing legacy DHA endpoint (required indefinitely for Windows 10 / GCC High / DoD) ===" "INFO"
    try {
        $dhaTest = Test-NetConnection -ComputerName "has.spserv.microsoft.com" -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
        $dhaStatus = if ($dhaTest.TcpTestSucceeded) { "OK" } else { "WARN" }
        Write-Status "Legacy DHA (has.spserv.microsoft.com) -> $($dhaTest.TcpTestSucceeded)" $dhaStatus
        $results.Add([PSCustomObject]@{
            RecordType = "Reachability"; DeviceName = "N/A"; OSVersion = ""; LikelyWindows11 = ""
            InScopeCandidate = ""; ComplianceState = ""; LastSyncDateTime = ""
            Note = "Legacy DHA | has.spserv.microsoft.com | TCP443Reachable=$($dhaTest.TcpTestSucceeded)"
        })
    } catch {
        Write-Status "Legacy DHA endpoint test failed to execute" "WARN"
    }
} else {
    Write-Status "Skipping reachability tests (-SkipReachabilityTest specified)." "WARN"
}

# --- Report: portal-only checklist ------------------------------------------

Write-Status ""
Write-Status "=== PORTAL-ONLY EVIDENCE — no stable Graph field exists for these; collect manually ===" "WARN"
$portalChecklist = @(
    "Intune admin center > Devices > Compliance policies > <policy> > confirm which Device Health settings (BitLocker/Secure Boot/Code Integrity) are configured, per policy"
    "Intune admin center > Tenant administration > Tenant status > Tenant details > Tenant location (determines authoritative regional endpoint set)"
    "Confirm tenant cloud type (commercial/GCC vs. GCC High/DoD) — GCC High/DoD tenants are permanently excluded from this migration"
    "Check Microsoft 365 Message Center for MC1473156 / MC1473600 and any tenant-specific rollout follow-up notice"
)
foreach ($item in $portalChecklist) {
    Write-Host "  [ ] $item" -ForegroundColor Yellow
    $results.Add([PSCustomObject]@{
        RecordType = "PortalCheck"; DeviceName = "N/A"; OSVersion = ""; LikelyWindows11 = ""
        InScopeCandidate = ""; ComplianceState = ""; LastSyncDateTime = ""; Note = $item
    })
}

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status ""
Write-Status "Report exported to $OutputPath." "OK"
Write-Status "Remember: SSL/TLS-inspecting proxies can pass a raw TCP/443 test while still breaking real attestation traffic — a clean reachability result here is necessary but not sufficient." "WARN"
