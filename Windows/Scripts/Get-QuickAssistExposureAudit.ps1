<#
.SYNOPSIS
    Audits a Windows device's Quick Assist exposure (installed/provisioned/legacy/running/blocked/reachable) and can optionally remove it.

.DESCRIPTION
    Quick Assist has no admin policy surface (no CSP/ADMX), so exposure has to be measured directly on the device.
    This script checks:
      - Store app (MicrosoftCorporationII.QuickAssist) installed for any user
      - Store app provisioned for new user profiles
      - Legacy inbox capability (App.Support.QuickAssist*) on older Windows 10 builds
      - Whether QuickAssist.exe is running right now (possible live session)
      - Last-run evidence from Prefetch
      - Effective AppLocker packaged-app (Appx) collection: enforcement mode, default allow rule present, QuickAssist deny present
      - DNS resolution + TCP 443 to the session broker (remoteassistance.support.services.microsoft.com)
      - hosts-file sinkhole entries for the broker
      - Whether Intune Remote Help is installed (the broker endpoint is shared - network blocking would break it)
    It produces a verdict (Exposed / Blocked / Removed / Mixed) and exports a CSV.

    With -Remove it uninstalls the Store app for all users, deprovisions it, and removes the legacy capability.
    Removal honours -WhatIf / -Confirm. It does NOT create AppLocker/WDAC rules or network blocks.

    Does not cover: Windows Remote Assistance (msra.exe), Quick Assist for macOS, tenant-side Remote Help settings.

.PARAMETER OutputPath
    Folder for the CSV report. Default: C:\Temp

.PARAMETER Remove
    Remove Quick Assist (Store app all users + provisioned + legacy capability). Supports -WhatIf.

.PARAMETER SkipNetwork
    Skip DNS/TCP tests (useful on isolated devices).

.EXAMPLE
    .\Get-QuickAssistExposureAudit.ps1
    Audit only, CSV to C:\Temp.

.EXAMPLE
    .\Get-QuickAssistExposureAudit.ps1 -Remove -WhatIf
    Show what would be removed without changing anything.

.EXAMPLE
    .\Get-QuickAssistExposureAudit.ps1 -Remove -Confirm:$false -OutputPath D:\Reports
    Remove all Quick Assist variants unattended (e.g. from an RMM job) and write the report to D:\Reports.

.NOTES
    Requires: Windows 10/11, Windows PowerShell 5.1+, run elevated (AllUsers AppX queries, provisioning and capability cmdlets need admin).
    Safe: audit mode is read-only. -Remove is destructive but reversible (reinstall from Store ID 9P7BP5VNWKX5).
    Reference: https://learn.microsoft.com/windows/client-management/client-tools/quick-assist
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$OutputPath = 'C:\Temp',
    [switch]$Remove,
    [switch]$SkipNetwork
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$PackageName = 'MicrosoftCorporationII.QuickAssist'
$BrokerFqdn  = 'remoteassistance.support.services.microsoft.com'
$results     = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Check, [string]$Value, [string]$Status, [string]$Note = '')
    $results.Add([pscustomobject]@{
        Computer = $env:COMPUTERNAME; Check = $Check; Value = $Value; Status = $Status; Note = $Note
        Timestamp = (Get-Date).ToString('s')
    })
    Write-Status "$Check : $Value $(if ($Note) { "- $Note" })" $Status
}

# ---------------- Preflight ----------------
Write-Status "Quick Assist exposure audit on $env:COMPUTERNAME"
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$ubr = if ($cv.PSObject.Properties['UBR']) { $cv.UBR } else { 0 }
$display = if ($cv.PSObject.Properties['DisplayVersion']) { $cv.DisplayVersion } else { $cv.ReleaseId }
Add-Result 'OSBuild' "$($cv.ProductName) $display $($cv.CurrentBuild).$ubr" 'INFO'

# ---------------- Detect ----------------
function Get-QAState {
    $s = [ordered]@{ AppX = @(); Provisioned = @(); Capability = $null }
    try { $s.AppX = @(Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction Stop) } catch { Write-Status "Get-AppxPackage failed: $($_.Exception.Message)" 'WARN' }
    try { $s.Provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $PackageName }) } catch { Write-Status "Get-AppxProvisionedPackage failed: $($_.Exception.Message)" 'WARN' }
    try { $s.Capability = Get-WindowsCapability -Online -Name 'App.Support.QuickAssist*' -ErrorAction Stop | Select-Object -First 1 } catch { $s.Capability = $null }
    [pscustomobject]$s
}

