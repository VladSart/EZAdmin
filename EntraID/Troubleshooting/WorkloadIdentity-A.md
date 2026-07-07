# Workload Identity Federation & Conditional Access for Workload Identities — Reference Runbook (Mode A: Deep Dive)

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

This topic covers two related but distinct Entra capabilities, both operating on **service principals** (workload identities) rather than user accounts:

1. **Workload identity federation** — lets an external workload (GitHub Actions, Azure DevOps, Kubernetes, another cloud provider) exchange its own short-lived OIDC token for an Entra access token, with no client secret or certificate ever stored. This is an authentication mechanism.
2. **Conditional Access for workload identities** — lets CA policies target service principals directly (location/risk-based blocking), separate from the traditional user-targeted CA model. This is an authorization/governance layer that sits on top of *any* authentication method a service principal uses (federated, secret, or certificate).

Out of scope: managed identities (system- or user-assigned) — CA for workload identities explicitly does **not** cover managed identities; they can only be governed via access reviews. Also out of scope: multi-tenant and Microsoft/third-party SaaS applications — CA for workload identities only applies to single-tenant service principals registered in your own tenant. For general app registration credential (secret/certificate) troubleshooting, see the companion topic `Troubleshooting/AppRegistrations-{A,B}.md`.

---
## How It Works

<details><summary>Full architecture — click to expand</summary>

### Why workload identity federation exists

Every client secret or certificate is a long-lived credential that must be stored somewhere (a CI/CD secret store, a Key Vault, an environment variable) and rotated before it expires. Federation removes the stored credential entirely by establishing a **trust relationship** between an external OIDC identity provider and an Entra app registration. At authentication time:

1. The external platform (GitHub, Azure DevOps, a Kubernetes cluster) mints a short-lived (minutes) OIDC ID token, signed by its own OIDC issuer.
2. That token is presented to Entra's token endpoint in place of a client secret/assertion, alongside the app's client ID.
3. Entra fetches the issuer's OIDC discovery document and JWKS to verify the token's signature independently — it does not trust the caller's claim of identity, it cryptographically verifies it.
4. Entra checks the token's `iss` (issuer), `sub` (subject), and `aud` (audience) claims against the app registration's configured **Federated Identity Credentials** — an exact match is required on all three.
5. If matched, Entra issues its own access token to the caller, scoped to whatever API permissions are already consented on the Service Principal. No secret was ever transmitted or stored.

### Subject identifier formats (the #1 source of mismatches)

| Provider | Subject (`sub`) format | Notes |
|---|---|---|
| GitHub Actions — branch | `repo:<org>/<repo>:ref:refs/heads/<branch>` | Case-sensitive, full ref path required |
| GitHub Actions — tag | `repo:<org>/<repo>:ref:refs/tags/<tag>` | |
| GitHub Actions — environment | `repo:<org>/<repo>:environment:<envName>` | Preferred for protected/production deploys |
| GitHub Actions — pull request | `repo:<org>/<repo>:pull_request` | Broad — matches any PR from the repo |
| Azure DevOps | `sc://<organization>/<project>/<service-connection-name>` | Managed by ADO itself; hand-editing tends to drift |
| Kubernetes (Azure AD Workload Identity) | `system:serviceaccount:<namespace>:<serviceAccountName>` | Requires the Workload Identity mutating webhook + annotated K8s Service Account |
| GitLab CI | `project_path:<group>/<project>:ref_type:branch:ref:<branch>` | Confirm exact format against GitLab's current OIDC claims docs — format has changed across GitLab versions |

`audiences` is almost always `api://AzureADTokenExchange` for Azure/Entra-targeted federation regardless of provider — this rarely needs to vary.

### Conditional Access for workload identities

CA for workload identities is architecturally the same policy engine as user CA, but with workload-identity-specific constraints:
- **Only two grant controls exist: Block, or nothing.** There's no MFA/compliant-device grant option — a service principal cannot perform MFA or report device compliance. Policies either block access outright, or the whole point (blocking) doesn't apply and it's not a valid target for that policy type.
- **Only two conditions are supported: location and Identity Protection risk (service principal risk level).** No sign-in frequency, no session controls, no app-enforced restrictions.
- **Targeting must be direct.** Adding a service principal to a group and scoping the policy to that group does not enforce — Entra explicitly does not evaluate group membership for workload identity CA. Each SP must be added to the policy's Include/Exclude list individually (or via the tenant-wide `ServicePrincipalsInMyTenant` catch-all).
- **Licensing gates editing, not enforcement.** Workload Identities Premium is required to create or modify these policies. If licensing lapses, already-configured policies continue to enforce; they simply become read-only until relicensed.
- **Continuous Access Evaluation (CAE) extends to workload identities** — critical events (e.g., an admin disabling the SP) and location/risk policy changes can revoke an already-issued token in near-real-time rather than waiting for natural token expiry.

