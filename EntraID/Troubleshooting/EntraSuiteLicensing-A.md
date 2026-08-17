# Microsoft Entra Suite & Global Secure Access Licensing — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Microsoft Entra Suite and Global Secure Access (GSA) licensing** — what each license tier actually unlocks, how per-user and per-guest billing models differ, the platform-level constraints that gate specific features, and the cost-allocation questions an MSP is regularly asked when a client is deciding whether to buy the Suite, the standalone add-ons, or neither.

Covers: the P1/P2-plus-Suite licensing stack, the standalone Internet Access/Private Access add-on model, the guest Monthly Active User (MAU) billing model, the feature-to-tier mapping, the remote-network combined-license floor, and a cohort-based allocation framework for advising clients on Suite vs. standalone vs. do-nothing.

**Assumes:**
- Microsoft Graph PowerShell SDK, with `User.Read.All`, `Organization.Read.All`, and (for the beta GSA cmdlets) `NetworkAccess.Read.All` scopes as needed
- Familiarity with the technical GSA client/connector architecture documented separately in `GlobalSecureAccess-A.md`/`-B.md` — this file focuses on licensing and cost, not client troubleshooting
- Pricing figures cited here reflect publicly available guidance as of this file's last update and are illustrative — always verify current pricing at Microsoft's official pricing page before using any number in a client-facing conversation

**Not covered:** GSA client installation, traffic forwarding profile technical configuration, Private Access connector deployment/troubleshooting, or Conditional Access Compliant Network policy design (all covered in `GlobalSecureAccess-A.md`/`-B.md` — this file is licensing/cost only, cross-reference that file for "why isn't the tunnel working" once licensing is confirmed correct), Microsoft 365 E7/enterprise-bundle-wide licensing economics beyond the specific point that the bundle carries the full Entra Suite, general Entra ID P1/P2 feature comparison outside its role as the Suite's mandatory base, and Defender for Cloud Apps CASB licensing (a related but separately licensed product in Microsoft's SSE story, not part of GSA/Suite itself).

---
## How It Works

<details><summary>Full architecture</summary>

### The licensing stack, bottom to top

Microsoft Entra Global Secure Access is not a single license — it's a set of capabilities gated across three distinct layers, and understanding which layer a given feature sits in is the single most useful skill for triaging a "why won't this turn on" ticket:

1. **Entra ID P1 or P2 — the mandatory base.** Every GSA capability, including the Suite itself, requires at least a P1 license underneath. P1/P2 alone (no additional purchase) already includes **Microsoft Entra Internet Access for Microsoft services** — the "Microsoft traffic profile" that provides direct, optimized connectivity to Microsoft 365 services, Universal Tenant Restrictions, the Compliant Network Conditional Access check, and source IP restoration for sign-in logs. This is the free tier most tenants already have without realizing it.

2. **Microsoft Entra Internet Access (full) and Microsoft Entra Private Access — the two GSA products proper.** These unlock general internet/SaaS SWG-style protection (Internet Access) and ZTNA-style private-app publishing (Private Access) respectively. Both are available **either bundled inside Microsoft Entra Suite, or purchased standalone** as individual add-ons on top of the P1/P2 base.

3. **Microsoft Entra Suite — the bundle.** Layers five capabilities on the P1/P2 base at a single combined price point: Identity Protection (P2-tier risk signals), Identity Governance, Verified ID Premium, Internet Access, and Private Access. The Suite is priced to undercut buying the same components individually — third-party licensing-advisory analysis has placed the gap at roughly 30-40% below assembling the parts separately, though exact figures move and should always be confirmed against current official pricing.

### Why the bundle discount doesn't automatically mean "buy it for everyone"

