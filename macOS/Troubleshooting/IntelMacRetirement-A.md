# Intel Mac Retirement (macOS 27 Golden Gate) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the two independent retirement timelines behind Apple's Intel-to-Apple-Silicon transition completion, not just what to click.

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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- The hardware-retirement timeline for Intel Macs (macOS 26 Tahoe as the last major OS for the 4 remaining supported Intel models; macOS 27 Golden Gate as Apple Silicon-only)
- The independent app-compatibility/Rosetta 2 retirement timeline (macOS 27 as the last full-support release, macOS 28 as the effective end of general-purpose Rosetta 2 translation)
- Fleet-planning implications for MSPs managing mixed Intel/Apple Silicon Mac estates via Intune
- Identifying at-risk devices and applications ahead of the transition, not remediating a specific broken application's code

**Out of scope:**
- Intune's own macOS minimum-enrollment-version policy mechanics (`macOS15MinimumVersion-A/B.md` covers that Intune-specific floor; this topic covers the underlying Apple OS/hardware retirement driving it)
- Application code migration/porting guidance for vendors rebuilding Intel-only apps as Universal binaries — this is an IT-operations/asset-planning runbook, not a developer migration guide
- Apple Silicon chip generation differences (M1 vs. M2 vs. M3 vs. M4) — not relevant to this topic; any Apple Silicon Mac is equally unaffected by the hardware-retirement track

**Assumptions:**
- Reader manages a mixed macOS fleet (Intel and Apple Silicon) via Intune, and needs to plan around both Apple's own hardware-support sunset and its software-compatibility sunset
- **Source-confidence note:** macOS 27 "Golden Gate" and macOS 28 are current-cycle Apple releases as of this writing (macOS 27 released September 2026; macOS 28 expected fall 2027 but not yet released). Facts here are corroborated across Apple's own WWDC 2025 "Platforms State of the Union" statement and multiple independent technology-press sources (MacRumors, AppleInsider, OSXDaily) rather than a single long-standing Apple support article, since this is recently-announced platform lifecycle information. Re-verify exact dates and the macOS 28 Rosetta 2 scope against Apple's current developer/support documentation before making firm client commitments — Apple's own language reserves some Rosetta 2 functionality indefinitely for "older, unmaintained gaming titles," which is a narrower carve-out than "Rosetta 2 is completely gone."

---

## How It Works

<details><summary>Full architecture</summary>

### Two Independent Retirement Tracks

This topic is frequently mis-scoped as a single "Intel Macs are going away" conversation. It is actually two architecturally separate retirement events that happen to be converging in the same rough timeframe because both are downstream of Apple's 2020-launched Apple Silicon transition reaching its final phase:

**Track 1 — Hardware retirement.** This is about which *physical Macs* can run which macOS version at all, independent of what software is installed on them.

**Track 2 — Software/app-compatibility retirement.** This is about which *compiled applications* (specifically, Intel-architecture-only binaries) can run on a given macOS version, independent of what physical Mac that macOS is running on — including on Apple Silicon Macs, via the Rosetta 2 translation layer.

A device or a ticket can be affected by either track alone, both simultaneously, or neither. Correctly triaging which track (or both) a given situation involves is the single most important diagnostic step in this topic.

### Track 1: The Hardware Retirement Timeline

```
macOS 26 "Tahoe" (2025 release)
   │
   Already narrowed hardware support to just 4 remaining Intel models:
   2019 Mac Pro, 2019/2020 27-inch iMac, and closely related late-Intel
   configurations — most Intel Macs older than this generation had
   already been excluded from macOS 26 one release earlier
   │
   Tahoe is the LAST major macOS these 4 models will ever receive
   │
   Apple has committed to approximately 2 years of SECURITY-ONLY
   updates for these devices after Tahoe — no new features, no
   further major-version upgrades, ever, on this hardware
   │
macOS 27 "Golden Gate" (September 2026)
   │
   Apple Silicon ONLY. Does not install, does not run, on any Intel
   Mac regardless of model or age. This is a hard architectural cutoff,
   not a compatibility-list exclusion the way prior "N-3 models
   dropped" transitions worked — no Intel Mac of any kind is eligible.
```

The practical consequence: an Intel Mac's maximum possible macOS version is now permanently fixed at whatever it can run today (macOS 26 Tahoe at best, for the 4 newest models; something older for everything else). There is no future OS-update path for Intel hardware, full stop.

### Track 2: The Rosetta 2 / App-Compatibility Retirement Timeline

