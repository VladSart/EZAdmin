# Microsoft Places — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**In scope:**
- Microsoft Places' directory data model (Building/Floor/Section/Room/Workspace/Desk hierarchy) and how it layers on top of, but remains architecturally distinct from, Exchange Online room/workspace mailboxes
- The three-role RBAC model (Places Administrator, Places Building Administrator, Places Desk Administrator) and the two different surfaces they're assigned through (Entra ID vs. Exchange Online PowerShell)
- Individual desk booking vs. desk pool (workspace) booking, their distinct configuration paths, and the four desk modes (Reservable, Drop-in, Assigned, Unavailable)
- The April 1, 2026 licensing unbundling (Teams Premium → per-space license model) and its transition period
- The July 28, 2026 automatic hierarchy generation change for tenants with no existing Places hierarchy
- Core client-facing features (work plans, workplace presence, Places Finder, Places Explorer, in-person events/hybrid RSVP, workplace check-in) only insofar as they depend on admin-side configuration covered here

**Out of scope (see cross-references):**
- Exchange Online room/workspace mailbox creation and calendar processing mechanics in general — see `M365/Exchange/` (this runbook treats room/workspace mailboxes as a prerequisite layer, not its own topic)
- Microsoft Teams Rooms device management, peripheral pairing, and the Teams Rooms Pro Management portal — see `M365/Teams/` (Places links peripheral devices to directory objects for check-in/auto-booking, but device provisioning itself is a Teams Rooms topic)
- Microsoft 365 Copilot licensing and tenant enablement — see `M365/Copilot/` (Copilot room booking and Quick book consume a Copilot license; this runbook does not cover Copilot licensing mechanics themselves)
- General Microsoft 365/Teams per-user licensing assignment workflow — see `M365/Licensing/` (this runbook covers only the Places-specific space-license model, which is licensed per-object, not per-user)
- Occupancy sensor hardware selection/installation — Places consumes sensor data once configured, but sensor procurement and physical installation are out of scope

**Assumes:**
- PowerShell 7.4.0 or later for any `MicrosoftPlaces` module cmdlet — **Windows PowerShell 5.1 cannot load this module at all**, a genuine exception to this repo's usual PS 5.1-compatible scripting baseline
- Exchange Online PowerShell (`ExchangeOnlineManagement`) for room/workspace mailbox and RoomList operations
- At least one of: Places Administrator (Entra ID), Exchange Administrator, or Global Administrator for full configuration access; Places Building/Desk Administrator (Exchange RBAC) for delegated scopes
- Tenant is fully on Exchange Online for the mailboxes involved — hybrid/on-premises mailboxes are architecturally excluded, not partially supported

---
## How It Works

### Two data models, one experience

Places is best understood as a **second data model layered on top of** Exchange Online's existing room/workspace mailbox system, not a replacement for it. Exchange Online already knows about room mailboxes, workspace-typed mailboxes (desk pools), RoomLists, and calendar-processing policies — this has existed for years independent of Places. Places adds a **hierarchical directory** (Building → Floor → Section → Room/Workspace/Desk) with rich metadata (capacity, A/V equipment, accessibility, photos, capability tags) that Exchange has no native concept of, and a set of **client experiences** (Places Finder, Places Explorer, the Places app, work plans, workplace presence) that read from both systems simultaneously.

This dual-model architecture is the root cause of the majority of real-world Places support tickets: an object can be perfectly correct in one system and broken in the other, and each client surface consults a different combination of the two:

```
                     ┌─────────────────────────┐         ┌──────────────────────────┐
                     │   Exchange Online        │         │   Places Directory        │
                     │   (pre-existing system)  │         │   (Places-native)         │
                     ├─────────────────────────┤         ├──────────────────────────┤
                     │ Room / Workspace mailbox │◄───────►│ Building/Floor/Section/    │
                     │ HiddenFromAddressLists   │  linked  │ Room/Workspace/Desk object │
                     │ RoomList membership      │  via     │ ParentId hierarchy         │
                     │ Set-CalendarProcessing   │  SMTP    │ Mode (Reservable/Drop-in/  │
                     │ (BookInPolicy, capacity) │  address │   Assigned/Unavailable)     │
                     │                          │          │ Metadata (tags, capacity,   │
                     │                          │          │   accessibility, photos)    │
                     └─────────────────────────┘         └──────────────────────────┘
                              │                                      │
                              ▼                                      ▼
                     Outlook classic Room Finder            Places Finder / Explorer /
                     (RoomList-driven, legacy)               new booking experience
                                                              (New Outlook, Teams calendar)
```

