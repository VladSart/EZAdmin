<#
.SYNOPSIS
    Read-only health audit of scheduled tasks on one or more Windows machines.

.DESCRIPTION
    Enumerates scheduled tasks (by default excluding the \Microsoft\ tree) and flags the
    configurations and results that cause most "scheduled task didn't run" tickets:

      - Schedule service state and whether TaskScheduler/Operational history is enabled
      - LastTaskResult decoded (0x1, 0x2, 0x41301, 0x41303, 0x41306, 0x800710E0, 0x8007052E, ...)
      - Disabled tasks, tasks with no NextRunTime on time-based triggers, expired triggers
      - Principal risk: stored-password (LogonType Password, non-gMSA), S4U with UNC paths,
        InteractiveToken tasks on servers
      - Action problems: mapped drive letters, relative Execute paths, missing executables
        (local only), no WorkingDirectory for script hosts
      - Laptop-hostile settings (DisallowStartIfOnBatteries), unlimited ExecutionTimeLimit
      - Optional (-CheckOrphans, local only): TaskCache registry entries without an XML file,
        XML files without a registry entry, and Tree entries with no SD value (hidden task -
        possible persistence, escalate to security)

    Does NOT modify, run, stop, enable, disable, or delete any task.

.PARAMETER ComputerName
    One or more computers. Default: local machine. Remote queries use CIM over WinRM.

.PARAMETER IncludeMicrosoft
    Include tasks under \Microsoft\. Off by default (hundreds of inbox tasks, mostly noise).

