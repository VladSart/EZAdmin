# Viva Engage (Yammer) — Reference Runbook (Mode A: Deep Dive)
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
- Viva Engage (formerly Yammer) network access, sign-in, and the service-principal gate
- Native Mode architecture: communities, connected Microsoft 365 Groups, and the auto-provisioned SharePoint/OneNote/Planner backing resources
- The admin role model (Global Administrator, Engage Administrator, Verified Administrator, Network Administrator, Answers Administrator, Corporate Communicator, Community Administrator) and which portal governs each
- Community lifecycle (create/update/delete) via the Microsoft Graph `/employeeExperience` API surface
- Domain-based home-network access and the internal-vs-external network model
- Community-creation gating via the Microsoft 365 Group creation policy

**Not in scope (see cross-references):**
- Communication Compliance and retention-label policy configuration for Viva Engage as a monitored channel — see `Security/Purview/CommunicationCompliance-A/B.md` and `Security/Purview/RetentionLabels-A/B.md` (this file covers Viva Engage's own admin/access model; those files own the Purview-side policy mechanics)
- eDiscovery collection against Yammer/Viva Engage content — see `Security/Purview/eDiscovery-A.md`
- Viva Engage Premium features in depth (Storylines, Leadership Corner, Campaigns, Answers) beyond what's needed to explain the admin role model — these are content/engagement features, not an admin troubleshooting surface, and change too frequently for a stable reference here
- General Microsoft 365 Group/Team creation policy administration beyond the one setting that happens to also gate community creation — see your tenant's Groups/Teams governance documentation for the full picture
- Microsoft 365 group-based licensing mechanics — see `M365/Licensing/Group-Based-Licensing-A/B.md`

**Assumed knowledge:**
- Comfortable with the Entra admin center and Microsoft Graph PowerShell SDK (`Microsoft.Graph` / `Microsoft.Graph.Beta`)
- Understands Microsoft 365 Groups as the backing object for Teams, SharePoint, and Planner
- Has at least Global Reader for read/evidence-collection steps; Global Administrator or Engage Administrator for any write action described here

---

## How It Works

<details><summary>Full architecture</summary>

### Native Mode is now universal, not a configuration state

Viva Engage originally launched as Yammer, a standalone network with its own identity model, and later moved to "Native Mode" — full integration with Microsoft 365 identity, Groups, and SharePoint storage. For years, tenants could be in either state, and troubleshooting content (including some still-published Microsoft docs and the cross-referenced Purview files in this repo) had to branch on "is this tenant Native Mode yet?"

That branch no longer exists. Microsoft retired access to non-native (legacy) networks on **October 13, 2025** — unmigrated networks became inaccessible and were scheduled for deletion. As of this writing, every reachable Viva Engage network is, by definition, a Native Mode network. This matters for two practical reasons: first, any remaining "check if Native Mode" step in older internal documentation or a stale runbook is now dead code — skip it. Second, the Microsoft Graph Viva Engage API (`/employeeExperience/*`) is explicitly documented as Native Mode-only, so it is now unconditionally usable against any tenant's network rather than conditionally available.

A separate, still-active migration exists for **External Networks** specifically (the invitation-only spaces for outside partners) — this began rolling out around mid-2025 and, unlike the internal-network Native Mode retirement, requires an explicit per-tenant admin opt-in rather than happening automatically. Don't conflate the two: internal-network Native Mode is done and universal; external-network modernization is ongoing and admin-initiated.

### The community → Microsoft 365 Group → backing-services chain

Every Viva Engage **community** in a Native Mode network is backed by exactly one connected **Microsoft 365 Group**, which in turn auto-provisions:

```
Community (Viva Engage-facing object)
    │
Connected Microsoft 365 Group (identity/membership backbone)
    ├─ SharePoint site (document library)
    ├─ OneNote notebook
    └─ Planner plan
```

This is provisioned and torn down as a single unit. You cannot create a Viva Engage community by calling the generic `POST /groups` Create Group API — Microsoft Graph explicitly blocks that path for communities; you must use `POST /employeeExperience/communities`, which handles the group and all three backing services together. Conversely, standard group-management operations (add/remove member, add/remove owner, rename, delete) work correctly against the connected group and automatically reflect in the community — for example, adding a user as a group **owner** automatically makes them a Community Administrator, and Microsoft Graph will refuse to remove the **last** owner of a group, which functions as an accidental built-in guardrail against orphaning a community's admin.

### Community creation is asynchronous

`POST /employeeExperience/communities` returns `202 Accepted` with a link to an `engagementAsyncOperation` resource rather than the finished community. The correct pattern is:

```
POST /employeeExperience/communities
  → 202 Accepted, Location: .../engagementAsyncOperations/{id}

GET /employeeExperience/engagementAsyncOperations/{id}   (poll, wait >30s between checks)
  → status: notStarted | running | succeeded | failed
  → on succeeded: resourceLocation points to the finished community

GET {resourceLocation}   → the finished community object
```

Scripts that assume synchronous creation and immediately try to read/use the new community will intermittently fail — not because of a platform bug, but because they're racing an operation that's documented as asynchronous.

### Community creation is gated by Microsoft 365 Group policy, not a Viva Engage setting

There is no Viva Engage-native "restrict community creation" toggle. Because every community requires a connected Microsoft 365 Group, community creation inherits whatever tenant-wide Group/Team creation policy is configured via the `Group.Unified` directory setting template — specifically `EnableGroupCreation` (boolean) and `GroupCreationAllowedGroupId` (the security or M365 group whose members are exempt from the restriction). If a user isn't in the allowed-creators group and `EnableGroupCreation` is `False`, the "Create Community" option is simply hidden from their UI — there's nothing to misconfigure inside Viva Engage itself to fix this; the fix lives entirely in Entra ID / Microsoft Graph group settings, and it affects Teams and SharePoint-connected Groups creation identically, not just communities. This is a recurring source of scope confusion in client requests ("restrict who can make new Viva Engage groups") that are really Microsoft 365 Groups governance requests wearing a Viva Engage label.

### The admin role model: seven roles, three different assignment surfaces

Viva Engage's admin roles are **not** a single flat list assignable from one place. They split across three distinct assignment surfaces:

| Role | Assigned in | Notes |
|---|---|---|
| Microsoft 365 Global Administrator | Entra ID / Microsoft 365 admin center | Broadest scope; controls all Viva Engage admin role assignment indirectly by controlling Engage Administrator assignment |
| Engage Administrator | Entra ID / Microsoft 365 admin center (or PIM) | True Entra directory role, internally still labeled *Yammer administrator* — configures all core/premium features, compliance, and can assign Verified/Network Admin/Corporate Communicator |
| Verified Administrator | Viva Engage/Yammer admin center (granted by Engage or another Verified admin) | Legal-implication tasks: security settings, keyword monitoring, data retention/export |
| Network Administrator | Viva Engage/Yammer admin center (granted by Engage, Verified, or another Network admin) | Day-to-day network configuration, usage policy, user/guest management, content moderation actions |
| Answers Administrator | Entra ID — assign the **Knowledge Manager** role | Governs the separate Answers (Q&A) feature and its topic management |
| Corporate Communicator | Viva Engage admin center → Setup and configuration → Manage corporate communicators | Campaign creation/management, marking communities official, muting content network-wide |
| Community Administrator | Inside the specific community's settings, or automatically granted to the community's creator | Scoped to one community only; can promote up to 100 co-admins within it |

The practical consequence: a support engineer who only checks Entra ID role assignments will correctly account for Global Administrator, Engage Administrator, and Answers Administrator, but will find **nothing** for Verified Administrator, Network Administrator, or Corporate Communicator — those three exist purely inside the Viva Engage/Yammer admin center's own admin list. As of the most recently updated Microsoft documentation for this topic (dated 2026), the assignment instructions for Verified/Network Admin still literally route through what's labeled the "Yammer admin center" — a naming artifact from the pre-rebrand product that persists in current official guidance and is worth knowing about so it doesn't read as a stale/wrong doc link when you encounter it.

### Role hierarchy and who can assign whom

```
Microsoft 365 Global Administrator
    └─ can assign: other Global Admins, Engage Admins, Answers Admins (Knowledge Manager)
Engage Administrator
    └─ can assign: Verified Admins, Network Admins, Corporate Communicators
Verified Administrator
    └─ can assign: Verified Admins, Network Admins, Corporate Communicators
Network Administrator
    └─ can assign: other Network Admins, Corporate Communicators
Community Administrator
    └─ can assign: other Community Admins (within their own community, up to 100)
```

Custom Viva Engage roles cannot be created or deleted — the seven roles above are Microsoft-predefined and fixed.

### Domain-gated network access

A user's access to the internal ("home") network is gated by whether their email domain is a **verified domain in Microsoft 365** and matches the network's configured domain set — not by license assignment alone. A user with a valid Viva Engage license but an email domain that isn't verified (a common gap right after an acquisition, or with a freshly-added subsidiary domain that hasn't completed DNS verification) will not see the internal network, which reads to the user exactly like "Viva Engage doesn't work for me." Organizations spanning multiple domains from different business units can either consolidate into one network or maintain separate **external networks** — a genuinely different network type (invitation-only, for outside collaboration) rather than a permission tier within the internal network.

