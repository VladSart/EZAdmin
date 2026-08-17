# Microsoft Places — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

**Read this first:** Microsoft Places is the AI-powered hybrid-workplace app (desk/room booking, work plans, Places Finder/Explorer) embedded in Teams and Outlook. It depends on a strict `Building > Floor > Section > Room/Desk` hierarchy layered **on top of** normal Exchange Online room/workspace mailboxes — most "it's not showing up" tickets are actually an Exchange room-mailbox or RoomList problem wearing a Places costume, not a Places-native fault. As of **April 1, 2026**, individual desk booking, autorelease, and occupancy analytics moved from a per-user Teams Premium entitlement to a **per-space license** model (Microsoft Teams Room / Shared Space / Shared Space-Single Space) — confirm which licensing era a client is in before troubleshooting a "premium feature" complaint.

**Tooling note:** Places PowerShell (the `MicrosoftPlaces` module: `Connect-MicrosoftPlaces`, `New-Place`, `Get-PlaceV3`, `Set-PlaceV3`, `Set-PlacesSettings`) **requires PowerShell 7.4.0+ — Windows PowerShell 5.1 will not load it.** This is a genuine exception to this repo's usual PS 5.1-compatible scripting convention; don't assume a client's existing automation runbook works unmodified here.

```powershell
# 1. Confirm the caller can actually reach Places PowerShell (PS7 required — this fails outright on PS5.1)
$PSVersionTable.PSVersion
Install-Module -Name MicrosoftPlaces -Force
Connect-MicrosoftPlaces

# 2. Confirm building visibility is turned on — OFF by default tenant-wide, the single most common
#    "I set up buildings but nobody can see them" root cause
Get-PlacesSettings | Select-Object EnableBuildings

# 3. Confirm the affected room/desk mailbox actually exists and isn't hidden from address lists
#    (requires Exchange Online PowerShell — Connect-ExchangeOnline)
Get-Mailbox -Identity <roomOrDeskSmtpAddress> |
    Select-Object DisplayName, RecipientTypeDetails, HiddenFromAddressListsEnabled

# 4. Confirm the room/desk is on a RoomList (required for Outlook Room Finder visibility — a
#    Places-directory listing alone is NOT enough)
Get-DistributionGroupMember -Identity <roomListAlias> | Select-Object DisplayName, PrimarySmtpAddress

# 5. Confirm the object's position in the Places hierarchy and its current mode
Get-PlaceV3 -Identity <smtpAddress> | Select-Object DisplayName, Type, ParentId, Mode
```

| Command / observation result | Interpretation | Do this |
|---|---|---|
| `$PSVersionTable.PSVersion` is 5.x | `MicrosoftPlaces` module cannot load at all — must switch to PowerShell 7 | Fix 1 |
| `EnableBuildings` is `False`/blank | Buildings, floors, and sections exist in the directory but are invisible in every Places surface tenant-wide | Fix 2 |
| `HiddenFromAddressListsEnabled` is `True` for a room/desk mailbox | Object is deliberately or accidentally hidden — won't surface in Room Finder or Places Finder | Fix 3 |
| Room/desk mailbox not a member of any RoomList | Won't appear in Outlook/Teams Room Finder even if fully configured in Places | Fix 4 |
| `Get-PlaceV3` shows `ParentId` empty or pointing at the wrong level | Object isn't correctly parented in the Building→Floor→Section chain — desk pools (workspaces) specifically **require** a Section parent, not a bare floor | Fix 5 |
| User reports "I used to book any desk, now I can't" on/after April 1, 2026 | Teams Premium→per-space desk-booking license transition — check space license assignment | Fix 6 |
| Desk shows correct license but booking still unavailable for 24-48h after assignment | Documented license-propagation delay — not a fault | Fix 7 |
| User has an on-premises Exchange mailbox | Places app, Places Finder, and work-location sharing are **not supported** for on-prem mailboxes — legacy Room Finder is the only available path | Fix 8 |
| Places Building/Desk Administrator can't rename a room or create a new resource mailbox | Working as designed — those two delegated roles cannot create resource mailboxes or edit room/workspace name/capacity, only Places Administrator or Exchange Administrator can | Fix 9 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft 365 tenant with Exchange Online mailboxes (room, workspace/desk-pool, or individual desk)
    │
    ├── Room/desk mailbox exists in Exchange Online (Get-Mailbox -Room / -Workspace)
    │     ├── NOT HiddenFromAddressListsEnabled (or deliberately hidden + accepted trade-off)
    │     └── Member of a RoomList (Add-DistributionGroupMember) — REQUIRED for Outlook/Teams
    │           Room Finder visibility, independent of Places directory placement
    │
    ▼
