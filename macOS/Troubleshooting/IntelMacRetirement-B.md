# Intel Mac Retirement (macOS 27 Golden Gate) — Hotfix Runbook (Mode B: Ops)
> Assess Intel Mac exposure and fix the immediate ticket in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

> **Timeline anchor:** macOS 27 "Golden Gate" (September 2026) is Apple Silicon-only — it does not install or run on any Intel Mac hardware at all. macOS 26 "Tahoe" (2025) was already the last major release for the four remaining supported Intel models (2019/early-2020 Mac Pro, iMac, and related), with roughly two years of security-only updates promised after that. Separately, macOS 27 is the LAST major release with full Rosetta 2 support for running Intel-compiled apps on Apple Silicon Macs — Rosetta 2 support largely ends in macOS 28 (fall 2027). These are two distinct cliffs: hardware retirement (Intel Macs stop getting new macOS entirely) and app-compatibility retirement (Intel-only apps stop running on Apple Silicon Macs), and a ticket may be about either one.

Run these first — results tell you which fix path to follow:

```bash
# 1. Is this device even an Intel Mac?
sysctl -n machdep.cpu.brand_string
# Contains "Intel" → Intel Mac. Contains "Apple" (M1/M2/M3/M4/etc.) → Apple Silicon, this
# runbook's hardware-retirement track does not apply — skip to app-compat checks only if relevant

# 2. What macOS version is currently installed?
sw_vers -productVersion
# macOS 26.x (Tahoe) on an Intel Mac = the last major OS this specific hardware will ever run;
# anything below 26 on Intel = still has at least one more upgrade available before the ceiling

# 3. Is this one of the four models that still got macOS 26 Tahoe, or already obsolete?
system_profiler SPHardwareDataType | grep "Model Identifier"
# Cross-reference the Model Identifier against Apple's published macOS 26 Tahoe compatibility
# list (2019 Mac Pro, 2019/2020 27-inch iMac, and related late-Intel models) — most Intel Macs
# older than these were already cut off from macOS 26 itself, one OS generation earlier

# 4. Is a specific app the actual complaint (Rosetta/compatibility), not the OS-upgrade ceiling?
system_profiler SPApplicationsDataType | grep -B5 "Kind: Intel"
# Lists Intel-only (non-universal) apps currently installed — these are the ones that will stop
# working outright once the device is on macOS 28 (Apple Silicon) or once Intel hardware simply
# can't take any further OS upgrade at all
```

**Interpretation table:**

| Finding | Action |
|---|---|
| Apple Silicon Mac (M-series) | Hardware-retirement track doesn't apply — only check Intel-only app compatibility if relevant (Fix 4) |
| Intel Mac on macOS 26 Tahoe, one of the 4 supported models | At its hardware ceiling — security updates only continue for ~2 years, no further feature OS ever | Plan hardware refresh (Fix 1) |
| Intel Mac below macOS 26, still eligible for at least one more OS bump | Not yet at the ceiling — upgrade path exists for now, but budget for refresh soon | Fix 2 |
| Intel Mac not on the supported-for-26 model list at all | Already obsolete for new macOS versions; likely stuck on macOS 15 or earlier already | Fix 1 (refresh), verify current security-update status |
| User/app team asks "will my Intel-only app still work?" | Depends entirely on target Mac's chip and macOS version — see Dependency Cascade | Fix 3 |
| MSP needs a fleet-wide count of at-risk Intel Macs | Not a single-device question | Fix 5 / companion script |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Two INDEPENDENT retirement tracks — do not conflate them:

