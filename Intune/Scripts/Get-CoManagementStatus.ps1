<#
.SYNOPSIS
    Device-local co-management diagnostic — pulls ConfigMgr client health, per-workload
    authority (ConfigMgr vs Intune), hybrid join state, and MDM enrollment in one pass,
    with an optional Graph cross-check for duplicate/stale device objects.

.DESCRIPTION
    CoManagement-A.md's Validation Steps and Evidence Pack are a sequence of ~8 separate
    commands an engineer runs by hand (dsregcmd, CCM WMI, CoManagementFlags registry, MDM
    enrollment registry, CCM_CoManagementWorkload WMI). This script consolidates all of
    them into a single structured object per device, so triage starts from one summary
    table instead of re-running each command individually — directly operationalizing
    CoManagement-A.md's Validation Steps 1-6 and CoManagement-B.md's Triage block.

    Specifically collects:
    - Hybrid Entra Join state (dsregcmd /status: AzureAdJoined, DomainJoined, MdmUrl) —
      co-management's non-negotiable prerequisite per both runbooks' Learning Pointers
    - ConfigMgr client service (CcmExec) status and version
    - CoManagementFlags registry bitmask (raw value only — this script does NOT attempt
      to decode individual bit positions into workload names, since that mapping is
      version-dependent and undocumented by Microsoft; use the authoritative
      CCM_CoManagementWorkload WMI class instead, see below)
    - CCM_CoManagementWorkload WMI class — the authoritative, human-readable per-workload
      authority list (WorkloadName + UseIntune), matching CoManagement-A.md's Evidence
      Pack Section 5 and avoiding the temptation to hand-decode CoManagementFlags
    - MDM enrollment registry (ProviderID = "MS DM Server") — EnrollmentType, UPN
    - Recent CoManagementHandler.log entries containing "error" or "fail"

    With -CheckGraphDuplicates, additionally queries Microsoft Graph for all Intune
    device records matching the device name and flags the CoManagement-A.md Phase 4
    scenario (duplicate device objects — one stale, one live) by comparing enrollment
    type and last check-in time across returned records.

    Exports one row per device to CSV and prints a colour-coded console summary flagging
    the specific failure signatures called out in both runbooks' Symptom -> Cause Maps.

    Does NOT cover (portal/console-only, see CoManagement-A.md Phase 2-3):
    - Workload slider position changes (ConfigMgr console only)
    - Pilot collection membership evaluation
    - Actual policy content comparison between ConfigMgr baselines and Intune profiles

.PARAMETER ComputerName
    One or more remote computer names. Defaults to the local machine. Remote collection
    uses Invoke-Command (requires WinRM) — if that's unavailable on a device with
    co-management problems, run locally on the device instead.

.PARAMETER CheckGraphDuplicates
    Switch. Also queries Microsoft Graph for all Intune device records matching each
    computer name and flags duplicate/stale objects (CoManagement-A.md Phase 4).
    Requires Microsoft.Graph.DeviceManagement module and an active or interactive
    Graph connection with DeviceManagementManagedDevices.Read.All.

.PARAMETER LogTailLines
    Number of lines to scan from the end of CoManagementHandler.log for error/fail
    entries. Default: 200.

.PARAMETER Credential
    Optional PSCredential for remote connections.

.PARAMETER OutputPath
    Path for the CSV export. Default: C:\Temp\CoManagementStatus-<timestamp>.csv

.EXAMPLE
    .\Get-CoManagementStatus.ps1

.EXAMPLE
    .\Get-CoManagementStatus.ps1 -ComputerName PC001,PC002 -CheckGraphDuplicates

.NOTES
    Requires: Windows 10/11 with ConfigMgr client; Microsoft.Graph.DeviceManagement
              module only if -CheckGraphDuplicates is used
    Run As: Local admin (WMI root\ccm namespace and registry Enrollments key both need it)
    Safe: Read-only — no workload slider changes, no policy triggers, no enrollment actions
    Cross-references: Intune/Troubleshooting/CoManagement-A.md (Validation Steps, Evidence
                       Pack, Phase 1-4) and CoManagement-B.md (Triage, Fix 1-5)
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [switch]$CheckGraphDuplicates,

    [int]$LogTailLines = 200,

    [PSCredential]$Credential,

    [string]$OutputPath = "C:\Temp\CoManagementStatus-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

