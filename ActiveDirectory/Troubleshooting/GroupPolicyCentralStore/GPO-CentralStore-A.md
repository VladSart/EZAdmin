# Group Policy Central Store & ADMX/ADML — Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**In scope:**
- The Group Policy Central Store (`\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions`) — what it is, how it's discovered, and how it's kept (or not kept) current
- ADMX (language-neutral policy definitions) and ADML (language-specific display resources) — the file pair relationship, versioning, and the presentation-layer-only nature of both
- `EnableLocalStoreOverride`, the registry-based escape hatch that forces a machine to ignore the Central Store
- The three documented failure classes: "Extra Registry Settings" (missing definition), namespace collisions (duplicate/conflicting ADMX), and resource-not-found errors (ADMX/ADML version mismatch)
- The recommended clean-rebuild ("rename-swap") migration method for updating the store safely

**Out of scope:**
- Group Policy client-side processing (how a domain-joined machine discovers, filters, and applies GPOs at boot/logon) — see `Windows/Troubleshooting/GPO-A.md`
- GPO replication mechanics — how the two halves of a GPO (Group Policy Container in AD, Group Policy Template in SYSVOL) stay in sync across domain controllers — see `ActiveDirectory/Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md`. This document assumes SYSVOL/DFSR replication is healthy and covers only the *contents* placed inside the `PolicyDefinitions` subfolder, not the replication mechanism carrying it
- Intune-native configuration profiles / the Intune-to-CSP policy model — see `Intune/Troubleshooting/GP-to-CSP-A.md`
- Group Policy Preferences item-level targeting, GPO backup/restore mechanics (`Backup-GPO`/`Restore-GPO`), and third-party GPO management tooling — not covered here
- Legacy `.adm` (non-XML) Administrative Templates — deprecated since Windows Vista/Server 2008; this document covers the current `.admx`/`.adml` format exclusively

**Assumptions:**
- Domain controllers are Windows Server with SYSVOL replicated via DFSR (legacy FRS is out of scope — see `DFS/Troubleshooting/FRS-Migration/`)
- You have rights to read/write files under the SYSVOL `Policies` share and, for registry-level fixes, local administrator rights on the affected admin workstation(s)
- The `GroupPolicy` PowerShell module (RSAT) is available for `Get-GPRegistryValue`/`Set-GPRegistryValue`/`Backup-GPO`/`Restore-GPO` operations

---
## How It Works

<details><summary>Full architecture — the Central Store, ADMX/ADML, and why "installed" doesn't mean "current"</summary>

### Why ADMX/ADML Replaced ADM

Pre-Vista Group Policy stored Administrative Template definitions as `.adm` files, and — critically — a copy of every `.adm` file used by a GPO was stored **inside that GPO's own SYSVOL folder** (`GPT\ADM\`). With hundreds of GPOs in a large domain, this meant hundreds of redundant copies of largely-identical files, replicated repeatedly across every DC via SYSVOL replication — a real bandwidth and storage cost. The `.admx`/`.adml` format (introduced with Windows Vista/Server 2008) solved this by splitting each template into a language-neutral `.admx` (the policy definitions and registry mappings) and one or more language-specific `.adml` files (the display strings shown in the UI for a given locale), and — the key architectural change — moving both out of individual GPOs entirely into a single, shared, optional location: the **Central Store**.

### What the Central Store Actually Is

The Central Store is nothing more than a specifically-named folder placed under the SYSVOL `Policies` share:

```
\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\
  ├── *.admx                    (language-neutral policy definitions)
  ├── en-US\*.adml               (English-US display strings)
  ├── de-DE\*.adml               (German display strings, if needed)
  └── <other-locale>\*.adml
```

There is nothing magic about its creation — no wizard, no AD schema change, no functional-level requirement. Any account with write access to the SYSVOL `Policies` folder can create it by simply creating the `PolicyDefinitions` directory and populating it with files. Group Policy tooling (GPMC, the Group Policy Management Editor / GPEdit) checks for this folder's existence **every time it opens the Administrative Templates node**, and if present, uses its contents as the authoritative source of ADMX/ADML definitions for that session — silently and automatically, with no configuration required on the editing machine beyond the folder existing and being reachable.

