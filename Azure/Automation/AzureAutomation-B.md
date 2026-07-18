# Azure Automation — Hotfix Runbook (Mode B: Ops)
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

Run these first — in order. Stop as soon as one gives you the answer.

```powershell
# 1. What actually happened to the job — pull the real status and exception, not just "Failed"
Get-AzAutomationJob -ResourceGroupName <rg> -AutomationAccountName <aa> -Name <runbookName> |
  Sort-Object StartTime -Descending | Select-Object -First 1 |
  Select-Object JobId, Status, StatusDetails, Exception, StartTime, EndTime

# 2. Does this Automation account have a managed identity — or is it still relying on a
#    Run As account that was force-retired on 30 Sept 2023? (the single most common
#    root cause of "sign-in" failures on runbooks written before 2023)
Get-AzAutomationAccount -ResourceGroupName <rg> -Name <aa> | Select-Object AutomationAccountName, Identity

# 3. If the job ran on a Hybrid Runbook Worker — is the worker actually alive?
Get-AzAutomationHybridRunbookWorker -ResourceGroupName <rg> -AutomationAccountName <aa> `
  -HybridRunbookWorkerGroupName <groupName> |
  Select-Object Name, WorkerType, LastSeenDateTime, VmResourceId

# 4. Is a module the runbook depends on actually usable (not stuck mid-import)?
Get-AzAutomationModule -ResourceGroupName <rg> -AutomationAccountName <aa> |
  Where-Object { $_.ProvisioningState -ne 'Succeeded' } |
  Select-Object Name, ProvisioningState, IsGlobal, Version

# 5. If triggered by webhook — is it still valid? (webhooks cannot be renewed once expired)
Get-AzAutomationWebhook -ResourceGroupName <rg> -AutomationAccountName <aa> -RunbookName <runbookName> |
  Select-Object Name, IsEnabled, ExpiryTime, LastInvokedTime
```

| If... | Then... |
|---|---|
| Job exception contains `No certificate was found` / `Login-AzureRMAccount to log in` / references `AzureRunAsConnection` | [Fix 1 — Runbook still using a retired Run As account](#fix-1) |
| Step 2 shows `Identity: $null` (no managed identity enabled at all) | [Fix 1](#fix-1) — nothing is currently available for the runbook to authenticate with |
| Job status is `Failed` with `this.Client.SubscriptionId cannot be null` or a 403/`AuthorizationFailed` | [Fix 2 — Managed identity has no role assignment](#fix-2) |
| Step 4 shows a module stuck in `Creating` for >10 minutes, or `Failed` | [Fix 3 — Module import stuck or dependency mismatch](#fix-3) |
| Job status is `Queued` and never starts, or `Suspended` with *"hybrid worker wasn't available"* / *"exceeded the job limit for a Hybrid Worker"* | [Fix 4 — Hybrid Runbook Worker not picking up jobs](#fix-4) |
| Triggering system receives `400 Bad Request: This webhook has expired or is disabled` | [Fix 5 — Webhook expired](#fix-5) |
| Job exception is `403 Forbidden` reaching Storage/Key Vault/SQL specifically | Not an identity problem — that resource's firewall blocks Automation entirely (see Learning Pointers); needs a Hybrid Worker + VNet service endpoint, not a role fix |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Automation Account
    │
    ├── Managed Identity (system- and/or user-assigned)
    │       │  ← Run As accounts (classic + newer) were force-retired 30 Sept 2023.
    │       │     Any runbook still calling Get-AutomationConnection -Name
    │       │     "AzureRunAsConnection" or Connect-AzAccount -ServicePrincipal
    │       │     -CertificateThumbprint has nothing left to authenticate with.
    │       ▼
    │   Role assignment on the TARGET resource
    │       │  ← the identity existing is not enough — it needs an explicit RBAC
    │       │     role on whatever the runbook is trying to touch
    │       ▼
    │   Runbook code + imported modules
    │       │  ← module must show ProvisioningState "Succeeded", not "Creating"
    │       │  ← Az module dependency chain must be internally consistent
    │       │     (e.g. Az.Storage requires a matching Az.Accounts version)
    │       ▼
    └── Execution environment
            ├── Azure sandbox (default)
            │       └── hard limits: 400 MB memory, 1,000 sockets,
            │           3-hour fair-share wall clock, 1 MB output stream
            │
            └── Hybrid Runbook Worker (extension-based — agent-based
                    retired 31 Aug 2024)
                    │
                    ├── System-assigned managed identity enabled ON THE VM
                    │     (Arc-connected machine agent required for non-Azure VMs)
                    ├── Extension installed + healthy, correct AutomationHybridServiceUrl
                    ├── Network reachability to *.azure-automation.net:443
                    │     (or Private Link, same VNet as the Automation account's PE)
                    └── Worker polls every 30s, picks up ~4 jobs per poll —
                          exceeding that without more workers suspends jobs
```

