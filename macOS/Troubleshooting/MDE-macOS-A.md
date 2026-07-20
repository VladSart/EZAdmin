# Microsoft Defender for Endpoint on macOS — Reference Runbook (Mode A: Deep Dive)
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

Covers **Microsoft Defender for Endpoint (MDE) on macOS** — deployment via Microsoft Intune, the client-side `mdatp` CLI, onboarding/licensing state, system extension and PPPC approval as they specifically apply to the Defender app bundle, cloud connectivity, and update channel management.

Applies to Microsoft Defender for Endpoint Plan 1, Plan 2, and Microsoft Defender for Business on macOS 12 (Monterey) or later, deployed and managed via Intune. Also touches Microsoft Purview Endpoint DLP for macOS, since the same app bundle (`com.microsoft.wdav`) and several of the same configuration profiles (Accessibility, Bluetooth, Full Disk Access) are shared infrastructure between MDE and Endpoint DLP.

**Explicitly out of scope** (see cross-references):
- Windows MDE onboarding (SENSE service, registry state) — `Security/Defender/MDE-Onboarding-A.md`/`-B.md`
- Generic, vendor-agnostic system extension/PPPC/kext mechanics that apply to any macOS security tool — `Extensions-A.md`/`Extensions-B.md` in this folder
- ASR rules, tamper protection, and general Defender feature configuration — `Security/Defender/` (largely Windows-first; macOS feature parity is more limited and evolving)
- Jamf Pro or "Other MDM" deployment paths — this runbook assumes Intune as the MDM

**Prerequisites:** macOS 12.x+ (13+ recommended for Background Services support), device enrolled and — critically — **supervised** in Intune via Automated Device Enrollment (ADE/DEP). A qualifying Microsoft 365/Defender for Endpoint license assigned to the device's primary user.

---

## How It Works

<details><summary>Full architecture</summary>

### The 12 deployment components

Unlike Windows, where a single onboarding script/GPO/Intune policy silently configures the SENSE service, macOS requires Apple's OS-level approval model to be satisfied *before* the Defender app can do anything. Microsoft's Intune deployment guide breaks this into 12 discrete steps/artifacts, each with its own bundle identifier and each independently capable of failing:

| # | Component | Sample file | Bundle identifier | Purpose |
|---|-----------|-------------|--------------------|---------|
| 1 | Approve system extensions | `sysext.mobileconfig` | N/A (Settings Catalog) | Pre-approves `com.microsoft.wdav.epsext` (EndpointSecurity) and `com.microsoft.wdav.netext` (Network) so the OS doesn't wait for a user click |
| 2 | Network filter | `netfilter.mobileconfig` | N/A | Lets the network extension inspect socket traffic for EDR telemetry — **only one Network Filter is supported system-wide on macOS**, a hard OS limit, not a Defender quirk |
| 3 | Full Disk Access | `fulldisk.mobileconfig` | `com.microsoft.wdav.epsext` | Grants TCC/PPPC access so the AV engine can actually read files it's supposed to scan |
| 4 | Background services | `background_services.mobileconfig` | N/A | Required since macOS 13 (Ventura) — apps can no longer run background daemons without explicit consent, and Defender's core scanning engine is a background daemon |
| 5 | Notifications | `notif.mobileconfig` | `com.microsoft.wdav.tray` | Lets the tray app and Microsoft AutoUpdate post user-facing alerts |
| 6 | Accessibility | `accessibility.mobileconfig` | `com.microsoft.dlp.daemon` | DLP-specific — required since macOS 10.13.6 for the Purview Endpoint DLP daemon to observe user actions (copy/paste, clipboard, print) |
| 7 | Bluetooth | `bluetooth.mobileconfig` | `com.microsoft.dlp.agent` | Required since macOS 14 (Sonoma) if Device Control policies govern Bluetooth peripherals |
| 8 | Microsoft AutoUpdate (MAU) | `com.microsoft.autoupdate2.mobileconfig` | `com.microsoft.autoupdate2` | Pins the update channel (Beta / Current-Preview / Current-Production) |
| 9 | Device Control | `DeviceControl.mobileconfig` | N/A | Optional — USB/removable media policy |
| 10 | Data Loss Prevention | `DataLossPrevention.mobileconfig` | N/A | Optional — Purview Endpoint DLP policy delivery |
| 11 | Onboarding package | `WindowsDefenderATPOnboarding.xml` | `com.microsoft.wdav.atp` | **This is what licenses the device** — a tenant-specific token, distinct from every profile above |
| 12 | Application | `Wdav.pkg` | N/A | The actual Defender app bundle, published via Intune Apps (not Configuration profiles) |

