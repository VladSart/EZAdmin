# macOS Managed Login Items — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "app login item still prompts / user can disable it / vanishes after logout" in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Managed Login Items is a macOS 13+ configuration profile (`com.apple.servicemanagement`) that
pre-approves specific apps' login items, launch agents, and launch daemons so they can't be disabled by
the user in System Settings. Almost every ticket in this topic is a **rule-matching problem**, not a
deployment problem — run these first, in this order:

```
# 1. Confirm the profile actually landed on the device
sudo profiles -P | grep -i -A5 "servicemanagement\|Login Items"
# Bad: nothing found → assignment/scope problem, check Intune before anything else

# 2. Confirm the macOS version — this payload is a hard floor at macOS 13 (Ventura)
sw_vers -productVersion
# Bad: below 13.0 → profile will not apply at all, and will NOT retroactively apply after an
#      in-place upgrade either — see Learning Pointers. Redeployment (Fix 5) is required post-upgrade.

# 3. Dump the current login/background item status, including which rules matched what
sudo sfltool dumpbtm
# Look for the target app/helper's bundle identifier or launchd Label in the output, and whether
# it shows as matched against a servicemanagement payload UUID or still pending user approval

# 4. Confirm what's actually in System Settings > General > Login Items on the device
# (requires screen access or remote assistance — no CLI equivalent for the UI view itself)
# Bad: the target item shows in the "unlocked"/removable section rather than under the
#      organization-managed section → Fix 1 (rule mismatch)
```

**Interpretation table:**

| Finding | Action |
|---|---|
| No servicemanagement profile shows on device at all | Assignment/scope problem — check Intune first |
| macOS below 13.0 | Payload cannot apply — informational only, escalate as an OS-upgrade requirement, not a config bug |
| Profile present, `sfltool dumpbtm` shows the item but not matched to a payload UUID | Fix 1 — rule (BundleIdentifier/TeamIdentifier/Label) doesn't match the actual installed item |
| Item still prompts the user for approval / user can still disable it | Fix 1 — same root cause, rule mismatch means the item falls back to standard unmanaged behavior |
| User reports a background app "asks permission to keep running" after quitting the app (macOS 26+) | Fix 2 — add the app via a Service Management profile rule to suppress this specific macOS 26 prompt |
| Profile was deployed to Monterey/earlier devices, still not managed after upgrading to Ventura+ | Fix 5 — payload does not retroactively apply post-upgrade, must trigger a fresh policy sync |
| Works for most helper items from an app, but one specific launch daemon isn't covered | Fix 3 — that daemon's `Label` differs from what the rule targets; rules match per-item, not per-app bundle alone |
| User keeps seeing "Managed items are being installed" repeatedly, more than once per day | Fix 4 — expected notification-throttling window is 24h; investigate whether multiple distinct apps/items are triggering separate first-time notifications rather than one item repeating |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Device on macOS 13 (Ventura) or later
   (hard floor — profile has no effect below this, and does not retroactively apply after
    an in-place OS upgrade without a fresh policy re-application)
        │
        ▼
Service Management (com.apple.servicemanagement) configuration profile delivered to device
   Payload Content = array of rule dictionaries, each specifying ONE rule type:
   BundleIdentifier (exact) | BundleIdentifierPrefix | TeamIdentifier (exact) |
   Label (exact, launchd .plist Label key) | LabelPrefix
        │
        ▼
macOS's Background Task Management framework (SMAppService-based) discovers a login item,
launch agent, or launch daemon being installed/registered by any app
        │
        ▼
Discovered item is compared against ALL profile rules — first match auto-approves it
   (item becomes "managed," moves to the organization-controlled section of
    System Settings > General > Login Items, user cannot disable it)
        │
        ▼
No match → item falls back to standard unmanaged behavior:
   user sees the normal "background item added" notification and CAN disable it manually
