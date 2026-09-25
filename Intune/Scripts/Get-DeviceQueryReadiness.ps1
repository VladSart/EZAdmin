<#
.SYNOPSIS
    Checks a Windows device's readiness for Intune Device query (single-device live query and multi-device inventory).

.DESCRIPTION
    Read-only, device-local. Evaluates the documented prerequisites that can be seen from the device:
      - OS is Windows; Entra joined or Entra hybrid joined (dsregcmd /status)
      - Intune MDM enrollment present (EnterpriseMgmt enrollment keys)
      - WNS transport: WpnService state/start type, TCP 443 to the WNS endpoint(s), and the
        "Turn off notifications network usage" policy (NoCloudApplicationNotification) in HKLM/HKCU
      - Multi-device (Windows) inventory collector: Microsoft Device Inventory Agent folder present
      - WinHTTP proxy (SSL inspection of WNS commonly breaks live query)

    It cannot see: Advanced Analytics licensing, admin RBAC (Managed Devices/Query), device ownership
    (Corporate/Personal — an Intune-side attribute), Endpoint analytics onboarding state, or throttling.
    Use -DeviceName with an existing Graph session (-CheckOwnershipViaGraph) to add the ownership check.

.PARAMETER WnsHosts
    Hosts to test on TCP 443. Default: client.wns.windows.com.

.PARAMETER CheckOwnershipViaGraph
    Also query Intune (Graph) for this device's ownership. Requires Microsoft.Graph.DeviceManagement and an
    existing Connect-MgGraph session with DeviceManagementManagedDevices.Read.All. Does not call Connect-MgGraph.

.PARAMETER ExportPath
    CSV path. Default: $env:TEMP\DeviceQueryReadiness-<computer>-<yyyyMMdd-HHmm>.csv

.EXAMPLE
    .\Get-DeviceQueryReadiness.ps1
    Local checks only (suitable for RMM / Remediation detection).

.EXAMPLE
    Connect-MgGraph -Scopes DeviceManagementManagedDevices.Read.All
    .\Get-DeviceQueryReadiness.ps1 -CheckOwnershipViaGraph

.NOTES
    Run elevated for complete results (HKLM enrollment keys). Safe: makes no changes.
    Companion runbooks: Intune/Troubleshooting/DeviceQuery-B.md and DeviceQuery-A.md.
#>
[CmdletBinding()]
param(
    [string[]]$WnsHosts = @('client.wns.windows.com'),
    [switch]$CheckOwnershipViaGraph,
    [string]$ExportPath = (Join-Path $env:TEMP ("DeviceQueryReadiness-{0}-{1:yyyyMMdd-HHmm}.csv" -f $env:COMPUTERNAME, (Get-Date)))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail, [string]$AppliesTo)
    $results.Add([pscustomobject]@{ Computer=$env:COMPUTERNAME; Check=$Check; Status=$Status; AppliesTo=$AppliesTo; Detail=$Detail })
    Write-Status "$Check — $Detail" $Status
}

# ---------------- Preflight ----------------
if ($env:OS -ne 'Windows_NT') { Write-Status "Windows only." "ERROR"; return }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Status "Not elevated — enrollment checks may be incomplete." "WARN" }

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Add-Result 'OS' 'INFO' ("{0} {1} build {2}.{3}" -f $cv.ProductName, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR) 'Both'

# ---------------- Join state ----------------
$ds = (dsregcmd /status) -join "`n"
$aadJoined = $ds -match 'AzureAdJoined\s*:\s*YES'
$domJoined = $ds -match 'DomainJoined\s*:\s*YES'
$tenant = if ($ds -match 'TenantName\s*:\s*(.+)') { $Matches[1].Trim() } else { '' }
if ($aadJoined) {
    $jt = if ($domJoined) { 'Entra hybrid joined' } else { 'Entra joined' }
    Add-Result 'JoinType' 'OK' "$jt (tenant: $tenant)" 'Single'
} else {
    Add-Result 'JoinType' 'ERROR' "Not Entra joined/hybrid joined (DomainJoined=$domJoined). Single-device query unsupported." 'Single'
}

# ---------------- MDM enrollment ----------------
$enrollments = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Enrollments') {
    $enrollments = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.PSObject.Properties['ProviderID'] -and $p.ProviderID -eq 'MS DM Server') { $p }
    })
}
if ($enrollments.Count -gt 0) {
    $upn = if ($enrollments[0].PSObject.Properties['UPN']) { $enrollments[0].UPN } else { 'n/a' }
    Add-Result 'IntuneEnrollment' 'OK' "MDM enrollment found (UPN: $upn)" 'Both'
} else {
    Add-Result 'IntuneEnrollment' 'ERROR' 'No Intune (MS DM Server) enrollment found' 'Both'
}

# ---------------- WNS transport ----------------
$svc = Get-Service -Name WpnService -ErrorAction SilentlyContinue
if (-not $svc) {
    Add-Result 'WpnService' 'ERROR' 'Windows Push Notifications System Service not present' 'Single'
} else {
    $st = if ($svc.Status -eq 'Running' -and $svc.StartType -ne 'Disabled') { 'OK' } else { 'ERROR' }
    Add-Result 'WpnService' $st "Status=$($svc.Status) StartType=$($svc.StartType)" 'Single'
}

