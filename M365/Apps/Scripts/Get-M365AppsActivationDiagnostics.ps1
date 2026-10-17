<#
.SYNOPSIS
    Read-only Microsoft 365 Apps (Click-to-Run) activation and licensing diagnostics for the current user and device.

.DESCRIPTION
    Collects the facts needed to triage "Unlicensed Product", "Product Deactivated", "Subscription expired",
    sign-in loops and Shared Computer Activation (SCA) problems on Microsoft 365 Apps for enterprise/business:

      - Click-to-Run install: ProductReleaseIds, version, platform, SCA value (C2R config + policy), token override path
      - Host type heuristic (multi-session / RDSH role) vs SCA state -> mismatch warnings
      - Per-user vNext licence files (%LOCALAPPDATA%\Microsoft\Office\Licenses) and SCA tokens (16.0\Licensing) with age
      - Cached Office identities (HKCU ...\Common\Identity\Identities) - flags multiple identities / MSA / unexpected domain
      - Device identity via dsregcmd (AzureAdJoined, DomainJoined, AzureAdPrt, TenantName)
      - Microsoft.AAD.BrokerPlugin registration
      - Legacy unsupported ADAL/WAM override registry values
      - TCP 443 reachability of licensing/identity endpoints, WinHTTP proxy
      - Recent Microsoft-Windows-AAD/Operational errors
      - Optional: server-side licence check through Microsoft Graph (-ExpectedUpn with -CheckGraph)

    It does NOT change anything: no reset, no registry writes, no sign-out. Use the playbooks in
    M365/Apps/Activation-A.md / Activation-B.md for remediation.
    Does not cover volume-licensed Office LTSC/2019/2021 (KMS/MAK) or Office for Mac.

.PARAMETER ExpectedUpn
    UPN the user should be signed in to Office with. Used to flag identity mismatches. Optional.

.PARAMETER CheckGraph
    Also query Microsoft Graph for the ExpectedUpn's Apps service-plan status. Requires the
    Microsoft.Graph.Users module and consent for User.Read.All. Interactive sign-in.

.PARAMETER LicenceAgeWarnDays
    Warn when the newest licence/token file is older than this many days. Default 30.

.PARAMETER OutputPath
    Folder for the CSV report. Default: $env:TEMP.

.EXAMPLE
    .\Get-M365AppsActivationDiagnostics.ps1
    Runs device + current-user checks and writes a CSV to %TEMP%.

.EXAMPLE
    .\Get-M365AppsActivationDiagnostics.ps1 -ExpectedUpn alex@contoso.com -CheckGraph -OutputPath C:\Temp
    Adds identity-mismatch detection and a Graph licence check.

.NOTES
    Run as the AFFECTED USER (licences and identities are per-user). No elevation required.
    Windows PowerShell 5.1 or PowerShell 7. Safe / read-only.
#>
[CmdletBinding()]
param(
    [string]$ExpectedUpn,
    [switch]$CheckGraph,
    [ValidateRange(1,365)][int]$LicenceAgeWarnDays = 30,
    [string]$OutputPath = $env:TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Area, [string]$Check, [string]$Value, [string]$Status = "INFO", [string]$Advice = "")
    $results.Add([pscustomobject]@{
        Computer = $env:COMPUTERNAME; User = $env:USERNAME; Area = $Area; Check = $Check
        Value = $Value; Status = $Status; Advice = $Advice
    })
    $msg = "{0} / {1}: {2}" -f $Area, $Check, $Value
    if ($Advice) { $msg += "  -> $Advice" }
    Write-Status $msg $Status
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -ErrorAction Stop
        if ($item.PSObject.Properties.Name -contains $Name) { return [string]$item.$Name }
    } catch { }
    return $null
}

# ---------------- Preflight ----------------
Write-Status "M365 Apps activation diagnostics - $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME"
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

