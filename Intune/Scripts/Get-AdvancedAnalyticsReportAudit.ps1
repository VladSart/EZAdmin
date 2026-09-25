<#
.SYNOPSIS
    Exports and flags Intune Advanced Analytics data (anomalies, battery health, resource performance) via Microsoft Graph beta.

.DESCRIPTION
    Read-only tenant audit for Microsoft Intune Advanced Analytics. It:
      1. Checks subscribed SKUs for a service plan that looks like an Advanced Analytics entitlement
         (loose name match - bundle plan names vary; confirm manually if nothing matches).
      2. Pulls the beta userExperienceAnalyticsAnomaly collection and lists active anomalies.
      3. Pulls userExperienceAnalyticsBatteryHealthDevicePerformance and flags devices below the
         capacity / estimated-runtime thresholds used by the Learn battery health insights
         (<60 % capacity most impacted, <3 h runtime most impacted).
      4. Pulls userExperienceAnalyticsResourcePerformance and flags devices below a score threshold.
    Each dataset is written to CSV and a summary is printed.

    It does NOT: change any setting, create device scopes, read the Device timeline (no documented
    bulk API), or run device queries. Graph beta resource shapes can change; missing properties are
    written as empty values rather than failing the run. Values of -1 mean "not available" (same as
    the portal CSV export).

.PARAMETER OutputFolder
    Folder for CSV output. Created if missing. Default: .\AdvancedAnalyticsAudit

.PARAMETER CapacityThreshold
    Battery max-capacity percentage below which a device is flagged. Default 60.

.PARAMETER RuntimeThresholdMinutes
    Estimated battery runtime (minutes) below which a device is flagged. Default 180.

.PARAMETER ResourceScoreThreshold
    Resource performance score (0-100) below which a device is flagged. Default 50.

.EXAMPLE
    .\Get-AdvancedAnalyticsReportAudit.ps1 -OutputFolder C:\Temp\AA

.EXAMPLE
    .\Get-AdvancedAnalyticsReportAudit.ps1 -CapacityThreshold 80 -RuntimeThresholdMinutes 240

.NOTES
    Requires: Microsoft.Graph.Authentication (Invoke-MgGraphRequest) and Microsoft.Graph.Identity.DirectoryManagement
              (Get-MgSubscribedSku). Delegated scopes: DeviceManagementManagedDevices.Read.All, Organization.Read.All.
    Run as: any user with Intune reporting read rights. No admin elevation on the local machine needed.
    Safe: read-only.
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = '.\AdvancedAnalyticsAudit',
    [ValidateRange(1,100)][int]$CapacityThreshold = 60,
    [ValidateRange(1,10000)][int]$RuntimeThresholdMinutes = 180,
    [ValidateRange(1,100)][int]$ResourceScoreThreshold = 50
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-Prop {
    # StrictMode-safe property read from a hashtable (Graph JSON) or PSObject
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null }
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

function Get-GraphAll {
    param([string]$Uri)
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next
        $val = Get-Prop $resp 'value'
        if ($val) { foreach ($v in $val) { $items.Add($v) } }
        $next = Get-Prop $resp '@odata.nextLink'
    }
    return ,$items
}

# ---------- Preflight ----------
foreach ($m in 'Microsoft.Graph.Authentication','Microsoft.Graph.Identity.DirectoryManagement') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Module $m not installed. Install-Module $m -Scope CurrentUser" }
}
if (-not (Get-MgContext)) {
    Write-Status 'Connecting to Microsoft Graph...'
    Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All','Organization.Read.All' -NoWelcome
}
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }
$base = 'https://graph.microsoft.com/beta/deviceManagement'
$summary = New-Object System.Collections.Generic.List[object]

# ---------- 1. Licence ----------
Write-Status 'Checking subscribed SKUs for an Advanced Analytics-like service plan...'
$licRows = @()
try {
    $licRows = @(Get-MgSubscribedSku | ForEach-Object {
        $sku = $_
        $_.ServicePlans | Where-Object { $_.ServicePlanName -match 'AdvancedEA|Advanced_?Analytics|INTUNE_SUITE' } |
            ForEach-Object { [pscustomobject]@{ Sku = $sku.SkuPartNumber; ServicePlan = $_.ServicePlanName; ProvisioningStatus = $_.ProvisioningStatus } }
    })
    if ($licRows.Count -gt 0) {
        $licRows | Export-Csv (Join-Path $OutputFolder 'licence.csv') -NoTypeInformation
        $ok = @($licRows | Where-Object ProvisioningStatus -eq 'Success').Count
        if ($ok -gt 0) { Write-Status "Found $ok provisioned matching service plan(s)." 'OK' }
        else { Write-Status 'Matching plans found but none show ProvisioningStatus=Success.' 'WARN' }
    } else {
        Write-Status 'No service plan matched. Confirm the SKU manually (bundle plan names differ).' 'WARN'
    }
} catch { Write-Status "Licence check failed: $($_.Exception.Message)" 'WARN' }
$summary.Add([pscustomobject]@{ Check='LicencePlansMatched'; Value=$licRows.Count })

