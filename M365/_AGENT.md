# M365 — Agent Instructions

## What's in this folder

Microsoft 365 service-level issues — Exchange Online, SharePoint, Teams, OneDrive, and licensing.

---

## Sub-modules

| Folder | Covers |
|--------|--------|
| `Exchange/` | Mail flow, hybrid coexistence, shared mailboxes, calendar permissions, spam/phishing |
| `SharePoint-OneDrive/` | Permissions, sync client, migration, storage, external sharing |
| `Teams/` | Calling plans, device policies, federation, meeting policies, guest access |
| `Licensing/` | Group-based licensing, service plan conflicts, assignment automation |
| `Copilot/` | Microsoft 365 Copilot licensing, policy, Conditional Access, and grounding/permission troubleshooting |

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

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — message trace / sign-in log / policy check → fix → validate
2. **Deep Dive** — M365 service architecture, data flow, permission model
3. **Learning Pointers** — what to study to get sharper at M365 administration
