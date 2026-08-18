# Azure AD B2C → Microsoft Entra External ID Migration — Hotfix Runbook (Mode B: Ops)
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

**Scope check first:** this file is for the **broader Azure AD B2C → Microsoft Entra External ID migration project** — tenant assessment, the Migration Policy Analyzer, standard vs. High Scale Compatibility (HSC) mode, password-preservation approach, and application cutover. If the ticket is specifically about a **JIT password-migration extension not firing** once you're already mid-cutover, go to `CIAMMigration-B.md` instead — that file owns the `OnPasswordSubmit` mechanism in detail.

```powershell
Connect-MgGraph -Scopes "Directory.Read.All","Application.Read.All","Policy.Read.All" -Environment Global

# 1. Which tenant are you actually in — legacy B2C or destination External ID?
Get-MgOrganization | Select-Object DisplayName, Id, TenantType, VerifiedDomains

# 2. Directory object count — the HSC-mode eligibility threshold is ~5 million objects
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directoryObjects/`$count" -Headers @{ "ConsistencyLevel" = "eventual" })

# 3. Is the client app still pointed at B2C endpoints, or already re-pointed at External ID?
Get-MgApplication -ApplicationId "<client-app-object-id>" |
  Select-Object DisplayName, SignInAudience, Web, Spa, PublicClient

# 4. Does the destination External ID tenant have the app registered at all?
Get-MgApplication -Filter "displayName eq '<app-display-name>'" | Select-Object Id, AppId, DisplayName

# 5. Confirm your own role can actually run the Migration Policy Analyzer
Get-MgUserMemberOf -UserId (Get-MgContext).Account -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty AdditionalProperties |
  Where-Object { $_.displayName -match "B2C IEF Policy Administrator|Global Administrator" }
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| `TenantType` shows the legacy B2C tenant, not a fresh External ID tenant | Destination tenant not created yet — Stage 2 (Prepare destination) hasn't started | → Fix 1 |
| Directory object count ≥ ~5,000,000 | Tenant may be HSC-mode eligible — standard migration risk profile changes | → Fix 2 |
| Client app `Web`/`Spa` redirect URIs still list `*.b2clogin.com` | App not yet cut over to External ID endpoints — auth will keep hitting B2C | → Fix 3 |
| App exists in B2C but not in destination tenant | Application registration step (Stage 2) skipped for this app | → Fix 4 |
| No `B2C IEF Policy Administrator`/`Global Administrator` role held | Can't reach Migration Policy Analyzer in the B2C portal — RBAC gap, not a tool bug | → Fix 5 |
| Analyzer report shows features as `Not Currently Supported` or `Architecture Incompatible` | Genuine product gap for this policy — needs a scoping decision, not a config fix | → Fix 6 |
| Users report password reset loops right after cutover | Password-preservation approach wasn't chosen deliberately before cutover | → Fix 7 |
| Social sign-in (Google/Facebook/etc.) broken after cutover | Social IdPs configured *inside B2C custom policies* aren't carried over automatically | → Fix 8 |

---
## Dependency Cascade

<details><summary>What must be true before an application can safely cut over</summary>

```
Decision: Standard migration vs. High Scale Compatibility (HSC) mode
├── Standard (recommended for most tenants, <~5M directory objects)
│   └── New destination External ID tenant created
│       └── Security/compliance/monitoring baseline configured (Stage 2)
│           └── Applications registered fresh in External ID (not reused from B2C)
│               └── User flows (or custom-auth-extension equivalents) configured
│                   └── Users + credentials migrated (Stage 3)
│                       ├── No password preservation needed → SSPR / passwordless / plaintext-set-via-Graph
│                       └── Password preservation needed
│                           ├── JIT (External ID-initiated) — see CIAMMigration-B.md/-A.md for the mechanism
│                           └── B2C-initiated (legacy IdP-initiated credential harvesting via B2C custom policy + REST API)
│                               └── Application cutover (Stage 4) — DNS/redirect URIs re-pointed
│                                   └── Legacy B2C tenant decommissioned only after full cutover + soak
└── HSC mode (only for ~5M+ object tenants, and only if limitations are accepted)
    └── Tenant enabled for HSC mode (B2C and External ID run side-by-side, same tenant)
        └── New app registrations only — never reuse existing B2C app registrations
            └── Single-tenant app config only (multitenant unsupported for External ID endpoints)
                └── Apps migrated to External ID endpoints one at a time, B2C endpoints untouched for the rest
                    └── Hard feature gaps apply for the life of HSC mode: no social IdPs, no passkeys,
                        no age gating, no admin-portal experience, limited Conditional Access
```

