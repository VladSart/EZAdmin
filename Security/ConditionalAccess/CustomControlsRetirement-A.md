# Conditional Access Custom Controls Retirement — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the retirement mechanics and migration architecture, not just the fix commands.

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

This runbook covers the **retirement of Conditional Access Custom Controls** — the legacy, preview-era
extensibility mechanism that let a Conditional Access policy grant control redirect a sign-in to a
third-party MFA provider (Duo, RSA, and similar vendors were the common integrations) via a
provider-supplied URL and tenant ID. Per Microsoft 365 Message Center announcement **MC1422061**, the
mechanism is being retired on a two-stage timeline:

- **September 2026** — creation/modification cutoff. No new Custom Controls can be created; no existing
  Custom Control can be edited (including routine maintenance like secret rotation).
- **May 2027** — full functional retirement. Any Conditional Access policy still relying on a Custom
  Control at this point stops satisfying that grant control entirely.

The designated replacement is **External Authentication Methods (External MFA)** — a GA, standards-based
OIDC integration surface covered in full in `EntraID/Troubleshooting/ExternalMFA-A.md`/`-B.md`. This
runbook is deliberately scoped narrower than that one: it covers *only* the retirement timeline, the
blast-radius/impact-assessment question ("does this affect us at all"), and the migration project
mechanics of moving a specific CA policy's grant control off a Custom Control. It does not re-document
External MFA's own configuration, consent model, or OIDC handshake — see the External MFA runbook for
that once a migration target provider integration is being stood up.

**Assumes:**
- Microsoft Graph PowerShell SDK: `Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser`
- Authenticated with `Connect-MgGraph` and `Policy.Read.All` (read) or `Policy.ReadWrite.ConditionalAccess`
  (write, for the eventual policy cutover) scopes
- A Conditional Access Administrator role to read/modify CA policies; Authentication Policy Administrator
  and Privileged Role Administrator are both needed on the External MFA side of the migration (see that
  runbook — the consent-role split is the most common rollout blocker there, not here)
- Entra ID P1 or higher (Conditional Access itself is licensed separately from this specific feature)

**Not covered:** External MFA's own OIDC trust handshake, consent model, and day-2 troubleshooting (see
`EntraID/Troubleshooting/ExternalMFA-A.md`); general Conditional Access policy design (see
`CA-Design-A.md`); the separate, unrelated passkey-default-authentication / SMS-Voice retirement rollout
(see `EntraID/Troubleshooting/PasskeyDefaultAuth-A.md`) — both are Entra-side September 2026 changes but
are otherwise independent projects with independent timelines.

---
## How It Works

<details><summary>Full architecture</summary>

### What a Custom Control actually was

A Conditional Access Custom Control is a grant control type — alongside "Require MFA," "Require compliant
device," etc. — that, instead of Entra ID evaluating the requirement itself, redirects the sign-in session
to a third-party-hosted URL associated with a specific tenant ID registered with that provider. The
provider does whatever authentication work it wants (push notification, hardware key challenge, etc.) out
of band, then redirects the session back to Entra ID with a signal indicating pass/fail. Unlike External
MFA's OIDC contract (typed `acr`/`amr` claims Entra ID validates against a fixed vocabulary — see the
External MFA runbook), Custom Controls predate that standardized handshake and rely on a much thinner,
largely opaque trust relationship between Entra ID and the provider's own redirect endpoint. This opacity
is precisely why Microsoft treats it as a legacy mechanism worth retiring rather than hardening further.

### Why this is being retired rather than patched