Outlook's classic Room Finder reads primarily from the Exchange side (RoomList membership); the new Places-powered booking experience in New Outlook and Teams calendar reads from the Places directory. An object missing from a RoomList but present in the Places hierarchy (or vice versa) produces the classic "works in one client, invisible in another" ticket.

### The hierarchy and its parenting rules

The Places directory enforces a strict `Building > Floor > Section > Room/Workspace/Desk` structure. Two parenting rules are asymmetric and a frequent source of misconfiguration:

- **Rooms** may parent directly to a Floor — a Section is optional for rooms.
- **Workspaces** (desk pools) and **individual desks** **must** parent to a Section. Parenting a workspace or desk directly to a Floor does not error, but the object silently fails to appear in the new booking experience. In practice, admins create an otherwise-empty Section purely to satisfy this rule for a floor with no other subdivisions.

Two ways to populate the hierarchy exist, and both write to the same underlying directory:

1. **`Initialize-Places` bulk import** — parses existing Exchange room/workspace mailboxes' `RoomList` membership to *infer* a starting building/floor/section mapping, exports it as an editable CSV, then imports the reviewed CSV to create the hierarchy in bulk. A third `Initialize-Places` option exports the equivalent PowerShell script without executing anything, for security teams that require change review before any bulk directory write.
2. **Manual configuration** — via the Places Management portal (`https://places.cloud.microsoft/places/admin/space-management`) or directly via `New-Place`/`Set-PlaceV3` PowerShell cmdlets, object by object.

**Building visibility is a separate, tenant-wide, off-by-default gate** sitting on top of a correctly built hierarchy: `Set-PlacesSettings -EnableBuildings`. A hierarchy can be 100% correctly structured and still be invisible in every Places client surface until this is explicitly enabled — this is the single most common "I did everything right and nothing shows up" root cause in this topic.

