# Azure Automation — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This runbook covers **Azure Automation account authentication (the managed identity model and the Run As account retirement), runbook job execution and sandbox failures, and extension-based Hybrid Runbook Worker connectivity** — the three failure layers that account for the overwhelming majority of "a client's automation stopped working" MSP tickets.

**Explicitly out of scope, with cross-references:**
- **Azure Update Manager** — the current, non-Automation-dependent patch management service. It shares no infrastructure with an Automation account (no Log Analytics workspace, no installed agent, uses Azure Policy and Arc/VM extensions directly), so a "patching isn't working" ticket almost never lands in this file anymore. Automation's own legacy **Update Management** solution retired 31 August 2024 — any reference to it found in an existing Automation account is dead weight to be decommissioned, not debugged. Worth a standalone future topic if patching-specific tickets accumulate.
- **Change Tracking and Inventory (Log Analytics-based)** — retired alongside Update Management on the same date; the Automation-account-hosted version is gone. Change tracking today lives under Azure Monitor Agent-based solutions, architecturally unrelated to anything in this file.
- **PowerShell Desired State Configuration (DSC) in Azure Automation** — a distinct feature of the Automation account (State Configuration) with its own pull-server/LCM architecture, its own failure modes, and its own Microsoft-recommended successor (Azure Automanage Machine Configuration / Guest Configuration). Not covered here.
- **Source control integration, runbook authoring in VS Code, and graphical (non-textual) runbook design** — covered only where they intersect a real failure mode (e.g., the graphical-runbook child-execution restriction, noted below); not a design guide.

---
## How It Works

<details><summary>Full architecture</summary>

An Automation account is fundamentally three loosely coupled subsystems sharing one resource: an **identity/authentication layer**, a **runbook execution service**, and (optionally) a **Hybrid Runbook Worker fleet** that extends execution outside Microsoft's own sandboxes.

**Identity.** Every Automation account can carry a system-assigned and/or one or more user-assigned managed identities, exactly like any other Azure resource with that capability. This is now the *only* first-party authentication path — the older **Run As account** model (an app registration + self-signed certificate, auto-rotated by Automation itself) was retired platform-wide on 30 September 2023 and can no longer be created or renewed. A managed identity is not a credential a runbook manages; it's a token endpoint (`IDENTITY_ENDPOINT`/`IDENTITY_HEADER` environment variables inside the sandbox, or the standard Azure IMDS on a VM) that `Connect-AzAccount -Identity` calls transparently. Critically, **enabling a system-assigned identity at the Automation-account level overrides any VM-level system-assigned identity previously used for Hybrid Runbook Worker jobs** — Automation always prefers its own account identity once one exists, which is a common source of "it broke when we fixed the other thing" confusion during Run As migrations.

**Runbook execution.** By default, every runbook job runs inside a **Azure sandbox** — a shared, multi-tenant, resource-constrained container Microsoft manages entirely. Sandboxes exist specifically so customers never need infrastructure to run simple automation, but the trade-off is hard, non-negotiable resource ceilings: roughly 400 MB memory, 1,000 concurrent network sockets, a 3-hour wall-clock "fair share" limit (PowerShell/Python jobs are marked `Stopped` when hit; PowerShell Workflow jobs are marked `Failed`), and a 1 MB cap on total job output stream size. None of these produce an application-level error — the job simply gets evicted. Sandboxes also cannot reach resources behind a network firewall that doesn't explicitly allow them (Automation is **not** on the Microsoft-trusted-services bypass list for Storage, Key Vault, or SQL firewalls — this is a permanent architectural fact, not a bug to report).

