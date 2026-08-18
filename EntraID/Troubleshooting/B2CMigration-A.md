# Azure AD B2C → Microsoft Entra External ID Migration — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

Covers the **project-level migration** from an Azure AD B2C tenant to a Microsoft Entra External ID *for customers* (CIAM) tenant: assessing the existing B2C implementation (custom policies and/or user flows), choosing between the **standard migration approach** and **High Scale Compatibility (HSC) mode**, preparing the destination tenant, migrating users and (optionally) credentials, rebuilding identity providers and branding, and cutting applications over.

**Not covered here:**
- The `OnPasswordSubmit` custom-authentication-extension mechanism itself, once JIT password migration is the chosen approach and is being built or debugged — see `CIAMMigration-A.md`/`-B.md`, which this file defers to for that entire sub-topic
- Workforce guest/B2B collaboration — a completely different External ID tenant configuration; see `ExternalIdentities-A.md`/`-B.md`
- General Entra External ID tenant day-2 operations unrelated to a migration project (branding changes on a tenant that was never B2C, user-flow tuning, etc.)

**Assumes:** an existing Azure AD B2C tenant with production traffic, and a decision in progress (or already made) to move to Microsoft Entra External ID. Azure AD B2C itself is not being shut down on any fixed date for existing customers — Microsoft has committed to supporting it until **at least May 2030** — so this is a planned modernization project, not an emergency migration, unless a specific customer's own contract/compliance timeline says otherwise.

---
## How It Works

Azure AD B2C's customization model is built on **Identity Experience Framework (IEF) custom policies** — XML-defined orchestration steps, technical profiles, and claims transformations that give near-total control over the sign-in experience at the cost of steep authoring complexity. Microsoft Entra External ID deliberately does not carry this model forward. Instead it offers **built-in user flows** for common scenarios (sign-up, sign-in, password reset) with configuration-based branding and attribute customization, plus **custom authentication extensions** — webhook-style callouts to your own HTTPS endpoint at specific points in the sign-in flow — for the logic that genuinely needs to be custom.

This is the single fact that shapes the entire migration: **there is no 1:1 lift-and-shift path for a B2C custom policy.** Every piece of custom logic has to be re-classified into one of four buckets and rebuilt accordingly.

<details><summary>Full feature-mapping model</summary>

| Azure AD B2C mechanism | External ID equivalent | Rebuild effort |
|---|---|---|
| Custom policies (XML/IEF) — orchestration, claims transformations | Custom authentication extensions | Code rewrite — you own the endpoint |
| Hosted pages with HTML/CSS | User flows with branding + native authentication | Configuration, mostly — some UX redesign |
| Microsoft Graph API (user management) | Microsoft Graph API | Unchanged — same API surface |
| Custom policy conditions / user flow conditions | Microsoft Entra Conditional Access | Reconfiguration — different policy model |
| Browser-based mobile flows, web redirects | Native Authentication SDKs (local accounts only) | New SDK integration if you want the native UX |
| Custom claims in policies | Custom authentication extensions | Code rewrite |
| Social IdPs configured **inside B2C custom policies** | Built-in social identity provider support | Reconfiguration — must be done natively, not carried over |
| Third-party IdPs configured through B2C custom policies | Not supported as-is | Architecture change required |

Four migration statuses the Migration Policy Analyzer assigns to each detected feature, and what each one actually means operationally:

- **Available** — works natively in External ID today, GA, documented, production-ready. Configure it; no code.
- **Custom Development Required** — achievable via custom authentication extensions, the Native Authentication SDK, or Graph API, but you own the implementation. This is the bulk of real migration effort.
- **Not Currently Supported** — no current equivalent, or only in preview with no committed GA timeline. Track the roadmap; don't build a permanent workaround around a temporary gap without checking first.
- **Architecture Incompatible** — a fundamental pattern mismatch. No amount of custom development closes this gap the way B2C did it; the fix is a different design, not more code.

</details>

### Standard migration vs. High Scale Compatibility (HSC) mode

Most tenants use the **standard migration approach**: create a new External ID tenant, migrate users (and credentials, if needed), rebuild applications and identity providers, and cut over. It offers the broadest feature compatibility but isn't designed for long-running side-by-side operation at very large scale.

