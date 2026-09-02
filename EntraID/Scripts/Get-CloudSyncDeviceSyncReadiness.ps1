<#
.SYNOPSIS    Read-only readiness and status audit for Microsoft Entra Cloud Sync
             Device Sync (preview).

.DESCRIPTION Checks the local provisioning agent's version against the 1.1.1107
             hard floor required for the AD2AADDeviceSync job type, reads (does
             not modify) the local AD forest's service connection point (SCP)
             keywords used for tenant discovery, and cross-references Microsoft
             Entra device objects carrying the ServerAd trust type (the trust
             type produced by BOTH classic Connect Sync Hybrid Azure AD Join
             AND the new Cloud Sync device sync preview feature -- this script
             cannot distinguish which pipeline produced a given device without
             correlating against Connect Sync's own presence separately).

             This script makes NO configuration changes: it does not enable
             device sync, does not run ConfigureSCP.ps1, and does not modify any
             AD or Entra object. Run it per-forest -- the SCP result is specific
             to whichever forest the executing host's domain controller belongs
             to; a multi-forest environment needs this run once per forest.

.PARAMETER OutputPath
             Directory to write the CSV report to. Defaults to the current
             directory.

.EXAMPLE
             .\Get-CloudSyncDeviceSyncReadiness.ps1
             .\Get-CloudSyncDeviceSyncReadiness.ps1 -OutputPath C:\Reports

.NOTES       Requires: ActiveDirectory RSAT module (for forest context) and an
             active Microsoft Graph connection with Device.Read.All scope
             (Connect-MgGraph -Scopes "Device.Read.All"). Does not require
             Enterprise Admins -- reading SCP keywords needs only standard
             read access to the Configuration naming context. Run as a
             domain-joined, domain-authenticated user.
             Safe/unsafe: fully read-only; safe to run at any time.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
$deviceSyncFloor = [version]"1.1.1107"
$results = [ordered]@{
    Forest                      = $null
    ComputerName                = $env:COMPUTERNAME
    ProvisioningAgentVersion    = $null
    MeetsDeviceSyncVersionFloor = $false
    SCPExists                   = $false
    SCPKeywords                 = $null
    SCPLooksConfigured          = $false
    ServerAdTrustDeviceCount    = $null
    GraphConnected              = $false
    CollectedAt                 = Get-Date
}

# ---- Detect: forest context ----
try {
    $results.Forest = (Get-ADDomain -ErrorAction Stop).Forest
    Write-Status "Forest detected: $($results.Forest)" "OK"
}
catch {
    Write-Status "Could not query AD forest context (ActiveDirectory module missing or not domain-joined). Continuing with local-only checks." "WARN"
}

# ---- Detect: provisioning agent version ----
try {
    $agentKey = "HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent"
    $agentVersionRaw = (Get-ItemProperty -Path $agentKey -ErrorAction SilentlyContinue).Version
    if ($agentVersionRaw) {
        $results.ProvisioningAgentVersion = $agentVersionRaw
        try {
            $results.MeetsDeviceSyncVersionFloor = ([version]$agentVersionRaw) -ge $deviceSyncFloor
        }
        catch {
            Write-Status "Agent version string '$agentVersionRaw' could not be parsed as a [version] -- verify manually." "WARN"
        }
        if ($results.MeetsDeviceSyncVersionFloor) {
            Write-Status "Provisioning agent $agentVersionRaw meets the 1.1.1107 device sync floor." "OK"
        }
        else {
            Write-Status "Provisioning agent $agentVersionRaw is BELOW the 1.1.1107 device sync floor -- upgrade before device sync will be available." "WARN"
        }
    }
    else {
        Write-Status "Microsoft Entra provisioning agent not found on this host (this script is intended to run ON or from a host with the agent installed, or where you can reach its registry key remotely)." "WARN"
    }
}
catch {
    Write-Status "Error reading provisioning agent version: $($_.Exception.Message)" "ERROR"
}

# ---- Detect: SCP (read-only) ----
try {
    $configCN = ([ADSI]"LDAP://RootDSE").configurationNamingContext
    $scpPath  = "LDAP://CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,$configCN"
    if ([System.DirectoryServices.DirectoryEntry]::Exists($scpPath)) {
        $results.SCPExists = $true
        $scpEntry = [ADSI]$scpPath
        $keywords = $scpEntry.keywords
        $results.SCPKeywords = ($keywords -join "; ")
        $hasName = ($keywords | Where-Object { $_ -match '^azureADName:' })
        $hasId   = ($keywords | Where-Object { $_ -match '^azureADId:' })
        $results.SCPLooksConfigured = [bool]($hasName -and $hasId)
        if ($results.SCPLooksConfigured) {
            Write-Status "SCP found with azureADName and azureADId keywords set: $($results.SCPKeywords)" "OK"
        }
        else {
            Write-Status "SCP object exists but is missing azureADName/azureADId keywords -- device discovery will not work in this forest until configured." "WARN"
        }
    }
    else {
        Write-Status "No SCP object found under CN=Device Registration Configuration,CN=Services -- device sync (and classic Hybrid Azure AD Join) cannot discover the tenant in this forest until ConfigureSCP.ps1 is run." "WARN"
    }
}
catch {
    Write-Status "Error reading SCP: $($_.Exception.Message)" "ERROR"
}

# ---- Detect: existing ServerAd-trust devices via Graph ----
try {
    if (Get-Command Get-MgDevice -ErrorAction SilentlyContinue) {
        $context = Get-MgContext -ErrorAction SilentlyContinue
        if ($context) {
            $results.GraphConnected = $true
            $serverAdDevices = Get-MgDevice -Filter "trustType eq 'ServerAd'" -All -ErrorAction Stop
            $results.ServerAdTrustDeviceCount = $serverAdDevices.Count
            Write-Status "Found $($results.ServerAdTrustDeviceCount) Entra device object(s) with TrustType=ServerAd (produced by EITHER classic Hybrid Azure AD Join via Connect Sync OR the new Cloud Sync device sync preview -- this count does not distinguish between the two)." "INFO"
        }
        else {
            Write-Status "Microsoft Graph module present but not connected. Run Connect-MgGraph -Scopes 'Device.Read.All' first to include device counts in this report." "WARN"
        }
    }
    else {
        Write-Status "Microsoft.Graph module not available -- skipping device count. Install-Module Microsoft.Graph.Identity.DirectoryManagement to enable this check." "WARN"
    }
}
catch {
    Write-Status "Error querying Microsoft Graph for devices: $($_.Exception.Message)" "ERROR"
}

# ---- Report ----
$reportObject = [PSCustomObject]$results
$reportObject | Format-List

$csvPath = Join-Path -Path $OutputPath -ChildPath "CloudSyncDeviceSyncReadiness_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$reportObject | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Report exported to $csvPath" "OK"

Write-Status "NOTE: This script cannot read the 'Device sync' Enabled/Disabled toggle state on a Cloud Sync configuration directly -- no supported Graph/PowerShell surface exists for that as of this writing. Verify the toggle in the Microsoft Entra admin center: Entra ID > Entra Connect > Cloud sync > <configuration> > Properties > Basics." "INFO"
