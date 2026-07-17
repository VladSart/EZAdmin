# macOS Declarative Device Management (DDM) — Reference Runbook (Mode A: Deep Dive)
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

Covers the **Declarative Device Management (DDM) protocol itself** — the transport and processing layer Apple introduced as an extension to the MDM protocol, and which Microsoft Intune now uses (via the Settings Catalog "Declarative Device Management" category) to deliver an increasing share of macOS configuration, most notably Software Updates and Compliance evaluation.

This is deliberately **not** a duplicate of `SoftwareUpdates-A.md` — that file covers the Software Update *declaration's* own content and update-specific mechanics (ASLS, staging, deferral). This file covers the *channel* those declarations travel over: how declarations, activations, assets, and status reporting work as a general-purpose protocol, independent of what's being configured. A device with a completely healthy DDM channel can still fail a specific Software Update declaration for update-specific reasons — and conversely, a device that looks "stuck" on multiple, unrelated policy types (updates AND compliance AND a new Settings Catalog profile, all at once) is a strong signal the DDM channel itself, not any individual policy, is the actual fault.

**Applies to:**
- macOS 13 (Ventura) and later — hard protocol floor, no exceptions
- Devices enrolled in Intune (MDM-supervised strongly recommended; DDM functions on unsupervised enrollments but several declaration types Apple/Intune deliver via DDM require supervision independently of the DDM transport itself)
- Intune Settings Catalog profiles under the "Declarative Device Management" category — this is now the **only** configuration surface for DDM-based settings; there is no separate dedicated policy blade the way there is (for now) for other config types

**Out of scope:** the content-level mechanics of any individual declaration type (see `SoftwareUpdates-A.md`, `Compliance-Policies-A.md` for those), and legacy (non-DDM) MDM commands, which continue to exist for pre-Ventura devices and settings DDM hasn't yet absorbed.

---
## How It Works

<details><summary>Full architecture — the DDM protocol model</summary>

### Why DDM exists

Classic MDM is fundamentally a **request/response, poll-driven** protocol: the server pushes a command via APNs, the device wakes up, executes it, and reports the result — once. If the device is offline when the command fires, or the command's effect is transient (e.g. "install this update right now"), the server has limited visibility into ongoing state without repeatedly re-issuing queries.

DDM inverts this. The server describes **desired end-state** ("declarations") rather than issuing imperative commands, hands the device a set of declarations to hold onto, and the device becomes responsible for continuously evaluating and maintaining that state — including proactively telling the server when something changes, without being asked. This is the same conceptual shift as Kubernetes' declarative reconciliation model applied to endpoint management: the server's job shrinks to "declare what should be true," and the device's job is "make it true, and tell me if you can't."

### The four declaration types

Apple's DDM protocol defines declarations in four categories:

| Declaration type | Purpose | Example (as surfaced by Intune Settings Catalog) |
|---|---|---|
| **Configurations** | Settings applied to the device — the DDM equivalent of a configuration profile payload | Software Update enforcement, passcode requirements, many Settings Catalog items |
| **Assets** | Referenced data/files a Configuration or Activation depends on (certificates, credentials) | A certificate asset backing an authentication declaration |
| **Activations** | Conditions under which a Configuration becomes active — predicate-based | "Apply this Configuration only if X is true" |
| **Management** | Meta-declarations about the management relationship itself | Server capabilities, status item subscriptions |

A single Intune Settings Catalog policy in the DDM category can generate one or more of these declaration types under the hood — the admin never authors raw declarations directly, Intune's Graph backend translates the Settings Catalog UI into the underlying DDM JSON.

### The sync cycle