Rosetta 2 is the dynamic binary-translation layer Apple introduced alongside the original Apple Silicon transition (2020) to let Intel-compiled ("x86_64") applications run on Apple Silicon ("arm64") Macs without a native rebuild. Apple's own WWDC 2025 "Platforms State of the Union" statement set the retirement timeline explicitly: *"Rosetta was designed to make the transition to Apple silicon easier, and we plan to make it available for the next two major macOS releases — through macOS 27 — as a general-purpose tool for Intel apps to help developers complete the migration of their apps."*

```
macOS 27 "Golden Gate" (September 2026)
   │
   LAST major release with full, general-purpose Rosetta 2 support
   │
   Behavior change even within this "full support" release: Rosetta 2
   is no longer pre-installed/auto-installed system-wide. The FIRST
   time a user launches an Intel-only app after upgrading, macOS
   prompts a brief on-demand Rosetta 2 installation before the app
   can open — a new friction point, not a removal of function
   │
macOS 28 (expected fall 2027)
   │
   General-purpose Rosetta 2 support LARGELY ENDS. Apple has stated
   it will retain a narrower subset of Rosetta functionality
   specifically to keep older, unmaintained GAME titles running —
   this is explicitly NOT a guarantee that ordinary Intel-only
   business/productivity applications will continue working
   │
   Any Intel-only app that hasn't shipped a Universal (Apple-Silicon-
   native) build by this point stops running on any Mac upgraded to
   macOS 28, REGARDLESS of whether that Mac itself is old (Intel,
   already excluded from 27/28 entirely) or brand-new (Apple Silicon)
```

The critical nuance: Track 2 affects Apple Silicon Macs, not Intel Macs. An Intel Mac never needs Rosetta 2 (it runs Intel binaries natively) — but an Intel Mac is separately barred from macOS 27/28 entirely by Track 1. So in practice, the Rosetta 2 cliff is specifically a risk to organizations running Intel-only legacy or niche line-of-business software on their *newer, Apple Silicon* fleet, which is a scenario many admins don't immediately think to check for.

### Why This Matters for Intune-Managed Fleets

Two distinct planning conversations fall out of this:

1. **Hardware refresh planning (Track 1):** Any Intel Mac still in the managed fleet has a hard, dated ceiling. This is a standard asset-lifecycle conversation, but the *dated* nature (Tahoe = last OS, ~2 years of security updates, then nothing) gives it real urgency that a vaguer "Macs eventually get old" framing doesn't convey.

2. **Application portfolio risk (Track 2):** Any Intel-only application in active use — regardless of what hardware it currently runs on — needs a Universal-build commitment from its vendor before an eventual macOS 28 upgrade, or a documented decision to hold affected devices back from that upgrade indefinitely (which itself becomes an increasingly untenable security posture over time, similar to any deferred-major-OS-upgrade situation).

Both conversations benefit from a proactive fleet inventory rather than reactive, per-ticket discovery — see the companion script and Remediation Playbooks below.

</details>

---

## Dependency Stack

