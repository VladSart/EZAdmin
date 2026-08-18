# Microsoft Loop — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** Microsoft Loop is not one thing — "Loop components" (small `.loop` files embedded in Outlook/Teams/OneNote/Whiteboard) and "Loop workspaces" (the standalone Loop app) are controlled by **two completely separate admin policy tools that must BOTH be configured** — Cloud Policy (`config.office.com`) governs everything except Teams; SharePoint PowerShell (`Set-SPOTenant`) governs Teams only. Most "Loop is half-working" tickets are this split, not a real fault. Loop's personal **My workspace** also shares its storage container with **Copilot Pages and Copilot Notebooks** — in every admin tool and audit log, that shared container is identified only as application `Loop`, regardless of which feature actually created it.

```powershell
# 1. Confirm the SharePoint PowerShell module is connected (needed for the Teams-side settings
#    and all SharePoint Embedded container management below)
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
Get-SPOTenant | Select-Object IsLoopEnabled, IsCollabMeetingNotesFluidEnabled

# 2. Cloud Policy state has NO PowerShell read — confirm manually at https://config.office.com
#    > Customization > Policy Management, looking for these three policy names:
#      - "Create Loop workspaces in Loop"
#      - "Create and view Loop files in Microsoft apps that support Loop"
#      - "Create and view Loop files in Outlook"

# 3. OWA mailbox policy gate (blocks Loop in Outlook on the web / new Outlook for Windows even
#    when Cloud Policy allows it)
Get-OwaMailboxPolicy | Select-Object Identity, DirectFileAccessOnPrivateComputersEnabled, `
    WacViewingOnPrivateComputersEnabled, DirectFileAccessOnPublicComputersEnabled, `
    WacViewingOnPublicComputersEnabled

# 4. List every user-owned container (My workspace / Copilot Pages / Copilot Notebooks — all
#    identified by the Loop Web Application ID regardless of which feature created them)
Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' |
    Where-Object OwnershipType -EQ 'UserOwned' | Format-Table

# 5. Find ownerless tenant-owned Loop workspaces (all owners left the org)
Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' |
    Where-Object { $_.OwnersCount -eq 0 } | Format-Table
```

**Interpret immediately:**

