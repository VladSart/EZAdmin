<#
.SYNOPSIS
    Read-only local snapshot of Microsoft Edge policy sources, precedence switches and (optionally) one setting.

.DESCRIPTION
    Collects on the local Windows device, for the current user:
      - Installed Edge version and whether it meets the Edge management service minimum (115.0.1901.7)
      - Edge management service switches: EdgeManagementEnabled, EdgeManagementEnrollmentToken (presence only,
        value redacted), EdgeManagementPolicyOverridesPlatformPolicy,
        EdgeManagementUserPolicyOverridesCloudMachinePolicy - in both HKLM and HKCU
      - Every mandatory and Recommended Edge platform policy value under HKLM/HKCU\SOFTWARE\Policies\Microsoft\Edge
      - A heuristic MDM indicator: PolicyManager\current\device areas whose name contains "edge"
      - Whether any Group Policy is applied to the computer at all (gpresult summary), as a hint only
      - If -PolicyName is given, where that one setting is set (HKLM/HKCU, mandatory/recommended)

    It does NOT read cloud-delivered (Edge management service) values - those are not stored as readable
    registry policy. Open edge://policy and read the Source column for the effective value and origin.

.PARAMETER PolicyName
    Optional. A single Edge policy name (for example HomepageLocation) to locate across hives.

.PARAMETER OutputPath
    Folder for the CSV report. Default: current directory.

.EXAMPLE
    .\Get-EdgePolicySourceAudit.ps1
    Full snapshot to EdgePolicySourceAudit_<computer>_<timestamp>.csv.

.EXAMPLE
    .\Get-EdgePolicySourceAudit.ps1 -PolicyName ExtensionInstallForcelist -OutputPath C:\Temp
    Also reports every location that sets ExtensionInstallForcelist.

.NOTES
    Requires : Windows PowerShell 5.1 or PowerShell 7 on Windows.
    Run-as   : The affected user (HKCU is per-user). Admin not required; gpresult computer scope may need admin.
    Safety   : Read-only. The enrollment token value is never written to screen or CSV.
