<#
.SYNOPSIS
    Collects the full Win32 app deployment diagnostic picture from a Windows device —
    IME service/process health, IME + AgentExecutor log error extraction, Delivery
    Optimization download status, detection-rule-relevant installed-app inventory, and
    disk free space.

.DESCRIPTION
    App-Deployment-A.md's Symptom → Cause Map lists ~10 distinct failure signatures
    (stuck pending, install failed, reinstall loop, access denied, content download
    timeout, etc.) that all trace back to a handful of the same underlying checks. This
    script collects the endpoint-visible evidence for all of them in one pass so triage
    starts from data instead of re-running the same six commands by hand every ticket:

    - IntuneManagementExtension (IME) service state and process uptime
    - IME scheduled task state and last run time (\Microsoft\Intune\)
    - IntuneManagementExtension.log tail, filtered for error/fail/0x8 patterns
      (the primary Win32 processing log)
    - AgentExecutor.log tail, filtered for exitcode/returncode/fail patterns
      (the primary Win32 install/detection log)
    - Delivery Optimization transfer status (peer vs CDN byte split, stalled transfers)
    - Installed-app registry inventory (both native and WOW6432Node uninstall keys),
      optionally filtered by name — the same data source most file/registry/MSI
      detection rules key off, per App-Deployment-A.md Validation Step 6
    - Free disk space on the system drive (the most common Requirements-rule failure)

    Exports a structured summary to CSV and prints a colour-coded console readout
    flagging the specific conditions App-Deployment-B.md/​-A.md call out as most likely
    causes (IME not running, task never scheduled, recent log errors, low disk space).

    Does NOT cover (all require Graph/portal access — do separately, see
    App-Deployment-B.md Fix Paths):
    - App assignment configuration (Required vs Available, group targeting)
    - Detection/requirements rule definitions as configured in the portal
    - App publishing state (Get-MgDeviceAppManagementMobileApp)
    - Supersedence/dependency chain configuration

.PARAMETER ComputerName
    One or more remote computer names. Defaults to the local machine if omitted.
    Note: IME logs and Delivery Optimization state can only be read locally on the
    affected device — this script uses Invoke-Command for remote targets, which
    requires WinRM to be reachable. If remote collection fails, run locally instead.

.PARAMETER AppNameFilter
    Wildcard filter applied to the installed-app inventory (e.g. "*Adobe*"). Default
    is "*" (all installed apps). Narrowing this makes the CSV far more readable when
    triaging a specific app's detection rule.

.PARAMETER LogTailLines
    Number of lines to read from the tail of each IME/AgentExecutor log before
    filtering. Default: 500.

.PARAMETER OutputPath
    Path for the CSV export. Default: C:\Temp\AppDeploymentDiagnostics-<timestamp>.csv

.PARAMETER Credential
    Optional PSCredential for remote connections.

.EXAMPLE
    .\Get-AppDeploymentDiagnostics.ps1

.EXAMPLE
    .\Get-AppDeploymentDiagnostics.ps1 -ComputerName PC001,PC002 -AppNameFilter "*Adobe*"

.NOTES
    Requires: Windows 10/11, run locally on the affected device where possible
    Run As: Local admin (IME logs and DO status both need it for full detail)
    Safe: Read-only — no service restarts, no uninstalls, no registry writes
    Cross-references: Intune/Troubleshooting/App-Deployment-B.md (Fix 1-5) and
                       App-Deployment-A.md (Symptom → Cause Map, Validation Steps)
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [string]$AppNameFilter = "*",

    [int]$LogTailLines = 500,

    [string]$OutputPath = "C:\Temp\AppDeploymentDiagnostics-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

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

