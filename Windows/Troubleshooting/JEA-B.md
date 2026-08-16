# Just Enough Administration (JEA) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

Run these first. Results tell you which fix path to take.

```powershell
# 1. Does the JEA endpoint exist at all on this machine?
Get-PSSessionConfiguration | Select-Object Name, Permission

# 2. Is the connecting user actually mapped to a role in this endpoint?
(Get-PSSessionConfiguration -Name <endpointName>).RoleDefinitions

# 3. Test-connect and see exactly which commands are visible to this user
Enter-PSSession -ComputerName <server> -ConfigurationName <endpointName>
Get-Command  # inside the session — this is the user's REAL effective command set

# 4. Role capability file syntax valid? (a bad .psrc silently breaks the whole endpoint)
Test-PSSessionConfigurationFile -Path <pathToPsscFile>

# 5. Is the account actually a virtual account, or did it fall back to something else?
whoami /all  # run INSIDE the JEA session, not on the host
```

| If | Then |
|----|------|
| `Get-PSSessionConfiguration` doesn't list the expected endpoint | Never registered, or registered under a different name than the client expects → **Fix 1** |
| Connection fails with "Access is denied" before a session even opens | User/group not in `RoleDefinitions`, or fails a `RequiredGroups` conditional access rule → **Fix 2** |
| Session opens but a cmdlet the user should have access to isn't visible | Command wasn't added to `VisibleCmdlets`/`VisibleFunctions` in the role capability file, or a typo in the name → **Fix 3** |
| A parameter is missing or a value gets rejected on an otherwise-visible cmdlet | Cmdlet is scoped with a restricted parameter set or `ValidateSet`/`ValidatePattern` that doesn't include what's needed → **Fix 4** |
| User reports they can do MORE than intended | Merge-across-roles is additive (most permissive wins) — check ALL role capabilities the user's groups map to, not just one → **Fix 5** |
| Session works from one server but not another with the "same" endpoint | Role capability file resolved from a DIFFERENT, same-named file on that machine — search-order isn't deterministic → **Fix 6** |
| A custom function in the role capability behaves unexpectedly (unrestricted access inside it) | Function bodies run OUTSIDE JEA's language constraints by design — this is expected, not a bypass bug → **Fix 7** (confirm by-design) |
| Registering/re-registering the endpoint dropped all active remoting sessions | Expected — `Register-`/`Unregister-PSSessionConfiguration` restarts WinRM — should only run in a maintenance window → **Fix 8** (confirm by-design) |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
PowerShell 5.0+ present (JEA is a built-in capability, no separate install)
        │
Role capability file(s) (.psrc) authored — one or more, each listing VisibleCmdlets/
   Functions/Providers/ExternalCommands for a specific role
        │
Role capability file(s) placed in a "RoleCapabilities" subfolder of a PowerShell module
   on $Env:PSModulePath (module folder name and .psd1/.psm1 root file must match)
        │
Session configuration file (.pssc) authored — defines RunAsVirtualAccount/GMSA identity,
   RoleDefinitions (user/group → role capability mapping), TranscriptDirectory, RequiredGroups
        │
Session configuration file syntax validated (Test-PSSessionConfigurationFile)
        │
Endpoint registered (Register-PSSessionConfiguration) — THIS RESTARTS WinRM, dropping all
   active remoting sessions on the machine
        │
Connecting user/group is a key in RoleDefinitions (exact match required — computer name,
   not "localhost" or a wildcard, for local groups)
        │
[If RequiredGroups set] connecting user additionally satisfies the conditional access rule
   (e.g., a JIT-elevation group, MFA/smartcard-logon group)
        │
Session opens in NoLanguage mode, RunAs identity assumed, ONLY the merged (most-permissive-
   wins) set of VisibleCmdlets/Functions/Providers/ExternalCommands across ALL matching roles
        │
[If TranscriptDirectory set] Local System writes a full transcript for the session
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the endpoint is actually registered on this machine, under the name the client expects:**
```powershell
Get-PSSessionConfiguration | Select-Object Name, Permission
```
Endpoint missing entirely → Fix 1. Present but the client is targeting a different `-ConfigurationName` → confirm the exact name with the client, this is a naming mismatch, not a JEA fault.

**2. Confirm the connecting user/group is actually mapped in RoleDefinitions:**
```powershell
(Get-PSSessionConfiguration -Name <endpointName>).RoleDefinitions
```
User's group not listed as a key → Fix 2. This is an exact-match lookup — a user in a *nested* group under one of the listed groups is NOT automatically covered unless PowerShell's own group-membership resolution (which does expand nested AD groups) confirms it; verify with `Get-ADGroupMember -Recursive` if in doubt.

