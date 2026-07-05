# FRS-to-DFSR SYSVOL Migration — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers stuck/failed SYSVOL migration from legacy FRS to DFSR.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

```powershell
# 1. What state is SYSVOL migration in globally?
dfsrmig /getglobalstate

# 2. What state is each individual DC in? (this is where migrations get stuck)
dfsrmig /getmigrationstate

# 3. Is SYSVOL still being served via FRS or DFSR right now?
Get-WinEvent -LogName "File Replication Service" -MaxEvents 5 -ErrorAction SilentlyContinue
Get-Service DFSR, NtFrs

# 4. Are GPOs/logon scripts actually failing for users right now?
dcdiag /test:sysvolcheck /test:netlogons

# 5. Confirm which DC is PDC emulator (authoritative source during migration)
netdom query fsmo
```

**Interpret:**
- `/getglobalstate` returns **Start (0)** → migration never began, this is a planned project not an incident — escalate to change management, don't hotfix
- `/getglobalstate` returns **Prepared (1)** or **Redirected (2)** but `/getmigrationstate` shows DCs stuck **not** "all succeeded" → see [Fix 1](#fix-1--dc-stuck-mid-migration)
- `NtFrs` service still running and `DFSR` also running on same DC → mid-migration, expected — do not stop either manually
- `dcdiag sysvolcheck` fails → SYSVOL share missing or not advertised, see [Fix 2](#fix-2--sysvol-share-missing-or-not-advertised)
- GPOs failing domain-wide → likely one DC (often PDC) is unhealthy — check that DC specifically before touching migration state

---

## Dependency Cascade

<details><summary>What must be true for FRS→DFSR migration to succeed</summary>

```
[All DCs healthy + AD replication converged]
    → All DCs reachable and running compatible OS (Server 2008 R2+ for DFSR SYSVOL)
    → PDC emulator is authoritative source for migration state changes
    → dfsrmig requires Domain Admin (or Enterprise Admin for global state change)
    → Each DC must independently transition: Start → Prepared → Redirected → Eliminated
    → A DC cannot skip a state — /setglobalstate only advances if ALL DCs report success at current state
    → FRS and DFSR run in PARALLEL during Prepared/Redirected — this is normal, not a bug
    → Migration is irreversible once "Eliminated" — FRS SYSVOL data is deleted
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm current global and per-DC state**
```powershell
dfsrmig /getglobalstate
dfsrmig /getmigrationstate
```
Expect all DCs listed under "succeeded" for the current state before advancing. Any DC not listed = stuck.

**Step 2 — Check the stuck DC's event log directly**
```powershell
Get-WinEvent -ComputerName <stuckDC> -LogName "DFS Replication" -MaxEvents 50 |
  Where-Object { $_.Id -in 8004,8014,8016,8018,8020 } |
  Select TimeCreated, Id, Message | Format-Table -Wrap
```
Event 8004 = migration triggered. Event 8016 = migration failed — message body names the reason (usually AD replication lag or FRS still active unexpectedly).

**Step 3 — Verify AD replication has actually converged domain-wide**
```powershell
repadmin /replsummary
repadmin /showrepl <stuckDC>
```
Migration state changes are stored in AD (`msDFSR-Options` on the DC computer object) — if AD replication hasn't converged, `/getmigrationstate` will show stale/inconsistent results across DCs.

**Step 4 — Confirm SYSVOL share is live on the stuck DC**
```powershell
Invoke-Command -ComputerName <stuckDC> -ScriptBlock {
  net share | Select-String "SYSVOL|NETLOGON"
}
```
Missing SYSVOL share on a DC = clients falling back to other DCs or failing logon scripts entirely from that site.

**Step 5 — Check FRS backlog if still mid-migration**
```powershell
# Only relevant if state is Start/Prepared and FRS is still primary
ntfrsutl backlog <stuckDC>  # legacy tool — may need to run from a DC with FRS tools still present
```

---

## Common Fix Paths

<details><summary>Fix 1 — DC stuck mid-migration (not progressing past current state)</summary>

**Symptom:** `/getmigrationstate` shows one or more DCs missing from the "succeeded" list for over an hour after `/setglobalstate` was advanced.

```powershell
# Step 1: Force AD replication convergence first — most "stuck" states are just AD lag
repadmin /syncall /AdeP

# Step 2: Re-check migration state after convergence
dfsrmig /getmigrationstate

# Step 3: If still stuck, restart DFSR on the stuck DC to force it to re-read the new state
Invoke-Command -ComputerName <stuckDC> -ScriptBlock { Restart-Service DFSR -Force }

# Step 4: Re-poll
dfsrmig /getmigrationstate
```

Only proceed to advance global state once ALL DCs report success at the current stage.

</details>

<details><summary>Fix 2 — SYSVOL share missing or not advertised</summary>

```powershell
# Check DFSR SYSVOL replication group flag on the affected DC
Invoke-Command -ComputerName <stuckDC> -ScriptBlock {
  Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\DFSR\Parameters\SysVols\Migrating Sysvols\Domain System Volume" |
    Select-Object "msDFSR-Flags", LocalPath
}
# Flags: 0 = waiting for initial sync, 16 = SYSVOL_READY (shared), 32 = SYSVOL not yet initialized, 48 = redirected+ready

# If not shared, force a poll and restart DFSR
Invoke-Command -ComputerName <stuckDC> -ScriptBlock {
  dfsrdiag PollAD
  Restart-Service DFSR -Force
}

# Wait 2-5 minutes, then verify
Invoke-Command -ComputerName <stuckDC> -ScriptBlock { net share }
```

> ⚠️ Do not manually share SYSVOL/NETLOGON via `net share` as a workaround — this masks the real DFSR problem and creates an inconsistent state.

</details>

<details><summary>Fix 3 — Migration will not advance past "Redirected" (state 2 → 3)</summary>

**Symptom:** `dfsrmig /setglobalstate 3` (Eliminated) fails or hangs.

```powershell
# Confirm every single DC — not just a sample — is at Redirected and succeeded
dfsrmig /getmigrationstate

# Common cause: a decommissioned/dead DC object still in AD is blocking global convergence
Get-ADDomainController -Filter * | Select Name, IPv4Address

# If a dead DC is found, it must be properly demoted/metadata-cleaned before migration can proceed
# DO NOT force state 3 while a phantom DC object exists — this is a common source of permanent SYSVOL corruption
```

**Do not run `/setglobalstate 3` under time pressure if any DC is unaccounted for.** This step deletes FRS SYSVOL data domain-wide and cannot be undone.

</details>

<details><summary>Fix 4 — Emergency rollback (only if caught in "Prepared" or early "Redirected")</summary>

> ⚠️ Rollback is only possible before state reaches **Eliminated (3)**. Once Eliminated, FRS SYSVOL is gone — there is no rollback, only restore from backup.

```powershell
# Roll back to the previous state (example: Redirected → Prepared)
dfsrmig /setglobalstate 1

# Monitor all DCs return to a consistent state
dfsrmig /getmigrationstate
```

</details>

---

## Escalation Evidence

```
FRS→DFSR Migration Issue — Evidence Pack
====================================
Domain:                     
Current global state:       [dfsrmig /getglobalstate output]
Per-DC migration state:     [dfsrmig /getmigrationstate output]
Stuck DC(s):                
PDC emulator:               [netdom query fsmo]
AD replication health:      [repadmin /replsummary output]
SYSVOL share status per DC: [net share on each DC]
Relevant Event IDs:         [8004 / 8014 / 8016 / 8018 / 8020]
Time migration started:     
Time issue first observed:  
Any dead/phantom DC objects: [Yes/No — list if yes]
Business impact:            [GPOs failing / logons failing / scoped to one site?]
```

---

## 🎓 Learning Pointers

- **This migration is one-way and irreversible past state 3 (Eliminated).** Many engineers treat `dfsrmig /setglobalstate 3` casually because the command runs instantly — but it silently deletes the FRS SYSVOL replica set on every DC. Always confirm every DC succeeded at state 2 first. [MS Docs: Migrate SYSVOL to DFSR](https://learn.microsoft.com/en-us/windows-server/storage/dfs-replication/migrate-sysvol-to-dfsr)
- **`/getmigrationstate` vs `/getglobalstate` answer different questions** — global state is the domain's target/intended state; migration state is what each DC has actually confirmed. A stuck migration always shows a mismatch between the two. Check both, every time.
- **AD replication convergence is the #1 root cause of "stuck" migrations**, not DFSR itself — the state machine literally lives in an AD attribute (`msDFSR-Options` on DC computer objects), so any AD replication lag looks identical to a genuine migration failure. Always run `repadmin /replsummary` before assuming DFSR is broken.
- **Phantom/orphaned DC objects block global state advancement forever.** If a DC was decommissioned without proper `ntdsutil` metadata cleanup, `dfsrmig` will wait indefinitely for a DC that no longer exists. This is one of the most common "migration hangs at Redirected forever" tickets on Microsoft Q&A and r/sysadmin.
- **Legacy environments still on FRS are running a deprecated, unsupported replication engine** — Microsoft ended FRS support with Windows Server 2008 R2 as the last OS that could still use it for SYSVOL, and FRS has no active bug fixes. If you inherit a domain still on FRS, this migration should be flagged as a priority project, not deferred.
- **Community resource:** search Microsoft Q&A / TechCommunity for "dfsrmig getmigrationstate not all succeeded" — the top threads consistently point to either AD replication lag or a leftover DC object as the cause, matching the fixes above.
