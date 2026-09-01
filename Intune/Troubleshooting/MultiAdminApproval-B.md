# Multi Admin Approval (MAA) — Hotfix Runbook (Mode B: Ops)
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

Run these against Microsoft Graph (delegated or app-only, `DeviceManagementRBAC.Read.All` + `DeviceManagementConfiguration.Read.All` minimum) to confirm this is MAA before chasing anything else.

```powershell
# 1. Is MAA even configured in this tenant? (no policies = MAA cannot be the cause)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalPolicies" |
  Select-Object -ExpandProperty value | Select-Object displayName, policyType, policyPlatform, approverGroupIds

# 2. Does the failing call's target resource type match an active policy's policyType?
#    (Apps / Compliance policies / Configuration policies / Device actions / Role / Scripts / Tenant Configuration)

# 3. Was the failing call app-auth (service principal / automation) or delegated (interactive admin)?
#    Check the sign-in log entry or the app registration used by the automation.

# 4. Pull the raw HTTP response from the failing call. Look for one of two specific signals:
#    - HTTP 400, body mentions "x-msft-approval-justification" required  -> header missing entirely
#    - HTTP 412 Precondition Failed, response has an "x-msft-approval-code" header -> this is NOT a failure,
#      it means MAA accepted the request and is waiting for a second admin to approve it

# 5. If you have a code from #4, check its live status:
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests?`$filter=requestId eq '<approval-code>'" |
  Select-Object -ExpandProperty value | Select-Object requestId, status, createdDateTime, requestorId
```

| Signal | Interpretation | Do This |
|---|---|---|
| No policies returned in step 1 | MAA is not enabled for any workload in this tenant | The failure is NOT MAA — look elsewhere (permissions, throttling, payload validation) |
| HTTP 400, missing justification header | Automation was never updated for MAA | Fix 1 |
| HTTP 412 + `x-msft-approval-code` present | Working as designed — request is pending approval | Fix 2 |
| `status: needsApproval` for >2.5 days | Request is about to expire (3-day TTL) | Fix 3 (escalate for approval NOW) |
| `status: rejected` | An approver explicitly rejected it | Fix 4 |
| `status: approved` but resource never got created/changed | Requestor never resubmitted with the approval code | Fix 5 |
| Automation account is a service principal and can't get anyone to approve in time | Frequent, low-risk automation | Fix 6 (exclusion) |
| Policy `policyType` is `role` and you're now locked out of fixing RBAC itself | Deadlock — MAA guarding its own prerequisite | Fix 7 |
| Interactive admin, not automation, hitting this | Same workflow, different door | Fix 8 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant has >= 2 admin accounts
    └─ At least one MAA access policy exists for the affected workload (opt-in, not default-on)
         └─ Policy's approverGroupIds points to a group that is:
              ├─ a pure Security group (NOT a Microsoft 365 group, NOT mail-enabled, NOT a distribution list
              │    — these silently fail to resolve approvers, no error is shown)
              └─ directly assigned as a member group to an Intune RBAC role assignment
                   (permissions held via nested groups or direct user assignment do NOT satisfy this)
                        └─ Approver group members periodically get REMOVED from the group if this isn't true
              └─ Caller (interactive OR app-auth/service principal) submits the change
                   ├─ Delegated (interactive): business justification entered in the UI
                   └─ App-auth (Graph API): x-msft-approval-justification header, Base64-encoded
                        └─ Server returns 412 + x-msft-approval-code (this IS the "accepted, pending" signal)
                             └─ A DIFFERENT admin account, member of the approver group, with the
                                resource-specific Read permission for that policy type, approves
                             └─ Original requestor/caller resubmits with x-msft-approval-code header
                                  (or clicks Complete in the portal, for delegated requests)
                                       └─ Change is applied. Status -> Completed.
                                       └─ Miss this last step within 3 days -> request Expires, start over
```

