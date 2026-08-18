# Microsoft Loop — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- The distinction between **Loop components** (`.loop` files embedded in Outlook, Teams, OneNote, Whiteboard) and **Loop workspaces** (the standalone Loop app), and why they have different licensing, storage, and policy requirements
- The **two independent admin policy tools** (Cloud Policy and SharePoint PowerShell/`Set-SPOTenant`) and the exact app-to-tool mapping, including the narrower Outlook-specific sub-policy
- The **storage architecture**: which creation path lands in SharePoint Embedded, a SharePoint site, or OneDrive, and the shared user-owned container model behind My workspace/Copilot Pages/Copilot Notebooks
- SharePoint Embedded **container management** (listing, ownerless-workspace detection, role model, container URL vs. Container Redirect URL) as it applies to Loop
- **Governance and compliance capabilities**: eDiscovery, Legal Hold, retention policies/labels, sensitivity labels, DLP, audit logging, and their current maturity/limitations for Loop content specifically
- **User departure / offboarding** mechanics for the personal container, contrasted explicitly with standard OneDrive offboarding
- **Cloud environment availability** across commercial, US government, sovereign, and air-gapped clouds

**Out of scope (see cross-references):**
- Copilot Pages and Copilot Notebooks as end-user features in their own right — this runbook covers them only insofar as they share infrastructure (the personal SharePoint Embedded container, the "Loop" application identity in audit logs) with Loop; see `M365/Copilot/Copilot-A/B.md` for Copilot licensing/tenant-enablement generally
- General SharePoint Online/OneDrive administration (quotas, sharing policies, site provisioning) — see `M365/SharePoint-OneDrive/` for anything not specific to Loop's use of that infrastructure
- General Microsoft Purview eDiscovery, retention, DLP, and sensitivity-label configuration mechanics — see `Security/Purview/` for the underlying feature administration; this runbook covers only Loop-specific application and limitations of those features
- Teams meeting-notes end-user experience beyond what's needed to explain the `IsCollabMeetingNotesFluidEnabled`/Cloud-Policy split
- Word for the web — Loop component rendering there was retired September 1, 2025 (existing components now display as read-only placeholder links); this runbook does not cover remediation for that retirement since there is none, only awareness

**Assumes:**
- SharePoint Online Management Shell (`Microsoft.Online.SharePoint.PowerShell`) connected via `Connect-SPOService` for all `Set-SPOTenant`/`Get-SPOContainer`/`Get-SPOApplication` operations
- SharePoint Embedded administrator role (or Global Administrator) for container management in the SharePoint admin center
- Exchange Online PowerShell for `Get-OwaMailboxPolicy`/`Set-OwaMailboxPolicy` operations
- Cloud Policy configuration is performed manually via `https://config.office.com` — **there is no PowerShell cmdlet to read or set Cloud Policy state**, a genuine and easy-to-forget asymmetry against the SharePoint-side settings, which are fully scriptable

---
## How It Works

### Two products sharing one brand — components vs. workspaces

"Microsoft Loop" is architecturally two related but distinct things:

- **Loop components** — small, real-time collaborative blocks (tables, task lists, paragraphs) embedded directly inside another app's content: an Outlook email, a Teams chat message or meeting note, a OneNote page, a Whiteboard canvas. A component requires only a **OneDrive or SharePoint license** — no special Loop entitlement.
- **Loop workspaces** — the standalone **Loop app**, a full canvas for organizing multiple pages and components into a shared or personal workspace. Workspaces require the **"Loop with workspaces" service plan** specifically, a narrower license than components need.

Both produce `.loop` files (earlier releases produced `.fluid` files, now deprecated) backed by the same real-time collaboration engine (the Fluid Framework, reachable over WebSocket at `*.svc.ms` and `*.office.com`), but **where the content is created determines where it's stored**, and that in turn determines which governance mechanisms apply to it — this storage-location dependency is the single most important architectural fact in this topic and recurs through nearly every section below.

### Two admin policy tools, cleanly split by app — not by feature

Unlike most Microsoft 365 features, which are gated by a single settings surface, Loop creation is controlled by **two entirely independent tools**, and an admin must configure **both** to fully control the product:

| Tool | Governs | Does NOT govern |
|---|---|---|
| **Cloud Policy** (`config.office.com` → Customization → Policy Management) | Loop workspaces (Loop app, including Teams **channel** workspaces specifically — a workspace type, not a component); Loop components in Outlook, OneNote, Whiteboard, and **Teams New Calendar** | Loop components in Teams **chat/channel** (non-calendar) surfaces |
| **SharePoint PowerShell** (`Set-SPOTenant`, tenant-wide only, no per-user scoping) | Loop components in Teams chat and channels (`IsLoopEnabled`); Collaborative meeting notes in Teams **classic** calendar (`IsCollabMeetingNotesFluidEnabled`) | Everything Cloud Policy governs, including Teams New Calendar meeting notes, which — despite being a Teams surface — check Cloud Policy instead |

