# M365 — Agent Instructions

## What's in this folder

Microsoft 365 service-level issues — Exchange Online, SharePoint, Teams, OneDrive, licensing, and the Microsoft 365 Apps desktop client stack.

---

## Sub-modules

| Folder | Covers |
|--------|--------|
| `Exchange/` | Mail flow, hybrid coexistence, shared mailboxes, calendar permissions, spam/phishing |
| `SharePoint-OneDrive/` | Permissions, sync client, migration, storage, external sharing |
| `Teams/` | Calling plans, device policies, federation, meeting policies, guest access |
| `Licensing/` | Group-based licensing, service plan conflicts, assignment automation |
| `Copilot/` | Microsoft 365 Copilot licensing, policy, Conditional Access, and grounding/permission troubleshooting (`Copilot-A/B.md`); agent lifecycle governance — Registry/Requests approval, ownership, risk signals, and the distinct admin surfaces per creation platform (Copilot Studio, Agent Builder, SharePoint, Foundry) — in `AgentGovernance-A/B.md` |
| `UniversalPrint/` | Printer connector, printer shares, driverless print job diagnostics |
| `Backup/` | Microsoft 365 Backup — protection policies/units, restore points, restore sessions, coverage-gap detection for SharePoint/OneDrive/Exchange |
| `Apps/` | Microsoft 365 Apps desktop client stack — Click-to-Run install architecture, Office Deployment Tool, update channels (Current/Monthly Enterprise/Semi-Annual Enterprise), Shared Computer Activation and client-level activation/licensing. Distinct from `Exchange/Outlook-Client-*.md` (Outlook-specific profile/Autodiscover issues) and `Licensing/` (Entra ID license assignment) |

---

## Before responding, also check

- `EntraID/` — almost all M365 access issues trace back to Entra identity
- `Security/ConditionalAccess/` — CA policies block M365 app access
- `PowerAutomate/` — if automation of M365 workloads is involved

---

## Key diagnostic approaches

```powershell
# Exchange Online connectivity + mail flow
Connect-ExchangeOnline
Get-MessageTrace -SenderAddress <sender> -StartDate (Get-Date).AddDays(-2) -EndDate (Get-Date)

# SharePoint/OneDrive sharing settings
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
Get-SPOTenant | Select SharingCapability, ExternalServicesEnabled

# Teams policy check
Connect-MicrosoftTeams
Get-CsUserPolicyAssignment -Identity <UPN>

# Licensing check
Connect-MgGraph -Scopes "User.Read.All"
Get-MgUserLicenseDetail -UserId <UPN> | Select SkuPartNumber
```

---

## Common entry points

- "User not receiving emails" → `Exchange/Mail-Flow-B.md`
- "External sharing blocked" → `SharePoint-OneDrive/` + tenant sharing settings
- "OneDrive sync errors" → `SharePoint-OneDrive/Sync-Issues-B.md`
- "Teams calling not working" → `Teams/Calling-B.md`
- "User missing a feature (Teams, SharePoint)" → `Licensing/` — check service plan assignment
- "Can't restore a deleted/overwritten site, OneDrive, or mailbox" → `Backup/M365-Backup-B.md`
- "Are we missing backup coverage anywhere" → `Backup/Scripts/Get-M365BackupCoverageAudit.ps1`
- "Office won't update / stuck on wrong update channel / GPO seems to override my change" → `Apps/Deployment-UpdateChannels-B.md` + `Apps/Scripts/Get-M365AppsHealth.ps1`
- "Office activation failing / Unlicensed on a shared or kiosk device" → `Apps/Deployment-UpdateChannels-B.md` (Shared Computer Activation)
- "Click-to-Run repair dialog does nothing" → `Apps/Deployment-UpdateChannels-B.md` Fix 3
- "A Copilot agent is stuck pending approval / has no owner / is flagged at risk" → `Copilot/AgentGovernance-B.md`
- "Our Copilot Studio agent works fine there but won't show up in Teams/M365 Copilot" → `Copilot/AgentGovernance-B.md` Fix 5

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — message trace / sign-in log / policy check → fix → validate
2. **Deep Dive** — M365 service architecture, data flow, permission model
3. **Learning Pointers** — what to study to get sharper at M365 administration
