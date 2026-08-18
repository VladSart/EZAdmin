# Entra Connect Sync — Mandatory Upgrade / Version EOL Readiness — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- The Microsoft Entra Connect Sync (on-prem sync-engine) **version lifecycle**: the 30 September 2026 mandatory-upgrade deadline (must be at or above `2.5.79.0`), the rolling per-version 12-month retirement policy, and how the two interact
- Version detection (running vs. installed-metadata), prerequisite requirements, and the Admin-Center-only distribution model
- Auto-upgrade mechanics and eligibility — including the documented `miiserver.exe.config`/`miisclient.exe.config` modification skip condition introduced in 2.6.3.0
- The specific known-issue failure chain (manually modified `miiserver.exe.config` → post-upgrade `FileLoadException`) and its fix
- What changed in the current release (`2.6.84.0`) that carries operational impact for MSPs: passwordless setup-wizard auth, App-Based Authentication behavior changes, PHS self-healing removal, PowerShell cmdlet parameter changes
- The 2.6.79.0 recall as a cautionary example of why "latest ≠ always safe to auto-apply blindly"

**Does not cover:**
- **Attribute sync errors, object matching/joining, and staging-mode day-2 operational issues** on an already-current Connect Sync server — that is `Connect-Sync-A.md`/`-B.md`'s scope; this file is purely about the version/upgrade lifecycle itself
- **Migrating from Entra Connect Sync to Entra Cloud Sync** as an architectural change (different sync engine, different topology, different feature-parity constraints) — see `CloudSync-A.md`/`-B.md` for the target architecture; this file assumes the customer is staying on Connect Sync and simply needs to stay supported
- **Password Hash Sync, Pass-through Authentication, or Seamless SSO configuration** beyond the specific FIPS-mode config-file modification known issue — see the relevant hybrid-auth documentation for general PHS/PTA/SSO troubleshooting
- **AD FS / federation** — Entra Connect Sync's upgrade lifecycle is independent of any federation server upgrade cadence

**Assumes:**
- An existing, functioning Microsoft Entra Connect Sync server (single-server or staging-mode pair) already performing directory synchronization
- Local administrator access to the sync server for version checks, prerequisite checks, and running the installer
- Ability to reach the Microsoft Entra Admin Center to download the current installer (the .msi is no longer distributed via a generic public download-center URL)

---
## How It Works

<details><summary>Full architecture — the version lifecycle model</summary>

### Two independent clocks, one shared consequence

Microsoft Entra Connect Sync's supportability is governed by two separate mechanisms that are easy to conflate:

1. **The mandatory-upgrade floor.** In May 2025, Microsoft released version `2.5.79.0` containing a back-end service hardening change. Any server still below this version loses synchronization entirely — not degraded, not "unsupported," genuinely non-functional — starting **30 September 2026**. This is a one-time, hard cutover tied to a specific back-end compatibility change, not a recurring policy.
2. **The rolling per-version retirement policy**, in effect since 15 March 2023: every Microsoft Entra Connect Sync 2.x version retires exactly 12 months after its *successor* version is released. This is continuous and version-specific — a server can clear the mandatory floor entirely and still be sitting on a version whose own 12-month clock has already run out.

Both clocks matter for different reasons. Missing the mandatory floor is a hard outage. Running a retired-but-above-floor version is a soft risk: Microsoft states it "might unexpectedly stop working," won't receive further security fixes, and support may be limited if a ticket is opened against it — serious for an MSP's SLA obligations even though it isn't an immediate hard stop.

### Version detection — why "installed version" and "running version" can disagree

Microsoft occasionally pushes incremental back-end service updates to a running Connect Sync server without bumping what Programs and Features reports as the installed version. This means the GUI-visible "installed version" can understate what's actually running. The authoritative check is the running binary itself:

```powershell
(Get-Item "C:\Program Files\Microsoft Azure AD Sync\Bin\miiserver.exe").VersionInfo.ProductVersion
```

A second, independent cross-check reads the server configuration version the sync engine itself reports:

```powershell
(Get-ADSyncGlobalSettingsParameter | Where-Object { $_.Name -eq 'Microsoft.Synchronize.ServerConfigurationVersion' }).Value
```

These two should agree; a mismatch is worth investigating on its own before trusting either number for a compliance/deadline assessment.

