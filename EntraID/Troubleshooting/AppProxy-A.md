# Entra ID Application Proxy — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**Covers:**
- Entra ID Application Proxy connector health and registration
- Application Proxy app publishing (pre-authentication: Entra ID and Passthrough)
- Single Sign-On (Kerberos Constrained Delegation, header-based, SAML, password-based)
- Connector groups, connector upgrades, and high-availability
- Network path: connector → Microsoft cloud endpoints

**Does not cover:**
- Azure AD Application Proxy classic (deprecated)
- Web Application Proxy (WAP) on-premises — that is a separate product
- ZTNA/Global Secure Access (Entra Private Access) — see its own runbook
- Third-party reverse proxies in front of App Proxy

**Assumed role:** Hybrid Identity Administrator or Global Administrator in Entra ID, and local admin on the connector server.

---

## How It Works

<details><summary>Full architecture</summary>

### Traffic Flow

```
User browser (internet)
       │  HTTPS (443)
       ▼
Microsoft Entra ID (cloud)
  ┌─────────────────────────────┐
  │  App Proxy Service          │
  │  (Front-end relay)          │
  └────────────┬────────────────┘
               │  Outbound TLS (443) — connector poll/tunnel
               ▼
  ┌─────────────────────────────┐
  │  Connector (on-premises)    │  Windows Server, domain-joined or workgroup
  │  - Polls *.msappproxy.net   │
  │  - Holds persistent channel │
  └────────────┬────────────────┘
               │  HTTP/HTTPS (internal)
               ▼
  Internal web application / server
```

### Key Design Points

**The connector makes ALL outbound connections.** No inbound firewall rules needed. The connector continuously polls Microsoft's relay service and the cloud "pushes" request data down the existing tunnel.

**Connector registration** binds the connector to a specific Entra tenant using an OAuth device code flow. The connector machine account in Entra ID is created as an enterprise application.

**Connector Groups** allow you to pin specific apps to specific connectors (e.g., one group per datacenter, one group per app segment). This is the primary HA and traffic-shaping mechanism.

**Pre-authentication modes:**
- **Entra ID (recommended):** User authenticates to Entra ID first; only authenticated sessions reach the connector. MFA and Conditional Access policies apply.
- **Passthrough:** The connector forwards the request directly to the backend. Authentication is entirely handled by the backend app. Conditional Access does NOT apply.

**Single Sign-On options:**
| SSO Type | When to use | Requirement |
|----------|-------------|-------------|
| Kerberos Constrained Delegation (KCD) | IWA-capable internal app | Connector server must be domain-joined; SPN configured on target account |
| Header-based | App uses HTTP headers for identity | PingAccess or native header injection |
| SAML | App supports SAML 2.0 | App must be pre-configured as SAML app |
| Password vault | Legacy basic-auth app | Per-user or shared credential vault |
| None / Passthrough | App has its own auth | — |

</details>

---

## Dependency Stack

