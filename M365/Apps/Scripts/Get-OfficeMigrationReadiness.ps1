<#
.SYNOPSIS
    Read-only readiness check for migrating a Windows device from MSI / LTSC / retail Office to Microsoft 365 Apps.

.DESCRIPTION
    Inventories everything that decides the migration path and classifies the device:
      - Click-to-Run 16.0 install: product IDs, bitness, build, channel (CDNBaseUrl / UpdateChannel decoded)
      - MSI Office / Visio / Project (2007-2016) from the uninstall keys (64- and 32-bit views)
      - Office 2013 Click-to-Run (15.0) presence
      - Office update policy (updatebranch / updatepath) that could pin the device to LTSC
      - Office licences with keys in Windows SPP (volume/retail leftovers)
      - Free space on the system drive and a pending-reboot indicator
    Produces a classification (e.g. LTSC-Volume-C2R, MSI, Mixed, Already-M365, Half-migrated) and a list of
    required steps. With -GenerateXml it writes suggested remove.xml / install.xml files for the Office Deployment Tool.

    Does NOT: uninstall, install, change licences or policies, contact Microsoft 365, or check user licences.
    Generated XML is a starting point - review product IDs, languages and channel before using it.

.PARAMETER TargetProductId
    O365ProPlusRetail (default, enterprise plans) or O365BusinessRetail (business plans).

.PARAMETER TargetChannel
    ODT channel name for the generated install.xml. Default MonthlyEnterprise.

.PARAMETER TargetBitness
    64 (default) or 32 for the generated install.xml.

.PARAMETER GenerateXml
    Write remove.xml (when C2R suites must be removed first) and install.xml to -OutputPath.

.PARAMETER OutputPath
    Folder for the CSV report and XML files. Default C:\Temp\OfficeMigration

.EXAMPLE
    .\Get-OfficeMigrationReadiness.ps1
    Report only.

.EXAMPLE
    .\Get-OfficeMigrationReadiness.ps1 -TargetProductId O365BusinessRetail -TargetChannel Current -GenerateXml
    Report plus ODT XML files for a Business Premium user on Current Channel.

.NOTES
    Requires: Windows PowerShell 5.1+. Run as: local administrator recommended (SPP and HKLM reads work as standard user
    on most builds, but some uninstall keys and policy keys may be filtered).
    Safe: read-only apart from writing the report/XML files to -OutputPath.
#>
[CmdletBinding()]
param(
    [ValidateSet('O365ProPlusRetail','O365BusinessRetail')]
    [string]$TargetProductId = 'O365ProPlusRetail',
    [ValidateSet('Current','MonthlyEnterprise','SemiAnnual','SemiAnnualPreview','CurrentPreview','BetaChannel')]
    [string]$TargetChannel = 'MonthlyEnterprise',
    [ValidateSet('64','32')]
    [string]$TargetBitness = '64',
    [switch]$GenerateXml,
    [string]$OutputPath = 'C:\Temp\OfficeMigration'
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
    param([string]$Area, [string]$Item, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Computer = $env:COMPUTERNAME; Area = $Area; Item = $Item; Status = $Status; Detail = $Detail })
    Write-Status -Message ("{0} | {1}: {2}" -f $Area, $Item, $Detail) -Status $Status
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

$channelMap = @{
    '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current'
    '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'CurrentPreview'
    '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'BetaChannel'
    '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'MonthlyEnterprise'
    '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'SemiAnnual'
    'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'SemiAnnualPreview'
    'f2e724c1-748f-4b47-8fb8-8e0d210e9208' = 'PerpetualVL2019'
    '5030841d-c919-4594-8d2d-84ae4f96e58e' = 'PerpetualVL2021'
    '7983bac0-e531-40cf-be00-fd24fe66619c' = 'PerpetualVL2024'
}
function Resolve-Channel {
    param([string]$Url)
    if (-not $Url) { return '' }
    foreach ($k in $channelMap.Keys) { if ($Url -match $k) { return $channelMap[$k] } }
    return "Unknown/custom ($Url)"
}

# ---------------- Preflight ----------------
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Result 'Preflight' 'Elevated' $(if ($isAdmin) { 'OK' } else { 'WARN' }) "Administrator=$isAdmin"

