# Microsoft Planner — Agent Instructions

## What's in this folder

Microsoft Planner — one brand covering two architecturally separate products with three independent admin surfaces: Basic plans (Group- or groupless-Roster-backed, controlled by the non-standard, separately-downloaded `PlannerTenantAdmin` PowerShell module, Global Administrator only) versus Premium plans (formerly the standalone "Project for the web," retired as its own app August 2025 with zero migration required, Dataverse-backed inside a Power Platform Environment, controlled only via the M365 admin center's Project org-settings page). Covers the Dataverse environment dependencies unique to Premium, Roster container lifecycle, broad-by-default Basic-plan guest permissions, the Exchange/SharePoint-dependency quirk in mobile Conditional Access enforcement, and the critical, easily-conflated distinction between Project for the web's already-completed retirement (folded into Planner, no action needed) and Project Online's genuinely separate, imminent September 30, 2026 retirement (real migration required, zero shared infrastructure with Planner).

---

## Before responding, also check

- `M365/_AGENT.md` — general M365 agent context and cross-service dependencies
- `M365/Loop/_AGENT.md` — if the ticket is about the Planner Loop component (inline plan view/edit in Outlook/Teams/Loop), governed by Cloud Policy, not either Planner admin toggle
- `M365/Copilot/_AGENT.md` — Copilot in Planner (Premium only) requires a Copilot license on top of Planner Plan 1/3/5
- `PowerAutomate/Troubleshooting/DLP-Policies-*.md` — general Power Platform DLP mechanics that the Roadmap connector workaround sits on top of
- `EntraID/Troubleshooting/` — for the Microsoft 365 Group creation policy that gates new Basic-plan creation

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Planner-B.md` | Hotfix runbook — diagnose and resolve in under 10 min: module-not-found, three-independent-switches confusion, license removal not locking content, Dataverse gate, Roster creation, guest permissions, mobile CA, Project Online vs. Project for the web confusion, calendar sync link concerns |
| `Planner-A.md` | Deep dive reference — full architecture (one brand, two products, three admin surfaces), Basic vs. Premium storage/licensing, Dataverse environment dependencies, guest/CA defaults, the two retirements that are not the same event |
| `Scripts/Get-PlannerAdminAudit.ps1` | Graph/PowerShell script — cross-checks Basic-plan tenant config, Premium service-plan assignment, and Roster-backed plan inventory |

---

## Common entry points

- "`Set-PlannerConfiguration`/`Get-PlannerConfiguration` command not found" → `Planner-B.md` Fix 1 — not a Graph/EXO/SPO module; a separately-downloaded ZIP requiring MSAL.PS, a manual file-unblock step, and Global Admin sign-in
- "We turned off Planner but Premium/Project plans (or the Loop component) still work" → `Planner-B.md` Fix 2 — three independent switches; none is a superset of another
- "Removed a user's Planner license but they can still edit their plans" → `Planner-B.md` Fix 3 — no supported full-lockout mechanism for existing content; check Microsoft 365 Group membership instead
- "User with a valid Premium license can't create a Project/Timeline plan" → `Planner-B.md` Fix 4 — check the Dataverse environment's "Enable D365 Apps" toggle and Production-environment license minimum
- "Roster-backed plans keep appearing after disabling Roster creation" → `Planner-B.md` Fix 5
- "Guest user edited/deleted content in a Basic plan unexpectedly" → `Planner-B.md` Fix 6 — broad guest defaults by design; adjust at the Microsoft 365 Group guest-access layer
- "CA policy scoped to Planner isn't enforced on the mobile app" → `Planner-B.md` Fix 7 — only applies if the same policy also targets Exchange Online or SharePoint Online
- "Client is panicking that Planner is shutting down" → `Planner-B.md` Fix 8 — almost certainly confusing Project Online (retiring Sept 30, 2026, real migration needed) with Project for the web (already folded in, no action needed)
- "Security review flags Planner's Outlook calendar sync links" → `Planner-B.md` Fix 9
- "How does Basic vs. Premium Planner actually work?" → `Planner-A.md` § How It Works
- "Audit tenant-wide Planner configuration and licensing" → `Scripts/Get-PlannerAdminAudit.ps1`

---

## Key diagnostic commands

```powershell
# Basic-plan tenant configuration (requires the special PlannerTenantAdmin module)
Get-PlannerConfiguration
# Returns: IsPlannerAllowed, AllowCalendarSharing, AllowRosterCreation

# Premium (Project for the web / Dataverse-backed) service plan state for a user —
# confirms the PROJECT_P1/PROJECT_PROFESSIONAL service plan is enabled, not just the SKU
Get-MgUserLicenseDetail -UserId <UPN> |
    Select-Object -ExpandProperty ServicePlans |
    Where-Object ServicePlanName -match "PROJECT_P1|PROJECT_PROFESSIONAL|PROJECTWORKMANAGEMENT"

# Confirm the Dataverse Default Environment exists and isn't blocked by the D365-apps gate
# (Power Platform admin center → Environments → Default Environment → Details — manual check,
# no reliable PowerShell one-liner across tenant configurations)

# Confirm which Microsoft 365 Group creation policy governs who can create a NEW Basic plan
Get-MgBetaDirectorySetting | Where-Object DisplayName -EQ "Group.Unified" |
    Select-Object -ExpandProperty Values

# List Roster-backed (groupless) plans a user owns
Get-MgPlannerPlan -Filter "owner eq '<groupOrRosterId>'" -ErrorAction SilentlyContinue
```

---

## Key dependency chain

```
Microsoft 365 subscription with a Planner-inclusive SKU
    │
    ├── BASIC PLANS (classic Planner)
    │     Controlled by: Set-PlannerConfiguration (PlannerTenantAdmin module, not PS Gallery)
    │     Backing container: Microsoft 365 Group (default) OR groupless Roster
    │     Group creation gated by EntraID's Group.Unified directory setting
    │
    ├── PREMIUM PLANS (formerly "Project for the web", folded in Aug 2025)
    │     Controlled by: M365 admin center → Org Settings → Project (NO PowerShell equivalent)
    │     Storage: Dataverse, inside a Power Platform Environment
    │       (Production environments require ≥5 Project licenses; "Enable D365 Apps" must be OFF)
    │
    └── PLANNER LOOP COMPONENT
          Controlled by: Cloud Policy (config.office.com) — separate from both switches above
    │
    ▼
Microsoft 365 Copilot in Planner (Premium only) — additional license layer
    │
    ▼
UNRELATED PRODUCT SHARING NO INFRASTRUCTURE:
Project Online — retiring Sept 30, 2026; its on/off toggle has zero effect on Planner
```

---

## Response format reminder (always 3 layers)

1. **Triage first** — Basic or Premium? Which of the three independent switches is actually in play?
2. **Fix the specific failure** — use the matching fix path from the B runbook
3. **Confirm resolution** — verify plan creation/access in the correct surface (Planner app for Basic, planner.cloud.microsoft for Premium); for Project Online confusion, confirm the client understands the two are unrelated
