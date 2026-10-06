# Exchange Hybrid Dedicated App & Graph Rich Coexistence — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

**Scope:** Exchange Server ↔ Exchange Online **rich coexistence** (Free/Busy, MailTips, profile photos, cloud archive for on-prem mailboxes) after three Microsoft changes: the shared first-party service principal was **blocked for EWS on 31 Oct 2025**, the **May 2026 SE Hotfix Update** added a Graph API path, and Exchange Online **EWS enforcement started Oct 2026** (`EwsAllowedAppIDs` required from 10 Oct 2026 for Worldwide tenants, permanent shutdown 1 Apr 2027). Mail flow, mailbox moves and HMA are **not** affected by the dedicated app (see `Hybrid-Coexistence-B.md`). Tenant-side EWS gate: `EWSRetirement-B.md`. Deep dive: `HybridDedicatedApp-A.md`. Script: `Scripts/Get-ExchangeHybridAppReadiness.ps1`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

Typical tickets: *"on-prem users can't see cloud users' free/busy (hatched/no info)"*, *"MailTips/OOF of cloud users missing in on-prem Outlook"*, *"profile photos gone across premises"*, *"free/busy broke on 10 October"*, *"on-prem mailbox can't use its cloud archive"*.

Run in an **elevated Exchange Management Shell** on a Mailbox server:

```powershell
# 1. Server builds - the HU revision matters, so read ExSetup, not AdminDisplayVersion
(Get-Command ExSetup.exe).FileVersionInfo.ProductVersion          # this server
Get-ExchangeServer | Where-Object IsMailboxServer | Format-Table Name, AdminDisplayVersion

# 2. Is the dedicated app feature on? Is the Graph flow on?
Get-SettingOverride | Where-Object { $_.SectionName -in 'ExchangeOnpremAsThirdPartyAppId','RouteThroughMSGraph' } |
    Format-List Name, ComponentName, SectionName, Parameters, Server

# 3. Auth Server points at the dedicated app?
Get-AuthServer | Where-Object Name -like '*evoSTS*' | Format-List Name, Realm, Enabled, ApplicationIdentifier, DomainName, GraphBaseUrl

# 4. Can this server get a token as the dedicated app?
$r = Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com -Mailbox <onprem-mailbox@contoso.com>
$r.ResultType; if ($r.Detail.FullId -match 'L:(?<g>[0-9a-fA-F-]{36})-AS:') { "appId used: $($Matches.g)" }
```

Then, in a **separate** PowerShell session (EXO module cmdlet names collide with EMS):

```powershell
Connect-ExchangeOnline -ShowBanner:$false
Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy | Format-List EwsEnabled, EwsAllowedAppIDs
```

