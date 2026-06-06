# Exchange Hybrid Coexistence — Hotfix Runbook (Mode B: Ops)
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

Run these first — identify the failure layer before touching anything:

```powershell
# 1. Test Hybrid Configuration Wizard (HCW) connector status
Get-HybridMailflow

# 2. Check Inbound/Outbound connectors
Get-InboundConnector | Select-Object Name, Enabled, ConnectorType, SenderDomains, TlsSenderCertificateName | Format-Table -AutoSize
Get-OutboundConnector | Select-Object Name, Enabled, ConnectorType, RecipientDomains, SmartHosts | Format-Table -AutoSize

# 3. Test mail flow from on-prem to Exchange Online
Test-MigrationServerAvailability -ExchangeRemoteMove -RemoteServer <HybridMBXServer> -Credentials (Get-Credential)

# 4. Check OAuth between on-prem and EXO
Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com/ews/exchange.asmx -Mailbox <UPN>

# 5. Free/Busy lookup test
Get-AvailabilityAddressSpace | Select-Object ForestName, UserName, AccessMethod, UseServiceAccount | Format-Table -AutoSize
```

**Interpretation Table:**

| Symptom | Likely Cause | Go To |
|---------|-------------|-------|
| No inbound connector from EXO | HCW not run or connector deleted | Fix 1 |
| Outbound connector missing smart host | HCW misconfiguration | Fix 1 |
| OAuth test fails with 401 | OAuth certificate expired/missing | Fix 2 |
| Free/busy returns "No information" | Availability address space broken | Fix 3 |
| MX pointing wrong way | DNS misconfiguration | Fix 4 |
| NDR 550 5.1.x from on-prem to cloud | SMTP namespace mismatch | Fix 5 |

---
## Dependency Cascade

<details><summary>What must be true for hybrid mail flow to work</summary>

```
Internet DNS (MX / SPF / autodiscover CNAME)
    └── Exchange Online accepted domain matches on-prem SMTP namespace
        └── HCW-created Outbound Connector (on-prem → EXO via smarthost)
            └── TLS certificate on Edge/HUB matches TlsSenderCertificateName
                └── EXO Inbound Connector trusts on-prem cert (Partner / OnPremises)
                    └── EXO Outbound Connector routes to on-prem smart host
                        └── On-prem Receive Connector accepts from EXO IP range
                            └── OAuth configured (for Free/Busy, MailTips, cross-prem delegation)
                                └── Autodiscover working in both directions
                                    └── HYBRID COEXISTENCE FUNCTIONAL
```
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Identify the failure direction**
```powershell
# From on-prem Exchange Management Shell:
Send-MailMessage -To <cloud-mailbox@tenant.onmicrosoft.com> -From <on-prem-user@domain.com> -Subject "Hybrid Test" -SmtpServer <HubTransportServer>
```
Expected: Delivery within 2 minutes. If NDR → note error code and skip to matching fix.

**Step 2 — Validate EXO connector configuration**
```powershell
# Connect to Exchange Online PowerShell first
Connect-ExchangeOnline -UserPrincipalName <admin@tenant.onmicrosoft.com>

# Check inbound connector (should show on-prem as trusted sender)
Get-InboundConnector | Where-Object {$_.ConnectorType -eq "OnPremises"} | Format-List Name, Enabled, SenderIPAddresses, TlsSenderCertificateName, RequireTls
```
Expected: `Enabled: True`, correct IP range or cert name for on-prem Edge/Hub.

**Step 3 — Validate on-prem Send Connector**
```powershell
# From on-prem EMS:
Get-SendConnector | Where-Object {$_.AddressSpaces -like "*onmicrosoft.com*"} | Format-List Name, Enabled, SmartHosts, TlsAuthLevel, TlsDomain
```
Expected: SmartHosts = `<tenant>-com.mail.protection.outlook.com`, TlsAuthLevel = `DomainValidation`.

**Step 4 — Check certificate validity**
```powershell
# On the Exchange server hosting the hybrid send connector:
Get-ExchangeCertificate | Select-Object Thumbprint, Subject, NotAfter, Services | Format-Table -AutoSize
```
Expected: Certificate covering your SMTP namespace, `NotAfter` in the future, Services includes `SMTP`.

**Step 5 — Test OAuth (Free/Busy)**
```powershell
# From on-prem EMS:
Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com/ews/exchange.asmx -Mailbox <on-prem-UPN>

# From EXO PowerShell:
Test-OAuthConnectivity -Service EWS -TargetUri https://<on-prem-ews-url>/ews/exchange.asmx -Mailbox <cloud-UPN>
```
Expected: `ResultType: Success` in both directions.