foreach ($h in $WnsHosts) {
    try {
        $t = Test-NetConnection -ComputerName $h -Port 443 -WarningAction SilentlyContinue
        $st = if ($t.TcpTestSucceeded) { 'OK' } else { 'ERROR' }
        Add-Result "WNS-443:$h" $st ("TcpTestSucceeded={0} RemoteAddress={1}" -f $t.TcpTestSucceeded, $t.RemoteAddress) 'Single'
    } catch {
        Add-Result "WNS-443:$h" 'ERROR' $_.Exception.Message 'Single'
    }
}

$policyHit = $false
foreach ($hive in 'HKLM','HKCU') {
    $path = "${hive}:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"
    if (Test-Path $path) {
        $p = Get-ItemProperty $path
        if ($p.PSObject.Properties['NoCloudApplicationNotification'] -and $p.NoCloudApplicationNotification -eq 1) {
            $policyHit = $true
            Add-Result "WNSPolicy:$hive" 'ERROR' 'NoCloudApplicationNotification=1 (notifications network usage turned off by policy)' 'Single'
        }
    }
}
if (-not $policyHit) { Add-Result 'WNSPolicy' 'OK' 'No NoCloudApplicationNotification=1 found (HKLM/HKCU)' 'Single' }

$proxy = ((netsh winhttp show proxy) -join ' ') -replace '\s+', ' '
$pst = if ($proxy -match 'Direct access') { 'OK' } else { 'WARN' }
Add-Result 'WinHTTPProxy' $pst "$proxy — if proxied, exclude *.wns.windows.com / *.notify.windows.com from TLS inspection" 'Single'

# ---------------- Multi-device inventory collector ----------------
$agent = 'C:\Program Files\Microsoft Device Inventory Agent'
if (Test-Path $agent) {
    $latest = Get-ChildItem $agent -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $when = if ($latest) { $latest.LastWriteTime.ToString('s') } else { 'n/a' }
    Add-Result 'DeviceInventoryAgent' 'OK' "Present; newest file write $when" 'Multi'
} else {
    Add-Result 'DeviceInventoryAgent' 'WARN' 'Not present — no properties catalog policy applied yet; Windows rows will be missing from multi-device query' 'Multi'
}

# ---------------- Optional: ownership via Graph ----------------
if ($CheckOwnershipViaGraph) {
    if (-not (Get-Command Get-MgDeviceManagementManagedDevice -ErrorAction SilentlyContinue)) {
        Add-Result 'Ownership' 'WARN' 'Microsoft.Graph.DeviceManagement module not available' 'Both'
    } elseif (-not (Get-MgContext)) {
        Add-Result 'Ownership' 'WARN' 'No Graph session (Connect-MgGraph -Scopes DeviceManagementManagedDevices.Read.All)' 'Both'
    } else {
        try {
            $md = @(Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$($env:COMPUTERNAME)'" -ErrorAction Stop)
            if ($md.Count -eq 0) {
                Add-Result 'Ownership' 'WARN' "No Intune record named $env:COMPUTERNAME" 'Both'
            } else {
                foreach ($d in $md) {
                    $st = if ("$($d.ManagedDeviceOwnerType)" -eq 'company') { 'OK' } else { 'ERROR' }
                    Add-Result 'Ownership' $st ("IntuneId={0} Owner={1} LastSync={2}" -f $d.Id, $d.ManagedDeviceOwnerType, $d.LastSyncDateTime) 'Both'
                }
            }
        } catch {
            Add-Result 'Ownership' 'WARN' $_.Exception.Message 'Both'
        }
    }
} else {
    Add-Result 'Ownership' 'INFO' 'Not checked — must be Corporate in Intune (use -CheckOwnershipViaGraph or check the portal)' 'Both'
}

# ---------------- Report ----------------
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
$errs = @($results | Where-Object Status -eq 'ERROR')
$single = if (@($errs | Where-Object { $_.AppliesTo -in 'Single','Both' }).Count -eq 0) { 'LIKELY READY' } else { 'BLOCKED' }
$multi  = if (@($results | Where-Object { $_.AppliesTo -in 'Multi','Both' -and $_.Status -in 'ERROR','WARN' -and $_.Check -ne 'Ownership' }).Count -eq 0) { 'LIKELY READY' } else { 'CHECK' }
Write-Status "Single-device query (device-side): $single" $(if ($single -eq 'LIKELY READY') {'OK'} else {'ERROR'})
Write-Status "Multi-device query (Windows inventory): $multi" $(if ($multi -eq 'LIKELY READY') {'OK'} else {'WARN'})
Write-Status "Tenant-side prerequisites (Advanced Analytics licence, RBAC Managed Devices/Query) are not visible from the device." "INFO"
Write-Status "Exported to $ExportPath" "OK"