```
[User Browser]
      │ HTTPS 443
      ▼
[Entra ID — App Proxy Service]
  relies on: Entra ID tenant health, app registration, CA policies
      │ Outbound TLS 443
      ▼
[Connector Server]
  requires:
    ├── Windows Server 2016+ (2019+ recommended)
    ├── .NET Framework 4.7.2+
    ├── TLS 1.2 enabled
    ├── Outbound to *.msappproxy.net :443
    ├── Outbound to *.servicebus.windows.net :443 (and :5671 fallback)
    ├── Outbound to login.microsoftonline.com :443
    ├── Outbound to graph.microsoft.com :443
    └── (KCD only) Domain membership + SPN delegation config
      │ HTTP/HTTPS internal
      ▼
[Internal Application Server]
  requires:
    ├── Reachable from connector (network path)
    ├── (KCD) Valid Kerberos SPN registered
    └── (KCD) Connector computer account in "Allowed to delegate" list
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Can't access this page" / 404 on external URL | Connector offline or no connectors in group | Entra portal → App Proxy → Connector status |
| 503 Service Unavailable | All connectors in group unreachable | Check connector service on server |
| Sign-in loop / redirect loop | CA policy blocks the app; missing redirect URI | Sign-in logs, app registration redirect URIs |
| "You cannot access this application" | CA block or user not assigned to app | CA What If tool, app assignments |
| Blank page after authentication | Backend app returning error; SSO misconfiguration | Connector event log, backend app logs |
| Kerberos error (KDC_ERR_S_PRINCIPAL_UNKNOWN) | SPN not registered or misspelled | `setspn -L <serviceaccount>` |
| Kerberos error (KRB_AP_ERR_MODIFIED) | SPN registered on wrong account | Check for duplicate SPNs |
| 401 Unauthorized after KCD | Connector not trusted for delegation; wrong delegation protocol | AD → Computer object → Delegation tab |
| Connector shows "Inactive" in portal | Service stopped; network blocked; token expired | `Get-Service WAPCSvc`; check firewall |
| Connector upgrade fails | Installer blocked by AV or GPO | Check MSI installer logs in %TEMP% |
| "AADSTS50011: reply URL mismatch" | Redirect URI in app registration doesn't match external URL | App registration → Authentication → Redirect URIs |
| Long page load times | Connector CPU/RAM constrained; long network RTT to backend | Perf counters on connector; traceroute to backend |

---

## Validation Steps

### 1. Connector Service Status
```powershell
Get-Service -Name 'WAPCSvc' | Select-Object Name, Status, StartType
Get-Service -Name 'WAPCUpdaterSvc' | Select-Object Name, Status, StartType
```
**Good:** Both `Running`, StartType `Automatic`
**Bad:** `Stopped` — connector is offline, app is unreachable

### 2. Connector Version
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft AAD App Proxy Connector" |
    Select-Object Version, InstallDate
```
**Good:** Version within 3 months of current release  
**Bad:** Very old version — may lack security patches and newer features. Download latest from Entra portal.

### 3. Outbound Connectivity Test
```powershell
# Test critical endpoints — run on the connector server
$endpoints = @(
    'proxy.cloudwebappproxy.net',
    'connector.aadrm.com',
    'login.microsoftonline.com',
    'graph.microsoft.com'
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443
    [PSCustomObject]@{
        Endpoint = $ep
        TcpSuccess = $result.TcpTestSucceeded
        PingSuccess = $result.PingSucceeded
    }
}
```
**Good:** `TcpTestSucceeded = True` for all endpoints  
**Bad:** Any `False` — firewall or proxy blocking outbound

### 4. TLS 1.2 Enabled
```powershell
# Check if TLS 1.2 is enabled for .NET
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319" -Name SchUseStrongCrypto -ErrorAction SilentlyContinue
Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319" -Name SchUseStrongCrypto -ErrorAction SilentlyContinue
```
**Good:** `SchUseStrongCrypto = 1`  
**Bad:** Missing or `0` — connector cannot establish TLS 1.2 sessions; set to `1` and restart service

### 5. Connector Event Logs
```powershell
Get-WinEvent -LogName 'Microsoft-AadApplicationProxy-Connector/Admin' -MaxEvents 50 |
    Where-Object LevelDisplayName -in 'Error','Warning' |
    Select-Object TimeCreated, Id, Message |
    Format-List
```
**Good:** No errors in last 24h  
**Bad:** Event IDs 12003 (bootstrap failure), 12008 (token acquisition failed), 12024 (DNS failure)

### 6. KCD — SPN Registration
```powershell
# Run on domain controller or any domain-joined machine with RSAT
# Replace <serviceaccount> with the account running the backend app
setspn -L <serviceaccount>
# Expected: HTTP/<internalFQDN> and HTTP/<shortname>
```
**Good:** SPN `HTTP/<internalFQDN>` present on the correct account  
**Bad:** Missing, on wrong account, or duplicated across accounts

### 7. KCD — Delegation Configuration
```powershell
# Check delegation settings on the connector computer account
Import-Module ActiveDirectory
Get-ADComputer -Identity <ConnectorComputerName> -Properties msDS-AllowedToDelegateTo |
    Select-Object Name, msDS-AllowedToDelegateTo
```
**Good:** `msDS-AllowedToDelegateTo` contains `HTTP/<internalFQDN>`  
**Bad:** Empty — KCD cannot obtain Kerberos tickets for users

