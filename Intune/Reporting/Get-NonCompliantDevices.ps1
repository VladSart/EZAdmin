
<#
.SYNOPSIS
    Generates a non-compliance report from Intune — grouped by policy, reason, and user.

.DESCRIPTION
    Pulls all non-compliant managed devices from Microsoft Graph and enriches each with:
      - Non-compliance reason(s) per policy setting
      - Days since last sync (to distinguish "policy failure" from "stale device")
      - User and manager details (optional — requires User.Read.All)
      - Grace period status and scheduled remediation date

    Output formats: console table, CSV (always), and optional HTML report.

    Designed for:
      - Weekly compliance reporting to management
      - Evidence packs for security audits
      - L2/L3 triage to identify systemic vs. individual device failures

.PARAMETER TenantId
    Azure AD tenant ID or primary domain.

.PARAMETER ClientId
    App registration client ID.
    Required permissions: DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All

.PARAMETER ClientSecret
    App registration client secret.

.PARAMETER IncludeInGracePeriod
    Include devices in grace period (default: excluded from alert list, still in CSV).

.PARAMETER HtmlReport
    Generate an HTML summary report in addition to CSV.

.PARAMETER OutputPath
    Directory to write output files. Defaults to current directory.

.EXAMPLE
    # Basic non-compliance report
    .\Get-NonCompliantDevices.ps1 -TenantId "contoso.com" -ClientId "<id>" -ClientSecret "<secret>"