### Microsoft Graph role management for Viva Engage

Beyond community CRUD, Microsoft Graph exposes role management specifically for Viva Engage's own predefined roles (distinct from Entra directory roles):

```
GET    /employeeExperience/roles                                    — static list of assignable role types
GET    /employeeExperience/roles/{roleId}/members                   — users holding a specific role
GET    /me/employeeExperience/assignedRoles                         — caller's own assigned roles
GET    /users/{userId}/employeeExperience/assignedRoles             — a specific user's assigned roles
POST   /employeeExperience/roles/{roleId}/members                   — assign a role
DELETE /employeeExperience/roles/{roleId}/members/{userId}          — revoke a role
```

This is the automatable equivalent of the Viva Engage/Yammer admin center's manual role-grant UI, useful for MSP-scale role audits across many client tenants without navigating each admin center by hand.

### API rate limiting

All Viva Engage Graph API calls are limited to **10 requests per user, per app, within a 30-second window**; exceeding it returns `429 Too Many Requests`. Bulk provisioning or audit scripts need deliberate pacing (a short sleep between calls, or explicit backoff on `429`) built in from the start — this limit is tight enough that a naive loop over even a few dozen communities will trip it.

</details>

---

## Dependency Stack

```
Entra ID tenant + verified domain(s)
    └── Microsoft 365 license (Business/Enterprise/EDU SKU = Viva Engage Core;
        Viva Suite or standalone add-on = Premium features)
            └── Viva Engage (Yammer) service principal — AppId
                00000005-0000-0ff1-ce00-000000000000
                (tenant-wide AccountEnabled gate; disabled = nobody signs in)
                    └── Native Mode network
                        (universal since Oct 13, 2025 legacy retirement —
                         no longer a per-tenant variable)
                            └── Domain-gated home-network membership
                                (user's verified email domain must match the
                                 network's configured domain set)
                                    └── Microsoft 365 Group creation policy
                                        (EnableGroupCreation /
                                         GroupCreationAllowedGroupId — gates
                                         community creation, tenant-wide,
                                         NOT Viva Engage-specific)
                                            └── Community created (single unit):
                                                Microsoft 365 Group +
                                                SharePoint site + OneNote +
                                                Planner plan
                                                    └── Admin role model
                                                        (7 roles, 3 assignment
                                                         surfaces — see How It
                                                         Works)
                                                            └── Microsoft Graph
                                                                /employeeExperience/*
                                                                (communities,
                                                                 roles, async
                                                                 ops — Native
                                                                 Mode only,
                                                                 10 req/30s)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Every user gets "Sorry, but we're having trouble signing you in. We received a bad request." on the Viva Engage tile | Viva Engage service principal `AccountEnabled = False` | `Get-MgServicePrincipal -Filter "AppId eq '00000005-0000-0ff1-ce00-000000000000'"` |
| One user or department can't see the internal network at all | Email domain not verified in M365, or doesn't match the network's domain set | `Get-MgDomain` for the user's domain |
| No "Create Community" option anywhere in the tenant | `EnableGroupCreation = False` with no matching `GroupCreationAllowedGroupId` membership | `Get-MgBetaDirectorySetting` on the `Group.Unified` template |
| A specific admin can't perform Verified/Network Admin actions despite "having the role" | The role was looked for (or assigned) in Entra ID, but these two roles only exist in the Viva Engage/Yammer admin center | Confirm assignment surface against the role table in How It Works |
| Automation script gets 404 trying to create a community | Script called `POST /groups` instead of `POST /employeeExperience/communities` | Review the automation's request path |
| Automation script's "created" community isn't found immediately after the create call | Creation is asynchronous (`202` + `engagementAsyncOperation`); script isn't polling | Confirm the script polls `engagementAsyncOperations/{id}` before reading the result |
| Bulk script fails partway through with `429` | Exceeded 10 requests/user/app/30s | Add pacing/backoff; check for parallel script instances sharing the same app registration |
| Community returns `404` from Graph when it definitely existed | Deleted — intentionally or accidentally | Confirm with the requesting admin; check the 30-day M365 content recovery window |
| Removing a user as group owner fails with an error | Microsoft Graph refuses to remove the **last** owner of a group | Add a second owner first, or confirm this is actually the intended final owner removal (which should go through account/group deletion instead) |
| Purview Communication Compliance/retention shows zero Viva Engage matches | Not a Native Mode gap (that's now universal) — check channel selection in the policy itself, or normal processing latency | See `Security/Purview/CommunicationCompliance-A.md` / `RetentionLabels-A.md` |
| External network partners see an outdated UX | External Network modernization is a separate, admin-opt-in migration, distinct from the (complete) internal Native Mode retirement | Check Viva Engage admin center for a pending migration prompt |

---

## Validation Steps

**Step 1 — Confirm the tenant-wide sign-in gate**
```powershell
Connect-MgGraph -Scopes "Application.Read.All"
Get-MgServicePrincipal -Filter "AppId eq '00000005-0000-0ff1-ce00-000000000000'" |
  Select-Object DisplayName, AccountEnabled, Id
