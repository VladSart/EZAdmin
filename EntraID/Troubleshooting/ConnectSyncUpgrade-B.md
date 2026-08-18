# Entra Connect Sync — Mandatory Upgrade / Version EOL Readiness — Hotfix Runbook (Mode B: Ops)
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

```powershell
# Run ON the Entra Connect Sync server. No Graph connection required for these checks.

# 1. Installed (running) version — the authoritative check, not Programs and Features
#    (Microsoft sometimes pushes incremental service updates without bumping install metadata)
$installedVersion = (Get-Item "C:\Program Files\Microsoft Azure AD Sync\Bin\miiserver.exe").VersionInfo.ProductVersion
$installedVersion

# 2. Cross-check via the ADSync module itself
Import-Module ADSync -ErrorAction SilentlyContinue
$serverConfigVersion = (Get-ADSyncGlobalSettingsParameter | Where-Object { $_.Name -eq 'Microsoft.Synchronize.ServerConfigurationVersion' }).Value
$serverConfigVersion

# 3. Compare against the hard mandatory-upgrade floor
$mandatoryFloor = [version]"2.5.79.0"
$isBelowFloor = [version]$installedVersion -lt $mandatoryFloor
"Below mandatory floor (2.5.79.0)?  $isBelowFloor"

# 4. Confirm minimum prereqs (both required for any successful upgrade)
[System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
[Net.ServicePointManager]::SecurityProtocol

# 5. Confirm the ADSync scheduler / service is actually running today (a stalled server
#    can look like a version problem when it's really a service problem)
Get-Service ADSync | Select-Object Status, StartType
```

| Triage result | Interpretation | Do this |
|---|---|---|
| `$installedVersion` is below `2.5.79.0` | **Sync stops working entirely on 30 Sep 2026** — this is a hard mandatory-upgrade deadline, not a routine EOL warning | Fix 1 |
| `$installedVersion` is `2.5.79.0` or higher, but older than the current release (`2.6.84.0` as of this writing) | Not on the mandatory floor's failure path, but likely past its own individual retirement date — check the version table in Fix 2 | Fix 2 |
| `$installedVersion` shows `2.6.79.0` | **Recalled release** — an issue was found post-release and the installer was withdrawn | Fix 3 |
| Upgrade completes but sync fails immediately after, citing `System.Diagnostics.DiagnosticSource` / `FileLoadException` | `miiserver.exe.config` was manually modified before upgrade (commonly for FIPS-mode Password Hash Sync) and the binding wasn't preserved | Fix 4 |
| Auto-upgrade never applied even though the server is online and healthy | Config-file customization is now (as of 2.6.3.0+) an explicit auto-upgrade skip condition — or the release simply wasn't published for auto-upgrade | Fix 5 |
| `.NET Framework` below 4.7.2 or TLS 1.2 not enabled | Upgrade installer will fail prerequisite checks before it starts | Fix 6 |
| Server is a swing/staging-mode secondary, not the active primary | Upgrade order and validation steps differ from a single-server topology | Fix 7 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Mandatory upgrade deadline: 30 Sep 2026 — ALL sync services stop, tenant-wide,
if server is below 2.5.79.0 (May 2025 back-end hardening release)
   │
   ├─ Per-version rolling retirement policy (independent of the mandatory floor)
   │     — every 2.x version retires 12 months after its successor releases
   │     — a server CAN be above 2.5.79.0 and still be past its own EOS date
   │
   ├─ Installer source: Microsoft Entra Admin Center ONLY
   │     (Microsoft_AAD_Connect_Provisioning blade → Get started → Manage tab)
   │     — the .msi is no longer distributed from a generic download-center URL
   │
   ├─ Prerequisites (installer hard-fails without these)
   │     ├─ .NET Framework 4.7.2 or later
   │     └─ TLS 1.2 enabled at the OS level
   │
   ├─ Auto-upgrade eligibility (NOT guaranteed for every server)
   │     ├─ Release must be published for auto-upgrade (not every version is —
   │     │     some are download-only)
   │     └─ Server config must not trip a known skip condition — as of 2.6.3.0,
   │           a manually modified miiserver.exe.config / miisclient.exe.config
   │           is an explicit, deliberate auto-upgrade skip
   │
   └─ Manual upgrade path (when auto-upgrade is skipped or unavailable)
         └─ Run the downloaded .msi directly on the server — in-place upgrade
               preserves the existing configuration database; a fresh known-good
               backup of the SQL/LocalDB sync database is still recommended first