```
TRACK 1 (Hardware)                          TRACK 2 (App/Rosetta compatibility)
─────────────────────                       ──────────────────────────────────
Mac chip = Intel                            App is Intel-only (not Universal)
      │                                            │
Model on macOS 26 Tahoe                     Mac chip = Apple Silicon
supported list?                                    │
      │  Yes         │  No                  Rosetta 2 installed/installable
      ▼              ▼                             │
macOS 26 Tahoe   Already stuck        macOS ≤ 27 → Rosetta 2 fully supported
= final OS       below 26,            (auto-install removed in 27 — first
      │          refresh overdue      launch triggers on-demand install)
~2yr security-                                      │
only updates                          macOS 28 → general-purpose Rosetta 2
      │                               support LARGELY ENDS (narrow carve-out
No macOS 27/28                        for old game titles only)
ever, on this                                       │
hardware — full                       App breaks UNLESS vendor ships a
architectural cutoff,                 Universal (Apple-Silicon-native)
not a compatibility list              build before the device upgrades
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Intel Mac can't upgrade past macOS 26 (or earlier) | Track 1 — hardware ceiling reached, this is permanent | `sw_vers`, `system_profiler SPHardwareDataType` model check |
| Intel Mac stopped receiving feature updates but still gets security patches | Expected — inside the ~2-year post-Tahoe security-only window | Confirm current patch level via `softwareupdate -l` |
| Intel-only app stops working after upgrading an Apple Silicon Mac to macOS 28 | Track 2 — Rosetta 2 support ended for general-purpose apps | Check app's architecture (`system_profiler SPApplicationsDataType`), check vendor for Universal build |
| Intel-only app prompts an unexpected install dialog on first launch after upgrading to macOS 27 | Expected — Rosetta 2 auto-install removed, on-demand install replaces it | Not a fault; confirm the install completes and the app runs normally afterward |
| Old game still runs fine on macOS 28, other Intel-only app doesn't | Expected — Apple's narrow Rosetta 2 carve-out is specifically for older unmaintained game titles, not general apps | Confirm via Apple's current documentation which categories remain covered |
| New Apple Silicon Mac purchase "should fix" an Intel-only app compatibility complaint | Partially true — fixes Track 1 concerns, does NOT fix Track 2 if the app itself stays Intel-only and the fleet later reaches macOS 28 | Clarify which track the original complaint was actually about |
| MSP client asks "how many of our Macs are affected" | Not answerable per-device — needs a fleet sweep | Run companion audit script |

---

## Validation Steps

**1. Confirm chip architecture:**
```bash
sysctl -n machdep.cpu.brand_string
```
Contains "Intel" → Track 1 applies (and Track 2 does not, since Intel Macs run Intel apps natively). Contains an Apple chip name (M1/M2/M3/M4/etc.) → Track 1 does not apply; Track 2 may, depending on installed apps.

**2. Confirm current macOS version and headroom:**
```bash
sw_vers -productVersion
```

**3. For Intel Macs, confirm exact model against the Tahoe-supported list:**
```bash
system_profiler SPHardwareDataType | grep "Model Identifier"
```
Cross-reference against Apple's current published macOS 26 Tahoe compatibility list — this list is authoritative and should be re-checked at time of use rather than hardcoded, since Apple's own published compatibility pages are the ground truth.

**4. Inventory Intel-only (non-Universal) applications, any chip:**
```bash
system_profiler SPApplicationsDataType | grep -B5 "Kind: Intel"
```
Expected "good": empty or only genuinely low-priority/legacy apps. Expected "needs attention": any business-critical app appearing here on a fleet that will eventually reach macOS 28.

**5. Confirm current patch currency for a device already at its Track 1 ceiling:**
```bash
softwareupdate -l
```
Expected during the security-only window: available security updates for the current major version, no available feature-version upgrade.

---

## Troubleshooting Steps (by phase)

### Phase 1: Track Identification

1. Determine chip architecture first — this immediately rules Track 1 in or out.
2. If Apple Silicon, inventory installed apps for Intel-only binaries to determine Track 2 exposure.
3. If Intel, confirm model against the Tahoe support list to determine remaining headroom (if any).

### Phase 2: Hardware-Ceiling Devices (Track 1)

1. Confirm the device is genuinely at its ceiling (not just behind on an available update it could still take).
2. Verify security-update currency for the installed OS version.
3. Route to hardware-refresh planning — this is not a technical remediation, it's an asset-lifecycle decision.

### Phase 3: App-Compatibility Exposure (Track 2)

1. Identify all Intel-only apps across the fleet, not just the one in the current ticket.
2. For each, check vendor roadmap/current release notes for a Universal build commitment.
3. For apps with no clear vendor path, flag as a migration-planning risk rather than a technical ticket to close.

### Phase 4: Fleet-Wide Planning

1. Run the companion audit script across the Intune-managed macOS estate.
2. Cross-reference the Intel-device list against the Track 1 model-eligibility check and the Track 2 app-inventory findings.
3. Produce two separate punch lists for the client/stakeholder: hardware refresh candidates, and application vendor follow-ups — conflating them into one list tends to under-prioritize the app-compatibility risk, since it's less visually obvious than "this Mac is old."

---

## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide Track 1 (hardware) risk assessment</summary>

```bash
# Run per-device or via the companion Graph-based script for the full Intune-managed fleet
sysctl -n machdep.cpu.brand_string
sw_vers -productVersion
system_profiler SPHardwareDataType | grep "Model Identifier"
```
Aggregate results into: Apple Silicon (no action), Intel-on-Tahoe-supported-model (plan refresh within the ~2-year security-only window), Intel-below-Tahoe-support (refresh overdue).

**Verify:** Cross-check the aggregated model list against Apple's current published compatibility page before finalizing a client-facing report — Apple's own page is authoritative and this playbook's snapshot may drift from it over time.

</details>

<details><summary>Playbook 2 — Fleet-wide Track 2 (app compatibility) risk assessment</summary>

```bash
system_profiler SPApplicationsDataType | grep -B5 "Kind: Intel"
```
Run across all Apple Silicon devices in the fleet (Intel devices are not exposed to this track). Compile a distinct application-level list (not device-level) since the same Intel-only app installed on many devices is one vendor-follow-up action, not many.

**Verify:** For each flagged app, confirm current vendor documentation/roadmap before escalating — some apps flagged as "Intel" by `system_profiler` may already have a pending Universal update not yet installed.

</details>

<details><summary>Playbook 3 — Client-facing timeline communication</summary>

Use when presenting findings to a client or stakeholder who needs to make budget/prioritization decisions.

Structure the communication around the two tracks explicitly, with their own dates:
- Track 1: "These N devices cannot receive any macOS version after Tahoe — plan replacement within [X] based on Apple's ~2-year security-update commitment."
- Track 2: "These M applications will stop working on any Mac upgraded to macOS 28 (expected fall 2027) unless the vendor ships a Universal build first — recommend contacting each vendor now."

Avoid a single combined "Macs are getting old" message — it obscures the app-compatibility risk, which is often the more urgent and less visible of the two for a client's day-to-day operations.

</details>

---

## Evidence Pack

```bash
#!/bin/bash
# Intel Mac / Rosetta retirement evidence collector — read-only, run locally on the Mac in question
OUTDIR="$HOME/Desktop/IntelMacRetirement-Evidence-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR"

