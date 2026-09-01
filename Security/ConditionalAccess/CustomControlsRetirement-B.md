# Conditional Access Custom Controls Retirement — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer. Microsoft is retiring **Custom Controls** in
Conditional Access — the mechanism that redirects sign-in to a third-party MFA provider (Duo,
RSA, etc.) via a custom control URL/tenant ID. Replacement is **External Authentication Methods
(External MFA)**, a standards-based, generally-available integration surface. As of **September
2026**, admins can no longer create new Custom Controls or modify existing ones; existing ones
keep working operationally until full retirement in **May 2027**.

```powershell
Connect-MgGraph -Scopes "Policy.Read.All"

# 1. Find every CA policy that references a Custom Control grant
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.GrantControls.CustomAuthenticationFactors } |
    Select-Object DisplayName, State, @{N="CustomFactors";E={$_.GrantControls.CustomAuthenticationFactors}}

# 2. Check whether any External Authentication Method is already configured
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations" |
    Select-Object -ExpandProperty value | Where-Object { $_."@odata.type" -match "externalAuthenticationMethod" }
```

| Result | Action |
|--------|--------|
| Policy references a Custom Control and no External Auth Method exists yet | → Fix 1: Configure External MFA for the same provider before you need to touch the policy |
| Admin tries to create/edit a Custom Control after the Sept 2026 cutoff and it's blocked/greyed out | → Expected — this is the retirement taking effect, not a bug; go to Fix 1 |
| Existing Custom Control still works today but you need to update it (e.g., rotate a secret) | → Not possible post-cutoff — must migrate to External MFA instead, there is no "modify" path |
| Third-party MFA provider (Duo, RSA, etc.) already listed as an External Authentication Method | → Fix 2: Cut over the CA policy grant control directly |
| No Custom Controls found anywhere in the tenant | → No impact — nothing to migrate |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Legacy: Conditional Access Custom Control]
  └─ Redirects sign-in to a third-party MFA URL/tenant configured via the (soon-retired)
     Custom Controls preview mechanism
         |
[Sept 2026 — creation/modification cutoff]
  └─ No NEW Custom Controls can be created
  └─ EXISTING Custom Controls continue to function operationally (no forced cutover yet)
         |
[External Authentication Methods (External MFA) — GA replacement]
  └─ Standards-based integration, configured per third-party MFA provider
  └─ Provider must support the External MFA integration (check with your MFA vendor —
     most major providers, e.g. Duo, have published their own migration guidance)
         |
[CA policy grant control]
  └─ Must be re-pointed from "Custom Authentication Factor" to the new External Authentication
     Method as the grant control
         |
[May 2027 — full retirement]
  └─ Custom Controls stop working entirely — any policy still relying on one fails open/closed
     depending on policy design; do not let migration slip past this date
```

</details>

---
## Diagnosis & Validation Flow

**1. Inventory every CA policy using a Custom Control**
```powershell
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.GrantControls.CustomAuthenticationFactors } |
    Select-Object DisplayName, State, Id
```

**2. Identify which third-party MFA provider each Custom Control points to**
Custom Control detail (provider URL/tenant ID) is not fully exposed via v1.0 Graph — cross-check
against **Entra admin center > Security > Conditional Access > Custom Controls (Preview)** for the
provider mapping, and confirm against your organization's own documentation of which provider
(Duo, RSA, etc.) was configured for each control.

**3. Confirm whether an External Authentication Method already exists for that provider**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations" |
    Select-Object -ExpandProperty value | Where-Object { $_."@odata.type" -match "externalAuthenticationMethod" } |
    Select-Object id, appId, state
```
If none exists yet for the provider in question, this is a net-new configuration task (Fix 1),
not a simple policy edit.

**4. Confirm the provider's own migration documentation**
Check the third-party MFA vendor's own docs for their specific External MFA setup steps — the
Entra-side configuration (app registration, appId, federated credential) varies per provider and is
published by the vendor, not standardized end-to-end by Microsoft.

