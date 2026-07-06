<#
.SYNOPSIS
    Collects the full Intune enrollment diagnostic picture from one or more devices —
    join state, MDM enrollment URL, enrollment scheduled task status, MDM endpoint
    connectivity, and recent enrollment error events.

.DESCRIPTION
    Enrollment/App-Deployment-B.md's Fix Paths assume the engineer already knows which
    of ~6 possible break points is at fault (licensing, MDM scope, restrictions, stale
    record, network, HAADJ timing). This script collects the endpoint-visible evidence
    for all of them in one pass so triage starts from data instead of guesswork:
    - dsregcmd /status, parsed into structured fields (AzureAdJoined, DomainJoined,
      EnterpriseJoined, AzureAdPrt, MDM enrollment/management URLs)
    - Presence and last-run result of the enrollment scheduled task
      ("Schedule #1 created by enrollment client")
    - Reachability to manage.microsoft.com and dm.microsoft.com over 443
    - Recent errors/warnings from the DeviceManagement-Enterprise-Diagnostic-Provider
      Admin event log (the most detailed enrollment error source)
    - Whether the device is domain-joined vs Entra-joined vs hybrid (HAADJ), since the
      correct fix path depends entirely on this

    Exports results to CSV and prints a colour-coded console summary.

    Does NOT cover (all require Graph/portal access — do separately, see Enrollment-B.md):
    - User licensing (Get-MgUserLicenseDetail)
    - MDM/MAM user scope configuration (portal only)
    - Enrollment restrictions configuration (portal only)
    - Stale/duplicate Intune device records (Get-MgDeviceManagementManagedDevice)
    - Generating the full MDMDiagnosticsTool zip for a Microsoft support case — run
      `mdmdiagnosticstool.exe -area DeviceEnrollment;DeviceProvisioning -zip <path>`
      separately if this script's findings don't explain the failure

.PARAMETER ComputerName
    One or more remote computer names. Defaults to the local machine if omitted.
    Note: dsregcmd and the enrollment scheduled task can only be read locally on the
    affected device — this script uses Invoke-Command for remote targets, which
    requires WinRM to be reachable (itself sometimes broken on devices with enrollment
    problems). If remote collection fails, run locally on the device instead.

.PARAMETER DaysBack
    Number of days of enrollment diagnostic event history to scan. Default: 3.

.PARAMETER OutputPath
    Path for the CSV export. Default: C:\Temp\EnrollmentDiagnostics-<timestamp>.csv

.PARAMETER Credential
    Optional PSCredential for remote connections.

.PARAMETER SkipConnectivityTest
    Skip the Test-NetConnection calls to MDM endpoints.

.EXAMPLE
    .\Get-EnrollmentDiagnostics.ps1

.EXAMPLE
    .\Get-EnrollmentDiagnostics.ps1 -ComputerName PC001,PC002 -DaysBack 7

.NOTES
    Requires: Windows 10/11, run locally on the affected device where possible
    Run As: Local admin (dsregcmd and the enrollment scheduled task both need it for
            full detail)
    Safe: Read-only — no enrollment actions taken, no Start-ScheduledTask calls made
    Cross-references: Intune/Troubleshooting/Enrollment-B.md (Fix 1-6) and Enrollment-A.md
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [int]$DaysBack = 3,

    [string]$OutputPath = "C:\Temp\EnrollmentDiagnostics-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

    [PSCredential]$Credential,

    [switch]$SkipConnectivityTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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

function Get-EnrollmentDiagnosticsLocal {
    param([string]$Computer, [bool]$SkipConnectivityTest, [int]$DaysBack)

    $result = [PSCustomObject]@{
        ComputerName         = $Computer
        CollectedAt          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        AzureAdJoined        = "Unknown"
        DomainJoined         = "Unknown"
        EnterpriseJoined     = "Unknown"
        AzureAdPrt           = "Unknown"
        MDMEnrollmentURL     = "Unknown"
        MDMUrl               = "Unknown"
        JoinType             = "Unknown"
        EnrollmentTaskExists = "Unknown"
        EnrollmentTaskState  = "Unknown"
        Endpoint_manage      = "Skipped"
        Endpoint_dm          = "Skipped"
        RecentEnrollErrors   = 0
        RecentEnrollWarnings = 0
        Errors               = ""
    }

    try {
        $dsreg = dsregcmd /status 2>$null

        function Get-DsregValue {
            param($Lines, $FieldName)
            $line = $Lines | Where-Object { $_ -match "^\s*$FieldName\s*:" } | Select-Object -First 1
            if ($line) { return ($line -split ':', 2)[1].Trim() }
            return "Not found"
        }

        $result.AzureAdJoined    = Get-DsregValue -Lines $dsreg -FieldName "AzureAdJoined"
        $result.DomainJoined     = Get-DsregValue -Lines $dsreg -FieldName "DomainJoined"
        $result.EnterpriseJoined = Get-DsregValue -Lines $dsreg -FieldName "EnterpriseJoined"
        $result.AzureAdPrt       = Get-DsregValue -Lines $dsreg -FieldName "AzureAdPrt"
        $result.MDMEnrollmentURL = Get-DsregValue -Lines $dsreg -FieldName "MDMEnrollmentUrl"
        $result.MDMUrl           = Get-DsregValue -Lines $dsreg -FieldName "MdmUrl"

        $result.JoinType = if ($result.AzureAdJoined -eq "YES" -and $result.DomainJoined -eq "YES") {
            "Hybrid Azure AD Joined (HAADJ)"
        } elseif ($result.AzureAdJoined -eq "YES") {
            "Entra (Azure AD) Joined only"
        } elseif ($result.DomainJoined -eq "YES") {
            "On-prem domain joined only — not registered with Entra"
        } else {
            "Not joined to anything — cannot enroll in Intune"
        }
    } catch {
        $result.Errors += "dsregcmd /status failed or unavailable: $($_.Exception.Message); "
    }

    try {
        $taskPath = "\Microsoft\Windows\EnterpriseMgmt\"
        $task = Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -like "Schedule #1*" } | Select-Object -First 1
        if ($task) {
            $result.EnrollmentTaskExists = "Yes"
            $result.EnrollmentTaskState  = $task.State
        } else {
            $result.EnrollmentTaskExists = "No — device likely never completed enrollment scheduling"
        }
    } catch {
        $result.Errors += "Enrollment scheduled task check failed: $($_.Exception.Message); "
    }

    if (-not $SkipConnectivityTest) {
        $endpointMap = @{
            Endpoint_manage = 'manage.microsoft.com'
            Endpoint_dm     = 'dm.microsoft.com'
        }
        foreach ($prop in $endpointMap.Keys) {
            try {
                $test = Test-NetConnection -ComputerName $endpointMap[$prop] -Port 443 -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction Stop
                $result.$prop = if ($test) { "Reachable" } else { "UNREACHABLE" }
            } catch {
                $result.$prop = "Test failed: $($_.Exception.Message)"
            }
        }
    }

    try {
        $cutoff = (Get-Date).AddDays(-$DaysBack)
        $events = Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -ge $cutoff }
        $result.RecentEnrollErrors   = ($events | Where-Object LevelDisplayName -eq 'Error' | Measure-Object).Count
        $result.RecentEnrollWarnings = ($events | Where-Object LevelDisplayName -eq 'Warning' | Measure-Object).Count
    } catch {
        $result.Errors += "Enrollment event log read failed: $($_.Exception.Message); "
    }

    return $result
}

