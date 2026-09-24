<#
.SYNOPSIS
    Read-only readiness audit for the 2026 Microsoft Graph PowerShell SDK changes on a host and/or a script folder.

.DESCRIPTION
    Covers three changes (see EntraID/Graph/GraphPowerShellSDK-A.md):
      1. Service-side cut-off of interactive-browser delegated auth for SDK versions < 2.36.1
         (default Microsoft Graph Command Line Tools app). App-only and device code unaffected.
      2. WAM as default interactive broker on Windows since v2.34 (DisableLoginByWAM honoured only
         with your own -ClientId on >= 2.35.1).
      3. Windows PowerShell 5.x retirement period for Graph modules from 16 Sep 2026; v3 (Q4 CY2026)
         supports PowerShell 7.x only.

    Host checks:
      - PowerShell editions present (Windows PowerShell 5.1, pwsh 7.x) and current edition.
      - Every Microsoft.Graph.Authentication / Microsoft.Graph.Beta.* / Microsoft.Graph.* version found
        in all known module paths for BOTH editions, flagging < 2.36.1 and side-by-side versions.
      - ExchangeOnlineManagement / MicrosoftTeams / Az.Accounts versions (MSAL co-load risk).
      - Scheduled tasks whose action runs powershell.exe (Windows PowerShell 5.1) — Windows only.
    Script corpus checks (-ScanPath):
      - Every .ps1/.psm1 containing Connect-MgGraph, classified by auth pattern
        (AppOnly-Cert, AppOnly-Secret, ManagedIdentity, AccessToken, DeviceCode,
         Interactive-OwnApp, Interactive-DefaultApp).
      - '#Requires -PSEdition Desktop', '-UseWindowsPowerShell', '-RequiredVersion 2.x' pins below 2.36.1.

    Does NOT: install, update or remove modules; change tasks; connect to any tenant.

.PARAMETER ScanPath
    Optional folder(s) to scan recursively for scripts that use the Graph SDK.

.PARAMETER SkipScheduledTasks
    Skip the scheduled-task inventory (e.g. non-admin session or non-Windows host).

.PARAMETER OutputPath
    CSV output path. Default: .\GraphSDK-Readiness-<computer>-<timestamp>.csv

.EXAMPLE
    .\Get-GraphSDKReadinessAudit.ps1

.EXAMPLE
    .\Get-GraphSDKReadinessAudit.ps1 -ScanPath 'D:\Scripts','\\fileserver\msp-automation' -OutputPath C:\Temp\graphsdk.csv

.NOTES
    Runs on Windows PowerShell 5.1 and PowerShell 7.x (Windows, macOS, Linux; Windows-only checks skip elsewhere).
    Run as admin to see all users' scheduled tasks and AllUsers module paths reliably.
    Safety: read-only.
    Related: EntraID/Graph/GraphPowerShellSDK-B.md, EntraID/Graph/GraphPowerShellSDK-A.md
#>
[CmdletBinding()]
param(
    [string[]]$ScanPath,
    [switch]$SkipScheduledTasks,
    [string]$OutputPath = (Join-Path $PWD ("GraphSDK-Readiness-{0}-{1}.csv" -f [Environment]::MachineName, (Get-Date -Format yyyyMMdd-HHmm)))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Area, [string]$Item, [string]$Value, [string]$Status, [string]$Note, [string]$Path = '')
    $results.Add([pscustomobject]@{
        Computer = [Environment]::MachineName; Area = $Area; Item = $Item; Value = $Value
        Status = $Status; Note = $Note; Path = $Path })
    Write-Status "$Area | $Item | $Value $(if ($Note) { "— $Note" })" $Status
}