**Hybrid Runbook Workers** solve both problems by running the job on customer-owned compute (Azure VM, Arc-enabled on-prem/multi-cloud server, or VMware guest via Arc) instead of the sandbox — no memory/socket/time ceiling, and normal network reachability rules apply since it's just another machine on that network. As of **31 August 2024**, only the **extension-based** worker model is supported; the older **agent-based** model (installed via the legacy Microsoft Monitoring Agent / OMS agent) is retired. The extension-based model deploys a VM extension (`Microsoft.Azure.Automation.HybridWorker.HybridWorkerForWindows`/`...ForLinux`) that requires a **system-assigned managed identity on the worker VM itself** (or the Arc-connected machine agent's own identity for non-Azure machines) to authenticate to the Automation service — a second, VM-scoped identity layer distinct from the Automation account's own identity described above. Workers register into named **Hybrid Runbook Worker Groups**; each active worker polls the Automation service roughly every 30 seconds and can pick up about 4 jobs per poll. A worker that hasn't reported a heartbeat (`LastSeenDateTime`) in 30+ days is purged from its group automatically.

**Authentication inside a runbook running on a Hybrid Worker deserves its own note**: unlike a sandbox job, a Hybrid Worker doesn't automatically have the old Run As certificate available locally even if one still technically exists elsewhere — `Connect-AzAccount -ServicePrincipal -CertificateThumbprint ...` fails there specifically with "no certificate was found," a distinct symptom from the sandbox-side Run As retirement failure, both root-caused by the same underlying platform change.

</details>

---
## Dependency Stack

```
Layer 7 — Job outcome (Completed / Failed / Suspended / Stopped)
Layer 6 — Execution environment limits
              ├── Azure sandbox: 400MB mem / 1,000 sockets / 3h wall clock / 1MB output
              └── Hybrid Worker: unrestricted, but depends on Layers 3-5 below being healthy
Layer 5 — Hybrid Worker job scheduling (30s poll cycle, ~4 jobs/poll/worker, 30-day heartbeat purge)
Layer 4 — Hybrid Worker network reachability (*.azure-automation.net:443, or Private Link
              matched to the SAME VNet as the Automation account's private endpoint)
Layer 3 — Hybrid Worker VM identity + extension health
              (system-assigned MI on the VM itself; Arc agent required for non-Azure machines;
               extension settings must reference the correct AutomationHybridServiceUrl)
Layer 2 — Runbook code correctness
              ├── Local execution validated (would this script run outside Automation at all?)
              └── Module dependency chain intact (ProvisioningState = Succeeded, versions aligned)
Layer 1 — RBAC role assignment on the TARGET resource the runbook is trying to act on
Layer 0 — Automation Account identity exists at all
              (managed identity — system- and/or user-assigned; Run As is retired and
               cannot be recreated as of 30 Sept 2023)
```