**The Run As → Managed Identity gap and the agent-based → extension-based Hybrid Worker gap are the two most common reasons an MSP inherits a "runbook that used to work."** Both were forced platform retirements (2023 and 2024 respectively), not gradual deprecations — a runbook nobody has touched since before those dates is likely broken right now, not "about to break."

</details>

---
## Diagnosis & Validation Flow

1. **Pull the actual job exception, never trust the portal's one-line status.**
   ```powershell
   Get-AzAutomationJob -ResourceGroupName <rg> -AutomationAccountName <aa> -Name <runbookName> |
     Sort-Object StartTime -Descending | Select-Object -First 1 -ExpandProperty Exception
   ```
   Good: empty/`$null` on a `Completed` job. Bad: any populated string — read it directly, it almost always names the exact cmdlet and reason.

2. **Confirm whether the Automation account has a managed identity, and which type.**
   ```powershell
   Get-AzAutomationAccount -ResourceGroupName <rg> -Name <aa> | Select-Object -ExpandProperty Identity
   ```
   `$null` = no identity at all. `PrincipalId` populated with `Type: SystemAssigned` (or `SystemAssigned, UserAssigned`) = identity exists — proceed to check its role assignments, not its existence.

3. **If using a Hybrid Runbook Worker, check the heartbeat before anything else.**
   ```powershell
   Get-AzAutomationHybridRunbookWorker -ResourceGroupName <rg> -AutomationAccountName <aa> `
     -HybridRunbookWorkerGroupName <groupName> | Select-Object Name, LastSeenDateTime
   ```
   Good: `LastSeenDateTime` within the last few minutes. Bad: stale by hours/days — the worker isn't polling; the job will queue forever, not fail with a useful error. Workers silently offline for 30+ days are purged from the group entirely.

4. **Check module provisioning state before assuming the runbook code is wrong.**
   ```powershell
   Get-AzAutomationModule -ResourceGroupName <rg> -AutomationAccountName <aa> -Name <moduleName> |
     Select-Object Name, ProvisioningState, Version
   ```
   Good: `Succeeded`. Bad: `Creating` (import still in progress — can take up to 10 minutes, don't run jobs against it yet) or `Failed` (usually a dependency version mismatch, e.g. `Az.Storage` imported before a compatible `Az.Accounts`).

5. **For a suspended/stopped job with no clear exception, check the sandbox limits before escalating as a "platform bug."**
   A job hitting 400 MB memory, 1,000 sockets, or the 3-hour fair-share wall clock is evicted with a generic `Stopped`/`Failed` status and no application-level error. This is by design — the fix is a Hybrid Worker (unrestricted) or splitting the runbook into child runbooks, not a retry.

6. **If everything above looks correct and the failure is a 403 reaching Storage, Key Vault, or SQL specifically**, this is not an identity or role problem — it's that resource's own network firewall. Azure Automation is **not** on the "trusted Microsoft services" bypass list for any of the three. The only fix is running the job from a Hybrid Runbook Worker inside (or peered with) that resource's VNet.

---
## Common Fix Paths

<details><summary id="fix-1">Fix 1 — Runbook still using a retired Run As account</summary>

**Symptom:** `No certificate was found in the certificate store with thumbprint ...`, `Login-AzureRMAccount to log in`, or the runbook code contains `Get-AutomationConnection -Name "AzureRunAsConnection"`.

**Root cause:** Azure Automation Run As accounts (classic and the newer certificate-based Run As accounts) were retired platform-wide on **30 September 2023**. They cannot be created or renewed anymore — any runbook still coded against one has no working authentication path left, full stop.

```powershell
# 1. Enable a system-assigned managed identity on the Automation account
Set-AzAutomationAccount -ResourceGroupName <rg> -Name <aa> -AssignSystemIdentity

# 2. Confirm it's enabled and grab the principal ID
$identity = (Get-AzAutomationAccount -ResourceGroupName <rg> -Name <aa>).Identity
$identity.PrincipalId

# 3. Grant it the same role(s) the old Run As account held on the target resource(s)
New-AzRoleAssignment -ObjectId $identity.PrincipalId `
  -Scope "/subscriptions/<subId>/resourceGroups/<targetRg>" `
  -RoleDefinitionName "Contributor"   # match to least-privilege for the actual task
```

Then update the runbook code — replace the Run As pattern:
```powershell
# OLD (retired, will always fail now):
$Conn = Get-AutomationConnection -Name AzureRunAsConnection
Connect-AzAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationId $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint

# NEW:
Disable-AzContextAutosave -Scope Process
$AzureContext = (Connect-AzAccount -Identity).context
Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
```

**Note for Hybrid Runbook Worker jobs specifically:** an Automation-account-level managed identity **overrides** any VM-level managed identity previously used for hybrid jobs once enabled — confirm this doesn't break a different runbook that was intentionally using the VM's own identity before rolling this out broadly.

**Rollback:** Disabling the managed identity (`Set-AzAutomationAccount -AssignSystemIdentity:$false` is not directly supported — remove via the portal Identity blade or `Remove-AzRoleAssignment` the granted roles) reverts access; it does not restore Run As, which cannot be recreated.

</details>

<details><summary id="fix-2">Fix 2 — Managed identity exists but has no role assignment</summary>

**Symptom:** `this.Client.SubscriptionId cannot be null`, or a 403 `AuthorizationFailed` naming the identity's object ID.

```powershell
# Confirm the identity has zero role assignments at the scope it needs
Get-AzRoleAssignment -ObjectId <principalId> -Scope "/subscriptions/<subId>"

# Grant the minimum role actually needed
New-AzRoleAssignment -ObjectId <principalId> `
  -Scope "/subscriptions/<subId>/resourceGroups/<rg>" `
  -RoleDefinitionName "<least-privilege role — e.g. Virtual Machine Contributor>"
```

Role assignment propagation can take a few minutes — don't churn a just-created assignment as "still broken" inside that window.

**Rollback:** `Remove-AzRoleAssignment` with the same parameters.

</details>

<details><summary id="fix-3">Fix 3 — Module import stuck or dependency mismatch</summary>

**Symptom:** `Get-AzAutomationModule` shows `Creating` for longer than ~10 minutes, or `Failed`; runbook errors with `The term '<cmdlet>' is not recognized`.

```powershell
# Confirm current state
Get-AzAutomationModule -ResourceGroupName <rg> -AutomationAccountName <aa> -Name <moduleName> |
  Select-Object Name, ProvisioningState, Version

# If genuinely stuck/failed, remove and reimport a matched-version set —
# Az.Storage (etc.) MUST be imported after a compatible Az.Accounts, not before
Remove-AzAutomationModule -ResourceGroupName <rg> -AutomationAccountName <aa> -Name <moduleName> -Force
New-AzAutomationModule -ResourceGroupName <rg> -AutomationAccountName <aa> -Name "Az.Accounts" `
  -ContentLinkUri "<PowerShell-Gallery-nupkg-URI>"
# wait for Az.Accounts to show ProvisioningState "Succeeded" before importing dependents
```

Never start a job against a module before its `ProvisioningState` is `Succeeded` — starting mid-import is a common self-inflicted "cmdlet not found" failure that looks identical to a real missing-module problem.

**Rollback:** Re-import the previously working module version from its saved `ContentLinkUri`.

</details>

<details><summary id="fix-4">Fix 4 — Hybrid Runbook Worker not picking up jobs</summary>

**Symptom:** Job status stuck `Queued`, or `Suspended` with *"hybrid worker wasn't available when scheduled job started"* or *"exceeded the job limit for a Hybrid Worker."*

```powershell
# Check heartbeat first
Get-AzAutomationHybridRunbookWorker -ResourceGroupName <rg> -AutomationAccountName <aa> `
  -HybridRunbookWorkerGroupName <groupName> | Select-Object Name, LastSeenDateTime, VmResourceId

# On the worker VM itself (Windows) — is the service actually running?
Get-Service HybridWorkerService | Select-Object Status, StartType

# On the worker VM itself (Linux):
# systemctl status hwd.service
```

- **Stale/no heartbeat:** machine is off, network-isolated, or the extension was uninstalled — fix connectivity/power state, or reinstall the extension.
- **Heartbeat is fresh but jobs still queue:** the group is undersized for the job rate. Each worker polls every 30 seconds and picks up roughly 4 jobs per poll — add workers to the group, or stagger job schedules so they don't all fire on the same minute mark.
- **Linux job stuck in `Running` at <25% CPU:** the Hybrid Worker daemon defaults to a 25% CPU quota per core (`CPUQuota=25%` in `/lib/systemd/system/hwd.service`). Edit the unit to `CPUQuota=` (blank) and `systemctl daemon-reload; systemctl restart hwd.service` to remove the cap.

**Rollback:** Config-only changes (CPU quota, worker count) — reversible by editing the setting back / removing added workers.

</details>

<details><summary id="fix-5">Fix 5 — Webhook expired</summary>

**Symptom:** Calling system receives `400 Bad Request: This webhook has expired or is disabled`.

```powershell
# Check current state — IsEnabled false = just re-enable; look for ExpiryTime in the past
Get-AzAutomationWebhook -ResourceGroupName <rg> -AutomationAccountName <aa> -RunbookName <runbookName> |
  Select-Object Name, IsEnabled, ExpiryTime