```
*Good:* `AccountEnabled = True`.
*Bad:* `AccountEnabled = False` — this affects every user in the tenant simultaneously; fix before any per-user investigation.

---

**Step 2 — Confirm domain verification for the affected user**
```powershell
$upn = "<user@domain.com>"
Get-MgDomain -DomainId $upn.Split("@")[1] | Select-Object Id, IsVerified, IsDefault
```
*Good:* `IsVerified = True` for the user's domain.
*Bad:* Domain missing from `Get-MgDomain` output entirely, or `IsVerified = False` — the user is licensed but architecturally cannot see the home network yet.

---

**Step 3 — Confirm which of the 7 admin roles a user actually holds**
```powershell
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/v1.0/users/<userId>/employeeExperience/assignedRoles"
```
*Good:* Returned roles match what the ticket claims the user should have.
*Bad:* Empty result for a user who "is definitely an admin" — cross-check whether the role in question (Verified/Network Admin/Corporate Communicator) is even visible through this Entra-user-centric endpoint, or whether it needs to be confirmed directly in the Viva Engage/Yammer admin center instead.

---

**Step 4 — Confirm the Microsoft 365 Group creation policy**
```powershell
Connect-MgGraph -Scopes "Directory.Read.All"
$groupUnified = Get-MgBetaDirectorySetting | Where-Object { $_.DisplayName -eq "Group.Unified" }
if ($groupUnified) {
    $groupUnified.Values | Where-Object { $_.Name -in @("EnableGroupCreation","GroupCreationAllowedGroupId") }
} else {
    Write-Host "No Group.Unified settings object exists — group (and community) creation is UNRESTRICTED by default."
}
```
*Good:* Policy state matches the client's intended governance (either deliberately open, or restricted to a known group).
*Bad:* `EnableGroupCreation = False` with no `GroupCreationAllowedGroupId`, and the requesting user isn't a Global/Engage Administrator (who bypass the restriction) — community creation will be invisible to them by design.

---

**Step 5 — Confirm a community's live state and connected group**
```powershell
$communityId = "<communityId>"
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/v1.0/employeeExperience/communities/$communityId"
```
*Good:* `200 OK` with the community object, including the connected `groupId`.
*Bad:* `404` — confirm deletion state (Remediation Playbook 2) before treating as a platform defect.

---

## Troubleshooting Steps (by phase)

### Phase 1: Tenant-Wide Access Failure
1. Run Validation Step 1 immediately if more than one unrelated user reports the same generic sign-in error on the same day.
2. If the service principal is enabled and the problem persists, check for a broader Microsoft 365 service health incident before deeper investigation (Microsoft 365 admin center → Service health).
3. Confirm licensing hasn't lapsed tenant-wide (a bulk license removal will look like a Viva Engage-specific outage).

### Phase 2: Individual/Departmental Access Gap
1. Run Validation Step 2 for domain verification.
2. Confirm the user isn't being sent to (or expecting) an external network instead of the internal one — verify which network type is actually relevant to the ticket.
3. For multi-domain organizations, confirm whether the intended architecture is a single consolidated network or deliberately separate external networks before "fixing" what may be working as designed.

### Phase 3: Admin Role Confusion
1. Run Validation Step 3.
2. Cross-check the role table in How It Works to identify the correct assignment surface (Entra ID vs. Viva Engage/Yammer admin center vs. inside a specific community).
3. Confirm the assigning admin themselves holds a role senior enough to grant the target role (see the role hierarchy diagram) — a Network Administrator cannot grant Verified Administrator, for example.

### Phase 4: Community Creation / Governance
1. Run Validation Step 4.
2. If restricting creation, confirm the client understands this is a Microsoft 365 Groups-wide policy change, not a Viva Engage-scoped one — document this explicitly in the change record.
3. If a specific user needs an exception without opening creation tenant-wide, add them to the `GroupCreationAllowedGroupId` group rather than changing `EnableGroupCreation`.

### Phase 5: Community Lifecycle / Data Recovery
1. Run Validation Step 5 to confirm current state.
2. If deleted, move directly to Remediation Playbook 2 (30-day recovery window) rather than re-explaining the architecture from scratch each time.
3. Distinguish the Groups/SharePoint/OneNote/Planner 30-day soft-delete window from the network's own conversation-retention clock (Delete vs. Archive) — they are independent and commonly confused during recovery-scoping conversations with a client.

### Phase 6: Automation/Graph API Issues
1. Confirm the correct endpoint is used (`/employeeExperience/communities`, never `/groups`, for community creation).
2. Confirm asynchronous polling is implemented correctly (>30s between polls against `engagementAsyncOperations`).
3. Confirm request pacing against the 10-req/30s limit, especially for multi-tenant MSP scripts that might run several client audits in parallel from the same app registration.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Tenant-wide sign-in outage (service principal disabled)</summary>

1. Confirm via Validation Step 1.
2. Re-enable:
   ```powershell
   Connect-MgGraph -Scopes "Application.ReadWrite.All"
   $sp = Get-MgServicePrincipal -Filter "AppId eq '00000005-0000-0ff1-ce00-000000000000'"
   Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AccountEnabled:$true
   ```
3. Confirm re-enablement:
   ```powershell
   (Get-MgServicePrincipal -ServicePrincipalId $sp.Id).AccountEnabled
   ```
4. Have one test user sign out and back in fully before declaring the tenant-wide issue resolved — token caching can make the fix appear not to have worked for a few minutes.

**Rollback:** If the service principal was disabled deliberately (security response, planned decommission), re-disabling it reverses this playbook exactly — confirm intent with whoever made the original change before doing so.

</details>

---

<details><summary>Playbook 2 — Recover a deleted community within the 30-day window</summary>

1. Confirm the deletion timestamp is within 30 days — after that, Microsoft 365 content (Group, SharePoint, OneNote, Planner) is permanently purged and not recoverable by any admin action.
2. Identify the connected group's object ID (from prior documentation, an audit script's last-known-good export, or Entra ID audit logs if still within their own retention window).
3. Restore the group and its connected resources:
   ```powershell
   Connect-MgGraph -Scopes "Directory.ReadWrite.All"
   Restore-MgDirectoryDeletedItem -DirectoryObjectId "<groupObjectId>"
   ```
4. Verify the community reappears in Viva Engage and that SharePoint/OneNote/Planner content is intact.
5. Separately, confirm conversation-level recovery against the network's retention setting — if set to **Delete**, conversations older than 30 days from deletion are gone regardless of the group restore above; if set to **Archive**, they should still be present.
6. If the community metadata itself (description, community-specific settings) doesn't fully return after the group restore, escalate to Microsoft Support with the Evidence Pack — there is no documented self-service Graph endpoint for restoring community-specific metadata independent of the underlying group.

**Rollback:** This playbook is itself a recovery action. If restored in error (e.g., a community that was deliberately decommissioned), re-run the standard community deletion flow to reverse it — understanding that doing so restarts a fresh 30-day recovery clock.

</details>

---

<details><summary>Playbook 3 — Reconcile the M365 Group creation policy with client intent (community-creation governance)</summary>

Use when a client wants to restrict who can create Viva Engage communities, and needs to understand this is a Groups-wide decision.

1. Document current state via Validation Step 4.
2. Confirm with the client explicitly: restricting `EnableGroupCreation` will also restrict who can create Teams and SharePoint-connected Groups — get this signed off as an accepted trade-off, not assumed.
3. Identify or create the security group that should be exempted via `GroupCreationAllowedGroupId`.
4. Apply the change:
   ```powershell
   Connect-MgGraph -Scopes "Directory.ReadWrite.All"
   $groupUnified = Get-MgBetaDirectorySetting | Where-Object { $_.DisplayName -eq "Group.Unified" }
   $body = @{
     values = @(
       @{ name = "EnableGroupCreation"; value = "False" }
       @{ name = "GroupCreationAllowedGroupId"; value = "<allowedGroupObjectId>" }
     )
   }
   Update-MgBetaDirectorySetting -DirectorySettingId $groupUnified.Id -BodyParameter $body
   ```
5. Communicate the change to end users before it takes effect — "Create Community"/"Create Team"/"Create Group" silently disappearing without warning is a common source of confused follow-up tickets.

**Rollback:**
```powershell
$body = @{ values = @( @{ name = "EnableGroupCreation"; value = "True" } ) }
Update-MgBetaDirectorySetting -DirectorySettingId $groupUnified.Id -BodyParameter $body
```

</details>

---

<details><summary>Playbook 4 — Bulk role audit across the 7 Viva Engage admin roles (MSP multi-client use)</summary>

Use as a recurring governance check, or when onboarding a new client tenant and needing a baseline of who currently holds elevated Viva Engage access.

1. Enumerate the static role list:
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/employeeExperience/roles"
   ```