---

## Troubleshooting Steps by Phase

### Phase 1: Connector Unreachable

1. Confirm connector service is running (Step 1 above)
2. Check if connector appears in Entra portal → Application Proxy → Connectors
3. If "Inactive": check outbound connectivity (Step 3)
4. If connectivity OK: check proxy settings on connector server
   ```powershell
   netsh winhttp show proxy
   # If behind a proxy, ensure it allows CONNECT to *.msappproxy.net
   ```
5. Check Windows Firewall is not blocking outbound on 443/5671
6. Check for security software blocking `WAPCSvc.exe`
7. Restart services and watch event log:
   ```powershell
   Restart-Service WAPCSvc -Force
   Start-Sleep 10
   Get-WinEvent -LogName 'Microsoft-AadApplicationProxy-Connector/Admin' -MaxEvents 20 |
       Select-Object TimeCreated, Id, Message | Format-List
   ```

### Phase 2: User Cannot Authenticate

1. Check sign-in logs in Entra portal → Sign-in logs — filter by app name
2. Look for CA policy blocks (Conditional Access result: Failure)
3. Check app registration → Authentication → Redirect URIs match external URL exactly
4. Verify user is assigned to the app:
   ```powershell
   # Using Microsoft Graph PowerShell
   Connect-MgGraph -Scopes "Application.Read.All","AppRoleAssignment.ReadWrite.All"
   $app = Get-MgServicePrincipal -Filter "displayName eq '<AppName>'"
   Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $app.Id |
       Select-Object PrincipalDisplayName, PrincipalType
   ```
5. If CA block: use What If tool (Entra portal → CA → What If)
6. If AADSTS50011 (redirect URI mismatch): update app registration to match external URL

### Phase 3: Authenticated but Backend Fails

1. Check Application Proxy app configuration in Entra portal:
   - Internal URL matches actual backend URL and port
   - Pre-authentication type matches intent
   - SSO type matches backend capability
2. Test direct backend connectivity from connector:
   ```powershell
   # Run on connector server
   Invoke-WebRequest -Uri 'http://<internalFQDN>:<port>/healthcheck' -UseDefaultCredentials
   ```
3. For KCD failures:
   - Run `klist purge` on connector server
   - Validate SPN (Step 6) and delegation (Step 7)
   - Check delegation protocol: Use Kerberos Only (not Any) when possible
   - Confirm connector computer account is in the correct OU (some GPOs block delegation)
4. Check connector event log for specific backend error codes

### Phase 4: Performance / Intermittent Issues

1. Check connector CPU and memory:
   ```powershell
   Get-Process -Name 'WAPCSvc' | Select-Object CPU, WorkingSet, Id
   ```
2. Add a second connector to the connector group for HA and load distribution
3. Check network latency: connector → backend (`Test-NetConnection`), connector → cloud (`traceroute`)
4. Review connector group assignment — ensure app is pinned to geographically closest connectors

---

## Remediation Playbooks

<details><summary>Playbook 1 — Register a New Connector</summary>

**Scenario:** Need to add a new connector server or replace a failed one.

**Prerequisites:** Windows Server 2016+, .NET 4.7.2+, local admin on server, Hybrid Identity Administrator role

```powershell
# Step 1: Download connector installer
# Entra portal → App Proxy → Download connector service

# Step 2: Verify prerequisites on new server
$dotnet = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release
if ($dotnet.Release -ge 461808) { Write-Host "OK: .NET 4.7.2+" -ForegroundColor Green }
else { Write-Host "FAIL: Install .NET 4.7.2 first" -ForegroundColor Red }

# Step 3: Enable TLS 1.2 for .NET (critical — do this before installing)
$regPaths = @(
    'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
)
foreach ($path in $regPaths) {
    Set-ItemProperty -Path $path -Name 'SchUseStrongCrypto' -Value 1 -Type DWord -Force
}

# Step 4: Run installer (interactive — requires Hybrid Identity Admin credentials)
# AADApplicationProxyConnectorInstaller.exe

# Step 5: Verify registration
Get-Service WAPCSvc | Select-Object Status
Get-WinEvent -LogName 'Microsoft-AadApplicationProxy-Connector/Admin' -MaxEvents 10 |
    Select-Object TimeCreated, Id, Message
```

