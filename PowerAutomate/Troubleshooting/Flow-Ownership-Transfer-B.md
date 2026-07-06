# Power Automate Flow Ownership Transfer — Hotfix Runbook (Mode B: Ops)
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

Trigger for this runbook: an employee is being offboarded (or already was, and flows they own just stopped running), and you need to find/transfer their flows before disabling or deleting their account.

```powershell
# Requires: Microsoft.PowerApps.Administration.PowerShell module
Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Force -Scope CurrentUser -AllowClobber
Install-Module -Name Microsoft.PowerApps.PowerShell -Force -Scope CurrentUser -AllowClobber -AcceptLicense

# 1. Authenticate as an environment admin / tenant admin
Add-PowerAppsAccount

# 2. Find every flow owned by the departing user, across all environments
$upn = "<departing.user@contoso.com>"
Get-AdminPowerAppEnvironment | ForEach-Object {
    Get-AdminFlow -EnvironmentName $_.EnvironmentName |
        Where-Object { $_.CreatedBy.userPrincipalName -eq $upn -or $_.CreatedBy.email -eq $upn }
} | Select-Object DisplayName, EnvironmentName, FlowName, Enabled

# 3. For each flow found, check who ELSE is already a co-owner (if anyone)
Get-AdminFlowOwnerRole -EnvironmentName "<envId>" -FlowName "<flowId>"
```

| Result | Interpretation |
|---|---|
| Flows returned in step 2, zero co-owners in step 3 | Flow has a **single point of failure** — must transfer ownership before/at disable, go to Fix 1 |
| Flows returned, co-owner already exists | Flow will keep running when owner is disabled, but connections inside it may still reference the departing user's credentials — go to Fix 2 |
| Flow shows `Enabled: False` already, ticket says "flow stopped working" | Account was already disabled and Power Automate auto-suspended the flow — go to Fix 3 |
| No flows found for the UPN, but user swears they "built the onboarding flow" | They may have built it in a **different environment** (e.g., Default vs. a dedicated one) or under a different licensed identity — re-run step 2 with `-EnvironmentName` omitted confirmed across *all* environments, and check Dataverse/Copilot Studio too |
| Flow found and owned solely by a **service account** already, not a real user | Not actually at risk from this offboarding — verify service account itself isn't also being disabled |

---
## Dependency Cascade

<details><summary>What must be true for a flow to keep running after its owner leaves</summary>

```
Flow object (owned by User A)
      │
      ▼
Connections referenced by flow's actions (SharePoint, Outlook, Dataverse, HTTP, etc.)
      │
      ▼
Each connection authenticates as EITHER:
   - The flow owner's own delegated identity  ◄── breaks immediately when owner is disabled
   - A service account / dedicated connection shared to the flow  ◄── survives owner disable
      │
      ▼
Flow's trigger fires → Power Automate evaluates connection validity
      │
      ▼
If ANY connection's underlying identity is disabled/deleted/unlicensed:
   → Flow run fails at that action ("Connection requires attention" / 401/403)
   → After repeated failures OR owner account disable, Microsoft may auto-suspend the flow entirely
      │
      ▼
Co-owners (if assigned via Get-AdminFlowOwnerRole / flow Share panel) can still see, edit,
and re-authenticate the flow's connections — but ONLY if added BEFORE the original owner left
```

The critical failure mode: ownership and connection identity are two *separate* things. Adding a co-owner does not automatically re-point the connections inside the flow's actions to that co-owner's identity — it only grants edit access. Each connection must be individually re-authenticated by the new owner, or the flow keeps trying to run as the departed user until it fails.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the flow is actually owned by (not just shared with) the departing user.**
   ```powershell
   Get-AdminFlow -EnvironmentName "<envId>" -FlowName "<flowId>" | Select-Object DisplayName, CreatedBy
   ```
   Expected: `CreatedBy` matches the departing user's object ID/UPN. If it's a co-owner situation instead, the flow is lower-risk — verify the actual owner separately.

2. **Enumerate every connection the flow depends on and whose identity backs each one.**
   In the Power Automate portal: flow → Edit → each action showing a connection icon → "Change connection" reveals the signed-in identity. There is no fully reliable PowerShell equivalent for connection-level identity across all connector types, so plan for a manual pass on business-critical flows.

3. **Check whether the flow has already failed runs due to the account being disabled.**
   ```powershell
   Get-AdminFlow -EnvironmentName "<envId>" -FlowName "<flowId>" | Select-Object Enabled, State
   Get-FlowRunHistory -EnvironmentName "<envId>" -FlowName "<flowId>" -TriggerHistoryHint  # see PowerAutomate/Scripts/Get-FlowRunHistory.ps1
   ```
   Expected/Good: `Enabled: True`, recent runs `Succeeded`.
   Bad: `Enabled: False` with `State` showing suspended, or recent runs `Failed` with 401/403 on a connector action — confirms identity-dependency failure, not a logic bug.

4. **Confirm a target co-owner/successor account exists and is licensed for Power Automate at the same tier the flow requires.**
   Check whether the flow uses any premium connector (HTTP, SQL, Dataverse) — the new owner needs a Power Automate Premium license or the flow will fail with a licensing error even after ownership transfers cleanly.

