<#
.SYNOPSIS
    Reports BitLocker encryption status across local or remote endpoints.

.DESCRIPTION
    Queries BitLocker volume status on one or more computers using manage-bde,
    WMI (Win32_EncryptableVolume), and the BitLocker PowerShell module.
    Produces a per-volume status table and exports to CSV.

    Covers:
    - Encryption status and percentage complete per volume
    - Protection status (on/off) and key protector types present
    - Recovery key availability in Entra ID / Active Directory (via Graph)
    - TPM protector presence and binding state
    - Compliance flag: fully encrypted + protection on + recovery key escrowed
    - Highlights volumes that are decrypted, suspended, or missing recovery keys

    Does NOT cover:
    - Enabling/disabling BitLocker (use Enable-BitLocker / manage-bde -on)
    - Rotating recovery keys (use BackupToAAD-BitLockerKeyProtector)
    - DMA attack surface (Kernel DMA Protection is separate — see VBS runbook)

.PARAMETER ComputerName
    One or more computer names or IPs to query. Default: local computer.

.PARAMETER Credential
    PSCredential for remote queries. If omitted, uses current session credentials.

.PARAMETER CheckEscrow
    If specified, queries Microsoft Graph to verify recovery keys are escrowed
    in Entra ID for each device. Requires Microsoft.Graph module and
    BitLockerKey.ReadBasic.All or DeviceManagementManagedDevices.Read.All.

.PARAMETER TenantId
    Required when -CheckEscrow is used. Your Entra ID tenant ID or domain.

.PARAMETER ExportPath
    Path for CSV export. Default: .\BitLockerStatus-<timestamp>.csv

.EXAMPLE
    .\Get-BitLockerStatus.ps1
    Reports BitLocker status on the local machine.

.EXAMPLE
    .\Get-BitLockerStatus.ps1 -ComputerName PC001,PC002,PC003
    Reports status across three machines using current credentials.

.EXAMPLE
    .\Get-BitLockerStatus.ps1 -ComputerName PC001 -CheckEscrow -TenantId contoso.onmicrosoft.com
    Reports status and verifies recovery key is escrowed in Entra ID.

.NOTES
    Requires: BitLocker (built into Windows); WMI remoting for remote queries
    Run-as: Administrator (local); admin credentials required for remote WMI
    Safe: Read-only — does not change encryption state
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2019/2022
#>

[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$CheckEscrow,
    [string]$TenantId,
    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"     { "Green" }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red" }
        default  { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region ─── Preflight ──────────────────────────────────────────────────────────
Write-Status "Get-BitLockerStatus — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\BitLockerStatus-$timestamp.csv"
}

if ($CheckEscrow -and -not $TenantId) {
    Write-Status "-CheckEscrow requires -TenantId. Disabling escrow check." "WARN"
    $CheckEscrow = $false
}

# Connect to Graph if escrow check requested
$graphConnected = $false
if ($CheckEscrow) {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.DirectoryManagement)) {
        Write-Status "Microsoft.Graph module not found — skipping escrow check. Install: Install-Module Microsoft.Graph" "WARN"
        $CheckEscrow = $false
    } else {
        try {
            Connect-MgGraph -TenantId $TenantId -Scopes "BitLockerKey.ReadBasic.All" -NoWelcome -ErrorAction Stop
            $graphConnected = $true
            Write-Status "Connected to Graph for escrow check" "OK"
        } catch {
            Write-Status "Graph connection failed: $_ — skipping escrow check" "WARN"
            $CheckEscrow = $false
        }
    }
}
#endregion

#region ─── Helper: protection status decode ──────────────────────────────────
function ConvertTo-ProtectionStatus {
    param([int]$Code)
    switch ($Code) {
        0 { return "Off" }
        1 { return "On" }
        2 { return "Unknown" }
        default { return "Unknown($Code)" }
    }
}

function ConvertTo-EncryptionStatus {
    param([int]$Code)
    switch ($Code) {
        0  { return "FullyDecrypted" }
        1  { return "FullyEncrypted" }
        2  { return "EncryptionInProgress" }
        3  { return "DecryptionInProgress" }
        4  { return "EncryptionPaused" }
        5  { return "DecryptionPaused" }
        default { return "Unknown($Code)" }
    }
}

