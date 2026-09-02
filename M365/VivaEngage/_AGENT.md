# Viva Engage (Yammer) — Agent Instructions

## What's in this folder

Viva Engage (formerly Yammer) — the tenant-wide service-principal sign-in gate, the now-universal Native Mode architecture (community ↔ connected Microsoft 365 Group ↔ SharePoint/OneNote/Planner backing services, since the October 13, 2025 legacy-network retirement), the 7-role admin model across its 3 real assignment surfaces (Entra ID, the Viva Engage/Yammer admin center, and per-community), community-creation gating via the Microsoft 365 Group creation policy (not a Viva Engage-specific setting), community lifecycle/recovery, domain-gated network access, and the Microsoft Graph `/employeeExperience` API surface with its rate limits. Distinct from `Security/Purview/CommunicationCompliance-*.md`/`RetentionLabels-*.md`, which own the Purview-side policy mechanics for Viva Engage as a monitored channel.

---

## Before responding, also check

- `M365/_AGENT.md` — general M365 agent context and cross-service dependencies
- `Security/Purview/CommunicationCompliance-B.md` / `RetentionLabels-B.md` — for Purview-side policy mechanics monitoring Viva Engage as a channel
- `EntraID/Troubleshooting/` — for domain verification and Microsoft 365 Group creation policy issues (the actual gate behind "Create Community")
- `M365/SharePoint-OneDrive/_AGENT.md` — communities auto-provision a connected SharePoint site; escalate storage-layer issues there

---

## Folder contents

| File | What it covers |
|------|---------------|
| `VivaEngage-B.md` | Hotfix runbook — diagnose and resolve in under 10 min: sign-in "bad request" errors, missing Create Community option, network visibility gaps, community recovery, role-assignment confusion, Graph automation failures, external-network legacy experience, Communication Compliance zero-match |
| `VivaEngage-A.md` | Deep dive reference — full architecture (universal Native Mode, community→Group→backing-services chain, async community creation, 7-role model and its 3 assignment surfaces, domain-gated access, Graph role management, API rate limiting) |
| `Scripts/Get-VivaEngageAdminAudit.ps1` | Graph script — tenant-wide service principal gate, Group creation policy, domain verification summary, optional per-user role checks |

---

## Common entry points

- "Sign-in error clicking the Viva Engage tile ('bad request')" → `VivaEngage-B.md` Fix 1
- "No 'Create Community' option appears for anyone in the tenant" → `VivaEngage-B.md` Fix 2 — this is a Microsoft 365 Group creation policy setting, not a Viva Engage one
- "A user or entire department can't see the internal network" → `VivaEngage-B.md` Fix 3 — domain-gated access
- "We accidentally deleted a community" → `VivaEngage-B.md` Fix 4 — 30-day recovery window
- "Someone was made Verified Admin/Network Admin/Corporate Communicator but I can't find that role in Entra ID" → `VivaEngage-B.md` Fix 5 — these roles only exist in the Viva Engage/Yammer admin center
- "Automating community management via Graph fails with 404 or 429" → `VivaEngage-B.md` Fix 6 — rate limit, Native Mode requirement
- "External network partners see an outdated/legacy experience" → `VivaEngage-B.md` Fix 7
- "Our Communication Compliance/retention policy shows zero Viva Engage matches" → `VivaEngage-B.md` Fix 8 — cross-reference Purview docs
- "How does the community→Group→backing-services chain actually work?" → `VivaEngage-A.md` § How It Works
- "Audit tenant-wide Viva Engage access and role state" → `Scripts/Get-VivaEngageAdminAudit.ps1`

---

## Key diagnostic commands

```powershell
Connect-MgGraph -Scopes "Application.Read.All","Directory.Read.All","User.Read.All"

# Confirm the Viva Engage (Yammer) service principal is enabled — gates sign-in/tile
# access for the ENTIRE tenant, not just one user
Get-MgServicePrincipal -Filter "AppId eq '00000005-0000-0ff1-ce00-000000000000'" |
    Select-Object DisplayName, AppId, AccountEnabled, Id

# Confirm the affected user's mailbox/UPN domain is a verified M365 domain
# (home-network access is domain-gated)
Get-MgDomain | Select-Object Id, IsVerified, IsDefault

# Confirm the affected user's assigned Viva Engage roles (Engage/Verified/Network/
# Answers/Corporate Communicator — NOT the same list as Entra roles)
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/users/<userId>/employeeExperience/assignedRoles"

# If the ticket is about community creation, confirm the Microsoft 365 Group
# creation policy — this is what actually gates the "Create Community" button
Get-MgBetaDirectorySetting | Where-Object { $_.DisplayName -eq "Group.Unified" } |
    Select-Object -ExpandProperty Values
```

---

## Key dependency chain

```
Entra ID tenant + verified domain(s)
    │
M365 license covering the user (any Business/Enterprise/EDU SKU includes Viva
Engage Core; Viva Suite or standalone add-on required for Premium features)
    │
Viva Engage (Yammer) service principal ENABLED (tenant-wide, all-or-nothing gate)
    │
Native Mode network (universal since Oct 13, 2025 legacy-network retirement)
    │
Microsoft 365 Group creation policy — gates the "Create Community" button;
an Entra ID / M365 Groups setting, NOT a Viva Engage-specific one
    │
Community created → auto-provisions: connected M365 Group, SharePoint site,
OneNote notebook, Planner plan
    │
Admin role model (Global Admin > Engage Admin > Verified Admin > Network Admin
> Corporate Communicator; Community Admin is scoped to one community)
    │
Microsoft Graph /employeeExperience/* endpoints — automation layer, Native
Mode networks only, 10 req/user/app/30s rate limit
```

---

## Response format reminder (always 3 layers)

1. **Triage first** — is it the tenant-wide service principal, domain verification, community-creation policy, or a role-assignment misunderstanding?
2. **Fix the specific failure** — use the matching fix path from the B runbook
3. **Confirm resolution** — verify sign-in/tile access, or confirm the community/role state in the Viva Engage admin center