$state = Get-QAState
if ($state.AppX.Count -gt 0) {
    $ver = ($state.AppX | Select-Object -ExpandProperty Version -Unique) -join ','
    Add-Result 'StoreAppInstalled' "Yes ($ver)" 'WARN' 'Installed for one or more users'
} else { Add-Result 'StoreAppInstalled' 'No' 'OK' }

if ($state.Provisioned.Count -gt 0) { Add-Result 'StoreAppProvisioned' 'Yes' 'WARN' 'New profiles will receive Quick Assist' }
else { Add-Result 'StoreAppProvisioned' 'No' 'OK' }

$capInstalled = $false
if ($state.Capability) {
    $capInstalled = ($state.Capability.State -eq 'Installed')
    Add-Result 'LegacyCapability' "$($state.Capability.Name) = $($state.Capability.State)" $(if ($capInstalled) {'WARN'} else {'OK'})
} else { Add-Result 'LegacyCapability' 'Not applicable on this build' 'OK' }

$proc = @(Get-Process -Name QuickAssist -ErrorAction SilentlyContinue)
if ($proc.Count -gt 0) {
    $start = ($proc | ForEach-Object { try { $_.StartTime.ToString('s') } catch { 'unknown' } }) -join ','
    Add-Result 'RunningNow' "Yes (started $start)" 'ERROR' 'Live session possible - confirm the user initiated it with IT'
} else { Add-Result 'RunningNow' 'No' 'OK' }

$pf = @(Get-ChildItem "$env:windir\Prefetch\QUICKASSIST.EXE-*.pf" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($pf.Count -gt 0) { Add-Result 'PrefetchLastRun' $pf[0].LastWriteTime.ToString('s') 'INFO' 'Approximate last execution' }
else { Add-Result 'PrefetchLastRun' 'None found' 'INFO' 'Prefetch may be disabled (e.g. SSD/VM policy)' }

# AppLocker packaged-app collection
$appxMode = 'NotConfigured'; $hasDefaultAllow = $false; $hasQADeny = $false
try {
    [xml]$al = Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop
    $coll = @($al.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq 'Appx' })
    if ($coll.Count -gt 0) {
        $appxMode = [string]$coll[0].EnforcementMode
        foreach ($r in @($coll[0].ChildNodes)) {
            $inner = $r.OuterXml
            if ($r.Action -eq 'Allow' -and $inner -match 'PublisherName="\*"' ) { $hasDefaultAllow = $true }
            if ($r.Action -eq 'Deny'  -and $inner -match 'QUICKASSIST') { $hasQADeny = $true }
        }
    }
} catch { Write-Status "AppLocker policy read failed: $($_.Exception.Message)" 'WARN' }
Add-Result 'AppLockerAppxMode' $appxMode 'INFO'
if ($hasQADeny) {
    $st = if ($appxMode -eq 'Enabled') {'OK'} else {'WARN'}
    Add-Result 'AppLockerQuickAssistDeny' 'Present' $st $(if ($appxMode -ne 'Enabled') {'Rule exists but collection is not enforced'})
} else { Add-Result 'AppLockerQuickAssistDeny' 'Absent' 'INFO' }
if ($appxMode -eq 'Enabled' -and -not $hasDefaultAllow) {
    Add-Result 'AppLockerDefaultAllow' 'Missing' 'ERROR' 'Enforced Appx collection without a default allow rule blocks all packaged apps'
}
$appId = Get-Service AppIDSvc -ErrorAction SilentlyContinue
if ($appId) { Add-Result 'AppIDSvc' "$($appId.Status)/$($appId.StartType)" $(if ($hasQADeny -and $appId.Status -ne 'Running') {'WARN'} else {'INFO'}) }

# Remote Help coexistence
$rh = Test-Path "$env:ProgramFiles\Remote Help\RemoteHelp.exe"
Add-Result 'RemoteHelpInstalled' $(if ($rh) {'Yes'} else {'No'}) 'INFO' $(if ($rh) {'Do NOT block the broker endpoint - it is shared with Remote Help'})

