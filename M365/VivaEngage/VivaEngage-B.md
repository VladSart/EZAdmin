# Viva Engage (Yammer) — Hotfix Runbook (Mode B: Ops)
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

Every Viva Engage network in the tenant is now in **Native Mode** — Microsoft retired access to non-native (legacy) networks on **October 13, 2025**, and unmigrated networks were deleted. If a ticket or a Microsoft doc still frames a problem as "check whether the network is in Native Mode," treat that as moot for any tenant reachable today; the real gating layers are the ones below.

```
1. Connect-MgGraph -Scopes "Application.Read.All","Directory.Read.All","User.Read.All"

2. Confirm the Viva Engage (Yammer) service principal is enabled — this gates
   sign-in/tile access for the ENTIRE tenant, not just one user:
   Get-MgServicePrincipal -Filter "AppId eq '00000005-0000-0ff1-ce00-000000000000'" |
     Select-Object DisplayName, AppId, AccountEnabled, Id

3. Confirm the affected user's mailbox/UPN domain is a verified M365 domain
   (home-network access is domain-gated):
   Get-MgDomain | Select-Object Id, IsVerified, IsDefault

4. Confirm the affected user's assigned Viva Engage roles (Engage/Verified/
   Network/Answers/Corporate Communicator — NOT the same list as Entra roles):
   Invoke-MgGraphRequest -Method GET `
     -Uri "https://graph.microsoft.com/v1.0/users/<userId>/employeeExperience/assignedRoles"

5. If the ticket is about community creation being unavailable, confirm the
   tenant's Microsoft 365 Group creation policy (this is what actually gates
   the "Create Community" button — Viva Engage has no separate toggle):
   Get-MgBetaDirectorySetting | Where-Object { $_.DisplayName -eq "Group.Unified" } |
     Select-Object -ExpandProperty Values
```

| Result | Action |
|--------|--------|
| Service principal `AccountEnabled` = `False` | → Fix 1: whole-tenant sign-in break, fix first before anything else |
| Domain not verified / not matching user's UPN | → Fix 3: domain verification gap, not a licensing or role problem |
| User has no Viva Engage roles but should be an admin | → Fix 5: confirm which portal actually grants that specific role |
| `Group.Unified` setting shows `EnableGroupCreation = False` and user isn't in the allowed group | → Fix 2: this is a tenant-wide M365 Groups policy, not a Viva Engage setting |
| Community existed, now returns 404 from Graph | → Fix 4: check whether it was deleted (30-day recovery window) before assuming a bug |
| Automation script fails with `429` mid-batch | → Fix 6: rate limit is 10 requests per user, per app, per 30 seconds |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Entra ID tenant + verified domain(s)
    │
M365 license covering the user (any Business/Enterprise/EDU SKU includes
Viva Engage Core; Viva Suite or standalone add-on required for Premium features)
    │
Viva Engage (Yammer) service principal ENABLED
(AppId 00000005-0000-0ff1-ce00-000000000000 — tenant-wide, all-or-nothing gate)
    │
Native Mode network
(universal since the Oct 13, 2025 legacy-network retirement — no longer a
per-tenant variable to check)
    │
Microsoft 365 Group creation policy
(EnableGroupCreation / GroupCreationAllowedGroupId — gates the "Create
Community" button; this is an Entra ID / M365 Groups setting, NOT a
Viva Engage-specific one)
    │
Community created → auto-provisions, as ONE unit:
    ├─ Connected Microsoft 365 Group
    ├─ SharePoint site (document library)
    ├─ OneNote notebook
    └─ Planner plan
    │
Admin role model governs ongoing management
(Global Admin > Engage Admin > Verified Admin > Network Admin >
Corporate Communicator; Community Admin is scoped to one community)
    │
Microsoft Graph /employeeExperience/* endpoints
(communities, roles, engagementAsyncOperation — automation layer,
Native Mode networks only, 10 req/user/app/30s rate limit)
```

</details>

---
## Diagnosis & Validation Flow

