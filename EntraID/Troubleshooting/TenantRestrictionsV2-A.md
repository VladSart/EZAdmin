# Tenant Restrictions v2 (TRv2) — Reference Runbook (Mode A: Deep Dive)
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

**Covers:** Microsoft Entra tenant restrictions v2 in workforce tenants — the cloud policy object inside cross-tenant access settings, its default vs. partner structure, the three client signalling methods (Windows GPO/CSP, corporate proxy, Global Secure Access universal tenant restrictions), authentication-plane vs. data-plane enforcement, the App Control/firewall hardening for unenlightened apps, v1→v2 migration, and MSP operating patterns.

**Doesn't cover:** B2B collaboration / direct connect inbound-outbound policy (`CrossTenant-A.md`), GSA client deployment/health (`GlobalSecureAccess-A.md`, `Windows/Troubleshooting/GlobalSecureAccess-Windows-A.md`), App Control authoring in general (`Security/Defender/WDAC-A.md`).

**Assumes:** Entra ID P1/P2 in the enforcing tenant; the engineer can hold Security Administrator (Conditional Access Administrator also works for partner-level edits per Microsoft's doc); Microsoft Graph PowerShell SDK.

Sources live-fetched run 261: Learn "Set up tenant restrictions v2" (ms.date 2026-03-20, updated_at 2026-06-11) and Learn "Policy CSP – TenantRestrictions" (ms.date 2025-03-12). Several data-plane capabilities are still labelled **preview** in Microsoft's article; this runbook keeps that label wherever Microsoft does.

---
## How It Works

<details><summary>Full architecture</summary>

### The four quadrants of cross-tenant control

| Account used | App owned by | Controlled by |
|---|---|---|
| Your tenant's account | Your tenant | Conditional Access / normal authZ |
| External account | **Your** apps | Cross-tenant **inbound** settings |
| Your tenant's account | **External** apps | Cross-tenant **outbound** settings |
| **External** account (other tenant or MSA) | **External** apps | **Tenant restrictions** |

Tenant restrictions exist for the last row — a user on your device/network signing into *someone else's* tenant (a personal tenant, a competitor's, a malicious one, or a consumer MSA) and exfiltrating data there. Inbound/outbound settings and TRv2 are configured on the same blade but don't affect each other.

### Policy object

TRv2 lives inside the tenant's `crossTenantAccessPolicy`:

```
/policies/crossTenantAccessPolicy
├── /default                      ← has an `id` = the Policy ID used in every signal
│     └── tenantRestrictions
│           ├── usersAndGroups { accessType: allowed|blocked, targets:[AllUsers] }   (default can't scope to users)
│           └── applications   { accessType: allowed|blocked, targets:[AllApplications | appIds] }
└── /partners/{tenantId}          ← per-external-tenant override (incl. MSA tenant 9188040d-6c67-4c5b-b112-36a304b66dad)
      └── tenantRestrictions      (null = "Inherited from default")
            ├── usersAndGroups  { targets: AllUsers | specific external user/group object IDs }
            └── applications    { targets: AllApplications | specific appIds }
```

Two structural rules catch people:
- **Symmetry rule on "block all":** Microsoft's portal note — if you block *all users and groups* you must also block *all external applications*, and vice versa. You express "allow only X" as a *block* default plus *allow* partner entries.
- **MSA has no per-user scope.** For the Microsoft account tenant only application granularity exists (e.g. allow Microsoft Learn `18fbca16-2224-45f6-85b0-f7bf2b39b3f3`, Enterprise Skills Initiative `195e7f27-02f9-4045-9a91-cd2fa1c2af2f`).

Blocking the MSA tenant does **not** block device-originated traffic like Autopilot, Windows Update, or organisational data collection, nor B2B consumer-account passthrough authentication used by some Azure/Office.com apps.

### The signal

Entra only evaluates TRv2 when the request carries:

```
sec-Restrict-Tenant-Access-Policy: <enforcingTenantId>:<defaultPolicyId>
```

No header → no enforcement. That's why a perfectly-configured cloud policy can "do nothing": the signal isn't reaching Entra.

### The three signalling methods

```
                 ┌───────────────────────── Auth plane ─────────────────────────┐ ┌─ Data plane ──────────────┐
Windows GPO/CSP  │ enlightened apps: Edge, Office, UWP, Windows net stack        │ │ SPO, EXO, Graph, Teams,   │
 (Cloud Policy   │ NOT Chrome/Firefox/.NET unless AppId tagging + firewall        │ │ Forms/anon links (preview)│
  Details)       └───────────────────────────────────────────────────────────────┘ └───────────────────────────┘
Corporate proxy  │ everything that crosses the proxy, any OS/browser (TLS break) │   none
GSA universal TR │ any OS/browser/form factor, on-net or remote                  │   Microsoft Graph only
```