**High Scale Compatibility (HSC) mode** exists specifically for Azure AD B2C tenants with **~5 million or more directory objects**, where a full user-and-credential migration in one operation would be high-risk or operationally impractical. In HSC mode, Azure AD B2C and External ID run **side by side in the same tenant** — existing users and credentials stay exactly where they are, and applications migrate to External ID endpoints one at a time, in phases, while everything not yet migrated keeps working against B2C untouched.

The trade-off is real and durable, not a temporary preview limitation: HSC mode today has **no social identity providers, no passkeys, no age gating, no admin-portal configuration experience, and materially reduced Conditional Access** (no authentication context, no step-up authentication, no session-based controls, no group-based application assignment). Third-party fraud protection for web-hosted flows isn't supported in HSC mode either — only native-authentication API flows can integrate a WAF-based third-party fraud check. None of this is a migration checklist item you complete and move past; it is the operating envelope of HSC mode for as long as a tenant stays in it.

<details><summary>Why HSC mode can't just "unlock" the missing features over time</summary>

The limitations aren't artificial preview gating on an otherwise-complete feature set — they stem from HSC mode's core design constraint: it keeps Azure AD B2C's existing identity store and much of its runtime behavior in place while layering External ID endpoints on top, rather than migrating the identity store itself. Features like social IdP federation and passkeys are implemented against External ID's own identity and credential model; a tenant running in HSC mode is, by definition, not fully on that model yet. Feature availability timelines can differ between HSC mode and standard deployment for exactly this reason — check the official roadmap rather than assuming parity is coming on the same schedule as standard-mode features.

</details>

### The three password-preservation patterns

Migrating users is always required in the standard approach, regardless of whether credentials are preserved. The credential decision is separate and depends on where applications authenticate during the transition:

1. **No preservation needed.** Users authenticate via social IdPs, you're moving to passwordless, you're comfortable requiring a reset, regulatory requirements mandate fresh consent anyway, or you already hold plaintext passwords and can set them directly via Graph during bulk migration. This is the simplest path — bulk-migrate user data, then let SSPR or a Graph-based password set handle the rest.
2. **Just-in-Time (JIT) password migration, External ID-initiated.** Applications have already cut over to External ID endpoints. On first sign-in, the `OnPasswordSubmit` custom authentication extension validates the user's password against the legacy IdP (B2C), writes it into External ID, and flips a migration flag so every subsequent sign-in is native. This is the pattern `CIAMMigration-A.md`/`-B.md` covers end-to-end — this file only needs you to know *when* to choose it: when you want applications to lead the cutover and credentials to follow lazily, one sign-in at a time.
3. **B2C-initiated migration (legacy IdP-initiated credential harvesting).** Applications **stay on B2C endpoints** while a B2C custom policy calls a REST API in the background to validate credentials and write them into the External ID tenant. Once enough of the user base has been harvested this way, applications cut over. This is the inverse of JIT: credentials lead, applications follow. Choose it when you want to de-risk the credential migration itself before touching any application's endpoint configuration.

Both JIT and B2C-initiated approaches create a **coexistence period** where both systems must be monitored. JIT works best time-boxed — plan a forced reset or final bulk migration for users who never sign in during the window. B2C-initiated migration is bounded by how much of the user base the background harvesting has actually reached before cutover is safe.

---
## Dependency Stack

```
Layer 6 — Decommission
    Azure AD B2C tenant retired (or left dormant) only after full cutover + soak period
Layer 5 — Application Cutover
    Client apps re-pointed at External ID endpoints (redirect URIs, authority, token validation)
    Application-side deploy required — this is not a tenant-config-only step
Layer 4 — Credential State
    Password-preservation approach implemented (or deliberately skipped in favor of reset/SSPR)
    JIT: OnPasswordSubmit extension live  |  B2C-initiated: harvesting REST API + custom policy live
Layer 3 — User Data
    Bulk user migration completed via Microsoft Graph (Stage 1 of the user/credential migration guide)
    Subject to Graph throttling at scale — plan batched writes, not a single bulk call
Layer 2 — Application & Identity Provider Configuration
    Applications registered fresh in External ID (never reused from B2C)
    User flows or custom authentication extensions rebuilt per the feature-mapping table
    Social/enterprise identity providers reconfigured natively (not carried over from B2C policies)
Layer 1 — Destination Tenant
    External ID tenant created
    Security, compliance, and monitoring baseline configured BEFORE any production user migration
Layer 0 — Migration Approach Decision
    Standard migration (most tenants) vs. HSC mode (~5M+ directory objects, accepted limitations)
    This decision shapes every layer above it — HSC mode skips Layer 3/4 almost entirely
    (existing users/credentials stay in place) and constrains Layer 2 to the documented HSC feature set
```