### What Happens When It Doesn't Exist

If the `PolicyDefinitions` folder is absent from SYSVOL, Group Policy tooling doesn't error — it falls back, per machine, to that machine's own **local** `C:\Windows\PolicyDefinitions` folder (or the RSAT-installed equivalent on a non-DC admin workstation). This local folder's contents are whatever shipped with that machine's OS build and whatever RSAT/Administrative Templates package was last installed on it. The practical consequence: two administrators on two different machines — say, one on a freshly imaged Windows 11 24H2 workstation and one on an older, less-frequently-updated admin jump box — see **two different sets of available policy settings** when editing the exact same GPO, with no error or warning that this divergence exists. This is the single most common root cause of "it works when I edit it, but not when they do."

### ADMX/ADML Are a Presentation Layer, Not the Policy Value Itself

This is the load-bearing distinction that separates this topic from most other AD hardening/config topics in this repo: **ADMX/ADML files never store a policy's actual configured value.** The value itself lives in the GPO's own `registry.pol` file (for Administrative Template settings, applied via the Group Policy Client Side Extension for Registry) and/or the Group Policy Container's AD attributes. ADMX/ADML exist purely so the Group Policy Management Editor UI knows *how to render a friendly checkbox/dropdown for a given registry value*. A missing or mismatched ADMX definition does not delete, corrupt, or stop the enforcement of an already-applied policy value on client machines — client-side processing (`Windows/Troubleshooting/GPO-A.md`) reads `registry.pol` directly and has no dependency on ADMX/ADML at all.

What *does* break without a correct ADMX/ADML definition is an **administrator's** ability to safely view and re-save that setting through the UI. This is why the most dangerous version of this problem isn't "I can't see a setting" — it's "I opened and saved a GPO from a machine that couldn't render setting X, and setting X is now gone," because GPMC's save operation for Administrative Templates settings works against what it can currently render.

### Two Independent Failure Classes That Look Similar But Aren't

**Missing definition ("Extra Registry Settings").** The editing machine's ADMX source (Central Store or local) simply doesn't contain a definition for a setting that's genuinely configured in the GPO. This happens for two different reasons that call for different responses: (a) the setting is from an *older* baseline (a legacy Office version's ADMX, for example) that a newer, wholesale-replaced Central Store no longer includes — Microsoft has removed roughly 40 policy settings across various OS version transitions, typically because the underlying feature itself was removed or replaced — or (b) the setting is *newer* than the Central Store — a recent Windows/Office feature update shipped a new ADMX defining it, but the Central Store was never updated to include that file.

**Namespace/version conflicts.** Every ADMX file declares a `target namespace` in its XML header. Group Policy tooling will refuse to load the Administrative Templates node at all — not just the one affected setting — if two `.admx` files in the same store declare the same target namespace. This is not caused by normal drift; it is specifically caused by an **incremental, partial update** to the store: copying a newer version of some files into an existing store without first removing the older versions of those same files, leaving both an old and a new definition of the same feature area's namespace present simultaneously. A well-documented real-world example: copying newer Windows 10 ADMX files over an existing store without a full replace triggers `Namespace 'Microsoft.Policies.Sensors.WindowsLocationProvider' is already defined as the target namespace for another file in the store`, because the geolocation feature's ADMX filename changed between versions but its declared namespace did not.

**ADMX/ADML resource mismatch.** An `.admx` file references its display strings by ID (e.g., `$(string.SomeSettingName)`), which its paired `.adml` must define. If an `.admx` is updated to a newer version but its `.adml` counterpart is not updated alongside it (or vice versa), the editor throws a `Resource '$(string ID=...)' referenced in attribute displayName could not be found` error for that specific setting. A documented example: Windows 10 version 1803's updated `SearchOCR.adml` is not compatible with an older `SearchOCR.admx` left in the store from a prior version — the pair must always be sourced and copied together, never independently.

### Why "Just Copy the New Files In" Is the Wrong Update Method