**3. If the session opens but access is still denied, check for a RequiredGroups conditional access rule:**
```powershell
(Get-PSSessionConfiguration -Name <endpointName>).RequiredGroups
```
A user can be correctly listed in `RoleDefinitions` and still get denied if they don't separately satisfy `RequiredGroups` (e.g., not currently a member of a JIT/PIM-elevated group, or didn't authenticate with MFA/smartcard when that's required) — Fix 2 covers both causes.

**4. Test the actual effective command set from inside a live session, not from reading the .psrc file:**
```powershell
Enter-PSSession -ComputerName <server> -ConfigurationName <endpointName>
Get-Command
Get-Help about_Command_Precedence  # if a cmdlet behaves differently than expected
```
Missing cmdlet the user should have → Fix 3. Cmdlet visible but a needed parameter/value is rejected → Fix 4.

**5. If the user can do MORE than intended, check every role their groups map to, not just the one you expect:**
```powershell
$config = Get-PSSessionConfiguration -Name <endpointName>
$config.RoleDefinitions
# For a user in multiple mapped groups, JEA merges ALL applicable role capabilities and grants
# the MOST PERMISSIVE combined result — a single overly broad role anywhere in the chain
# widens access for every user who touches it, even via an otherwise-narrow second role
```
This is Fix 5 — over-permissioning almost always traces back to one role capability file being broader than intended, not a JEA merge bug.

**6. If behavior differs between servers using the "same" endpoint name, confirm which .psrc file actually resolved:**
```powershell
# Role capability search order is NOT guaranteed alphabetical or otherwise deterministic
# across machines with more than one module on $Env:PSModulePath containing a same-named .psrc
Get-Module -ListAvailable | Where-Object { Test-Path (Join-Path $_.ModuleBase 'RoleCapabilities') }
```
Multiple same-named `.psrc` files found across different modules → Fix 6 (rename to guarantee uniqueness).

---

## Common Fix Paths

<details><summary>Fix 1 — Endpoint not registered, or registered under an unexpected name</summary>

**Symptom:** `Get-PSSessionConfiguration` doesn't list the endpoint name the client is targeting.

```powershell
# Confirm what IS registered
Get-PSSessionConfiguration | Select-Object Name

# Register the missing endpoint (requires local admin; restarts WinRM — see Fix 8)
Register-PSSessionConfiguration -Path <pathToPsscFile> -Name <endpointName> -Force
```

**Rollback:** `Unregister-PSSessionConfiguration -Name <endpointName> -Force` if registered in error — this also restarts WinRM.

</details>

<details><summary>Fix 2 — Access denied before a session opens</summary>

**Symptom:** Connection attempt fails immediately with an access-denied error, before any JEA-scoped command runs.

```powershell
# Confirm exact RoleDefinitions keys — must be COMPUTERNAME\GroupName for local groups,
# never "localhost" or a wildcard
$Env:COMPUTERNAME
(Get-PSSessionConfiguration -Name <endpointName>).RoleDefinitions

# Confirm the user's actual group membership (including nested AD groups)
Get-ADGroupMember -Identity <expectedGroupName> -Recursive | Where-Object SamAccountName -eq <username>

# If RequiredGroups is set, confirm the user currently satisfies it (e.g., JIT-elevated group membership)
(Get-PSSessionConfiguration -Name <endpointName>).RequiredGroups
```

If the group mapping and RequiredGroups both check out but access still fails, confirm the endpoint's own WinRM-level permission (`Get-PSSessionConfiguration | Select Name, Permission`) — a JEA `RoleDefinitions` entry doesn't override a WinRM ACL that separately denies the connecting identity.

**Rollback:** N/A — diagnostic only until the specific gap (missing role mapping vs. failed conditional access) is confirmed.

</details>

<details><summary>Fix 3 — Expected cmdlet/function not visible in the session</summary>

**Symptom:** `Get-Command` inside the JEA session doesn't list a cmdlet the user is supposed to have access to.

```powershell
# Locate the role capability file actually in effect for this endpoint/role
Get-Module -ListAvailable | Where-Object { Test-Path (Join-Path $_.ModuleBase "RoleCapabilities\<roleName>.psrc") }

# Edit the .psrc — add the missing cmdlet/function name to VisibleCmdlets or VisibleFunctions
# VisibleCmdlets = @('Get-Service', 'Restart-Service', '<newCmdletName>')

# Re-test syntax before the change takes effect for new sessions
Test-PSSessionConfigurationFile -Path <pathToPsscFile>
```