Layers 0-1 are the account's own authentication; Layers 3-5 only apply when execution happens on a Hybrid Worker rather than the default sandbox. A ticket that looks like a "runbook is broken" problem is very often actually stuck at Layer 0 (identity doesn't exist) or Layer 1 (identity exists, has no role) — always confirm those two before reading a single line of runbook code.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `No certificate was found in the certificate store with thumbprint ...` | Runbook still coded against a retired Run As account | Search runbook for `AzureRunAsConnection` / `CertificateThumbprint` |
| `Login-AzureRMAccount to log in` | Run As account expired/retired, or mixed AzureRM/Az module versions | Check `Identity` on the Automation account; check module versions match |
| `this.Client.SubscriptionId cannot be null` | Managed identity exists but has zero role assignments | `Get-AzRoleAssignment -ObjectId <principalId>` |
| `403 Forbidden` / `AuthorizationFailed` on a specific resource | Identity lacks the specific role needed for that resource | `Get-AzRoleAssignment` scoped to that resource |
| `403 Forbidden` reaching Storage/Key Vault/SQL specifically, identity otherwise fine elsewhere | That resource's firewall blocks Automation outright (not a trusted service) | Confirm firewall is enabled on the target resource; requires Hybrid Worker + VNet path |
| `The term '<cmdlet>' is not recognized` | Module missing, still importing, or version mismatch | `Get-AzAutomationModule` → `ProvisioningState` |
| Runbook import silently fails, no cmdlets available | Module imported while a dependency (e.g. `Az.Accounts`) wasn't yet `Succeeded` | Re-check import order; `Az.Accounts` first, always |
| Job stuck `Queued` indefinitely | Hybrid Worker not polling — offline, unhealthy, or extension uninstalled | `Get-AzAutomationHybridRunbookWorker` → `LastSeenDateTime` |
| Job `Suspended`: *"exceeded the job limit for a Hybrid Worker"* | Too few workers in the group for the job submission rate (>4 jobs/30s/worker) | Count active workers vs. concurrent job volume |
| Job `Suspended`: *"hybrid worker wasn't available when scheduled job started"* | Worker was off/unreachable at the exact schedule trigger time | Correlate `LastSeenDateTime` against the schedule's fire time |
| Linux Hybrid Worker job stuck `Running`, CPU pinned near 25% | Default per-core `CPUQuota=25%` in the `hwd.service` systemd unit | `systemctl status hwd.service`; check unit file `CPUQuota=` value |
| Hybrid Worker deployment fails: *"Unable to retrieve IMDS identity endpoint for non-Azure VM"* | Deploying on a non-Azure machine without the Arc Connected Machine agent installed | Confirm Arc agent status before deploying the extension |
| Hybrid Worker deployment fails: *"Invalid Authorization Token"* | User-assigned MI enabled on the VM, but system-assigned MI is NOT | Enable system-assigned MI specifically; reinstall extension |
| Hybrid Worker deployment fails: *"Authentication failed for private links"* | VM's VNet ≠ VNet of the Automation account's private endpoint | Confirm both share the same VNet or a properly peered/DNS-resolved path |
| Runbook job fails after 3 automatic retries, generic error | Sandbox memory/socket/ADAL-auth limit hit, or genuine module incompatibility | Check job memory footprint; consider Hybrid Worker if consistently near limits |
| Job `Stopped` (PS/Python) or `Failed` (PS Workflow) after exactly ~3 hours | Sandbox 3-hour fair-share wall-clock eviction | Move to Hybrid Worker, or split into child runbooks via `Start-AzAutomationRunbook` |
| Caller receives `400 Bad Request: This webhook has expired or is disabled` | Webhook past its (non-renewable) expiry, or manually disabled | `Get-AzAutomationWebhook` → `IsEnabled` / `ExpiryTime` |
| `429: The request rate is currently too large` from `Get-AzAutomationJobOutput` | Runbook emits excessive verbose-stream volume | Reduce verbose output, or filter `-Stream Output` only |

---
## Validation Steps

1. **Confirm the Automation account's identity state.**
   ```powershell
   (Get-AzAutomationAccount -ResourceGroupName <rg> -Name <aa>).Identity
   ```
   Good: `Type` shows `SystemAssigned` and/or `UserAssigned` with a populated `PrincipalId`. Bad: `$null` — no first-party authentication path exists at all for any runbook in this account.

2. **Confirm that identity actually holds a role at the scope it needs.**
   ```powershell
   Get-AzRoleAssignment -ObjectId <principalId> -Scope "/subscriptions/<subId>/resourceGroups/<rg>"
   ```
   Good: at least one role covering the runbook's actual operations. Bad: empty result — identity exists but is functionally powerless.

3. **Grep every runbook for retired Run As patterns before they cause a production failure, not after.**
   ```powershell
   Get-AzAutomationRunbook -ResourceGroupName <rg> -AutomationAccountName <aa> |
     ForEach-Object {
       $content = Export-AzAutomationRunbook -ResourceGroupName <rg> -AutomationAccountName <aa> -Name $_.Name -OutputFolder $env:TEMP -Force
       Select-String -Path $content -Pattern "AzureRunAsConnection|CertificateThumbprint" -SimpleMatch
     }
   ```
   Good: no matches. Bad: any match — that runbook will fail the moment it next runs, whether or not it has yet.

