# macOS Time Machine Backup Policy — Hotfix Runbook (Mode B: Ops)
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

Managed Time Machine (deployed via the `com.apple.MCX.TimeMachine` MDM payload, configured in Intune under Settings Catalog) only **defines a destination and default options** — it does not force backups to actually run, and Intune has no built-in reporting for backup success/failure. Most "Time Machine isn't backing up" tickets are either a missing/unreachable destination or a user-facing misunderstanding of what the policy actually enforces.

```bash
# 1. Confirm the managed Time Machine profile is present on-device
sudo profiles -P | grep -iB2 -A15 "TimeMachine"

# 2. Check Time Machine's own destination and status
tmutil destinationinfo

# 3. Check current backup status/progress
tmutil status

# 4. Check backup history
tmutil listbackups 2>&1 | tail -20

# 5. Confirm the managed preference domain is actually populated
sudo defaults read /Library/Managed\ Preferences/com.apple.TimeMachine.plist 2>&1
```

| Result | Interpretation |
|---|---|
| `profiles -P` shows no TimeMachine payload | Policy never assigned, or MDM sync hasn't delivered it — check Intune assignment before anything else |
| `tmutil destinationinfo` returns "No destinations configured" despite the profile being present | Destination URL in the policy is unreachable, malformed, or requires credentials the device doesn't have — see Fix 1 |
| `tmutil status` shows `Running = 0` and no recent entries in `listbackups` | Automatic backups aren't triggering — check "Enable automatic backups" setting and power/lid-closed state |
| Managed Preferences plist is empty/missing but `profiles -P` shows the payload | Profile delivered but preference domain not yet written — force a sync, or a genuine payload malformation |
| Destination reachable, backups running, but excluded data still appears in destination | "Paths to skip" list misconfigured or not yet applied — see Fix 3 |
| User reports Time Machine UI shows a *different* destination than IT expects | A pre-existing user-configured destination coexists with the managed one — see Fix 4, the two are not automatically reconciled |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Device is MDM-enrolled (Time Machine payload: Device Enrollment or ADE only —
NOT available via user-approved/BYOD enrollment types)
        │
com.apple.MCX.TimeMachine payload delivered (Settings Catalog, macOS profile)
        │
Backup Location URL resolvable and reachable from the device's network
        │      (SMB/AFP share, or a locally/network-attached disk — the payload
        │       does not manage credentials for the share itself, see Fix 1)
        │
"Enable automatic backups" = true (if backups should run unattended)
        │