```

If the server is below `2.5.79.0`, nothing else in this list matters more than closing that gap before 30 Sep 2026 — every other check here is secondary to that one deadline.

</details>

---
## Diagnosis & Validation Flow

1. **Get the true running version**, not what Programs and Features shows. `(Get-Item "...\miiserver.exe").VersionInfo.ProductVersion` reflects the actual running binary; the installed-programs list reflects only the original install and can lag behind incremental service-side pushes.
2. **Compare against `2.5.79.0`.** Anything below this is on a hard countdown to 30 Sep 2026 — treat this as a P1/scheduling item regardless of how healthy sync looks today, since the failure mode is a full stop, not a degradation.
3. **If at or above the floor, check the per-version retirement table** (Common Fix Paths, Fix 2) — being past the mandatory floor does not mean the server is on a currently-supported version.
4. **Confirm auto-upgrade actually applies here.** A server that "should have" auto-upgraded but didn't is more often explained by a config-file modification skip or a download-only release than by a broken auto-upgrade pipeline.
5. **Before running the installer manually**, confirm `.NET Framework 4.7.2+` and `TLS 1.2` — a prerequisite failure mid-upgrade on a production sync server is a worse outage than doing the 30-second check first.
6. **After any upgrade, immediately verify sync actually resumes** — check `Get-Service ADSync` is `Running`, then trigger a delta sync (`Start-ADSyncSyncCycle -PolicyType Delta`) and confirm it completes without new errors before considering the upgrade closed out.

---
## Common Fix Paths

<details><summary>Fix 1 — Server is below the 2.5.79.0 mandatory floor (30 Sep 2026 hard deadline)</summary>

```powershell
# Confirm exactly how far behind, for prioritization/escalation context
$installedVersion  # from Triage step 1
[version]"2.5.79.0"  # the floor
```
This is not a routine "upgrade when convenient" item. Every synchronization service tenant-wide stops on 30 Sep 2026 for any server still below this version — there is no grace period documented, and no workaround other than upgrading. Download the current installer from the **Microsoft Entra Admin Center → Microsoft Entra Connect → Get started → Manage** tab (this is the only distribution channel — do not use an old bookmarked download-center link, which may serve a stale or unpublished build). Back up the sync database before upgrading if this server has any history of manual configuration changes (see Fix 4 for the specific known-bad pattern).

**Rollback:** Microsoft Entra Connect Sync upgrades are in-place and do not offer a built-in downgrade path — if an upgrade needs to be reversed, restore from a pre-upgrade VM snapshot or sync-database backup taken before running the installer.
</details>

<details><summary>Fix 2 — At/above 2.5.79.0 but past its own individual retirement date</summary>

```powershell
# Per-version End of Support table (from Microsoft's official version-history reference —
# re-check https://aka.ms/aadconnectrss periodically, this table shifts as new versions ship)
$eosTable = @{
  '2.5.3.0'    = '2026-07-31'
  '2.5.76.0'   = '2026-09-01'
  '2.5.79.0'   = '2026-10-23'
  '2.5.190.0'  = '2027-02-02'
  '2.6.1.0'    = '2027-03-10'
  '2.6.3.0'    = '2027-07-07'
  '2.6.84.0'   = $null   # current release — no EOS scheduled yet
}
$eosTable[$installedVersion]
```
A retired (non-mandatory-floor) version doesn't necessarily stop working the way sub-2.5.79.0 does, but Microsoft explicitly states retired versions "might unexpectedly stop working," lose access to the latest security fixes, and may not receive full support if a ticket is opened. Treat any version with a past or near-term EOS date as a scheduled upgrade, distinct in urgency from the hard mandatory-floor deadline in Fix 1.

**Rollback:** none — this is an assessment step, not a change.
</details>

<details><summary>Fix 3 — Server shows version 2.6.79.0 (recalled)</summary>

Microsoft identified a post-release issue with 2.6.79.0 and withdrew the installer entirely — it is no longer available for download. If a server somehow shows this version (installed before the recall, or via an already-cached installer), uninstall it and install the current release (**2.6.84.0** as of this writing, always confirm the latest at the Admin Center) instead. Do not attempt to "fix forward" by patching on top of 2.6.79.0.

**Rollback:** uninstalling 2.6.79.0 and reinstalling the current version is itself the fix — there is no separate rollback needed beyond ensuring the sync database backup exists first, as with any upgrade.
</details>

<details><summary>Fix 4 — Sync fails post-upgrade with a `System.Diagnostics.DiagnosticSource` / `FileLoadException` error</summary>

```powershell
# Applies specifically to upgrades TO 2.5.190.0 or 2.6.1.0, where miiserver.exe.config
# was previously manually modified (most commonly: FIPS-mode Password Hash Sync guidance)