Places directory hierarchy (separate data model layered on top of the mailboxes above)
    Building → Floor → Section → Room / Desk-pool ("Workspace") / individual Desk
    │
    ├── Rooms CAN parent directly to a Floor (Section optional)
    ├── Workspaces (desk pools) MUST parent to a Section — floor-only parenting silently fails
    │     to appear in the new booking experience
    ├── Individual desks MUST parent to a Section, same rule as workspaces
    └── Built via Initialize-Places (bulk CSV import) OR manually via Places Management portal
        OR manually via New-Place/Set-PlaceV3 PowerShell — all three write to the SAME directory
    │
    ▼
Building visibility gate (tenant-wide, OFF by default)
    Set-PlacesSettings -EnableBuildings 'Default:true'   ← nothing in the hierarchy is visible
                                                             in ANY Places surface until this runs
    │
    ▼
Licensing (post-April 1, 2026 model)
    ├── Core features (work plans, presence, check-in, room/workspace booking, Places Finder,
    │   Places Explorer, Places Management portal) → included in standard M365/Teams plans,
    │   NO Teams Premium or space license required as of the April 2026 unbundling
    ├── Individual desk booking, Autorelease, Occupancy reports → REQUIRE a space license
    │   (Microsoft Teams Room / Teams Shared Space / Teams Shared Space-Single Space) on that
    │   specific room/desk object — licenses are per-SPACE, not per-user
    │   └── Transition-period exception: pre-April-2026 Teams Premium subscribers keep premium
    │       desk booking until their next renewal, then fall onto the space-license model too
    └── Copilot room booking / Quick book → REQUIRE a Microsoft 365 Copilot license (unrelated
        to space licenses)
    │
    ▼
RBAC — three roles, two different assignment surfaces
    ├── Places Administrator      → Microsoft Entra ID / M365 admin center — full control,
    │                                 including resource-mailbox creation and room/workspace
    │                                 rename/capacity edits
    ├── Places Building Administrator → Exchange Online PowerShell (PlacesBuildingManagement role)
    │                                 — day-to-day building management, CANNOT create mailboxes
    │                                 or rename/resize rooms/workspaces
    └── Places Desk Administrator     → Exchange Online PowerShell — desk mode + desk assignment
                                        only, same mailbox-creation/rename restriction
    │
    ▼
Client surfaces (where the end result actually appears)
    New Outlook (Windows/web) + Teams calendar (Windows/web) = full new booking experience
    Classic Outlook / Outlook mobile / Teams mobile           = Places app only (older booking UI)
    Exchange on-premises mailbox (hybrid)                      = Places entirely unavailable;
                                                                    legacy Room Finder only
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm PowerShell 7 before attempting any `MicrosoftPlaces` cmdlet.**
   ```powershell
   $PSVersionTable.PSVersion
   ```
   - Good: 7.4.0 or later.
   - Bad: anything on the 5.x branch → module import will fail outright, not partially. Go to Fix 1 before doing anything else.

2. **Confirm building visibility tenant-wide.**
   ```powershell
   Get-PlacesSettings | Select-Object EnableBuildings
   ```
   - Good: `True` (or `Default:true`).
   - Bad: `False`/blank → this alone explains "buildings exist but nobody sees them," regardless of how correctly the hierarchy underneath was built. Fix 2.

3. **Confirm the underlying Exchange mailbox state for the specific room/desk in question.**
   ```powershell
   Get-Mailbox -Identity <smtpAddress> | Select-Object DisplayName, RecipientTypeDetails, HiddenFromAddressListsEnabled
   ```
   - Good: correct `RecipientTypeDetails` (RoomMailbox for rooms/individual desks, or Workspace-typed for desk pools) and not hidden.
   - Bad: wrong type, or hidden without a deliberate reason → Fix 3.

4. **Confirm RoomList membership** — this is independent of Places directory placement and is required for classic Room Finder visibility in Outlook/Teams.
   ```powershell
   Get-DistributionGroupMember -Identity <roomListAlias>
   ```
   - Good: the object is listed.
   - Bad: absent → Fix 4, even if the Places directory side looks perfect.