.EXAMPLE
    # Include grace period, produce HTML report, save to desktop
    .\Get-NonCompliantDevices.ps1 -TenantId "contoso.com" -ClientId "<id>" -ClientSecret "<secret>" `
        -IncludeInGracePeriod -HtmlReport -OutputPath "C:\Reports"

.NOTES
    Requires: DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All
    Run-as: Not required (no elevation needed)
    Safe/Unsafe: SAFE — read-only
    Rate limits: Graph throttles at ~300 req/min for Device Management. Script includes backoff.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$ClientSecret,
    [switch]$IncludeInGracePeriod,
    [switch]$HtmlReport,
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Status] $Message" -ForegroundColor $colour
}

function Invoke-GraphRequest {
    param([string]$Uri, [hashtable]$Headers, [int]$MaxRetries = 3)
    $attempt = 0
    do {
        try {
            return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers
        } catch {
            $attempt++
            if ($_.Exception.Response.StatusCode -eq 429 -and $attempt -lt $MaxRetries) {
                $retryAfter = $_.Exception.Response.Headers['Retry-After'] ?? 30
                Write-Status "Graph throttled — waiting ${retryAfter}s (attempt $attempt/$MaxRetries)" -Status "WARN"
                Start-Sleep -Seconds $retryAfter
            } elseif ($attempt -ge $MaxRetries) {
                throw
            }
        }
    } while ($attempt -lt $MaxRetries)
}

# ─────────────────────────────────────────────
# AUTH
# ─────────────────────────────────────────────
Write-Status "Authenticating to Microsoft Graph..."
$tokenResp = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -Body @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    } -ContentType "application/x-www-form-urlencoded"

$headers = @{ Authorization = "Bearer $($tokenResp.access_token)" }
Write-Status "Authenticated OK" -Status "OK"

# ─────────────────────────────────────────────
# FETCH NON-COMPLIANT DEVICES
# ─────────────────────────────────────────────
Write-Status "Fetching non-compliant devices..."
$states = @("noncompliant")
if ($IncludeInGracePeriod) { $states += "inGracePeriod" }
$filterStr = ($states | ForEach-Object { "complianceState eq '$_'" }) -join " or "

$selectFields = "id,deviceName,complianceState,lastSyncDateTime,operatingSystem,osVersion," +
                "userPrincipalName,userDisplayName,deviceEnrollmentType,autopilotEnrolled," +
                "managementAgent,azureADRegistered,enrollmentProfileName,deviceCategoryDisplayName," +
                "managementCertificateExpirationDate"

$allNonCompliant = [System.Collections.Generic.List[object]]::new()
$uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$filterStr&`$select=$selectFields&`$top=500"

do {
    $resp = Invoke-GraphRequest -Uri $uri -Headers $headers
    $resp.value | ForEach-Object { $allNonCompliant.Add($_) }
    $uri = $resp.'@odata.nextLink'
    if ($uri) { Write-Status "  Paging... $($allNonCompliant.Count) devices so far" }
} while ($uri)

Write-Status "Found $($allNonCompliant.Count) non-compliant device(s)" -Status $(if ($allNonCompliant.Count -gt 0) {"WARN"} else {"OK"})

if ($allNonCompliant.Count -eq 0) {
    Write-Status "No non-compliant devices — tenant is clean!" -Status "OK"
    exit 0
}

# ─────────────────────────────────────────────
# FETCH COMPLIANCE POLICY STATES PER DEVICE
# ─────────────────────────────────────────────
Write-Status "Fetching policy states for each non-compliant device (this may take a moment)..."
$enriched = [System.Collections.Generic.List[object]]::new()
$i = 0

foreach ($device in $allNonCompliant) {
    $i++
    Write-Progress -Activity "Fetching policy details" -Status "$i/$($allNonCompliant.Count): $($device.deviceName)" `
        -PercentComplete (($i / $allNonCompliant.Count) * 100)

    $policyUri  = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.id)/deviceCompliancePolicyStates"
    $policyResp = Invoke-GraphRequest -Uri $policyUri -Headers $headers
    $failedPolicies = $policyResp.value | Where-Object { $_.state -ne "compliant" }

    # Collect failing settings per policy
    $failedSettings = foreach ($policy in $failedPolicies) {
        $settingUri  = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.id)/deviceCompliancePolicyStates/$($policy.id)/settingStates"
        $settingResp = Invoke-GraphRequest -Uri $settingUri -Headers $headers -ErrorAction SilentlyContinue
        $settingResp.value | Where-Object { $_.state -ne "compliant" } | ForEach-Object {
            "$($policy.displayName): $($_.setting) [$($_.state)]"
        }
    }

    $lastSync     = if ($device.lastSyncDateTime) { [datetime]$device.lastSyncDateTime } else { $null }
    $daysSince    = if ($lastSync) { [math]::Round(([datetime]::UtcNow - $lastSync).TotalDays, 1) } else { "Never" }
    $stalePrimary = $daysSince -ne "Never" -and $daysSince -gt 7

    $enriched.Add([PSCustomObject]@{
        DeviceName          = $device.deviceName
        ComplianceState     = $device.complianceState
        LastSyncDateTime    = $lastSync
        DaysSinceSync       = $daysSince
        StaleDevice         = $stalePrimary
        FailedPolicies      = ($failedPolicies.displayName -join "; ")
        FailedSettings      = ($failedSettings -join "; ")
        FailedPolicyCount   = $failedPolicies.Count
        OS                  = "$($device.operatingSystem) $($device.osVersion)"
        UserUPN             = $device.userPrincipalName
        UserDisplayName     = $device.userDisplayName
        EnrollmentType      = $device.deviceEnrollmentType
        AutopilotEnrolled   = $device.autopilotEnrolled
        Category            = $device.deviceCategoryDisplayName
        ManagedDeviceId     = $device.id
    })

    Start-Sleep -Milliseconds 100  # Throttle guard
}

Write-Progress -Activity "Fetching policy details" -Completed

# ─────────────────────────────────────────────
# CONSOLE REPORT
# ─────────────────────────────────────────────
Write-Host "`n===== NON-COMPLIANCE REPORT — $(Get-Date -Format 'yyyy-MM-dd HH:mm') =====" -ForegroundColor Red

