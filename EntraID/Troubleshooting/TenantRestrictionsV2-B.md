# Tenant Restrictions v2 (TRv2) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

**Scope:** Entra ID tenant restrictions v2 — the cross-tenant access "Tenant restrictions" policy that controls *external* accounts reaching *external* apps from your networks/devices. Covers the three signalling paths (Windows GPO/CSP, corporate proxy header, Global Secure Access universal tenant restrictions), the most common "user suddenly blocked" and "policy does nothing" tickets, and v1→v2 header conflicts.
**Not in scope:** B2B inbound/outbound collaboration settings (see `CrossTenant-B.md`), Global Secure Access client health itself (see `GlobalSecureAccess-B.md`).

Sources (live-fetched run 261): Learn "Set up tenant restrictions v2" (ms.date 2026-03-20, updated 2026-06-11); Learn "Policy CSP – TenantRestrictions" (ms.date 2025-03-12).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run on the affected Windows device (elevated PowerShell), then the Graph check from an admin workstation.

```powershell
# 1. Is the device-side TRv2 policy present? (GPO "Cloud Policy Details" / CSP ConfigureTenantRestrictions)
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TenantRestrictions\Payload' -ErrorAction SilentlyContinue |
    Select-Object * -ExcludeProperty PS*

# 2. What has the TRv2 client logged recently?
Get-WinEvent -LogName 'Microsoft-Windows-TenantRestrictions/Operational' -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List

# 3. Is anything still injecting the v1 header path? (proxy config visible to the device)
netsh winhttp show proxy

# 4. Admin side: TRv2 default policy + its ID (Connect-MgGraph -Scopes Policy.Read.All first)
$d = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/default'
$d.id; $d.tenantRestrictions | ConvertTo-Json -Depth 6

# 5. Partner overrides (the only way anything gets allowed when the default is Block)
(Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners').value |
    Where-Object { $_.tenantRestrictions } | Select-Object tenantId, @{n='TR';e={$_.tenantRestrictions | ConvertTo-Json -Depth 6 -Compress}}
```