**Rollback:** Uninstall via Programs & Features. Remove connector from Entra portal if it still shows.

</details>

<details><summary>Playbook 2 — Configure KCD for a New App</summary>

**Scenario:** Publishing an IWA-capable app (e.g., SharePoint on-prem, internal web app) with SSO via Kerberos.

```powershell
# ── Step 1: Identify the service account running the backend app ──
# Find the account — it should own the SPN for the internal URL

# ── Step 2: Register the SPN on the service account ──
# Run on DC or with RSAT AD tools
# Format: HTTP/<internalFQDN> and HTTP/<internalShortName>
setspn -S HTTP/<internalFQDN> <DOMAIN>\<serviceaccount>
setspn -S HTTP/<internalShortName> <DOMAIN>\<serviceaccount>

# Verify:
setspn -L <DOMAIN>\<serviceaccount>

# ── Step 3: Configure delegation on the Connector computer account ──
Import-Module ActiveDirectory

# Get the connector computer account
$connector = Get-ADComputer -Identity <ConnectorComputerName>

# Set constrained delegation — Kerberos only is preferred
Set-ADComputer -Identity $connector -Add @{
    'msDS-AllowedToDelegateTo' = @("HTTP/<internalFQDN>", "HTTP/<internalShortName>")
}

# Set delegation type to "Use Kerberos only" (value 0x1000000 = 16777216)
Set-ADAccountControl -Identity $connector -TrustedToAuthForDelegation $false
Set-ADComputer -Identity $connector -KerberosEncryptionType AES128,AES256

# ── Step 4: Force Group Policy update and flush Kerberos tickets ──
gpupdate /force
klist purge

# ── Step 5: Configure App in Entra portal ──
# App Proxy app → Single sign-on → Windows Integrated Authentication
# Internal Application SPN: HTTP/<internalFQDN>
# Delegated Login Identity: User Principal Name (or SAM-account-name for legacy apps)

# ── Step 6: Test ──
# Browse to external URL → should SSO without prompt
```

**Rollback:**
```powershell
# Remove SPN if rollback needed
setspn -D HTTP/<internalFQDN> <DOMAIN>\<serviceaccount>
# Clear delegation on connector
Set-ADComputer -Identity <ConnectorComputerName> -Clear 'msDS-AllowedToDelegateTo'
```

</details>

<details><summary>Playbook 3 — Move Connector to a Different Connector Group</summary>

**Scenario:** App is routing through wrong connectors; need to reassign.

```powershell
# This is primarily done in the portal, but can be scripted via Graph API

Connect-MgGraph -Scopes "Application.ReadWrite.All"

# List connector groups
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/onPremisesPublishingProfiles/applicationProxy/connectorGroups" |
    Select-Object -ExpandProperty value |
    Select-Object id, name

# List connectors in a group
$groupId = "<connectorGroupId>"
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/onPremisesPublishingProfiles/applicationProxy/connectorGroups/$groupId/members" |
    Select-Object -ExpandProperty value |
    Select-Object id, machineName, status

# Move connector to different group
$connectorId = "<connectorId>"
$targetGroupId = "<targetGroupId>"
Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/onPremisesPublishingProfiles/applicationProxy/connectors/$connectorId/memberOf/`$ref" `
    -Body (@{ "@odata.id" = "https://graph.microsoft.com/v1.0/onPremisesPublishingProfiles/applicationProxy/connectorGroups/$targetGroupId" } | ConvertTo-Json) `
    -ContentType "application/json"
```

</details>

<details><summary>Playbook 4 — Force Connector Upgrade</summary>

**Scenario:** Connector is running a very old version and auto-update has failed.