$minInteractive = [version]'2.36.1'
$minDisableWam  = [version]'2.35.1'
$isWindowsHost  = ($PSVersionTable.PSVersion.Major -le 5) -or ((Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)

# ---------------- Preflight / host ----------------
Add-Finding 'Host' 'Current edition' ("{0} {1}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion) `
    $(if ($PSVersionTable.PSEdition -eq 'Desktop') {'WARN'} else {'OK'}) `
    $(if ($PSVersionTable.PSEdition -eq 'Desktop') {'Windows PowerShell 5.1 — Graph retirement period from 16 Sep 2026; v3 will not support it'} else {''})

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshCmd -and $isWindowsHost) {
    $candidate = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path $candidate) { $pwshCmd = Get-Item $candidate }
}
if ($pwshCmd) {
    $pwshPath = if ($pwshCmd -is [System.Management.Automation.CommandInfo]) { $pwshCmd.Source } else { $pwshCmd.FullName }
    $pwshVer  = (Get-Item $pwshPath).VersionInfo.ProductVersion
    Add-Finding 'Host' 'PowerShell 7 installed' "$pwshVer" 'OK' '' $pwshPath
} else {
    Add-Finding 'Host' 'PowerShell 7 installed' 'No' $(if ($isWindowsHost) {'WARN'} else {'INFO'}) 'Install: winget install --id Microsoft.PowerShell --source winget'
}

# ---------------- Detect: module inventory across both editions ----------------
$paths = New-Object System.Collections.Generic.List[string]
foreach ($p in ($env:PSModulePath -split [IO.Path]::PathSeparator)) { if ($p) { $paths.Add($p) } }
if ($isWindowsHost) {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'PowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\Modules'),
        (Join-Path $docs 'WindowsPowerShell\Modules'),
        (Join-Path $docs 'PowerShell\Modules'))) { $paths.Add($p) }
}
$paths = @($paths | Where-Object { Test-Path $_ } | Sort-Object -Unique)

$graphVersions = @()
foreach ($root in $paths) {
    foreach ($name in @('Microsoft.Graph.Authentication', 'ExchangeOnlineManagement', 'MicrosoftTeams', 'Az.Accounts', 'Microsoft.Entra')) {
        $modDir = Join-Path $root $name
        if (-not (Test-Path $modDir)) { continue }
        foreach ($verDir in (Get-ChildItem $modDir -Directory -ErrorAction SilentlyContinue)) {
            $v = $null
            if (-not [version]::TryParse($verDir.Name, [ref]$v)) { continue }
            $edition = if ($root -match 'WindowsPowerShell') { 'Desktop(5.1) path' } elseif ($root -match '[\\/]PowerShell[\\/]') { 'Core(7) path' } else { 'Shared/other path' }
            if ($name -eq 'Microsoft.Graph.Authentication') {
                $graphVersions += $v
                $st = if ($v -lt $minInteractive) { 'ERROR' } else { 'OK' }
                $nt = if ($v -lt $minInteractive) { "< $minInteractive — interactive-browser delegated auth with default app will be blocked" }
                      elseif ($v -lt $minDisableWam) { 'DisableLoginByWAM not honoured on this version' } else { '' }
                Add-Finding 'Module' $name "$v" $st "$edition. $nt" $verDir.FullName
            } else {
                Add-Finding 'Module' $name "$v" 'INFO' "$edition (co-load MSAL risk with Graph in same session)" $verDir.FullName
            }
        }
    }
    # Count Graph submodule version spread (catches mismatched submodules)
    $sub = @(Get-ChildItem $root -Directory -Filter 'Microsoft.Graph.*' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue } |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } | Select-Object -ExpandProperty Name -Unique)
    if ($sub.Count -gt 1) {
        Add-Finding 'Module' 'Microsoft.Graph.* submodule versions' ($sub -join ', ') 'WARN' 'Multiple versions side by side in one path — assembly-load failures likely' $root
    }
}
$distinct = @($graphVersions | Sort-Object -Unique)
if ($distinct.Count -eq 0) {
    Add-Finding 'Module' 'Microsoft.Graph.Authentication' 'Not found' 'INFO' 'Graph SDK not installed in known paths'
} elseif ($distinct.Count -gt 1) {
    Add-Finding 'Module' 'Graph SDK distinct versions (all paths)' (($distinct | ForEach-Object { "$_" }) -join ', ') 'WARN' 'Standardise on one version >= 2.36.1 per edition'
} else {
    Add-Finding 'Module' 'Graph SDK distinct versions (all paths)' "$($distinct[0])" 'OK' ''
}

# ---------------- Detect: scheduled tasks on Windows PowerShell 5.1 ----------------
if ($isWindowsHost -and -not $SkipScheduledTasks) {
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        try {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
                @($_.Actions | Where-Object { ($_.PSObject.Properties.Name -contains 'Execute') -and ($_.Execute -match 'powershell(\.exe)?"?$') }).Count -gt 0 })
            foreach ($t in $tasks) {
                $taskArgs = (@($t.Actions | ForEach-Object { if ($_.PSObject.Properties.Name -contains 'Arguments') { $_.Arguments } }) -join ' ')
                $graphHint = $taskArgs -match 'Graph|Mg[A-Z]|Intune|Entra'
                Add-Finding 'ScheduledTask' "$($t.TaskPath)$($t.TaskName)" 'powershell.exe (5.1)' $(if ($graphHint) {'WARN'} else {'INFO'}) `
                    $(if ($graphHint) {'Arguments suggest Graph use — move to pwsh.exe'} else {'Runs on 5.1 — check script for Graph use'}) $taskArgs
            }
            if ($tasks.Count -eq 0) { Add-Finding 'ScheduledTask' 'powershell.exe tasks' '0' 'OK' '' }
        } catch {
            Add-Finding 'ScheduledTask' 'Enumeration' 'failed' 'WARN' $_.Exception.Message
        }
    }
}