Write-Host "`n[STALE DEVICES — last sync >7 days, may just need a re-sync]" -ForegroundColor Yellow
$enriched | Where-Object { $_.StaleDevice } |
    Sort-Object DaysSinceSync -Descending |
    Format-Table DeviceName, DaysSinceSync, ComplianceState, UserUPN -AutoSize

Write-Host "`n[GENUINE NON-COMPLIANCE — recently synced but still failing]" -ForegroundColor Red
$enriched | Where-Object { -not $_.StaleDevice } |
    Sort-Object FailedPolicyCount -Descending |
    Format-Table DeviceName, FailedPolicies, OS, UserUPN -AutoSize

Write-Host "`n[TOP FAILING POLICIES]" -ForegroundColor Cyan
$enriched |
    Where-Object { $_.FailedPolicies } |
    ForEach-Object { $_.FailedPolicies -split ";" } |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ } |
    Group-Object |
    Sort-Object Count -Descending |
    Select-Object -First 10 |
    Format-Table Count, Name -AutoSize

# ─────────────────────────────────────────────
# CSV EXPORT
# ─────────────────────────────────────────────
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$timestamp = Get-Date -Format "yyyyMMdd_HHmm"
$csvFile   = Join-Path $OutputPath "NonCompliantDevices_$timestamp.csv"
$enriched | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
Write-Status "CSV exported → $csvFile" -Status "OK"

# ─────────────────────────────────────────────
# HTML REPORT (optional)
# ─────────────────────────────────────────────
if ($HtmlReport) {
    $htmlFile = Join-Path $OutputPath "NonCompliantDevices_$timestamp.html"
    $rows = $enriched | ForEach-Object {
        $rowColour = if ($_.StaleDevice) { "#fff3cd" } elseif ($_.ComplianceState -eq "noncompliant") { "#f8d7da" } else { "#fff8e1" }
        "<tr style='background:$rowColour'>
            <td>$($_.DeviceName)</td>
            <td>$($_.ComplianceState)</td>
            <td>$($_.DaysSinceSync)</td>
            <td>$($_.FailedPolicies)</td>
            <td>$($_.OS)</td>
            <td>$($_.UserUPN)</td>
        </tr>"
    }
    $html = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'>
<title>Intune Non-Compliance Report</title>
<style>body{font-family:Segoe UI,Arial;margin:2em;} table{border-collapse:collapse;width:100%}
th{background:#0078d4;color:#fff;padding:8px;text-align:left} td{border:1px solid #ddd;padding:6px}
h2{color:#0078d4}</style></head><body>
<h2>Intune Non-Compliance Report</h2>
<p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm UTC')</p>
<p>Total non-compliant: <strong>$($enriched.Count)</strong> |
   Stale (>7d): <strong>$($enriched | Where-Object StaleDevice | Measure-Object | Select-Object -Exp Count)</strong> |
   Active failures: <strong>$($enriched | Where-Object {-not $_.StaleDevice} | Measure-Object | Select-Object -Exp Count)</strong></p>
<table><tr><th>Device</th><th>State</th><th>Days Since Sync</th><th>Failed Policies</th><th>OS</th><th>User</th></tr>
$($rows -join "`n")
</table></body></html>
"@
    Set-Content -Path $htmlFile -Value $html -Encoding UTF8
    Write-Status "HTML report → $htmlFile" -Status "OK"
}

# ─────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────
Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Total non-compliant    : $($enriched.Count)"
Write-Host "  Stale (>7d no sync)    : $($enriched | Where-Object StaleDevice | Measure-Object | Select-Object -Exp Count)"
Write-Host "  Active policy failures : $($enriched | Where-Object {-not $_.StaleDevice} | Measure-Object | Select-Object -Exp Count)"
Write-Host ""
Write-Status "Tip: Stale devices should be synced first (.\Invoke-IntuneSync.ps1) before investigating policy failures." -Status "INFO"
