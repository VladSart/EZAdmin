<#
.SYNOPSIS
    Audits Microsoft Purview Message Encryption (OME) readiness — IRM config, OME config, transport
    rule targeting, and per-user licensing — in a single pass.

.DESCRIPTION
    Companion script for MessageEncryption-B.md / MessageEncryption-A.md. Automates the Triage and
    Diagnosis & Validation Flow steps from both runbooks so an engineer doesn't have to run
    Get-IRMConfiguration, Get-OMEConfiguration, Test-IRMConfiguration, and Get-TransportRule
    separately and manually cross-reference the results.

    Checks and flags:
    - IRM_NOT_ENABLED: InternalLicensingEnabled or AzureRMSLicensingEnabled is $false — OME cannot
      function at all until both are true (MessageEncryption-B.md Fix 2)
    - SIMPLIFIED_ACCESS_DISABLED: SimplifiedClientAccessEnabled is $false — tenant is still on legacy
      OME v1 (certificate-based) rather than the modern OTP/social-login portal experience
    - OTP_DISABLED: OTPEnabled is $false on the OME configuration — external recipients without a
      Microsoft/Google account cannot open encrypted mail (Fix 3)
    - TEST_IRM_FAIL: Test-IRMConfiguration returns a non-PASS overall result — the single most
      reliable end-to-end signal per the runbook's Diagnosis Step 1
    - NO_OME_TRANSPORT_RULE: no transport rule has ApplyOME or ApplyRMSTemplate set — encryption is
      never triggered regardless of how healthy IRM/OME config is
    - OME_RULE_DISABLED: a rule with ApplyOME/ApplyRMSTemplate exists but State is Disabled
    - USER_MISSING_RMS_LICENSE (per -User only): user lacks an RMS_S_PREMIUM / equivalent AIP/MIP
      service plan, so OME "succeeds" silently without actually encrypting (MessageEncryption-B.md's
      licensing Learning Pointer)

    Does NOT cover:
    - Sending a live test message or validating OTP portal delivery end-to-end (do this manually per
      Diagnosis Step 3/4 after config checks pass)
    - Revoking already-sent encrypted messages (Fix 4 — requires the Purview compliance portal or
      AIPService module, an explicit write action, not part of this read-only audit)

.PARAMETER User
    One or more UPNs to check for RMS/AIP licensing. Optional — if omitted, license checks are
    skipped and only tenant-level IRM/OME/transport rule config is audited.

.PARAMETER AdminUpn
    UPN used as the -Sender for Test-IRMConfiguration. Required for the end-to-end IRM test; if
    omitted, that check is skipped and noted in the output.

.PARAMETER OutputPath
    Path for CSV export of the transport rule findings. Default: C:\Temp\OMEConfigAudit-<timestamp>.csv

.EXAMPLE
    .\Get-OMEConfigurationAudit.ps1 -AdminUpn admin@contoso.com

.EXAMPLE
    .\Get-OMEConfigurationAudit.ps1 -AdminUpn admin@contoso.com -User "john.smith@contoso.com","jane.doe@contoso.com"

.NOTES
    Requires: Exchange Online module (ExchangeOnlineManagement) v3.0+; Microsoft.Graph.Users module
    for the optional -User license check
    Permissions: Exchange Administrator (or View-Only Organization Management) for read cmdlets;
    User.Read.All (Graph, delegated or app) for license lookups
    Run-as: Connect-ExchangeOnline (and Connect-MgGraph if using -User) before running this script
    Safe: Read-only. Makes no changes to IRM config, OME config, or transport rules.
#>