A tenant can be perfectly correct at every lower layer and still fail at Layer 5 if the client application's own build/deploy hasn't shipped the endpoint change — this is the most common "migration is done but nothing works" gap, because it's the one layer that isn't purely an Entra-side configuration change.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Migration Policy Analyzer returns `CallerError` | Invalid XML, or a base policy (`TrustFrameworkBase`/`TrustFrameworkExtensions`) not uploaded to the tenant being analyzed | Confirm all policy files compile successfully in IEF first; verify base policies are present |
| Analyzer doesn't detect a feature you know exists | Non-standard implementation pattern, or a required base policy wasn't included in the analysis selection | Include base + extensions + relying-party policies together in one analysis run |
| Analyzer flags generic-sounding features like "Orchestration Branching" | These are structural patterns present in nearly all custom policies, not custom logic specific to you | Filter to `Custom Development Required`/`Not Currently Supported` only when prioritizing |
| Users can't sign in immediately after cutover | No password-preservation mechanism was actually implemented before the app was re-pointed | Confirm JIT extension or B2C-initiated harvesting was live *before* cutover, not planned for after |
| Social sign-in missing or broken post-migration | Social IdP was configured inside a B2C custom policy — not carried over automatically | Reconfigure the provider natively via `identity/identityProviders` in External ID |
| Age-classification logic missing post-migration | Age gating has no current External ID equivalent, in either standard or HSC mode | Flag early — this needs an alternate design, not a migration step |
| HSC-mode tenant missing Conditional Access controls the team expects | Authentication context, step-up auth, session controls, and group-based app assignment are documented HSC gaps | Confirm against the HSC limitations list before treating it as a bug |
| Third-party fraud/bot protection stopped working after HSC-mode cutover | Web-hosted (browser) flows don't support third-party fraud integration in HSC mode | Move to native-authentication API flows with a WAF in front, or accept the gap |
| Application registered but tokens fail validation | App reused an old B2C registration instead of a fresh External ID registration | Confirm a genuinely new app object exists; B2C app objects are not portable |
| Multi-tenant app fails against External ID in HSC mode | HSC mode requires single-tenant (`AzureADMyOrg`) app registrations only | Re-register as single-tenant; multitenant isn't supported for External ID endpoints in HSC mode |
| Migration "stuck" for months with no clear end date | Standard migration was chosen for a tenant that's actually HSC-eligible, and coexistence has no natural end state | Re-run the HSC eligibility check; a long-running side-by-side standard migration is a sign the approach decision needs revisiting |

---
## Validation Steps

1. **Confirm the approach decision against actual scale, not assumption.**
   ```powershell
   (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directoryObjects/`$count" -Headers @{ "ConsistencyLevel" = "eventual" })
   ```
   Good: a number that clearly supports the chosen approach (well under ~5M for standard). Bad: near or over the threshold while running standard migration steps — revisit the decision before continuing.

2. **Run the Migration Policy Analyzer and capture a baseline.** (Portal-only — Identity Experience Framework → Migration Policy Analyzer in the B2C tenant.) Good: a complete summary with feature counts by status. Bad: `CallerError`, or a report that seems suspiciously empty relative to known policy complexity — re-check base policy inclusion.

3. **Verify the destination tenant's security/compliance/monitoring baseline exists before any user migration.**
   ```powershell
   Get-MgOrganization | Select-Object DisplayName, Id
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identity/identityProviders" | Select-Object -ExpandProperty value
   ```
   Good: destination tenant exists, identity providers already reconfigured. Bad: attempting to migrate users into a tenant with no baseline security configuration yet.

4. **Verify each application is freshly registered, not reused.**
   ```powershell
   Get-MgApplication -Filter "displayName eq '<app-display-name>'" | Select-Object Id, AppId, SignInAudience, CreatedDateTime
   ```
   Good: `CreatedDateTime` postdates the migration project start; a genuinely new object ID that never existed in B2C. Bad: attempting to reuse a B2C `AppId` in the External ID tenant — not supported.

5. **Verify the chosen credential-preservation mechanism is actually live before cutover, not just planned.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" |
     Select-Object -ExpandProperty value | Where-Object { $_."@odata.type" -match "onPasswordSubmit" }
   ```
   Good: extension exists and is wired to a listener policy (JIT approach), or a documented B2C-initiated harvesting policy is confirmed live. Bad: cutover already happened with neither in place.

