<#
.SYNOPSIS
    Audits WSUS server role health — core services, IIS WsusPool state,
    content/metadata consistency, content-volume disk space, and recent
    WSUS-specific errors.

.DESCRIPTION
    Read-only diagnostic script for the "WSUS-Server-A.md"/"WSUS-Server-B.md"
    runbooks. Run on the WSUS server itself with local Administrator rights.

    Covers:
      1. WsusService and W3SVC (IIS) service state
      2. WsusPool application pool state and recycling configuration
         (memory-limit exhaustion is the most common real-world WSUS
         outage cause)
      3. SUSDB engine identification (WID vs. full SQL Server) via the
         SqlServerName registry value — informs which connection method
         any follow-up database maintenance requires
      4. Content directory disk space headroom
      5. wsusutil checkhealth invocation (content/metadata consistency)
         — SKIPPED by default since it can run long on a large content
         store; enable explicitly with -RunCheckHealth
      6. Recent WSUS-specific Application-log errors

    Does NOT run wsusutil reset, modify IIS/WsusPool configuration, run
    the Cleanup Wizard, or alter SUSDB in any way — findings only.

.PARAMETER RunCheckHealth
    If set, invokes "wsusutil.exe checkhealth" as part of the audit. This
    can take a long time on a large content store — off by default.

.PARAMETER ContentVolumeWarnPercentFree
    Free-space percentage on the content volume below which a WARN is
    raised. Default: 15.

.PARAMETER OutputPath
    Folder to write CSV output to. Default: current directory.

.EXAMPLE
    .\Get-WSUSServerHealth.ps1
    Runs the standard audit without the (potentially long-running)
    content health check.

.EXAMPLE
    .\Get-WSUSServerHealth.ps1 -RunCheckHealth -OutputPath C:\WSUSAudit
    Includes wsusutil checkhealth, output to C:\WSUSAudit.

.NOTES
    Requires: WSUS server role installed locally (wsusutil.exe present),
    WebAdministration PowerShell module (installed with IIS management
    tools).
    Run-as: local Administrator on the WSUS server.
    Safe: read-only by default. wsusutil checkhealth (opt-in via
    -RunCheckHealth) is itself read-only/reporting-only — it does not
    modify content or SUSDB.
#>

[CmdletBinding()]
param(
    [switch]$RunCheckHealth,
    [ValidateRange(1,99)]
    [int]$ContentVolumeWarnPercentFree = 15,
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = New-Object System.Collections.Generic.List[PSObject]
function Add-Finding {
    param([string]$Category, [string]$Item, [string]$Status, [string]$Detail)
    $findings.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Category  = $Category
        Item      = $Item
        Status    = $Status
        Detail    = $Detail
    })
    Write-Status "$Category | $Item — $Detail" -Status $Status
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

Write-Status "=== WSUS Server Health Audit ===" -Status "INFO"

#region --- 1. Core service state ---
Write-Status "`n=== Core Services ===" -Status "INFO"
foreach ($svcName in @("WsusService", "W3SVC")) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        if ($svc.Status -eq "Running") {
            Add-Finding -Category "Service" -Item $svcName -Status "OK" -Detail "Status: Running, StartType: $($svc.StartType)"
        } else {
            Add-Finding -Category "Service" -Item $svcName -Status "ERROR" -Detail "Status: $($svc.Status) — this blocks the console AND all client scan/download traffic"
        }
    } catch {
        Add-Finding -Category "Service" -Item $svcName -Status "ERROR" -Detail "Service not found — is the WSUS role installed on this machine? $($_.Exception.Message)"
    }
}
#endregion

