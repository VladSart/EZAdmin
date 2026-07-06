<#
.SYNOPSIS
    Reports Windows 365 Cloud PC fleet-wide provisioning status, license consumption, and
    Azure Network Connection (ANC) health in a single pass.

.DESCRIPTION
    Mirrors the pattern of Azure/AVD/Scripts/Get-AVDSessionHealth.ps1 for the Windows 365
    Cloud PC estate. Automates the Validation Steps from Windows365-A.md and the Triage table
    from Windows365-B.md across the entire tenant instead of one user at a time.

    Reports include:
    - Every Cloud PC with Status, ProvisioningType, and StatusDetails (error code) where present
    - PROVISIONING_STUCK — flags Cloud PCs in pendingProvisioning for longer than
      -PendingProvisioningHoursThreshold, per Windows365-B.md Fix 2's "common miss" about
      group-based licensing lag
    - PROVISIONING_FAILED — surfaces the StatusDetails error code so networkConfigurationError
      (ANC problem) can be distinguished from internalServerError (transient, retry) per the
      Symptom -> Cause Map in Windows365-A.md
    - ANC health for every Azure Network Connection in the tenant — a single unhealthy ANC
      blocks all new/re- provisioning for every Cloud PC that depends on it, so this is
      reported independently of per-Cloud-PC status per Windows365-A.md Playbook 1
    - NOT_IN_INTUNE — flags Cloud PCs with Status = provisioned that have no matching managed
      device in Intune, the "provisioned but unusable" case from Windows365-A.md Phase 3 and
      Symptom -> Cause Map
    - License summary — per-SKU consumed vs. available count for Windows 365 Enterprise/
      Business SKUs (CPC_E_*/CPC_B_*), to catch fleet-wide license exhaustion before individual
      users start filing "no Cloud PC" tickets

    Does NOT perform any remediation, resize, or reprovision action — this is a read-only
    fleet report companion to the fix paths in Windows365-B.md and Windows365-A.md.