### Distribution model change

The installer `.msi` is now exclusively hosted in the **Microsoft Entra Admin Center**, under the Connect provisioning blade's **Get started → Manage** tab. This is a meaningful operational change from earlier years when a generic Microsoft download-center URL was the standard reference — any MSP runbook, ticket template, or automation script still pointing at an old download-center link needs updating, since that link may no longer serve the current build (or may not exist at all).

### Auto-upgrade — eligibility is neither universal nor guaranteed

Two independent gates determine whether a given server auto-upgrades to a given release:

1. **Release publication status.** Not every version Microsoft ships is published for auto-upgrade — some releases are explicitly download-only. The version-history page marks each release's status; a server "should have" auto-upgraded only if the specific target release was actually published for auto-upgrade in the first place.
2. **Server-side eligibility.** As of version `2.6.3.0`, Microsoft added an explicit, deliberate skip condition: if `miiserver.exe.config` or `miisclient.exe.config` has been manually modified on a given server, auto-upgrade detects this and skips that server rather than risk silently discarding the customization (see the Known Issue section below for why this matters). A server meeting this condition needs a **manual** upgrade, with the administrator responsible for re-applying any required binding-redirect fix by hand.

Auto-upgrade, when it applies, is described by Microsoft as intended to push *important* updates and critical fixes — not necessarily the literal latest version if there's no critical-fix reason to push it. A server that's several minor versions "behind" the very latest release via auto-upgrade alone is not necessarily broken; it may simply not have needed a critical-fix push yet. This nuance matters when a compliance sweep flags "not on the latest version" — cross-reference against the mandatory floor and the version's own retirement date before treating every non-latest server as an incident.

### Known issue: post-upgrade `FileLoadException` from a customized config file

This is the single most disruptive documented failure mode in the current version-history record, and it specifically targets a well-intentioned prior customization. Historical Microsoft guidance for enabling Password Hash Synchronization in FIPS-compliant environments instructed administrators to manually modify `miiserver.exe.config`. When such a server upgrades to `2.5.190.0` or `2.6.1.0`, the upgrade process detects the modified file and deliberately does not overwrite it (to protect the customization) — but this also means a required assembly binding redirect for `System.Diagnostics.DiagnosticSource` never gets applied. The result: synchronization fails immediately post-upgrade with `System.IO.FileLoadException: Could not load file or assembly 'System.Diagnostics.DiagnosticSource, Version=6.0.0.1'...`.

The documented workaround is a manual edit: add a `<dependentAssembly>` binding redirect entry for `System.Diagnostics.DiagnosticSource` (public key token `cc7b13ffcd2ddd51`, redirecting versions `0.0.0.0-8.0.0.0` to `8.0.0.0`) inside the `<assemblyBinding>` section of `miiserver.exe.config`, then restart the `ADSync` service.

Version `2.6.3.0` addressed the *systemic* risk (auto-upgrade now skips servers with modified config files entirely, per the eligibility gate above), but a server upgrading manually still needs the fix applied by hand if it has this specific customization history.

### What changed in the current release (2.6.84.0)

Released 7 July 2026, flagged by Microsoft as containing security fixes with an explicit "upgrade as soon as possible" recommendation. Operationally relevant changes for MSPs managing multiple tenants:

- **Auto-upgrade now merges, rather than overwrites, customer config-file modifications** — a direct architectural fix to the class of problem described above, validating the merged result before applying it. This changes the calculus for future config customizations, though existing modified-config servers should still be treated per the known-issue guidance until confirmed otherwise on a case-by-case basis.
- **App-Based Authentication setup no longer silently falls back** to the legacy directory synchronization account on failure — it now stops with an explicit error, surfacing configuration problems instead of masking them behind a working-but-less-secure fallback.
- **Existing servers no longer get automatically switched** from the legacy sync account to Application-Based Authentication in the background; only new installations configure it during setup. Switching an existing server now requires deliberately re-running the setup wizard.
- **Removed Password Hash Synchronization self-healing.** PHS no longer automatically re-enables its own cloud feature flag if something disables it — an administrator must explicitly re-enable it. A tenant that previously relied on PHS "just coming back" after an unexpected flag flip now needs active monitoring for this condition.
- **`Set-ADSyncAADCompanyFeature` and `Set-ADSyncAADPasswordSyncState` now require explicit `-AADUsername`** for interactive authentication — any existing automation script calling these cmdlets non-interactively needs review against this new requirement.
- Added phishing-resistant authentication (passkeys, FIDO2 security keys via Windows Web Account Manager) as a preview option for the setup wizard's own admin sign-in, and France sovereign cloud support.