```
Intune (Graph API backend)
    │
    ▼
Compiles Settings Catalog "Declarative Device Management" settings
into Declaration Items (Configurations / Assets / Activations / Management)
    │
    ▼
APNs push → "DeclarativeManagement" MDM command
    │
    ▼
mdmclient (device) receives push
    │
    ▼
ddmd (Declarative Device Management daemon) fetches the current
Declarations List from the server (tokenized — DeclarationsToken)
    │
    ├── Compares against locally cached declarations
    ├── Fetches only new/changed declarations (delta sync via token)
    └── Applies each declaration locally
            │
            ▼
    Local evaluation loop (continuous, not one-shot):
    device re-evaluates Activation predicates and Configuration
    state on its own schedule and on relevant system events —
    NOT only when a push arrives
            │
            ▼
    Status Channel evaluates subscribed StatusItems
    (Management declaration defines which StatusItems the
    server cares about)
            │
            ▼
    Status report sent proactively to Intune the moment a
    subscribed value changes — no polling required
            │
            ▼
    Intune portal reflects near-real-time device state
```

### Why this matters for offline devices

Because declarations are cached and evaluated locally, a device that goes offline immediately after receiving a declaration continues to enforce it — a Software Update deadline, a passcode requirement, or a compliance-relevant setting keeps being evaluated without needing a live connection to Intune. This is a deliberate resilience property, not an accident: legacy MDM commands generally require round-trip connectivity to even begin.

### The false-error / downgrade-detection behavior

Because Configurations are evaluated against **actual current state**, not just "was the push delivered," a declaration whose target state is already satisfied — or, worse, whose target is now *behind* actual state (e.g. a Software Update declaration targeting a build the device has already surpassed) — reports as an **Error**, not Success or "not applicable." The device is correctly refusing to move backward, but the resulting status is easy to misread as a genuine failure. This is documented behavior from Intune's own community guidance, not a bug, and is one of the most common sources of false-positive "broken DDM" tickets.

</details>

---
## Dependency Stack

```
Apple DDM protocol support (macOS 13+ hard floor)
        │
MDM enrollment + supervision
        │
APNs push delivery (17.0.0.0/8, ports 443/5223)
        │
mdmclient — MDM command processing on-device
        │
ddmd — Declarative Device Management daemon
        │
Intune Graph API backend — compiles Settings Catalog DDM
category settings into Declaration Items
        │
Declarations List sync (tokenized delta sync)
        │
Local declaration cache + continuous evaluation loop
        │
Individual declaration content (Software Update / Compliance /
other Settings Catalog DDM-category settings — each has its
own sub-dependencies, e.g. Software Update also needs ASLS
and disk space; see that topic's own dependency stack)
        │
Status Channel — subscribed StatusItems
        │
Proactive status report → Intune portal reflects state
```

