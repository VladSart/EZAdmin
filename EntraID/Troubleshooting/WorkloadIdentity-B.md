# Workload Identity Federation & Conditional Access for Workload Identities — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes. A CI/CD pipeline (GitHub Actions, Azure DevOps), Kubernetes workload, or other federated client suddenly can't get a token from Entra — or a service principal is being blocked that wasn't before.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---
## Triage

Two unrelated failure families produce similar-looking "pipeline suddenly can't auth" tickets: **(1)** the federated credential trust itself is broken (no secret involved at all), or **(2)** a Conditional Access policy scoped to workload identities is now blocking the service principal. Triage both in parallel.

```powershell
Connect-MgGraph -Scopes "Application.Read.All","Policy.Read.All" -NoWelcome

# 1. Find the app registration and list its federated credentials
$app = Get-MgApplication -Filter "displayName eq '<AppName>'"
Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id |
    Select-Object Name, Issuer, Subject, Audiences

# 2. Confirm the Service Principal exists and is enabled
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"
$sp | Select-Object DisplayName, AccountEnabled, Id

# 3. Check for Conditional Access policies scoped to workload identities that include this SP
Get-MgIdentityConditionalAccessPolicy | Where-Object {
    $_.Conditions.ClientApplications.IncludeServicePrincipals -contains $sp.Id -or
    $_.Conditions.ClientApplications.IncludeServicePrincipals -contains "ServicePrincipalsInMyTenant"
} | Select-Object DisplayName, State

# 4. Pull the exact AADSTS error from the caller's own logs (GitHub Actions run log /
#    Azure DevOps pipeline log / kubectl describe pod) — Entra sign-in logs for
#    service principals live in the portal, not a dedicated Graph cmdlet:
#    Entra admin center > Identity > Applications > Enterprise applications >
#    <app> > Sign-in logs > tab "Service principal sign-ins"
```

**Interpret — if X then do Y:**