- **Windows GPO/CSP.** ADMX `TenantRestrictions.admx` → *Cloud Policy Details* (`trv2_payload`), stored under `HKLM\SOFTWARE\Policies\Microsoft\Windows\TenantRestrictions\Payload`; MDM path `./Device/Vendor/MSFT/Policy/Config/TenantRestrictions/ConfigureTenantRestrictions` (ADMX-backed, device scope, Pro/Enterprise/Education/IoT; Win10 2004–21H1 need KB5006738, Win10 21H2+, Win11 21H2+, Server build 20348.320+). Devices don't need to be Entra-joined — domain-joined GPO-managed devices work. This is the **only** path Microsoft documents as delivering data-plane protection for SharePoint/Exchange (anonymous-link blocking, token-infiltration defence). Microsoft still labels the Windows option "(preview)" in the article.
- **Corporate proxy.** Requires TLS inspection of `login.live.com`, `login.microsoft.com`, `login.microsoftonline.com`, `login.windows.net` — Microsoft explicitly supports decrypting those for header insertion as an exception to its no-inspection guidance. Auth plane only: anonymous Teams meeting join and "anyone" links are not blocked. ExpressRoute doesn't change this — it's layer 3 and doesn't inject anything.
- **Universal tenant restrictions (GSA).** The GSA client tags Microsoft traffic; no proxy, no TLS break. Auth plane everywhere, data plane only for Graph. Included in plain Entra P1/P2 via the Microsoft traffic profile.

### Data plane (preview) behaviour worth knowing

- **Teams:** with TRv2 client signalling, anonymous join to *externally hosted* meetings is blocked, and joining with an externally issued identity follows the TRv2 policy. Home-tenant members are unaffected by TRv2. Configure the policy on the **Office 365** app, because Teams depends on SPO/EXO.
- **SharePoint/OneDrive:** anyone-links for your own tenant still work; anyone-links to *another* tenant prompt for sign-in and are then evaluated. Consumer OneDrive (`onedrive.live.com`) is unconverged legacy stack and isn't covered — block it at the proxy if needed.
- **Forms:** anonymous access to externally hosted forms is blocked automatically when enforced.

### Service principals

TRv2 blocks service-principal sign-ins too when the request is signalled (proxy, or GPO with firewall protection + AppId tagging). The failure is `AADSTS5000211` and it's logged **only in the target tenant**, not in the enforcing tenant — a blind spot when an automation account breaks.

### v1 vs v2

v1 = proxy header allowlist (`Restrict-Access-To-Tenants` + `Restrict-Access-Context`, and `sec-Restrict-Tenant-Access-Policy: restrict-msa` to login.live.com), tenant-level only, header length limits the list. v2 = cloud policy, user/group/app granularity, portal UI, data plane options. Migration is one-time: create partner entries for each v1 allowlisted tenant, then swap headers; leaving `restrict-msa` in place conflicts with v2.
</details>

---
## Dependency Stack