---
## Common Fix Paths

<details><summary>Fix 1 — Transfer ownership before the account is disabled (preferred path — do this during offboarding, not after)</summary>

```powershell
# Add a co-owner with full edit rights
Set-AdminFlowOwnerRole -EnvironmentName "<envId>" -FlowName "<flowId>" -RoleName "CanEdit" -PrincipalType "User" -PrincipalObjectId "<newOwnerObjectId>"
```
Then, as the **new owner**, open the flow in the Power Automate portal and manually re-authenticate every connection ("Fix connection" / "Change connection" on each action) so the flow no longer depends on the departing user's credentials. Ownership role assignment alone does NOT migrate connection identities — this manual step is mandatory.

**Rollback:** remove the added co-owner role if transferred in error:
```powershell
Remove-AdminFlowOwnerRole -EnvironmentName "<envId>" -FlowName "<flowId>" -RoleName "CanEdit" -PrincipalType "User" -PrincipalObjectId "<newOwnerObjectId>"
```

</details>

<details><summary>Fix 2 — Co-owner exists but connections still reference the departing user</summary>

Have the co-owner (or an admin with edit rights) open the flow → for each action with a connector icon → "Change connection" → select or create a connection under their own identity → Save. Re-test with a manual trigger run.

If the flow uses a **service account** connection pattern instead (recommended going forward — see Learning Pointers), point all actions at the shared service account's existing connection rather than any individual's.

</details>

<details><summary>Fix 3 — Flow already auto-suspended after the account was disabled</summary>

```powershell
# Re-enable the flow after fixing ownership/connections (Fix 1 first)
Enable-AdminFlow -EnvironmentName "<envId>" -FlowName "<flowId>"
```
If `Enable-AdminFlow` fails with a connection error, the connections still need manual re-authentication (Fix 2) before the flow will stay enabled. Re-enabling without fixing the underlying connection just produces the same suspension again on next failed run.

</details>

<details><summary>Fix 4 — Bulk sweep: transfer ALL flows for a departing user in one pass</summary>

```powershell
$upn = "<departing.user@contoso.com>"
$newOwnerId = "<newOwnerObjectId>"

Get-AdminPowerAppEnvironment | ForEach-Object {
    $env = $_.EnvironmentName
    Get-AdminFlow -EnvironmentName $env | Where-Object {
        $_.CreatedBy.userPrincipalName -eq $upn -or $_.CreatedBy.email -eq $upn
    } | ForEach-Object {
        Write-Host "Transferring $($_.DisplayName) in $env"
        Set-AdminFlowOwnerRole -EnvironmentName $env -FlowName $_.FlowName -RoleName "CanEdit" -PrincipalType "User" -PrincipalObjectId $newOwnerId
    }
}
```
This grants co-ownership at scale but still requires the manual per-connection re-authentication step in Fix 1/2 for each flow — script it as a checklist handoff to the new owner, not a fully automated fix, since Microsoft does not expose a supported API to reassign connection identities programmatically.

</details>

---
## Escalation Evidence

```
Flow Ownership Transfer Escalation — <date>
Departing user: <UPN>
Offboarding date/account disable date: <date>
Flows found owned by departing user: <count + list from triage step 2>
Flows with NO existing co-owner (single point of failure): <list>
Flows using premium connectors requiring a licensed new owner: <list>
New owner/successor identified: <UPN or "none identified — escalating">
Connections successfully re-authenticated: <list / in progress>
Flows still failing after transfer attempt: <list>
Escalating because: <e.g. no successor owner has been assigned by the business, premium license needed and not yet provisioned, flow logic itself references departing user's mailbox/OneDrive as a data source (not just auth)>
```

---
## 🎓 Learning Pointers
- Ownership (who can edit) and connection identity (who the flow authenticates *as*) are separate systems in Power Automate — transferring one does not transfer the other. This is the #1 cause of "we transferred it, why did it still break" tickets.
- Build a habit of adding a **service account or dedicated automation identity** as a co-owner and connection source on any business-critical flow at creation time, not retroactively during an offboarding fire drill. See Microsoft Learn: [Manage connections in Power Automate](https://learn.microsoft.com/en-us/power-automate/add-manage-connections).
- Offboarding checklists should include a Power Automate/Power Apps ownership sweep alongside mailbox and OneDrive handling — it's frequently missed because it isn't in Exchange/Entra tooling.
- `Get-AdminFlow` and `Set-AdminFlowOwnerRole` require the **Microsoft.PowerApps.Administration.PowerShell** module and environment admin or tenant admin rights — a standard Global Admin role alone isn't automatically sufficient in all tenant configurations if Power Platform admin delegation has been scoped down.
- Flows that use the calling user's own OneDrive/mailbox as a *data source* (not just for auth) — e.g., "when a file is added to my OneDrive" — can't be trivially fixed by reconnecting; the trigger itself is tied to that person's content and needs redesign, not just reconnection.
- Deep dive on connection references, service-principal patterns, and the environment admin transfer model: `Flow-Ownership-Transfer-A.md`.