#region --- 2. WsusPool application pool ---
Write-Status "`n=== IIS WsusPool ===" -Status "INFO"
try {
    Import-Module WebAdministration -ErrorAction Stop
    $poolState = Get-WebAppPoolState -Name WsusPool -ErrorAction Stop
    if ($poolState.Value -eq "Started") {
        Add-Finding -Category "IIS" -Item "WsusPool state" -Status "OK" -Detail "Started"
    } else {
        Add-Finding -Category "IIS" -Item "WsusPool state" -Status "ERROR" -Detail "$($poolState.Value) — console and client scans will fail while stopped"
    }

    $pool = Get-Item "IIS:\AppPools\WsusPool" -ErrorAction Stop
    $memLimit = $pool.recycling.periodicRestart.privateMemory
    if ($memLimit -gt 0 -and $memLimit -lt 4GB / 1KB) {
        Add-Finding -Category "IIS" -Item "WsusPool private memory limit" -Status "WARN" -Detail "$memLimit KB — a low non-zero limit is a common cause of recycling-related outages on larger WSUS installs; consider raising or setting to 0 (unlimited)"
    } else {
        Add-Finding -Category "IIS" -Item "WsusPool private memory limit" -Status "OK" -Detail "$(if ($memLimit -eq 0) { 'Unlimited' } else { "$memLimit KB" })"
    }

    $rapidFail = $pool.failure.rapidFailProtection
    if ($rapidFail) {
        Add-Finding -Category "IIS" -Item "WsusPool rapid-fail protection" -Status "WARN" -Detail "Enabled — will stop the pool entirely after repeated crashes instead of allowing continued recovery attempts; commonly disabled on WSUS servers"
    } else {
        Add-Finding -Category "IIS" -Item "WsusPool rapid-fail protection" -Status "OK" -Detail "Disabled"
    }
} catch {
    Add-Finding -Category "IIS" -Item "WsusPool" -Status "ERROR" -Detail "Could not query WsusPool — WebAdministration module missing, or pool doesn't exist on this server: $($_.Exception.Message)"
}
#endregion

#region --- 3. SUSDB engine identification ---
Write-Status "`n=== SUSDB Engine ===" -Status "INFO"
try {
    $setup = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -ErrorAction Stop
    $sqlServerName = $setup.SqlServerName
    if ($sqlServerName -match "##WID|##SSEE") {
        Add-Finding -Category "SUSDB" -Item "Engine" -Status "INFO" -Detail "Windows Internal Database (WID) — value: $sqlServerName. Connect via SSMS/SSMS Express using the named-pipe path; no SQL Agent available for scheduled maintenance (use Task Scheduler + sqlcmd instead)"
    } elseif ($sqlServerName) {
        Add-Finding -Category "SUSDB" -Item "Engine" -Status "INFO" -Detail "Full SQL Server instance — value: $sqlServerName. Standard SSMS/sqlcmd connection applies; SQL Agent available for scheduled maintenance"
    } else {
        Add-Finding -Category "SUSDB" -Item "Engine" -Status "WARN" -Detail "SqlServerName registry value empty or unreadable"
    }
} catch {
    Add-Finding -Category "SUSDB" -Item "Engine" -Status "WARN" -Detail "Could not read WSUS Setup registry key — is the WSUS role installed on this machine? $($_.Exception.Message)"
}
#endregion

#region --- 4. Content directory disk space ---
Write-Status "`n=== Content Directory Disk Space ===" -Status "INFO"
try {
    $contentDir = $setup.ContentDir
    if ($contentDir) {
        $qualifier = (Split-Path $contentDir -Qualifier).TrimEnd(':')
        $drive = Get-PSDrive -Name $qualifier -ErrorAction Stop
        $totalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 1)
        $freeGB  = [math]::Round($drive.Free / 1GB, 1)
        $pctFree = if (($drive.Used + $drive.Free) -gt 0) { [math]::Round(($drive.Free / ($drive.Used + $drive.Free)) * 100, 1) } else { 0 }

        if ($pctFree -lt $ContentVolumeWarnPercentFree) {
            Add-Finding -Category "Storage" -Item "Content volume ($qualifier`:)" -Status "WARN" -Detail "$freeGB GB free of $totalGB GB ($pctFree`% free) — WSUS fails content downloads silently on low disk space, not loudly"
        } else {
            Add-Finding -Category "Storage" -Item "Content volume ($qualifier`:)" -Status "OK" -Detail "$freeGB GB free of $totalGB GB ($pctFree`% free)"
        }
    } else {
        Add-Finding -Category "Storage" -Item "Content volume" -Status "WARN" -Detail "ContentDir registry value empty or unreadable"
    }
} catch {
    Add-Finding -Category "Storage" -Item "Content volume" -Status "WARN" -Detail "Could not determine content volume free space: $($_.Exception.Message)"
}
#endregion

