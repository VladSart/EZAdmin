<#
.SYNOPSIS
    Read-only inventory of SMB security-hardening posture (Win 11 24H2 / WS2025 defaults) across one or more machines.

.DESCRIPTION
    Collects the SMB client and server settings that changed in Windows 11 24H2 and Windows Server 2025
    (required signing, insecure guest logons, client NTLM blocking + exception list, dialect min/max,
    client-mandated encryption, authentication rate limiter delay, mailslots, signing/encryption auditing),
    live SMB connection/session dialect + signing state, and optionally the SMB audit events
    (SMBClient/Audit 31998/31999, SMBServer/Audit 3021/3022) that identify peers which cannot sign or encrypt.

    Flags each machine with findings such as "guest enabled but signing required (guest will still fail)",
    "unsigned live sessions", "NTLM blocked with empty exception list", or "SMB 2.x sessions present".

    Makes NO configuration changes. Properties that do not exist on older builds are reported as 'n/a'.
    Does not cover share/NTFS permissions or SMB over QUIC (see Get-SmbOverQuicHealth.ps1).

.PARAMETER ComputerName
    One or more computers to query via PowerShell remoting (WinRM). Defaults to the local machine.

.PARAMETER IncludeAuditEvents
    Also collect SMB signing/encryption audit events (last -AuditDays days).

.PARAMETER AuditDays
    Look-back window for audit events. Default 7.

.PARAMETER OutputPath
    Folder for CSV output. Default: $env:TEMP.

.EXAMPLE
    .\Get-SmbHardeningPosture.ps1
    Local posture report.

.EXAMPLE
    .\Get-SmbHardeningPosture.ps1 -ComputerName (Get-Content .\hosts.txt) -IncludeAuditEvents -AuditDays 14 -OutputPath C:\Reports

.NOTES
    Requires: SmbShare module (in-box), WinRM for remote targets. Run elevated for event log and server config access.
    Safe: read-only.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [switch]$IncludeAuditEvents,
    [ValidateRange(1,90)][int]$AuditDays = 7,
    [string]$OutputPath = $env:TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------- Collector (runs locally or remotely) ----------