# ───────────────────────────────────────────────────────────────
# MAIN
# ───────────────────────────────────────────────────────────────

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($computer in $ComputerName) {
    Write-Status "Collecting enrollment diagnostics on: $computer" "INFO"

    if ($computer -eq $env:COMPUTERNAME) {
        $res = Get-EnrollmentDiagnosticsLocal -Computer $computer -SkipConnectivityTest $SkipConnectivityTest.IsPresent -DaysBack $DaysBack
    } else {
        try {
            $invokeParams = @{
                ComputerName = $computer
                ScriptBlock  = ${function:Get-EnrollmentDiagnosticsLocal}
                ArgumentList = @($computer, $SkipConnectivityTest.IsPresent, $DaysBack)
                ErrorAction  = "Stop"
            }
            if ($Credential) { $invokeParams.Credential = $Credential }

            $res = Invoke-Command @invokeParams
            $res.PSObject.Properties.Remove("PSComputerName")
            $res.PSObject.Properties.Remove("RunspaceId")
        } catch {
            Write-Status "Cannot connect to $computer — $($_.Exception.Message)" "ERROR"
            $res = [PSCustomObject]@{
                ComputerName         = $computer
                CollectedAt          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                AzureAdJoined        = "N/A"
                DomainJoined         = "N/A"
                EnterpriseJoined     = "N/A"
                AzureAdPrt           = "N/A"
                MDMEnrollmentURL     = "N/A"
                MDMUrl               = "N/A"
                JoinType             = "N/A"
                EnrollmentTaskExists = "N/A"
                EnrollmentTaskState  = "N/A"
                Endpoint_manage      = "N/A"
                Endpoint_dm          = "N/A"
                RecentEnrollErrors   = 0
                RecentEnrollWarnings = 0
                Errors               = "Connection failed: $($_.Exception.Message)"
            }
        }
    }

    $allResults.Add($res)

    Write-Status "  JoinType: $($res.JoinType)" "INFO"
    Write-Status "  AzureAdPrt: $($res.AzureAdPrt) | MDMEnrollmentURL: $($res.MDMEnrollmentURL)" $(if ($res.AzureAdPrt -eq "YES") { "OK" } else { "WARN" })

    if ($res.MDMEnrollmentURL -notmatch "manage\.microsoft\.com" -and $res.MDMEnrollmentURL -ne "Unknown") {
        Write-Status "  MDM enrollment URL missing or not pointing to Intune — check MDM user scope" "WARN"
    }
    if ($res.EnrollmentTaskExists -match "^No") {
        Write-Status "  Enrollment scheduled task not found — enrollment never completed scheduling" "WARN"
    }
    if ($res.RecentEnrollErrors -gt 0) {
        Write-Status "  Recent enrollment errors in event log: $($res.RecentEnrollErrors)" "WARN"
    }
    if ($res.Errors) {
        Write-Status "  Errors: $($res.Errors)" "ERROR"
    }
}

# ─── Export ───
$outputDir = Split-Path $OutputPath
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Results exported to: $OutputPath" "OK"

Write-Host "`n=== Enrollment Diagnostics Summary ===" -ForegroundColor Cyan
$allResults | Format-Table ComputerName, JoinType, AzureAdPrt, MDMEnrollmentURL, EnrollmentTaskExists, RecentEnrollErrors -AutoSize

Write-Host "`nNote: Licensing, MDM/MAM scope, enrollment restrictions, and stale device records" -ForegroundColor DarkGray
Write-Host "are portal/Graph-only checks — see Enrollment-B.md Fix 1-3 for those." -ForegroundColor DarkGray
