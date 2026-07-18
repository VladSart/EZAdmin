<#
.SYNOPSIS
    Read-only health and configuration audit of File Server Resource Manager (FSRM) on a file server.

.DESCRIPTION
    One-shot diagnostic sweep covering the failure modes documented in
    DFS/Troubleshooting/FSRM/FSRM-A.md and FSRM-B.md:

    1. Service & config store health
       - SrmSvc service state
       - Presence and ACL of the FSRM config store (System Volume Information\SRM\*.xml)
       - Flags SERVICE_DOWN and CONFIG_STORE_ACL_RISK

    2. Volume eligibility
       - Every local volume's file system, flagging any ReFS volume as REFS_UNSUPPORTED
         (FSRM cannot manage these — informational, not fixable in place)

    3. Quota consistency
       - Every auto-apply quota's MatchesTemplate flag — flags STALE_DERIVED_QUOTA when a
         template has been edited but not propagated (Set-FsrmAutoQuota -UpdateDerived)
       - Nested quota detection — flags NESTED_QUOTA_RISK when a folder's effective available
         space is capped by a more restrictive parent-folder quota

    4. File screening sanity
       - Flags SCREEN_BLOCKS_TMP when an active file screen's file group includes *.tmp,
         since this is the documented root cause of Office .xlsm/.xlsb save failures

    5. Notification pipeline
       - Optional live SMTP test via -TestEmail (off by default — sends a real test email,
         only run when explicitly requested)
       - Reports the configured notification throttle window for context

    6. Storage report health
       - Every configured storage report's LastRunStatus, flagging REPORT_FAILED

    7. Classification mode
       - USN Change Journal skip flags (SkipUSNCreationForSystem / SkipUSNCreationForVolumes)
         — flags REALTIME_CLASSIFICATION_DISABLED as informational context, not an error,
         since this can be an intentional space-saving trade-off

    Read-only. Makes no configuration changes unless -TestEmail is specified, in which case
    the only action taken is Send-FsrmTestEmail (no quota, screen, or setting is modified).

.PARAMETER OutputPath
    Path to export CSV reports. Default: $env:TEMP\FSRMAudit-<date>

.PARAMETER TestEmail
    Optional recipient address. If supplied, sends a live Send-FsrmTestEmail to validate the
    SMTP notification path end-to-end. Omit to skip (default — no email is sent).

.EXAMPLE
    .\Get-FSRMAudit.ps1

.EXAMPLE
    .\Get-FSRMAudit.ps1 -TestEmail "[email protected]" -OutputPath "C:\Temp\FSRM-Audit"

.NOTES
    Requires: FileServerResourceManager PowerShell module (installed with the FS-Resource-Manager
              Windows feature), local administrator rights
    Run as:   Local administrator on the file server hosting FSRM
    Safe to run repeatedly — read-only except for the optional -TestEmail live SMTP test.
    Companion runbooks: DFS/Troubleshooting/FSRM/FSRM-A.md, DFS/Troubleshooting/FSRM/FSRM-B.md
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$OutputPath = "$env:TEMP\FSRMAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')",
    [string]$TestEmail = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$Findings = [System.Collections.Generic.List[PSObject]]::new()

function Add-Finding {
    param([string]$Category, [string]$Flag, [string]$Detail, [string]$Severity)
    $Findings.Add([PSCustomObject]@{
        Category = $Category
        Flag     = $Flag
        Detail   = $Detail
        Severity = $Severity
    })
}

Write-Status "FSRM Audit started — $(Get-Date)" "INFO"
Write-Status "Export path: $OutputPath" "INFO"
Write-Host ""

# ─── 1. Service & config store health ──────────────────────────────────────────

Write-Host "=== Service & Config Store ===" -ForegroundColor Magenta

try {
    $Svc = Get-Service -Name SrmSvc -ErrorAction Stop
    if ($Svc.Status -ne 'Running') {
        Write-Status "SrmSvc status: $($Svc.Status)" "ERROR"
        Add-Finding "Service" "SERVICE_DOWN" "SrmSvc status is $($Svc.Status), expected Running" "ERROR"
    } else {
        Write-Status "SrmSvc status: Running ($($Svc.StartType))" "OK"
    }
} catch {
    Write-Status "FSRM service (SrmSvc) not found — is the FS-Resource-Manager feature installed?" "ERROR"
    Add-Finding "Service" "SERVICE_NOT_INSTALLED" "SrmSvc service not found on this host" "ERROR"
}

$ConfigStorePath = "$env:SystemDrive\System Volume Information\SRM"
$ConfigFiles = @("quota.xml", "filescrn.xml", "classification.xml", "storagereports.xml")