$c2rPath = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
if (-not (Test-Path $c2rPath)) {
    Add-Result 'Install' 'Click-to-Run' 'Not found' 'ERROR' 'No Click-to-Run Microsoft 365 Apps install detected (MSI/volume Office is out of scope)'
} else {
    # ---------------- Detect: install ----------------
    $products = Get-RegValue $c2rPath 'ProductReleaseIds'
    $version  = Get-RegValue $c2rPath 'VersionToReport'
    $platform = Get-RegValue $c2rPath 'Platform'
    Add-Result 'Install' 'ProductReleaseIds' $products
    Add-Result 'Install' 'Version/Platform' ("{0} / {1}" -f $version, $platform)

    $scaC2r    = Get-RegValue $c2rPath 'SharedComputerLicensing'
    $polPath   = 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Licensing'
    $scaPolicy = Get-RegValue $polPath 'SharedComputerLicensing'
    $scaOn = ($scaC2r -eq '1') -or ($scaPolicy -eq '1')
    Add-Result 'Mode' 'SharedComputerLicensing (C2R / Policy)' ("{0} / {1}" -f ($(if ($null -eq $scaC2r) {'<unset>'} else {$scaC2r})), ($(if ($null -eq $scaPolicy) {'<unset>'} else {$scaPolicy})))

    $tokOverride = Get-RegValue $polPath 'SCLCacheOverride'
    $tokDir      = Get-RegValue $polPath 'SCLCacheOverrideDirectory'
    if ($tokOverride -eq '1' -and $tokDir) {
        $exp = [Environment]::ExpandEnvironmentVariables($tokDir)
        $st = if (Test-Path $exp) { 'OK' } else { 'WARN' }
        Add-Result 'Mode' 'SCA token override directory' $exp $st $(if ($st -eq 'WARN') {'Override path not reachable - tokens cannot be written/read'} else {''})
    }

    # Host type heuristic
    $multiSession = $false
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        if ($os.Caption -match 'multi-session|Server') { $multiSession = $true }
        Add-Result 'Host' 'OS' $os.Caption
    } catch { Add-Result 'Host' 'OS' 'Unable to query' 'WARN' }
    $rdsh = $null
    try { $rdsh = Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_TerminalServiceSetting -ErrorAction Stop } catch { }
    if ($rdsh -and ($rdsh.PSObject.Properties.Name -contains 'TerminalServerMode') -and $rdsh.TerminalServerMode -eq 1) { $multiSession = $true }
    Add-Result 'Host' 'Multi-session host (heuristic)' ([string]$multiSession)

    if ($multiSession -and -not $scaOn) {
        Add-Result 'Mode' 'SCA fit' 'Multi-session host WITHOUT SCA' 'ERROR' 'Enable SCA (Activation-B Fix 4) and reset earlier per-user activations'
    } elseif (-not $multiSession -and $scaOn) {
        Add-Result 'Mode' 'SCA fit' 'SCA on a single-session device' 'WARN' 'Valid for shared kiosks/labs; unexpected on a personal laptop'
    } else {
        Add-Result 'Mode' 'SCA fit' 'Consistent with host type' 'OK'
    }
    if ($scaPolicy -eq '1' -and $products -match 'O365BusinessRetail') {
        Add-Result 'Mode' 'SCA via GPO on Business SKU' 'Policy-based SCA with O365BusinessRetail' 'WARN' 'GPO path documented as not applicable to M365 Apps for business - use C2R registry/ODT'
    }
}