The Suite's discount is real and verifiable against list pricing for the individual components. The buyer-side question independent licensing analysts consistently raise is narrower: **who in the tenant actually uses the components that create the value.** Internet Access and Private Access — the secure network access layer — are the components most frequently cited as the actual value driver over a plain identity base; Identity Governance is commonly purchased broadly across a tenant but configured/used for only a fraction of the licensed population in practice. This isn't a Microsoft-published statistic — it's a pattern independent licensing advisory firms report across multiple client engagements — but it's directionally consistent with a simple mechanism: bundle pricing makes it cheap to over-license by default, and nothing in the purchasing process forces a cohort-level allocation decision the way per-component purchasing would.

The practical implication for an MSP advising a client: **license the P1/P2 identity base broadly (most users need it), and license the full Suite narrowly** — to the specific cohort that will actually use Internet Access, Private Access, or Governance features — rather than defaulting the Suite to every seat because the bundle math looks favorable in aggregate.

### The employee vs. guest licensing split — two entirely different models

This is the most consequential technical-licensing distinction in the whole topic, and it's easy to get backwards:

- **Employee (Member) users** consume GSA/Suite licenses the same way they consume any other Microsoft 365 seat-based license: assigned directly or via a licensing group, consumed as long as the assignment exists, independent of actual usage.
- **Guest users** (`userType = Guest`, the default for every B2B invitation method) are billed under a **Monthly Active User (MAU)** model specifically for Global Secure Access — a guest is only billed in a given month if they actually initiate at least one sign-in to Private Access tunnels via the GSA client that month. No sign-in, no billing, regardless of whether a "license" was ever formally assigned in the traditional sense.

A frequently-misunderstood detail: Entra ID P1/P2 has a well-known **first-50,000-external-users-free** MAU allowance for basic external-identity billing. That allowance **does not extend to Global Secure Access for guests, and does not extend to Identity Governance for guests either** — both are billed as separate line items even for guest populations still inside that free-50,000 window on the base external-identity product. A tenant that assumes "we're under the 50K free guest tier, so GSA is free for our guests too" will be surprised by the bill.

Guest billing also applies uniformly whether the guest is a true external partner or an "internal guest" object created for some other reason — there's no exemption based on where the guest's home organization sits. Billing requires the resource tenant's Entra External ID subscription to be linked to an Azure subscription; an unlinked tenant can produce access or billing-validation failures that look unrelated to licensing at first glance.

### Feature-to-tier mapping — what each layer actually unlocks

| Capability | P1/P2 base only | + Internet Access | + Private Access |
|---|---|---|---|
| Windows/macOS/mobile GSA client | ✅ | ✅ | ✅ |
| Traffic logs | ✅ | ✅ | ✅ |
| Remote network (branch connectivity)† | ✅ | ✅ | — |
| Direct Microsoft services connectivity | ✅ | — | — |
| Universal Tenant Restrictions | ✅ | — | — |
| Compliant Network Conditional Access check | ✅ | — | — |
| Source IP restoration (sign-in logs) | ✅ | — | — |
| Microsoft 365 Enriched logs | ✅ | — | — |
| Universal Conditional Access | ✅ | ✅ | — |
| Universal Continuous Access Evaluation | ✅ | ✅ | ✅ |
| Context-aware network security / SWG filtering | — | ✅ | — |
| Web category / FQDN filtering | — | ✅ | — |
| TLS inspection | — | ✅ | — |
| Threat intelligence | — | ✅ | — |
| Prompt injection protection | — | ✅ | — |
| Data Loss Prevention (network layer) | — | ✅ | — |
| Shadow AI discovery | — | ✅ | — |
| Network controls for agents†† | — | ✅ | — |
| VPN replacement (ZTNA) | — | — | ✅ |
| Quick Access | — | — | ✅ |
| Per-app TCP/UDP access | — | — | ✅ |
| App Discovery | — | — | ✅ |
| Private DNS | — | — | ✅ |
| Single sign-on across private apps (Kerberos SSO) | — | — | ✅ |
| Connector marketplace / multicloud support | — | — | ✅ |