| Result | Meaning | Action |
|---|---|---|
| Any Mailbox server below the builds in the Dependency Cascade | That server can't use the dedicated app at all — its rich-coexistence calls fail since 31 Oct 2025 | → Fix 1 |
| No `ExchangeOnpremAsThirdPartyAppId` override | Dedicated app (if it exists) is not in use — typical after HCW created the app | → Fix 2 |
| Override present, `ApplicationIdentifier` empty or not the `ExchangeServerApp-*` appId | Auth Server not configured | → Fix 2 (run the script's configure step) |
| Test-OAuthConnectivity `Success`, appId = dedicated app, no `RouteThroughMSGraph` override, and EXO `EwsAllowedAppIDs` populated **without** that appId | Hybrid is on the **EWS** flow and the tenant EWS gate is blocking it | → Fix 3 (fast) or Fix 4 (durable) |
| `RouteThroughMSGraph` override present, Free/Busy still fails | Graph permissions/consent missing, server can't reach `graph.microsoft.com`, or tenant isn't in Global cloud | → Fix 4 checks / Fix 7 |
| Free/Busy works, only **cloud archive** for on-prem mailboxes broken | `full_access_as_app` (EWS) was removed — archive has no Graph path yet | → Fix 6 |
| Test-OAuthConnectivity fails with certificate/key errors | Auth Certificate renewed but not uploaded to the dedicated app | → Fix 5 |
| Servers on Exchange 2016/2019 | No Graph flow will ever ship for them; EWS flow dies 1 Apr 2027 | → Fix 1 (SE upgrade or finish migration) |

---
## Dependency Cascade

<details><summary>What must be true for on-prem ↔ cloud Free/Busy, MailTips, photos to work (Oct 2026 – Mar 2027)</summary>

```
[Classic Full or Modern Full hybrid configured via HCW, OAuth (not DAuth)]
  └─ Every Mailbox server on a supported build
  │     Dedicated app (EWS flow):  SE RTM 15.2.2562.17 | 2019 CU15 HU 15.2.1748.24
  │                                2019 CU14 HU 15.2.1544.25 | 2016 CU23 HU 15.1.2507.55
  │     Graph flow:                SE RTM + May 2026 HU 15.2.2562.41 or later ONLY
  └─ Entra: app ExchangeServerApp-<ExchangeOrgGuid> exists (one per on-prem org, per tenant)
  │     ├─ keyCredentials = current (and next) Auth Certificate public key
  │     ├─ EWS flow:   Office 365 Exchange Online / full_access_as_app (application) + admin consent
  │     └─ Graph flow: MailboxSettings.Read, MailTips.ReadBasic.All, Calendars.Read,
  │                    ProfilePhoto.Read.All (application) + admin consent
  └─ On-prem: Get-AuthServer evoSTS* → ApplicationIdentifier = appId, DomainName incl. <org>.mail.onmicrosoft.com
  └─ On-prem: SettingOverride  Global / ExchangeOnpremAsThirdPartyAppId  Enabled=true
  │     └─ (Graph) SettingOverride  SettingOverride / RouteThroughMSGraph  Enabled=true
  │           └─ Outbound 443 to login.microsoftonline.com + graph.microsoft.com; tenant in Global cloud
  └─ OrganizationRelationship → TargetSharingEpr = EXO EWS endpoint (script sets via Autodiscover)
  └─ EXO tenant EWS gate (only for calls still on EWS: EWS flow, cloud archive, unsupported MailTips):
        EwsEnabled = True AND EwsAllowedAppIDs contains the dedicated appId   [until 1 Apr 2027]
```
Up to **60 min** for Exchange processes to pick up app config; up to **24 h** for `EwsAllowedAppIDs` changes in EXO.
</details>

---
## Diagnosis & Validation Flow

1. **Builds.** `(Get-Command ExSetup.exe).FileVersionInfo.ProductVersion` on each Mailbox server (or `Get-ExchangeHybridAppReadiness.ps1`). Expected for Graph: `15.02.2562.041` or later. Anything older can't use Graph; anything below the EWS-flow table can't do rich coexistence at all.
2. **Feature overrides.** `Get-SettingOverride` (Triage 2). Expected: `EnableExchangeHybrid3PAppFeature` (`Enabled=true`). If you moved to Graph, also `EnableRouteThroughMSGraphFeature`. If `Server` is populated, the override only applies to those servers.
3. **Auth Server.** `ApplicationIdentifier` = the dedicated appId; `DomainName` includes the remote routing domain; `GraphBaseUrl` = `https://graph.microsoft.com` for Global. Empty `ApplicationIdentifier` = still on the shared principal = broken since 31 Oct 2025.
4. **Token test.** Triage 4. Good: `Success` and the extracted appId equals the `ExchangeServerApp-*` appId. Note: the token is acquired by the server running EMS, so a `Success` doesn't prove the *mailbox's* server is updated.
5. **Entra app.** In Graph PowerShell (`Application.Read.All`):
   ```powershell
   Connect-MgGraph -Scopes Application.Read.All -NoWelcome
   Get-MgApplication -Filter "startswith(displayName,'ExchangeServerApp-')" | Format-List DisplayName, AppId, @{n='Certs';e={$_.KeyCredentials | ForEach-Object { "$($_.DisplayName) exp $($_.EndDateTime)" }}}
   ```
   Expected: exactly one app per on-prem org; a non-expired certificate whose thumbprint matches `(Get-AuthConfig).CurrentCertificateThumbprint`.
6. **Sign-in evidence.** Entra admin center → Sign-in logs → **Service principal sign-ins**, filter on the app name. Failures with key/assertion errors (e.g. `AADSTS700027`) point at the certificate; no sign-ins at all point at the override/Auth Server.
7. **Tenant EWS gate.** Triage EXO block. If hybrid is still on EWS (no Graph override, or cloud archive in use), the dedicated appId **must** be in `EwsAllowedAppIDs` from 10 Oct 2026.
8. **End-to-end.** Outlook on an on-prem mailbox → Scheduling Assistant for a cloud user, and the reverse. Remote Connectivity Analyzer *Free/Busy* test for the cross-premises leg.

---
## Common Fix Paths

<details><summary>Fix 1 — Server build too old (or still on 2016/2019)</summary>

```powershell
# Inventory every server's exact build (run on any Exchange server, needs WinRM to the others)
Get-ExchangeServer | ForEach-Object {
    $v = Invoke-Command -ComputerName $_.Fqdn -ScriptBlock { (Get-Command ExSetup.exe).FileVersionInfo.ProductVersion } -ErrorAction SilentlyContinue
    [pscustomobject]@{ Server = $_.Name; ExSetup = $v; Roles = $_.ServerRole }
}
```
- **SE without May 2026 HU:** install the May 2026 HU (or a later SE update that contains it) from the Download Center — it is **not** pushed via Microsoft Update. Run [HealthChecker](https://aka.ms/ExchangeHealthChecker) before and after.
- **2019 CU14/CU15 or 2016 CU23 without April 2025 HU:** install the April 2025 HU to get the EWS-flow dedicated app as a bridge — then plan SE. Microsoft will **not** ship the Graph flow for 2016/2019 (not even via ESU). Rich coexistence on those versions stops for good on **1 April 2027**.
- Mixed estates: servers below the table silently fail their share of cross-premises lookups. Update all Mailbox servers, not just the "hybrid server".
</details>

<details><summary>Fix 2 — App exists (HCW) but feature not enabled / Auth Server not pointed at it</summary>

```powershell
# Enable the dedicated app feature org-wide, then refresh the config cache
New-SettingOverride -Name "EnableExchangeHybrid3PAppFeature" -Component "Global" -Section "ExchangeOnpremAsThirdPartyAppId" `
    -Parameters @("Enabled=true") -Reason "Enable dedicated Exchange hybrid app feature"
Get-ExchangeDiagnosticInfo -Process Microsoft.Exchange.Directory.TopologyService -Component VariantConfiguration -Argument Refresh
```
If `Get-AuthServer` has no `ApplicationIdentifier`, run Microsoft's script (download from https://aka.ms/ConfigureExchangeHybridApplication) on a Mailbox server with internet access:
```powershell
.\ConfigureExchangeHybridApplication.ps1 -FullyConfigureExchangeHybridApplication
# No internet on the Mailbox server? Split mode, Exchange step only:
.\ConfigureExchangeHybridApplication.ps1 -ConfigureAuthServer -ConfigureTargetSharingEpr -EnableExchangeHybridApplicationOverride `
    -CustomAppId "<appId>" -TenantId "<tenantId>" -RemoteRoutingDomain "<tenant>.mail.onmicrosoft.com"
```
Allow up to 60 min, then re-run Triage 4. **Do not** create the override if the org uses **DAuth** rather than OAuth — it breaks on-prem → cloud lookups.

**Rollback:** `Get-SettingOverride | Where-Object {$_.ComponentName -eq "Global" -and $_.SectionName -eq "ExchangeOnpremAsThirdPartyAppId"} | Remove-SettingOverride` + the refresh command. Note this does **not** restore anything — the shared principal path is permanently blocked.
</details>

<details><summary>Fix 3 — Hybrid on EWS flow, blocked by EwsAllowedAppIDs (fast bridge)</summary>

In the **EXO** session. The list is a replacement value — always read-merge-write:
```powershell
$hybridAppId = "<ExchangeServerApp appId>"
$cur = (Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy).EwsAllowedAppIDs
$ids = @(); if ($cur) { $ids = @($cur -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
if ($ids -notcontains $hybridAppId) { $ids += $hybridAppId }
Set-OrganizationConfig -EwsAllowedAppIDs ($ids -join ',')
Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy | Format-List EwsEnabled, EwsAllowedAppIDs
```
Up to **24 h** to take effect. This only buys time to **1 April 2027**; do Fix 4 if servers are on SE.
**Rollback:** re-write the list without the ID (same read-merge-write pattern).
</details>

<details><summary>Fix 4 — Move rich coexistence to Graph (SE + May 2026 HU, Global cloud only)</summary>

Pre-checks:
```powershell
Test-NetConnection -ComputerName login.microsoftonline.com -Port 443
Test-NetConnection -ComputerName graph.microsoft.com -Port 443
```
Then re-run the script on a Mailbox server and answer **Yes** to Graph permissions and to enabling the Graph flow:
```powershell
.\ConfigureExchangeHybridApplication.ps1 -FullyConfigureExchangeHybridApplication
```
Verify:
```powershell
Get-SettingOverride | Where-Object SectionName -eq 'RouteThroughMSGraph' | Format-List Name, Parameters
Get-AuthServer | Where-Object Name -like '*evoSTS*' | Format-List ApplicationIdentifier, GraphBaseUrl
```
- The script won't enable the Graph override unless **tenant-wide admin consent** for `MailboxSettings.Read`, `MailTips.ReadBasic.All`, `Calendars.Read`, `ProfilePhoto.Read.All` is granted.
- **1:N (one org → several tenants):** prepare the app + Graph permissions in **every** tenant **before** the Graph override exists — the override is org-wide and breaks tenants without consented Graph permissions.
- Graph covers Free/Busy, profile photos, and MailTips **Automatic Replies only**. Other MailTips and cloud archive still use EWS — keep `full_access_as_app` and keep the appId on the EXO EWS list until you've confirmed you don't need them.

**Rollback:** `Get-SettingOverride | Where-Object SectionName -eq 'RouteThroughMSGraph' | Remove-SettingOverride` then `Get-ExchangeDiagnosticInfo -Process Microsoft.Exchange.Directory.TopologyService -Component VariantConfiguration -Argument Refresh`. Hybrid falls back to the EWS flow (needs Fix 3 in place).
</details>

<details><summary>Fix 5 — Auth Certificate renewed, app still has the old key</summary>

```powershell
Get-AuthConfig | Format-List CurrentCertificateThumbprint, PreviousCertificateThumbprint, NextCertificateThumbprint, NextCertificateEffectiveDate
.\ConfigureExchangeHybridApplication.ps1 -UpdateCertificate
# Offline server: export the .cer (public key only) and run on a connected machine:
.\ConfigureExchangeHybridApplication.ps1 -UpdateCertificate -CertificateMethod "File" -CertificateInformation "C:\Certificates\NewAuthCertificate.cer"
```
`-UpdateCertificate` uploads current + next cert and deletes expired ones from the app. Use [MonitorExchangeAuthCertificate](https://aka.ms/MonitorExchangeAuthCertificate) to catch the next renewal before it bites.
</details>

<details><summary>Fix 6 — Cloud archive for on-prem mailboxes broke after "least privilege" clean-up</summary>

"Move to Archive" (cloud archive) has **no Graph path** yet. If someone ran `-RemoveApiPermissions "EWS"`, re-add the permission:
Entra admin center → App registrations → `ExchangeServerApp-<guid>` → API permissions → Add → APIs my organization uses → **Office 365 Exchange Online** → Application permissions → `full_access_as_app` → **Grant admin consent**. Then make sure the appId is on `EwsAllowedAppIDs` (Fix 3). After 1 April 2027 this path ends regardless — the cloud-archive scenario needs a Microsoft answer or the mailbox must move to EXO.
</details>

<details><summary>Fix 7 — Graph flow enabled in a cloud where it isn't supported, or HCW re-uploaded the cert to the shared principal</summary>

- Graph flow is supported only in **Microsoft 365 Global** (not 21Vianet, GCC High, DoD, Bleu, Delos as of the May 2026 docs). If enabled elsewhere, remove the `RouteThroughMSGraph` override (Fix 4 rollback) — Free/Busy, MailTips and photos stop until you do.
- Re-running HCW with *OAuth, Intra Organization Connector and Organization Relationship* re-uploads the Auth Certificate to the **first-party** `Office 365 Exchange Online` principal (the CVE-2025-53786 exposure). Purge it again (needs Global Administrator):
```powershell
.\ConfigureExchangeHybridApplication.ps1 -ResetFirstPartyServicePrincipalKeyCredentials
```
HMA keeps working — it doesn't need the cert on the shared principal.
</details>

---
## Escalation Evidence

```
Ticket: Exchange hybrid rich coexistence — dedicated app / Graph
Tenant ID / cloud:                         <tenantId> / <Global|GCC High|...>
On-prem Exchange org GUID:                 <(Get-OrganizationConfig).Guid>
Mailbox servers + ExSetup builds:          <server=15.2.2562.xx, ...>
Hybrid type (Classic / Modern) + auth:     <Classic Full|Modern Full> / <OAuth|DAuth>
Setting overrides present:                 <EnableExchangeHybrid3PAppFeature? EnableRouteThroughMSGraphFeature? server-scoped?>
AuthServer ApplicationIdentifier / GraphBaseUrl: <appId> / <url>
Entra app name / appId / cert expiry:      <ExchangeServerApp-...> / <appId> / <date>
Graph permissions consented (Y/N each):    MailboxSettings.Read <> MailTips.ReadBasic.All <> Calendars.Read <> ProfilePhoto.Read.All <> full_access_as_app <>
EXO EwsEnabled / appId in EwsAllowedAppIDs: <True|False|null> / <Y|N>  (list last changed: <date>)
Test-OAuthConnectivity ResultType + appId: <Success|Failure> / <appId>
Failing feature + direction:               <Free/Busy|MailTips|Photos|Archive>, <on-prem→cloud | cloud→on-prem>
First failure (UTC):                       <timestamp>   Changes in last 72h: <HU installed, HCW re-run, cert renewed, list edited>
Service-principal sign-in log errors:      <AADSTS code / none>
Attached: Get-ExchangeHybridAppReadiness.ps1 CSV, HealthChecker HTML
```

---
## 🎓 Learning Pointers
- **Two gates, two sides.** The dedicated app fixes *who* Exchange Server authenticates as; `EwsAllowedAppIDs` decides whether Exchange Online still accepts EWS from that identity. From 10 Oct 2026 a perfectly configured hybrid on the EWS flow can still fail because the tenant list omits its appId. Source: [Deploy dedicated Exchange hybrid app](https://learn.microsoft.com/exchange/hybrid-deployment/deploy-dedicated-hybrid-app) and MC1485116.
- **HCW creates the app but doesn't switch it on.** The `EnableExchangeHybrid3PAppFeature` override is what makes servers use it — the single most common "we did everything" gap.
- **Graph is SE-only and partial.** Free/Busy and photos move fully; MailTips only Automatic Replies; cloud archive not at all. Don't strip `full_access_as_app` until you've confirmed nobody uses the remaining EWS scenarios. Background: [Exchange Server Security Changes for Hybrid Deployments](https://techcommunity.microsoft.com/blog/exchange/exchange-server-security-changes-for-hybrid-deployments/4396833).
- **Test-OAuthConnectivity tests the server you're on.** Run it from (or remote into) the server that owns the failing mailbox, or you'll get a misleading `Success`.
- **Certificate hygiene is now app hygiene.** Every Auth Certificate renewal needs `-UpdateCertificate`, and every HCW re-run needs the shared-principal purge. See [Maintain the Exchange Server OAuth certificate](https://learn.microsoft.com/exchange/plan-and-deploy/integration-with-sharepoint-and-skype/maintain-oauth-certificate).
- **DAuth orgs: hands off the override.** DAuth/org-relationship scenarios stop working with EWS retirement; plan OAuth instead of enabling the dedicated-app override on a DAuth org.