Sufficient free space at the destination (no MDM-side enforcement of this —
Time Machine's own capacity management applies)
        │
tmutil / backupd (Time Machine's backup daemon) executes on its normal schedule
        │
Backup completes → visible in `tmutil listbackups` and Time Machine UI
```

**The MDM payload's job ends at "destination is configured."** Everything below that line — actual share reachability, credentials, disk space, and whether `backupd` successfully completes a backup — is standard macOS Time Machine behavior with zero Intune-side visibility. There is no compliance policy setting or Intune report for "backup completed successfully." Plan escalations and evidence-gathering accordingly — this is a device-local investigation, not a portal one.

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the profile delivered**
```bash
sudo profiles -P | grep -iB2 -A15 "TimeMachine"
```
Expected: a profile entry referencing the Time Machine payload with your configured `Backup location`.
Bad: no match → policy not assigned to this device, or MDM sync hasn't landed yet — check Intune assignment and force a sync (`sudo mdmclient Poll` — see `DDM-B.md`/`SoftwareUpdates-B.md` if using DDM-delivered Settings Catalog delivery for this profile type).

**2. Confirm the managed preference domain**
```bash
sudo defaults read /Library/Managed\ Preferences/com.apple.TimeMachine.plist
```
Expected: keys matching your configured settings (`DestinationURL` or similar, `AutoBackup`, `SkipPaths`, etc — exact key names vary by macOS version, treat this as a presence/sanity check rather than a definitive schema reference).
Bad: empty or missing file despite a profile being present in step 1 → payload malformed or not yet fully processed.

**3. Confirm destination reachability**
```bash
tmutil destinationinfo
```
Expected: destination listed with a `Kind` and `URL` matching policy, `ID` populated.
Bad: "No destinations configured" → the device could not resolve/mount the destination. This is by far the most common real-world failure — see Fix 1.

**4. Check for an in-progress or recently completed backup**
```bash
tmutil status
tmutil listbackups 2>&1 | tail -10
```
Expected: `Running = 1` during an active backup, or recent timestamped entries in the backup list.
Bad: `Running = 0` and no recent backups → automatic backups aren't triggering.

**5. Check Time Machine's own logs for destination errors**
```bash
log show --predicate 'subsystem == "com.apple.TimeMachine"' --last 4h --info 2>/dev/null | grep -iE "error|fail|unreachable|denied" | tail -40
```

**6. Confirm network path to an SMB/AFP destination (if applicable)**
```bash
# Replace with your actual destination host
smbutil view //<destinationHost> 2>&1
```

---
## Common Fix Paths

<details>
<summary>Fix 1 — Destination unreachable or requires credentials the device doesn't have</summary>

**Scenario:** `tmutil destinationinfo` reports no destination despite a valid-looking profile.

The Time Machine MDM payload configures a **destination URL**, but does not manage authentication to that destination — if the target share requires a username/password and the device has never been granted (or has lost) credentials to it, the destination will never successfully mount for unattended backups.

```bash
# Confirm network reachability to the destination host/share independent of Time Machine
smbutil view //<destinationHost> 2>&1

# Check Keychain for stored destination credentials (user must be logged in for user keychain access)
security find-internet-password -s <destinationHost> 2>&1
```

If credentials are missing: this typically requires either (a) a passwordless/guest-accessible share, (b) pre-provisioning credentials via a separate mechanism (this payload does not do it), or (c) prompting the user to authenticate once via System Settings → General → Time Machine, after which credentials persist in their keychain.

**Rollback:** N/A — diagnostic. No destructive action; if credentials are added via System Settings, that is a user-side additive change, not a rollback-relevant one.

</details>

<details>
<summary>Fix 2 — Automatic backups not triggering despite reachable destination</summary>

**Scenario:** Destination is configured and reachable, but no backups have run.

```bash
# Confirm the automatic-backup setting actually landed
sudo defaults read /Library/Managed\ Preferences/com.apple.TimeMachine.plist 2>&1 | grep -i auto

# Force a manual backup to isolate whether it's a scheduling issue vs. a destination issue
sudo tmutil startbackup --auto
sleep 5
tmutil status
```

If a manual `startbackup` succeeds but automatic backups don't run on their own: check power settings — Time Machine automatic backups can be deferred on battery power or when the destination volume is asleep/disconnected on a schedule outside the device's normal usage pattern (e.g. a laptop that's rarely both powered and connected to the destination network simultaneously). This is expected Time Machine behavior, not a policy bug, and is worth setting user expectations around for laptop fleets backing up to on-prem network shares.

**Rollback:** N/A — `startbackup` is the intended user-facing action; nothing to roll back.

</details>

<details>
<summary>Fix 3 — Excluded paths still appearing in backup</summary>

**Scenario:** "Paths to skip" configured in the policy, but excluded data still shows up in the destination.

```bash
# Confirm the exclusion list actually landed in managed preferences
sudo defaults read /Library/Managed\ Preferences/com.apple.TimeMachine.plist 2>&1 | grep -A20 -i skip
```

Exclusions only apply to **backups taken after the exclusion was configured** — Time Machine does not retroactively purge already-backed-up data matching a newly added exclusion from prior snapshots. If old data needs to be removed from existing backups, that requires a separate, manual `tmutil` deletion pass against the destination, which is destructive and should not be done without explicit confirmation of what's being removed.

**Rollback:** N/A — this fix path is expectation-setting, not a technical change. If a destructive `tmutil delete` pass is genuinely needed, treat it as its own change with explicit sign-off, outside the scope of this quick-fix path.

</details>

<details>
<summary>Fix 4 — User has a pre-existing, different Time Machine destination configured</summary>

**Scenario:** Time Machine UI shows a destination that doesn't match what IT configured via MDM.

The MDM payload does not forcibly override or remove a destination the user configured themselves before (or independently of) the policy's delivery — the two can coexist confusingly, or the user-configured one may simply take visible precedence in the UI depending on when each was set.

```bash
# List all currently known destinations (not just the "current" one)
tmutil destinationinfo -A
```

If a stale/incorrect user-added destination needs to be removed so only the managed one remains:
```bash
# Identify the destination ID to remove from the -A output above, then:
sudo tmutil removedestination <destinationID>
```

**Rollback:** Re-add the removed destination manually via `tmutil setdestination` if this was done in error — capture the exact URL/ID from `destinationinfo -A` output *before* removing it.

</details>

---
## Escalation Evidence

```
Device name / serial:
Managed profile present (profiles -P grep TimeMachine, Y/N):
Managed Preferences plist populated (Y/N, key list if possible):
tmutil destinationinfo output:
tmutil status output:
Last successful backup timestamp (tmutil listbackups):
Destination type (SMB share / AFP / local disk) and host:
Network reachability confirmed to destination (Y/N):
Relevant Time Machine log errors (last 4h):
Time issue first observed:
Business impact (single device / fleet-wide):
```

---
## 🎓 Learning Pointers

- **The MDM payload configures a destination — it doesn't operate Time Machine.** There's no Intune compliance signal, no portal report, and no enforcement mechanism for "did this device actually complete a backup." If backup assurance matters for your environment, budget for either a third-party MDM-reportable backup solution or an Intune Shell Script that runs `tmutil listbackups` and reports staleness — the built-in payload alone gives you configuration delivery, not verification. See: [Apple — Time Machine device management payload settings](https://support.apple.com/guide/deployment/time-machine-payload-settings-dep1cddddk7/web)

- **Credentials are the device's problem, not the payload's.** `com.apple.MCX.TimeMachine` sets the destination URL; it does not provision, store, or manage authentication to that destination. Any credentialed share needs a separate plan for how devices obtain and retain those credentials — this is the single most common real-world gap between "policy looks correctly configured" and "backups actually run."

- **Enrollment-method gate, easy to miss.** The Time Machine payload's supported enrollment methods are Device Enrollment and Automated Device Enrollment only — a BYOD/user-approved-enrolled Mac cannot receive this payload at all, the same category of enrollment-type gate seen elsewhere in this repo (compare to Recovery Lock's supervision requirement). Confirm enrollment type before troubleshooting delivery.

- **Exclusions are forward-only.** "Paths to skip" only affects future backups. Don't assume adding an exclusion retroactively shrinks or cleans existing backup destinations — that requires a separate, deliberate, destructive action.

- **Duplicates are explicitly disallowed, and that's a design signal.** Apple's payload spec states only one Time Machine payload can be delivered to a device — if you need different backup destinations for different device groups, that has to be modeled as separate, non-overlapping assignment scopes for a single policy (or genuinely distinct policies targeting mutually exclusive groups), not layered profiles.
