# Conditional Access — Authentication Context — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope note:** Authentication Context (`c1`–`c25` claim tags) decides **when** a step-up challenge fires — it's tagged onto a specific resource or action (a SharePoint sensitivity label, a Protected Action, a PIM role activation, a custom app's own claims challenge). This is distinct from `AuthenticationStrengths-B.md`, which governs **what counts** as satisfying that challenge once it fires. A client asking "why doesn't opening this labeled document force extra MFA" almost always has a Context problem (nothing is tagged, or nothing is listening), not a Strength problem.

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
# 1. Confirm Entra ID P1 minimum (Authentication Context requires P1)
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "AAD_PREMIUM" } |
    Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}

# 2. List all defined Authentication Context class references and their published state
Connect-MgGraph -Scopes "Policy.Read.All"
Get-MgIdentityConditionalAccessAuthenticationContextClassReference |
    Select-Object Id, DisplayName, Description, IsAvailable

# 3. List CA policies and flag which ones target an Authentication Context condition
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.Conditions.Applications.IncludeAuthenticationContextClassReferences } |
    Select-Object DisplayName, State, @{N="Contexts";E={$_.Conditions.Applications.IncludeAuthenticationContextClassReferences -join ", "}}

# 4. Check a user's recent sign-ins for the acrs (Authentication Context) claim being requested/satisfied
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 10 |
    Select-Object CreatedDateTime, AppDisplayName, @{N="CAResult";E={$_.AppliedConditionalAccessPolicies.Result -join ", "}}

# 5. For SharePoint-tagged contexts specifically — confirm the tenant-wide toggle is on
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"
Get-SPOTenant | Select-Object EnableAIPIntegration
```

**Interpretation table:**

| Result | What it means | Action |
|---|---|---|
| No Entra ID P1/P2 SKU found | Feature unavailable at current licensing tier | Fix 1 |
| Context exists but `IsAvailable = False` | Context not "published to apps" — no app can select/tag it | Fix 2 |
| CA policy targets a context, but sign-in logs never show that policy evaluated for the expected action | Nothing is actually emitting that context — resource/app was never tagged | Fix 3 |
| SharePoint label has "require Conditional Access authentication context" on, but nothing fires | `EnableAIPIntegration` off tenant-wide, wrong context ID on the label, target is the root site (unsupported), or the site was actually tagged directly via `Set-SPOSite` and the label check is looking in the wrong place | Fix 4 |
| PIM role activates fine but with only plain MFA, weaker than the phishing-resistant method the client expects | CA policy targeting the context is Off/Report-only/user-excluded — PIM's documented backup protection silently substitutes native MFA instead of blocking activation | Fix 6 (Cause B) |
| Custom/LOB app never triggers the step-up despite CA policy and context both correctly configured | App doesn't implement claims-challenge handling (MSAL) — Authentication Context requires app-side support | Fix 5 |
| PIM role activation doesn't prompt the expected stronger auth | Role's Activation settings aren't pointed at the same context the CA policy targets | Fix 6 |
| User re-prompted far more (or less) often than expected across unrelated apps in the same session | Confusing Authentication Context with Authentication Strength/session controls — check which control is actually firing | Fix 7 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Entra ID P1 (minimum) — P2 adds risk-based signal but is not required for Context itself
    │
    └── Authentication Context Class Reference (c1–c99, max 99 per tenant)
            │
            ├── Created (Entra admin center → Conditional Access → Authentication context,
            │       or Graph: New-MgIdentityConditionalAccessAuthenticationContextClassReference)
            │
            ├── "Publish to apps" = IsAvailable = true
            │       └── Without this, NO app (SharePoint, custom app, PIM) can select the
            │           context in its own settings UI — it exists but is invisible to consumers
            │
            ├── A CONSUMER actually tags a resource/action with the context ID:
            │       ├── Purview sensitivity label → "Require Conditional Access authentication
            │       │       context" toggle + specific context selected (SharePoint/OneDrive
            │       │       sites only; needs M365 E5 or E3+Advanced Compliance)
            │       ├── Direct SharePoint site tag → Set-SPOSite -ConditionalAccessPolicy
            │       │       AuthenticationContext (bypasses labeling entirely; needs M365 E5 or
            │       │       SharePoint Advanced Management/Copilot license; NOT supported on the
            │       │       root site)
            │       ├── Entra ID Protected Actions → sensitive admin operations (e.g. editing CA
            │       │       policies themselves, updating Authentication Methods policy) tagged
            │       │       with a context
            │       ├── PIM role Activation settings → "Require Conditional Access authentication
            │       │       context" + specific context selected
            │       └── Custom/LOB app → app code explicitly requests the context via MSAL and
            │               handles the resulting claims challenge (WWW-Authenticate / claims param)
            │
            └── A Conditional Access policy targets "Authentication context" (NOT "Cloud apps")
                    as its resource condition, selects the same context ID, and applies a grant
                    control (Require MFA, Require authentication strength, Require compliant
                    device, Block)
                        │
                        └── Claims challenge mechanism fires at request time — same underlying
                            mechanism shared with Authentication Strength; requires the client/app
                            to be claims-challenge-aware to actually re-prompt the user
```

