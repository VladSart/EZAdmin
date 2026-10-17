<#
.SYNOPSIS
    Read-only inventory of Office COM, VSTO and Excel XLL add-ins with binary bitness and a
    compatibility verdict against a target Office bitness (default x64).

.DESCRIPTION
    Companion to M365/Apps/OfficeToM365Migration-A/B.md. Before moving a device from 32-bit Office
    (MSI, LTSC, retail or Microsoft 365 Apps x86) to 64-bit Microsoft 365 Apps, every in-process
    native add-in must exist in a 64-bit build or it will silently fail to load. This script:

      - Detects installed Office bitness (Click-to-Run Platform, or MSI Outlook\Bitness)
      - Enumerates add-in registrations for Word, Excel, PowerPoint, Outlook, Access, Visio,
        Project, OneNote and MS Project from:
          HKLM 64-bit view, HKLM WOW6432Node (32-bit Office), HKCU,
          and the Click-to-Run virtual registry (ClickToRun\REGISTRY\MACHINE)
      - Resolves ProgID -> CLSID -> InprocServer32 and reads the PE header of the DLL
        (x86 / x64 / ARM64), or classifies it as VSTO / .NET shim (bitness-neutral)
      - Enumerates Excel XLL / XLAM add-ins from Excel\Options OPENx values (XLL = native, bitness
        matters; XLA/XLAM = VBA, check Declare statements for PtrSafe)
      - Reports Resiliency\DisabledItems counts and DoNotDisableAddinList entries per app
      - Assigns a verdict per add-in: Compatible / Incompatible / Neutral / Unknown

    Does not inspect VBA code inside XLAM/DOTM files, Office Web (JavaScript) add-ins, or
    per-user registrations of users other than the one running the script.

.PARAMETER TargetBitness
    Bitness of the Office build you plan to run. x64 (default) or x86.

.PARAMETER OutputPath
    Folder for the CSV report. Defaults to $env:TEMP.

.PARAMETER IncludeDisabled
    Include add-ins whose LoadBehavior indicates they are not set to load (0/1/2/16 without bit 1).
    By default every registered add-in is listed; this switch only affects the summary counts.

.EXAMPLE
    .\Get-OfficeAddinInventory.ps1
    Inventory for the current user + machine, verdict against 64-bit Office.

.EXAMPLE
    .\Get-OfficeAddinInventory.ps1 -TargetBitness x86 -OutputPath C:\Temp
    Checks what would break when staying on / moving to 32-bit Office.

.NOTES
    Requires : Windows PowerShell 5.1+ (PowerShell 7 also works). No modules.
    Run as   : The affected user (HKCU add-ins are per user). Elevation not required.
    Safety   : Read-only. Reads registry and the first 4 KB of each add-in DLL.
    LoadBehavior: 3 = load at startup, 9 = load on demand, 16 = load once then on demand,
                  2 = not loaded at startup (often set by Office after a crash/slow load).
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86')][string]$TargetBitness = 'x64',
    [string]$OutputPath = $env:TEMP,
    [switch]$IncludeDisabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-PEMachine {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'FileNotFound' }
    $fs = $null
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $buf = New-Object byte[] 4096
        $read = $fs.Read($buf, 0, $buf.Length)
        if ($read -lt 64 -or $buf[0] -ne 0x4D -or $buf[1] -ne 0x5A) { return 'NotPE' }
        $peOff = [BitConverter]::ToInt32($buf, 0x3C)
        if ($peOff -lt 0 -or ($peOff + 6) -gt $read) { return 'NotPE' }
        if ($buf[$peOff] -ne 0x50 -or $buf[$peOff + 1] -ne 0x45) { return 'NotPE' }
        $machine = [BitConverter]::ToUInt16($buf, $peOff + 4)
        switch ($machine) {
            0x014C { return 'x86' }
            0x8664 { return 'x64' }
            0xAA64 { return 'ARM64' }
            default { return ('0x{0:X4}' -f $machine) }
        }
    } catch {
        return 'Unreadable'
    } finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
}

function Get-RegDefault {
    param([string]$Path)
    try {
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        return $k.GetValue('')
    } catch { return $null }
}

