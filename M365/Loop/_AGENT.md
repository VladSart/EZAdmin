# Microsoft Loop — Agent Instructions

## What's in this folder

Microsoft Loop troubleshooting and reference content, split between two products sharing one brand: Loop components (embedded `.loop` blocks in Outlook, Teams, OneNote, Whiteboard — riding on existing OneDrive/SharePoint licenses) and Loop workspaces (the standalone Loop app, requiring the narrower "Loop with workspaces" service plan). Covers the two independent, non-overlapping admin policy tools (Cloud Policy at config.office.com governs everything except Teams; `Set-SPOTenant -IsLoopEnabled`/`-IsCollabMeetingNotesFluidEnabled` governs Teams only), the separate OWA mailbox-policy gate for web/new Outlook, the shared user-owned SharePoint Embedded container behind My workspace/Copilot Pages/Copilot Notebooks, container ownership types, Loop's maturing Purview governance posture, offboarding handling, and cloud-environment availability (commercial-cloud-only).

---

## Before responding, also check

- `M365/_AGENT.md` — general M365 agent context and cross-service dependencies
- `M365/Copilot/Copilot-A.md`/`-B.md` — base Copilot licensing/CA broadly; this folder covers only the storage/container infrastructure Copilot Pages and Notebooks share with Loop
- `M365/SharePoint-OneDrive/_AGENT.md` — if the issue is SharePoint Embedded container mechanics broadly, not Loop-specific
- `Security/Purview/` — retention labels, eDiscovery, and Communication Compliance mechanics that Loop content sits underneath (Loop has no dedicated governance surface of its own)
- `EntraID/Troubleshooting/` — if users can't authenticate at all (sign-in failure, not a Loop policy gate)

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Loop-B.md` | Hotfix runbook — diagnose and resolve access/creation/storage failures in under 10 min: two-policy-tool trap, OWA gate, can't-fully-disable Loop, eDiscovery gaps, retention labels, workspace restore, GCC/sovereign-cloud absence, offboarding, ownerless workspaces |
| `Loop-A.md` | Deep dive reference — full architecture (two products, two policy tools, storage-by-origin model), container ownership types, governance maturity, offboarding differences from OneDrive, cloud-environment availability |
| `Scripts/Get-LoopGovernanceAudit.ps1` | Graph/SPO script — inventories Cloud Policy-visible state, `IsLoopEnabled`/`IsCollabMeetingNotesFluidEnabled`, user-owned and ownerless containers |

---

## Common entry points

- "Loop works in Teams but not Outlook/OneNote" (or the reverse) → `Loop-B.md` Fix 1 — two separate admin policy tools govern different apps, not the same one twice
- "We disabled Loop but Copilot Pages/Notebooks still create a container" → `Loop-B.md` Fix 3 — the shared personal container is created by either policy alone; must disable both
- "Loop won't create/view in web Outlook or new Outlook despite Cloud Policy allowing it" → `Loop-B.md` Fix 2 — OWA mailbox policy booleans, independent of Cloud Policy
- "eDiscovery custodian search finds nothing for a user's My workspace content" → `Loop-B.md` Fix 4
- "Can't apply or see a retention label on a Loop component" → `Loop-B.md` Fix 5
- "A shared Loop workspace just disappeared" → `Loop-B.md` Fix 6 — no end-user recycle bin; admin-side SharePoint Embedded container restore required
- "GCC/GCC High/DoD tenant says the Loop app is missing entirely" → `Loop-B.md` Fix 7 — commercial-cloud-only by design, not a bug
- "Employee left and we need their Loop/Copilot Pages content" → `Loop-B.md` Fix 8 — no automatic manager delegation, unlike OneDrive; must manually add a custodian before the retention window closes
- "Ownerless shared Loop workspace nobody can manage" → `Loop-B.md` Fix 9
- "How does Loop's storage/container model actually work?" → `Loop-A.md` § How It Works
- "Audit tenant-wide Loop policy/container state" → `Scripts/Get-LoopGovernanceAudit.ps1`

---

## Key diagnostic commands

```powershell
# Confirm SharePoint PowerShell module state (needed for Teams-side settings and
# all SharePoint Embedded container management below)
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
Get-SPOTenant | Select-Object IsLoopEnabled, IsCollabMeetingNotesFluidEnabled

# Cloud Policy state has NO PowerShell read — confirm manually at https://config.office.com
# > Customization > Policy Management, looking for:
#   - "Create Loop workspaces in Loop"
#   - "Create and view Loop files in Microsoft apps that support Loop"
#   - "Create and view Loop files in Outlook"

# OWA mailbox policy gate (blocks Loop in Outlook on the web / new Outlook for Windows
# even when Cloud Policy allows it)
Get-OwaMailboxPolicy | Select-Object Identity, DirectFileAccessOnPrivateComputersEnabled, `
    WacViewingOnPrivateComputersEnabled, DirectFileAccessOnPublicComputersEnabled, `
    WacViewingOnPublicComputersEnabled

# List every user-owned container (My workspace / Copilot Pages / Copilot Notebooks —
# all identified by the Loop Web Application ID regardless of which feature created them)
Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' |
    Where-Object OwnershipType -EQ 'UserOwned' | Format-Table

# Find ownerless tenant-owned Loop workspaces (all owners left the org)
Get-SPOContainer -OwningApplicationId 'a187e399-0c36-4b98-8f04-1edc167a0996' |
    Where-Object { $_.OwnersCount -eq 0 } | Format-Table
```

---

## Key dependency chain

```
Microsoft 365 tenant with OneDrive/SharePoint licenses (Loop components)
    + "Loop with workspaces" service plan (Loop workspaces specifically)
    │
    ▼
TWO independent admin policy tools — BOTH must allow creation, checked by different apps
    │
    ├── Cloud Policy (config.office.com) — checked by everything EXCEPT Teams
    └── SharePoint org properties (PowerShell only, Teams-only, tenant-wide)
          IsLoopEnabled / IsCollabMeetingNotesFluidEnabled
    │
    ▼
Additional per-surface gate: OWA mailbox policy (Exchange Online, independent of both above)
    │
    ▼
Storage layer — WHERE content lands depends entirely on WHERE it was created
    (SharePoint Embedded container, SharePoint site, or OneDrive depending on origin app)
    │
    ▼
Governance layer (Purview) — applies AFTER the container/site/OneDrive location is
settled; eDiscovery/retention/DLP target "All SharePoint Sites" or the specific
container URL, never a Loop-specific scope of its own
```

---

## Response format reminder (always 3 layers)

1. **Triage first** — which app is affected, and which of the two policy tools + OWA gate governs it?
2. **Fix the specific failure** — use the matching fix path from the B runbook
3. **Confirm resolution** — verify creation/access in the affected app; check container ownership if the ticket involves offboarding or ownerless workspaces