TRACK 1 — Hardware retirement (Intel Mac stops getting new macOS at all)
  Mac has an Intel CPU (not Apple Silicon M-series)
        │
  Is it one of the 4 models macOS 26 Tahoe still supports?
     (2019 Mac Pro, 2019/2020 27" iMac, and closely related late-Intel models)
        │                                    │
       YES                                  NO
        │                                    │
  macOS 26 Tahoe = LAST          Already stuck on macOS 15 or
  major OS this hardware         earlier — refresh is overdue,
  will ever run                  not upcoming
        │
  ~2 years of SECURITY-ONLY updates promised after Tahoe
  (no new features, no macOS 27/28 — ever, on this hardware)
        │
  macOS 27 "Golden Gate" (Sept 2026) does not install on ANY Intel Mac —
  this is an Apple Silicon-only release, full stop, regardless of model

TRACK 2 — App-compatibility retirement (Intel-COMPILED apps on Apple Silicon Macs)
  App is Intel-only / not yet a Universal (Apple Silicon-native) build
        │
  Running on an Apple Silicon Mac via Rosetta 2 translation
        │
  macOS 27 "Golden Gate" — LAST major release with full Rosetta 2 support;
  no longer auto-installs Rosetta (first launch of an Intel app now
  prompts a brief on-demand Rosetta install)
        │
  macOS 28 (fall 2027) — Rosetta 2 support LARGELY ENDS; Apple retains
  only a narrow subset for older, unmaintained gaming titles
        │
  Any Intel-only app not rebuilt as Apple-Silicon-native by then
  STOPS WORKING on macOS 28 — independent of whether the Mac itself
  is old (Intel) or new (Apple Silicon); this is an app problem,
  not a hardware-age problem
```

**Key concepts:**
- **These are two different clocks.** An Intel Mac's hardware ceiling (Track 1) and an Intel-compiled app's Rosetta ceiling (Track 2) can each be hit independently — a brand-new Apple Silicon Mac can still lose a critical Intel-only LOB app on macOS 28, and an aging Intel Mac has already lost its OS-upgrade path regardless of what apps it runs.
- **"macOS 26 Tahoe supports my Intel Mac" is not permanent safety.** It's explicitly the *last* major OS those 4 models will ever get — the security-updates-only period is a wind-down, not steady-state support.
- **Rosetta 2 doesn't disappear all at once.** macOS 27 keeps full support but drops silent auto-install; macOS 28 is where most Intel-only apps actually break.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Identify chip architecture**
```bash
sysctl -n machdep.cpu.brand_string
```

**Step 2 — Identify current OS version and remaining upgrade headroom**
```bash
sw_vers -productVersion
```

**Step 3 — For Intel Macs, confirm the specific model against the macOS 26 Tahoe support list**
```bash
system_profiler SPHardwareDataType | grep "Model Identifier"
```
Only 2019 Mac Pro, 2019/2020 27-inch iMac, and closely related late-Intel models made the macOS 26 Tahoe cut — most other Intel Macs were already excluded one OS generation earlier and are further along the obsolescence curve than this runbook's "ceiling" framing implies.

**Step 4 — Inventory Intel-only (non-Universal) applications**
```bash
system_profiler SPApplicationsDataType | grep -B5 "Kind: Intel"
```
Flags apps that will stop working under macOS 28's Rosetta drawdown regardless of the Mac's own chip.

---

## Common Fix Paths

<details><summary>Fix 1 — Intel Mac at or past its hardware ceiling</summary>

**Cause:** Device is on macOS 26 Tahoe (or earlier, if not even Tahoe-eligible) with no further feature-OS upgrade path available on this hardware, ever.

**Remediation:**
1. Confirm current security-update status is current for the installed OS version (`softwareupdate -l`)
2. Escalate to procurement/asset-management for hardware refresh planning — treat this the same as any other end-of-support hardware conversation, not an emergency, but not indefinitely deferrable either
3. If immediate replacement isn't possible, ensure the device is scoped out of any Intune/MDM policy that assumes macOS 27+ availability (see the companion `macOS15MinimumVersion-A/B.md` runbooks for the separate, Intune-specific enrollment-floor angle)

**Rollback:** N/A — this is asset-lifecycle planning, not a reversible technical change.

</details>

<details><summary>Fix 2 — Intel Mac not yet at ceiling, refresh should be budgeted proactively</summary>

**Cause:** Device still has upgrade headroom today but is on a hard, dated retirement curve.

**Remediation:**
1. Add to the org's hardware-refresh roadmap with a target date tied to the ~2-year post-Tahoe security-update window, not "whenever it breaks"
2. Use the companion audit script to build a fleet-wide list rather than reacting device-by-device

**Rollback:** N/A.

</details>

<details><summary>Fix 3 — "Will my Intel-only app still work?" question</summary>

**Cause:** Ambiguous unless both the target Mac's chip AND target macOS version are known.

**Remediation — answer via this decision path:**
1. Is the app already Universal (Apple Silicon-native)? → Works everywhere, no action needed
2. Is the target Mac Intel? → Works as long as that specific Intel Mac keeps getting macOS updates at all (Track 1 applies, Track 2 is moot — Rosetta isn't needed on Intel hardware)
3. Is the target Mac Apple Silicon, and staying on macOS 27 or earlier? → Still works via Rosetta 2 (though no longer auto-installed — first launch prompts an install)
4. Is the target Mac Apple Silicon, moving to macOS 28+? → Will very likely stop working unless the vendor ships a Universal build before that upgrade — check with the vendor now, don't wait for the break

**Rollback:** N/A — this is a compatibility assessment, not a change.

</details>

<details><summary>Fix 4 — Intel-only LOB app confirmed broken after a macOS 28 upgrade (future-dated scenario)</summary>

**Cause:** macOS 28's Rosetta 2 drawdown removed translation support the app depended on.

**Remediation:**
1. Check for a Universal/Apple-Silicon-native update from the vendor first — this is by far the most common resolution
2. If no update exists and the app is business-critical, evaluate whether a dedicated Intel Mac (kept off macOS 28) can be retained specifically to run that app, understanding this extends, not eliminates, the eventual problem
3. Escalate to the business owner of that application for a replacement/migration decision — this is not a device-configuration problem to solve technically

**Rollback:** N/A.

</details>

<details><summary>Fix 5 — MSP needs fleet-wide Intel Mac / Intel-app exposure visibility</summary>

**Cause:** Individual-device triage doesn't scale to planning a client's hardware-refresh budget or a Rosetta-dependency risk assessment.

**Remediation:** Run `Get-IntelMacFleetAudit.ps1` (companion script; Graph-based, queries Intune-managed macOS device inventory for Intel-architecture devices and cross-references against the macOS 26 Tahoe supported-model list) across the tenant rather than checking devices one at a time.

**Rollback:** N/A — read-only audit.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Intel Mac / Rosetta Retirement Issue
=====================================
Device Name:              [hostname]
Chip:                      [Intel | Apple Silicon — machdep.cpu.brand_string output]
Model Identifier:          [system_profiler SPHardwareDataType output]
Current macOS version:     [sw_vers -productVersion]
On macOS 26 Tahoe supported-model list: [Yes/No/Unknown]
Track affected:            [Track 1 - Hardware ceiling | Track 2 - App/Rosetta compatibility | Both]
Affected application(s):   [name, Intel-only vs. Universal status]

Symptom description:
[what the user/admin reported]

Steps already attempted:
[ ] Confirmed chip architecture
[ ] Confirmed current macOS version and remaining upgrade headroom
[ ] Confirmed model against the macOS 26 Tahoe support list (if Intel)
[ ] Inventoried Intel-only applications on the device
[ ] Checked vendor for a Universal/Apple-Silicon-native app update
[ ] Determined whether this is a hardware-refresh or app-migration decision
```

---

## 🎓 Learning Pointers

- **Two independent clocks are running — don't collapse them into one conversation.** Hardware retirement (Intel Macs stop getting new macOS entirely, ending with macOS 26 Tahoe for the last 4 supported models) and app-compatibility retirement (Rosetta 2 largely ending in macOS 28, breaking Intel-only apps on Apple Silicon Macs) have different timelines and different remediation owners (asset management vs. application owner).

- **"Supported by macOS 26 Tahoe" is explicitly a sunset announcement, not a clean bill of health.** Apple's own ~2-year security-only-updates commitment after Tahoe is the tell — plan the hardware refresh now rather than waiting for the device to stop receiving any updates at all.

- **A brand-new Apple Silicon Mac is not immune to this topic.** If it runs a critical Intel-only LOB application, that application's Rosetta 2 dependency puts it on the same macOS 28 collision course as an old Intel Mac — check application architecture, not just device age, when scoping risk.

- **Rosetta 2's retirement is staged, not a single cutoff.** macOS 27 keeps full support (just drops silent auto-install), and macOS 28 is where most Intel-only apps actually break — this staging gives a real, usable window to get vendor updates or migration plans in place before the actual failure.

- **This is a fast-moving, recently-announced Apple platform timeline (confirmed at WWDC 2025, with macOS 27 Golden Gate shipping September 2026)** — cross-check current guidance via Apple's own developer/support documentation before making firm client-facing commitments, since exact dates for macOS 28 and any policy adjustments remain subject to change as of this writing. [macOS 27 Golden Gate Is the Last to Support Intel Apps via Rosetta 2 — MacRumors](https://www.macrumors.com/2026/06/10/macos-golden-gate-last-to-support-intel-apps/)

- **This topic is distinct from, but related to, this repo's `macOS15MinimumVersion-A/B.md`.** That topic covers Intune/Company Portal's own minimum-enrollment-version floor tied to the same macOS 27 release; this topic covers the underlying Apple-side hardware and app-compatibility retirement driving that floor. Check both when scoping a client's full macOS 27 exposure.
