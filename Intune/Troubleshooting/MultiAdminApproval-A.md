# Multi Admin Approval (MAA) — Reference Runbook (Mode A: Deep Dive)
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

This file covers **Intune Multi Admin Approval (MAA)** — the "second admin must approve this change" control configured via *access policies* — for **both** of its enforcement surfaces:

1. **Delegated (interactive) enforcement** — an admin working in the Intune admin center is required to get a second admin's sign-off before a protected change takes effect. This has existed since MAA's original release.
2. **Application-authenticated (app-auth) enforcement** — service principals, scheduled automation, and third-party integrations calling Microsoft Graph with app-only tokens are *also* intercepted when the resource they're touching is protected by an access policy. This is a materially newer behavior (documented change, `ms.date` **2026-08-06**) and is the source of nearly all "this automation used to work and now it's failing" tickets.

**Explicitly out of scope / do not confuse with this topic:**
- MAA is **opt-in per workload, per tenant** — it does not exist or apply anywhere until an administrator creates at least one `operationApprovalPolicy`. A tenant with no access policies configured is entirely unaffected by anything in this file.
- MAA governs **write operations only** (`POST`/`PATCH`/`PUT`/`DELETE`). `GET` requests are never intercepted, regardless of policy configuration.
- MAA is a change-control gate, not an RBAC permission system — a caller still needs the normal Intune RBAC permission for the operation (e.g., `MobileApps/Create`) *in addition to* getting MAA approval. MAA adds a second gate; it doesn't replace the first. See `Troubleshooting/ScopeTags-A.md` for the underlying RBAC/scope-tag model MAA layers on top of.
- This is unrelated to Microsoft Entra Privileged Identity Management (PIM) role activation — PIM governs *becoming* a privileged admin; MAA governs a *specific change an already-privileged admin (or their automation) is attempting to make*. A tenant can have either, both, or neither.
- App-registration permission scoping and consent (i.e., whether a service principal has `DeviceManagementApps.ReadWrite.All` at all) is a separate, prerequisite concern — see `EntraID/Troubleshooting/AppConsentPolicies-A.md`/`-B.md`. MAA only engages *after* the caller already has the underlying Graph permission; a permission problem produces a `403`, not the `400`/`412` pair this file is about.

---
## How It Works

<details><summary>Full architecture</summary>

MAA is implemented as an interception layer sitting between the Intune Graph API surface and the underlying resource providers (apps, compliance policies, configuration policies, device actions, RBAC roles, Windows scripts, tenant configuration/device categories). An **access policy** (Graph resource: `operationApprovalPolicy`) declares:

- which resource type it protects (`policyType`: `app`, `script`, `compliancePolicy`, `configurationPolicy`, `deviceAction`/`deviceWipe`/`deviceRetire`/`deviceDelete`, `role`, `tenantConfiguration`, and several other narrower/future values),
- an optional platform scope (`policyPlatform`),
- and the **approver group** (`approverGroupIds`) — a Microsoft Entra security group whose members are allowed to approve requests against that policy.

When any caller — interactive admin session or app-auth service principal — issues a write operation against a resource covered by an active policy, the request is intercepted *before* the change is applied:

- **Delegated (portal) callers** see a **Business justification** field on the Save + Review screen. Submitting creates a pending request visible on **My requests**.
- **App-auth (Graph API) callers** must supply an `x-msft-approval-justification` request header, Base64-encoded, on the write call itself. If the header is missing, the call fails outright with **HTTP 400** (not "pending" — this is a genuine client error, the request was never accepted into the approval queue).

If the justification is present and accepted, MAA does **not** apply the change and does **not** return a normal success code. It returns **HTTP 412 Precondition Failed**, with an `x-msft-approval-code` response header carrying a request ID. This is the single most important and most commonly misread signal in the whole feature: *a 412 with an approval code means MAA worked correctly and is now waiting on a human* — it is not a bug, a permissions failure, or a transient error to retry blindly. Retrying the identical call without the approval code produces a second, redundant pending request (Intune blocks duplicate submissions for the same object while one is already pending).