---
## Common Fix Paths

<details><summary>Fix 1 — Configure External Authentication Method for the provider</summary>

Use when: a Custom Control exists for a provider that does not yet have an External Authentication
Method configured.

```
1. Confirm the third-party MFA provider supports External Authentication Methods (check the
   vendor's own documentation — most major MFA vendors published guidance alongside this
   retirement announcement).
2. In Entra admin center: Security > Authentication methods > External Authentication Methods >
   Add external authentication method.
3. Complete the provider-specific app registration / federated credential setup per the vendor's
   documented steps (this step is provider-specific and not covered generically here).
4. Verify the new External Authentication Method shows state = enabled:
```
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations" |
    Select-Object -ExpandProperty value | Where-Object { $_."@odata.type" -match "externalAuthenticationMethod" }
```
```
5. Pilot with a small test group before touching any production CA policy grant control.
```

**Rollback:** Disabling the External Authentication Method configuration does not affect the still
-functioning legacy Custom Control (pre-May 2027) — you can roll back to the old grant control on the
CA policy itself if the pilot surfaces issues.

</details>

<details><summary>Fix 2 — Cut over the CA policy grant control to External MFA</summary>

Use when: the External Authentication Method is already configured and tested, and it's time to
switch the production Conditional Access policy over from the Custom Control.

```
1. Entra admin center > Security > Conditional Access > select the target policy > Grant.
2. Under "Require authentication strength" (or the equivalent grant option), select or build an
   authentication strength that includes the new External Authentication Method, replacing the
   Custom Authentication Factor grant.
3. Save the policy — this takes effect immediately once saved; confirm CA propagation delay
   (typically several minutes) before considering the cutover validated.
4. Test sign-in with a pilot account before removing/disabling the old Custom Control entirely.
5. Once confirmed, decommission the Custom Control (this is the vendor-side/preview-portal cleanup
   step — the CA policy itself no longer references it after step 2-3).
```

**Rollback:** Revert the CA policy's grant control back to the Custom Authentication Factor —
possible up until the May 2027 hard retirement date, after which the Custom Control no longer
functions at all and this rollback path disappears.

</details>

---
## Escalation Evidence

```
CA CUSTOM CONTROLS RETIREMENT ESCALATION
==========================================
Date/Time                          :
Tenant ID                          :
CA Policy name(s) affected         :
Third-party MFA provider           :
External Auth Method configured?   : Yes / No
Custom Control still functioning?  : Yes / No
Target migration date              :
Error message (verbatim)           :
Steps Already Tried                :
```

---
## 🎓 Learning Pointers

- **This is a hard creation/modification cutoff (Sept 2026), not an immediate functional
  retirement** — existing Custom Controls keep working operationally until May 2027. Don't panic
  -migrate everything overnight; do plan the External MFA cutover with normal change-management
  rigor before the May 2027 date. [MC1422061 — Retirement of Custom Controls in Conditional Access
  and migration to External MFA](https://mc.merill.net/message/MC1422061)
- **No impact if the tenant never used Custom Controls** — this is a narrow, provider-specific
  legacy feature; most tenants using native Entra MFA, FIDO2, or WHfB are entirely unaffected.
  Confirm via the Triage query before treating this as a required project.
- **The provider-side setup for External Authentication Methods is vendor-specific** — Microsoft
  standardizes the Entra-side policy surface, but the actual app registration/federation steps come
  from each MFA vendor's own documentation. Budget time to pull the specific vendor's guide rather
  than assuming a single generic Microsoft walkthrough covers every provider.
- **Related but distinct from the broader passkey-default-authentication rollout** — see
  `EntraID/Troubleshooting/PasskeyDefaultAuth-B.md`/`-A.md` for the separate SMS/Voice retirement
  timeline; don't conflate the two Conditional Access-adjacent September 2026 changes when triaging
  tickets.