† Remote network requires a **combined total of at least 50 licenses** across Entra ID P1 and Entra Internet Access before it can be enabled — a hard platform floor, not a per-connection limit.
†† Requires an additional Microsoft Agent 365 license on top of Internet Access.

Internet Access and Private Access capabilities are each available **either inside Microsoft Entra Suite, or as standalone add-on licenses** on top of P1/P2 — the Suite is a bundling/pricing convenience, not the only way to acquire either product.

### The top-tier M365 bundle trap

Certain top-tier Microsoft 365 enterprise offers (e.g., higher E-suite tiers) include the complete Microsoft Entra Suite as part of the bundle. This is genuinely valuable for organizations that were going to buy the Suite anyway — but it creates a specific cost-allocation blind spot: **seats that only need identity (P1/P2-level capability) are paying, inside that bundle's price, for Internet Access/Private Access/Governance capability they will never use.** The correct cost comparison for evaluating such a bundle is never "bundle price vs. Suite price alone" — it's "bundle price vs. (base identity license × total seats) + (targeted Suite allocation × the cohort that actually needs it)."

</details>

---
## Dependency Stack

```
Entra ID tenant
  └── Entra ID P1 or P2 assigned to the user (mandatory base for ANY GSA capability)
        ├── FREE, included automatically: Entra Internet Access for Microsoft services
        │     (Microsoft-traffic profile — direct M365 connectivity, Universal Tenant
        │      Restrictions, Compliant Network CA check, source IP restoration)
        └── Additional license required for the two GSA products proper:
              ├── Path A: Microsoft Entra Suite (bundles both products + Governance +
              │     Identity Protection + Verified ID Premium at one price point)
              └── Path B: Standalone Internet Access license + standalone
                    Private Access license (bought separately, each still
                    requires the P1/P2 base — no discount vs. Path A)
                          └── Per-user assignment (direct or group-based)
                                ├── Employee (Member): standard seat-based consumption
                                └── Guest: Monthly Active User (MAU) billing —
                                      only billed on an actual billable sign-in month;
                                      free-50K-external-MAU allowance does NOT apply
                                      to GSA-for-guests or Governance-for-guests
                                      └── Requires: resource tenant's Entra External ID
                                            subscription linked to an Azure subscription
        └── Remote network (branch connectivity) — requires combined P1 + Internet
              Access license count ≥ 50 across the tenant before it activates at all
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| GSA client installs but Internet Access filtering does nothing | Tenant/user has no Internet Access license (Suite or standalone) — only the free P1/P2 Microsoft-traffic profile is active | `Get-MgSubscribedSku`, `Get-MgUserLicenseDetail` |
| Private Access app publishing option missing/greyed out in admin center | No Private Access license present tenant-wide | `Get-MgSubscribedSku` |
| Feature works for some users, not others, same tenant | Per-user license assignment gap — tenant purchase exists but isn't assigned to the affected user(s) | `Get-MgUserLicenseDetail` per user |
| Guest user complains GSA access "stopped working" mid-month with no config change | Expected MAU billing behavior only if a payment/subscription-linkage issue exists — otherwise check sign-in logs for actual usage pattern, not a licensing symptom by default | Sign-in logs filtered to `UserType=Guest` + `Application=Global Secure Access Client` |
| Org assumed guests were "free" under the 50K external MAU allowance, then got billed | The 50K free allowance is scoped to base external-identity billing only, not GSA-for-guests or Governance-for-guests | Review the tenant's Entra External ID billing detail directly |
| Compliant Network Conditional Access check works, but Web Content Filtering doesn't | Compliant Network is a P1/P2-included capability; Web Content Filtering requires Internet Access specifically — two different tiers | Feature-to-tier mapping table above |
| Remote network / branch connectivity option unavailable | Combined P1 + Internet Access license count under the 50-license floor | `Get-MgSubscribedSku`, sum enabled units across both SKUs |
| Client asks "is Suite worth it for us" with no clear answer | Missing usage data — cohort-level Internet Access/Private Access/Governance actual-use rate not yet measured | See Remediation Playbook 2 |
| Top-tier M365 bundle quote includes Suite, client assumes it's "free" | Bundle pricing embeds Suite cost across all seats regardless of individual need | Model bundle vs. base+targeted-Suite allocation (Playbook 2) |
| Access reviews/governance features enabled tenant-wide but nobody uses them | Common over-licensing pattern per independent licensing-advisory findings — Governance bought broadly, configured narrowly | Cross-reference Access Review completion rates against Suite-licensed population |

---
## Validation Steps

**1. Enumerate every subscribed SKU in the tenant**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId, ConsumedUnits, @{N='Enabled';E={$_.PrepaidUnits.Enabled}}
```
Expected: identify whether the tenant holds a Suite SKU, standalone Internet Access/Private Access SKUs, or neither beyond plain P1/P2.