```
Layer 6  Enforcement result: allow / AADSTS5000211 / sign-in prompt on anon link
Layer 5  Entra token service evaluates default + partner tenantRestrictions
Layer 4  Signal present on request: sec-Restrict-Tenant-Access-Policy: <tenantId>:<policyId>
           ├─ Windows client (Payload registry → net stack / enlightened apps)
           │    └─ optional: App Control AppIdTagging (M365ResourceAccessEnforcement) + firewall protection
           ├─ Proxy TLS inspection + header injection on 4 login domains
           └─ GSA client, Microsoft traffic profile, universal TR enabled
Layer 3  Correct IDs distributed (home tenant ID + DEFAULT policy id)
Layer 2  TRv2 default policy created; partner entries for allowed tenants/apps
Layer 1  Entra ID P1/P2; Security Administrator (or CA Administrator for partner edits)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `AADSTS5000211` for a legitimate partner app | No partner entry / partner entry doesn't list the app or user | Organizational settings → Tenant restrictions column |
| Policy configured, nothing ever blocked | No signal: GPO not applied, wrong IDs, or proxy not inspecting | `HKLM:\...\TenantRestrictions\Payload`; proxy config |
| Blocked in Edge, works in Chrome | Chrome isn't enlightened | Expected; Playbook 4 |
| Anonymous Teams join still possible | Signalling via proxy only (auth plane) | Move to Windows client or accept gap |
| Anyone-link to another tenant's SPO opens anonymously | Proxy/GSA path, or device not covered | Windows client path required for SPO data plane |
| Users can't reach Microsoft Learn / partner training | MSA tenant blocked by default | Partner entry for MSA tenant with app allow |
| Automation account in a customer tenant starts failing | SP sign-in signalled & blocked; log is in the *target* tenant | Target tenant sign-in logs, service principal tab |
| Entra admin center shows "Access denied" | Known issue | `?feature.msaljs=true&exp.msaljsexp=true` |
| Macs lose Platform SSO after proxy TRv2 | Apple rejects non-Apple-root intercept certs | Use GSA universal TR for Macs |
| Some tenants blocked after v1→v2 cutover | Allowlisted v1 tenants not recreated as partners | Diff v1 header list vs `/partners` |
| Everything to Microsoft endpoints broken after enabling firewall option | Firewall protection enabled without AppId tagging policy | Untick firewall option, restart |
| Cross-cloud (e.g. commercial ↔ GCC High) resources unreachable with GPO | Documented: TRv2 blocks cross-cloud at data plane | Known limitation |

---
## Validation Steps

1. **Cloud policy exists and has the expected default.**
   ```powershell
   Connect-MgGraph -Scopes 'Policy.Read.All'
   $d = Invoke-MgGraphRequest GET 'https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/default'
   $d.id; $d.tenantRestrictions.usersAndGroups.accessType; $d.tenantRestrictions.applications.accessType
   ```
   Good: an `id` GUID, both access types set (typically `blocked`). Bad: `tenantRestrictions` null/empty → no policy ever created.

2. **Partner overrides are intentional.**
   ```powershell
   (Invoke-MgGraphRequest GET 'https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners').value |
     Where-Object tenantRestrictions | ForEach-Object { '{0}  users:{1}  apps:{2}' -f $_.tenantId, $_.tenantRestrictions.usersAndGroups.accessType, $_.tenantRestrictions.applications.accessType }
   ```
   Good: every line maps to a documented business need. Bad: `AllUsers`+`AllApplications` allowed for a tenant nobody recognises.

3. **Windows device carries the right pointer.**
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TenantRestrictions\Payload' | Format-List *
   ```
   Good: values contain your tenant ID and the step-1 `id`. Bad: key missing or other IDs.

4. **Client is logging.**
   ```powershell
   Get-WinEvent -LogName 'Microsoft-Windows-TenantRestrictions/Operational' -MaxEvents 10
   ```
   Good: events present after sign-in attempts. Bad: log absent/empty on a covered device.

5. **Negative test.** From a covered device, in Edge, sign into a throwaway external tenant not on the allowlist. Good: `AADSTS5000211`. Bad: sign-in succeeds → signal isn't arriving.

6. **Proxy path (if used).** Confirm the proxy injects only the v2 header to the four login domains and has removed v1 headers. Good: single `sec-Restrict-Tenant-Access-Policy: <tenant>:<policy>` header. Bad: `restrict-msa` or `Restrict-Access-To-Tenants` still present.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Classify the complaint.** "Blocked when I shouldn't be" → policy content (Layer 2/5). "Not blocked when I should be" → signal (Layer 3/4) or path capability. Don't touch clients for a policy-content problem.

**Phase 2 — Identify identity and app.** Get the UPN (home vs external), the target tenant, the app ID (from the error page's correlation details or the resource tenant's sign-in log). Match against partner entries.

**Phase 3 — Identify the signalling path(s).** Many MSP customers run two (GPO for Windows + GSA for Macs). Each device's behaviour is determined by *its* path.

**Phase 4 — Validate IDs end-to-end.** The single most common deployment error is using the partner-level Policy ID shown on a partner's pane rather than the default policy `id` (Microsoft's proxy guidance: take `id` from `/crossTenantAccessPolicy/default`).

**Phase 5 — Check capability gaps before calling it a bug.** Chrome/Firefox/.NET on Windows client path; anonymous links on proxy path; non-Graph data plane on GSA path; consumer OneDrive; cross-cloud.

**Phase 6 — Service principals and automation.** If only scripted/app access broke, check the target tenant's service-principal sign-ins and whether the automation host is behind the TRv2 proxy.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield "block by default, allow what's needed"</summary>