| Result | Meaning | Do this |
|---|---|---|
| Error `AADSTS5000211` ("A tenant restrictions policy added to this request by a device or network administrator does not allow access to '<tenant>'") | TRv2 is working as designed and the external tenant/app/user isn't allowed | Decide: add a partner policy (Fix 1) or move the user to B2B guest access instead |
| Registry key #1 missing on a device you expected to be covered | Device isn't getting the GPO/CSP | Fix 3 |
| Key present but tenant ID / policy GUID ≠ output of #4 | Wrong or stale IDs deployed (commonly the *partner* policy ID copied instead of the default) | Fix 3 — redeploy with default policy `id` |
| Default `tenantRestrictions` is `null`/empty in #4 | No TRv2 policy has ever been created | Create it in the portal (Cross-tenant access settings → Default settings → Edit tenant restrictions defaults → **Create policy**) |
| Users blocked from Microsoft Learn / MSA-based portals | Default blocks the MSA tenant `9188040d-6c67-4c5b-b112-36a304b66dad` | Fix 1 with app-level allow (e.g. Learn app ID `18fbca16-2224-45f6-85b0-f7bf2b39b3f3`) |
| Admins get "Access denied" opening entra.microsoft.com after TRv2 rollout | Documented known issue | Fix 5 |
| Chrome/Firefox/PowerShell bypass TRv2 on a GPO-covered device | Those apps don't use the Windows networking stack ("unenlightened") | Fix 4 (App Control AppId tagging + firewall) |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Entra ID P1/P2 in the enforcing (home) tenant
└── Cross-tenant access policy: Default "Tenant restrictions" policy CREATED (has Policy ID)
    ├── Default: External users & groups = Allow|Block  (can't be scoped per user)
    ├── Default: External applications = Allow|Block    (block-all users ⇒ must block-all apps and vice versa)
    └── Organizational settings (partner tenants) — override default per tenant / user / group / app
        └── MSA tenant 9188040d-... : app-level granularity only, no per-user
│
└── SIGNAL: request must carry header  sec-Restrict-Tenant-Access-Policy: <HomeTenantId>:<DefaultPolicyId>
    ├── Path A — Windows GPO/CSP (ConfigureTenantRestrictions → HKLM\...\TenantRestrictions\Payload)
    │     ├── Win10 19041.1320+ w/ KB5006738, 21H2+, Win11, Server 20348.320+
    │     ├── Auth plane + DATA plane (SPO/EXO/Graph/Teams, anonymous-link blocking)
    │     └── Only "enlightened" apps (Windows net stack, Edge, Office, UWP) — NOT Chrome/Firefox/.NET
    │           └── Optional: App Control AppIdTagging policy + "Enable firewall protection of Microsoft endpoints"
    ├── Path B — Corporate proxy header injection (TLS break-and-inspect on login.* domains)
    │     └── Auth plane ONLY — no anonymous Teams/SPO blocking; must remove v1 headers
    └── Path C — Global Secure Access universal tenant restrictions (Microsoft traffic profile)
          └── Auth plane all OS/browsers; data plane for Microsoft Graph only
│
└── Microsoft Entra enforces at sign-in → AADSTS5000211 on block
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm it's really TRv2.**
   `Get-WinEvent -LogName 'Microsoft-Windows-TenantRestrictions/Operational' -MaxEvents 5`
   - Expected (covered device): recent events present. **Empty/missing log** on a device supposed to be GPO/CSP-covered ⇒ the client feature isn't configured; check step 3.
   - Error text contains `AADSTS5000211` ⇒ TRv2. `AADSTS500021`-style "access to tenant denied" with no TRv2 policy ⇒ you're looking at a **v1** proxy allowlist (`Restrict-Access-To-Tenants`) instead.

2. **Identify which identity the user used.** TRv2 only evaluates *externally issued* identities (anything that isn't `user@<your tenant>`). Home-tenant members accessing a partner as B2B guests are governed by cross-tenant *outbound* settings, not TRv2.
   - Expected: blocked account's UPN suffix belongs to another tenant or is an MSA.

3. **Compare deployed IDs to the cloud policy.**
   ```powershell
   $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TenantRestrictions\Payload' -ErrorAction SilentlyContinue
   $reg | Format-List *
   ```
   - Good: the values contain your home tenant ID and the **default** policy `id` from Triage #4.
   - Bad: another tenant's ID, a partner policy's ID, or blank ⇒ Fix 3.

4. **Check the partner override, if any.** In Entra admin center → External Identities → Cross-tenant access settings → Organizational settings, look at the **Tenant restrictions** column. "Inherited from default" = no override.

5. **For "TRv2 isn't blocking anything":** determine the path. GPO/CSP path doesn't cover Chrome/Firefox/.NET. Proxy path doesn't block anonymous Teams join / anyone-links. GSA path gives data-plane only for Graph. Match the gap to the path before treating it as a bug.

6. **Check sign-in logs in the *resource* tenant for service principals.** A service principal blocked by TRv2 logs only in the tenant that received the request — nothing appears in your enforcing tenant.

---
## Common Fix Paths

<details><summary>Fix 1 — Allow a specific partner tenant / app / group while keeping default Block</summary>

Portal: Cross-tenant access settings → Organizational settings → **Add organization** (domain or tenant ID) → Tenant restrictions column → **Inherited from default** → **Customize settings** → set Users & groups and External applications tabs.

Graph (PATCH an *existing* partner entry; add the org first if missing):
```powershell
# Requires Policy.ReadWrite.CrossTenantAccess
$partnerTenantId = '<partnerTenantId>'
$body = @{
  tenantRestrictions = @{
    usersAndGroups = @{ accessType = 'allowed'; targets = @(@{ target = 'AllUsers'; targetType = 'user' }) }
    applications   = @{ accessType = 'allowed'; targets = @(@{ target = '<appId>'; targetType = 'application' }) }
  }
} | ConvertTo-Json -Depth 6
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partnerTenantId" -Body $body -ContentType 'application/json'
```
For Teams: set the policy on the **Office 365** app, not Teams/SPO/EXO individually — Teams depends on SPO and EXO.
Rollback: set `tenantRestrictions` back to `$null` on the partner (or delete the partner entry if it only existed for TRv2).
</details>

<details><summary>Fix 2 — Remove conflicting v1 headers from the proxy</summary>

On the proxy, delete `Restrict-Access-To-Tenants`, `Restrict-Access-Context`, and `sec-Restrict-Tenant-Access-Policy: restrict-msa` (the v1 MSA block sent to login.live.com). Keep only:

```
sec-Restrict-Tenant-Access-Policy: <HomeTenantId>:<DefaultPolicyId>
```
injected to `login.live.com`, `login.microsoft.com`, `login.microsoftonline.com`, `login.windows.net`. Microsoft documents that leaving `restrict-msa` in place conflicts with v2.
Recreate each v1 allowlisted tenant as a partner policy (Fix 1) **before** removing the v1 header, or users lose access to those tenants in the gap.
</details>

<details><summary>Fix 3 — Redeploy the Windows client policy (GPO or Intune)</summary>

GPO: Computer Configuration → Administrative Templates → Windows Components → **Tenant Restrictions** → **Cloud Policy Details** → Enabled; fill **Microsoft Entra Directory ID** and **Policy GUID** only (leave other fields blank unless you're deliberately enabling firewall protection).

Intune: Settings catalog → search "Tenant Restrictions" → *Cloud Policy Details* (backed by `./Device/Vendor/MSFT/Policy/Config/TenantRestrictions/ConfigureTenantRestrictions`, ADMX-backed).

Then on the device:
```powershell
gpupdate /force            # GPO path
# Intune path: sync from Settings > Accounts > Access work or school, or:
Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -TaskName 'PushLaunch' -ErrorAction SilentlyContinue | Start-ScheduledTask
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TenantRestrictions\Payload'
```
Rollback: set the GPO/Settings-catalog entry to Not configured/Disabled; the Payload key is removed on next refresh.
</details>

<details><summary>Fix 4 — Close the Chrome / Firefox / PowerShell bypass (destructive if wrong)</summary>

⚠️ Microsoft's CSP doc: enabling **firewall protection of Microsoft endpoints** without an App Control AppId tagging policy already applied **blocks all apps from reaching Microsoft endpoints**. Order matters: tagging policy first, pilot group, then firewall checkbox.

```powershell
# On a build/reference machine with the App Control policy XML created (wizard or New-CIPolicy)
Set-CIPolicyIdInfo -ResetPolicyID .\policy.xml -AppIdTaggingPolicy -AppIdTaggingKey 'M365ResourceAccessEnforcement' -AppIdTaggingValue 'True'
# note the new PolicyID GUID written to the XML, then:
ConvertFrom-CIPolicy .\policy.xml ".\{<PolicyID>}.cip"
```
Deploy the `.cip` to a pilot device (`C:\Windows\System32\CodeIntegrity\CiPolicies\Active\`) and refresh, then tick **Enable firewall protection of Microsoft endpoints** in Cloud Policy Details, `gpupdate /force`, and **restart**.
Rollback: untick firewall protection first, restart, then remove the `.cip` and refresh.
</details>

<details><summary>Fix 5 — Admins get "Access denied" in the Entra admin center after TRv2</summary>

Documented known issue. Append the feature flags:
```
https://entra.microsoft.com/?feature.msaljs=true&exp.msaljsexp=true#home
```
</details>

<details><summary>Fix 6 — macOS Platform SSO breaks behind the TRv2 proxy</summary>

Documented Apple limitation: Platform SSO fails when the proxy injecting the header uses a certificate chain outside Apple's system roots (you can't add your own PKI to that store). Move Macs to **universal tenant restrictions via Global Secure Access** (Path C), or exclude Macs from proxy injection. See `macOS/Troubleshooting/Platform-SSO-B.md`.
</details>

---
## Escalation Evidence

```
Ticket: TRv2 — <short symptom>
Enforcing (home) tenant ID:        <tenantId>
Default TRv2 policy ID (Graph):    <policyId>
Signalling path(s) in use:         [ ] Windows GPO/CSP  [ ] Proxy header  [ ] GSA universal TR
Affected device OS/build:          <winver output>
Payload registry values present:   <yes/no + values>
Blocked identity (UPN / MSA):      <user@externaltenant>
Target resource / app ID:          <app name / appId>
Exact error + correlation ID:      <AADSTS5000211 ... Correlation ID ... Timestamp ...>
Partner policy for that tenant:    <inherited / customized: summary>
TenantRestrictions/Operational events (last 20): <attached>
v1 headers removed from proxy?:    <yes/no/n.a.>
Steps already taken:               <...>
```

---
## 🎓 Learning Pointers
- TRv2 governs **external identities reaching external apps** — the fourth quadrant that inbound/outbound B2B settings don't touch. If the user is signing in with their *own* tenant account, you're in the wrong runbook. [Set up tenant restrictions v2](https://learn.microsoft.com/en-us/entra/external-id/tenant-restrictions-v2)
- The policy is cloud-side; the device/proxy only carries the `sec-Restrict-Tenant-Access-Policy` pointer. A block that "shouldn't happen" is almost always a partner-policy decision, not a client fault.
- Signalling path decides protection depth: only the Windows client path gives data-plane protection (anonymous Teams/SharePoint links, token infiltration) for SPO/EXO. Proxy = auth plane only. [TRv2 overview — supported scenarios](https://learn.microsoft.com/en-us/entra/external-id/tenant-restrictions-v2#supported-scenarios)
- Firewall protection without an AppId tagging policy is an outage switch. [Policy CSP – TenantRestrictions](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-tenantrestrictions)
- For Macs and non-Windows, use [universal tenant restrictions in Global Secure Access](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-universal-tenant-restrictions) — free in plain Entra P1/P2 (see `EntraSuiteLicensing-A.md`).
- Migrating from v1? Follow [Plan a tenant restrictions v1 migration to v2](https://learn.microsoft.com/en-us/entra/external-id/tenant-restrictions-migration) — build partner policies first, remove headers second.