Because both failure classes above are specifically caused by **partial, incremental** updates to the store, Microsoft's own documented best practice is to never update a Central Store by copying individual new files over an existing folder. Instead: build a complete, clean `PolicyDefinitions` folder from a single source (one specific, fully-patched reference machine, or an official downloaded Administrative Templates package), merge in any *extension* ADMX/L files the base OS package doesn't include (Office, MDOP, third-party applications with Group Policy support), and then **replace the entire store atomically** using a rename-swap: rename the new, complete folder into production (`PolicyDefinitions`) only after renaming the existing folder aside (e.g., `PolicyDefinitions-23H2`). This both prevents partial-update conflicts entirely and provides an instant, zero-risk rollback path — simply rename the old folder back if a problem surfaces.

### The `EnableLocalStoreOverride` Escape Hatch

A single registry value, `HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy\EnableLocalStoreOverride` (`REG_DWORD`), forces a specific machine to **always** use its own local `C:\Windows\PolicyDefinitions` instead of checking for a Central Store at all, regardless of whether one exists or how current it is. This has one legitimate, narrow use case: testing a newly built local ADMX folder against production GPOs on a single admin workstation *before* promoting that folder to the Central Store. Left set beyond that testing window, it silently and permanently isolates that one admin's editing experience from the Central Store — and from every other admin who isn't using the same override — reproducing the exact "different admins see different settings" problem the Central Store exists to solve, but now on a single machine that looks otherwise normal.

</details>

---
## Dependency Stack

```
Admin opens Group Policy Management Editor for any GPO, on any machine
  └── That machine's EnableLocalStoreOverride registry value
        ├── 1 — ALWAYS use local C:\Windows\PolicyDefinitions
        │       (Central Store existence/content is irrelevant on this machine)
        └── 0 / absent (default) — check for a Central Store
              └── \\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions exists?
                    ├── NO  — silent fallback to THIS machine's local
                    │        C:\Windows\PolicyDefinitions (OS-build/RSAT-version dependent)
                    └── YES — use the Central Store as the ADMX/ADML source
                          ├── Requires: SYSVOL share reachable from this machine
                          ├── Requires: SYSVOL/DFSR replication delivered current
                          │             content to the DC this machine is talking to
                          │             (see ActiveDirectory/Troubleshooting/GroupPolicy/
                          │              AD-GroupPolicy-A.md and DFS/Troubleshooting/
                          │              Replication/ if content is inconsistent across DCs)
                          ├── Requires: no duplicate ADMX target-namespace declarations
                          │             anywhere in the store (or the ENTIRE Administrative
                          │             Templates node fails to load, not just one setting)
                          └── Requires: every .admx has its .adml counterpart present, at
                                        a MATCHING version, in the relevant locale folder
                                        (or that one setting throws a resource-not-found
                                        error when rendered)

              (Independently, in parallel, regardless of any of the above:)
              Client-side Group Policy processing on END-USER machines
                reads registry.pol / applies GPO settings directly —
                has NO dependency on ADMX/ADML or the Central Store at all
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Two admins editing the same GPO from different machines see different available settings under Administrative Templates | No Central Store exists — each machine falls back to its own local, OS-build-dependent ADMX set | `Test-Path \\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions` |
| A newly released Windows/Office feature's policy setting doesn't appear in GPMC anywhere, despite clients being fully patched | Central Store exists but was never updated after that feature's ADMX shipped — Windows Update does not update the Central Store automatically | Compare the newest `.admx` LastWriteTime in the store against your current OS/Office servicing baseline |
| A setting shows as **"Extra Registry Settings"** and can't be edited via checkbox/dropdown UI | The current ADMX source (Central Store or local override) doesn't define that setting — either it's older than the store's baseline (legacy/removed) or newer than the store's last update | Confirm the setting's origin (which OS/Office version introduced or last shipped it) against the store's freshness |
| GPMC/GPEdit fails to load the entire Administrative Templates node with `Namespace '...' is already defined as the target namespace for another file in the store` | Two `.admx` files in the store declare the same namespace — caused by an incremental/partial file copy rather than a full replace | Enumerate every `.admx`'s declared `target namespace` and check for duplicates (see Evidence Pack) |
| A specific setting throws `Resource '$(string ID=...)' referenced in attribute displayName could not be found` | That setting's `.admx` and `.adml` are from different versions — one was updated without its pair | Compare file versions/dates of the specific `.admx` against its locale-folder `.adml` counterpart |
| A setting configured last month appears blank/gone after a routine GPO edit by a colleague | The GPO was opened and saved from a machine whose ADMX source didn't render that setting, and GPMC didn't preserve a value it couldn't display | `Get-GPRegistryValue` to check whether the raw value survives even though GPMC doesn't show it; restore from `Backup-GPO` history if it's genuinely gone |
| Central Store exists, is current, but one specific admin still reports missing/wrong settings | That admin's machine has `EnableLocalStoreOverride=1` set — possibly a forgotten diagnostic leftover | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy -Name EnableLocalStoreOverride` on that machine specifically |
| Central Store was just updated, but some DCs' admins still see the old behavior while others see the new one | SYSVOL/DFSR hasn't finished replicating the updated `PolicyDefinitions` folder to every DC yet, or a specific DC's DFSR is unhealthy | `dfsrdiag replicationstate`; cross-reference `ActiveDirectory/Troubleshooting/Replication/AD-Replication-A.md` |
| Office (or other extension) settings that used to work disappeared after a base-Windows ADMX refresh | The refresh replaced the store wholesale from a base-OS-only source without first merging in the extension ADMX/L files that were previously present | Confirm the pre-refresh store's extension files (Office, MDOP, third-party) were merged into the new folder before it was promoted to production |
| Duplicate-looking settings, or a setting that behaves inconsistently between two similarly-named policies | Two ADMX files with the same target namespace both loaded successfully in some tooling version but not others — a subtler variant of the namespace-conflict failure that doesn't always hard-fail | Same check as the namespace-conflict row; treat any duplicate namespace as a defect regardless of whether it currently throws a visible error |