echo "== Chip architecture ==" > "$OUTDIR/summary.txt"
sysctl -n machdep.cpu.brand_string >> "$OUTDIR/summary.txt"

echo "== macOS version ==" >> "$OUTDIR/summary.txt"
sw_vers >> "$OUTDIR/summary.txt"

echo "== Hardware model ==" >> "$OUTDIR/summary.txt"
system_profiler SPHardwareDataType | grep "Model Identifier" >> "$OUTDIR/summary.txt"

echo "== Available software updates ==" >> "$OUTDIR/summary.txt"
softwareupdate -l >> "$OUTDIR/summary.txt" 2>&1

echo "== Intel-only (non-Universal) applications ==" >> "$OUTDIR/summary.txt"
system_profiler SPApplicationsDataType | grep -B5 "Kind: Intel" >> "$OUTDIR/summary.txt"

echo "Evidence collected: $OUTDIR/summary.txt"
```

---

## Command Cheat Sheet

```bash
# Chip architecture
sysctl -n machdep.cpu.brand_string

# macOS version
sw_vers -productVersion

# Hardware model (for Tahoe-support-list cross-reference)
system_profiler SPHardwareDataType | grep "Model Identifier"

# Intel-only (non-Universal) application inventory
system_profiler SPApplicationsDataType | grep -B5 "Kind: Intel"

# Available software updates / current patch level
softwareupdate -l

# Full hardware overview (for escalation evidence)
system_profiler SPHardwareDataType
```

---

## 🎓 Learning Pointers

- **This is two independent retirement tracks, not one.** Hardware retirement (Intel Macs stop getting new macOS at all, ending with macOS 26 Tahoe) and app-compatibility retirement (Rosetta 2 largely ending in macOS 28) have different affected populations, different owners, and different remediation paths. Conflating them into a single "Intel Macs are old" conversation is the most common mis-scoping in this topic.

- **A new Apple Silicon Mac does not automatically solve an Intel-only application problem.** If the organization keeps running that Intel-only app without a Universal-build commitment from the vendor, the same app breaks on that brand-new Mac once it reaches macOS 28 — hardware refresh and application modernization are separate risk-reduction actions.

- **Apple's own "~2 years of security-only updates" framing for the last supported Intel Macs is a wind-down commitment, not steady-state support.** Treat it as a countdown for hardware-refresh planning, not as ongoing reassurance that those devices are fine indefinitely.

- **Rosetta 2's retirement is staged across two releases, which is a genuine planning advantage.** macOS 27 keeps full support (with a new on-demand-install UX quirk worth pre-communicating to users), and macOS 28 is the real cliff — that gives roughly a year of lead time to chase vendor Universal-build commitments before anything actually breaks.

- **This is recent, fast-evolving platform-lifecycle information as of this writing** (macOS 27 shipped September 2026; macOS 28 is not yet released as of this writing). Confirm current dates, the exact scope of Apple's game-title Rosetta 2 carve-out, and any policy refinements against Apple's own current developer/support documentation before making firm client commitments. [macOS 27 Golden Gate Is the Last to Support Intel Apps via Rosetta 2 — MacRumors](https://www.macrumors.com/2026/06/10/macos-golden-gate-last-to-support-intel-apps/)

- **Cross-reference with this repo's `macOS15MinimumVersion-A/B.md`.** That topic is Intune's own enrollment-floor policy response to the same macOS 27 release; this topic is the underlying Apple-side hardware/app-compatibility reality driving it. A complete client conversation about macOS 27 exposure should draw on both.
