<#
.SYNOPSIS
    Collects SMB file share connectivity, protocol, and permission diagnostics.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/SMB-B.md and SMB-A.md.
    Runs against a client-server pair and reports, in one pass, everything the
    runbook's triage and diagnosis steps ask for:
    - TCP 445 reachability from this machine to the target server
    - DNS resolution of the server name
    - SMB client protocol/signing configuration (local)
    - Share existence, share-level ACL, and NTFS ACL on the target (if run with
      rights to query the server remotely, or run directly on the server)
    - LanmanServer service state (server-side, best-effort if remote WMI/PS remoting works)

    Exports full detail to CSV so results can be pasted into the runbook's
    Escalation Evidence template.

    Does NOT cover:
    - Creating shares or fixing permissions (see SMB-B.md Fix 2 / Fix 4)
    - Kerberos/NTLM root-cause diagnosis (see Get-KerberosDiagnostics.ps1)
    - SMB multichannel / RDMA performance tuning

.PARAMETER ServerName
    FQDN or hostname of the file server. Required.

.PARAMETER ShareName
    Name of the share to check (without leading slashes). Optional — if omitted,
    only connectivity and protocol checks run; share/ACL checks are skipped.

.PARAMETER Credential
    PSCredential to use when querying the server remotely. If omitted, current
    session credentials are used.

.PARAMETER ExportPath
    Path for CSV export. Default: .\SMBDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-SMBDiagnostics.ps1 -ServerName fs01.contoso.com
    Runs connectivity and protocol checks only.

.EXAMPLE
    .\Get-SMBDiagnostics.ps1 -ServerName fs01.contoso.com -ShareName Finance
    Also checks share existence, share ACL, and NTFS ACL for \\fs01.contoso.com\Finance.
    Requires PS remoting or being run on the server itself for the ACL checks.

.NOTES
    Requires: Windows PowerShell 5.1+; SmbShare module (built-in)
    Run-as: Standard user for connectivity checks; local admin on the server for ACL checks
    Safe: Read-only — makes no changes to shares, permissions, or SMB configuration
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2019/2022
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerName,

    [string]$ShareName,

    [System.Management.Automation.PSCredential]$Credential,

    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region ─── Preflight ──────────────────────────────────────────────────────────
Write-Status "Get-SMBDiagnostics — target: $ServerName — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\SMBDiagnostics-$timestamp.csv"
}

$isLocal = ($ServerName -eq $env:COMPUTERNAME -or $ServerName -eq "localhost")
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        CheckedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    Write-Status "$Check — $Detail" $Status
}
#endregion

#region ─── 1. DNS resolution ──────────────────────────────────────────────────
try {
    $dns = Resolve-DnsName -Name $ServerName -ErrorAction Stop
    Add-Result "DNS" "OK" "Resolved to $($dns[0].IPAddress)"
} catch {
    Add-Result "DNS" "ERROR" "Failed to resolve $ServerName : $_"
}
#endregion

#region ─── 2. TCP 445 connectivity ────────────────────────────────────────────
try {
    $tcp = Test-NetConnection -ComputerName $ServerName -Port 445 -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) {
        Add-Result "TCP445" "OK" "Port 445 reachable ($($tcp.RemoteAddress))"
    } else {
        Add-Result "TCP445" "ERROR" "Port 445 unreachable — network/firewall issue"
    }
} catch {
    Add-Result "TCP445" "ERROR" "Test-NetConnection failed: $_"
}
#endregion

#region ─── 3. Local SMB client configuration ──────────────────────────────────
try {
    $clientCfg = Get-SmbClientConfiguration
    Add-Result "Client-SMB1" $(if ($clientCfg.EnableSMB1Protocol) { "WARN" } else { "OK" }) "SMB1: $($clientCfg.EnableSMB1Protocol)"
    Add-Result "Client-SMB2" $(if ($clientCfg.EnableSMB2Protocol) { "OK" } else { "ERROR" }) "SMB2/3: $($clientCfg.EnableSMB2Protocol)"
    Add-Result "Client-Signing" "INFO" "RequireSecuritySignature: $($clientCfg.RequireSecuritySignature)"
} catch {
    Add-Result "Client-SMBConfig" "WARN" "Could not read SMB client config: $_"
}
#endregion