---
## Validation Steps

**Step 1 — Confirm the Central Store exists and where it's located**
```powershell
$domain = (Get-ADDomain).DNSRoot
$store = "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions"
Test-Path $store
```
Expected: `True`. This is the prerequisite for every other check below — if `False`, stop here and go to Remediation Playbook 1 (initial creation) rather than diagnosing further.

**Step 2 — Determine store freshness**
```powershell
Get-ChildItem $store -Filter *.admx | Sort-Object LastWriteTime -Descending | Select-Object -First 5 Name, LastWriteTime
```
Expected: dates reasonably close to your current Windows/Office servicing baseline. A store with files dated years in the past, unchanged since creation, explains missing modern settings without any error being thrown.

**Step 3 — Check for duplicate ADMX namespaces (the cause of a full node-load failure)**
```powershell
Get-ChildItem $store -Filter *.admx | ForEach-Object {
  try {
    $xml = [xml](Get-Content $_.FullName -ErrorAction Stop)
    [PSCustomObject]@{ File = $_.Name; Namespace = $xml.policyDefinitions.policyNamespaces.target.namespace }
  } catch {
    [PSCustomObject]@{ File = $_.Name; Namespace = "PARSE ERROR: $_" }
  }
} | Group-Object Namespace | Where-Object Count -gt 1 | Select-Object Name, Count
```
Expected: no groups returned. Any namespace with `Count -gt 1` is a confirmed conflict that will block the Administrative Templates node from loading for anyone using this store.

**Step 4 — Check ADMX/ADML pairing completeness for a given locale**
```powershell
$locale = "en-US"
$admxNames = (Get-ChildItem $store -Filter *.admx).BaseName
$admlNames = (Get-ChildItem "$store\$locale" -Filter *.adml -ErrorAction SilentlyContinue).BaseName
Compare-Object $admxNames $admlNames | Where-Object SideIndicator -eq "<="
```
Expected: no output. Any `.admx` listed here has no matching `.adml` in that locale folder and will fail to render its display strings.

**Step 5 — Confirm SYSVOL/DFSR delivered current content consistently to every DC**
```powershell
$dcs = (Get-ADDomainController -Filter *).HostName
foreach ($dc in $dcs) {
  $path = "\\$dc\SYSVOL\$domain\Policies\PolicyDefinitions"
  $newest = (Get-ChildItem $path -Filter *.admx -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
  [PSCustomObject]@{ DC = $dc; NewestADMXDate = $newest }
}
```
Expected: the same (or near-identical, accounting for in-flight replication) newest-file date across every DC. A DC lagging significantly behind explains "the fix worked for some admins but not others."