$collector = {
    param([bool]$WantAudit, [int]$Days)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    function Get-Prop {
        param($Obj, [string]$Name)
        if ($null -eq $Obj) { return 'n/a' }
        $p = $Obj.PSObject.Properties[$Name]
        if ($null -eq $p) { return 'n/a' }
        if ($null -eq $p.Value) { return '' }
        if ($p.Value -is [System.Array]) { return ($p.Value -join ';') }
        return $p.Value
    }

    $os = Get-CimInstance Win32_OperatingSystem
    $cli = $null; $srv = $null
    try { $cli = Get-SmbClientConfiguration } catch { }
    try { $srv = Get-SmbServerConfiguration } catch { }

    $conns = @(); $sess = @()
    try { $conns = @(Get-SmbConnection -ErrorAction SilentlyContinue) } catch { }
    try { $sess  = @(Get-SmbSession -ErrorAction SilentlyContinue) } catch { }

    $unsignedConn = @($conns | Where-Object { $_.PSObject.Properties['Signed'] -and -not $_.Signed })
    $oldConn      = @($conns | Where-Object { $_.PSObject.Properties['Dialect'] -and "$($_.Dialect)" -like '2.*' })
    $unsignedSess = @($sess  | Where-Object { $_.PSObject.Properties['Signed'] -and -not $_.Signed })
    $oldSess      = @($sess  | Where-Object { $_.PSObject.Properties['Dialect'] -and "$($_.Dialect)" -like '2.*' })

    $audit = @()
    if ($WantAudit) {
        $start = (Get-Date).AddDays(-$Days)
        foreach ($spec in @(
            @{Log='Microsoft-Windows-SMBClient/Audit'; Ids=@(31998,31999)},
            @{Log='Microsoft-Windows-SMBServer/Audit'; Ids=@(3021,3022)})) {
            try {
                $ev = Get-WinEvent -FilterHashtable @{LogName=$spec.Log; Id=$spec.Ids; StartTime=$start} -ErrorAction Stop
                foreach ($e in $ev) {
                    $first = ''
                    if ($e.Message) { $first = ($e.Message -split "`r?`n")[0] }
                    $audit += [pscustomobject]@{
                        Computer    = $env:COMPUTERNAME
                        TimeCreated = $e.TimeCreated
                        Log         = $spec.Log
                        Id          = $e.Id
                        Message     = $first
                        FullMessage = ($e.Message -replace "`r?`n", ' | ')
                    }
                }
            } catch { }
        }
    }

    [pscustomobject]@{
        Computer                      = $env:COMPUTERNAME
        OSCaption                     = $os.Caption
        Build                         = [int]$os.BuildNumber
        Is24H2OrLater                 = ([int]$os.BuildNumber -ge 26100)
        Cli_RequireSecuritySignature  = Get-Prop $cli 'RequireSecuritySignature'
        Cli_EnableInsecureGuestLogons = Get-Prop $cli 'EnableInsecureGuestLogons'
        Cli_RequireEncryption         = Get-Prop $cli 'RequireEncryption'
        Cli_BlockNTLM                 = Get-Prop $cli 'BlockNTLM'
        Cli_BlockNTLMExceptions       = Get-Prop $cli 'BlockNTLMServerExceptionList'
        Cli_Smb2DialectMin            = Get-Prop $cli 'Smb2DialectMin'
        Cli_Smb2DialectMax            = Get-Prop $cli 'Smb2DialectMax'
        Cli_EnableMailslots           = Get-Prop $cli 'EnableMailslots'
        Cli_AuditNoSigning            = Get-Prop $cli 'AuditServerDoesNotSupportSigning'
        Cli_AuditNoEncryption         = Get-Prop $cli 'AuditServerDoesNotSupportEncryption'
        Srv_RequireSecuritySignature  = Get-Prop $srv 'RequireSecuritySignature'
        Srv_EncryptData               = Get-Prop $srv 'EncryptData'
        Srv_RejectUnencryptedAccess   = Get-Prop $srv 'RejectUnencryptedAccess'
        Srv_Smb2DialectMin            = Get-Prop $srv 'Smb2DialectMin'
        Srv_Smb2DialectMax            = Get-Prop $srv 'Smb2DialectMax'
        Srv_AuthDelayMs               = Get-Prop $srv 'InvalidAuthenticationDelayTimeInMs'
        Srv_AuditNoSigning            = Get-Prop $srv 'AuditClientDoesNotSupportSigning'
        Srv_AuditNoEncryption         = Get-Prop $srv 'AuditClientDoesNotSupportEncryption'
        OutboundConnections           = $conns.Count
        OutboundUnsigned              = $unsignedConn.Count
        OutboundSmb2x                 = $oldConn.Count
        OutboundUnsignedServers       = (($unsignedConn | ForEach-Object { $_.ServerName } | Sort-Object -Unique) -join ';')
        InboundSessions               = $sess.Count
        InboundUnsigned               = $unsignedSess.Count
        InboundSmb2x                  = $oldSess.Count
        InboundUnsignedClients        = (($unsignedSess | ForEach-Object { $_.ClientComputerName } | Sort-Object -Unique) -join ';')
        AuditEvents                   = $audit
    }
}

# ---------- Preflight ----------
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$results = New-Object System.Collections.Generic.List[object]
$audits  = New-Object System.Collections.Generic.List[object]