A **different** administrator — never the requestor, even if the requestor happens to also be in the approver group — reviews the request (in the portal, under **Multi Admin Approval > Received requests** / **All requests**) and either **Approves** or **Rejects** it, optionally leaving approver notes. Approving does **not** apply the change either; it only unblocks the next step:

- **Delegated callers** return to **My requests** and select **Complete**.
- **App-auth callers** resubmit the *exact original request* (same method, URL, body) with the justification header replaced by `x-msft-approval-code: <code>`.

Only at this final resubmission/Complete step is the change actually applied to the resource, and the request's status transitions to `Completed`. If this step doesn't happen within **3 days** of creation, the request silently **Expires** and must be resubmitted from the very beginning — there is no extension mechanism and Intune sends no notification at any point in this lifecycle (creation, approaching expiry, or approval) to either the requestor or the approver pool.

**Approver eligibility is stricter than group membership alone.** For an account to actually be able to approve:
1. It must be a direct member of the group referenced in the policy's `approverGroupIds` — **nested group membership may behave unreliably** and isn't a supported pattern.
2. That group itself must be a **pure Microsoft Entra security group** (`securityEnabled: true`, `mailEnabled: false`, no `Unified` group type). Distribution lists, mail-enabled security groups, and Microsoft 365 groups are accepted when you configure the policy but **silently fail to resolve any usable approvers** — no error at configuration time or at approval time, the request simply has no one who can act on it.
3. That same group must be **directly** assigned as a member group on at least one Intune RBAC role assignment. Permissions the individual members hold through *other* groups, or as direct user role assignments, do not satisfy this — Intune specifically checks the approver group object's own RBAC role-assignment membership. Groups that fail this check have members **periodically removed from the group automatically**.
4. The approving account needs the *resource-specific* Read permission for the policy type (e.g., `ManagedDevices/Read` to approve a device-action request), on top of approver-group membership.
5. By default the approver (and requestor) needs an assigned Intune license; a tenant can enable **Allow access to unlicensed admins** to lift this, but that setting is **irreversible** once turned on.

