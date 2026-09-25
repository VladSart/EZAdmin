<#
.SYNOPSIS
    Scans MSI packages (local folder or UNC share) for VBScript custom actions that will fail once the
    VBSCRIPT Feature on Demand is disabled or removed.

.DESCRIPTION
    Companion to Windows/Troubleshooting/VBScriptDeprecation-A.md / -B.md. Fills the gap that
    Get-VBScriptDependencyAudit.ps1 documents: MSI custom actions don't leave .vbs files on disk, and the
    VBScriptDeprecationAlert event 4096 only fires once the package has actually run. This script finds them
    statically, before an install, repair or uninstall breaks with error 1720/1721.

    How it classifies: the CustomAction.Type column is a bit field. The low 3 bits are the code type
    (1 DLL, 2 EXE, 5 JScript, 6 VBScript, 7 install), bits 0x30 are the source (Binary table / installed file /
    directory-text / property), and higher bits are scheduling flags (deferred +1024, no-impersonate +2048,
    and others). Exact-match lists such as 6/38/50 or 6/38/54 miss deferred variants (for example 1030, 3078),
    so this script tests (Type -band 7). VBScript = 6, JScript = 5 (reported separately with -IncludeJScript).

    Also reports, per package: ProductName, ProductVersion, Manufacturer, ProductCode (Property table), the
    custom action's Source/Target (script text is truncated) and the source kind decoded from bits 0x30.

    Read-only: databases are opened in read-only mode (0). No installs, no changes.

.PARAMETER Path
    One or more folders (local or UNC) to scan recursively for *.msi. Also accepts individual .msi paths.

.PARAMETER IncludeJScript
    Also report JScript custom actions (type 5). JScript is a separate engine and not part of the VBSCRIPT FOD,
    but it's often retired alongside it.

.PARAMETER OutputPath
    Folder for CSV output. Default: current directory.

.EXAMPLE
    .\Find-MsiVBScriptCustomAction.ps1 -Path '\\fs01\Packages' -OutputPath C:\Temp\MsiVbs

.EXAMPLE
    .\Find-MsiVBScriptCustomAction.ps1 -Path 'C:\Windows\Installer' -OutputPath C:\Temp\MsiVbs
    Scans the locally cached MSI copies of installed products (useful for "what will fail on uninstall/repair").

.NOTES
    Requires : Windows PowerShell 5.1 or PowerShell 7 on Windows (WindowsInstaller.Installer COM object).
    Run-as   : Any user with read access to the packages. C:\Windows\Installer needs an elevated session.
    Safe     : Read-only.
    Output   : MsiScriptCustomActions.csv (one row per custom action), MsiScanSummary.csv (one row per package)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,
    [switch]$IncludeJScript,
    [string]$OutputPath = '.'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Invoke-Com {
    param($Object, [string]$Member, [string]$Kind, [object[]]$Arguments)
    $flag = if ($Kind -eq 'Get') { [Reflection.BindingFlags]::GetProperty } else { [Reflection.BindingFlags]::InvokeMethod }
    return $Object.GetType().InvokeMember($Member, $flag, $null, $Object, $Arguments)
}

function Get-MsiQueryRows {
    # Returns an array of string arrays for a SELECT against an open database. Empty array if the table is missing.
    param($Database, [string]$Sql, [int]$ColumnCount)
    $rows = New-Object System.Collections.Generic.List[object]
    $view = $null
    try {
        $view = Invoke-Com $Database 'OpenView' 'Method' @($Sql)
        [void](Invoke-Com $view 'Execute' 'Method' $null)
        while ($true) {
            $rec = Invoke-Com $view 'Fetch' 'Method' $null
            if ($null -eq $rec) { break }
            $vals = New-Object string[] $ColumnCount
            for ($i = 1; $i -le $ColumnCount; $i++) { $vals[$i - 1] = [string](Invoke-Com $rec 'StringData' 'Get' @($i)) }
            $rows.Add($vals)
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rec)
        }
    } catch {
        Write-Verbose "Query failed ($Sql): $($_.Exception.Message)"
    } finally {
        if ($view) {
            try { [void](Invoke-Com $view 'Close' 'Method' $null) } catch { }
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view)
        }
    }
    return , $rows.ToArray()
}