2. For each returned role ID, list its members:
   ```powershell
   Invoke-MgGraphRequest -Method GET `
     -Uri "https://graph.microsoft.com/v1.0/employeeExperience/roles/$roleId/members"
   ```
3. Cross-reference against Entra directory role holders for Global Administrator, Engage Administrator, and Answers Administrator (Knowledge Manager) separately — these three do not appear in the `/employeeExperience/roles` results, since they're Entra-native, not Viva Engage-native.
4. Flag any departed employee or overly broad Verified/Network Admin assignment for removal, granted from the Viva Engage/Yammer admin center by a current Engage or Verified Administrator.
5. Document findings per client, consistent with the Evidence Pack format below.

**Rollback:** N/A — read-only audit.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Viva Engage admin/access evidence collector.
.DESCRIPTION Read-only. Collects service-principal state, domain verification,
             Group.Unified creation policy, and a specific user's Viva Engage
             role assignments — the evidence Microsoft Support asks for on
             sign-in, community-creation, and role-confusion tickets.
.PARAMETER   UserUpn   UPN of the affected user (optional; skips user-scoped
             checks if omitted).
.EXAMPLE     .\Get-VivaEngageEvidence.ps1 -UserUpn user@contoso.com
.NOTES       Requires Microsoft.Graph and Microsoft.Graph.Beta modules.
             No pwsh available in this authoring environment to execute-test
             directly — reviewed manually for cmdlet/parameter correctness
             against current Microsoft Graph PowerShell SDK documentation.
#>
[CmdletBinding()]
param(
    [string]$UserUpn
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

Connect-MgGraph -Scopes "Application.Read.All","Directory.Read.All","User.Read.All" -NoWelcome

$outPath = "$env:TEMP\VivaEngage-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine("=== VIVA ENGAGE EVIDENCE PACK ===")
$null = $sb.AppendLine("Collected: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC")
$null = $sb.AppendLine("")

# 1. Tenant-wide service principal gate
Write-Status "Checking Viva Engage service principal state..."
$sp = Get-MgServicePrincipal -Filter "AppId eq '00000005-0000-0ff1-ce00-000000000000'"
$null = $sb.AppendLine("--- Service Principal ---")
if ($sp) {
    $null = $sb.AppendLine("DisplayName: $($sp.DisplayName)")
    $null = $sb.AppendLine("AccountEnabled: $($sp.AccountEnabled)")
    if (-not $sp.AccountEnabled) {
        Write-Status "Service principal is DISABLED — this breaks sign-in tenant-wide." "ERROR"
    } else {
        Write-Status "Service principal enabled." "OK"
    }
} else {
    $null = $sb.AppendLine("Service principal not found — unexpected for a tenant with Viva Engage in use.")
    Write-Status "Service principal not found." "WARN"
}
$null = $sb.AppendLine("")

# 2. Microsoft 365 Group creation policy (gates community creation)
Write-Status "Checking Group.Unified creation policy..."
$null = $sb.AppendLine("--- Group.Unified Creation Policy ---")
$groupUnified = Get-MgBetaDirectorySetting | Where-Object { $_.DisplayName -eq "Group.Unified" }
if ($groupUnified) {
    foreach ($v in $groupUnified.Values) {
        if ($v.Name -in @("EnableGroupCreation","GroupCreationAllowedGroupId")) {
            $null = $sb.AppendLine("$($v.Name): $($v.Value)")
        }
    }
} else {
    $null = $sb.AppendLine("No Group.Unified settings object exists — group/community creation is UNRESTRICTED by default.")
    Write-Status "No custom Group.Unified policy — creation is open tenant-wide." "WARN"
}
$null = $sb.AppendLine("")

# 3. Domain verification summary
Write-Status "Checking verified domains..."
$null = $sb.AppendLine("--- Verified Domains ---")
Get-MgDomain | ForEach-Object {
    $null = $sb.AppendLine("$($_.Id): Verified=$($_.IsVerified) Default=$($_.IsDefault)")
}
$null = $sb.AppendLine("")

# 4. User-scoped checks (optional)
if ($UserUpn) {
    Write-Status "Checking user-scoped evidence for $UserUpn..."
    $null = $sb.AppendLine("--- User: $UserUpn ---")
    try {
        $user = Get-MgUser -UserId $UserUpn
        $userDomain = $UserUpn.Split("@")[1]
        $domainInfo = Get-MgDomain -DomainId $userDomain -ErrorAction SilentlyContinue
        if ($domainInfo) {
            $null = $sb.AppendLine("Domain '$userDomain' verified: $($domainInfo.IsVerified)")
        } else {
            $null = $sb.AppendLine("Domain '$userDomain' not found in tenant's verified domain list.")
            Write-Status "User's domain not found in tenant — likely access gap." "WARN"
        }

        $roles = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/users/$($user.Id)/employeeExperience/assignedRoles" `
            -ErrorAction SilentlyContinue
        $null = $sb.AppendLine("Viva Engage roles (employeeExperience/assignedRoles):")
        if ($roles -and $roles.value) {
            foreach ($r in $roles.value) {
                $null = $sb.AppendLine("  - $($r.displayName)")
            }
        } else {
            $null = $sb.AppendLine("  (none returned — remember Verified Admin/Network Admin/Corporate")
            $null = $sb.AppendLine("   Communicator may not surface here; confirm in the Viva Engage/")
            $null = $sb.AppendLine("   Yammer admin center directly.)")
        }

        $licenses = Get-MgUserLicenseDetail -UserId $user.Id
        $null = $sb.AppendLine("Licenses:")
        foreach ($lic in $licenses) {
            $null = $sb.AppendLine("  - $($lic.SkuPartNumber)")
        }
    } catch {
        $null = $sb.AppendLine("Error collecting user-scoped evidence: $($_.Exception.Message)")
        Write-Status "Error collecting user-scoped evidence: $($_.Exception.Message)" "ERROR"
    }
    $null = $sb.AppendLine("")
}