Applications can NEVER approve their own (or anyone else's) MAA request — only an interactive admin sign-in can approve. An automation account stuck waiting on itself is a design gap in the automation, not a bug in MAA.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm MAA is actually in play.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalPolicies"
   ```
   Expected: at least one policy object with a `policyType` matching the resource the failing call targets (`app`, `script`, `compliancePolicy`, `configurationPolicy`, `deviceAction`/`deviceWipe`/`deviceRetire`/`deviceDelete`, `role`, `tenantConfiguration`). No policies = stop, this isn't MAA.

2. **Re-run the failing call manually and capture the raw response body and headers**, not just the status code. The difference between "broken" and "working as designed" is entirely in the headers.
   - Missing header entirely → HTTP `400`.
   - Header present, MAA accepted the request → HTTP `412 Precondition Failed` with an `x-msft-approval-code` response header. **This is success, not an error** — many automation frameworks treat any non-2xx as a hard failure and alert on it incorrectly.

3. **Check GET vs. write.** MAA only intercepts `POST`/`PATCH`/`PUT`/`DELETE`. If the failing call is a `GET`, MAA is not the cause — look elsewhere.

4. **Look up the approval request status.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests?`$filter=requestId eq '<approval-code>'"
   ```
   Expected good output: `status` progresses `needsApproval` → `approved` → (requestor resubmits/completes) → `Completed`. `rejected` and `cancelled` are terminal — the original request must be resubmitted from scratch.

5. **If `status` is stuck at `needsApproval`,** confirm a human with approver rights actually knows a request is waiting — Intune sends **no notification** when a request is created. This is the single most common cause of "it's been stuck for days."

6. **If approvals never seem to land even when someone approves,** verify the approver group itself: is it a Security group (not M365/mail-enabled/DL), and is it directly assigned as a member group on an Intune RBAC role assignment? Both are silent-failure conditions with no error surfaced to the approver.

7. **Validate the fix** by re-submitting the original request with the `x-msft-approval-code` header and confirming the resource now exists/changed, and that the approval request's `status` reads `Completed`.

---
## Common Fix Paths

<details><summary>Fix 1 — Automation never updated for MAA (HTTP 400, missing justification header)</summary>

Update the automation to send the required header on the first attempt:

```http
POST https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts
Content-Type: application/json
x-msft-approval-justification: <Base64-encoded justification string>

{ ... resource body ... }
```

```powershell
$justification = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Scheduled compliance policy update - change ticket 4821"))
$headers = @{ "x-msft-approval-justification" = $justification }
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts" -Headers $headers -Body $body
```

Rollback: none needed — this only adds a required header, it does not change behavior for tenants without MAA policies configured.

</details>

<details><summary>Fix 2 — 412 response with an approval code (this is expected, not broken)</summary>

Do not retry the call as-is; retrying without the approval code just creates a duplicate pending request rejected with "a request for this object is already pending."

1. Extract `x-msft-approval-code` from the response headers.
2. Save the original method, URL, and body — you must resend the *exact same* request in step 4.
3. Wait for `status: approved` (poll `operationApprovalRequests?$filter=requestId eq '<code>'`).
4. Resubmit with `x-msft-approval-code` in place of the justification header:

```powershell
$headers = @{ "x-msft-approval-code" = "<approval-code>" }
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts" -Headers $headers -Body $body
```

Rollback: n/a — no change has been applied yet at this stage.

</details>

<details><summary>Fix 3 — Request about to expire (3-day TTL, status still needsApproval)</summary>

Requests that aren't approved AND completed within 3 days silently expire and must be resubmitted from scratch — there's no grace period or extension.

1. Identify who is in the approver group for the relevant policy (`approverGroupIds` on the `operationApprovalPolicy` object → resolve via `Get-MgGroupMember`).
2. Contact them directly — Intune does not send a notification when a request is created or about to expire.
3. If nobody in the approver group is reachable, this is a process gap, not a technical one — escalate to the access-policy owner.

Rollback: n/a.

</details>

<details><summary>Fix 4 — Request rejected</summary>

Rejections are terminal. Pull the approver's rejection notes (visible to the requestor on **My requests** in the Intune admin center, or via the request object) and resubmit a corrected request from scratch with a stronger business justification if the rejection was about insufficient justification rather than the change itself.

Rollback: n/a — nothing was applied.

</details>

<details><summary>Fix 5 — Approved but never completed</summary>

`approved` only means a second admin signed off — Intune does not auto-apply the change. The *original requestor* must resubmit the request with the `x-msft-approval-code` header (API) or select **Complete** (portal UI). Confirm the original caller has this step wired into its automation — a common gap is code that submits and polls for `approved` but never resubmits.

Rollback: n/a.

</details>

<details><summary>Fix 6 — Exclude a trusted automation account from MAA enforcement</summary>

Use for frequent, low-risk automation where a human approval loop isn't practical (e.g., a nightly compliance-policy sync). Exclusions apply **only** to app-auth calls from that specific service principal — interactive/delegated calls against the same resource are still gated.

1. In the Intune admin center: **Tenant administration** > **Multi Admin Approval** > **Access policies** > select the policy > **Exclusions** tab > **Add enterprise applications**.
2. Select the automation's app registration/service principal.
3. A second administrator must approve the exclusion change itself before it takes effect.

Limits: 50 excluded apps per policy, exclusion scope is per-policy (excluding an app from the Scripts policy does not exclude it from the Apps policy).

**Rollback:** remove the application from the Exclusions tab on the same access policy. Also requires a second-admin approval, and is logged in the Intune audit log same as the original exclusion.

⚠️ Security note: every exclusion is a standing gap in the approval workflow for that resource type. Review the exclusion list periodically — this is exactly the control MAA exists to enforce, so don't exclude broadly just to make automation errors go away.

</details>

<details><summary>Fix 7 — Deadlocked on the Role access policy (can't fix RBAC because RBAC changes need MAA approval)</summary>

If a `role`-type access policy is active and the approver group was never correctly assigned to an RBAC role assignment (or the assignment was removed), you can end up unable to make the very RBAC change MAA needs to function.

1. **Tenant administration** > **Multi Admin Approval** > **Access policies** > find the `role`-type policy > delete it. (Deleting the policy itself is not gated the same way as modifying RBAC role assignments.)
2. Wait 3–5 minutes for the deletion to propagate.
3. **Tenant administration** > **Roles** — complete the RBAC role assignment that adds the approver group as a member group.
4. Re-create the `role`-type access policy once RBAC is correctly configured.

Rollback: re-creating the deleted policy restores enforcement; there is no data loss from the deletion itself, only a temporary enforcement gap on Role changes during steps 2–4.

</details>

<details><summary>Fix 8 — Interactive admin stuck (not automation)</summary>

Same underlying workflow, portal UI instead of headers:

1. Admin submits the change, enters a **Business justification** on the Save + Review screen.
2. A different admin (approver group member, not the requestor, not a self-approval even if the requestor is also in the approver group) approves via **Tenant administration** > **Multi Admin Approval** > **Received requests**.
3. Original admin returns to **My requests** and selects **Complete**.

If the requestor is the *only* member of the approver group, no one can approve — this is a policy misconfiguration (Fix 7's RBAC-assignment check applies here too), not a bug.

Rollback: n/a.

</details>

<details><summary>Fix 9 — Unlicensed admin can't participate in MAA at all</summary>

By default, MAA participants (requestors and approvers) need an Intune license. If a needed approver is unlicensed, either assign them a license, or have someone with the right permission enable **Allow access to unlicensed admins** in tenant settings.

⚠️ **This setting is irreversible — it cannot be turned back off once enabled.** Confirm this is genuinely wanted (and understand the licensing/group-membership-cap implications) before enabling it, rather than flipping it as a quick unblock.

Rollback: none available — do not treat this as a reversible troubleshooting step.

</details>

---
## Escalation Evidence

```
MULTI ADMIN APPROVAL — ESCALATION TEMPLATE
============================================
Tenant: <tenant ID / name>
Affected workload/policyType: <app | script | compliancePolicy | configurationPolicy | deviceAction | role | tenantConfiguration>
Access policy name: <displayName from operationApprovalPolicies>
Caller type: <interactive admin UPN | service principal / app registration name + app ID>
Approval request ID (x-msft-approval-code): <code, if one was issued>
Request status at time of escalation: <needsApproval | approved | rejected | cancelled | expired>
Request created: <createdDateTime>          Time since creation: <duration>
Raw HTTP response from the failing call (status + body, headers included): <paste>
Approver group for this policy: <group display name / object ID>
Approver group validated as pure Security group (not M365/mail-enabled/DL): <yes/no>
Approver group confirmed directly assigned to an Intune RBAC role assignment: <yes/no>
Is this a repeat/recurring automation failure or a one-off interactive request: <recurring/one-off>
Business impact / urgency: <description>
Requested action: <approve this specific request | fix approver group config | add exclusion | escalate RBAC deadlock>
```

---
## 🎓 Learning Pointers

- MAA enforcement on app-auth (Graph API/automation) calls is a change that shipped in **2026** — any automation written before then almost certainly does not send the justification header, and this is the #1 root cause of a sudden wave of failures with no code change on your side. See [Use Multi Admin Approval with the Microsoft Graph API](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control/multi-admin-approval-graph-api).
- HTTP `412 Precondition Failed` with an `x-msft-approval-code` header is **not an error condition** — it's MAA's way of saying "accepted, now pending." Alert on `400` (misconfigured automation) differently than `412` (working as designed, needs a human) in your monitoring.
- The approver group's two silent-failure conditions — wrong group type (must be pure Security, not M365/mail-enabled/DL) and not being directly assigned to an RBAC role assignment — produce **no error message anywhere**. If approvals "don't seem to work," check these first before assuming a Graph/API bug.
- The `role` policyType is the one access policy type that can deadlock your own tenant — read [Use access policies to require multi admin approval](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control/multi-admin-approval#more-considerations) before enabling it, and know Fix 7 before you need it.
- Requests are a **3-day TTL, no notifications, no auto-extend**. If your org relies on MAA for routine automation, someone needs an operational habit (or your own alerting on `needsApproval` age) or things will silently expire.
- If the Change Review Agent (Intune Copilot) is enabled in your tenant, it can suggest approve/reject decisions specifically for Windows PowerShell script requests inside the same Multi Admin Approval UI — worth enabling if script-deployment approvals are a high-volume bottleneck. See [Change Review Agent overview](https://learn.microsoft.com/en-us/intune/copilot/agents/change-review-agent).