function Get-CoManagementStatusLocal {
    param([string]$Computer, [int]$LogTailLines)

    $result = [PSCustomObject]@{
        ComputerName         = $Computer
        CollectedAt          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        AzureAdJoined        = "Unknown"
        DomainJoined         = "Unknown"
        JoinType             = "Unknown"
        MdmUrl               = "Unknown"
        CcmExecStatus        = "Unknown"
        CcmClientVersion     = "Unknown"
        CoManagementFlagsRaw = "Unknown"
        WorkloadSummary      = "Unknown"
        MDMEnrollmentUPN     = "Unknown"
        MDMEnrollmentType    = "Unknown"
        RecentHandlerErrors  = 0
        HandlerLogSample     = ""
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
        $result.AzureAdJoined = Get-DsregValue -Lines $dsreg -FieldName "AzureAdJoined"
        $result.DomainJoined  = Get-DsregValue -Lines $dsreg -FieldName "DomainJoined"
        $result.MdmUrl        = Get-DsregValue -Lines $dsreg -FieldName "MdmUrl"

        $result.JoinType = if ($result.AzureAdJoined -eq "YES" -and $result.DomainJoined -eq "YES") {
            "Hybrid Azure AD Joined (HAADJ) — co-management prerequisite met"
        } elseif ($result.AzureAdJoined -eq "YES") {
            "Azure AD Joined only (AADJ) — co-management supported without on-prem AD"
        } elseif ($result.DomainJoined -eq "YES") {
            "Domain-joined only — NOT registered with Entra — co-management CANNOT enroll"
        } else {
            "Not joined to anything — co-management prerequisite missing"
        }
    } catch {
        $result.Errors += "dsregcmd /status failed: $($_.Exception.Message); "
    }

    try {
        $svc = Get-Service -Name CcmExec -ErrorAction SilentlyContinue
        $result.CcmExecStatus = if ($svc) { $svc.Status } else { "Service not found — ConfigMgr client not installed" }

        $client = Get-CimInstance -Namespace "root\ccm" -ClassName "SMS_Client" -ErrorAction SilentlyContinue
        $result.CcmClientVersion = if ($client) { $client.ClientVersion } else { "Unavailable" }
    } catch {
        $result.Errors += "ConfigMgr client check failed: $($_.Exception.Message); "
    }

    try {
        $flags = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\CCM\CoManagementFlags" -ErrorAction SilentlyContinue
        $result.CoManagementFlagsRaw = if ($null -ne $flags.Flags) { $flags.Flags } else { "Not present (0 / not co-managed)" }
    } catch {
        $result.Errors += "CoManagementFlags read failed: $($_.Exception.Message); "
    }

    try {
        $workloads = Get-CimInstance -Namespace "root\ccm" -ClassName "CCM_CoManagementWorkload" -ErrorAction SilentlyContinue
        if ($workloads) {
            $result.WorkloadSummary = ($workloads | ForEach-Object {
                "$($_.WorkloadName)=$(if ($_.UseIntune) { 'Intune' } else { 'ConfigMgr' })"
            }) -join "; "
        } else {
            $result.WorkloadSummary = "CCM_CoManagementWorkload class not available (client not co-managed or WMI not populated)"
        }
    } catch {
        $result.Errors += "Workload WMI query failed: $($_.Exception.Message); "
    }

    try {
        $enrollments = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { $_.ProviderID -eq "MS DM Server" }
        if ($enrollments) {
            $result.MDMEnrollmentUPN  = ($enrollments.UPN -join "; ")
            $result.MDMEnrollmentType = ($enrollments.EnrollmentType -join "; ")
        } else {
            $result.MDMEnrollmentUPN  = "No MDM enrollment found"
            $result.MDMEnrollmentType = "N/A"
        }
    } catch {
        $result.Errors += "MDM enrollment registry read failed: $($_.Exception.Message); "
    }

    try {
        $logPath = "C:\Windows\CCM\Logs\CoManagementHandler.log"
        if (Test-Path $logPath) {
            $tail = Get-Content $logPath -Tail $LogTailLines -ErrorAction SilentlyContinue
            $hits = $tail | Select-String -Pattern "error|fail" -CaseSensitive:$false
            $result.RecentHandlerErrors = ($hits | Measure-Object).Count
            $result.HandlerLogSample = ($hits | Select-Object -Last 3 | ForEach-Object { $_.Line.Trim() }) -join " | "
        } else {
            $result.HandlerLogSample = "Log not found — client not installed or has never run co-management handler"
        }
    } catch {
        $result.Errors += "CoManagementHandler.log read failed: $($_.Exception.Message); "
    }

    return $result
}

