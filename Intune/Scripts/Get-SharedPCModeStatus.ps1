<#
.SYNOPSIS
    Read-only audit of Windows Shared PC mode, Account Manager thresholds, exemptions and profile-deletion readiness on one device.

.DESCRIPTION
    Run on a shared Windows 10/11 device. The script:
      - Checks the OS edition and build (Home is unsupported; build 22621+ is needed for EnableSharedPCModeWithOneDriveSync).
      - Reads SharedModeSettings.IsEnabled / ShouldAvoidLocalStorage through WinRT (if available).
      - Reads the effective values in HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\NodeValues and \AccountManagement.
      - If running as SYSTEM, also reads the desired CSP values from the MDM Bridge (root\cimv2\mdm\dmmap MDM_SharedPC)
        and flags any differences (the classic "changed after enablement" problem).
      - Computes system-drive free % against DiskLevelDeletion / DiskLevelCaching and says whether deletion should be active.
      - Lists non-special profiles with LastUseTime and marks each as exempt / local / eligible-for-deletion under the effective policy.
      - Resolves every exemption SID to an account name and flags SIDs that don't resolve.
      - Flags risky configurations: AccountModel 0 (guest-only), plain EnableSharedPCMode (OneDrive sync off), no Account Manager.
      - Scans SharedPCSetup.log for error/fail lines.
    Every finding goes to a CSV. With -CollectLogs, the registry export and setup log are also zipped.

    It changes nothing and deletes no profiles. It doesn't evaluate the LGPO settings Shared PC writes
    (see the Shared PC technical reference for those).

.PARAMETER OutputPath
    Folder for the CSV and optional zip. Default: C:\Temp\SharedPC-Status

.PARAMETER CollectLogs
    Export the SharedPC registry key and copy SharedPCSetup.log into a zip.

.EXAMPLE
    .\Get-SharedPCModeStatus.ps1

.EXAMPLE
    # As SYSTEM (for example an Intune remediation or psexec -s) to include the MDM Bridge desired-state comparison
    .\Get-SharedPCModeStatus.ps1 -CollectLogs

.NOTES
    Requires: Windows PowerShell 5.1, run elevated. SYSTEM context is optional (enables the MDM_SharedPC read).
    Safe: read-only.
    Sources: learn.microsoft.com/windows/client-management/mdm/sharedpc-csp; learn.microsoft.com/windows/configuration/shared-pc/set-up-shared-or-guest-pc
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\Temp\SharedPC-Status',
    [switch]$CollectLogs
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Area, [string]$Check, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString('s'); Device = $env:COMPUTERNAME
        Area = $Area; Check = $Check; Status = $Status; Detail = $Detail
    })
    Write-Status -Message "$Area | $Check : $Detail" -Status $Status
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($item -and $item.PSObject.Properties[$Name]) { return $item.$Name }
    return $null
}

# ---------------- Preflight ----------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC'
$isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
$edOk = $os.Caption -notmatch 'Home'
Add-Result 'Platform' 'OS' $(if ($edOk) {'OK'} else {'ERROR'}) "$($os.Caption) build $build$(if (-not $edOk) {' (Home edition does not support Shared PC)'})"
Add-Result 'Platform' 'Run context' 'INFO' $(if ($isSystem) {'SYSTEM (MDM Bridge read enabled)'} else {'Admin (MDM Bridge read skipped; run as SYSTEM for desired-state comparison)'})

# ---------------- Detect: live mode ----------------
$liveEnabled = $null
try {
    $null = [Windows.System.Profile.SharedModeSettings, Windows.System.Profile, ContentType = WindowsRuntime]
    $liveEnabled = [Windows.System.Profile.SharedModeSettings]::IsEnabled
    $avoidLocal = [Windows.System.Profile.SharedModeSettings]::ShouldAvoidLocalStorage
    Add-Result 'Mode' 'SharedModeSettings.IsEnabled' $(if ($liveEnabled) {'OK'} else {'WARN'}) "$liveEnabled (ShouldAvoidLocalStorage=$avoidLocal)"
} catch {
    Add-Result 'Mode' 'SharedModeSettings.IsEnabled' 'INFO' "WinRT query unavailable: $($_.Exception.Message). Falling back to registry."
}

# ---------------- Detect: effective values ----------------
$nvPath = Join-Path $base 'NodeValues'
$amPath = Join-Path $base 'AccountManagement'
$nodeNames = 'EnableSharedPCMode', 'EnableSharedPCModeWithOneDriveSync', 'EnableAccountManager', 'AccountModel', 'DeletionPolicy',
             'DiskLevelDeletion', 'DiskLevelCaching', 'InactiveThreshold', 'MaintenanceStartTime', 'SleepTimeout', 'SignInOnResume',
             'SetPowerPolicies', 'SetEduPolicies', 'RestrictLocalStorage', 'KioskModeAUMID', 'MaxPageFileSizeMB', 'EnableWindowsInsiderPreviewFlighting'
