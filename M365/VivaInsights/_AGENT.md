# Viva Insights — Agent Instructions

## What's in this folder

Viva Insights — the dual-model architecture splitting Personal insights (private, per-user, processed/stored inside the employee's own Exchange mailbox, never admin-visible) from Organizational insights (admin-configured, aggregated, de-identified: Copilot Dashboard, Agent Dashboard, Consumption Dashboard, advanced analysis). Covers the four-surface admin/access model (Insights Administrator and Insights Analyst are real Entra directory roles; AI Administrator can manage most settings but does not get automatic web-app access; Manager and Group Manager are Viva-native only and never appear in Entra/PIM), Viva Feature Access Management (VFAM) as the current, sole control surface for Copilot/Agent Dashboard access, the two independent Minimum group size configuration surfaces split by license state, the tenant default-on/off setting vs. the separate end-user opt-out control, licensing paths, and GDPR/data-subject-rights handling.

---

## Before responding, also check

- `M365/_AGENT.md` — general M365 agent context and cross-service dependencies
- `M365/Copilot/_AGENT.md` — Copilot licensing/CA/grounding broadly, not Viva Insights' own admin model (though a Copilot license bundles both Personal and Organizational insights automatically)
- `EntraID/Troubleshooting/` — for Insights Administrator/Insights Analyst role assignment (true Entra roles, PIM-eligible)
- `Security/Purview/` — for GDPR/data-subject-request mechanics beyond the Viva Insights-specific opt-out controls

---

## Folder contents

| File | What it covers |
|------|---------------|
| `VivaInsights-B.md` | Hotfix runbook — diagnose and resolve in under 10 min: no team/org insights visible, role confusion (Manager/Group Manager aren't Entra roles), Copilot Dashboard access broken after "old way" setup, minimum group size mismatch, personal insights opt-out, propagation delay, Partitions reversal, AI Administrator missing web-app access, Agent Dashboard missing |
| `VivaInsights-A.md` | Deep dive reference — full architecture (two products/one brand, personal vs. organizational data models, four admin surfaces, two aggregation thresholds, VFAM replacing legacy Copilot Dashboard controls, licensing paths, GDPR) |
| `Scripts/Get-VivaInsightsAdminAudit.ps1` | Graph/EXO script — Entra-native role membership, VFAM state for the web app and Agent Dashboard, optional per-user checks |

---

## Common entry points

- "A manager or leader can't see any team/organization insights" → `VivaInsights-B.md` Fix 1 — team size below the Minimum team size threshold; no PowerShell read, check via Manager hierarchy search
- "Someone was told they're an 'Insights Admin'/'Group Manager' but the role isn't showing up in Entra ID or PIM" → `VivaInsights-B.md` Fix 2 — Manager and Group Manager are NOT Entra roles, Viva-native only
- "Copilot Dashboard access stopped working after being set up 'the old way'" → `VivaInsights-B.md` Fix 3 — the old admin-center toggle and pre-VFAM PowerShell are retired; VFAM is now the only path
- "Minimum group size looks different in two different places" → `VivaInsights-B.md` Fix 4 — two independent settings, split by whether the tenant holds a Viva Insights license
- "End user says personal insights/digest/add-in stopped working, or wants out entirely" → `VivaInsights-B.md` Fix 5
- "A setting was changed and the dashboard/report still shows the old state" → `VivaInsights-B.md` Fix 6 — check the propagation-delay table (up to 7 days for privacy settings)
- "Partitions was turned on and now needs to be turned back off" → `VivaInsights-B.md` Fix 7 — one-way setting, Microsoft Support only
- "AI Administrator was assigned the role but still can't open the Viva Insights web app" → `VivaInsights-B.md` Fix 8 — the role doesn't grant itself automatic web app access
- "Agent Dashboard is missing or shows nothing" → `VivaInsights-B.md` Fix 9 — requires both the web app control AND its own separate VFAM control
- "How does the Personal vs. Organizational insights model actually work?" → `VivaInsights-A.md` § How It Works
- "Audit tenant-wide role/VFAM state" → `Scripts/Get-VivaInsightsAdminAudit.ps1`

---

## Key diagnostic commands

```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory","User.Read.All"

# Confirm whether the requester should be an Entra-native Viva Insights admin
# (Insights Administrator/Insights Analyst are real, PIM-eligible Entra roles;
# Manager and Group Manager are NOT)
Get-MgDirectoryRole -Filter "DisplayName eq 'Insights Administrator'" | Get-MgDirectoryRoleMember

# Confirm current Viva Feature Access Management (VFAM) state for the Viva Insights
# web app — gates Copilot Dashboard, Agent Dashboard, and advanced analysis access
Connect-ExchangeOnline
Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app"

# "A manager can't see their team" — confirm against Minimum team size (checked
# in the Viva Insights web app → Manager settings → Manager hierarchy; no
# Graph/PowerShell read exists for this)

# "A dashboard/setting change hasn't shown up yet" — check the propagation-delay
# table (Fix 6) before assuming the change failed
```

---

## Key dependency chain

```
Entra ID tenant
    │
M365 license
    ├─ E3/E5 core SKU → Personal insights only
    ├─ Microsoft 365 Copilot license → Personal AND Organizational insights bundled
    └─ Standalone Viva Insights add-on / Viva Suite → Organizational insights
         without requiring a Copilot license
    │
    ├── PERSONAL INSIGHTS (per-user, private)
    │     Stored inside the user's OWN Exchange Online mailbox — no admin,
    │     manager, or analyst can see this data through any normal surface
    │     End-user opt-out is a SEPARATE control from the tenant default-on/off
    │
    └── ORGANIZATIONAL INSIGHTS (admin-configured, aggregated)
          Viva Insights web app — single on/off gate for Copilot Dashboard +
          Agent Dashboard + Consumption Dashboard + advanced analysis, via VFAM
              │
          Admin role model — 4 real surfaces: Insights Administrator, Insights
          Analyst (both true Entra roles), AI Administrator (manages settings,
          no automatic web-app access), Manager/Group Manager (Viva-native only)
              │
          Minimum team size (≥5) → gates manager visibility entirely
          Minimum group size (≥5/10) → gates specific data-point suppression
          Privacy settings (Partitions, keyword/domain suppression) → up to 7-day propagation
```

---

## Response format reminder (always 3 layers)

1. **Triage first** — Personal or Organizational branch? Which of the four admin surfaces is actually in play?
2. **Fix the specific failure** — use the matching fix path from the B runbook; most role-confusion tickets resolve by explaining the Entra-role vs. Viva-native-role split (Fix 2)
3. **Confirm resolution** — verify in the correct surface (personal app for Personal insights, Viva Insights web app/Copilot Dashboard for Organizational); allow up to 7 days for privacy-setting propagation before re-escalating