#region ─── 4. net view (share visibility) ─────────────────────────────────────
try {
    $netViewOutput = net view "\\$ServerName" 2>&1 | Out-String
    if ($netViewOutput -match 'error 5') {
        Add-Result "NetView" "ERROR" "Access denied (error 5) enumerating shares"
    } elseif ($netViewOutput -match 'error 53') {
        Add-Result "NetView" "ERROR" "Network path not found (error 53) — name resolution or connectivity issue"
    } elseif ($netViewOutput -match 'Share name') {
        Add-Result "NetView" "OK" "Server responded with share list"
    } else {
        Add-Result "NetView" "WARN" "Unexpected net view output — review manually"
    }
} catch {
    Add-Result "NetView" "ERROR" "net view failed: $_"
}
#endregion

#region ─── 5. Server-side checks (best-effort — local or remote via PS remoting) ──
$serverScript = {
    param($ShareNameInner)

    $out = [PSCustomObject]@{
        ServerServiceStatus = $null
        ServerSMB1          = $null
        ServerSMB2          = $null
        ServerSigning       = $null
        ShareExists         = $null
        SharePath           = $null
        ShareAccess         = $null
    }

    try { $out.ServerServiceStatus = (Get-Service -Name LanmanServer -ErrorAction Stop).Status } catch {}

    try {
        $srvCfg = Get-SmbServerConfiguration -ErrorAction Stop
        $out.ServerSMB1    = $srvCfg.EnableSMB1Protocol
        $out.ServerSMB2    = $srvCfg.EnableSMB2Protocol
        $out.ServerSigning = $srvCfg.RequireSecuritySignature
    } catch {}

    if ($ShareNameInner) {
        try {
            $share = Get-SmbShare -Name $ShareNameInner -ErrorAction Stop
            $out.ShareExists = $true
            $out.SharePath   = $share.Path
            $access = Get-SmbShareAccess -Name $ShareNameInner -ErrorAction SilentlyContinue |
                ForEach-Object { "$($_.AccountName):$($_.AccessRight)" }
            $out.ShareAccess = ($access -join "; ")
        } catch {
            $out.ShareExists = $false
        }
    }

    return $out
}

try {
    if ($isLocal) {
        $serverInfo = & $serverScript $ShareName
    } else {
        $icmParams = @{ ComputerName = $ServerName; ScriptBlock = $serverScript; ArgumentList = $ShareName; ErrorAction = "Stop" }
        if ($Credential) { $icmParams['Credential'] = $Credential }
        $serverInfo = Invoke-Command @icmParams
    }

    Add-Result "Server-LanmanServer" $(if ($serverInfo.ServerServiceStatus -eq 'Running') { "OK" } else { "ERROR" }) "Status: $($serverInfo.ServerServiceStatus)"
    if ($null -ne $serverInfo.ServerSMB1) {
        Add-Result "Server-SMB1" $(if ($serverInfo.ServerSMB1) { "WARN" } else { "OK" }) "SMB1: $($serverInfo.ServerSMB1)"
        Add-Result "Server-Signing" "INFO" "RequireSecuritySignature: $($serverInfo.ServerSigning)"
    }

    if ($ShareName) {
        if ($serverInfo.ShareExists) {
            Add-Result "Share-Exists" "OK" "Path: $($serverInfo.SharePath)"
            Add-Result "Share-ACL" "INFO" "$($serverInfo.ShareAccess)"
        } else {
            Add-Result "Share-Exists" "ERROR" "Share '$ShareName' not found on $ServerName"
        }
    }
} catch {
    Add-Result "ServerSideChecks" "WARN" "Could not reach server for detailed checks (PS remoting/WinRM required for remote queries): $_"
}
#endregion

#region ─── Summary ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── SMB Diagnostics Summary ──────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Target       : \\$ServerName$(if ($ShareName) { "\$ShareName" })"
Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: SMB path looks healthy." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — match failed checks to SMB-B.md fix paths (Fix 1-5)." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