**2. Confirm the P1/P2 base is actually present** (mandatory prerequisite for everything else)
```powershell
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM" } | Select-Object SkuPartNumber, ConsumedUnits
```
Expected: `AAD_PREMIUM` (P1) or `AAD_PREMIUM_P2` present. If absent, no GSA capability can exist in this tenant regardless of any other license held.

**3. Confirm per-user license assignment for the specific affected identity**
```powershell
Connect-MgGraph -Scopes "User.Read.All"
Get-MgUserLicenseDetail -UserId "<upn>" | Select-Object SkuPartNumber, ServicePlans
```
Expected: the relevant SKU appears in the user's assigned licenses, and the specific `ServicePlans` entry for the reported-missing capability shows `ProvisioningStatus = Success`.

**4. Confirm user type before applying employee-style licensing logic**
```powershell
Get-MgUser -UserId "<upn>" -Property UserType | Select-Object UserType
```
Expected: `Member` for standard per-seat logic, `Guest` for MAU-based GSA billing logic — apply the correct model before troubleshooting further.

**5. For a guest-billing question, pull actual billable sign-in activity rather than assuming from license state alone**
Portal path: **Entra ID > Monitoring & health > Sign-in logs**, filtered to `User type = Guest`, `Cross tenant access type = B2B collaboration`, `Application = Global Secure Access Client`, `Client app = Mobile Apps and Desktop clients`. This is the closest available proxy for confirming what will actually be billed for a given guest in a given month.

**6. Confirm remote network's combined-license floor if that specific feature is the concern**
```powershell
$p1p2 = (Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM" } | Measure-Object -Property {$_.PrepaidUnits.Enabled} -Sum).Sum
$ia   = (Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "ENTRA_INTERNET_ACCESS" } | Measure-Object -Property {$_.PrepaidUnits.Enabled} -Sum).Sum
Write-Host "Combined P1/P2 + Internet Access licenses: $($p1p2 + $ia) (feature requires >= 50)"
```

---
## Troubleshooting Steps (by phase)

### Phase 1 — Confirm Base Licensing

1. Confirm P1/P2 is present tenant-wide — nothing else matters if this is missing.
2. Confirm whether the tenant holds Suite, standalone add-ons, or neither.

### Phase 2 — Confirm Assignment

1. Confirm the specific affected user (or licensing group they belong to) has the relevant SKU assigned.
2. Confirm `ServicePlans` provisioning status shows `Success`, not `Disabled` or `PendingActivation`.

### Phase 3 — Confirm Feature-to-Tier Mapping

1. Identify exactly which capability is reported missing.
2. Cross-reference against the feature-to-tier table in How It Works — confirm the user's actual license tier includes that specific capability before assuming a fault.

### Phase 4 — Guest-Specific Path (if applicable)

1. Confirm `UserType` first — do not apply employee per-seat logic to a guest identity.
2. Confirm the tenant's Entra External ID subscription is linked to an Azure subscription.
3. Pull actual billable sign-in activity from sign-in logs rather than inferring from license assignment state, since guest billing is usage-driven, not assignment-driven.