#>
[CmdletBinding()]
param(
    [string]$PolicyName,
    [string]$OutputPath = (Get-Location).Path
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row {
    param([string]$Category, [string]$Location, [string]$Name, $Value, [string]$Status, [string]$Note)
    $rows.Add([pscustomobject]@{
        Category = $Category; Location = $Location; Name = $Name; Value = [string]$Value; Status = $Status; Note = $Note
    })
}

function Get-RegValues {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $item = Get-ItemProperty -Path $Path
    return @($item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' })
}

# ---------- Preflight ----------
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Write-Status "This script reads the Windows registry and must run on Windows." "ERROR"; return
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

# ---------- Detect: Edge version ----------
$exe = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
         "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($exe) {
    $verStr = (Get-Item $exe).VersionInfo.ProductVersion
    $ok = $false
    try { $ok = ([version]$verStr -ge [version]'115.0.1901.7') } catch { $ok = $false }
    Add-Row 'Edge' $exe 'Version' $verStr $(if ($ok) { 'OK' } else { 'WARN' }) 'Edge management service requires 115.0.1901.7+'
    Write-Status "Edge version $verStr" $(if ($ok) { 'OK' } else { 'WARN' })
} else {
    Add-Row 'Edge' '' 'Version' '' 'ERROR' 'msedge.exe not found in Program Files'
    Write-Status "Edge executable not found" "ERROR"
}

# ---------- Detect: management switches + platform policy ----------
$switches = 'EdgeManagementEnabled', 'EdgeManagementEnrollmentToken',
            'EdgeManagementPolicyOverridesPlatformPolicy', 'EdgeManagementUserPolicyOverridesCloudMachinePolicy'
$hives = [ordered]@{
    'HKLM mandatory'   = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    'HKCU mandatory'   = 'HKCU:\SOFTWARE\Policies\Microsoft\Edge'
    'HKLM recommended' = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\Recommended'
    'HKCU recommended' = 'HKCU:\SOFTWARE\Policies\Microsoft\Edge\Recommended'
}
$platformCount = 0
foreach ($h in $hives.Keys) {
    $vals = Get-RegValues $hives[$h]
    foreach ($v in $vals) {
        if ($switches -contains $v.Name) {
            switch ($v.Name) {
                'EdgeManagementEnabled' {
                    $st = if ([int]$v.Value -eq 0) { 'WARN' } else { 'OK' }
                    Add-Row 'Switch' $h $v.Name $v.Value $st '0 = Edge never contacts the Edge management service'
                }
                'EdgeManagementEnrollmentToken' {
                    Add-Row 'Switch' $h $v.Name '<present - redacted>' 'INFO' 'Device-scope cloud policy delivered by policy ID'
                }
                default {
                    $st = if ([int]$v.Value -eq 1) { 'WARN' } else { 'INFO' }
                    Add-Row 'Switch' $h $v.Name $v.Value $st 'Precedence override is active - changes the default ranking'
                }
            }
        } else {
            $platformCount++
            $val = if ($v.Value -is [array]) { ($v.Value -join ';') } else { $v.Value }
            Add-Row 'PlatformPolicy' $h $v.Name $val 'INFO' 'GPO/MDM/manual - beats Edge management service by default'
        }
    }
    # List-type policies (e.g. ExtensionInstallForcelist) are subkeys with numbered values
    if (Test-Path $hives[$h]) {
        foreach ($sub in Get-ChildItem $hives[$h] -ErrorAction SilentlyContinue | Where-Object PSChildName -ne 'Recommended') {
            $items = Get-RegValues $sub.PSPath
            $platformCount++
            Add-Row 'PlatformPolicy' $h $sub.PSChildName (($items | ForEach-Object { $_.Value }) -join ';') 'INFO' 'List policy (subkey)'
        }
    }
}
if (-not ($rows | Where-Object { $_.Category -eq 'Switch' -and $_.Name -eq 'EdgeManagementEnabled' })) {
    Add-Row 'Switch' '(not set)' 'EdgeManagementEnabled' '' 'OK' 'Not configured = enabled by default on Edge 115.1935+'
}
Write-Status "Platform (registry) Edge policies found: $platformCount"

# ---------- Detect: MDM heuristic ----------
$pm = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device'
$mdmAreas = @()
if (Test-Path $pm) {
    $mdmAreas = @(Get-ChildItem $pm -ErrorAction SilentlyContinue | Where-Object PSChildName -match 'edge')
}
foreach ($a in $mdmAreas) {
    Add-Row 'MDM' $pm $a.PSChildName (@(Get-RegValues $a.PSPath).Count) 'INFO' 'Heuristic: MDM (Intune) area with Edge in its name; value = setting count'
}
Write-Status ("MDM Edge policy areas (heuristic): {0}" -f $mdmAreas.Count)

# ---------- Detect: GPO hint ----------
try {
    $gp = & gpresult /r /scope computer 2>$null | Out-String
    $applied = if ($gp -match 'Applied Group Policy Objects\s*[-]+\s*([\s\S]*?)\r?\n\s*\r?\n') { ($Matches[1] -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ';' } else { '' }
    Add-Row 'GPO' 'gpresult /scope computer' 'AppliedGPOs' $applied 'INFO' 'Hint only - confirm which GPO sets Edge policy with gpresult /h'
} catch {
    Add-Row 'GPO' 'gpresult' 'AppliedGPOs' '' 'WARN' "gpresult failed: $($_.Exception.Message)"
}

# ---------- Execute: locate a single policy ----------
if ($PolicyName) {
    $hits = @($rows | Where-Object { $_.Name -eq $PolicyName })
    if ($hits.Count -eq 0) {
        Write-Status "'$PolicyName' is not set in any registry hive. If edge://policy shows it, it comes from the Edge management service (cloud)." "WARN"
        Add-Row 'Lookup' '' $PolicyName '' 'WARN' 'Not in registry - cloud-delivered or not set'
    } else {
        foreach ($hit in $hits) { Write-Status "'$PolicyName' set in $($hit.Location) = $($hit.Value)" "OK" }
        if ($hits.Count -gt 1) { Write-Status "'$PolicyName' is set in more than one location - expect a conflict/precedence question." "WARN" }
    }
}

# ---------- Validate / Report ----------
foreach ($r in $rows | Where-Object Status -in 'WARN', 'ERROR') {
    Write-Status ("{0} {1} [{2}] = {3} - {4}" -f $r.Category, $r.Name, $r.Location, $r.Value, $r.Note) $r.Status
}
$csv = Join-Path $OutputPath ("EdgePolicySourceAudit_{0}_{1:yyyyMMdd_HHmmss}.csv" -f $env:COMPUTERNAME, (Get-Date))
$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "Report: $csv" "OK"
Write-Status "Next: open edge://policy, click 'Reload policies', and compare the Source column against this report."