**Everything upstream of "Application cutover" is reversible.** Once an application's redirect URIs and client config point at External ID and users are authenticating there, rolling back means re-pointing the app *and* reconciling any state written to External ID since cutover — treat cutover as the one-way door in this dependency chain, not tenant creation or user migration.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm which migration approach was actually decided, not assumed**
```powershell
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directoryObjects/`$count" -Headers @{ "ConsistencyLevel" = "eventual" })
```
- Expected: a number well under 5,000,000 → standard migration is correct, stop second-guessing HSC mode
- Bad: at or above ~5,000,000 → confirm HSC mode was actually the chosen path (check tenant settings), don't assume standard migration docs apply

**Step 2 — Run or re-check the Migration Policy Analyzer (portal-only, not scriptable via Graph)**
```
Azure portal → Azure AD B2C tenant → Identity Experience Framework → Migration Policy Analyzer
→ select policies (must include a relying party policy) → Analyze Policies
```
- Expected: a Migration Summary with feature counts by status (Available / Custom Development Required / Not Currently Supported / Architecture Incompatible)
- Bad: `CallerError` result — usually invalid XML or a missing base policy (`TrustFrameworkBase`/`TrustFrameworkExtensions`) not uploaded to the tenant being analyzed

**Step 3 — Validate the destination tenant has the application registered and configured**
```powershell
Get-MgApplication -Filter "displayName eq '<app-display-name>'" |
  Select-Object Id, AppId, SignInAudience, Web, Spa
```
- Expected: one application object, `SignInAudience = AzureADMyOrg` (single-tenant) unless deliberately multitenant, redirect URIs pointing at External ID
- Bad: no result → app was never registered in the destination tenant (Stage 2 skipped); two+ results → duplicate registration, confirm which one the client actually uses

**Step 4 — Confirm the password-preservation decision was actually implemented, not just discussed**
```powershell
# JIT approach — confirm the custom authentication extension exists (see CIAMMigration-B.md Triage for the full check)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" |
  Select-Object -ExpandProperty value | Where-Object { $_."@odata.type" -match "onPasswordSubmit" }
```
- Expected: an extension exists if JIT was the chosen approach; none needed if the plan was reset-after-migration or plaintext-set-via-Graph
- Bad: no extension, no SSPR communication sent, and users are already cut over → nobody can sign in — this is the most common "we migrated and now nobody can log in" root cause

**Step 5 — Confirm social/enterprise identity providers were rebuilt, not assumed carried over**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identity/identityProviders" |
  Select-Object -ExpandProperty value | Select-Object identityProviderType, name
```
- Expected: every social/enterprise IdP the B2C tenant used is listed here, configured natively in External ID
- Bad: missing providers → these were configured *inside B2C custom policies*, which the standard migration does not carry forward automatically

**Step 6 — Confirm application cutover state matches what users are experiencing**
```powershell
Get-MgApplication -ApplicationId "<client-app-object-id>" | Select-Object -ExpandProperty Web | Select-Object RedirectUris
```
- Expected: redirect URIs point at the External ID tenant's CIAM authority, not `*.b2clogin.com`
- Bad: still B2C — the client app itself (mobile build, SPA config, backend) hasn't shipped the endpoint change yet; this is an application-side deploy gap, not an Entra config gap

---
## Common Fix Paths

<details><summary>Fix 1 — Destination External ID tenant not created / not prepared</summary>

**Symptom:** Migration is "in progress" per the project plan, but there's no External ID tenant to point anything at yet.

```
1. Create the external tenant: Azure portal → Create a resource → Microsoft Entra External ID
2. Configure baseline security/compliance/monitoring BEFORE migrating any production users
3. Register applications fresh — do not attempt to reuse Azure AD B2C app registrations
```

This is a from-scratch setup step, not a troubleshooting fix — walk `B2CMigration-A.md` Remediation Playbook 1 (Stage 2: Prepare destination tenant) in full before touching user or credential migration.

**Rollback:** none needed — nothing has been cut over yet at this stage.

</details>

<details><summary>Fix 2 — Tenant is HSC-eligible but standard migration docs are being followed</summary>

**Symptom:** Directory object count is at or above ~5 million, but the team is following standard-migration steps that assume a clean cutover — leading to confusion about why passwords/users aren't "moving."

