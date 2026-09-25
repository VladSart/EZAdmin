<#
.SYNOPSIS
    Reports Smart App Control (SAC) state, toggle readiness, management context and recent Code Integrity blocks on a Windows 11 device.

.DESCRIPTION
    Read-only. Designed to run per device via RMM, an Intune remediation (detection) script or interactively.
    Reports:
      - SAC state from HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy\VerifiedAndReputablePolicyState
        (0 = Off, 1 = On/Enforce, 2 = Evaluation) and, where available, Get-MpComputerStatus SmartAppControlState
      - OS build + UBR and whether it is at/after KB5083769 (26100.8246 / 26200.8246, April 2026),
        the update that made SAC reversible without reinstall
      - Management context (domain join, MDM enrollment) - SAC is expected Off on managed devices
      - Active Code Integrity policies (CiTool.exe --list-policies, Windows 11 22H2+)
      - Code Integrity block/audit events (3033, 3034, 3076, 3077) in the last -Hours hours, with the blocked file path
      - A recommendation string per device

    It does NOT change SAC state. There is no supported programmatic toggle; use Windows Security.

.PARAMETER Hours
    Look-back window for Code Integrity events. Default 72.

.PARAMETER OutputPath
    Folder for CSV output. Default C:\Temp

.EXAMPLE
    .\Get-SmartAppControlStatus.ps1
    Local device, last 72 hours of CI events, CSVs to C:\Temp.

.EXAMPLE
    .\Get-SmartAppControlStatus.ps1 -Hours 336 -OutputPath D:\Reports
    Two-week look-back for a SAC pilot review.

.NOTES
    Requires: Windows 11, Windows PowerShell 5.1 or PowerShell 7. Run elevated to read the CodeIntegrity log and CiTool output.
    Safe: read-only; creates only the output folder and two CSVs.
    Sources: Topedia / CIAOPS (April 2026) for KB5083769 behaviour; Microsoft Support Smart App Control FAQ.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 2160)]
    [int]$Hours = 72,
    [string]$OutputPath = 'C:\Temp'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------- Preflight ----------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Status "Not elevated - CodeIntegrity events and CiTool output may be missing." "WARN" }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int]$cv.CurrentBuild
$ubr   = 0
if ($cv.PSObject.Properties.Name -contains 'UBR') { $ubr = [int]$cv.UBR }
$productName = [string]$cv.ProductName
if ($build -ge 22000 -and $productName -like 'Windows 10*') { $productName = $productName -replace 'Windows 10', 'Windows 11' }

if ($build -lt 22000) {
    Write-Status "Build $build is not Windows 11 - Smart App Control does not apply." "WARN"
}

# ---------------- Detect ----------------
$stateMap = @{ 0 = 'Off'; 1 = 'On'; 2 = 'Evaluation' }
$sacRaw = $null
$ciKey = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue
if ($ciKey -and ($ciKey.PSObject.Properties.Name -contains 'VerifiedAndReputablePolicyState')) {
    $sacRaw = [int]$ciKey.VerifiedAndReputablePolicyState
}
$sacState = 'NotProvisioned'
if ($null -ne $sacRaw) {
    if ($stateMap.ContainsKey($sacRaw)) { $sacState = $stateMap[$sacRaw] } else { $sacState = "Unknown($sacRaw)" }
}

$mpState = $null
$mpExpiry = $null
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    if ($mp.PSObject.Properties.Name -contains 'SmartAppControlState')      { $mpState  = [string]$mp.SmartAppControlState }
    if ($mp.PSObject.Properties.Name -contains 'SmartAppControlExpiration') { $mpExpiry = [string]$mp.SmartAppControlExpiration }
} catch {
    Write-Status "Get-MpComputerStatus unavailable (Defender not primary AV?): $($_.Exception.Message)" "INFO"
}

# KB5083769 = 26100.8246 (24H2) / 26200.8246 (25H2). Later feature builds are assumed to include it.
$toggleReady = $false
if ($build -gt 26200) { $toggleReady = $true }
elseif (($build -eq 26100 -or $build -eq 26200) -and $ubr -ge 8246) { $toggleReady = $true }

$domainJoined = [bool](Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain
$mdmProviders = @()
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p -and ($p.PSObject.Properties.Name -contains 'ProviderID') -and $p.ProviderID) { $mdmProviders += [string]$p.ProviderID }
}
$mdmProviders = @($mdmProviders | Select-Object -Unique)
$managed = $domainJoined -or ($mdmProviders.Count -gt 0)