# ---------------- Detect: per-user licence state ----------------
$now = Get-Date
$licDirs = @(
    @{ Name = 'vNext licences'; Path = Join-Path $env:LOCALAPPDATA 'Microsoft\Office\Licenses' },
    @{ Name = 'SCA tokens / legacy Licensing'; Path = Join-Path $env:LOCALAPPDATA 'Microsoft\Office\16.0\Licensing' }
)
$anyLicence = $false
foreach ($d in $licDirs) {
    if (Test-Path $d.Path) {
        $files = @(Get-ChildItem -Path $d.Path -Recurse -File -ErrorAction SilentlyContinue)
        if ($files.Count -gt 0) {
            $anyLicence = $true
            $newest = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
            $age = [math]::Round(($now - $newest).TotalDays, 1)
            $st = if ($age -gt $LicenceAgeWarnDays) { 'WARN' } else { 'OK' }
            Add-Result 'Licence' $d.Name ("{0} file(s), newest {1:yyyy-MM-dd HH:mm} ({2} d)" -f $files.Count, $newest, $age) $st $(if ($st -eq 'WARN') {'Renewal may be failing - check network/identity'} else {''})
        } else {
            Add-Result 'Licence' $d.Name 'Folder present, empty'
        }
    } else {
        Add-Result 'Licence' $d.Name 'Folder not present'
    }
}
if (-not $anyLicence) { Add-Result 'Licence' 'Any licence on device for this user' 'None' 'WARN' 'User has not activated here (or state was reset) - check sign-in/identity' }

# ---------------- Detect: Office identities ----------------
$idPath = 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities'
$ids = @()
if (Test-Path $idPath) {
    $ids = @(Get-ChildItem $idPath -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        $email = if ($p -and ($p.PSObject.Properties.Name -contains 'EmailAddress')) { [string]$p.EmailAddress } else { '' }
        $prov  = if ($p -and ($p.PSObject.Properties.Name -contains 'ProviderId')) { [string]$p.ProviderId } else { '' }
        [pscustomobject]@{ Email = $email; Provider = $prov }
    })
}
if ($ids.Count -eq 0) {
    Add-Result 'Identity' 'Cached Office identities' 'None' 'WARN' 'User not signed in to Office'
} else {
    $list = ($ids | ForEach-Object { "{0} [{1}]" -f $_.Email, $_.Provider }) -join '; '
    $st = if ($ids.Count -gt 1) { 'WARN' } else { 'OK' }
    Add-Result 'Identity' 'Cached Office identities' $list $st $(if ($st -eq 'WARN') {'Multiple identities - confirm the licensed one is primary (File > Account)'} else {''})
    if ($ExpectedUpn) {
        $match = @($ids | Where-Object { $_.Email -ieq $ExpectedUpn })
        if ($match.Count -eq 0) { Add-Result 'Identity' 'Expected UPN signed in' "No identity for $ExpectedUpn" 'ERROR' 'Wrong account - Activation-B Fix 2/3' }
        else { Add-Result 'Identity' 'Expected UPN signed in' $ExpectedUpn 'OK' }
    }
}