1. Inventory required external tenants (vendors, parent company, training portals) and MSA apps.
2. Create the default policy (portal: Default settings → Edit tenant restrictions defaults → Create policy); set Users & groups = **Block**, External applications = **Block**, All external applications.
3. Add partner entries with the narrowest scope that works (specific groups + apps).
4. Pilot the Windows client policy on an IT group; watch `TenantRestrictions/Operational` and helpdesk tickets for 1–2 weeks.
5. Expand; add GSA universal TR for macOS/mobile if licensed/needed.

Rollback: unassign the client policy (GPO/Intune) — enforcement stops immediately for those devices because the signal disappears; the cloud policy can stay.
</details>

<details><summary>Playbook 2 — Migrate from v1 proxy headers</summary>

1. Export the current `Restrict-Access-To-Tenants` list from the proxy.
2. For each tenant, add a partner entry (Allow, ideally scoped).
3. If v1 used `restrict-msa`, add an MSA partner entry allowing only required apps.
4. Change the proxy: remove all v1 headers, add `sec-Restrict-Tenant-Access-Policy: <tenantId>:<defaultPolicyId>` to the four login domains.
5. Optionally add Windows client signalling to gain data-plane protection.

Rollback: restore the v1 header set on the proxy (keep a config export). v1 and v2 headers must not coexist.
</details>

<details><summary>Playbook 3 — Allow a partner tenant via Graph (scriptable for many customers)</summary>

```powershell
Connect-MgGraph -Scopes 'Policy.ReadWrite.CrossTenantAccess'
$partner = '<partnerTenantId>'
# Create partner entry if it doesn't exist
$exists = $null
try { $exists = Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partner" } catch {}
if (-not $exists) {
  Invoke-MgGraphRequest POST 'https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners' -Body (@{ tenantId = $partner } | ConvertTo-Json) -ContentType 'application/json'
}
$body = @{ tenantRestrictions = @{
  usersAndGroups = @{ accessType='allowed'; targets=@(@{ target='AllUsers'; targetType='user' }) }
  applications   = @{ accessType='allowed'; targets=@(@{ target='AllApplications'; targetType='application' }) } } } | ConvertTo-Json -Depth 6
Invoke-MgGraphRequest PATCH "https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners/$partner" -Body $body -ContentType 'application/json'
```
Rollback: `PATCH` with `@{ tenantRestrictions = $null }`, or `DELETE .../partners/$partner` if the entry exists only for TRv2 (⚠️ deleting also removes any inbound/outbound B2B customisation on that partner — check first).
</details>

<details><summary>Playbook 4 — Harden against unenlightened apps (App Control AppId tagging + firewall)</summary>

1. Build an App Control base policy (App Control Policy Wizard; template **Default Windows** or **Allow Microsoft**) listing the apps allowed to reach Microsoft resources.
2. Convert to a tagging policy:
   ```powershell
   Set-CIPolicyIdInfo -ResetPolicyID .\policy.xml -AppIdTaggingPolicy -AppIdTaggingKey 'M365ResourceAccessEnforcement' -AppIdTaggingValue 'True'
   ConvertFrom-CIPolicy .\policy.xml ".\{<PolicyID>}.cip"
   ```
