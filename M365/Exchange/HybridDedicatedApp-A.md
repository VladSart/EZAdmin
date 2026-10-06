# Exchange Hybrid Dedicated App & Graph Rich Coexistence — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions
- **In scope:** the identity and API that Exchange Server uses to call Exchange Online for **rich coexistence** — Free/Busy, MailTips, profile photos and cloud archive for on-prem mailboxes. Covers the dedicated Entra app (`ExchangeServerApp-<orgGuid>`), the two on-prem Setting Overrides, the EWS → Graph switch shipped in the **May 2026 SE Hotfix Update**, and how all of it interacts with the Exchange Online EWS retirement (`EwsAllowedAppIDs` enforcement from **10 Oct 2026**, shutdown **1 Apr 2027**).
- **Out of scope:** mail flow connectors, mailbox moves (unaffected by the dedicated app), HMA (still uses the first-party principal and keeps working), cross-*tenant* calendar sharing (`CrossTenantCalendarSharing-A.md`), third-party EWS apps (`EWSRetirement-A.md`). General hybrid health: `Hybrid-Coexistence-A.md`.
- **Assumes:** Classic Full or Modern Full hybrid already configured with HCW; OAuth (not DAuth) between premises; Exchange Online tenant in Microsoft 365 Global unless stated.
- **Source currency:** built 2026-10-06 from Microsoft Learn *Deploy dedicated Exchange hybrid app* (updated 2026-05-07), Message Center **MC1485116** (1 Oct 2026), and Exchange Team coverage of the May 2026 SE HU. Re-verify the Graph scenario table and cloud-support table before relying on them after early 2027 — Microsoft says both will expand.

---
## How It Works

<details><summary>Full architecture</summary>

### Three eras of hybrid identity
| Era | Identity Exchange Server uses toward EXO | API | Status |
|---|---|---|---|
| Legacy (to Oct 2025) | Shared first-party `Office 365 Exchange Online` service principal; HCW uploaded the on-prem **Auth Certificate** to its `keyCredentials` | EWS | **EWS access via the shared principal permanently blocked since 31 Oct 2025** |
| Dedicated app, EWS flow (Apr 2025 HU onward) | Customer-owned app `ExchangeServerApp-<ExchangeOrgGuid>` with the Auth Certificate as its credential | EWS (`full_access_as_app`) | Works until EXO EWS shutdown, **1 Apr 2027**; subject to `EwsAllowedAppIDs` from 10 Oct 2026 |
| Dedicated app, Graph flow (SE + May 2026 HU) | Same app | Microsoft Graph (application permissions) + EWS for anything not yet ported | The supported long-term path; **SE only** |

Why a customer-owned app rather than a new Microsoft-managed one: permission changes (EWS → Graph) become a customer-timed event, the app can be audited in sign-in logs, and it can be fenced with Conditional Access for workload identities. It also removed the CVE-2025-53786 exposure, where an on-prem admin's Auth Certificate on the shared principal could be abused to act against the cloud tenant.

### Call path (on-prem user looks up a cloud user's free/busy)
```
Outlook (on-prem mailbox)
  └─► Exchange Server (Availability service)
        ├─ finds target is a MailUser with cloud RemoteRoutingAddress
        ├─ reads OrganizationRelationship / IntraOrganizationConnector
        ├─ AuthServer evoSTS*  (ApplicationIdentifier = dedicated appId)
        │     └─► Entra token endpoint: client-credentials, cert = Auth Certificate
        │            token: appid = ExchangeServerApp-..., aud = EXO or Graph
        ├─ RouteThroughMSGraph override on?
        │     yes ─► https://graph.microsoft.com  (Calendars.Read → schedule data)
        │     no  ─► TargetSharingEpr (EXO EWS)  ── EXO EWS gate:
        │                                           EwsEnabled + EwsAllowedAppIDs ∋ appId
        └─ returns free/busy to Outlook
```
The cloud → on-prem direction is served by Exchange Online calling *into* the on-prem EWS endpoint and is governed by EXO's own configuration; it isn't what the dedicated app authenticates. Tickets that only fail in one direction tell you which half to look at.