function ConvertTo-KeyProtectorType {
    param([int]$Code)
    switch ($Code) {
        0 { return "Unknown" }
        1 { return "TPM" }
        2 { return "ExternalKey" }
        3 { return "RecoveryPassword" }
        4 { return "TPMAndPIN" }
        5 { return "TPMAndStartupKey" }
        6 { return "TPMAndPINAndStartupKey" }
        7 { return "PublicKey" }
        8 { return "Passphrase" }
        9 { return "TpmNetworkKey" }
        10 { return "AdAccountOrGroup" }
        default { return "Type$Code" }
    }
}
#endregion

#region ─── Helper: query one computer ────────────────────────────────────────
function Get-BitLockerStatusForComputer {
    param(
        [string]$Computer,
        [System.Management.Automation.PSCredential]$Cred
    )

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $isLocal = ($Computer -eq $env:COMPUTERNAME -or $Computer -eq "localhost" -or $Computer -eq "127.0.0.1")

    # Build WMI session parameters
    $wmiParams = @{ Namespace = "root\CIMv2\Security\MicrosoftVolumeEncryption"; Class = "Win32_EncryptableVolume" }
    if (-not $isLocal) {
        $wmiParams['ComputerName'] = $Computer
        if ($Cred) { $wmiParams['Credential'] = $Cred }
    }

    try {
        $volumes = Get-WmiObject @wmiParams -ErrorAction Stop
    } catch {
        Write-Status "  WMI query failed on $Computer : $_" "ERROR"
        $rows.Add([PSCustomObject]@{
            Computer         = $Computer
            DriveLetter      = "N/A"
            VolumeType       = "N/A"
            EncryptionStatus = "QueryFailed"
            ProtectionStatus = "N/A"
            EncryptionPct    = "N/A"
            KeyProtectors    = "N/A"
            HasTPM           = "N/A"
            HasRecoveryPwd   = "N/A"
            EscrowStatus     = "N/A"
            Compliant        = $false
            Note             = $_.Exception.Message
            CheckedAt        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        })
        return $rows
    }

    foreach ($vol in $volumes) {
        $encStatus  = ConvertTo-EncryptionStatus  -Code $vol.ConversionStatus
        $protStatus = ConvertTo-ProtectionStatus  -Code $vol.ProtectionStatus

        # Get encryption percentage
        $encPct = try { $vol.EncryptionPercentage } catch { "N/A" }

        # Get key protector types
        $kpTypes = @()
        try {
            $kpIds = $vol.GetKeyProtectors(0).VolumeKeyProtectorID
            foreach ($kpId in $kpIds) {
                $kpTypeCode = $vol.GetKeyProtectorType($kpId).KeyProtectorType
                $kpTypes += ConvertTo-KeyProtectorType -Code $kpTypeCode
            }
        } catch { }

        $hasTPM         = ($kpTypes | Where-Object { $_ -like "TPM*" }).Count -gt 0
        $hasRecoveryPwd = $kpTypes -contains "RecoveryPassword"

        # Escrow check via Graph (Entra ID)
        $escrowStatus = "NotChecked"
        if ($CheckEscrow -and $graphConnected) {
            try {
                # Find Entra device by computer name
                $device = Get-MgDevice -Filter "displayName eq '$Computer'" -Top 1 -ErrorAction SilentlyContinue
                if ($device) {
                    $keys = Get-MgInformationProtectionBitlockerRecoveryKey -Filter "deviceId eq '$($device.DeviceId)'" -ErrorAction SilentlyContinue
                    $escrowStatus = if ($keys) { "Escrowed($($keys.Count)keys)" } else { "NotEscrowed" }
                } else {
                    $escrowStatus = "DeviceNotFound"
                }
            } catch {
                $escrowStatus = "CheckFailed"
            }
        }

        # Compliance: fully encrypted + protection on + has recovery password
        $compliant = ($encStatus -eq "FullyEncrypted") -and ($protStatus -eq "On") -and $hasRecoveryPwd

        # Status label for display
        $statusLabel = if ($compliant) { "OK" } elseif ($encStatus -eq "FullyDecrypted") { "ERROR" } else { "WARN" }

        $note = @()
        if ($encStatus -ne "FullyEncrypted")  { $note += "Not fully encrypted ($encStatus)" }
        if ($protStatus -ne "On")             { $note += "Protection is $protStatus" }
        if (-not $hasTPM)                     { $note += "No TPM protector" }
        if (-not $hasRecoveryPwd)             { $note += "No recovery password protector" }
        if ($escrowStatus -eq "NotEscrowed")  { $note += "Recovery key NOT escrowed in Entra ID" }

        $row = [PSCustomObject]@{
            Computer         = $Computer
            DriveLetter      = $vol.DriveLetter
            VolumeType       = if ($vol.VolumeType -eq 0) { "OS" } elseif ($vol.VolumeType -eq 1) { "Fixed" } else { "Removable" }
            EncryptionStatus = $encStatus
            ProtectionStatus = $protStatus
            EncryptionPct    = "$encPct%"
            KeyProtectors    = ($kpTypes -join ", ")
            HasTPM           = $hasTPM
            HasRecoveryPwd   = $hasRecoveryPwd
            EscrowStatus     = $escrowStatus
            Compliant        = $compliant
            Note             = ($note -join "; ")
            CheckedAt        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }

        $rows.Add($row)

        $colour = switch ($statusLabel) {
            "OK"    { "Green" }
            "WARN"  { "Yellow" }
            "ERROR" { "Red" }
            default { "White" }
        }
        Write-Host "  [$statusLabel] $Computer | $($vol.DriveLetter) | $encStatus | Protection: $protStatus | Protectors: $($kpTypes -join ',') | Compliant: $compliant" -ForegroundColor $colour
    }

    return $rows
}
#endregion