**Order matters.** Microsoft's own documentation is explicit that steps should be deployed 1→11 before the app itself lands, because the app requests extension activation and FDA/background/notification consent on first launch — if those approval profiles aren't already in place, the requests either hang waiting for a user who will never see a prompt (unsupervised device) or fire before Apple's OS has anywhere to route the silent approval.

### Why macOS onboarding looks nothing like Windows

On Windows, "onboarding" is largely a registry-key/service-state operation performed by a script running as SYSTEM — no user-facing consent model exists to fight through. On macOS, Apple's privacy and security architecture (TCC/PPPC, System Extensions framework, Background Task Management since Ventura) requires **explicit approval for nearly every capability a security product needs**, and MDM can only pre-approve these silently if the device is **supervised** — meaning enrolled via Apple Business/ADE, not manually/BYOD-enrolled. This is the single biggest source of confusion for engineers coming from a Windows-first MSP background: a config profile "delivered successfully" in Intune's per-device status does not mean the capability it grants is actually active — it means the *policy* was pushed; the *OS-level state* it's supposed to produce must be separately verified with `systemextensionsctl`, `profiles show`, or the TCC database.

### The onboarding package vs. everything else

The onboarding package (`WindowsDefenderATPOnboarding.xml`) deserves special attention because it is architecturally different from the other 11 components: it's not a capability-approval profile, it's a **license/tenant-binding token**. A device can have every system extension activated, every PPPC grant in place, and the app fully installed and running — and still show `licensed: false` in `mdatp health` and a red "x" shield, because this one specific artifact never landed. Its successful delivery is recorded at `/Library/Application Support/Microsoft/Defender/com.microsoft.wdav.atp.plist`.

### The `mdatp` CLI as the ground truth

Every layer above eventually surfaces through the `mdatp` command-line tool, which should be treated as the canonical source of truth over "profile shows Succeeded in Intune" — profile delivery and actual OS-level effect are two different things, and `mdatp health` is the only place both are reconciled:

```bash
mdatp health                              # top-level healthy/licensed/protection state + health_issues array
mdatp health --details system_extensions  # per-extension activation state
mdatp health --details permissions        # PPPC/TCC grant state
mdatp health --details edr                # EDR sensor-specific state
mdatp health --details definitions        # AV signature freshness
mdatp connectivity test                   # live reachability test against every required cloud endpoint
mdatp diagnostic create                   # bundles full logs into a zip for escalation
```

### Passive mode and side-by-side operation

For migration windows or clients running a third-party AV/EDR alongside MDE (common in MSP AV-replacement projects), the `com.microsoft.wdav` preferences profile supports `passiveMode: true`, which disables real-time antivirus remediation while keeping EDR sensor telemetry active. This does **not** resolve the single-Network-Filter-slot conflict described in component #2 above — passive mode only affects the antivirus engine's remediation behavior, not extension activation arbitration, which macOS itself enforces at the OS level regardless of any Defender setting.

### Consumer app collision

If a user has separately installed "Microsoft Defender for Individuals" (the consumer product) on a machine already running the Intune-managed MDE, the two share UI surface and the device may present a "Sign in with your Microsoft account" screen instead of the expected managed shield. This is resolved by setting `userInterface.consumerExperience` to `disabled` in the preferences profile — it is a UI routing conflict, not a licensing or extension fault, and is easy to misdiagnose as a broken onboarding.

</details>

---

## Dependency Stack

