<#
.SYNOPSIS
    Audits a tenant's Defender for Business licensing/seat consumption and,
    optionally, a local device's sensor/policy state for DfB-specific triage.

.DESCRIPTION
    Defender for Business (DfB) runs on the same SENSE sensor and portal as full
    Defender for Endpoint (MDE) — most sensor-level issues are covered by
    Get-MDEDeviceStatus.ps1. This script focuses on the parts that are genuinely
    DfB-specific:
      - Confirms which SKU is present (standalone DEFENDER_BUSINESS vs. bundled
        SPB / Microsoft 365 Business Premium)
      - Reports seat consumption against the 300-user program cap
      - Flags near-cap or at-cap tenants before they cause onboarding failures
      - Optionally inspects the LOCAL device's Default-policy-vs-custom-policy
        effective config to help diagnose "unexpected settings" tickets

    Tenant-scope checks use Microsoft Graph (read-only). Device-scope checks run
    locally via Get-MpPreference/Get-MpComputerStatus and require no admin rights
    beyond what's already needed to query Defender AV state.

.PARAMETER IncludeDeviceCheck
    If set, also runs the local device sensor/policy snapshot in addition to the
    tenant licensing check. Run this switch directly on the affected endpoint.

.PARAMETER SeatWarningThresholdPercent
    Percentage of seat consumption at which to flag a WARN (default: 90).

.PARAMETER ExportPath
    Full path for CSV export of the license summary. Defaults to
    $env:TEMP\DfB-Status-<date>.csv.

.EXAMPLE
    # Tenant-only licensing check (run from any machine with Graph access)
    .\Get-DefenderForBusinessStatus.ps1

.EXAMPLE
    # Full check including local device policy snapshot — run ON the affected device
    .\Get-DefenderForBusinessStatus.ps1 -IncludeDeviceCheck

.EXAMPLE
    # Flag seat consumption earlier, at 75%
    .\Get-DefenderForBusinessStatus.ps1 -SeatWarningThresholdPercent 75

.NOTES
    Requires: Microsoft.Graph.Users.Actions / Microsoft.Graph.Identity.DirectoryManagement
              (Install-Module Microsoft.Graph)
    Permissions needed (Graph): Organization.Read.All (delegated or app)
    Recommended role: Global Reader, License Administrator, or Security Reader
    Device-scope portion requires no elevation beyond standard Defender AV query rights.
    Safe to run in production — read-only operations only.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$IncludeDeviceCheck,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$SeatWarningThresholdPercent = 90,

    [Parameter()]
    [string]$ExportPath = "$env:TEMP\DfB-Status-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR","SECTION")]
        [string]$Status = "INFO"
    )
    $colour = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SECTION" { "Cyan" }
        default   { "White" }
    }
    $prefix = if ($Status -eq "SECTION") { "`n====" } else { "[$Status]" }
    Write-Host "$prefix $Message" -ForegroundColor $colour
}

$DfbSkuPatterns = @("DEFENDER_BUSINESS", "SPB", "SPE_E3", "SPE_E5")
$SeatCap = 300

#region Prerequisites
Write-Status "Checking prerequisites..." -Status SECTION

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
    Write-Status "Microsoft.Graph.Identity.DirectoryManagement module not found. Installing..." -Status WARN
    Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
Write-Status "Graph module loaded." -Status OK
#endregion

#region Authentication
Write-Status "Connecting to Microsoft Graph..." -Status SECTION
try {
    Connect-MgGraph -Scopes "Organization.Read.All" -NoWelcome -ErrorAction Stop
    $context = Get-MgContext
    Write-Status "Connected as: $($context.Account) | Tenant: $($context.TenantId)" -Status OK
}
catch {
    Write-Status "Graph connection failed: $($_.Exception.Message)" -Status ERROR
    Write-Status "Try: Connect-MgGraph -Scopes 'Organization.Read.All'" -Status INFO
    exit 1
}
#endregion

#region License / Seat Audit
Write-Status "Auditing Defender for Business licensing..." -Status SECTION

$allSkus = Get-MgSubscribedSku -ErrorAction Stop
$dfbSkus = $allSkus | Where-Object {
    $partNumber = $_.SkuPartNumber
    $DfbSkuPatterns | Where-Object { $partNumber -match $_ }
}

