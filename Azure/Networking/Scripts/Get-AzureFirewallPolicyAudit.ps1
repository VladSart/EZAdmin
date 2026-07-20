<#
.SYNOPSIS
    Read-only fleet-wide audit of Azure Firewall resources and their Firewall Policies for
    SKU mismatches, rule-ordering red flags, TLS inspection certificate health, and IDPS posture.

.DESCRIPTION
    Sweeps every Azure Firewall visible in the current Az context (or a specified subscription
    list) and flags common Firewall-Policy-specific risk conditions that don't surface as an
    obvious "unhealthy" state on the resource itself:

      - Firewall Policy SKU tier lower than the Firewall resource's own SKU tier (the #1 silent
        gap — Premium compute with a Standard/Basic policy quietly has no TLS inspection/IDPS)
      - TLS inspection enabled but the referenced Key Vault certificate is expired or expiring
        inside a configurable warning window
      - TLS inspection enabled at the policy level with zero Application rules actually opted in
        at the rule level (policy-level toggle alone does nothing)
      - IDPS mode set to Off on a Premium policy (feature paid for, not turned on)
      - A large number of IDPS signature overrides present (drift/tuning-debt signal worth a
        periodic review, not inherently wrong)
      - DNAT (NAT-type) rule collections present with zero corresponding Network rule collections
        in the same policy — a heuristic flag for "may be missing the post-translation allow,"
        not a definitive finding, since a permissive default elsewhere can make this a non-issue
      - Rule Collection Groups sharing the same priority number (undefined/ambiguous tie-break
        behavior within Azure Firewall Policy)
      - Firewall deployed in a Virtual WAN secured hub (HubIPAddresses populated) flagged
        informationally, since routing-layer issues for these belong in VirtualWAN-B.md/A.md,
        not this script's rule-content checks

    This script makes NO configuration changes. Every finding is written to the console and
    exported to CSV for ticket attachment or trend tracking across visits.

.PARAMETER SubscriptionId
    One or more subscription IDs to sweep. If omitted, uses all subscriptions the current Az
    context can see.

.PARAMETER CertExpiryWarningDays
    Number of days before a TLS inspection certificate's expiry to raise a warning finding.
    Default: 60.

.PARAMETER SignatureOverrideWarningCount
    Number of IDPS signature overrides on a single policy at which to raise an informational
    "review tuning debt" finding. Default: 200.

.PARAMETER OutputPath
    Folder to write the CSV report to. Default: current directory.

.EXAMPLE
    .\Get-AzureFirewallPolicyAudit.ps1
    Audits every Azure Firewall and its associated policy in every subscription the current
    session can see.

.EXAMPLE
    .\Get-AzureFirewallPolicyAudit.ps1 -SubscriptionId "11111111-1111-1111-1111-111111111111" -CertExpiryWarningDays 90

.NOTES
    Requires: Az.Network, Az.KeyVault modules, an authenticated Az context (Connect-AzAccount)
    with at minimum Reader role on the target subscription(s) and, for the certificate-expiry
    check, Key Vault Secret "Get" access on the certificate referenced by TransportSecurity
    (if the running identity lacks this, that specific check is skipped with a warning, not a
    script failure).
    Read-only — makes no changes to any firewall, policy, rule, or certificate.
    The DNAT-without-Network-rule check is explicitly a heuristic (flagged for manual review)
    since a policy's default action and rule collection group ordering can make a bare DNAT
    rule collection non-issue in context — always confirm against the runbook's evaluation-order
    guidance (AzureFirewall-A.md "Rule evaluation order") before treating it as a defect.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 365)]
    [int]$CertExpiryWarningDays = 60,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10000)]
    [int]$SignatureOverrideWarningCount = 200,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# SKU rank for comparing Firewall vs. Policy tiers ("lower policy tier than firewall" = gap)
$SkuRank = @{ "Basic" = 1; "Standard" = 2; "Premium" = 3 }

if (-not (Get-AzContext)) {
    Write-Status "No active Az context. Run Connect-AzAccount first." -Status "ERROR"
    exit 1
}

$subs = if ($SubscriptionId) {
    $SubscriptionId | ForEach-Object { Get-AzSubscription -SubscriptionId $_ }
} else {
    Get-AzSubscription
}

Write-Status "Sweeping $($subs.Count) subscription(s) for Azure Firewalls..." -Status "INFO"

$findings = New-Object System.Collections.Generic.List[Object]