#region --- 5. Optional wsusutil checkhealth ---
if ($RunCheckHealth) {
    Write-Status "`n=== wsusutil checkhealth (this may take a while on a large content store) ===" -Status "INFO"
    try {
        $wsusutil = Join-Path $env:ProgramFiles "Update Services\Tools\wsusutil.exe"
        if (Test-Path $wsusutil) {
            & $wsusutil checkhealth | Out-Null
            Start-Sleep -Seconds 5
            $healthEvent = Get-WinEvent -LogName Application -MaxEvents 20 -ErrorAction SilentlyContinue |
                Where-Object { $_.ProviderName -eq "Windows Server Update Services" -and $_.Id -eq 12052 } |
                Select-Object -First 1
            if ($healthEvent) {
                Add-Finding -Category "ContentHealth" -Item "checkhealth result" -Status "INFO" -Detail "$($healthEvent.TimeCreated) — $($healthEvent.Message.Split("`n")[0])"
            } else {
                Add-Finding -Category "ContentHealth" -Item "checkhealth result" -Status "WARN" -Detail "checkhealth invoked but no Event ID 12052 result found yet — it may still be running for a large content store; re-check the Application log shortly"
            }
        } else {
            Add-Finding -Category "ContentHealth" -Item "wsusutil.exe" -Status "WARN" -Detail "wsusutil.exe not found at expected path — is the WSUS role installed on this machine?"
        }
    } catch {
        Add-Finding -Category "ContentHealth" -Item "(error)" -Status "WARN" -Detail "wsusutil checkhealth failed: $($_.Exception.Message)"
    }
} else {
    Add-Finding -Category "ContentHealth" -Item "checkhealth" -Status "INFO" -Detail "Skipped (default) — re-run with -RunCheckHealth to include; can be long-running on a large content store"
}
#endregion

#region --- 6. Recent WSUS-specific event errors ---
Write-Status "`n=== Recent WSUS Application-Log Errors ===" -Status "INFO"
try {
    $events = Get-WinEvent -LogName Application -MaxEvents 300 -ErrorAction Stop |
        Where-Object { $_.ProviderName -eq "Windows Server Update Services" -and $_.LevelDisplayName -eq "Error" }
    if ($events) {
        foreach ($e in $events | Select-Object -First 25) {
            Add-Finding -Category "EventLog" -Item "EventID $($e.Id)" -Status "WARN" -Detail "$($e.TimeCreated) — $($e.Message.Split("`n")[0])"
        }
    } else {
        Add-Finding -Category "EventLog" -Item "WSUS source" -Status "OK" -Detail "No matching Error events in the most recent 300 Application log entries"
    }
} catch {
    Add-Finding -Category "EventLog" -Item "(error)" -Status "WARN" -Detail "Get-WinEvent failed: $($_.Exception.Message)"
}
#endregion

#region --- Summary and export ---
$errorCount = ($findings | Where-Object Status -eq "ERROR").Count
$warnCount  = ($findings | Where-Object Status -eq "WARN").Count
Write-Status "`n=== Summary: $errorCount ERROR, $warnCount WARN out of $($findings.Count) checks ===" -Status $(if ($errorCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARN" } else { "OK" })

$csvPath = Join-Path $OutputPath "WSUSServerHealth_$(Get-Date -Format yyyyMMdd-HHmm).csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Findings exported to $csvPath" -Status "INFO"
#endregion
