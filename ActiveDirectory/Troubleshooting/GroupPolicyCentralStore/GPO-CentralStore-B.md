# Group Policy Central Store & ADMX/ADML — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session on a DC or an admin workstation with RSAT/GPMC installed:

```powershell
# 1. Does a Central Store exist for this domain?
$domain = (Get-ADDomain).DNSRoot
Test-Path "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions"

# 2. What's actually in it — file count and most recent write time (a stale/never-updated store is
#    the most common root cause)
Get-ChildItem "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions" -Filter *.admx -ErrorAction SilentlyContinue |
  Measure-Object -Property LastWriteTime -Maximum | Select-Object Count, Maximum

# 3. Is this workstation forced to ignore the Central Store entirely?
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy" -Name "EnableLocalStoreOverride" -ErrorAction SilentlyContinue

# 4. Do the ADML (language) folders actually match the ADMX files present? (mismatched pairs cause
#    "resource could not be found" errors)
$store = "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions"
(Get-ChildItem $store -Filter *.admx -ErrorAction SilentlyContinue).Count
(Get-ChildItem "$store\en-US" -Filter *.adml -ErrorAction SilentlyContinue).Count

# 5. Confirm SYSVOL replication health on this DC (Central Store is just files inside SYSVOL — if
#    SYSVOL/DFSR is unhealthy, the Central Store looks "wrong" for reasons that have nothing to do
#    with ADMX content)
dfsrdiag replicationstate
```

| What you see | What it means |
|---|---|
| Test-Path (check 1) returns `False` | No Central Store exists — every admin's GPMC/GPEdit is silently falling back to its own local `C:\Windows\PolicyDefinitions`, which differs by OS build/RSAT version — go to Fix 1 |
| A setting shows as **"Extra Registry Settings"** and can't be edited via the UI | The ADMX/ADML source this machine is using (Central Store or local override) doesn't define that setting — go to Fix 2 |
| Error on opening a GPO: `Namespace '...' is already defined as the target namespace for another file in the store` | Two ADMX files in the store define the same namespace — almost always caused by an incremental/partial ADMX copy that left old and new versions side by side — go to Fix 3 |
| Error: `Resource '$(string ID=...)' referenced in attribute displayName could not be found` | An ADML (language) file is out of sync with its ADMX (definition) file — go to Fix 4 |
| `EnableLocalStoreOverride = 1` (check 3) | This machine is deliberately ignoring the Central Store — confirm this was intentional and not a forgotten diagnostic workaround (Fix 5) |
| A setting that was configured last week now appears blank/missing after someone else edited the GPO | Likely edited from a machine whose ADMX source didn't define that setting, which can silently drop it on save — go to Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Admin opens GPMC/Group Policy Management Editor on some machine
  └── EnableLocalStoreOverride registry value on THAT machine
        ├── 0 or absent (default) — use the Central Store if one exists
        │     └── \\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions present?
        │           ├── NO  — silently falls back to this machine's LOCAL
        │           │        C:\Windows\PolicyDefinitions (version varies by OS build/RSAT)
        │           └── YES — uses the Central Store's .admx (definitions) +
        │                     language-specific .adml (e.g. en-US\*.adml) as the
        │                     rendering source for every ADMX-backed setting
        │                       └── Central Store is just files under SYSVOL —
        │                           inherits SYSVOL/DFSR replication health and
        │                           timing to reach every DC consistently
        └── 1 — ALWAYS use local C:\Windows\PolicyDefinitions, Central Store ignored
              entirely regardless of whether one exists or is current

