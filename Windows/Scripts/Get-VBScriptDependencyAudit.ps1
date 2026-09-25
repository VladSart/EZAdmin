<#
.SYNOPSIS
    Read-only audit of a Windows device's VBScript engine state and VBScript dependencies ahead of Phase 2 of the VBScript deprecation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/VBScriptDeprecation-B.md and -A.md.

    Checks:
    - VBScript Feature on Demand state (VBSCRIPT~~~~) and whether the engine actually executes (cscript probe)
    - Deprecation telemetry: event ID 4096 from provider VBScriptDeprecationAlert in the Application log, plus
      the Windows Script Host operational log if present (community sources disagree on location, so both are queried)
    - Whether the OSLicense module (slmgr.vbs replacement, Windows 11 Aug/Sept 2026 update) is available
    - Microsoft 365 Apps build (2508+ has built-in VBA RegExp)
    - Presence of OSPP.VBS (Office volume activation, which has no full PowerShell replacement yet)
    - Scheduled tasks whose action references wscript/cscript/.vbs/.wsf/slmgr/winrm.vbs/prnmngr etc.
    - HKLM/HKCU Run and RunOnce values referencing VBScript
    - Literal references in .vbs/.wsf/.ps1/.cmd/.bat files under the supplied -ScanPath folders

    Output: one row per finding to a CSV, plus a console summary. With -Quiet it prints one summary line
    and exits 1 when dependencies are found (0 when clean), so it can be used as an Intune Remediation
    detection script.

    Does NOT:
    - Change anything (it never adds or removes the FOD)
    - Scan SYSVOL/GPO scripts (see VBScriptDeprecation-A.md Playbook 4)
    - Detect MSI VBScript custom actions or COM CreateObject callers unless they have run and produced an event 4096
    - Parse event 4096 call stacks beyond extracting .vbs/.exe tokens

.PARAMETER LookbackDays
    How many days of event 4096 history to read. Default 14.

.PARAMETER ScanPath
    Folders to search for script references. Default: C:\Scripts, C:\ProgramData, C:\Windows\Setup\Scripts.
    Folders that don't exist are skipped.

.PARAMETER OutputPath
    Folder for the CSV. Default: $env:TEMP.

.PARAMETER Quiet
    Intune Remediation mode: single-line STDOUT, exit code 1 if any dependency is found, 0 otherwise.

.EXAMPLE
    .\Get-VBScriptDependencyAudit.ps1
    Full audit with defaults. The CSV is written to %TEMP%.

.EXAMPLE
    .\Get-VBScriptDependencyAudit.ps1 -LookbackDays 30 -ScanPath 'D:\Automation','C:\ProgramData\MyRMM' -OutputPath 'C:\Temp'

.EXAMPLE
    # Intune Remediation detection script (run as System, 64-bit, no remediation script)
    .\Get-VBScriptDependencyAudit.ps1 -Quiet

.NOTES
    Requires: Windows PowerShell 5.1 or PowerShell 7 on Windows 10/11 or Server 2016+.
    Run as: Administrator recommended (Get-WindowsCapability and the full scheduled-task list need elevation).
    Without elevation the FOD check is reported as Unknown and the rest still runs.
    Safe: read-only. The cscript probe writes and deletes one temporary .vbs file in %TEMP%.
    Author: EZAdmin auto-build run 252 (2026-09-25). Not executed in a live environment. Treat the first run as validation.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 90)]
    [int]$LookbackDays = 14,

    [string[]]$ScanPath = @('C:\Scripts', 'C:\ProgramData', 'C:\Windows\Setup\Scripts'),

    [string]$OutputPath = $env:TEMP,

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    if ($Quiet) { return }
    $colour = switch ($Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Category, [string]$Item, [string]$Detail, [string]$Severity = 'Info')
    $findings.Add([PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        Category     = $Category
        Item         = $Item
        Detail       = $Detail
        Severity     = $Severity
        Collected    = (Get-Date).ToString('s')
    })
}

# Regex for VBScript consumers in command lines and file contents
$depPattern = '(?i)(wscript(\.exe)?\b|cscript(\.exe)?\b|\.vbs\b|\.wsf\b|slmgr|ospp\.vbs|winrm\.vbs|prnmngr|prnport|prndrvr|prnqctl|prncnfg|VBScript\.RegExp|mshta)'