### Phase 5 — Cost/Allocation Advisory (non-technical escalations)

1. Clarify whether the actual ask is technical (something won't turn on) or commercial (should we buy this).
2. For commercial questions, move to Remediation Playbook 2 rather than continuing technical diagnosis.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Bulk-audit a tenant's GSA/Suite license utilization</summary>

Use when a client asks "are we actually using what we're paying for" or before a renewal/negotiation conversation.

```powershell
Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All","AuditLog.Read.All"

# Step 1: Inventory SKUs and consumption
$skus = Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId, ConsumedUnits, @{N='Enabled';E={$_.PrepaidUnits.Enabled}}
$skus | Format-Table -AutoSize

# Step 2: Identify which users hold a Suite/Internet Access/Private Access SKU
$suiteSkuId = ($skus | Where-Object SkuPartNumber -match "ENTRA_SUITE").SkuId
$licensedUsers = Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,UserType,AssignedLicenses |
    Where-Object { $_.AssignedLicenses.SkuId -contains $suiteSkuId }

# Step 3: Cross-reference against actual GSA sign-in activity (requires AuditLog.Read.All)
# Pull recent sign-ins to the Global Secure Access Client application and compare the
# distinct set of active users against the full licensed population from Step 2 —
# the delta is the "licensed but not using it" cohort driving over-spend.
```
This produces the raw data needed to answer "what % of our Suite-licensed seats are actually touching Internet Access/Private Access this month" — the exact question independent licensing-advisory practice flags as the one that matters most for right-sizing a Suite purchase.

**Rollback:** N/A — read-only audit.

</details>

<details><summary>Playbook 2 — Cohort-based Suite vs. standalone vs. base-only allocation model</summary>

Use when advising a client on whether to buy the Suite broadly, narrowly, or not at all.

1. **Segment the user population into three cohorts:**
   - Cohort A: needs identity only (no secure network access, no governance workflows) — license P1/P2 only.
   - Cohort B: needs secure network access (remote workers needing Private Access ZTNA, or users needing Internet Access SWG filtering) and/or active governance participation (access review owners, entitlement management approvers) — license the full Suite (or standalone add-ons if Governance/Verified ID aren't needed).
   - Cohort C: uncertain / mixed signal — pilot with a standalone add-on license first rather than defaulting to Suite, to gather real usage data before committing to the bundle at scale.

2. **Price both paths for the actual cohort sizes** — Suite-for-Cohort-B-only + P1/P2-for-everyone-else, versus a single blanket Suite-for-everyone number. The savings almost always sit in not over-licensing Cohort A, not in the Suite's own bundle discount (which is real but secondary to the allocation question).

3. **If evaluating a top-tier M365 bundle that includes the Suite**, run the same cohort math against "bundle price × all seats" vs. "base license × Cohort A + bundle price (or targeted Suite) × Cohort B" before treating the bundled Suite as pure upside.

4. **Revisit the allocation periodically**, not just at initial purchase — cohort membership shifts as roles change, and a Suite purchase that was well-targeted at rollout can drift into blanket over-licensing over time without a periodic re-check.

**Rollback:** N/A — this is an advisory framework, not a configuration change; any resulting license reassignment follows the same add/remove pattern shown in `EntraSuiteLicensing-B.md` Fix 2.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Entra Suite / Global Secure Access licensing evidence for a cost/allocation review or escalation
.NOTES     Requires User.Read.All, Organization.Read.All (AuditLog.Read.All optional, for usage cross-reference)
#>
param([string]$UserPrincipalName = "")

Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All"

$outputPath = "C:\EntraSuiteLicensing_Evidence_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# Tenant-wide SKU inventory
Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId, ConsumedUnits, @{N='Enabled';E={$_.PrepaidUnits.Enabled}} |
    Export-Csv "$outputPath\tenant-skus.csv" -NoTypeInformation

# Per-user license assignment for a specific affected user (optional)
if ($UserPrincipalName -ne "") {
    Get-MgUserLicenseDetail -UserId $UserPrincipalName |
        Select-Object SkuPartNumber, ServicePlans |
        Export-Csv "$outputPath\user_license_detail.csv" -NoTypeInformation
}

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# All subscribed SKUs and consumption
Get-MgSubscribedSku | Select SkuPartNumber,ConsumedUnits,@{N='Enabled';E={$_.PrepaidUnits.Enabled}}

# Confirm P1/P2 base present
Get-MgSubscribedSku | Where-Object SkuPartNumber -match "AAD_PREMIUM"

# Per-user license detail
Get-MgUserLicenseDetail -UserId "<upn>"

# Assign a SKU to a user
Set-MgUserLicense -UserId "<upn>" -AddLicenses @{SkuId="<sku-id>"} -RemoveLicenses @()

# Remove a SKU from a user
Set-MgUserLicense -UserId "<upn>" -AddLicenses @() -RemoveLicenses @("<sku-id>")

# Confirm user type (Member vs. Guest — different GSA billing model)
Get-MgUser -UserId "<upn>" -Property UserType

# GSA forwarding profile state (technical cross-check, not licensing)
Get-MgBetaNetworkAccessForwardingProfile | Select Name,State

# Combined P1/P2 + Internet Access license count (remote network 50-license floor)
(Get-MgSubscribedSku | Where-Object {$_.SkuPartNumber -match "AAD_PREMIUM|ENTRA_INTERNET_ACCESS"} |
    Measure-Object -Property {$_.PrepaidUnits.Enabled} -Sum).Sum
```

---
## 🎓 Learning Pointers

- **The Suite is priced as an addition to P1/P2, never a substitute** — any cost comparison, budget conversation, or troubleshooting session needs to start from confirming the base license is present, since nothing above it can function without it. Reference: [Microsoft Entra Suite overview](https://learn.microsoft.com/en-us/entra/fundamentals/try-microsoft-entra-suite)
- **Guest GSA licensing runs on Monthly Active Users, not seat assignment** — and the familiar 50,000-free-external-MAU allowance from base Entra ID external-identity billing does not extend to GSA-for-guests or Governance-for-guests. This is the single most common source of "why did we get billed for guests we thought were free" confusion. Reference: [Global Secure Access licensing for guest users](https://learn.microsoft.com/en-us/entra/global-secure-access/reference-licensing-guest-users)
- **Feature availability is tier-specific, not a single on/off GSA switch.** The Microsoft-traffic profile, Universal Tenant Restrictions, and Compliant Network are all free inside plain P1/P2; genuine SWG filtering lives behind Internet Access, and ZTNA/private-app publishing lives behind Private Access. Map the specific missing capability to its tier before troubleshooting further. Reference: [What is Global Secure Access — licensing overview and feature comparison table](https://learn.microsoft.com/en-us/entra/global-secure-access/overview-what-is-global-secure-access#licensing-overview)
- **Bundle discounts don't automatically justify blanket licensing.** Independent licensing-advisory analysis across multiple enterprise engagements has consistently found that only a minority-to-slim-majority of Suite-licensed seats (commonly cited in the 30-60% range, though this varies by tenant and should be measured, not assumed) actually use the network-access features that create the Suite's value over a plain identity base — treat this as a prompt to measure actual usage before recommending a blanket rollout, not as a universal ratio to quote.
- **A top-tier M365 bundle including the Suite is not "free" Suite capability** — part of that bundle's price still reflects Suite value, so seats that only need identity are effectively paying for access/governance features inside the bundle price they'll never use. Model the bundle against a targeted base-plus-Suite allocation before treating the inclusion as pure upside.
- Pricing moves — always confirm current per-user figures at [Microsoft Entra Plans & Pricing](https://www.microsoft.com/en-us/security/business/microsoft-entra-pricing) before quoting a number to a client, rather than relying on a cached figure from this file or any single source.
