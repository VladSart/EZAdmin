<#
.SYNOPSIS
    Read-only health and configuration audit for a Microsoft Entra Domain Services (AADDS) managed domain.

.DESCRIPTION
    Collects control-plane state (Az PowerShell), tenant sync/federation posture (Microsoft Graph
    PowerShell), and NSG/route-table configuration for a Microsoft Entra Domain Services managed
    domain, then flags common misconfiguration patterns documented in EntraDomainServices-A.md:
      - Federated tenant without Password Hash Synchronization (hard blocker for the whole feature)
      - NSG rules deviating from the platform-managed baseline (unsupported, breaks sync/management)
      - A user-defined route touching 0.0.0.0/0 on the managed domain's subnet (unsupported)
      - Stale Domain Services app registrations that block re-enablement after a failed attempt

    Optionally, when run FROM a management VM domain-joined to the managed domain (-ManagedDomainFQDN
    supplied and the ActiveDirectory RSAT module present), also audits a sample of in-domain user
    objects for PasswordLastSet gaps (cloud-only users who've never changed their password since
    enablement) and current lockout state.

    This script does NOT modify any configuration. It is read-only by design.

.PARAMETER DomainServiceName
    The name of the Microsoft Entra Domain Services resource (managed domain) in Azure.

.PARAMETER ResourceGroupName
    Resource group containing the Domain Services resource.

.PARAMETER ManagedDomainFQDN
    Optional. The managed domain's FQDN (e.g. dscontoso.com). If supplied and the ActiveDirectory
    RSAT module is available, enables the in-domain user sampling checks.

.PARAMETER SampleUserCount
    Optional. Number of in-domain user objects to sample for PasswordLastSet/lockout checks when
    -ManagedDomainFQDN is supplied. Default 25.

.PARAMETER OutputPath
    Optional. Folder to write the CSV/JSON evidence exports to. Defaults to the current directory.

.EXAMPLE
    .\Get-EntraDomainServicesHealth.ps1 -DomainServiceName "dscontoso" -ResourceGroupName "rg-identity"

    Runs the control-plane, tenant, and networking checks only.