Changes to a role capability file take effect for **new** JEA sessions immediately — no re-registration or WinRM restart required, unlike changes to the session configuration (.pssc) file itself.

**Rollback:** Remove the added entry from `VisibleCmdlets`/`VisibleFunctions` if it was added in error; takes effect for the next new session.

</details>

<details><summary>Fix 4 — Cmdlet visible but a parameter/value is rejected</summary>

**Symptom:** The cmdlet itself runs, but a specific parameter is missing, or a value passed to an allowed parameter gets rejected.

```powershell
# Check the current scoping in the .psrc — look for a restricted Parameters list or
# ValidateSet/ValidatePattern that doesn't include what's needed
VisibleCmdlets = @(
    @{ Name = 'Restart-Service'; Parameters = @{ Name = 'Name'; ValidateSet = @('Dns', 'Spooler') } }
)

# Widen the ValidateSet or switch to ValidatePattern if the value list needs to be broader
# (remember: you cannot apply both to the same cmdlet — ValidatePattern silently overrides
#  ValidateSet if both are present)
```

Common parameters (`-Verbose`, `-ErrorAction`, etc.) are always allowed and never need explicit listing — don't add them to `Parameters`, it has no effect and adds noise.

**Rollback:** Revert the `Parameters`/`ValidateSet`/`ValidatePattern` change if it over-widens access; re-test with `Test-PSSessionConfigurationFile`.

</details>

<details><summary>Fix 5 — User can do more than intended (over-permissioned)</summary>

**Symptom:** A user reports (or an audit finds) access to a cmdlet or parameter value beyond what any single role was supposed to grant.

```powershell
# Enumerate EVERY role the user's group memberships map to — not just the "obvious" one
$config = Get-PSSessionConfiguration -Name <endpointName>
$config.RoleDefinitions | Where-Object { <userGroupList> -contains $_.Name }
```

JEA's merge behavior is unconditionally additive across matching roles for a given user: if cmdlet X is unrestricted in ANY role the user matches, it is unrestricted for that user in the session — full stop, even if a different matching role scopes it tightly. The fix is almost always narrowing the OVER-BROAD role, not the narrow one.

**Rollback:** N/A — this is a configuration tightening, not a reversible "undo"; document the prior (over-broad) state before editing for audit purposes.

</details>

<details><summary>Fix 6 — Same endpoint name behaves differently across servers</summary>

**Symptom:** Two servers both show the endpoint registered under the same name, but users report different available commands.

```powershell
# Role capability search order is NOT deterministic when multiple modules contain a
# same-named .psrc file — find every candidate on each machine
Get-Module -ListAvailable | ForEach-Object {
    $rcPath = Join-Path $_.ModuleBase 'RoleCapabilities'
    if (Test-Path $rcPath) { Get-ChildItem $rcPath -Filter '*.psrc' }
}
```

If more than one `.psrc` with the same base name exists across different modules on `$Env:PSModulePath`, rename one to guarantee a unique name — Microsoft explicitly documents this as "strongly recommended" rather than optional, precisely because search order isn't alphabetical or otherwise predictable.

**Rollback:** Renaming a role capability file requires updating the matching `RoleDefinitions` reference in the session configuration and re-registering the endpoint (WinRM restart — schedule accordingly).

</details>

<details><summary>Fix 7 — Custom function in a role capability seems to bypass JEA constraints</summary>

**Symptom:** A custom `FunctionDefinitions` entry in a `.psrc` appears to access the file system, registry, or other resources not explicitly listed in `VisibleProviders`.

```powershell
# This is EXPECTED, not a bypass bug — function bodies defined in FunctionDefinitions
# run in the system's DEFAULT language mode, NOT NoLanguage mode, and are NOT subject
# to JEA's provider/command constraints internally
```

The constraint that matters is which functions are listed in `VisibleFunctions` — once a function is exposed, its *internal* implementation can do anything the RunAs identity is capable of, by design. This is exactly why Microsoft's own guidance stresses careful authoring of custom functions and warns against piping user input directly into cmdlets like `Invoke-Expression` inside them.

**Rollback:** N/A — confirmation only. If genuine unintended capability is found, the fix is rewriting the function body more restrictively, not a JEA configuration change.

</details>

<details><summary>Fix 8 — Registering/unregistering dropped active sessions</summary>

