<#
.SYNOPSIS
    Audits Microsoft Defender for Identity (MDI) sensor health, connectivity, and
    required audit-policy prerequisites across one or more Domain Controllers.

.DESCRIPTION
    Unlike MDE/Defender AV, MDI is a sensor-per-Domain-Controller model — there is no
    single "tenant health" check, so this script targets a list of DCs directly (not
    arbitrary endpoints) and queries each one for:
    - AATPSensor / AATPSensorUpdater service state
    - Outbound HTTPS reachability to the tenant's MDI workspace endpoints
    - Advanced Audit Policy coverage for the subcategories MDI depends on
      (Credential Validation, Logon, Directory Service Access, Directory Service Changes)
    - Recent AATPSensor errors in the Application event log
    - RestrictRemoteSam registry state (a common silent killer of lateral-movement
      detection when the MDI service account isn't in the allow-list)

    If -DomainController is omitted and the ActiveDirectory module is available, the
    script auto-discovers all DCs in the current domain via Get-ADDomainController.

    Exports results to CSV and prints a colour-coded console summary.

    Does NOT cover:
    - MDI portal health alerts (security.microsoft.com → Settings → Identities → Sensors)
      — those are cloud-side and not queryable via local PowerShell; cross-reference
      manually per MDI-B.md Step 3
    - Sensor install/reinstall — read-only diagnostic only
    - NTDS SACL auditing configuration (Fix 6 in MDI-B.md) — flagged, not remediated

.PARAMETER DomainController
    One or more Domain Controller hostnames to check. If omitted, attempts to
    auto-discover all DCs in the current domain via the ActiveDirectory module.

.PARAMETER WorkspaceName
    The MDI workspace name (from the MDI portal), used to build the endpoint
    connectivity test (<WorkspaceName>.atp.azure.com / <WorkspaceName>sensorapi.atp.azure.com).
    If omitted, connectivity testing is skipped and only local sensor/audit checks run.

.PARAMETER DaysBack
    Number of days of AATPSensor Application-log errors to retrieve. Default: 7.

.PARAMETER OutputPath
    Path for the CSV export. Default: C:\Temp\MDI-Status-<timestamp>.csv

.PARAMETER Credential
    Optional PSCredential for remote connections to the DCs.

.EXAMPLE
    .\Get-MDIStatus.ps1 -WorkspaceName "contoso"

.EXAMPLE
    .\Get-MDIStatus.ps1 -DomainController DC01,DC02 -WorkspaceName "contoso" -DaysBack 14

.NOTES
    Requires: Windows Server 2012 R2+ DC with MDI sensor installed; ActiveDirectory
              PowerShell module for auto-discovery (optional — can pass -DomainController instead)
    Run As: Domain admin or delegated rights to query DC services/event logs remotely (WinRM required)
    Safe: Read-only — no service restarts, no audit policy changes, no SACL changes
    Cross-references: Security/Defender/MDI-B.md (Fix 1-6) and MDI-A.md
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$DomainController,

    [string]$WorkspaceName,

    [int]$DaysBack = 7,

    [string]$OutputPath = "C:\Temp\MDI-Status-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

    [PSCredential]$Credential
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

# ─── Resolve target DC list ───
if (-not $DomainController -or $DomainController.Count -eq 0) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $DomainController = (Get-ADDomainController -Filter *).HostName
        Write-Status "No -DomainController specified — auto-discovered $($DomainController.Count) DC(s) via ActiveDirectory module" "INFO"
    } catch {
        Write-Status "No -DomainController specified and ActiveDirectory module unavailable — defaulting to local machine ($env:COMPUTERNAME). This is only correct if the local machine IS a DC running the MDI sensor." "WARN"
        $DomainController = @($env:COMPUTERNAME)
    }
}