# 1. Navigate to the Bin folder
Set-Location "$env:ProgramFiles\Microsoft Azure AD Sync\Bin"

# 2. Back up the current config before editing
Copy-Item .\miiserver.exe.config ".\miiserver.exe.config.bak-$(Get-Date -Format yyyyMMdd)"

# 3. Open miiserver.exe.config and add this entry inside the <assemblyBinding> section:
#    <dependentAssembly>
#      <assemblyIdentity name="System.Diagnostics.DiagnosticSource" publicKeyToken="cc7b13ffcd2ddd51" culture="neutral" />
#      <bindingRedirect oldVersion="0.0.0.0-8.0.0.0" newVersion="8.0.0.0" />
#    </dependentAssembly>
notepad .\miiserver.exe.config

# 4. Restart the sync service
Restart-Service ADSync
```
Root cause: during upgrade, Microsoft Entra Connect detects that `miiserver.exe.config` has been manually modified and deliberately does **not** overwrite it (to avoid discarding customer changes) — but this also means a required dependency binding redirect never gets applied, breaking sync. This exact failure was the trigger for the 2.6.3.0 auto-upgrade skip behavior described in Fix 5.

**Rollback:** restore `miiserver.exe.config.bak-<date>` if the manual edit doesn't resolve the error, then escalate — a config file that's been modified for reasons beyond the documented FIPS/PHS scenario may need a different fix.
</details>

<details><summary>Fix 5 — Auto-upgrade never applied despite the server being online and healthy</summary>

```powershell
# Confirm whether this server's config has ever been manually modified — a file timestamp
# far newer than the install date is a strong signal, though not fully conclusive
(Get-Item "$env:ProgramFiles\Microsoft Azure AD Sync\Bin\miiserver.exe.config").LastWriteTime
(Get-Item "$env:ProgramFiles\Microsoft Azure AD Sync\Bin\miiserver.exe").VersionInfo.ProductVersion
```
As of version 2.6.3.0, auto-upgrade explicitly detects modifications to `miiserver.exe.config` and `miisclient.exe.config` and **skips automatic upgrade** on those servers by design — this is the fix for the Fix 4 failure mode, not a bug. If this server has customizations, plan for a manual upgrade instead and follow Fix 4's config-preservation steps proactively. Separately, not every released version is published for auto-upgrade at all — a "download only" release status on the version-history page means auto-upgrade was never going to apply regardless of server state.

**Rollback:** none — this is expected, intentional behavior once a config modification is confirmed; the action item is to schedule a manual upgrade, not to "fix" auto-upgrade.
</details>

<details><summary>Fix 6 — Prerequisite check fails (.NET Framework or TLS 1.2)</summary>

```powershell
# .NET Framework release key check (528040+ = 4.8, 461808+ = 4.7.2, see Microsoft's release-key table)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release

