# Purview Time-Boxed Role Group Assignments — Hotfix Runbook (Mode B: Ops)
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

**This is a new native capability, not a bug in an old one.** Since roughly late July–August 2026,
Microsoft Purview supports setting an **expiration date (1 day to 2 years)** directly on role group
member assignments — for both new and existing members. When the date is reached, Purview automatically
removes that specific assignment. Most tickets here are "why did my access disappear" or "how do I set
this up," not a genuine defect. This is portal-only — there is no dedicated PowerShell cmdlet for
setting expiration as of this writing; `Get-RoleGroupMember` is the only reliable read-side check.

```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>

# 1. Who is currently a member of the role group in question, and via which path (direct vs. group)?
Get-RoleGroupMember -Identity "<RoleGroupName>" | Select-Object Name, RecipientType, DisplayName

# 2. Does the user hold the SAME role group through more than one path? (each has its own expiration)
Get-RoleGroup | Where-Object { (Get-RoleGroupMember -Identity $_.Name -ErrorAction SilentlyContinue).Name -contains "<UserOrGroupName>" } |
    Select-Object Name

# 3. Does the user have an overlapping Microsoft Entra role granting the same effective permission?
#    (Purview role-group expiration does NOT touch Entra role assignments)
Get-MgUserAppRoleAssignment -UserId "<user@contoso.com>" | Select-Object AppRoleId, ResourceDisplayName
```

| Result | Interpretation |
|---|---|
| User reports losing Purview access with no warning | Expected — **no advance expiration notification exists**. Direct them to the *My Permissions* page in the Purview portal to check the expiration date of any active assignment. Go to Fix 1. |
| User needs access restored temporarily | → Fix 1: Extend or reset the expiration via the Purview portal (no PowerShell path exists). |
| User needs the assignment to become permanent | → Fix 2: Set expiration to "No expiry." |
| eDiscovery Manager/Administrator role member lost access unexpectedly | → NOT this feature — expiration is explicitly unsupported for `eDiscovery Manager` and `eDiscovery Administrator` role groups; investigate as a separate removal/change. See `eDiscovery-B.md`. |
| User still has access despite an expired assignment | → Fix 3: Check for a second, still-valid assignment path (direct + group, or overlapping Entra role) before assuming the expiration silently failed. |
| Admin wants to bulk-apply expiration to many existing (currently permanent) assignments | → Fix 4: Existing assignments are **not** auto-converted — each must be edited individually or via a portal bulk-select. |
| Security group assigned to a Purview role group in a GCC/sovereign cloud tenant, expiration option missing | → Expected — security-group role-group assignment (and by extension its expiration UI) is currently limited to Microsoft 365 commercial cloud. |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
[Microsoft Purview portal — Settings > Roles and scopes > Role groups]
        |
[Role group supports expiring assignments]
  ├─ ALL built-in and custom role groups EXCEPT:
  │     ├─ eDiscovery Manager   (expiration NOT supported)
  │     └─ eDiscovery Administrator  (expiration NOT supported)
        |
[Member type]
  ├─ Individual user  → direct expiration on that specific assignment
  └─ Security group   → expiration applies to the group's role-group assignment as a whole
        (Microsoft 365 commercial cloud only — not available for GCC/sovereign clouds
         at this time)
        |
[Expiration value — set independently per assignment]
  ├─ 1 day to 2 years from the current date
  ├─ "No expiry" — permanent, the pre-existing default behavior
  └─ Existing (pre-feature) assignments default to "No expiry" until an admin explicitly edits them
        |
[At expiration]
  └─ Purview automatically removes ONLY that specific role-group assignment
        ├─ Does NOT touch a separate, still-valid assignment to the SAME role group via a
        │     different path (e.g., direct membership vs. security-group membership)
        └─ Does NOT touch any overlapping Microsoft Entra ID role granting similar permissions
              (a structurally separate system — see EntraID/ for PIM-based Entra role expiration)
        |
[User-facing signal]
  └─ "My Permissions" page in the Purview portal shows the LATEST expiration date across all of
        a user's active assignments — no proactive notification is sent before expiry
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm current membership and path**
```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>
Get-RoleGroupMember -Identity "<RoleGroupName>" | Select-Object Name, RecipientType
```
This shows current members but does **not** expose the expiration date via PowerShell — expiration
metadata is portal-only as of this writing. Cross-check the Purview portal's Members tab for the
`Expires on` column.

**2. Check the Purview portal directly for expiration state**
```
Purview portal > Settings > Roles and scopes > Role groups > <RoleGroupName> > Members tab
```
Each member row shows either an expiration date or "No expiry." This is the authoritative source —
there is no equivalent read-only cmdlet property exposed yet for this specific field.

**3. Rule out multiple assignment paths**
A user commonly gets the same role group through both a direct assignment and a security-group
assignment. If one expires while the other remains active, the user keeps access — this is expected
overlap behavior, not a bug in the expiring one.
```powershell
Get-RoleGroupMember -Identity "<RoleGroupName>" |
    Where-Object { $_.RecipientType -eq "MailUniversalSecurityGroup" }
# Then separately check group membership of the affected user:
Get-DistributionGroupMember -Identity "<SecurityGroupName>" | Where-Object { $_.PrimarySmtpAddress -eq "<user@contoso.com>" }
```