### The two Setting Overrides
| Override name (script default) | Component / Section | Effect |
|---|---|---|
| `EnableExchangeHybrid3PAppFeature` | `Global` / `ExchangeOnpremAsThirdPartyAppId`, `Enabled=true` | Servers on a supporting build use the dedicated app's identity |
| `EnableRouteThroughMSGraphFeature` | `SettingOverride` / `RouteThroughMSGraph`, `Enabled=true` | Servers on SE + May 2026 HU send supported scenarios to Graph |

Both are **organization-wide** unless created with `-Server`. HCW (latest) can create the app with EWS permissions but **never** creates either override — the script or a manual `New-SettingOverride` does. After any override change, `Get-ExchangeDiagnosticInfo -Process Microsoft.Exchange.Directory.TopologyService -Component VariantConfiguration -Argument Refresh` forces pickup; full propagation can still take up to 60 min.

### Supported builds
| Version | Build | EWS flow | Graph flow |
|---|---|---|---|
| SE RTM + May 2026 HU | 15.2.2562.41 | Yes | **Yes** |
| SE RTM | 15.2.2562.17 | Yes | No |
| 2019 CU15 + Apr 2025 HU | 15.2.1748.24 | Yes | No |
| 2019 CU14 + Apr 2025 HU | 15.2.1544.25 | Yes | No |
| 2016 CU23 + Apr 2025 HU | 15.1.2507.55 | Yes | No |

Microsoft has stated 2016/2019 will not receive the Graph flow, including under ESU. Servers below these builds can't do rich coexistence at all — and in a mixed estate they fail only the lookups they happen to serve, which is why the symptom is often "intermittent".

### Graph scenario coverage (May 2026)
| Feature | EWS | Graph |
|---|---|---|
| Free/Busy | Yes | Yes |
| MailTips | Yes | Partial — Automatic Replies only |
| Profile pictures | Yes | Yes |
| Move to Archive (cloud archive for on-prem mailbox) | Yes | **No** |

With the Graph override on, Exchange still uses EWS for anything Graph doesn't cover. Practical consequence: until Microsoft ports the remaining scenarios, most orgs need **both** permission sets on the app **and** the appId on `EwsAllowedAppIDs` until 1 April 2027.

### App permissions
- EWS flow: `Office 365 Exchange Online` → `full_access_as_app` (application). Tenant-wide mailbox access — the reason security teams push to remove it.
- Graph flow: `MailboxSettings.Read`, `MailTips.ReadBasic.All`, `Calendars.Read`, `ProfilePhoto.Read.All` (application). The script won't create the Graph override until admin consent exists.
- Removal: `-RemoveApiPermissions "EWS"` or `"Graph"`.
- Scoping: RBAC for Applications / Application Access Policies can narrow app-only access, but scoping a hybrid app to a subset of cloud mailboxes means lookups for unscoped users fail — treat as an advanced design choice, not a default.

### Where the EXO EWS retirement bites (MC1485116)
- From **10 Oct 2026**, Worldwide tenants with `EwsEnabled=True` need `EwsAllowedAppIDs`. Microsoft auto-populated lists on **8–9 Oct** from **60 days** of activity for tenants that had True + no list on 3 Oct. MC1485116 explicitly lists **Exchange Server hybrid scenarios** among Microsoft traffic that can generate EWS — i.e. the dedicated appId appears in usage data and must stay on the list while any hybrid scenario uses EWS.
- Tenants with `EwsEnabled` unset stay in Microsoft's phased disablement → `False` → hybrid EWS flow dead even with a perfect app.
- Cross-tenant organization relationships aren't affected by the AppID requirement, but **DAuth**-based relationships stop working with EWS retirement; Microsoft recommends moving hybrid to OAuth.

### Multi-org topologies
- **1 on-prem org : N tenants** — run the script per tenant; one app per tenant. Because the Graph override is org-wide, every tenant must have consented Graph permissions **before** you turn it on.
- **N forests : 1 tenant** — one app per forest (`ExchangeServerApp-<each org GUID>`), all in the same tenant; all their appIds go on `EwsAllowedAppIDs`.
- Don't rename the app: HCW and the script detect it by name, and a rename produces a duplicate on the next run.
</details>