.PARAMETER TaskPath
    Only audit tasks whose TaskPath starts with this value (e.g. '\Contoso\').

.PARAMETER CheckOrphans
    Local machine only. Compare System32\Tasks XML files against the TaskCache registry.

.PARAMETER OutputPath
    Folder for the CSV reports. Created if missing.

.EXAMPLE
    .\Get-ScheduledTaskHealth.ps1

.EXAMPLE
    .\Get-ScheduledTaskHealth.ps1 -ComputerName (Get-Content .\servers.txt) -TaskPath '\Contoso\' -OutputPath C:\Temp\TaskAudit

.EXAMPLE
    .\Get-ScheduledTaskHealth.ps1 -CheckOrphans -IncludeMicrosoft

.NOTES
    Requires: Windows PowerShell 5.1+, ScheduledTasks module, local admin on each target
    (non-admins cannot see tasks secured to administrators). Remote: WinRM enabled.
    Safe: read-only.
    Companion to Windows/Troubleshooting/TaskScheduler-A.md / TaskScheduler-B.md.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [switch]$IncludeMicrosoft,
    [string]$TaskPath,
    [switch]$CheckOrphans,
    [string]$OutputPath = "C:\Temp\ScheduledTaskHealth"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------- Reference data ----------------
$ResultMap = @{
    '0x0'        = 'Success'
    '0x1'        = 'Action returned 1 (script/program error)'
    '0x2'        = 'File not found (Execute path)'
    '0x41300'    = 'Ready (never completed a run)'
    '0x41301'    = 'Currently running / hung previous instance'
    '0x41302'    = 'Task disabled'
    '0x41303'    = 'Has not yet run'
    '0x41306'    = 'Terminated (user or ExecutionTimeLimit)'
    '0x8004131F' = 'Instance already running (IgnoreNew)'
    '0x80070002' = 'File not found'
    '0x80070005' = 'Access denied (batch logon right / ACL)'
    '0x8007052E' = 'Logon failure (stored password wrong/expired)'
    '0x800710E0' = 'Refused: conditions not met or user not logged on'
    '0x800704DD' = 'User not logged on'
    '0xC000013A' = 'Process terminated (Ctrl+C / shutdown / stop)'
}

function ConvertTo-ResultHex {
    param([object]$Code)
    $n = [int64]$Code
    if ($n -lt 0) { $n = $n + 4294967296 }   # Int32-signed HRESULT -> unsigned
    return ('0x{0:X}' -f $n)
}

function Get-ResultText {
    param([string]$Hex)
    if ($ResultMap.ContainsKey($Hex)) { return $ResultMap[$Hex] }
    return 'Unrecognised - likely the action exit code'
}

function Test-IsGmsa {
    param([string]$UserId)
    return ($UserId -and $UserId.TrimEnd() -match '\$$')
}

# ---------------- Preflight ----------------
if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
    Write-Status "ScheduledTasks module not available on this machine." "ERROR"; return
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$stamp   = Get-Date -Format 'yyyyMMdd-HHmm'
$results = New-Object System.Collections.Generic.List[object]
$hostRows= New-Object System.Collections.Generic.List[object]
$orphans = New-Object System.Collections.Generic.List[object]

# ---------------- Detect / Execute ----------------
foreach ($cn in $ComputerName) {
    $isLocal = ($cn -eq $env:COMPUTERNAME -or $cn -eq 'localhost' -or $cn -eq '.')
    Write-Status "Auditing $cn" "INFO"
    $cim = $null
    try {
        if ($isLocal) { $cim = New-CimSession } else { $cim = New-CimSession -ComputerName $cn }
    } catch {
        Write-Status "$cn : CIM session failed - $($_.Exception.Message)" "ERROR"
        $hostRows.Add([pscustomobject]@{ Computer=$cn; Reachable=$false; ScheduleService=''; HistoryEnabled=''; TasksAudited=0; Flagged=0; Note=$_.Exception.Message })
        continue
    }

    # Service + history
    $svcState = 'Unknown'; $history = 'Unknown'
    try {
        $svc = Get-CimInstance -CimSession $cim -ClassName Win32_Service -Filter "Name='Schedule'"
        if ($svc) { $svcState = "$($svc.State)/$($svc.StartMode)" }
    } catch { $svcState = 'QueryFailed' }
    try {
        if ($isLocal) {
            $history = [string](Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational').IsEnabled
        } else {
            $history = [string](Invoke-Command -ComputerName $cn -ScriptBlock { (Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational').IsEnabled })
        }
    } catch { $history = 'QueryFailed' }
    if ($svcState -notlike 'Running*') { Write-Status "$cn : Schedule service = $svcState" "ERROR" }
    if ($history -ne 'True') { Write-Status "$cn : Task history enabled = $history (no run history available)" "WARN" }

    $isServer = $false
    try {
        $os = Get-CimInstance -CimSession $cim -ClassName Win32_OperatingSystem
        $isServer = ($os.ProductType -ne 1)
    } catch { }

    try {
        $tasks = @(Get-ScheduledTask -CimSession $cim -ErrorAction Stop)
    } catch {
        Write-Status "$cn : Get-ScheduledTask failed - $($_.Exception.Message)" "ERROR"
        Remove-CimSession $cim -ErrorAction SilentlyContinue
        continue
    }
    if (-not $IncludeMicrosoft) { $tasks = @($tasks | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) }
    if ($TaskPath)              { $tasks = @($tasks | Where-Object { $_.TaskPath -like "$TaskPath*" }) }

    $flaggedCount = 0
    foreach ($t in $tasks) {
        $issues = New-Object System.Collections.Generic.List[string]
        $info = $null
        try { $info = Get-ScheduledTaskInfo -InputObject $t -ErrorAction Stop } catch { $issues.Add('TaskInfo unreadable (corrupt definition?)') }

        $lastHex = ''; $lastText = ''; $lastRun = $null; $nextRun = $null; $missed = $null
        if ($info) {
            $lastHex  = ConvertTo-ResultHex -Code $info.LastTaskResult
            $lastText = Get-ResultText -Hex $lastHex
            $lastRun  = $info.LastRunTime
            $nextRun  = $info.NextRunTime
            $missed   = $info.NumberOfMissedRuns
            if ($lastHex -notin @('0x0','0x41303','0x41301','0x41300')) { $issues.Add("LastResult $lastHex ($lastText)") }
            if ($lastHex -eq '0x41301' -and $lastRun -and $lastRun -lt (Get-Date).AddDays(-1)) { $issues.Add('Running >24h - probable hang') }
        }

        if ($t.State -eq 'Disabled') { $issues.Add('Task disabled') }

        # Triggers
        $trigTypes = @()
        $hasTimeTrigger = $false
        foreach ($tr in @($t.Triggers)) {
            if ($null -eq $tr) { continue }
            $type = $tr.CimClass.CimClassName -replace '^MSFT_Task','' -replace 'Trigger$',''
            $trigTypes += $type
            if ($type -in @('Time','Daily','Weekly','Monthly','MonthlyDOW','')) { $hasTimeTrigger = $true }
            $eb = $null
            try { $eb = $tr.EndBoundary } catch { }
            if ($eb) {
                $ebDate = $null
                if ([datetime]::TryParse([string]$eb, [ref]$ebDate) -and $ebDate -lt (Get-Date)) { $issues.Add("Trigger expired ($eb)") }
            }
            $en = $true
            try { $en = $tr.Enabled } catch { }
            if ($en -eq $false) { $issues.Add("Trigger $type disabled") }
        }
        if (@($t.Triggers).Count -eq 0) { $issues.Add('No triggers (on-demand only)') }
        elseif ($hasTimeTrigger -and $t.State -ne 'Disabled' -and $info -and -not $nextRun) { $issues.Add('Time trigger but no NextRunTime') }

        # Principal
        $userId    = [string]$t.Principal.UserId
        $groupId   = [string]$t.Principal.GroupId
        $logonType = [string]$t.Principal.LogonType
        $runLevel  = [string]$t.Principal.RunLevel
        $storedPwd = ($logonType -eq 'Password' -and -not (Test-IsGmsa $userId))
        if ($storedPwd) { $issues.Add('Stored password principal - breaks on rotation; consider gMSA') }
        if ($logonType -eq 'Interactive' -and $isServer) { $issues.Add('Run-only-when-logged-on task on a server') }

        # Actions
        $actionText = New-Object System.Collections.Generic.List[string]
        foreach ($a in @($t.Actions)) {
            if ($null -eq $a) { continue }
            $exe = $null; $arg = $null; $wd = $null
            try { $exe = [string]$a.Execute; $arg = [string]$a.Arguments; $wd = [string]$a.WorkingDirectory } catch { $actionText.Add('[ComHandler]'); continue }
            $actionText.Add(("{0} {1}" -f $exe, $arg).Trim())
            $full = ("$exe $arg")
            if ($full -match '(^|[\s"''=])[D-Zd-z]:\\' ) {
                # D:-Z: may be real local volumes; flag as possible mapped drive
                $issues.Add('Action references drive letter D:-Z: - verify not a mapped drive')
            }
            if ($logonType -eq 'S4U' -and $full -match '\\\\[^\\]+\\') { $issues.Add('S4U principal with UNC path - S4U has no network credentials') }
            $clean = [Environment]::ExpandEnvironmentVariables($exe.Trim('"'))
            if ($clean -and -not [IO.Path]::IsPathRooted($clean)) {
                # Bare names resolve via the service's PATH (System32 etc.). Only flag if not resolvable locally.
                $resolvable = $false
                if ($isLocal) { $resolvable = [bool](Get-Command -Name $clean -CommandType Application -ErrorAction SilentlyContinue) }
                elseif ($clean -match '^(powershell|pwsh|cmd|wscript|cscript|rundll32|msiexec|schtasks|robocopy|reg|sc|net)(\.exe)?$') { $resolvable = $true }
                if (-not $resolvable) { $issues.Add("Relative / unresolvable Execute path '$exe'") }
            }
            if ($isLocal -and $clean -and [IO.Path]::IsPathRooted($clean) -and -not (Test-Path -LiteralPath $clean)) {
                $issues.Add("Execute path missing: $clean")
            }
            if ($clean -match '(powershell|pwsh|cmd|wscript|cscript)(\.exe)?$' -and -not $wd -and $arg -notmatch '[A-Za-z]:\\|\\\\') {
                $issues.Add('Script host without WorkingDirectory and no absolute script path')
            }
            if ($isLocal -and $arg -match '-File\s+"?([A-Za-z]:\\[^"]+?\.ps1)') {
                $script = [Environment]::ExpandEnvironmentVariables($Matches[1])
                if (-not (Test-Path -LiteralPath $script)) { $issues.Add("Script missing: $script") }
            }
        }

        # Settings
        $s = $t.Settings
        $etl = [string]$s.ExecutionTimeLimit
        if ($s.DisallowStartIfOnBatteries -and -not $isServer) { $issues.Add('Will not start on battery (DisallowStartIfOnBatteries)') }
        if ($etl -in @('PT0S','')) { $issues.Add('No ExecutionTimeLimit - hangs never auto-stop') }
        if ($s.RunOnlyIfIdle) { $issues.Add('RunOnlyIfIdle set') }

        if ($issues.Count -gt 0) { $flaggedCount++ }
        $results.Add([pscustomobject]@{
            Computer          = $cn
            TaskPath          = $t.TaskPath
            TaskName          = $t.TaskName
            State             = [string]$t.State
            LastRunTime       = $lastRun
            LastResultHex     = $lastHex
            LastResultMeaning = $lastText
            NextRunTime       = $nextRun
            MissedRuns        = $missed
            RunAs             = $(if ($userId) { $userId } else { $groupId })
            LogonType         = $logonType
            RunLevel          = $runLevel
            StoredPassword    = $storedPwd
            Triggers          = ($trigTypes -join ';')
            Actions           = ($actionText -join ' | ')
            ExecutionLimit    = $etl
            MultipleInstances = [string]$s.MultipleInstances
            Priority          = $s.Priority
            Author            = [string]$t.Author
            IssueCount        = $issues.Count
            Issues            = ($issues -join '; ')
        })
    }

    $hostRows.Add([pscustomobject]@{ Computer=$cn; Reachable=$true; ScheduleService=$svcState; HistoryEnabled=$history; TasksAudited=$tasks.Count; Flagged=$flaggedCount; Note='' })
    Remove-CimSession $cim -ErrorAction SilentlyContinue

    # ---------------- Orphan check (local only) ----------------
    if ($CheckOrphans -and $isLocal) {
        Write-Status "Checking TaskCache vs System32\Tasks parity" "INFO"
        $treeRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree'
        $xmlRoot  = Join-Path $env:windir 'System32\Tasks'
        $regTasks = @{}
        foreach ($k in @(Get-ChildItem -Path $treeRoot -Recurse -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $hasId = $props.PSObject.Properties.Name -contains 'Id'
            if (-not $hasId) { continue }   # folder, not task
            $rel = $k.Name -replace '^.*\\TaskCache\\Tree\\',''
            $regTasks[$rel.ToLowerInvariant()] = $true
            $hasSD = $props.PSObject.Properties.Name -contains 'SD'
            if (-not $hasSD) {
                $orphans.Add([pscustomobject]@{ Computer=$cn; Type='NoSecurityDescriptor'; Task=$rel; Detail='Tree entry has no SD value - hidden task, possible persistence. Escalate to security.' })
            }
            if (-not (Test-Path -LiteralPath (Join-Path $xmlRoot $rel))) {
                $orphans.Add([pscustomobject]@{ Computer=$cn; Type='RegistryWithoutXml'; Task=$rel; Detail='TaskCache entry has no XML file' })
            }
        }
        foreach ($f in @(Get-ChildItem -Path $xmlRoot -Recurse -File -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Substring($xmlRoot.Length).TrimStart('\')
            if (-not $regTasks.ContainsKey($rel.ToLowerInvariant())) {
                $orphans.Add([pscustomobject]@{ Computer=$cn; Type='XmlWithoutRegistry'; Task=$rel; Detail='XML file has no TaskCache entry' })
            }
        }
    } elseif ($CheckOrphans -and -not $isLocal) {
        Write-Status "$cn : -CheckOrphans is local-only; skipped" "WARN"
    }
}

# ---------------- Validate / Report ----------------
$taskCsv  = Join-Path $OutputPath "ScheduledTaskHealth-Tasks-$stamp.csv"
$hostCsv  = Join-Path $OutputPath "ScheduledTaskHealth-Hosts-$stamp.csv"
$results  | Sort-Object Computer, TaskPath, TaskName | Export-Csv -Path $taskCsv -NoTypeInformation -Encoding UTF8
$hostRows | Export-Csv -Path $hostCsv -NoTypeInformation -Encoding UTF8
if ($orphans.Count -gt 0) {
    $orphCsv = Join-Path $OutputPath "ScheduledTaskHealth-Orphans-$stamp.csv"
    $orphans | Export-Csv -Path $orphCsv -NoTypeInformation -Encoding UTF8
    Write-Status "$($orphans.Count) orphan/hidden entries -> $orphCsv" "WARN"
    $noSd = @($orphans | Where-Object Type -eq 'NoSecurityDescriptor')
    if ($noSd.Count -gt 0) { Write-Status "$($noSd.Count) task(s) with no SD value - treat as a security finding" "ERROR" }
}

$flagged = @($results | Where-Object IssueCount -gt 0)
Write-Host ""
Write-Status ("Tasks audited: {0}  Flagged: {1}  Hosts: {2}" -f $results.Count, $flagged.Count, $hostRows.Count) $(if ($flagged.Count) {"WARN"} else {"OK"})
if ($flagged.Count -gt 0) {
    $flagged | Sort-Object IssueCount -Descending | Select-Object -First 15 Computer, TaskPath, TaskName, LastResultHex, Issues | Format-Table -AutoSize -Wrap
}
Write-Status "Task report: $taskCsv" "OK"
Write-Status "Host report: $hostCsv" "OK"
