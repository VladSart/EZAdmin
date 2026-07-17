# macOS Declarative Device Management (DDM) — Hotfix Runbook (Mode B: Ops)
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

DDM is the transport layer underneath Software Updates, Compliance, and (increasingly) every Settings Catalog macOS profile — this topic covers a **broken DDM channel itself**, not any one declaration's content. If the device is stuck on a specific software update, start in `SoftwareUpdates-B.md` instead; come here when the symptom is "nothing declarative is landing at all" or the Intune policy report itself looks wrong.

```bash
# 1. Confirm MDM enrollment + supervision (DDM requires both)
sudo profiles status -type enrollment

# 2. Confirm the device is DDM-eligible (macOS 13+)
sw_vers

# 3. Pull current declarations the device has actually received
sudo mdmclient QueryDeclarations 2>&1 | head -80

# 4. Force a DDM sync
sudo mdmclient Poll

# 5. Check the DDM daemon's own log for processing errors
log show --predicate 'subsystem == "com.apple.managedclient.ddm"' --last 1h --info 2>/dev/null | grep -iE "error|fail|reject" | tail -40
```

| Result | Interpretation |
|---|---|
| `profiles status` shows "not supervised" or no MDM enrollment | DDM will not function — this is an enrollment problem, not a DDM problem. Escalate to enrollment triage. |
| `sw_vers` shows macOS 12 or earlier | Device is DDM-**ineligible**. Declarations will never be delivered — Intune silently falls back to legacy MDM commands where they still exist, or the policy simply reports no status. Not a bug. |
| `QueryDeclarations` returns empty or only a subset of expected declaration types | Sync never completed, or a declaration was rejected server-side (scope/conflict) — never left Intune. |
| `QueryDeclarations` shows the declaration but Intune portal shows "Error" | Declaration was received and processed but the **device's actual state doesn't match** what was declared (see Common Fix Paths → the "false error" pattern). |
| `mdmclient Poll` returns immediately with no log activity | APNs push not reaching the device — check APNs connectivity (`nc -zv 17.57.145.132 443`), same dependency as every other MDM push. |
| DDM log shows `unsupported-declaration-type` or `asset-reference-error` | Malformed or unsupported declaration — usually a very new Settings Catalog setting the device's OS build doesn't understand yet. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Device is MDM-enrolled AND supervised
        │
Device OS ≥ macOS 13 (Ventura) — DDM protocol floor
        │
APNs push reaches device (17.0.0.0/8:443, 5223)
        │
mdmclient receives DeclarativeManagement push command
        │
ddmd (Declarative Device Management daemon) processes it
        │
Declaration fetched from Intune (Configurations / Assets / Activations / Management)
        │
Declaration applied on-device (may itself depend on other subsystems —
e.g. a SoftwareUpdate declaration also needs disk space, ASLS reachability)
        │
Status Channel evaluates subscribed StatusItems
        │
Status report sent back to Intune (proactive — not polled)
        │