$null = $sb.AppendLine("--- Manual Evidence To Attach ---")
$null = $sb.AppendLine("1. Exact error text/screenshot from the affected user")
$null = $sb.AppendLine("2. If community-related: community ID and screenshot of Graph 404/expected state")
$null = $sb.AppendLine("3. If role-confusion: screenshot of the Viva Engage/Yammer admin center Admins list")
$null = $sb.AppendLine("4. If external network: screenshot of any pending migration prompt in the admin center")

$sb.ToString() | Out-File $outPath -Encoding UTF8
Write-Status "Evidence written to: $outPath" "OK"
notepad $outPath
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|---------|
| Check tenant-wide sign-in gate | `Get-MgServicePrincipal -Filter "AppId eq '00000005-0000-0ff1-ce00-000000000000'"` |
| Re-enable the service principal | `Update-MgServicePrincipal -ServicePrincipalId <id> -AccountEnabled:$true` |
| Check domain verification | `Get-MgDomain -DomainId <domain>` |
| Check a user's Viva Engage roles | `Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/<userId>/employeeExperience/assignedRoles"` |
| Check M365 Group creation policy | `Get-MgBetaDirectorySetting \| Where-Object { $_.DisplayName -eq "Group.Unified" }` |
| Restrict group/community creation to a group | `Update-MgBetaDirectorySetting` on the `Group.Unified` template, set `EnableGroupCreation=False` + `GroupCreationAllowedGroupId` |
| Get a community | `GET /employeeExperience/communities/{communityId}` |
| List communities | `GET /employeeExperience/communities` |
| Create a community (async) | `POST /employeeExperience/communities` → poll `engagementAsyncOperations/{id}` |
| Delete a community | `DELETE /employeeExperience/communities/{communityId}` (cascades to Group/SharePoint/OneNote/Planner, 30-day recovery) |
| Add/remove community member | `POST` / `DELETE /groups/{groupId}/members/$ref` (via connected group) |
| Add/remove community admin | `POST` / `DELETE /groups/{groupId}/owners/$ref` (via connected group; last owner can't be removed) |
| List Viva Engage role types | `GET /employeeExperience/roles` |
| List members of a Viva Engage role | `GET /employeeExperience/roles/{roleId}/members` |
| Assign / revoke a Viva Engage role | `POST` / `DELETE /employeeExperience/roles/{roleId}/members/{userId}` |
| Restore a deleted community's group (≤30 days) | `Restore-MgDirectoryDeletedItem -DirectoryObjectId <groupObjectId>` |
| Grant Verified/Network Admin | Viva Engage/Yammer admin center → Admins → Grant Verified Admin / Grant Network Admin |
| Grant Corporate Communicator | Viva Engage admin center → Setup and configuration → Manage corporate communicators |
| Grant Answers Administrator | Entra ID → assign **Knowledge Manager** role |

---

## 🎓 Learning Pointers

- **Native Mode is now a universal, permanent state — not a per-tenant setting to check.** Microsoft retired every legacy (non-native) network on October 13, 2025. Older internal documentation, community posts, and even some still-indexed Microsoft support pages that branch on "if your network isn't Native Mode yet" describe a state that no longer exists anywhere reachable. Recognize and discount that framing on sight. [MS Docs: Overview of Native Mode](https://learn.microsoft.com/en-us/viva/engage/overview-native-mode)

- **The admin role model spans three separate assignment surfaces, and that split is permanent by design, not a migration artifact.** Global Administrator, Engage Administrator, and Answers Administrator are Entra directory roles; Verified Administrator, Network Administrator, and Corporate Communicator only exist inside the Viva Engage/Yammer admin center; Community Administrator is scoped inside a single community. Memorize the table in How It Works rather than guessing — the wrong-portal search is the single most common time-waster on Viva Engage admin tickets. [MS Docs: Manage administrator roles in Viva Engage](https://learn.microsoft.com/en-us/viva/engage/eac-key-admin-roles-permissions)

- **"Restrict community creation" is architecturally a Microsoft 365 Groups request, not a Viva Engage one.** Every community requires a connected Group, so the only lever is the tenant's `EnableGroupCreation`/`GroupCreationAllowedGroupId` policy — which also governs Teams and SharePoint-connected Group creation. Scope any client request accordingly before promising a Viva Engage-only fix that doesn't technically exist. [MS Docs: Viva Engage and Microsoft 365 Groups](https://learn.microsoft.com/en-us/viva/engage/engage-microsoft-365-groups)

- **Community deletion is one cascading operation across four services, with two independent recovery clocks.** The Group/SharePoint/OneNote/Planner bundle gets a uniform 30-day soft-delete window; conversation-level recovery is governed separately by the network's own retention setting (Delete = 30 days then permanent; Archive = indefinite). Scope any recovery conversation against both clocks explicitly, since they rarely align by coincidence. [MS Docs: Delete a community in Viva Engage](https://support.microsoft.com/en-us/office/delete-a-community-in-viva-engage-c9d19e25-ce9e-4b47-9174-baefc203793e)

- **The Viva Engage Graph API is intentionally narrow and asynchronous where it matters.** You cannot provision a community through the generic Groups API, creation itself is a polled async operation, and the whole surface is rate-limited to 10 requests per user/app per 30 seconds. Build automation around these constraints from the start rather than discovering them via failed runs against a client tenant. [MS Docs: Use the Microsoft Graph API to work with Viva Engage](https://learn.microsoft.com/en-us/graph/api/resources/engagement-api-overview?view=graph-rest-1.0)

- **External Network modernization is a separate, still-active, admin-opt-in migration — don't conflate it with the completed internal Native Mode retirement.** A client asking "why do our partners still see the old Yammer look" is describing a pending opt-in prompt, not a bug, and not the same migration that already finished for internal networks. [MS Docs: Combine multiple Viva Engage networks](https://learn.microsoft.com/en-us/viva/engage/configure-your-viva-engage-network/consolidate-multiple-viva-engage-networks)