# ---------------- Detect: Click-to-Run 16.0 ----------------
$c2r = $null
try { $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction Stop } catch { $c2r = $null }
$products = @()
$platform = ''
$c2rChannel = ''
if ($c2r) {
    $ids = [string](Get-Prop $c2r 'ProductReleaseIds')
    $products = @($ids -split ',' | Where-Object { $_ })
    $platform = [string](Get-Prop $c2r 'Platform')
    $ver = [string](Get-Prop $c2r 'VersionToReport')
    $cdn = [string](Get-Prop $c2r 'CDNBaseUrl')
    $upd = [string](Get-Prop $c2r 'UpdateChannel')
    $c2rChannel = if ($upd) { Resolve-Channel $upd } else { Resolve-Channel $cdn }
    Add-Result 'C2R 16.0' 'Products' 'INFO' ($products -join ', ')
    Add-Result 'C2R 16.0' 'Platform / Version' 'INFO' "$platform / $ver"
    Add-Result 'C2R 16.0' 'Channel' 'INFO' ("Effective=$c2rChannel; CDNBaseUrl=" + (Resolve-Channel $cdn) + $(if ($upd) { "; UpdateChannel=" + (Resolve-Channel $upd) } else { '' }))
} else {
    Add-Result 'C2R 16.0' 'Install' 'INFO' 'No Click-to-Run 16.0 install found'
}

$m365Suites   = @($products | Where-Object { $_ -in @('O365ProPlusRetail','O365BusinessRetail','O365HomePremRetail','O365SmallBusPremRetail') })
$oldSuites    = @($products | Where-Object { $_ -notmatch '^(O365|Visio|Project|AccessRuntime|LanguagePack|ProofingTools|OneNoteFree|SkypeforBusinessEntry)' })
$visioProject = @($products | Where-Object { $_ -match '^(Visio|Project)' })

# ---------------- Detect: MSI ----------------
$msi = @()
$uninstallPaths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
foreach ($p in $uninstallPaths) {
    $entries = @(Get-ItemProperty $p -ErrorAction SilentlyContinue)
    foreach ($e in $entries) {
        $dn = [string](Get-Prop $e 'DisplayName')
        $wi = Get-Prop $e 'WindowsInstaller'
        $sys = Get-Prop $e 'SystemComponent'
        if ($dn -match '^Microsoft (Office|Visio|Project)' -and $wi -eq 1 -and $sys -ne 1) {
            $msi += [pscustomobject]@{ Name = $dn; Version = [string](Get-Prop $e 'DisplayVersion'); View = $(if ($p -like '*WOW6432Node*') { 'x86' } else { 'x64' }) }
        }
    }
}
if ($msi.Count -gt 0) {
    foreach ($m in $msi) { Add-Result 'MSI' $m.Name 'WARN' "Version=$($m.Version); Registry view=$($m.View) - removed by <RemoveMSI/>" }
} else {
    Add-Result 'MSI' 'Office/Visio/Project MSI' 'OK' 'None found'
}
$msi16VisioProject = @($msi | Where-Object { $_.Name -match 'Visio|Project' -and $_.Version -like '16.*' })

# ---------------- Detect: Office 2013 C2R ----------------
$c2r15 = Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\15.0\ClickToRun'
Add-Result 'C2R 15.0' 'Office 2013 Click-to-Run' $(if ($c2r15) { 'ERROR' } else { 'OK' }) $(if ($c2r15) { 'Present - not removed by RemoveMSI or ODT 16.0 Remove; uninstall first' } else { 'Not present' })

# ---------------- Detect: policy ----------------
$pol = $null
try { $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -ErrorAction Stop } catch { $pol = $null }
if ($pol) {
    $ub = [string](Get-Prop $pol 'updatebranch'); $up = [string](Get-Prop $pol 'updatepath')
    $polStatus = if ($ub -match 'Perpetual|LTSC' -or $up -match 'LTSC|Perpetual|2019|2021|2024') { 'WARN' } else { 'INFO' }
    Add-Result 'Policy' 'officeupdate' $polStatus "updatebranch='$ub'; updatepath='$up' - policy overrides ODT channel"
} else {
    Add-Result 'Policy' 'officeupdate' 'OK' 'No Office update policy set'
}

