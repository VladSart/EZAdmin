# Intune Deployment Plans & Deployments (Ring-Based Rollouts) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Context:** Intune **Deployments** (public preview) roll a single payload — a Win32 app, Enterprise App Catalog app, Settings catalog policy, or Endpoint security policy, Windows 10/11 only — out across timed **rings**. A **deployment plan** is the reusable ring template. Deployments only add group assignments to the payload as each ring activates. They don't hold their own copy of the payload. Location: **Intune admin center > Devices > Manage devices > Deployments**. Sources: [Deployment plans and deployments overview](https://learn.microsoft.com/en-us/intune/device-management/deployments/overview), [Create and manage a deployment](https://learn.microsoft.com/en-us/intune/device-management/deployments/create-deployment), [Permissions, scope tags, and approvals](https://learn.microsoft.com/en-us/intune/device-management/deployments/rbac-scope-tags), [Known issues](https://learn.microsoft.com/en-us/intune/device-management/deployments/known-issues). All four pages were fetched live on 2026-09-25 (`ms.date` 2026-08-26, `updated_at` 2026-09-21).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Typical tickets: a deployment is paused in an **error state**; a new deployment is missing from the list; the payload wasn't offered in the wizard; **Cancel** didn't remove the app or policy from devices; the final ring replaced the payload's existing assignments.

```powershell
# Prereq: Connect-MgGraph -Scopes DeviceManagementConfiguration.Read.All,DeviceManagementApps.Read.All,Group.Read.All
# No Graph/PowerShell surface for the Deployments objects themselves is documented yet (preview).
# Triage reads the PAYLOAD, because the payload's assignments are the source of truth.

# 1. Settings catalog / Endpoint security payload: current assignments
$policyId = '<configurationPolicyId>'
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId/assignments").value |
    ForEach-Object { [pscustomobject]@{ Type = $_.target.'@odata.type'; GroupId = $_.target.groupId; Filter = $_.target.deviceAndAppManagementAssignmentFilterId } }

# 2. Win32 / Enterprise App Catalog payload: assignments + intent
$appId = '<mobileAppId>'
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/assignments").value |
    ForEach-Object { [pscustomobject]@{ Intent = $_.intent; Type = $_.target.'@odata.type'; GroupId = $_.target.groupId } }

# 3. Is a ring group deleted (hard) or soft-deleted (restorable for 30 days)?
$gid = '<ringGroupObjectId>'
try { Get-MgGroup -GroupId $gid -Property Id,DisplayName | Select-Object Id,DisplayName; 'LIVE' }
catch { try { Get-MgDirectoryDeletedItemAsGroup -DirectoryObjectId $gid | Select-Object Id,DisplayName,DeletedDateTime; 'SOFT-DELETED' } catch { 'PERMANENTLY DELETED / not found' } }
```