# ---------- Detect ----------
foreach ($c in $ComputerName) {
    Write-Status "Querying $c ..."
    try {
        if ($c -eq $env:COMPUTERNAME -or $c -eq 'localhost' -or $c -eq '.') {
            $r = & $collector ([bool]$IncludeAuditEvents) $AuditDays
        } else {
            $r = Invoke-Command -ComputerName $c -ScriptBlock $collector -ArgumentList ([bool]$IncludeAuditEvents), $AuditDays
        }
    } catch {
        Write-Status "$c unreachable or query failed: $($_.Exception.Message)" "ERROR"
        $results.Add([pscustomobject]@{ Computer = $c; Findings = "QUERY FAILED: $($_.Exception.Message)" })
        continue
    }

    foreach ($a in @($r.AuditEvents)) { if ($null -ne $a) { $audits.Add($a) } }

    # ---------- Evaluate ----------
    $f = New-Object System.Collections.Generic.List[string]
    if (-not $r.Is24H2OrLater) { $f.Add('Pre-24H2 build: new SMB hardening controls not present') }
    if ("$($r.Cli_EnableInsecureGuestLogons)" -eq 'True' -and "$($r.Cli_RequireSecuritySignature)" -eq 'True') {
        $f.Add('Guest logons enabled but client signing required: guest access will still fail')
    }
    if ("$($r.Cli_EnableInsecureGuestLogons)" -eq 'True' -and "$($r.Cli_RequireSecuritySignature)" -eq 'False') {
        $f.Add('Guest + unsigned client allowed: weakened posture, confirm documented exception')
    }
    if ("$($r.Cli_BlockNTLM)" -eq 'True' -and [string]::IsNullOrEmpty("$($r.Cli_BlockNTLMExceptions)")) {
        $f.Add('SMB NTLM blocked with no exceptions: IP/CNAME/non-domain targets will fail')
    }
    if ("$($r.Cli_RequireEncryption)" -eq 'True') { $f.Add('Client requires encryption: SMB 2.x / non-encrypting 3rd-party servers will fail') }
    if ("$($r.Cli_Smb2DialectMin)" -match 'SMB3') { $f.Add("Client dialect floor $($r.Cli_Smb2DialectMin): SMB 2.x devices blocked") }
    if ("$($r.Srv_AuthDelayMs)" -eq '0') { $f.Add('Server auth rate limiter disabled (delay 0)') }
    if ($r.OutboundUnsigned -gt 0) { $f.Add("Unsigned outbound sessions to: $($r.OutboundUnsignedServers)") }
    if ($r.InboundUnsigned -gt 0) { $f.Add("Unsigned inbound sessions from: $($r.InboundUnsignedClients)") }
    if ($r.OutboundSmb2x -gt 0 -or $r.InboundSmb2x -gt 0) { $f.Add("SMB 2.x sessions present (out=$($r.OutboundSmb2x), in=$($r.InboundSmb2x))") }
    if ("$($r.Cli_AuditNoSigning)" -ne 'True' -and $r.Is24H2OrLater) { $f.Add('Client signing audit off: enable to inventory non-signing servers') }

    $row = $r | Select-Object * -ExcludeProperty AuditEvents, PSComputerName, RunspaceId, PSShowComputerName
    $row | Add-Member -NotePropertyName Findings -NotePropertyValue ($f -join ' | ') -Force
    $results.Add($row)

    if ($f.Count -eq 0) { Write-Status "$c : no hardening findings" "OK" }
    else { foreach ($x in $f) { Write-Status "$c : $x" "WARN" } }
}

# ---------- Report ----------
$postureCsv = Join-Path $OutputPath "SmbHardeningPosture_$stamp.csv"
$results | Export-Csv -Path $postureCsv -NoTypeInformation
Write-Status "Posture report: $postureCsv" "OK"

if ($IncludeAuditEvents) {
    $auditCsv = Join-Path $OutputPath "SmbHardeningAudit_$stamp.csv"
    if ($audits.Count -gt 0) {
        $audits | Export-Csv -Path $auditCsv -NoTypeInformation
        Write-Status "$($audits.Count) audit events exported: $auditCsv" "WARN"
    } else {
        Write-Status "No SMB signing/encryption audit events found (auditing may be off - see Cli_AuditNoSigning column)" "INFO"
    }
}