.PARAMETER PendingProvisioningHoursThreshold
    Hours a Cloud PC can sit in pendingProvisioning before being flagged PROVISIONING_STUCK.
    Default: 4 (matches the Windows365-B.md triage table's ">4 hours" threshold).

.PARAMETER SkipIntuneCheck
    Switch. Skip the per-Cloud-PC Intune enrollment cross-check (faster, but misses
    NOT_IN_INTUNE detection). Useful if DeviceManagementManagedDevices.Read.All isn't granted.

.PARAMETER ExportPath
    Directory to save CSV reports. Defaults to the current directory.

.EXAMPLE
    .\Get-CloudPcFleetStatus.ps1

.EXAMPLE
    .\Get-CloudPcFleetStatus.ps1 -PendingProvisioningHoursThreshold 6 -ExportPath C:\Temp\W365

.NOTES
    Requires: Microsoft.Graph.Beta module
    Install:  Install-Module Microsoft.Graph.Beta -Scope CurrentUser
    Permissions: CloudPC.Read.All, DeviceManagementConfiguration.Read.All,
                 DeviceManagementManagedDevices.Read.All (Graph delegated or app scopes)
    Safe to run: Read-only. No Cloud PCs are resized, reprovisioned, or restarted.
#>

[CmdletBinding()]
param(
    [int]$PendingProvisioningHoursThreshold = 4,
    [switch]$SkipIntuneCheck,
    [string]$ExportPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

#region Preflight
Write-Status "Windows 365 Cloud PC Fleet Status Reporter" "INFO"
Write-Status "===========================================" "INFO"

if (-not (Get-Module -ListAvailable -Name "Microsoft.Graph.Beta")) {
    Write-Status "Microsoft.Graph.Beta module not found. Install with: Install-Module Microsoft.Graph.Beta -Scope CurrentUser" "ERROR"
    exit 1
}

if (-not (Test-Path -Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
}

$scopes = @("CloudPC.Read.All", "DeviceManagementConfiguration.Read.All")
if (-not $SkipIntuneCheck) { $scopes += "DeviceManagementManagedDevices.Read.All" }

Write-Status "Connecting to Microsoft Graph..." "INFO"
try {
    Connect-MgGraph -Scopes $scopes -ErrorAction Stop -NoWelcome
    Write-Status "Connected to Microsoft Graph" "OK"
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    exit 1
}
#endregion

#region Cloud PC inventory
Write-Status "Retrieving Cloud PC inventory..." "INFO"
try {
    $cloudPcs = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All -ErrorAction Stop
} catch {
    Write-Status "Failed to retrieve Cloud PCs: $($_.Exception.Message)" "ERROR"
    exit 1
}
Write-Status "Retrieved $($cloudPcs.Count) Cloud PC(s)" "OK"

$intuneDevices = @()
if (-not $SkipIntuneCheck) {
    Write-Status "Retrieving Intune managed devices for enrollment cross-check..." "INFO"
    try {
        $intuneDevices = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All -ErrorAction Stop
        Write-Status "Retrieved $($intuneDevices.Count) Windows managed device(s)" "OK"
    } catch {
        Write-Status "Could not retrieve Intune managed devices — NOT_IN_INTUNE checks will be skipped: $($_.Exception.Message)" "WARN"
        $SkipIntuneCheck = $true
    }
}

$cloudPcReport = [System.Collections.Generic.List[PSCustomObject]]::new()
$now = Get-Date

foreach ($cpc in $cloudPcs) {
    $flags = [System.Collections.Generic.List[string]]::new()

    switch ($cpc.Status) {
        "failed" {
            $flags.Add("PROVISIONING_FAILED")
            if ($cpc.LastModifiedDateTime) {
                # keep as informational only — failure itself is the flag
            }
        }
        "pendingProvisioning" {
            $ageHours = if ($cpc.LastModifiedDateTime) {
                [math]::Round(($now - $cpc.LastModifiedDateTime).TotalHours, 1)
            } else { -1 }
            if ($ageHours -ge $PendingProvisioningHoursThreshold) {
                $flags.Add("PROVISIONING_STUCK (${ageHours}h)")
            }
        }
        "provisionedWithWarnings" { $flags.Add("PROVISIONED_WITH_WARNINGS") }
        default { }
    }

    if (-not $SkipIntuneCheck -and $cpc.Status -eq "provisioned") {
        $match = $intuneDevices | Where-Object {
            $_.UserPrincipalName -eq $cpc.UserPrincipalName -and ($_.Model -like "*Cloud PC*" -or $_.DeviceName -like "*$($cpc.DisplayName)*")
        }
        if (-not $match) { $flags.Add("NOT_IN_INTUNE") }
    }

    $cloudPcReport.Add([PSCustomObject]@{
        DisplayName        = $cpc.DisplayName
        UserPrincipalName  = $cpc.UserPrincipalName
        Status             = $cpc.Status
        StatusDetails      = $cpc.StatusDetails.Code
        ProvisioningType   = $cpc.ProvisioningType
        ServicePlanName    = $cpc.ServicePlanName
        LastModified       = $cpc.LastModifiedDateTime
        Flags              = ($flags -join "; ")
        Severity           = if ($flags -match "PROVISIONING_FAILED|NOT_IN_INTUNE") { "HIGH" }
                              elseif ($flags.Count -gt 0) { "MEDIUM" }
                              else { "OK" }
    })
}
#endregion

#region ANC health
Write-Status "Retrieving Azure Network Connection health..." "INFO"
$ancReport = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $ancs = Get-MgBetaDeviceManagementVirtualEndpointOnPremisesConnection -ErrorAction Stop
    foreach ($anc in $ancs) {
        $ancReport.Add([PSCustomObject]@{
            DisplayName       = $anc.DisplayName
            HealthCheckStatus = $anc.HealthCheckStatus
            ErrorType         = $anc.ErrorType
            Flag              = if ($anc.HealthCheckStatus -ne "healthy") { "ANC_UNHEALTHY" } else { "OK" }
        })
    }
    Write-Status "Retrieved $($ancs.Count) ANC(s)" "OK"
} catch {
    Write-Status "Could not retrieve ANCs (tenant may be fully Entra-joined with none configured): $($_.Exception.Message)" "WARN"
}
#endregion

#region License summary
Write-Status "Building license consumption summary..." "INFO"
$licenseReport = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $skus = Get-MgSubscribedSku -All -ErrorAction Stop | Where-Object { $_.SkuPartNumber -match "^CPC_(E|B)_" }
    foreach ($sku in $skus) {
        $enabled = $sku.PrepaidUnits.Enabled
        $consumed = $sku.ConsumedUnits
        $pctUsed = if ($enabled -gt 0) { [math]::Round(($consumed / $enabled) * 100, 1) } else { 0 }
        $licenseReport.Add([PSCustomObject]@{
            SkuPartNumber = $sku.SkuPartNumber
            Enabled       = $enabled
            Consumed      = $consumed
            Available     = $enabled - $consumed
            PctUsed       = $pctUsed
            Flag          = if ($pctUsed -ge 95) { "NEAR_EXHAUSTION" } else { "OK" }
        })
    }
} catch {
    Write-Status "Could not retrieve license SKU consumption: $($_.Exception.Message)" "WARN"
}
#endregion

#region Summary + export
$separator = "=" * 60
Write-Host ""
Write-Host $separator -ForegroundColor Cyan
Write-Host "  WINDOWS 365 CLOUD PC FLEET STATUS" -ForegroundColor Cyan
Write-Host "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan
Write-Host ""

$high = $cloudPcReport | Where-Object Severity -eq "HIGH"
$med  = $cloudPcReport | Where-Object Severity -eq "MEDIUM"
Write-Status "Total Cloud PCs: $($cloudPcReport.Count)" "INFO"
Write-Status "HIGH severity (failed / not in Intune): $($high.Count)" $(if ($high.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "MEDIUM severity (stuck / warnings): $($med.Count)" $(if ($med.Count -gt 0) { "WARN" } else { "OK" })
Write-Host ""

if ($high.Count -gt 0) {
    Write-Host "[ HIGH SEVERITY CLOUD PCs ]" -ForegroundColor Red
    $high | Select-Object DisplayName, UserPrincipalName, Status, StatusDetails, Flags | Format-Table -AutoSize
}

$ancUnhealthy = $ancReport | Where-Object Flag -eq "ANC_UNHEALTHY"
Write-Host "[ AZURE NETWORK CONNECTION HEALTH ]" -ForegroundColor Yellow
if ($ancUnhealthy.Count -gt 0) {
    Write-Status "$($ancUnhealthy.Count) unhealthy ANC(s) found — blocks ALL new/re-provisioning through them" "ERROR"
    $ancUnhealthy | Format-Table -AutoSize
} elseif ($ancReport.Count -gt 0) {
    Write-Status "All $($ancReport.Count) ANC(s) healthy" "OK"
} else {
    Write-Status "No ANCs configured (fully Entra ID-joined fleet, or none retrieved)" "INFO"
}
Write-Host ""

if ($licenseReport.Count -gt 0) {
    Write-Host "[ LICENSE CONSUMPTION ]" -ForegroundColor Yellow
    $licenseReport | Format-Table -AutoSize
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$cpcCsv = Join-Path $ExportPath "CloudPcFleetStatus-$stamp.csv"
$cloudPcReport | Export-Csv -Path $cpcCsv -NoTypeInformation -Encoding UTF8
Write-Status "Cloud PC report exported to: $cpcCsv" "OK"

if ($ancReport.Count -gt 0) {
    $ancCsv = Join-Path $ExportPath "CloudPcFleetStatus-ANCHealth-$stamp.csv"
    $ancReport | Export-Csv -Path $ancCsv -NoTypeInformation -Encoding UTF8
    Write-Status "ANC health report exported to: $ancCsv" "OK"
}

if ($licenseReport.Count -gt 0) {
    $licCsv = Join-Path $ExportPath "CloudPcFleetStatus-Licenses-$stamp.csv"
    $licenseReport | Export-Csv -Path $licCsv -NoTypeInformation -Encoding UTF8
    Write-Status "License report exported to: $licCsv" "OK"
}

Write-Status "Windows 365 Cloud PC fleet status report complete." "OK"
#endregion