**The Role policy type is architecturally special and self-referential.** An access policy of `policyType: role` protects *all* RBAC role changes — including the very role assignments MAA itself depends on (the approver group's assignment from point 3 above). If that assignment is ever broken or was never correctly configured while a Role access policy is active, fixing it requires an RBAC change, which itself now requires MAA approval — a genuine deadlock with no self-service way out except deleting the Role policy, fixing RBAC without MAA in the way, and re-creating the policy afterward.

</details>

---
## Dependency Stack

```
Layer 7 — Change actually applied
    resource is created/updated/deleted; request status = Completed
Layer 6 — Resubmission / Complete step
    app-auth: original request resent with x-msft-approval-code header
    delegated: requestor selects "Complete" on My requests
    MUST happen within 3 days of request creation, or status -> Expired
Layer 5 — Approval decision
    a DIFFERENT admin (never the requestor) reviews and Approves/Rejects
    requires: approver-group membership (direct, not nested)
              + resource-specific Read permission for the policy type
              + Intune license (unless unlicensed-admin access is enabled)
Layer 4 — Pending request created
    app-auth: HTTP 412 + x-msft-approval-code issued
    delegated: request appears on My requests / All requests
Layer 3 — Justification supplied on the write call
    app-auth: x-msft-approval-justification header, Base64-encoded (else HTTP 400)
    delegated: Business justification field on Save + Review
Layer 2 — Approver group correctly wired
    Entra security group (NOT M365/mail-enabled/DL — silent failure otherwise)
    directly assigned as a member group to an Intune RBAC role assignment
Layer 1 — Access policy exists and is active
    operationApprovalPolicy created for the target policyType
    (Apps / Compliance policies / Configuration policies / Device actions /
     Role-based access control / Scripts / Tenant Configuration)
Layer 0 — Foundational prerequisites
    tenant has >= 2 admin accounts
    caller has the normal Intune RBAC permission for the underlying operation
      (MAA is an additional gate, not a replacement for RBAC — see ScopeTags-A.md)
    write operation only (POST/PATCH/PUT/DELETE) — GET is never gated
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Automation suddenly returns HTTP 400 on calls that worked for months | App-auth MAA enforcement (2026 change) — automation never sends `x-msft-approval-justification` | List `operationApprovalPolicies`; confirm one matches the resource type being written |
| Automation returns HTTP 412, monitoring flags it as a failure | 412 + `x-msft-approval-code` is MAA's success/pending signal, not an error | Re-read the response headers, not just the status code |
| Retrying the "failed" call creates a duplicate/conflicting request | Blind retry-on-error logic resubmitting without the approval code | Fix automation to branch on 412 specifically and follow the approval-code path |
| Request sits at `needsApproval` for days | No notification exists; approver pool doesn't know a request is waiting | Confirm someone with approver rights was contacted directly |
| Approver clicks Approve but change never happens | Requestor never resubmitted with the approval code / never clicked Complete | Check request `status` — `approved` ≠ `Completed` |
| Approver group members keep disappearing from the group | Group isn't directly assigned to an Intune RBAC role assignment — Intune prunes it periodically | Verify RBAC role-assignment membership for the group object itself |
| A legitimate approver can never successfully approve anything | Approver group is a Microsoft 365 group, mail-enabled security group, or distribution list | Check `securityEnabled`/`mailEnabled`/`groupTypes` on the group object |
| Approver has group membership but "can't approve" in the UI | Missing resource-specific Read permission for that policy type, or unlicensed with unlicensed-access not enabled | Check the approver's Intune RBAC role for the matching Read permission + license |
| Admin can no longer edit any RBAC role or role assignment, including to fix MAA itself | Role-type access policy active + approver-group RBAC assignment was never correctly configured (deadlock) | Confirm a `role`-type policy exists; check whether approver group truly has a role assignment |
| Only some automation accounts fail, others of the same type succeed | Per-app exclusion configured on the access policy for the succeeding service principal | Check the policy's exclusion list for that app registration/service principal ID |
| Requestor is also in the approver group but still can't self-approve | By design — self-approval is never permitted, even for members of the approver group | Route to a genuinely different admin |
| Interactive admin change works fine, but the same resource type fails via script | Access policy only recently extended enforcement to app-auth, or an app-registration exclusion exists for delegated calls incorrectly assumed to also cover app-auth (it's the reverse — exclusions are app-auth only, delegated is always enforced) | Re-check whether the caller is using delegated vs. app-only auth |

---
## Validation Steps

1. **Confirm which workloads have MAA active.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalPolicies"
   ```
   Good: returns 0+ policy objects with `policyType`/`policyPlatform`/`approverGroupIds`. Bad/unexpected: a policy exists for a workload nobody remembers configuring — treat as a real change-control gap, not a bug.

2. **Validate an approver group's type.**
   ```powershell
   Get-MgGroup -GroupId <approverGroupId> -Property SecurityEnabled,MailEnabled,GroupTypes | Select SecurityEnabled,MailEnabled,GroupTypes
   ```
   Good: `SecurityEnabled = True`, `MailEnabled = False`, `GroupTypes` does not contain `Unified`. Bad: any deviation — this group will silently fail to produce usable approvers.

3. **Validate the approver group's RBAC role-assignment membership.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/roleAssignments" |
     Select-Object -ExpandProperty value | Where-Object { $_.members -contains "<approverGroupId>" }
   ```
   Good: at least one role assignment lists the group ID directly in `members`. Bad: no matches — the group will have members pruned automatically and won't function as an approver pool.

4. **Reproduce and correctly interpret a write call against a protected resource.**
   Send a `POST`/`PATCH` to the protected endpoint without the justification header first, and confirm `400`; then with the header, and confirm `412` + `x-msft-approval-code`. Good: exactly this sequence. Bad: a `403` instead (that's a permissions problem upstream of MAA, not MAA itself) or a normal `200`/`201` (MAA isn't actually enforcing on this resource — re-check the policy's `policyType`/`policyPlatform` match).

5. **Poll a pending request's lifecycle end-to-end.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests?`$filter=requestId eq '<code>'"
   ```
   Good: `status` moves `needsApproval` → `approved` → (after resubmission) `Completed`, all within 3 days. Bad: stuck at `needsApproval` past ~2.5 days with no approver contacted, or `Expired`.

6. **Confirm an exclusion is actually scoped to the right policy.**
   Exclusions are per-policy, not tenant-wide or per-app-globally. A service principal excluded on the Scripts policy is still fully enforced against the Apps policy. Re-check exclusions on the *specific* policy the failing call targets.

7. **Confirm licensing isn't silently blocking a would-be approver.**
   Check whether the tenant has **Allow access to unlicensed admins** enabled, and whether the specific approver account holds an Intune license if not. This is a common reason a technically-correct approver group still produces "no one available to approve."

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm MAA is actually the cause.** List active policies; match the failing resource type; confirm the call is a write (not GET); rule out a plain `403` (permissions, not MAA).

**Phase 2 — Classify the failure by HTTP response.** `400` = automation never sends the justification header (client-side gap). `412` + approval code = working as designed, move to Phase 3. Anything else = not MAA — troubleshoot as a normal Graph/RBAC issue.

**Phase 3 — Track the pending request.** Poll `operationApprovalRequests` by `requestId`. If stuck at `needsApproval`, this is a human/process gap (no notification exists) — directly contact an approver-group member.

**Phase 4 — Validate the approver path if approval never seems to land.** Check group type (Security-only), direct RBAC role-assignment membership of the group, individual approver's resource-specific Read permission, and license status. Any one of these failing silently blocks approval with no error surfaced anywhere in the UI or API.

**Phase 5 — Confirm resubmission/completion actually happened.** `approved` is not `Completed`. For app-auth, confirm the automation has a resubmission branch using `x-msft-approval-code`, not just a poll-and-stop.

**Phase 6 — If this is recurring, low-risk automation, evaluate an exclusion** rather than building a full approval-wait loop into every script — but treat every exclusion as a standing risk-acceptance decision, reviewed periodically, not a permanent fix-and-forget.

**Phase 7 — If the failure is specifically about RBAC/role changes and appears to deadlock**, apply the Role-policy recovery playbook below rather than attempting further RBAC edits through the normal path.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Update automation end-to-end for MAA (app-auth)</summary>

1. Identify every write call your automation makes against a resource type covered by an active access policy (cross-reference `operationApprovalPolicies` against the automation's known Graph calls).
2. Add the `x-msft-approval-justification` header (Base64-encoded) to each write call.
3. Branch on the response: `2xx` = no policy active for this call right now, proceed normally; `412` = extract `x-msft-approval-code`, persist it alongside the original request (method/URL/body) in whatever state store the automation uses; `400` = the header itself is malformed or missing — a code bug, fix before deploying further.
4. Build a resubmission path: either a scheduled re-check that polls `operationApprovalRequests` for `status: approved` and then resubmits with `x-msft-approval-code`, or (for automation that can tolerate a longer wait) a webhook/notification-driven approach — Intune itself provides no push notification, so this has to be built external to MAA (e.g., poll on a cadence well inside the 3-day expiry window).
5. Alert distinctly on `400` (code needs fixing) vs. requests stuck at `needsApproval` past a reasonable SLA (process needs attention) vs. `rejected`/`Expired` (needs human investigation) — collapsing all three into one generic "automation failed" alert is the most common operational mistake here.

Rollback: none required — this playbook only adds header/branching logic; it has no effect in tenants or on resource types without an active access policy.

</details>

<details><summary>Playbook 2 — Stand up a correctly-configured approver group from scratch</summary>

1. Create (or select) a Microsoft Entra **security group** — confirm `securityEnabled: true`, `mailEnabled: false` — never repurpose an existing Microsoft 365 group or distribution list for this.
2. Add the intended approvers as **direct** members (not nested via another group).
3. Assign this group as a **member group** on an Intune RBAC role assignment (via **Tenant administration > Roles**), granting at minimum the resource-specific Read permission for every policy type this group will approve (e.g., `ManagedDevices/Read` for device-action approvals, `MobileApps/Read` for app approvals).
4. Confirm each intended approver has an assigned Intune license, or that **Allow access to unlicensed admins** is deliberately enabled (document this decision — it's irreversible).
5. Create the access policy (`policyType` matching the resource to protect) referencing this group in `approverGroupIds`.
6. Validate end-to-end with a low-risk test write against the protected resource before relying on this for production change control.

Rollback: deleting the access policy removes enforcement immediately; the approver group and its RBAC role assignment can be left in place or removed independently — they have no effect without an active policy referencing them.

</details>

<details><summary>Playbook 3 — Recover from a Role-policy RBAC deadlock</summary>

Use when a `role`-type access policy is active and no path exists to modify RBAC (including to fix the approver group's own assignment) because every RBAC change now requires MAA approval that can't be granted.

1. **Tenant administration > Multi Admin Approval > Access policies** — locate the policy with `policyType: role`.
2. Delete it. (Policy deletion itself is not gated by the same RBAC-change enforcement it creates for *other* role edits.)
3. Wait 3–5 minutes for the deletion to propagate through the service.
4. **Tenant administration > Roles** — complete the RBAC role assignment(s) needed, specifically ensuring the intended approver group is added as a **member group** (not just individual members) to an appropriate role assignment.
5. Verify via Validation Step 3 above that the group now resolves correctly.
6. Re-create the Role-type access policy, now that its own dependency (a correctly-assigned approver group) is satisfied.
7. Document this incident — it's a strong signal the original Role-policy rollout skipped the RBAC-assignment verification step, and other access policies in the tenant may have the same latent gap.

Rollback: none needed beyond the playbook itself — deleting and re-creating the Role policy is the intended recovery path, not a destructive workaround.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Read-only evidence collector for a Multi Admin Approval investigation.
.DESCRIPTION
    Pulls active access policies, resolves approver group type/RBAC-assignment health,
    and lists recent approval requests with age/expiry risk. No write operations.
    Requires: DeviceManagementRBAC.Read.All, Group.Read.All (delegated or app-only).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "== Active MAA access policies ==" -ForegroundColor Cyan
$policies = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalPolicies").value
$policies | Select-Object displayName, policyType, policyPlatform, approverGroupIds, lastModifiedDateTime | Format-Table -Wrap

Write-Host "`n== Approver group health per policy ==" -ForegroundColor Cyan
$roleAssignments = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/roleAssignments").value
foreach ($p in $policies) {
    foreach ($gid in $p.approverGroupIds) {
        $g = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=id,displayName,securityEnabled,mailEnabled,groupTypes"
        $isPureSecurity = ($g.securityEnabled -eq $true -and $g.mailEnabled -eq $false -and ($g.groupTypes -notcontains "Unified"))
        $hasRoleAssignment = [bool]($roleAssignments | Where-Object { $_.members -contains $gid })
        [pscustomobject]@{
            Policy               = $p.displayName
            ApproverGroup        = $g.displayName
            IsPureSecurityGroup  = $isPureSecurity
            DirectRBACAssignment = $hasRoleAssignment
            RiskFlag             = if (-not $isPureSecurity -or -not $hasRoleAssignment) { "SILENT FAILURE RISK" } else { "OK" }
        }
    }
}

Write-Host "`n== Recent approval requests (age/expiry risk) ==" -ForegroundColor Cyan
$requests = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests").value
$requests | ForEach-Object {
    $age = (Get-Date) - [datetime]$_.createdDateTime
    [pscustomobject]@{
        RequestId    = $_.requestId
        Status       = $_.status
        CreatedUTC   = $_.createdDateTime
        AgeHours     = [math]::Round($age.TotalHours,1)
        ExpiryRisk   = if ($_.status -eq "needsApproval" -and $age.TotalHours -gt 60) { "APPROACHING 3-DAY TTL" } else { "n/a" }
    }
} | Sort-Object AgeHours -Descending | Format-Table -AutoSize

Write-Host "`nKnown gaps: this pack cannot read the 'Allow access to unlicensed admins' tenant setting or per-policy" -ForegroundColor Yellow
Write-Host "exclusion lists — both are portal/UI-surfaced only as of this writing. Verify manually." -ForegroundColor Yellow
```

---
## Command Cheat Sheet

```powershell
# List all MAA access policies
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalPolicies"

# Get one policy by ID
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalPolicies/<policyId>"

# List / filter approval requests
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests?`$filter=requestId eq '<code>'"

# Check approver group type (must be pure Security group)
Get-MgGroup -GroupId <groupId> -Property SecurityEnabled,MailEnabled,GroupTypes

# Check RBAC role assignments (confirm approver group is a direct member)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/roleAssignments"

# Submit an app-auth write with justification (first attempt)
$headers = @{ "x-msft-approval-justification" = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("<justification>")) }
Invoke-MgGraphRequest -Method POST -Uri "<protected-endpoint>" -Headers $headers -Body $body

# Resubmit after approval
$headers = @{ "x-msft-approval-code" = "<code>" }
Invoke-MgGraphRequest -Method POST -Uri "<protected-endpoint>" -Headers $headers -Body $body

# Resolve approver group membership (who can approve, pending the RBAC/type checks above)
Get-MgGroupMember -GroupId <approverGroupId>

# Interactive-side navigation
# Tenant administration > Multi Admin Approval > Access policies
# Tenant administration > Multi Admin Approval > My requests / Received requests / All requests
# Tenant administration > Roles  (to fix RBAC role assignments)
```

---
## 🎓 Learning Pointers

- The app-auth enforcement change is genuinely new (documented `ms.date` 2026-08-06) and is opt-in *only in the sense that it requires an existing access policy* — once a tenant has any MAA policy configured for a workload, app-auth calls against it are enforced automatically with no separate switch. Read [Use Multi Admin Approval with the Microsoft Graph API](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control/multi-admin-approval-graph-api) before assuming legacy automation is safe.
- Treat `412` + `x-msft-approval-code` as a distinct, expected outcome in any monitoring/alerting you build around Intune Graph automation — conflating it with a genuine `4xx`/`5xx` failure is the single most common false-positive source once MAA is enabled.
- The approver-group requirements (pure security group, direct RBAC role-assignment membership, direct — not nested — membership) are all **silent-failure conditions**. None of them produce an error at policy-creation time. Build your own validation (see the Evidence Pack above) rather than trusting the UI to tell you something's wrong.
- Read the **Role policy type** deadlock scenario in [Use access policies to require multi admin approval — More considerations](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control/multi-admin-approval#more-considerations) *before* enabling a Role access policy in a live tenant, not after getting locked out.
- The `operationApprovalPolicy` Graph resource schema (`policyType`, `policyPlatform`, `approverGroupIds`, `policySet`) is documented at [operationApprovalPolicy resource type](https://learn.microsoft.com/en-us/graph/api/resources/intune-rbac-operationapprovalpolicy?view=graph-rest-beta) — note that the documented schema does **not** expose a per-app exclusion list property; exclusions are configured and reviewed in the Intune admin center UI only as of this writing, a genuine Known-Gap for any Graph-only auditing tooling (including the accompanying script in this repo).
- If Windows PowerShell script deployment approvals are a recurring bottleneck, the **Change Review Agent** (part of Intune Copilot) can generate approve/reject suggestions directly inside the Multi Admin Approval UI — see [Change Review Agent overview](https://learn.microsoft.com/en-us/intune/copilot/agents/change-review-agent). It does not remove the human-approval requirement (an agent still can't approve on Intune's behalf per the "applications can't approve their own requests" rule), it only speeds up the human's decision.