```powershell
# Confirm actual object count with a precise (non-estimated) query if the tenant is near the threshold
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directoryObjects/`$count" -Headers @{ "ConsistencyLevel" = "eventual" })
```

Escalate to a scoping conversation: HSC mode keeps existing users/credentials in place and migrates *applications* in phases — the mental model, feature availability, and Graph queries you use are different from standard migration. See `B2CMigration-A.md` Symptom → Cause Map for the full HSC-vs-standard decision criteria before proceeding further.

**Rollback:** not applicable — this is a scoping correction, not a change to make and undo.

</details>

<details><summary>Fix 3 — Client app still pointed at B2C endpoints</summary>

**Symptom:** Migration Policy Analyzer looks clean, users exist in External ID, but sign-in still routes through the old B2C tenant.

```powershell
$app = Get-MgApplication -ApplicationId "<client-app-object-id>"
$app.Web.RedirectUris

# Update redirect URIs to the External ID authority (example — confirm exact authority for your tenant)
$body = @{
    web = @{
        redirectUris = @("https://<your-ciam-tenant>.ciamlogin.com/<tenant-id>/oauth2/authresp")
    }
} | ConvertTo-Json -Depth 5
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/<client-app-object-id>" -Body $body -ContentType "application/json"
```

This is only the Entra-side half of the fix — the client application itself (mobile app build, SPA authority config, backend token validation) must also ship pointing at the new authority and issuer. Coordinate the deploy before flipping traffic.

**Rollback:** re-patch `redirectUris` back to the `*.b2clogin.com` values if you need to fail back to B2C.

</details>

<details><summary>Fix 4 — Application never registered in the destination tenant</summary>

**Symptom:** `Get-MgApplication -Filter "displayName eq '<app-display-name>'"` returns nothing in the External ID tenant.

```powershell
$body = @{
    displayName    = "<app-display-name>"
    signInAudience = "AzureADMyOrg"
    web            = @{ redirectUris = @("https://<your-ciam-tenant>.ciamlogin.com/<tenant-id>/oauth2/authresp") }
} | ConvertTo-Json -Depth 5
New-MgApplication -BodyParameter $body
```

Remember: **new registration, not a copy.** External ID app properties and Native Authentication support differ enough from B2C that reusing an old B2C app registration object is not supported — this applies in both standard and HSC mode.

**Rollback:** delete the newly created app registration if it was created in error (`Remove-MgApplication -ApplicationId <id>`); this doesn't affect the B2C-side registration.

</details>

<details><summary>Fix 5 — Can't reach the Migration Policy Analyzer (RBAC gap)</summary>

**Symptom:** Analyzer menu item is missing or access is denied in the B2C portal.

```powershell
Get-MgUserMemberOf -UserId (Get-MgContext).Account |
  Select-Object -ExpandProperty AdditionalProperties |
  Where-Object { $_.displayName -match "Administrator" } | Select-Object displayName
```

Required: **B2C IEF Policy Administrator** or **Global Administrator**, in the **B2C tenant itself** (not the destination External ID tenant — these are separate directories with separate role assignments). Also check Conditional Access isn't blocking portal access for this admin account.

**Rollback:** not applicable — this is a permissions grant, not a reversible config change.

</details>

<details><summary>Fix 6 — Analyzer reports Not Currently Supported / Architecture Incompatible features</summary>

**Symptom:** The migration assessment surfaces features with no clean migration path — commonly QR code authentication, WS-Federation, SAML artifact binding, inbound SAML encryption, CAPTCHA on sign-in, or age gating.

```
1. Confirm the feature is genuinely in use (not a false positive — the analyzer reads XML structure,
   not runtime behavior; cross-check against how the policy actually behaves in production)