Microsoft's own migration guidance frames Custom Controls as a **preview-era mechanism that never reached
GA maturity** — it lacks the claims-based validation model, the consent-gated app registration, and the
signed-token verification that External MFA's OIDC implementation provides natively. Rather than retrofit
those protections onto the old redirect model, Microsoft built External MFA as a parallel, better-specified
replacement and is now sunsetting the original. This is the same pattern as several other Entra legacy
mechanisms retired in favor of a standards-based successor — the operational lesson is the same each time:
a "still works" legacy feature with an announced retirement date is not a low-priority item, because the
cutoff for *creating or modifying* it lands well before the cutoff for it *functioning*, and organizations
that wait for the functional cutoff lose the ability to make any interim adjustments during the window
where they'd most want to (e.g., rotating a compromised secret).

### The two-cutoff structure and its operational trap

The eight-month gap between the September 2026 creation/modification freeze and the May 2027 functional
retirement is deliberately generous — but it creates a specific trap: a Custom Control that is working
today and needs no changes will keep silently working right up until May 2027, giving zero forcing
function to migrate early. Teams that treat "still works" as "not urgent" commonly discover the real
urgency only when something *forces* a change during the frozen window — a provider certificate expiring,
a tenant ID needing to move, a provider deprecating their own side of the integration — at which point the
Custom Control cannot be touched at all, and an emergency External MFA migration has to happen under time
pressure instead of on a planned schedule. The correct read of this timeline is: treat September 2026 as
the actual deadline for starting migration planning, not May 2027.

### Why Custom Control provider-side detail isn't visible via Graph