Three specific Cloud Policy settings exist, evaluated in a defined order for Outlook:

1. **Create Loop workspaces in Loop** — gates workspace creation in the Loop app, including Teams channel workspaces. Also one of two policies (see below) controlling creation of the shared personal SharePoint Embedded container.
2. **Create and view Loop files in Microsoft apps that support Loop** — the broad switch for Outlook, Teams New Calendar, OneNote, and Whiteboard. Explicitly does **not** apply to Loop workspaces, Teams (non-calendar), Copilot Pages, or Copilot Notebooks.
3. **Create and view Loop files in Outlook** — a narrower, Outlook-specific override. Outlook and Teams New Calendar check setting #2 **first**, then apply setting #3 on top if applicable — the two are evaluated together, not independently.

Cloud Policy scoping uses Microsoft 365, security, or dynamic groups, with explicit priority ordering when multiple configurations target overlapping users (lower priority number evaluated first — the classic "enable for a subset by using two groups with different priorities" pattern applies here the same as any other Cloud Policy setting). Propagation after a change: **up to 90 minutes** if a policy configuration already existed for that scope, **up to 24 hours** if this is the very first policy configuration ever applied to it — a meaningfully longer worst case than most tenant-setting changes admins are used to.

A fourth, independent gate sits underneath both tools specifically for web-based Outlook clients: **OWA mailbox policy**. `Get/Set-OwaMailboxPolicy` exposes four relevant booleans — `DirectFileAccessOnPrivateComputersEnabled`, `WacViewingOnPrivateComputersEnabled`, and their `...OnPublicComputers...` counterparts — split by whether the user's session is flagged Private or Public. All four relevant to the session type must be `True` for Loop to function in Outlook on the web or new Outlook for Windows, **regardless of Cloud Policy state**. Conditional Access policies matching a session add a further, by-design restriction independent of both.

### Storage: where content lands depends entirely on where it was created

| Created in... | Stored in... | Lifetime managed by |
|---|---|---|
| Loop app, any workspace (My workspace or shared) | SharePoint Embedded container | User account (My workspace) / workspace owners or Microsoft 365 Group (shared) |
| Teams channel workspace | SharePoint Embedded container (shared) | Microsoft 365 Group |
| Teams chat notes | SharePoint Embedded container | Microsoft Teams Chat |
| Teams channel or channel meeting | SharePoint site (channel folder or `Meetings` folder) | Microsoft 365 Group |
| Teams private chat or meeting | User's OneDrive (`Microsoft Teams Chat files` or `Meetings` folder) | User account |
| Outlook email | User's OneDrive (`Attachments` folder) | User account |
| OneNote for Windows/web | User's OneDrive (`OneNote Loop files` folder) | User account |
| Whiteboard | User's OneDrive (`Whiteboard\Components` folder) | User account |

All Loop storage, regardless of location, counts against the organization's **SharePoint storage quota** — there is no separate Loop quota and no admin control to set a per-container storage limit. SharePoint Embedded containers themselves have a hard **25 TB maximum size** that cannot be increased or decreased.

**The shared personal container — the single most important storage detail in this topic:** the SharePoint Embedded container backing **My workspace** is the *exact same physical container* used by **Copilot Pages** and **Copilot Notebooks** for a given user — not three containers, one. This container is created the first time a user needs any of the three experiences, and creation succeeds if **either** of two independent policies allows it: `Create Loop workspaces in Loop` **or** `Create and view Copilot Pages and Copilot Notebooks`. To prevent the container from ever being created, both must be disabled for the same user — disabling only one leaves the other feature able to create it anyway. In every admin tool, PowerShell output, and Purview audit record, this container is identified solely by the **Loop application IDs** (Web: `a187e399-0c36-4b98-8f04-1edc167a0996`; Mobile: `0922ef46-e1b9-4f7e-9134-9ad00547eb41`) — there is no separate Copilot Pages or Copilot Notebooks identity to filter on anywhere. The container's display name itself varies by which app the user visited first ("Pages" if Copilot app first, "My workspace" if Loop app first, localized to the user's language) — searching by Principal owner, not by name, is the reliable lookup method.

### Container ownership types and the role model

SharePoint Embedded containers backing Loop come in three ownership types, each with different lifecycle rules:

- **User-owned** — exactly one per user, holding My workspace + Copilot Pages + Copilot Notebooks content together. Lifecycle tied to the principal owner's account.
- **Tenant-owned** — shared workspaces created ad hoc by any user, using a **roster permissions model**. If all owners leave, the workspace becomes ownerless but is **not** automatically deleted — it sits inert until an admin assigns a new owner.
- **Group-owned** — shared workspaces tied to a Microsoft 365 Group (e.g., Teams channel workspaces), whose lifecycle is managed identically to a SharePoint Team site's group-lifecycle mechanics.