3. Deploy the `.cip` to pilot devices (`C:\Windows\System32\CodeIntegrity\CiPolicies\Active\`) and refresh (RefreshPolicy tool or restart).
4. **Only then** tick *Enable firewall protection of Microsoft endpoints* in Cloud Policy Details, `gpupdate /force`, restart.
5. Test: Chrome to office.com should show Microsoft's "internet access is blocked" page; PowerShell `Connect-MgGraph` behaves per policy.

Rollback order: firewall option off → restart → remove `.cip` → refresh. Reversing the order can strand the device without Microsoft connectivity.
</details>

<details><summary>Playbook 5 — MSP technician access when customers enforce TRv2</summary>

MSP engineers signing into customer tenants from **customer-managed** devices use an external identity (the MSP tenant) → TRv2 applies. Options: add a partner entry for the MSP tenant scoped to the technicians' group and admin apps, or use MSP-owned devices/networks outside the customer's signalling. GDAP access itself is unaffected by TRv2 unless the technician's device/network signals the customer policy. The reverse also holds: an MSP enforcing TRv2 on its own fleet must add partner entries for any customer tenant where technicians use *customer-issued* accounts.
</details>

---
## Evidence Pack

```powershell
<#  TRv2 evidence pack — run elevated on an affected Windows device; Graph section optional.  #>
$out = Join-Path $env:TEMP ("TRv2-Evidence-{0:yyyyMMdd-HHmm}" -f (Get-Date))
New-Item -ItemType Directory -Path $out -Force | Out-Null

cmd /c ver                                            > "$out\os.txt"
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
  Select-Object ProductName, DisplayVersion, CurrentBuild, UBR     | Out-File "$out\os.txt" -Append
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TenantRestrictions\Payload' -ErrorAction SilentlyContinue |
  Format-List * | Out-File "$out\trv2-payload.txt"
Get-WinEvent -LogName 'Microsoft-Windows-TenantRestrictions/Operational' -MaxEvents 200 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\trv2-events.csv" -NoTypeInformation
netsh winhttp show proxy                               > "$out\winhttp-proxy.txt"
dsregcmd /status                                       > "$out\dsregcmd.txt"
Get-ChildItem 'C:\Windows\System32\CodeIntegrity\CiPolicies\Active' -ErrorAction SilentlyContinue |
  Select-Object Name, Length, LastWriteTime | Export-Csv "$out\ci-active-policies.csv" -NoTypeInformation

if (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue) {
  try {
    Invoke-MgGraphRequest GET 'https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/default' |
      ConvertTo-Json -Depth 8 | Out-File "$out\cta-default.json"
    (Invoke-MgGraphRequest GET 'https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners').value |
      ConvertTo-Json -Depth 8 | Out-File "$out\cta-partners.json"
  } catch { "Graph not connected: $($_.Exception.Message)" | Out-File "$out\graph-error.txt" }
}
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Default TRv2 policy + id | `Invoke-MgGraphRequest GET https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/default` |
| All partner entries | `Invoke-MgGraphRequest GET https://graph.microsoft.com/beta/policies/crossTenantAccessPolicy/partners` |
| One partner (MSA) | `.../partners/9188040d-6c67-4c5b-b112-36a304b66dad` |
| Reset defaults (⚠️ also resets inbound/outbound defaults) | `Invoke-MgGraphRequest POST .../crossTenantAccessPolicy/default/resetToSystemDefault` |
| Device payload | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\TenantRestrictions\Payload` |
| Client events | `Get-WinEvent -LogName Microsoft-Windows-TenantRestrictions/Operational -MaxEvents 50` |
| Refresh GPO | `gpupdate /force` |
| Active CI policies | `Get-ChildItem C:\Windows\System32\CodeIntegrity\CiPolicies\Active` |
| Tag an App Control policy | `Set-CIPolicyIdInfo -ResetPolicyID .\policy.xml -AppIdTaggingPolicy -AppIdTaggingKey M365ResourceAccessEnforcement -AppIdTaggingValue True` |
| Compile policy | `ConvertFrom-CIPolicy .\policy.xml ".\{<PolicyID>}.cip"` |
| WinHTTP proxy | `netsh winhttp show proxy` |
| Proxy header (v2) | `sec-Restrict-Tenant-Access-Policy: <tenantId>:<defaultPolicyId>` |
| Admin center workaround | `https://entra.microsoft.com/?feature.msaljs=true&exp.msaljsexp=true#home` |
| Fleet audit script | `EntraID/Scripts/Get-TenantRestrictionsV2Audit.ps1` |

---
## 🎓 Learning Pointers
- Know which quadrant you're in: TRv2 is the only control for *external identity → external app*. [Tenant restrictions vs. inbound and outbound settings](https://learn.microsoft.com/en-us/entra/external-id/tenant-restrictions-v2#tenant-restrictions-vs-inbound-and-outbound-settings)
- Protection depth is a property of the signalling path, not the policy. Pick paths per platform deliberately: Windows client for data plane, GSA for Macs/mobile, proxy as a catch-all auth-plane net.
- Unenlightened apps are the real bypass on Windows. Read [App Control AppId tagging policies](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/appidtagging/design-create-appid-tagging-policies) before ticking the firewall box.
- Service-principal blocks log in the *other* tenant — include that in any MSP automation runbook that runs from customer networks.
- The MSA tenant ID `9188040d-6c67-4c5b-b112-36a304b66dad` and the app-only granularity for consumer accounts are worth memorising; most "why can't users reach Learn" tickets are this.
- For Macs: [Universal tenant restrictions tutorial](https://learn.microsoft.com/en-us/entra/global-secure-access/tutorial-microsoft-traffic-tenant-restrictions); for migration: [v1 → v2 migration plan](https://learn.microsoft.com/en-us/entra/external-id/tenant-restrictions-migration).
