<#
.SYNOPSIS
    Audits AD CS certificate templates in the forest for the ESC1 (vulnerable
    template — enrollee-supplied subject) and ESC4 (template ACL abuse) classes
    of misconfiguration.

.DESCRIPTION
    Checks, against the Configuration naming context:
      - ESC1 shape: templates with CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT
        (msPKI-Certificate-Name-Flag bit 0x1) set, combined with a
        client-authentication-capable Extended Key Usage (Client Authentication,
        Smart Card Logon, PKINIT Client Authentication, or Any Purpose), and
        which security principals hold Enroll rights on those templates
      - ESC4 shape: any non-admin, non-service security principal holding
        WriteDacl, WriteOwner, WriteProperty, or GenericAll rights on ANY
        template object, independent of that template's current subject-name/
        EKU configuration
      - Cross-references findings against which CAs actually publish each
        template (via certutil -CATemplates), where certutil is available

    This is a DEFENSIVE, READ-ONLY audit script. It does not attempt to
    enroll for a certificate, does not simulate exploitation, and does not
    change any template configuration, ACL, or CA setting. It reports findings
    to the console and exports a consolidated CSV for follow-up remediation
    using the companion runbooks (Windows/Troubleshooting/
    ADCSTemplateMisconfiguration-B.md / -A.md).

    Distinct from Get-NTLMRelayADCSAudit.ps1 (checks ESC8 — NTLM relay to an
    AD CS HTTP(S) enrollment endpoint, a different attack primitive requiring
    coercion/relay rather than a direct enrollment-rights abuse).

.PARAMETER KnownAdminIdentities
    Array of identity name fragments treated as expected/trusted holders of
    template write-rights (not flagged as ESC4 findings). Default covers the
    standard built-in Tier 0 groups. Extend this if your environment has a
    dedicated, legitimately-scoped PKI administration group you want excluded
    from findings.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\ADCSVulnerableTemplateAudit_<timestamp>.csv

.EXAMPLE
    .\Get-ADCSVulnerableTemplateAudit.ps1
    # Audits every certificate template in the current forest's Configuration NC

.EXAMPLE
    .\Get-ADCSVulnerableTemplateAudit.ps1 -KnownAdminIdentities "Domain Admins","Enterprise Admins","SYSTEM","Administrators","Cert Publishers","PKI-Admins"
    # Additionally treats a custom "PKI-Admins" group as an expected ACL holder

.NOTES
    Requires: ActiveDirectory module (RSAT) with read access to the
              Configuration naming context. Does NOT require CA server access
              for the detection portion; certutil-based CA cross-reference is
              attempted opportunistically and degrades gracefully if certutil
              or a reachable CA is unavailable.
    Run as: Any domain-authenticated account with default read access to the
            Configuration naming context (no elevated rights required to run
            this audit; remediation actions require separate, appropriate
            delegated rights and are NOT performed by this script)
    Safe/Unsafe: READ-ONLY — does not modify any template configuration, ACL,
                 or CA setting. Does not attempt to enroll for a certificate.
    Tested against: Windows Server AD CS with standard v2/v3/v4 certificate
                    template schema. Does not cover standalone (non-enterprise)
                    CAs, which use a file-based, non-AD-object template model.
    Limitation: This script flags CANDIDATE misconfigurations based on
                template attributes and ACLs. It does not confirm live
                exploitability (e.g. it does not check whether a flagged
                template is actually reachable/published on a live CA unless
                certutil succeeds) — treat every finding as requiring the
                human review described in the companion runbook, not as an
                automatic ground truth.
#>

[CmdletBinding()]
param(
    [string[]] $KnownAdminIdentities = @("Domain Admins", "Enterprise Admins", "SYSTEM", "Administrators", "Cert Publishers", "Enterprise Key Admins", "Key Admins"),
    [string] $ExportPath = "$env:TEMP\ADCSVulnerableTemplateAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"     { "Green"  }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red"    }
        "HEADER" { "Cyan"   }
        default  { "White"  }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

Write-Status "AD CS Vulnerable Certificate Template Audit (ESC1 / ESC4)" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

$results = @()

# Well-known extended-right GUID for Certificate-Enrollment
$enrollRightGuid = "0e10c968-78fb-11d2-90d4-00c04f79dc55"
$autoenrollRightGuid = "a05b8cc2-17bc-4802-a710-e7c15ab866a2"

# Client-authentication-capable EKU OIDs
$clientAuthEkus = @(
    "1.3.6.1.5.5.7.3.2",      # Client Authentication
    "1.3.6.1.4.1.311.20.2.2", # Smart Card Logon
    "1.3.6.1.5.2.3.4",        # PKINIT Client Authentication
    "2.5.29.37.0"             # Any Purpose
)

#region --- Preflight ---

Write-Status "`n=== Preflight ===" -Status "HEADER"

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Status "  ActiveDirectory module not available. Cannot proceed with template audit." -Status "ERROR"
    $results += [PSCustomObject]@{ Category = "Preflight"; Item = "ActiveDirectory module"; Value = "Missing"; Status = "ERROR"; Note = "Install RSAT: Active Directory Domain Services and LDAP Tools" }
    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "Report saved to $ExportPath" -Status "INFO"
    return
}

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $configNC = (Get-ADRootDSE).ConfigurationNamingContext
    Write-Status "  Configuration NC: $configNC" -Status "OK"
    $results += [PSCustomObject]@{ Category = "Preflight"; Item = "ConfigurationNamingContext"; Value = $configNC; Status = "OK"; Note = "" }
} catch {
    Write-Status "  Could not import ActiveDirectory module or reach the Configuration NC: $_" -Status "ERROR"
    $results += [PSCustomObject]@{ Category = "Preflight"; Item = "Module/NC"; Value = "FAILED"; Status = "ERROR"; Note = "$_" }
    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "Report saved to $ExportPath" -Status "INFO"
    return
}

