# Microsoft Places — Agent Instructions

## What's in this folder

Microsoft Places — the hybrid-workplace app (desk/room booking, work plans, Places Finder/Explorer) embedded in Teams and Outlook, architecturally layered on top of (not a replacement for) Exchange Online room/workspace mailboxes. Covers the strict Building > Floor > Section > Room/Workspace/Desk directory hierarchy and its asymmetric parenting rule (Workspace/Desk objects must parent to a Section, Rooms don't), the tenant-wide `EnableBuildings` visibility gate (off by default), the three-role RBAC model split across Entra ID (Places Administrator) and Exchange RBAC (Places Building/Desk Administrator), the April 1, 2026 licensing unbundling (core features moved to standard M365/Teams plans; desk booking/Autorelease/Occupancy reports now require a per-space MTR/MTSS/MTSS-SS license), and the hard architectural exclusion of Exchange on-premises/hybrid mailboxes. Requires PowerShell 7.4+ for the `MicrosoftPlaces` module — a deliberate exception to this repo's usual PS 5.1-compatible scripting convention.

---

## Before responding, also check

- `M365/_AGENT.md` — general M365 agent context and cross-service dependencies
- `M365/Exchange/_AGENT.md` — if the underlying object is a room/desk mailbox issue (creation, hiding, RoomList membership) rather than a Places-directory issue
- `M365/Copilot/Copilot-A.md`/`-B.md` — if the ticket is about Copilot room booking/Quick book specifically (requires a Copilot license, unrelated to space licenses)
- `EntraID/Troubleshooting/` — for Places Administrator role assignment issues
- `M365/Licensing/_AGENT.md` — for the broader post-April-2026 licensing model and SKU assignment mechanics

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Places-B.md` | Hotfix runbook — diagnose and resolve in under 10 min: PS version gate, building visibility, hidden mailboxes, RoomList membership, hierarchy parenting, licensing transition, propagation delay, hybrid-mailbox exclusion, RBAC boundary |
| `Places-A.md` | Deep dive reference — full architecture (two data models, hierarchy/parenting rules, individual desks vs. desk pools, the April 2026 licensing inversion, three-role RBAC across two assignment surfaces, hard Exchange hybrid exclusion) |
| `Scripts/Get-PlacesReadinessAudit.ps1` | PowerShell/Graph script — Places directory + Exchange mailbox cross-check: hierarchy parenting, building visibility, RoomList membership, license state per space |

---

## Common entry points

- "MicrosoftPlaces module won't load / cmdlets not found" → `Places-B.md` Fix 1 — requires PowerShell 7.4+, will not load on Windows PowerShell 5.1
- "We built our building/floor hierarchy but nobody can see it" → `Places-B.md` Fix 2 — tenant-wide `EnableBuildings` setting, off by default, separate from hierarchy correctness
- "Room/desk mailbox exists but doesn't show up anywhere" → `Places-B.md` Fix 3 — check `HiddenFromAddressListsEnabled`
- "Room shows fine in Places Management portal but missing from Outlook Room Finder" → `Places-B.md` Fix 4 — RoomList membership is a separate, Exchange-side gate from Places directory placement
- "Desk pool is configured but won't show up for booking" → `Places-B.md` Fix 5 — workspaces must parent to a Section, not just a Floor; silent failure, no error
- "User could book any desk before, now they can't" → `Places-B.md` Fix 6 — April 1, 2026 licensing unbundling; per-space MTR/MTSS/MTSS-SS license now required unless still inside a legacy Teams Premium grace period
- "Desk still not bookable 24-48h after license assignment" → `Places-B.md` Fix 7 — propagation timing
- "User on an on-premises Exchange mailbox can't use Places" → `Places-B.md` Fix 8 — hard architectural exclusion, not a degraded experience
- "Places Building/Desk Administrator can't create a mailbox or rename a room" → `Places-B.md` Fix 9 — permanent role-boundary restriction, not a misconfiguration
- "How does the Places hierarchy/licensing model actually work?" → `Places-A.md` § How It Works
- "Audit hierarchy, visibility, and license readiness" → `Scripts/Get-PlacesReadinessAudit.ps1`

---

## Key diagnostic commands

```powershell
# Confirm the caller can actually reach Places PowerShell (PS7 required — fails outright on PS5.1)
$PSVersionTable.PSVersion
Install-Module -Name MicrosoftPlaces -Force
Connect-MicrosoftPlaces

# Confirm building visibility is turned on — OFF by default tenant-wide, the single most
# common "I set up buildings but nobody can see them" root cause
Get-PlacesSettings | Select-Object EnableBuildings

# Confirm the affected room/desk mailbox exists and isn't hidden from address lists
# (requires Exchange Online PowerShell — Connect-ExchangeOnline)
Get-Mailbox -Identity <roomOrDeskSmtpAddress> |
    Select-Object DisplayName, RecipientTypeDetails, HiddenFromAddressListsEnabled

# Confirm the room/desk is on a RoomList (required for Outlook Room Finder visibility —
# a Places-directory listing alone is NOT enough)
Get-DistributionGroupMember -Identity <roomListAlias> | Select-Object DisplayName, PrimarySmtpAddress

# Confirm the object's position in the Places hierarchy and its current mode
Get-PlaceV3 -Identity <smtpAddress> | Select-Object DisplayName, Type, ParentId, Mode
```

---

## Key dependency chain

```
Microsoft 365 tenant with Exchange Online mailboxes (room, workspace/desk-pool, or individual desk)
    │
    ├── Room/desk mailbox exists in Exchange Online, not hidden, and on a RoomList
    │     (RoomList required for Outlook/Teams Room Finder, independent of Places directory)
    │
    ▼
Places directory hierarchy (separate data model layered on top of the mailboxes above)
    Building → Floor → Section → Room / Desk-pool ("Workspace") / individual Desk
    (Workspaces/Desks MUST parent to a Section — floor-only parenting silently fails)
    │
    ▼
Building visibility gate (tenant-wide, OFF by default)
    Set-PlacesSettings -EnableBuildings 'Default:true'
    │
    ▼
Licensing (post-April 1, 2026 model)
    Core features → included in standard M365/Teams plans
    Individual desk booking/Autorelease/Occupancy reports → require a per-SPACE license
    Copilot room booking/Quick book → requires a Copilot license (separate)
    │
    ▼
RBAC — Places Administrator (Entra ID, full control) vs. Places Building/Desk
Administrator (Exchange RBAC, day-to-day only — cannot create mailboxes or rename/resize)
    │
    ▼
Client surfaces — new Outlook/Teams calendar (full experience) vs. classic
Outlook/mobile (Places app only) vs. Exchange on-prem/hybrid (unavailable)
```

---

## Response format reminder (always 3 layers)

1. **Triage first** — is it PowerShell version, building visibility, mailbox state, hierarchy parenting, or licensing?
2. **Fix the specific failure** — use the matching fix path from the B runbook
3. **Confirm resolution** — verify the room/desk appears and is bookable in the new Outlook/Teams booking experience; allow up to 24-48h for licensing propagation