$ciPolicies = ''
$ciTool = Get-Command CiTool.exe -ErrorAction SilentlyContinue
if ($ciTool) {
    try {
        $raw = & $ciTool.Source --list-policies 2>&1 | Out-String
        $names = [regex]::Matches($raw, '(?m)Friendly Name:\s*(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() }
        $ciPolicies = (@($names) | Select-Object -Unique) -join '; '
    } catch { $ciPolicies = "CiTool error: $($_.Exception.Message)" }
}

# ---------------- Execute: CI events ----------------
$events = New-Object System.Collections.Generic.List[object]
try {
    $since = (Get-Date).AddHours(-$Hours)
    $raw = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3033, 3034, 3076, 3077; StartTime = $since } -ErrorAction Stop
    foreach ($e in $raw) {
        $file = ''
        if ($e.Message -match '(?i)(?:attempted to load|process)\s+(.+?\.(?:exe|dll|sys|msi|mst|ps1|js|vbs))') { $file = $Matches[1].Trim() }
        $kind = switch ($e.Id) { 3077 {'Blocked'} 3033 {'SignatureLevelNotMet'} 3034 {'SignatureLevelNotMet(Audit)'} 3076 {'AuditWouldBlock'} }
        $events.Add([PSCustomObject]@{
            Computer    = $env:COMPUTERNAME
            TimeCreated = $e.TimeCreated
            EventId     = $e.Id
            Kind        = $kind
            File        = $file
            Message     = ($e.Message -split "`r?`n")[0]
        })
    }
} catch {
    Write-Status "No CodeIntegrity events in the last $Hours h (or log not readable)." "INFO"
}
$blockCount = @($events | Where-Object { $_.EventId -in 3077, 3033 }).Count

# ---------------- Validate / recommend ----------------
$recommendation =
    if ($build -lt 22000) { 'N/A - not Windows 11' }
    elseif ($managed -and $sacState -eq 'On') { 'Managed device with SAC On - unusual; plan App Control for Business and confirm intent' }
    elseif ($managed) { 'Managed device - use App Control for Business (Intune/GPO); SAC expected Off' }
    elseif ($sacState -eq 'Off' -and -not $toggleReady) { 'SAC Off and build predates KB5083769 - patch before attempting to re-enable' }
    elseif ($sacState -eq 'Off') { 'SAC Off, toggle available - candidate for enabling (exclude dev/admin personas)' }
    elseif ($sacState -eq 'On' -and $blockCount -gt 0) { "SAC On with $blockCount block(s) - review blocked files (signed vendor build / temp toggle)" }
    elseif ($sacState -eq 'On') { 'SAC On, no recent blocks - healthy' }
    elseif ($sacState -eq 'Evaluation') { 'Evaluation - observing only, never blocks; blocks here come from another control' }
    else { 'SAC not provisioned - check edition/build' }

$summary = [PSCustomObject]@{
    Computer        = $env:COMPUTERNAME
    Product         = $productName
    Build           = "$build.$ubr"
    ToggleReady     = $toggleReady
    SACState        = $sacState
    SACRaw          = $sacRaw
    MpSACState      = $mpState
    MpSACExpiration = $mpExpiry
    DomainJoined    = $domainJoined
    MDMProviders    = ($mdmProviders -join '; ')
    Managed         = $managed
    CIPolicies      = $ciPolicies
    CIEventsInWindow= $events.Count
    Blocks          = $blockCount
    Recommendation  = $recommendation
    AuditTime       = (Get-Date).ToString('s')
}

# ---------------- Report ----------------
$sumFile = Join-Path $OutputPath "SAC_Summary_$($env:COMPUTERNAME)_$stamp.csv"
$evtFile = Join-Path $OutputPath "SAC_CIEvents_$($env:COMPUTERNAME)_$stamp.csv"
$summary | Export-Csv -Path $sumFile -NoTypeInformation -Encoding UTF8
$events  | Export-Csv -Path $evtFile -NoTypeInformation -Encoding UTF8

$summary | Format-List
$lvl = if ($blockCount -gt 0 -or ($sacState -eq 'Off' -and -not $toggleReady -and -not $managed)) { 'WARN' } else { 'OK' }
Write-Status $recommendation $lvl
Write-Status "Summary: $sumFile" "OK"
if ($events.Count -gt 0) { Write-Status "CI events: $evtFile" "INFO" }