Intune portal reflects device state
```

**The DDM channel is a prerequisite for the declaration's own content, not a substitute for it.** A perfectly healthy DDM channel will still report "Error" if the declaration's payload — e.g. a target OS version already superseded by what's installed — is logically impossible to satisfy. Don't assume a status error means the transport is broken; read the declaration content first.

</details>

---
## Diagnosis & Validation Flow

**1. Confirm DDM eligibility**
```bash
sw_vers
sudo profiles status -type enrollment
```
Expected: macOS 13.0+, `MDM enrollment: Yes (supervised)`. Below macOS 13 or unsupervised → DDM is architecturally unavailable on this device; stop here and document as ineligible, don't keep troubleshooting a channel that can't exist.

**2. Pull the full declarations list**
```bash
sudo mdmclient QueryDeclarations 2>&1
```
Expected: JSON/plist-style output listing each declaration by `Identifier` and `Type` (e.g. `com.apple.configuration.softwareupdate.enforcement.specific`). Compare identifiers against what's assigned to the device in Intune (Devices → Configuration → filter by Settings Catalog "Declarative Device Management" category).
Bad: fewer declarations present on-device than assigned in Intune → sync gap, go to Fix 1.

**3. Force a sync and watch it land**
```bash
sudo mdmclient Poll
sleep 5
log show --predicate 'subsystem == "com.apple.managedclient.ddm"' --last 2m --info 2>/dev/null | tail -60
```
Expected: log entries showing declaration fetch/processing activity within seconds of the poll.
Bad: no log activity at all → push isn't reaching the device (APNs), not a DDM-layer problem.

**4. Check for declaration processing errors**
```bash
log show --predicate 'subsystem == "com.apple.managedclient.ddm"' --last 4h --info 2>/dev/null | grep -iE "error|reject|invalid|unsupported"
```
Expected: no matches. Any match names the failing declaration type — cross-reference against Fix 3 or 4.

**5. Verify status is actually being reported back**
```bash
sudo mdmclient QueryResponses 2>&1 | head -60
```
Expected: recent timestamped status entries. A stale timestamp (hours/days old) while declarations continue to update means the **status channel** specifically is stuck, even though declarations are still being received — a narrower failure than a full DDM outage.

---
## Common Fix Paths

<details>
<summary>Fix 1 — Declaration assigned in Intune but never arrives on-device</summary>

**Scenario:** `QueryDeclarations` is missing a declaration that's assigned and targeted correctly in Intune.

```bash
# Force MDM poll
sudo mdmclient Poll

# Re-check
sudo mdmclient QueryDeclarations 2>&1 | grep -i "<expected-declaration-type>"

# If still missing, check for a stuck/queued MDM command backlog
sudo mdmclient QueryDeviceInformation 2>&1
```
On the Intune side: confirm the device is in the assigned group (not just the user), and check **Devices → Monitor → Installation status** or the profile's own per-device status blade for an explicit error before assuming it's a transport issue.

**Rollback:** N/A — read-only diagnostic and re-poll, no destructive action.

</details>

<details>
<summary>Fix 2 — Device below macOS 13, DDM permanently unavailable</summary>

**Scenario:** Device is a valid MDM enrollment but running macOS 12 or earlier.

There is no client-side fix. DDM is a protocol floor tied to the OS build, not a setting. Options:
1. Upgrade the device to macOS 13+ (may itself require the legacy, non-DDM update path — see `SoftwareUpdates-B.md`).
2. For anything DDM-only configured in Intune (e.g. newer Settings Catalog categories that no longer have a legacy equivalent), the setting simply will not apply to this device until it's upgraded — document this as a known gap rather than continuing to chase it.

**Rollback:** N/A — no change made; this is a scoping decision, not a fix.

</details>

<details>
<summary>Fix 3 — "Error" status on a declaration that's actually correct (false-error / downgrade-detection pattern)</summary>

**Scenario:** Intune shows a declaration (commonly a Software Update declaration) as "Error," but the device is actually already compliant or ahead of the target.

This is a known, documented behavior, not a bug: **a declaration that specifies an OS version older than what's already installed reports Error**, because the device interprets it as an attempted downgrade request it correctly refuses to honor.

```bash
# Confirm actual device OS version
sw_vers -productVersion

