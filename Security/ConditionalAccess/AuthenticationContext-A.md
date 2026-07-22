# Conditional Access — Authentication Context — Reference Runbook (Mode A: Deep Dive)
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

**Applies to:** Microsoft Entra ID Conditional Access Authentication Context (`c1`–`c99` claim class references), its four native consumer surfaces (Purview sensitivity labels on SharePoint/OneDrive, direct `Set-SPOSite` tagging, Entra ID Protected Actions, PIM role Activation settings), and the custom-application developer pattern (MSAL claims challenge). Entra ID P1 minimum; several consumer surfaces layer additional licensing on top (see Licensing below).

**Role required:** Conditional Access Administrator (create/manage contexts and policies); Compliance Administrator or Information Protection Administrator (sensitivity labels); Privileged Role Administrator (PIM role Activation settings); SharePoint Administrator (`Set-SPOSite`/`Set-SPOTenant`); Security Reader (view/audit only).

**Does not cover:** Authentication Strength — the grant control that decides *what counts* as satisfying any step-up challenge, context-triggered or not; see `AuthenticationStrengths-A.md`. Session controls / sign-in frequency as a standalone mechanism (only touched here where it interacts with PIM reauthentication); see `CA-Design-A.md`. Token Protection / PoP binding, a separate anti-replay layer; see `TokenProtection-A.md`. Microsoft Defender for Cloud Apps session-policy-based step-up (a related but separately licensed and configured mechanism — Defender for Cloud Apps can itself request an authentication context, but its own session-control configuration is out of scope here).

**What is Authentication Context?**
Authentication Context is a Conditional Access *resource condition* — a named, numbered tag (`c1` through `c99`) that a consuming surface attaches to a specific resource, document, admin action, or role activation. A Conditional Access policy can then target "Authentication context" instead of "Cloud apps" as its condition, so the same underlying CA policy engine can apply a stronger grant control (MFA, a specific Authentication Strength, a compliant-device requirement, or Block) to one narrow slice of a much larger, generally-lower-friction application — without a separate CA policy per resource and without touching the app's own access model. It answers **when** a step-up should fire. It says nothing about **what satisfies** that step-up once it fires; that's Authentication Strength's job.

---

## How It Works

<details><summary>Full architecture</summary>

### The claims-challenge foundation

Authentication Context is built on the same OpenID Connect claims-challenge extension used by Authentication Strength and Continuous Access Evaluation. The mechanics:

