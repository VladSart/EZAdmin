# Microsoft Defender for Endpoint on macOS — Hotfix Runbook (Mode B: Ops)
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

Run on the affected Mac (Terminal):

```bash
# 1 — Overall health + the exact reasons it's unhealthy
mdatp health

# 2 — Is the device even licensed/onboarded?
mdatp health --field licensed
mdatp health --field org_id

# 3 — System extension approval state (the #1 cause of the shield showing an "x")
systemextensionsctl list | grep -i wdav

# 4 — Cloud connectivity (proxy/firewall/SSL-inspection failures show here)
mdatp connectivity test

# 5 — Are the required MDM configuration profiles actually present?
profiles show -all 2>&1 | grep -E "com.microsoft.wdav|system-extension-policy|webcontent-filter|TCC.configuration-profile-policy|notificationsettings|servicemanagement"
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| `healthy: false`, `health_issues` lists `"no active event provider"` / `"full disk access has not been granted"` | System extension not approved and/or PPPC/FDA profile missing | [Fix 1](#fix-1) |
| Shield icon shows red **x**, "No license found" | Onboarding profile/package never landed, or agent out of date | [Fix 2](#fix-2) |
| `systemextensionsctl list` shows `[activated waiting for user]` | Device isn't supervised, or the System Extensions profile hasn't applied yet | [Fix 1](#fix-1) |
| `mdatp connectivity test` fails one or more endpoints | Proxy/firewall blocking, or SSL/TLS-inspecting proxy in the path (unsupported) | [Fix 3](#fix-3) |
| Agent healthy, onboarded, but device never appears in the Defender portal | Sensor healthy but telemetry not reaching the portal yet, or org_id mismatch | [Fix 4](#fix-4) |
| `com.microsoft.wdav.atp.offboarding.plist` exists on disk | Device was previously offboarded — blocks re-onboarding until removed | [Fix 5](#fix-5) |
| A **second** security product's kernel/network filter is also installed | Another Network Filter extension is fighting MDE's for the single-slot Content Filter | [Fix 6](#fix-6) |

---

## Dependency Cascade

<details><summary>What must be true for MDE on macOS to reach "healthy"</summary>

```
[Mac enrolled + supervised in Intune (ADE/DEP — silent profile approval needs this)]
    └── [11 Settings Catalog / custom configuration profiles delivered, IN ORDER]
            1. System Extensions (sysext.mobileconfig) — approves com.microsoft.wdav.epsext + .netext
            2. Network Filter (netfilter.mobileconfig) — ONE per device, conflicts if a 2nd vendor filter exists
            3. Full Disk Access / PPPC (fulldisk.mobileconfig)
            4. Background Services (background_services.mobileconfig) — required macOS 13+
            5. Notifications (notif.mobileconfig)
            6. Accessibility (accessibility.mobileconfig) — DLP-related
            7. Bluetooth (bluetooth.mobileconfig) — Device Control, macOS 14+
            8. Microsoft AutoUpdate channel (com.microsoft.autoupdate2.mobileconfig)
            9. Defender preferences (com.microsoft.wdav.xml — AV/EDR policy)
                    └── [Wdav.pkg app published + installed via Intune]
                            └── [Onboarding package deployed (WindowsDefenderATPOnboarding.xml) — THIS is what "licenses" the device]
                                    └── [System extension shows "activated enabled" in systemextensionsctl]
                                            └── [mdatp health: healthy=true, real_time_protection_available=true]
                                                    └── [Device visible in security.microsoft.com within ~15–30 min]