# ---------------- Detect: SPP licences ----------------
$spp = @()
try {
    $spp = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" -ErrorAction Stop)
} catch {
    Add-Result 'SPP' 'Query' 'WARN' "SoftwareLicensingProduct query failed: $($_.Exception.Message)"
}
foreach ($s in $spp) {
    $st = if ($s.Name -match 'Visio|Project') { 'INFO' } else { 'WARN' }
    Add-Result 'SPP' $s.Name $st "Key=*****-$($s.PartialProductKey); LicenseStatus=$($s.LicenseStatus)"
}
if ($spp.Count -eq 0) { Add-Result 'SPP' 'Office keys' 'OK' 'No Office product keys in Windows SPP' }

# ---------------- Detect: disk / reboot ----------------
$sysDrive = $env:SystemDrive.TrimEnd(':')
$freeGB = [math]::Round((Get-PSDrive -Name $sysDrive).Free / 1GB, 1)
Add-Result 'Readiness' 'Free space' $(if ($freeGB -ge 4) { 'OK' } else { 'ERROR' }) "$freeGB GB free on $env:SystemDrive (need ~4 GB)"
$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
Add-Result 'Readiness' 'Pending reboot' $(if ($pending) { 'WARN' } else { 'OK' }) "RebootPending=$pending"
$busy = @(Get-Process -Name 'OfficeC2RClient' -ErrorAction SilentlyContinue)
Add-Result 'Readiness' 'C2R operation running' $(if ($busy.Count) { 'WARN' } else { 'OK' }) "OfficeC2RClient processes=$($busy.Count)"

# ---------------- Classify ----------------
$class = 'No-Office'
$steps = New-Object System.Collections.Generic.List[string]
if ($m365Suites.Count -gt 0 -and $oldSuites.Count -gt 0) { $class = 'Half-migrated' }
elseif ($m365Suites.Count -gt 0 -and $msi.Count -eq 0 -and -not $c2r15) { $class = 'Already-M365' }
elseif ($oldSuites -match 'Volume$') { $class = 'LTSC/2019-Volume-C2R' }
elseif ($oldSuites.Count -gt 0) { $class = 'Retail-C2R' }
elseif ($msi.Count -gt 0) { $class = 'MSI' }
if ($c2r15) { $class = "$class + Office2013-C2R" }

if ($c2r15) { $steps.Add('Uninstall Office 2013 Click-to-Run first (Settings > Apps or Microsoft uninstall support tool), reboot.') }
if ($oldSuites.Count -gt 0) { $steps.Add("ODT Remove pass for: $($oldSuites -join ', ') (remove.xml).") }
if ($msi.Count -gt 0) { $steps.Add('Include <RemoveMSI/> in install.xml (or Intune "Remove other versions" = Yes).') }
if ($msi16VisioProject.Count -gt 0) { $steps.Add('MSI Visio/Project 2016 cannot coexist with C2R - replace with C2R volume or VisioProRetail/ProjectProRetail.') }
$keepVP = @($visioProject | Where-Object { $_ -match 'Volume$' })
if ($keepVP.Count -gt 0) { $steps.Add("Volume Visio/Project ($($keepVP -join ', ')) can stay only on the M365 channel + same bitness; re-add them in install.xml with their key.") }
if ($platform -and (($platform -eq 'x86' -and $TargetBitness -eq '64') -or ($platform -eq 'x64' -and $TargetBitness -eq '32'))) { $steps.Add("Bitness change $platform -> $TargetBitness (MigrateArch=TRUE); check 32-bit add-ins / Access MDE first.") }
if ($pol -and ([string](Get-Prop $pol 'updatepath') -or [string](Get-Prop $pol 'updatebranch'))) { $steps.Add('Review Office update policy (updatepath/updatebranch) before migrating - it overrides the ODT channel.') }
if (@($spp | Where-Object { $_.Name -notmatch 'Visio|Project' }).Count -gt 0) { $steps.Add('After migration remove stale Office suite keys from SPP (UninstallProductKey).') }
if ($class -eq 'Already-M365' -and $steps.Count -eq 0) { $steps.Add('Nothing to migrate. For activation issues see Activation-B.md.') }