1. A resource server (SharePoint, a custom API, PIM's own activation endpoint) receives a request and determines the caller needs a specific context satisfied — either because it's evaluating a locally-stored mapping (custom apps) or because it's a native Microsoft surface with the mapping built in (SharePoint labels, PIM).
2. If the presented token doesn't carry the required value in its `acrs` (Authentication Context Class Reference) claim, the resource server returns `401` with a `WWW-Authenticate` header carrying a base64-encoded `claims` parameter requesting that specific context.
3. The client (if claims-challenge-aware — see the Gotcha below) intercepts this, redirects the user back through Microsoft Entra ID, which evaluates every CA policy targeting that context ID.
4. If all matching policies' grant controls are satisfied, Entra issues a new token with `acrs` containing the satisfied context ID(s), and the client retries the original request.

This is architecturally identical to how Authentication Strength triggers a re-challenge — the two features share the claims-challenge transport layer. What differs is *what* triggers the challenge (a specific tagged resource vs. any request to an app the CA policy targets) and *what* the policy demands once triggered (Authentication Context itself demands nothing about method; it's the grant control on the CA policy, commonly an Authentication Strength, that does).

### Opportunistic (implicit) ACRS evaluation — the most under-documented part of this feature

Not every context satisfaction requires a round-trip challenge. A resource provider can opt in (per token type — ID token and access token are opted in independently) to have Entra proactively add satisfied `acrs` values to a token even when the client never explicitly asked for them, provided the CA policies protecting those contexts are already satisfied by the user's existing session state. Microsoft's own documented truth table (see the Command Cheat Sheet's linked source) covers the corner cases; the practical implications:

- **A user can be silently, correctly protected with zero visible prompt.** If they authenticated with a qualifying method recently and sign-in frequency hasn't lapsed, the `acrs` claim gets added opportunistically on the next token issuance — no redirect, no banner, nothing the user notices. This is *correct, intended behavior*, not a sign the policy failed to fire.
- **Sign-in frequency and CAS (Cloud App Security / Defender for Cloud Apps) session state both gate opportunistic evaluation independently of the explicit challenge path.** A stale auth factor (outside the configured sign-in frequency interval) blocks opportunistic issuance even though an explicit challenge would still succeed if triggered.
- This is the single most common source of "the sign-in log shows the policy applied and satisfied, but the user swears they were never asked for anything" tickets — both statements are true simultaneously, and neither indicates a misconfiguration.

### Authentication Context works with users OR workload identities, never both in the same policy

A CA policy targeting an Authentication Context condition can be scoped to human users or to workload identities (service principals, managed identities under Workload Identities Premium) — but not mixed within a single policy. A tenant running both scenarios needs two separate CA policies even when they reference the identical context ID.

### The four native consumer surfaces, compared

| Surface | Tags | Licensing (beyond Entra P1) | Notes |
|---|---|---|---|
| Purview sensitivity label | SharePoint/OneDrive sites, via label policy | Microsoft 365 E5, or E3 + Advanced Compliance | Propagation to existing content can take up to 24h; new content picks it up on creation. Cannot target the SharePoint root site. |
| Direct SharePoint site tag (`Set-SPOSite -ConditionalAccessPolicy AuthenticationContext`) | A specific site collection, no label involved | Microsoft 365 E5, or SharePoint Advanced Management / Copilot license | Bypasses Purview entirely — a site tagged this way shows nothing in its sensitivity label configuration. Also cannot target the root site. |
| Entra ID Protected Actions | Specific sensitive Microsoft Graph/admin-center operations (editing CA policies, Authentication Methods policy changes, etc.) | Entra ID P1 (the feature itself; specific protected actions may carry their own prerequisites) | Its own separate assignment UI under Entra ID Protection — not visible from the Authentication Context blade. |
| PIM role Activation setting | A specific Entra or Azure resource role's activation flow | Entra ID Governance / PIM licensing (P2 or Entra ID Governance) | Layered alongside, not instead of, PIM's native "Require MFA on activation" toggle — see the Backup Protection Mechanism note below. |

Custom/LOB applications are a fifth, developer-driven surface: the app itself queries Graph for available contexts, lets an admin map sensitive operations to a context ID, and raises the claims challenge in its own code. There is no tenant-wide inventory of what a custom app has mapped — that mapping lives entirely in the app's own store.

### The backup protection mechanism (PIM-specific, and the most consequential gotcha in this topic)

PIM's "On activation, require Microsoft Entra Conditional Access authentication context" setting and its "On activation, require multifactor authentication" setting are independent toggles on the same Activation tab. Microsoft's documented behavior when the CA-authentication-context path is configured but not properly backed by a live, enforcing CA policy:

> *"As a backup protection mechanism, if there are no Conditional Access policies in the tenant that target authentication context configured in PIM settings, during PIM role activation, the multifactor authentication feature in Microsoft Entra ID is required as the [require MFA] setting would be."*

Critically, **this backup mechanism only fires for the specific case of a missing/never-created CA policy** — Microsoft explicitly documents that it does *not* trigger if the CA policy exists but is turned Off, is in Report-only mode, or has the activating user excluded from its scope. In those three cases, PIM activation proceeds with **no elevated auth requirement enforced at all** beyond whatever baseline sign-in the user already had — a materially different and more dangerous outcome than "falls back to plain MFA," and one that produces no visible error anywhere in PIM's own UI. Any PIM-plus-Authentication-Context design should be validated against all four states (missing / off / report-only / user-excluded) before being trusted as a control, not just the happy path.

### SharePoint's specific, permanent app-compatibility limitations

A site or label carrying an Authentication Context is a documented, permanent source of feature breakage in several Microsoft first-party surfaces — not a bug to chase. As of this writing, Microsoft's own limitations list includes: older Office app versions, SharePoint's iOS/Android mobile apps, Viva Engage, OneNote-in-Teams-channel association, Teams channel meeting recording upload, SharePoint folder renaming from within Teams, Teams webinar scheduling against a context-protected OneDrive, the OneDrive sync client (won't sync a context-protected site at all), Outlook on every platform (Windows, Mac, Android, iOS — none support communicating with a context-protected SharePoint site), multi-file download when combined with Conditional Access App Control session controls, multi-file download when the context is applied directly to a site with no active/enabled CA policy behind it, cross-geo file copy/move to a context-protected destination, and Excel Web Query (IQY) export. A support ticket reporting one of these specific, narrow feature failures against a site that otherwise works normally should be checked against this list before being escalated as a bug.

</details>

---

## Dependency Stack

```
Microsoft Entra ID P1 (minimum tenant-wide prerequisite for the feature to exist at all)
    │
    ├──► Authentication Context Class Reference object (c1–c99)
    │         ├── Created
    │         ├── Published to apps (IsAvailable = true)
    │         └── (only relevant to deletion) unassigned from every CA policy first
    │
    ├──► Consumer surface tags a resource/action — FOUR independent paths, no unified inventory:
    │         ├── Purview sensitivity label  (needs M365 E5 / E3+Advanced Compliance)
    │         ├── Direct Set-SPOSite tag     (needs M365 E5 / SPO Advanced Mgmt or Copilot license)
    │         ├── Entra ID Protected Action  (own assignment surface, separate from CA blade)
    │         └── PIM role Activation setting (needs Entra ID Governance / P2)
    │                    │
    │                    └── Independent of, and layered alongside, PIM's own native
    │                        "Require MFA on activation" toggle — NOT a replacement for it
    │
    ├──► Conditional Access policy targets "Authentication context" (not Cloud apps),
    │         selects the matching context ID, and carries a grant control
    │         (Require MFA / Require Authentication Strength / Require compliant device / Block)
    │
    └──► Claims-challenge transport fires the actual re-prompt
              ├── EXPLICIT: client/app requests the context in its own token request
              │       └── requires app-side MSAL claims-challenge handling (WWW-Authenticate)
              └── IMPLICIT/OPPORTUNISTIC: Entra proactively adds a satisfied acrs value
                      to a resource-provider-opted-in token when the protecting CA policy
                      is already satisfied by current session state — no visible prompt
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Authentication Context blade greyed out / unavailable in Entra admin center | Missing Entra ID P1 | `Get-MgSubscribedSku` for `AAD_PREMIUM` |
| Context created, nothing anywhere seems to react to it | `IsAvailable = $false` — not published to apps | `Get-MgIdentityConditionalAccessAuthenticationContextClassReference` |
| Context published, CA policy exists, still nothing fires | No consumer surface actually tags a resource with this context ID | Walk all four consumer surfaces individually — no single query covers all of them |
| SharePoint label configured, step-up never fires, target is the site's root URL | Root site is explicitly unsupported for auth-context tagging | Confirm target isn't `https://<tenant>.sharepoint.com` itself |
| SharePoint label shows nothing, but the site is definitely gated in testing | Site was tagged directly via `Set-SPOSite`, bypassing the label entirely | `Get-SPOSite -Identity <url> \| Select ConditionalAccessPolicy` |
| One specific SharePoint feature broke on an otherwise-working context-protected site | Documented, permanent app-compatibility limitation (OneDrive sync, Outlook, mobile apps, etc.) | Cross-check against Microsoft's limitations list before treating as a bug |
| Third-party/background app still reaches a context-protected SharePoint site | `BlockAppAccessWithAuthenticationContext` defaults to `$false` | `Get-SPOTenant \| Select BlockAppAccessWithAuthenticationContext` |
| Custom/LOB app never re-prompts despite fully correct tenant-side config | App doesn't implement MSAL claims-challenge handling | Confirm with the app owner/dev; this is a code gap, not a tenant fix |
| PIM activation gives the expected stronger method | (not a symptom — working as designed) | — |
| PIM activation gives only plain MFA when a stronger method was expected | Paired CA policy is Off / Report-only / excludes the user — PIM's documented backup protection substituted native MFA | Check the CA policy's `State` and `ExcludeUsers`, not the PIM setting |
| PIM activation gives **no** elevated requirement at all, weaker than plain MFA too | Same root cause as above, but the "backup protection" case doesn't apply (CA policy exists but is off/report-only/excluded) — this specific combination is NOT auto-backstopped | Same check; escalate as a real gap, not a fallback |
| User reports never being prompted for anything extra, but sign-in logs show the policy applied and satisfied | Opportunistic/implicit ACRS evaluation — expected behavior, not a failure | `AppliedConditionalAccessPolicies` in sign-in logs, `Result = success` |
| Two engineers configuring the same tenant get inconsistent context ID meanings | No documented context-ID-to-business-purpose mapping exists tenant-wide | Establish and maintain one; nothing in the product tracks this for you |
| Attempt to delete a context fails | Context still assigned to a CA policy, or still published | Unassign from all CA policies and un-publish before deleting |
| Workload identity sign-in isn't challenged by a context that works fine for users | CA policy scoped to Users, not Workload identities — the two can't share one policy | Build a second, workload-identity-scoped policy against the same context ID |

---

## Validation Steps

**1. Confirm licensing floor**
```powershell
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "AAD_PREMIUM" } |
    Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}
```
Good: at least one `AAD_PREMIUM` SKU with `Enabled > 0`. Bad: no match — the Authentication Context blade itself will be inaccessible.

**2. Inventory every defined context and its published state**
```powershell
Get-MgIdentityConditionalAccessAuthenticationContextClassReference |
    Select-Object Id, DisplayName, Description, IsAvailable
```
Good: every context an admin believes is "live" shows `IsAvailable = True`. Bad: a context believed to be in production shows `False` — it's invisible to every consumer surface's own settings UI.

**3. Confirm CA policy targeting, not just naming**
```powershell
Get-MgIdentityConditionalAccessPolicy -All |
    Select-Object DisplayName, State,
        @{N="TargetsContext";E={$_.Conditions.Applications.IncludeAuthenticationContextClassReferences -join ", "}}
```
Good: the policy's `TargetsContext` is non-empty and matches the intended context ID. Bad: a policy named suggestively (e.g., "Require MFA for sensitive docs") has an empty `TargetsContext` — it's a plain Cloud-apps policy with nothing to do with Authentication Context regardless of its name.

**4. Walk each consumer surface individually — there is no single query**
```powershell
# SharePoint — check BOTH tagging paths
Get-SPOSite -Identity "<siteUrl>" | Select-Object Url, ConditionalAccessPolicy
Get-Label | Select-Object Name, @{N="AuthContext";E={$_.EncryptionAADPropertiesJson}}

# Protected Actions
Get-MgPolicyAuthorizationPolicy | Select-Object -ExpandProperty AdditionalProperties

# PIM role activation settings — Beta endpoint
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole' and roleDefinitionId eq '<RoleDefinitionId>'"
```
Good: at least one surface returns a match for the context ID under investigation. Bad: all four come back empty — the context and policy are both correctly configured but structurally unable to ever fire.

**5. Confirm the claims challenge actually completed in the sign-in log**
```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 25 |
    Select-Object CreatedDateTime, AppDisplayName, ResourceDisplayName,
        @{N="CAPolicies";E={$_.AppliedConditionalAccessPolicies | ForEach-Object { "$($_.DisplayName): $($_.Result)" }}}
```
Good: the specific context-targeting policy name shows `Result = success` correlated to the timestamp of the sensitive action. Bad: only a generic baseline MFA policy shows as applied — the context-specific policy never evaluated, meaning nothing actually requested that `acrs` value for this request.

**6. For PIM specifically, validate all four backup-protection states, not just the happy path**
```powershell
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.Conditions.Applications.IncludeAuthenticationContextClassReferences -contains "<ContextId>" } |
    Select-Object DisplayName, State, @{N="ExcludedUsers";E={$_.Conditions.Users.ExcludeUsers -join ", "}}
```
Good: `State = enabledForReportingButNotEnforced` is NOT what you want in production — confirm `State = "enabled"` and the target user isn't in `ExcludedUsers`. Bad: any of Off / Report-only / user-excluded — the PIM activation is either silently falling back to plain MFA (if the policy is entirely missing) or, in these three specific states, enforcing nothing extra at all.

**7. Confirm safe-to-delete state before removing a context**
```powershell
(Get-MgIdentityConditionalAccessPolicy -All) |
    Where-Object { $_.Conditions.Applications.IncludeAuthenticationContextClassReferences -contains "<ContextId>" }
```
Good: empty result AND `IsAvailable = $false` — safe to delete. Bad: any policy still references it — Microsoft's API blocks the delete, but don't rely on the block alone; confirm no *resource* still expects it either (a stale label reference will simply stop protecting content once the context is gone, with no error surfaced to the label owner).

---

## Troubleshooting Steps (by phase)

**Phase 1 — Licensing & feature availability**
Confirm Entra ID P1 minimum. If the specific consumer surface is SharePoint sensitivity labels or direct site tagging, separately confirm the SharePoint-specific licensing floor (M365 E5, or E3+Advanced Compliance for labels; M365 E5 or SharePoint Advanced Management/Copilot for direct site tagging) — Entra P1 alone is necessary but not sufficient for those two surfaces.

**Phase 2 — Context object state**
Confirm the context exists, is published (`IsAvailable = true`), and its ID matches exactly what every downstream surface expects. A context ID typo (c3 vs. c5) between a label and its CA policy is the single most common root cause across every consumer surface.

**Phase 3 — Consumer-surface tagging (the step most often skipped)**
Because there is no unified inventory, walk each of the four native surfaces (plus any custom app's own mapping, which requires asking the app owner) individually. Don't assume "the CA policy is correct" means "something is actually emitting this context" — those are independent facts.

**Phase 4 — CA policy targeting and grant control**
Confirm the policy targets "Authentication context" specifically (not Cloud apps with a suggestive name), selects the correct context ID, is in the correct `State`, and carries the intended grant control. For PIM specifically, also confirm the policy doesn't exclude the affected user and isn't in Report-only — these two states specifically defeat the backup protection mechanism.

**Phase 5 — Claims-challenge transport and client capability**
If the tenant-side configuration checks out across Phases 1–4 but the user still isn't challenged, confirm the requesting client/app is claims-challenge-aware. Native Microsoft surfaces (SharePoint web, PIM's own activation UI) handle this natively; custom/LOB apps require explicit MSAL implementation, and older/legacy app versions are a common, undiagnosed dead end here.

**Phase 6 — Opportunistic evaluation sanity check**
Before concluding a policy "isn't firing" from a user's own account of not being prompted, check the sign-in log directly. A satisfied context added opportunistically produces zero user-visible signal by design — this phase exists specifically to prevent chasing a non-existent bug based on user-reported experience alone.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Rolling out a new Authentication Context end-to-end (design → pilot → enforce)</summary>

**Goal:** Stand up a new context cleanly, with a documented ID-to-purpose mapping, validated against a pilot group before wide enforcement.

1. **Document the mapping first, before creating anything.** Decide what business scenario this context represents (e.g., "c7 = access to the Finance restricted SharePoint site") and record it somewhere durable — nothing in the product does this for you, and with up to 99 possible contexts, undocumented ad hoc allocation becomes unmanageable fast.
2. Create the context and publish it:
   ```powershell
   New-MgIdentityConditionalAccessAuthenticationContextClassReference `
       -Id "c7" -DisplayName "Finance restricted access" -IsAvailable
   ```
3. Build the CA policy in Report-only first, scoped to a pilot group, targeting "Authentication context" with the new ID and the intended grant control (commonly a Require Authentication Strength grant paired with this — see `AuthenticationStrengths-A.md`).
4. Tag exactly one pilot resource with the context (a single SharePoint label applied to a test site, or one Protected Action) — validate the full chain end-to-end using Validation Steps 1–5 above before tagging anything else.
5. Confirm sign-in logs show the pilot policy evaluating and satisfying correctly for pilot users, and confirm non-pilot users are unaffected.
6. Flip the CA policy from Report-only to On, still pilot-scoped. Monitor for a full business cycle.
7. Expand scope (both the CA policy's user/group assignment and the number of tagged resources) incrementally, re-validating after each expansion.

**Rollback:** Set the CA policy back to Report-only or Off at any stage — tagged resources remain tagged but the context is no longer enforced. Un-publish the context (`IsAvailable = $false`) to also prevent any *new* consumer from selecting it, without affecting already-tagged resources.

</details>

<details><summary>Playbook 2 — Securing PIM role activation against the backup-protection gap</summary>

**Goal:** Ensure a PIM-role-plus-Authentication-Context design actually enforces the intended stronger method in all states, not just the happy path.

1. Create and **fully enable** (not Report-only) a CA policy targeting the intended context ID, with no exclusions covering any user who will hold the PIM-eligible role. Do this *before* configuring the PIM side — Microsoft's own guidance leads with this order specifically because of the backup-protection interaction.
2. Pair the CA policy's grant control with a specific Authentication Strength (e.g., phishing-resistant) rather than plain MFA — otherwise the PIM-side configuration adds complexity without meaningfully raising the bar over the native "Require MFA on activation" toggle.
3. Configure the role's Activation tab: select "On activation, require Microsoft Entra Conditional Access authentication context" and choose the matching context ID.
4. Validate all four states explicitly, not just confirm-it-works-once: test activation with the CA policy On, then temporarily set it to Report-only and re-test (expect fallback to plain MFA per the backup mechanism), then temporarily exclude the test user (expect NO elevated requirement — the dangerous case), then restore the policy to its intended On/included state. Document the observed behavior at each state for the client's own future reference.
5. If reauthentication is required on *every* activation regardless of existing session state, set the CA policy's Session Controls → Sign-in frequency to "Every time" — without this, a user who authenticated recently satisfies the context opportunistically and PIM won't visibly re-prompt them.

**Rollback:** Clear the context selection on the role's Activation tab — the role reverts to whatever native MFA/approval settings remain configured, no PIM-side data loss.

</details>

<details><summary>Playbook 3 — Safely retiring an Authentication Context</summary>

**Goal:** Remove a context that's no longer needed without silently breaking whatever still references it.

1. Inventory every CA policy referencing the context ID (Validation Step 7) and every consumer-surface tag across all four surfaces (Validation Step 4) — build a complete "what breaks if I remove this" list before touching anything.
2. Re-point or remove each CA policy's reference to the context first. A CA policy can simply be deleted or edited to remove the context condition; do this before touching the context object itself.
3. Un-publish the context (`IsAvailable = $false`) — this immediately prevents any *new* consumer from selecting it while leaving already-tagged resources functioning until you handle them explicitly in the next step.
4. Remove the tag from each consumer-surface resource identified in step 1 (clear the sensitivity label's Conditional Access setting, clear `Set-SPOSite -ConditionalAccessPolicy None`, remove the PIM role's Activation-tab selection, remove the Protected Action assignment).
5. Once no CA policy references it and it's unpublished, delete the context object:
   ```powershell
   Remove-MgIdentityConditionalAccessAuthenticationContextClassReference -AuthenticationContextClassReferenceId "c7"
   ```
   Microsoft's API blocks this while any CA policy still references the context — treat that block as a safety net, not as your primary verification step, since a stale *resource*-side reference (e.g., a label still pointing at now-orphaned context) won't trigger it.

**Rollback:** If deletion hasn't happened yet, simply re-publish (`IsAvailable = $true`) and re-attach the CA policy condition — no data was lost. Once actually deleted, the context ID and its historical audit trail cannot be restored; a "new" context reusing the same ID number is a distinct object with no memory of the old one.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Authentication Context configuration and sign-in evidence for escalation.
.DESCRIPTION Read-only. Gathers context definitions, CA policy targeting, SharePoint tagging state
             (both label-based and direct), PIM activation settings for a specified role, and
             recent sign-in log correlation for a specified user. Does not modify any setting.
#>
param(
    [string]$ContextId,
    [string]$UserPrincipalName,
    [string]$SharePointSiteUrl,
    [string]$RoleDefinitionId
)

Connect-MgGraph -Scopes "Policy.Read.All","AuditLog.Read.All","Organization.Read.All" -NoWelcome

$evidence = [ordered]@{
    Licensing        = Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "AAD_PREMIUM" } |
                            Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}
    Contexts         = Get-MgIdentityConditionalAccessAuthenticationContextClassReference |
                            Select-Object Id, DisplayName, IsAvailable
    TargetingPolicies = Get-MgIdentityConditionalAccessPolicy -All |
                            Where-Object { $_.Conditions.Applications.IncludeAuthenticationContextClassReferences -contains $ContextId } |
                            Select-Object DisplayName, State, @{N="ExcludedUsers";E={$_.Conditions.Users.ExcludeUsers -join ", "}}
    SignInEvidence   = if ($UserPrincipalName) {
                            Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UserPrincipalName'" -Top 25 |
                                Select-Object CreatedDateTime, AppDisplayName, ResourceDisplayName,
                                    @{N="CAPolicies";E={$_.AppliedConditionalAccessPolicies | ForEach-Object { "$($_.DisplayName): $($_.Result)" }}}
                        } else { "No UserPrincipalName supplied" }
    RoleActivation   = if ($RoleDefinitionId) {
                            Invoke-MgGraphRequest -Method GET `
                                -Uri "https://graph.microsoft.com/beta/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole' and roleDefinitionId eq '$RoleDefinitionId'"
                        } else { "No RoleDefinitionId supplied" }
}

$evidence | ConvertTo-Json -Depth 6 | Out-File ".\AuthContext-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').json"

if ($SharePointSiteUrl) {
    Write-Host "Run separately against the SPO admin connection (Connect-SPOService):" -ForegroundColor Yellow
    Write-Host "  Get-SPOSite -Identity '$SharePointSiteUrl' | Select-Object Url, ConditionalAccessPolicy"
    Write-Host "  Get-SPOTenant | Select-Object EnableAIPIntegration, BlockAppAccessWithAuthenticationContext"
}

Write-Host "Evidence collected. Attach the JSON export plus a Get-AuthContextAudit.ps1 findings CSV to the ticket." -ForegroundColor Green
```

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-MgSubscribedSku \| Where ServicePlans -match AAD_PREMIUM` | Confirm P1/P2 licensing floor |
| `Get-MgIdentityConditionalAccessAuthenticationContextClassReference` | List all contexts + published state |
| `New-MgIdentityConditionalAccessAuthenticationContextClassReference` | Create a new context |
| `Update-MgIdentityConditionalAccessAuthenticationContextClassReference -IsAvailable` | Publish/unpublish a context |
| `Remove-MgIdentityConditionalAccessAuthenticationContextClassReference` | Delete a context (blocked while CA-policy-referenced) |
| `Get-MgIdentityConditionalAccessPolicy -All \| Select Conditions.Applications.IncludeAuthenticationContextClassReferences` | Find which CA policies actually target a context |
| `Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'"` | Confirm claims-challenge completion, per user |
| `Get-Label` (Purview/Security & Compliance PowerShell) | Inspect sensitivity label auth-context config |
| `Get-SPOSite -Identity <url> \| Select ConditionalAccessPolicy` | Check direct site-level tagging |
| `Set-SPOSite -ConditionalAccessPolicy AuthenticationContext -AuthenticationContextName <name>` | Apply/remove direct site tagging |
| `Get-SPOTenant \| Select EnableAIPIntegration, BlockAppAccessWithAuthenticationContext` | Confirm both SharePoint tenant-wide toggles |
| `Get-MgPolicyAuthorizationPolicy` | Inspect Protected Actions assignment |
| `Invoke-MgGraphRequest -Uri ".../beta/policies/roleManagementPolicyAssignments?..."` | Inspect a PIM role's Activation settings incl. auth-context binding |

---

## 🎓 Learning Pointers

- **The four consumer surfaces have zero shared inventory — "what's tagged with c7" is a question you answer by walking each surface, not by a single query.** Build a habit of checking all four (label, direct SPO tag, Protected Actions, PIM) before declaring a context unused or fully deployed. [Targeting resources in Conditional Access policies](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-cloud-apps#authentication-context)

- **Opportunistic ACRS evaluation means "the user wasn't prompted" and "the policy is protecting the resource" can both be true at once.** Always verify enforcement from the sign-in log's `AppliedConditionalAccessPolicies`, never from a user's recollection of being challenged. [Developer guide — expected behavior tables](https://learn.microsoft.com/en-us/entra/identity-platform/developer-guide-conditional-access-authentication-context#authentication-context-acrs-in-conditional-access-expected-behavior)

- **PIM's backup-protection mechanism is a narrow safety net, not a general guarantee.** It only substitutes MFA when the CA policy is entirely missing — a policy that exists but is Off, Report-only, or excludes the user produces *no* elevated requirement at all, silently. Validate all four states before trusting a PIM-plus-context design. [Configure Azure resource role settings in PIM](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-resource-roles-configure-role-settings#on-activation-require-microsoft-entra-conditional-access-authentication-context)

- **SharePoint has two structurally separate tagging paths (label vs. direct `Set-SPOSite`) that don't show up in each other's admin surface.** A "the label looks fine but the site is still gated / still open" ticket should always check both before assuming corruption or a bug. [Conditional access policy — SharePoint](https://learn.microsoft.com/en-us/sharepoint/authentication-context-example)

- **The context limit was raised from 25 to 99 (`c1`–`c99`)** — if you're referencing older internal documentation, training material, or a colleague's memory that says "25," treat the product itself (via `Get-MgIdentityConditionalAccessAuthenticationContextClassReference`) as authoritative, not any cached number. [Configure authentication contexts](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-cloud-apps#configure-authentication-contexts)

- **A CA policy targeting Authentication Context can scope to users or workload identities, never both in one policy.** A tenant protecting both service-principal and human access to the same sensitive scenario needs two separate CA policies referencing the same context ID, not one combined policy. [Authentication context overview](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-cloud-apps#authentication-context)