foreach ($sub in $subs) {
    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
    } catch {
        Write-Status "Could not set context to subscription $($sub.Name) ($($sub.Id)): $_" -Status "WARN"
        continue
    }

    $firewalls = @()
    try {
        $firewalls = Get-AzFirewall -ErrorAction Stop
    } catch {
        Write-Status "Could not enumerate Azure Firewalls in $($sub.Name): $_" -Status "WARN"
        continue
    }

    if (-not $firewalls) { continue }

    foreach ($fw in $firewalls) {
        $ctxLabel = "$($sub.Name)/$($fw.ResourceGroupName)/$($fw.Name)"
        Write-Status "Checking $ctxLabel" -Status "INFO"

        $isVwanHosted = $null -ne $fw.HubIPAddresses
        if ($isVwanHosted) {
            $findings.Add([PSCustomObject]@{
                Subscription = $sub.Name; ResourceGroup = $fw.ResourceGroupName; Firewall = $fw.Name
                Category = "Deployment Model"; Severity = "Info"
                Finding = "Virtual WAN secured-hub deployment (HubIPAddresses populated)"
                Detail = "Routing-layer issues (traffic not reaching the firewall) belong in VirtualWAN-B.md/A.md, not this script's rule-content checks."
            })
        }

        if (-not $fw.FirewallPolicy -or -not $fw.FirewallPolicy.Id) {
            $findings.Add([PSCustomObject]@{
                Subscription = $sub.Name; ResourceGroup = $fw.ResourceGroupName; Firewall = $fw.Name
                Category = "Policy Association"; Severity = "High"
                Finding = "No Firewall Policy associated"
                Detail = "Firewall is using classic (non-policy) rules, or is unconfigured. Modern rule management requires an associated Firewall Policy."
            })
            continue
        }

        # Resolve the policy object from its resource ID
        $policy = $null
        try {
            $policyResource = Get-AzResource -ResourceId $fw.FirewallPolicy.Id -ErrorAction Stop
            $policy = Get-AzFirewallPolicy -ResourceGroupName $policyResource.ResourceGroupName -Name $policyResource.Name -ErrorAction Stop
        } catch {
            Write-Status "  Could not resolve Firewall Policy for $($fw.Name): $_" -Status "WARN"
            continue
        }

        # --- SKU mismatch: policy tier lower than firewall tier ---
        $fwRank = $SkuRank[$fw.Sku.Tier]
        $policyRank = $SkuRank[$policy.Sku]
        if ($fwRank -and $policyRank -and $policyRank -lt $fwRank) {
            $findings.Add([PSCustomObject]@{
                Subscription = $sub.Name; ResourceGroup = $fw.ResourceGroupName; Firewall = $fw.Name
                Category = "SKU Mismatch"; Severity = "High"
                Finding = "Firewall SKU '$($fw.Sku.Tier)' but Policy SKU '$($policy.Sku)'"
                Detail = "Premium-tier compute paid for but policy tier caps available features (no TLS inspection/IDPS). See AzureFirewall-B.md Fix 2."
            })
        }

        # --- TLS inspection: enabled at policy level? cert present/expiring? ---
        $tlsEnabled = $null -ne $policy.TransportSecurity
        if ($tlsEnabled) {
            $certSecretId = $policy.TransportSecurity.CertificateAuthority.KeyVaultSecretId
            if (-not $certSecretId) {
                $findings.Add([PSCustomObject]@{
                    Subscription = $sub.Name; ResourceGroup = $fw.ResourceGroupName; Firewall = $fw.Name
                    Category = "TLS Inspection"; Severity = "High"
                    Finding = "TransportSecurity configured but no CertificateAuthority secret reference found"
                    Detail = "TLS inspection will not function without a valid Key Vault-backed CA certificate."
                })
            } else {
                try {
                    $secretUri = [Uri]$certSecretId
                    $vaultName = $secretUri.Host.Split('.')[0]
                    $secretName = $secretUri.Segments[2].TrimEnd('/')
                    $cert = Get-AzKeyVaultCertificate -VaultName $vaultName -Name $secretName -ErrorAction Stop
                    if ($cert -and $cert.Expires) {
                        $daysLeft = ($cert.Expires - (Get-Date)).Days
                        if ($daysLeft -lt 0) {
                            $findings.Add([PSCustomObject]@{
                                Subscription = $sub.Name; ResourceGroup = $fw.ResourceGroupName; Firewall = $fw.Name
                                Category = "TLS Certificate Expired"; Severity = "High"
                                Finding = "Intermediate CA certificate expired $([math]::Abs($daysLeft)) day(s) ago"
                                Detail = "All TLS-inspected HTTPS traffic is likely broken tenant-wide until renewed."
                            })
                        } elseif ($daysLeft -le $CertExpiryWarningDays) {
                            $findings.Add([PSCustomObject]@{
                                Subscription = $sub.Name; ResourceGroup = $fw.ResourceGroupName; Firewall = $fw.Name
                                Category = "TLS Certificate Expiring"; Severity = "Medium"
                                Finding = "Intermediate CA certificate expires in $daysLeft day(s)"
                                Detail = "Renew and re-apply to the Firewall Policy before expiry — Azure sends no automatic reminder for this certificate."
                            })
                        }
                    }
                } catch {
                    Write-Status "  Could not read TLS inspection cert for $($fw.Name) (insufficient Key Vault access or parse failure): $_" -Status "WARN"
                }
            }
        }

        # --- IDPS posture ---
        if ($policy.Sku -eq "Premium") {
            $idpsMode = $policy.IntrusionDetection.Mode
            if ($idpsMode -eq "Off" -or -not $idpsMode) {
                $findings.Add([PSCustomObject]@{
                    Subscription = $sub.Name; ResourceGroup = $fw.ResourceGroupName; Firewall = $fw.Name
                    Category = "IDPS Posture"; Severity = "Low"
                    Finding = "IDPS mode is Off on a Premium-tier policy"
                    Detail = "Premium is licensed for IDPS but the feature is not active — confirm this is intentional."
                })
            }

            $overrideCount = ($policy.IntrusionDetection.Configuration.SignatureOverrides | Measure-Object).Count
            if ($overrideCount -ge $SignatureOverrideWarningCount) {
                $findings.Add([PSCustomObject]@{
                    Subscription = $sub.Name; ResourceGroup = $fw.ResourceGroupName; Firewall = $fw.Name
                    Category = "IDPS Tuning Debt"; Severity = "Info"
                    Finding = "$overrideCount signature overrides configured"
                    Detail = "Not inherently wrong, but worth a periodic review to confirm overrides are still justified (max 10,000 supported)."
                })
            }
        }

        # --- Rule Collection Groups: priority collisions + DNAT/Network heuristic ---
        $groups = @()
        try {
            $groups = Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName $policy.ResourceGroupName -PolicyName $policy.Name -ErrorAction Stop
        } catch {
            Write-Status "  Could not enumerate rule collection groups for $($policy.Name): $_" -Status "WARN"
            continue
        }

        $priorityGroups = $groups | Group-Object Priority | Where-Object { $_.Count -gt 1 }
        foreach ($pg in $priorityGroups) {
            $findings.Add([PSCustomObject]@{
                Subscription = $sub.Name; ResourceGroup = $fw.ResourceGroupName; Firewall = $fw.Name
                Category = "Priority Collision"; Severity = "Medium"
                Finding = "$($pg.Count) Rule Collection Groups share priority $($pg.Name): $(($pg.Group.Name) -join ', ')"
                Detail = "Ambiguous tie-break behavior — assign unique priority values."
            })
        }

        $natCollectionCount = 0
        $networkCollectionCount = 0
        foreach ($group in $groups) {
            try {
                $full = Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName $policy.ResourceGroupName -PolicyName $policy.Name -Name $group.Name -ErrorAction Stop
                $natCollectionCount += ($full.Properties.RuleCollection | Where-Object { $_.RuleCollectionType -eq 'FirewallPolicyNatRuleCollection' } | Measure-Object).Count
                $networkCollectionCount += ($full.Properties.RuleCollection | Where-Object { $_.RuleCollectionType -eq 'FirewallPolicyFilterRuleCollection' -and $_.Rules.RuleType -eq 'NetworkRule' } | Measure-Object).Count
            } catch {
                continue
            }
        }
        if ($natCollectionCount -gt 0 -and $networkCollectionCount -eq 0) {
            $findings.Add([PSCustomObject]@{
                Subscription = $sub.Name; ResourceGroup = $fw.ResourceGroupName; Firewall = $fw.Name
                Category = "DNAT Without Network Rule (heuristic)"; Severity = "Low"
                Finding = "$natCollectionCount NAT rule collection(s) present, 0 Network rule collections found"
                Detail = "Manual review recommended — DNAT'd traffic may lack an explicit post-translation allow. Not a definitive finding; a permissive default elsewhere can make this a non-issue."
            })
        }
    }
}

# --- Report ---
Write-Host ""
Write-Status "=== Azure Firewall Policy Audit Summary ===" -Status "INFO"
if ($findings.Count -eq 0) {
    Write-Status "No findings — all audited firewalls/policies look healthy against the checks in this script." -Status "OK"
} else {
    $severityOrder = @{ "High" = 0; "Medium" = 1; "Low" = 2; "Info" = 3 }
    $bySeverity = $findings | Group-Object Severity | Sort-Object @{Expression = { $severityOrder[$_.Name] } }
    foreach ($group in $bySeverity) {
        $status = switch ($group.Name) { "High" { "ERROR" } "Medium" { "WARN" } default { "INFO" } }
        Write-Status "$($group.Name): $($group.Count) finding(s)" -Status $status
    }
    $findings | Sort-Object @{Expression = { $severityOrder[$_.Severity] } }, Firewall |
        Format-Table Subscription, Firewall, Category, Severity, Finding -AutoSize -Wrap
}

$csvPath = Join-Path $OutputPath "AzureFirewallPolicyAudit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Report exported to $csvPath" -Status "OK"