**1. Rule out the tenant-wide sign-in gate first.** A disabled service principal breaks Viva Engage for every user simultaneously — if more than one unrelated user reports the same symptom on the same day, check this before touching any individual account.
Command: Step 2 in Triage.

**2. Confirm domain verification before assuming a licensing gap.** Home-network access requires the user's email domain to be verified in Microsoft 365; a newly acquired subsidiary or a typo'd domain will look exactly like "user can't access Viva Engage" but has nothing to do with license assignment.
Command: Step 3 in Triage.

**3. Separate Entra directory roles from Viva Engage-specific roles.** Global Administrator and Engage Administrator (aka *Yammer administrator* in Entra ID) are true Entra directory roles, assignable via the Entra admin center or PIM. Verified Administrator, Network Administrator, and Corporate Communicator are **not** — they only exist inside the Viva Engage/Yammer admin center and must be granted by an existing Engage/Verified admin from there. A PIM assignment for "Network Administrator" simply doesn't exist as an option; if someone tries to find it in Entra roles and can't, that's expected, not a bug.

**4. For community-creation tickets, check the M365 Groups policy, not Viva Engage settings.** There is no Viva-Engage-native "who can create communities" toggle. Creating a community always creates a connected Microsoft 365 Group, so community creation inherits whatever `EnableGroupCreation`/`GroupCreationAllowedGroupId` policy governs Groups/Teams creation tenant-wide.

**5. For "it used to work, now it's a 404," check deletion state before escalating.** `GET /employeeExperience/communities/{id}` returning 404 for a community that definitely existed usually means it was deleted (by design or by mistake) — verify with the requesting admin before treating it as a platform fault.

---
## Common Fix Paths

<details><summary>Fix 1 — Sign-in error clicking the Viva Engage tile ("Sorry, but we're having trouble signing you in. We received a bad request.")</summary>

This is caused by the Viva Engage (Yammer) service principal having `AccountEnabled = False` — when this happens, **no user in the tenant can sign in**, even if correctly licensed and role-assigned.

1. Confirm the state:
   ```powershell
   Connect-MgGraph -Scopes "Application.Read.All"
   $sp = Get-MgServicePrincipal -Filter "AppId eq '00000005-0000-0ff1-ce00-000000000000'"
   $sp | Select-Object DisplayName, AccountEnabled, Id
   ```
2. If `AccountEnabled` is `False`, re-enable it:
   ```powershell
   Connect-MgGraph -Scopes "Application.ReadWrite.All"
   Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AccountEnabled:$true
   ```
3. Have the user sign out completely and retry the Viva Engage tile after a few minutes for token cache/propagation.

**Note:** older guidance references `Get-MsolServicePrincipal`/`Set-MsolServicePrincipal` from the MSOnline module — MSOnline is retired; use the Microsoft Graph PowerShell SDK commands above.

**Rollback:** N/A — re-enabling a first-party Microsoft service principal that should be enabled is not a destructive action. If it was intentionally disabled (e.g., during an offboarding/security response), coordinate with whoever disabled it before flipping it back.

</details>

---

<details><summary>Fix 2 — No "Create Community" option appears for anyone in the tenant</summary>

Community creation is gated by the tenant's Microsoft 365 Group creation policy, not by anything inside Viva Engage itself.

1. Check the current policy:
   ```powershell
   Connect-MgGraph -Scopes "Directory.Read.All"
   $groupUnified = Get-MgBetaDirectorySetting | Where-Object { $_.DisplayName -eq "Group.Unified" }
   $groupUnified.Values | Where-Object { $_.Name -in @("EnableGroupCreation","GroupCreationAllowedGroupId") }
   ```
2. If `EnableGroupCreation` is `False` and no `GroupCreationAllowedGroupId` is set, group (and therefore community) creation is off tenant-wide by design.
3. To allow a specific set of users, create/identify a security group and set it as the allowed-creators group:
   ```powershell
   Connect-MgGraph -Scopes "Directory.ReadWrite.All"
   $settingId = $groupUnified.Id
   $body = @{
     values = @(
       @{ name = "EnableGroupCreation"; value = "False" }
       @{ name = "GroupCreationAllowedGroupId"; value = "<allowedGroupObjectId>" }
     )
   }
   Update-MgBetaDirectorySetting -DirectorySettingId $settingId -BodyParameter $body
   ```