| Observation | Meaning | Do |
|---|---|---|
| Deployment paused in **error**, and a ring group also appears in the payload's own assignments (step 1/2) | **Assignment collision** detected when the ring activated | [Fix 1](#fix-1) |
| Deployment in error with **Group deleted from Microsoft Entra ID** | A ring group was permanently deleted | [Fix 2](#fix-2): cancel or delete it, then recreate |
| Deployment in error, group status **Soft-deleted** (step 3 = SOFT-DELETED) | Ring group is in the 30-day recycle bin | [Fix 2](#fix-2): restore the group, then Resume |
| Deployment created but **not in the Deployments list** | Payload is protected by a **Multi Admin Approval** access policy and the request is still pending (known issue) | [Fix 3](#fix-3) |
| Payload missing from **Add payload** picker | Not supported (platform or type), admin's scope tags don't cover it, or it's already in another scheduled/active deployment | [Fix 4](#fix-4) |
| Win32/EAC app has `available` or `uninstall` intent assignments | Deployments support **Required** only | [Fix 4](#fix-4) |
| Cancelled deployment, but devices still get the app or policy | **By design.** Cancel stops ring progression. It doesn't remove assignments that earlier rings added | [Fix 5](#fix-5) |
| After the final ring, the payload's original group assignments are gone and only **All devices**/**All users** remains | **By design.** The virtual-group ring replaces the Required include assignments. Excludes stay | [Fix 6](#fix-6) |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Windows 10/11 device, Intune-enrolled
 └─ Payload exists in Intune and is a supported type
      ├─ Settings catalog policy | Endpoint security policy
      └─ Win32 app | Enterprise App Catalog app  → Required intent only
           (EAC: "Update with supersedence" OK; "Automatically update" NOT supported)
 └─ Admin RBAC
      ├─ Deployment plan: Deployment plan C/R/U/D permission (built-in roles:
      │    Application Mgr, Policy & Profile Mgr, Endpoint Security Mgr, School Admin = CRUD;
      │    Read Only Operator, Help Desk Operator = Read)
      └─ Deployment: NO dedicated permission; Read + Assign on payload category
           (Device configurations OR Mobile apps). Scope tags come from the PAYLOAD.
 └─ Multi Admin Approval (if an access policy covers the payload type)
      └─ Create / Resume / Cancel / Delete each need approval
 └─ Deployment (one payload, not in another scheduled/active deployment)
      └─ Rings: ≥1 group each, ≥1 hour apart, excludes apply to all rings
           ├─ Ring N activates → collision check (ring group ∈ payload assignments? → ERROR + pause)
           ├─ Group checks (soft-deleted / permanently deleted → ERROR)
           └─ Ring groups ADDED to payload Required assignments (cumulative)
                └─ Virtual-group ring (All users / All devices) = FINAL ring
                     └─ REPLACES Required include-group assignments; excludes preserved
 └─ Device check-in → normal Intune policy/app processing (IME for Win32)
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm platform and payload type.** Only Windows 10 and later, and only the four payload types above.
   ```powershell
   (Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/<id>?`$select=name,platforms,technologies,templateReference").templateReference
   ```
   Expected: `platforms` = `windows10`. A populated `templateReference.templateFamily` like `endpointSecurity*` means it's an Endpoint security policy. `none` means plain Settings catalog. Older template-based ("intent") endpoint security policies aren't `configurationPolicies` objects, so the picker may not list them. Treat that as unconfirmed and check the picker.

2. **Collision check.** Compare the ring's groups (from the deployment's details pane) with the payload assignments from Triage 1/2. Any shared group ID is a collision. Intune checks at creation and again at every ring activation.

3. **Deleted-group check.** Run Triage step 3 for every group in the erroring ring. Permanently deleted means the deployment can't recover. Soft-deleted means restore and then Resume.

4. **MAA check.** If the deployment is missing or stuck, go to **Tenant administration > Multi Admin Approval** (or **Admin tasks**) and look for a pending request against the deployment. The approver needs **Read** on the payload to open the link in the request.

5. **Check the effect on devices.** Deployments only change assignments. Once the ring's groups are on the payload, normal processing takes over. For Win32 apps, check `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppWorkload.log`. For policies, check per-device status on the payload itself.

---
## Common Fix Paths

<details><summary id="fix-1">Fix 1 — Assignment collision (deployment paused in error)</summary>

1. Find the group that appears in both the payload's assignments and the activating ring (Diagnosis 2).
2. Remove that group **from the payload's assignments**. The deployment's rings can't be edited after creation.
   ```powershell
   # Settings catalog: re-POST the full assignment set WITHOUT the colliding group (assign replaces the whole set)
   $policyId = '<configurationPolicyId>'; $colliding = '<groupId>'
   $current = (Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId/assignments").value
   $current | ConvertTo-Json -Depth 6 | Out-File "$env:TEMP\assign-backup-$policyId.json"   # rollback copy (full original set)
   $keep = $current | Where-Object { $_.target.groupId -ne $colliding } | ForEach-Object { @{ target = $_.target } }
   Invoke-MgGraphRequest POST "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId/assign" -Body (@{ assignments = @($keep) } | ConvertTo-Json -Depth 8)
   ```
   For apps, removing the assignment in the portal (**App > Properties > Assignments**) is safer than using the API.
3. Go back to the deployment and select **Resume**. If MAA covers the payload type, Resume needs approval.
4. **Rollback:** the backup JSON holds the full original set. Re-post its entries (as `@{ target = ... }` objects) to `/assign` to restore. Removing a group can stop delivery to those devices until the ring adds it back, so do this in a change window.
</details>

<details><summary id="fix-2">Fix 2 — Ring group deleted</summary>

- **Soft-deleted:**
  ```powershell
  Restore-MgDirectoryDeletedItem -DirectoryObjectId '<groupId>'
  ```
  Then **Resume**. Resume stays greyed out until *every* soft-deleted group in the deployment is restored.
- **Permanently deleted**, or a mix of permanently and soft-deleted: the deployment can't recover. **Cancel** or **Delete** it, fix the plan (remove the deleted groups and give any empty ring at least one group), then create a new deployment. Groups added by rings that already ran stay on the payload.
- **Plans:** opening a plan with deleted groups shows a banner. You can't save the plan, or create a deployment from it, until the groups are removed.
</details>

<details><summary id="fix-3">Fix 3 — Deployment missing from the list / action "did nothing" (Multi Admin Approval)</summary>

1. **Tenant administration > Multi Admin Approval > Received requests** (approver view) or **My requests** (requester view).
2. Approve (as a different admin), then the requester **completes** the request. Until approval, the deployment doesn't appear in the list (documented known issue).
3. Remember that **Resume, Cancel, and Delete** also go through MAA. A "Cancel that didn't cancel" is often just waiting for approval.
</details>

<details><summary id="fix-4">Fix 4 — Payload not selectable in the wizard</summary>

| Cause | Fix |
|---|---|
| Not Windows, or an unsupported type (iOS app, Admin template, LOB MSI, and so on) | Not supported in preview. Use manual ring assignments or Autopatch for updates |
| Payload already in another scheduled or active deployment | Finish, cancel, or delete that deployment first |
| Admin's scope tags don't include the payload | Add the scope tag to the admin's role assignment, or have an in-scope admin create it |
| Win32/EAC app has Available/Uninstall assignments | Deployments only drive **Required**. Keep Available assignments separately, but they're outside the ring model |
| EAC app set to **Automatically update** | Not supported with deployments. Switch to supersedence-based updates |
</details>

<details><summary id="fix-5">Fix 5 — "We cancelled but it's still installing"</summary>

Cancel and Pause both leave any assignments already added in place. To actually pull back:
1. Open the payload's **Assignments** and remove the groups the completed rings added. Use Fix 1's snippet for policies.
2. For apps you want **removed** from devices, add an **Uninstall** assignment separately. Deployments don't do uninstall rollbacks.
3. **Rollback:** re-add the groups from the backup JSON.
</details>

<details><summary id="fix-6">Fix 6 — Final ring wiped the original targeted groups</summary>

This is by design. When the virtual-group ring (All users / All devices) activates, it **replaces** the Required include-group assignments. Excludes are preserved. If you still need a narrower Required scope:
- Add the specific groups back on the payload afterwards (direct payload changes always win over the deployment), **or**
- Rebuild the plan so the final ring uses a broad security group instead of a virtual group. Security groups are additive, not replacing.
</details>

---
## Escalation Evidence

```
INTUNE DEPLOYMENTS (PREVIEW) — ESCALATION
==========================================
Ticket #: <>
Tenant ID: <>
Deployment name: <>          Created by: <UPN>     Created (UTC): <>
Deployment plan used: <name / "manual rings">
Payload type: <Settings catalog / Endpoint security / Win32 / EAC>   Payload ID: <>
Deployment state: <scheduled / active / paused / error / cancelled>
Error text shown: <e.g. "Group deleted from Microsoft Entra ID" / collision>
Ring that failed: <ring name>   Ring start (UTC): <>
Ring group IDs + live/soft-deleted/deleted status: <>
Payload assignments at time of failure (export JSON attached): <yes/no>
Multi Admin Approval policy covers payload type: <yes/no>  Pending request ID: <>
Admin role + scope tags of the operator: <>
Steps already taken (Fix #): <>
Repro in a second tenant/payload: <yes/no>
```

---
## 🎓 Learning Pointers
- **The payload is the source of truth.** Deployments only add groups to the payload's own Required assignments. That's why a collision stops the run, why Cancel doesn't roll anything back, and why any direct edit to payload assignments overrides the deployment. See [How payload assignments change as rings deploy](https://learn.microsoft.com/en-us/intune/device-management/deployments/overview#how-payload-assignments-change-as-rings-deploy).
- **A virtual group in a ring replaces, it doesn't add.** An All users / All devices ring is automatically the last ring and swaps out the earlier Required include groups. Excludes survive. Design plans with this in mind.
- **Deployments have no permission of their own.** Anyone with Read + Assign on the payload category can create one, and scope tags come from the payload. Plans are the only object with dedicated CRUD permissions: [Permissions, scope tags, and approvals](https://learn.microsoft.com/en-us/intune/device-management/deployments/rbac-scope-tags).
- **With MAA, four actions need approval** (Create, Resume, Cancel, Delete), and a pending Create is hidden from the list. For MAA itself, see [MultiAdminApproval-B.md](MultiAdminApproval-B.md) and [Use Multi Admin Approval in Intune](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control/multi-admin-approval).
- Before creating a deployment, run `Intune/Scripts/Get-IntuneDeploymentReadiness.ps1` against the payload and your planned ring groups. It catches collisions, unsupported intents, and deleted groups before they turn into a paused rollout.
- Deep dive and design guidance: [DeploymentPlans-A.md](DeploymentPlans-A.md).