**Step 6 — Check mail routing**
```powershell
# Trace a specific message:
Get-MessageTrackingLog -Server <HubServer> -Sender <sender@domain.com> -Recipients <recipient@tenant.onmicrosoft.com> -Start (Get-Date).AddHours(-2) | Select-Object Timestamp, EventId, Source, MessageSubject, Recipients | Format-Table -AutoSize
```

---
## Common Fix Paths

<details><summary>Fix 1 — Rebuild/repair HCW connectors</summary>

**Use when:** Connectors missing or misconfigured after HCW failure.

```powershell
# Verify what connectors EXO has:
Connect-ExchangeOnline -UserPrincipalName <admin@tenant.onmicrosoft.com>
Get-InboundConnector | Format-List
Get-OutboundConnector | Format-List
```

**Recommended action:** Re-run the Hybrid Configuration Wizard from on-prem Exchange.
- Download from: https://aka.ms/hybridwizard
- Run as Exchange admin with Global Admin credentials for the tenant
- Select "Minimal" or "Full" hybrid — Full is required for OAuth/Free-Busy
- The wizard will recreate connectors without affecting mailboxes

**Rollback:** HCW is non-destructive for connectors — re-running replaces them cleanly.

**Post-fix validation:**
```powershell
# Confirm new connectors exist:
Get-InboundConnector | Where-Object {$_.ConnectorType -eq "OnPremises"} | Select-Object Name, Enabled
Get-OutboundConnector | Where-Object {$_.ConnectorType -eq "OnPremises"} | Select-Object Name, Enabled
```
</details>

<details><summary>Fix 2 — Renew/repair OAuth certificate</summary>

**Use when:** `Test-OAuthConnectivity` fails with 401 Unauthorized or cert errors.

```powershell
# Step 1: Check current OAuth config on-prem
Get-AuthConfig | Format-List

# Step 2: Check certificate referenced by AuthConfig
$authConfig = Get-AuthConfig
Get-ExchangeCertificate -Thumbprint $authConfig.CurrentCertificateThumbprint | Select-Object Subject, NotAfter

# Step 3: If cert expired, create a new one and update AuthConfig
$newCert = New-ExchangeCertificate -KeySize 2048 -SubjectName "CN=Microsoft Exchange Server Auth Certificate" -FriendlyName "Microsoft Exchange Server Auth Certificate" -PrivateKeyExportable $false -Services None
Set-AuthConfig -NewCertificateThumbprint $newCert.Thumbprint -NewCertificateEffectiveDate (Get-Date)
Set-AuthConfig -PublishCertificate

# Step 4: Push updated metadata to Azure AD
# This requires the Microsoft Entra Connect server or manual Azure AD update
# Run from on-prem EMS:
$acl = Get-AuthConfig
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$metadata = Invoke-WebRequest -Uri "https://autodiscover.<yourdomain.com>/autodiscover/metadata/json/1" -UseBasicParsing
```

**Note:** After rotating the auth cert, allow up to 15 minutes for propagation. Re-test OAuth.

**Rollback:** Keep the old cert thumbprint noted — you can revert `Set-AuthConfig -CurrentCertificateThumbprint <oldThumbprint>`.
</details>

<details><summary>Fix 3 — Repair Free/Busy (Availability Address Space)</summary>

**Use when:** Cross-premises Free/Busy returns "No information" or availability errors.

```powershell
# Check on-prem availability config pointing to EXO:
Get-AvailabilityAddressSpace | Format-List

# If missing or wrong, recreate it (on-prem EMS):
Remove-AvailabilityAddressSpace -Identity "outlook.office365.com" -Confirm:$false
Add-AvailabilityAddressSpace -ForestName "outlook.office365.com" -AccessMethod InternalProxy -UseServiceAccount $true -ProxyUrl https://outlook.office365.com/ews/exchange.asmx

# On EXO side — check that on-prem org relationship is set:
Get-OrganizationRelationship | Format-List

# If the on-prem org relationship is missing TargetAutodiscoverEpr:
Set-OrganizationRelationship -Identity "<OnPrem Org>" -TargetAutodiscoverEpr "https://autodiscover.<yourdomain.com>/autodiscover/autodiscover.svc/WSSecurity"
```

**Post-fix validation:**
```powershell
# Test from EXO (requires impersonation rights):
Test-OrganizationRelationship -UserIdentity <cloud-UPN> -Identity "<OnPrem Org>" -Verbose
```
</details>

