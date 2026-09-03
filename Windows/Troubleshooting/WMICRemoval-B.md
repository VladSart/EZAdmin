# WMIC Removal from Windows — Hotfix Runbook (Mode B: Ops)
> Fix or escalate a broken WMIC-dependent script or tool in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

> **Source note:** Corroborated directly from the official Microsoft Support KB (KB5067470, "Windows Management Instrumentation Command-line (WMIC) removal from Windows," originally published 2025-09-12, last revised 2026-02-13). WMIC (`wmic.exe`) has been on a multi-year deprecation path since 2016 (Windows Server 2012) and 2021 (Windows 10 21H2); it shipped disabled-by-default as of Windows 11 23H2/24H2, was removed on upgrade to Windows 11 25H2 (but re-addable as a Feature on Demand), and per Microsoft's own published timeline will be **fully and permanently removed — with no Feature on Demand restore path — in the next Windows 11 feature update in 2026**. This is a certainty, not a preview/roadmap item: only the underlying `wmic.exe` CLI wrapper is going away — the WMI service and infrastructure itself is unaffected and fully supported going forward via PowerShell (CIM cmdlets) or programmatic (.NET/COM) interfaces.

Run these first — results tell you which fix path to follow:

```powershell
# 1. Is WMIC even present on this machine right now?
Get-Command wmic.exe -ErrorAction SilentlyContinue
Get-WindowsCapability -Online -Name "WMIC*" | Select-Object Name, State

# 2. What OS build is this, and has it already crossed the 25H2 removal line?
[System.Environment]::OSVersion.Version
Get-ComputerInfo -Property WindowsProductName, OsBuildNumber, WindowsVersion

# 3. Is the reported failure actually WMIC, or a WMI/CIM query failing for an unrelated reason?
#    (WMI service health check — this must be healthy regardless of WMIC's presence)
Get-Service Winmgmt | Select-Object Status, StartType
Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object Caption

# 4. Search for the actual failing WMIC invocation (script, scheduled task, RMM/monitoring agent, GPO logon script)
Get-ScheduledTask | ForEach-Object {
    $actions = $_.Actions | Where-Object { $_.Execute -like "*wmic*" -or $_.Arguments -like "*wmic*" }
    if ($actions) { [PSCustomObject]@{ Task = $_.TaskName; Path = $_.TaskPath } }
}
```

**Interpretation table:**

| Finding | Action |
|---|---|
| `wmic.exe` not found, `WMIC*` capability shows `NotPresent`, build is 25H2+ | Fully removed as expected — this is the documented end state, not a bug. Go to Fix 1 (rewrite) or Fix 2 (temporary FoD re-add, only if pre-2026-feature-update) |
| `wmic.exe` found but a specific command errors/hangs | Not a removal issue — likely a WMI repository corruption or permissions problem underneath; check `Winmgmt` service and `Get-CimInstance` independently (Step 3) before assuming this runbook applies |
| WMI/CIM queries also fail via `Get-CimInstance` | This is a WMI repository/service problem, not WMIC removal — treat as a separate WMI-repository-health ticket, out of scope here |
| A scheduled task, GPO logon script, or RMM/monitoring agent calls `wmic` | Found the actual break — Fix 1 (rewrite in PowerShell/CIM) is the only durable fix; do not just chase symptoms machine-by-machine |
| Third-party software (not an internal script) shells out to WMIC internally | Fix 3 — vendor escalation, FoD re-add is a stopgap only, not a resolution |
| Org-wide concern before a mass 25H2/26H2 rollout | Fix 4 — proactive fleet-wide scan before removal reaches your fleet, not reactive per-ticket firefighting |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Windows 11 (any supported version) or Windows Server 2012+ through 2025
        │
WMIC.exe (Feature on Demand, "WMIC") installed AND enabled
   Disabled by default since Windows 11 23H2/24H2 — even on a version that
   still technically SUPPORTS the FoD, it is not present by default anymore
        │
Underlying WMI (Windows Management Instrumentation) service (Winmgmt) healthy
   WMI itself is NEVER removed — this is the layer everything actually depends
   on; WMIC was only ever a thin CLI wrapper around it
        │