.EXAMPLE
    .\Get-EntraDomainServicesHealth.ps1 -DomainServiceName "dscontoso" -ResourceGroupName "rg-identity" `
        -ManagedDomainFQDN "dscontoso.com" -SampleUserCount 50

    Also samples 50 in-domain user objects for credential-sync and lockout health (requires RSAT
    ActiveDirectory module and execution from a machine domain-joined to the managed domain, or with
    line-of-sight + -Server targeting rights to it).

.NOTES
    Requires: Az.DomainServices / Az.Network (Az PowerShell), Microsoft.Graph.Identity.DirectoryManagement
    (Microsoft Graph PowerShell), already-authenticated context for both (Connect-AzAccount / Connect-MgGraph).
    Optional: ActiveDirectory module (RSAT) for the -ManagedDomainFQDN in-domain checks.
    Read-only. Safe to run at any time, including against a production managed domain.
    Run-as: any account with Reader on the Domain Services resource group and Directory Readers in Entra ID
    is sufficient for the control-plane/tenant checks. In-domain checks require an account that can query
    the managed domain (no elevated managed-domain rights needed for read-only queries).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$DomainServiceName,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [string]$ManagedDomainFQDN,
    [int]$SampleUserCount = 25,
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Area, [string]$Severity, [string]$Detail)
    $findings.Add([pscustomobject]@{
        Timestamp = Get-Date -Format "o"
        Area      = $Area
        Severity  = $Severity
        Detail    = $Detail
    })
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Checking required modules and authenticated context..." "INFO"

$requiredModules = @("Az.DomainServices", "Az.Network", "Microsoft.Graph.Identity.DirectoryManagement")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" "WARN"
    }
}

try {
    $null = Get-AzContext -ErrorAction Stop
    Write-Status "Az PowerShell context confirmed." "OK"
}
catch {
    Write-Status "No active Az PowerShell context. Run Connect-AzAccount first." "ERROR"
    throw
}

try {
    $null = Get-MgContext -ErrorAction Stop
    Write-Status "Microsoft Graph PowerShell context confirmed." "OK"
}
catch {
    Write-Status "No active Microsoft Graph PowerShell context. Run Connect-MgGraph -Scopes 'Organization.Read.All','User.Read.All' first." "ERROR"
    throw
}

$inDomainChecksAvailable = $false
if ($ManagedDomainFQDN) {
    if (Get-Module -ListAvailable -Name ActiveDirectory) {
        $inDomainChecksAvailable = $true
        Write-Status "ActiveDirectory module found. In-domain checks enabled for $ManagedDomainFQDN." "OK"
    }
    else {
        Write-Status "ActiveDirectory (RSAT) module not found. Skipping in-domain checks despite -ManagedDomainFQDN being supplied." "WARN"
        Add-Finding -Area "Preflight" -Severity "WARN" -Detail "ActiveDirectory RSAT module unavailable; in-domain PasswordLastSet/lockout checks skipped."
    }
}

# ---------------------------------------------------------------------------
# 1. Control-plane health
# ---------------------------------------------------------------------------
Write-Status "Retrieving managed domain control-plane state..." "INFO"

$domainService = $null
try {
    $domainService = Get-AzADDomainService -Name $DomainServiceName -ResourceGroupName $ResourceGroupName
    Write-Status "Managed domain '$($domainService.DomainName)' retrieved." "OK"
    if ($domainService.ProvisioningState -and $domainService.ProvisioningState -ne "Succeeded") {
        Add-Finding -Area "ControlPlane" -Severity "ERROR" -Detail "ProvisioningState is '$($domainService.ProvisioningState)', not 'Succeeded'."
    }
}
catch {
    Write-Status "Failed to retrieve Domain Services resource '$DomainServiceName' in RG '$ResourceGroupName': $($_.Exception.Message)" "ERROR"
    Add-Finding -Area "ControlPlane" -Severity "ERROR" -Detail "Unable to retrieve Domain Services resource: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 2. Tenant sync / federation posture
# ---------------------------------------------------------------------------
Write-Status "Checking tenant password hash sync / federation posture..." "INFO"

try {
    $org = Get-MgOrganization
    $onPremSyncEnabled = $org.OnPremisesSyncEnabled
    if ($null -eq $onPremSyncEnabled -or $onPremSyncEnabled -eq $false) {
        Write-Status "Tenant appears cloud-only or on-prem sync not currently reporting enabled (OnPremisesSyncEnabled=$onPremSyncEnabled)." "INFO"
    }
    else {
        Write-Status "Tenant is hybrid-synchronized (OnPremisesSyncEnabled=True)." "OK"
    }
    Add-Finding -Area "TenantSync" -Severity "INFO" -Detail "OnPremisesSyncEnabled=$onPremSyncEnabled. Confirm separately in Microsoft Entra Connect that Password Hash Synchronization is enabled -- this API does not directly expose PHS-vs-federation state, and a federated tenant WITHOUT PHS enabled as a backup is a hard blocker for Domain Services authentication tenant-wide."
}
catch {
    Write-Status "Failed to retrieve tenant organization info: $($_.Exception.Message)" "ERROR"
    Add-Finding -Area "TenantSync" -Severity "ERROR" -Detail "Unable to retrieve organization info: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 3. NSG baseline check on the managed domain's subnet
# ---------------------------------------------------------------------------
Write-Status "Checking NSG configuration on the managed domain subnet..." "INFO"

$requiredInboundRuleNames = @("AllowVnetInBound", "AllowAzureLoadBalancerInBound")
$expectedManagementTag    = "AzureActiveDirectoryDomainServices"

try {
    $nsgs = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName
    $ddsNsg = $nsgs | Where-Object { $_.Name -match [regex]::Escape($DomainServiceName) -or $_.Tag.Values -match "DomainServices" }

    if (-not $ddsNsg) {
        Write-Status "Could not auto-identify the managed domain's NSG by name match. Falling back to listing all NSGs in the RG for manual review." "WARN"
        Add-Finding -Area "Networking" -Severity "WARN" -Detail "NSG auto-identification by name failed; $($nsgs.Count) NSG(s) found in resource group '$ResourceGroupName' -- verify manually which one is attached to the managed domain subnet."
    }
    else {
        foreach ($nsg in $ddsNsg) {
            $ruleNames = $nsg.SecurityRules.Name
            foreach ($required in $requiredInboundRuleNames) {
                if ($ruleNames -notcontains $required) {
                    Add-Finding -Area "Networking" -Severity "WARN" -Detail "NSG '$($nsg.Name)' is missing expected default rule '$required' (defaults are usually implicit, not explicit -- confirm this isn't a false positive before treating as a defect)."
                }
            }

            $mgmtRule = $nsg.SecurityRules | Where-Object { $_.SourceAddressPrefix -eq $expectedManagementTag -or $_.DestinationPortRange -contains "5986" }
            if (-not $mgmtRule) {
                Add-Finding -Area "Networking" -Severity "ERROR" -Detail "NSG '$($nsg.Name)' has no inbound rule for TCP 5986 from the $expectedManagementTag service tag -- required for Microsoft to manage the domain (WinRM)."
            }

            $customRules = $nsg.SecurityRules | Where-Object {
                $_.SourceAddressPrefix -notin @($expectedManagementTag, "CorpNetSaw", "VirtualNetwork", "AzureLoadBalancer", "*") -and
                $_.Name -notin @("AllowVnetInBound", "AllowAzureLoadBalancerInBound", "AllowVnetOutBound", "AllowInternetOutBound")
            }
            foreach ($cr in $customRules) {
                Add-Finding -Area "Networking" -Severity "WARN" -Detail "NSG '$($nsg.Name)' rule '$($cr.Name)' does not match the documented platform-managed baseline -- review for an unsupported manual edit (source: $($cr.SourceAddressPrefix), dest port: $($cr.DestinationPortRange -join ','))."
            }
            if (-not $customRules -and $mgmtRule) {
                Write-Status "NSG '$($nsg.Name)' matches the expected platform-managed baseline." "OK"
            }
        }
    }
}
catch {
    Write-Status "Failed to retrieve/evaluate NSG configuration: $($_.Exception.Message)" "ERROR"
    Add-Finding -Area "Networking" -Severity "ERROR" -Detail "Unable to evaluate NSG configuration: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 4. Route table / UDR check
# ---------------------------------------------------------------------------
Write-Status "Checking for unsupported user-defined routes (0.0.0.0/0)..." "INFO"

try {
    $routeTables = Get-AzRouteTable -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    foreach ($rt in $routeTables) {
        $defaultRoute = $rt.Routes | Where-Object { $_.AddressPrefix -eq "0.0.0.0/0" }
        if ($defaultRoute) {
            Add-Finding -Area "Networking" -Severity "WARN" -Detail "Route table '$($rt.Name)' contains a user-defined 0.0.0.0/0 route (NextHop: $($defaultRoute.NextHopType)) -- if associated with the managed domain's subnet, this is an unsupported configuration that can disrupt sync/management/patching."
        }
    }
    if (-not $routeTables) {
        Write-Status "No route tables found in resource group '$ResourceGroupName'." "OK"
    }
}
catch {
    Write-Status "Failed to retrieve route tables: $($_.Exception.Message)" "WARN"
    Add-Finding -Area "Networking" -Severity "WARN" -Detail "Unable to retrieve route tables for UDR check: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 5. Stale Domain Services app registration check (enablement blockers)
# ---------------------------------------------------------------------------
Write-Status "Checking for stale Domain Services app registrations..." "INFO"

try {
    $staleAppId = "d87dcbc6-a371-462e-88e3-28ad15ec4e64"
    $staleSp = Get-MgServicePrincipal -Filter "AppId eq '$staleAppId'" -ErrorAction SilentlyContinue
    if ($staleSp) {
        Add-Finding -Area "TenantConfig" -Severity "WARN" -Detail "Found service principal for AppId '$staleAppId' (AzureActiveDirectoryDomainControllerServices) -- if a prior Domain Services enablement failed, this can block a clean re-enable attempt."
    }

    $syncAppUri = "https://sync.aaddc.activedirectory.windowsazure.com"
    $syncApp = Get-MgApplication -Filter "IdentifierUris eq '$syncAppUri'" -ErrorAction SilentlyContinue
    if ($syncApp) {
        Add-Finding -Area "TenantConfig" -Severity "WARN" -Detail "Found stale 'Microsoft Entra Domain Services Sync' application (IdentifierUri '$syncAppUri') -- can block re-enablement after a prior failed/deleted deployment."
    }

    if (-not $staleSp -and -not $syncApp) {
        Write-Status "No stale Domain Services app registrations found." "OK"
    }
}
catch {
    Write-Status "Failed to check for stale app registrations: $($_.Exception.Message)" "WARN"
    Add-Finding -Area "TenantConfig" -Severity "WARN" -Detail "Unable to check for stale app registrations: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 6. Optional in-domain user sampling
# ---------------------------------------------------------------------------
$sampledUsers = @()
if ($inDomainChecksAvailable) {
    Write-Status "Sampling up to $SampleUserCount in-domain user objects on $ManagedDomainFQDN..." "INFO"
    try {
        $sampledUsers = Get-ADUser -Filter * -Server $ManagedDomainFQDN -ResultSetSize $SampleUserCount `
            -Properties PasswordLastSet, LockedOut, Enabled, SamAccountName, whenCreated |
            Select-Object SamAccountName, UserPrincipalName, Enabled, LockedOut, PasswordLastSet, whenCreated

        $neverSetPassword = $sampledUsers | Where-Object { -not $_.PasswordLastSet }
        foreach ($u in $neverSetPassword) {
            Add-Finding -Area "InDomainUsers" -Severity "WARN" -Detail "User '$($u.SamAccountName)' has no PasswordLastSet value -- likely a cloud-only account that has never changed its password since Domain Services was enabled, so no NTLM/Kerberos hash has synchronized yet."
        }

        $lockedOut = $sampledUsers | Where-Object { $_.LockedOut }
        foreach ($u in $lockedOut) {
            Add-Finding -Area "InDomainUsers" -Severity "WARN" -Detail "User '$($u.SamAccountName)' is currently locked out IN THE MANAGED DOMAIN (local-only state, not reflected in Entra ID)."
        }

        Write-Status "Sampled $($sampledUsers.Count) user object(s): $($neverSetPassword.Count) with no PasswordLastSet, $($lockedOut.Count) currently locked out." "INFO"
    }
    catch {
        Write-Status "Failed to sample in-domain users: $($_.Exception.Message)" "WARN"
        Add-Finding -Area "InDomainUsers" -Severity "WARN" -Detail "Unable to sample in-domain users against '$ManagedDomainFQDN': $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "----------------------------------------------------------" "INFO"
Write-Status "Summary: $($findings.Count) finding(s) recorded ($(($findings | Where-Object Severity -eq 'ERROR').Count) ERROR, $(($findings | Where-Object Severity -eq 'WARN').Count) WARN, $(($findings | Where-Object Severity -eq 'INFO').Count) INFO)" "INFO"

foreach ($f in $findings) {
    Write-Status "[$($f.Area)] $($f.Detail)" $f.Severity
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$findingsPath = Join-Path $OutputPath "EntraDomainServicesHealth-Findings-$timestamp.csv"
$findings | Export-Csv -Path $findingsPath -NoTypeInformation
Write-Status "Findings exported to $findingsPath" "OK"

if ($sampledUsers) {
    $usersPath = Join-Path $OutputPath "EntraDomainServicesHealth-SampledUsers-$timestamp.csv"
    $sampledUsers | Export-Csv -Path $usersPath -NoTypeInformation
    Write-Status "Sampled user data exported to $usersPath" "OK"
}

Write-Status "Audit complete. This script made no configuration changes." "OK"