function Get-AppDeploymentDiagnosticsLocal {
    param([string]$Computer, [string]$AppNameFilter, [int]$LogTailLines)

    $result = [PSCustomObject]@{
        ComputerName          = $Computer
        CollectedAt           = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        IMEServiceStatus      = "Unknown"
        IMEProcessRunning     = "Unknown"
        IMETaskState          = "Unknown"
        IMETaskLastRun        = "Unknown"
        IMELogErrorCount      = 0
        AgentExecutorErrCount = 0
        DOTransferCount       = 0
        DOStalledCount        = 0
        FreeDiskMB            = "Unknown"
        MatchedInstalledApps  = 0
        Errors                = ""
    }

    try {
        $svc = Get-Service -Name "IntuneManagementExtension" -ErrorAction Stop
        $result.IMEServiceStatus = $svc.Status
    } catch {
        $result.IMEServiceStatus = "Not found"
        $result.Errors += "IME service not found; "
    }

    try {
        $proc = Get-Process -Name "IntuneManagementExtension" -ErrorAction SilentlyContinue
        $result.IMEProcessRunning = if ($proc) { "Yes (PID $($proc.Id), started $($proc.StartTime))" } else { "No" }
    } catch {
        $result.Errors += "Process check failed: $($_.Exception.Message); "
    }

    try {
        $task = Get-ScheduledTask -TaskPath "\Microsoft\Intune\" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($task) {
            $result.IMETaskState   = $task.State
            $info                  = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            $result.IMETaskLastRun = if ($info) { $info.LastRunTime } else { "Unknown" }
        } else {
            $result.IMETaskState = "Not found"
        }
    } catch {
        $result.Errors += "IME task check failed: $($_.Exception.Message); "
    }

    $imeLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
    try {
        if (Test-Path $imeLog) {
            $lines = Get-Content $imeLog -Tail $LogTailLines -ErrorAction SilentlyContinue
            $result.IMELogErrorCount = ($lines | Select-String -Pattern "error|fail|0x8" -CaseSensitive:$false | Measure-Object).Count
        } else {
            $result.Errors += "IME log not found at expected path; "
        }
    } catch {
        $result.Errors += "IME log read failed: $($_.Exception.Message); "
    }

    $agentLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log"
    try {
        if (Test-Path $agentLog) {
            $lines = Get-Content $agentLog -Tail $LogTailLines -ErrorAction SilentlyContinue
            $result.AgentExecutorErrCount = ($lines | Select-String -Pattern "error|exitcode|returncode|fail" -CaseSensitive:$false | Measure-Object).Count
        } else {
            $result.Errors += "AgentExecutor log not found (no Win32 app has run on this device yet, or IME never installed); "
        }
    } catch {
        $result.Errors += "AgentExecutor log read failed: $($_.Exception.Message); "
    }

    try {
        $doStatus = Get-DeliveryOptimizationStatus -ErrorAction SilentlyContinue
        if ($doStatus) {
            $result.DOTransferCount = ($doStatus | Measure-Object).Count
            $result.DOStalledCount  = ($doStatus | Where-Object { $_.Status -eq 'Stalled' -or $_.Status -eq 'Paused' } | Measure-Object).Count
        }
    } catch {
        $result.Errors += "Delivery Optimization status unavailable: $($_.Exception.Message); "
    }

    try {
        $drive = Get-PSDrive -Name C -ErrorAction Stop
        $result.FreeDiskMB = [math]::Round($drive.Free / 1MB, 0)
    } catch {
        $result.Errors += "Disk space check failed: $($_.Exception.Message); "
    }

    try {
        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\"
        )
        $apps = foreach ($p in $paths) {
            if (Test-Path $p) {
                Get-ChildItem $p -ErrorAction SilentlyContinue | Get-ItemProperty -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like $AppNameFilter }
            }
        }
        $result.MatchedInstalledApps = ($apps | Measure-Object).Count
    } catch {
        $result.Errors += "Installed-app inventory read failed: $($_.Exception.Message); "
    }

    return $result
}

# ───────────────────────────────────────────────────────────────
# MAIN
# ───────────────────────────────────────────────────────────────

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($computer in $ComputerName) {
    Write-Status "Collecting app deployment diagnostics on: $computer" "INFO"

    if ($computer -eq $env:COMPUTERNAME) {
        $res = Get-AppDeploymentDiagnosticsLocal -Computer $computer -AppNameFilter $AppNameFilter -LogTailLines $LogTailLines
    } else {
        try {
            $invokeParams = @{
                ComputerName = $computer
                ScriptBlock  = ${function:Get-AppDeploymentDiagnosticsLocal}
                ArgumentList = @($computer, $AppNameFilter, $LogTailLines)
                ErrorAction  = "Stop"
            }
            if ($Credential) { $invokeParams.Credential = $Credential }

            $res = Invoke-Command @invokeParams
            $res.PSObject.Properties.Remove("PSComputerName")
            $res.PSObject.Properties.Remove("RunspaceId")
        } catch {
            Write-Status "Cannot connect to $computer — $($_.Exception.Message)" "ERROR"
            $res = [PSCustomObject]@{
                ComputerName          = $computer
                CollectedAt           = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                IMEServiceStatus      = "N/A"
                IMEProcessRunning     = "N/A"
                IMETaskState          = "N/A"
                IMETaskLastRun        = "N/A"
                IMELogErrorCount      = 0
                AgentExecutorErrCount = 0
                DOTransferCount       = 0
                DOStalledCount        = 0
                FreeDiskMB            = "N/A"
                MatchedInstalledApps  = 0
                Errors                = "Connection failed: $($_.Exception.Message)"
            }
        }
    }

    $allResults.Add($res)

    Write-Status "  IME service: $($res.IMEServiceStatus) | Process running: $($res.IMEProcessRunning)" $(if ($res.IMEServiceStatus -eq "Running") { "OK" } else { "ERROR" })
    Write-Status "  IME log errors (last $LogTailLines lines): $($res.IMELogErrorCount) | AgentExecutor errors: $($res.AgentExecutorErrCount)" $(if ($res.IMELogErrorCount -gt 0 -or $res.AgentExecutorErrCount -gt 0) { "WARN" } else { "OK" })

    if ($res.FreeDiskMB -ne "Unknown" -and $res.FreeDiskMB -ne "N/A" -and [int]$res.FreeDiskMB -lt 2048) {
        Write-Status "  Free disk space low: $($res.FreeDiskMB) MB — check Requirements rule failures" "WARN"
    }
    if ($res.DOStalledCount -gt 0) {
        Write-Status "  $($res.DOStalledCount) stalled/paused Delivery Optimization transfer(s) — check CDN reachability" "WARN"
    }
    if ($res.IMETaskState -eq "Not found") {
        Write-Status "  IME scheduled task not found — IME may never have completed install" "WARN"
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

Write-Host "`n=== App Deployment Diagnostics Summary ===" -ForegroundColor Cyan
$allResults | Format-Table ComputerName, IMEServiceStatus, IMELogErrorCount, AgentExecutorErrCount, FreeDiskMB, MatchedInstalledApps -AutoSize

Write-Host "`nNote: App assignment, detection/requirements rule definitions, and publishing state" -ForegroundColor DarkGray
Write-Host "are portal/Graph-only checks — see App-Deployment-B.md Fix 1-5 for those." -ForegroundColor DarkGray
