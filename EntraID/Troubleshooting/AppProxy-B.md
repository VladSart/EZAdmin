# Azure AD Application Proxy — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run these in order. Each takes under 60 seconds.

```powershell
# 1. Check connector service status on the connector server
Get-Service -Name "ApplicationProxyConnectorService" | Select-Object Name, Status, StartType

# 2. Check connector registration status
Get-EventLog -LogName "Application" -Source "Microsoft AAD Application Proxy Connector" -Newest 20 |
    Select-Object TimeGenerated, EntryType, Message | Format-Table -Wrap

# 3. Test outbound connectivity to required endpoints
$endpoints = @(
    "login.microsoftonline.com",
    "proxy.cloudwebappproxy.net",
    "servicebus.windows.net"
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{
        Endpoint = $ep
        TCPSuccess = $result.TcpTestSucceeded
        RemoteAddress = $result.RemoteAddress
    }
} | Format-Table

# 4. Check connector group assignment in Entra admin portal (output tenant/app info)
# Requires AzureAD or Microsoft.Graph module
Connect-MgGraph -Scopes "Application.Read.All"
Get-MgServicePrincipal -Filter "tags/Any(t: t eq 'WindowsAzureActiveDirectoryOnPremApp')" |
    Select-Object DisplayName, Id | Format-Table

# 5. Check TLS and system clock skew (clock drift causes auth failures)
$drift = ([datetime]::UtcNow - (w32tm /query /status | Select-String "Last Successful" | ForEach-Object { [datetime]($_ -replace ".*:\s*","") })).TotalSeconds
Write-Host "Clock drift (seconds): $drift" -ForegroundColor $(if ([Math]::Abs($drift) -gt 300) {"Red"} else {"Green"})
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| Service stopped / disabled | Connector not running | → Fix 1 |
| Event 12003 / 12004 | Connector registration expired | → Fix 2 |
| Any TCP test = False | Outbound firewall blocking proxy endpoints | → Fix 3 |
| No connector in portal | Connector not registered to this tenant | → Fix 2 |
| Drift > 300 seconds | Clock skew will cause Kerberos/token failures | → Fix 4 |

---
## Dependency Cascade

<details><summary>What must be true for App Proxy to work</summary>

```
Microsoft Entra ID (Cloud)
    └── App Proxy Service
          └── Connector Group (contains ≥1 active connector)
                └── Connector Server (on-prem / IaaS VM)
                      ├── ApplicationProxyConnectorService (running)
                      ├── ApplicationProxyConnectorUpdaterService (running)
                      ├── Outbound HTTPS :443 to *.msappproxy.net, *.servicebus.windows.net
                      ├── No TLS inspection on proxy endpoints (breaks connector bootstrap)
                      ├── System clock within 5 minutes of UTC
                      └── Backend App Server
                            ├── Reachable from connector (DNS + firewall)
                            ├── If Kerberos (KCD): SPN registered, connector account delegated
                            └── If Header-based/SAML: IIS/app config correct
