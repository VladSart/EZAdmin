# Intune Suite → Microsoft 365 E3/E5 Base Licensing Consolidation — Hotfix Runbook (Mode B: Ops)
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

Starting **1 July 2026** (rollout completing by **1 August 2026**), Microsoft folded a large slice of the paid **Intune Suite** add-on directly into base **Microsoft 365 E3 and E5** licensing — no separate purchase, no admin action, automatic provisioning for eligible tenants. This is a licensing/procurement event, not a technical deployment — most tickets are "why does this feature suddenly work" or "are we double-paying" rather than a broken feature.

```powershell
Connect-MgGraph -Scopes "Organization.Read.All","User.Read.All"

# 1. What base SKUs does the tenant actually hold?
Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId, ConsumedUnits, @{N='Prepaid';E={$_.PrepaidUnits.Enabled}}

# 2. Does the tenant also hold a standalone Intune Suite / individual add-on SKU (potential redundant spend)?
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match 'INTUNE_SUITE|EPM|CLOUD_PKI|ENTERPRISE_APP|REMOTE_HELP|ADVANCED_ANALYTICS' } |
    Select-Object SkuPartNumber, ConsumedUnits

# 3. Is the feature the user is asking about actually part of THIS bundling, or a separate change?
#    E3-qualifying SKUs → Remote Help, Advanced Analytics, Intune Plan 2 (Tunnel for MAM, FOTA updates, specialty device mgmt)
#    E5-qualifying SKUs → everything in E3 PLUS Endpoint Privilege Management (EPM), Enterprise App Management (EAM), Microsoft Cloud PKI

# 4. Per-user assignment check (the bundled capability still needs the base license assigned to the specific user)
Get-MgUserLicenseDetail -UserId "<UPN>" | Select-Object SkuPartNumber, ServicePlans
```