2. Not Currently Supported → check the Microsoft Entra roadmap (https://aka.ms/entra-roadmap) for a
   committed date before designing a workaround
3. Architecture Incompatible → this is not a timeline gap, it's a pattern mismatch — plan an
   alternative design now rather than waiting on a future release
```

Age gating specifically has no current External ID equivalent in either standard or HSC mode — flag this early to stakeholders if the B2C tenant derives/stores minor-vs-major classification via custom policy; it changes the migration timeline, not just the technical approach.

**Rollback:** not applicable — this is a scoping/design decision.

</details>

<details><summary>Fix 7 — Password reset loops immediately after cutover</summary>

**Symptom:** Users can't sign in post-cutover; no password-preservation mechanism was actually implemented before the application was pointed at External ID.

```
1. Confirm which approach was supposed to be used — check the project plan / change record, don't guess
2. If none was implemented: users have no valid credential in External ID yet — the fastest safe recovery
   is forcing SSPR (self-service password reset) with a proactive email communication, not silently
   waiting for tickets to pile up
3. If JIT was supposed to be running: go to Diagnosis Step 4 above, then CIAMMigration-B.md Triage
   for the extension-specific checks
```

**Rollback:** re-point the application back to B2C endpoints (reverse of Fix 3) only as a last resort — this reopens the B2C/External ID identity-state-sync problem the migration was trying to close, so treat it as a stop-the-bleeding measure with an explicit re-cutover date, not a resolution.

</details>

<details><summary>Fix 8 — Social sign-in broken after cutover</summary>

**Symptom:** Google/Facebook/Apple (or other social) sign-in worked in B2C, fails or is missing entirely in External ID.

```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identity/identityProviders" |
  Select-Object -ExpandProperty value
```

If the provider isn't listed, it needs to be **reconfigured natively** in External ID (built-in social identity provider support) — third-party identity providers wired up purely through B2C custom policies are explicitly not carried over by the migration and are not supported when configured that way in External ID.

```powershell
$body = @{
    "@odata.type" = "#microsoft.graph.socialIdentityProvider"
    identityProviderType = "Google"
    name = "Google"
    clientId = "<client-id>"
    clientSecret = "<client-secret>"
}
New-MgIdentityIdentityProvider -BodyParameter $body
```

**Rollback:** remove the newly created identity provider (`Remove-MgIdentityIdentityProvider`) if misconfigured; this doesn't affect the B2C-side provider config.

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — Azure AD B2C → Microsoft Entra External ID Migration
================================================
Date/Time:                     _______________
Reported by:                   _______________
Source B2C tenant:             _______________
Destination External ID tenant:_______________
Migration approach:            Standard / HSC mode
Password-preservation approach:JIT / B2C-initiated / None (reset-after-migration)
Affected application(s):       _______________

Symptom:                       _______________
Migration Policy Analyzer run: Y / N — date: _______________
Analyzer summary (if run):     Available ___ / Custom Dev Required ___ / Not Supported ___ / Incompatible ___

Triage results:
  Directory object count:              _______________
  App registered in destination tenant:_______________
  Redirect URIs point at External ID:  _______________
  Password-preservation mechanism live:_______________
  Social/enterprise IdPs reconfigured: _______________

Steps already taken:            _______________
Escalating to:                  _______________
```

---
## 🎓 Learning Pointers

- **Standard vs. HSC mode is a scale-and-limitations decision, not a preference.** HSC mode only applies at roughly 5 million+ directory objects, and it trades feature completeness (no social IdPs, no passkeys, no age gating, no admin portal) for a lower-risk phased application cutover. Don't reach for it below the threshold — it adds constraints with no offsetting benefit there. [Plan your migration from Azure AD B2C to External ID](https://learn.microsoft.com/en-us/entra/external-id/customers/plan-your-migration-from-b2c-to-external-id)
- **The Migration Policy Analyzer is read-only and portal-only.** It scans custom-policy XML in place, doesn't touch the tenant, and can't be triggered from Graph — budget for a manual portal step in any migration runbook or automation plan. [Analyze Azure AD B2C custom policies](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-analyze-azure-ad-b2c-custom-policies)
- **"Custom Development Required" doesn't mean broken — it means you own the rebuild.** Custom authentication extensions, the Native Authentication SDK, and Microsoft Graph API each map to a specific category of B2C custom-policy logic. Treat the analyzer's recommended-path column as your work breakdown, not just a compatibility report.
- **User flows never need analysis — only custom policies do.** If a B2C tenant is entirely user-flow-based (no IEF/XML custom policies), the analyzer step in this runbook is a non-issue; go straight to feature mapping and application cutover.
- **Application cutover is the one genuinely one-way step in this whole project.** Tenant creation, user migration, and even password-preservation setup can all be redone or paused. Once traffic is live on External ID, treat any re-point back to B2C as an emergency stop-gap with its own remediation date, not a shrug-and-revert.
- **Social identity providers configured through B2C custom policies are a documented gap, not a bug in this repo's guidance.** Microsoft's own migration article calls this out explicitly under Stage 4 validation — budget time to reconfigure these natively before cutover, not after users start filing tickets. [Migrate from Azure AD B2C to External ID](https://learn.microsoft.com/en-us/entra/external-id/customers/migrate-from-b2c-to-external-id)