6. **Verify application redirect URIs and token validation actually point at External ID.**
   ```powershell
   Get-MgApplication -ApplicationId "<client-app-object-id>" | Select-Object -ExpandProperty Web
   ```
   Good: URIs reference the External ID CIAM authority. Bad: still `*.b2clogin.com` after the project reports cutover complete.

7. **Confirm HSC-mode-specific constraints if applicable — new, single-tenant app registrations only.**
   ```powershell
   Get-MgApplication -ApplicationId "<app-object-id>" | Select-Object SignInAudience
   ```
   Good: `AzureADMyOrg`. Bad: any multitenant value in an HSC-mode tenant — this will not function against External ID endpoints in HSC mode.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Assessment**
1. Inventory every application, user flow, identity provider, and custom policy in the B2C tenant.
2. Run the Migration Policy Analyzer against every custom policy set (must include a relying party policy per run).
3. Cross-reference analyzer output against the feature-mapping table to scope real engineering work, not just configuration.
4. Confirm the standard-vs-HSC decision against actual directory object count — don't take a prior assumption at face value if the tenant has grown since the decision was made.

**Phase 2 — Destination Preparation**
1. Create the External ID tenant (or confirm the HSC-mode toggle on the existing B2C tenant, if HSC was chosen).
2. Configure security, compliance, and monitoring baselines before any production data lands here.
3. Register applications fresh — never carry over B2C app registration objects.
4. Reconfigure user flows and rebuild custom authentication extensions per the analyzer's recommended paths.
5. Reconfigure social/enterprise identity providers natively.

**Phase 3 — User & Credential Migration**
1. Bulk-migrate user data via Graph (batch to avoid throttling at scale).
2. If preserving passwords, implement the chosen approach — JIT (build per `CIAMMigration-A.md` Playbook 1) or B2C-initiated harvesting (B2C custom policy + REST API).
3. If not preserving passwords, communicate the reset/SSPR path to users proactively, before cutover, not after tickets start.

**Phase 4 — Validation & Cutover**
1. Test every authentication flow: sign-up, sign-in, password reset, token issuance and custom claims, application/API integrations, custom authentication extensions, and native authentication.
2. Confirm the B2C-only-feature gaps (age gating; social IdPs in custom policies) are addressed, not silently dropped.
3. Cut applications over — coordinate the Entra-side redirect-URI change with the actual client application deploy.
4. Monitor via Azure Monitor / Microsoft Sentinel. Note: **User Insights retires 31 August 2026** — new deployments should go straight to Azure Monitor with Log Analytics rather than building on a retiring dashboard.

**Phase 5 — Decommission**
1. Confirm full cutover across every application, including any third-party-owned apps in an ISV tenant scenario — migration can't complete until every app owner has moved.
2. Soak the destination tenant under production load before touching the B2C tenant.
3. Decommission or leave the B2C tenant dormant per the organization's own data-retention and compliance requirements — there is no Microsoft-imposed deadline forcing this while B2C remains supported (through at least May 2030).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full standard migration, tenant assessment through cutover</summary>