Version `2.6.79.0`, released between `2.6.3.0` and `2.6.84.0`, was recalled after a post-release issue was identified — the installer was withdrawn from distribution entirely. Any server showing this exact version should be uninstalled and reinstalled with the current release rather than patched forward; this is a useful cautionary data point that "most recent release" and "safe to blanket-auto-apply" aren't always the same thing, even for a vendor with Microsoft's release-QA process.

</details>

---
## Dependency Stack

```
Layer 5 — The 30 Sep 2026 mandatory-upgrade deadline (hard, tenant-wide, one-time)
          — governs whether sync functions AT ALL past this date
Layer 4 — Per-version rolling 12-month retirement policy (continuous, ongoing)
          — governs supportability/security-fix currency independent of Layer 5
Layer 3 — Distribution + prerequisites
          ├─ Installer sourced from Microsoft Entra Admin Center exclusively
          └─ .NET Framework 4.7.2+ and TLS 1.2 enabled — installer hard-fails
                its own prereq gate otherwise
Layer 2 — Auto-upgrade eligibility (two independent gates)
          ├─ Release must be published for auto-upgrade (not all are)
          └─ Server config must not trip the modified-config-file skip
                (miiserver.exe.config / miisclient.exe.config, since 2.6.3.0)
Layer 1 — Manual upgrade path (used when Layer 2 doesn't apply)
          — in-place .msi install; config-modification known issue (Learning
            Pointers / Remediation Playbook 2) must be handled explicitly here
Layer 0 — Post-upgrade validation
          — ADSync service running, delta sync cycle completes clean,
            no new FileLoadException-class errors
```

A gap at Layer 5 is the only layer with a hard, non-negotiable deadline attached — treat it as the forcing function for everything below it. A gap at Layer 3 (prerequisites) blocks the installer from even starting, regardless of how urgent Layer 5 is.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Programs and Features shows an old version, but sync appears otherwise healthy | Incremental back-end service push without an installed-metadata bump | Check `miiserver.exe.VersionInfo.ProductVersion` directly, not Programs and Features |
| Server confirmed below `2.5.79.0` | On the hard mandatory-upgrade path — will fail entirely after 30 Sep 2026 | Schedule an upgrade immediately, treat as P1 scheduling regardless of current apparent health |
| Server above `2.5.79.0` but flagged in a compliance sweep as "outdated" | May simply be past its own individual retirement date, a separate (softer) risk | Cross-reference against the per-version EOS table |
| Old bookmarked Microsoft download-center link for the installer 404s or serves an unexpected build | Distribution model changed — installer is Admin-Center-only now | Pull the installer from Microsoft Entra Admin Center → Connect → Get started → Manage |
| Auto-upgrade "should have" applied but didn't, server is online and otherwise healthy | Release wasn't published for auto-upgrade, or server tripped the modified-config-file skip (2.6.3.0+) | Confirm release's auto-upgrade status; check `miiserver.exe.config`/`miisclient.exe.config` modification history |
| Sync fails immediately post-upgrade with `System.Diagnostics.DiagnosticSource` / `FileLoadException` | Manually modified `miiserver.exe.config` (commonly FIPS-mode PHS guidance) lost its required binding redirect during upgrade to `2.5.190.0` or `2.6.1.0` | Manually add the `dependentAssembly` binding redirect entry, restart `ADSync` |
| Server shows version `2.6.79.0` | Recalled release | Uninstall, reinstall the current version instead of patching forward |
| Installer fails before completing any install steps | `.NET Framework` below 4.7.2, or TLS 1.2 not enabled at OS level | Check the .NET release registry key and TLS 1.2 SCHANNEL keys |
| PHS silently stopped working with no obvious trigger, on a server running `2.6.84.0`+ | PHS self-healing was removed in this release — the cloud feature flag no longer auto-re-enables | Check the PHS cloud feature flag state directly and re-enable manually if disabled |
| Automation script calling `Set-ADSyncAADCompanyFeature` or `Set-ADSyncAADPasswordSyncState` starts failing after an upgrade | These cmdlets now require explicit `-AADUsername` for interactive auth as of `2.6.84.0` | Update the script to pass `-AADUsername` and handle the interactive MSAL prompt, or redesign the automation around this new constraint |