| Finding | Next action |
|---|---|
| Error `AADSTS700211` | No matching federated identity record — subject claim in the token doesn't match any configured federated credential. See [Fix 1](#fix-1--subjectissuer-mismatch-aadsts700211--700213--70021) |
| Error `AADSTS700213` or `AADSTS70021` | Same root cause as above (older/alternate wording) — go to [Fix 1](#fix-1--subjectissuer-mismatch-aadsts700211--700213--70021) |
| Error `AADSTS700223` or `AADSTS700238` | Workload identity federation is disabled at the tenant level | [Fix 2](#fix-2--federation-disabled-at-tenant-level-aadsts700223--700238) |
| Error `AADSTS70025` | Client application has no federated identity credentials configured at all | [Fix 3](#fix-3--no-federated-credential-configured-aadsts70025) |
| No federation errors, but sign-in fails with "Access has been blocked due to Conditional Access policies" | A Conditional Access policy scoped to this service principal is blocking it — see [Fix 4](#fix-4--conditional-access-blocking-a-service-principal) |
| Azure DevOps service connection shows "Failed" with an issuer URL that doesn't start with `https://login.microsoftonline.com` | Stale/incorrectly-generated service connection — see [Fix 5](#fix-5--azure-devops-service-connection-issuer-url-stale) |
| Everything above looks fine, still fails | Check clock skew on the caller and confirm the OIDC token's `aud` claim exactly matches what's configured (case-sensitive) |

---
## Dependency Cascade

<details><summary>What must be true for a federated-credential (secretless) sign-in to succeed — click to expand</summary>

```
[External OIDC identity provider issues a short-lived token]
    │   GitHub Actions: token from GitHub's own OIDC provider (token.actions.githubusercontent.com)
    │   Azure DevOps: token from Azure DevOps' own OIDC provider (vstoken.dev.azure.com)
    │   Kubernetes: token from the cluster's OIDC issuer (via Azure AD Workload Identity webhook)
    │
    ▼
[Token's issuer (iss), subject (sub), and audience (aud) claims are read]
    │   sub format is provider-specific and CASE-SENSITIVE, e.g.:
    │     GitHub:  repo:org/repo:ref:refs/heads/main  (or :environment:name, :pull_request)
    │     ADO:     sc://<org>/<project>/<service-connection-name>
    │     K8s:     system:serviceaccount:<namespace>:<service-account>
    │
    ▼
[App Registration has a Federated Identity Credential whose issuer+subject+audience
 EXACTLY matches the incoming token — no wildcards, no partial matches]
    │   Created via Entra portal, Graph (New-MgApplicationFederatedIdentityCredential),
    │   or IaC (Bicep/Terraform azurerm_application_federated_identity_credential)
    │
    ▼
[Entra exchanges the external token for an Entra access token — NO SECRET OR
 CERTIFICATE IS EVER PRESENTED. This is the entire point of federation.]
    │
    ▼
[Workload identity federation must be ENABLED at the tenant level]
    │   Can be disabled by tenant policy — surfaces as AADSTS700223/700238
    │
    ▼
[Resulting token request is evaluated by any Conditional Access policy scoped to
 "Workload identities" that includes this specific Service Principal]
    │   Requires Workload Identities Premium license to CREATE/MODIFY such policies
    │   (existing policies keep enforcing even if the license lapses — they just can't be edited)
    │   Policies must target the SP directly — group membership does NOT enforce for SPs
    │
    ▼
[Token issued, scoped to whatever API permissions were already consented on the SP]
    │
    ▼
[Downstream resource (Graph, Azure Resource Manager, custom API) validates the token]
    │
    ▼
[Call succeeds]
```

**What silently breaks this and produces a confusing error:**
- Someone renames a GitHub branch, Azure DevOps service connection, or Kubernetes service account **after** the federated credential was created — the `sub` claim changes, the credential doesn't, and auth fails with zero indication of what changed
- Azure DevOps workload-identity service connections have a strict creation order: the service connection must exist before the federated credential referencing it, and editing/regenerating a service connection can silently invalidate the trust
- A Conditional Access admin adds a new workload-identity risk or location policy without realizing it will retroactively block a CI/CD pipeline that has been running fine for months

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the federated credential exists and inspect its exact subject string**
```powershell
Connect-MgGraph -Scopes "Application.Read.All" -NoWelcome
$app = Get-MgApplication -Filter "displayName eq '<AppName>'"
Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id | Format-List
```
Healthy: at least one credential whose `Issuer`/`Subject`/`Audiences` match the caller. Broken: no credentials returned at all → `AADSTS70025`.

**Step 2 — Decode the OIDC token the caller actually presented (if you have access to the pipeline log)**
GitHub Actions and Azure DevOps both log a redacted/claim summary on OIDC token request failures. Compare the `sub` claim shown there character-for-character against Step 1's `Subject` — a single wrong character (wrong branch name, wrong environment name, `main` vs `master`) is the single most common root cause.

**Step 3 — Confirm workload identity federation isn't disabled tenant-wide**
No dedicated Graph read exists for this tenant-wide toggle as of this writing; if Step 1 shows a correctly-matching credential and you still get `AADSTS700223`/`AADSTS700238`, escalate to a Global Administrator to check **Entra admin center → Identity → Application Proxy / Enterprise Applications → Security defaults / tenant policies** or open a support case — this is a tenant-level kill switch, not something visible per-app.

**Step 4 — Check whether Conditional Access is the actual blocker (not federation at all)**
```powershell
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"
Get-MgIdentityConditionalAccessPolicy | Where-Object {
    $_.Conditions.ClientApplications.IncludeServicePrincipals -contains $sp.Id -or
    $_.Conditions.ClientApplications.IncludeServicePrincipals -contains "ServicePrincipalsInMyTenant"
} | Select-Object DisplayName, State, Id
```
Broken: a policy in `State: enabled` targets this SP. Check its Conditions (location/risk) against what's actually different about this run — new pipeline runner IP range, new region, a triggered risk detection.

**Step 5 — Confirm Workload Identities Premium licensing if a CA policy needs modifying**
```powershell
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -like "*WORKLOAD*" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N="Total";E={$_.PrepaidUnits.Enabled}}
```
If the SKU is absent or fully consumed, existing CA policies for workload identities keep enforcing but cannot be edited until licensing is restored — this is a common surprise mid-incident.

**Step 6 — Portal sign-in log for the definitive error code and CA evaluation detail**
Entra admin center → **Identity** → **Applications** → **Enterprise applications** → select app → **Sign-in logs** → tab **Service principal sign-ins** → open the failed entry → **Conditional Access** tab shows exactly which policy fired, if any.

---
## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — Subject/issuer mismatch (AADSTS700211 / 700213 / 70021)</summary>

**Symptom:** A federated credential exists but doesn't match the incoming token's claims. Almost always follows a rename, branch change, or environment change on the caller's side.

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All" -NoWelcome
$app = Get-MgApplication -Filter "displayName eq '<AppName>'"

# Remove the stale credential
Remove-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id `
    -FederatedIdentityCredentialId "<staleCredentialId>"

# Recreate with the corrected subject — examples per provider:
# GitHub Actions (branch):
New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter @{
    name      = "github-main-branch"
    issuer    = "https://token.actions.githubusercontent.com"
    subject   = "repo:<org>/<repo>:ref:refs/heads/main"
    audiences = @("api://AzureADTokenExchange")
}
# GitHub Actions (environment — use this form for protected environments):
#   subject = "repo:<org>/<repo>:environment:<environmentName>"
# Kubernetes:
#   subject = "system:serviceaccount:<namespace>:<serviceAccountName>"
```
For Azure DevOps, prefer editing the **service connection** in the Azure DevOps UI (Project Settings → Service connections → Manage Service Principal) rather than hand-editing the federated credential directly — ADO owns the pairing and hand-edits commonly drift out of sync again at the next pipeline change.

**Rollback:** keep the old federated credential's issuer/subject/audience noted before deleting it — if the rename gets reverted, you'll need to recreate the original.

</details>

<details id="fix-2"><summary>Fix 2 — Federation disabled at tenant level (AADSTS700223 / 700238)</summary>

**Symptom:** Every federated-credential sign-in across every app fails simultaneously, with correctly-configured credentials. This is not an app-level problem.

This requires a Global Administrator or tenant policy change — there is no per-app workaround. Escalate with the exact error code and confirm nothing changed via a recent Conditional Access, Security Defaults, or tenant-wide policy rollout. If the org genuinely intends to disable workload identity federation tenant-wide, every affected pipeline needs to fall back to certificate or secret-based auth as an interim measure — do not leave production CI/CD broken while the policy question is resolved.

**Rollback:** re-enabling the tenant setting (once identified) immediately restores all previously-working federated credentials — nothing else needs to be rebuilt.

</details>

<details id="fix-3"><summary>Fix 3 — No federated credential configured (AADSTS70025)</summary>

**Symptom:** The app registration has zero federated credentials — someone configured the caller (GitHub workflow, ADO pipeline, K8s pod) to use OIDC federation, but never created the matching trust on the Entra side.

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All" -NoWelcome
$app = Get-MgApplication -Filter "displayName eq '<AppName>'"

New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter @{
    name      = "<descriptive-name>"
    issuer    = "<provider-issuer-URL>"
    subject   = "<exact-subject-string-see-fix-1-formats>"
    audiences = @("api://AzureADTokenExchange")
}
```
`audiences` is almost always exactly `api://AzureADTokenExchange` for Azure-targeted federation — a typo here is a second common cause of this same error even after the credential exists.

**Rollback:** `Remove-MgApplicationFederatedIdentityCredential` — no other object was touched.

</details>

<details id="fix-4"><summary>Fix 4 — Conditional Access blocking a service principal</summary>

**Symptom:** No federation error at all — token exchange succeeds, then the request is blocked with "Access has been blocked due to Conditional Access policies," or the equivalent is seen in the caller's error output.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess" -NoWelcome
$policy = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId "<policyId>"
$policy | Select-Object DisplayName, State
```

If the block is intentional (new location/risk restriction) but this specific pipeline needs an exception, add its Service Principal to the policy's **Exclude** list — do not disable the policy tenant-wide:
```powershell
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId "<policyId>" -Conditions @{
    ClientApplications = @{
        IncludeServicePrincipals = $policy.Conditions.ClientApplications.IncludeServicePrincipals
        ExcludeServicePrincipals = @($policy.Conditions.ClientApplications.ExcludeServicePrincipals + $sp.Id)
    }
}
```
If the block is a risk-based policy firing on a **real** compromise indicator (leaked credential, anomalous token), do not simply exclude the SP — investigate the risk detection first (Entra admin center → **Identity Protection** → **Risky workload identities**) before restoring access.

**Rollback:** remove the SP from the exclusion list once the underlying cause (location change, risk) is resolved and confirmed legitimate — leaving broad exclusions in place defeats the purpose of the policy.

</details>

<details id="fix-5"><summary>Fix 5 — Azure DevOps service connection issuer URL stale</summary>

**Symptom:** ADO workload-identity service connection shows "Failed," and the issuer URL on the underlying federated credential doesn't start with `https://login.microsoftonline.com` (or references an old ADO organization/tenant configuration).

In the Azure DevOps UI: **Project Settings** → **Service connections** → select the connection → **Edit** → **Save** (even with no field changes, this forces ADO to regenerate the federated credential's issuer/subject pairing against the current org/project). This must be done through the ADO UI, not by hand-editing the federated credential in Entra — ADO and Entra must stay in sync, and manual edits on the Entra side get silently overwritten or drift again at the next ADO-side change.

**Rollback:** none needed — this is a non-destructive regeneration of an existing trust, not a new object.

</details>

---
## Escalation Evidence

```
Workload Identity Federation — Evidence Pack
====================================
App display name:
Application (client) ID:
Service Principal Object ID:
Federated credential name(s):
  Issuer:
  Subject:
  Audience:

Caller platform:            [GitHub Actions / Azure DevOps / Kubernetes / other]
Caller identifier:          [repo:org/repo:ref:... / sc://org/project/name / namespace:sa]
Recent change on caller side: [branch rename / new environment / new service connection / none known]

Error details:
  Error code:                [AADSTS.....]
  Failure reason:
  Sign-in log timestamp:
  Source: [caller pipeline log / portal Service principal sign-ins]

Conditional Access:
  Policy name (if any fired):
  Policy state:               [On / Report-only / Off]
  Condition that fired:       [location / risk / other]
  Workload Identities Premium licensed: [YES / NO]

Symptoms:
  What broke:
  When it started:
  First failing run/build ID:

Steps already tried:
```

---
## 🎓 Learning Pointers

- **Federated credentials replace the secret entirely — there is nothing to rotate, but the trust is exact-match, not fuzzy.** A single wrong character in the `subject` claim (branch name, environment name, namespace) fails closed with an error code that gives no hint about *which* character is wrong. Always diff the exact string, don't eyeball it. [MS Docs: Workload identity federation](https://learn.microsoft.com/en-us/entra/identity-platform/workload-identity-federation)

- **Conditional Access for workload identities only enforces when a policy targets the Service Principal directly — group membership does nothing.** An admin who adds a service principal to a security group and assigns CA to that group will see the policy silently not apply, with no error anywhere. [MS Docs: Conditional Access for workload identities](https://learn.microsoft.com/en-us/entra/identity/conditional-access/workload-identity)

- **Workload Identities Premium licensing gates editing, not enforcement.** If the license lapses, existing CA policies scoped to service principals keep blocking/allowing exactly as configured — they just can't be created or modified until licensing is restored. Don't assume a licensing problem explains an active block.

- **Azure DevOps owns its own workload-identity service connections — treat Entra-side federated credential edits for ADO as read-only unless you're prepared for them to drift again.** The safe fix path is always through the ADO service connection UI's Edit → Save, which regenerates the trust correctly. [MS Docs: Troubleshoot workload identity service connections](https://learn.microsoft.com/en-us/azure/devops/pipelines/release/troubleshoot-workload-identity)

- **A CI/CD pipeline that starts failing with no code or config change on your side may be a Conditional Access rollout, not a federation break.** Rule out policy changes (Step 4 above) before spending time re-verifying subject strings that were working an hour ago.

- **Leaked-credential and anomalous-token risk detections apply to workload identities too, via Identity Protection.** If a service principal gets blocked by a risk-based CA policy, check **Risky workload identities** before excluding it — the block may be catching a real credential exposure (e.g., a secret or token accidentally committed to a public repo). [MS Docs: Securing workload identities with Identity Protection](https://learn.microsoft.com/en-us/entra/id-protection/concept-workload-identity-risk)
