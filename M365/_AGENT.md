# M365 — Agent Instructions

## What's in this folder

Microsoft 365 service-level issues — Exchange Online, SharePoint, Teams, OneDrive, licensing, and the Microsoft 365 Apps desktop client stack.

---

## Sub-modules

| Folder | Covers |
|--------|--------|
| `Exchange/` | Mail flow, hybrid coexistence, shared mailboxes, calendar permissions, spam/phishing; also covers mailbox migration batch mechanics — Cutover, Staged, IMAP, Remote Move, and Cross-tenant (`MigrationBatches-A/B.md`) — distinct from steady-state hybrid coexistence/routing (`Hybrid-Coexistence-A/B.md`) |
| `SharePoint-OneDrive/` | Permissions, sync client, migration, storage, external sharing |
| `Teams/` | Calling plans, device policies, federation, meeting policies, guest access |
| `Licensing/` | Group-based licensing, service plan conflicts, assignment automation |
| `Copilot/` | Microsoft 365 Copilot licensing, policy, Conditional Access, and grounding/permission troubleshooting (`Copilot-A/B.md`); agent lifecycle governance — Registry/Requests approval, ownership, risk signals, and the distinct admin surfaces per creation platform (Copilot Studio, Agent Builder, SharePoint, Foundry) — in `AgentGovernance-A/B.md` |
| `UniversalPrint/` | Printer connector, printer shares, driverless print job diagnostics; also covers migrating OFF an on-premises print server ONTO Universal Print (`UP-Migration-A/B.md`) — distinct from steady-state UP operation and from server-to-server print migration (`Windows/Troubleshooting/PrintServerMigration-A/B.md`) |
| `Backup/` | Microsoft 365 Backup — protection policies/units, restore points, restore sessions, coverage-gap detection for SharePoint/OneDrive/Exchange |
| `Apps/` | Microsoft 365 Apps desktop client stack — Click-to-Run install architecture, Office Deployment Tool, update channels (Current/Monthly Enterprise/Semi-Annual Enterprise), Shared Computer Activation and client-level activation/licensing. Distinct from `Exchange/Outlook-Client-*.md` (Outlook-specific profile/Autodiscover issues) and `Licensing/` (Entra ID license assignment) |
| `VivaEngage/` | Viva Engage (Yammer) — the tenant-wide service-principal sign-in gate, Native Mode architecture (community ↔ connected M365 Group ↔ SharePoint/OneNote/Planner), the 7-role admin model across its 3 real assignment surfaces (Entra ID / Viva Engage-Yammer admin center / per-community), community-creation gating via the M365 Group creation policy, and the Microsoft Graph `/employeeExperience` API surface. Distinct from `Security/Purview/CommunicationCompliance-*.md`/`RetentionLabels-*.md`, which own the Purview-side policy mechanics for Viva Engage as a monitored channel |
| `Places/` | Microsoft Places — the hybrid-workplace app (desk/room booking, work plans, Places Finder/Explorer) embedded in Teams and Outlook, architecturally layered on top of (not a replacement for) Exchange Online room/workspace mailboxes; the strict Building>Floor>Section>Room/Workspace/Desk directory hierarchy and its asymmetric parenting rule (Workspace/Desk objects must parent to a Section, Rooms don't), the tenant-wide `EnableBuildings` visibility gate, the three-role RBAC model split across Entra ID (Places Administrator) and Exchange RBAC (Places Building/Desk Administrator), and the April 1, 2026 licensing unbundling (Teams Premium → per-space MTR/MTSS/MTSS-SS license model). Requires PowerShell 7.4+ for the `MicrosoftPlaces` module — a deliberate exception to this repo's usual PS 5.1-compatible scripting convention |

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
- "We're decommissioning our print server and moving to Universal Print" → `UniversalPrint/UP-Migration-A.md`
- "Migration to Universal Print is 'done' but users still see the old printer / can't find the new one" → `UniversalPrint/UP-Migration-B.md`
- "Nobody can sign in to Viva Engage / Yammer, getting a 'bad request' error" → `VivaEngage/VivaEngage-B.md` Fix 1 (tenant-wide service principal gate)
- "No 'Create Community' option anywhere in Viva Engage" → `VivaEngage/VivaEngage-B.md` Fix 2 (this is an M365 Group creation policy setting, not a Viva Engage one)
- "Someone was made Verified Admin / Network Admin but I can't find that role in Entra ID" → `VivaEngage/VivaEngage-B.md` Fix 5 (these roles only exist in the Viva Engage/Yammer admin center)
- "We accidentally deleted a Viva Engage community" → `VivaEngage/VivaEngage-B.md` Fix 4 (30-day recovery window)
- "Our Communication Compliance/retention policy shows zero Viva Engage matches" → `VivaEngage/VivaEngage-B.md` Fix 8 + cross-reference `Security/Purview/CommunicationCompliance-B.md`/`RetentionLabels-B.md`
- "We built our building/floor hierarchy in Places but nobody can see it" → `Places/Places-B.md` Fix 2 (tenant-wide `EnableBuildings` setting, off by default — separate from hierarchy correctness)
- "Desk pool is configured but won't show up for booking" → `Places/Places-B.md` Fix 5 (workspaces must parent to a Section, not just a Floor — silent failure, no error)
- "MicrosoftPlaces PowerShell module won't install / cmdlets not found" → `Places/Places-B.md` Fix 1 (requires PowerShell 7.4+, will not load on Windows PowerShell 5.1)
- "User could book any desk before, now they can't" → `Places/Places-B.md` Fix 6 (April 1, 2026 licensing unbundling — per-space MTR/MTSS/MTSS-SS license now required, unless still inside a legacy Teams Premium grace period)
- "Room shows fine in Places Management portal but missing from Outlook Room Finder" → `Places/Places-B.md` Fix 4 (RoomList membership is a separate, Exchange-side gate from Places directory placement)
- "Places Building/Desk Administrator can't create a room or rename one" → `Places/Places-B.md` Fix 9 (permanent role-boundary restriction, not a misconfiguration)

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — message trace / sign-in log / policy check → fix → validate
2. **Deep Dive** — M365 service architecture, data flow, permission model
3. **Learning Pointers** — what to study to get sharper at M365 administration
