# This Script needs to be run in Admin Powershell.
# Function to check HTTP/HTTPS and DNS resolution
function Test-Url {
    param (
        [string]$Url
    )
    
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 5
        if ($response.StatusCode -eq 200) {
            Write-Output "$Url is reachable."
        } else {
            Write-Output "Error: $Url returned status code $($response.StatusCode)."
        }
    } catch {
        Write-Output "Error: $Url is not reachable."
    }
}

# Test DNS resolution for base domains (no wildcards)
function Test-Dns {
    param (
        [string]$domain
    )
    
    try {
        $dns = Resolve-DnsName -Name $domain
        Write-Output "$domain resolved successfully."
    } catch {
        Write-Output "Error: $domain DNS resolution failed."
    }
}

# Test NTP (UDP 123) for time.windows.com
function Test-NTP {
    try {
        Test-NetConnection -ComputerName time.windows.com -Port 123 -InformationLevel Quiet
        if ($?) {
            Write-Output "NTP to time.windows.com on port 123 is reachable."
        } else {
            Write-Output "Error: NTP to time.windows.com on port 123 is unreachable."
        }
    } catch {
        Write-Output "Error: NTP to time.windows.com failed."
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
    "https://purchase.md.mp.microsoft.com/"
)

# List of base domains for DNS resolution (no wildcards)
$dnsDomains = @(
    "microsoftaik.azure.net",
    "msftconnecttest.com",
    "manage.microsoft.com"
)

# Test each URL for HTTP/HTTPS reachability
foreach ($url in $urls) {
    Test-Url $url
}

# Test DNS resolution for base domains
foreach ($domain in $dnsDomains) {
    Test-Dns $domain
}

# Test NTP reachability
Test-NTP