### Risk detections for workload identities

Microsoft Entra ID Protection extends its risk-detection engine to service principals:
- **Leaked credentials** — the Microsoft leaked-credentials service cross-references credentials found on GitHub, paste sites, and dark-web sources against valid Entra credentials, including workload identity secrets/certs. Always surfaces as High risk because it represents confirmed exposure, not a heuristic.
- **Anomalous token** — flags tokens with unusual characteristics (unexpected lifetime, replay from an unfamiliar location/IP/user agent).
- Full risk detail and risk-based CA enforcement require Workload Identities Premium; without it, detections still fire but with limited reporting detail.

</details>

---
## Dependency Stack

```
Layer 6: Downstream resource (Graph API, ARM, custom API)
         validates token audience/roles claim
              ▲
Layer 5: Conditional Access evaluation (workload identity policies)
         — location, service principal risk level — Block or allow only
              ▲
Layer 4: Entra token issuance
         — scoped to consented API permissions on the Service Principal
              ▲
Layer 3: Federated Identity Credential match
         — issuer + subject + audience, EXACT match, on the App Registration
              ▲
Layer 2: External OIDC token verification
         — Entra fetches issuer's OIDC discovery doc + JWKS, verifies signature
              ▲
Layer 1: External OIDC identity provider issues short-lived token
         — GitHub Actions / Azure DevOps / Kubernetes cluster / other CI platform
```

A fault at Layer 1-3 fails as a federation error (`AADSTS7002xx`/`70021`/`70025`). A fault at Layer 5 fails as a Conditional Access block with no federation error at all — these two failure families are easy to conflate under time pressure because both present as "the pipeline can't get a token," but the fix paths are completely different (fixing a subject string does nothing for a CA block, and vice versa).

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `AADSTS700211` / `700213` / `70021` | Subject/issuer/audience mismatch between token and configured federated credential | Compare exact `sub` claim vs. `Get-MgApplicationFederatedIdentityCredential` output |
| `AADSTS700223` / `700238` | Workload identity federation disabled at tenant level | Escalate to Global Admin — no per-app fix exists |
| `AADSTS70025` | No federated credential configured on the app at all | `Get-MgApplicationFederatedIdentityCredential` returns empty |
| "Access has been blocked due to Conditional Access policies," no federation error | CA policy scoped to workload identities is blocking this SP | Sign-in log → Conditional Access tab; check policies targeting the SP directly |
| Pipeline worked yesterday, fails today, no code/config change on caller side | Either a CA policy rollout, or a Workload Identities Premium license lapse pausing a report-only→enforced transition | Check recent CA policy changes; check SKU consumption |
| ADO service connection shows "Failed," issuer URL looks wrong | Service connection and federated credential have drifted out of sync | Edit → Save the service connection in ADO to force regeneration |
| Federated credential looks correct, still fails, caller is a renamed/moved GitHub repo | GitHub's `sub` claim embeds the exact repo path — a repo rename or transfer invalidates it | Update the federated credential's subject to the new `org/repo` path |
| SP was working, now blocked, Identity Protection shows a risk detection | Leaked credential or anomalous token flagged — potentially a real compromise | Investigate in **Risky workload identities** before excluding the SP from any blocking policy |
| CA policy edit attempt fails/greyed out | Workload Identities Premium license lapsed or was never assigned | `Get-MgSubscribedSku` — check consumption against total |
| Federated credential exists, `sub` matches exactly, still fails | `aud` (audience) mismatch — often a typo variant of `api://AzureADTokenExchange` | Byte-for-byte compare the `audiences` array |

---
## Validation Steps

**1. Enumerate all federated credentials on the app**
```powershell
Connect-MgGraph -Scopes "Application.Read.All" -NoWelcome
$app = Get-MgApplication -Filter "displayName eq '<AppName>'"
Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id | Format-List Name, Issuer, Subject, Audiences
```
Good: one or more credentials with issuer/subject/audience matching every caller that should be able to authenticate. Bad: empty result (nothing federated — expect `AADSTS70025` if the caller expects federation) or entries with stale subjects from renamed branches/environments.