```

**If disabled (not expired):** re-enable via `Set-AzAutomationWebhook -IsEnabled $true`.

**If expired:** webhooks have a hard, non-renewable expiration — you cannot revive an already-expired one. Delete and recreate:
```powershell
Remove-AzAutomationWebhook -ResourceGroupName <rg> -AutomationAccountName <aa> -Name <oldWebhookName>

$webhook = New-AzAutomationWebhook -ResourceGroupName <rg> -AutomationAccountName <aa> `
  -RunbookName <runbookName> -Name "<newWebhookName>" -IsEnabled $true `
  -ExpiryTime (Get-Date).AddYears(1) -Force

$webhook.WebhookURI   # SAVE THIS NOW — it is never retrievable again after this command returns
```

**Rollback:** N/A — deleting an expired webhook is not destructive to the runbook itself. Update every calling system with the new URI before considering this closed; a missed caller is the most common way this ticket reopens.

</details>

---
## Escalation Evidence

Copy this template and fill in before escalating:

```
AZURE AUTOMATION ESCALATION — <date/time>
Automation Account: <name>   Resource Group: <rg>   Subscription: <subId>
Runbook: <name>   Job ID: <jobId>   Job Status: <status>

Managed identity type: <SystemAssigned / UserAssigned / none>   Principal ID: <guid>
Role assignments confirmed at target scope? <yes/no — paste Get-AzRoleAssignment output>

Job exception (full text):
  <paste from Get-AzAutomationJob ... | Select -ExpandProperty Exception>

Execution environment: <Azure sandbox / Hybrid Worker group name>
If Hybrid Worker — LastSeenDateTime: <timestamp>   Extension healthy? <yes/no>

Module state (if suspected): <paste Get-AzAutomationModule output>
Webhook state (if triggered by webhook): <paste Get-AzAutomationWebhook output>

What's been tried:
  <bullet list>

Business impact / urgency:
  <one line>
```

---
## 🎓 Learning Pointers

- **Run As accounts (classic and certificate-based) were force-retired on 30 September 2023** — they cannot be created, renewed, or repaired. Any runbook error mentioning `AzureRunAsConnection`, a certificate thumbprint, or "Login-AzureRMAccount to log in" is this, not a transient auth glitch. Migrate to a system- or user-assigned managed identity. See [Migrate from a Run As account to Managed identities](https://learn.microsoft.com/en-us/azure/automation/migrate-run-as-accounts-managed-identity).
- **Agent-based Hybrid Runbook Workers (the MMA/OMS-agent-based Windows and Linux workers) retired on 31 August 2024.** If a client's Hybrid Worker was set up before then and nobody has touched it since, assume it's running the retired agent and needs migration to the extension-based worker, not a restart. See [Troubleshoot extension-based Hybrid Runbook Worker issues](https://learn.microsoft.com/en-us/azure/automation/troubleshoot/extension-based-hybrid-runbook-worker).
- **An Automation-account-level managed identity silently overrides a VM-level managed identity for hybrid jobs, the moment it's enabled.** If a runbook was intentionally using the Hybrid Worker VM's own identity, enabling the account-level identity as part of a Run As migration can change *which* identity's permissions actually apply — verify both identities' role assignments cover the same access before rolling this out. See [Using a system-assigned managed identity for an Azure Automation account](https://learn.microsoft.com/en-us/azure/automation/enable-managed-identity-for-automation).
- **Azure Automation is not on the "trusted Microsoft services" bypass list for Storage, Key Vault, or SQL firewalls.** Enabling those resources' firewalls blocks the Azure sandbox completely, with no exception available — the only fix is running the job from a Hybrid Runbook Worker inside the resource's own network path.
- **Azure sandbox jobs are hard-capped at 400 MB memory, 1,000 concurrent sockets, a 3-hour fair-share wall clock, and a 1 MB total output stream** — a job hitting any of these is evicted with a generic status and no application-level error. Don't debug the runbook logic first; check whether it's actually a resource-limit eviction.
- **Automation Update Management (the legacy, Log-Analytics/MMA-dependent patching solution built into Automation accounts) retired on 31 August 2024**, replaced by **Azure Update Manager**, which no longer depends on an Automation account, Log Analytics workspace, or installed agent at all. If a ticket references "Update Management" inside an Automation account, that's the retired product — the fix is migrating to Update Manager, a separate service, not troubleshooting the old one.