# ---------- 2. Anomalies ----------
Write-Status 'Reading anomalies...'
try {
    $anoms = Get-GraphAll "$base/userExperienceAnalyticsAnomaly"
    $rows = foreach ($a in $anoms) {
        [pscustomobject]@{
            AnomalyName   = Get-Prop $a 'anomalyName'
            Type          = Get-Prop $a 'anomalyType'
            Severity      = Get-Prop $a 'severity'
            State         = Get-Prop $a 'state'
            Asset         = Get-Prop $a 'assetName'
            AssetVersion  = Get-Prop $a 'assetVersion'
            FirstSeen     = Get-Prop $a 'anomalyFirstOccurrenceDateTime'
            LastSeen      = Get-Prop $a 'anomalyLatestOccurrenceDateTime'
            DetectionModel= Get-Prop $a 'detectionModelId'
        }
    }
    $rows = @($rows)
    $rows | Export-Csv (Join-Path $OutputFolder 'anomalies.csv') -NoTypeInformation
    $active = @($rows | Where-Object { "$($_.State)" -match 'active|new' })
    $hi = @($active | Where-Object { "$($_.Severity)" -match 'high|medium' })
    Write-Status "Anomalies: $($rows.Count) total, $($active.Count) active, $($hi.Count) active Medium/High." $(if ($hi.Count) {'WARN'} else {'OK'})
    if ($rows.Count -eq 0) { Write-Status 'Zero anomalies is normal for small/quiet fleets (volume-based models).' }
    $summary.Add([pscustomobject]@{ Check='AnomaliesActiveMediumHigh'; Value=$hi.Count })
} catch {
    Write-Status "Anomaly read failed (licence, permission or beta change): $($_.Exception.Message)" 'WARN'
    $summary.Add([pscustomobject]@{ Check='AnomaliesActiveMediumHigh'; Value='error' })
}

# ---------- 3. Battery health ----------
Write-Status 'Reading battery health device performance...'
try {
    $bat = Get-GraphAll "$base/userExperienceAnalyticsBatteryHealthDevicePerformance"
    $rows = foreach ($b in $bat) {
        $cap = Get-Prop $b 'maxCapacityPercentage'
        $rt  = Get-Prop $b 'estimatedRuntimeInMinutes'
        $flags = @()
        if ($null -ne $cap -and [double]$cap -ge 0 -and [double]$cap -lt $CapacityThreshold) { $flags += 'LowCapacity' }
        if ($null -ne $rt  -and [double]$rt  -ge 0 -and [double]$rt  -lt $RuntimeThresholdMinutes) { $flags += 'LowRuntime' }
        if ($flags.Count -eq 1 -and $flags[0] -eq 'LowRuntime' -and $null -ne $cap -and [double]$cap -ge 80) { $flags = @('GoodCapacityPoorRuntime-CheckAppImpact') }
        [pscustomobject]@{
            DeviceName        = Get-Prop $b 'deviceName'
            Model             = Get-Prop $b 'model'
            Manufacturer      = Get-Prop $b 'manufacturer'
            MaxCapacityPct    = $cap
            EstRuntimeMinutes = $rt
            BatteryAgeDays    = Get-Prop $b 'batteryAgeInDays'
            HealthStatus      = Get-Prop $b 'healthStatus'
            Flags             = ($flags -join ';')
        }
    }
    $rows = @($rows)
    $rows | Export-Csv (Join-Path $OutputFolder 'battery-health.csv') -NoTypeInformation
    $flagged = @($rows | Where-Object Flags)
    Write-Status "Battery: $($rows.Count) devices, $($flagged.Count) flagged (<$CapacityThreshold% capacity or <$RuntimeThresholdMinutes min runtime)." $(if ($flagged.Count) {'WARN'} else {'OK'})
    $summary.Add([pscustomobject]@{ Check='BatteryDevicesFlagged'; Value=$flagged.Count })
} catch {
    Write-Status "Battery read failed: $($_.Exception.Message)" 'WARN'
    $summary.Add([pscustomobject]@{ Check='BatteryDevicesFlagged'; Value='error' })
}

# ---------- 4. Resource performance ----------
Write-Status 'Reading resource performance...'
try {
    $res = Get-GraphAll "$base/userExperienceAnalyticsResourcePerformance"
    $rows = foreach ($r in $res) {
        $score = Get-Prop $r 'deviceResourcePerformanceScore'
        [pscustomobject]@{
            DeviceName      = Get-Prop $r 'deviceName'
            Model           = Get-Prop $r 'model'
            Manufacturer    = Get-Prop $r 'manufacturer'
            MachineType     = Get-Prop $r 'machineType'
            ResourceScore   = $score
            CpuSpikePct     = Get-Prop $r 'cpuSpikeTimePercentage'
            RamSpikePct     = Get-Prop $r 'ramSpikeTimePercentage'
            CpuSpikeScore   = Get-Prop $r 'cpuSpikeTimeScore'
            RamSpikeScore   = Get-Prop $r 'ramSpikeTimeScore'
            Flag            = $(if ($null -ne $score -and [double]$score -ge 0 -and [double]$score -lt $ResourceScoreThreshold) { 'BelowThreshold' } else { '' })
        }
    }
    $rows = @($rows)
    $rows | Export-Csv (Join-Path $OutputFolder 'resource-performance.csv') -NoTypeInformation
    $flagged = @($rows | Where-Object Flag)
    Write-Status "Resource performance: $($rows.Count) devices, $($flagged.Count) below score $ResourceScoreThreshold." $(if ($flagged.Count) {'WARN'} else {'OK'})
    $summary.Add([pscustomobject]@{ Check='ResourceDevicesFlagged'; Value=$flagged.Count })
} catch {
    Write-Status "Resource performance read failed (DoD cloud has no resource performance): $($_.Exception.Message)" 'WARN'
    $summary.Add([pscustomobject]@{ Check='ResourceDevicesFlagged'; Value='error' })
}

# ---------- Report ----------
$summary | Export-Csv (Join-Path $OutputFolder 'summary.csv') -NoTypeInformation
$summary | Format-Table -AutoSize
Write-Status "CSV output written to $((Resolve-Path $OutputFolder).Path)" 'OK'