```
Apple Business (ADE/DEP token) ── device enrolled AND supervised
    └── Intune MDM enrollment (silent profile approval requires supervision)
         └── Layer 1 — Capability approval profiles (steps 1–8, any order issues cause activation to hang)
              System Extensions ─┬─ Full Disk Access (PPPC/TCC)
                                  ├─ Background Services (macOS 13+)
                                  ├─ Notifications
                                  ├─ Network Filter (ONE system-wide slot — hard OS limit)
                                  ├─ Accessibility (DLP)
                                  └─ Bluetooth (Device Control, macOS 14+)
              └── Layer 2 — Microsoft AutoUpdate channel pin
                   └── Layer 3 — Application published + installed (Wdav.pkg via Intune Apps, NOT Configuration profiles)
                        └── Layer 4 — Onboarding package (WindowsDefenderATPOnboarding.xml)
                             ── SEPARATE from Layers 1–3; this is what sets licensed=true
                             └── Layer 5 — mdatp daemon reaches "healthy" state
                                  └── Layer 6 — Cloud connectivity (mdatp connectivity test, all endpoints OK)
                                       ── SSL-inspecting/authenticated proxies are UNSUPPORTED here
                                       └── Layer 7 — Device visible in security.microsoft.com (~15–30 min lag)
```

A ticket at Layer 6 or 7 (agent looks healthy but nothing shows in the portal) is the most common false-escalation to "Defender is broken" — always confirm Layers 1–5 are genuinely healthy via `mdatp health` before assuming a cloud/portal-side fault.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Shield icon shows red **x**, "Action needed" | One or more Layer 1 capability profiles missing or unapproved | `mdatp health`, `systemextensionsctl list` |
| `health_issues` includes `"no active event provider"` | EndpointSecurity system extension not activated | `mdatp health --details system_extensions` |
| `health_issues` includes `"full disk access has not been granted"` | PPPC/FDA profile missing or not yet applied | `profiles show -all \| grep TCC`, check TCC.db |
| `health_issues` includes `"network event provider not running"` | Network extension blocked, OR a second vendor's Network Filter already owns the single system slot | `systemextensionsctl list` — look for a 2nd Network Extension entry |
| `licensed: false`, everything else healthy | Onboarding package (`WindowsDefenderATPOnboarding.xml`) never delivered, or agent out of date | `cat .../com.microsoft.wdav.atp.plist`, `mdatp health --field app_version` |
| Device shows "Sign in with your Microsoft account" | Consumer Defender app installed alongside managed MDE — UI collision | Set `consumerExperience: disabled` in preferences profile |
| `systemextensionsctl` shows `[activated waiting for user]` indefinitely | Device is not supervised (manual/BYOD enrollment) — silent approval is architecturally impossible | `profiles status -type enrollment` |
| `mdatp connectivity test` fails with curl error 35/60 | SSL-inspecting proxy — explicitly unsupported on the MDE channel | Proxy team must add an inspection bypass for MDE FQDNs |
| Agent healthy + licensed, portal shows nothing after 30+ min | `org_id` mismatch (stale onboarding from prior tenant) or telemetry not flushing | `mdatp health --field org_id`, restart `wdavdaemon` |
| Re-onboarding a previously offboarded Mac silently fails | `com.microsoft.wdav.atp.offboarding.plist` still present, blocking re-onboard | `ls /Library/Application Support/Microsoft/Defender/` |
| Endpoint DLP features not working despite MDE being healthy | Accessibility/Bluetooth profiles (DLP-specific, separate from AV/EDR profiles) missing, or Purview Device Monitoring not enabled at the portal level | `profiles show -all \| grep -i accessibility`, check Purview → Settings → Devices |
| EDR sensor healthy on Intel Mac, missing/degraded after replacing with Apple Silicon unit | Some legacy third-party AV kexts are Intel-only and silently fail on arm64 — not a Defender issue, but commonly mis-escalated as one | `uname -m`, confirm Defender itself is Universal (`file` on the binary) — Defender itself has been Universal since early releases |

