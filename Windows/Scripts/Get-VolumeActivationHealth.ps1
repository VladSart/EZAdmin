<#
.SYNOPSIS
    Read-only Windows volume activation health check (KMS client/host, ADBA, Subscription Activation) with CSV export.

.DESCRIPTION
    Uses the SoftwareLicensingProduct / SoftwareLicensingService CIM classes (no dependency on slmgr.vbs,
    so it works where the VBScript feature has been removed) to report, per computer:
      - OS caption/build and the Windows licensing channel (RETAIL, OEM_DM, VOLUME_MAK, VOLUME_KMSCLIENT, VOLUME_KMS_<ver>)
      - License status (decoded), grace minutes remaining, last error/status reason
      - KMS client details: pinned host vs DNS-discovered host, Client Machine ID (for duplicate-CMID detection)
      - _vlmcs._tcp SRV lookup for the machine's domain and a TCP 1688 reachability test to each target
      - KMS host details if the machine is a host: current count, total/failed requests, DNS publishing, port
      - Entra join / PRT state (dsregcmd) for Subscription Activation, and whether a firmware (OA3) key exists
      - Optional: ADBA activation objects in the forest (requires ActiveDirectory module)
    Ends with a list of findings and exports one CSV row per computer.

    What it does NOT do: change keys, activate, rearm, or touch DNS. It does not export any product key
    other than the last 5 characters Windows already exposes (PartialProductKey).

.PARAMETER ComputerName
    One or more computers to query over WinRM/CIM. Defaults to the local computer.

.PARAMETER KmsTestPort
    TCP port used for the KMS reachability test. Default 1688.

.PARAMETER IncludeADBA
    Also enumerate Active Directory-Based Activation objects in the forest (runs once, locally).

.PARAMETER OutputPath
    Folder for the CSV report. Default: $env:TEMP.

.EXAMPLE
    .\Get-VolumeActivationHealth.ps1
    Checks the local machine and writes VolumeActivationHealth_<timestamp>.csv to %TEMP%.

.EXAMPLE
    .\Get-VolumeActivationHealth.ps1 -ComputerName PC01,PC02,KMS01 -IncludeADBA -OutputPath C:\Reports
    Checks three machines over WinRM, enumerates ADBA objects, and writes the CSV to C:\Reports.

.NOTES
    Requires: Windows PowerShell 5.1+. Remote targets need WinRM (CIM over WSMan).
    Run as: local admin recommended (non-admin can read most licensing CIM data; dsregcmd runs locally only).
    Safe: read-only. dsregcmd and the SRV/port tests run from the machine executing the script for remote targets,
    except dsregcmd which is only collected for the local computer.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [int]$KmsTestPort = 1688,
    [switch]$IncludeADBA,
    [string]$OutputPath = $env:TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

$statusMap = @{
    0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OOBGrace'; 3 = 'OOTGrace'
    4 = 'NonGenuineGrace'; 5 = 'Notification'; 6 = 'ExtendedGrace'
}

# ---------------- Preflight ----------------
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$csvPath = Join-Path $OutputPath "VolumeActivationHealth_$stamp.csv"
$results = New-Object System.Collections.Generic.List[object]
$findings = New-Object System.Collections.Generic.List[string]

# ---------------- ADBA (optional, once) ----------------
$adbaObjects = @()
if ($IncludeADBA) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $cfg = (Get-ADRootDSE).configurationNamingContext
        $base = "CN=Activation Objects,CN=Microsoft SPP,CN=Services,$cfg"
        $adbaObjects = @(Get-ADObject -SearchBase $base -Filter * -SearchScope OneLevel -Properties displayName, whenCreated |
            Select-Object Name, displayName, whenCreated)
        if ($adbaObjects.Count -gt 0) {
            Write-Status "ADBA: $($adbaObjects.Count) activation object(s) found" "OK"
            foreach ($o in $adbaObjects) { Write-Status "  ADBA object: $($o.displayName) (created $($o.whenCreated))" "INFO" }
        } else {
            Write-Status "ADBA: no activation objects in forest" "WARN"
            $findings.Add("Forest has no ADBA activation objects - domain clients rely on KMS discovery only.")
        }
    } catch {
        Write-Status "ADBA query failed or container absent: $($_.Exception.Message)" "WARN"
    }
}