**2. Confirm the Service Principal's enabled state and owner coverage**
```powershell
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"
$sp | Select-Object DisplayName, AccountEnabled
Get-MgServicePrincipalOwner -ServicePrincipalId $sp.Id
```
Good: `AccountEnabled: true`. Bad: `false` — someone disabled it, possibly during a security review or automatically as part of an Identity Protection remediation action.

**3. Enumerate Conditional Access policies scoped to workload identities**
```powershell
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.ClientApplications } |
    Select-Object DisplayName, State, @{N="IncludedSPs";E={$_.Conditions.ClientApplications.IncludeServicePrincipals}}
```
Good: policies list explicit SP Object IDs or the deliberate `ServicePrincipalsInMyTenant` catch-all, states match intended enforcement (`enabled` / `enabledForReportingButNotEnforced`). Bad: a policy in `enabled` state unexpectedly includes this SP.

**4. Confirm Workload Identities Premium licensing**
```powershell
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -like "*WORKLOAD*" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N="Total";E={$_.PrepaidUnits.Enabled}}
```
Good: consumed < total. Bad: fully consumed or SKU absent — existing policies still enforce, but nobody can adjust them.

**5. Check Identity Protection for risk on this specific workload identity**
Entra admin center → **Identity Protection** → **Risky workload identities** → search by Service Principal name/Object ID. Good: no active risk. Bad: an open High-risk detection (leaked credential, anomalous token) — this changes the remediation path entirely (see [Playbook 3](#playbook-3--risky-workload-identity-remediation)).

**6. Review the Service Principal sign-in log's Conditional Access tab for the actual failure**
Entra admin center → **Enterprise applications** → app → **Sign-in logs** → **Service principal sign-ins** → open the failed entry → **Conditional Access** tab. This is the single most authoritative source for whether CA fired, and which policy.

**7. Confirm clock sync on the caller for federation timing edge cases**
OIDC tokens carry short validity windows (often 5-10 minutes). Self-hosted GitHub Actions runners or on-prem Kubernetes nodes with clock drift can produce tokens that are already expired by the time Entra evaluates them — check NTP sync on any self-hosted/on-prem runner.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Isolate which layer failed.** Get the exact `AADSTS` code (federation layer, Layers 1-4) vs. a Conditional-Access-worded block (Layer 5) from the portal sign-in log before touching anything. These require entirely different fixes.

**Phase 2 — For federation errors, diff the claims.** Pull the caller's actual token claims (pipeline log, `kubectl describe` for K8s workload identity, or a deliberate debug run) and diff every character of `iss`/`sub`/`aud` against the configured Federated Identity Credential. Do not assume — a repo rename, branch rename, or ADO service connection regeneration silently invalidates the match.

**Phase 3 — For Conditional Access blocks, identify the firing condition.** Location-based policies fail predictably when a CI/CD runner's egress IP range changes (e.g., moving from self-hosted to GitHub-hosted runners, or a hosted runner pool rotating IP ranges). Risk-based policies require an Identity Protection investigation before any exclusion is applied.

**Phase 4 — Check for a recent tenant-wide or platform-side change independent of the app itself.** Federation-disabled errors (`AADSTS700223`/`700238`) and licensing-driven CA gaps are tenant-level, not app-level — don't spend time re-verifying an individual app's configuration if every federated app started failing simultaneously.

**Phase 5 — Apply the fix from the matching Remediation Playbook below, then re-run the caller (not just re-check configuration) to confirm end-to-end.**

**Phase 6 — Document the root cause in the app's own change log / README** (branch renames and CA policy scope changes are exactly the kind of silent breaking change that recurs on the next similar rename unless it's written down somewhere the next engineer will find it).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate an app from secret/certificate auth to workload identity federation</summary>

**Goal:** Eliminate a rotation-dependent credential entirely for a workload that supports OIDC federation (GitHub Actions, Azure DevOps, Kubernetes, other Azure services via managed identity federation).

1. Confirm the calling platform supports OIDC federation and can present an ID token (GitHub Actions `id-token: write` permission; Azure DevOps workload-identity service connection type; Kubernetes with the Azure AD Workload Identity webhook installed).
2. Determine the exact subject string using the format table above — do this **before** creating the credential, ideally by capturing a real token claim from a test run rather than guessing.
3. Create the Federated Identity Credential:
   ```powershell
   Connect-MgGraph -Scopes "Application.ReadWrite.All" -NoWelcome
   New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter @{
       name      = "<descriptive-name>"
       issuer    = "<provider-issuer-URL>"
       subject   = "<exact-subject>"
       audiences = @("api://AzureADTokenExchange")
   }
   ```
4. Update the caller's pipeline/workload configuration to use federated/OIDC auth instead of a stored secret (e.g., `azure/login@v2` with `client-id`/`tenant-id`/`subscription-id` and no `client-secret` for GitHub Actions).
5. Run the pipeline once in a non-production context to confirm the exchange succeeds end-to-end.
6. Only after confirming success, remove the old secret/certificate from the App Registration and from wherever it was stored (Key Vault, pipeline secret variable, etc.).

**Rollback:** keep the old secret valid and in place until Step 5 is confirmed — federation and secret-based credentials can coexist on the same app registration simultaneously, so there's no need to cut over destructively.

</details>

<details><summary>Playbook 2 — Roll out Conditional Access for workload identities safely</summary>

**Goal:** Add location- or risk-based CA enforcement to service principals without breaking existing automation.

1. Confirm Workload Identities Premium licensing covers the service principals in scope.
2. Identify the target SP's **Object ID** from **Enterprise applications** (not the App Registration's Object ID — these are different objects; using the wrong one silently fails to match).
3. Create the policy in **Report-only** mode first:
   ```json
   {
     "displayName": "Block workload identities outside approved locations",
     "state": "enabledForReportingButNotEnforced",
     "conditions": {
       "applications": { "includeApplications": ["All"] },
       "clientApplications": {
         "includeServicePrincipals": ["<SP Object ID>"]
       },
       "locations": {
         "includeLocations": ["All"],
         "excludeLocations": ["<Named Location ID or AllTrusted>"]
       }
     },
     "grantControls": { "operator": "and", "builtInControls": ["block"] }
   }
   ```