```

**Critical ordering note:** deploying the app/onboarding package *before* the System Extensions and PPPC profiles is the single most common cause of a stuck "x" shield — the extension activates but sits in `[activated waiting for user]` forever on an unsupervised device, or silently fails FDA checks. Always confirm profiles 1–8 are present before troubleshooting the app itself.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm MDM supervision (required for silent approval)**
```bash
profiles status -type enrollment
```
Expected: `MDM enrollment: Yes (Device Enrollment)` and supervised. Unsupervised (BYOD/manual) enrollment means the user must manually approve every extension/permission — that's expected behavior, not a bug.

**Step 2 — Confirm all required profiles landed**
```bash
profiles show -all | grep -E "ProfileDisplayName|PayloadType" | grep -B1 -iE "wdav|extension-policy|webcontent-filter|TCC|notification|servicemanagement|autoupdate"
```
Bad: any of the 8 profile payload types from the Dependency Cascade missing → re-check Intune assignment for that specific profile, not just the group as a whole (a common mistake is assigning the app but forgetting one config profile).

**Step 3 — Confirm system extension activation**
```bash
systemextensionsctl list
```
Expected:
```
1 extension for com.microsoft.wdav.epsext [activated enabled]
1 extension for com.microsoft.wdav.netext [activated enabled]
```
Bad: `[activated waiting for user]` (approval profile missing/not applied) or `[terminated]` (crashed — check Console.app / `log show`).

**Step 4 — Run full health check**
```bash
mdatp health
mdatp health --details system_extensions
mdatp health --details permissions
```
Good: `healthy: true`, `licensed: true`, `real_time_protection_available: true`.

**Step 5 — Test cloud connectivity**
```bash
mdatp connectivity test
```
Every endpoint should report `[OK]`. `curl` error 35/60 on any endpoint = certificate pinning rejection, almost always an SSL-inspecting proxy — MDE explicitly does not support SSL inspection on its channel.

**Step 6 — Confirm portal visibility**
security.microsoft.com → **Assets → Devices**, filter by hostname. Allow 15–30 minutes after a clean onboard before treating "not visible" as a real problem.

---

## Common Fix Paths

<details>
<summary id="fix-1">Fix 1 — Extension stuck "waiting for user" / FDA not granted</summary>

**Confirm the cause first — supervision status decides the fix:**
```bash
profiles status -type enrollment
```

**If supervised (ADE/DEP) and still stuck:**
1. In Intune → Devices → macOS → Configuration profiles, confirm the **System Extensions** (Settings Catalog) profile and the **Full Disk Access / PPPC** custom profile are both assigned to this device's group and show `Succeeded` in per-device status — not just `Assigned`.
2. Force a profile refresh on the device:
```bash
sudo profiles renew -type enrollment
```
3. Re-check:
```bash
systemextensionsctl list
mdatp health --details system_extensions
```

**If unsupervised (BYOD/manual enrollment) — this requires end-user action, it is not a config bug:**
Have the user go to **System Settings → Privacy & Security**, scroll to the blocked-extension banner, and select **Allow**. Repeat for each of: system extension approval, Full Disk Access (Microsoft Defender + Microsoft Defender Security Extension), Background Services, Notifications, Accessibility.

**Note (Intune-specific deprecation):** Intune's original System Extensions payload type was deprecated for new policies in the August 2024 service release. If building this fresh, use the **Settings Catalog → System Extensions** category, not the legacy template — existing legacy profiles keep working but can't be edited into new ones.

**Rollback:** none needed — this is an additive approval, not a destructive change.
</details>

<details>
<summary id="fix-2">Fix 2 — "No license found" / red x shield</summary>

Per Microsoft's own troubleshooting flow, this has exactly three root causes — check in this order:

**1. Onboarding package never ran (most common):**
```bash
cat "/Library/Application Support/Microsoft/Defender/com.microsoft.wdav.atp.plist" 2>/dev/null
```
If missing or empty, the onboarding profile (`WindowsDefenderATPOnboarding.xml`, deployed as a custom configuration profile) never landed. Re-check Intune assignment for that specific profile — it is separate from the app and from the AV/EDR settings profile, and is the single item that actually "licenses" the device.

**2. Agent out of date:**
```bash
mdatp health --field app_version
```
Compare against current minimum (101.95.07 or later as of this writing — verify against [What's new in MDE on macOS](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-endpoint-releases#macos-releases)). Update via the Microsoft AutoUpdate channel profile, or manually via Company Portal → reinstall.

**3. Device was previously offboarded:**
```bash
ls -la "/Library/Application Support/Microsoft/Defender/com.microsoft.wdav.atp.offboarding.plist" 2>/dev/null
```
If this file exists, it **blocks re-onboarding**. See [Fix 5](#fix-5).

**If none of the above — license not assigned to the user in M365 admin center:** confirm the target user/device has a qualifying SKU (Defender for Endpoint P1/P2, or a bundled E5/Business Premium license) actually assigned, not just available in the tenant pool.

**Rollback:** none — this is a diagnostic/re-delivery fix, not a destructive change.
</details>

<details>
<summary id="fix-3">Fix 3 — Cloud connectivity test fails</summary>

```bash
mdatp connectivity test
```

**If specific endpoints fail with a timeout (not a cert error):** a firewall/proxy is blocking anonymous HTTPS traffic to the MDE cloud endpoints. Cross-check the full required URL list against [MDE on macOS network connectivity prerequisites](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-endpoint-mac-prerequisites#network-connectivity) and open outbound 443 for those FQDNs, unauthenticated.

**If curl error 35 or 60 on any endpoint:** this is certificate pinning rejection — almost always an SSL/TLS-inspecting proxy in the path. **MDE explicitly does not support SSL inspection or authenticated proxies on its telemetry channel.** The fix is a proxy exception (bypass inspection and authentication) for the MDE FQDN list, not a certificate trust change on the Mac — adding the inspection CA to the system keychain will not fix this.

**Quick manual cross-check without the CLI:**
```bash
curl -w ' %{url_effective}\n' 'https://x.cp.wd.microsoft.com/api/report' 'https://cdn.x.cp.wd.microsoft.com/ping'
```
Both should return `OK`.

**Rollback:** none — network path fix only.
</details>

<details>
<summary id="fix-4">Fix 4 — Healthy + licensed, but not visible in the portal</summary>

1. Confirm `org_id` matches your tenant (rules out a stale onboarding from a different tenant — common after a re-image in MSP fleets):
```bash
mdatp health --field org_id
```
2. Force a telemetry flush:
```bash
sudo launchctl kickstart -k system/com.microsoft.fresno.plist 2>/dev/null || sudo pkill -HUP wdavdaemon
```
3. Re-run `mdatp connectivity test` — if anything fails here, fix that first, then wait another 15–30 minutes before re-checking the portal.
4. Search the portal by `edr_machine_id` (`mdatp health --field edr_machine_id`) rather than hostname — catches duplicate/stale device objects with a mismatched name.

**Rollback:** none.
</details>

<details>
<summary id="fix-5">Fix 5 — Stale offboarding file blocking re-onboarding</summary>

```bash
sudo rm "/Library/Application Support/Microsoft/Defender/com.microsoft.wdav.atp.offboarding.plist"
```
Then re-deliver the onboarding profile (re-sync from Intune, or re-run the onboarding script if deploying manually). Allow ~15 minutes after removal before re-onboarding — offboarding is not instantaneous on the backend side either.

**Rollback:** re-creating the offboarding file is the intended way to offboard a device on purpose — don't remove it if this Mac is being decommissioned or re-tenanted deliberately.
</details>

<details>
<summary id="fix-6">Fix 6 — Second security product's Network Filter conflicts</summary>

**Only one Network Filter (Content Filter) extension is supported system-wide on macOS.** If another EDR/AV product (CrowdStrike, SentinelOne, Jamf Protect, etc.) is also installed with its own network extension, one of the two will silently lose the network-filtering slot — this is an Apple OS-level limitation, not a Defender bug.

```bash
systemextensionsctl list
```
Look for a second `[activated enabled]` entry of type Network Extension from a different Team ID.

If running two products side-by-side is required (migration window), see Microsoft's [side-by-side considerations](https://learn.microsoft.com/en-us/defender-endpoint/mde-side-by-side) and put MDE's AV component into passive mode (`passiveMode: true` in the `com.microsoft.wdav` preferences profile) while the other product owns real-time protection — but note EDR/network-filtering conflicts are not resolved by passive mode alone; the losing extension must be deactivated.

**Rollback:** re-activating a deactivated extension requires reinstalling/relaunching the owning app.
</details>

---

## Escalation Evidence

```
=== MDE ON macOS ESCALATION ===
Date/Time      :
Engineer       :
Ticket         :