```powershell
# Check current version
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft AAD App Proxy Connector" | Select-Object Version

# Check updater service
Get-Service WAPCUpdaterSvc | Select-Object Status, StartType

# If updater is stopped:
Start-Service WAPCUpdaterSvc
Start-Sleep 30
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft AAD App Proxy Connector" | Select-Object Version

# If updater fails (check event log for errors):
Get-WinEvent -LogName 'Microsoft-AadApplicationProxy-ConnectorUpdater/Admin' -MaxEvents 20 |
    Select-Object TimeCreated, Id, Message | Format-List

# Manual upgrade: download latest installer from Entra portal
# Run with /quiet /norestart
# AADApplicationProxyConnectorInstaller.exe /quiet /norestart
```

**Note:** Manual upgrade preserves connector registration — no re-registration needed.

</details>

---

## Evidence Pack

Run this on the connector server to collect all diagnostic data for an escalation ticket:

```powershell
<#
.SYNOPSIS  Collects App Proxy connector diagnostics for escalation
.NOTES     Run as local administrator on the connector server
           Output saved to C:\AppProxyDiag_<hostname>_<date>.txt
#>

$outFile = "C:\AppProxyDiag_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"

function Write-Section {
    param([string]$Title)
    "`n" + ("="*60) + "`n$Title`n" + ("="*60) | Tee-Object -FilePath $outFile -Append | Write-Host -ForegroundColor Cyan
}

"App Proxy Connector Diagnostics — $($env:COMPUTERNAME) — $(Get-Date)" |
    Tee-Object -FilePath $outFile | Write-Host

Write-Section "CONNECTOR SERVICES"
Get-Service -Name 'WAPCSvc','WAPCUpdaterSvc' | Select-Object Name, Status, StartType |
    Tee-Object -FilePath $outFile -Append | Format-Table

Write-Section "CONNECTOR VERSION"
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft AAD App Proxy Connector" |
    Select-Object Version, InstallDate |
    Tee-Object -FilePath $outFile -Append | Format-List

Write-Section "OUTBOUND CONNECTIVITY"
$endpoints = @(
    @{Host='proxy.cloudwebappproxy.net'; Port=443},
    @{Host='connector.aadrm.com'; Port=443},
    @{Host='login.microsoftonline.com'; Port=443},
    @{Host='graph.microsoft.com'; Port=443},
    @{Host='*.servicebus.windows.net'; Port=5671}
)
foreach ($ep in $endpoints) {
    if ($ep.Host -notlike '*.*') { continue }
    $r = Test-NetConnection -ComputerName $ep.Host -Port $ep.Port -WarningAction SilentlyContinue
    [PSCustomObject]@{ Endpoint="$($ep.Host):$($ep.Port)"; TCP=$r.TcpTestSucceeded } |
        Tee-Object -FilePath $outFile -Append | Format-Table
}

Write-Section "TLS 1.2 REGISTRY"
$tlsPaths = @(
    'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319',
    'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'
)
foreach ($p in $tlsPaths) {
    if (Test-Path $p) {
        Get-ItemProperty $p | Select-Object PSPath, SchUseStrongCrypto, Enabled, DisabledByDefault |
            Tee-Object -FilePath $outFile -Append | Format-List
    }
}

Write-Section "PROXY SETTINGS"
netsh winhttp show proxy | Tee-Object -FilePath $outFile -Append

Write-Section "CONNECTOR EVENT LOG (Last 50 errors/warnings)"
Get-WinEvent -LogName 'Microsoft-AadApplicationProxy-Connector/Admin' -MaxEvents 100 -ErrorAction SilentlyContinue |
    Where-Object LevelDisplayName -in 'Error','Warning' |
    Select-Object TimeCreated, Id, Message |
    Tee-Object -FilePath $outFile -Append | Format-List

Write-Section "UPDATER EVENT LOG (Last 20)"
Get-WinEvent -LogName 'Microsoft-AadApplicationProxy-ConnectorUpdater/Admin' -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Tee-Object -FilePath $outFile -Append | Format-List