# ---------------- Detect: script corpus ----------------
if ($ScanPath) {
    $files = foreach ($sp in $ScanPath) {
        if (Test-Path $sp) { Get-ChildItem -Path $sp -Recurse -File -Include *.ps1, *.psm1 -ErrorAction SilentlyContinue }
        else { Add-Finding 'Scan' 'Path' $sp 'WARN' 'Not found' }
    }
    $count = 0
    foreach ($f in @($files)) {
        $text = $null
        try { $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop } catch { continue }
        if (-not $text) { continue }
        if ($text -match '(?im)^\s*#Requires\s+-PSEdition\s+Desktop') {
            Add-Finding 'Script' '#Requires -PSEdition Desktop' $f.Name 'WARN' 'Pinned to Windows PowerShell 5.1' $f.FullName
        }
        if ($text -match '(?i)-UseWindowsPowerShell') {
            Add-Finding 'Script' '-UseWindowsPowerShell' $f.Name 'WARN' 'Uses 5.1 compatibility session' $f.FullName
        }
        foreach ($m in [regex]::Matches($text, '(?i)Microsoft\.Graph[\w\.]*[^\r\n]*-RequiredVersion\s+[''"]?(\d+\.\d+\.\d+)')) {
            $pv = [version]$m.Groups[1].Value
            if ($pv -lt $minInteractive) { Add-Finding 'Script' 'Graph RequiredVersion pin' "$pv" 'WARN' "Pinned below $minInteractive" $f.FullName }
        }
        $connects = [regex]::Matches($text, '(?im)^[^#\r\n]*Connect-MgGraph[^\r\n]*')
        foreach ($c in $connects) {
            $line = $c.Value
            $pattern =
                if ($line -match '(?i)-Identity\b') { 'ManagedIdentity' }
                elseif ($line -match '(?i)-Certificate(Thumbprint|Name)?\b') { 'AppOnly-Cert' }
                elseif ($line -match '(?i)-ClientSecretCredential\b') { 'AppOnly-Secret' }
                elseif ($line -match '(?i)-AccessToken\b') { 'AccessToken' }
                elseif ($line -match '(?i)-UseDeviceCode|-UseDeviceAuthentication|-DeviceCode') { 'DeviceCode' }
                elseif ($line -match '(?i)-ClientId\b|-AppId\b') { 'Interactive-OwnApp' }
                elseif ($line -match '(?i)^\s*Connect-MgGraph\s*@') { 'Splatted-Review' }
                else { 'Interactive-DefaultApp' }
            $looksAutomated = $f.FullName -match '(?i)task|schedule|runbook|automation|job|nightly|daily|rmm'
            $status = switch ($pattern) {
                'Interactive-DefaultApp' { if ($looksAutomated) { 'ERROR' } else { 'WARN' } }
                'AppOnly-Secret'         { 'WARN' }
                'Splatted-Review'        { 'WARN' }
                default                  { 'OK' }
            }
            $note = switch ($pattern) {
                'Interactive-DefaultApp' { 'Default Command Line Tools app: WAM forced on Windows; needs SDK >= 2.36.1' + $(if ($looksAutomated) { '; unattended use of delegated auth — convert to app-only' } else { '' }) }
                'AppOnly-Secret'         { 'Works; prefer certificate or managed identity' }
                'Splatted-Review'        { 'Parameters splatted — review manually' }
                default                  { '' }
            }
            Add-Finding 'Script' "Connect-MgGraph: $pattern" $f.Name $status $note $f.FullName
            $count++
        }
    }
    Add-Finding 'Scan' 'Connect-MgGraph calls found' "$count" 'INFO' ("Scanned {0} file(s)" -f @($files).Count)
}

# ---------------- Validate / Report ----------------
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
$err  = @($results | Where-Object Status -eq 'ERROR').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Done. ERROR=$err WARN=$warn. CSV: $OutputPath" $(if ($err) {'ERROR'} elseif ($warn) {'WARN'} else {'OK'})