Device Name    :
Serial Number  : (system_profiler SPHardwareDataType | grep Serial)
macOS Version  : (sw_vers -productVersion / -buildVersion)
Architecture   : (uname -m — arm64 or x86_64)
Supervised     : (profiles status -type enrollment)

mdatp health (full output)      :
mdatp health --field org_id     :
mdatp health --field licensed   :
mdatp health --field app_version:

systemextensionsctl list output :

Profiles present (profiles show -all, grep wdav/extension/TCC) :

mdatp connectivity test output  :

Offboarding plist present? (ls .../com.microsoft.wdav.atp.offboarding.plist) :

Steps Attempted:
1.
2.
3.

Expected behaviour : mdatp health reports healthy=true, licensed=true; device visible in security.microsoft.com
Actual behaviour   :
```

---

## 🎓 Learning Pointers

- **Onboarding on macOS is a manual, multi-profile deployment — there is no single "click to onboard" like Windows Autopilot/GPO.** Intune requires 8+ separate configuration profiles delivered in a specific order before the app and onboarding package even land; missing or misordering one is the most common root cause of "it's stuck." See [Deploy MDE on macOS with Intune](https://learn.microsoft.com/en-us/defender-endpoint/mac-install-with-intune).
- **The onboarding package is what "licenses" the device — it's a separate artifact from the app and from the AV/EDR settings profile.** A device can have the app installed and running with zero license/onboarding state; `mdatp health --field licensed` is the fastest way to tell these apart. See [Troubleshoot license issues](https://learn.microsoft.com/en-us/defender-endpoint/mac-support-license).
- **`mdatp health --details <feature>`** (e.g. `system_extensions`, `permissions`, `edr`, `definitions`) gives targeted diagnostics far faster than reading the full health dump — always reach for the details flag once the top-level `health_issues` array points at a category. See [Troubleshoot agent health issues](https://learn.microsoft.com/en-us/defender-endpoint/mac-health-status).
- **SSL-inspecting and authenticated proxies are explicitly unsupported** on the MDE cloud channel — a client's corporate proxy team must add an inspection bypass for the MDE FQDN list, not a certificate trust workaround on the Mac. Curl errors 35/60 are the tell.
- **Intune's legacy "Extensions" profile template is deprecated for new policies (August 2024 service release onward)** — existing legacy profiles keep working, but new builds should use Settings Catalog → System Extensions. Don't assume an old runbook screenshot still matches the current portal UI.
- **This runbook covers the macOS/Linux-specific deployment gap explicitly left open by `Security/Defender/MDE-Onboarding-A.md` and `-B.md`**, which are Windows-only (SENSE service, registry-based onboarding state). For general system-extension/PPPC mechanics that apply to any vendor (not just Defender), see `Extensions-A.md`/`Extensions-B.md` in this folder.