4. If the `Group.Unified` settings object doesn't exist yet, it must first be created from the `Group.Unified` directory setting template before it can be updated — group creation is unrestricted by default until this object exists.

**Rollback:** Set `EnableGroupCreation` back to `True` (or remove `GroupCreationAllowedGroupId`) to restore the prior, wider creation policy. This setting affects **all** Microsoft 365 Groups and Teams creation, not just Viva Engage communities — confirm with the client before changing it that they understand the blast radius.

</details>

---

<details><summary>Fix 3 — A user or entire department can't see the internal network</summary>

1. Confirm the user's UPN/mailbox domain:
   ```powershell
   $upn = "<user@domain.com>"
   $domain = $upn.Split("@")[1]
   Get-MgDomain -DomainId $domain | Select-Object Id, IsVerified, IsDefault
   ```
2. If the domain isn't verified in Microsoft 365, verify it first (standard M365 domain-verification flow — TXT/MX record) — this is a Microsoft 365 admin center task, not a Viva Engage-specific one.
3. If the domain **is** verified but the user still can't see the network, confirm they aren't intended for a separate **external network** (invitation-only, for outside partners) rather than the internal/home network — the two are architecturally distinct networks, not a permission level within one network.
4. For a newly acquired subsidiary with its own domain, decide deliberately whether to consolidate into one network or keep separate external networks — see [Combine multiple Viva Engage networks](https://learn.microsoft.com/en-us/viva/engage/configure-your-viva-engage-network/consolidate-multiple-viva-engage-networks) before making changes, since merging networks is not casually reversible.

**Rollback:** Domain verification itself has no meaningful rollback (removing a verified domain is a much larger M365 tenant action, out of scope for a Viva Engage ticket).

</details>

---

<details><summary>Fix 4 — Recover a deleted community</summary>

Deleting a community deletes, as one operation, the connected Microsoft 365 Group **and** its SharePoint document library, OneNote notebook, and Planner plans.

1. Confirm the 30-day window hasn't elapsed — Microsoft 365 content (Group, SharePoint, OneNote, Planner) tied to a deleted community is soft-deleted and admin-restorable for **30 days** from deletion.
2. Conversation-level recovery depends on the network's retention setting, not the 30-day Groups window: if the network retention policy is set to **Delete**, deleted conversations are retained 30 days then permanently purged; if set to **Archive**, they're retained indefinitely and remain recoverable well past 30 days.
3. To restore the underlying Microsoft 365 Group (and its connected resources) within the 30-day window:
   ```powershell
   Connect-MgGraph -Scopes "Directory.ReadWrite.All"
   Get-MgDirectoryDeletedItemAsGroup -DirectoryObjectId <groupObjectId>   # confirm it's the right group first
   Restore-MgDirectoryDeletedItem -DirectoryObjectId <groupObjectId>
   ```
4. There is no separate self-service Graph endpoint to restore the *community* object itself distinct from its underlying group — restoring the group is the mechanism. If the community-level metadata (description, community-specific settings) doesn't fully reappear after group restore, escalate to Microsoft Support with the Evidence Pack rather than assuming it's unrecoverable.

**Rollback:** This *is* the rollback path for an accidental deletion. Going the other direction (re-deleting after a restore) uses the same destructive community-delete action — confirm with the requester before repeating it.

</details>

---

<details><summary>Fix 5 — Assigning Verified Admin / Network Admin / Corporate Communicator doesn't show up anywhere in Entra ID</summary>

This is expected, not a bug — these three roles are **not** Entra directory roles.

| Role | Assign in |
|---|---|
| Global Administrator | Entra ID / Microsoft 365 admin center |
| Engage Administrator (aka *Yammer administrator*) | Entra ID / Microsoft 365 admin center |
| Verified Administrator | Viva Engage/Yammer admin center → Admins → find user → **Grant Verified Admin** |
| Network Administrator | Viva Engage/Yammer admin center → Admins → find user → **Grant Network Admin** |
| Answers Administrator | Entra ID — assign the **Knowledge Manager** role |
| Corporate Communicator | Viva Engage admin center → Setup and configuration → **Manage corporate communicators** |
| Community Administrator | Inside the specific community → Settings → Manage Members and Admins → **Make Admin** (or automatically granted to whoever creates the community) |

1. Confirm which role is actually needed against the table above before searching the wrong portal.
2. Only an Engage Administrator or an existing Verified Administrator can grant Verified/Network Admin — if the requester doesn't have one of those roles, they cannot self-serve this in the Viva Engage admin center.
3. For Community Administrator specifically, adding a user as a **group owner** via Entra ID/Graph also automatically grants them community admin on the connected community — a valid alternative path if you're already scripting group ownership changes.

**Rollback:** Revoke the same way it was granted — via the matching portal in the table above, not via an Entra role removal (which will do nothing for Verified/Network Admin/Corporate Communicator).

</details>

---

<details><summary>Fix 6 — Automating community management via Graph fails with 404 or 429</summary>

1. **404 on creation:** confirm the automation is calling `POST /employeeExperience/communities`, not `POST /groups` — you cannot provision a Viva Engage community through the generic Create Group API; it will create a plain M365 Group with no Viva Engage community behind it.
2. **Creation "succeeds" but the community isn't immediately queryable:** community creation is asynchronous. `POST /employeeExperience/communities` returns `202 Accepted` with a link to an `engagementAsyncOperation`; poll `GET /employeeExperience/engagementAsyncOperations/{id}` — waiting **more than 30 seconds between checks** — until `status` is `succeeded`, then read `resourceLocation` for the created community.
3. **429 Too Many Requests:** the Viva Engage API allows **10 requests per user, per app, per 30-second window**. A bulk-provisioning script that loops without throttling will trip this quickly — add a delay or batch with backoff rather than retrying immediately.

**Rollback:** N/A — this is an automation-correctness fix, not a configuration change.

</details>

---

<details><summary>Fix 7 — External network partners see an outdated/legacy experience</summary>

External Networks began a separate modernization migration in mid-2025, distinct from the (now-complete) internal-network Native Mode migration. A tenant that hasn't explicitly actioned this yet will still show partners the older external-network UX.

1. Confirm in the Viva Engage admin center whether an external-network migration prompt is pending — this requires an explicit admin opt-in, it does not happen automatically on a timer for every tenant.
2. Action the migration prompt when convenient for the client (communicate to external partners beforehand, since the UX changes materially).
3. If the client wants to defer, confirm they understand Microsoft's own guidance: failure to respond to a migration request eventually results in the legacy external network being deprecated and deleted, not indefinitely grandfathered.

**Rollback:** Not reversible once actioned — treat the migration prompt as a one-way decision and confirm timing with the client rather than clicking through it reactively.

</details>

---

<details><summary>Fix 8 — Communication Compliance / retention label policy shows zero matches from Viva Engage</summary>

Cross-reference: `Security/Purview/CommunicationCompliance-A.md` and `Security/Purview/RetentionLabels-A.md` both document a **Native Mode** prerequisite for these channels to be visible to Purview policies. Since every network is now Native Mode tenant-wide (Oct 13, 2025 retirement), "the tenant isn't Native Mode yet" is **no longer a valid explanation** as of this writing — if that's still the working theory on a ticket, it's stale.

1. Re-verify current-state facts rather than reusing an old assumption: confirm the policy's channel selection actually includes Viva Engage, not just Teams/Exchange.
2. Confirm normal processing latency hasn't been mistaken for a failure — ~24h for email, ~48h for Teams/Viva Engage/third-party sources, per `CommunicationCompliance-B.md`.
3. For retention label distribution specifically, confirm the correct cmdlet was used — `Set-AppRetentionCompliancePolicy -RetryDistribution` for Teams/Viva Engage, not `Set-RetentionCompliancePolicy` (per `RetentionLabels-A.md`).
4. If both channel selection and latency are ruled out, treat as a genuine Purview-side issue and follow `CommunicationCompliance-B.md`/`RetentionLabels-B.md` directly rather than duplicating that troubleshooting here.

**Rollback:** N/A — read-only verification path.

</details>

---
## Escalation Evidence

```
=== VIVA ENGAGE ESCALATION TEMPLATE ===
Affected user(s)/UPN(s): ___________
Network type (Internal/home / External): ___________
Symptom (sign-in error / can't create community / can't see network / deleted
community / role assignment confusion / automation 404-429 / external network
legacy UX / Purview zero matches): ___________
Service principal AccountEnabled state (Step 2 in Triage): ___________
Domain verification state for affected UPN (Step 3 in Triage): ___________
Viva Engage roles currently assigned to the user (Step 4 in Triage): ___________
M365 Group creation policy state, if community-creation related (Step 5): ___________
Community ID (if applicable) and last known-good state: ___________
Timeline (when first reported / first observed): ___________
Screenshot of the exact error text or portal state (attach): ___________
```

---
## 🎓 Learning Pointers

- **Native Mode is no longer a variable to check — it's universal.** Microsoft retired all legacy (non-native) Viva Engage networks on October 13, 2025. Any documentation, internal note, or prior ticket that frames a fix as conditional on "if the network isn't in Native Mode yet" is describing a state that can no longer exist. Treat that framing as historical, not diagnostic. [MS Docs: Access to Non-Native Viva Engage Network Ending](https://learn.microsoft.com/en-us/viva/engage/overview-native-mode)

- **A single disabled service principal (AppId `00000005-0000-0ff1-ce00-000000000000`) breaks sign-in for the entire tenant at once.** If multiple unrelated users report the same generic sign-in error the same day, check this tenant-wide gate before triaging individual accounts one by one. [MS Docs: Sign-in error when you select the Viva Engage tile](https://learn.microsoft.com/en-us/yammer/troubleshoot-problems/error-when-click-the-yammer-tile-in-office-365)

- **Verified Admin, Network Admin, and Corporate Communicator are not Entra directory roles — don't look for them in PIM.** Only Global Administrator and Engage Administrator (Yammer administrator) live in Entra ID; the other admin roles are granted from inside the Viva Engage/Yammer admin center itself by an existing higher-privilege admin. [MS Docs: Manage administrator roles in Viva Engage](https://learn.microsoft.com/en-us/viva/engage/eac-key-admin-roles-permissions)

- **"Restrict who can create communities" is really "restrict who can create Microsoft 365 Groups."** There is no Viva-Engage-specific creation toggle; changing `EnableGroupCreation`/`GroupCreationAllowedGroupId` affects Teams and Groups creation tenant-wide, not just communities — confirm the client understands that blast radius before applying it as a Viva Engage fix. [MS Docs: Viva Engage and Microsoft 365 Groups](https://learn.microsoft.com/en-us/viva/engage/engage-microsoft-365-groups)

- **Community deletion is a single cascading operation across four Microsoft 365 services at once** (Group, SharePoint, OneNote, Planner), all soft-deleted together for 30 days. Conversation-level retention is a *separate* clock governed by the network's own retention policy (Delete = 30 days then gone forever; Archive = indefinite) — don't conflate the two recovery windows when scoping an escalation. [MS Docs: Delete a community in Viva Engage](https://support.microsoft.com/en-us/office/delete-a-community-in-viva-engage-c9d19e25-ce9e-4b47-9174-baefc203793e)

- **The Graph API for Viva Engage only works against Native Mode networks and enforces a tight 10-requests-per-30-seconds limit.** Bulk automation (provisioning many communities, syncing role assignments) needs deliberate throttling and asynchronous polling (`engagementAsyncOperation`, wait >30s between polls) built in from the start, not added after the first `429`. [MS Docs: Use the Microsoft Graph API to work with Viva Engage](https://learn.microsoft.com/en-us/graph/api/resources/engagement-api-overview?view=graph-rest-1.0)
