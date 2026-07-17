# macOS Managed Login Items — Reference Runbook (Mode A: Deep Dive)
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
- The `com.apple.servicemanagement` configuration profile ("Managed Login Items" / "Service
  Management" payload) that pre-approves login items, launch agents, and launch daemons on macOS 13+
- The `SMAppService`-based Background Task Management framework underneath it, and how it replaced the
  pre-Ventura helper-executable install pattern
- The five rule types (`BundleIdentifier`, `BundleIdentifierPrefix`, `TeamIdentifier`, `Label`,
  `LabelPrefix`) and their exact-match vs. prefix-match semantics
- User notification behavior, including the 24-hour throttling window and macOS 26's additional
  background-task-continuation prompt
- Diagnostic tooling: `sfltool dumpbtm`/`resetbtm`, Console/`log stream` filtering, and the
  `attributions.plist` reference file

**Does not cover:**
- The legacy pre-Ventura pattern of installer scripts manually placing `.plist` files into
  `/Library/LaunchAgents` or `/Library/LaunchDaemons` — this runbook covers how the OS *discovers and
  manages* those items once registered, not how to author a launchd job itself
- The **Login Window** payload (a separate Apple configuration profile controlling the macOS login
  screen itself — different purpose despite the similar name)
- The **Restrictions** payload's blanket "allow/disallow adding login items" toggle, which is a coarser,
  separate control from this payload's per-item rule-based management — see Learning Pointers for how
  the two interact
- Privacy Preferences Policy Control (PPPC/TCC) grants for what a login item is *allowed to do* once
  running — see `PPPC-A.md`/`PPPC-B.md` for that, a related but architecturally separate permission
  system
- The Declarative Device Management (DDM) variant of background task management configuration
  (`Background task management declarative`, macOS 14+) — this runbook covers the classic XML
  configuration-profile version; see `DDM-A.md` for the general declarative transport this newer
  variant rides on

**Assumptions:**
- Devices are Intune-enrolled, MDM profile delivery is otherwise healthy (not separately diagnosed here
  — see `Intune/Troubleshooting/` for general profile delivery issues)
- The organization is trying to LOCK ON specific corporate/security-relevant login items (EDR agents,
  VPN clients, backup software) so end users cannot disable them — the inverse use case (blocking
  unwanted login items outright) is the Restrictions payload's job, not this one

---
## How It Works

<details><summary>Full architecture — from helper-executable chaos to a managed, observable framework</summary>

### The pre-Ventura problem this framework solves

Before macOS 13, an app that wanted a helper process to launch at login, or a background daemon to run
persistently, typically shipped an installer script that manually copied a `.plist` file into
`/Library/LaunchAgents` (user-context) or `/Library/LaunchDaemons` (system-context), then called
`launchctl load`. This worked, but had no unified visibility for either the end user or an
administrator: there was no single place in System Settings to see "what's launching automatically on
this Mac," and no OS-level way to distinguish an organization-sanctioned agent from an arbitrary
third-party or malicious one.

### SMAppService and the new bundle structure

Starting with macOS 13, Apple introduced the `SMAppService` framework (part of the ServiceManagement
private/public framework family) and, alongside it, a new app-bundle structure that simplifies how
helper executables and their associated `.plist` files are installed — updating the mechanism used by
earlier macOS versions rather than replacing it outright. Apps built against this newer structure
register their login items, launch agents, and launch daemons through `SMAppService` APIs, which the OS
tracks centrally. This is what makes the items visible under **System Settings > General > Login
Items** for the first time — a unified, user-facing inventory that didn't meaningfully exist before.

### What the Managed Login Items profile actually does

The profile does not install, register, or create any login item, launch agent, or launch daemon
itself. Its entire function is to **pre-approve** items that the OS has already discovered through
normal registration (whether via the new `SMAppService` path or a legacy-style install script — the
framework's discovery mechanism isn't limited to only newly-built apps). The profile's `Payload
Content` is an array of dictionaries, each specifying exactly one rule. When the framework discovers a
new item, it's compared against every rule in every applicable profile; the first rule that matches
auto-approves the item, moving it into the organization-managed section of Login Items where the end
user cannot disable it. No match means the item falls back to the normal end-user consent flow — a
notification, and the ability to disable it manually at any time.

### The five rule types and their match semantics

| Rule Type | Match Type | Matches Against |
|---|---|---|
| `BundleIdentifier` | Exact | The app's `CFBundleIdentifier` |
| `BundleIdentifierPrefix` | Prefix | The start of the app's `CFBundleIdentifier` |
| `TeamIdentifier` | Exact | The code-signing Team Identifier (covers every item signed by that developer team, regardless of individual bundle ID or Label) |
| `Label` | Exact | The launchd `.plist` file's `Label` key |
| `LabelPrefix` | Prefix | The start of the launchd `.plist` file's `Label` key |

`TeamIdentifier` is frequently the most maintainable rule for multi-component commercial software
(main app + helper + one or more daemons, all signed by the same developer) since it covers the whole
family without needing to individually enumerate every bundle ID and Label the vendor ships or later
adds in an update.

### Notification behavior and the 24-hour throttling window

The end-user experience is deliberately minimal by design: the FIRST item that matches a rule during an
installation event surfaces a single system notification informing the user that "managed items are
being installed" and can be reviewed in System Settings. Any additional items matching a rule within
the same 24-hour window produce **no further notifications** — the intent is to avoid notification
fatigue during, for example, a bulk software deployment that registers several managed helper processes
in quick succession. If the user actively closes the notification, a subsequent match will notify
again; if the user "Snoozes" it (for a selectable 1-day or 1-week window), notifications are suppressed
for that entire snoozed period regardless of how many new items match in the meantime.

### macOS 26: a second, related prompt for background task continuation

Starting with macOS 26, a functionally distinct behavior was introduced: if an app's background tasks
remain active after the user quits the app itself, the user is shown an allow/not-allow prompt asking
whether those tasks should be allowed to keep running. This is NOT the same notification as the
original login-item approval flow, and is suppressed independently — specifically by matching the app
via a `BundleIdentifier`, `BundleIdentifierPrefix`, or `TeamIdentifier` rule (not `Label`/`LabelPrefix`,
since this particular prompt is scoped at the app level, not the individual launchd job level).

</details>

---
## Dependency Stack

```
macOS 13 (Ventura) or later on the device
   (hard floor; NOT retroactive to devices later upgraded from an earlier OS without a fresh
    policy re-application)
        │
SMAppService-based Background Task Management framework (built into the OS)
   discovers login items / launch agents / launch daemons as they're registered by any app,
   regardless of whether that app uses the new bundle structure or a legacy install script
        │
Service Management (com.apple.servicemanagement) configuration profile delivered via MDM
   Payload Content = array of rule dictionaries (BundleIdentifier / BundleIdentifierPrefix /
   TeamIdentifier / Label / LabelPrefix)
        │
Rule evaluation against each newly-discovered item — first match wins, auto-approves
        │
Managed item moves to the organization-controlled section of
System Settings > General > Login Items — end user cannot disable it
   (unmatched items fall back to standard consent flow: notified, user-removable)
        │
(macOS 26+) Separate background-task-continuation prompt suppressed independently via
BundleIdentifier/BundleIdentifierPrefix/TeamIdentifier rule match at the app level
```

The profile is entirely reactive — it has no effect on anything that hasn't already been (or isn't
about to be) registered with the OS by some other install mechanism. This is the most common source of
"the policy isn't working" tickets that are actually rule-matching gaps, not delivery failures.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No effect at all, item still shows normal consent prompt | Rule doesn't match the item's actual BundleIdentifier/TeamIdentifier/Label | `sfltool dumpbtm`, compare against configured rules |
| Worked before an OS upgrade, still not working after | Payload does not retroactively apply post-upgrade | `sw_vers`, force a re-sync |
| Works for the main app but not a specific helper/daemon | Rules match per-item; the daemon's Label differs from the matched app's identifiers | `grep Label` on the specific `.plist`, compare against rule scope |
| User still sees an allow/not-allow prompt after quitting the app (macOS 26+) | Missing app-level rule for the newer background-continuation prompt specifically | Confirm a BundleIdentifier/Prefix/TeamIdentifier rule exists (not just Label) |
| Repeated "managed items" notifications more than once/day | Multiple genuinely distinct new items matching, not the same item repeating — or a snooze/dismiss interaction resetting the window | `log stream` filtered on `backgroundtaskmanagement`/`mcx` during the event |
| Device below macOS 13 | Payload has no effect at all — expected, not a bug | `sw_vers -productVersion` |
| Managed item disappeared after a major app update | Vendor changed the BundleIdentifier/Team ID/Label between versions | Re-check identifiers post-update, update rule if changed |
| Profile appears delivered (`profiles -P`) but `sfltool dumpbtm` shows nothing relevant | Item hasn't actually been registered with the OS yet by the underlying app/install process | Confirm the app/daemon install itself succeeded independently of this profile |

---
## Validation Steps

**1. Confirm macOS version meets the floor**
```bash
sw_vers -productVersion
```
Expected: 13.0 or later.

**2. Confirm the profile is delivered**
```bash
sudo profiles -P | grep -i -A5 "servicemanagement\|Login Items"
```

**3. Dump full login/background item state**
```bash
sudo sfltool dumpbtm
```
Expected: the target item listed with a matched `servicemanagement` payload UUID.

**4. Confirm the item's real identifiers**
```bash
defaults read "/Applications/<AppName>.app/Contents/Info.plist" CFBundleIdentifier
codesign -dv "/Applications/<AppName>.app" 2>&1 | grep "TeamIdentifier"
grep -A1 "<key>Label</key>" /Library/LaunchAgents/<file>.plist /Library/LaunchDaemons/<file>.plist 2>/dev/null
```

**5. Compare against configured profile rules**
```
Intune → Devices → Configuration → <Service Management profile> → Configuration settings
```
Expected: at least one rule exactly (or correctly prefix-) matches the Step 4 output.

**6. Live-verify via the unified log during a real trigger**
```bash
log stream --debug --info --predicate "subsystem = 'com.apple.backgroundtaskmanagement' and category = 'mcx'"
```

---
## Troubleshooting Steps (by phase)

### Phase 1: Applicability
1. Confirm macOS 13.0+.
2. If the device was recently upgraded from an earlier macOS version, treat "not working" as expected
   until a fresh sync/reboot has occurred — this payload is explicitly non-retroactive.

### Phase 2: Delivery
1. Confirm the profile itself is present via `profiles -P`.
2. If absent, resolve as a standard Intune assignment/scope issue before assuming a rule problem.

### Phase 3: Discovery
1. Confirm the underlying item (login item, agent, or daemon) is actually registered with the OS at
   all, independent of this profile — `sfltool dumpbtm` lists ALL discovered items, matched or not.
2. If the item doesn't appear in `dumpbtm` output at all, the problem is upstream (the app/installer
   never registered it), not this profile.

### Phase 4: Rule matching
1. Extract the item's real BundleIdentifier, TeamIdentifier, and/or Label.
2. Compare exactly against configured rules — remember `BundleIdentifier` and `TeamIdentifier` require
   an EXACT match; only the `*Prefix` variants do partial matching.
3. Prefer `TeamIdentifier` rules for multi-component vendor software to reduce future drift risk when
   the vendor changes a bundle ID or Label in an update.

### Phase 5: macOS 26+ specific behavior
1. If the complaint is specifically about a "keep running in background" prompt rather than the
   original login-item approval notification, confirm a `BundleIdentifier`/`Prefix`/`TeamIdentifier`
   rule exists — `Label` rules do not suppress this particular prompt.

---
## Remediation Playbooks

<details>
<summary>Playbook 1 — Onboarding a new corporate security/agent tool with multiple helper components</summary>

**Scenario:** Deploying an EDR agent, backup client, or VPN client that installs a main app plus one or
more launch daemons, and all of them need to be locked-on (non-disableable) for end users.

```
1. Install the tool on a representative test device via the normal deployment mechanism (MDM script,
   PKG deployment, etc.) — this profile has nothing to pre-approve until something is registered
2. Run sfltool dumpbtm on the test device to enumerate every login item/agent/daemon the tool
   registered
3. For each, extract BundleIdentifier/TeamIdentifier/Label per Diagnosis Step 4
4. If all components share the same code-signing Team ID (common for commercial vendors), prefer a
   single TeamIdentifier rule over enumerating each BundleIdentifier/Label individually
5. Build the Service Management profile in Intune with the resulting rule(s)
6. Assign to a pilot group first, validate via sfltool dumpbtm that all expected items show as managed
7. Expand to full fleet once validated
```

**Rollback:** Removing the profile (or the specific rule) reverts affected items to standard,
user-removable behavior — not destructive, but end users regain the ability to disable the tool's
background components, which may itself be a security-relevant regression worth planning around.

</details>

<details>
<summary>Playbook 2 — Recovering managed status after a vendor changes bundle identifiers in an update</summary>

**Scenario:** A previously-managed corporate app's login item stops being auto-approved after the
vendor ships a major update.

```
1. Confirm the regression correlates with an app update (check app version history / update logs)
2. Re-extract the item's current BundleIdentifier/TeamIdentifier/Label per Diagnosis Step 4 on an
   updated device
3. Compare against the existing profile rule — if the vendor changed the BundleIdentifier or Label but
   kept the same code-signing TeamIdentifier, this is the scenario where migrating to a TeamIdentifier
   rule prevents recurrence on the NEXT vendor update too
4. Update the rule in Intune, re-sync affected devices
5. Confirm via sfltool dumpbtm
```

**Rollback:** N/A — rule value edit only.

</details>

<details>
<summary>Playbook 3 — Post-OS-upgrade re-activation for a fleet-wide macOS 13+ rollout</summary>

**Scenario:** A fleet is being upgraded from macOS 12 or earlier to Ventura or later, and this profile
was already assigned in anticipation but needs to actually take effect post-upgrade.

```
1. Confirm the profile is (and was) correctly assigned to the target group — no change needed to the
   assignment itself
2. As each device completes its OS upgrade to 13.0+, trigger (or wait for) a normal Intune check-in/
   sync — this is normally sufficient for the payload to become active without any profile change
3. Spot-check a sample of freshly-upgraded devices via sfltool dumpbtm to confirm managed status is
   actually being applied, rather than assuming it based on profile presence alone
4. If any device doesn't pick it up after a sync and reboot, remove and reassign the profile to that
   specific device to force a completely fresh delivery
```

**Rollback:** N/A — non-destructive verification/resync process.

</details>

---
## Evidence Pack

```bash
#!/bin/bash
# Run locally on the affected Mac (ideally as root via sudo) as part of an escalation package.
# Collects everything the Symptom -> Cause Map and Validation Steps above ask for in one pass.
# Read-only. Use Get-ManagedLoginItemsAudit.sh in Scripts/ for the full structured version with
# CSV export and pass/fail scoring.

echo "=== macOS Version ==="
sw_vers -productVersion

echo ""
echo "=== Service Management Profile Presence ==="
sudo profiles -P | grep -i -B1 -A5 "servicemanagement\|Login Items"

echo ""
echo "=== Full Login/Background Item Dump ==="
sudo sfltool dumpbtm

echo ""
echo "=== Recent Background Task Management Log Activity ==="
log show --predicate "subsystem = 'com.apple.backgroundtaskmanagement' and category = 'mcx'" --last 1h
```

---
## Command Cheat Sheet

| Task | Where |
|---|---|
| Confirm macOS version | `sw_vers -productVersion` |
| Confirm profile delivered | `sudo profiles -P \| grep -i -A5 "servicemanagement\|Login Items"` |
| Dump full login/background item state | `sudo sfltool dumpbtm` |
| Reset login/background item data (destructive, restart after) | `sudo sfltool resetbtm` |
| Get an app's BundleIdentifier | `defaults read "/Applications/<App>.app/Contents/Info.plist" CFBundleIdentifier` |
| Get an app's code-signing Team ID | `codesign -dv "/Applications/<App>.app" 2>&1 \| grep TeamIdentifier` |
| Get a launchd job's Label | `grep -A1 "<key>Label</key>" <path-to-plist>` |
| Live-monitor matching activity | `log stream --debug --info --predicate "subsystem = 'com.apple.backgroundtaskmanagement' and category = 'mcx'"` |
| Build/edit the profile in Intune | Intune → Devices → Configuration → macOS → Templates (or Settings Catalog) → Service Management |
| Common vendor-attribution reference file (on-device) | `/System/Library/PrivateFrameworks/BackgroundTaskManagement.framework/Versions/A/Resources/attributions.plist` |

---
## 🎓 Learning Pointers

- **This is a pre-approval mechanism, not an installation mechanism — always separate "is the item
  registered with the OS" from "is the item matched by a rule."** `sfltool dumpbtm` answers both
  questions in one command and should be the first diagnostic step for every ticket in this topic. [Manage login items and background tasks on Mac](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web)

- **`TeamIdentifier` rules age better than `BundleIdentifier`/`Label` rules for commercial vendor
  software.** Vendors routinely change bundle identifiers and launchd Labels between major versions
  without changing their code-signing Team ID — building rules around the Team ID where possible avoids
  a recurring "it stopped being managed after the last update" ticket pattern.

- **The 24-hour notification throttling window is a UX design choice, not a bug to route around.**
  Multiple genuinely new items matching within the same day correctly produce only one notification —
  don't mistake this for the profile silently failing to notify about items 2, 3, and 4.

- **macOS 13 (Ventura) is a hard floor and explicitly NOT retroactive across an OS upgrade.** This is
  one of the most commonly mis-modeled facts about this payload — plan a post-upgrade sync/verification
  step into any rollout timeline that depends on this policy activating on newly-upgraded devices.

- **macOS 26 added a second, independently-suppressed prompt for background task continuation after
  app quit.** Don't conflate a user's "why do I keep getting asked about this app running in the
  background" report with the original login-item notification — it needs its own
  `BundleIdentifier`/`TeamIdentifier` rule coverage, and `Label` rules won't suppress it. [Background task management example](https://support.apple.com/guide/deployment/background-task-management-example-dep91dff5936/web)

- **This payload and the Restrictions payload's login-item toggle solve opposite problems and can
  coexist.** Restrictions can globally block end users from ADDING new login items at all; Managed
  Login Items pre-approves and locks SPECIFIC items so they can't be removed. A device with both
  deployed is a common, intentional combination for locked-down fleets — don't treat the presence of
  both as a misconfiguration without checking whether that's the actual intent.
