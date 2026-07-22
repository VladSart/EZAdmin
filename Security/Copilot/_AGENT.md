# Security — Copilot (Microsoft Security Copilot) — Agent Instructions

## What's in this folder

Runbooks for **Microsoft Security Copilot** — the AI-assisted security investigation platform (standalone portal plus embedded experiences in Defender XDR, Purview, Intune, and Entra). Covers its three-layer RBAC model (Security Copilot's own Owner/Contributor roles, Microsoft Entra role inheritance, and plugin-specific service RBAC via on-behalf-of authentication), Security Compute Unit (SCU) capacity provisioning and billing, plugin/promptbook publishing scope, and multitenant/MSSP access (B2B tenant switching, GDAP, Azure Lighthouse). Targeted at L2/L3 MSP engineers handling "Copilot doesn't work / doesn't see data / ran out of capacity" tickets.

**Not to be confused with Microsoft 365 Copilot** (the productivity assistant in Word/Excel/Teams/Outlook) — a completely different product with its own licensing and RBAC. See `M365/Copilot/`.

---

## Before responding, also check

| Resource | Why |
|----------|-----|
| `M365/Copilot/Copilot-A.md` | The *other* Copilot — confirm which product a ticket actually means before troubleshooting either |
| `Security/Defender/` | Defender XDR Unified RBAC gates the Defender XDR plugin/embedded experience |
| `Security/Purview/` | Purview roles gate the Purview plugin/embedded experience and DSPM for AI overlaps with Copilot oversight generally |
| `EntraID/Troubleshooting/` | Entra role assignment mechanics underpin Copilot Owner inheritance and plugin RBAC for Entra data |
| `Intune/Troubleshooting/` | Intune RBAC gates the Intune plugin/embedded experience (Copilot in Intune) |
| `Security/ConditionalAccess/` | CA policies can additionally gate access to AI/Copilot surfaces beyond RBAC |

---

## Folder contents

| File | What it covers |
|------|---------------|
| `_AGENT.md` | This file — routing and orientation |
| `SecurityCopilot-A.md` | Deep dive — three-layer RBAC architecture, SCU capacity/billing model, multitenant access mechanisms |
| `SecurityCopilot-B.md` | Hotfix runbook for access denied, missing plugin data, SCU exhaustion, and capacity-permission gaps |
| `Scripts/Get-SecurityCopilotAccessAudit.ps1` | Read-only audit of a user's Entra role inheritance and Azure RBAC/capacity resource state |

---

## Common entry points

- "User can't access Security Copilot at all" → `SecurityCopilot-B.md` Fix 1
- "Copilot plugin shows no data / insufficient permissions" → `SecurityCopilot-B.md` Fix 2 (the #1 real-world ticket)
- "Ran out of Security Compute Units" / SCU errors → `SecurityCopilot-B.md` Fix 5
- "Admin has Security Administrator but can't change capacity" → `SecurityCopilot-B.md` Fix 4
- "Custom plugin/promptbook not visible to other users" → `SecurityCopilot-B.md` Fix 6
- "Setting up MSSP/partner access to a client's Security Copilot" → `SecurityCopilot-A.md` Remediation Playbook 4
- Architecture/design questions ("how does Copilot access data," "how is SCU billed") → `SecurityCopilot-A.md`

---

## Key diagnostic commands

```powershell
# Entra directory roles (Copilot Owner inheritance check)
Get-MgUserMemberOf -UserId "<user@domain.com>" | Select-Object -ExpandProperty AdditionalProperties

# Azure RBAC at subscription scope (capacity management requirement)
Get-AzRoleAssignment -SignInName "<user@domain.com>" -Scope "/subscriptions/<sub-id>"

# SCU capacity resource
Get-AzResource -ResourceType "Microsoft.SecurityCopilot/capacities" -ExpandProperties
```

---

## Key dependency chain

```
Copilot Owner/Contributor (Security Copilot's own RBAC)
        │
SCU capacity available (auto for M365 E5/E7, else manual — needs Azure Contributor/Owner + Entra Security Admin+)
        │
Session/embedded experience reached
        │
Plugin invoked — on-behalf-of auth against the plugin's OWN service RBAC (Sentinel/Intune/Defender XDR/Purview)
        │
Result bounded by the most restrictive layer
```

---

## Response format reminder

Always respond in three layers: (1) a fast Mode B fix path for an active ticket, (2) the Mode A architectural "why" if the user wants to understand root cause, (3) a Learning Pointer connecting the finding to the broader RBAC/capacity pattern documented here.