---
## Validation Steps

1. **Confirm true running version.**
   ```powershell
   (Get-Item "C:\Program Files\Microsoft Azure AD Sync\Bin\miiserver.exe").VersionInfo.ProductVersion
   ```
   Expected: a version at or above `2.5.79.0` at minimum, ideally the current release. Bad: anything below `2.5.79.0` — treat as urgent.

2. **Cross-check via the ADSync module.**
   ```powershell
   (Get-ADSyncGlobalSettingsParameter | Where-Object { $_.Name -eq 'Microsoft.Synchronize.ServerConfigurationVersion' }).Value
   ```
   Expected: agrees with step 1. Bad: material disagreement — investigate before trusting either number for a deadline/compliance decision.

3. **Prerequisites present.**
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release
   ```
   Expected: release key `461808` or higher (4.7.2+). Bad: below this threshold — the installer will refuse to proceed.

4. **TLS 1.2 enabled.**
   ```powershell
   Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" -ErrorAction SilentlyContinue
   ```
   Expected: key present, `Enabled = 1`, `DisabledByDefault = 0`. Bad: key absent or explicitly disabled.

5. **Config-file modification history checked before any upgrade.**
   ```powershell
   (Get-Item "$env:ProgramFiles\Microsoft Azure AD Sync\Bin\miiserver.exe.config").LastWriteTime
   ```
   Expected: timestamp consistent with the original install/last official upgrade. Bad: a timestamp significantly newer, suggesting manual modification — plan for the Fix 4 (Mode B) config remediation proactively rather than reactively after a failure.

6. **Post-upgrade service and sync-cycle health.**
   ```powershell
   Get-Service ADSync | Select-Object Status
   Start-ADSyncSyncCycle -PolicyType Delta
   ```
   Expected: `Running`, and the delta cycle completes with no new errors. Bad: service not running, or a fresh `FileLoadException`-class error appears — treat as an incomplete upgrade, not a transient blip.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Establish true current state.**
Get the running version (not the installed-metadata version), cross-check it against the ADSync module's own report, and compare against both the mandatory floor and the per-version retirement table. Don't proceed to remediation planning until this is unambiguous.

**Phase 2 — Classify urgency.**
Below `2.5.79.0` is a hard, dated, tenant-wide outage risk — schedule immediately regardless of current apparent sync health. At/above the floor but past individual retirement is a softer, ongoing supportability risk — schedule normally, but don't treat it with Phase-1-below-floor urgency.

**Phase 3 — Confirm prerequisites before touching the installer.**
.NET Framework and TLS 1.2 gaps cause the installer to fail its own prereq check — resolve these first, especially on older Windows Server builds that may predate .NET 4.7.2 by default.

**Phase 4 — Determine auto-upgrade eligibility, don't assume it.**
Check both whether the target release was published for auto-upgrade and whether this specific server's config-file state would trip the 2.6.3.0+ skip condition. A server needing manual upgrade because of legitimate customization is expected behavior, not a fault to chase.

**Phase 5 — If manually upgrading a server with known config customization, pre-stage the fix.**
Don't wait for the post-upgrade `FileLoadException` to appear — if this server's `miiserver.exe.config` was modified for FIPS-mode PHS (or any other reason), have the binding-redirect fix ready to apply immediately after the installer completes, and validate with a delta sync cycle before considering the change closed.

**Phase 6 — Post-upgrade validation is mandatory, not optional.**
A completed installer run is not the same as a working sync engine. Confirm service state and run an actual delta sync cycle before closing out the change.

**Phase 7 — Escalate to Microsoft only after Phases 1-6 clear and a failure persists.**
If version, prerequisites, config-file state, and the documented known-issue fix are all confirmed correct and sync still fails post-upgrade, capture the exact error text and escalate — a genuinely novel failure mode on a fresh major release is more plausible here than a misapplied documented fix.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Bringing a below-floor server current before 30 Sep 2026</summary>

1. Confirm the exact running version via `miiserver.exe.VersionInfo.ProductVersion`.
2. Back up the sync database (SQL or LocalDB, depending on install type) and take a VM snapshot if virtualized — an in-place upgrade has no built-in downgrade path.
3. Confirm `.NET Framework 4.7.2+` and `TLS 1.2` are present; remediate first if not.
4. Download the current installer from **Microsoft Entra Admin Center → Microsoft Entra Connect → Get started → Manage**. Do not use an old download-center bookmark.
5. Check whether `miiserver.exe.config`/`miisclient.exe.config` has ever been manually modified on this server (Validation Step 5). If yes, be prepared to apply the Fix 4 (Mode B) binding-redirect fix immediately post-install.
6. Run the installer. If this server is a staging-mode secondary, upgrade it first and validate before touching the active primary (see Playbook 3).
7. Post-install: confirm `ADSync` service is `Running`, run `Start-ADSyncSyncCycle -PolicyType Delta`, confirm clean completion.
8. Record the new version and date for the tenant's own compliance tracking — this deadline will recur in spirit (a future hardening release is plausible) even though this specific 30 Sep 2026 date is a one-time event.

**Rollback:** restore from the pre-upgrade VM snapshot or sync-database backup if the upgrade produces an unresolvable failure; escalate to Microsoft with the exact error text before attempting a second in-place upgrade over a failed one.
</details>

<details><summary>Playbook 2 — Resolving the config-modification post-upgrade failure</summary>

1. Confirm the failure signature: `System.IO.FileLoadException` referencing `System.Diagnostics.DiagnosticSource`, occurring immediately after an upgrade to `2.5.190.0` or `2.6.1.0`.
2. Confirm `miiserver.exe.config` has a modification history predating the upgrade (Validation Step 5) — this narrows the cause to the documented known issue rather than a novel failure.
3. Back up the current (broken) config file before editing.
4. Add the documented `dependentAssembly` binding-redirect entry for `System.Diagnostics.DiagnosticSource` (public key token `cc7b13ffcd2ddd51`, redirect `0.0.0.0-8.0.0.0` → `8.0.0.0`) inside the `<assemblyBinding>` section.
5. Restart the `ADSync` service and run a delta sync cycle to confirm resolution.
6. If this server is on `2.6.3.0` or later going forward, note that future auto-upgrades will skip it automatically because of this same config-modification history — plan for manual upgrades with this same pre-staged fix on every future version bump until/unless the customization is retired.

**Rollback:** restore the pre-edit config backup if the binding-redirect addition doesn't resolve the error, and escalate — a config file modified for reasons beyond the documented FIPS/PHS scenario may need a different, undocumented fix.
</details>

<details><summary>Playbook 3 — Staging-mode pair upgrade sequencing</summary>

1. Identify which server is currently active (`Get-ADSyncScheduler` — check `StagingModeEnabled` on each) before starting.
2. Upgrade the staging (inactive) server first, following Playbook 1 in full.
3. Validate the staging server independently — confirm service health and that it can complete a delta sync cycle while still in staging mode (staging-mode sync cycles run but do not export to the connected directories, so this is a safe validation step).
4. Only once the staging server is confirmed healthy on the new version, upgrade the active primary, following Playbook 1.
5. Do not use this window to also promote staging to active — treat the version upgrade and any staging/active role change as two separate, sequential maintenance actions to keep the blast radius of any single change small.

**Rollback:** if the staging server's post-upgrade validation fails, it can remain in staging mode indefinitely without impacting production while investigated — there is no time pressure to proceed to the active server until staging is confirmed healthy.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Entra Connect Sync version/EOL readiness evidence for a
             server, for ticket escalation or tenant compliance tracking.
.DESCRIPTION Read-only. Captures running version, prerequisite state, config-file
             modification signal, and service health, exporting to CSV.
.EXAMPLE     .\Get-ConnectSyncUpgradeEvidence.ps1
.NOTES       Run locally on the Entra Connect Sync server with local admin rights.
#>

$binPath = "$env:ProgramFiles\Microsoft Azure AD Sync\Bin"
$installedVersion = (Get-Item "$binPath\miiserver.exe").VersionInfo.ProductVersion
Import-Module ADSync -ErrorAction SilentlyContinue
$configVersion = (Get-ADSyncGlobalSettingsParameter -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -eq 'Microsoft.Synchronize.ServerConfigurationVersion' }).Value
$netRelease = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release -ErrorAction SilentlyContinue).Release
$tlsClient = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" -ErrorAction SilentlyContinue
$configLastWrite = (Get-Item "$binPath\miiserver.exe.config" -ErrorAction SilentlyContinue).LastWriteTime
$svc = Get-Service ADSync -ErrorAction SilentlyContinue

[PSCustomObject]@{
    Hostname               = $env:COMPUTERNAME
    InstalledVersion        = $installedVersion
    ServerConfigVersion      = $configVersion
    BelowMandatoryFloor      = ([version]$installedVersion -lt [version]"2.5.79.0")
    DotNetReleaseKey          = $netRelease
    TLS12ClientEnabled        = ($tlsClient.Enabled -eq 1)
    ConfigFileLastWriteTime   = $configLastWrite
    ADSyncServiceStatus       = $svc.Status
    CollectedAt               = Get-Date
} | Export-Csv -Path ".\ConnectSyncUpgradeReadiness_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
```