5. **Confirm hierarchy parenting via `Get-PlaceV3`.**
   ```powershell
   Get-PlaceV3 -Identity <smtpAddress> | Select-Object DisplayName, Type, ParentId, Mode
   ```
   - Good: `ParentId` resolves to a Section for workspaces/desks, or at minimum a Floor for rooms.
   - Bad: empty `ParentId`, or a workspace/desk parented only to a Floor → Fix 5.

6. **If the complaint is licensing-shaped ("I could book any desk before, now I can't"), check the object's space license and the date against April 1, 2026.**
   - Good: space license (MTR/MTSS/MTSS-SS) assigned to the specific desk, or client confirmed still inside their pre-2026 Teams Premium renewal window.
   - Bad: no space license and no active legacy Teams Premium grace period → Fix 6.

7. **If licensing was just assigned and the desk still won't book, check elapsed time before escalating.**
   - Good: within ~24-48 hours of license assignment.
   - Bad: well past that window → escalate, don't keep re-checking.

---
## Common Fix Paths

<details><summary>Fix 1 — MicrosoftPlaces module won't load (wrong PowerShell version)</summary>

**When to use:** `Install-Module`/`Connect-MicrosoftPlaces` fails or the module silently exposes no cmdlets.

1. Confirm the engineer is running **PowerShell 7.4.0 or later** — Windows PowerShell 5.1 (`powershell.exe`) cannot run this module at all, not even in a degraded mode.
2. Install PowerShell 7 if not already present: [Installing PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell).
3. From a `pwsh` (not `powershell`) session:
   ```powershell
   Install-Module -Name MicrosoftPlaces -Force
   Connect-MicrosoftPlaces
   ```
4. Also install/connect Exchange Online and Microsoft Teams PowerShell modules if the task touches room mailboxes or Teams Rooms peripherals — Places management routinely spans all three.

**Rollback:** N/A — tooling fix, no tenant configuration changed.

</details>

<details><summary>Fix 2 — Buildings exist but aren't visible anywhere</summary>

**When to use:** `Get-PlacesSettings` shows `EnableBuildings` is off/blank, and users report no building picker in Teams/Outlook despite buildings being present in the Places Management portal.

```powershell
Connect-MicrosoftPlaces
Set-PlacesSettings -EnableBuildings 'Default:true'
```