function Get-MDISensorStatusLocal {
    param([string]$Computer, [string]$WorkspaceName, [int]$DaysBack)

    $result = [PSCustomObject]@{
        DomainController        = $Computer
        CollectedAt             = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        AATPSensorStatus        = "Unknown"
        AATPSensorStartType     = "Unknown"
        AATPSensorUpdaterStatus = "Unknown"
        WorkspaceEndpointOK     = "Skipped (no -WorkspaceName)"
        SensorApiEndpointOK     = "Skipped (no -WorkspaceName)"
        AuditCredValidation     = "Unknown"
        AuditLogon              = "Unknown"
        AuditDSAccess           = "Unknown"
        AuditDSChanges          = "Unknown"
        RestrictRemoteSamSet    = "Unknown"
        RecentSensorErrors      = 0
        LastSensorError         = "None"
        Errors                  = ""
    }

    try {
        $svc = Get-Service -Name "AATPSensor" -ErrorAction Stop
        $result.AATPSensorStatus    = $svc.Status
        $result.AATPSensorStartType = $svc.StartType
        $result.AATPSensorUpdaterStatus = (Get-Service -Name "AATPSensorUpdater" -ErrorAction SilentlyContinue).Status
    } catch {
        $result.Errors += "AATPSensor service not found — sensor likely not installed on this DC: $($_.Exception.Message); "
    }

    if ($WorkspaceName) {
        try {
            $ws = Test-NetConnection -ComputerName "$WorkspaceName.atp.azure.com" -Port 443 -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction Stop
            $result.WorkspaceEndpointOK = if ($ws) { "Reachable" } else { "UNREACHABLE" }
        } catch {
            $result.WorkspaceEndpointOK = "Test failed: $($_.Exception.Message)"
        }
        try {
            $sa = Test-NetConnection -ComputerName "${WorkspaceName}sensorapi.atp.azure.com" -Port 443 -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction Stop
            $result.SensorApiEndpointOK = if ($sa) { "Reachable" } else { "UNREACHABLE" }
        } catch {
            $result.SensorApiEndpointOK = "Test failed: $($_.Exception.Message)"
        }
    }

    try {
        $auditRaw = auditpol /get /category:* 2>$null
        $findState = {
            param($lines, $pattern)
            $line = $lines | Where-Object { $_ -match $pattern }
            if (-not $line) { return "Not found" }
            if ($line -match 'Success and Failure') { return "Success and Failure" }
            if ($line -match 'Success') { return "Success only" }
            if ($line -match 'Failure') { return "Failure only" }
            if ($line -match 'No Auditing') { return "NO AUDITING" }
            return "Unrecognised: $line"
        }
        $result.AuditCredValidation = & $findState $auditRaw 'Credential Validation'
        $result.AuditLogon          = & $findState $auditRaw '\s+Logon\s'
        $result.AuditDSAccess       = & $findState $auditRaw 'Directory Service Access'
        $result.AuditDSChanges      = & $findState $auditRaw 'Directory Service Changes'
    } catch {
        $result.Errors += "auditpol query failed: $($_.Exception.Message); "
    }

    try {
        $restrictSam = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RestrictRemoteSam" -ErrorAction SilentlyContinue
        $result.RestrictRemoteSamSet = if ($restrictSam) { "Yes — verify MDI service account SID is in the allow-list, or lateral movement detection is blind" } else { "No (default — SAM-R not restricted)" }
    } catch {
        $result.Errors += "RestrictRemoteSam check failed: $($_.Exception.Message); "
    }

    try {
        $cutoff = (Get-Date).AddDays(-$DaysBack)
        $events = Get-WinEvent -FilterHashtable @{
            LogName      = "Application"
            ProviderName = "Azure Advanced Threat Protection Sensor"
            Level        = 2
            StartTime    = $cutoff
        } -ErrorAction SilentlyContinue

        $result.RecentSensorErrors = ($events | Measure-Object).Count
        $latest = $events | Sort-Object TimeCreated -Descending | Select-Object -First 1
        if ($latest) {
            $result.LastSensorError = "$($latest.TimeCreated.ToString('yyyy-MM-dd HH:mm')) — $(($latest.Message -split "`n" | Select-Object -First 1))"
        }
    } catch {
        $result.Errors += "Event log read failed (may mean provider not registered — sensor not installed): $($_.Exception.Message); "
    }

    return $result
}

# ───────────────────────────────────────────────────────────────
# MAIN
# ───────────────────────────────────────────────────────────────

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($dc in $DomainController) {
    Write-Status "Checking MDI sensor status on: $dc" "INFO"

    if ($dc -eq $env:COMPUTERNAME) {
        $res = Get-MDISensorStatusLocal -Computer $dc -WorkspaceName $WorkspaceName -DaysBack $DaysBack
    } else {
        try {
            $invokeParams = @{
                ComputerName = $dc
                ScriptBlock  = ${function:Get-MDISensorStatusLocal}
                ArgumentList = @($dc, $WorkspaceName, $DaysBack)
                ErrorAction  = "Stop"
            }
            if ($Credential) { $invokeParams.Credential = $Credential }

            $res = Invoke-Command @invokeParams
            $res.PSObject.Properties.Remove("PSComputerName")
            $res.PSObject.Properties.Remove("RunspaceId")
        } catch {
            Write-Status "Cannot connect to $dc — $($_.Exception.Message)" "ERROR"
            $res = [PSCustomObject]@{
                DomainController        = $dc
                CollectedAt             = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                AATPSensorStatus        = "N/A"
                AATPSensorStartType     = "N/A"
                AATPSensorUpdaterStatus = "N/A"
                WorkspaceEndpointOK     = "N/A"
                SensorApiEndpointOK     = "N/A"
                AuditCredValidation     = "N/A"
                AuditLogon              = "N/A"
                AuditDSAccess           = "N/A"
                AuditDSChanges          = "N/A"
                RestrictRemoteSamSet    = "N/A"
                RecentSensorErrors      = 0
                LastSensorError         = "N/A"
                Errors                  = "Connection failed: $($_.Exception.Message)"
            }
        }
    }

    $allResults.Add($res)

    $flag = if ($res.AATPSensorStatus -eq "Running") { "OK" } else { "WARN" }
    Write-Status "  AATPSensor: $($res.AATPSensorStatus) | Updater: $($res.AATPSensorUpdaterStatus) | Workspace endpoint: $($res.WorkspaceEndpointOK)" $flag

    if ($res.AuditDSChanges -eq "NO AUDITING" -or $res.AuditDSAccess -eq "NO AUDITING") {
        Write-Status "  Directory Service auditing is OFF — MDI will miss AD object change detections on this DC" "WARN"
    }
    if ($res.RestrictRemoteSamSet -match "^Yes") {
        Write-Status "  RestrictRemoteSam is configured — confirm MDI service account is allow-listed" "WARN"
    }
    if ($res.RecentSensorErrors -gt 0) {
        Write-Status "  AATPSensor errors in last $DaysBack days: $($res.RecentSensorErrors)" "WARN"
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

Write-Host "`n=== MDI Sensor Status Summary ===" -ForegroundColor Cyan
$allResults | Format-Table DomainController, AATPSensorStatus, WorkspaceEndpointOK, AuditDSChanges, RecentSensorErrors -AutoSize