Unlike External MFA (which stores `appId`, `clientId`, and `discoveryUrl` as structured properties on an
`externalAuthenticationMethodConfiguration` object queryable via
`/policies/authenticationMethodsPolicy/authenticationMethodConfigurations`), a Custom Control's
provider-specific configuration — which URL, which tenant ID, which provider — lives in the **Custom
Controls (Preview)** blade of the Conditional Access UI, not in a Graph-queryable resource with the same
level of structured detail as v1.0 exposes for other grant control types. A CA policy's
`GrantControls.CustomAuthenticationFactors` property confirms *that* a policy references a Custom Control,
but resolving *which* provider that control points to requires cross-referencing the admin center UI (or
the organization's own change-management documentation of what was configured and when) — there is no
single Graph call that returns both facts together. Build any inventory/audit tooling around this
constraint rather than assuming full provider detail is programmatically recoverable.

### The exclusivity requirement during migration

Both this runbook and the External MFA runbook's Playbook 2 emphasize the same architectural constraint:
during migration, a user must be in scope for **either** the legacy Custom Control policy **or** the new
External MFA policy, never both simultaneously. Because Entra ID evaluates all applicable CA policies
independently and does not de-duplicate equivalent grant requirements across them, a user caught in both
policies at once is redirected to the (functionally equivalent) provider twice in the same sign-in
attempt — once per policy. This is not a bug in either mechanism; it is a direct consequence of CA's
"all matching policies' controls must be satisfied" evaluation model applied to two policies that happen
to target overlapping populations with overlapping (but structurally distinct) grant controls.

</details>

---
## Dependency Stack

```
[Legacy: Custom Controls (Preview) admin blade]
  └── Provider-specific configuration: redirect URL, provider tenant ID
        (NOT structured/queryable via Graph at the same fidelity as External MFA)
              └── CA policy grant control: GrantControls.CustomAuthenticationFactors
                    └── [Sept 2026] Creation/modification FROZEN
                          ├── Existing controls keep functioning operationally
                          └── No edits possible — secret rotation, URL changes, etc.
                                all blocked from this date forward
                                      └── [May 2027] Functional retirement
                                            └── Any policy still on a Custom Control grant
                                                fails that control entirely from this date

[Parallel/replacement track: External Authentication Methods]
  └── See EntraID/Troubleshooting/ExternalMFA-A.md for the full stack —
      appId/clientId/discoveryUrl → admin consent (Privileged Role Admin) →
      includeTargets/excludeTargets → CA "Require MFA" grant (NOT auth strength) →
      OIDC handshake with acr/amr claim validation
        └── Migration constraint: target population must be MUTUALLY EXCLUSIVE
            between the legacy Custom Control policy and the new External MFA policy
            for the duration of the migration — overlap produces a double-redirect,
            not a failure, but is a signal the exclusion scoping is wrong
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Admin can't create a new Custom Control at all | Expected — creation frozen from September 2026 | Confirm current date is past the cutoff; this is not a bug |
| Admin can't edit/rotate a secret on an existing Custom Control | Expected — modification frozen from September 2026, no exceptions including maintenance | Same as above; plan the External MFA migration instead of attempting a workaround edit |
| Existing Custom Control simply stops authenticating users | If before May 2027: **not** the retirement — investigate as a normal provider-side or CA policy issue | Provider status, CA policy state/exclusions, sign-in logs |
| Existing Custom Control stops authenticating users on/after May 2027 | Expected — full functional retirement reached | Confirm date; this policy needed to be migrated before this point |
| User redirected to the provider twice in one sign-in during migration | User is in scope for both the legacy Custom Control policy and the new External MFA policy simultaneously | CA policy assignments/exclusions on both policies — see Troubleshooting Phase 3 |
| Team can't find which provider a given Custom Control points to via Graph | Expected — Graph exposes only `CustomAuthenticationFactors` presence, not full provider detail | Cross-reference Entra admin center Custom Controls (Preview) blade or internal change-management records |
| Uncertainty whether the tenant is affected at all | Most tenants using native Entra MFA/FIDO2/WHfB have zero Custom Controls configured | Run the Triage query in `CustomControlsRetirement-B.md`; zero results = no action needed |

---
## Validation Steps

**1. Confirm Graph connection and scope**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"
Get-MgContext | Select-Object Scopes
```
Expected: `Policy.Read.All` present.

**2. Inventory every CA policy referencing a Custom Control grant**
```powershell
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.GrantControls.CustomAuthenticationFactors } |
    Select-Object DisplayName, Id, State,
        @{N="CustomFactors";E={$_.GrantControls.CustomAuthenticationFactors}}
```
Expected: Zero rows on tenants never configured with a Custom Control — treat that as confirmation of
no impact, not an incomplete query. One row per affected policy otherwise.

**3. Confirm current External Authentication Method configurations**
```powershell
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations" |
    Select-Object -ExpandProperty value |
    Where-Object { $_."@odata.type" -match "externalAuthenticationMethod" } |
    Select-Object id, appId, state
```
Expected: Populated only for providers already migrated (or mid-migration). Empty result for a tenant
that has Custom Controls but hasn't started migrating yet — this is the expected starting state for a
migration project.

**4. Confirm the target migration date is inside the safe planning window**
No Graph query answers this — check today's date against the two published cutoffs (September 2026
creation/modification freeze, May 2027 functional retirement) and treat any Custom Control found in
Step 2 as needing a completed migration before May 2027, with all *configuration* work needing to happen
inside whatever window remains before September 2026 if any control-side edits (not just the CA policy
grant control) are still needed.

---
## Troubleshooting Steps (by phase)

### Phase 1: Impact Assessment

1. Run the Step 2 inventory query — zero results means no further action is needed on this topic for
   this tenant.
2. For each policy found, note its `State` (On/Off/Report-only) — an Off or Report-only policy still
   needs migrating if it's expected to be turned on before May 2027, but carries no immediate operational
   urgency.

### Phase 2: Provider Identification

1. For each affected policy, resolve which third-party provider the Custom Control points to via the
   Entra admin center's Custom Controls (Preview) blade (not fully recoverable via Graph — see How It
   Works).
2. Confirm with the provider (or internal documentation) whether they publish External MFA migration
   guidance — most major providers that supported Custom Controls have published their own since this
   retirement was announced.

### Phase 3: Migration Execution (mirrors External MFA runbook Playbook 2)

1. Stand up and fully validate the External MFA method configuration against a small pilot group —
   follow `EntraID/Troubleshooting/ExternalMFA-A.md` Playbook 1 end-to-end before touching the existing
   Custom Control policy at all.
