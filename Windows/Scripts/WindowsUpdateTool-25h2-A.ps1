

<#
.SYNOPSIS
  UpdateWindows11-25h2-A — Dependency-driven Windows Update tool (built-in only).

.DESCRIPTION
  Attempts to bring a Windows 11 device fully up to date using ONLY built-in components:
  - Windows Update Agent COM API (Microsoft.Update.*)
  - BITS / Invoke-WebRequest for optional Catalog package download
  - wusa.exe / dism.exe for optional package installation

  Notes / Reality check:
  - Reaching a specific Feature Update (e.g., 25H2) is not always forceable purely via built-ins.
    Availability depends on: safeguard holds, policy pins, WSUS/WUfB configuration, hardware readiness,
    and Microsoft's staged rollout.
  - This script will:
      1) Register Microsoft Update service (if possible)
      2) Install all applicable software updates (quality + drivers if included)
      3) Optionally install a provided Catalog package URL (MSU/CAB)
      4) Re-scan in cycles to catch follow-on updates

  Phases: Preflight → Detect → Plan → Execute → Validate → Report → Rollback

.DEPENDENCY MAP
  Permissions
    - Must run elevated (local admin)

  Windows Components
    - Windows Update services: wuauserv, usosvc, bits, cryptsvc
    - COM: Microsoft.Update.Session, Microsoft.Update.ServiceManager

  External Network
    - Windows Update/Microsoft Update endpoints must be reachable (unless WSUS is in use)
    - Optional: CatalogPackageUrl must be reachable if provided

  Tools (built-in)
    - Start-BitsTransfer (BITS)
    - wusa.exe (for .msu)
    - dism.exe (for .cab)

.FAILURE MODES (top)
  1) Not running as admin → hard fail
  2) WSUS/dual-scan prevents feature updates → warn or optional fix
  3) TargetReleaseVersion pin blocks upgrade → warn or optional clear
  4) Safeguard hold blocks 25H2 → cannot override, collect evidence
  5) Update services disabled/stopped → attempt start, else fail
  6) Insufficient disk space → fail
  7) Proxy blocks WU endpoints → fail with network hints
  8) WU cache corruption → detect via COM errors, suggest repair
  9) Reboot required to complete updates → return special exit code
 10) Catalog package install fails → capture exit code and log

.EXIT CODES
  0  Success (no pending updates; feature version reached if possible)
  2  Success but reboot required to complete
  10 Preflight failure (admin/OS/etc)
  20 Dependency failure (services/COM)
  30 Update scan/download/install failure
  40 Catalog install failure
  50 Validation failure (updates still pending after max cycles)

.EXAMPLES
  # Standard: install all updates via WU/MU (no reboot), 3 cycles
  .\UpdateWindows11-25h2-A.ps1 -TargetFeatureVersion "25H2" -MaxCycles 3

  # Also install a specific MSU from a direct URL (you must supply the actual direct file URL)
  .\UpdateWindows11-25h2-A.ps1 -CatalogPackageUrl "https://download.windowsupdate.com/.../windows11.0-kbXXXXXXX-x64.msu" -CatalogPackageType MSU

  # Optional policy remediations (use carefully)
  .\UpdateWindows11-25h2-A.ps1 -FixWSUS -ClearTargetReleaseVersion

#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [Parameter()] [ValidateNotNullOrEmpty()] [string] $TargetFeatureVersion = '25H2',
  [Parameter()] [ValidateRange(1, 10)] [int] $MaxCycles = 3,
  [Parameter()] [ValidateRange(0, 720)] [int] $CycleDelaySeconds = 30,

  [Parameter()] [string] $LogDirectory = "C:\ProgramData\EZAdmin\Logs",
  [Parameter()] [ValidateSet('JSONL', 'CSV')] [string] $LogFormat = 'JSONL',

  [Parameter()] [string] $CatalogPackageUrl,
  [Parameter()] [ValidateSet('MSU', 'CAB')] [string] $CatalogPackageType,
  [Parameter()] [string] $CatalogExpectedSha256,

  [Parameter()] [switch] $FixWSUS,
  [Parameter()] [switch] $ClearTargetReleaseVersion,
  [Parameter()] [switch] $IncludeDrivers,

  [Parameter()] [switch] $AllowReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Phase = 'Init'
