# Azure Automation — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure Automation** account authentication (the managed identity model and the 30-September-2023 Run As account retirement), **runbook job execution failures** (Azure sandbox resource limits, module import/dependency issues, webhook expiry), and **extension-based Hybrid Runbook Worker connectivity** (agent-based workers retired 31 August 2024). Explicitly out of scope: Azure Update Manager (a separate, non-Automation-dependent service — Automation's own legacy Update Management solution is retired and covered here only as a decommission flag), Change Tracking and Inventory, and PowerShell DSC/State Configuration.

---

## Before responding, also check

- **EntraID/Troubleshooting/AppRegistrations**, **EntraID/Troubleshooting/WorkloadIdentity** — alternative or complementary identity models; a runbook migrating off a Run As account sometimes ends up comparing notes against these rather than managed identity specifically
- **Azure/KeyVault** — a very common Automation target resource; the "403 from a runbook" symptom can be a Key Vault firewall/authorization problem rather than an Automation identity problem — check `KeyVault-B.md` if the failing operation is a vault read
- **Azure/Arc** — non-Azure Hybrid Runbook Workers require the Arc Connected Machine agent to be healthy first; an Arc connectivity problem masquerades as a Hybrid Worker deployment failure
- **Security/Sentinel** — Automation runbooks are a common SOAR/playbook execution target; if the question is about a Sentinel-triggered automation rather than a standalone runbook, confirm which layer actually failed before assuming this folder's fixes apply

---

## Folder contents

| File | What it covers |
|------|----------------|
| `AzureAutomation-B.md` | Hotfix runbook — Run As account failures, missing/unassigned managed identity roles, stuck module imports, Hybrid Worker job queuing/suspension, expired webhooks |
| `AzureAutomation-A.md` | Deep dive — managed identity architecture and Run As retirement, sandbox execution limits, extension-based Hybrid Runbook Worker architecture, migration and fleet-audit playbooks |
| `Scripts/Get-AzureAutomationHealth.ps1` | Read-only fleet sweep — identity presence, module provisioning state, Hybrid Worker heartbeat/purge risk, webhook expiry, recent job failure rate |

---

## Common entry points

- **"Runbook fails with 'No certificate was found' or 'Login-AzureRMAccount to log in'"** → `AzureAutomation-B.md` Fix 1 — retired Run As account, migrate to managed identity
- **"Runbook fails with 'this.Client.SubscriptionId cannot be null' or a 403"** → `AzureAutomation-B.md` Fix 2 — identity exists but has no role assignment
- **"Cmdlet not recognized" / module errors** → `AzureAutomation-B.md` Fix 3 — check module `ProvisioningState` before assuming code is wrong
- **"Job stuck Queued forever" or "exceeded the job limit for a Hybrid Worker"** → `AzureAutomation-B.md` Fix 4 — check worker heartbeat first
- **"400 Bad Request: webhook has expired or is disabled"** → `AzureAutomation-B.md` Fix 5 — expired webhooks cannot be renewed, must recreate
- **"Should we still be using a Run As account?"** → `AzureAutomation-A.md` Playbook 1 — no, it was retired 30 Sept 2023; full migration sequence
- **"Our Hybrid Worker hasn't been touched since before 2024"** → `AzureAutomation-A.md` Playbook 2 — likely still agent-based (retired), needs extension-based migration
- **"Client mentions 'Update Management' inside their Automation account"** → that's the retired legacy solution (31 Aug 2024) — flag for migration to Azure Update Manager, a separate service, not covered in this folder
- **"Onboarding a new client's existing Automation estate"** → `Scripts/Get-AzureAutomationHealth.ps1` — run first, prioritize NO_MANAGED_IDENTITY and STALE_HEARTBEAT flags

---

## Key diagnostic commands

```powershell
# Identity state — check this FIRST for any authentication-flavored failure
(Get-AzAutomationAccount -ResourceGroupName <rg> -Name <aa>).Identity

# Most recent job's actual exception text
Get-AzAutomationJob -ResourceGroupName <rg> -AutomationAccountName <aa> -Name <runbook> |
  Sort-Object StartTime -Descending | Select-Object -First 1 -ExpandProperty Exception

# Module readiness
Get-AzAutomationModule -ResourceGroupName <rg> -AutomationAccountName <aa> |
  Where-Object { $_.ProvisioningState -ne 'Succeeded' }

# Hybrid Worker heartbeat
Get-AzAutomationHybridRunbookWorker -ResourceGroupName <rg> -AutomationAccountName <aa> `
  -HybridRunbookWorkerGroupName <group> | Select-Object Name, LastSeenDateTime

# Webhook expiry
Get-AzAutomationWebhook -ResourceGroupName <rg> -AutomationAccountName <aa> -RunbookName <runbook> |
  Select-Object Name, IsEnabled, ExpiryTime
```

---

## Key dependency chain

```
Automation Account
    │
    ├── Managed Identity (system-/user-assigned — Run As retired 30 Sept 2023, cannot be recreated)
    │       └── RBAC role assignment on the TARGET resource
    ▼
Runbook code + module dependency chain (ProvisioningState = Succeeded)
    ▼
Execution environment
    ├── Azure sandbox (default) — hard caps: 400MB mem / 1,000 sockets / 3h wall clock / 1MB output
    └── Hybrid Runbook Worker (extension-based — agent-based retired 31 Aug 2024)
            ├── System-assigned MI on the worker VM (+ Arc agent if non-Azure)
            ├── Extension healthy, network reachable to *.azure-automation.net:443
            └── 30s poll cycle, ~4 jobs/poll/worker, 30-day heartbeat purge
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — unblock the specific failing job or worker (Mode B)
2. **Root cause** — which layer actually failed: identity, module, sandbox limit, or Hybrid Worker layer (Mode A)
3. **Prevention** — audit for the two forced-retirement gaps (Run As, agent-based Hybrid Worker) proactively rather than waiting for the next failure
