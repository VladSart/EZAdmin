# This Script needs to be run in Admin PowerShell.

# Check if running as administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator. Please restart PowerShell as an Administrator and try again."
    exit
}

# Ensure required modules are available
$requiredModules = @("DnsClient")
foreach ($module in $requiredModules) {
    if (!(Get-Module -ListAvailable -Name $module)) {
        Install-Module -Name $module -Force -Scope CurrentUser
    }
    Import-Module $module
}

# Function to check HTTP/HTTPS and DNS resolution
function Test-Url {
    param (
        [string]$Url
    )
    
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 10
        if ($response.StatusCode -eq 200) {
            return @{Status = "Success"; Message = "$Url is reachable."}
        } else {
            return @{Status = "Warning"; Message = "Warning: $Url returned status code $($response.StatusCode)."}
        }
    } catch {
        return @{Status = "Error"; Message = "Error: $Url is not reachable. $($_.Exception.Message)"}
    }
}

# Test DNS resolution for base domains (no wildcards)
function Test-Dns {
    param (
        [string]$domain
    )
    
    try {
        $dns = Resolve-DnsName -Name $domain -ErrorAction Stop
        return @{Status = "Success"; Message = "$domain resolved successfully."}
    } catch {
        return @{Status = "Error"; Message = "Error: $domain DNS resolution failed. $($_.Exception.Message)"}
    }
}

# Test NTP (UDP 123) for time.windows.com
function Test-NTP {
    try {
        $result = Test-NetConnection -ComputerName time.windows.com -Port 123 -InformationLevel Quiet
        if ($result) {
            return @{Status = "Success"; Message = "NTP to time.windows.com on port 123 is reachable."}
        } else {
            return @{Status = "Error"; Message = "Error: NTP to time.windows.com on port 123 is unreachable."}
        }
    } catch {
        return @{Status = "Error"; Message = "Error: NTP to time.windows.com failed. $($_.Exception.Message)"}
    }
}

# List of URLs for Autopilot Networking and Activation Requirements
$urls = @(
    "https://ekop.intel.com/ekcertservice",
    "https://ekcert.spserv.microsoft.com/EKCertificate/GetEKCertificate/v1",
    "https://ftpm.amd.com/pki/aia",
    "https://ztd.dds.microsoft.com",
    "https://cs.dds.microsoft.com",
    "https://login.live.com",
    "https://lgmsapeweu.blob.core.windows.net",
    "https://go.microsoft.com/",
    "http://go.microsoft.com/",
    "https://activation.sls.microsoft.com/",
    "http://crl.microsoft.com/pki/crl/products/MicProSecSerCA_2007-12-04.crl",
    "https://validation.sls.microsoft.com/",
    "https://activation-v2.sls.microsoft.com/",
    "https://displaycatalog.mp.microsoft.com/",
    "https://licensing.mp.microsoft.com/",
    "https://purchase.mp.microsoft.com/",
    "https://displaycatalog.md.mp.microsoft.com/",
    "https://licensing.md.mp.microsoft.com/",
    "https://purchase.md.mp.microsoft.com/",
    "https://login.microsoftonline.com",
    "https://graph.windows.net",
    "https://www.microsoft.com/store",
    "https://onedrive.live.com",
    "https://www.office.com"
)

# List of base domains for DNS resolution (no wildcards)
$dnsDomains = @(
    "microsoftaik.azure.net",
    "msftconnecttest.com",
    "manage.microsoft.com"
)

# Initialize results array
$results = @()

# Test each URL for HTTP/HTTPS reachability
foreach ($url in $urls) {
    $result = Test-Url $url
    $results += [PSCustomObject]@{
        Type = "URL"
        Target = $url
        Status = $result.Status
        Message = $result.Message
    }
}

# Test DNS resolution for base domains
foreach ($domain in $dnsDomains) {
    $result = Test-Dns $domain
    $results += [PSCustomObject]@{
        Type = "DNS"
        Target = $domain
        Status = $result.Status
        Message = $result.Message
    }
}

# Test NTP reachability
$ntpResult = Test-NTP
$results += [PSCustomObject]@{
    Type = "NTP"
    Target = "time.windows.com"
    Status = $ntpResult.Status
    Message = $ntpResult.Message
}

# Generate summary report
$summaryReport = $results | ForEach-Object {
    [PSCustomObject]@{
        Type = $_.Type
        Target = $_.Target
        Status = $_.Status
        Message = $_.Message
    }
}

# Save results to a file
$reportPath = "$env:TEMP\AutopilotConnectivityReport.csv"
$summaryReport | Export-Csv -Path $reportPath -NoTypeInformation

Write-Host "`nSummary Report:"
$summaryReport | Format-Table -AutoSize

Write-Host "`nDetailed report saved to: $reportPath"

# Return the report path for Intune to collect
$reportPath