---

## Validation Steps

**1. Confirm supervision (the single biggest unlock/blocker for everything downstream)**
```bash
profiles status -type enrollment
```
Expected: `MDM enrollment: Yes (Device Enrollment)`. Non-supervised = every capability approval below requires a user click; that is expected Apple behavior, not a misconfiguration.

**2. Enumerate every profile actually present on the device**
```bash
sudo profiles show -all
```
Cross-reference against the 8 capability profiles in the How It Works table. Missing rows = that specific Intune assignment failed or was never created — a common gap is publishing the app and onboarding profile while forgetting Background Services or Bluetooth, since those two were added most recently to Microsoft's guidance (Ventura/Sonoma).

**3. Confirm system extension activation state**
```bash
systemextensionsctl list
```
Expected two entries, both `[activated enabled]`:
```
*    com.microsoft.wdav  com.microsoft.wdav.epsext  [activated enabled]
*    com.microsoft.wdav  com.microsoft.wdav.netext  [activated enabled]
```

**4. Confirm PPPC/TCC grants**
```bash
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, service, allowed FROM access WHERE client LIKE '%wdav%';"
```
Expected: rows for `kTCCServiceSystemPolicyAllFiles` (Full Disk Access) with `allowed = 1`.

**5. Confirm licensing/onboarding state**
```bash
mdatp health --field licensed
cat "/Library/Application Support/Microsoft/Defender/com.microsoft.wdav.atp.plist"
```
Expected: `licensed: true`; plist contains tenant onboarding data.

**6. Run the full component health check**
```bash
mdatp health
```
Expected: `healthy: true`, `real_time_protection_available: true`, `network_protection_status: started` (if Network Protection is enabled).

**7. Test cloud reachability**
```bash
mdatp connectivity test
```
Every listed endpoint should report `[OK]`.

**8. Cross-check against Apple's own profile analyzer**
```bash
curl -O https://raw.githubusercontent.com/microsoft/mdatp-xplat/master/macos/mdm/analyze_profiles.py
sudo python3 analyze_profiles.py
```
Compares installed profiles against Microsoft's published-good set and flags drift/typos — faster than manually diffing `profiles show -all` output.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Scope the failure

1. One device or many? One → device-specific (supervision state, local profile drift, stale offboarding file). Many/fleet-wide → deployment/profile-assignment issue in Intune.
2. Is this a fresh deployment or a previously-working device that regressed? Regression after a macOS upgrade points at re-approval requirements (system extensions occasionally need re-activation post-upgrade) rather than a profile problem.
3. Confirm supervision before anything else — it changes which fixes are even possible: `profiles status -type enrollment`.

### Phase 2 — Profile delivery (Intune side)

1. Intune admin center → Devices → macOS → Configuration → each of the 8 capability profiles individually → **Device and user check-in status** → confirm `Succeeded` for this specific device, not just group assignment.
2. On the device: `sudo profiles show -all` — cross-check every payload type is present.
3. If a profile is assigned but not applying: force a management check-in from Company Portal, or `sudo profiles renew -type enrollment`.

### Phase 3 — Extension and permission activation (OS side)

1. `systemextensionsctl list` — note exact state for both `epsext` and `netext`.
2. `waiting for user` on a supervised device = profile genuinely missing/not-yet-applied, not a real "waiting" state — supervision should make this instantaneous. Don't assume it will resolve itself.
3. `terminated` = crashed; pull `/Library/Logs/DiagnosticReports/` entries matching `wdav` and Console.app logs.
4. Check TCC/PPPC grants per Validation Step 4.

### Phase 4 — Licensing/onboarding