2. Create a new CA policy with grant control "Require multifactor authentication" (never an
   authentication strength — see the hard incompatibility documented in the External MFA runbook),
   scoped only to the same pilot group.
3. Explicitly exclude the pilot group from the legacy Custom Control policy (or scope the legacy policy
   to exclude anyone now in the new policy). Verify this exclusivity directly — this is what prevents the
   double-redirect symptom, not an assumption to leave unverified.
4. Validate pilot sign-ins end-to-end, then incrementally expand both the External MFA method's
   `includeTargets` and the new CA policy's assignment together, shrinking the legacy policy's scope in
   lockstep.
5. Once 100% of the target population is migrated and validated, set the legacy Custom Control policy to
   Off entirely — do not leave it in an excluded-but-still-enabled state indefinitely, since an
   accidental future re-inclusion would silently reintroduce the double-redirect risk.

### Phase 4: Post-Migration Verification

1. Re-run the Step 2 inventory query — the migrated policy should either be deleted or show `State = Off`
   with the Custom Control grant control removed.
2. Confirm the corresponding External MFA method configuration shows `state = enabled` and the full
   target population in `includeTargets`.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full Impact Assessment for a Tenant with Unknown Custom Controls Usage</summary>

Use when: Taking over administration of a tenant, or performing pre-migration due diligence, and it's
not yet known whether any Custom Controls are configured.

```powershell
Connect-MgGraph -Scopes "Policy.Read.All"

# Step 1: Full CA policy inventory with Custom Control flag
$policies = Get-MgIdentityConditionalAccessPolicy -All
$customControlPolicies = $policies | Where-Object { $_.GrantControls.CustomAuthenticationFactors }

if ($customControlPolicies.Count -eq 0) {
    Write-Host "No Custom Controls found — tenant is not affected by this retirement." -ForegroundColor Green
} else {
    Write-Host "Found $($customControlPolicies.Count) polic(y/ies) referencing a Custom Control:" -ForegroundColor Yellow
    $customControlPolicies | Select-Object DisplayName, Id, State |
        Format-Table -AutoSize
    Write-Host "Cross-reference each policy against the Entra admin center's Custom Controls (Preview)" -ForegroundColor Yellow
    Write-Host "blade to identify the specific third-party provider before planning migration." -ForegroundColor Yellow
}

# Step 2: Check current External MFA readiness (already-migrated or in-progress providers)
$existingExternalMFA = Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations" |
    Select-Object -ExpandProperty value |
    Where-Object { $_."@odata.type" -match "externalAuthenticationMethod" }
$existingExternalMFA | Select-Object id, appId, state
```

**Rollback:** N/A — read-only assessment.

</details>

<details><summary>Playbook 2 — Verifying Exclusivity Before Expanding Migration Scope</summary>

Use when: Mid-migration, before expanding the pilot group to a wider population, to confirm no user is
double-targeted by both the legacy and new policies.

```powershell
$legacyPolicy = Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.GrantControls.CustomAuthenticationFactors } | Select-Object -First 1
$newPolicy = Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.DisplayName -eq "<new External MFA policy display name>" }

# Compare include/exclude targeting on both policies
[PSCustomObject]@{
    LegacyIncludeUsers = ($legacyPolicy.Conditions.Users.IncludeUsers -join ", ")
    LegacyExcludeUsers = ($legacyPolicy.Conditions.Users.ExcludeUsers -join ", ")
    NewIncludeUsers    = ($newPolicy.Conditions.Users.IncludeUsers -join ", ")
    NewExcludeUsers    = ($newPolicy.Conditions.Users.ExcludeUsers -join ", ")
}
```
Manually confirm every user/group in the new policy's include list appears in the legacy policy's
exclude list (or vice versa for groups still on the legacy path) before widening scope. There is no
single Graph call that resolves group membership overlap automatically — for large populations, expand
group membership via `Get-MgGroupMember` on both sides and diff the resulting user ID sets.

