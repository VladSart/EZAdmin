# Microsoft 365 Copilot — Agent Instructions

## What's in this folder

Microsoft 365 Copilot licensing, enablement, policy, and grounding/permission troubleshooting — covers Word, Excel, PowerPoint, Outlook, and Teams Copilot experiences. Also covers **agent lifecycle governance** (approval, publishing, ownership, risk, access) for agents surfaced through Copilot — declarative agents, Copilot Studio agents, Agent Builder agents, SharePoint agents, and Frontier agents. For Copilot Studio's own security/governance controls (per-agent authentication, DLP, CMK), see `PowerAutomate/PowerApps/CopilotStudio-Security-A.md`/`-B.md` instead.

---

## Before responding, also check

- `M365/_AGENT.md` — general M365 agent context and cross-service dependencies
- `M365/Licensing/` — if the issue is a broader license assignment/group-based licensing problem, not Copilot-specific
- `M365/SharePoint-OneDrive/Permissions-B.md` — Copilot grounding failures are frequently SharePoint/OneDrive permission issues, not Copilot bugs
- `Security/ConditionalAccess/` — if sign-in to the Copilot app is being blocked
- `Security/Purview/DLP-Policy-B.md` — if Copilot activity is being restricted by a DLP policy on sensitive content

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Copilot-B.md` | Hotfix runbook — license/policy/CA/grounding triage, diagnosis, and fix paths in under 10 minutes |
| `Copilot-A.md` | Deep-dive reference — full architecture, Symptom → Cause map, phased troubleshooting, remediation playbooks |
| `AgentGovernance-B.md` | Hotfix runbook — agent lifecycle governance triage (approval, publishing, ownership, risk, access) across declarative agents, Copilot Studio agents, Agent Builder agents, SharePoint agents, and Frontier agents. Assumes base Copilot already works |
| `AgentGovernance-A.md` | Deep-dive reference — full agent governance architecture, Symptom → Cause map, phased troubleshooting, remediation playbooks |
| `Scripts/Get-CopilotUsageReport.ps1` | Read-only tenant report: Copilot SKU pool, per-user license health (flags Copilot-without-base-license), Teams Copilot policy summary |

---

## Common entry points

- "User doesn't have Copilot" → `Copilot-B.md` § Triage — check license stack (base + add-on)
- "Copilot doesn't know about my files" → `Copilot-B.md` § Fix 4 — grounding/permission gap, check SharePoint/OneDrive permissions first
- "Copilot missing from Word/Excel/Outlook ribbon" → `Copilot-B.md` § Fix 1/2 — license propagation or base license missing
- "Copilot blocked entirely, can't sign in to it" → `Copilot-B.md` § Fix 5 — Conditional Access scoping
- "We just tightened SharePoint sharing and now Copilot answers got worse" → `Copilot-B.md` § Learning Pointers — expected behavior, not a bug
- "Who approved this agent / who owns it / can end users publish their own agents" → `AgentGovernance-B.md` § Triage — agent lifecycle governance, not a licensing issue

---

## Key diagnostic commands

```powershell
# Confirm license stack
Connect-MgGraph -Scopes "User.Read.All"
Get-MgUserLicenseDetail -UserId '<UPN>' | Select-Object SkuPartNumber

# Confirm tenant/policy enablement
Connect-MicrosoftTeams
Get-CsTeamsCopilotPolicy -Identity Global

# Confirm no Conditional Access block
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>' and appDisplayName eq 'Microsoft 365 Copilot'" -Top 5 |
    Select-Object CreatedDateTime, ConditionalAccessStatus

# Confirm SharePoint/OneDrive permission on a specific grounding document
Connect-MgGraph -Scopes "Sites.Read.All"
Get-MgSitePermission -SiteId '<SiteId>'
```

---

## Key dependency chain

```
Base M365 license (E3/E5/Business Premium) →
  Microsoft 365 Copilot add-on license →
    Tenant-level Copilot enablement →
      App-specific Copilot policy (not disabled for user's group) →
        Conditional Access allows the Copilot service principal →
          User's actual Graph/SharePoint/Exchange permissions →
            Content indexed by Microsoft Search / Semantic Index →
              Copilot returns a grounded answer
```

---

## Response format reminder (always 3 layers)

1. **Triage first** — is it license, policy, Conditional Access, or grounding/permissions?
2. **Fix the specific failure** — use the matching fix path from `Copilot-B.md`
3. **Confirm resolution** — have the user re-test the same prompt/document that originally failed; confirm Copilot appears in the app ribbon after a client restart