```

**Key concept:** the profile doesn't install anything itself — it only pre-approves items that some
other mechanism (the app's own installer, an MDM script deploying a LaunchDaemon, etc.) has already
registered with the OS. A "not managed" ticket is a rule-matching problem against an item that already
exists, not a missing-deployment problem for the underlying app.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the profile is present**
```bash
sudo profiles -P | grep -i -A5 "servicemanagement\|Login Items"
```

**Step 2 — Confirm macOS version meets the floor**
```bash
sw_vers -productVersion
```

**Step 3 — Dump the full login/background item state**
```bash
sudo sfltool dumpbtm
```
This is the single most useful diagnostic on this topic — it lists every registered login item,
launch agent, and launch daemon along with whether each is matched to a managed `servicemanagement`
payload UUID. Include this output verbatim when filing feedback with Apple or escalating.

**Step 4 — Identify the exact bundle identifier / Team ID / launchd Label of the item in question**
```bash
# Bundle ID of an app:
defaults read "/Applications/<AppName>.app/Contents/Info.plist" CFBundleIdentifier
# Team ID (code signing):
codesign -dv "/Applications/<AppName>.app" 2>&1 | grep "TeamIdentifier"
# launchd Label of a specific agent/daemon plist:
grep -A1 "<key>Label</key>" /Library/LaunchAgents/<file>.plist /Library/LaunchDaemons/<file>.plist 2>/dev/null
```

**Step 5 — Compare against the profile's configured rules**
```
Intune admin center → Devices → Configuration → <Service Management profile> → Configuration settings
```
Confirm at least one rule exactly matches (or correctly prefix-matches) the values from Step 4.

**Step 6 — Live-monitor as a real-time test**
```bash
log stream --debug --info --predicate "subsystem = 'com.apple.backgroundtaskmanagement' and category = 'mcx'"
```
Trigger the app/item installation (or a fresh login) in another session and watch for match/no-match
activity in real time.

---
## Common Fix Paths

<details><summary>Fix 1 — Rule doesn't match the actual item (most common root cause)</summary>

**Cause:** The profile's rule value (bundle ID, Team ID, or Label) doesn't exactly match what the
installed item actually presents — often because the app publisher changed a bundle ID/Label between
versions, or the rule was built against a guess rather than the item's real identifiers.

```
# 1. Get the item's real identifiers per Diagnosis Step 4 above
# 2. Compare exactly against the profile's rule — BundleIdentifier and TeamIdentifier rules require
#    an EXACT match; only *Prefix rule types do partial matching
# 3. Update the rule in Intune to the correct value:
Intune admin center → <Service Management profile> → Configuration settings → edit the rule
# 4. Re-sync the device
Intune admin center → device → Sync
# 5. Re-check with sfltool dumpbtm after sync completes
```

**Rollback:** N/A — editing a rule value is not destructive; the item simply falls back to unmanaged
behavior until the correct rule is in place.

</details>

<details><summary>Fix 2 — macOS 26+ "keep running in background" prompt after quitting the app</summary>

**Cause:** Starting with macOS 26, if an app's background tasks remain active after the user quits the
app, the user is shown an allow/not-allow prompt. This is a distinct, newer behavior from the standard
login-item approval notification and is specifically suppressed by matching the app via a Service
Management profile rule.

```
# 1. Confirm the app's BundleIdentifier, BundleIdentifierPrefix, or TeamIdentifier
# 2. Add (or confirm) a matching rule in the Service Management profile using one of those three
#    rule types specifically (Label/LabelPrefix rules do not suppress this particular prompt)
Intune admin center → <Service Management profile> → Configuration settings → add rule
# 3. Re-sync affected devices
```

**Rollback:** N/A — additive rule change.

</details>

<details><summary>Fix 3 — One specific launch daemon not covered while the rest of the app's items are</summary>

**Cause:** Rules match per-item, not per-app-bundle. An app can register multiple login items, launch
agents, and launch daemons under different Labels — a rule that matches the main app's BundleIdentifier
does not automatically cover a launch daemon with an unrelated Label unless a LabelPrefix or
TeamIdentifier rule was used to cover the whole family.

```
# 1. Get the specific daemon's Label per Diagnosis Step 4
# 2. Either add a dedicated Label/LabelPrefix rule for it, or replace narrow BundleIdentifier rules
#    with a broader TeamIdentifier rule if all the app's helper items share the same code-signing
#    Team ID (usually the most maintainable long-term fix for multi-component apps)
# 3. Re-sync affected devices
```

**Rollback:** N/A — additive rule change.

</details>

<details><summary>Fix 4 — Investigating repeated "Managed items are being installed" notifications</summary>

**Cause:** By design, the FIRST item match in a 24-hour window triggers a single user notification;
subsequent matches within that window are silent. Notifications repeating more often than once per day
usually means multiple genuinely distinct items (not the same one repeating) are triggering separate
first-time notifications, or the user is dismissing/snoozing in a way that resets the window.

```
# 1. Use sfltool dumpbtm and the log stream command from Diagnosis Steps 3 and 6 to identify EVERY
#    distinct item matching in the affected time window, not just the one the user reported
# 2. Confirm whether these are newly-registered items (e.g. a recent app update changed its bundle
#    structure) vs. a genuine framework bug — if a known-good, previously-matched item is generating
#    fresh notifications with no app update, this may warrant filing feedback with Apple (attach the
#    sfltool dumpbtm output)
```

**Rollback:** N/A — diagnostic only.

</details>

<details><summary>Fix 5 — Profile pre-deployed to a device before its macOS 13+ upgrade doesn't take effect</summary>

**Cause:** This payload has no retroactive effect. A device that received the profile while still on
macOS 12 or earlier, then later upgraded to Ventura or newer, does NOT automatically start managing
login items — Apple's documentation is explicit that pre-deploying to an earlier OS does not work once
the Mac upgrades.

```
# 1. Confirm current macOS version is 13.0+ (sw_vers -productVersion)
# 2. Force a fresh policy sync/check-in — this is usually sufficient to trigger correct application
#    post-upgrade, since the profile itself is unchanged, only its applicability
Intune admin center → device → Sync
# 3. If still not applying after a sync and a reboot, remove and reassign the profile to force a
#    completely fresh delivery rather than relying on the existing (pre-upgrade) profile state
```

**Rollback:** N/A — resync/reassignment is non-destructive.

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — macOS Managed Login Items Issue
=====================================
Device Name:                  [hostname]
Serial Number:                 [Intune → device → Hardware → Serial number]
macOS Version:                 [sw_vers -productVersion]
Target App/Item Name:          [app or helper name]
Bundle Identifier:             [defaults read .../Info.plist CFBundleIdentifier]
Team Identifier:               [codesign -dv output]
launchd Label (if applicable): [from plist]

Profile present on device (sudo profiles -P):         [Yes/No]
sfltool dumpbtm shows item matched to payload UUID:     [Yes/No — paste relevant excerpt]
Rule type(s) configured in Intune for this item:         [BundleIdentifier/Prefix/TeamIdentifier/Label/Prefix]
Rule value(s) configured:                                [value]
Item visible under System Settings > Login Items (managed vs. removable section): [managed/removable]

Steps already attempted:
[ ] Confirmed profile delivered to device
[ ] Confirmed macOS 13.0+ and, if recently upgraded, forced a re-sync
[ ] Confirmed exact bundle ID / Team ID / Label of the target item
[ ] Compared item identifiers against configured rule(s) for an exact/prefix match
[ ] Captured sfltool dumpbtm output
[ ] Live-monitored via log stream during a fresh trigger of the item
```