---
## Command Cheat Sheet

```powershell
# True running version (authoritative over Programs and Features)
(Get-Item "C:\Program Files\Microsoft Azure AD Sync\Bin\miiserver.exe").VersionInfo.ProductVersion

# Server-reported configuration version
Import-Module ADSync
(Get-ADSyncGlobalSettingsParameter | Where-Object { $_.Name -eq 'Microsoft.Synchronize.ServerConfigurationVersion' }).Value

# .NET Framework release key (461808+ = 4.7.2+)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release

# TLS 1.2 registry check
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" -ErrorAction SilentlyContinue

# Config-file modification signal
(Get-Item "C:\Program Files\Microsoft Azure AD Sync\Bin\miiserver.exe.config").LastWriteTime

# Service + sync-cycle health
Get-Service ADSync
Start-ADSyncSyncCycle -PolicyType Delta

# Staging-mode check (per server in a pair)
(Get-ADSyncScheduler).StagingModeEnabled

# PHS cloud feature flag (manual re-enable — self-healing removed in 2.6.84.0)
Set-ADSyncAADPasswordSyncState -AADUsername "<admin@contoso.com>" -Enable $true

# RSS release-notification feed
# https://aka.ms/aadconnectrss

# Installer source (portal, not a direct download URL)
# Microsoft Entra Admin Center → Microsoft Entra Connect → Get started → Manage
```