1. **Assess.** Inventory applications, user flows, custom policies, identity providers, token/claim requirements, and custom business logic in the existing B2C tenant.
2. **Analyze.** Run the Migration Policy Analyzer against all custom policies; export the JSON report for engineering scoping.
3. **Map.** Translate every `Custom Development Required` feature into a specific implementation task: custom authentication extension, Native Authentication SDK integration, or Graph-API/app-side logic — using the feature-mapping table as the routing key.
4. **Prepare.** Stand up the destination tenant, configure security/compliance/monitoring, register applications fresh, rebuild user flows and identity providers.
5. **Decide on credentials.** Choose no-preservation, JIT, or B2C-initiated based on which side (application or credential) you want to lead the cutover.
6. **Migrate users.** Bulk-migrate via Graph in batches; watch for throttling on large tenants.
7. **Implement credential preservation** (if chosen) — build the JIT extension per `CIAMMigration-A.md`, or the B2C custom-policy REST API harvesting flow.
8. **Validate.** Run the full Stage 4 validation checklist (sign-up/sign-in/reset, token/claims, app/API integrations, extensions, native auth, load testing).
9. **Cut over.** Re-point application redirect URIs and coordinate the client-side deploy; monitor closely during the coexistence window.
10. **Decommission.** Retire or archive the B2C tenant per your own compliance timeline, not a Microsoft-imposed one.

**Rollback:** at any point before Step 9, rolling back means simply not proceeding — nothing user-facing has changed yet. After Step 9, rollback means re-pointing applications back to B2C endpoints and treating any External ID-side state changes since cutover as needing reconciliation; this should be a rare, explicitly time-boxed stop-gap, not a routine escape hatch.

</details>

<details><summary>Playbook 2 — HSC mode enablement and phased application migration</summary>

1. **Confirm eligibility.** Verify directory object count is at or above ~5 million via the Graph `directoryObject` count endpoint.
2. **Review limitations explicitly with stakeholders.** No social IdPs, no passkeys, no age gating, no admin-portal experience, reduced Conditional Access, limited third-party fraud protection for web-hosted flows — get this accepted in writing before enabling, since it's a durable operating constraint, not a rollout checklist item.
3. **Enable HSC mode** on the existing Azure AD B2C tenant — this does not affect any existing application.
4. **Register the first migrating application fresh**, single-tenant only. Never reuse the existing B2C app registration.
5. **Migrate the application to External ID endpoints.** Users and credentials stay exactly where they are — no user/credential migration step in HSC mode.
6. **Validate the migrated application** against the reduced HSC feature set specifically — don't test against the standard-mode feature list by mistake.
7. **Repeat per application**, at whatever pace the business can absorb — HSC mode does not automatically move applications; every migration is a deliberate, manual step.
8. **Reach full migration** when every application has moved to External ID endpoints; at that point the tenant is ready for Azure AD B2C retirement.

**Rollback:** an individual application can be re-pointed back to B2C endpoints at any phase without affecting other applications, since users/credentials never left B2C in the first place — this is HSC mode's main operational advantage over standard migration's cutover risk.

</details>

<details><summary>Playbook 3 — Recovering from a cutover that broke sign-in (post-incident)</summary>

1. **Triage first: is this an Entra-side config gap or a client-app deploy gap?** Check redirect URIs (Entra side) against the actual client build's authority configuration (app side) — these are two independently movable pieces.
2. **If no credential-preservation mechanism was live at cutover:** communicate SSPR/reset to affected users immediately rather than waiting for individual tickets; this is the highest-volume, fastest-to-fix root cause.
3. **If social sign-in is broken:** reconfigure the provider natively in External ID (`identity/identityProviders`) — this was never going to carry over automatically from a B2C custom policy, regardless of how the rest of the migration went.
4. **If this is an HSC-mode tenant:** confirm the failure isn't simply a documented HSC limitation (Conditional Access scenario, fraud protection, passkeys) being treated as a bug.
5. **Decide fail-forward vs. fail-back.** Fixing forward (correcting the missing piece in External ID) is almost always faster and safer than re-pointing back to B2C, which reopens identity-state-sync problems the migration was meant to close. Reserve fail-back for genuinely broad outages with no fast forward fix.

**Rollback:** documented above as the last-resort fail-back path — always paired with an explicit re-cutover date, never left open-ended.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Read-only evidence collector for a B2C → External ID migration ticket escalation.
.DESCRIPTION Gathers tenant type, directory object count, application registration/redirect-URI
             state, identity provider inventory, and custom-authentication-extension presence.
             Makes no changes. Requires Directory.Read.All, Application.Read.All, Policy.Read.All.
#>
Connect-MgGraph -Scopes "Directory.Read.All","Application.Read.All","Policy.Read.All" -Environment Global