# Compare against the declaration's TargetOSVersion/TargetBuildVersion
sudo mdmclient QueryDeclarations 2>&1 | grep -A5 "softwareupdate"
```

If the installed version is equal to or newer than the target: the "Error" is cosmetic. Remove or retire the stale declaration/policy in Intune rather than troubleshooting the device.

**Rollback:** N/A — this fix path is Intune-side policy cleanup, not a device change.

</details>

<details>
<summary>Fix 4 — Unsupported or malformed declaration (new Settings Catalog setting, older OS build)</summary>

**Scenario:** DDM log shows `unsupported-declaration-type` or similar for a specific declaration.

```bash
log show --predicate 'subsystem == "com.apple.managedclient.ddm"' --last 24h --info 2>/dev/null | grep -B2 -A2 "unsupported\|invalid"
```

Cross-check the declaration's minimum OS requirement (Apple's Settings Catalog reference notes minimum OS per setting) against `sw_vers`. If the device's OS build predates the setting's introduction, this is expected — either exclude the device from that policy's assignment or wait for the OS upgrade.

**Rollback:** N/A — diagnostic only. If misassigned, remove the device/group from the policy's assignment in Intune.

</details>

<details>
<summary>Fix 5 — Status channel stale while declarations still update (partial DDM failure)</summary>

**Scenario:** `QueryDeclarations` shows current data, but `QueryResponses` timestamps are stale and Intune's reported device state lags reality.

```bash
# Restart the managed client processes (safe — MDM framework, not user session)
sudo launchctl kickstart -k system/com.apple.ManagedClient 2>/dev/null || echo "service name may differ by OS version — check: sudo launchctl list | grep -i managedclient"

# Force a fresh poll after restart
sudo mdmclient Poll

# Re-check response freshness
sudo mdmclient QueryResponses 2>&1 | head -20
```

**Rollback:** Restarting the managed client daemon is non-destructive — it re-establishes its own state from Intune on next poll. No user data or configuration is lost.

</details>

---
## Escalation Evidence

```
Device name / serial:
macOS version (sw_vers):
Supervision status (profiles status -type enrollment):
Declarations present (mdmclient QueryDeclarations, redacted if needed):
Declarations expected (per Intune assignment):
Last successful status report timestamp (mdmclient QueryResponses):
DDM daemon log errors (last 4h, subsystem com.apple.managedclient.ddm):
APNs connectivity confirmed (Y/N):
Time issue first observed:
Business impact (single device / fleet-wide / specific policy type):
```

---
## 🎓 Learning Pointers

- **DDM is a transport, not a feature.** Software Updates, Compliance status, and a growing share of Settings Catalog macOS settings all ride on the same declarative channel. A "software update stuck" ticket and a "compliance not reporting" ticket can share the exact same root cause if both trace back to a broken DDM sync — check `mdmclient QueryDeclarations` before assuming they're unrelated. See: [Apple — Declarative device management](https://support.apple.com/guide/deployment/intro-to-declarative-device-management-depb1bab77f8/web)

- **The "Error means broken" assumption is wrong for DDM.** Because DDM declarations are evaluated logically against actual device state (not just "did the push succeed"), a device that's already ahead of a stale policy will show Error, not Success. Read the declaration content before troubleshooting the transport. See: [Declarative status reports for Apple devices](https://support.apple.com/guide/deployment/declarative-status-reports-depd90ee8a5f/web)

- **Legacy MDM update policies are being retired, not just deprecated.** Microsoft has confirmed it will end support for MDM-based (non-DDM) Apple software update policies, and Apple itself has deprecated the underlying MDM update workload the legacy policies relied on. Any environment still on the legacy "Update policies for macOS" blade needs a DDM migration plan now, not after the next macOS upgrade cycle breaks it. See: [Microsoft Learn — Manage macOS software updates using MDM-based policies (deprecation notice)](https://learn.microsoft.com/en-us/intune/device-updates/apple/deprecated-mdm-policies-macos), updated 2026-06-22; [Intune Customer Success blog — Move to declarative device management](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-move-to-declarative-device-management-for-apple-software-updates/4432177)

- **DDM has a hard OS floor.** macOS 13 (Ventura) minimum — there is no client-side workaround for devices below that. Build fleet-eligibility awareness into your rollout plans the same way you would for any hardware/OS-gated feature (compare to Recovery Lock's Apple Silicon gate).

- **Offline resilience is the point.** Once a declaration is delivered, the device evaluates and applies it locally without needing to phone home first — this is why DDM-managed devices behave more predictably on flaky networks than legacy poll-based MDM commands. Don't assume "device is offline" fully explains a DDM failure; check what was delivered before it went offline.