**Step 6 — Confirm this admin's own machine isn't overridden to ignore the store**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy" -Name "EnableLocalStoreOverride" -ErrorAction SilentlyContinue
```
Expected: value absent or `0`.

**Step 7 — Confirm an already-applied client-side setting survives regardless of ADMX state**
```powershell
Get-GPRegistryValue -Name "<GPOName>" -Key "<RegistryKeyPath>"
```
Expected: the raw value is present in the GPO even if GPMC's UI can't currently render a friendly view of it — confirms the presentation-layer-only nature of the problem versus an actual data-loss event.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Establish Whether a Central Store Exists and Its Freshness
1. `Test-Path` the expected SYSVOL location
2. If absent, this is a Playbook 1 (initial creation) scenario — stop diagnosing individual settings and build one
3. If present, check the newest `.admx` file date against your current patch baseline

### Phase 2 — Classify the Failure
1. Full Administrative Templates node fails to load at all → namespace conflict (Validation Step 3) → Remediation Playbook 2
2. One specific setting shows "Extra Registry Settings" → missing definition (older or newer than the store) → confirm via Symptom → Cause Map, then Playbook 1 (rebuild) if the store is generally stale, or a targeted extension-file merge if it's a specific application's ADMX
3. One specific setting throws a resource-not-found error → ADMX/ADML pairing mismatch (Validation Step 4) → re-copy the matched pair
4. No error at all, but different admins see different settings → per-machine local fallback or `EnableLocalStoreOverride` (Validation Steps 1 and 6)

### Phase 3 — Confirm the Replication Layer Isn't the Actual Cause
1. If the store was recently updated but the problem persists inconsistently across admins, run Validation Step 5 before assuming the update itself was wrong
2. Cross-reference `ActiveDirectory/Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md` and `DFS/Troubleshooting/Replication/` if DFSR itself shows backlog or errors

### Phase 4 — Rebuild Cleanly (Never Patch Incrementally)
1. Identify a single, current, fully-patched reference machine (or an official downloaded Administrative Templates package) as the sole source
2. Build a complete new `PolicyDefinitions` folder from that source
3. Merge in extension ADMX/L files (Office, MDOP, third-party) that the base OS package doesn't include
4. Promote via rename-swap (see Remediation Playbook 1) — never copy individual files into the live, production-named folder

### Phase 5 — Validate Data Integrity, Not Just Editor Behavior
1. Confirm previously-configured settings that use the affected ADMX files still resolve correctly via `Get-GPRegistryValue`
2. Re-run Validation Steps 3 and 4 against the new store before considering the rebuild complete
3. Confirm replication to every DC (Validation Step 5) before declaring the rollout finished domain-wide

### Phase 6 — Prevent Recurrence
1. Document which reference machine/package is the designated "source of truth" for future Central Store updates
2. Establish a recurring (e.g., quarterly, or tied to major OS/Office feature updates) review cadence rather than updating reactively when a ticket surfaces
3. Audit for any `EnableLocalStoreOverride=1` machines left over from past diagnostics

---
## Remediation Playbooks

<details><summary>Playbook 1 — Clean rebuild / migration to a current ADMX baseline (rename-swap method)</summary>

**Scenario:** The Central Store is missing entirely, badly stale, or has accumulated namespace conflicts from past incremental updates, and needs to be rebuilt from a known-clean source without an outage or data loss.

**Step 1 — Identify a single source of truth**
Pick one current, fully-patched reference machine (or download the official Administrative Templates package for your target OS version) — never assemble the new store by combining files from multiple, possibly-inconsistent sources.

**Step 2 — Build the new folder OUTSIDE the production path first**
```powershell
$domain = (Get-ADDomain).DNSRoot
$newStore = "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions-New"
New-Item -Path $newStore -ItemType Directory -Force
# Copy from the reference machine's local C:\Windows\PolicyDefinitions (run from/against that machine)
# Copy-Item "C:\Windows\PolicyDefinitions\*" -Destination $newStore -Recurse -Force
```

**Step 3 — Merge in extension ADMX/L files (Office, MDOP, third-party) BEFORE promoting**
Copy any application-specific `.admx`/`.adml` pairs your environment relies on into `$newStore`, from their own official sources — do not carry these over from the old store blindly if a newer version of the application itself is in use.

**Step 4 — Validate the new folder before it goes live**
```powershell
# Namespace conflict check
Get-ChildItem $newStore -Filter *.admx | ForEach-Object {
  $xml = [xml](Get-Content $_.FullName)
  [PSCustomObject]@{ File = $_.Name; Namespace = $xml.policyDefinitions.policyNamespaces.target.namespace }
} | Group-Object Namespace | Where-Object Count -gt 1