Add-Result 'Summary' 'Classification' $(if ($class -match 'Half|2013') { 'ERROR' } elseif ($class -eq 'Already-M365') { 'OK' } else { 'WARN' }) $class
$i = 1
foreach ($s in $steps) { Add-Result 'Summary' "Step $i" 'INFO' $s; $i++ }

# ---------------- Generate XML ----------------
if ($GenerateXml) {
    $logPath = 'C:\Temp\ODTLogs'
    if ($oldSuites.Count -gt 0) {
        $rem = New-Object System.Text.StringBuilder
        [void]$rem.AppendLine('<Configuration>')
        [void]$rem.AppendLine('  <Remove>')
        foreach ($p in $oldSuites) {
            [void]$rem.AppendLine("    <Product ID=`"$p`">")
            [void]$rem.AppendLine('      <Language ID="en-us" />  <!-- list every installed language for this product -->')
            [void]$rem.AppendLine('    </Product>')
        }
        [void]$rem.AppendLine('  </Remove>')
        [void]$rem.AppendLine('  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />')
        [void]$rem.AppendLine('  <Display Level="None" AcceptEULA="TRUE" />')
        [void]$rem.AppendLine("  <Logging Level=`"Standard`" Path=`"$logPath`" />")
        [void]$rem.AppendLine('</Configuration>')
        $remFile = Join-Path $OutputPath 'remove.xml'
        Set-Content -Path $remFile -Value $rem.ToString() -Encoding UTF8
        Add-Result 'XML' 'remove.xml' 'OK' $remFile
    }
    $lang = if ($msi.Count -gt 0) { '      <Language ID="MatchPreviousMSI" />' + [Environment]::NewLine + '      <Language ID="MatchOS" Fallback="en-us" />' } else { '      <Language ID="MatchOS" Fallback="en-us" />' }
    $migrate = if ($platform -and $c2r -and $oldSuites.Count -eq 0) { ' MigrateArch="TRUE"' } else { '' }
    $ins = New-Object System.Text.StringBuilder
    [void]$ins.AppendLine('<Configuration>')
    [void]$ins.AppendLine("  <Add OfficeClientEdition=`"$TargetBitness`" Channel=`"$TargetChannel`"$migrate>")
    [void]$ins.AppendLine("    <Product ID=`"$TargetProductId`">")
    [void]$ins.AppendLine($lang)
    [void]$ins.AppendLine('    </Product>')
    foreach ($vp in $keepVP) {
        [void]$ins.AppendLine("    <Product ID=`"$vp`" PIDKEY=`"REPLACE-WITH-KEY`">")
        [void]$ins.AppendLine('      <Language ID="MatchOS" Fallback="en-us" />')
        [void]$ins.AppendLine('    </Product>')
    }
    [void]$ins.AppendLine('  </Add>')
    if ($msi.Count -gt 0) { [void]$ins.AppendLine('  <RemoveMSI />') }
    [void]$ins.AppendLine('  <Property Name="SharedComputerLicensing" Value="0" />  <!-- 1 for RDS/AVD -->')
    [void]$ins.AppendLine('  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />')
    [void]$ins.AppendLine('  <Updates Enabled="TRUE" />')
    [void]$ins.AppendLine('  <Display Level="None" AcceptEULA="TRUE" />')
    [void]$ins.AppendLine("  <Logging Level=`"Standard`" Path=`"$logPath`" />")
    [void]$ins.AppendLine('</Configuration>')
    $insFile = Join-Path $OutputPath 'install.xml'
    Set-Content -Path $insFile -Value $ins.ToString() -Encoding UTF8
    Add-Result 'XML' 'install.xml' 'OK' "$insFile (run remove.xml first if generated)"
    if ($keepVP.Count -gt 0) { Add-Result 'XML' 'Volume keys' 'WARN' 'Replace REPLACE-WITH-KEY with the Visio/Project GVLK or MAK before use.' }
}

# ---------------- Report ----------------
$file = Join-Path $OutputPath ("OfficeMigrationReadiness-{0}-{1}.csv" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
$results | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
Write-Status "Classification: $class. Report: $file" $(if ($class -eq 'Already-M365') { 'OK' } else { 'WARN' })
