<#
.SYNOPSIS
    Reports Known Issue Rollback (KIR) activation state across one or more Windows devices.

.DESCRIPTION
    Read-only audit that answers "is the KIR actually active on this device?" by checking every layer:
      - OS build.UBR and whether a specified regressing KB is installed
      - KIR policy override values under HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides
        (optionally matching a specific feature ID)
      - Whether the device restarted AFTER the override key was last written (KIR requires a restart)
      - Locally present KIR ADMX files (GPO path) and MDM-ingested ADMX (Intune path)
      - Management channel hint (domain-joined / MDM-enrolled)
    and classifies each device as Active / PendingRestart / NotDelivered / NotNeeded / Unreachable.

    The restart check uses the registry key's LastWriteTime (read via the RegQueryInfoKey Win32 API), which is the best on-device
    signal available; it can be skewed if other values under the same key change later.

    It does NOT install MSIs, change policy, or restart devices.

.PARAMETER ComputerName
    Target device(s). Default: local machine.

.PARAMETER KB
    Optional regressing KB (e.g. KB5122882). If supplied and not installed, device is classed NotNeeded.

.PARAMETER FeatureId
    Optional numeric feature ID expected from the KIR ADMX. If supplied, only that value counts as "delivered".

.PARAMETER OutputPath
    Folder for the CSV report. Default C:\Temp.

.EXAMPLE
    .\Get-KnownIssueRollbackStatus.ps1
    Local device, any KIR override.

.EXAMPLE
    .\Get-KnownIssueRollbackStatus.ps1 -ComputerName (Get-Content .\servers.txt) -KB KB5123099
    Fleet check for the Server 2016 September 2026 RDS KIR.

.NOTES
    Requires: PowerShell 5.1+, WinRM for remote targets, local admin on targets.
    Safe: read-only.
    Reference: https://learn.microsoft.com/en-us/troubleshoot/windows-client/group-policy/use-group-policy-to-deploy-known-issue-rollback
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [ValidatePattern('^KB\d{6,8}$')][string]$KB,
    [ValidatePattern('^\d+$')][string]$FeatureId,
    [string]$OutputPath = 'C:\Temp'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------- Preflight ----------
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
Write-Status ("Targets: {0} | KB filter: {1} | FeatureId filter: {2}" -f $ComputerName.Count, ($(if ($KB) {$KB} else {'<none>'})), ($(if ($FeatureId) {$FeatureId} else {'<any>'})))

# ---------- Detect ----------
$probe = {
    param($KB, $FeatureId)
    Set-StrictMode -Off
    $ErrorActionPreference = 'SilentlyContinue'
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $kbInstalled = $null
    if ($KB) { $kbInstalled = [bool](Get-HotFix -Id $KB) }

    $keyPath = 'SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides'
    $values = @(); $keyWrite = $null
    $rk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath)
    if ($rk) {
        foreach ($n in $rk.GetValueNames()) { $values += ('{0}={1}' -f $n, $rk.GetValue($n)) }
        $rk.Close()
        # Key LastWriteTime is not exposed by .NET Framework RegistryKey; read it via RegQueryInfoKey P/Invoke
        try {
            $sig = @'
using System; using System.Runtime.InteropServices;
public static class RegTime {
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
  public static extern int RegOpenKeyEx(UIntPtr hKey, string subKey, int opt, int sam, out UIntPtr res);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
  public static extern int RegQueryInfoKey(UIntPtr hKey, IntPtr c, IntPtr cl, IntPtr r, IntPtr sk, IntPtr msk, IntPtr mcl, IntPtr v, IntPtr mvn, IntPtr mvl, IntPtr sd, out long ft);
  [DllImport("advapi32.dll")] public static extern int RegCloseKey(UIntPtr hKey);
  public static DateTime Get(string sub) {
    UIntPtr h; if (RegOpenKeyEx(new UIntPtr(0x80000002u), sub, 0, 0x20019, out h) != 0) return DateTime.MinValue;
    long ft; RegQueryInfoKey(h, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out ft);
    RegCloseKey(h); return DateTime.FromFileTime(ft);
  }
}
'@
            if (-not ('RegTime' -as [type])) { Add-Type -TypeDefinition $sig -ErrorAction Stop }
            $t = [RegTime]::Get($keyPath)
            if ($t -ne [DateTime]::MinValue) { $keyWrite = $t }
        } catch { $keyWrite = $null }
    }

    $matchFeature = if ($FeatureId) { [bool]($values | Where-Object { $_ -like "$FeatureId=*" }) } else { $values.Count -gt 0 }
    $localAdmx = @(Get-ChildItem "$env:windir\PolicyDefinitions" -Filter '*Rollback*.admx' | Select-Object -ExpandProperty Name) -join ';'
    $mdmAdmx   = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled' -Recurse |
                    Where-Object { $_.PSChildName -match 'KIR|KnownIssueRollback' } | Select-Object -ExpandProperty PSChildName -Unique) -join ';'
    $cs = Get-CimInstance Win32_ComputerSystem
    $mdm = [bool](Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' | Where-Object { (Get-ItemProperty $_.PSPath).ProviderID -eq 'MS DM Server' })

    [pscustomobject]@{
        OS            = "$($cv.ProductName) $($cv.DisplayVersion)"
        BuildUBR      = "$($cv.CurrentBuild).$($cv.UBR)"
        KBInstalled   = $kbInstalled
        OverrideVals  = ($values -join ';')
        FeatureMatch  = $matchFeature
        KeyLastWrite  = $keyWrite
        LastBoot      = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        LocalKirAdmx  = $localAdmx
        MdmKirAdmx    = $mdmAdmx
        DomainJoined  = [bool]$cs.PartOfDomain
        MdmEnrolled   = $mdm
    }
}