# ADMX/ADML pairing check
$admxNames = (Get-ChildItem $newStore -Filter *.admx).BaseName
$admlNames = (Get-ChildItem "$newStore\en-US" -Filter *.adml -ErrorAction SilentlyContinue).BaseName
Compare-Object $admxNames $admlNames | Where-Object SideIndicator -eq "<="
```
Expected: no output from either check. Resolve any findings before proceeding to Step 5.

**Step 5 — Atomic promotion via rename-swap**
```powershell
$store = "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions"
$oldStore = "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions-Previous"

Rename-Item -Path $store -NewName "PolicyDefinitions-Previous" -ErrorAction Stop
Rename-Item -Path $newStore -NewName "PolicyDefinitions" -ErrorAction Stop
```

**Step 6 — Validate in production, monitor across a full admin work cycle**
Re-run Validation Steps 1-6 against the newly-promoted store. Watch for any "Extra Registry Settings" or resource-not-found reports from admins over the following days, not just immediately after promotion.

**Step 7 — Archive (don't immediately delete) the previous store**
Once stable for a defined period (e.g., two weeks), move `PolicyDefinitions-Previous` out of SYSVOL to an archive location rather than deleting it outright, in case an old, still-needed legacy ADMX definition is discovered missing later.

**Rollback note:** If a problem surfaces after promotion, reverse Step 5 exactly — rename `PolicyDefinitions` back to something else and rename `PolicyDefinitions-Previous` back to `PolicyDefinitions`. This is a near-instant, zero-data-loss rollback specifically because the swap never deleted anything.

</details>

<details><summary>Playbook 2 — Resolving a namespace conflict without a full rebuild (urgent, narrow fix)</summary>

**Scenario:** A namespace conflict is actively blocking the entire Administrative Templates node domain-wide, and a full Playbook 1 rebuild can't be completed immediately.

**Step 1 — Identify the exact conflicting files**
```powershell
$domain = (Get-ADDomain).DNSRoot
$store = "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions"
$conflicts = Get-ChildItem $store -Filter *.admx | ForEach-Object {
  $xml = [xml](Get-Content $_.FullName)
  [PSCustomObject]@{ File = $_.FullName; Namespace = $xml.policyDefinitions.policyNamespaces.target.namespace }
} | Group-Object Namespace | Where-Object Count -gt 1
$conflicts | ForEach-Object { $_.Group }
```

**Step 2 — Determine which file is current and which is stale**
Compare each conflicting file's version/date against your reference machine's current local copy of the same feature area — the goal is identifying the outdated leftover, not guessing.

**Step 3 — Remove ONLY the confirmed-stale file and its matching ADML entries**
```powershell
# After confirming which specific file is the outdated leftover:
Remove-Item "$store\<StaleFileName>.admx" -WhatIf   # remove -WhatIf once confirmed
Get-ChildItem "$store" -Recurse -Filter "<StaleFileName>.adml" | Remove-Item -WhatIf
```

**Step 4 — Re-validate immediately**
```powershell
Get-ChildItem $store -Filter *.admx | ForEach-Object {
  $xml = [xml](Get-Content $_.FullName)
  [PSCustomObject]@{ File = $_.Name; Namespace = $xml.policyDefinitions.policyNamespaces.target.namespace }
} | Group-Object Namespace | Where-Object Count -gt 1
```
Expected: no output.

**Step 5 — Schedule a proper Playbook 1 rebuild afterward**
This narrow fix resolves the immediate outage but does not address whatever process allowed a partial/incremental update to happen — schedule the full clean rebuild to establish a verified-consistent baseline rather than leaving the store in a hand-patched state.

**Rollback note:** Back up the store (or note exactly which file was removed) before deleting anything — if the "stale" file turns out to still be needed by some other still-in-use GPO setting, you'll need to restore it.

</details>

<details><summary>Playbook 3 — Establishing governance to prevent drift going forward</summary>

**Scenario:** The store has just been rebuilt/created and the team wants to avoid ending up back in this state.

**Step 1 — Designate and document a single source-of-truth reference**
Record which specific machine, or which official downloaded package, is the sanctioned source for future Central Store updates — and who owns keeping that reference current.

**Step 2 — Establish an update cadence tied to real triggers, not just "when someone notices"**
Recommended triggers: a new Windows feature update/Office version rollout, a specific ticket reporting a missing setting, or a fixed quarterly review — whichever comes first.

**Step 3 — Require the rename-swap method for every future update, without exception**
Document this as the only sanctioned update process — incremental copy-in-place updates are the direct, repeated root cause of this topic's most disruptive failure mode (namespace conflicts) and should be explicitly disallowed as a practice.

**Step 4 — Periodically audit for `EnableLocalStoreOverride` leftovers across admin workstations**
```powershell
# Run against known admin/RSAT-capable workstations
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy" -Name "EnableLocalStoreOverride" -ErrorAction SilentlyContinue
```
A machine found with this set outside an active, documented testing window should have it cleared.

**Step 5 — Keep the immediately-prior store archived, not deleted, after each rebuild**
Per Playbook 1 Step 7 — provides a recovery path if a legacy setting definition is later found to be missing.

**Rollback note:** N/A — this playbook establishes process, not a reversible technical change.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Group Policy Central Store / ADMX Evidence Collector
.NOTES     Run with read access to the SYSVOL Policies share; no changes are made.
#>

$domain = (Get-ADDomain).DNSRoot
$store = "\\$domain\SYSVOL\$domain\Policies\PolicyDefinitions"
$reportPath = "C:\Temp\GPOCentralStoreEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== Central Store Existence & Freshness ===" | Out-File "$reportPath\01_StoreStatus.txt"
if (Test-Path $store) {
  "Store exists at: $store" | Out-File "$reportPath\01_StoreStatus.txt" -Append
  Get-ChildItem $store -Filter *.admx | Sort-Object LastWriteTime -Descending |
    Select-Object -First 10 Name, LastWriteTime | Format-Table -AutoSize |
    Out-File "$reportPath\01_StoreStatus.txt" -Append
} else {
  "Store does NOT exist at: $store" | Out-File "$reportPath\01_StoreStatus.txt" -Append
}

"=== Namespace Conflict Check ===" | Out-File "$reportPath\02_NamespaceConflicts.txt"
if (Test-Path $store) {
  Get-ChildItem $store -Filter *.admx | ForEach-Object {
    try {
      $xml = [xml](Get-Content $_.FullName -ErrorAction Stop)
      [PSCustomObject]@{ File = $_.Name; Namespace = $xml.policyDefinitions.policyNamespaces.target.namespace }
    } catch {
      [PSCustomObject]@{ File = $_.Name; Namespace = "PARSE ERROR" }
    }
  } | Group-Object Namespace | Where-Object Count -gt 1 |
    Format-Table -AutoSize | Out-File "$reportPath\02_NamespaceConflicts.txt" -Append
}

"=== ADMX/ADML Pairing Check (en-US) ===" | Out-File "$reportPath\03_PairingCheck.txt"
if (Test-Path "$store\en-US") {
  $admxNames = (Get-ChildItem $store -Filter *.admx).BaseName
  $admlNames = (Get-ChildItem "$store\en-US" -Filter *.adml).BaseName
  Compare-Object $admxNames $admlNames | Where-Object SideIndicator -eq "<=" |
    Out-File "$reportPath\03_PairingCheck.txt" -Append
}

"=== EnableLocalStoreOverride (this machine) ===" | Out-File "$reportPath\04_LocalOverride.txt"
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy" -Name "EnableLocalStoreOverride" -ErrorAction SilentlyContinue |
  Format-List | Out-File "$reportPath\04_LocalOverride.txt" -Append

"=== Per-DC Store Freshness ===" | Out-File "$reportPath\05_PerDCFreshness.txt"
$dcs = (Get-ADDomainController -Filter *).HostName
foreach ($dc in $dcs) {
  $path = "\\$dc\SYSVOL\$domain\Policies\PolicyDefinitions"
  $newest = (Get-ChildItem $path -Filter *.admx -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
  "$dc : $newest" | Out-File "$reportPath\05_PerDCFreshness.txt" -Append
}

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check whether a Central Store exists | `Test-Path \\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions` |
| Check newest ADMX file date (staleness) | `Get-ChildItem $store -Filter *.admx \| Sort LastWriteTime -Descending \| Select -First 1` |
| Check for duplicate ADMX namespaces | See Evidence Pack section 02, or Validation Step 3 |
| Check ADMX/ADML pairing gaps | See Evidence Pack section 03, or Validation Step 4 |
| Check local override on this machine | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\Group Policy -Name EnableLocalStoreOverride` |
| Force this machine to always use local ADMX | `Set-ItemProperty HKLM:\...\Group Policy -Name EnableLocalStoreOverride -Value 1` |
| Revert to using the Central Store | `Remove-ItemProperty HKLM:\...\Group Policy -Name EnableLocalStoreOverride` |
| Read a GPO's raw registry value (bypasses ADMX rendering) | `Get-GPRegistryValue -Name "<GPOName>" -Key "<RegistryKeyPath>"` |
| Set a GPO's raw registry value without ADMX | `Set-GPRegistryValue -Name "<GPOName>" -Key "<RegistryKeyPath>" -ValueName "<Value>" -Type DWord -Value <n>` |
| Atomically promote a rebuilt store | `Rename-Item $store "PolicyDefinitions-Previous"; Rename-Item $newStore "PolicyDefinitions"` |
| Restore a GPO from backup | `Restore-GPO -Name "<GPOName>" -Path "<BackupFolderPath>"` |
| Check SYSVOL/DFSR replication state | `dfsrdiag replicationstate` |
| List all DCs to check store consistency across | `Get-ADDomainController -Filter *` |

