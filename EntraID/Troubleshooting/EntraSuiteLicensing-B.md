# Microsoft Entra Suite & Global Secure Access Licensing — Hotfix Runbook (Mode B: Ops)
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

```powershell
Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All","AuditLog.Read.All"

# 1. What licenses/SKUs does the tenant actually hold?
Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId, ConsumedUnits, PrepaidUnits

# 2. Does a specific affected user have a P1/P2/Suite SKU assigned?
Get-MgUserLicenseDetail -UserId "<user-upn-or-id>" | Select-Object SkuPartNumber, ServicePlans

# 3. Is the user's failure a licensing gate, or an actual product configuration issue?
Get-MgBetaNetworkAccessForwardingProfile | Select-Object Name, State

# 4. Is this a guest user? (Guests bill/license completely differently — MAU-based, not seat-based)
Get-MgUser -UserId "<user-upn-or-id>" -Property UserType | Select-Object UserType
```

| Result | Interpretation |
|---|---|
| No `Microsoft Entra Suite`, `Microsoft Entra Internet Access`, or `Microsoft Entra Private Access` SKU anywhere in tenant | Tenant isn't licensed for GSA's Internet/Private Access capabilities at all — only the P1/P2-included Microsoft-traffic profile is available. Go to [Fix 1](#common-fix-paths). |
| SKU present tenant-wide, but the specific user has no service plan assigned | Per-user assignment gap, not a tenant licensing gap. Go to [Fix 2](#common-fix-paths). |
| User has a license, but a specific GSA feature (TLS inspection, Web Content Filtering, Quick Access) doesn't work | Feature-tier gap — that capability requires Internet Access or Private Access specifically, not just Entra ID P1/P2. Go to [Fix 3](#common-fix-paths). |
| Affected identity is `UserType = Guest` | Guest billing is Monthly Active User (MAU)-based and licensed completely differently from employee seats — a guest with no billable sign-in this month is not "unlicensed," they're simply not yet billed. Go to [Fix 4](#common-fix-paths). |
| Finance/procurement asking "why does the Suite cost what it does" or "should we buy Suite or the parts" | Not a technical fault — go straight to [Fix 5](#common-fix-paths) for the allocation framework. |
| Remote network / branch connectivity feature won't enable | Tenant is under the combined 50-license floor across Entra ID P1 + Entra Internet Access. Go to [Fix 6](#common-fix-paths). |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Entra ID P1 or P2 (mandatory base — Suite sits ON TOP of this, never replaces it)
  └── Microsoft Entra Internet Access for Microsoft services
        (Microsoft-traffic profile only — included FREE in plain P1/P2, no extra license)
  └── Microsoft Entra Suite license               OR    Standalone add-on licenses
        (bundles 5 capabilities at ~1 combined              (Internet Access license +
         price point, requires P1/P2 underneath)              Private Access license,
              ├── Identity Protection (P2-tier)                bought separately,
              ├── Identity Governance                          each ALSO requires
              ├── Verified ID Premium                          P1/P2 underneath)
              ├── Microsoft Entra Internet Access
              │     └── Internet/SWG traffic profile unlocked
              └── Microsoft Entra Private Access
                    └── Private/ZTNA traffic profile unlocked
                          └── Enterprise Applications can be
                              published for Private Access
        └── Per-user assignment (Suite or standalone SKU must be
              ASSIGNED to the specific user, tenant-level purchase
              alone does not activate anything for that user)
                └── Employee seats: standard per-user license consumption
                └── Guest seats: separate Monthly Active User (MAU) billing model,
                      NOT the same as employee per-seat assignment — first 50,000
                      MAU/month free ONLY for guests on P1/P2, that free tier does
                      NOT extend to GSA-for-guests or Governance-for-guests
        └── Remote network (branch connectivity) — requires a COMBINED total of
              at least 50 licenses across Entra ID P1 + Entra Internet Access
              before it can be enabled at all
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm what's actually purchased tenant-wide**
```powershell
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, @{N='Enabled';E={$_.PrepaidUnits.Enabled}}
```
Expected: a SKU string containing `ENTRA_SUITE` (or the current-year equivalent name), or separately `Entra Internet Access`/`Entra Private Access`/`Entra ID P1`/`Entra ID P2`. If none of these appear, no GSA capability beyond the P1/P2-included Microsoft-traffic profile exists in this tenant — full stop, regardless of any per-user configuration attempted.

**2. Confirm the specific affected user has the license assigned**
```powershell
Get-MgUserLicenseDetail -UserId "<upn>" | Select-Object SkuPartNumber
```
A tenant-wide purchase does not license any individual user automatically — assignment (direct or via a licensing group) is a separate step from procurement.

**3. Identify exactly which GSA capability is missing, then map it to the correct license tier**
Not every "not working" report is a licensing issue — cross-reference against the feature-tier table in `EntraSuiteLicensing-A.md`'s How It Works section before assuming a purchase is needed. The Microsoft-traffic profile, Universal Tenant Restrictions, Compliant Network check, and Source IP restoration are all included in plain P1/P2 — no Internet Access or Private Access license required for those specifically.

**4. Confirm user type before troubleshooting license assignment for an external identity**
```powershell
Get-MgUser -UserId "<upn>" -Property UserType,UserPrincipalName
```
`UserType = Guest` means standard per-seat license assignment logic does not apply — see Fix 4.

**5. If this is a cost/procurement question, not a technical fault, redirect accordingly**
Confirm with the requester whether the actual ask is "why won't this feature turn on" (technical, continue diagnosis) vs. "should we buy the Suite or the individual pieces" (commercial — go to Fix 5, which is a framework, not a script).

---
## Common Fix Paths

<details><summary>Fix 1 — No GSA-capable SKU in the tenant at all</summary>

```powershell
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits
```
If nothing resembling `ENTRA_SUITE`, `Entra Internet Access`, or `Entra Private Access` appears, the tenant is currently limited to what plain Entra ID P1/P2 already includes for free: the Microsoft-traffic forwarding profile only (direct Microsoft 365 service connectivity, Universal Tenant Restrictions, Compliant Network check, source IP restoration). Internet Access (SWG-style general internet/SaaS protection) and Private Access (ZTNA/VPN replacement) both require a license purchase — either the bundled Suite or the two standalone add-ons — before any configuration attempt in the Global Secure Access admin center will produce a working result for end users.

This is not fixable from PowerShell/Graph — it requires a licensing purchase decision. Escalate to whoever owns the Microsoft licensing relationship with the finding: "GSA Internet Access / Private Access requires a license this tenant does not currently hold; only the free P1/P2 Microsoft-traffic profile is available today."

**Rollback:** N/A — diagnostic only.

</details>

<details><summary>Fix 2 — Tenant holds the SKU, but the affected user has no assignment</summary>

```powershell
# Confirm current assignment
Get-MgUserLicenseDetail -UserId "<upn>"

# Assign directly (adjust SkuId to the tenant's actual Suite/Internet Access/Private Access SKU)
$skuId = (Get-MgSubscribedSku | Where-Object SkuPartNumber -like "*ENTRA_SUITE*").SkuId
Set-MgUserLicense -UserId "<upn>" -AddLicenses @{SkuId = $skuId} -RemoveLicenses @()
```
Prefer group-based licensing over direct per-user assignment for anything beyond a one-off fix — direct assignment doesn't scale and is easy to lose track of during offboarding.

**Rollback:** `Set-MgUserLicense -UserId "<upn>" -RemoveLicenses @($skuId) -AddLicenses @()` removes the assignment cleanly; the user reverts to whatever base license (if any) remains.

</details>

<details><summary>Fix 3 — User is licensed, but a specific capability is missing (feature-tier gap)</summary>

Cross-check the requested capability against license tier before assuming a bug:
- **Included in plain Entra ID P1/P2** (no Suite/standalone add-on needed): Microsoft-traffic forwarding profile, Universal Tenant Restrictions, Compliant Network Conditional Access check, source IP restoration, Microsoft 365 Enriched logs.
- **Requires Internet Access specifically** (Suite or standalone): Web Content Filtering, FQDN filtering, TLS inspection, threat intelligence, Data Loss Prevention (network layer), Shadow AI discovery, prompt-injection protection, network controls for agents (the last one additionally requires a Microsoft Agent 365 license).
- **Requires Private Access specifically** (Suite or standalone): Quick Access, per-app TCP/UDP access, App Discovery, Private DNS, Kerberos SSO across private apps, connector marketplace/multicloud support.

If the reported-missing capability is in a tier the user isn't licensed for, this is expected behavior, not a fault — route back to the licensing conversation (Fix 5) rather than continuing technical troubleshooting.

**Rollback:** N/A — diagnostic/clarification only.

</details>

<details><summary>Fix 4 — Guest user licensing confusion (MAU billing, not per-seat)</summary>

Guest users (`UserType = Guest`, the default for all B2B invitations) are billed under a **Monthly Active User (MAU)** model for Global Secure Access specifically — this is structurally different from the per-seat license assignment employees use.

Key facts to check before troubleshooting further:
- A guest is only billed when they actually sign in at least once in a given month to Microsoft Entra Private Access tunnels via the GSA client.
- The well-known "first 50,000 MAU free" allowance for external users applies to plain Entra ID P1/P2 external-identity billing — it does **not** extend to Global Secure Access for guests, and does **not** extend to Identity Governance for guests either. Both are billed as separate line items even within that free-MAU window.
- Guest billing applies uniformly to both internal guests (B2B collaboration within the same tenant family) and true external guests — there's no exemption for "internal" guest accounts.
- The resource tenant's Entra External ID subscription must be linked to an Azure subscription for billing/feature access to work correctly at all — an unlinked tenant can produce access failures that look like a licensing gap but are actually a billing-linkage gap.

```powershell
# Identify billable guest sign-ins via sign-in log filters
# (Portal: Entra ID > Monitoring & health > Sign-in logs)
# Filter: UserType = Guest, CrossTenantAccessType = B2B collaboration,
#         Application = Global Secure Access Client, ClientApp = Mobile Apps and Desktop clients
```

**Rollback:** N/A — this is a billing-model clarification, not a configuration change.

</details>

<details><summary>Fix 5 — Cost/procurement question: buy the Suite, or the standalone pieces?</summary>

This is not a technical fix — route the requester through this framework rather than guessing:

1. **The Suite always sits on top of an Entra ID P1 (minimum) base** — it is priced as an addition, never a replacement. Any cost comparison that omits the base P1/P2 license cost from the standalone-components total is comparing incorrectly.
2. **The Suite bundles five capabilities**: Identity Protection (P2-tier risk signals), Identity Governance, Verified ID Premium, Internet Access, and Private Access. In practice, the two components that most concretely justify taking the Suite over a plain identity base are Internet Access and Private Access — the secure network access layer.
3. **License by cohort, not blanket.** Independent licensing-advisory analysis (third-party, not Microsoft) covering multiple enterprise engagements found that typically only 30-60% of seats in a given tenant actually use the network-access features (Internet Access/Private Access) that justify the Suite's premium over a plain identity license — and that Identity Governance in particular is frequently purchased broadly but configured for a fraction of the licensed population. Treat this as directional guidance, not a guaranteed ratio for any specific tenant — always validate against actual GSA client sign-in and Access Review completion data for the tenant in question before committing to an allocation.
4. **If the tenant is evaluating a top-tier Microsoft 365 bundle that includes the full Entra Suite** (e.g., certain E7-class offers), remember that inclusion doesn't make the Suite "free" — seats that only need identity (not secure access or governance) are still effectively paying for capability inside the bundle price that they'll never use. Model the bundle against "base license + targeted Suite allocation for the cohort that needs it" before treating the inclusion as pure upside.
5. Pricing figures move — always confirm current per-user pricing at [Microsoft Entra Plans & Pricing](https://www.microsoft.com/en-us/security/business/microsoft-entra-pricing) rather than quoting a fixed number from memory or from this file, since Microsoft revises pricing periodically.

**Rollback:** N/A — advisory guidance.

</details>

<details><summary>Fix 6 — Remote network (branch connectivity) won't enable</summary>

```powershell
Get-MgSubscribedSku |
    Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM|ENTRA_INTERNET_ACCESS" } |
    Select-Object SkuPartNumber, @{N='Enabled';E={$_.PrepaidUnits.Enabled}}
```
Remote network / branch connectivity requires a **combined total of at least 50 licenses** across Entra ID P1 and Microsoft Entra Internet Access before the feature can be enabled at all — this is a fixed platform floor, not a per-branch or per-connector limit. A tenant under that combined threshold will find the feature unavailable regardless of how the licenses it does hold are configured.

**Rollback:** N/A — diagnostic only; the fix is acquiring additional licenses to cross the 50-license combined floor.

</details>

---
## Escalation Evidence

```
=== Entra Suite / Global Secure Access Licensing — Escalation Template ===

Affected user UPN:
UserType: [ ] Member  [ ] Guest
Tenant SKUs present (Get-MgSubscribedSku output):
User's assigned license(s) (Get-MgUserLicenseDetail output):
Reported-missing capability:
Capability's required tier (P1/P2 baseline / Internet Access / Private Access / Suite-only):
Is this a technical fault or a procurement/cost question:
Guest billing only — recent billable sign-in observed in sign-in logs (Y/N):
Guest billing only — External ID subscription linked to Azure subscription (Y/N):
Remote network only — combined P1 + Internet Access license count:
Steps already attempted:
```

---
## 🎓 Learning Pointers

- **The Suite is an addition to Entra ID P1/P2, never a replacement for it.** Every cost comparison, and every "why isn't this working" ticket, needs to start from confirming the P1/P2 base license is in place before looking at Suite/standalone add-ons. Reference: [Microsoft Entra Suite overview](https://learn.microsoft.com/en-us/entra/fundamentals/try-microsoft-entra-suite)
- **Tenant-level purchase and per-user assignment are two separate steps** — a tenant can hold hundreds of unused Suite/Internet Access/Private Access licenses while a specific reported user has none assigned. Always check both layers, not just one.
- **Guest licensing for Global Secure Access is Monthly Active User-based, not seat-based**, and the familiar "50,000 free external MAU" allowance from plain Entra ID P1/P2 external-identity billing does not extend to GSA or Governance for guests — this is a genuinely easy assumption to get wrong. Reference: [Global Secure Access licensing for guest users](https://learn.microsoft.com/en-us/entra/global-secure-access/reference-licensing-guest-users)
- **Feature availability maps to a specific tier, not just "has GSA license or not."** The Microsoft-traffic profile ships free in plain P1/P2; Internet Access and Private Access each unlock a distinct, non-overlapping set of capabilities documented in Microsoft's own feature comparison table — check the table before assuming a licensed user should have every GSA capability. Reference: [What is Global Secure Access — licensing overview](https://learn.microsoft.com/en-us/entra/global-secure-access/overview-what-is-global-secure-access#licensing-overview)
- **Remote network / branch connectivity has a fixed 50-combined-license floor** that's easy to miss during a small pilot — a proof-of-concept with a handful of test licenses will never be able to enable this specific feature no matter how it's configured.
- Pricing and bundle composition change over time — always verify current figures at the official pricing page rather than relying on a cached number, since Suite/standalone pricing and what's bundled into top-tier M365 offers both shift periodically.