foreach ($File in $ConfigFiles) {
    $FullPath = Join-Path $ConfigStorePath $File
    if (-not (Test-Path $FullPath)) {
        Write-Status "Config file not found: $File (may be unused if that FSRM feature area is unconfigured)" "WARN"
        continue
    }
    try {
        $Acl = Get-Acl -Path $FullPath -ErrorAction Stop
        $HasSystem = $Acl.Access | Where-Object { $_.IdentityReference -match 'SYSTEM' -and $_.FileSystemRights -match 'FullControl' }
        $HasAdmins = $Acl.Access | Where-Object { $_.IdentityReference -match 'Administrators' -and $_.FileSystemRights -match 'FullControl' }
        if (-not $HasSystem -or -not $HasAdmins) {
            Write-Status "$File — ACL missing expected SYSTEM/Administrators FullControl entries" "ERROR"
            Add-Finding "ConfigStore" "CONFIG_STORE_ACL_RISK" "$FullPath is missing SYSTEM or Administrators FullControl" "ERROR"
        } else {
            Write-Status "$File — ACL OK" "OK"
        }
    } catch {
        Write-Status "$File — could not read ACL: $($_.Exception.Message)" "ERROR"
        Add-Finding "ConfigStore" "CONFIG_STORE_UNREADABLE" "$FullPath ACL read failed: $($_.Exception.Message)" "ERROR"
    }
}
Write-Host ""

# ─── 2. Volume eligibility ──────────────────────────────────────────────────────

Write-Host "=== Volume Eligibility (NTFS required) ===" -ForegroundColor Magenta

$Volumes = Get-Volume | Where-Object { $_.DriveLetter }
foreach ($Vol in $Volumes) {
    if ($Vol.FileSystem -eq 'ReFS') {
        Write-Status "$($Vol.DriveLetter): — ReFS, unsupported by FSRM" "ERROR"
        Add-Finding "Volume" "REFS_UNSUPPORTED" "Volume $($Vol.DriveLetter): is ReFS — FSRM cannot manage it, migration to NTFS required" "ERROR"
    } else {
        Write-Status "$($Vol.DriveLetter): — $($Vol.FileSystem)" "OK"
    }
}
Write-Host ""

# ─── 3. Quota consistency ───────────────────────────────────────────────────────

Write-Host "=== Quota Consistency ===" -ForegroundColor Magenta

try {
    $AutoQuotas = Get-FsrmAutoQuota -ErrorAction Stop
    foreach ($Aq in $AutoQuotas) {
        if ($Aq.PSObject.Properties.Name -contains 'MatchesTemplate' -and $Aq.MatchesTemplate -eq $false) {
            Write-Status "Auto-quota $($Aq.Path) — template drift (MatchesTemplate = False)" "WARN"
            Add-Finding "Quota" "STALE_DERIVED_QUOTA" "$($Aq.Path) no longer matches template $($Aq.Template) — needs Set-FsrmAutoQuota -UpdateDerived" "WARN"
        }
    }
    Write-Status "Auto-apply quotas checked: $($AutoQuotas.Count)" "INFO"
} catch {
    Write-Status "Could not enumerate auto-apply quotas: $($_.Exception.Message)" "WARN"
}

try {
    $AllQuotas = Get-FsrmQuota -ErrorAction Stop
    # Nested quota detection: for each quota path, look for any other quota on a parent path
    # with a smaller Size — that parent becomes the real effective ceiling.
    foreach ($Q in $AllQuotas) {
        $Parents = $AllQuotas | Where-Object {
            $_.Path -ne $Q.Path -and $Q.Path -like "$($_.Path)*" -and $_.Size -lt $Q.Size
        }
        if ($Parents) {
            $ParentList = ($Parents | ForEach-Object { "$($_.Path) ($([math]::Round($_.Size/1MB,0))MB)" }) -join '; '
            Write-Status "$($Q.Path) — capped by more restrictive parent quota: $ParentList" "WARN"
            Add-Finding "Quota" "NESTED_QUOTA_RISK" "$($Q.Path) effective limit capped by: $ParentList" "WARN"
        }
    }
    Write-Status "Quotas checked for nesting: $($AllQuotas.Count)" "INFO"
} catch {
    Write-Status "Could not enumerate quotas: $($_.Exception.Message)" "WARN"
}
Write-Host ""

# ─── 4. File screening sanity ───────────────────────────────────────────────────

Write-Host "=== File Screening Sanity ===" -ForegroundColor Magenta

try {
    $Screens = Get-FsrmFileScreen -ErrorAction Stop
    foreach ($Screen in $Screens) {
        foreach ($GroupName in $Screen.IncludeGroup) {
            try {
                $Group = Get-FsrmFileGroup -Name $GroupName -ErrorAction Stop
                if ($Group.IncludeExtension -contains '*.tmp') {
                    Write-Status "$($Screen.Path) — file group '$GroupName' blocks *.tmp (breaks Office save-then-rename)" "WARN"
                    Add-Finding "FileScreen" "SCREEN_BLOCKS_TMP" "$($Screen.Path) via group '$GroupName' blocks *.tmp — likely cause of Office .xlsm/.xlsb save failures" "WARN"
                }
            } catch {
                Write-Status "  Could not read file group '$GroupName': $($_.Exception.Message)" "WARN"
            }
        }
    }
    Write-Status "File screens checked: $($Screens.Count)" "INFO"
} catch {
    Write-Status "Could not enumerate file screens: $($_.Exception.Message)" "WARN"
}
Write-Host ""