<details><summary>Fix 4 — Fix MX / mail routing direction</summary>

**Use when:** Mail isn't flowing because MX is pointing to wrong endpoint, or centralized mail transport is misconfigured.

```powershell
# Check if EXO is configured for centralized mail transport (routes through on-prem):
Get-OutboundConnector | Where-Object {$_.RouteAllMessagesViaOnPremises -eq $true} | Select-Object Name, RouteAllMessagesViaOnPremises

# Disable centralized transport if not intended:
Set-OutboundConnector -Identity "<HCW Outbound Connector Name>" -RouteAllMessagesViaOnPremises $false
```

**DNS check (external):** Verify MX record points to `<tenant>.mail.protection.outlook.com` if Exchange Online should receive inbound. MX TTL changes take time — confirm with registrar.

**Rollback:** Re-enable `RouteAllMessagesViaOnPremises` if your org uses centralized transport intentionally.
</details>

<details><summary>Fix 5 — Fix SMTP namespace / NDR 550 5.1.x</summary>

**Use when:** On-prem users get NDR when emailing cloud users, or vice versa.

```powershell
# Check accepted domains in EXO:
Get-AcceptedDomain | Select-Object DomainName, DomainType, Default | Format-Table -AutoSize

# Check accepted domains on-prem:
Get-AcceptedDomain | Select-Object DomainName, DomainType | Format-Table -AutoSize

# Verify email address policies on-prem match EXO proxy addresses:
Get-EmailAddressPolicy | Format-List

# Ensure cloud mailboxes have the on-prem SMTP namespace as a proxy address:
Get-Mailbox -ResultSize Unlimited | Where-Object {$_.EmailAddresses -notlike "*@<yourdomain.com>*"} | Select-Object DisplayName, PrimarySmtpAddress
```

**If proxy address is missing from cloud mailbox:**
```powershell
# Add the on-prem SMTP address to the cloud mailbox:
Set-Mailbox -Identity <cloud-UPN> -EmailAddresses @{Add="smtp:<user@yourdomain.com>"}
```

**Rollback:** Remove the added proxy address if it causes duplicates: `@{Remove="smtp:<address>"}`.
</details>

---
## Escalation Evidence

Copy, fill blanks, paste into ticket:

```
HYBRID COEXISTENCE ESCALATION
==============================
Tenant:              <tenantName>.onmicrosoft.com
On-prem Exchange:    <version> on <serverFQDN>
Hybrid type:         [ ] Minimal  [ ] Full  [ ] Classic  [ ] Modern
Issue reported:      <description>

Failure direction:
  [ ] On-prem → Cloud  [ ] Cloud → On-prem  [ ] Both  [ ] Free/Busy only

Error codes / NDRs:
  <paste exact NDR text>

Test-OAuthConnectivity result (on-prem → EXO):
  <paste output>

Test-OAuthConnectivity result (EXO → on-prem):
  <paste output>

Connector status:
  Inbound connector enabled:  [ ] Yes  [ ] No  [ ] Missing
  Outbound connector enabled: [ ] Yes  [ ] No  [ ] Missing

Auth cert NotAfter:   <date>
TLS cert NotAfter:    <date>

HCW last run:         <date or "unknown">
Recent changes:       <any DNS, cert, or connector changes in last 30 days>
```

---
## 🎓 Learning Pointers

- **HCW is idempotent** — rerunning it is always safe and is the fastest path to a known-good connector state. Bookmark: https://aka.ms/hybridwizard
- **OAuth ≠ TLS** — hybrid uses *two* certificates: a TLS cert for SMTP transport (bound to the send/receive connector) and an auth cert for OAuth (bound to `Get-AuthConfig`). Confusing them is a common escalation mistake.
- **Free/Busy has two code paths** — EWS proxy (used when OAuth is not configured) and OAuth-based (used when `UseOAuthAuthentication` is `$true`). Always check `Get-OrganizationRelationship | Select FreeBusyAccessEnabled, FreeBusyAccessLevel, UseOAuthAuthentication`.
- **Centralized mail transport** routes all EXO outbound through on-prem — useful for compliance but breaks if on-prem goes offline. Check `Get-OutboundConnector | Select RouteAllMessagesViaOnPremises`.
- **MRS Proxy** must be enabled on on-prem CAS for mailbox moves: `Get-WebServicesVirtualDirectory | Select Server, MRSProxyEnabled`.
- MS Docs — Exchange hybrid deployment overview: https://learn.microsoft.com/en-us/exchange/exchange-hybrid