1. Run the command above — this is a tenant-wide switch, off by default even after a fully correct hierarchy build.
2. Set client expectations: newly visible buildings/floors/sections should appear immediately, but changes to individual rooms/workspaces can take **up to 24 hours** to propagate.
3. If only specific buildings should be visible rather than all of them, use scoped values instead of `Default:true` — see [Set-PlacesSettings](https://learn.microsoft.com/en-us/microsoft-365/places/powershell/set-placessettings#-enablebuildings) for the full syntax.

**Rollback:** `Set-PlacesSettings -EnableBuildings 'Default:false'` — reverts to the pre-configuration default.

</details>

<details><summary>Fix 3 — Room/desk mailbox hidden from address lists</summary>

**When to use:** `HiddenFromAddressListsEnabled` returns `True` for a room or desk that should be bookable.

```powershell
Set-Mailbox -Identity <smtpAddress> -HiddenFromAddressListsEnabled $false
```

1. Confirm this wasn't hidden deliberately (e.g., a desk pool intentionally restricted to a specific team via `BookInPolicy` rather than via hiding).
2. Unhide, then allow standard Microsoft 365 directory sync propagation (usually well under an hour, but can take longer under load).
3. If the room/desk should remain hidden from the general directory but still bookable by a specific group, use `Set-CalendarProcessing -BookInPolicy <GroupDL>` instead of unhiding — hiding and booking-restriction are two different mechanisms often confused for each other.

**Rollback:** `Set-Mailbox -Identity <smtpAddress> -HiddenFromAddressListsEnabled $true` if re-hidden in error.

</details>

<details><summary>Fix 4 — Room/desk not on a RoomList</summary>

**When to use:** Object is correctly configured in the Places directory but still doesn't appear in Outlook/Teams Room Finder.

```powershell
Connect-ExchangeOnline
Add-DistributionGroupMember -Identity <roomListAlias> -Member <smtpAddress>
```

1. Confirm a RoomList actually exists for the building/site in question — if not, create one first (`New-DistributionGroup -Name <name> -RoomList`).
2. Add the room or desk-pool mailbox as a member.
3. This step is required **in addition to** Places directory parenting, not instead of it — the two systems are independently consulted by different client surfaces.

**Rollback:** `Remove-DistributionGroupMember -Identity <roomListAlias> -Member <smtpAddress>` if added in error.

</details>

<details><summary>Fix 5 — Object not correctly parented in the hierarchy (especially desk pools)</summary>

**When to use:** `Get-PlaceV3` shows a missing or floor-level-only `ParentId` for a workspace (desk pool) or individual desk.

```powershell
Connect-MicrosoftPlaces
$section = Get-PlaceV3 -AncestorId <floorPlaceId> | Where-Object DisplayName -eq '<sectionName>'
Set-PlaceV3 -Identity <smtpAddress> -ParentId $section.PlaceId
```

1. Remember the hard rule: **rooms** can parent directly to a Floor, but **workspaces and individual desks must parent to a Section** — a Section with zero other content is a perfectly valid, common pattern purely to satisfy this requirement.
2. If no Section exists yet on the target floor, create one first: `New-Place -Type Section -Name "<name>" -ParentId <floorPlaceId>`.
3. Re-run `Get-PlaceV3 -Identity <smtpAddress>` to confirm the new `ParentId` before telling the client it's resolved — this step is silent, there's no separate confirmation prompt.

**Rollback:** Re-parent to the prior `ParentId` if the change was made in error; re-parenting has no destructive side effect on existing bookings.

</details>

<details><summary>Fix 6 — Desk booking broke after the April 2026 licensing transition</summary>

**When to use:** A user who previously booked any desk freely now can't, and the timing lines up with April 1, 2026 or later.

1. Confirm whether the client's Teams Premium subscription **predates** April 1, 2026 and hasn't yet renewed — if so, premium desk booking continues working until that renewal, this is expected behavior, not a fault.
2. If the grace period has ended (or never applied), confirm a **space license** — Microsoft Teams Room, Microsoft Teams Shared Space, or Microsoft Teams Shared Space-Single Space — is assigned to the **specific desk object**, not to the user. Space licenses are per-space, a common point of confusion for admins used to per-user M365 licensing.
3. Note the free-tier nudge: 3 free MTSS-SS licenses are granted per purchased MTSS license — check whether the client already has unused capacity before recommending a new purchase.
4. Assign or reallocate the space license via the Places Management portal or the tenant's licensing admin center, then proceed to Fix 7 for propagation timing.

**Rollback:** N/A — licensing assignment, reversible by unassigning if done in error.

</details>

<details><summary>Fix 7 — Desk still not bookable 24-48h after license assignment</summary>

**When to use:** A space license was correctly assigned to a desk in `Reservable` mode, but booking remains unavailable well past the normal propagation window.

1. Confirm at least 24-48 hours have elapsed since assignment before treating this as a fault.
2. If the client needs it faster, use the documented manual refresh trick — **this cancels any bookings already scheduled on that desk that haven't started yet**, so warn the client first:
   ```powershell
   Set-PlaceV3 -Identity <smtpAddress> -Mode @{Name='Unavailable'}
   # then
   Set-PlaceV3 -Identity <smtpAddress> -Mode @{Name='Reservable'}
   ```
3. Re-verify bookability in the client (New Outlook/Teams calendar) after the mode flip completes.

**Rollback:** N/A once the refresh is done — but be aware the `Unavailable` step itself is the destructive action (see warning above), not something to roll back after the fact.

</details>

<details><summary>Fix 8 — User on an on-premises Exchange mailbox can't use Places</summary>

**When to use:** A user reports no Places app, no Places Finder, and work-location changes in Teams "don't seem to do anything."

1. Confirm the user's mailbox location: `Get-Mailbox -Identity <UPN> | Select-Object RecipientTypeDetails, ExchangeGuid` — an on-premises/hybrid mailbox is the root cause, not a Places misconfiguration.
2. Explain the hard limitation to the client: Places features (the app, Places Finder, Places Explorer, work-location sharing) are **not available** to users whose mailbox is hosted on-premises. Changes to work location in Teams appear to succeed in the UI but are only visible locally to that user — never shared with colleagues.
3. The only remediation is migrating the mailbox to Exchange Online — this is a mailbox-migration project, not a Places configuration fix. Legacy Room Finder in Outlook continues to work for these users in the meantime.

**Rollback:** N/A — this is a platform limitation, not a misconfiguration to undo.

</details>

<details><summary>Fix 9 — Building/Desk Administrator can't create a mailbox or rename a room</summary>

**When to use:** A delegated Places Building Administrator or Places Desk Administrator reports they can't create a new room/workspace mailbox, or can't rename/resize an existing one.

1. Confirm this is expected: **neither delegated role can create resource mailboxes or update room/workspace name and capacity** — this is a documented, permanent restriction, not a bug or an incomplete role grant.
2. Route the specific task to a **Places Administrator** (Entra ID-assigned) or an **Exchange Administrator**, who both have the necessary permissions.
3. If this comes up often for a given delegated admin, consider whether their scope of responsibility actually needs the full Places Administrator role instead — but weigh that against the standing least-privilege guidance before escalating the role.

**Rollback:** N/A — role boundaries working as designed.

</details>

---
## Escalation Evidence

```
=== Microsoft Places Escalation ===
Ticket #:
Client / Tenant:
Affected object (room/desk/workspace SMTP address):
PowerShell version used for diagnosis (must be 7.4+):
EnableBuildings setting (Y/N):
HiddenFromAddressListsEnabled (Y/N):
RoomList membership confirmed (Y/N):
Get-PlaceV3 ParentId / hierarchy level:
Space license assigned + type (MTR/MTSS/MTSS-SS/None):
Teams Premium legacy grace period still active (Y/N):
Time since last relevant config/license change:
Requesting user's mailbox location (Exchange Online / on-premises):
Requesting admin's Places role (Places Administrator / Building Administrator / Desk Administrator):
When did the issue start:
What changed (client-reported):
Escalation target:            [ ] Microsoft Support   [ ] Internal L3   [ ] Exchange room-mailbox owner
```

---
## 🎓 Learning Pointers

- **Places PowerShell hard-requires PowerShell 7.4+ — this is a real exception to "everything runs fine in Windows PowerShell 5.1."** Confirm the engineer's shell before assuming a scripting failure is a Places bug. See [Set up your account as a Places Admin](https://learn.microsoft.com/en-us/microsoft-365/places/management-overview).

- **Building visibility is a single tenant-wide OFF-by-default switch that sits entirely separate from hierarchy correctness.** A perfectly built Building→Floor→Section→Room tree is still invisible everywhere until `Set-PlacesSettings -EnableBuildings` is explicitly turned on — don't debug the hierarchy before checking this. See [Configure buildings and floors](https://learn.microsoft.com/en-us/microsoft-365/places/get-started/quick-setup-buildings-floors).

- **Desk pools (workspaces) and individual desks have a stricter parenting rule than rooms** — they must parent to a Section, never just a Floor, or they silently fail to appear in the new booking experience. This is the single most common Places-native (not Exchange-native) misconfiguration. See [Configure desk booking](https://learn.microsoft.com/en-us/microsoft-365/places/configure-desk-booking).

- **The April 1, 2026 licensing unbundling reversed which Places features need a premium grant.** Core booking, Places Finder, and Places Explorer are now free for standard M365/Teams users; only individual desk booking, autorelease, and occupancy analytics need a per-space (not per-user) license — the opposite direction from most Microsoft 365 feature-gating changes, worth explicitly re-explaining to clients who remember the old model. See [Microsoft Places overview](https://learn.microsoft.com/en-us/microsoft-365/places/places-overview).

- **RoomList membership and Places directory placement are two independent systems that both gate visibility, in different clients.** A room can be perfectly configured in one and completely missing from the other — always check both rather than assuming success in the Places Management portal means Outlook Room Finder will also work. See [Configure buildings and floors — Troubleshooting](https://learn.microsoft.com/en-us/microsoft-365/places/get-started/quick-setup-buildings-floors#troubleshooting).

- **On-premises/hybrid mailboxes are a hard, currently-unfixable exclusion from Places** — not a licensing or configuration gap. Set this expectation early with any client mid-migration to Exchange Online rather than troubleshooting it as a bug. See [Microsoft Places overview](https://learn.microsoft.com/en-us/microsoft-365/places/places-overview).