The underlying setting VALUE is always stored in the GPO itself (registry.pol / GPC
attributes) regardless of ADMX availability — ADMX/ADML is a presentation layer only.
A missing/mismatched ADMX does not delete an already-applied client-side setting; it
only affects what the EDITING admin can see and safely re-save.
```

Key failure points:
- No one ever explicitly created the Central Store — GPMC works fine on every admin's machine individually, just inconsistently, until two admins compare notes or a setting appears to "vanish"
- The Central Store was created once, years ago, and never updated — new OS/Office ADMX-backed settings simply don't appear in the UI, with no error at all
- An admin copied new ADMX files over old ones instead of replacing the whole folder — leaves duplicate/conflicting namespace definitions behind
- `EnableLocalStoreOverride=1` was set once as a diagnostic workaround and never unset — that machine is now permanently isolated from whatever the Central Store contains

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm whether a Central Store exists at all**
```powershell
$domain = (Get-ADDomain).DNSRoot
Test-Path "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions"
```
Expected: `True`. If `False`, every machine in the domain is on its own local ADMX set — this is the single most common root cause of "works on my machine" GPO editing inconsistencies.

**Step 2 — Check how stale the store is**
```powershell
(Get-ChildItem "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions" -Filter *.admx |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
```
Expected: a date reasonably close to your current Windows/Office baseline. A store last touched years ago explains missing modern settings — the Central Store is never auto-updated by Windows Update.

**Step 3 — Confirm this admin's own machine isn't overriding the store**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy" -Name "EnableLocalStoreOverride" -ErrorAction SilentlyContinue
```
Expected: value absent or `0`. A `1` here means this specific machine never uses the Central Store, which explains a "only this admin sees different settings" report.

**Step 4 — Reproduce the exact error**
Open Group Policy Management Editor on the affected GPO and note the exact text: "Extra Registry Settings" (missing ADMX definition), a namespace-collision error (duplicate ADMX), or a resource-not-found error (ADMX/ADML mismatch) point to different fixes below.

**Step 5 — Confirm SYSVOL/DFSR isn't the actual root cause**
```powershell
dfsrdiag replicationstate
Get-WinEvent -LogName "DFS Replication" -MaxEvents 5 | Select-Object TimeCreated, Id, Message
```
Expected: no active backlog/errors. If DFSR itself is unhealthy, a freshly updated Central Store may not have finished replicating to the DC this admin's machine is talking to — this looks identical to "the fix didn't work" but is a separate, SYSVOL-layer problem (see `DFS/Troubleshooting/Replication/`).

---
## Common Fix Paths

<details><summary>Fix 1 — No Central Store exists yet</summary>

**Cause:** The `PolicyDefinitions` folder was never created under SYSVOL, so every admin's tools silently use their own local, inconsistent ADMX/ADML set.

```powershell
$domain = (Get-ADDomain).DNSRoot
$centralStore = "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions"

# Create the folder structure
New-Item -Path $centralStore -ItemType Directory -Force

# Seed it from a single, current, fully-patched reference machine — copy its entire
# local PolicyDefinitions folder as the starting point (do this from that machine, or
# via an admin share, not by hand-picking individual files)
# Example (run FROM the reference machine, or adjust the source path accordingly):
# Copy-Item "C:\Windows\PolicyDefinitions\*" -Destination $centralStore -Recurse -Force

# Verify
Test-Path $centralStore
(Get-ChildItem $centralStore -Filter *.admx).Count
```

**Rollback note:** Non-destructive — creating the Central Store only adds a new file source; it does not remove or change any existing GPO setting values. If something looks wrong immediately after, delete the `PolicyDefinitions` folder to instantly revert every machine back to local-ADMX behavior.

</details>

<details><summary>Fix 2 — Setting shows "Extra Registry Settings" and can't be edited</summary>

**Cause:** The ADMX/ADML source this machine is currently using (Central Store or local, per Triage check 3) doesn't contain a definition for that specific setting — often because it's an older Office/legacy setting that a newer ADMX baseline removed, or a newer OS setting the Central Store hasn't been updated with yet.

```powershell
# You can still read/change the underlying value directly without the UI definition:
Get-GPRegistryValue -Name "<GPOName>" -Key "<RegistryKeyPath>"
Set-GPRegistryValue -Name "<GPOName>" -Key "<RegistryKeyPath>" -ValueName "<ValueName>" -Type DWord -Value <Value>
Remove-GPRegistryValue -Name "<GPOName>" -Key "<RegistryKeyPath>" -ValueName "<ValueName>"

# If this is a legacy Office/older-Windows setting, keep a copy of the OLDER
# PolicyDefinitions folder available and use EnableLocalStoreOverride on ONE dedicated
# admin workstation to edit those specific legacy settings only:
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy" -Name "EnableLocalStoreOverride" -Value 1
# Remember to set this back to 0 (or remove it) when done — see Fix 5
```

**Rollback note:** `Set-GPRegistryValue`/`Remove-GPRegistryValue` changes are real GPO changes — treat them with the same care as any GPO edit. Reverting `EnableLocalStoreOverride` back to `0`/removing it is required after use; do not leave a workstation permanently isolated from the Central Store.

</details>

<details><summary>Fix 3 — Namespace conflict error opening a GPO</summary>

**Cause:** Two ADMX files in the store define the same target namespace — typically from copying newer OS ADMX files over an existing store without first removing the old, now-superseded files of the same feature area.

```powershell
$domain = (Get-ADDomain).DNSRoot
$centralStore = "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions"

# Identify every ADMX's declared target namespace to spot duplicates
Get-ChildItem $centralStore -Filter *.admx | ForEach-Object {
  $xml = [xml](Get-Content $_.FullName)
  [PSCustomObject]@{
    File      = $_.Name
    Namespace = $xml.policyDefinitions.policyNamespaces.target.namespace
  }
} | Group-Object Namespace | Where-Object Count -gt 1
```

Do **not** try to fix this by deleting one of the two conflicting files individually — that risks leaving a partially-consistent, still-mismatched store. Rebuild the folder cleanly instead (see Fix 6 / Remediation Playbook 1 in the Mode A reference doc): source a single, current, fully-patched reference machine's entire local `PolicyDefinitions` folder, merge in any extension (Office/third-party) ADMX/L files, and replace the whole store atomically using the rename-swap method so you can instantly roll back if something is still wrong.

**Rollback note:** Use the rename-swap approach (rename the current store aside, promote the new one) rather than deleting-in-place, so a bad rebuild can be reverted in seconds by renaming back.

</details>

<details><summary>Fix 4 — "Resource ... could not be found" error (ADMX/ADML mismatch)</summary>

**Cause:** An ADMX file was updated without its matching ADML (language) file, or vice versa — the two must be copied as a pair from the same source/version.

```powershell
$domain = (Get-ADDomain).DNSRoot
$centralStore = "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions"

# List ADMX files with no matching en-US ADML (adjust language folder as needed)
$admx = Get-ChildItem $centralStore -Filter *.admx | Select-Object -ExpandProperty BaseName
$adml = Get-ChildItem "$centralStore\en-US" -Filter *.adml | Select-Object -ExpandProperty BaseName
Compare-Object $admx $adml | Where-Object SideIndicator -eq "<="
```

Re-copy the affected ADMX **and** its matching ADML from the exact same source build — never mix an ADMX from one OS/Office version with an ADML from another.

**Rollback note:** Copying a matched pair over a mismatched one is safe; keep a backup of the store beforehand (or use the rename-swap method) in case the source pair itself turns out to be wrong.

</details>

<details><summary>Fix 5 — EnableLocalStoreOverride was left set to 1 and forgotten</summary>

**Cause:** A prior diagnostic/workaround set this machine to permanently ignore the Central Store, and it was never reverted — this machine now silently diverges from every other admin's editing experience.

```powershell
Remove-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy" -Name "EnableLocalStoreOverride" -ErrorAction SilentlyContinue
# or, to be explicit rather than removing the value:
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy" -Name "EnableLocalStoreOverride" -Value 0
```

**Rollback note:** N/A — this fix removes a workaround; it does not change any GPO setting itself. Confirm the Central Store is actually current (Triage check 2) before removing the override, or the admin's editing experience may get worse, not better.

</details>

<details><summary>Fix 6 — A setting appears to have "vanished" after someone else edited/saved the GPO</summary>

**Cause:** The GPO was opened and saved from a machine whose ADMX source didn't define that setting — GPMC can silently fail to preserve a setting it can't render, on save.

```powershell
# Confirm the raw value: it may still be present in the GPO even if GPMC won't show it
Get-GPRegistryValue -Name "<GPOName>" -Key "<RegistryKeyPath>"

# If it's genuinely gone, restore from GPO backup if one exists
Restore-GPO -Name "<GPOName>" -Path "<BackupFolderPath>"
```

Going forward, standardize on editing GPOs from machines pointed at the (current, complete) Central Store only — this is the actual prevention, not a per-incident fix.

**Rollback note:** `Restore-GPO` replaces the current GPO with the backed-up version — confirm you're not also discarding other, legitimate recent changes before restoring.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Group Policy Central Store / ADMX Issue

Domain: ____________
Central Store exists (Yes/No): ____________
Central Store last-modified date (newest .admx): ____________
Affected admin workstation EnableLocalStoreOverride value: ____________
Exact error text observed: ____________
Affected GPO name: ____________
Affected setting (path/name): ____________
SYSVOL/DFSR replication health confirmed (Yes/No): ____________

Steps already attempted:
[ ] Confirmed whether a Central Store exists
[ ] Checked staleness of the store (newest ADMX file date)
[ ] Confirmed EnableLocalStoreOverride is not unexpectedly set on the affected machine
[ ] Captured the exact GPMC/GPEdit error text
[ ] Checked for duplicate ADMX namespaces
[ ] Confirmed SYSVOL/DFSR replication is healthy
```

---
## 🎓 Learning Pointers

- **The Central Store is opt-in and silent about its absence.** If the `PolicyDefinitions` folder under SYSVOL doesn't exist, GPMC/GPEdit fall back per-machine to each admin's own local `C:\Windows\PolicyDefinitions` — with no warning that this is happening, and no indication two admins are seeing different available settings.
- **Windows Update never updates the Central Store for you.** A client OS servicing update ships new local ADMX files on that client; the domain's Central Store stays exactly as it was until an admin manually copies the update in.
- **Never patch a Central Store incrementally by copying new files over old ones.** That's how duplicate/conflicting namespace definitions happen. Rebuild from a single, clean, current reference machine's folder and replace the whole store — see the Mode A reference doc's rename-swap migration playbook.
- **A missing or mismatched ADMX/ADML never deletes an already-applied client-side policy value.** ADMX/ADML is a rendering layer for the GPO editor only; the actual setting lives in `registry.pol`/the GPO's own attributes. What breaks is an admin's ability to safely view and re-save that setting.
- **`EnableLocalStoreOverride=1` is a legitimate, narrow diagnostic tool** — for testing a new local ADMX build against production policies before promoting it to the Central Store — but it is easy to forget to unset, silently isolating that one admin's editing experience from everyone else's going forward.
- Related: [How to create and manage the Central Store for Group Policy Administrative Templates in Windows](https://learn.microsoft.com/en-us/troubleshoot/windows-client/group-policy/create-and-manage-central-store), [Group Policy settings show as Extra Registry Settings and can't be edited](https://learn.microsoft.com/en-us/troubleshoot/windows-server/group-policy/group-policy-settings-show-as-extra-registry-settings)
