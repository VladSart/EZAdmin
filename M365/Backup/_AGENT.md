# Microsoft 365 Backup — Agent Instructions

## What's in this folder

Microsoft 365 Backup troubleshooting and reference content — the first-party, pay-as-you-go backup and restore service for SharePoint, OneDrive, and Exchange Online (Graph namespace `solutions/backupRestore`). Covers service enablement, Azure pay-as-you-go billing setup, protection policies/units, restore points, restore sessions, and coverage-gap detection.

**Not the same as:** Purview retention policies/labels (compliance preservation, not point-in-time recovery — see `Security/Purview/`), or the native 93-day recycle bin/version history built into OneDrive/SharePoint.

---

## Before responding, also check

- `M365/_AGENT.md` — general M365 agent context and cross-service dependencies
- `Security/Purview/` — if the question is about retention/legal holds interacting with a restore, or about compliance-driven preservation rather than backup/restore
- `M365/SharePoint-OneDrive/_AGENT.md` — if the issue is native SharePoint/OneDrive behavior (sync, permissions, migration) rather than the Backup product itself
- `M365/Exchange/_AGENT.md` — if the issue is native Exchange mailbox behavior rather than the Backup product itself
- `EntraID/_AGENT.md` — if a user/mailbox/OneDrive owner has been deleted from Entra ID and needs reconnection before a restore will work correctly

---

## Folder contents

| File | What it covers |
|------|---------------|
| `M365-Backup-B.md` | Hotfix runbook — service not enabled, stalled policy activation, coverage gaps, failed restore sessions, hold-blocked restores, billing not linked |
| `M365-Backup-A.md` | Deep dive reference — full architecture (append-only storage, data trust boundary), object model, symptom→cause map, restore performance benchmarks, deleted-user recovery playbooks |
| `Scripts/Get-M365BackupCoverageAudit.ps1` | Read-only Graph script — diffs actual SharePoint sites / OneDrive accounts / Exchange mailboxes against Backup protection units to flag `NOT_PROTECTED` items, stalled policies, and recent restore-session failures |

---

## Common entry points

- "Backup pane won't open / greyed out" → `M365-Backup-B.md` § Triage — check billing link and admin role first
- "Can't restore this site/mailbox/OneDrive at all" → `M365-Backup-B.md` § Fix 3 — item was likely never added to a protection policy
- "No restore points before a certain date" → `M365-Backup-A.md` § Symptom → Cause Map — retention doesn't back-fill from before the item was added
- "Restore keeps failing / rejected" → `M365-Backup-B.md` § Fix 4 and Fix 5 — check restore session error and holds
- "Deleted user's mailbox/OneDrive needs recovery" → `M365-Backup-A.md` § Remediation Playbooks → Playbook 2
- "How does Microsoft 365 Backup actually work?" → `M365-Backup-A.md` § How It Works
- "Are we missing backup coverage anywhere?" → `Scripts/Get-M365BackupCoverageAudit.ps1`
- "Is this ransomware-recoverable and how fast?" → `M365-Backup-A.md` § Command Cheat Sheet — performance table, and Remediation Playbook 4

---

## Key diagnostic commands

```powershell
Connect-MgGraph -Scopes "BackupRestore-Configuration.Read.All"

# Tenant-level service status
Get-MgSolutionBackupRestore | Select-Object ServiceStatus

# All protection policies across workloads
Get-MgSolutionBackupRestoreProtectionPolicy | Select-Object DisplayName, Status

# Site/drive/mailbox protection unit detail (raw Graph — no dedicated cmdlet surfaces filters yet)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/siteProtectionUnits"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/driveProtectionUnits"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/mailboxProtectionUnits"

# Recent restore sessions
Get-MgSolutionBackupRestoreSession | Sort-Object CreatedDateTime -Descending | Select-Object -First 10
```

---

## Key dependency chain

```
Azure subscription (pay-as-you-go billing linked) →
  Microsoft 365 Backup Storage service enabled tenant-wide →
    Protection policy created per workload (SharePoint / OneDrive / Exchange) →
      Protection units added — directly or via inclusion rule →
        Restore points generated automatically (10-min granularity, 0-14 days;
          weekly 15-365 days; Exchange: 10-min for the full year) →
            Restore session triggered by admin (in-place or new URL/folder)
```

**Billing is Azure-based, not M365-license-based** — E3/E5 licensing has no bearing on whether Backup is active for a tenant.

---

## Response format reminder (always 3 layers)

1. **Triage first** — is it enablement/billing, policy coverage, or a specific restore failure?
2. **Fix the specific failure** — use the matching fix path from the B runbook; check for holds before assuming a defect
3. **Confirm resolution** — restore session reaches `Status: succeeded`; for coverage gaps, re-run the audit script and confirm the item now shows as protected

**Portal shortcuts:**
- Microsoft 365 Backup home: Microsoft 365 admin center → Settings → Microsoft 365 Backup
- Billing setup: Microsoft 365 admin center → Billing → Your bills & payments (or legacy: Setup → Billing and licenses → Activate pay-as-you-go services)