**Common gaps:**
- A context can be fully created and even referenced by a CA policy while zero resources actually emit it — the policy will simply never trigger, with no error anywhere.
- SharePoint/OneDrive is the only Microsoft-native consumer via sensitivity labels as of GA, and it has a second, entirely separate direct-tagging path (`Set-SPOSite`) that a label-only check will miss; every other native surface (PIM, Protected Actions) configures its own separate "require this context" toggle independently — there is no single place that lists "everything tagged with c3."
- PIM's own documented "backup protection mechanism" silently falls back to plain MFA (not a hard failure) if the paired CA policy is off, report-only, or excludes the activating user — a role that "just works" with weaker-than-expected auth is often this fallback firing quietly, not a misconfiguration to chase in PIM itself.
- Non-claims-challenge-aware apps (legacy line-of-business apps, apps not coded against MSAL's claims challenge pattern) can be targeted by a CA policy on paper but will never actually re-prompt a user — the request is simply blocked with no interactive step-up path, which looks identical to "the policy is too strict" from the helpdesk's view.

</details>

---

## Diagnosis & Validation Flow

**1. Identify the failure category**

```
Context exists, nothing seems to reference it at all?          → Fix 2/3
SharePoint label configured but step-up never fires?            → Fix 4
Custom app configured but users never get re-prompted?          → Fix 5
PIM activation doesn't ask for the expected stronger method?     → Fix 6
Users confused about why re-auth frequency varies by app?        → Fix 7
```

**2. Confirm the context is published**

```powershell
Get-MgIdentityConditionalAccessAuthenticationContextClassReference | Select-Object Id, DisplayName, IsAvailable
```
`IsAvailable` must be `$true` for any consumer app to be able to select it.

**3. Confirm a CA policy actually targets it (not just "All cloud apps")**

```powershell
(Get-MgIdentityConditionalAccessPolicy -All) |
    Select-Object DisplayName, State,
        @{N="TargetsContext";E={$_.Conditions.Applications.IncludeAuthenticationContextClassReferences -join ", "}}
```
A policy with an empty `TargetsContext` value is evaluating on cloud apps/users only — it has nothing to do with Authentication Context regardless of its name.

**4. Confirm the resource-side tag matches the same context ID**

For SharePoint: Purview compliance portal → Information protection → Labels → \<label\> → "Protect documents...that contain this label..." → confirm "Use Azure Conditional Access to protect labeled SharePoint sites" is on for the label, and the context ID selected matches the CA policy's context exactly (c3 tagged on the label but c5 targeted by the policy = silent no-op).

**5. Confirm sign-in logs show the claims challenge actually being requested and satisfied**

```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 25 |
    Select-Object CreatedDateTime, AppDisplayName, ResourceDisplayName,
        @{N="CAPolicies";E={$_.AppliedConditionalAccessPolicies | ForEach-Object { "$($_.DisplayName): $($_.Result)" }}}
```
Look for the specific context-targeting policy name in `AppliedConditionalAccessPolicies` with `Result = success` at the moment the sensitive action occurred, not just a generic MFA policy.

---

## Common Fix Paths

<details><summary>Fix 1 — Licensing gap</summary>

**Symptom:** Authentication Context blade in Conditional Access is greyed out or unavailable.

```powershell
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "AAD_PREMIUM" } |
    Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}
```

**Fix:** Confirm at least Entra ID P1 is present and assigned to the users in scope. Custom Authentication Strengths (often paired with Context) also require P1.

**Rollback:** N/A — informational.

</details>

<details><summary>Fix 2 — Context created but not published to apps</summary>

**Cause:** `IsAvailable = $false`. The context exists as an object but no consuming app/feature can present it as an option.

```powershell
Update-MgIdentityConditionalAccessAuthenticationContextClassReference `
    -AuthenticationContextClassReferenceId "c1" -IsAvailable
```

**Fix:** Toggle "Publish to apps" on for the context in Entra admin center → Conditional Access → Authentication context, or set `IsAvailable = $true` via Graph. Re-check the consuming app's settings UI — the context should now appear as selectable.

**Rollback:** Set `IsAvailable` back to `$false` — existing tags referencing the context on labels/policies are NOT automatically removed, they simply stop being selectable for NEW configurations; already-tagged resources keep functioning.

</details>

<details><summary>Fix 3 — CA policy targets the context, but nothing emits it</summary>

**Cause:** A context and a matching CA policy both exist, but no resource, label, Protected Action, or app is actually tagged with that context ID — the policy has nothing to ever evaluate against.

**Check:** Walk each known consumer surface and confirm the exact context ID is selected:
```powershell
# Sensitivity labels tagged with an authentication context (requires Purview PowerShell)
Get-Label | Select-Object Name, @{N="AuthContext";E={$_.EncryptionAADPropertiesJson}}

# Protected Actions (Entra ID Governance / Protected Actions preview or GA feature)
Get-MgPolicyAuthorizationPolicy | Select-Object -ExpandProperty AdditionalProperties
```

**Fix:** Tag the intended resource/label/action with the context ID the CA policy already targets, or update the CA policy to target the context ID that's actually in use. Document the mapping (which context ID = which business scenario) — this is the single most common cause of "we configured this and nothing happens."

**Rollback:** Remove the tag from the resource; the CA policy remains but will simply never fire again.

</details>

<details><summary>Fix 4 — SharePoint sensitivity label (or direct site) step-up never fires</summary>

**Cause A — tenant-wide integration toggle is off:**
```powershell
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"
Get-SPOTenant | Select-Object EnableAIPIntegration
Set-SPOTenant -EnableAIPIntegration $true
```

**Cause B — label's context ID doesn't match the CA policy's context ID:**
Re-open the label in Purview compliance portal → confirm the exact context selected → compare against the CA policy's `IncludeAuthenticationContextClassReferences`.

**Cause C — label change hasn't propagated yet:**
Label policy publishing can take up to 24 hours for existing content; new documents/sites pick it up faster. Don't troubleshoot as a hard failure inside that window.

**Cause D — target is the root site, or someone expected the wrong tagging path:** Authentication context via a sensitivity label **cannot be applied to the SharePoint root site** (`https://<tenant>.sharepoint.com`) — this is a documented, permanent limitation, not a propagation delay. Separately, SharePoint has *two independent ways* to tag a site with a context, and they're easy to confuse when troubleshooting: a sensitivity label (Purview-driven, requires Microsoft 365 E5 or E3+Advanced Compliance) **or** a direct per-site assignment via `Set-SPOSite` (requires Microsoft 365 E5 or the SharePoint Advanced Management/Copilot license), which bypasses labeling entirely:
```powershell
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<site>" `
    -ConditionalAccessPolicy AuthenticationContext -AuthenticationContextName "<ContextDisplayName>"
```
If a site was tagged directly this way, checking only its sensitivity label will show nothing — confirm with `Get-SPOSite -Identity <url> | Select ConditionalAccessPolicy` before assuming the site is untagged.

**Cause E — background/third-party app bypassing the tag:** by default, non-interactive/background app principals are NOT blocked by a site-level authentication context. If a client expects third-party app access to also be gated, this requires explicitly opting in:
```powershell
Set-SPOTenant -BlockAppAccessWithAuthenticationContext $true   # default: $false
```
This requires at least one CA policy already scoped to an application principal — enabling it with none configured has no effect.

**Rollback:** `Set-SPOTenant -EnableAIPIntegration $false` disables the integration tenant-wide — will silently stop ALL label-based Authentication Context step-ups, not just the one being tested. Scope-test carefully before disabling in production. `Set-SPOTenant -BlockAppAccessWithAuthenticationContext $false` reverts the background-app blocking to its default off state.

</details>

<details><summary>Fix 5 — Custom/LOB app never re-prompts despite correct CA + Context config</summary>

**Cause:** Authentication Context step-up depends on the requesting app correctly handling a claims challenge (`WWW-Authenticate` header with a `claims` parameter, or MSAL's `ClaimsChallenge`/`WebApiMsalUiRequiredException` handling). An app that doesn't implement this simply gets blocked outright — there is no automatic browser-level re-prompt for non-claims-aware apps.

**Fix:** Confirm with the app owner/developer whether the app is built with a current MSAL library version and explicitly handles claims challenges for the target API/resource. If not, Authentication Context cannot be used against that app until claims-challenge handling is added — this is an app-code change, not a CA/Entra configuration fix.

**Rollback:** N/A — this is a capability gap, not a misconfiguration to roll back.

</details>

<details><summary>Fix 6 — PIM role activation doesn't ask for the expected stronger method</summary>

**Cause A — context/policy mismatch:** PIM's own "Require Microsoft Entra Conditional Access authentication context" setting on the role's Activation tab isn't pointed at the same context ID the CA policy (with the stronger grant control) targets.

```powershell
# Inspect the role's activation policy — Beta endpoint, PIM role settings
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole' and roleDefinitionId eq '<RoleDefinitionId>'"
```

**Fix:** In PIM → role settings → Activation → "On activation, require Microsoft Entra Conditional Access authentication context" → select the same context ID used by the CA policy carrying the stronger grant (e.g., phishing-resistant Authentication Strength). Microsoft's own guidance pairs this specifically with Authentication Strengths to force a *different* method than the one used to sign in, not just a repeat MFA prompt.

**Cause B — silently falling back to plain MFA (the opposite symptom, and the more dangerous one):** if the CA policy targeting the context is Off, in Report-only, or has the activating user excluded, PIM's documented "backup protection mechanism" silently substitutes its own native "Require Azure MFA" activation requirement instead — the role still activates, just with a weaker control than intended, and nothing in PIM's own UI flags this fallback occurred. This is the opposite complaint from Cause A ("didn't get the stronger method I expected") and needs the CA policy's State checked first, not the PIM setting.

```powershell
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.Conditions.Applications.IncludeAuthenticationContextClassReferences -contains "<ContextId>" } |
    Select-Object DisplayName, State, @{N="ExcludedUsers";E={$_.Conditions.Users.ExcludeUsers -join ", "}}