# Legacy unsupported overrides
$legacy = @(
    @{ P = 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity'; N = 'EnableADAL' },
    @{ P = 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity'; N = 'DisableADALatopWAMOverride' },
    @{ P = 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity'; N = 'DisableAADWAM' }
)
foreach ($l in $legacy) {
    $v = Get-RegValue $l.P $l.N
    if ($null -ne $v) { Add-Result 'Identity' "Legacy override $($l.N)" $v 'WARN' 'Unsupported ADAL-era workaround - remove and retest' }
}

# ---------------- Detect: device identity ----------------
try {
    $ds = (& dsregcmd.exe /status) 2>$null
    foreach ($k in 'AzureAdJoined','DomainJoined','WorkplaceJoined','AzureAdPrt','TenantName') {
        $line = $ds | Where-Object { $_ -match ("^\s*{0}\s*:" -f $k) } | Select-Object -First 1
        if ($line) {
            $val = ($line -split ':',2)[1].Trim()
            $st = 'INFO'; $adv = ''
            if ($k -eq 'AzureAdPrt') {
                $st = if ($val -eq 'YES') { 'OK' } else { 'WARN' }
                if ($st -eq 'WARN') { $adv = 'No PRT - silent sign-in will fail; see EntraID/Troubleshooting/PRT-Issues-B.md' }
            }
            Add-Result 'Device' $k $val $st $adv
        }
    }
} catch { Add-Result 'Device' 'dsregcmd' 'Failed to run' 'WARN' }

try {
    $bp = Get-AppxPackage -Name 'Microsoft.AAD.BrokerPlugin' -ErrorAction Stop
    if ($bp) { Add-Result 'Device' 'AAD BrokerPlugin' ("{0} {1}" -f $bp.Version, $bp.Status) 'OK' }
    else { Add-Result 'Device' 'AAD BrokerPlugin' 'Not registered for this user' 'ERROR' 'Re-register (Activation-B Fix 2)' }
} catch { Add-Result 'Device' 'AAD BrokerPlugin' 'Unable to query' 'WARN' }

# ---------------- Detect: network ----------------
try {
    $px = (& netsh.exe winhttp show proxy) -join ' '
    $pv = if ($px -match 'Direct access') { 'Direct' } else { ($px -replace '\s+',' ').Trim() }
    Add-Result 'Network' 'WinHTTP proxy' $pv
} catch { }
foreach ($h in 'ols.officeapps.live.com','login.microsoftonline.com','officeclient.microsoft.com') {
    $ok = $false
    try { $ok = [bool](Test-NetConnection -ComputerName $h -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop).TcpTestSucceeded } catch { $ok = $false }
    Add-Result 'Network' "TCP 443 $h" ([string]$ok) $(if ($ok) {'OK'} else {'ERROR'}) $(if (-not $ok) {'Blocked - proxy/firewall (Activation-B Fix 5)'} else {''})
}

try {
    $since = (Get-Date).AddDays(-3)
    $aad = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-AAD/Operational'; Level = 2; StartTime = $since } -MaxEvents 50 -ErrorAction Stop)
    $st = if ($aad.Count -gt 0) { 'WARN' } else { 'OK' }
    Add-Result 'Events' 'AAD/Operational errors (3 d)' ([string]$aad.Count) $st $(if ($aad.Count -gt 0) {"Latest: Id $($aad[0].Id) at $($aad[0].TimeCreated)"} else {''})
} catch { Add-Result 'Events' 'AAD/Operational errors (3 d)' '0 or log unavailable' }

# ---------------- Optional: Graph ----------------
if ($CheckGraph) {
    if (-not $ExpectedUpn) {
        Add-Result 'Graph' 'Licence check' 'Skipped' 'WARN' '-CheckGraph needs -ExpectedUpn'
    } elseif (-not (Get-Module -ListAvailable Microsoft.Graph.Users)) {
        Add-Result 'Graph' 'Licence check' 'Microsoft.Graph.Users not installed' 'WARN' 'Install-Module Microsoft.Graph -Scope CurrentUser'
    } else {
        try {
            Import-Module Microsoft.Graph.Users -ErrorAction Stop
            Connect-MgGraph -Scopes 'User.Read.All' -NoWelcome -ErrorAction Stop
            $plans = @((Get-MgUserLicenseDetail -UserId $ExpectedUpn -ErrorAction Stop) | ForEach-Object { $_.ServicePlans } |
                Where-Object { $_.ServicePlanName -match '^(OFFICESUBSCRIPTION|O365_BUSINESS|OFFICE_BUSINESS)$' })
            if ($plans.Count -eq 0) {
                Add-Result 'Graph' 'Apps service plan' 'None' 'ERROR' 'User has no Microsoft 365 Apps entitlement'
            } else {
                foreach ($pl in $plans) {
                    $st = if ($pl.ProvisioningStatus -eq 'Success') { 'OK' } else { 'ERROR' }
                    Add-Result 'Graph' "Plan $($pl.ServicePlanName)" $pl.ProvisioningStatus $st
                }
            }
        } catch { Add-Result 'Graph' 'Licence check' $_.Exception.Message 'WARN' }
    }
}

# ---------------- Report ----------------
$csv = Join-Path $OutputPath ("M365AppsActivation_{0}_{1}_{2:yyyyMMdd_HHmmss}.csv" -f $env:COMPUTERNAME, $env:USERNAME, (Get-Date))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$err  = @($results | Where-Object Status -eq 'ERROR').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
Write-Status ("Done. {0} error(s), {1} warning(s). Report: {2}" -f $err, $warn, $csv) $(if ($err) {'ERROR'} elseif ($warn) {'WARN'} else {'OK'})