**Symptom:** All PowerShell remoting sessions, DSC runs, and management tool connections on the machine dropped at the moment `Register-PSSessionConfiguration` or `Unregister-PSSessionConfiguration` ran.

```powershell
# Expected — both cmdlets restart the WinRM service as part of their operation, with no
# quieter alternative for a single-machine registration/update
```

This is documented, by-design behavior, not a fault. Always schedule JEA endpoint registration or updates for a maintenance window on production machines — never as an ad hoc same-ticket change during business hours.

**Rollback:** N/A — confirmation only; plan future registration changes around this constraint.

</details>

---

## Escalation Evidence

```
=== JEA Endpoint Failure — Ticket Evidence ===

Date/Time:                          _______________
Server / Endpoint name:             _______________
Connecting user / group:            _______________
Reported symptom:                   _______________  (access-denied / missing-cmdlet / over-permissioned / cross-server-inconsistency)

--- Commands Run ---
Endpoint registered (Y/N):               _______________
RoleDefinitions entry for user's group:  _______________
RequiredGroups satisfied (Y/N, if set):  _______________
Effective Get-Command output (session):  _______________
Role capability file(s) resolved from:   _______________

--- Steps Taken ---
[ ] Confirmed endpoint registered under the expected name
[ ] Confirmed user/group present in RoleDefinitions
[ ] Confirmed RequiredGroups conditional access satisfied (if applicable)
[ ] Tested actual effective command set from inside a live session
[ ] Checked ALL roles the user's groups map to (not just the expected one)
[ ] Confirmed which .psrc file resolved if search order was in question
```

---

## 🎓 Learning Pointers

- **Always test the effective command set from inside a live session (`Get-Command` after `Enter-PSSession`), never by reading the `.psrc` file alone.** Role merging across multiple matching roles, search-order non-determinism across modules, and the always-allowed common-parameter set all mean the file's contents and the session's real behavior can diverge in ways that are easy to miss on paper. [MS Docs: JEA Role Capabilities](https://learn.microsoft.com/en-us/powershell/scripting/security/remoting/jea/role-capabilities)

- **JEA's role-merging is unconditionally additive and always resolves to the MOST permissive combined result.** A user belonging to two groups, each mapped to a different role, gets the union of both roles' access — including an unrestricted `ValidateSet`/`ValidatePattern` from either role overriding a more restrictive one from the other. Over-permissioning almost never comes from a "JEA bug" — it comes from one role capability file being broader than whoever wrote the narrower, intended-to-be-restrictive role expected. [MS Docs: How role capabilities are merged](https://learn.microsoft.com/en-us/powershell/scripting/security/remoting/jea/role-capabilities#how-role-capabilities-are-merged)

- **Role capability search order across multiple same-named `.psrc` files is explicitly documented as non-deterministic — not alphabetical, not "first module wins" reliably.** Microsoft's own guidance is to keep role capability filenames unique across the whole `$Env:PSModulePath`; treat any cross-server behavioral inconsistency under the "same" endpoint name as a search-order collision until proven otherwise.

- **`Register-PSSessionConfiguration` and `Unregister-PSSessionConfiguration` both restart the WinRM service** — every active remoting session, DSC run, and WMI-over-WinRM operation on the machine drops the moment either command runs. Treat any JEA endpoint change as a maintenance-window activity, the same discipline this repo already applies to other WinRM-service-affecting changes (see `WinRM-A.md`).

- **A custom function's own body is NOT subject to JEA's language-mode or provider constraints** — it runs in the default language mode of the RunAs identity, meaning it can touch the file system, registry, or anything else that identity is capable of, regardless of what's listed in `VisibleProviders`. The security boundary lives entirely in which functions get exposed via `VisibleFunctions`, not in what those functions' code is technically capable of once exposed — review custom function bodies with the same scrutiny as granting full admin to whatever they touch. [MS Docs: Creating custom functions](https://learn.microsoft.com/en-us/powershell/scripting/security/remoting/jea/role-capabilities#creating-custom-functions)

- **This is a distinct technology from the WinRM listener/endpoint configuration covered in `WinRM-A.md`/`WinRM-B.md`.** WinRM governs whether remoting can happen at all (listener, ports, TrustedHosts, authentication); JEA governs what a specific remoted-in user can DO once connected, via a custom, role-scoped endpoint layered on top of WinRM rather than replacing it. A ticket about "can't connect at all" belongs in the WinRM files; a ticket about "connected, but has access to more/less than expected" belongs here.