Role names differ between the SharePoint admin center and the Loop app itself, and **only two of the four available admin-center roles are actually meaningful to Loop**:

| SharePoint admin center role | Loop app role | Notes |
|---|---|---|
| Owner | Owner | Full control including membership management |
| Manager | Editor | Can edit content, cannot manage membership |
| Writer | *(unused)* | Exists in the underlying SharePoint Embedded platform; the Loop app does not use it — never assign |
| Reader | *(unused)* | Same — never assign |

**Legacy roster exception:** tenant-owned workspaces created **before April 2025** still use the original in-app roster model for membership management rather than the SharePoint admin center — admin-center membership changes only take effect for workspaces created on or after that date, until the legacy roster is fully retired.

Two distinct URLs exist for a container and are easy to confuse: the **container URL** (used only to target the container within Purview for compliance features — grants no access and isn't a clickable link) and the **Container Redirect URL** (a genuine clickable link that opens the container in the Loop app for any user who already has access). Sending the wrong one to an end user produces a confusing non-functional link.

### Governance and compliance — a maturing, unevenly-covered surface

Loop content, once landed in OneDrive, a SharePoint site, or a SharePoint Embedded container, is governed by the same Purview mechanisms as any other SharePoint/OneDrive content, targeted almost always via the **"All SharePoint Sites"** scope (which implicitly includes every SharePoint Embedded container of every ownership type) or, for narrower targeting, the specific container URL retrieved from the admin center.

Current capability snapshot (accurate as of this runbook's research date, verified against Microsoft Learn pages updated as recently as five weeks prior):

| Capability | Status | Detail |
|---|---|---|
| Admin policies | ✅ Available | Cloud Policy + SharePoint PowerShell (see above) |
| GDPR / EU Data Boundary | ✅ Supported | Via Purview DSR tooling and eDiscovery workflows |
| Conditional Access | ✅ Supported | |
| Information Barriers | ◐ Partial | OneDrive/SharePoint-stored Loop content only — **not supported for SharePoint Embedded** (Loop workspaces, My workspace). If IB is a hard requirement, the only lever is restricting workspace creation entirely via admin policy |
| Customer Lockbox | ✅ Supported | |
| eDiscovery | ✅ Supported | Search/collection always; review and HTML export require an eDiscovery **Premium** license |
| Legal Hold | ✅ Supported | Content preserved in the Preservation Hold Library; custodian-picker integration for the personal container began rolling out **early August 2026** — check current tenant state rather than assuming either the old manual-URL workflow or the new picker is what a given tenant sees |
| Retention policies | ✅ Supported | Full support, targeted at "All SharePoint Sites" or per-container |
| Retention labels | ◐ Limited | Manual application only from **inside the Loop app itself** on the underlying file — not available from the embedded component view. Record/regulatory-record labeling is **not available at all** for Loop content as of this writing |
| Sensitivity labels | ✅ Supported | Pages and components individually; workspaces (containers) at the container level via SharePoint admin center/PowerShell |
| DLP | ✅ Supported | Full rule enforcement with end-user policy tips |
| Recycle bin | ◐ Partial | Components and pages have one; **Loop workspaces themselves do not** — deletion requires admin-side container restore |

A version-history detail worth flagging: SharePoint Embedded containers default to retaining **50 major versions per file**, configurable per application via `Set-SPOApplication -ItemMajorVersionLimit` — a different default and configuration surface than standard SharePoint/OneDrive versioning settings.

Audit log searching has one persistent limitation stemming directly from the shared-container architecture: because Copilot Pages, Copilot Notebooks, and Loop My workspace share one application identity, **audit events for all three appear under the same Loop application IDs** — there is no way to filter Copilot Pages/Notebooks events out of a Loop-scoped audit search, or vice versa, without additionally filtering by the specific container's GUID.

### User departure — deliberately similar to, but meaningfully different from, OneDrive

The personal container's lifecycle after a user leaves follows the **same OneDrive deletion lifecycle** (active retention period → recycle bin period → permanent deletion, governed by the same tenant retention-period setting that applies to OneDrive). The one genuine difference is the handoff: OneDrive **automatically** delegates access to the departed user's manager and sends a notification email. The Loop/Copilot personal container has **no automatic delegation or notification whatsoever** — an IT admin must manually add a custodian as a container Owner and manually send them the Container Redirect URL, or the content is silently and permanently lost when the retention window closes with nobody granted access. SharePoint Embedded additionally offers a capability OneDrive does not: **principal owner transfer**, permanently reassigning the entire container (and resetting its deletion schedule) to a new owner rather than merely granting preservation access.

### Cloud environment availability — uneven, not a single on/off switch

Loop availability varies meaningfully by both **environment** and **specific app integration** — treating "Loop" as a single yes/no capability per cloud environment produces wrong answers:

| Integration | Commercial | GCC/GCC High/DoD | Bleu | Delos | Air-gapped |
|---|---|---|---|---|---|
| Loop workspaces | ✅ | ❌ | ❌ | ❌ | ❌ |
| Loop components — Teams (chat, channels, notes) | ✅ | ✅ | ✅ | ❌ | ❌ |
| Loop components — Outlook, Teams New Calendar | ✅ | ❌ | ✅ | ❌ | ❌ |
| Loop components — OneNote | ✅ | ❌ | ❌ | ❌ | ❌ |
| Loop components — Whiteboard | ✅ | ❌ | ✅ | ❌ | ❌ |

Where an experience is marked unavailable, **no admin policy can enable it** — this is a platform boundary, not a configuration gap. Loop workspaces are commercial-cloud-only across the board; individual component integrations are the more nuanced, and more commonly mis-assumed, part of this matrix.

---
## Dependency Stack

```
Microsoft 365 tenant
    │
    ▼
Licensing layer
    ├── Loop components → OneDrive or SharePoint license (broad, standard)
    └── Loop workspaces  → "Loop with workspaces" service plan (narrower, specific)
    │
    ▼
Network layer
    ├── Standard Office 365 URL/IP allow-listing
    └── WebSocket traffic to *.svc.ms and *.office.com (real-time collaboration engine)
    │
    ▼
TWO independent admin policy tools (BOTH must allow creation for full functionality)
    ├── Cloud Policy (config.office.com, NO PowerShell read/write) — governs workspaces,
    │   Outlook, Teams New Calendar, OneNote, Whiteboard
    └── SharePoint PowerShell (Set-SPOTenant, tenant-wide only) — governs Teams chat/channel
        components (IsLoopEnabled) and Teams classic-calendar meeting notes
        (IsCollabMeetingNotesFluidEnabled)
    │
    ▼
Additional web-Outlook-specific gate (Exchange Online, independent of both above)
    OWA mailbox policy — 4 booleans split by Private/Public session type
    │
    ▼
Storage layer (location determined by creation surface, not configurable independently)
    ├── SharePoint Embedded containers — Loop app (any workspace), Teams chat notes
    │   └── Personal "My workspace" container SHARED with Copilot Pages/Copilot Notebooks,
    │       always identified as application "Loop" (Web ID: a187e399-..., Mobile: 0922ef46-...)
    ├── SharePoint sites — Teams channel content, channel meetings
    └── User OneDrive — Teams private chat/meetings, Outlook, OneNote, Whiteboard
    │
    ▼
Container ownership & role model (SharePoint Embedded specifically)
    ├── User-owned (1 per user) / Tenant-owned (roster, ownerless-if-abandoned) /
    │   Group-owned (M365 Group lifecycle)
    └── Roles: Owner / Editor(=Manager) meaningful; Writer/Reader unused by Loop app
        (legacy roster still governs tenant-owned workspaces created before April 2025)
    │
    ▼
Governance layer (Microsoft Purview) — targets "All SharePoint Sites" or specific container URL
    ├── eDiscovery (Premium license needed for review/HTML export)
    ├── Legal Hold (custodian-picker for personal container: rolling out from Aug 2026)
    ├── Retention policies (full support) / Retention labels (limited, in-app only)
    ├── Sensitivity labels (pages/components + per-container)
    ├── DLP (full support)
    └── Information Barriers (OneDrive/SharePoint only — NOT SharePoint Embedded)
    │
    ▼
Offboarding (manual handoff — no automatic manager delegation, unlike OneDrive)
    │
    ▼
Cloud environment availability gate (uneven by integration — see matrix above)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Loop works in Teams but not Outlook/OneNote/Whiteboard | Only SharePoint PowerShell configured, Cloud Policy not configured (or vice versa) | `Get-SPOTenant` + manual check at config.office.com |
| Loop won't create in web Outlook/new Outlook despite Cloud Policy allowing it | OWA mailbox policy booleans false | `Get-OwaMailboxPolicy` |
| Disabling "the Loop policy" doesn't stop the personal container from being created | Only one of two container-creating policies disabled (Loop workspaces / Copilot Pages & Notebooks) | Check both Cloud Policy settings for the user |
| Loop components render as static read-only links in Word for the web | Expected — Word web rendering retired September 1, 2025 | N/A, not fixable |
| eDiscovery custodian shows no Loop content | Container not yet a selectable data source, or not manually added | SharePoint admin center → Containers → Active containers |
| Retention label control missing on a Loop component | Expected — must be applied from inside the Loop app on the underlying file | Open file directly in Loop app |
| Loop content marked as a record can't be locked/unlocked | Expected — record locking not yet available for Loop content | N/A, product gap |
| Shared workspace vanished entirely | No end-user recycle bin for workspaces (only components/pages have one) | SharePoint admin center → Containers → Deleted containers |
| Restored workspace still missing from user's Loop app | Restoring the container doesn't auto-refresh in-app navigation | User must revisit a saved page link or Container Redirect URL |
| Government/sovereign/air-gapped tenant missing the Loop app | Loop workspaces are commercial-cloud-only; some components have narrower availability too | Confirm cloud environment + specific integration against the matrix |
| Departed user's content permanently gone with no warning | No automatic manager delegation for the personal container (unlike OneDrive) | Confirm custodian was added before the retention window closed |
| Nobody can manage a shared workspace | All owners left — ownerless tenant-owned workspace | `Get-SPOContainer ... Where OwnersCount -eq 0` |
| Admin-center membership changes don't apply to an older shared workspace | Workspace predates April 2025 — still on legacy in-app roster model | Check container creation date |
| Information Barriers not enforced on Loop workspace content | SharePoint Embedded containers are outside IB scope entirely | Confirm content location — OneDrive/SharePoint-stored Loop content IS covered, Loop workspaces are not |
| Audit search for "Loop" also returns unrelated Copilot Pages/Notebooks events | Shared application identity — no separate filter exists | Add container GUID to Keyword Search for a specific workspace |
| Trying to move Loop content between tenants during an M&A/migration project | No supported cross-tenant container transfer exists | Confirm with client this is a hard platform gap, not a missing flag |

---
## Validation Steps

1. **Confirm SharePoint-side (Teams) settings.**
   ```powershell
   Get-SPOTenant | Select-Object IsLoopEnabled, IsCollabMeetingNotesFluidEnabled
   ```
   Expected: both `True` if Teams-side Loop should be functional tenant-wide (this setting cannot be scoped per-user).

2. **Confirm Cloud Policy state manually** (no PowerShell equivalent exists).
   `https://config.office.com` → Customization → Policy Management → check all three relevant policy names for the correct scope, state, and priority.

3. **Confirm the OWA mailbox policy gate if the complaint touches web Outlook or new Outlook.**
   ```powershell
   Get-OwaMailboxPolicy -Identity <policyName> | Select-Object Direct*Enabled, Wac*Enabled
   ```
   Expected: the four booleans relevant to the affected session type (Private/Public) are `True`.

4. **Confirm container existence and ownership for a specific user or workspace.**
   ```powershell
   Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' |
       Where-Object { $_.PrincipalOwner -eq '<UPN>' -or $_.DisplayName -like '*<workspace>*' }
   ```
   Expected: exactly one user-owned container per user; shared workspaces resolvable by name or owner.

5. **Confirm governance targeting for compliance requests.**
   Retrieve the container URL from SharePoint admin center → Containers → Active/Deleted containers → General tab, and confirm whether it's being targeted correctly in the relevant Purview policy or eDiscovery case (via "All SharePoint Sites" scope or the specific container URL).

6. **Confirm cloud environment before troubleshooting any availability complaint.**
   Identify commercial vs. GCC/GCC High/DoD vs. Bleu/Delos vs. air-gapped, then check the specific integration (not just "Loop" broadly) against the availability matrix.

---
## Troubleshooting Steps (by phase)

### Phase 1: Scope the Complaint
1. Identify exactly which surface is affected (Outlook web/new Outlook/classic, Teams, OneNote, Whiteboard, Loop app) — this determines which policy tool and which fix path apply.
2. Distinguish "Loop component" issues from "Loop workspace" issues — different licensing, different storage, sometimes different policy tool.

### Phase 2: Policy Layer Investigation
1. Check SharePoint-side settings via `Get-SPOTenant` if Teams is involved.
2. Check Cloud Policy manually at config.office.com if any non-Teams surface is involved.
3. Check OWA mailbox policy if web Outlook/new Outlook specifically is involved.
4. Confirm propagation timing (90 min vs. 24h) before treating a recent change as ineffective.

### Phase 3: Storage/Container Investigation
1. Determine expected storage location based on creation surface (see storage table).
2. Locate the specific container via `Get-SPOContainer` or SharePoint admin center if the issue involves a shared workspace or the personal container.
3. Confirm ownership type (User/Tenant/Group) and, for tenant-owned workspaces, creation date relative to April 2025.

### Phase 4: Governance/Compliance Investigation
1. Confirm which Purview capability is in question and cross-reference against the current capability table — several limitations (workspace recycle bin, retention-label application point, Information Barriers on SharePoint Embedded, record locking) are product gaps, not misconfigurations.
2. Retrieve the container URL if targeted compliance action is needed.

### Phase 5: Offboarding/Lifecycle Investigation
1. For departed-user content concerns, confirm immediately whether a custodian was already added — this is time-sensitive given the lack of automatic delegation.
2. For ownerless shared workspaces, confirm via `OwnersCount -eq 0` before assuming a permissions bug.

### Phase 6: Escalation
1. Package the Evidence Pack output below.
2. Escalate genuine platform gaps (e.g., cross-tenant migration, record locking, Information Barriers on SharePoint Embedded) as known limitations, not bugs — set expectations rather than filing a support ticket expecting a fix timeline.
3. Escalate genuine anomalies (a correctly-configured policy tool not taking effect well past propagation windows) to Microsoft Support with the Evidence Pack attached.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full tenant-wide Loop enablement (or full lockdown) done correctly</summary>

1. Decide the target state per surface: Loop app workspaces, Outlook, Teams New Calendar, OneNote, Whiteboard (all Cloud Policy), and Teams chat/channel components + classic-calendar meeting notes (SharePoint PowerShell).
2. Configure Cloud Policy first at `https://config.office.com`, scoped to All users or a specific group with explicit priority if overlapping configurations exist.
3. Configure the SharePoint side:
   ```powershell
   Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
   Set-SPOTenant -IsLoopEnabled $true   # or $false
   Set-SPOTenant -IsCollabMeetingNotesFluidEnabled $true   # or $false
   ```
   Repeat against every region if the tenant has multiple organization URLs — these settings are not automatically consistent across regions.
4. If full lockdown of the shared personal container is the goal, explicitly disable **both** `Create Loop workspaces in Loop` and `Create and view Copilot Pages and Copilot Notebooks` for the target scope — confirm neither policy alone is left enabled.
5. If web Outlook/new Outlook is in scope, verify OWA mailbox policy booleans align with the intended state (`Set-OwaMailboxPolicy`).
6. Allow the documented propagation windows (90 min / 24h for Cloud Policy; "short time" for SharePoint properties) before validating with end users.
7. Validate with a test user in the target scope across every affected surface individually — do not assume success in one surface implies success in another.

**Rollback:** Revert each policy tool to its prior state independently; changes are not retroactive to already-created content or containers.

</details>

<details><summary>Playbook 2 — Offboarding a departing user's Loop/Copilot content</summary>

**When to use:** Standard operating procedure for any user departure where Loop/Copilot Pages/Notebooks usage is a possibility (safe default: run this for every departure, since a user-owned container may exist even if usage wasn't obvious).

1. Locate the container: SharePoint admin center → Containers → Active containers → Application name: Loop, Ownership type: User → search by Principal owner (not display name, which varies).
2. Decide preserve-and-copy vs. permanent reassignment:
   - **Preserve (mirrors OneDrive offboarding):** add the manager or a designated custodian as container Owner via the Membership tab, then send them the Container Redirect URL with clear instructions that content must be actively copied to a new workspace/notebook before the retention window ends — access alone does not preserve anything, and Copilot Notebook chat conversations cannot be preserved under any circumstance.
   - **Permanent reassignment (Loop/Copilot-only capability, not available for OneDrive):** use SharePoint Embedded principal owner transfer (`Set-SPOContainer` `PrincipalOwnerTransfer`) to hand the entire container, and its reset deletion schedule, to a new owner outright.
3. At scale, automate the Owner-add step via PowerShell as a standard offboarding script action, paired with a Power Automate notification — do not rely on a manual checklist item as the sole safeguard for organizations with regular departures.
4. Confirm this step is documented in the organization's broader offboarding runbook (see `[Remove a former user]` cross-reference) alongside mailbox and OneDrive handling, since Loop/Copilot content follows a related but not identical process.

**Rollback:** N/A — preservation/reassignment workflow; removing an added custodian Owner later is safe and non-destructive.

</details>

<details><summary>Playbook 3 — Loop-scoped Purview governance setup for a compliance-sensitive client</summary>

**When to use:** A client needs eDiscovery, retention, or DLP coverage that explicitly and verifiably includes Loop content, not just an assumption that "SharePoint policies cover everything."

1. Confirm license posture — eDiscovery **Premium** (typically E5 Compliance) is required for review and HTML export of Loop/Copilot Pages content, not just search/collection.
2. Configure retention **policies** (not labels, given labels' limited manual-application support) scoped to "All SharePoint Sites" for blanket coverage, or to specific container URLs retrieved from the admin center for narrower per-workspace targeting.
3. If per-item labeling is a hard requirement despite the limitation, document the workaround explicitly for end users: labels must be applied from inside the Loop app on the underlying file, not from the embedded component view — this is a training/communication task, not a configuration one.
4. If Information Barriers are a compliance requirement, confirm explicitly with the client that **SharePoint Embedded content (Loop workspaces, My workspace) is not covered** — the only lever available is restricting workspace creation via admin policy for the affected population, since IB itself cannot reach this content.
5. Set up the audit-search runbook in advance: document the Loop application IDs and the container-GUID-filtering technique for isolating a specific workspace's events, and flag to the compliance team that Copilot Pages/Notebooks audit events cannot be separated from Loop's by application identity alone.
6. Revisit the eDiscovery custodian-picker rollout status periodically — it was still rolling out as of this runbook's research date and tenant behavior may change without a corresponding policy change on the client's part.

**Rollback:** N/A — governance configuration; standard Purview policy rollback procedures apply to whatever underlying retention/DLP/label policy was configured.

</details>

<details><summary>Playbook 4 — Pre-engagement scoping for tenant-to-tenant migration or M&A involving Loop content</summary>

**When to use:** An MSP is scoping a tenant-to-tenant migration, divestiture, or acquisition where the source tenant has active Loop usage.

1. Inventory Loop usage first via `Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996'` against the source tenant to establish scale (user-owned container count, shared/tenant-owned workspace count, any group-owned workspaces tied to Teams).
2. Set the client's expectation explicitly and early: **there is no supported method to transfer a SharePoint Embedded container between tenants** — this is a hard platform gap, not a missing PowerShell parameter or a licensing-tier limitation to work around.
3. Scope a manual content-migration path instead, using the same "Copy to workspace" mechanism documented for individual offboarding (Playbook 2) at whatever scale is realistic — this is a per-page, user-driven copy operation, not a bulk admin tool.
4. For content stored in OneDrive/SharePoint (rather than SharePoint Embedded) as a result of its creation surface — Outlook, OneNote, Whiteboard, Teams private chat — standard OneDrive/SharePoint tenant-to-tenant migration tooling applies normally, since that content isn't in a SharePoint Embedded container at all. Distinguish this from workspace/My-workspace/Teams-channel-workspace content, which is.
5. Document the realistic scope and cost of the manual migration path in the engagement estimate rather than discovering the platform gap mid-project.

**Rollback:** N/A — pre-engagement scoping exercise, no configuration change.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Loop-relevant configuration evidence for escalation.
.NOTES     Read-only. Requires SharePoint Online Management Shell (Connect-SPOService) and
           Exchange Online PowerShell connected. Cloud Policy state has no PowerShell equivalent
           and must be captured manually from https://config.office.com and pasted into the
           report. See Scripts/Get-LoopGovernanceAudit.ps1 for the full, documented tenant-wide
           version with CSV export.
#>
$evidence = [System.Collections.Generic.List[string]]::new()

$evidence.Add("=== SharePoint Tenant Settings (Teams-side Loop) ===")
$evidence.Add((Get-SPOTenant | Select-Object IsLoopEnabled, IsCollabMeetingNotesFluidEnabled | Out-String))

$evidence.Add("=== OWA Mailbox Policy (web Outlook / new Outlook gate) ===")
$evidence.Add((Get-OwaMailboxPolicy -Identity $OwaPolicyIdentity |
    Select-Object DirectFileAccessOnPrivateComputersEnabled, WacViewingOnPrivateComputersEnabled, `
                  DirectFileAccessOnPublicComputersEnabled, WacViewingOnPublicComputersEnabled | Out-String))

$evidence.Add("=== User-Owned Containers (My workspace / Copilot Pages / Copilot Notebooks) ===")
$evidence.Add((Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' |
    Where-Object OwnershipType -EQ 'UserOwned' | Select-Object DisplayName, PrincipalOwner, ContainerTypeId | Out-String))

$evidence.Add("=== Ownerless Tenant-Owned Workspaces ===")
$evidence.Add((Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' |
    Where-Object { $_.OwnersCount -eq 0 } | Select-Object DisplayName, OwnershipType | Out-String))

$evidence.Add("=== MANUAL: Cloud Policy state from https://config.office.com ===")
$evidence.Add("Create Loop workspaces in Loop: <fill in>")
$evidence.Add("Create and view Loop files in Microsoft apps that support Loop: <fill in>")
$evidence.Add("Create and view Loop files in Outlook: <fill in>")

$evidence | Out-File -FilePath ".\Loop-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Connect to SharePoint Online Management Shell | `Connect-SPOService -Url https://<tenant>-admin.sharepoint.com` |
| Check Teams-side Loop settings | `Get-SPOTenant \| Select-Object IsLoopEnabled, IsCollabMeetingNotesFluidEnabled` |
| Enable/disable Loop components in Teams | `Set-SPOTenant -IsLoopEnabled $true\|$false` |
| Enable/disable collaborative meeting notes (Teams classic calendar) | `Set-SPOTenant -IsCollabMeetingNotesFluidEnabled $true\|$false` |
| Check OWA mailbox policy booleans | `Get-OwaMailboxPolicy -Identity <policy> \| Select Direct*Enabled, Wac*Enabled` |
| Set OWA mailbox policy for Loop | `Set-OwaMailboxPolicy -Identity <policy> -DirectFileAccessOnPrivateComputersEnabled $true -WacViewingOnPrivateComputersEnabled $true` |
| List all user-owned Loop/Copilot containers | `Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' \| Where OwnershipType -EQ 'UserOwned'` |
| Find ownerless tenant-owned workspaces | `Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' \| Where {$_.OwnersCount -eq 0}` |
| Find a specific user's container | `Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' \| Where PrincipalOwner -eq '<UPN>'` |
| Reassign a container's principal owner | `Set-SPOContainer -Identity <containerId> -PrincipalOwnerTransfer <newOwnerUPN>` |
| Get/set guest app permissions (3rd-party eDiscovery/migration tools) | `Get-SPOApplicationPermission` / `Set-SPOApplicationPermission` |
| Set version history limit for an application | `Set-SPOApplication -Identity <appId> -ItemMajorVersionLimit <n>` |
| Cloud Policy management (no PowerShell) | `https://config.office.com` → Customization → Policy Management |
| Locate a container in the admin UI | SharePoint admin center → Containers → Active/Deleted containers → filter Application name: Loop |
| Retrieve a Container Redirect URL | Container details panel → General tab → Container Redirect URL |
| Retrieve a container URL for Purview targeting | Container details panel → General tab → Container URL (not a shareable link) |
| Search audit logs for Loop-related events | Purview audit log search → Keyword: `page`, `loop`, `loot`, or `fluid`; filter `SourceFileExtension` |

---
## 🎓 Learning Pointers

- **Loop is not one product but two — components (broad license, embedded everywhere) and workspaces (narrower "Loop with workspaces" service plan, standalone app) — and each is governed by its own combination of the two admin policy tools.** Conflating them when scoping a client engagement or troubleshooting a ticket is the most common source of wasted time in this topic. See [Requirements for Loop components and Loop workspaces](https://learn.microsoft.com/en-us/microsoft-365/loop/loop-requirements).

- **Cloud Policy and SharePoint PowerShell split responsibility for Loop cleanly by app, not by feature, and neither is a superset of the other.** Cloud Policy has no PowerShell equivalent at all — treat any automation or Infrastructure-as-Code approach to Loop governance as inherently incomplete unless it also accounts for the manual config.office.com step. See [Manage Loop in your organization](https://learn.microsoft.com/en-us/microsoft-365/loop/loop-admin-configuration).

- **The personal SharePoint Embedded container is genuinely shared infrastructure between Loop My workspace, Copilot Pages, and Copilot Notebooks — one container, one application identity, three features.** This has real consequences for policy design (two policies both gate the same container), audit investigation (can't cleanly separate the three features' events), and offboarding (one preservation workflow covers all three at once, which is efficient once understood but confusing the first time). See [Overview of Loop storage](https://learn.microsoft.com/en-us/microsoft-365/loop/loop-storage).

- **Loop's Purview compliance story is real but still actively maturing — don't assume feature parity with mature SharePoint/OneDrive governance.** Retention labels, record locking, Information Barriers on SharePoint Embedded, and the eDiscovery custodian picker are all either limited or mid-rollout as of this runbook's research date. Re-verify current state against live Microsoft Learn documentation before making compliance commitments to a client, rather than relying on this runbook's snapshot indefinitely. See [Summary of governance, lifecycle, and compliance capabilities for Loop](https://learn.microsoft.com/en-us/microsoft-365/loop/loop-compliance-summary).

- **Offboarding a Loop/Copilot user is NOT automatically covered by standard OneDrive offboarding procedures**, despite following the same underlying retention/recycle-bin timeline. The missing automatic manager delegation is a genuine gap between "the data will eventually be deleted on the standard schedule" and "someone will actually be notified in time to save anything" — bake this explicitly into offboarding runbooks rather than assuming OneDrive coverage extends to it. See [Grant access to containers](https://learn.microsoft.com/en-us/microsoft-365/loop/grant-access).

- **Cross-tenant migration of Loop content is a hard, currently unsolved platform gap** — worth surfacing in any M&A or tenant-consolidation scoping conversation as early as possible, since it affects project cost and timeline in a way that's easy to discover too late if assumed to work like standard SharePoint/OneDrive tenant-to-tenant migration. See [Manage SharePoint Embedded containers — Migrations](https://learn.microsoft.com/en-us/microsoft-365/loop/spe-management#migrations).