**4. Rule out an overlapping Microsoft Entra role**
```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
Get-MgUserAppRoleAssignment -UserId "<user@contoso.com>" -ErrorAction SilentlyContinue
```
Purview role-group expiration is a Purview-native mechanism only; a user can independently retain
overlapping capability through a directory role such as Compliance Administrator assigned in Entra ID,
which this feature does not touch.

**5. Confirm the role group even supports expiration**
Check the role group name against the exclusion list: `eDiscovery Manager` and `eDiscovery
Administrator` do not support automatic expiration. All other built-in and custom role groups do.

---
## Common Fix Paths

<details><summary>Fix 1 — Extend or reset an expiring/expired assignment</summary>

Use when: a user needs continued access and their assignment has expired or is about to.

```
1. Sign in to the Microsoft Purview portal (https://purview.microsoft.com/) as an admin with
   Role Management permissions.
2. Settings > Roles and scopes > Role groups > select the role group.
3. Members tab > select the user or security group > Edit expiration.
4. Choose a new expiration date (1 day - 2 years) or select "No expiry."
5. Apply. The change takes effect immediately; no propagation delay expected beyond normal portal
   caching (a few minutes).
```

**Rollback:** Re-open Edit expiration and set a different date, or select "No expiry" to remove the
time bound entirely.

</details>

<details><summary>Fix 2 — Make an assignment permanent</summary>

Use when: the temporary need has become an ongoing one and the org wants to stop managing renewal.

```
1. Purview portal > Settings > Roles and scopes > Role groups > <RoleGroupName> > Members.
2. Select the member > Edit expiration > choose "No expiry" > Apply.
```

**Rollback:** Re-apply a specific expiration date later if the access should become time-bound again.

**Consider instead:** if the goal is genuine just-in-time access rather than "permanent until someone
remembers to revisit it," evaluate PIM for Groups (User → PIM-managed security group → Purview role
group) for a full activation-based workflow rather than a static expiration date. See Playbook 2 in
`TimeBoxedRoleGroups-A.md`.

</details>

<details><summary>Fix 3 — User retains access after an assignment expired</summary>

Use when: an assignment shows as expired/removed in the portal, but the user reports continued access.

```
1. Run Diagnosis Steps 3 and 4 to check for a second direct/group assignment path and any
   overlapping Entra ID directory role.
2. If a second Purview assignment path is found, decide whether it should also be time-boxed or
   removed — expiring one path does not revoke access still granted by another.
3. If an overlapping Entra role is found, that is out of scope for this feature entirely; handle it
   as a separate Entra role-assignment review (see EntraID/Troubleshooting/ for PIM-based Entra role
   management).
4. If neither is found and access genuinely persists past the documented expiration, capture the
   Escalation Evidence below — this would be a genuine platform defect.
```

**Rollback:** N/A — diagnostic only.

</details>

<details><summary>Fix 4 — Bulk-apply expiration to existing permanent assignments</summary>

Use when: an admin wants to retroactively time-box a set of already-permanent role group assignments
as part of a least-privilege cleanup initiative.

```
1. There is no bulk PowerShell cmdlet for this — existing assignments are NOT automatically given
   an expiration when the feature becomes available in a tenant; they remain "No expiry" until
   explicitly edited.
2. Use Get-RoleGroupMember (Diagnosis Step 1) to build the full list of members per role group that
   need review.
3. For each member, open the role group in the portal, select the member(s), and use Edit expiration
   — the portal does support multi-select for bulk editing within a single role group's Members view.
4. Track progress in a spreadsheet/ticket since there is no cmdlet-based verification of the
   resulting expiration dates — the portal Members list ("Expires on" column) is the only
   authoritative source.
```

**Rollback:** Re-open Edit expiration on any member and set "No expiry" to undo.

</details>

---
## Escalation Evidence

```
PURVIEW TIME-BOXED ROLE GROUP ESCALATION
=========================================
Date/Time                              :
Role group name                        :
Affected user/security group           :
Assignment path (direct/group)         :
Expiration date shown in portal        :
Expected behavior                      : Access should have expired / Access should still be active
Actual behavior                        :
Other assignment paths checked?        : Yes / No — result:
Overlapping Entra role checked?        : Yes / No — result:
Role group is eDiscovery Mgr/Admin?    : Yes / No (expiration unsupported if Yes)
Steps Already Tried                    :
```

---
## 🎓 Learning Pointers

- **This closes a long-standing gap between Purview and Entra PIM** — for years, the only way to get
  time-bound Purview access was to build an indirect PIM-for-Groups chain (security group → PIM
  eligibility → Purview role group). This feature makes simple time-boxing native, though PIM-for-Groups
  remains the right tool for full just-in-time activation workflows. [Auto-Expiring Role Group Assignments in Microsoft Purview](https://blog.admindroid.com/microsoft-purview-role-group-permission-expiration/)
- **There is no user notification before expiry** — build this into any client-facing process
  documentation; users must proactively check "My Permissions," or admins must track renewal dates
  externally (ticket system, calendar reminder) for anything time-critical like an active investigation.
- **Expiration is per-assignment, not per-user** — a user with the same role group granted two
  different ways has two independent expiration clocks. Don't assume removing/expiring one path fully
  revokes access.
- **eDiscovery Manager and eDiscovery Administrator are permanent exclusions** — don't spend time
  looking for an expiration option on those two role groups specifically; it doesn't exist.
- **This does not replace periodic access reviews** — expiration controls *how long* an assignment
  lasts, not *whether* it should exist in the first place. Recommend continuing scheduled access
  reviews (Entra ID Governance) alongside this feature, not instead of it.