**Rollback:** N/A — read-only verification step, performed before any policy change.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Conditional Access Custom Controls retirement/migration evidence for escalation
.NOTES     Requires Microsoft.Graph.Identity.SignIns module and Policy.Read.All scope
#>

$outputPath = "C:\CACustomControls_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$policies = Get-MgIdentityConditionalAccessPolicy -All
$customControlPolicies = $policies | Where-Object { $_.GrantControls.CustomAuthenticationFactors }
$customControlPolicies | Select-Object DisplayName, Id, State,
    @{N="CustomFactors";E={$_.GrantControls.CustomAuthenticationFactors -join ", "}} |
    Export-Csv "$outputPath\custom_control_policies.csv" -NoTypeInformation

$externalMFA = Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations" |
    Select-Object -ExpandProperty value |
    Where-Object { $_."@odata.type" -match "externalAuthenticationMethod" }
$externalMFA | ConvertTo-Json -Depth 6 | Out-File "$outputPath\external_mfa_methods.json"

Write-Host "NOTE: which third-party provider each Custom Control points to is not fully resolvable" -ForegroundColor Yellow
Write-Host "via Graph — cross-reference the Entra admin center's Custom Controls (Preview) blade and" -ForegroundColor Yellow
Write-Host "attach that detail manually alongside this evidence pack." -ForegroundColor Yellow

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# Inventory every CA policy referencing a Custom Control
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.GrantControls.CustomAuthenticationFactors } |
    Select-Object DisplayName, Id, State

# List all External MFA method configurations (migration target state)
$policy = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy" -Method GET
$policy.authenticationMethodConfigurations | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.externalAuthenticationMethodConfiguration' }

# Compare a legacy and new policy's user targeting before expanding migration scope
Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId "<policyId>" |
    Select-Object -ExpandProperty Conditions

# NOT available via Graph as of this writing:
#   - Which specific third-party provider a Custom Control redirects to (admin center UI only)
#   - A single call that resolves group-membership overlap between two policies' targeting
```

---
## 🎓 Learning Pointers

- **The creation/modification cutoff (September 2026) is the real deadline, not the functional
  retirement (May 2027).** A working Custom Control gives zero forcing function to migrate early — the
  actual risk is an unplanned need to edit one (secret rotation, provider change) during the frozen
  window, when no edit path exists at all. Plan migration relative to September 2026, not May 2027.
  [MC1422061 — Retirement of Custom Controls in Conditional Access and migration to External MFA]
  (https://mc.merill.net/message/MC1422061)
- **Custom Controls predate External MFA's standardized claims-based trust model.** Understanding *why*
  Microsoft is retiring rather than patching this mechanism (thin, largely opaque provider trust vs.
  External MFA's signed `acr`/`amr` OIDC contract) helps set client expectations that this is a genuine
  security-posture upgrade, not just administrative churn.
- **Graph cannot fully resolve which provider a given Custom Control points to.** Any audit tooling
  (including the companion script in this folder) can only confirm *that* a policy references a Custom
  Control, not *which* provider — budget time for a manual cross-reference against the admin center or
  internal change records before scoping a migration project.
- **The exclusivity requirement during migration is the same architectural pattern as the External MFA
  runbook's own Playbook 2** — don't design a novel migration approach; reuse that proven parallel-run
  pattern (pilot group → verify exclusivity → incrementally expand → decommission) rather than a
  big-bang cutover, which offers no safe rollback window.
- **This is one of two adjacent-but-independent September 2026 Entra changes** — don't conflate this
  with the passkey-default-authentication / SMS-Voice retirement rollout
  (`EntraID/Troubleshooting/PasskeyDefaultAuth-A.md`). Both share a month and a general "legacy
  auth-adjacent mechanism being retired" theme, but have entirely separate timelines, triggers, and
  remediation paths — verify which one a ticket actually concerns before applying either runbook.