# ---------------- Per computer ----------------
foreach ($cn in $ComputerName) {
    Write-Status "Checking $cn" "INFO"
    $isLocal = ($cn -eq $env:COMPUTERNAME -or $cn -eq 'localhost' -or $cn -eq '.')
    $row = [ordered]@{
        ComputerName = $cn; Reachable = $false; OSCaption = $null; Build = $null; Domain = $null
        ProductName = $null; Channel = $null; LicenseStatus = $null; GraceMinutes = $null; StatusReason = $null
        PartialKey = $null; KmsPinnedHost = $null; KmsDiscoveredHost = $null; ClientMachineId = $null
        IsKmsHost = $false; HostCurrentCount = $null; HostTotalRequests = $null; HostFailedRequests = $null
        HostDnsPublishing = $null; HostPort = $null; SrvTargets = $null; SrvPortReachable = $null
        FirmwareKeyPresent = $null; RearmRemaining = $null; AzureAdJoined = $null; AzureAdPrt = $null
        WorkplaceJoined = $null; Findings = $null
    }
    $local = New-Object System.Collections.Generic.List[string]

    try {
        $cimParams = @{ ErrorAction = 'Stop' }
        if (-not $isLocal) { $cimParams['ComputerName'] = $cn }

        $os  = Get-CimInstance @cimParams -ClassName Win32_OperatingSystem
        $cs  = Get-CimInstance @cimParams -ClassName Win32_ComputerSystem
        $svc = Get-CimInstance @cimParams -ClassName SoftwareLicensingService
        $prods = @(Get-CimInstance @cimParams -ClassName SoftwareLicensingProduct `
                    -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'")
        $row.Reachable = $true
        $row.OSCaption = $os.Caption
        $row.Build     = $os.BuildNumber
        $row.Domain    = $cs.Domain

        $oa3 = Get-Prop $svc 'OA3xOriginalProductKey'
        $row.FirmwareKeyPresent = [bool]($oa3)
        $row.RearmRemaining     = Get-Prop $svc 'RemainingWindowsReArmCount'
        $row.ClientMachineId    = Get-Prop $svc 'ClientMachineID'
        $row.HostDnsPublishing  = Get-Prop $svc 'KeyManagementServiceDnsPublishing'
        $row.HostPort           = Get-Prop $svc 'KeyManagementServiceListeningPort'

        # Prefer the OS product (not add-ons such as ESU) - pick the one whose Name starts with "Windows"
        $osProd = $prods | Where-Object { $_.Name -like 'Windows*' -and $_.Description -notlike '*ESU*' } | Select-Object -First 1
        if (-not $osProd) { $osProd = $prods | Select-Object -First 1 }

        # A KMS host has a product with VOLUME_KMS_ in Description (not KMSCLIENT)
        $hostProd = $prods | Where-Object { $_.Description -match 'VOLUME_KMS_' -or ($_.Description -match 'VOLUME_KMS' -and $_.Description -notmatch 'KMSCLIENT') } | Select-Object -First 1

        if ($osProd) {
            $row.ProductName   = $osProd.Name
            if ($osProd.Description -match '(RETAIL|OEM_[A-Z_]+|VOLUME_MAK|VOLUME_KMSCLIENT|VOLUME_KMS_?[A-Z0-9_]*|TIMEBASED_[A-Z]+)') { $row.Channel = $Matches[1] }
            else { $row.Channel = $osProd.Description }
            $ls = [int]$osProd.LicenseStatus
            $row.LicenseStatus = if ($statusMap.ContainsKey($ls)) { $statusMap[$ls] } else { "Unknown($ls)" }
            $row.GraceMinutes  = Get-Prop $osProd 'GracePeriodRemaining'
            $reason = Get-Prop $osProd 'LicenseStatusReason'
            if ($null -ne $reason) { $row.StatusReason = ('0x{0:X8}' -f ([uint32]$reason)) }
            $row.PartialKey        = $osProd.PartialProductKey
            $row.KmsPinnedHost     = Get-Prop $osProd 'KeyManagementServiceMachine'
            $row.KmsDiscoveredHost = Get-Prop $osProd 'DiscoveredKeyManagementServiceMachineName'
        } else {
            $local.Add("No Windows product with an installed key found.")
        }

        if ($hostProd) {
            $row.IsKmsHost          = $true
            $row.HostCurrentCount   = Get-Prop $hostProd 'KeyManagementServiceCurrentCount'
            $row.HostTotalRequests  = Get-Prop $hostProd 'KeyManagementServiceTotalRequests'
            $row.HostFailedRequests = Get-Prop $hostProd 'KeyManagementServiceFailedRequests'
            if ($null -ne $row.HostCurrentCount -and [int]$row.HostCurrentCount -lt 25) {
                $local.Add("KMS host count $($row.HostCurrentCount) is below 25 - client OS activations will fail with 0xC004F038 (servers need 5).")
            }
            if ($row.HostDnsPublishing -eq $false) { $local.Add("KMS host DNS publishing is disabled - clients won't auto-discover it (slmgr /cdns).") }
        }

        # Channel-level findings
        switch -Regex ([string]$row.Channel) {
            '^VOLUME_KMSCLIENT$' {
                if ($row.LicenseStatus -ne 'Licensed') { $local.Add("KMS client not licensed (status $($row.LicenseStatus), reason $($row.StatusReason)).") }
                if ($row.KmsPinnedHost) { $local.Add("KMS host is pinned to '$($row.KmsPinnedHost)' - verify it is live; clear with slmgr /ckms to use DNS.") }
                if ($row.FirmwareKeyPresent -and $row.OSCaption -match 'Pro') {
                    $local.Add("Pro device with firmware OEM key is running a GVLK - if this is an Entra/Intune device, reinstall the OA3 key and use Subscription Activation.")
                }
            }
            '^(RETAIL|OEM_)' {
                if ($row.LicenseStatus -ne 'Licensed') { $local.Add("Retail/OEM channel not licensed - KMS/ADBA will not apply to this key.") }
            }
            '^VOLUME_MAK$' {
                if ($row.LicenseStatus -ne 'Licensed') { $local.Add("MAK channel not licensed - run slmgr /ato or check MAK remaining count.") }
            }
        }
        if ($null -ne $row.GraceMinutes -and $row.LicenseStatus -eq 'Licensed' -and $row.Channel -eq 'VOLUME_KMSCLIENT' -and [int]$row.GraceMinutes -lt 43200) {
            $local.Add("KMS activation expires in under 30 days ($([math]::Round([int]$row.GraceMinutes/1440)) d) - client hasn't renewed recently.")
        }
    } catch {
        $row.Findings = "CIM query failed: $($_.Exception.Message)"
        Write-Status "$cn : $($row.Findings)" "ERROR"
        $results.Add([pscustomobject]$row)
        continue
    }

    # SRV discovery + port reachability (from this machine, against the target's domain)
    if ($row.Domain -and $row.Domain -ne 'WORKGROUP') {
        try {
            $srv = @(Resolve-DnsName -Type SRV "_vlmcs._tcp.$($row.Domain)" -ErrorAction Stop | Where-Object { $_.Type -eq 'SRV' })
            if ($srv.Count -gt 0) {
                $row.SrvTargets = ($srv | ForEach-Object { "$($_.NameTarget):$($_.Port)" }) -join '; '
                $reach = foreach ($s in $srv) {
                    $ok = $false
                    try { $ok = (Test-NetConnection -ComputerName $s.NameTarget -Port $KmsTestPort -WarningAction SilentlyContinue).TcpTestSucceeded } catch { $ok = $false }
                    if (-not $ok) { $local.Add("SRV target $($s.NameTarget) not reachable on TCP $KmsTestPort (stale record or firewall).") }
                    "$($s.NameTarget)=$ok"
                }
                $row.SrvPortReachable = $reach -join '; '
            } else {
                $row.SrvTargets = 'none'
            }
        } catch {
            $row.SrvTargets = 'none'
            if ($row.Channel -eq 'VOLUME_KMSCLIENT' -and -not $row.KmsPinnedHost -and $adbaObjects.Count -eq 0) {
                $local.Add("No _vlmcs._tcp SRV record for $($row.Domain) (expect 0x8007232B) and no pinned host.")
            }
        }
    }

    # Join / PRT state (local only)
    if ($isLocal) {
        try {
            $ds = dsregcmd /status 2>$null
            $get = { param($k) $l = $ds | Where-Object { $_ -match "^\s*$k\s*:" } | Select-Object -First 1; if ($l) { ($l -split ':',2)[1].Trim() } }
            $row.AzureAdJoined   = & $get 'AzureAdJoined'
            $row.AzureAdPrt      = & $get 'AzureAdPrt'
            $row.WorkplaceJoined = & $get 'WorkplaceJoined'
            if ($row.OSCaption -match 'Pro' -and $row.AzureAdJoined -eq 'YES' -and $row.AzureAdPrt -ne 'YES') {
                $local.Add("Entra-joined Pro without a PRT - Subscription Activation cannot obtain a licence token.")
            }
            if ($row.OSCaption -match 'Pro' -and $row.AzureAdJoined -ne 'YES' -and $row.WorkplaceJoined -eq 'YES') {
                $local.Add("Device is only Entra registered - Subscription Activation requires Entra join or hybrid join.")
            }
        } catch {
            Write-Status "dsregcmd not available: $($_.Exception.Message)" "WARN"
        }
    }

    $row.Findings = ($local -join ' | ')
    foreach ($f in $local) { $findings.Add("$cn : $f") }
    $lvl = if ($row.LicenseStatus -eq 'Licensed' -and $local.Count -eq 0) { 'OK' } elseif ($row.LicenseStatus -eq 'Licensed') { 'WARN' } else { 'ERROR' }
    Write-Status ("{0}: {1} | {2} | {3}" -f $cn, $row.OSCaption, $row.Channel, $row.LicenseStatus) $lvl
    $results.Add([pscustomobject]$row)
}

# ---------------- Cross-machine checks ----------------
$dupes = @($results | Where-Object { $_.ClientMachineId -and $_.Channel -eq 'VOLUME_KMSCLIENT' } |
    Group-Object ClientMachineId | Where-Object { $_.Count -gt 1 })
foreach ($d in $dupes) {
    $findings.Add("Duplicate CMID $($d.Name) on: $(($d.Group.ComputerName) -join ', ') - image not generalized; KMS counts these once.")
}

# ---------------- Report ----------------
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Report written: $csvPath" "OK"
if ($findings.Count -gt 0) {
    Write-Status "Findings ($($findings.Count)):" "WARN"
    $findings | ForEach-Object { Write-Status "  $_" "WARN" }
} else {
    Write-Status "No findings." "OK"
}
$results
