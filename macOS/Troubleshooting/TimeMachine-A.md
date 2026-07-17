# macOS Time Machine Backup Policy — Reference Runbook (Mode A: Deep Dive)
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

Covers **managed Time Machine backup configuration** for macOS devices via the `com.apple.MCX.TimeMachine` MDM payload, deployed through Microsoft Intune's Settings Catalog. This is a **configuration delivery** mechanism, not a backup monitoring or reporting system — a critical distinction that shapes almost every troubleshooting decision in this topic.

**Applies to:**
- Devices enrolled via Device Enrollment or Automated Device Enrollment (ADE) — the only enrollment methods this payload supports
- macOS devices where IT wants to standardize (not necessarily enforce completion of) local network or attached-disk backups

**Out of scope:** third-party backup solutions (Time Machine is Apple's only natively MDM-manageable backup mechanism), iCloud-based data protection (an entirely separate system with no relationship to this payload), and File Provider/OneDrive-based data protection strategies some organizations use instead of or alongside Time Machine.

**Explicit non-assumption:** unlike most Intune-managed macOS settings covered elsewhere in this repo, this payload has **no DDM equivalent, no compliance policy integration, and no Intune-side success/failure reporting**. Treat any expectation of portal-visible backup status as a documentation gap to set with stakeholders up front, not a troubleshooting target.

---
## How It Works

<details><summary>Full architecture — managed Time Machine configuration delivery</summary>

### The payload model

The Time Machine MDM payload (`com.apple.MCX.TimeMachine`) is a **legacy-style configuration profile payload** — it is delivered as part of a standard MDM configuration profile, not as a DDM declaration. Intune's Settings Catalog surfaces it under general macOS settings rather than under the "Declarative Device Management" category used by newer settings like Software Update enforcement (see `DDM-A.md` for that distinction). This matters operationally: troubleshooting a delivery failure for this payload uses the same `profiles -P` / managed-preferences inspection pattern as any classic configuration profile, not `mdmclient QueryDeclarations`.

```
Intune (Settings Catalog — macOS platform, Time Machine category)
    │
    ▼
Standard MDM configuration profile containing com.apple.MCX.TimeMachine payload
    │
    ▼
APNs push → mdmclient (device) → InstallProfile MDM command
    │
    ▼
Profile installed, payload written to
/Library/Managed Preferences/com.apple.TimeMachine.plist
    │
    ▼
macOS reads managed preferences on Time Machine UI load / backupd startup
    │
    ▼
tmutil / backupd operate against the configured destination
    │
    ▼
Backups run per Time Machine's own internal scheduling logic
(NOT observable or controllable from Intune beyond initial configuration)
```

### What the payload actually configures

| Setting | Effect | Enforcement strength |
|---|---|---|
| Backup location (`DestinationURL`) | Sets the target for backups — SMB/AFP network share or local/attached volume | Configures only; does not verify reachability or provision credentials |
| Back up all volumes | Includes non-startup mounted volumes in scope | Configures only |
| Back up system files and folders | Includes macOS system files (normally excluded by default Time Machine behavior) | Configures only |
| Enable automatic backups | Removes the need for the user to manually trigger backups | Configures scheduling behavior; does not guarantee execution (power/connectivity dependent) |
| Enable local snapshots | Allows local APFS snapshots when the network/external destination is unreachable (macOS 10.8+) | Configures only |
| Backup size limit | Caps total backup size in MB | Enforced by Time Machine itself once configured |
| Paths to skip | Excludes specific paths from all *future* backups | Forward-only — does not retroactively purge existing backup content |

### Why there's no completion signal

Apple's own documentation is explicit that "each device management service developer implements these settings differently" — the payload's job, by design, ends at delivering configuration to the device. Time Machine's actual backup execution is governed entirely by `backupd`, a system daemon with its own internal scheduling, power-state awareness, and destination-availability logic that predates MDM entirely and was never built with a management-service feedback channel in mind. This is architecturally different from, say, FileVault (which reports escrow status back through Intune) or Compliance policies (which have dedicated DDM status reporting) — Time Machine simply has no equivalent telemetry path.

</details>

---
## Dependency Stack

```
MDM enrollment via Device Enrollment or ADE
(payload unsupported on BYOD/user-approved enrollment)
        │
com.apple.MCX.TimeMachine profile delivered and installed
        │
Managed Preferences plist populated
(/Library/Managed Preferences/com.apple.TimeMachine.plist)
        │
Destination URL resolvable (DNS/network path to SMB/AFP host,
or local/attached volume physically present)
        │
Destination authentication satisfied
(payload does NOT provision credentials — separate dependency,
often the actual point of failure)
        │
Sufficient destination free space
(Time Machine's own internal management, no MDM-side enforcement)
        │
backupd scheduling conditions met
(power state, destination availability, elapsed time since last backup)
        │
Backup executes and completes
        │
Visible via tmutil listbackups / Time Machine UI
(NOT visible in Intune — no portal signal exists)
```

**The critical break point in most real-world tickets is "Destination authentication satisfied."** The payload delivers a URL; it does not deliver a way to authenticate to it. Any environment deploying this to a credentialed network share needs an explicit, separately-designed plan for credential provisioning — this is the single largest gap between "policy looks correctly assigned" in Intune and "backups are actually running" on the device.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| `profiles -P` shows no TimeMachine payload at all | Policy not assigned, device not in scope, or enrollment type unsupported (BYOD) | Confirm assignment + enrollment method |
| Payload present but Managed Preferences plist empty | Profile delivered but not yet fully processed, or malformed payload | Force sync, re-check after a few minutes |
| `tmutil destinationinfo` shows no destination | Destination URL unreachable or requires credentials the device lacks | Network reachability + Keychain credential check |
| Destination reachable but no backups ever run | Automatic backups disabled, or `backupd` scheduling conditions never met (e.g. laptop rarely on-network while charged) | Manual `tmutil startbackup --auto` to isolate |
| Backups run but excluded paths still present in older snapshots | Exclusions are forward-only, expected behavior | Confirm exclusion timing vs. affected snapshot dates |
| Time Machine UI shows a different destination than policy specifies | User-configured destination coexisting with managed one | `tmutil destinationinfo -A` to see all destinations |
| Backup destination fills up / oldest backups purged unexpectedly | Time Machine's own space-management thinning — not policy-controlled unless a size limit is set | Check "Backup size limit" setting and destination free space |
| Backups succeed on Wi-Fi-connected desktop Macs, fail on laptops | Power/connectivity scheduling gap inherent to `backupd`, not a policy fault | Set stakeholder expectations; consider local-snapshot fallback setting |
| Multiple devices report identical destination URL conflicts/contention | Shared destination not designed for concurrent multi-device backup (SMB share capacity/locking) | Review destination architecture, not device-side config |

---
## Validation Steps

**1. Confirm enrollment method supports this payload**
```bash
sudo profiles status -type enrollment
```
Good: Device Enrollment or ADE-based enrollment. Bad: BYOD/user-approved — payload will never be deliverable regardless of assignment.

**2. Confirm the profile delivered**
```bash
sudo profiles -P | grep -iB2 -A15 "TimeMachine"
```

**3. Confirm managed preferences populated**
```bash
sudo defaults read /Library/Managed\ Preferences/com.apple.TimeMachine.plist
```

**4. Confirm destination configuration and reachability**
```bash
tmutil destinationinfo -A
```
Good: destination(s) listed with resolvable `URL` and non-empty `ID`. Bad: empty output despite a delivered profile.

**5. Confirm network path independently of Time Machine (for network destinations)**
```bash
smbutil view //<destinationHost> 2>&1
```

**6. Confirm credential availability**
```bash
security find-internet-password -s <destinationHost> 2>&1
```
Bad: not found → destination will fail to mount for unattended/automatic backups.

**7. Check backup execution history**
```bash
tmutil listbackups 2>&1 | tail -20
tmutil status
```

**8. Check destination free space**
```bash
df -h /Volumes/<destinationMountPoint> 2>&1
```

---
## Troubleshooting Steps (by phase)

### Phase 1: Payload not delivering

1. Confirm enrollment method (Phase 1 gate — BYOD is a hard stop).
2. Confirm Intune assignment targets the correct device/group.
3. Force an MDM sync: **System Settings → Privacy & Security → Profiles → Refresh**, or `sudo mdmclient Poll`.
4. Re-check `profiles -P` after sync.

### Phase 2: Payload delivered, destination not configuring

1. Check Managed Preferences plist for populated keys.
2. If empty despite profile presence, capture the raw profile payload (`sudo profiles -P -o /tmp/profiles.plist`) for content inspection — a malformed `DestinationURL` value is the most common payload-level fault.
3. Re-push the policy from Intune (remove/reassign) if content inspection reveals a configuration error.

### Phase 3: Destination configured, not reachable

1. Test network path independently (`smbutil view`, `ping`, or physical presence for local/attached destinations).
2. Check credential availability in Keychain.
3. If credentials are the gap, determine your organization's credential-provisioning plan — this payload does not solve it, and there is no MDM-native answer beyond user self-service authentication via System Settings.

### Phase 4: Destination reachable, backups not executing

1. Confirm "Enable automatic backups" landed in managed preferences.
2. Force a manual backup to isolate scheduling vs. destination issues.
3. If manual works but automatic doesn't, investigate device usage patterns (power state, network presence) against `backupd`'s scheduling — this is often a device-usage-pattern finding, not a fixable fault.

### Phase 5: Backups executing but content/retention concerns

1. Confirm exclusion list content and timing relative to affected backup dates.
2. Check destination free space and Time Machine's own thinning/retention behavior.
3. For destination capacity planning across multiple devices sharing one destination, review architecture rather than individual device configuration.

---
## Remediation Playbooks

<details>
<summary>Playbook 1 — Standing up managed Time Machine for a device population with a credentialed network share</summary>

**Scenario:** Deploying this payload for the first time against an SMB share requiring authentication — the most common real-world gap identified in this topic.

1. Confirm the destination share is reachable from the target device network (test `smbutil view` from a representative device before broad rollout).
2. Decide your credential-provisioning approach up front — options include a guest-accessible share (simplest, weakest access control), a shared service-account credential pre-provisioned via a separate configuration mechanism, or accepting a one-time user self-service authentication step via System Settings.
3. Deploy the Settings Catalog Time Machine policy to a small pilot group.
4. Validate via `tmutil destinationinfo` and a forced manual backup (`sudo tmutil startbackup --auto`) on pilot devices before expanding assignment.
5. Document the "no completion visibility" limitation explicitly for stakeholders expecting Intune-reportable backup status — set expectations before, not after, rollout.

**Rollback:** Remove the policy assignment; `com.apple.MCX.TimeMachine`'s managed preferences are removed on profile removal, reverting devices to unmanaged (user-controlled) Time Machine configuration. Existing backup destination content on the share itself is unaffected either way.

</details>

<details>
<summary>Playbook 2 — Reconciling a coexisting user-configured destination</summary>

**Scenario:** Devices had user-configured Time Machine destinations before the managed policy was deployed, or a user has since added their own.

1. Run `tmutil destinationinfo -A` to enumerate all known destinations on affected devices.
2. Identify which destination ID corresponds to the managed one (matches the policy's `DestinationURL`) versus any user-added ones.
3. Decide organizational policy: coexistence is generally harmless (Time Machine can back up to multiple destinations), but if consolidation is required, remove the non-managed destination explicitly per device: `sudo tmutil removedestination <destinationID>`.
4. Communicate to affected users before removing a destination they configured themselves, particularly if it contains backup history they may need.

**Rollback:** Re-add the removed destination manually (`tmutil setdestination`) using the URL/ID captured before removal. Removing a destination reference does not delete existing backup data at that destination.

</details>

<details>
<summary>Playbook 3 — Setting realistic backup-assurance expectations (process playbook, not technical)</summary>

**Scenario:** Stakeholders expect Intune-reportable "backup completed" status equivalent to what exists for FileVault escrow or Compliance policies — this payload cannot provide it.

1. Document explicitly (this file, or an internal wiki) that Time Machine via MDM is configuration-delivery-only.
2. If backup assurance is a genuine business requirement (compliance, data-loss-prevention), evaluate: (a) an Intune Shell Script scheduled to periodically report `tmutil listbackups` freshness back via a custom compliance script or Log Analytics ingestion, or (b) a third-party backup solution with native MDM-integrated reporting.
3. If proceeding with Shell-Script-based reporting, see `Shell-Script-Failures-A.md` for the general Intune Shell Script delivery/reliability model before building on top of it.

**Rollback:** N/A — planning/expectation-setting playbook.

</details>

---
## Evidence Pack

```bash
# Run this on-device via macOS shell (remote session, Intune Shell Script, or SSH)
# Collects Time Machine configuration + execution evidence for escalation

OutputPath="/tmp/tm-evidence-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OutputPath"

sudo profiles status -type enrollment > "$OutputPath/enrollment_status.txt" 2>&1
sudo profiles -P > "$OutputPath/all_profiles.txt" 2>&1
sudo defaults read /Library/Managed\ Preferences/com.apple.TimeMachine.plist > "$OutputPath/managed_prefs.txt" 2>&1

tmutil destinationinfo -A > "$OutputPath/destinations.txt" 2>&1
tmutil status > "$OutputPath/tm_status.txt" 2>&1
tmutil listbackups > "$OutputPath/backup_history.txt" 2>&1

df -h > "$OutputPath/disk_space.txt" 2>&1

log show --predicate 'subsystem == "com.apple.TimeMachine"' --last 24h --info > "$OutputPath/tm_log_24h.txt" 2>&1

tar czf /tmp/tm-evidence.tar.gz -C /tmp "$(basename "$OutputPath")"
echo "Evidence pack: /tmp/tm-evidence.tar.gz"
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check enrollment method | `sudo profiles status -type enrollment` |
| List all profiles (find TimeMachine payload) | `sudo profiles -P \| grep -iB2 -A15 TimeMachine` |
| Read managed Time Machine preferences | `sudo defaults read /Library/Managed\ Preferences/com.apple.TimeMachine.plist` |
| List all known destinations | `tmutil destinationinfo -A` |
| Check current backup status | `tmutil status` |
| List backup history | `tmutil listbackups` |
| Force a manual backup | `sudo tmutil startbackup --auto` |
| Remove a stale/incorrect destination | `sudo tmutil removedestination <destinationID>` |
| Add a destination manually | `sudo tmutil setdestination <url>` |
| Test SMB share reachability | `smbutil view //<destinationHost>` |
| Check stored destination credentials | `security find-internet-password -s <destinationHost>` |
| Time Machine unified log | `log show --predicate 'subsystem == "com.apple.TimeMachine"' --last 4h --info` |

---
## 🎓 Learning Pointers

- **This is configuration delivery, not backup management.** The single most important mental model for this topic: Intune's role ends the moment the destination is configured on-device. Everything downstream — reachability, credentials, scheduling, completion — is Time Machine's own long-standing macOS subsystem behavior, entirely invisible to Intune. Don't build escalation processes around a portal signal that doesn't exist. See: [Apple — Time Machine device management payload settings](https://support.apple.com/guide/deployment/time-machine-payload-settings-dep1cddddk7/web)

- **Credentials are the recurring failure mode.** Because the payload only sets a `DestinationURL` and never provisions authentication, any credentialed destination needs its own separate design decision. This is analogous to (but distinct from) the Wi-Fi/802.1X "three-legged stool" problem covered in `WiFi-8021x-A.md` — a single MDM payload configuring a *reference* to something (a network destination, a certificate) without owning the full dependency chain required to actually use it.

- **Enrollment-method gates are easy to overlook.** This payload's supported enrollment methods (Device Enrollment, ADE) exclude BYOD/user-approved enrollment entirely — worth checking early in any "policy isn't applying" ticket, the same category of gate seen with Recovery Lock's supervision requirement, just enforced at a different layer.

- **Exclusions and retention are forward-only and destination-managed respectively.** Don't promise retroactive cleanup of already-backed-up excluded data, and don't expect MDM-side control over how Time Machine thins old backups at the destination — both are Time Machine's own long-standing behavior, unrelated to the managing MDM service.

- **If backup assurance genuinely matters, this payload alone won't satisfy it.** Any compliance or data-loss-prevention requirement that needs proof of completed backups requires supplementary tooling (custom compliance scripting, Log Analytics ingestion of `tmutil` output, or a third-party MDM-integrated backup product) — flag this gap to stakeholders during planning, not after an audit.