4. Let it run in report-only for a representative period covering all normal automation schedules (weekly/monthly jobs, not just daily ones) — check the **Report-only** tab of the sign-in log or the Conditional Access Insights workbook for any legitimate SP that would have been blocked.
5. Add any legitimate-but-flagged SPs to the exclusion list, or adjust the location list, before flipping to `enabled`.
6. Switch `state` to `enabled` only after a clean report-only period.

**Rollback:** set `state` back to `enabledForReportingButNotEnforced` or `disabled` — no destructive changes were made to the service principals themselves.

</details>

<details><summary>Playbook 3 — Risky workload identity remediation</summary>

**Goal:** Respond correctly when Identity Protection flags a service principal as risky, rather than reflexively excluding it from CA and restoring access.

1. Open **Entra admin center → Identity Protection → Risky workload identities**, find the SP, and review the specific detection (Leaked Credentials vs. Anomalous Token).
2. **Leaked Credentials is a confirmed exposure, not a heuristic** — treat it as an incident: rotate/remove the exposed secret or federated credential trust immediately, and search the source (public repo, paste site) for how it was exposed.
   ```powershell
   # Remove the compromised credential
   Remove-MgApplicationPassword -ApplicationId $app.Id -KeyId "<compromisedKeyId>"
   # Or for a compromised federated credential trust:
   Remove-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -FederatedIdentityCredentialId "<id>"
   ```
3. For **Anomalous Token**, investigate the specific anomaly (unfamiliar IP/location, unusual token lifetime) — confirm whether it correlates with a known infrastructure change (new CI runner region, new K8s cluster) before dismissing it as a false positive.
4. Only after remediating the actual cause, mark the risk as resolved in the portal (**Confirm compromised** or **Dismiss** as appropriate) — dismissing without remediation leaves the underlying exposure live.
5. If a blocking CA policy fired appropriately on this risk, do not exclude the SP as a first response — that reopens the exact exposure the policy caught.

**Rollback:** not applicable — this playbook is itself the remediation of a security event, not a reversible configuration change.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS Collects Workload Identity Federation + Conditional Access evidence for escalation.
#>
Connect-MgGraph -Scopes "Application.Read.All","Policy.Read.All","IdentityRiskyServicePrincipal.Read.All" -NoWelcome

$appName = "<AppName>"
$app = Get-MgApplication -Filter "displayName eq '$appName'"
$sp  = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"