$script:StartTime = Get-Date
$script:Changes = New-Object System.Collections.Generic.List[object]
$script:InstalledKb = New-Object System.Collections.Generic.List[string]
$script:RebootRequired = $false
$script:LogPath = $null

function New-LogFile {
  if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
  }

  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $name = "UpdateWindows11-25h2-A-$stamp"
  $ext = if ($LogFormat -eq 'CSV') { 'csv' } else { 'jsonl' }
  $script:LogPath = Join-Path $LogDirectory "$name.$ext"

  if ($LogFormat -eq 'CSV') {
    "ts,level,phase,message,data" | Out-File -FilePath $script:LogPath -Encoding utf8 -Force
  } else {
    "" | Out-File -FilePath $script:LogPath -Encoding utf8 -Force
  }
}

function Write-Log {
  param(
    [Parameter(Mandatory)] [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')] [string] $Level,
    [Parameter(Mandatory)] [string] $Message,
    [Parameter()] [hashtable] $Data
  )

  $ts = (Get-Date).ToString('o')
  $phase = $script:Phase

  $line = "[$ts] [$Level] [$phase] $Message"
  Write-Host $line

  $payload = [ordered]@{
    ts = $ts
    level = $Level
    phase = $phase
    message = $Message
    data = $Data
  }

  if ($LogFormat -eq 'CSV') {
    $dataJson = if ($null -eq $Data) { '' } else { ($Data | ConvertTo-Json -Compress -Depth 6) }
    $csvLine = ($payload.ts, $payload.level, $payload.phase, ($payload.message -replace '"',''''), ($dataJson -replace '"','''')) -join ','
    Add-Content -Path $script:LogPath -Value $csvLine -Encoding utf8
  } else {
    $json = ($payload | ConvertTo-Json -Compress -Depth 6)
    Add-Content -Path $script:LogPath -Value $json -Encoding utf8
  }
}

function Set-Phase { param([string]$Name) $script:Phase = $Name; Write-Log -Level INFO -Message "Phase: $Name" }

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OSInfo {
  $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $ux = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction SilentlyContinue

  [pscustomobject]@{
    ProductName     = $cv.ProductName
    EditionID       = $cv.EditionID
    DisplayVersion  = $cv.DisplayVersion
    ReleaseId       = $cv.ReleaseId
    CurrentBuild    = $cv.CurrentBuild
    UBR             = $cv.UBR
    BuildLabEx      = $cv.BuildLabEx
    PauseExpiry     = $ux.PauseUpdatesExpiryTime
  }
}

function Test-DiskSpace {
  param([int]$MinGB = 20)
  $sys = Get-CimInstance -ClassName Win32_OperatingSystem
  $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($sys.SystemDrive)'"
  $freeGB = [math]::Round(($drive.FreeSpace / 1GB), 2)
  return [pscustomobject]@{ SystemDrive = $sys.SystemDrive; FreeGB = $freeGB; MinGB = $MinGB; Ok = ($freeGB -ge $MinGB) }
}

function Get-WURegistryState {
  $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  $au   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

  $trv  = (Get-ItemProperty -Path $base -ErrorAction SilentlyContinue).TargetReleaseVersion
  $trvi = (Get-ItemProperty -Path $base -ErrorAction SilentlyContinue).TargetReleaseVersionInfo

  $uws  = (Get-ItemProperty -Path $base -ErrorAction SilentlyContinue).UseWUServer
  $wsus = (Get-ItemProperty -Path $base -ErrorAction SilentlyContinue).WUServer

  $useWUServerAU = (Get-ItemProperty -Path $au -ErrorAction SilentlyContinue).UseWUServer

  [pscustomobject]@{
    TargetReleaseVersion     = $trv
    TargetReleaseVersionInfo = $trvi
    UseWUServer              = $uws
    WUServer                 = $wsus
    UseWUServerAU            = $useWUServerAU
  }
}

function Ensure-ServiceRunning {
  param([Parameter(Mandatory)][string[]]$Names)

  foreach ($n in $Names) {
    $svc = Get-Service -Name $n -ErrorAction Stop
    if ($svc.StartType -eq 'Disabled') {
      Write-Log -Level WARN -Message "Service is disabled" -Data @{ name = $n }
    }
    if ($svc.Status -ne 'Running') {
      if ($PSCmdlet.ShouldProcess($n, 'Start-Service')) {
        try {
          Start-Service -Name $n -ErrorAction Stop
          Write-Log -Level INFO -Message "Service started" -Data @{ name = $n }
        } catch {
          Write-Log -Level ERROR -Message "Failed to start service" -Data @{ name = $n; error = $_.Exception.Message }
          throw
        }
      }
    }
  }
}

function Register-MicrosoftUpdateService {
  try {
    $sm = New-Object -ComObject 'Microsoft.Update.ServiceManager'
    $null = $sm.ClientApplicationID = 'EZAdmin-UpdateWindows11-25h2-A'

    $muId = '7971f918-a847-4430-9279-4a52d1efe18d'
    $existing = $null

    try {
      $existing = $sm.Services | Where-Object { $_.ServiceID -eq $muId }
    } catch { }

    if (-not $existing) {
      if ($PSCmdlet.ShouldProcess('Microsoft Update', 'AddService2')) {
        $flags = 7
        $svc = $sm.AddService2($muId, $flags, $null)
        Write-Log -Level INFO -Message "Microsoft Update service registered" -Data @{ serviceId = $svc.ServiceID; name = $svc.Name }
      }
    } else {
      Write-Log -Level INFO -Message "Microsoft Update service already present" -Data @{ serviceId = $muId }
    }
  } catch {
    Write-Log -Level WARN -Message "Could not register Microsoft Update service (continuing)" -Data @{ error = $_.Exception.Message }
  }
}

function Set-WSUSDisabled {
  $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
  if (-not (Test-Path -LiteralPath $au)) { New-Item -Path $au -Force | Out-Null }

  $before = (Get-ItemProperty -Path $au -ErrorAction SilentlyContinue).UseWUServer
  if ($before -ne 0) {
    if ($PSCmdlet.ShouldProcess($au, 'Set UseWUServer=0')) {
      Set-ItemProperty -Path $au -Name UseWUServer -Type DWord -Value 0 -Force
      $script:Changes.Add([pscustomobject]@{ type='reg'; path=$au; name='UseWUServer'; before=$before; after=0 }) | Out-Null
      Write-Log -Level WARN -Message "WSUS policy disabled (UseWUServer=0). A gpupdate / policy refresh may be required." -Data @{ before = $before; after = 0 }
    }
  } else {
    Write-Log -Level INFO -Message "WSUS policy already disabled" -Data @{ UseWUServer = $before }
  }
}

function Clear-TargetReleaseVersionPin {
  $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  if (-not (Test-Path -LiteralPath $base)) { return }

  $props = Get-ItemProperty -Path $base -ErrorAction SilentlyContinue
  foreach ($name in @('TargetReleaseVersion','TargetReleaseVersionInfo')) {
    if ($null -ne ($props.PSObject.Properties[$name])) {
      $before = $props.$name
      if ($PSCmdlet.ShouldProcess($base, "Remove $name")) {
        Remove-ItemProperty -Path $base -Name $name -ErrorAction SilentlyContinue
        $script:Changes.Add([pscustomobject]@{ type='reg-remove'; path=$base; name=$name; before=$before }) | Out-Null
        Write-Log -Level WARN -Message "Removed TargetReleaseVersion pin" -Data @{ name=$name; before=$before }
      }
    }
  }
}

function New-WUObjects {
  $session = New-Object -ComObject 'Microsoft.Update.Session'
  $session.ClientApplicationID = 'EZAdmin-UpdateWindows11-25h2-A'
  $searcher = $session.CreateUpdateSearcher()

  [pscustomobject]@{
    Session  = $session
    Searcher = $searcher
  }
}

function Find-ApplicableUpdates {
  param(
    [Parameter(Mandatory)] $WU,
    [Parameter()] [switch] $Drivers
  )

  $criteria = if ($Drivers) {
    "IsInstalled=0 and IsHidden=0"
  } else {
    "IsInstalled=0 and IsHidden=0 and Type='Software'"
  }

  Write-Log -Level INFO -Message "Searching updates" -Data @{ criteria = $criteria }

  $result = $WU.Searcher.Search($criteria)
  $updates = New-Object -ComObject 'Microsoft.Update.UpdateColl'

  for ($i=0; $i -lt $result.Updates.Count; $i++) {
    $u = $result.Updates.Item($i)

    if (-not $u.EulaAccepted) {
      try { $u.AcceptEula() } catch { }
    }

    $updates.Add($u) | Out-Null
  }

  $summary = @{
    total = $updates.Count
    titlesPreview = @()
  }

  $maxPreview = [math]::Min(10, $updates.Count)
  for ($j=0; $j -lt $maxPreview; $j++) {
    $summary.titlesPreview += $updates.Item($j).Title
  }

  Write-Log -Level INFO -Message "Applicable updates found" -Data $summary

  return $updates
}

function Install-Updates {
  param(
    [Parameter(Mandatory)] $WU,
    [Parameter(Mandatory)] $Updates
  )

  if ($Updates.Count -eq 0) {
    Write-Log -Level INFO -Message "No updates to install"
    return
  }

  $downloader = $WU.Session.CreateUpdateDownloader()
  $downloader.Updates = $Updates

  if ($PSCmdlet.ShouldProcess("$($Updates.Count) updates", 'Download')) {
    Write-Log -Level INFO -Message "Downloading updates" -Data @{ count = $Updates.Count }
    $dl = $downloader.Download()
    Write-Log -Level INFO -Message "Download result" -Data @{ resultCode = $dl.ResultCode; hresult = $dl.HResult }
  }

  $installer = $WU.Session.CreateUpdateInstaller()
  $installer.Updates = $Updates
  $installer.ForceQuiet = $true

  if ($PSCmdlet.ShouldProcess("$($Updates.Count) updates", 'Install')) {
    Write-Log -Level INFO -Message "Installing updates" -Data @{ count = $Updates.Count }
    $res = $installer.Install()

    $script:RebootRequired = $script:RebootRequired -or [bool]$res.RebootRequired

    for ($i=0; $i -lt $Updates.Count; $i++) {
      $u = $Updates.Item($i)
      $rc = $res.GetUpdateResult($i).ResultCode

      $kb = $null
      try {
        if ($u.KBArticleIDs -and $u.KBArticleIDs.Count -gt 0) {
          $kb = ($u.KBArticleIDs | ForEach-Object { "KB$_" }) -join ','
        }
      } catch { }

      if ($kb) { $script:InstalledKb.Add($kb) | Out-Null }

      Write-Log -Level INFO -Message "Update result" -Data @{ title = $u.Title; kb = $kb; resultCode = $rc }
    }

    Write-Log -Level INFO -Message "Install summary" -Data @{ rebootRequired = $res.RebootRequired; overall = $res.ResultCode; hresult = $res.HResult }

    if ($res.HResult -ne 0) {
      throw "Update install returned HRESULT $($res.HResult)"
    }
  }
}

function Download-FileBuiltIn {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$DestinationPath
  )

  if (Get-Command -Name Start-BitsTransfer -ErrorAction SilentlyContinue) {
    Start-BitsTransfer -Source $Url -Destination $DestinationPath -ErrorAction Stop
  } else {
    Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
  }
}

function Get-Sha256 {
  param([Parameter(Mandatory)][string]$Path)
  (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Install-CatalogPackage {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][ValidateSet('MSU','CAB')][string]$Type,
    [Parameter()] [string] $ExpectedSha256
  )

  Set-Phase 'Execute-Catalog'

  $tempDir = Join-Path $env:TEMP 'EZAdmin-Catalog'
  if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

  $fileName = if ($Type -eq 'MSU') { 'catalog.msu' } else { 'catalog.cab' }
  $dest = Join-Path $tempDir $fileName

  if ($PSCmdlet.ShouldProcess($Url, "Download catalog $Type")) {
    Write-Log -Level INFO -Message "Downloading catalog package" -Data @{ url = $Url; dest = $dest }
    Download-FileBuiltIn -Url $Url -DestinationPath $dest
  }

  if ($ExpectedSha256) {
    $actual = Get-Sha256 -Path $dest
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
      Write-Log -Level ERROR -Message "Catalog package hash mismatch" -Data @{ expected = $ExpectedSha256; actual = $actual }
      throw "Catalog hash mismatch"
    }
    Write-Log -Level INFO -Message "Catalog package hash verified" -Data @{ sha256 = $actual }
  }

  if ($Type -eq 'MSU') {
    $args = "/quiet /norestart `"$dest`""
    if ($PSCmdlet.ShouldProcess($dest, 'wusa install')) {
      Write-Log -Level INFO -Message "Installing MSU via wusa" -Data @{ args = $args }
      $p = Start-Process -FilePath "$env:SystemRoot\System32\wusa.exe" -ArgumentList $args -Wait -PassThru
      Write-Log -Level INFO -Message "wusa exit" -Data @{ exitCode = $p.ExitCode }

      if ($p.ExitCode -eq 3010) {
        $script:RebootRequired = $true
      } elseif ($p.ExitCode -ne 0) {
        throw "wusa failed with exit code $($p.ExitCode)"
      }
    }
  } else {
    $args = "/Online /Add-Package /PackagePath:`"$dest`" /NoRestart"
    if ($PSCmdlet.ShouldProcess($dest, 'dism add-package')) {
      Write-Log -Level INFO -Message "Installing CAB via dism" -Data @{ args = $args }
      $p = Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" -ArgumentList $args -Wait -PassThru
      Write-Log -Level INFO -Message "dism exit" -Data @{ exitCode = $p.ExitCode }

      if ($p.ExitCode -eq 3010) {
        $script:RebootRequired = $true
      } elseif ($p.ExitCode -ne 0) {
        throw "dism failed with exit code $($p.ExitCode)"
      }
    }
  }

  $script:Changes.Add([pscustomobject]@{ type='catalog'; url=$Url; packageType=$Type; path=$dest }) | Out-Null
}

function Test-TargetFeatureVersion {
  param([string]$Target)

  $os = Get-OSInfo

  $display = $os.DisplayVersion
  $ok = $false

  try {
    $digits = ($display -replace '[^0-9]','')
    $targetDigits = ($Target -replace '[^0-9]','')

    if ($digits -and $targetDigits) {
      $ok = ([int]$digits -ge [int]$targetDigits)
    }
  } catch {
    $ok = $false
  }

  [pscustomobject]@{ DisplayVersion = $display; Target = $Target; Ok = $ok; Build = "$($os.CurrentBuild).$($os.UBR)" }
}

function Invoke-Rollback {
  Set-Phase 'Rollback'

  if ($script:Changes.Count -eq 0) {
    Write-Log -Level INFO -Message "No recorded changes to rollback"
    return
  }

  foreach ($c in [System.Linq.Enumerable]::Reverse($script:Changes)) {
    try {
      if ($c.type -eq 'reg') {
        if ($PSCmdlet.ShouldProcess($c.path, "Rollback registry $($c.name)")) {
          Set-ItemProperty -Path $c.path -Name $c.name -Type DWord -Value $c.before -Force
          Write-Log -Level WARN -Message "Rolled back registry value" -Data @{ path=$c.path; name=$c.name; restored=$c.before }
        }
      } elseif ($c.type -eq 'reg-remove') {
        Write-Log -Level WARN -Message "Rollback note: removed policy value cannot be restored without stored original object" -Data @{ path=$c.path; name=$c.name; before=$c.before }
      } elseif ($c.type -eq 'catalog') {
        Write-Log -Level WARN -Message "Rollback note: catalog installs are not auto-uninstalled. Use wusa /uninstall or dism /remove-package if needed." -Data @{ url=$c.url; packageType=$c.packageType; path=$c.path }
      }
    } catch {
      Write-Log -Level ERROR -Message "Rollback step failed" -Data @{ change = ($c | ConvertTo-Json -Compress -Depth 6); error = $_.Exception.Message }
    }
  }
}

try {
  New-LogFile
  Set-Phase 'Preflight'

  Write-Log -Level INFO -Message "Starting" -Data @{ started = $script:StartTime.ToString('o'); log = $script:LogPath }

  if (-not (Test-IsAdmin)) {
    Write-Log -Level ERROR -Message "Must run as Administrator"
    exit 10
  }

  $os = Get-OSInfo
  Write-Log -Level INFO -Message "OS detected" -Data ($os | Select-Object ProductName,EditionID,DisplayVersion,CurrentBuild,UBR,PauseExpiry | ConvertTo-Json -Compress | ConvertFrom-Json)

  if ($os.ProductName -notlike '*Windows 11*') {
    Write-Log -Level ERROR -Message "This script is intended for Windows 11" -Data @{ product = $os.ProductName }
    exit 10
  }

  $disk = Test-DiskSpace -MinGB 20
  Write-Log -Level INFO -Message "Disk space" -Data @{ drive = $disk.SystemDrive; freeGB = $disk.FreeGB; minGB = $disk.MinGB; ok = $disk.Ok }
  if (-not $disk.Ok) {
    Write-Log -Level ERROR -Message "Insufficient disk space" -Data @{ freeGB = $disk.FreeGB; requiredGB = $disk.MinGB }
    exit 10
  }

  Ensure-ServiceRunning -Names @('wuauserv','usosvc','bits','cryptsvc')

  $pol = Get-WURegistryState
  Write-Log -Level INFO -Message "WU policy snapshot" -Data ($pol | ConvertTo-Json -Compress | ConvertFrom-Json)

  if ($pol.TargetReleaseVersion -eq 1 -or $pol.TargetReleaseVersionInfo) {
    Write-Log -Level WARN -Message "TargetReleaseVersion pin detected; can block feature updates" -Data @{ TargetReleaseVersion = $pol.TargetReleaseVersion; TargetReleaseVersionInfo = $pol.TargetReleaseVersionInfo }
    if ($ClearTargetReleaseVersion) {
      Set-Phase 'Preflight-Policy'
      Clear-TargetReleaseVersionPin
    }
  }

  if ($pol.UseWUServer -eq 1 -or $pol.UseWUServerAU -eq 1 -or $pol.WUServer) {
    Write-Log -Level WARN -Message "WSUS policy detected; feature updates may be blocked" -Data @{ UseWUServer = $pol.UseWUServer; UseWUServerAU = $pol.UseWUServerAU; WUServer = $pol.WUServer }
    if ($FixWSUS) {
      Set-Phase 'Preflight-Policy'
      Set-WSUSDisabled
    }
  }

  Set-Phase 'Detect'

  $targetCheck = Test-TargetFeatureVersion -Target $TargetFeatureVersion
  Write-Log -Level INFO -Message "Target feature version check" -Data @{ display = $targetCheck.DisplayVersion; target = $targetCheck.Target; ok = $targetCheck.Ok; build = $targetCheck.Build }

  Register-MicrosoftUpdateService
  $wu = New-WUObjects

  Set-Phase 'Plan'

  for ($cycle = 1; $cycle -le $MaxCycles; $cycle++) {
    Write-Log -Level INFO -Message "Cycle" -Data @{ cycle = $cycle; max = $MaxCycles }

    $updates = Find-ApplicableUpdates -WU $wu -Drivers:$IncludeDrivers

    if ($updates.Count -eq 0) {
      Write-Log -Level INFO -Message "No applicable updates remaining" -Data @{ cycle = $cycle }
      break
    }

    Set-Phase 'Execute'
    Install-Updates -WU $wu -Updates $updates

    if ($CycleDelaySeconds -gt 0 -and $cycle -lt $MaxCycles) {
      Set-Phase 'Execute-Delay'
      Write-Log -Level INFO -Message "Sleeping between cycles" -Data @{ seconds = $CycleDelaySeconds }
      Start-Sleep -Seconds $CycleDelaySeconds
      Set-Phase 'Plan'
    }
  }

  if ($CatalogPackageUrl) {
    if (-not $CatalogPackageType) {
      Write-Log -Level ERROR -Message "CatalogPackageType is required when CatalogPackageUrl is provided" -Data @{ CatalogPackageUrl = $CatalogPackageUrl }
      exit 40
    }

    try {
      Install-CatalogPackage -Url $CatalogPackageUrl -Type $CatalogPackageType -ExpectedSha256 $CatalogExpectedSha256
    } catch {
      Write-Log -Level ERROR -Message "Catalog install failed" -Data @{ error = $_.Exception.Message }
      Invoke-Rollback
      exit 40
    }

    Set-Phase 'Plan'
    $updatesAfterCatalog = Find-ApplicableUpdates -WU $wu -Drivers:$IncludeDrivers
    if ($updatesAfterCatalog.Count -gt 0) {
      Set-Phase 'Execute'
      Install-Updates -WU $wu -Updates $updatesAfterCatalog
    }
  }

  Set-Phase 'Validate'

  $remaining = Find-ApplicableUpdates -WU $wu -Drivers:$IncludeDrivers
  $targetCheck2 = Test-TargetFeatureVersion -Target $TargetFeatureVersion

  Write-Log -Level INFO -Message "Validation" -Data @{ remaining = $remaining.Count; display = $targetCheck2.DisplayVersion; target = $targetCheck2.Target; targetOk = $targetCheck2.Ok; rebootRequired = $script:RebootRequired }

  Set-Phase 'Report'

  $runtime = [math]::Round(((Get-Date) - $script:StartTime).TotalMinutes, 2)
  $summary = [ordered]@{
    runtimeMinutes = $runtime
    logPath = $script:LogPath
    installedKb = ($script:InstalledKb | Select-Object -Unique)
    remainingUpdates = $remaining.Count
    displayVersion = $targetCheck2.DisplayVersion
    targetVersion = $TargetFeatureVersion
    targetReached = $targetCheck2.Ok
    rebootRequired = $script:RebootRequired
    allowReboot = [bool]$AllowReboot
  }

  Write-Log -Level INFO -Message "Summary" -Data ($summary | ConvertTo-Json -Compress | ConvertFrom-Json)

  if ($script:RebootRequired -and $AllowReboot) {
    if ($PSCmdlet.ShouldProcess('Computer', 'Restart-Computer')) {
      Write-Log -Level WARN -Message "Restarting computer to complete updates"
      Restart-Computer -Force
      exit 0
    }
  }

  if ($script:RebootRequired) {
    exit 2
  }

  if ($remaining.Count -gt 0) {
    exit 50
  }

  exit 0

} catch {
  Write-Log -Level ERROR -Message "Unhandled failure" -Data @{ phase = $script:Phase; error = $_.Exception.Message }
  try { Invoke-Rollback } catch { }
  exit 30
}