# ---------------------------------------------------------------- Preflight
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Status 'Not elevated: the FOD state and some scheduled tasks may be unreadable.' 'WARN' }

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$build = [int]$os.BuildNumber
Write-Status "OS: $($os.Caption) build $($os.BuildNumber).$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR)"
Add-Finding -Category 'OS' -Item $os.Caption -Detail "Build $($os.BuildNumber)"

# ---------------------------------------------------------------- Detect: FOD state
$fodState = 'Unknown'
if ($isAdmin) {
    try {
        $cap = Get-WindowsCapability -Online -Name 'VBSCRIPT*' -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $cap) { $fodState = [string]$cap.State } else { $fodState = 'NoCapability(pre-24H2 inbox?)' }
    } catch {
        $fodState = "Error: $($_.Exception.Message)"
    }
}
$fodSeverity = if ($fodState -eq 'Installed') { 'Info' } elseif ($fodState -like 'Unknown*' -or $fodState -like 'NoCapability*') { 'Info' } else { 'High' }
Add-Finding -Category 'Engine' -Item 'VBSCRIPT FOD' -Detail $fodState -Severity $fodSeverity
Write-Status "VBScript FOD state: $fodState" $(if ($fodSeverity -eq 'High') { 'WARN' } else { 'OK' })

# ---------------------------------------------------------------- Detect: engine probe
$probeResult = 'NotRun'
$probeFile = Join-Path $env:TEMP ("vbs-probe-{0}.vbs" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
try {
    Set-Content -Path $probeFile -Value 'WScript.Echo "VBS-OK"' -Encoding ASCII
    $cscript = Join-Path $env:SystemRoot 'System32\cscript.exe'
    if (Test-Path $cscript) {
        $out = & $cscript //nologo $probeFile 2>&1 | Out-String
        $probeResult = if ($out -match 'VBS-OK') { 'Executes' } else { "Fails: $($out.Trim())" }
    } else {
        $probeResult = 'cscript.exe missing'
    }
} catch {
    $probeResult = "Error: $($_.Exception.Message)"
} finally {
    Remove-Item -Path $probeFile -Force -ErrorAction SilentlyContinue
}
Add-Finding -Category 'Engine' -Item 'cscript probe' -Detail $probeResult -Severity $(if ($probeResult -eq 'Executes') { 'Info' } else { 'High' })
Write-Status "Engine probe: $probeResult" $(if ($probeResult -eq 'Executes') { 'OK' } else { 'WARN' })

# ---------------------------------------------------------------- Detect: event 4096 telemetry
$since = (Get-Date).AddDays(-$LookbackDays)
$eventCount = 0
$logsToQuery = @('Application', 'Microsoft-Windows-Windows Script Host/Operational')
foreach ($log in $logsToQuery) {
    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Id = 4096; StartTime = $since } -ErrorAction Stop |
            Where-Object { $_.ProviderName -like '*VBScript*' -or ($_.Message -and $_.Message -like '*VBScript*') })
    } catch {
        # "No events were found" and "log does not exist" both land here
        Write-Verbose "Log '$log': $($_.Exception.Message)"
    }
    foreach ($e in $events) {
        $eventCount++
        $tokens = @()
        if ($e.Message) {
            $tokens = [regex]::Matches($e.Message, '(?i)[\w\-. ]+\.(vbs|wsf|exe)') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique
        }
        Add-Finding -Category 'Telemetry4096' -Item ($e.TimeCreated.ToString('s')) -Detail (($tokens | Select-Object -First 8) -join ' > ') -Severity 'Medium'
    }
}
Write-Status "Event 4096 (VBScript usage) in last $LookbackDays days: $eventCount" $(if ($eventCount -gt 0) { 'WARN' } else { 'OK' })

# ---------------------------------------------------------------- Detect: replacement tooling / Office
$osl = @(Get-Module -ListAvailable -Name '*OSLicense*' -ErrorAction SilentlyContinue)
$oslDetail = if ($osl.Count -gt 0) { "Available v$($osl[0].Version)" } else { 'Not available (needs Win 11 Aug/Sept 2026 update; not in Server 2025/WinPE)' }
Add-Finding -Category 'Replacement' -Item 'OSLicense module' -Detail $oslDetail
Write-Status "OSLicense module: $oslDetail"