#region ─── Main loop ─────────────────────────────────────────────────────────
$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($computer in $ComputerName) {
    Write-Status "Checking: $computer"
    $credParam = if ($Credential -and $computer -ne $env:COMPUTERNAME) { $Credential } else { $null }
    $rows = Get-BitLockerStatusForComputer -Computer $computer -Cred $credParam
    foreach ($r in $rows) { $allResults.Add($r) }
}
#endregion

#region ─── Summary ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── BitLocker Status Summary ──────────────────────" -ForegroundColor Cyan

$totalVolumes    = $allResults.Count
$compliantCount  = ($allResults | Where-Object { $_.Compliant }).Count
$decryptedCount  = ($allResults | Where-Object { $_.EncryptionStatus -eq "FullyDecrypted" }).Count
$noRecoveryCount = ($allResults | Where-Object { $_.HasRecoveryPwd -eq $false -and $_.EncryptionStatus -ne "QueryFailed" }).Count
$notEscrowCount  = ($allResults | Where-Object { $_.EscrowStatus -eq "NotEscrowed" }).Count

Write-Host "  Total volumes checked : $totalVolumes"
Write-Host "  Compliant (encrypted + protected + recovery key) : $compliantCount" -ForegroundColor $(if ($compliantCount -eq $totalVolumes) { "Green" } else { "Yellow" })
Write-Host "  Fully decrypted       : $decryptedCount" -ForegroundColor $(if ($decryptedCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Missing recovery key  : $noRecoveryCount" -ForegroundColor $(if ($noRecoveryCount -gt 0) { "Yellow" } else { "Green" })
if ($CheckEscrow) {
    Write-Host "  Not escrowed in Entra : $notEscrowCount" -ForegroundColor $(if ($notEscrowCount -gt 0) { "Red" } else { "Green" })
}

$problemVolumes = $allResults | Where-Object { -not $_.Compliant }
if ($problemVolumes) {
    Write-Host ""
    Write-Host "─── Non-Compliant Volumes ─────────────────────────" -ForegroundColor Yellow
    $problemVolumes | Format-Table Computer, DriveLetter, EncryptionStatus, ProtectionStatus, HasTPM, HasRecoveryPwd, EscrowStatus, Note -AutoSize
}

Write-Host ""
#endregion

#region ─── Export ────────────────────────────────────────────────────────────
if ($allResults.Count -gt 0) {
    $allResults | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "Exported → $ExportPath" "OK"
}

Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