# Network
$brokerReachable = $null
if (-not $SkipNetwork) {
    $hostsHit = Select-String -Path "$env:windir\System32\drivers\etc\hosts" -Pattern ([regex]::Escape($BrokerFqdn)) -ErrorAction SilentlyContinue |
                Where-Object { $_.Line -notmatch '^\s*#' }
    if ($hostsHit) { Add-Result 'HostsFileEntry' ($hostsHit.Line.Trim() -join '; ') 'WARN' 'Broker overridden in hosts file' }
    try {
        $dns = Resolve-DnsName $BrokerFqdn -ErrorAction Stop | Where-Object { $_.PSObject.Properties['IPAddress'] } | Select-Object -ExpandProperty IPAddress
        $dnsTxt = ($dns -join ',')
        $sink = $dns | Where-Object { $_ -in @('0.0.0.0','127.0.0.1','::','::1') }
        Add-Result 'BrokerDNS' $dnsTxt $(if ($sink) {'WARN'} else {'OK'}) $(if ($sink) {'Sinkholed'})
    } catch { Add-Result 'BrokerDNS' 'Resolution failed' 'WARN' $_.Exception.Message }
    try {
        $tnc = Test-NetConnection $BrokerFqdn -Port 443 -WarningAction SilentlyContinue
        $brokerReachable = [bool]$tnc.TcpTestSucceeded
        Add-Result 'BrokerTCP443' $brokerReachable 'INFO'
    } catch { Add-Result 'BrokerTCP443' 'Test failed' 'WARN' $_.Exception.Message }
}

# ---------------- Execute (optional removal) ----------------
if ($Remove) {
    if ($state.AppX.Count -gt 0 -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Remove $PackageName for all users")) {
        try { $state.AppX | Remove-AppxPackage -AllUsers -ErrorAction Stop; Write-Status 'Store app removed for all users' 'OK' }
        catch { Write-Status "Remove-AppxPackage failed: $($_.Exception.Message)" 'ERROR' }
    }
    if ($state.Provisioned.Count -gt 0 -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Deprovision $PackageName")) {
        try { $state.Provisioned | Remove-AppxProvisionedPackage -Online -ErrorAction Stop | Out-Null; Write-Status 'Provisioned package removed' 'OK' }
        catch { Write-Status "Remove-AppxProvisionedPackage failed: $($_.Exception.Message)" 'ERROR' }
    }
    if ($capInstalled -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Remove capability $($state.Capability.Name)")) {
        try { Remove-WindowsCapability -Online -Name $state.Capability.Name -ErrorAction Stop | Out-Null; Write-Status 'Legacy capability removed' 'OK' }
        catch { Write-Status "Remove-WindowsCapability failed: $($_.Exception.Message)" 'ERROR' }
    }
    # ---------------- Validate ----------------
    if (-not $WhatIfPreference) {
        $after = Get-QAState
        $capAfter = if ($after.Capability) { $after.Capability.State } else { 'n/a' }
        Add-Result 'PostRemoval' "AppX=$($after.AppX.Count) Provisioned=$($after.Provisioned.Count) Capability=$capAfter" $(if ($after.AppX.Count -eq 0 -and $after.Provisioned.Count -eq 0 -and $capAfter -ne 'Installed') {'OK'} else {'WARN'})
        $state = $after; $capInstalled = ($capAfter -eq 'Installed')
    }
}

# ---------------- Report ----------------
$present = ($state.AppX.Count -gt 0) -or ($state.Provisioned.Count -gt 0) -or $capInstalled
$blocked = ($hasQADeny -and $appxMode -eq 'Enabled') -or ($brokerReachable -eq $false)
$verdict = if (-not $present -and $blocked) { 'Removed+Blocked' }
           elseif (-not $present)           { 'Removed (reinstall not blocked)' }
           elseif ($blocked)                { 'Present but Blocked' }
           else                             { 'Exposed' }
Add-Result 'Verdict' $verdict $(switch -Wildcard ($verdict) { 'Exposed' {'ERROR'} 'Removed (*' {'WARN'} 'Present*' {'WARN'} default {'OK'} })

$csv = Join-Path $OutputPath ("QuickAssistExposure_{0}_{1}.csv" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "Report written: $csv" 'OK'
