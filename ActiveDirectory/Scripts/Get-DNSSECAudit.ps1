<#
.SYNOPSIS
    DNSSEC posture audit for AD-integrated (and file-backed) DNS zones — signing state, Key Master health,
    key rollover configuration, trust anchor presence, and secure-delegation chain status.

.DESCRIPTION
    Collects and reports on:
      - Per-zone signed/unsigned state and, if signed, Key Master identity + online/offline status
      - KSK/ZSK inventory: cryptographic algorithm, NSEC/NSEC3 consistency, rollover status
      - Trust anchor presence on the local server for each signed zone
      - RFC 5011 automatic trust anchor rollover configuration
      - Secure delegation status to the parent zone (ParentHasSecureDelegation) for child zones
      - A live Resolve-DnsName -DnssecOk test per signed zone, flagging missing or expiring RRSIG data
      - Explicit reminder that nslookup.exe is NOT a valid DNSSEC test tool (informational only, does not run it)

    Does NOT sign, unsign, roll keys, move/seize the Key Master role, or modify any DNS record.
    Read-only. Exports a consolidated CSV for escalation/reporting.

.PARAMETER ZoneName
    One or more specific zone names to audit. If omitted, every primary zone on the local DNS server is audited.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\DNSSECAudit_<timestamp>.csv

.PARAMETER SignatureExpiryWarningDays
    Flag RRSIG records expiring within this many days as a warning. Default: 14.

.PARAMETER SkipLiveQueryTest
    Skip the Resolve-DnsName -DnssecOk live query test per zone (useful for a config-only, network-independent
    audit pass). Default: $false.

.EXAMPLE
    .\Get-DNSSECAudit.ps1
    # Audits every zone on the local DNS server, full CSV export

.EXAMPLE
    .\Get-DNSSECAudit.ps1 -ZoneName "secure.contoso.com","contoso.com" -SignatureExpiryWarningDays 7
    # Audits two specific zones, tightens the expiry warning window to 7 days

.NOTES
    Requires: DnsServer PowerShell module (installed with DNS Server role or via RSAT: DNS Server Tools)
    Run as: Domain Admin or delegated DNSSEC-viewing rights on a primary, authoritative DNS server
    Best run: Directly on a DC/DNS server that is (or can reach) the Key Master for the zones being audited —
              DNSSEC properties cannot be viewed on a secondary zone
    Safe/Unsafe: READ-ONLY — makes no changes to zones, keys, trust anchors, or DNS records
    Tested against: Windows Server 2016 / 2019 / 2022 / 2025 DNS Server role
#>

[CmdletBinding()]
param(
    [string[]] $ZoneName,
    [string]   $ExportPath                  = "$env:TEMP\DNSSECAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [int]      $SignatureExpiryWarningDays  = 14,
    [switch]   $SkipLiveQueryTest
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

#region --- Preflight ---

Write-Status "DNSSEC Posture Audit" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"
Write-Status "Reminder: nslookup.exe is NOT DNSSEC-aware — never use it to validate these findings. This script and Resolve-DnsName -DnssecOk are the supported test methods." -Status "INFO"

if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    Write-Status "DnsServer module not found. Run on a DNS server with the role installed, or install RSAT: DNS Server Tools." -Status "ERROR"
    return
}
Import-Module DnsServer -ErrorAction Stop

$results = [System.Collections.Generic.List[object]]::new()

#endregion

#region --- Zone discovery ---

try {
    if ($ZoneName) {
        $zones = foreach ($z in $ZoneName) { Get-DnsServerZone -Name $z -ErrorAction Stop }
    } else {
        $zones = Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq "Primary" }
    }
} catch {
    Write-Status "Failed to enumerate zones: $_" -Status "ERROR"
    return
}

Write-Status "Zones to audit: $($zones.Count)" -Status "INFO"

#endregion

#region --- Per-zone DNSSEC audit ---