---
## Dependency Stack
```
L9  User experience: Scheduling Assistant / MailTips / photos / archive in on-prem Outlook
L8  EXO acceptance:   (EWS calls) EwsEnabled=True + appId ∈ EwsAllowedAppIDs  | (Graph) consented app perms
L7  Transport of call: TargetSharingEpr (EWS)  |  graph.microsoft.com 443 outbound (Graph)
L6  Routing switch:   SettingOverride RouteThroughMSGraph (optional, SE+May26 HU, Global cloud only)
L5  Identity switch:  SettingOverride ExchangeOnpremAsThirdPartyAppId Enabled=true
L4  AuthServer evoSTS*: ApplicationIdentifier=appId, DomainName ∋ <tenant>.mail.onmicrosoft.com, GraphBaseUrl
L3  Entra app ExchangeServerApp-<orgGuid>: Auth Cert in keyCredentials, API perms + admin consent
L2  On-prem Auth Certificate (Get-AuthConfig) valid; next cert pre-staged and uploaded
L1  Every Mailbox server on a supported build; HCW hybrid (OAuth) + OrgRelationship/IOC in place
L0  Network: login.microsoftonline.com + EXO/Graph endpoints reachable from Mailbox servers
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| All on-prem → cloud free/busy dead since Nov 2025 | Never moved off the shared principal (no dedicated app or no override) | Validation 2–3 |
| Intermittent failures depending on user | Some Mailbox servers below supported build | Validation 1 |
| Worked until ~10 Oct 2026, then broke | Hybrid on EWS flow; appId absent from `EwsAllowedAppIDs` (auto-list missed it, or admin rewrote list without it) | Validation 7 |
| Broke after EWS was "turned off" in EXO | `EwsEnabled=False` (admin or phased rollout) while hybrid still uses EWS | Validation 7 |
| Broke right after enabling Graph flow | Consent missing in one of N tenants; outbound Graph blocked by proxy; non-Global cloud | Validation 5–6, Playbook 3 |
| Only OOF MailTips work, other MailTips missing after removing EWS perm | Graph covers Automatic Replies only | Scenario table |
| Cloud archive for on-prem mailboxes fails, rest fine | `full_access_as_app` removed or appId not on EWS list | Playbook 4 |
| Test-OAuthConnectivity fails with key/cert error | Auth Certificate rotated; app not updated | Validation 4–5 |
| Sign-in logs show the dedicated app succeeding, feature still fails | Problem is past auth: EXO EWS gate, Graph permission, or the OrgRelationship | Validation 7–8 |
| Security alert: certificate on Office 365 Exchange Online principal | HCW re-run uploaded it again | Playbook 5 |
| Duplicate `ExchangeServerApp-*` apps | App renamed, or script run in a second forest (legit in N:1) | Validation 5 |

---
## Validation Steps
1. **Builds** — `(Get-Command ExSetup.exe).FileVersionInfo.ProductVersion` per server.
   Good: ≥ `15.2.2562.41` everywhere (Graph-capable). Acceptable bridge: table builds. Bad: anything lower.
2. **Identity override** — `Get-SettingOverride | ? SectionName -eq 'ExchangeOnpremAsThirdPartyAppId' | fl Name,Parameters,Server`.
   Good: one override, `Enabled=true`, `Server` empty. Bad: none, or scoped to a subset of servers.
3. **Auth Server** — `Get-AuthServer | ? Name -like '*evoSTS*' | fl Name,Realm,ApplicationIdentifier,DomainName,GraphBaseUrl`.
   Good: `ApplicationIdentifier` = dedicated appId, `Realm` = tenant ID. Bad: empty `ApplicationIdentifier` (shared principal → blocked).
4. **Token** — `Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com -Mailbox <onprem mbx>`; extract appId from `Detail.FullId`.
   Good: `Success` + dedicated appId. Bad: `Failure`, or the first-party Exchange Online appId `00000002-0000-0ff1-ce00-000000000000`.
5. **Entra app** — `Get-MgApplication -Filter "startswith(displayName,'ExchangeServerApp-')"`; check `KeyCredentials` end dates and thumbprints against `Get-AuthConfig`; check `RequiredResourceAccess` and that admin consent exists (Enterprise applications → Permissions).
6. **Routing override (if Graph)** — `Get-SettingOverride | ? SectionName -eq 'RouteThroughMSGraph'`; `Test-NetConnection graph.microsoft.com -Port 443` from **every** Mailbox server (proxy settings: `Get-ExchangeServer | fl Name,InternetWebProxy`).
7. **EXO EWS gate** — `Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy | fl EwsEnabled,EwsAllowedAppIDs`.
   Good while any EWS scenario remains: `True` + list containing the appId. Bad: `False`, `$null` enabled, or appId missing.
8. **Functional** — Scheduling Assistant both directions; `Test-OrganizationRelationship` is EWS/DAuth-oriented and not authoritative for OAuth — prefer Outlook + Remote Connectivity Analyzer Free/Busy test.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Inventory (no changes).** Run `Get-ExchangeHybridAppReadiness.ps1` (EMS) with `-ExoPrefix` after `Connect-ExchangeOnline -Prefix EXO` in the same session. Record builds, overrides, AuthServer, token appId, EXO list membership.

**Phase 2 — Bridge (before/after 10 Oct 2026).** Ensure the dedicated app is live (Playbook 1) and its appId is on `EwsAllowedAppIDs` (Playbook 2). This restores service on any supported build.

**Phase 3 — Modernise (SE estates).** Install the May 2026 HU on all Mailbox servers, enable Graph (Playbook 3), verify per feature, then decide whether EWS permission can be dropped (only if no cloud archive and non-OOF MailTips are acceptable).

**Phase 4 — Harden.** Purge the shared principal (Playbook 5), add Conditional Access for workload identities restricted to the Exchange egress IPs (Workload Identities Premium), alert on app credential changes, calendar the Auth Certificate renewal.

**Phase 5 — Pre-April 2027.** Anything still on 2016/2019 with on-prem mailboxes loses rich coexistence on 1 Apr 2027. Upgrade to SE or finish migrating; if no mailboxes remain on-prem, delete the app (`-DeleteApplication`) and purge the shared principal.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Stand up / repair the dedicated app (all-in-one)</summary>

```powershell
# Mailbox server with internet access, elevated EMS, Application Administrator (or GA) in Entra
.\ConfigureExchangeHybridApplication.ps1 -FullyConfigureExchangeHybridApplication
# Other clouds:
.\ConfigureExchangeHybridApplication.ps1 -FullyConfigureExchangeHybridApplication -AzureEnvironment "ChinaCloud"
```
Not compatible with Server Core — use split mode: export the Auth Certificate (public key only) on the server, `-CreateApplication -UpdateCertificate -CertificateMethod "File" -CertificateInformation <cer>` on a connected machine, then `-ConfigureAuthServer -ConfigureTargetSharingEpr -EnableExchangeHybridApplicationOverride -CustomAppId <appId> -TenantId <tenantId> -RemoteRoutingDomain <tenant>.mail.onmicrosoft.com` on the Mailbox server.

**Rollback (troubleshooting only — it does not restore service):** run HCW with the OAuth/IOC/OrgRel option; remove the `ExchangeOnpremAsThirdPartyAppId` override; `Get-AuthServer | ? {$_.Name -like "*evoSTS*" -and $_.Realm -eq "<tenantId>"} | Set-AuthServer -ApplicationIdentifier $null -DomainName $null`; `.\ConfigureExchangeHybridApplication.ps1 -DeleteApplication`.
</details>

<details><summary>Playbook 2 — Keep hybrid EWS calls alive under EwsAllowedAppIDs</summary>

```powershell
Connect-ExchangeOnline -ShowBanner:$false
$appIds = @("<ExchangeServerApp appId #1>")       # add one per on-prem forest
$cur  = (Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy).EwsAllowedAppIDs
$list = @(); if ($cur) { $list = @($cur -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$before = $list.Count
foreach ($a in $appIds) { if ($list -notcontains $a) { $list += $a } }
"Adding $($list.Count - $before) ID(s); total $($list.Count)"
Set-OrganizationConfig -EwsEnabled $true -EwsAllowedAppIDs ($list -join ',')
```
`EwsEnabled` changes apply in ~1 h, list changes in up to 24 h. Keep a copy of `$cur` in the change record — it's your rollback. Never write the list from a hand-typed value; one omission is an outage for every other EWS app.
</details>

<details><summary>Playbook 3 — Switch to the Graph flow safely</summary>

1. All Mailbox servers ≥ 15.2.2562.41 (Validation 1). Tenant in Global cloud.
2. Outbound 443 to `graph.microsoft.com` from every Mailbox server, including through `InternetWebProxy` if set.
3. For **each** tenant the org is hybrid with: re-run `-FullyConfigureExchangeHybridApplication` from a connected server and accept Graph permissions + consent. For split execution use `-CreateApplication -UseGraphApiOnly` only if you are certain no EWS scenario is needed.
4. Accept the prompt to enable the Graph flow (creates `EnableRouteThroughMSGraphFeature`), or create it after all tenants are ready:
   ```powershell
   New-SettingOverride -Name "EnableRouteThroughMSGraphFeature" -Component "SettingOverride" -Section "RouteThroughMSGraph" `
       -Parameters @("Enabled=true") -Reason "Move hybrid rich coexistence to Graph"
   Get-ExchangeDiagnosticInfo -Process Microsoft.Exchange.Directory.TopologyService -Component VariantConfiguration -Argument Refresh
   ```
   (The component/section values come from Microsoft's documented script operations; prefer letting the script create it.)
5. Validate Free/Busy, photos, OOF MailTips. Watch service-principal sign-ins for resource `Microsoft Graph`.
6. Only then consider `-RemoveApiPermissions "EWS"` — and only if cloud archive and non-OOF MailTips aren't needed.

**Rollback:** remove the `RouteThroughMSGraph` override + refresh. Requires the EWS permission and EXO list entry to still be present.
</details>

<details><summary>Playbook 4 — Restore cloud archive (EWS-only scenario)</summary>

Re-add `full_access_as_app` (Office 365 Exchange Online, Application) to the app and grant admin consent; confirm the appId is on `EwsAllowedAppIDs` (Playbook 2). Plan for 1 Apr 2027: unless Microsoft publishes a Graph path, on-prem primary + cloud archive is a configuration with an end date — move the primary mailbox to EXO.
</details>

<details><summary>Playbook 5 — Purge the shared principal & harden</summary>

```powershell
# Global Administrator; any internet-connected machine
.\ConfigureExchangeHybridApplication.ps1 -ResetFirstPartyServicePrincipalKeyCredentials
# or only a given cert + all expired ones:
.\ConfigureExchangeHybridApplication.ps1 -ResetFirstPartyServicePrincipalKeyCredentials -CertificateInformation "<thumbprint>"
```
Repeat after **every** HCW run that includes the OAuth/IOC/OrgRel option. Then: Conditional Access for workload identities (block the app outside Exchange egress IPs), alert on "Update application – Certificates and secrets management" audit events for the app, and record an owner for the app object.
</details>

<details><summary>Playbook 6 — Auth Certificate rotation with the dedicated app</summary>

1. `Get-AuthConfig` — confirm a `NextCertificateThumbprint` is staged with an effective date ≥ 48 h out.
2. `.\ConfigureExchangeHybridApplication.ps1 -UpdateCertificate` — uploads current + next, removes expired.
3. After the effective date, `Test-OAuthConnectivity` again; `-UpdateCertificate` once more to prune the old key.
Skipping step 2 means the day the next cert becomes current, every token request fails.
</details>

---
## Evidence Pack
```powershell
# Run in elevated EMS. Optional: Connect-ExchangeOnline -Prefix EXO first for tenant-side data.
param([string]$OnPremMailbox = "<onprem-mailbox@contoso.com>", [string]$Out = "C:\Temp\HybridAppEvidence")
New-Item -ItemType Directory -Path $Out -Force | Out-Null
Get-ExchangeServer | Where-Object IsMailboxServer | ForEach-Object {
    $v = try { Invoke-Command -ComputerName $_.Fqdn -ScriptBlock { (Get-Command ExSetup.exe).FileVersionInfo.ProductVersion } -ErrorAction Stop } catch { "unreachable: $($_.Exception.Message)" }
    [pscustomobject]@{ Server = $_.Name; ExSetup = $v; AdminDisplayVersion = "$($_.AdminDisplayVersion)" }
} | Export-Csv "$Out\01-Builds.csv" -NoTypeInformation
Get-SettingOverride | Format-List * | Out-File "$Out\02-SettingOverrides.txt"
Get-AuthServer | Format-List * | Out-File "$Out\03-AuthServer.txt"
Get-AuthConfig | Format-List * | Out-File "$Out\04-AuthConfig.txt"
Get-OrganizationRelationship | Format-List * | Out-File "$Out\05-OrgRelationship.txt"
Get-IntraOrganizationConnector | Format-List * | Out-File "$Out\06-IOC.txt"
Get-HybridConfiguration | Format-List * | Out-File "$Out\07-HybridConfiguration.txt"
Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com -Mailbox $OnPremMailbox |
    Format-List * | Out-File "$Out\08-OAuthTest.txt"
if (Get-Command Get-EXOOrganizationConfig -ErrorAction SilentlyContinue) {
    Get-EXOOrganizationConfig -RetrieveEwsOperationAccessPolicy |
        Format-List EwsEnabled, EwsAllowedAppIDs, EwsApplicationAccessPolicy, EwsAllowList |
        Out-File "$Out\09-EXO-EwsPolicy.txt"
}
Compress-Archive -Path "$Out\*" -DestinationPath "$Out.zip" -Force
"Evidence: $Out.zip"
```
Add the HealthChecker HTML and an Entra service-principal sign-in export (filtered on `ExchangeServerApp-`).

---
## Command Cheat Sheet
| Purpose | Command |
|---|---|
| Exact server build | `(Get-Command ExSetup.exe).FileVersionInfo.ProductVersion` |
| Dedicated-app override | `Get-SettingOverride \| ? SectionName -eq 'ExchangeOnpremAsThirdPartyAppId'` |
| Graph-flow override | `Get-SettingOverride \| ? SectionName -eq 'RouteThroughMSGraph'` |
| Refresh override cache | `Get-ExchangeDiagnosticInfo -Process Microsoft.Exchange.Directory.TopologyService -Component VariantConfiguration -Argument Refresh` |
| Auth Server | `Get-AuthServer \| ? Name -like '*evoSTS*' \| fl ApplicationIdentifier,DomainName,GraphBaseUrl` |
| Token test | `Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com -Mailbox <mbx>` |
| Auth certs | `Get-AuthConfig \| fl *Thumbprint*,NextCertificateEffectiveDate` |
| Full configure | `.\ConfigureExchangeHybridApplication.ps1 -FullyConfigureExchangeHybridApplication` |
| Upload new cert | `.\ConfigureExchangeHybridApplication.ps1 -UpdateCertificate` |
| Purge shared principal | `.\ConfigureExchangeHybridApplication.ps1 -ResetFirstPartyServicePrincipalKeyCredentials` |
| Drop EWS perm | `.\ConfigureExchangeHybridApplication.ps1 -RemoveApiPermissions "EWS"` |
| Delete app | `.\ConfigureExchangeHybridApplication.ps1 -DeleteApplication` |
| Find app in Entra | `Get-MgApplication -Filter "startswith(displayName,'ExchangeServerApp-')"` |
| EXO EWS gate | `Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy \| fl EwsEnabled,EwsAllowedAppIDs` |
| Readiness audit | `.\Get-ExchangeHybridAppReadiness.ps1 -OnPremMailbox <mbx> -ExoPrefix EXO` |

---
## 🎓 Learning Pointers
- **Read the build, not the CU.** HU revisions (`.41` vs `.17`) decide Graph eligibility, and `AdminDisplayVersion` hides them. Microsoft's [HealthChecker](https://aka.ms/ExchangeHealthChecker) reports the HU level and flags the dedicated-app state.
- **The override is the switch, the app is the key.** HCW builds the key; only `New-SettingOverride`/the script turns the lock. Most "dedicated app done, still broken" tickets are a missing override. Reference: [Deploy dedicated Exchange hybrid app](https://learn.microsoft.com/exchange/hybrid-deployment/deploy-dedicated-hybrid-app).
- **Graph doesn't free you from EWS yet.** Cloud archive and most MailTips still ride EWS, so the dedicated appId belongs on `EwsAllowedAppIDs` until 1 Apr 2027 — MC1485116 names Exchange hybrid as an EWS traffic source. See `EWSRetirement-A.md`.
- **1:N orgs flip all tenants at once.** Setting Overrides are org-wide; prepare consent everywhere before enabling Graph.
- **It's a privileged workload identity — treat it like one.** Owner, sign-in monitoring, CA for workload identities, and the shared-principal purge after each HCW run (CVE-2025-53786). Background: [Exchange Server Security Changes for Hybrid Deployments](https://techcommunity.microsoft.com/blog/exchange/exchange-server-security-changes-for-hybrid-deployments/4396833).
- **April 2027 is the real deadline for 2016/2019.** No Graph flow will ship for them; budget the SE upgrade or the last migration batches now (`MigrationBatches-A.md`).