4. **Confirm every module a runbook imports is actually usable.**
   ```powershell
   Get-AzAutomationModule -ResourceGroupName <rg> -AutomationAccountName <aa> |
     Select-Object Name, ProvisioningState, Version, IsGlobal
   ```
   Good: `Succeeded` for every non-global module the runbook references. Bad: `Creating` (still importing — wait), `Failed` (investigate dependency order/version).

5. **For Hybrid Worker groups, confirm heartbeat freshness across the whole group, not just one worker.**
   ```powershell
   Get-AzAutomationHybridRunbookWorker -ResourceGroupName <rg> -AutomationAccountName <aa> `
     -HybridRunbookWorkerGroupName <groupName> | Select-Object Name, LastSeenDateTime
   ```
   Good: all workers within the last ~1 minute (30s poll cycle). Bad: any worker stale by more than a few minutes — treat as offline for capacity-planning purposes even before the 30-day auto-purge.

6. **Validate a runbook actually runs standalone before blaming the platform.**
   Run the exact script content locally in PowerShell (with `Connect-AzAccount` swapped for an interactive login) or Python. A script with a real logic/syntax error fails identically in both places — ruling this out first prevents chasing a platform ghost.

7. **Check recent job history in aggregate, not one job at a time, to spot a systemic pattern.**
   ```powershell
   Get-AzAutomationJob -ResourceGroupName <rg> -AutomationAccountName <aa> -StartTime (Get-Date).AddDays(-7) |
     Group-Object Status | Select-Object Name, Count
   ```
   A cluster of `Suspended` jobs points to Hybrid Worker capacity; a cluster of `Failed` jobs with the same exception points to an identity or module regression, not a one-off.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Identity and authorization.** Confirm the Automation account has a managed identity (Validation Step 1) and that it holds the role the failing operation actually needs (Step 2). This resolves the largest single category of "used to work, now doesn't" tickets, almost entirely attributable to the 2023 Run As retirement catching up with runbooks nobody has revisited since. Do this before opening the runbook editor.

**Phase 2 — Module and code correctness.** Confirm module `ProvisioningState` (Step 4), confirm import order respected dependency chains (`Az.Accounts` before anything depending on it), and confirm the script logic itself runs locally (Step 6). A `cmdlet not recognized` error is module-layer, not logic-layer, roughly nine times out of ten.

**Phase 3 — Sandbox limits.** If the job fails, stops, or is evicted with no clear application error — especially after a consistent ~3-hour runtime, or while processing large in-memory datasets — check for sandbox ceiling behavior (memory/socket/wall-clock/output-size) before treating it as a code bug. The fix is architectural (Hybrid Worker or child-runbook decomposition), not a retry.

**Phase 4 — Hybrid Worker deployment (if applicable).** For a worker that's never successfully joined a group: confirm system-assigned MI is enabled on the VM specifically (not just user-assigned), confirm Arc agent presence for non-Azure machines, and confirm the group referenced in the deployment actually still exists. These three account for nearly every extension-deployment failure.

**Phase 5 — Hybrid Worker job execution (if applicable).** For a worker that's joined successfully but jobs still misbehave: check heartbeat freshness, check whether job submission rate exceeds the ~4-jobs-per-30-seconds-per-worker throughput, and on Linux specifically check the default 25% per-core CPU quota if jobs appear to hang at low CPU usage.

**Phase 6 — Escalate with evidence, not conclusions.** If Phases 1-5 are all clean and the failure persists, this has left the domain of configuration and likely needs either a Microsoft support case (platform-side sandbox/service issue) or a deeper look at the runbook's actual business logic against real data conditions. Package the [Evidence Pack](#evidence-pack) output rather than re-describing symptoms from memory.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Run As account → Managed Identity migration (fleet-wide)</summary>

**When to use:** Any Automation account still containing runbooks written before September 2023, or any client engagement where "our automation randomly stopped working" is the opening ticket.

1. Inventory every runbook referencing `AzureRunAsConnection` or a certificate thumbprint (Validation Step 3).
2. Enable a system-assigned managed identity on the Automation account:
   ```powershell
   Set-AzAutomationAccount -ResourceGroupName <rg> -Name <aa> -AssignSystemIdentity
   ```
3. Document every role the old Run As service principal held (check the Entra app registration's role assignments before it's cleaned up, if it still exists) and replicate them onto the new managed identity's principal ID.
4. Update runbook code to the `Connect-AzAccount -Identity` pattern (see `AzureAutomation-B.md` Fix 1) for every flagged runbook, testing each individually rather than batch-editing blind.
5. If any runbooks run on a Hybrid Runbook Worker via a VM-level identity today, explicitly verify the VM-level identity's role coverage is not silently superseded once the account-level identity is enabled — both need equivalent access, or the hybrid job's effective permissions change unexpectedly.
6. Remove the old Run As app registration and certificate from Entra ID only after every dependent runbook has been verified against the new identity in production, not just tested.

**Rollback:** Managed identity role assignments can be removed (`Remove-AzRoleAssignment`) without side effects to other resources — this migration has no destructive step until the old Run As registration is explicitly deleted in step 6.

</details>

<details><summary>Playbook 2 — Agent-based → Extension-based Hybrid Runbook Worker migration</summary>

**When to use:** Any Hybrid Runbook Worker deployed before August 2024 that hasn't been explicitly re-platformed since — assume it is running the retired agent-based model until confirmed otherwise.

1. Confirm the current model: agent-based workers show under the legacy `HybridRunbookWorkerGroup` resource type with an installed Microsoft Monitoring Agent; extension-based workers show the `Microsoft.Azure.Automation.HybridWorker.HybridWorkerFor*` VM extension in `Get-AzVMExtension`.
2. Enable a system-assigned managed identity on each worker VM (or confirm Arc Connected Machine agent presence + its own identity for non-Azure machines).
3. Create or confirm the target Hybrid Runbook Worker Group exists for the extension-based model (agent-based and extension-based groups are not interchangeable).
4. Deploy the extension-based worker to each VM, referencing the correct `AutomationHybridServiceUrl` (cross-check against the Automation account's own `AutomationHybridServiceUrl` property, not assumed from the account name).
5. Validate heartbeat (`LastSeenDateTime`) before decommissioning the old agent-based worker from its legacy group.
6. Update any runbook that authenticated via the Run As certificate copied locally to the old worker (`Export-RunAsCertificateToHybridWorker` pattern) to use the VM's managed identity instead — the certificate-copy workaround has no equivalent need once Run As itself no longer exists.

**Rollback:** Uninstalling the new extension (documented uninstall scripts exist for both Windows and Linux) and leaving the legacy agent-based worker in place is reversible up until the legacy Log Analytics workspace backing it is itself decommissioned.

</details>

<details><summary>Playbook 3 — Module dependency cleanup (fleet-wide hygiene)</summary>

**When to use:** Recurring "cmdlet not recognized" tickets across multiple runbooks in the same account, or after a manual/partial module update left the dependency chain inconsistent.

1. Inventory current module state and versions:
   ```powershell
   Get-AzAutomationModule -ResourceGroupName <rg> -AutomationAccountName <aa> |
     Select-Object Name, Version, ProvisioningState
   ```
2. Never mix `AzureRM.*` and `Az.*` modules in the same runbook or account — this specific combination causes sandbox crashes (`get_SerializationSettings` type-load errors), not graceful failures.
3. Use the built-in **Update Azure modules** action (Automation account → Modules → Update Azure modules) rather than manually reimporting each module individually — it resolves the dependency graph correctly; manual reimports in the wrong order are the most common self-inflicted cause of this problem.
4. Re-run affected runbooks only after every dependent module shows `ProvisioningState: Succeeded` — not merely "imported."

**Rollback:** Individual modules can be reimported at a prior version via their saved `ContentLinkUri` if an update introduces a regression; test in a non-production Automation account first where one is available.

</details>

<details><summary>Playbook 4 — Fleet-wide MSP audit sweep</summary>

**When to use:** Onboarding a new client's existing Automation estate, or a periodic health sweep across all managed tenants.

1. Run `Scripts/Get-AzureAutomationHealth.ps1` against every Automation account in scope.
2. Treat any account with no managed identity at all as an immediate priority — it means every runbook in that account either already fails or is one Run As certificate expiry away from failing with no advance warning.
3. Treat any Hybrid Runbook Worker with a stale heartbeat as an immediate priority — jobs silently queue forever rather than producing an actionable error, so this class of failure is otherwise invisible until a scheduled task's absence is noticed downstream.
4. Cross-reference any account still showing an active **Update Management** (legacy) solution — this is dead, retired functionality as of 31 August 2024 and should be flagged for migration to Azure Update Manager as a separate remediation, not patched in place.
5. Document findings per client rather than remediating live during a discovery sweep — several of these fixes (Playbooks 1 and 2 especially) are non-trivial enough to warrant their own scheduled change window.

**Rollback:** N/A — this playbook is read-only by design; all actual remediation happens via the other three playbooks.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Azure Automation account, job, identity, and Hybrid Worker evidence for escalation.
.NOTES
    Read-only. Run with Connect-AzAccount already authenticated against the target subscription.
#>
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$AutomationAccountName,
    [string]$RunbookName,
    [string]$OutputPath = ".\AzureAutomation-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
)

$evidence = [System.Collections.Generic.List[string]]::new()
$evidence.Add("=== Azure Automation Evidence Pack — $(Get-Date -Format o) ===")

$aa = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName
$evidence.Add("`n--- Automation Account ---")
$evidence.Add(($aa | Select-Object AutomationAccountName, Location, Identity | Format-List | Out-String))