foreach ($zone in $zones) {

    $zn = $zone.ZoneName
    Write-Status "Auditing zone: $zn" -Status "HEADER"

    $row = [ordered]@{
        ZoneName                   = $zn
        IsDsIntegrated             = $zone.IsDsIntegrated
        IsSigned                   = $false
        KeyMasterServer            = $null
        KeyMasterStatus            = $null
        IsKeyMasterServerLocal     = $null
        KSKCount                   = 0
        ZSKCount                   = 0
        CryptoAlgorithms           = $null
        NsecMode                   = $null
        Rfc5011TrustAnchorRollover = $null
        TrustAnchorPresentLocally  = $false
        ParentHasSecureDelegation  = $null
        LiveQueryRRSIGFound        = $null
        SoonestSignatureExpiry     = $null
        Findings                   = [System.Collections.Generic.List[string]]::new()
    }

    # --- Signed state + Key Master ---
    $dnssecSetting = $null
    try {
        $dnssecSetting = Get-DnsServerDnsSecZoneSetting -ZoneName $zn -ErrorAction Stop
    } catch {
        $row.Findings.Add("Zone is not signed (Get-DnsServerDnsSecZoneSetting returned no data or errored) — informational only unless signing was expected here.")
    }

    if ($dnssecSetting) {
        $row.IsSigned                   = $true
        $row.KeyMasterServer            = $dnssecSetting.KeyMasterServer
        $row.KeyMasterStatus            = $dnssecSetting.KeyMasterStatus
        $row.IsKeyMasterServerLocal     = $dnssecSetting.IsKeyMasterServer
        $row.Rfc5011TrustAnchorRollover = $dnssecSetting.EnableRfc5011KeyRollover
        $row.ParentHasSecureDelegation  = $dnssecSetting.ParentHasSecureDelegation

        if ($dnssecSetting.KeyMasterStatus -eq "Offline") {
            $row.Findings.Add("Key Master is OFFLINE — signing/key rollover operations for this zone are stalled. See Fix 3 (DNSSEC-B.md) or Playbook 2 (DNSSEC-A.md) before signatures approach expiry.")
        }

        if (-not $dnssecSetting.EnableRfc5011KeyRollover) {
            $row.Findings.Add("RFC 5011 automatic trust anchor rollover is DISABLED — every KSK rollover requires someone to manually push updated trust anchors to every validating resolver. Confirm this is a known, owned manual process.")
        }

        if ($row.ParentHasSecureDelegation -eq $false) {
            $row.Findings.Add("ParentHasSecureDelegation = False. If the parent zone is intentionally unsigned, this is expected (island of trust). If the parent IS signed, a DS record is missing — see Fix 4 (DNSSEC-B.md) / Playbook 3 (DNSSEC-A.md).")
        }

        # --- Signing key inventory ---
        try {
            $keys = Get-DnsServerSigningKey -ZoneName $zn -ErrorAction Stop
            $row.KSKCount         = @($keys | Where-Object KeyType -eq "KeySigningKey").Count
            $row.ZSKCount         = @($keys | Where-Object KeyType -eq "ZoneSigningKey").Count
            $row.CryptoAlgorithms = ($keys | Select-Object -ExpandProperty CryptoAlgorithm -Unique) -join ", "

            if ($row.KSKCount -eq 0) { $row.Findings.Add("No KSK found — a signed zone requires at least one Key Signing Key.") }
            if ($row.ZSKCount -eq 0) { $row.Findings.Add("No ZSK found — a signed zone requires at least one Zone Signing Key.") }

            $algosDistinct = $keys | Select-Object -ExpandProperty CryptoAlgorithm -Unique
            if (($algosDistinct -contains "RsaSha1") -and ($algosDistinct -contains "RsaSha1Nsec3")) {
                $row.Findings.Add("Incompatible algorithm mix detected: RSA/SHA-1 and RSA/SHA-1 (NSEC3) cannot coexist in the same zone — this zone is likely mid-migration or misconfigured.")
            }
        } catch {
            $row.Findings.Add("Could not enumerate signing keys: $_")
        }

        # --- Trust anchor presence (local server) ---
        try {
            $anchor = Get-DnsServerTrustAnchor -Name $zn -ErrorAction Stop
            $row.TrustAnchorPresentLocally = [bool]$anchor
            if (-not $anchor) {
                $row.Findings.Add("No trust anchor found locally for this zone. If this server is expected to VALIDATE responses for it (not just serve them), validation will fail with DNS_ERROR_UNSECURE_PACKET for any client requiring it.")
            }
        } catch {
            $row.Findings.Add("Trust anchor lookup failed or zone has no trust anchor configured locally: $_")
        }

        # --- Live query test ---
        if (-not $SkipLiveQueryTest) {
            try {
                $queryResult = Resolve-DnsName -Name $zn -Type SOA -DnssecOk -ErrorAction Stop
                $rrsig = $queryResult | Where-Object QueryType -eq "RRSIG"
                $row.LiveQueryRRSIGFound = [bool]$rrsig

                if (-not $rrsig) {
                    $row.Findings.Add("Live Resolve-DnsName -DnssecOk query returned no RRSIG record for the zone apex. Either the zone isn't actually signed as reported, or this query was answered by a non-authoritative/non-signing server.")
                } else {
                    $soonest = ($rrsig | Sort-Object Expiration | Select-Object -First 1).Expiration
                    $row.SoonestSignatureExpiry = $soonest
                    if ($soonest -and ($soonest -lt (Get-Date))) {
                        $row.Findings.Add("SIGNATURE EXPIRED ($soonest) — validation will fail for any resolver requiring DNSSEC for this zone. Check Key Master reachability across the rollover boundary.")
                    } elseif ($soonest -and ($soonest -lt (Get-Date).AddDays($SignatureExpiryWarningDays))) {
                        $row.Findings.Add("Signature expiring soon ($soonest, within $SignatureExpiryWarningDays days) — confirm automatic rollover is functioning before this becomes an outage.")
                    }
                }
            } catch {
                $row.Findings.Add("Live DNSSEC query test failed: $_")
            }
        }
    }

    $results.Add([pscustomobject]$row)

    if ($row.Findings.Count -eq 0) {
        Write-Status "  No issues found." -Status "OK"
    } else {
        foreach ($f in $row.Findings) { Write-Status "  $f" -Status "WARN" }
    }
}