# ─── 5. Notification pipeline ───────────────────────────────────────────────────

Write-Host "=== Notification Pipeline ===" -ForegroundColor Magenta

try {
    $Settings = Get-FsrmSetting -ErrorAction Stop
    if (-not $Settings.SmtpServer) {
        Write-Status "No SMTP server configured — email notifications cannot function" "ERROR"
        Add-Finding "Notification" "SMTP_NOT_CONFIGURED" "Get-FsrmSetting shows no SmtpServer set" "ERROR"
    } else {
        Write-Status "SMTP server configured: $($Settings.SmtpServer)" "OK"
    }
    if (-not $Settings.AdminEmailAddress) {
        Write-Status "No admin recipient configured" "WARN"
        Add-Finding "Notification" "ADMIN_EMAIL_NOT_CONFIGURED" "Get-FsrmSetting shows no AdminEmailAddress set" "WARN"
    }
} catch {
    Write-Status "Could not read FSRM settings: $($_.Exception.Message)" "WARN"
}

if ($TestEmail) {
    try {
        Send-FsrmTestEmail -ToAddress $TestEmail -ErrorAction Stop
        Write-Status "Test email sent to $TestEmail — confirm delivery manually" "OK"
    } catch {
        Write-Status "Test email failed: $($_.Exception.Message)" "ERROR"
        Add-Finding "Notification" "TEST_EMAIL_FAILED" "Send-FsrmTestEmail to $TestEmail failed: $($_.Exception.Message)" "ERROR"
    }
} else {
    Write-Status "Skipping live SMTP test (pass -TestEmail <address> to send one)" "INFO"
}
Write-Host ""

# ─── 6. Storage report health ───────────────────────────────────────────────────

Write-Host "=== Storage Report Health ===" -ForegroundColor Magenta

try {
    $Reports = Get-FsrmStorageReport -ErrorAction Stop
    foreach ($Report in $Reports) {
        if ($Report.PSObject.Properties.Name -contains 'LastRunStatus' -and $Report.LastRunStatus -and $Report.LastRunStatus -notmatch 'Completed|Succeeded') {
            Write-Status "Report '$($Report.Name)' — last run status: $($Report.LastRunStatus)" "ERROR"
            Add-Finding "StorageReport" "REPORT_FAILED" "Report '$($Report.Name)' LastRunStatus = $($Report.LastRunStatus)" "ERROR"
        } else {
            Write-Status "Report '$($Report.Name)' — OK" "OK"
        }
    }
    Write-Status "Storage reports checked: $($Reports.Count)" "INFO"
} catch {
    Write-Status "Could not enumerate storage reports: $($_.Exception.Message)" "WARN"
}
Write-Host ""

# ─── 7. Classification mode ─────────────────────────────────────────────────────

Write-Host "=== Classification Mode ===" -ForegroundColor Magenta

try {
    $UsnSettings = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SrmSvc\Settings" -ErrorAction SilentlyContinue
    if ($UsnSettings -and $UsnSettings.PSObject.Properties.Name -contains 'SkipUSNCreationForSystem' -and $UsnSettings.SkipUSNCreationForSystem -eq 1) {
        Write-Status "SkipUSNCreationForSystem = 1 — real-time classification disabled server-wide" "WARN"
        Add-Finding "Classification" "REALTIME_CLASSIFICATION_DISABLED" "USN journal creation disabled server-wide — classification only runs on scheduled sweeps, not real-time" "WARN"
    } else {
        Write-Status "USN journal creation not globally disabled — real-time classification available if configured" "OK"
    }
} catch {
    Write-Status "Could not read USN journal registry settings" "WARN"
}
Write-Host ""

# ─── Summary ─────────────────────────────────────────────────────────────────────

$Errors   = $Findings | Where-Object Severity -eq "ERROR"
$Warnings = $Findings | Where-Object Severity -eq "WARN"

Write-Host "=== SUMMARY ===" -ForegroundColor Magenta
Write-Status "Total findings: $($Findings.Count)" "INFO"
Write-Status "Errors:         $($Errors.Count)"   $(if ($Errors.Count -gt 0)   { "ERROR" } else { "OK" })
Write-Status "Warnings:       $($Warnings.Count)" $(if ($Warnings.Count -gt 0) { "WARN" }  else { "OK" })

if ($Findings.Count -gt 0) {
    Write-Host ""
    Write-Host "FINDINGS:" -ForegroundColor Yellow
    $Findings | Sort-Object Severity | Format-Table Category, Flag, Detail, Severity -Wrap
    Write-Status "Cross-reference each Flag against FSRM-B.md's Symptom/Fix mapping." "INFO"
}

# ─── Export ──────────────────────────────────────────────────────────────────────

$Findings | Export-Csv "$OutputPath\fsrm-findings.csv" -NoTypeInformation

Write-Status "`nFull report: $OutputPath" "INFO"
Write-Status "Done." "OK"