# ---------------------------------------------------------------- Preflight
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$msiFiles = New-Object System.Collections.Generic.List[object]
foreach ($p in $Path) {
    if (-not (Test-Path $p)) { Write-Status "Not found, skipped: $p" 'WARN'; continue }
    $item = Get-Item $p
    if ($item.PSIsContainer) {
        foreach ($f in @(Get-ChildItem -Path $p -Recurse -File -Filter '*.msi' -ErrorAction SilentlyContinue)) { $msiFiles.Add($f) }
    } elseif ($item.Extension -ieq '.msi') { $msiFiles.Add($item) }
}
Write-Status "$($msiFiles.Count) MSI package(s) to scan"
if ($msiFiles.Count -eq 0) { return }

$installer = New-Object -ComObject WindowsInstaller.Installer
$sourceKinds = @{ 0x00 = 'BinaryTable'; 0x10 = 'InstalledFile'; 0x20 = 'Directory/Text'; 0x30 = 'Property' }
$actionRows = New-Object System.Collections.Generic.List[object]
$pkgRows = New-Object System.Collections.Generic.List[object]
$n = 0

# ---------------------------------------------------------------- Scan
foreach ($msi in $msiFiles) {
    $n++
    Write-Progress -Activity 'Scanning MSI custom actions' -Status $msi.Name -PercentComplete ([int](100 * $n / $msiFiles.Count))
    $db = $null
    $pkg = [ordered]@{ Package = $msi.FullName; ProductName = ''; ProductVersion = ''; Manufacturer = ''; ProductCode = ''; VBScriptActions = 0; JScriptActions = 0; Status = 'OK' }
    try {
        $db = Invoke-Com $installer 'OpenDatabase' 'Method' @($msi.FullName, 0)
        foreach ($r in (Get-MsiQueryRows $db "SELECT ``Property``, ``Value`` FROM ``Property`` WHERE ``Property``='ProductName' OR ``Property``='ProductVersion' OR ``Property``='Manufacturer' OR ``Property``='ProductCode'" 2)) {
            $pkg[$r[0]] = $r[1]
        }
        foreach ($r in (Get-MsiQueryRows $db 'SELECT `Action`, `Type`, `Source`, `Target` FROM `CustomAction`' 4)) {
            $type = 0
            if (-not [int]::TryParse($r[1], [ref]$type)) { continue }
            $code = $type -band 7
            if ($code -ne 6 -and -not ($IncludeJScript -and $code -eq 5)) { continue }
            $engine = if ($code -eq 6) { 'VBScript' } else { 'JScript' }
            if ($code -eq 6) { $pkg['VBScriptActions'] = $pkg['VBScriptActions'] + 1 } else { $pkg['JScriptActions'] = $pkg['JScriptActions'] + 1 }
            $target = $r[3]
            if ($target.Length -gt 200) { $target = $target.Substring(0, 200) + '...' }
            $actionRows.Add([pscustomobject]@{
                Package        = $msi.FullName
                ProductName    = $pkg.ProductName
                ProductVersion = $pkg.ProductVersion
                Action         = $r[0]
                Type           = $type
                Engine         = $engine
                SourceKind     = $sourceKinds[($type -band 0x30)]
                Deferred       = [bool]($type -band 0x400)
                NoImpersonate  = [bool]($type -band 0x800)
                Source         = $r[2]
                TargetPreview  = ($target -replace '\s+', ' ')
            })
        }
    } catch {
        $pkg['Status'] = "Error: $($_.Exception.Message)"
        Write-Status "Could not open $($msi.FullName): $($_.Exception.Message)" 'WARN'
    } finally {
        if ($db) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db) }
    }
    $pkgRows.Add([pscustomobject]$pkg)
}
Write-Progress -Activity 'Scanning MSI custom actions' -Completed
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer)

# ---------------------------------------------------------------- Report
$actionRows | Export-Csv (Join-Path $OutputPath 'MsiScriptCustomActions.csv') -NoTypeInformation
$pkgRows | Export-Csv (Join-Path $OutputPath 'MsiScanSummary.csv') -NoTypeInformation
$affected = @($pkgRows | Where-Object { $_.VBScriptActions -gt 0 })
$errors = @($pkgRows | Where-Object { $_.Status -ne 'OK' })
Write-Status ("Packages scanned: {0} | with VBScript custom actions: {1} | unreadable: {2}" -f $pkgRows.Count, $affected.Count, $errors.Count) $(if ($affected.Count -gt 0) { 'WARN' } else { 'OK' })
if ($affected.Count -gt 0) {
    $affected | Sort-Object VBScriptActions -Descending | Select-Object -First 15 ProductName, ProductVersion, VBScriptActions, Package | Format-Table -AutoSize | Out-String | Write-Host
    Write-Status 'These packages will fail install/repair/uninstall without the VBSCRIPT FOD. Get vendor updates, repackage, or keep a scoped FOD exception.' 'WARN'
}