$certutilAvailable = $null -ne (Get-Command certutil.exe -ErrorAction SilentlyContinue)
Write-Status "  certutil.exe available for CA cross-reference: $certutilAvailable" -Status $(if ($certutilAvailable) { "OK" } else { "WARN" })

#endregion

#region --- Detect: Load every certificate template ---

Write-Status "`n=== Loading Certificate Templates ===" -Status "HEADER"

$allTemplates = @()
try {
    $allTemplates = Get-ADObject -SearchBase $configNC -LDAPFilter "(objectClass=pKICertificateTemplate)" `
        -Properties Name, msPKI-Certificate-Name-Flag, pKIExtendedKeyUsage, nTSecurityDescriptor -ErrorAction Stop
    Write-Status "  Found $($allTemplates.Count) certificate template object(s)." -Status "INFO"
    $results += [PSCustomObject]@{ Category = "Detect"; Item = "TemplateCount"; Value = $allTemplates.Count; Status = "INFO"; Note = "" }
} catch {
    Write-Status "  Could not enumerate certificate templates: $_" -Status "ERROR"
    $results += [PSCustomObject]@{ Category = "Detect"; Item = "TemplateEnumeration"; Value = "FAILED"; Status = "ERROR"; Note = "$_" }
    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "Report saved to $ExportPath" -Status "INFO"
    return
}

#endregion

#region --- Opportunistic CA publication cross-reference ---

$publishedTemplateNames = @()
if ($certutilAvailable) {
    Write-Status "`n=== CA Publication Cross-Reference (best-effort) ===" -Status "HEADER"
    try {
        $catOutput = certutil -CATemplates 2>&1
        if ($LASTEXITCODE -eq 0 -and $catOutput) {
            foreach ($line in $catOutput) {
                # certutil -CATemplates output lines are typically "TemplateName:  DisplayName"
                if ($line -match "^([A-Za-z0-9_\-]+):") {
                    $publishedTemplateNames += $Matches[1]
                }
            }
            Write-Status "  Parsed $($publishedTemplateNames.Count) published template reference(s) from certutil output." -Status "OK"
        } else {
            Write-Status "  certutil -CATemplates did not return usable output (no reachable/configured local CA, or access denied). Publication status will be reported as Unknown." -Status "WARN"
        }
    } catch {
        Write-Status "  Could not run certutil -CATemplates: $_. Publication status will be reported as Unknown." -Status "WARN"
    }
} else {
    Write-Status "`n  Skipping CA publication cross-reference — certutil.exe not available on this host." -Status "WARN"
}

#endregion

#region --- ESC1 Detection ---

Write-Status "`n=== ESC1 Detection: Enrollee-Supplied-Subject + Client-Auth EKU ===" -Status "HEADER"

$esc1Candidates = @()
foreach ($tmpl in $allTemplates) {
    $nameFlag = $null
    if ($tmpl.PSObject.Properties.Match('msPKI-Certificate-Name-Flag').Count -gt 0) {
        $nameFlag = $tmpl.'msPKI-Certificate-Name-Flag'
    }

    if ($null -eq $nameFlag) {
        continue  # attribute not present/readable — cannot assert either way, skip rather than false-flag
    }

    $enrolleeSuppliesSubject = ([int64]$nameFlag -band 0x1) -ne 0
    if (-not $enrolleeSuppliesSubject) { continue }

    $ekus = @()
    if ($tmpl.PSObject.Properties.Match('pKIExtendedKeyUsage').Count -gt 0) {
        $ekus = @($tmpl.pKIExtendedKeyUsage)
    }
    $hasClientAuthEku = $false
    foreach ($eku in $clientAuthEkus) {
        if ($ekus -contains $eku) { $hasClientAuthEku = $true; break }
    }
    # No EKU restriction at all (empty EKU list) also behaves like "Any Purpose" in practice
    if ($ekus.Count -eq 0) { $hasClientAuthEku = $true }

    if ($hasClientAuthEku) {
        $esc1Candidates += $tmpl
    }
}