if (-not $dfbSkus) {
    Write-Status "No Defender for Business, Business Premium, or E3/E5 SKUs found on this tenant." -Status WARN
    Write-Status "Confirm this is the correct tenant, or that DfB terminology applies here." -Status INFO
}

$licenseResults = [System.Collections.Generic.List[PSObject]]::new()

foreach ($sku in $dfbSkus) {
    $total = $sku.PrepaidUnits.Enabled
    $consumed = $sku.ConsumedUnits
    $isStandaloneDfB = $sku.SkuPartNumber -match "DEFENDER_BUSINESS"
    $effectiveCap = if ($isStandaloneDfB) { [Math]::Min($total, $SeatCap) } else { $total }
    $pctUsed = if ($effectiveCap -gt 0) { [Math]::Round(($consumed / $effectiveCap) * 100, 1) } else { 0 }

    $status = if ($isStandaloneDfB -and $consumed -ge $SeatCap) {
        "AT PROGRAM CAP (300)"
    } elseif ($pctUsed -ge $SeatWarningThresholdPercent) {
        "NEAR CAPACITY"
    } else {
        "OK"
    }

    $record = [PSCustomObject]@{
        SkuPartNumber   = $sku.SkuPartNumber
        SkuId           = $sku.SkuId
        ConsumedUnits   = $consumed
        TotalUnits      = $total
        PercentUsed     = $pctUsed
        ProgramCapNote  = if ($isStandaloneDfB) { "300-seat DfB program cap applies" } else { "No DfB seat cap (bundled/enterprise SKU)" }
        Status          = $status
    }
    $licenseResults.Add($record)

    $colour = switch ($status) {
        "AT PROGRAM CAP (300)" { "ERROR" }
        "NEAR CAPACITY"        { "WARN" }
        default                { "OK" }
    }
    Write-Status "$($sku.SkuPartNumber): $consumed / $total used ($pctUsed%) — $status" -Status $colour
}

if ($licenseResults.Count -gt 0) {
    $licenseResults | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "License summary exported to: $ExportPath" -Status OK
}
#endregion

#region Device-Scope Check (optional)
if ($IncludeDeviceCheck) {
    Write-Status "Running local device sensor/policy snapshot..." -Status SECTION

    try {
        $sense = Get-Service -Name "Sense" -ErrorAction SilentlyContinue
        $onboarding = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -ErrorAction SilentlyContinue
        $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
        $mpPref = Get-MpPreference -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            SenseServiceStatus = $sense.Status
            SenseStartType     = $sense.StartType
            OnboardingState    = $onboarding.OnboardingState
            OrgId              = $onboarding.OrgId
            AMRunningMode      = $mpStatus.AMRunningMode
            AntivirusEnabled   = $mpStatus.AntivirusEnabled
            RealTimeProtection = $mpStatus.RealTimeProtectionEnabled
            IsTamperProtected  = $mpStatus.IsTamperProtected
            ASRRuleCount       = ($mpPref.AttackSurfaceReductionRules_Ids | Measure-Object).Count
            PUAProtection      = $mpPref.PUAProtection
            CloudBlockLevel    = $mpPref.CloudBlockLevel
        } | Format-List

        if ($mpStatus.AMRunningMode -eq "Passive") {
            Write-Status "AV is in Passive mode (3rd-party AV likely primary). Real-time blocking requires EDR in Block Mode — check portal: Settings > Endpoints > Advanced features." -Status WARN
        }
        if (-not $onboarding.OnboardingState -or $onboarding.OnboardingState -eq 0) {
            Write-Status "Device does not appear onboarded locally. If licensing shows available seats, investigate onboarding delivery (Intune/GPO/script) — see MDE-Onboarding-B.md." -Status ERROR
        }
    }
    catch {
        Write-Status "Device-scope check failed: $($_.Exception.Message)" -Status ERROR
        Write-Status "Ensure this script is run locally on the affected endpoint with Defender AV present." -Status INFO
    }
}
else {
    Write-Status "Skipping device-scope check (use -IncludeDeviceCheck to run it on the affected endpoint)." -Status INFO
}
#endregion

#region Disconnect
Disconnect-MgGraph | Out-Null
Write-Status "Disconnected from Microsoft Graph." -Status OK
Write-Status "Run complete." -Status OK
#endregion