# TLS 1.2 registry enablement (both client and server halves)
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" -ErrorAction SilentlyContinue
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server" -ErrorAction SilentlyContinue
```
Install/upgrade .NET Framework 4.7.2 or later first if the release key is below `461808`. If TLS 1.2 registry keys are absent or explicitly disabled, enable them and reboot before re-attempting the installer — the upgrade wizard fails its own prerequisite gate rather than partially installing.

**Rollback:** none — these are read-only checks; enabling TLS 1.2/upgrading .NET are additive changes with no meaningful rollback need.
</details>

<details><summary>Fix 7 — Server is a staging-mode secondary, not the active primary</summary>

Upgrade the staging server first and confirm it comes back healthy in staging mode before touching the active primary — this validates the new version against this tenant's actual configuration without risking a production sync outage. Never promote a staging server to active during the upgrade window itself; treat the version upgrade and any staging/active promotion as two separate, sequential changes.

**Rollback:** if the staging server fails to come back healthy post-upgrade, it can be left in staging mode indefinitely without impacting production sync (the active primary is unaffected) while the failure is investigated.
</details>

---
## Escalation Evidence

```
Server hostname: ____________________
Installed version (miiserver.exe.VersionInfo.ProductVersion): ____________________
Installed version (Get-ADSyncGlobalSettingsParameter ServerConfigurationVersion): ____________________
Below 2.5.79.0 mandatory floor? (Y/N): ____________________
Current version's own End of Support date (from Fix 2 table): ____________________
.NET Framework release key: ____________________
TLS 1.2 enabled (Client/Server registry keys present): ____________________
Auto-upgrade expected but did not apply? (Y/N): ____________________
miiserver.exe.config last-modified timestamp vs. install date: ____________________
ADSync service status: ____________________
Error text from most recent failed sync cycle (if any): ____________________
Topology (single server / staging-mode pair / swing migration in progress): ____________________
```

---
## 🎓 Learning Pointers

- **This is a hard, tenant-wide failure deadline, not a routine deprecation notice.** 30 September 2026 is when every synchronization service on a sub-2.5.79.0 server stops — not degrades, stops — and Microsoft states explicitly there's no workaround besides upgrading. Flag any customer server below this version as a scheduling priority now, not "next maintenance window." [Microsoft Entra Connect: Version release history](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/reference-connect-version-history)
- **The mandatory floor and a version's own retirement date are two independent clocks.** A server can clear the 30 Sep 2026 deadline by sitting at exactly 2.5.79.0 and still be on a version that retires a few weeks later (23 Oct 2026, per the current table) — don't treat "cleared the mandatory floor" as "done," re-check the rolling 12-months-after-successor retirement policy separately.
- **The installer is Admin-Center-only now.** Old bookmarked download-center URLs for Entra Connect are not a reliable source going forward — always pull from **Microsoft Entra Admin Center → Microsoft Entra Connect → Get started → Manage**.
- **A modified `miiserver.exe.config` is a known, named failure trap** — most commonly from following older FIPS-mode Password Hash Sync guidance. As of 2.6.3.0, auto-upgrade deliberately skips these servers rather than risk the Fix 4 failure; a manual upgrade on one of these servers still needs the config fix applied by hand.
- **Auto-upgrade eligibility is per-release, not universal.** Some versions are published download-only. Don't assume a server "should have" auto-upgraded just because it's online and otherwise healthy — check both the release's own auto-upgrade status and the server's config-modification state before troubleshooting further.
- **Subscribe to the release-notification feed** (`https://aka.ms/aadconnectrss`) for any tenant with an on-prem Connect Sync server still in play — this is the fastest way to catch a future mandatory-upgrade cycle before it becomes a deadline-week fire drill.