Write-Status "  ESC1-shaped template candidates found: $($esc1Candidates.Count)" -Status $(if ($esc1Candidates.Count -gt 0) { "WARN" } else { "OK" })

foreach ($tmpl in $esc1Candidates) {
    $isPublished = if ($publishedTemplateNames.Count -gt 0) { $publishedTemplateNames -contains $tmpl.Name } else { "Unknown" }
    Write-Host "    - $($tmpl.Name)  (Published: $isPublished)"

    # Pull Enroll-right holders for this template
    $enrollHolders = @()
    try {
        $aces = $tmpl.nTSecurityDescriptor.Access
        $enrollHolders = $aces | Where-Object {
            $_.ActiveDirectoryRights -match "ExtendedRight" -and
            ($_.ObjectType -eq $enrollRightGuid -or $_.ObjectType -eq $autoenrollRightGuid -or $_.ObjectType -eq [Guid]::Empty)
        } | Select-Object -ExpandProperty IdentityReference -Unique
    } catch {
        Write-Status "      Could not read ACL for $($tmpl.Name): $_" -Status "WARN"
    }

    $enrollSummary = if ($enrollHolders) { ($enrollHolders -join "; ") } else { "Could not determine" }
    $broadGrant = ($enrollHolders -match "Authenticated Users|Domain Users|Everyone")

    $status = if ($broadGrant) { "ERROR" } else { "WARN" }
    $results += [PSCustomObject]@{
        Category = "ESC1"; Item = $tmpl.Name
        Value = "EnrolleeSuppliesSubject=true; ClientAuthEKU=true"
        Status = $status
        Note = "Published=$isPublished; EnrollRightHolders=$enrollSummary; See ADCSTemplateMisconfiguration-B.md Fix 1"
    }
}

if ($esc1Candidates.Count -eq 0) {
    Write-Status "  No published-schema templates found with the ESC1 combination." -Status "OK"
}

#endregion

#region --- ESC4 Detection ---

Write-Status "`n=== ESC4 Detection: Non-Admin Template ACL Write-Rights (all templates) ===" -Status "HEADER"

$esc4FindingCount = 0
foreach ($tmpl in $allTemplates) {
    try {
        $aces = $tmpl.nTSecurityDescriptor.Access
        $writeAces = $aces | Where-Object {
            ($_.ActiveDirectoryRights -match "WriteDacl|WriteOwner|GenericAll|WriteProperty") -and
            $_.AccessControlType -eq "Allow"
        }
        foreach ($ace in $writeAces) {
            $identity = $ace.IdentityReference.ToString()
            $isKnownAdmin = $false
            foreach ($known in $KnownAdminIdentities) {
                if ($identity -match [regex]::Escape($known)) { $isKnownAdmin = $true; break }
            }
            if (-not $isKnownAdmin) {
                $esc4FindingCount++
                Write-Status "    ESC4 finding: '$identity' holds $($ace.ActiveDirectoryRights) on template '$($tmpl.Name)'" -Status "ERROR"
                $results += [PSCustomObject]@{
                    Category = "ESC4"; Item = $tmpl.Name
                    Value = $identity
                    Status = "ERROR"
                    Note = "Rights=$($ace.ActiveDirectoryRights); non-admin identity can reconfigure this template into an ESC1 shape; see ADCSTemplateMisconfiguration-B.md Fix 2"
                }
            }
        }
    } catch {
        Write-Status "  Could not read ACL for $($tmpl.Name): $_" -Status "WARN"
        $results += [PSCustomObject]@{ Category = "ESC4"; Item = $tmpl.Name; Value = "ACL read failed"; Status = "WARN"; Note = "$_" }
    }
}

if ($esc4FindingCount -eq 0) {
    Write-Status "  No non-admin WriteDacl/WriteOwner/WriteProperty/GenericAll grants found on any template." -Status "OK"
} else {
    Write-Status "  Total ESC4 findings: $esc4FindingCount" -Status "ERROR"
}

#endregion

#region --- Export & Summary ---

$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

Write-Status "`n=== Summary ===" -Status "HEADER"
$errorCount = ($results | Where-Object Status -eq "ERROR").Count
$warnCount  = ($results | Where-Object Status -eq "WARN").Count
Write-Host "  Total checks/findings : $($results.Count)"
Write-Host "  Errors (high confidence, likely exploitable) : $errorCount"
Write-Host "  Warnings (review recommended)                : $warnCount"
Write-Host "  Report saved to        : $ExportPath"

if ($errorCount -gt 0) {
    Write-Status "High-confidence ESC1/ESC4 findings present. Review the CSV and apply the remediation playbooks in ADCSTemplateMisconfiguration-B.md / -A.md." -Status "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "Candidate findings present that warrant manual review — see CSV." -Status "WARN"
} else {
    Write-Status "No ESC1/ESC4 indicators found in this pass." -Status "OK"
}

#endregion