```

**Note:** "On activation, require Microsoft Entra Conditional Access authentication context" and "On activation, require multifactor authentication" are two independent toggles on the same Activation tab — both can be enabled together, and the backup protection mechanism above only fires when the CA-policy side of the pairing is broken, not as a deliberate defense-in-depth layer.

**Rollback:** Clear the context selection on the role's Activation tab — activation reverts to whatever native MFA/approval settings remain configured.

</details>

<details><summary>Fix 7 — Confusing Authentication Context with Authentication Strength or session controls</summary>

**Symptom:** "Why does opening this one document ask for extra verification but everything else in the same session doesn't" or vice versa.

**Clarify which control is firing:**
- **Authentication Context** = decides **when** (this specific document/action/role activation) — see `AuthenticationContext-A.md`.
- **Authentication Strength** = decides **what counts** as satisfying any step-up, context-triggered or not — see `AuthenticationStrengths-B.md`.
- **Sign-in frequency / session controls** = a completely separate CA grant that re-prompts on a time interval regardless of any context — see `CA-Design-A.md`.

All three can be layered on the same request; check `AppliedConditionalAccessPolicies` in the sign-in log to see exactly which named policy actually fired, rather than guessing from symptoms alone.

**Rollback:** N/A — diagnostic clarification only.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Conditional Access Authentication Context
=========================================================
Date/Time of issue:              ___________________________
Tenant ID:                       ___________________________
Context ID (c1-c25):             ___________________________
Context DisplayName:             ___________________________
IsAvailable (published):         [ ] Yes  [ ] No

Consumer surface affected:
  [ ] SharePoint/OneDrive sensitivity label
  [ ] Entra ID Protected Action
  [ ] PIM role activation
  [ ] Custom/LOB application (MSAL claims challenge)

CA policy name targeting this context:  ___________________________
CA policy State:                        [ ] On  [ ] Report-only  [ ] Off
Grant control on the policy:            ___________________________

Symptom:
  [ ] Nothing fires at all
  [ ] Fires inconsistently
  [ ] Fires but wrong grant control applied
  [ ] User never gets re-prompted (app doesn't support claims challenge)

Affected user UPN:                ___________________________
Sign-in log excerpt (AppliedConditionalAccessPolicies):
___________________________

SharePoint EnableAIPIntegration state (if relevant):   [ ] On  [ ] Off

Attached evidence:
  [ ] Get-MgIdentityConditionalAccessAuthenticationContextClassReference export
  [ ] CA policy export
  [ ] Sign-in log export
  [ ] Get-AuthContextAudit.ps1 findings CSV

Support contact: https://admin.microsoft.com → Support → New service request
Product: Microsoft Entra Conditional Access — Authentication Context
```