```

Key failure points:
- Connector service stopped or in crash loop (event 12003, 12004, 12008)
- TLS inspection stripping connector bootstrap certificate
- Connector registered to wrong tenant
- Backend server unreachable from connector host
- KCD misconfiguration (wrong SPN, wrong delegation type)

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the connector is registered and active**
```powershell
# In Entra admin center: Identity > Applications > Enterprise applications > Application proxy
# Or via Graph:
Connect-MgGraph -Scopes "OnPremisesPublishingProfiles.Read.All"
(Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/onPremisesPublishingProfiles/applicationProxy/connectors" -Method GET).value |
    Select-Object name, status, machineName | Format-Table
```
Expected: Status = `active`. If `inactive` → connector not checking in.

**2. Check connector event logs**
```powershell
Get-WinEvent -LogName "Microsoft-AadApplicationProxy-Connector/Admin" -MaxEvents 50 |
    Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
    Select-Object TimeCreated, Id, Message | Format-Table -Wrap
```
Key event IDs:
- **1000** — Connector started OK
- **12003** — Connector cannot connect to proxy service
- **12004** — Authentication failure (check registration)
- **12008** — Kerberos delegation failure

**3. Test backend reachability from connector server**
```powershell
# Replace <BACKEND-HOST> and <PORT> with actual values
Test-NetConnection -ComputerName "<BACKEND-HOST>" -Port <PORT>
Resolve-DnsName "<BACKEND-HOST>"
```
Expected: TcpTestSucceeded = True, DNS resolves to internal IP.

**4. If KCD is in use — validate SPN and delegation**
```powershell
# Check SPN exists for backend service
setspn -L <service-account-or-computer>

# Check connector computer account has delegation configured
Get-ADComputer -Identity "<CONNECTOR-HOSTNAME>" -Properties msDS-AllowedToDelegateTo |
    Select-Object Name, msDS-AllowedToDelegateTo
```
Expected: SPN present (e.g. `HTTP/<backendFQDN>`), delegation list includes backend SPN.

**5. Test end-to-end — access the external URL**
Open `https://<external-url>.msappproxy.net` in a browser as a test user. Check:
- Entra sign-in page appears → app proxy routing works, issue is auth or backend
- 502/503 → backend unreachable from connector
- Blank page / certificate error → TLS inspection issue

---
## Common Fix Paths

<details><summary>Fix 1 — Restart connector services</summary>

```powershell
# Restart both connector services
Restart-Service -Name "ApplicationProxyConnectorService" -Force
Restart-Service -Name "ApplicationProxyConnectorUpdaterService" -Force

# Confirm running
Get-Service -Name "ApplicationProxyConnector*" | Select-Object Name, Status
```

If service fails to start, check:
```powershell
Get-WinEvent -LogName "System" -MaxEvents 50 |
    Where-Object { $_.Message -match "ApplicationProxy" }
```

**Rollback:** N/A — restarting services is non-destructive. If service won't start, see Fix 2 (re-register).

</details>

<details><summary>Fix 2 — Re-register the connector</summary>

Use when: connector shows inactive in portal, event 12004, or certificate expired.

```powershell
# On the connector server — run as the connector service account or local admin
# Download latest connector installer from Entra portal, or use existing binary:
$connectorPath = "C:\Program Files\Microsoft AAD App Proxy Connector\ApplicationProxyConnectorInstaller.exe"

# Re-register (will prompt for Entra Global Admin / Application Administrator credentials)
& $connectorPath /q /norestart REGISTERCONNECTOR="true" TENANTID="<TENANT-ID>"
```

Alternatively: uninstall and reinstall from Entra admin center > Application proxy > Download connector service.

**Rollback:** If re-registration fails with a new connector, old registration persists until manually deleted in portal.

</details>

<details><summary>Fix 3 — Fix outbound firewall / proxy blocking</summary>

Required outbound endpoints (all :443, no TLS inspection):
```
login.microsoftonline.com
*.msappproxy.net
*.servicebus.windows.net
management.azure.com
```

```powershell
# Test each endpoint
$required = @(
    "login.microsoftonline.com",
    "proxy.cloudwebappproxy.net",
    "servicebus.windows.net",
    "management.azure.com"
)
$required | ForEach-Object {
    $r = Test-NetConnection -ComputerName $_ -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ Host = $_; Port443 = $r.TcpTestSucceeded }
} | Format-Table
```

If corporate proxy is intercepting HTTPS: configure connector service to bypass TLS inspection for `*.msappproxy.net` and `*.servicebus.windows.net`.

Set system proxy if needed:
```powershell
netsh winhttp set proxy <PROXY-HOST>:<PORT> bypass-list="*.msappproxy.net;*.servicebus.windows.net"
```

**Rollback:**
```powershell
netsh winhttp reset proxy
```

</details>

<details><summary>Fix 4 — Fix clock skew causing auth failures</summary>

```powershell
# Force NTP sync
w32tm /resync /force
w32tm /query /status

# If not syncing to domain controller:
w32tm /config /manualpeerlist:"<DC-FQDN>" /syncfromflags:manual /reliable:YES /update
net stop w32tm && net start w32tm
w32tm /resync /force
```

Expected: `Last Successful Sync Time` within last 5 minutes, offset < 5 seconds.

</details>

<details><summary>Fix 5 — Fix KCD (Kerberos Constrained Delegation) for SSO</summary>

```powershell
# Step 1 — Register SPN for backend service (run on DC as Domain Admin)
setspn -S HTTP/<backend-FQDN> <service-account-or-machine>
setspn -S HTTP/<backend-shortname> <service-account-or-machine>

# Step 2 — Configure delegation on connector computer account
$connectorPC = Get-ADComputer -Identity "<CONNECTOR-HOSTNAME>"
Set-ADComputer -Identity $connectorPC -Add @{
    'msDS-AllowedToDelegateTo' = 'HTTP/<backend-FQDN>'
}

# Step 3 — Set delegation type to "Use any authentication protocol" (Protocol Transition)
Set-ADAccountControl -Identity $connectorPC -TrustedToAuthForDelegation $true

# Verify
Get-ADComputer -Identity "<CONNECTOR-HOSTNAME>" -Properties TrustedToAuthForDelegation, msDS-AllowedToDelegateTo |
    Select-Object Name, TrustedToAuthForDelegation, msDS-AllowedToDelegateTo
```

**Rollback:**
```powershell
Set-ADComputer -Identity "<CONNECTOR-HOSTNAME>" -Clear msDS-AllowedToDelegateTo
Set-ADAccountControl -Identity "<CONNECTOR-HOSTNAME>" -TrustedToAuthForDelegation $false
```

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Azure AD Application Proxy
===============================================
Date/Time (UTC)     : [                    ]
Reported by         : [                    ]
Affected app URL    : [https://             ]
External URL        : [https://            .msappproxy.net]
Connector server(s) : [                    ]
Connector group     : [                    ]
Tenant ID           : [                    ]

Symptoms
--------
[ ] App unreachable externally (502/503)
[ ] Sign-in loop / auth failure
[ ] KCD/SSO not working
[ ] Connector shows Inactive in portal
[ ] Other: [                            ]

Triage results
--------------
Connector service status    : [Running / Stopped]
Last event log error        : [Event ID: ___ Message: ___]
Outbound connectivity       : [All pass / Blocked: ___]
Clock drift (seconds)       : [        ]
Backend reachable from connector : [Yes / No]
SPN status (if KCD)         : [Present / Missing / Wrong]

Evidence collected
------------------
[ ] Connector Admin event log export (last 24h)
[ ] Test-NetConnection output for all endpoints
[ ] setspd -L output (if KCD issue)
[ ] Get-ADComputer delegation output (if KCD issue)
[ ] Screenshot of connector status in Entra portal

Escalation path: Entra ID > App Proxy > raise support ticket with above evidence pack.
```

---
## 🎓 Learning Pointers

- **Connector bootstrap uses mutual TLS** — the connector authenticates to Microsoft's proxy service using a client certificate issued at registration. TLS inspection that strips this certificate breaks registration entirely. Bypass `*.msappproxy.net` at your proxy/firewall. [MS Docs: Understand Azure AD App Proxy connectors](https://learn.microsoft.com/en-us/entra/identity/app-proxy/application-proxy-connectors)
- **Connector groups let you segment by location or app type** — put connectors near the backend apps they serve. Cross-site connector → backend latency shows up as slow app load. [MS Docs: Connector groups](https://learn.microsoft.com/en-us/entra/identity/app-proxy/application-proxy-connector-groups)
- **KCD requires Protocol Transition when Entra does pre-auth** — because Entra obtains a token (not a Kerberos ticket) for the user, the connector must use S4U2Self to get a service ticket on their behalf. This requires `TrustedToAuthForDelegation = True` on the connector account. [MS Docs: KCD for App Proxy SSO](https://learn.microsoft.com/en-us/entra/identity/app-proxy/application-proxy-configure-single-sign-on-with-kcd)
- **Event ID 12003 vs 12004** — 12003 = network connectivity failure (firewall/proxy), 12004 = authentication/registration failure (certificate expired or re-registration needed). Different root cause, different fix. Check event details carefully.
- **Connector auto-updates require the Updater service** — `ApplicationProxyConnectorUpdaterService` handles automatic upgrades. If it's stopped, connectors won't update and will eventually fall out of support. Keep both services running.
- **Use App Proxy health dashboard in Entra portal** — Identity > Applications > Enterprise applications > Application proxy shows real-time connector health, version, and last active timestamp. Check here first before diving into event logs.