**Layering note:** everything above "Individual declaration content" is shared infrastructure — a fault there affects every DDM-delivered setting simultaneously. A fault below that line is scoped to one declaration type. This distinction is the single most useful triage signal: **is only one policy type affected, or several unrelated ones at once?**

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Multiple, unrelated DDM-delivered policy types all stuck/pending on one device | Shared DDM channel fault (APNs, ddmd, or sync itself) | `mdmclient QueryDeclarations` — compare count/types against Intune assignment |
| Only one specific policy type stuck, others updating fine | Declaration-specific fault, not a DDM channel fault | Check that declaration's own dedicated topic |
| Declaration shows "Error" but device state looks correct or ahead of target | False-error / downgrade-detection pattern | Compare actual device state to declaration's target value |
| `QueryDeclarations` empty entirely | Device never completed initial DDM sync, or is DDM-ineligible | `sw_vers` (< macOS 13 = ineligible) + supervision status |
| Declarations present but `QueryResponses` timestamps stale | Status Channel specifically stuck (declarations still land, status doesn't report back) | Restart managed client daemon, re-poll, re-check `QueryResponses` |
| `unsupported-declaration-type` in ddmd log | OS build predates the setting Intune is trying to deliver | Compare declaration's minimum-OS requirement to `sw_vers` |
| `asset-reference-error` in ddmd log | A Configuration references an Asset (e.g. certificate) that failed to deliver or resolve | Check the referenced certificate/asset profile's own assignment and status |
| Intune shows "Pending" indefinitely, device never receives push | APNs not reaching device | `nc -zv 17.57.145.132 443`, check APNS Token status in Intune device Hardware blade |
| DDM works fine on some devices in a group, not others | Partial OS-version fragmentation within the assigned group (some devices below macOS 13) | Fleet-wide `sw_vers` audit against the policy's assignment |
| Everything DDM was fine, broke after a macOS upgrade | Declaration compatibility shift, or stale legacy (non-DDM) policy now conflicting post-upgrade | Check for coexisting legacy MDM update policies targeting the same device |

---
## Validation Steps

**1. Confirm DDM eligibility**
```bash
sw_vers -productVersion
sudo profiles status -type enrollment
```
Good: macOS ≥ 13.0, `MDM enrollment: Yes (supervised)`. Bad: below 13.0 → DDM cannot function, full stop.

**2. Pull the device's current declarations**
```bash
sudo mdmclient QueryDeclarations 2>&1
```
Good: a list of Declaration Items with `Identifier`/`Type` fields matching what's assigned in Intune. Bad: empty, or fewer entries than expected.

**3. Pull the device's current status responses**
```bash
sudo mdmclient QueryResponses 2>&1
```
Good: recent timestamps (within the last check-in interval) for each subscribed StatusItem. Bad: stale timestamps while declarations otherwise look current.

**4. Force a sync cycle and watch it happen live**
```bash
sudo mdmclient Poll
log show --predicate 'subsystem == "com.apple.managedclient.ddm"' --last 2m --info 2>/dev/null
```
Good: log entries appear within seconds showing fetch/evaluate/report activity. Bad: silence → push isn't arriving.

**5. Check for declaration-level processing errors**
```bash
log show --predicate 'subsystem == "com.apple.managedclient.ddm"' --last 24h --info 2>/dev/null | grep -iE "error|reject|invalid|unsupported|asset-reference"
```

**6. Cross-reference Intune-side assignment**
In the Intune portal: Devices → Configuration → filter by category "Declarative Device Management" → open the policy → per-device status. Confirm the device is targeted (directly or via group) and not excluded.

**7. Check for coexisting legacy (non-DDM) policies on the same setting**
```bash
sudo profiles -P | grep -iE "softwareupdate|update"
```
A legacy MDM-based update policy and a DDM Settings Catalog policy both targeting the same device can produce conflicting or confusing status — Microsoft has deprecated the legacy path specifically to eliminate this overlap; if both exist, that's itself the finding.

---
## Troubleshooting Steps (by phase)

### Phase 1: Channel-level — declarations not arriving at all

1. Confirm eligibility (macOS 13+, supervised, enrolled) — if any fails, stop, this is not a DDM bug.
2. Confirm APNs reachability (`nc -zv 17.57.145.132 443`); check the device's APNS Token status in Intune's Hardware blade.
3. Force `sudo mdmclient Poll` and watch the ddmd log in real time.
4. If no log activity at all follows a poll, treat as an APNs/push delivery issue, not a DDM-specific one — the same push infrastructure every other MDM command relies on.
5. If log activity occurs but no new declarations appear, check the Intune-side assignment for scoping errors (wrong group, device excluded).

### Phase 2: Declarations arrive but don't apply correctly

1. Pull `QueryDeclarations` and identify the specific declaration by `Type`.
2. Check ddmd log for that declaration's identifier specifically — filter the grep by the declaration's `Identifier` string.
3. Determine whether the failure is content-specific (route to that setting's own topic) or protocol-level (`unsupported-declaration-type`, `asset-reference-error` — stay here).
4. For `asset-reference-error`: identify and validate the referenced Asset declaration (usually a certificate) independently.

### Phase 3: Declarations apply but status doesn't report back

1. `QueryResponses` — confirm which StatusItems are stale.
2. Restart the managed client daemon (`sudo launchctl kickstart -k system/com.apple.ManagedClient`, verify exact service label via `launchctl list | grep -i managedclient` since it can vary by OS build).
3. Re-poll and re-check `QueryResponses` freshness.
4. If still stale, escalate — a persistently broken status channel with otherwise-healthy declaration delivery is unusual enough to warrant an Apple/Microsoft support case rather than further local troubleshooting.

### Phase 4: Intune-side false positives

1. Compare declaration target value to actual device state directly on-device — don't trust the portal status alone.
2. If the device is ahead of/equal to target: document as a false error, retire the stale policy.
3. Check for coexisting legacy (non-DDM) policies producing overlapping or contradictory status for the same underlying setting.

---
## Remediation Playbooks

<details>
<summary>Playbook 1 — Fleet-wide DDM eligibility audit before rolling out a new DDM-only setting</summary>

**Scenario:** About to deploy a Settings Catalog policy that only exists under the DDM category (no legacy equivalent) — need to know how much of the fleet can actually receive it before assigning broadly.

1. Run `Scripts/Get-DDMStatusAudit.ps1` against the target assignment group.
2. Review the OS-version breakdown — any device below macOS 13 is a guaranteed non-recipient, not a delayed one.
3. Decide: exclude ineligible devices from the assignment (cleanest), or accept them as a known gap and plan their OS upgrade path separately.
4. Re-run the audit after the OS-upgrade wave to confirm eligibility improved before re-including those devices.

**Rollback:** N/A — planning/audit step, no policy changes made by the script itself.

</details>

<details>
<summary>Playbook 2 — Diagnosing a device stuck across multiple unrelated DDM policy types</summary>

**Scenario:** A single device shows "Pending" or "Error" on Software Update, Compliance, and an unrelated Settings Catalog profile simultaneously — the multi-policy-type pattern that signals a channel fault, not several coincidental content faults.

1. Confirm this really is multi-type, not one root policy with several visible effects.
2. Run through **Phase 1** in full.
3. If APNs/push is confirmed healthy but declarations still aren't landing, capture the evidence pack below and escalate to Microsoft support with the device's `QueryDeclarations` output attached — a channel-level DDM fault on an otherwise-healthy device is rare enough that L2/L3 local remediation options are limited beyond service restart.

**Rollback:** N/A — diagnostic escalation path.

</details>

<details>
<summary>Playbook 3 — Migrating off legacy (non-DDM) macOS update policies</summary>

**Scenario:** Environment still has devices on the legacy "Update policies for macOS" blade, which Microsoft has confirmed will lose support, ahead of it breaking unexpectedly on an OS upgrade.

1. Inventory devices/groups currently targeted by legacy update policies (Intune portal: Devices → Update policies for macOS).
2. Build the equivalent DDM (Settings Catalog → Declarative Device Management → Software Update) policy in parallel — do not delete the legacy policy yet.
3. Assign the new DDM policy to a pilot group first; confirm via `QueryDeclarations` that pilot devices receive it correctly.
4. Once confirmed, migrate the remaining assignment groups, then remove the legacy policy assignment (not necessarily the policy object itself, in case rollback is needed).
5. Re-run `Scripts/Get-DDMStatusAudit.ps1` post-migration to confirm fleet-wide receipt.

**Rollback:** Re-assign the legacy policy and remove the DDM policy's assignment if the pilot surfaces unexpected regressions. Keep both policy objects defined (unassigned rather than deleted) during the transition window.

</details>

---
## Evidence Pack

```bash
# Run this on-device via macOS shell (remote session, Intune Shell Script, or SSH)
# Collects DDM-channel evidence for escalation — protocol-level, not declaration-content-specific

OutputPath="/tmp/ddm-evidence-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OutputPath"

sw_vers > "$OutputPath/sw_vers.txt"
sudo profiles status -type enrollment > "$OutputPath/enrollment_status.txt" 2>&1
sudo mdmclient QueryDeclarations > "$OutputPath/declarations.txt" 2>&1
sudo mdmclient QueryResponses > "$OutputPath/responses.txt" 2>&1
sudo mdmclient QueryDeviceInformation > "$OutputPath/device_info.txt" 2>&1
sudo profiles -P > "$OutputPath/all_profiles.txt" 2>&1

log show --predicate 'subsystem == "com.apple.managedclient.ddm"' --last 24h --info > "$OutputPath/ddm_log_24h.txt" 2>&1

curl -s -o /dev/null -w "APNs feedback reachability: %{http_code}\n" https://api.push.apple.com > "$OutputPath/apns_check.txt" 2>&1

tar czf /tmp/ddm-evidence.tar.gz -C /tmp "$(basename "$OutputPath")"
echo "Evidence pack: /tmp/ddm-evidence.tar.gz"
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check OS eligibility | `sw_vers -productVersion` |
| Check supervision/enrollment | `sudo profiles status -type enrollment` |
| List current declarations | `sudo mdmclient QueryDeclarations` |
| List current status responses | `sudo mdmclient QueryResponses` |
| Force DDM/MDM sync | `sudo mdmclient Poll` |
| Device info query | `sudo mdmclient QueryDeviceInformation` |
| List all installed profiles | `sudo profiles -P` |
| DDM daemon log (live window) | `log show --predicate 'subsystem == "com.apple.managedclient.ddm"' --last 1h --info` |
| Filter DDM log for errors | add `\| grep -iE "error\|reject\|invalid\|unsupported"` |
| Restart managed client daemon | `sudo launchctl kickstart -k system/com.apple.ManagedClient` |
| Confirm managed client service label (varies by OS) | `launchctl list \| grep -i managedclient` |
| APNs port reachability | `nc -zv 17.57.145.132 443` |
| Check for legacy update policy profiles | `sudo profiles -P \| grep -iE "softwareupdate\|update"` |

---
## 🎓 Learning Pointers

- **DDM is Apple's move from imperative to declarative endpoint management** — the same architectural shift Kubernetes made for infrastructure. Understanding "the server declares desired state, the device reconciles toward it continuously" reframes almost every DDM troubleshooting question from "why didn't the command run" to "why isn't the device's evaluation matching the declared state." See: [Apple — Intro to declarative device management](https://support.apple.com/guide/deployment/intro-to-declarative-device-management-depb1bab77f8/web)

- **Four declaration types, one mental model.** Configurations (settings), Assets (referenced data), Activations (conditional predicates), Management (meta/status subscriptions) — when a declaration fails, identifying which of the four types it is narrows the failure mode immediately (an Asset failure is almost always a certificate/credential problem, not a settings problem). See: [Apple — Declarative status reports](https://support.apple.com/guide/deployment/declarative-status-reports-depd90ee8a5f/web)

- **The legacy-to-DDM migration is not optional and not distant.** Microsoft has published an explicit deprecation notice for MDM-based macOS update policies, and Apple has already deprecated the underlying legacy MDM update workload those policies depend on. Community reporting (unverified against an official Microsoft date at time of writing, treat as directional) associates the hard cutover with the next annual macOS release cycle. Build the migration into planning now rather than reactively. See: [Microsoft Learn — deprecated-mdm-policies-macos](https://learn.microsoft.com/en-us/intune/device-updates/apple/deprecated-mdm-policies-macos) (updated 2026-06-22); [Intune Customer Success — Move to DDM for Apple software updates](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-move-to-declarative-device-management-for-apple-software-updates/4432177)

- **Everything under the "Declarative Device Management" Settings Catalog category shares one transport.** When troubleshooting what looks like an isolated policy failure, always check whether other DDM-category policies are also affected on the same device — that single check is the fastest way to distinguish a channel-level fault (escalate/restart daemon) from a content-level one (route to the specific setting's own topic).

- **Status is push, not pull — and that changes what "stale" means.** A DDM StatusItem that hasn't updated in days isn't necessarily broken; it may simply mean nothing about that item has changed. Don't force unnecessary re-syncs to "refresh" status that's accurately reflecting an unchanged state — reserve `mdmclient Poll` for genuine troubleshooting, not routine reassurance-checking.
