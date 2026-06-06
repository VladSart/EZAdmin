# Power Automate — Agent Instructions

## What's in this folder

Microsoft Power Automate (formerly Microsoft Flow) — cloud flows, desktop flows, and their integration with the Microsoft 365 ecosystem.

This module focuses on what MSPs actually use Power Automate for:
- **SharePoint site provisioning** — creating sites, applying templates, setting default libraries
- **SharePoint permission management** — breaking inheritance, assigning roles, managing groups
- **M365 Group and Teams provisioning** — automated workspace creation with governance
- **Approval workflows** — routing requests before provisioning
- **Connector troubleshooting** — auth failures, throttling, licence issues
- **Flow governance** — DLP policies, environment management, licence requirements

---

## Before responding, also check

- `M365/SharePoint-OneDrive/` — if the issue is in SharePoint itself, not the flow
- `EntraID/` — if connector auth is failing (OAuth, service principal, permissions)
- `EntraID/Graph/` — for flows using HTTP/Graph API actions
- `Intune/` — if Power Automate Desktop flows are deployed via Intune

---

## Folder contents

| File | What it covers |
|------|---------------|
| `SharePoint/SharePoint-Site-Provisioning-B.md` | Hotfix: site creation flows broken |
| `SharePoint/SharePoint-Site-Provisioning-A.md` | Deep dive: site provisioning architecture, permissions model |
| `SharePoint/Permission-Management-B.md` | Hotfix: permission flows failing |
| `Troubleshooting/Connector-Auth-B.md` | Hotfix: connector auth failures, token expiry |
| `Troubleshooting/Throttling-Limits-B.md` | Hotfix: 429 throttling, flow run quotas |
| `Scripts/New-SharePointSiteViaGraph.ps1` | PS equivalent: create SP site via Graph (for when Flow won't do it) |
| `Scripts/Set-SharePointSitePermissions.ps1` | PS: assign/remove site permissions at scale |

---

## Common entry points

- "Flow to create SharePoint site is failing" → `SharePoint/SharePoint-Site-Provisioning-B.md`
- "Permission assignment step in flow throws 403" → `SharePoint/Permission-Management-B.md`, check service account permissions
- "Flow shows 'Connection requires attention'" → `Troubleshooting/Connector-Auth-B.md`
- "Flow runs but SharePoint site wasn't created" → `SharePoint/SharePoint-Site-Provisioning-A.md` (timing/async issues)
- "Getting 429 errors or flow suspended" → `Troubleshooting/Throttling-Limits-B.md`
- "Need to build a site creation flow from scratch" → `SharePoint/SharePoint-Site-Provisioning-A.md`
- "DLP policy blocking connector" → `EntraID/` (environment admin controls DLP)

---

## Key dependencies for Power Automate flows

```
[Flow trigger] → [Connection/Connector] → [Licensed user or service principal]
      ↓                     ↓                           ↓
  Runs in          OAuth token valid            Power Automate licence
  Environment      (expires, needs refresh)     (Per-user / Per-flow / E3/E5)
      ↓
  Actions execute → SharePoint/Graph API → App permissions or delegated
      ↓
  Throttle limits apply:
    SharePoint REST: 200 req/sec per tenant
    Graph API: 10k req/10min per app
    Power Automate: depends on licence tier
```

---

## Licence requirements (common confusion)

| Feature | Minimum licence |
|---------|----------------|
| Basic automated flows | Microsoft 365 E3/E5 (seeded) |
| Premium connectors (SQL, Azure, etc.) | Power Automate Premium |
| Per-flow licence | Power Automate per-flow plan |
| Unattended desktop flows | Power Automate Premium |
| HTTP connector (to Graph API) | Premium connector = Premium licence |

> ⚠️ The HTTP connector is premium. Many flows that "just use Graph" break because the HTTP action requires a premium licence that the account doesn't have.

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — identify broken step → fix connection/permission → validate flow runs
2. **Deep Dive** — full dependency chain, SharePoint API behaviour, governance model
3. **Learning Pointers** — what to explore after the fix