| Finding | Interpretation | Action |
|---|---|---|
| Tenant holds `SPE_E3`/`SPE_E5`/`M365EDU_A3`/`M365EDU_A5`-family SKU, dated after Aug 2026 | Bundled capabilities should already be live, no add-on purchase needed | Confirm per-user license assignment (step 4) before troubleshooting the feature itself |
| Tenant holds base E3/E5 **and** a standalone Intune Suite/EPM/Cloud PKI/Remote Help SKU with consumed seats | Likely redundant spend — the add-on may now be fully or partially superseded | Escalate to account/licensing owner for a billing review; do not unassign automatically |
| Feature (EPM, Remote Help, Cloud PKI, EAM) still shows unlicensed for a specific user despite tenant holding a qualifying base SKU | Per-user license assignment gap, not a tenant-wide gap | Assign the base E3/E5 license to that user; the bundled service plan rides along |
| User is on EMS E3-only (no full M365 E3/E5) | E3-tier inclusions (Remote Help, Advanced Analytics, Plan 2 features) still apply — confirmed eligible; EPM/EAM/Cloud PKI (E5-only) do not | Do not assume EMS E3 gets E5-tier features |
| Feature request is for Cloud PKI specifically on an E3-only tenant | **Not included at E3** — Cloud PKI is E5-only under this bundling | Standalone Cloud PKI/Intune Suite purchase still required |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant holds a qualifying base SKU (M365/EMS E3 or E5 family)
    → Tenant-level provisioning of bundled service plans complete (automatic, per Microsoft's own rollout window — July 1 to Aug 1 2026; a 30-day Message Center notice precedes activation in a given tenant)
        → Specific user has the base E3/E5 license ASSIGNED (not just tenant-held)
            → Correct service plan enabled within that SKU (bulk/group-based licensing can suppress individual service plans)
                → Feature-specific prerequisites still apply on top of licensing:
                    - EPM: EPM agent installed + elevation policy assigned (see EPM-B.md)
                    - Remote Help: BOTH helper and sharer need the license (see RemoteHelp-B.md)
                    - Cloud PKI: E5 only, 3-CA-per-tenant cap still applies (see CloudPKI-B.md)
                    - EAM: Enterprise App Catalog still needs its own configuration (see EnterpriseAppManagement-B.md)
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm which base SKU(s) the tenant actually holds and when they were provisioned.**
   `Get-MgSubscribedSku` — cross-reference `SkuPartNumber` against Microsoft's current E3/E5-family SKU list (naming varies: `SPE_E3`, `SPE_E5`, `SPE_E3_USGOV_DOD`, education/nonprofit variants, etc.). A tenant on an older or non-qualifying commercial plan (e.g., Business Premium, F3/F1, standalone EMS without full M365) does **not** get this bundling — verify before assuming eligibility.

2. **Confirm the rollout has actually reached this tenant.**
   Bundled service plans provision automatically but on a rolling schedule (Message Center gives 30 days' notice before activation). A tenant created or upgraded very recently, or checked before ~August 2026, may show the SKU without the bundled service plans populated yet. Check `Get-MgUserLicenseDetail` `ServicePlans` for the specific plan name rather than assuming SKU presence alone means the feature is live.

3. **Confirm per-user assignment, not just tenant-wide entitlement.**
   Bundling changes what a SKU *contains* — it does not auto-assign that SKU to users who don't already have it. A user without any E3/E5 license assigned still has nothing, bundled or not.

4. **Disambiguate from the feature-specific runbook.**
   If the base licensing checks out and the feature still doesn't work, licensing is not the cause — hand off to the feature's own runbook (`EPM-B.md`, `RemoteHelp-B.md`, `CloudPKI-B.md`, `EnterpriseAppManagement-B.md`) rather than continuing to troubleshoot licensing.

---
## Common Fix Paths

<details><summary>Fix 1 — Feature shows unlicensed but tenant holds a qualifying E3/E5 SKU</summary>

Use when: tenant-wide SKU is correct but a specific user can't access EPM/Remote Help/Cloud PKI/EAM.

```powershell
# Confirm the user's assigned licenses and enabled service plans
Get-MgUserLicenseDetail -UserId "<UPN>" | Select-Object SkuPartNumber, ServicePlans

# If the base E3/E5 SKU itself is missing from this user, assign it
$sku = Get-MgSubscribedSku | Where-Object SkuPartNumber -eq "<SPE_E3-or-E5-SkuPartNumber>"
Set-MgUserLicense -UserId "<UPN>" -AddLicenses @{ SkuId = $sku.SkuId } -RemoveLicenses @()

# If the SKU is assigned but a specific service plan is disabled (group-based licensing exclusion),
# check the license assignment's disabled-plans list — remove the exclusion via the M365 admin center
# or Entra ID group-based licensing blade rather than via a raw Graph call (avoids reintroducing drift)
```

Propagation after a licensing change can take up to a few hours; don't treat a fresh assignment as broken within that window.

</details>

<details><summary>Fix 2 — Suspected redundant spend (standalone add-on still assigned post-bundling)</summary>

Use when: tenant holds both a qualifying E3/E5 SKU and a standalone Intune Suite/EPM/Cloud PKI/Remote Help/Enterprise App Management SKU with consumed seats.

```powershell
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match 'INTUNE_SUITE|EPM|CLOUD_PKI|ENTERPRISE_APP|REMOTE_HELP|ADVANCED_ANALYTICS' } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
```

This is a **billing/procurement decision, not a technical fix** — do not unassign or cancel a standalone add-on SKU without confirming with the account/licensing owner first. Two legitimate reasons a standalone SKU may still be needed even after bundling: (a) the tenant is on E3 and needs an E5-only capability (Cloud PKI, EPM, EAM) via the older standalone route instead of upgrading to E5; (b) the standalone SKU covers users who are not themselves licensed for the qualifying E3/E5 base plan. Flag as a review item in the ticket rather than resolving unilaterally.

</details>

<details><summary>Fix 3 — Tenant SKU looks qualifying but bundled service plans never appeared</summary>

Use when: it's well past August 2026, the tenant clearly holds a qualifying SKU, but no bundled service plans show in `Get-MgUserLicenseDetail` for any user.

1. Check the tenant's Microsoft 365 Message Center (admin.microsoft.com > Health > Message center) for the specific rollout notification and its stated activation date for this tenant.
2. Confirm the SKU is a genuinely qualifying commercial/education/government variant — some regional or grandfathered plan variants may be excluded or delayed; Microsoft's own documentation is the source of truth per tenant, not a blog post.
3. If the activation date has passed and plans still haven't appeared, this is a genuine Microsoft-side provisioning gap — escalate via a Microsoft support ticket rather than continuing to self-diagnose; there is no admin-facing "re-trigger provisioning" action.

No rollback needed — this fix path is read/verify only.

</details>

---
## Escalation Evidence

```
=== Intune Suite Base Licensing Escalation ===
Tenant ID: <__>
Base SKU(s) held: <__>  (SkuPartNumber + ConsumedUnits)
Bundled service plans expected: <__>  (E3 tier / E5 tier)
Bundled service plans observed on affected user (Get-MgUserLicenseDetail): <__>
Standalone add-on SKU(s) also held: <__>  (flag if present — redundant-spend review needed)
Message Center rollout notification ID (if found): <__>
Feature affected: <__>  (EPM / Remote Help / Cloud PKI / Enterprise App Management / other)
Confirmed NOT a feature-specific config issue (ruled out via its own runbook): Y / N
```

---
## 🎓 Learning Pointers

- **This is a licensing entitlement change, not a feature deployment** — nothing to "roll out" tenant-side beyond confirming SKU assignment. Don't spend triage time looking for a missing Intune policy when the actual gap is a license assignment. [Advanced Microsoft Intune capabilities now available in Microsoft 365 E3 and E5](https://techcommunity.microsoft.com/blog/microsoftintuneblog/advanced-microsoft-intune-capabilities-now-available-in-microsoft-365-e3-and-e5/4529335)

- **Cloud PKI is E5-only under this bundling — E3 does not get it.** This is the single most common expectation mismatch; confirm tier before promising a client Cloud PKI "for free" post-bundling. See `Intune/Troubleshooting/CloudPKI-B.md`'s own Learning Pointer on this same date.

- **Tenant-held SKU ≠ user-assigned license ≠ enabled service plan.** Three distinct layers, each a separate common point of failure — check all three before concluding a feature is broken versus simply unlicensed for that user.

- **Community sources disagree on exact pricing and on a small set of secondary details** (list-price increases, an alternate "October 2026" rollout-completion date reported by at least one source) that this repo could not confirm against a single, unambiguous, currently-live official page at time of writing. Treat the July 1 → Aug 1 2026 window and the E3/E5 feature split above as the well-corroborated core facts, and verify pricing/edge-case details directly in the tenant's own Message Center and admin center billing pages before quoting a client a number.

- **This bundling doesn't change any RBAC, deployment, or configuration requirement for the underlying features** — it only changes how the license is obtained. Continue troubleshooting EPM/Remote Help/Cloud PKI/EAM issues via their own dedicated runbooks once licensing itself is confirmed healthy.