if ($RunbookName) {
    $evidence.Add("`n--- Recent Jobs: $RunbookName ---")
    $jobs = Get-AzAutomationJob -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $RunbookName |
        Sort-Object StartTime -Descending | Select-Object -First 5
    $evidence.Add(($jobs | Select-Object JobId, Status, StatusDetails, StartTime, EndTime | Format-Table -AutoSize | Out-String))
    foreach ($job in $jobs) {
        $evidence.Add("Job $($job.JobId) Exception: $($job.Exception)")
    }
}

$evidence.Add("`n--- Modules (non-Succeeded only) ---")
$modules = Get-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName |
    Where-Object { $_.ProvisioningState -ne 'Succeeded' }
$evidence.Add(($modules | Select-Object Name, ProvisioningState, Version | Format-Table -AutoSize | Out-String))

$evidence.Add("`n--- Hybrid Runbook Worker Groups ---")
$groups = Get-AzAutomationHybridWorkerGroup -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName
foreach ($g in $groups) {
    $evidence.Add("Group: $($g.Name)")
    $workers = Get-AzAutomationHybridRunbookWorker -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -HybridRunbookWorkerGroupName $g.Name
    $evidence.Add(($workers | Select-Object Name, WorkerType, LastSeenDateTime | Format-Table -AutoSize | Out-String))
}