1. Confirm the onboarding package profile specifically (separate from every capability profile) is assigned and succeeded.
2. Check the onboarding plist and offboarding plist per Validation Step 5 and the Symptom Map row on stale offboarding.
3. Confirm agent version meets minimum via `mdatp health --field app_version` against current [What's new](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-endpoint-releases#macos-releases).

### Phase 5 — Cloud/portal

1. `mdatp connectivity test` — resolve any failing endpoint before assuming a portal-side delay.
2. Check `org_id` for tenant mismatch (common after MSP re-imaging/re-tenanting).
3. Allow the documented 15–30 minute first-appearance lag before escalating a "not visible in portal" ticket.

### Phase 6 — Conflicts with other security tools

1. `systemextensionsctl list` — look for a second Network Extension entry from a different Team ID; only one can hold the system's Content Filter slot.
2. If intentional side-by-side operation is required during a migration, configure passive mode per Microsoft's [side-by-side guidance](https://learn.microsoft.com/en-us/defender-endpoint/mde-side-by-side) — but understand this does not resolve the Network Filter arbitration, only AV remediation behavior.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full clean deployment sequence audit (new tenant/site rollout)</summary>

Before assigning to a pilot group, verify every artifact exists in Intune in the correct order:

1. Settings Catalog profile: System Extensions → `com.microsoft.wdav.epsext` + `com.microsoft.wdav.netext`, Team ID `UBF8T346G9`
2. Custom profile: `netfilter.mobileconfig` (downloaded fresh from `https://raw.githubusercontent.com/microsoft/mdatp-xplat/master/macos/mobileconfig/profiles/netfilter.mobileconfig` — never hand-typed, to avoid a typo'd payload)
3. Custom profile: `fulldisk.mobileconfig`
4. Custom profile: `background_services.mobileconfig`
5. Custom profile: `notif.mobileconfig`
6. Custom profile: `accessibility.mobileconfig`
7. Custom profile: `bluetooth.mobileconfig` (if Device Control in scope)
8. Custom profile: `com.microsoft.autoupdate2.mobileconfig`
9. Custom profile (name **must** be exactly `com.microsoft.wdav`): AV/EDR preferences XML from the [Intune recommended profile](https://learn.microsoft.com/en-us/defender-endpoint/mac-preferences#intune-recommended-profile)
10. App: Microsoft Defender for Endpoint → macOS, published via Intune Apps (not Configuration)
11. Custom profile: onboarding package XML, downloaded fresh per-tenant from the Defender portal (**never reused across tenants** — this is the license-binding artifact)

Assign all 11 to the same pilot device group, wait one full check-in cycle, then validate with the full Validation Steps sequence above.

**Rollback:** unassign the app and onboarding profile first (stops licensing/functionality), then remove capability profiles — removing capability profiles first while the app is still active can leave the extension in an inconsistent activated-but-unapproved state.

</details>

<details><summary>Playbook 2 — Recover a device stuck at "waiting for user" on a supervised fleet</summary>

```bash
# 1. Confirm supervision is genuinely active (not just enrolled)
profiles status -type enrollment

# 2. Confirm the System Extensions profile is actually present, not just assigned in Intune
sudo profiles show -all | grep -A5 "SystemExtensions\|com.apple.system-extension-policy"

# 3. If missing, force a fresh management check-in
sudo profiles renew -type enrollment

# 4. Re-check activation
systemextensionsctl list

# 5. If still stuck, deactivate and let the app re-request (only if app has already launched once)
sudo systemextensionsctl deactivate UBF8T346G9/com.microsoft.wdav.epsext
open -a "Microsoft Defender"
```

**Rollback:** none required — this is an activation-repair sequence, not a destructive change.

</details>

<details><summary>Playbook 3 — Resolve a stalled tenant re-onboard after device re-imaging (MSP fleet reuse)</summary>

```bash
# 1. Check for stale onboarding/offboarding state from the PREVIOUS tenant
ls -la "/Library/Application Support/Microsoft/Defender/" | grep -E "atp.plist|offboarding"

# 2. If an offboarding plist exists, remove it (only if this device is confirmed to be re-provisioned for THIS tenant)
sudo rm "/Library/Application Support/Microsoft/Defender/com.microsoft.wdav.atp.offboarding.plist"

# 3. Confirm org_id no longer references the old tenant
mdatp health --field org_id

# 4. Re-deliver the CURRENT tenant's onboarding profile (must be freshly downloaded from THIS tenant's Defender portal)
#    — re-sync Intune or re-run the onboarding profile push

# 5. Validate
mdatp health --field licensed
mdatp health --field org_id
```

**Rollback:** if re-onboarded to the wrong tenant by mistake, offboard properly via the portal's offboarding package for that tenant before attempting to onboard to the correct one — do not just delete files to "start over," as the portal-side device object will remain in the wrong tenant otherwise.

</details>

<details><summary>Playbook 4 — Diagnose and resolve Network Filter conflict during AV migration</summary>

```bash
# 1. Enumerate all active network/system extensions and their vendors
systemextensionsctl list

# 2. Identify the competing product's Team ID and bundle ID from the output

# 3. Decide the migration order — do NOT run two full real-time AV engines with competing
#    Network Filters simultaneously in production; pick one to hold the Network Filter slot

# 4. If keeping the legacy product active temporarily, set Defender to passive mode
#    (com.microsoft.wdav preferences profile, passiveMode: true) — note this affects
#    AV remediation only, not the Network Filter arbitration itself

# 5. When ready to cut over, deactivate the losing extension and confirm the winner is enabled
sudo systemextensionsctl deactivate <OtherVendorTeamID>/<OtherVendorBundleID>
systemextensionsctl list
```

**Rollback:** re-enable the deactivated legacy product by reinstalling/relaunching its host app, then re-set Defender to active mode if needed.

</details>

---

## Evidence Pack

```bash
#!/bin/bash
# EZAdmin — MDE on macOS Evidence Collector
OUTPUT="/tmp/mde_macos_evidence_$(date +%Y%m%d_%H%M%S).txt"

echo "=== MDE on macOS Evidence Pack ===" > "$OUTPUT"
echo "Date: $(date)" >> "$OUTPUT"
echo "Hostname: $(hostname)" >> "$OUTPUT"
echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))" >> "$OUTPUT"
echo "Arch: $(uname -m)" >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo "=== MDM Supervision ===" >> "$OUTPUT"
profiles status -type enrollment >> "$OUTPUT" 2>&1

echo "" >> "$OUTPUT"
echo "=== Installed Profiles (Defender-relevant) ===" >> "$OUTPUT"
sudo profiles show -all 2>&1 | grep -iE "ProfileDisplayName|PayloadType|wdav|extension-policy|webcontent-filter|TCC|notification|servicemanagement|autoupdate" >> "$OUTPUT"

echo "" >> "$OUTPUT"
echo "=== System Extensions ===" >> "$OUTPUT"
systemextensionsctl list >> "$OUTPUT" 2>&1

echo "" >> "$OUTPUT"
echo "=== mdatp health (full) ===" >> "$OUTPUT"
mdatp health >> "$OUTPUT" 2>&1

echo "" >> "$OUTPUT"
echo "=== mdatp health details ===" >> "$OUTPUT"
for f in system_extensions permissions edr definitions; do
  echo "--- $f ---" >> "$OUTPUT"
  mdatp health --details "$f" >> "$OUTPUT" 2>&1
done

echo "" >> "$OUTPUT"
echo "=== Onboarding / Offboarding artifacts ===" >> "$OUTPUT"
ls -la "/Library/Application Support/Microsoft/Defender/" >> "$OUTPUT" 2>&1

echo "" >> "$OUTPUT"
echo "=== TCC Full Disk Access (wdav) ===" >> "$OUTPUT"
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, service, allowed FROM access WHERE client LIKE '%wdav%';" >> "$OUTPUT" 2>&1

echo "" >> "$OUTPUT"
echo "=== Cloud connectivity test ===" >> "$OUTPUT"
mdatp connectivity test >> "$OUTPUT" 2>&1

echo "" >> "$OUTPUT"
echo "=== Recent system_extensions log errors (2h) ===" >> "$OUTPUT"
log show --last 2h --predicate 'subsystem == "com.apple.system_extensions"' 2>/dev/null \
  | grep -i "wdav\|error\|fail\|block" | tail -30 >> "$OUTPUT"

echo "" >> "$OUTPUT"
echo "Evidence written to: $OUTPUT"
echo "Consider also running: sudo mdatp diagnostic create   (full MS-formatted support bundle)"
cat "$OUTPUT"
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Full health summary | `mdatp health` |
| One health field only | `mdatp health --field <name>` (e.g. `licensed`, `org_id`, `app_version`, `edr_machine_id`) |
| Detailed health for a feature | `mdatp health --details system_extensions \| permissions \| edr \| definitions \| features` |
| Cloud connectivity test | `mdatp connectivity test` |
| Bundle full diagnostic logs | `sudo mdatp diagnostic create` |
| List system extensions + state | `systemextensionsctl list` |
| Check MDM enrollment/supervision | `profiles status -type enrollment` |
| Show all installed MDM profiles | `sudo profiles show -all` |
| Force MDM check-in | `sudo profiles renew -type enrollment` |
| Deactivate a system extension | `sudo systemextensionsctl deactivate <TeamID>/<BundleID>` |
| Check TCC/PPPC grants for Defender | `sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "SELECT client,service,allowed FROM access WHERE client LIKE '%wdav%';"` |
| Onboarding license artifact | `cat "/Library/Application Support/Microsoft/Defender/com.microsoft.wdav.atp.plist"` |
| Offboarding artifact (blocks re-onboard if present) | `ls "/Library/Application Support/Microsoft/Defender/com.microsoft.wdav.atp.offboarding.plist"` |
| Download a reference `.mobileconfig` (avoid typos) | `curl -O https://raw.githubusercontent.com/microsoft/mdatp-xplat/master/macos/mobileconfig/profiles/<name>.mobileconfig` |
| Cross-check installed profiles vs. Microsoft's published set | `sudo python3 analyze_profiles.py` (from mdatp-xplat repo) |
| Manual cloud reachability spot-check | `curl -w ' %{url_effective}\n' 'https://x.cp.wd.microsoft.com/api/report' 'https://cdn.x.cp.wd.microsoft.com/ping'` |
| macOS version/build | `sw_vers` |
| Architecture | `uname -m` |

---

## 🎓 Learning Pointers

- **macOS onboarding is fundamentally a 12-artifact deployment, not a single onboarding action.** Coming from Windows (one SENSE service, one registry key), the biggest mental shift is that "onboarding" on macOS is really "satisfy Apple's consent model across 8 separate capabilities, then separately deliver a distinct licensing artifact." Treat each of the 12 components in the How It Works table as independently verifiable. [Deploy MDE on macOS with Intune](https://learn.microsoft.com/en-us/defender-endpoint/mac-install-with-intune).
- **Supervision (ADE/DEP), not just enrollment, is the real gate on silent approval.** A device can be fully MDM-enrolled and still require manual user clicks for every capability if it wasn't enrolled through Apple Business. Always check `profiles status -type enrollment` for the supervision flag before troubleshooting profile content.
- **The Network Filter is a single, system-wide OS resource.** This is an Apple platform limit, not something Microsoft (or any vendor) can configure around — running two full security products with competing network extensions in production will always result in one losing that slot. Plan AV migrations with this in mind, not as an afterthought.
- **The onboarding package is a tenant-bound license token, never reusable across tenants** — a very common MSP mistake is re-imaging a device and re-running an old onboarding package from a prior client's tenant. Always download fresh from the target tenant's Defender portal, and check `org_id` when troubleshooting "not appearing" tickets on reused hardware.
- **SSL-inspecting and authenticated proxies are explicitly and permanently unsupported** on the MDE cloud channel — this isn't a "not yet supported," it's a security design decision (certificate pinning). Any client's network/security team that inspects all outbound TLS by policy needs a documented bypass for the MDE FQDN list.
- **Intune's legacy "Extensions" configuration profile template was deprecated for new policies starting the August 2024 service release** — existing profiles built on it keep working, but new deployments must use the Settings Catalog's System Extensions category. If a runbook screenshot or old ticket references the old template, verify against the current portal before repeating those steps.