---

## 🎓 Learning Pointers

- **A context that exists and a policy that targets it are necessary but not sufficient — something must actually tag a resource with it.** The most common "nothing happens" ticket in this topic is a fully-wired context and CA policy with zero resources ever emitting that context ID. Always confirm the consumer side (label, Protected Action, PIM setting, app code) before assuming the CA policy is broken. [Conditional Access authentication context](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-cloud-apps#authentication-context)

- **"Publish to apps" is a separate, easy-to-miss switch from simply creating the context.** A newly created context is invisible to every consumer app's own settings UI until `IsAvailable` is explicitly set to true — don't assume creation alone makes it selectable elsewhere.

- **Authentication Context and Authentication Strength are commonly conflated but solve different problems.** Context answers "when should a step-up fire" (a specific document, action, or role activation); Strength answers "what satisfies it" (which method combination). A request for "step-up on sensitive documents" almost always needs both configured together, not one or the other. [Authentication context overview](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-cloud-apps#authentication-context)

- **Claims-challenge support is an app-code requirement, not a tenant configuration.** A custom or legacy LOB app that hasn't implemented MSAL's claims-challenge handling cannot be step-up-challenged via Authentication Context no matter how correctly the tenant side is configured — this is frequently misdiagnosed as a broken CA policy.

- **Up to 99 authentication contexts exist per tenant (`c1`–`c99`).** Plan context allocation deliberately (document what each ID represents) rather than creating them ad hoc per project — running out mid-rollout means retiring and reusing IDs, which risks orphaning existing tags. Before deleting a context, confirm via sign-in log search that no CA policy still targets it and it's unpublished (`IsAvailable = $false`) — Microsoft blocks deletion of a context that's still assigned to a policy specifically to prevent silently breaking an active protection.

- **A user sometimes satisfies a context with zero visible prompt — this is expected "opportunistic" behavior, not a broken policy.** If the CA policy protecting a context is already satisfied by the user's existing session (e.g., they signed in with MFA recently and sign-in frequency hasn't lapsed), Entra can add the `acrs` claim to the token proactively without a fresh challenge. Don't treat "user says they weren't asked for anything extra" as proof the context isn't being enforced — check the sign-in log's `AppliedConditionalAccessPolicies` instead of relying on the user's memory of being prompted. [Developer guide to Conditional Access authentication context](https://learn.microsoft.com/en-us/entra/identity-platform/developer-guide-conditional-access-authentication-context#authentication-context-acrs-in-conditional-access-expected-behavior)

- **SharePoint has a long, specific list of features that silently break on an authentication-context-protected site** (OneDrive sync app, mobile apps, Outlook on every platform, Teams webinar scheduling, cross-geo file moves, multi-file download when combined with app-enforced restriction, and more). Before troubleshooting a "this one SharePoint feature stopped working" ticket as a bug, check whether the affected site carries a context — this is Microsoft's own documented, permanent limitations list, not something to fix. [Conditional access policy — SharePoint](https://learn.microsoft.com/en-us/sharepoint/authentication-context-example#limitations)