$evidence -join "`n" | Out-File -FilePath $OutputPath -Encoding utf8
Write-Host "Evidence written to $OutputPath"
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AzAutomationAccount -ResourceGroupName <rg> -Name <aa>` | Check account identity state |
| `Set-AzAutomationAccount -ResourceGroupName <rg> -Name <aa> -AssignSystemIdentity` | Enable system-assigned managed identity |
| `Get-AzRoleAssignment -ObjectId <principalId>` | Confirm role assignments held by the identity |
| `New-AzRoleAssignment -ObjectId <principalId> -Scope <scope> -RoleDefinitionName <role>` | Grant a role to the managed identity |
| `Get-AzAutomationJob -ResourceGroupName <rg> -AutomationAccountName <aa> -Name <runbook>` | List job history for a runbook |
| `Get-AzAutomationJobOutput -Id <jobId> \| Get-AzAutomationJobOutputRecord` | Pull full job output/exception detail |
| `Get-AzAutomationModule -ResourceGroupName <rg> -AutomationAccountName <aa>` | Check module provisioning state/version |
| `Remove-AzAutomationModule` / `New-AzAutomationModule` | Reimport a module cleanly |
| `Get-AzAutomationHybridWorkerGroup -ResourceGroupName <rg> -AutomationAccountName <aa>` | List Hybrid Runbook Worker groups |
| `Get-AzAutomationHybridRunbookWorker -ResourceGroupName <rg> -AutomationAccountName <aa> -HybridRunbookWorkerGroupName <g>` | Check individual worker heartbeat/type |
| `Get-AzAutomationWebhook -ResourceGroupName <rg> -AutomationAccountName <aa> -RunbookName <runbook>` | Check webhook enabled/expiry state |
| `New-AzAutomationWebhook -ResourceGroupName <rg> -AutomationAccountName <aa> -RunbookName <runbook> -Name <name> -IsEnabled $true -ExpiryTime <date>` | Create a replacement webhook (save URI immediately) |
| `Start-AzAutomationRunbook -ResourceGroupName <rg> -AutomationAccountName <aa> -Name <runbook>` | Start a runbook (also the fix for graphical-runbook child-execution restriction) |
| `Export-AzAutomationRunbook -ResourceGroupName <rg> -AutomationAccountName <aa> -Name <runbook> -OutputFolder <path>` | Pull runbook source for local review/grep |
| `systemctl status hwd.service` (on a Linux Hybrid Worker) | Check worker daemon health / CPU quota setting |

---
## 🎓 Learning Pointers

- **Run As accounts were retired platform-wide on 30 September 2023, not deprecated on a slow timeline** — a runbook that used them and hasn't been touched since is not "at risk," it is already broken or will be the instant its certificate's remaining validity runs out. Treat any pre-2023 Automation account as needing an audit, not a wait-and-see approach. See [Migrate from a Run As account to Managed identities](https://learn.microsoft.com/en-us/azure/automation/migrate-run-as-accounts-managed-identity).
- **Agent-based Hybrid Runbook Workers retired on 31 August 2024**, the same date as Automation's legacy Update Management and Change Tracking solutions — all three retirements share a root cause (the underlying Microsoft Monitoring Agent's own end of support). A client environment untouched since before that date likely has all three problems simultaneously, not just one. See [Troubleshoot extension-based Hybrid Runbook Worker issues](https://learn.microsoft.com/en-us/azure/automation/troubleshoot/extension-based-hybrid-runbook-worker) and [What's new in Azure Automation](https://learn.microsoft.com/en-us/azure/automation/whats-new).
- **Account-level managed identity always takes precedence over VM-level managed identity for Hybrid Worker jobs, silently, the moment it's enabled** — this is documented but easy to miss mid-migration, and can change a hybrid job's effective permissions without any visible error. See [Using a system-assigned managed identity for an Azure Automation account](https://learn.microsoft.com/en-us/azure/automation/enable-managed-identity-for-automation).
- **Sandbox resource limits (400 MB memory, 1,000 sockets, 3-hour fair share, 1 MB output) are permanent architectural constants, not throttling that can be requested to be raised** — the only escape valve is a Hybrid Runbook Worker or splitting work into child runbooks via `Start-AzAutomationRunbook`.
- **A webhook, once past its expiry, cannot be renewed — only replaced.** Building any client-facing integration against an Automation webhook should set the expiry as far out as operationally reasonable (Microsoft's own guidance suggests up to a year or more) and document the URI outside the portal, since `Get-AzAutomationWebhook` never returns it after creation.
- **Automation is absent from the trusted-Microsoft-services bypass list for Storage, Key Vault, and SQL firewalls** — a client enabling network restrictions on any of those three will break every sandbox-based runbook touching them, with an identical-looking 403 regardless of how correct the RBAC role assignment is. This is one of the most common false "permissions" escalations in this whole topic.