[CmdletBinding()]
param(
    [string[]]$User,

    [string]$AdminUpn,

    [string]$OutputPath = "C:\Temp\OMEConfigAudit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

# Preflight
Write-Status "Checking Exchange Online connection..."
Try {
    $null = Get-OrganizationConfig -ErrorAction Stop
    Write-Status "Exchange Online connected" -Status "OK"
} Catch {
    Write-Status "Not connected to Exchange Online. Run: Connect-ExchangeOnline" -Status "ERROR"
    Exit 1
}

New-Item -Path (Split-Path $OutputPath) -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

$findings = [System.Collections.Generic.List[string]]::new()

# 1. IRM configuration
Write-Status "Checking IRM configuration..."
$irm = Get-IRMConfiguration
Write-Host ""
Write-Host "--- IRM Configuration ---"
$irm | Select-Object InternalLicensingEnabled, AzureRMSLicensingEnabled, SimplifiedClientAccessEnabled | Format-List

If (-not $irm.InternalLicensingEnabled -or -not $irm.AzureRMSLicensingEnabled) {
    $findings.Add("IRM_NOT_ENABLED: InternalLicensingEnabled=$($irm.InternalLicensingEnabled), AzureRMSLicensingEnabled=$($irm.AzureRMSLicensingEnabled)")
    Write-Status "IRM is not fully enabled — OME cannot function" -Status "ERROR"
} Else {
    Write-Status "IRM licensing enabled" -Status "OK"
}

If (-not $irm.SimplifiedClientAccessEnabled) {
    $findings.Add("SIMPLIFIED_ACCESS_DISABLED: tenant is on legacy OME v1 (certificate-based)")
    Write-Status "SimplifiedClientAccessEnabled is False — legacy OME v1 in use" -Status "WARN"
}

# 2. OME configuration
Write-Status "Checking OME configuration..."
$ome = Get-OMEConfiguration
Write-Host ""
Write-Host "--- OME Configuration ---"
$ome | Select-Object Identity, OTPEnabled, ExternalMailExpiryEnabled | Format-Table -AutoSize

If (-not $ome) {
    $findings.Add("NO_OME_CONFIGURATION: OME has never been initialised")
    Write-Status "No OME configuration found — run Set-IRMConfiguration -AzureRMSLicensingEnabled `$true" -Status "ERROR"
} Else {
    ForEach ($cfg in $ome) {
        If (-not $cfg.OTPEnabled) {
            $findings.Add("OTP_DISABLED: OME config '$($cfg.Identity)' has OTPEnabled=`$false")
            Write-Status "OTP disabled on OME config '$($cfg.Identity)' — external recipients without MS/Google accounts cannot open encrypted mail" -Status "WARN"
        }
    }
}

# 3. Test-IRMConfiguration (end-to-end)
If ($AdminUpn) {
    Write-Status "Running Test-IRMConfiguration -Sender $AdminUpn ..."
    Try {
        $testResult = Test-IRMConfiguration -Sender $AdminUpn -ErrorAction Stop
        $overall = $testResult | Select-String -Pattern "OVERALL RESULT"
        Write-Host ($testResult | Out-String)
        If ($overall -match "PASS") {
            Write-Status "Test-IRMConfiguration: PASS" -Status "OK"
        } Else {
            $findings.Add("TEST_IRM_FAIL: Test-IRMConfiguration did not return PASS — see full output above")
            Write-Status "Test-IRMConfiguration did NOT pass — review failing test names above" -Status "ERROR"
        }
    } Catch {
        $findings.Add("TEST_IRM_ERROR: $($_.Exception.Message)")
        Write-Status "Test-IRMConfiguration threw an error: $($_.Exception.Message)" -Status "ERROR"
    }
} Else {
    Write-Status "No -AdminUpn supplied — skipping Test-IRMConfiguration end-to-end check" -Status "WARN"
}

# 4. Transport rule targeting
Write-Status "Checking transport rules for OME targeting..."
$omeRules = Get-TransportRule | Where-Object { $_.ApplyOME -eq $true -or $_.RemoveOMEv2 -eq $true -or $PSItem.ApplyRMSTemplate }

$ruleResults = [System.Collections.Generic.List[PSObject]]::new()

If (-not $omeRules) {
    $findings.Add("NO_OME_TRANSPORT_RULE: no rule applies OME or an RMS template")
    Write-Status "No transport rule applies OME — encryption will never trigger regardless of IRM/OME health" -Status "ERROR"
} Else {
    ForEach ($rule in $omeRules) {
        $ruleResults.Add([PSCustomObject]@{
            Name             = $rule.Name
            State            = $rule.State
            Priority         = $rule.Priority
            ApplyOME         = $rule.ApplyOME
            ApplyRMSTemplate = $rule.ApplyRMSTemplate
            RemoveOMEv2      = $rule.RemoveOMEv2
        })
        If ($rule.State -ne "Enabled") {
            $findings.Add("OME_RULE_DISABLED: rule '$($rule.Name)' is $($rule.State)")
            Write-Status "Rule '$($rule.Name)' targets OME but is $($rule.State)" -Status "WARN"
        }
    }
    Write-Host ""
    Write-Host "--- OME Transport Rules ---"
    $ruleResults | Format-Table -AutoSize
}

# 5. Per-user licensing (optional)
If ($User) {
    Write-Status "Checking RMS/AIP licensing for $($User.Count) user(s)..."
    ForEach ($u in $User) {
        Try {
            $license = Get-MgUserLicenseDetail -UserId $u -ErrorAction Stop
            $hasRms = $license | Select-Object -ExpandProperty ServicePlans |
                Where-Object { $_.ServicePlanName -match "RMS|AIP|MIP" -and $_.ProvisioningStatus -eq "Success" }
            If (-not $hasRms) {
                $findings.Add("USER_MISSING_RMS_LICENSE: $u has no active RMS/AIP/MIP service plan")
                Write-Status "$u is missing an RMS/AIP service plan — OME will fail silently for this user" -Status "WARN"
            } Else {
                Write-Status "$u has RMS/AIP licensing OK" -Status "OK"
            }
        } Catch {
            Write-Status "Could not resolve license for $u — $($_.Exception.Message)" -Status "WARN"
        }
    }
}

# Summary
Write-Host ""
Write-Status "=== SUMMARY ===" -Status "OK"
If ($findings.Count -eq 0) {
    Write-Status "No issues found. OME appears fully configured and targeted." -Status "OK"
} Else {
    Write-Status "$($findings.Count) issue(s) found:" -Status "WARN"
    $findings | ForEach-Object { Write-Host "  - $_" }
}

If ($ruleResults.Count -gt 0) {
    $ruleResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Transport rule findings exported to: $OutputPath" -Status "OK"
}