Write-Section "OS & DOTNET"
[PSCustomObject]@{
    OS = (Get-CimInstance Win32_OperatingSystem).Caption
    Build = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuild
    DotNetRelease = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release).Release
} | Tee-Object -FilePath $outFile -Append | Format-List

Write-Host "`nDiagnostic file saved to: $outFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check connector service | `Get-Service WAPCSvc` |
| Restart connector | `Restart-Service WAPCSvc -Force` |
| View connector event log errors | `Get-WinEvent -LogName 'Microsoft-AadApplicationProxy-Connector/Admin' -MaxEvents 50 \| Where LevelDisplayName -in 'Error','Warning'` |
| Test outbound to App Proxy | `Test-NetConnection proxy.cloudwebappproxy.net -Port 443` |
| Check proxy settings | `netsh winhttp show proxy` |
| Get connector version | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft AAD App Proxy Connector" \| Select Version` |
| List SPNs on account | `setspn -L <DOMAIN>\<account>` |
| Register SPN | `setspn -S HTTP/<fqdn> <DOMAIN>\<account>` |
| Check delegation on computer | `Get-ADComputer <name> -Properties msDS-AllowedToDelegateTo` |
| Flush Kerberos tickets | `klist purge` |
| Force Group Policy update | `gpupdate /force` |
| Check .NET TLS setting | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319" \| Select SchUseStrongCrypto` |
| Enable TLS 1.2 for .NET | `Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name SchUseStrongCrypto -Value 1` |
| Start updater service | `Start-Service WAPCUpdaterSvc` |

---

## 🎓 Learning Pointers

- **App Proxy is connector-pull, not cloud-push.** The connector polls outbound — this is why you need no inbound firewall rules. Understanding this architecture eliminates most "why can't users connect?" confusion. If the connector can't reach *.msappproxy.net on 443, nothing works.  
  → [MS Docs: Understand App Proxy connectors](https://learn.microsoft.com/en-us/entra/identity/app-proxy/application-proxy-connectors)

- **KCD requires the connector, not the user, to get Kerberos tickets.** The connector server's computer account must be trusted for delegation in AD, and it requests a service ticket on behalf of the user. The user never presents a Kerberos ticket to the backend. If the connector is not domain-joined, KCD is not possible.  
  → [MS Docs: KCD for App Proxy SSO](https://learn.microsoft.com/en-us/entra/identity/app-proxy/application-proxy-configure-single-sign-on-with-kcd)

- **Conditional Access applies only in Entra pre-authentication mode.** If the app is set to Passthrough, CA policies are completely bypassed. This is a security gap to be aware of and document. Switch to Entra pre-authentication for all apps that should enforce MFA or device compliance.  
  → [MS Docs: Pre-authentication](https://learn.microsoft.com/en-us/entra/identity/app-proxy/application-proxy-configure-single-sign-on-with-headers)

- **Connector groups are the right tool for datacenter segmentation.** Don't run one global connector group — create per-datacenter or per-region groups and pin apps to the appropriate group. This reduces latency, provides blast-radius isolation, and makes HA reasoning explicit.  
  → [MS Docs: Connector groups](https://learn.microsoft.com/en-us/entra/identity/app-proxy/application-proxy-connector-groups)

- **TLS 1.2 registry keys are not set by default on older Windows Server versions.** Connector registration and ongoing communication both require TLS 1.2. The two .NETFramework registry paths for `SchUseStrongCrypto` are frequently the silent cause of "connector won't register" failures on Windows Server 2016 endpoints that haven't been fully hardened.  
  → [MS Docs: Prerequisites](https://learn.microsoft.com/en-us/entra/identity/app-proxy/application-proxy-add-on-premises-application)

- **Monitor the updater service, not just the connector service.** Auto-update failures accumulate silently. A connector running a 2-year-old version may miss security fixes and break when Microsoft deprecates older authentication flows. Check `WAPCUpdaterSvc` and the updater event log monthly.  
  → [MS Tech Community: App Proxy connector updates](https://techcommunity.microsoft.com/t5/microsoft-entra-blog/bg-p/Identity)