A script/task/tool invokes the wmic.exe binary directly (not the WMI service
via PowerShell CIM cmdlets, COM API, or .NET System.Management)
        │
Removal timeline (per Microsoft's published KB5067470):
   2016  Deprecated — Windows Server 2012
   2021  Deprecated — Windows 10, version 21H2
   2022  Available as FoD, preinstalled+enabled by default — Windows 11 22H2
   2024  Disabled by default (still FoD-restorable) — Windows 11 23H2/24H2
   2025  Removed on 25H2 upgrade (still FoD-restorable)
   2026  FULLY removed in the next Windows 11 feature update —
         NO Feature on Demand restore path exists after this point
        │
Once the 2026 feature update lands: any remaining WMIC-dependent script,
scheduled task, GPO logon script, or third-party/RMM agent invocation
fails outright with no supported way to bring WMIC back
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm current WMIC presence/state on the affected machine**
```powershell
Get-Command wmic.exe -ErrorAction SilentlyContinue
Get-WindowsCapability -Online -Name "WMIC*" | Select-Object Name, State
```
`NotPresent`/command not found → WMIC is genuinely gone on this machine; this is expected per the documented timeline, not a fault.

**Step 2 — Confirm OS build/version to place the machine on the removal timeline**
```powershell
[System.Environment]::OSVersion.Version
Get-ComputerInfo -Property WindowsProductName, OsBuildNumber, WindowsVersion
```
25H2 or later without WMIC found → consistent with documented behavior. Pre-25H2 with WMIC found but disabled → capability is present but not enabled by default; can still be temporarily re-added (Fix 2) until the fully-removed 2026 feature update reaches this machine.

**Step 3 — Rule out a WMI service/repository problem masquerading as "WMIC broke"**
```powershell
Get-Service Winmgmt | Select-Object Status, StartType
Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Select-Object Caption
```
If `Get-CimInstance` also fails, this is a WMI repository/service health issue independent of WMIC's removal — do not proceed down this runbook; investigate WMI repository corruption (`winmgmt /verifyrepository`, `winmgmt /salvagerepository`) separately.

**Step 4 — Locate every actual WMIC invocation on the machine/fleet**
```powershell
# Local: scheduled tasks
Get-ScheduledTask | ForEach-Object {
    $a = $_.Actions | Where-Object { $_.Execute -like "*wmic*" -or $_.Arguments -like "*wmic*" }
    if ($a) { [PSCustomObject]@{ Task = $_.TaskName; Path = $_.TaskPath } }
}

# Local: search common script locations for the literal string "wmic"
Get-ChildItem -Path "C:\Scripts","C:\ProgramData" -Include *.ps1,*.bat,*.cmd -Recurse -ErrorAction SilentlyContinue |
    Select-String -Pattern "wmic" -SimpleMatch | Select-Object Path, LineNumber
```
Use the companion `Get-WMICUsageAudit.ps1` script for a broader, fleet-wide, evidence-generating version of this same search (GPO SYSVOL logon scripts, scheduled tasks, common RMM install paths).

**Step 5 — Confirm the specific WMIC command's PowerShell/CIM replacement before rewriting**
```powershell
# Example equivalence pattern (per Microsoft's own migration guidance):
# WMIC:       wmic path win32_process get Name
# PowerShell: Get-CimInstance Win32_Process | Select-Object Name
```
Nearly every WMIC query maps directly to `Get-CimInstance <ClassName>` with the same WMI class name — the class names and properties are unchanged; only the CLI wrapper syntax differs.

---

## Common Fix Paths

<details><summary>Fix 1 — Rewrite the WMIC-dependent script/task using PowerShell CIM cmdlets (the durable fix)</summary>

**Cause:** A script, scheduled task, GPO logon script, or internally-authored tool shells out directly to `wmic.exe`, which is on a hard, published, no-FoD-restore removal path in 2026.

**Remediation:**
1. Identify the exact WMIC command(s) in use (Diagnosis Step 4/5).
2. Translate each to its PowerShell equivalent. Common patterns:
   ```powershell
   # WMIC:       wmic path win32_process get Name,ProcessId
   # PowerShell: Get-CimInstance Win32_Process | Select-Object Name, ProcessId

   # WMIC:       wmic product get name,version
   # PowerShell: Get-CimInstance Win32_Product | Select-Object Name, Version
   #             (Get-CimInstance Win32_Product is itself slow/triggers MSI reconfig —
   #              prefer the registry-based uninstall-key enumeration pattern instead
   #              for production inventory scripts)

   # WMIC:       wmic process where name="notepad.exe" call terminate
   # PowerShell: Get-CimInstance Win32_Process -Filter "Name='notepad.exe'" |
   #                 Invoke-CimMethod -MethodName Terminate

   # WMIC:       wmic bios get serialnumber
   # PowerShell: (Get-CimInstance Win32_BIOS).SerialNumber
   ```
3. For batch files/scripts that cannot be fully rewritten immediately, invoke PowerShell inline as a bridge: `powershell -c "<command>"` from the existing `.bat`/`.cmd` file — this is Microsoft's own documented interim pattern and buys time without leaving WMIC as a hard dependency.
4. Update GPO logon scripts, scheduled task actions, and any internal documentation/support articles that instruct staff to run WMIC commands.
5. Test the rewritten script/task on a pilot machine (ideally one already past the removal line) before deploying broadly.

**Rollback:** N/A — this is a forward-only migration; there is no supported path back to WMIC once removed.

</details>

<details><summary>Fix 2 — Temporary Feature on Demand re-add (stopgap only, time-limited)</summary>

**Cause:** A machine still on a pre-2026-feature-update build needs WMIC back immediately while a proper rewrite (Fix 1) is scheduled.

**Important:** This is only possible on builds that still support WMIC as a Feature on Demand. Once a machine takes the 2026 feature update that fully removes WMIC, **no FoD restore path exists at all** — this fix path stops working permanently for that machine going forward.

```powershell
# Check current capability state
Get-WindowsCapability -Online -Name "WMIC*"

# Re-add if State shows NotPresent and the build still supports it
Add-WindowsCapability -Online -Name "WMIC~~~~"
```

**Verify:** `Get-Command wmic.exe` resolves; re-run the previously-failing command.

**Rollback:**
```powershell
Remove-WindowsCapability -Online -Name "WMIC~~~~"
```

Treat this fix as a dated stopgap with an explicit expiry — schedule Fix 1 before this machine's next feature update, not after the next failure.

</details>

<details><summary>Fix 3 — Third-party software/agent shells out to WMIC internally</summary>

**Cause:** The failure isn't in an internally-authored script but inside a vendor product (backup agent, RMM tool, legacy monitoring agent, older AV product) that calls `wmic.exe` under the hood.

**Remediation:**
1. Confirm via Diagnosis Step 4 that the failing process is the vendor binary/service, not an internal script.
2. Check the vendor's current release notes/knowledge base for WMIC-removal awareness — most major RMM/monitoring vendors have already published guidance or shipped updated agent versions that use CIM/WMI directly instead of shelling to WMIC.
3. Update to the vendor's current agent version if a WMIC-independent release exists.
4. If no updated version exists yet, open a support ticket with the vendor citing Microsoft's KB5067470 removal timeline, and use Fix 2 as a bounded stopgap only on pre-removal-line machines while awaiting the vendor fix.

**Rollback:** Revert to the prior agent version if an update introduces regressions; re-apply Fix 2 stopgap if still on an eligible build.

</details>

<details><summary>Fix 4 — Proactive fleet-wide scan before removal reaches your environment</summary>

**Cause:** No active ticket yet, but the org needs to get ahead of the 2026 feature-update rollout rather than firefighting tickets machine-by-machine as it lands.

**Remediation:**
1. Run the companion `Windows/Scripts/Get-WMICUsageAudit.ps1` across representative machines/servers (or fleet-wide via your existing remote-execution tooling) to inventory: GPO SYSVOL logon/startup scripts referencing `wmic`, local scheduled tasks with `wmic` in their action, and common script directories.
2. Prioritize remediation of GPO-delivered scripts and scheduled tasks first — these affect every machine the policy applies to, not just one.
3. Track remediation against your organization's Windows Update ring/feature-update rollout schedule — WMIC-dependent tooling should be fixed on a timeline that lands BEFORE the 2026 feature update reaches production rings, not after.

**Rollback:** N/A — this is an inventory/planning activity, not a configuration change.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — WMIC Removal Issue
=====================================
Device Name:                [hostname]
OS Build:                   [output of Get-ComputerInfo -Property OsBuildNumber]
WMIC capability state:      [output of Get-WindowsCapability -Online -Name "WMIC*"]
Winmgmt service status:     [Running/Stopped — Get-Service Winmgmt]
Get-CimInstance baseline test result: [success/failure]
Failing invocation source:  [scheduled task / GPO logon script / internal script / third-party agent — name/path]
Exact WMIC command that fails: [command text]
PowerShell/CIM replacement identified: [Yes/No — command text if yes]
Third-party vendor involved (if applicable): [vendor + product + version]

Steps already attempted:
[ ] Confirmed WMIC presence/state on the affected machine
[ ] Confirmed Winmgmt service and Get-CimInstance work independently of WMIC
[ ] Located the exact script/task/agent invoking WMIC
[ ] Identified or attempted the PowerShell/CIM equivalent command
[ ] Checked vendor KB/release notes if a third-party agent is involved
[ ] Considered Feature on Demand re-add as a bounded stopgap (pre-removal-line builds only)
```

---

## 🎓 Learning Pointers

- **Only the CLI wrapper is going away — WMI itself is fully intact and fully supported.** This is the single most important framing for any ticket: nothing that was possible via WMIC becomes impossible after removal, it just requires PowerShell (`Get-CimInstance`, `Invoke-CimMethod`) or a programmatic interface (.NET `System.Management`, the WMI COM API) instead of the `wmic.exe` text wrapper. [WMIC removal from Windows — Microsoft Support (KB5067470)](https://support.microsoft.com/en-us/topic/windows-management-instrumentation-command-line-wmic-removal-from-windows-e9e83c7f-4992-477f-ba1d-96f694b8665d)

- **2026's removal has no Feature on Demand restore path — earlier removals did.** The 25H2-upgrade removal (2025) could still be undone via `Add-WindowsCapability`; the 2026 feature-update removal is permanent for that machine going forward. Don't let Fix 2 (FoD re-add) become the default answer — it only buys time on machines that haven't crossed the final line yet.

- **Most WMIC-to-PowerShell translations are nearly mechanical** (`wmic <class> get <properties>` → `Get-CimInstance <Class> | Select-Object <Properties>`), because the underlying WMI class names and properties are completely unchanged — only the CLI syntax around them differs. This makes Fix 1 far less effort than teams often assume. [WMI command line (WMIC) utility deprecation: Next steps — Microsoft Tech Community](https://techcommunity.microsoft.com/blog/windows-itpro-blog/wmi-command-line-wmic-utility-deprecation-next-steps/4039242)

- **GPO logon scripts and scheduled tasks are the highest-leverage remediation targets.** A single WMIC-dependent GPO script or centrally-deployed scheduled task can affect an entire OU or fleet — prioritize finding and fixing these over chasing individual machine tickets one at a time.

- **`Get-CimInstance Win32_Product` is a known-slow, side-effecting anti-pattern independent of WMIC removal** (it triggers an MSI self-repair/reconfigure pass for every installed product as a side effect of enumeration) — when rewriting a WMIC inventory script that queried `win32_product`, prefer the registry uninstall-key enumeration pattern instead of a literal `Get-CimInstance Win32_Product` translation, or you'll trade one production risk for another.

- **This is a security hardening move, not just cleanup** — WMIC has been a long-documented living-off-the-land tool abused by attackers and malware for host reconnaissance and defense evasion; removing it closes off a well-known administrative binary from that abuse surface, independent of the IT-admin migration effort it requires.