# ───────────────────────────────────────────────────────────────
# MAIN
# ───────────────────────────────────────────────────────────────

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($computer in $ComputerName) {
    Write-Status "Collecting co-management status on: $computer" "INFO"

    if ($computer -eq $env:COMPUTERNAME) {
        $res = Get-CoManagementStatusLocal -Computer $computer -LogTailLines $LogTailLines
    } else {
        try {
            $invokeParams = @{
                ComputerName = $computer
                ScriptBlock  = ${function:Get-CoManagementStatusLocal}
                ArgumentList = @($computer, $LogTailLines)
                ErrorAction  = "Stop"
            }
            if ($Credential) { $invokeParams.Credential = $Credential }

            $res = Invoke-Command @invokeParams
            $res.PSObject.Properties.Remove("PSComputerName")
            $res.PSObject.Properties.Remove("RunspaceId")
        } catch {
            Write-Status "Cannot connect to $computer — $($_.Exception.Message)" "ERROR"
            $res = [PSCustomObject]@{
                ComputerName = $computer; CollectedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                AzureAdJoined = "N/A"; DomainJoined = "N/A"; JoinType = "N/A"; MdmUrl = "N/A"
                CcmExecStatus = "N/A"; CcmClientVersion = "N/A"; CoManagementFlagsRaw = "N/A"
                WorkloadSummary = "N/A"; MDMEnrollmentUPN = "N/A"; MDMEnrollmentType = "N/A"
                RecentHandlerErrors = 0; HandlerLogSample = ""
                Errors = "Connection failed: $($_.Exception.Message)"
            }
        }
    }

    $allResults.Add($res)

    Write-Status "  JoinType: $($res.JoinType)" $(if ($res.JoinType -match "^Hybrid|^Azure AD Joined only") { "OK" } else { "ERROR" })
    Write-Status "  CcmExec: $($res.CcmExecStatus) | Version: $($res.CcmClientVersion)" $(if ($res.CcmExecStatus -eq "Running") { "OK" } else { "WARN" })
    Write-Status "  Workloads: $($res.WorkloadSummary)" "INFO"
    Write-Status "  MDM Enrollment: $($res.MDMEnrollmentUPN) ($($res.MDMEnrollmentType))" $(if ($res.MDMEnrollmentUPN -eq "No MDM enrollment found") { "WARN" } else { "OK" })

    if ($res.CoManagementFlagsRaw -match "^Not present|^0$") {
        Write-Status "  CoManagementFlags = 0/absent — co-management not actually active on this device" "WARN"
    }
    if ($res.RecentHandlerErrors -gt 0) {
        Write-Status "  $($res.RecentHandlerErrors) error/fail entries in recent CoManagementHandler.log — sample: $($res.HandlerLogSample)" "WARN"
    }
    if ($res.Errors) {
        Write-Status "  Collection errors: $($res.Errors)" "ERROR"
    }
}

# ─── Optional: Graph duplicate-device check (CoManagement-A.md Phase 4) ───
if ($CheckGraphDuplicates) {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.DeviceManagement)) {
        Write-Status "Microsoft.Graph.DeviceManagement module not found — skipping duplicate check. Install with:" "ERROR"
        Write-Status "  Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser" "ERROR"
    } else {
        try {
            $context = Get-MgContext -ErrorAction Stop
            if (-not $context) { throw "No active Graph session" }
            Write-Status "Using existing Graph session: $($context.Account)" "OK"
        } catch {
            Write-Status "Connecting to Graph (DeviceManagementManagedDevices.Read.All)..." "INFO"
            Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" -NoWelcome
        }

        Write-Host "`n=== Duplicate Device Check (CoManagement-A.md Phase 4) ===" -ForegroundColor Cyan
        foreach ($computer in $ComputerName) {
            try {
                $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=deviceName eq '$computer'&`$select=deviceName,managementAgent,enrolledDateTime,lastSyncDateTime,id"
                $devices = Invoke-MgGraphRequest -Method GET -Uri $uri | Select-Object -ExpandProperty value

                if (-not $devices -or $devices.Count -eq 0) {
                    Write-Status "$computer — no Intune device records found via Graph" "WARN"
                } elseif ($devices.Count -eq 1) {
                    Write-Status "$computer — single device record (ManagementAgent: $($devices[0].managementAgent)) — no duplication" "OK"
                } else {
                    Write-Status "$computer — $($devices.Count) device records found — POSSIBLE DUPLICATE (Phase 4)" "ERROR"
                    $devices | Sort-Object lastSyncDateTime -Descending |
                        Format-Table deviceName, managementAgent, enrolledDateTime, lastSyncDateTime, id -AutoSize
                    Write-Host "  Keep the record with ManagementAgent=configurationManagerClientMdm and the most recent lastSyncDateTime;" -ForegroundColor DarkGray
                    Write-Host "  delete the stale one per CoManagement-A.md Phase 4 step 4." -ForegroundColor DarkGray
                }
            } catch {
                Write-Status "$computer — Graph duplicate check failed: $($_.Exception.Message)" "ERROR"
            }
        }
    }
}

# ─── Export ───
$outputDir = Split-Path $OutputPath
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Results exported to: $OutputPath" "OK"

Write-Host "`n=== Co-Management Status Summary ===" -ForegroundColor Cyan
$allResults | Format-Table ComputerName, JoinType, CcmExecStatus, MDMEnrollmentUPN, RecentHandlerErrors -AutoSize

Write-Host "`nNote: Workload slider position changes and pilot collection membership are" -ForegroundColor DarkGray
Write-Host "ConfigMgr-console-only — see CoManagement-A.md Phase 2 / Playbook 2 for those steps." -ForegroundColor DarkGray