**Live platform change (July 28, 2026, roughly three weeks before this runbook's research date):** for tenants that have **never** built any Places hierarchy, Microsoft now automatically generates one from building/floor metadata already present on room mailboxes (set via `Set-Place`), once `EnableBuildings` is turned on — no `Initialize-Places` run required. This only applies to genuinely hierarchy-less tenants; any tenant that already has a hierarchy (even a partial or stale one) continues to require manual `Initialize-Places`/portal maintenance, and this automatic behavior will not retroactively apply to them. New or changed building/floor metadata on room mailboxes then flows into the auto-generated hierarchy via a **daily** update cycle — client engagements planned before this date should be re-scoped, since a "build the hierarchy from scratch" task for a truly greenfield tenant may now be substantially automated.

### Individual desks vs. desk pools — different creation paths, same directory

Places supports two distinct desk-booking models that can coexist side by side in the same building, but a **single physical desk can only be configured as one or the other**:

- **Individual desk** — a specific, named desk a user selects and books directly. Created via **Places PowerShell** (`New-Place -Type Desk`), auto-generating a desk mailbox if one isn't supplied.
- **Desk pool ("workspace")** — a group of interchangeable desks booked as a shared resource, without the user choosing a specific physical desk. Desk pools **must be created in Exchange Online first** (`New-Mailbox -Room ... | Set-Mailbox -Type Workspace`), then explicitly linked into the Places hierarchy via `Set-PlaceV3 -ParentId <sectionId>` — this linkage step is what makes the pool appear in the new booking experience, and is easy to forget since the Exchange-side mailbox creation alone looks complete.

Each of the four desk **modes** governs bookability independently of hierarchy placement:

| Mode | Behavior |
|---|---|
| Reservable | Can be booked in advance or on the spot |
| Drop-in | Available for on-the-spot use only; cannot be pre-booked |
| Assigned | Permanently linked to one user; nobody else can book it |
| Unavailable | Not bookable at all (maintenance, decommission, or as a forced-refresh technique — see below) |

A documented, genuinely useful but **destructive** technique: toggling a desk from `Reservable` → `Unavailable` → `Reservable` forces an immediate configuration refresh (useful for accelerating the 24-48 hour space-license propagation delay covered below) — but the `Unavailable` step **cancels every booking on that desk that hasn't started yet**. This is not a documented bug; it is stated Microsoft behavior, and this runbook treats it accordingly as a "confirm with the client first" destructive action, not a routine troubleshooting step.

### The April 1, 2026 licensing model inversion

Before April 1, 2026, most of what people think of as "Places" — individual desk booking, Places Finder, Places Explorer — required a per-user **Teams Premium** license. As of that date, Microsoft restructured this in a direction that is the *opposite* of the typical Microsoft 365 feature-gating pattern (features usually move from free to premium over time, not the reverse):

| Feature | Pre-April 2026 requirement | Post-transition requirement |
|---|---|---|
| Places Finder, Places Explorer, Places card, core booking | Teams Premium | **Core** — included in standard Business/Enterprise/Education/Frontline/Teams plans, no extra license |
| Individual desk booking | Teams Premium | **Per-space license** (Microsoft Teams Room / Teams Shared Space / Teams Shared Space-Single Space) on the specific desk |
| Autorelease | Teams Premium | Per-space license |
| Occupancy reports (Places analytics) | Teams Premium | Per-space license |
| Quick book, Copilot room booking | Teams Premium / N/A | Microsoft 365 Copilot license (unrelated axis) |

Space licenses are assigned **per object** (a specific room or desk), not per user — a structural difference from almost every other Microsoft 365 licensing decision an admin will have made, and worth calling out explicitly to avoid an admin trying (and failing) to assign a space license to a user account.

**Transition period mechanics:** organizations with a Teams Premium subscription purchased *before* April 1, 2026 keep full premium desk-booking capability, ignoring the space-license requirement entirely, **until that subscription's next renewal** — at which point they fall onto the same per-space model as everyone else. A tenant mid-transition can have some users still on the old grandfathered behavior and others already needing space licenses, depending purely on individual license renewal dates — a genuine source of "it works for me but not my coworker" tickets that has nothing to do with Places configuration.

**License propagation delay:** once a Teams Shared Space or Teams Shared Space-Single Space license is assigned to a desk in Reservable mode, it can take **24-48 hours** to take full effect across Places experiences. The `Unavailable`→`Reservable` mode-flip technique described above can force an immediate refresh, at the cost of cancelling not-yet-started bookings.

### RBAC — three roles, two assignment surfaces, one hard capability boundary

| Role | Assigned via | Can do | Cannot do |
|---|---|---|---|
| **Places Administrator** | Microsoft Entra ID / M365 admin center | Everything: enable/disable Places features, bulk directory upload, occupancy sensor config, full CRUD on buildings/floors/sections/rooms/workspaces/desks, reservation/autorelease policy, team assignment, desk mode, desk-to-user assignment | — |
| **Places Building Administrator** | Exchange Online PowerShell (`PlacesBuildingManagement` role) | Day-to-day management of one or more assigned buildings: occupancy sensors, maps, floors/sections/desks CRUD, reservation/autorelease policy, team assignment, desk mode, desk assignment, read all directory data | **Cannot create resource mailboxes; cannot update existing room/workspace name or capacity** |
| **Places Desk Administrator** | Exchange Online PowerShell | Desk mode management, desk-to-user assignment, read all directory data | Everything else — narrowest of the three roles |

The capability boundary shared by both delegated (Exchange-assigned) roles — **no resource-mailbox creation, no room/workspace rename or capacity edit** — is permanent and by design, not a partial or fixable role grant. Requests for either capability must route to a Places Administrator or an Exchange Administrator. Global Administrator and Exchange Administrator can also manage every aspect of Places, but Microsoft's own guidance explicitly recommends against using them routinely for Places work, reserving the purpose-built roles for least-privilege delegation.

### Exchange hybrid — a hard architectural exclusion, not a degraded experience

Users whose mailbox is hosted on-premises (in an Exchange hybrid topology) are **entirely excluded** from Places — not rate-limited, not read-only, not degraded: the Places app, Places Finder, and work-location sharing simply don't function for them. Critically, the Teams work-location control remains **visibly present and interactive** for these users — but changes they make are local-only, never propagated to colleagues or reflected anywhere else, which produces a specific and confusing failure mode: the feature *looks* like it's working from the user's own point of view. These users retain access only to the legacy, pre-Places Room Finder in Outlook. The only remediation is migrating the mailbox to Exchange Online; there is no Places-side configuration workaround.

---
## Dependency Stack

```
Microsoft 365 tenant with Exchange Online mailboxes
    │
    ▼
Exchange Online layer (pre-existing, independent of Places)
    ├── Room mailbox / Workspace-typed mailbox (New-Mailbox -Room, Set-Mailbox -Type Workspace)
    ├── HiddenFromAddressListsEnabled = $false (or deliberately true with accepted trade-off)
    ├── RoomList membership (Add-DistributionGroupMember) — gates classic Room Finder visibility
    └── Set-CalendarProcessing (BookInPolicy, EnforceCapacity, etc.) — booking eligibility rules
    │
    ▼
Places directory layer (Places-native, linked to Exchange objects by SMTP address)
    Building → Floor → Section → Room / Workspace / Desk
    ├── Rooms: Floor or Section parent (Section optional)
    ├── Workspaces & individual desks: Section parent REQUIRED (Floor-only parenting silently fails)
    └── Built via Initialize-Places (bulk), Places Management portal, or New-Place/Set-PlaceV3
        (as of July 28, 2026: auto-generated for hierarchy-less tenants once EnableBuildings is on)
    │
    ▼
Building visibility gate (tenant-wide, OFF by default)
    Set-PlacesSettings -EnableBuildings   ← blocks ALL Places surfaces until enabled, regardless
                                              of hierarchy correctness underneath
    │
    ▼
Licensing (per-space model, effective April 1, 2026)
    ├── Core features: included in standard M365/Teams plans (no extra license since the unbundling)
    ├── Individual desk booking / Autorelease / Occupancy reports: space license required
    │   (MTR / MTSS / MTSS-SS — 3 free MTSS-SS granted per purchased MTSS)
    │   └── Legacy exception: pre-April-2026 Teams Premium subscribers exempt until renewal
    └── Quick book / Copilot room booking: Microsoft 365 Copilot license (independent axis)
    │
    ▼
RBAC (governs who can configure the layers above)
    ├── Places Administrator (Entra ID) — full control, only role that can create mailboxes /
    │   rename / resize rooms and workspaces
    ├── Places Building Administrator (Exchange RBAC, PlacesBuildingManagement) — scoped to
    │   assigned buildings, cannot create mailboxes or rename/resize
    └── Places Desk Administrator (Exchange RBAC) — desk mode + assignment only
    │
    ▼
Client surfaces (consume both Exchange and Places-directory state, unevenly)
    ├── New Outlook (Windows/web) + Teams calendar (Windows/web) → full new booking experience,
    │   reads Places directory
    ├── Classic Outlook / Outlook mobile / Teams mobile → Places app only, older UI
    ├── Outlook classic Room Finder → reads RoomList membership (Exchange side), largely
    │   independent of Places directory state
    └── Exchange on-premises/hybrid mailbox → Places entirely unavailable; legacy Room Finder only
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `MicrosoftPlaces` module won't install/import | Running Windows PowerShell 5.1 instead of PowerShell 7.4+ | `$PSVersionTable.PSVersion` |
| Buildings/floors fully configured but invisible everywhere | Tenant-wide `EnableBuildings` setting is off | `Get-PlacesSettings` |
| Room visible in Places Management portal but missing from Outlook Room Finder | Not a member of any RoomList (Exchange-side gate, independent of Places directory) | `Get-DistributionGroupMember -Identity <roomList>` |
| Desk pool (workspace) configured but not bookable in the new experience | Parented to a Floor instead of a Section — workspaces require a Section parent | `Get-PlaceV3 -Identity <smtp>` → check `ParentId` level |
| Room mailbox exists but never appears anywhere | `HiddenFromAddressListsEnabled` is `True` | `Get-Mailbox -Identity <smtp>` |
| User previously booked any desk freely, now can't (on/after Apr 1 2026) | Per-space licensing transition — either no space license assigned, or grace period ended | Check space license on the specific desk object; check client's Teams Premium renewal date |
| Space license assigned but desk still not bookable | Normal 24-48h propagation delay | Elapsed time since assignment; force-refresh via mode toggle if urgent |
| Existing bookings vanished after a troubleshooting step | The `Unavailable`→`Reservable` force-refresh technique was used — cancels not-yet-started bookings by design | Confirm this was communicated/approved before use |
| User's work-location changes in Teams appear to do nothing for colleagues | User's mailbox is hosted on-premises (hybrid) — a hard architectural exclusion | `Get-Mailbox -Identity <UPN>` → mailbox location |
| Places Building/Desk Administrator can't create a room or rename one | Working as designed — neither delegated role can create mailboxes or edit name/capacity | Confirm role scope; route to Places Administrator/Exchange Administrator |
| `Initialize-Places` produces unexpected/duplicate buildings | Inconsistent spelling of building/floor/section names across the import CSV — any variation creates a NEW object rather than matching an existing one | Review CSV for spelling consistency before import |
| A truly greenfield tenant already shows some buildings with no manual setup | Expected — the July 28, 2026 automatic hierarchy generation feature, inferred from room-mailbox building/floor metadata | Confirm via `Get-PlaceV3` that these match `Set-Place` metadata already on the mailboxes |
| Desk pool created in Exchange but never appears in new booking experience | The `Set-PlaceV3 -ParentId` linkage step to a Section was never run — Exchange-side creation alone is not sufficient | `Get-PlaceV3 -Identity <workspace-smtp>` → confirm `ParentId` populated |

---
## Validation Steps

1. **Confirm tooling.**
   ```powershell
   $PSVersionTable.PSVersion
   ```
   Expected: 7.4.0+. Bad: 5.x — stop and fix tooling before proceeding.

2. **Confirm building visibility.**
   ```powershell
   Get-PlacesSettings | Select-Object EnableBuildings
   ```
   Expected: enabled (globally or scoped to relevant buildings). Bad: disabled.

3. **Confirm the Exchange-side object state.**
   ```powershell
   Get-Mailbox -Identity <smtp> | Select-Object DisplayName, RecipientTypeDetails, HiddenFromAddressListsEnabled
   ```
   Expected: correct recipient type, not unexpectedly hidden.

4. **Confirm RoomList membership** (independent check from Places directory).
   ```powershell
   Get-DistributionGroupMember -Identity <roomListAlias>
   ```
   Expected: target object present.

5. **Confirm Places directory placement and mode.**
   ```powershell
   Get-PlaceV3 -Identity <smtp> | Select-Object DisplayName, Type, ParentId, Mode
   ```
   Expected: `Type` matches intent (Room/Workspace/Desk), `ParentId` resolves to a Section for Workspace/Desk types, `Mode` matches intended bookability.

6. **Confirm licensing for premium-gated features.**
   Places Management portal → object's license assignment, or the tenant's licensing admin center. Expected: space license present on the object for desk booking/autorelease/occupancy analytics, unless the client is confirmed still within a legacy Teams Premium grace period.

7. **Confirm role scope for the requesting/delegated admin** if a configuration action is failing.
   Expected: the action attempted falls within that role's documented capability boundary (see RBAC table above) — many "the role doesn't work" tickets are actually "the role was never meant to do this."

---
## Troubleshooting Steps (by phase)

### Phase 1: Tooling & Prerequisite Confirmation
1. Confirm PowerShell 7.4+ is available for any `MicrosoftPlaces` cmdlet work.
2. Confirm the relevant Exchange Online and Microsoft Teams PowerShell modules are also connected if the task spans mailbox or peripheral-device configuration.

### Phase 2: Exchange-Layer Investigation
1. Confirm the room/workspace/desk mailbox exists with the correct recipient type.
2. Confirm hide-from-address-list state.
3. Confirm RoomList membership for classic Room Finder visibility.

### Phase 3: Places-Directory-Layer Investigation
1. Confirm `EnableBuildings` tenant setting.
2. Confirm hierarchy parenting, paying particular attention to the Workspace/Desk-must-parent-to-Section rule.
3. Confirm desk `Mode` matches intended bookability.

### Phase 4: Licensing Investigation
1. Identify whether the affected feature is core (no license needed post-unbundling) or space-licensed.
2. If space-licensed, confirm license assignment on the specific object and check propagation timing.
3. Check for an active legacy Teams Premium grace period if the client predates April 2026.

### Phase 5: RBAC & Scope Investigation
1. Confirm which of the three Places roles the requesting admin holds and whether the attempted action falls inside that role's documented boundary.
2. Route mailbox-creation or rename/resize requests to Places Administrator/Exchange Administrator if the requester only holds a delegated role.

### Phase 6: Escalation
1. Package the Evidence Pack output below.
2. Escalate genuine platform-side failures (e.g., `Initialize-Places` producing incorrect results despite a clean CSV, or persistent visibility failures well past all documented propagation windows) to Microsoft Support.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield Places rollout for a new client</summary>

1. Confirm the client's Exchange Online room/workspace mailbox inventory is accurate and complete first — Places quality is capped by the accuracy of the underlying Exchange data.
2. Check whether the client already has ANY existing Places hierarchy. If genuinely none exists and the rollout starts on/after July 28, 2026, consider relying on the automatic hierarchy-generation feature (ensure `Set-Place` building/floor metadata is populated on room mailboxes, then enable `EnableBuildings`) rather than running a full manual `Initialize-Places` bulk import.
3. If automatic generation doesn't apply or needs augmenting, run `Initialize-Places` Option 1 to export the suggested CSV mapping, review/correct building and floor names for consistency (any spelling variance creates duplicate objects), then import via Option 2.
4. Enable building visibility: `Set-PlacesSettings -EnableBuildings 'Default:true'`.
5. Decide the desk-booking model per location — individual desks (Places PowerShell `New-Place -Type Desk`) vs. desk pools (Exchange `New-Mailbox -Type Workspace` + `Set-PlaceV3 -ParentId` linkage) — and note that a physical desk can only be one or the other.
6. Assign space licenses (MTR/MTSS/MTSS-SS) to any room/desk that needs autorelease, occupancy analytics, or individual desk booking; confirm whether the client still has an active legacy Teams Premium grace period that defers this need.
7. Delegate ongoing management via Places Building/Desk Administrator roles scoped to the least privilege actually needed, reserving full Places Administrator for central IT.
8. Allow the documented propagation windows (hierarchy changes: usually immediate for buildings/floors/sections, up to 24h for rooms/workspaces; licensing: 24-48h) before declaring anything broken.

**Rollback:** Disabling `EnableBuildings` reverts visibility tenant-wide without deleting the underlying hierarchy data — a safe way to pause a rollout mid-flight if needed.

</details>

<details><summary>Playbook 2 — Migrating an existing Teams Premium desk-booking deployment through the April 2026 transition</summary>

**When to use:** A client built their desk-booking deployment before April 1, 2026 under the Teams Premium model and needs to plan for the eventual space-license requirement.

1. Identify the client's Teams Premium subscription renewal date — this determines exactly when the grace period ends for that tenant, not a single fixed date for everyone.
2. Inventory every room/desk currently relying on premium features (autorelease, occupancy reports, individual desk booking) via `Get-PlaceV3` and cross-reference against current space-license assignment.
3. Calculate space-license need: MTR for meeting rooms, MTSS for BYOD rooms/common-area phones/individual desks, MTSS-SS specifically for BYOD rooms or individual desks (not common-area phones) — factoring in the 3 free MTSS-SS licenses granted per purchased MTSS.
4. Procure and pre-assign space licenses well ahead of the renewal date rather than reactively after users start losing access.
5. Communicate the timeline to the client explicitly — "your booking experience won't change today, but will require action by <renewal date>" is a materially different message than "this is broken."

**Rollback:** N/A — this is a licensing-planning exercise, not a configuration change with a rollback path.

</details>

<details><summary>Playbook 3 — Diagnosing a "works in one client, not another" report</summary>

**When to use:** A room or desk is bookable in one client (e.g., Teams calendar) but not another (e.g., classic Outlook, or vice versa).

1. Identify exactly which client surface is failing — New Outlook/Teams calendar (Places-directory-driven) vs. classic Outlook/Outlook mobile Room Finder (RoomList-driven).
2. Check the system the failing client actually depends on: Places directory (`Get-PlaceV3`) for the new experience, RoomList membership (`Get-DistributionGroupMember`) for classic Room Finder.
3. Do not assume both systems are in sync just because one is confirmed correct — this dual-model architecture is specifically designed to allow independent configuration, which means independent misconfiguration is equally possible.
4. Fix the specific gap identified rather than re-configuring both systems defensively — understanding which system each client reads from prevents unnecessary rework.

**Rollback:** N/A — diagnostic playbook, remediation follows whichever Fix Path in `Places-B.md` applies.

</details>

<details><summary>Playbook 4 — MSP fleet-wide Places readiness audit</summary>

**When to use:** An MSP wants a standing check across managed tenants before recommending a Places rollout or troubleshooting a licensing-transition question at scale.

1. Run `Scripts/Get-PlacesReadinessAudit.ps1` per tenant to collect PowerShell version compliance, `EnableBuildings` state, Places directory object counts by type and parenting validity (specifically flagging Workspace/Desk objects parented above Section level), RoomList cross-reference gaps, and best-effort space-license signal.
2. Cross-reference findings against each tenant's Teams Premium subscription status and renewal date to flag clients approaching the end of their April-2026-transition grace period.
3. Prioritize remediation for any tenant showing Workspace/Desk objects with invalid parenting or `EnableBuildings` disabled — these two findings alone explain the large majority of real-world "Places doesn't work" tickets per this runbook's own Symptom → Cause Map.

**Rollback:** N/A — read-only audit.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Places-relevant configuration evidence for escalation or fleet audit.
.NOTES     Read-only. Requires PowerShell 7.4+, MicrosoftPlaces and ExchangeOnlineManagement
           modules connected. See Scripts/Get-PlacesReadinessAudit.ps1 for the full, documented
           tenant-wide version with CSV export. This inline block is the minimal manual
           equivalent for a single quick escalation.
#>
$evidence = [System.Collections.Generic.List[string]]::new()

$evidence.Add("=== PowerShell Version ===")
$evidence.Add(($PSVersionTable.PSVersion | Out-String))

$evidence.Add("=== EnableBuildings Setting ===")
$evidence.Add((Get-PlacesSettings | Select-Object EnableBuildings | Out-String))

$evidence.Add("=== Target Object — Exchange Side ===")
$evidence.Add((Get-Mailbox -Identity $TargetSmtp |
    Select-Object DisplayName, RecipientTypeDetails, HiddenFromAddressListsEnabled | Out-String))

$evidence.Add("=== Target Object — Places Directory Side ===")
$evidence.Add((Get-PlaceV3 -Identity $TargetSmtp |
    Select-Object DisplayName, Type, ParentId, Mode | Out-String))

$evidence | Out-File -FilePath ".\Places-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Install/update Places PowerShell module (PS7+ only) | `Install-Module -Name MicrosoftPlaces -Force` |
| Connect to Places | `Connect-MicrosoftPlaces` |
| Check building visibility setting | `Get-PlacesSettings \| Select-Object EnableBuildings` |
| Enable building visibility tenant-wide | `Set-PlacesSettings -EnableBuildings 'Default:true'` |
| Bulk-generate hierarchy from existing rooms | `Initialize-Places` |
| Create a building/floor/section | `New-Place -Type Building\|Floor\|Section -Name "<name>" -ParentId <id>` |
| Create an individual desk | `New-Place -Type Desk -Name "<name>" -ParentId <sectionId> -Mode @{Name='Reservable'}` |
| Read/query a Places object | `Get-PlaceV3 -Identity <smtp>` or `Get-PlaceV3 -Type Room\|Desk\|Building\|Floor\|Section` |
| Update a Places object's parent/metadata | `Set-PlaceV3 -Identity <smtp> -ParentId <id> -Capacity <n> -Tags "<tag>"` |
| Export all rooms regardless of RoomList | `Get-PlaceV3 -Type Room \| Export-Csv -NoTypeInformation "rooms.csv"` |
| Check Exchange mailbox type/visibility | `Get-Mailbox -Identity <smtp> \| Select-Object RecipientTypeDetails, HiddenFromAddressListsEnabled` |
| Create a workspace (desk-pool) mailbox | `New-Mailbox -Room -Alias <alias> -Name <name> \| Set-Mailbox -Type Workspace` |
| Check/add RoomList membership | `Get-DistributionGroupMember -Identity <roomList>` / `Add-DistributionGroupMember -Identity <roomList> -Member <smtp>` |
| Apply a desk/room booking policy | `Set-CalendarProcessing -Identity <smtp> -BookInPolicy <GroupDL> -EnforceCapacity $true` |
| Assign the Places Building Administrator role | `New-ManagementRoleAssignment -Role "PlacesBuildingManagement" -User <user>` |
| Force-refresh a desk's config (⚠ cancels bookings) | `Set-PlaceV3 -Identity <smtp> -Mode @{Name='Unavailable'}` then `... -Mode @{Name='Reservable'}` |

---
## 🎓 Learning Pointers

- **Places is architecturally two systems, not one** — a pre-existing Exchange Online room/workspace mailbox layer, and a Places-native directory hierarchy layered on top, linked only by SMTP address. Every non-obvious symptom in this topic traces back to these two systems disagreeing. See [Microsoft Places overview](https://learn.microsoft.com/en-us/microsoft-365/places/places-overview).

- **The workspace/desk-must-parent-to-a-Section rule is asymmetric with rooms** and is not enforced with an error — it fails silently by simply not appearing in the new booking experience. Build this check into any Places deployment review as a first-class item, not an edge case. See [Configure buildings and floors](https://learn.microsoft.com/en-us/microsoft-365/places/get-started/quick-setup-buildings-floors).

- **The April 2026 licensing unbundling moved in the opposite direction from typical Microsoft 365 feature-gating** — core Places features became free, while a narrower set of premium features moved to a per-space (not per-user) license. Don't apply per-user licensing intuition when troubleshooting or advising on this topic. See [Microsoft Places overview — Licensing requirements](https://learn.microsoft.com/en-us/microsoft-365/places/places-overview#licensing-requirements).

- **The July 28, 2026 automatic hierarchy generation is genuinely new and narrowly scoped** — it only helps tenants with zero existing hierarchy, and does nothing for a tenant with even a partial or stale one. Verify which category a client falls into before assuming this feature will simplify their specific rollout. See [Configure buildings and floors](https://learn.microsoft.com/en-us/microsoft-365/places/get-started/quick-setup-buildings-floors).

- **Delegated Places roles have a permanent, non-negotiable capability ceiling** (no mailbox creation, no room/workspace rename/resize) that is easy to mistake for an incomplete role assignment. Confirm the role boundary before troubleshooting what looks like a broken permission grant. See [Configure administrator roles](https://learn.microsoft.com/en-us/microsoft-365/places/configure-admin-roles).

- **The `Unavailable`→`Reservable` force-refresh technique is a genuinely documented workaround, not a hack — but it is also genuinely destructive** (cancels not-yet-started bookings). Treat it with the same "confirm with the client first" discipline this repo applies to any other irreversible action, despite its simplicity. See [Microsoft Places overview — FAQ](https://learn.microsoft.com/en-us/microsoft-365/places/places-overview#frequently-asked-questions).