---
## 🎓 Learning Pointers

- **The Central Store is discovered automatically and silently — there's no error for its absence.** Every editing machine independently falls back to its own local ADMX set if the SYSVOL folder isn't there, producing divergent GPMC experiences with no indication anything is inconsistent. Confirming its existence should be step one for any "the GPO editor is behaving oddly" ticket.
- **ADMX/ADML is a presentation layer over `registry.pol`, never the policy value's storage.** A missing or broken ADMX definition affects what an admin can safely *view and re-save*; it never affects what's already enforced on client machines, which read `registry.pol` directly (see `Windows/Troubleshooting/GPO-A.md`).
- **Windows Update ships new local ADMX files on clients; it never touches your domain's Central Store.** Treat Central Store updates as a deliberate, scheduled administrative task tied to your OS/Office update cadence — not something that happens automatically alongside patching.
- **Never update the Central Store by copying individual new files over old ones.** This is the specific, well-documented cause of namespace conflicts that can fail the entire Administrative Templates node, not just one setting. Always rebuild from a single clean source and promote atomically via rename-swap.
- **An ADMX and its ADML must always be sourced and updated together, as a matched pair.** Updating one without the other produces resource-not-found errors for that setting's display strings, even though the underlying registry mapping itself may still be perfectly valid.
- **`EnableLocalStoreOverride=1` is a legitimate but easy-to-forget diagnostic tool.** Audit for it periodically on admin workstations — a machine stuck on this setting reproduces the exact "inconsistent admin experience" problem the Central Store exists to prevent.
- Related: [How to create and manage the Central Store for Group Policy Administrative Templates in Windows](https://learn.microsoft.com/en-us/troubleshoot/windows-client/group-policy/create-and-manage-central-store), [Group Policy settings show as Extra Registry Settings and can't be edited](https://learn.microsoft.com/en-us/troubleshoot/windows-server/group-policy/group-policy-settings-show-as-extra-registry-settings), [Managing Group Policy ADMX Files Step-by-Step Guide](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-vista/cc709647(v=ws.10))