[PSCustomObject]@{
    AppDisplayName      = $app.DisplayName
    AppId               = $app.AppId
    ServicePrincipalId  = $sp.Id
    AccountEnabled      = $sp.AccountEnabled
    FederatedCredentials = (Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id |
        ForEach-Object { "$($_.Name): $($_.Issuer) | $($_.Subject) | $($_.Audiences -join ',')" }) -join " ;; "
    MatchingCAPolicies  = (Get-MgIdentityConditionalAccessPolicy | Where-Object {
        $_.Conditions.ClientApplications.IncludeServicePrincipals -contains $sp.Id -or
        $_.Conditions.ClientApplications.IncludeServicePrincipals -contains "ServicePrincipalsInMyTenant"
    } | ForEach-Object { "$($_.DisplayName) [$($_.State)]" }) -join " ;; "
} | Format-List
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id` | List federated credentials on an app |
| `New-MgApplicationFederatedIdentityCredential` | Create a new federated credential trust |
| `Remove-MgApplicationFederatedIdentityCredential` | Remove a stale/incorrect federated credential |
| `Get-MgServicePrincipal -Filter "appId eq '<appId>'"` | Resolve App Registration to its Service Principal (Enterprise App) Object ID |
| `Get-MgIdentityConditionalAccessPolicy` | List all CA policies, including workload-identity-scoped ones |
| `Update-MgIdentityConditionalAccessPolicy` | Modify include/exclude SP lists on a CA policy |
| `Get-MgSubscribedSku \| Where SkuPartNumber -like "*WORKLOAD*"` | Check Workload Identities Premium licensing |
| `Get-MgServicePrincipalOwner -ServicePrincipalId $sp.Id` | Check SP owner coverage |
| Portal: Enterprise apps → Sign-in logs → **Service principal sign-ins** | Definitive error code + CA evaluation detail |
| Portal: Identity Protection → **Risky workload identities** | Leaked credential / anomalous token detections |
| Portal: Identity Protection → **Risk detections** (filtered to workload identity) | Full detection history |
| Portal: Conditional Access → policy → **Report-only** tab | Safe rollout impact preview |
| Azure DevOps: Project Settings → Service connections → Edit → Save | Force-regenerate an ADO workload-identity trust |

---
## 🎓 Learning Pointers

- **Federation and Conditional Access for workload identities are two independent systems that happen to fail with similarly-worded symptoms.** Always determine which layer failed (an `AADSTS7002xx` federation code vs. a Conditional-Access-worded block with no federation error) before choosing a fix — applying a federation fix to a CA problem, or vice versa, wastes the entire triage window. [MS Docs: Workload identity federation](https://learn.microsoft.com/en-us/entra/identity-platform/workload-identity-federation)

- **The subject claim format is provider-specific, case-sensitive, and exact-match — there is no fuzzy matching or wildcard support.** Capture a real token's claims from a test run rather than constructing the subject string from memory or documentation examples; a subtly wrong format (e.g., `environment:` vs `ref:refs/heads/`) is the most common root cause in this entire topic.

- **CA for workload identities explicitly ignores group membership — every policy must target service principals directly (or the `ServicePrincipalsInMyTenant` catch-all).** This is a deliberate design choice, not a bug, and it surprises admins used to group-based CA targeting for users. [MS Docs: Conditional Access for workload identities](https://learn.microsoft.com/en-us/entra/identity/conditional-access/workload-identity)

- **Licensing lapses don't disable enforcement — they disable editing.** A team that discovers a Workload Identities Premium license expired mid-incident should not assume that explains an active block; existing policies keep enforcing regardless of license state.

- **A leaked-credential detection on a workload identity is a confirmed exposure, not a probabilistic risk score.** Treat it with the same urgency as a real secret leak (because it is one) — investigate and remediate the exposure before dismissing the risk or excluding the SP from a blocking policy. [MS Docs: Securing workload identities with Identity Protection](https://learn.microsoft.com/en-us/entra/id-protection/concept-workload-identity-risk)

- **Continuous Access Evaluation extends to workload identities**, meaning a critical event (SP disabled, CA policy change) can revoke an already-issued token before its natural expiry — if a pipeline fails mid-run after having successfully authenticated moments earlier, check for a CAE-triggered revocation rather than assuming the original authentication was flawed. [MS Docs: CAE for workload identities](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-continuous-access-evaluation-workload)