$effective = @{}
if (Test-Path $nvPath) {
    $nv = Get-ItemProperty $nvPath
    foreach ($p in $nv.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) { $effective[$p.Name] = $p.Value }
    Add-Result 'Effective' 'NodeValues' 'OK' (($effective.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ')
} else {
    Add-Result 'Effective' 'NodeValues' $(if ($liveEnabled) {'WARN'} else {'ERROR'}) 'Key not present: Shared PC setup has not run on this device'
}
if (Test-Path $amPath) {
    $am = Get-ItemProperty $amPath
    Add-Result 'Effective' 'AccountManagement' 'INFO' (($am.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ')
}

function Get-Eff { param([string]$Name, $Default) if ($effective.ContainsKey($Name)) { return $effective[$Name] } return $Default }
function ConvertTo-IntSafe {
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    $t = "$Value".Trim()
    if ($t -ieq 'true') { return 1 }
    if ($t -ieq 'false') { return 0 }
    $n = 0
    if ([int]::TryParse($t, [ref]$n)) { return $n }
    return $Default
}
$modePlain = (ConvertTo-IntSafe (Get-Eff 'EnableSharedPCMode' 0) 0)
$modeOD = (ConvertTo-IntSafe (Get-Eff 'EnableSharedPCModeWithOneDriveSync' 0) 0)
$acctMgr = (ConvertTo-IntSafe (Get-Eff 'EnableAccountManager' 0) 0)
$acctModel = Get-Eff 'AccountModel' $null
$delPolicy = (ConvertTo-IntSafe (Get-Eff 'DeletionPolicy' 1) 1)
$dlDel = (ConvertTo-IntSafe (Get-Eff 'DiskLevelDeletion' 25) 25)
$dlCache = (ConvertTo-IntSafe (Get-Eff 'DiskLevelCaching' 50) 50)
$inactive = (ConvertTo-IntSafe (Get-Eff 'InactiveThreshold' 30) 30)
$maint = (ConvertTo-IntSafe (Get-Eff 'MaintenanceStartTime' 0) 0)

# ---------------- Risk flags ----------------
if ($modePlain -and $modeOD) { Add-Result 'Config' 'Action nodes' 'WARN' 'Both EnableSharedPCMode and EnableSharedPCModeWithOneDriveSync set: use only one' }
elseif ($modePlain) { Add-Result 'Config' 'OneDrive' 'WARN' 'Plain EnableSharedPCMode: OneDrive sync is disabled. Use EnableSharedPCModeWithOneDriveSync on Win11 22621+.' }
elseif ($modeOD) {
    Add-Result 'Config' 'OneDrive' $(if ($build -ge 22621) {'OK'} else {'ERROR'}) $(if ($build -ge 22621) {'OneDrive-sync variant in use'} else {"OneDrive-sync variant requires build 22621+ (device is $build)"})
}
if ($null -ne $acctModel) {
    $am = ConvertTo-IntSafe $acctModel 0
    $amText = switch ($am) { 0 {'guest-only (CSP default): org users cannot use this device as intended'} 1 {'domain/Entra-joined accounts only'} 2 {'domain/Entra accounts + Guest'} default {"unknown value $am"} }
    Add-Result 'Config' 'AccountModel' $(if ($am -eq 0) {'WARN'} else {'OK'}) "$am = $amText"
}
if (($modePlain -or $modeOD) -and -not $acctMgr) {
    Add-Result 'Config' 'Account Manager' 'WARN' 'Shared PC mode on but EnableAccountManager is off: profiles are never cleaned up automatically'
} elseif ($acctMgr) {
    $polText = switch ($delPolicy) { 0 {'delete at sign-out'} 1 {'delete when disk below threshold'} 2 {'delete at disk threshold and after inactivity'} default {"unknown $delPolicy"} }
    Add-Result 'Config' 'Deletion policy' 'INFO' "$delPolicy = $polText; DiskLevelDeletion=$dlDel% DiskLevelCaching=$dlCache% InactiveThreshold=${inactive}d MaintenanceStart=$([TimeSpan]::FromMinutes($maint).ToString('hh\:mm'))"
    if ($dlDel -ge $dlCache) { Add-Result 'Config' 'Threshold sanity' 'WARN' "DiskLevelDeletion ($dlDel) >= DiskLevelCaching ($dlCache): hysteresis band inverted/empty" }
}

# ---------------- Desired state (MDM Bridge, SYSTEM only) ----------------
if ($isSystem) {
    try {
        $mdm = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_SharedPC' -ErrorAction Stop | Select-Object -First 1
        if ($mdm) {
            $diffs = @()
            foreach ($n in $nodeNames) {
                if ($mdm.PSObject.Properties[$n] -and $null -ne $mdm.$n -and "$($mdm.$n)" -ne '') {
                    $desired = $mdm.$n
                    if ($desired -is [bool]) { $desired = [int]$desired }
                    $eff = if ($effective.ContainsKey($n)) { $effective[$n] } else { '<absent>' }
                    if ("$desired" -ne "$eff") { $diffs += "$n desired=$desired effective=$eff" }
                }
            }
            if ($diffs) { Add-Result 'Desired' 'CSP vs NodeValues' 'WARN' "Mismatch (values changed after enablement? re-trigger action): $($diffs -join '; ')" }
            else { Add-Result 'Desired' 'CSP vs NodeValues' 'OK' 'Desired CSP values match effective NodeValues' }
        } else { Add-Result 'Desired' 'MDM_SharedPC' 'INFO' 'No instance (device not MDM-configured for Shared PC)' }
    } catch { Add-Result 'Desired' 'MDM_SharedPC' 'WARN' "Read failed: $($_.Exception.Message)" }
}

# ---------------- Disk band ----------------
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
$freePct = [math]::Round($disk.FreeSpace / $disk.Size * 100, 1)
$band = if ($freePct -lt ($dlDel / 2)) { "BELOW emergency level ($([math]::Round($dlDel/2,1))%): profiles deleted at sign-out" }
        elseif ($freePct -lt $dlDel) { 'Below DiskLevelDeletion: deletion active during maintenance' }
        elseif ($freePct -lt $dlCache) { 'In caching band: no disk-driven deletion (policy 2 inactivity deletion still possible)' }
        else { 'Above DiskLevelCaching: no disk-driven deletion' }
Add-Result 'Disk' "$env:SystemDrive free" $(if ($freePct -lt $dlDel) {'WARN'} else {'INFO'}) "$freePct% ($([math]::Round($disk.FreeSpace/1GB,1)) GB). $band"

# ---------------- Exemptions ----------------
$exPath = Join-Path $base 'Exemptions'
$exemptSids = @()
if (Test-Path $exPath) {
    foreach ($k in Get-ChildItem $exPath) {
        $sid = $k.PSChildName; $exemptSids += $sid
        try {
            $name = ([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount]).Value
            Add-Result 'Exemptions' $sid 'OK' $name
        } catch {
            Add-Result 'Exemptions' $sid 'WARN' 'SID does not resolve on this device (wrong SID, deleted account, or Entra user never signed in here)'
        }
    }
} else { Add-Result 'Exemptions' 'Exemptions key' 'INFO' 'None configured' }

# ---------------- Profiles ----------------
$localSids = @(Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object { $_.SID.Value })
$profiles = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special })
foreach ($p in $profiles) {
    $age = if ($p.LastUseTime) { [int]((Get-Date) - $p.LastUseTime).TotalDays } else { -1 }
    $class = if ($exemptSids -contains $p.SID) { 'Exempt' }
             elseif ($localSids -contains $p.SID) { 'Local account (never deleted by Shared PC)' }
             elseif (-not $acctMgr) { 'Org account (Account Manager off)' }
             elseif ($delPolicy -eq 0) { 'Org account (deleted at sign-out)' }
             elseif ($delPolicy -eq 2 -and $age -ge $inactive) { 'ELIGIBLE: inactive beyond threshold' }
             elseif ($freePct -lt $dlDel) { 'ELIGIBLE: disk below deletion threshold (oldest first)' }
             else { 'Cached (not currently eligible)' }
    Add-Result 'Profile' $p.LocalPath 'INFO' "SID=$($p.SID) Loaded=$($p.Loaded) LastUse=$(if ($p.LastUseTime) {$p.LastUseTime.ToString('yyyy-MM-dd')} else {'n/a'}) AgeDays=$age -> $class"
}
Add-Result 'Profile' 'Count' 'INFO' "$($profiles.Count) non-special profiles"

# ---------------- Setup log ----------------
$log = Join-Path $env:WINDIR 'SharedPCSetup.log'
if (Test-Path $log) {
    $errs = @(Select-String -Path $log -Pattern 'error', 'fail' -ErrorAction SilentlyContinue | Select-Object -Last 5)
    Add-Result 'Log' 'SharedPCSetup.log' $(if ($errs.Count) {'WARN'} else {'OK'}) $(if ($errs.Count) { ($errs | ForEach-Object { $_.Line.Trim() }) -join ' || ' } else { "No error/fail lines (last write $((Get-Item $log).LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" })
} else {
    Add-Result 'Log' 'SharedPCSetup.log' 'INFO' 'Not present (setup has never run on this device)'
}

# ---------------- Report ----------------
$csv = Join-Path $OutputPath "SharedPC-Status-$env:COMPUTERNAME-$stamp.csv"
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "Results: $csv" 'OK'

if ($CollectLogs) {
    $bundle = Join-Path $OutputPath "SharedPC-Logs-$env:COMPUTERNAME-$stamp"
    New-Item -Path $bundle -ItemType Directory -Force | Out-Null
    & reg.exe export 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC' (Join-Path $bundle 'SharedPC.reg') /y | Out-Null
    if (Test-Path $log) { Copy-Item $log $bundle }
    Copy-Item $csv $bundle
    Compress-Archive -Path "$bundle\*" -DestinationPath "$bundle.zip" -Force
    Write-Status "Log bundle: $bundle.zip" 'OK'
}

$e = @($results | Where-Object Status -eq 'ERROR').Count
$w = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Summary: $e error(s), $w warning(s). See SharedPC-B.md triage table." $(if ($e) {'ERROR'} elseif ($w) {'WARN'} else {'OK'})