# ---------- Execute ----------
$results = foreach ($c in $ComputerName) {
    try {
        if ($c -in @($env:COMPUTERNAME, 'localhost', '.')) { $r = & $probe $KB $FeatureId }
        else { $r = Invoke-Command -ComputerName $c -ScriptBlock $probe -ArgumentList $KB, $FeatureId -ErrorAction Stop }

        # ---------- Validate / classify ----------
        $status =
            if ($KB -and $r.KBInstalled -eq $false) { 'NotNeeded' }
            elseif (-not $r.FeatureMatch) { 'NotDelivered' }
            elseif ($r.KeyLastWrite -and $r.LastBoot -and ($r.LastBoot -lt $r.KeyLastWrite)) { 'PendingRestart' }
            else { 'Active' }
        $action = switch ($status) {
            'Active'         { 'Verify symptom resolved; retire KIR once fixing update installed.' }
            'PendingRestart' { 'Restart device to activate KIR.' }
            'NotDelivered'   { 'Check GPO scope/ADMX (domain) or Intune Custom profile status (MDM).' }
            'NotNeeded'      { 'Regressing KB not installed.' }
        }
        $lvl = switch ($status) { 'Active'{'OK'} 'NotNeeded'{'OK'} 'PendingRestart'{'WARN'} default{'ERROR'} }
        Write-Status "$c [$($r.BuildUBR)] -> $status" $lvl

        [pscustomobject]@{
            ComputerName = $c; Status = $status; Action = $action
            OS = $r.OS; BuildUBR = $r.BuildUBR; KB = $KB; KBInstalled = $r.KBInstalled
            OverrideVals = $r.OverrideVals; KeyLastWrite = $r.KeyLastWrite; LastBoot = $r.LastBoot
            LocalKirAdmx = $r.LocalKirAdmx; MdmKirAdmx = $r.MdmKirAdmx
            DomainJoined = $r.DomainJoined; MdmEnrolled = $r.MdmEnrolled
        }
    }
    catch {
        Write-Status "$c unreachable: $($_.Exception.Message)" 'ERROR'
        [pscustomobject]@{
            ComputerName = $c; Status = 'Unreachable'; Action = 'Check WinRM / run locally'
            OS = ''; BuildUBR = ''; KB = $KB; KBInstalled = $null; OverrideVals = ''
            KeyLastWrite = $null; LastBoot = $null; LocalKirAdmx = ''; MdmKirAdmx = ''
            DomainJoined = $null; MdmEnrolled = $null
        }
    }
}

# ---------- Report ----------
$csv = Join-Path $OutputPath ("KIRStatus_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "Summary:"
$results | Group-Object Status | Sort-Object Name | ForEach-Object { Write-Status ("  {0,-15} {1}" -f $_.Name, $_.Count) }
Write-Status "Report written to $csv" 'OK'
$results