$c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
if ($null -ne $c2r -and ($c2r.PSObject.Properties.Name -contains 'VersionToReport')) {
    $ver = [version]$c2r.VersionToReport
    $regexOk = $ver -ge [version]'16.0.19127.20154'
    Add-Finding -Category 'Office' -Item 'Click-to-Run build' -Detail "$ver (built-in VBA RegExp: $regexOk)" -Severity $(if ($regexOk) { 'Info' } else { 'Medium' })
    Write-Status "Office C2R $ver - built-in VBA RegExp: $regexOk" $(if ($regexOk) { 'OK' } else { 'WARN' })
}

$osppPaths = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { -not [string]::IsNullOrEmpty($_) } |
    ForEach-Object { Join-Path $_ 'Microsoft Office\Office16\OSPP.VBS' }
foreach ($p in $osppPaths) {
    if ($p -and (Test-Path $p)) {
        Add-Finding -Category 'Office' -Item 'OSPP.VBS present' -Detail $p -Severity 'Medium'
        Write-Status "OSPP.VBS found: $p (volume Office activation depends on VBScript)" 'WARN'
    }
}

# ---------------------------------------------------------------- Detect: scheduled tasks
try {
    foreach ($task in Get-ScheduledTask -ErrorAction Stop) {
        foreach ($a in @($task.Actions)) {
            if (-not ($a.PSObject.Properties.Name -contains 'Execute')) { continue }
            $cmd = "{0} {1}" -f $a.Execute, $a.Arguments
            if ($cmd -match $depPattern) {
                Add-Finding -Category 'ScheduledTask' -Item ($task.TaskPath + $task.TaskName) -Detail $cmd.Trim() -Severity 'High'
            }
        }
    }
} catch {
    Write-Status "Scheduled task scan failed: $($_.Exception.Message)" 'WARN'
}

# ---------------------------------------------------------------- Detect: Run keys
$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)
foreach ($k in $runKeys) {
    $props = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
    if ($null -eq $props) { continue }
    foreach ($prop in $props.PSObject.Properties) {
        if ($prop.Name -like 'PS*') { continue }
        $val = [string]$prop.Value
        if ($val -match $depPattern) {
            Add-Finding -Category 'RunKey' -Item "$k\$($prop.Name)" -Detail $val -Severity 'High'
        }
    }
}

# ---------------------------------------------------------------- Detect: script files
foreach ($root in $ScanPath) {
    if (-not (Test-Path -LiteralPath $root)) { Write-Verbose "Skip missing path $root"; continue }
    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Include *.vbs, *.wsf, *.ps1, *.cmd, *.bat -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        if ($f.Extension -in '.vbs', '.wsf') {
            Add-Finding -Category 'ScriptFile' -Item $f.FullName -Detail 'VBScript/WSF file present' -Severity 'Medium'
            continue
        }
        $hits = Select-String -LiteralPath $f.FullName -Pattern $depPattern -ErrorAction SilentlyContinue | Select-Object -First 3
        foreach ($h in $hits) {
            Add-Finding -Category 'ScriptReference' -Item "$($f.FullName):$($h.LineNumber)" -Detail $h.Line.Trim() -Severity 'High'
        }
    }
}

# ---------------------------------------------------------------- Report
$depCount = @($findings | Where-Object { $_.Category -in 'Telemetry4096', 'ScheduledTask', 'RunKey', 'ScriptFile', 'ScriptReference' -or ($_.Category -eq 'Office' -and $_.Item -eq 'OSPP.VBS present') }).Count

if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$csv = Join-Path $OutputPath ("VBScriptDependencyAudit-{0}-{1}.csv" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
$findings | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

if ($Quiet) {
    $summary = "FOD=$fodState; Probe=$probeResult; Events4096=$eventCount; Dependencies=$depCount; OSLicense=$([bool]($osl.Count -gt 0)); CSV=$csv"
    Write-Output $summary
    if ($depCount -gt 0) { exit 1 } else { exit 0 }
}

Write-Host ''
Write-Status '---- Summary ----'
$findings | Group-Object Category | Sort-Object Name | ForEach-Object { Write-Status ("{0,-16} {1}" -f $_.Name, $_.Count) }
if ($depCount -gt 0) {
    Write-Status "$depCount VBScript dependency finding(s). These will break when the FOD is disabled (Phase 2, ~2027). See VBScriptDeprecation-B.md." 'WARN'
} else {
    Write-Status 'No VBScript dependencies found on this device in the scanned scope.' 'OK'
}
Write-Status "CSV: $csv" 'OK'