$evidence = [ordered]@{
    Timestamp           = (Get-Date).ToString("o")
    Tenant              = Get-MgOrganization | Select-Object DisplayName, Id
    DirectoryObjectCount = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directoryObjects/`$count" -Headers @{ "ConsistencyLevel" = "eventual" })
    IdentityProviders   = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identity/identityProviders").value
    CustomAuthExtensions = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions").value |
        Where-Object { $_."@odata.type" -match "onPasswordSubmit" }
}

$evidence | ConvertTo-Json -Depth 6 | Out-File ".\B2CMigration-Evidence-$(Get-Date -Format yyyyMMdd-HHmm).json"
Write-Host "Evidence pack written. Attach the JSON to the escalation ticket." -ForegroundColor Cyan
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-MgOrganization` | Confirm which tenant you're connected to |
| `(Invoke-MgGraphRequest -Method GET -Uri ".../directoryObjects/`$count" -Headers @{"ConsistencyLevel"="eventual"})` | Directory object count — HSC eligibility check |
| `Get-MgApplication -Filter "displayName eq '<name>'"` | Confirm an app is registered in the destination tenant |
| `Get-MgApplication -ApplicationId <id> \| Select Web` | Check current redirect URIs / cutover state |
| `New-MgApplication -BodyParameter <hash>` | Register a fresh application in External ID |
| `Invoke-MgGraphRequest GET .../identity/identityProviders` | List configured social/enterprise identity providers |
| `New-MgIdentityIdentityProvider -BodyParameter <hash>` | Reconfigure a social IdP natively |
| `Invoke-MgGraphRequest GET .../beta/identity/customAuthenticationExtensions` | Check for a live JIT `OnPasswordSubmit` extension |
| `Get-MgUserMemberOf -UserId (Get-MgContext).Account` | Confirm your own role holds B2C IEF Policy Administrator (for the analyzer) |
| Azure portal → B2C tenant → Identity Experience Framework → Migration Policy Analyzer | Run the custom-policy migration assessment (portal-only, no Graph equivalent) |

---
## 🎓 Learning Pointers

- **Azure AD B2C isn't being force-retired for existing customers.** Microsoft has committed to support until at least May 2030 — the pressure to migrate is about landing on a modernized platform (and the fact that new purchases closed May 1, 2025), not an imminent shutoff. Frame migration timelines to stakeholders accordingly. [Azure AD B2C FAQ](https://learn.microsoft.com/en-us/azure/active-directory-b2c/faq?tabs=app-reg-ga#azure-ad-b2c-end-of-sale)
- **There is no automated custom-policy converter.** The Migration Policy Analyzer assesses and maps — it doesn't rewrite IEF XML into custom authentication extension code for you. Budget real engineering time for every `Custom Development Required` finding. [Analyze Azure AD B2C custom policies](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-analyze-azure-ad-b2c-custom-policies)
- **HSC mode's feature gaps are structural, not a punch list to clear before go-live.** No social IdPs, no passkeys, no age gating — these persist for the life of the tenant in HSC mode, because the mode is defined by *not* fully migrating the identity store. Don't promise stakeholders these will "come later" without checking the roadmap first. [Plan your migration from Azure AD B2C to External ID](https://learn.microsoft.com/en-us/entra/external-id/customers/plan-your-migration-from-b2c-to-external-id)
- **JIT and B2C-initiated migration are mirror images of each other.** JIT leads with the application (cut over first, credentials trickle in on sign-in); B2C-initiated leads with credentials (harvest in the background, cut applications over once enough users are migrated). Picking the wrong one for your risk tolerance is a common source of an open-ended, never-quite-finished migration.
- **User Insights retires 31 August 2026.** Any new monitoring setup for a freshly migrated External ID tenant should go straight to Azure Monitor + Log Analytics rather than building dashboards on a feature that's already sunsetting. [Migrate from User Insights](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-user-insights#migrate-from-user-insights)
- **Cross-reference `CIAMMigration-A.md`/`-B.md` the moment JIT is the chosen credential-preservation path.** This file owns the project-level decision and cutover; that pair owns the extension mechanics, encryption key management, and throttling tuning once JIT is actually being built.