---
## 🎓 Learning Pointers

- **Treat 30 September 2026 as a hard, dated commitment across every customer with an on-prem Connect Sync server** — build it into scheduling now rather than waiting for a reactive fire drill in the final weeks. [Microsoft Entra Connect: Version release history](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/reference-connect-version-history)
- **"Installed version" and "running version" can disagree** because Microsoft occasionally pushes incremental back-end updates without bumping install metadata — always verify via `miiserver.exe.VersionInfo.ProductVersion` directly for any compliance-sensitive check, never trust Programs and Features alone.
- **The mandatory floor and per-version retirement are two separate clocks that both need tracking.** A server can be fully clear of the 30 Sep 2026 deadline and still be running a version whose own 12-months-after-successor retirement date has already passed — a compliance sweep needs to check both.
- **A modified `miiserver.exe.config` is a landmine that specifically detonates on upgrade, not on install.** If an MSP has ever applied FIPS-mode Password Hash Sync guidance (or any other manual config edit) to a customer's Connect Sync server, that server needs the binding-redirect fix pre-staged before any future manual upgrade to `2.5.190.0`/`2.6.1.0`-class releases — waiting for the failure to appear costs an unplanned sync outage.
- **PHS self-healing is gone as of `2.6.84.0`.** Any tenant relying on the old "it just comes back" behavior for the Password Hash Sync cloud feature flag needs active monitoring going forward — build a check for this into recurring health audits rather than assuming PHS state is self-correcting.
- **The 2.6.79.0 recall is a useful reminder that "latest release" and "safe to blanket auto-apply immediately" aren't synonyms even for a mature Microsoft product** — a brief staged/staggered rollout across a multi-tenant MSP's customer base (rather than pushing every server to the exact newest build the same day it ships) reduces blast radius if a future release has a similar issue. [Microsoft Entra Connect: Upgrade from a previous version](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-upgrade-previous-version)