function Resolve-InprocServer {
    # Returns @{ Clsid; Path; Source } searching 64-bit, 32-bit and per-user class registrations.
    param([string]$ProgId)
    $roots = @(
        @{ Name = 'HKCU';       Base = 'HKCU:\Software\Classes' },
        @{ Name = 'HKCU-WOW64'; Base = 'HKCU:\Software\Classes\WOW6432Node' },
        @{ Name = 'HKLM';       Base = 'HKLM:\SOFTWARE\Classes' },
        @{ Name = 'HKLM-WOW64'; Base = 'HKLM:\SOFTWARE\WOW6432Node\Classes' },
        @{ Name = 'C2R';        Base = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\REGISTRY\MACHINE\Software\Classes' }
    )
    $clsid = $null
    foreach ($r in $roots) {
        $c = Get-RegDefault -Path (Join-Path $r.Base "$ProgId\CLSID")
        if ($c) { $clsid = "$c"; break }
    }
    if (-not $clsid) { return @{ Clsid = ''; Path = ''; Source = 'ProgIdNotRegistered' } }
    $clsidRoots = @(
        @{ Name = 'HKCU';       Base = 'HKCU:\Software\Classes\CLSID' },
        @{ Name = 'HKLM';       Base = 'HKLM:\SOFTWARE\Classes\CLSID' },
        @{ Name = 'HKLM-WOW64'; Base = 'HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID' },
        @{ Name = 'HKCU-WOW64'; Base = 'HKCU:\Software\Classes\WOW6432Node\CLSID' },
        @{ Name = 'C2R';        Base = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\REGISTRY\MACHINE\Software\Classes\CLSID' }
    )
    foreach ($r in $clsidRoots) {
        $p = Get-RegDefault -Path (Join-Path $r.Base "$clsid\InprocServer32")
        if ($p) {
            $expanded = [Environment]::ExpandEnvironmentVariables(("$p").Trim('"'))
            return @{ Clsid = $clsid; Path = $expanded; Source = $r.Name }
        }
        $lp = Get-RegDefault -Path (Join-Path $r.Base "$clsid\LocalServer32")
        if ($lp) { return @{ Clsid = $clsid; Path = ("$lp").Trim('"'); Source = "$($r.Name)-LocalServer" } }
    }
    return @{ Clsid = $clsid; Path = ''; Source = 'ClsidNotRegistered' }
}

function Get-LoadBehaviorText {
    param($Value)
    if ($null -eq $Value) { return 'n/a' }
    switch ([int]$Value) {
        0 { 'Unloaded, do not load automatically' }
        1 { 'Loaded, do not load automatically' }
        2 { 'Load at startup - currently unloaded (often disabled by Office)' }
        3 { 'Load at startup' }
        8 { 'Load on demand - unloaded' }
        9 { 'Load on demand' }
        16 { 'Load first time, then on demand' }
        default { "Other ($Value)" }
    }
}

# ---------------- Preflight ----------------
Write-Status "Office add-in inventory on $env:COMPUTERNAME for $env:USERNAME (target: $TargetBitness)"
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

$officeBitness = 'Unknown'
$installType = 'NotDetected'
try {
    $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction Stop
    if ($c2r.PSObject.Properties['Platform']) { $officeBitness = "$($c2r.Platform)"; $installType = 'ClickToRun' }
} catch { }
if ($installType -eq 'NotDetected') {
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Office\16.0\Outlook', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\16.0\Outlook',
                     'HKLM:\SOFTWARE\Microsoft\Office\15.0\Outlook', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\15.0\Outlook')) {
        $b = $null
        try { $b = (Get-ItemProperty -Path $k -Name Bitness -ErrorAction Stop).Bitness } catch { }
        if ($b) { $officeBitness = "$b"; $installType = 'MSI'; break }
    }
}
Write-Status "Installed Office: $installType / $officeBitness" $(if ($installType -eq 'NotDetected') { 'WARN' } else { 'OK' })

# ---------------- Enumerate COM / VSTO add-ins ----------------
$apps = @('Word', 'Excel', 'PowerPoint', 'Outlook', 'Access', 'Visio', 'MS Project', 'OneNote', 'Publisher')
$hives = @(
    @{ Scope = 'HKLM-64';  Base = 'HKLM:\SOFTWARE\Microsoft\Office' },
    @{ Scope = 'HKLM-32';  Base = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office' },
    @{ Scope = 'HKCU';     Base = 'HKCU:\Software\Microsoft\Office' },
    @{ Scope = 'C2R-HKLM'; Base = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\REGISTRY\MACHINE\Software\Microsoft\Office' },
    @{ Scope = 'C2R-HKLM-32'; Base = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\REGISTRY\MACHINE\Software\Wow6432Node\Microsoft\Office' }
)

$rows = New-Object System.Collections.Generic.List[object]

foreach ($h in $hives) {
    foreach ($app in $apps) {
        $addinsKey = Join-Path $h.Base "$app\Addins"
        if (-not (Test-Path -LiteralPath $addinsKey)) { continue }
        foreach ($sub in @(Get-ChildItem -LiteralPath $addinsKey -ErrorAction SilentlyContinue)) {
            $progId = $sub.PSChildName
            $friendly = $sub.GetValue('FriendlyName')
            $lb = $sub.GetValue('LoadBehavior')
            $manifest = $sub.GetValue('Manifest')
            $kind = ''; $binPath = ''; $arch = ''; $clsid = ''; $src = ''
            if ($manifest) {
                $kind = 'VSTO'
                $binPath = ("$manifest" -split '\|')[0]
                $arch = 'Neutral'
            } else {
                $res = Resolve-InprocServer -ProgId $progId
                $clsid = $res.Clsid; $binPath = $res.Path; $src = $res.Source
                if ($src -like '*LocalServer') { $kind = 'COM (out-of-process EXE)'; $arch = 'Neutral' }
                elseif ($binPath -match '(?i)mscoree\.dll$') { $kind = 'COM (.NET shim)'; $arch = 'Neutral' }
                elseif ($binPath) { $kind = 'COM (native DLL)'; $arch = Get-PEMachine -Path $binPath }
                else { $kind = 'COM'; $arch = 'Unresolved' }
            }
            # Scope implication: HKLM-32 registrations are only seen by 32-bit Office, HKLM-64 by 64-bit Office.
            $seenBy = switch -Wildcard ($h.Scope) {
                'HKLM-64'     { 'x64 Office' }
                'C2R-HKLM'    { 'C2R Office (native view)' }
                'HKLM-32'     { 'x86 Office' }
                'C2R-HKLM-32' { 'x86 Office' }
                default       { 'Both (per-user)' }
            }
            $verdict = switch ($arch) {
                'Neutral'      { 'Neutral' }
                'x86'          { if ($TargetBitness -eq 'x86') { 'Compatible' } else { 'Incompatible' } }
                'x64'          { if ($TargetBitness -eq 'x64') { 'Compatible' } else { 'Incompatible' } }
                'ARM64'        { 'Review (ARM64 binary)' }
                default        { 'Unknown' }
            }
            $advice = switch ($verdict) {
                'Incompatible' { "Obtain a $TargetBitness build from the vendor before migrating" }
                'Neutral'      { if ($kind -eq 'VSTO') { 'Managed VSTO - check vendor support and VSTO runtime on target' } else { 'Bitness-neutral registration - confirm vendor support' } }
                'Unknown'      { 'Binary not found / unreadable - possibly orphaned registration' }
                default        { '' }
            }
            if ($h.Scope -match '32$' -and $TargetBitness -eq 'x64' -and $verdict -ne 'Incompatible') {
                $advice = ($advice + '; registered only for 32-bit Office - installer must also register for 64-bit').Trim('; ')
            }
            $rows.Add([pscustomobject]@{
                Computer = $env:COMPUTERNAME; User = $env:USERNAME; App = $app; Type = $kind
                Name = $(if ($friendly) { "$friendly" } else { $progId }); ProgId = $progId; Clsid = $clsid
                RegistrationScope = $h.Scope; SeenBy = $seenBy
                LoadBehavior = $lb; LoadBehaviorText = Get-LoadBehaviorText $lb
                Path = $binPath; ResolvedFrom = $src; BinaryArch = $arch
                InstalledOffice = "$installType/$officeBitness"; Target = $TargetBitness
                Verdict = $verdict; Advice = $advice
            })
        }
    }
}

# ---------------- Excel XLL / XLAM via OPENx ----------------
foreach ($ver in @('16.0', '15.0')) {
    $optKey = "HKCU:\Software\Microsoft\Office\$ver\Excel\Options"
    if (-not (Test-Path $optKey)) { continue }
    $opt = Get-Item -LiteralPath $optKey
    foreach ($vn in @($opt.GetValueNames() | Where-Object { $_ -match '^OPEN\d*$' })) {
        $raw = "$($opt.GetValue($vn))"
        $path = $raw
        if ($raw -match '"([^"]+)"') { $path = $Matches[1] } else { $path = ($raw -replace '^/\S+\s+', '').Trim() }
        $path = [Environment]::ExpandEnvironmentVariables($path)
        $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
        if ($ext -eq '.xll') {
            $arch = Get-PEMachine -Path $path
            $type = 'Excel XLL (native)'
            $verdict = switch ($arch) {
                'x86' { if ($TargetBitness -eq 'x86') { 'Compatible' } else { 'Incompatible' } }
                'x64' { if ($TargetBitness -eq 'x64') { 'Compatible' } else { 'Incompatible' } }
                default { 'Unknown' }
            }
            $advice = if ($verdict -eq 'Incompatible') { "Need $TargetBitness XLL (vendors usually ship *-x64.xll / *64.xll)" } elseif ($verdict -eq 'Unknown') { 'XLL not found - stale OPEN entry?' } else { '' }
        } else {
            $arch = 'Neutral'
            $type = "Excel add-in ($ext)"
            $verdict = 'Review'
            $advice = 'VBA add-in - check Declare statements use PtrSafe/LongPtr for 64-bit'
        }
        $rows.Add([pscustomobject]@{
            Computer = $env:COMPUTERNAME; User = $env:USERNAME; App = 'Excel'; Type = $type
            Name = [IO.Path]::GetFileName($path); ProgId = ''; Clsid = ''
            RegistrationScope = "HKCU $ver Options\$vn"; SeenBy = 'Both (per-user)'
            LoadBehavior = $null; LoadBehaviorText = 'Opened at startup'
            Path = $path; ResolvedFrom = $raw; BinaryArch = $arch
            InstalledOffice = "$installType/$officeBitness"; Target = $TargetBitness
            Verdict = $verdict; Advice = $advice
        })
    }
}

# ---------------- Resiliency ----------------
foreach ($app in @('Word', 'Excel', 'PowerPoint', 'Outlook')) {
    $dis = "HKCU:\Software\Microsoft\Office\16.0\$app\Resiliency\DisabledItems"
    $n = 0
    if (Test-Path $dis) { $n = @((Get-Item $dis).GetValueNames()).Count }
    if ($n -gt 0) { Write-Status "$app has $n Resiliency DisabledItems entries (hard-disabled add-ins/docs)" 'WARN' }
    foreach ($pk in @("HKCU:\Software\Microsoft\Office\16.0\$app\Resiliency\DoNotDisableAddinList",
                      "HKCU:\Software\Policies\Microsoft\Office\16.0\$app\Resiliency\AddinList")) {
        if (Test-Path $pk) {
            $names = @((Get-Item $pk).GetValueNames() | Where-Object { $_ }) -join ', '
            if ($names) { Write-Status "$app keep-enabled list ($pk): $names" 'INFO' }
        }
    }
}

# ---------------- Report ----------------
if ($rows.Count -eq 0) {
    Write-Status 'No COM/VSTO/XLL add-in registrations found for this user/machine' 'OK'
} else {
    $active = @($rows | Where-Object { $IncludeDisabled -or $null -eq $_.LoadBehavior -or ([int]$_.LoadBehavior -band 1) -or [int]$_.LoadBehavior -in 3, 9, 16 })
    $bad = @($active | Where-Object { $_.Verdict -eq 'Incompatible' })
    $unk = @($active | Where-Object { $_.Verdict -in 'Unknown', 'Review', 'Review (ARM64 binary)' })
    foreach ($r in $bad) { Write-Status ("INCOMPATIBLE: {0} [{1}] {2} -> {3}" -f $r.Name, $r.App, $r.BinaryArch, $r.Path) 'ERROR' }
    foreach ($r in $unk) { Write-Status ("Review: {0} [{1}] {2}" -f $r.Name, $r.App, $r.Advice) 'WARN' }
    Write-Status ("{0} registrations, {1} active; {2} incompatible with {3}, {4} need review" -f $rows.Count, $active.Count, $bad.Count, $TargetBitness, $unk.Count) $(if ($bad.Count) { 'ERROR' } elseif ($unk.Count) { 'WARN' } else { 'OK' })
}

$csv = Join-Path $OutputPath ("OfficeAddinInventory-{0}-{1}-{2}.csv" -f $env:COMPUTERNAME, $env:USERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "Report written: $csv" 'OK'