| Symptom | Quick check | Go to |
|---|---|---|
| Loop works in Teams, not in Outlook/OneNote/Whiteboard (or vice versa) | Only one of the two policy tools was configured | Fix 1 |
| Loop still creatable in web Outlook/new Outlook despite Cloud Policy disabled | OWA mailbox policy booleans still `True` — a second, independent gate | Fix 2 |
| Disabling both Loop policies still leaves the shared personal container appearing | Only one of the *two* creation policies (`Create Loop workspaces in Loop` / `Create and view Copilot Pages and Copilot Notebooks`) was disabled — either alone can create it | Fix 3 |
| eDiscovery custodian search shows no results for a user's My workspace content | Container isn't a selectable data source yet (pre-rollout) or wasn't manually added | Fix 4 |
| Retention label doesn't appear as an option when right-clicking a Loop component | Expected — retention labels can't be applied directly on a component, only inside the Loop app itself | Fix 5 |
| A shared Loop workspace vanished and users report "it's just gone" | No end-user recycle bin for workspaces (components/pages have one, workspaces don't) — needs admin-side container restore | Fix 6 |
| GCC/GCC High/DoD/sovereign-cloud tenant reports the Loop app is entirely missing | Expected — Loop **workspaces** are commercial-cloud only; only some Loop components in Teams are available in government clouds | Fix 7 |
| A departed employee's Loop/Copilot content needs preserving before deletion | No automatic manager handoff (unlike OneDrive) — must be done manually before the retention window ends | Fix 8 |
| Nobody can manage a shared workspace, "all owners left" | `OwnersCount -eq 0` — ownerless tenant-owned workspace | Fix 9 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft 365 tenant with OneDrive/SharePoint licenses (Loop components)
    + "Loop with workspaces" service plan (Loop workspaces specifically)
    │
    ▼
TWO independent admin policy tools — BOTH must allow creation, checked by different apps
    │
    ├── Cloud Policy (config.office.com) — checked by everything EXCEPT Teams
    │     ├── "Create Loop workspaces in Loop"                          → Loop app workspaces
    │     ├── "Create and view Loop files in Microsoft apps that       → Outlook, Teams New
    │     │    support Loop"                                              Calendar, OneNote,
    │     │                                                                Whiteboard
    │     └── "Create and view Loop files in Outlook"                  → Outlook + Teams New
    │          (checked in addition to the app-wide setting above)         Calendar, narrower
    │
    └── SharePoint org properties (PowerShell only, Teams-only, tenant-wide, not per-user)
          ├── IsLoopEnabled                        → Loop components in Teams chat/channels
          └── IsCollabMeetingNotesFluidEnabled      → Collaborative meeting notes (Teams
                                                          classic calendar only — New Calendar
                                                          meeting notes use Cloud Policy instead)
    │
    ▼
Additional per-surface gate: OWA mailbox policy (Exchange Online, independent of both above)
    Outlook on the web / new Outlook for Windows require 4 booleans TRUE:
    DirectFileAccessOn{Private,Public}ComputersEnabled + WacViewingOn{Private,Public}ComputersEnabled
    │
    ▼
Storage layer — WHERE content lands depends entirely on WHERE it was created
    ├── Loop app (any workspace) + Teams chat notes  → SharePoint Embedded container
    ├── Teams channel / channel meeting                → SharePoint site (channel/Meetings folder)
    ├── Teams private chat/meeting, Outlook, OneNote,  → User's OneDrive
    │   Whiteboard
    └── Personal "My workspace"                        → SAME user-owned SharePoint Embedded
                                                            container shared with Copilot Pages
                                                            and Copilot Notebooks — always
                                                            identified as application "Loop"
    │
    ▼
Governance layer (Purview) — applies AFTER the container/site/OneDrive location is settled
    eDiscovery, Legal Hold, retention policies/labels, sensitivity labels, DLP, audit logs —
    all target "All SharePoint Sites" scope or the specific container URL, never a Loop-specific
    scope of its own
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm which Teams-side switches are set.**
   ```powershell
   Get-SPOTenant | Select-Object IsLoopEnabled, IsCollabMeetingNotesFluidEnabled
   ```
   - Good: both `True` if Teams-side Loop should work.
   - Bad: either `False` while the complaint is Teams-specific → Fix 1.

2. **Confirm Cloud Policy state manually** (no PowerShell read exists for this).
   - Sign in to `https://config.office.com` → Customization → Policy Management.
   - Good: the relevant policy for the affected app (see Dependency Cascade above) is Enabled or Not configured.
   - Bad: Disabled, or a lower-priority group policy is overriding the intended one → Fix 1.

3. **If the complaint is specific to Outlook on the web or new Outlook for Windows, check the OWA mailbox policy.**
   ```powershell
   Get-OwaMailboxPolicy -Identity <policyName> | Select-Object Direct*Enabled, Wac*Enabled
   ```
   - Good: all four relevant booleans `True` for the session type in question (Private vs. Public).
   - Bad: any `False` → Fix 2, even if Cloud Policy looks correct.

4. **If trying to fully disable Loop and content still appears, check BOTH creation policies for the shared personal container.**
   - Good: `Create Loop workspaces in Loop` AND `Create and view Copilot Pages and Copilot Notebooks` are both Disabled for the affected user/group.
   - Bad: only one is disabled → Fix 3.

5. **If this is a compliance/eDiscovery request, locate the container first.**
   - SharePoint admin center → Containers → Active containers → filter **Application name: Loop**.
   - Confirm whether the custodian-picker integration (rolling out early August 2026) is present in this tenant's Purview eDiscovery UI, or whether the container URL must be added manually → Fix 4.

6. **If a workspace is missing, distinguish "deleted" from "never existed here."**
   ```powershell
   Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' |
       Where-Object DisplayName -like "*<workspace name>*"
   ```
   - Good: found in Active containers (points to a policy/permission issue) or in Deleted containers within the recycle-bin window (restorable) → Fix 6.
   - Bad: not found anywhere and past the recycle-bin window → unrecoverable, set expectations accordingly.

7. **If the tenant is a government/sovereign/air-gapped cloud, confirm this before troubleshooting further.**
   - Good: client understands Loop workspaces are commercial-cloud-only by design.
   - Bad: time being spent trying to "fix" a platform-availability gap → Fix 7, stop troubleshooting.

---
## Common Fix Paths

<details><summary>Fix 1 — Loop works in one app but not another (the two-policy-tool trap)</summary>

**When to use:** Loop components create/open fine in Teams but not Outlook (or vice versa), despite one of the two policy tools looking "correctly" configured.

1. Identify exactly which surface is failing, then check the tool that **actually governs that surface** — see the Dependency Cascade above. Teams checks SharePoint org properties only; every other app checks Cloud Policy only. Configuring one and assuming it covers both is the single most common misconfiguration in this topic.
2. For Teams:
   ```powershell
   Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
   Set-SPOTenant -IsLoopEnabled $true
   Set-SPOTenant -IsCollabMeetingNotesFluidEnabled $true
   ```
   If the tenant has multiple regions (multiple organization URLs), repeat against **every** region — a partial run produces inconsistent behavior across the org, not a clean failure.
3. For Outlook/OneNote/Whiteboard/Teams New Calendar: sign in to `https://config.office.com` → Customization → Policy Management, set the relevant policy to Enabled, and confirm scope (All users, or a specific Microsoft 365/security/dynamic group) and priority if multiple configurations target the same users.
4. Allow propagation time: up to 90 minutes if a policy configuration already existed for that scope, up to 24 hours if this is the first policy configuration ever applied to it.

**Rollback:** Set the relevant policy back to Disabled (Cloud Policy) or run `Set-SPOTenant -IsLoopEnabled $false` / `-IsCollabMeetingNotesFluidEnabled $false` (Teams) if changed in error.

</details>

<details><summary>Fix 2 — Loop won't create/view in Outlook on the web or new Outlook despite Cloud Policy allowing it</summary>

**When to use:** Cloud Policy confirms Loop should be available, but users report no Loop option in OWA or new Outlook for Windows specifically.

```powershell
Get-OwaMailboxPolicy -Identity <policyName> |
    Select-Object DirectFileAccessOnPrivateComputersEnabled, WacViewingOnPrivateComputersEnabled, `
                  DirectFileAccessOnPublicComputersEnabled, WacViewingOnPublicComputersEnabled

Set-OwaMailboxPolicy -Identity <policyName> `
    -DirectFileAccessOnPrivateComputersEnabled $true -WacViewingOnPrivateComputersEnabled $true `
    -DirectFileAccessOnPublicComputersEnabled $true -WacViewingOnPublicComputersEnabled $true
```

1. Set the **Private**-session pair (`DirectFileAccessOnPrivateComputersEnabled`, `WacViewingOnPrivateComputersEnabled`) to `$true` at minimum — this is the pair that matters for the large majority of normal, non-kiosk sign-ins.
2. Set the **Public**-session pair as well only if the organization genuinely needs Loop available on "This is a public or shared computer" sessions — public-session settings intentionally default more restrictive for good reason.
3. Also check the tenant's Conditional Access policies against this mailbox — sessions meeting Conditional Access criteria have documented, by-design limited functionality that can independently block Loop regardless of the OWA policy state.

**Rollback:** Revert the four booleans to their prior values if this was a deliberate security posture, not an oversight.

</details>

<details><summary>Fix 3 — Can't fully disable Loop; the shared personal container keeps appearing</summary>

**When to use:** Both Loop-specific Cloud Policy settings are Disabled, but users can still create Copilot Pages/Notebooks (and the underlying container still gets created).

1. Understand the mechanism first: the single user-owned SharePoint Embedded container behind **My workspace**, **Copilot Pages**, and **Copilot Notebooks** is created the moment **either** of two independent policies allows it for that user — `Create Loop workspaces in Loop` **or** `Create and view Copilot Pages and Copilot Notebooks`.
2. To genuinely prevent the container from being created at all, disable **both** policies for the same user/group scope — disabling only the Loop-named one leaves the Copilot Pages/Notebooks path fully able to create it.
3. Confirm via PowerShell after both are disabled and propagation time has passed:
   ```powershell
   Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' |
       Where-Object { $_.OwnersCount -gt 0 -and $_.PrincipalOwner -eq '<UPN>' }
   ```
   No result confirms no container exists yet for that user.

**Rollback:** Re-enable either policy as needed; this does not retroactively delete already-created containers.

</details>

<details><summary>Fix 4 — eDiscovery custodian search finds nothing for a user's My workspace content</summary>

**When to use:** A custodian was added to a Purview eDiscovery case, but their Loop My workspace content doesn't appear as a selectable data source alongside their mailbox and OneDrive.

1. Check whether this tenant has the custodian-picker integration for the user-owned container (rolling out and expected **early August 2026** — verify current availability against the live Purview eDiscovery UI, since this was still rolling out very recently relative to this runbook's research date).
2. If not yet available, retrieve the container URL manually:
   - SharePoint admin center → Containers → Active containers → filter **Application name: Loop**, **Ownership type: User** → locate by Principal owner → General tab → copy the container URL (this is a Purview-targeting identifier, **not** a shareable/clickable link — use the separate Container Redirect URL for that).
3. Add the copied URL as a manual data source in the eDiscovery case alongside the user's mailbox and OneDrive.
4. For **audit log** searches instead of eDiscovery case sources, search Purview audit logs for keywords `page`, `loop`, `loot` (templates), or `fluid` (deprecated extension) — or filter directly by container URL `/*` plus the container's GUID in Keyword Search for a specific workspace's events. Remember Copilot Pages/Notebooks audit events share the same Loop application identity — there is no separate way to filter them out.

**Rollback:** N/A — investigative workflow, no configuration change.

</details>

<details><summary>Fix 5 — Can't apply or see a retention label on a Loop component</summary>

**When to use:** A user or admin expects a retention-label control when right-clicking a Loop component embedded in Outlook/Teams/OneNote, and it isn't there.

1. Confirm this is expected, not broken: Loop components have **limited support for manually applying retention labels**, and the label control is **not available from the embedded component itself** — it only appears when the user navigates to the underlying Loop file from within the Loop app.
2. Direct the user to open the specific Loop file inside the Loop app (not the embedded view in Outlook/Teams) to view or apply a published retention label there.
3. If the goal is retaining/deleting Loop content on a schedule rather than per-item labeling, use a **retention policy** (not a label) scoped to "All SharePoint Sites," or scoped to the specific workspace's container URL for a narrower target — retention policies work normally for Loop content and don't have this limitation.
4. If the content needs to be marked as a record or regulatory record, note this is **not currently possible** to apply manually on Loop content either inside the component or the Loop app — this is a genuine product gap to set expectations around, not a configuration step being missed.

**Rollback:** N/A — informational/workflow correction, no destructive action.

</details>

<details><summary>Fix 6 — A shared Loop workspace was deleted and needs restoring</summary>

**When to use:** Users report a shared Loop workspace has disappeared entirely (not just individual pages/components, which have their own end-user recycle bin).

1. Confirm first: **Loop workspaces have no end-user recycle bin** — this is expected for the workspace container itself, even though individual components and pages inside a workspace do have one.
2. Locate the container in SharePoint admin center → Containers → **Deleted containers**, filtered to **Application name: Loop**.
3. If found and still within the recycle-bin retention window, restore it via the admin center's container restore action.
4. **Set expectations correctly:** restoring the container does **not** automatically make the workspace reappear in affected users' Loop app navigation. Each user must revisit a previously saved page/workspace link (or receive a fresh Container Redirect URL from admin) to see it again.
5. If past the recycle-bin window, the content is unrecoverable — communicate this plainly rather than continuing to search.

**Rollback:** N/A — this fix path is itself a recovery action.

</details>

<details><summary>Fix 7 — Loop workspaces missing entirely in a government/sovereign/air-gapped tenant</summary>

**When to use:** A GCC, GCC High, DoD, sovereign-cloud (Bleu/Delos), or air-gapped tenant reports the Loop app or workspace-creation options are completely absent.

1. Confirm the tenant's cloud environment before spending further troubleshooting time.
2. Set the correct expectation: **Loop workspaces are commercial-cloud only** — not available in GCC, GCC High, DoD, Bleu, Delos, or air-gapped environments at all, and no admin policy can enable them where the underlying platform doesn't support it.
3. Loop **components in Teams** (chat, channels, chat/meeting notes) have broader — but still uneven — availability: available in GCC and Bleu, **not** available in GCC High, DoD, Delos, or air-gapped. Loop components in Outlook, Teams New Calendar, OneNote, and Whiteboard follow yet another, narrower matrix (commercial and Bleu only for most of these). Confirm the specific integration against the current cloud-availability matrix before promising or denying a capability.
4. This is a platform boundary, not a support case — do not escalate to Microsoft Support expecting a fix; only escalate to confirm current matrix accuracy if documentation and observed behavior disagree.

**Rollback:** N/A — platform limitation, not a misconfiguration.

</details>

<details><summary>Fix 8 — Departing employee's Loop/Copilot content needs preserving</summary>

**When to use:** An employee is leaving (or has left) and their My workspace/Copilot Pages/Copilot Notebooks content needs to be preserved before automatic deletion.

1. **Act before offboarding completes, or immediately after** — unlike OneDrive, there is **no automatic manager delegation or notification** for a user-owned Loop/Copilot container. If nobody is manually granted access before the retention period ends, the content is permanently and irrecoverably deleted.
2. Locate the container: SharePoint admin center → Containers → Active containers → filter **Application name: Loop**, **Ownership type: User** → find by Principal owner (the container may display as "My workspace" or "Pages" depending on which app the user visited first — search by owner, not by name).
3. Add a custodian (typically the departing user's manager) as a container **Owner** via the Membership tab — this grants access but does **not** change the principal owner or reset the deletion schedule.
4. Copy the **Container Redirect URL** (General tab) and send it to the custodian with clear instructions: they must actively **copy** content they want to keep into a new Loop workspace or Copilot Notebook before the retention window ends — granting access alone does not preserve anything. Copilot Notebook chat conversations specifically **cannot be preserved at all**; only Pages, Overview content, Custom Instructions, and References survive, and each requires a different manual preservation step.
5. Alternative for full preservation without manual content-copying: use SharePoint Embedded **principal owner transfer** in PowerShell (`Set-SPOContainer` with the `PrincipalOwnerTransfer` capability) to permanently reassign the entire container to a new owner — this resets the deletion schedule to the new owner's account and is the only option OneDrive itself doesn't offer.
6. For larger organizations, automate step 3 with PowerShell as part of the standard offboarding script, paired with a Power Automate notification — don't rely on a manual checklist item alone at scale.

**Rollback:** N/A — preservation workflow; removing an added custodian owner afterward is safe and doesn't affect the principal owner or deletion schedule.

</details>

<details><summary>Fix 9 — Ownerless shared Loop workspace nobody can manage</summary>

**When to use:** All owners of a tenant-owned shared Loop workspace have left the organization, and remaining members can't delete or manage it.

```powershell
Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' |
    Where-Object { $_.OwnersCount -eq 0 } | Format-Table
```

1. Confirm the workspace is genuinely ownerless via the command above, or in SharePoint admin center → Containers → Active containers, filtered to Application name: Loop.
2. Add a new Owner via the container's Membership tab (or PowerShell) — members alone cannot self-service this; it requires SharePoint Embedded administrator access.
3. Only assign the **Owner** or **Editor** (labeled "Manager" in the admin center) roles — the **Writer** and **Reader** roles exist in the underlying platform but are **not used by the Loop app at all** and should never be assigned to Loop container members.
4. Note the pre-April-2025 exception: tenant-owned workspaces created **before** April 2025 use a legacy roster model still controlled from inside the Loop app itself, not fully manageable from the admin center yet — confirm workspace creation date before assuming the admin-center path will work.

**Rollback:** Remove the newly added owner if assigned in error — this does not affect other members' access.

</details>

---
## Escalation Evidence

```
=== Microsoft Loop Escalation ===
Ticket #:
Client / Tenant:
Cloud environment (Commercial / GCC / GCC High / DoD / Bleu / Delos / air-gapped):
Affected surface (Outlook web / new Outlook / classic Outlook / Teams / OneNote / Whiteboard / Loop app):
Get-SPOTenant IsLoopEnabled / IsCollabMeetingNotesFluidEnabled:
Relevant Cloud Policy setting + state (checked at config.office.com):
OWA mailbox policy booleans (if Outlook-related):
Affected container found in Active/Deleted containers (Y/N, URL):
Container ownership type (User / Tenant / Group):
Container creation date (pre/post April 2025, if tenant-owned):
Custodian/owner already assigned (Y/N):
When did the issue start:
What changed (client-reported):
Escalation target:            [ ] Microsoft Support   [ ] Internal L3   [ ] SharePoint Embedded administrator
```

---
## 🎓 Learning Pointers

- **Loop has two independent, non-overlapping admin policy tools, not one.** Cloud Policy controls everything except Teams; SharePoint PowerShell (`Set-SPOTenant`) controls Teams only. Configuring one and assuming full coverage is the root cause of most "Loop is half-broken" tickets in this topic. See [Manage Loop in your organization](https://learn.microsoft.com/en-us/microsoft-365/loop/loop-admin-configuration).

- **The personal My workspace container is shared with Copilot Pages and Copilot Notebooks, and is always identified as application "Loop" everywhere — admin tools, PowerShell, and audit logs.** Disabling "the Loop policy" alone does not stop this container from being created if the Copilot Pages/Notebooks policy is still enabled, and audit searches can't distinguish which feature actually wrote a given event. See [Overview of Loop storage](https://learn.microsoft.com/en-us/microsoft-365/loop/loop-storage).

- **eDiscovery/compliance support for Loop is still actively maturing** — the custodian-picker integration for the personal container only began rolling out in early August 2026, and record/regulatory-record labeling of Loop content isn't available at all yet. Confirm current-state capability against live Microsoft Learn documentation before promising a client a specific compliance workflow. See [Summary of governance, lifecycle, and compliance capabilities for Loop](https://learn.microsoft.com/en-us/microsoft-365/loop/loop-compliance-summary).

- **User offboarding for Loop/Copilot content is a manual step your standard OneDrive-based offboarding checklist will not catch automatically.** No manager delegation, no automatic notification — build this into the offboarding runbook explicitly, ideally via PowerShell + Power Automate at any scale beyond a handful of departures per month. See [Grant access to containers — Options when a user leaves](https://learn.microsoft.com/en-us/microsoft-365/loop/grant-access#options-when-a-user-leaves-the-organization).

- **Loop workspace availability by cloud environment is genuinely uneven, not a simple "government cloud = unavailable" rule.** Workspaces are commercial-only across the board, but individual Loop component integrations (Teams, Outlook, OneNote, Whiteboard) each have their own, different availability matrix across GCC/GCC High/DoD/Bleu/Delos/air-gapped — check the specific integration, not just the product name, before setting client expectations. See [Requirements for Loop — Cloud environment availability](https://learn.microsoft.com/en-us/microsoft-365/loop/loop-requirements#cloud-environment-availability).

- **There is currently no supported way to move a SharePoint Embedded container (and therefore Loop content) between tenants.** Flag this explicitly during any tenant-to-tenant migration or M&A engagement scoping conversation — it is a hard platform gap today, not a missing PowerShell flag to search harder for. See [Manage SharePoint Embedded containers — Migrations](https://learn.microsoft.com/en-us/microsoft-365/loop/spe-management#migrations).