#endregion

#region --- Report ---

Write-Status "" -Status "INFO"
Write-Status "=== Summary ===" -Status "HEADER"
$signedCount = @($results | Where-Object IsSigned).Count
Write-Status "Zones audited: $($results.Count)  |  Signed: $signedCount  |  Unsigned: $($results.Count - $signedCount)" -Status "INFO"

$flagged = $results | Where-Object { $_.Findings.Count -gt 0 }
Write-Status "Zones with findings: $($flagged.Count)" -Status $(if ($flagged.Count -gt 0) { "WARN" } else { "OK" })

$exportRows = $results | ForEach-Object {
    [pscustomobject]@{
        ZoneName                   = $_.ZoneName
        IsDsIntegrated             = $_.IsDsIntegrated
        IsSigned                   = $_.IsSigned
        KeyMasterServer            = $_.KeyMasterServer
        KeyMasterStatus            = $_.KeyMasterStatus
        IsKeyMasterServerLocal     = $_.IsKeyMasterServerLocal
        KSKCount                   = $_.KSKCount
        ZSKCount                   = $_.ZSKCount
        CryptoAlgorithms           = $_.CryptoAlgorithms
        Rfc5011TrustAnchorRollover = $_.Rfc5011TrustAnchorRollover
        TrustAnchorPresentLocally  = $_.TrustAnchorPresentLocally
        ParentHasSecureDelegation  = $_.ParentHasSecureDelegation
        LiveQueryRRSIGFound        = $_.LiveQueryRRSIGFound
        SoonestSignatureExpiry     = $_.SoonestSignatureExpiry
        FindingsCount              = $_.Findings.Count
        Findings                   = ($_.Findings -join " | ")
    }
}

$exportRows | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" -Status "OK"

#endregion