---
## 🎓 Learning Pointers

- **This payload pre-approves items, it doesn't install them.** The underlying login item, launch
  agent, or launch daemon must already be registered by some other mechanism (the app's own installer,
  a separate MDM script). A "not managed" ticket is a rule-matching problem, not a missing-deployment
  problem — always start with `sfltool dumpbtm`, not with re-deploying the app. [Manage login items and background tasks on Mac](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web)

- **Rules match per-item, not per-app.** A multi-component app (main app + helper + daemon) can need
  more than one rule, or a single well-chosen `TeamIdentifier` rule to cover the whole family at once —
  this is usually the more maintainable choice than enumerating every `BundleIdentifier` individually.

- **`sfltool dumpbtm` and `sfltool resetbtm` are the two commands to know for this entire topic.**
  `dumpbtm` is always safe and is the first diagnostic step; `resetbtm` is destructive to local login/
  background item state and Apple recommends a restart after using it — never run it as a first-line
  triage step, only as a deliberate reset action.

- **macOS 13 (Ventura) is a hard floor, and it is NOT retroactive.** Pre-deploying this profile to a
  device still running Monterey or earlier does nothing at deployment time, and critically, does not
  automatically activate once that same device is later upgraded to Ventura+ — plan for a re-sync (or
  profile reassignment) as an explicit step in any OS-upgrade rollout that depends on this policy.

- **macOS 26 introduced a related-but-distinct prompt** for apps whose background tasks keep running
  after the user quits the app — suppressing it requires a `BundleIdentifier`/`BundleIdentifierPrefix`/
  `TeamIdentifier` rule specifically (not `Label`), and it's easy to conflate this with the original
  login-item approval notification when triaging a "why is the user still seeing a permission popup"
  ticket. [Background task management example](https://support.apple.com/guide/deployment/background-task-management-example-dep91dff5936/web)
