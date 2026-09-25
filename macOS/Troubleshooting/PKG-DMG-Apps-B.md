# macOS PKG / DMG App Deployment (Intune Agent) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "macOS app (PKG) / (DMG) stuck or Failed", "0x87D301xx", "app installed but Intune says Failed", or "Company Portal still shows Pending" in under 10 minutes.

> **Context (Sept 2026):** Intune has two ways to push a package to a Mac, and they fail in different ways:
> - **macOS LOB app (managed PKG):** delivered by the MDM protocol (`InstallEnterpriseApplication`). The package must be a signed distribution package that installs into `/Applications`.
> - **macOS app (PKG)** (unmanaged) and **macOS app (DMG)**: installed by the **Microsoft Intune management agent** (`IntuneMdmDaemon`, running as root), the same agent that runs shell scripts. Both have an 8 GB limit.
>
> This runbook covers the **agent-delivered** types. Everything depends on the agent being installed and checking in, and on the **Included apps** detection list matching real `CFBundleIdentifier` and `CFBundleShortVersionString` values. The PKG type needs agent 2308.006+ (2309.007+ for pre/post-install scripts). Updating a DMG needs agent 2304.039+. DMG update and delete also need Full Disk Access, which Intune requests automatically on macOS 13+. Sources: [Add an unmanaged macOS PKG app (Learn, ms.date 2026-04-14)](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-unmanaged-pkg-macos); [Add a macOS DMG app (Learn, ms.date 2026-04-14)](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-dmg-macos); [Support tip: Troubleshooting the Intune management agent on macOS (Intune Customer Success)](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-troubleshooting-microsoft-intune-management-agent-on-macos/4431810).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run on the Mac in Terminal (use `sudo` for the root-owned logs). Allow about 60 seconds.

```bash
# 1. Agent installed and running?
ls -d "/Library/Intune/Microsoft Intune Agent.app" && defaults read "/Library/Intune/Microsoft Intune Agent.app/Contents/Info" CFBundleShortVersionString
pgrep -il "^IntuneMdm"            # expect IntuneMdmDaemon (root) and IntuneMdmAgent (user)

# 2. Latest daemon log: app install lines and 0x87D301xx codes
LOG=$(ls -t /Library/Logs/Microsoft/Intune/IntuneMDMDaemon*.log 2>/dev/null | head -1); echo "$LOG"
sudo grep -iE "AppInstall|PKG|DMG|0x87D30|Detection|Included" "$LOG" | tail -30

# 3. Is the app actually on disk, and what bundle ID/version does it report?
mdfind "kMDItemCFBundleIdentifier == '<bundle.id>'"
defaults read "/Applications/<App Name>.app/Contents/Info" CFBundleIdentifier
defaults read "/Applications/<App Name>.app/Contents/Info" CFBundleShortVersionString

# 4. Disk space and OS version (0x87D3013A / 0x87D30135 / 0x87D30137)
df -h / | tail -1 ; sw_vers -productVersion
```

| Result | Meaning | Go to |
|---|---|---|
| No agent app, or `pgrep` shows nothing | Agent isn't installed, or crashed | Fix 1 |
| Log shows nothing for the app | Assignment not received, or the agent hasn't checked in (roughly every 8 h) | Fix 1 (force check-in) |
| App on disk but Intune says **Failed** / not detected | **Included apps** bundle ID or version doesn't match | Fix 2 |
| `0x87D30137` | Device is below the app's Minimum OS | Update macOS or lower the requirement |
| `2016214710` (PKG) | Pre-install script returned non-zero, so the install was skipped | Fix 3 |
| `0x87D3013E` / `0x87D30139` (DMG) | No `.app` in the DMG / DMG won't mount | Fix 4 |
| `0x87D3013B` / `0x87D30135` / `0x87D3013A` | Can't write to /Applications, out of disk, or corrupt payload | Fix 5 |
| `0x87D30131` / `0x87D30132` | Download failed | Fix 5 (network) |
| Company Portal shows **Pending** but the app works | Known issue. The portal report is correct | Fix 6 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Intune reports "Installed"
└── Every bundle ID in "Included apps" is found at the expected version
    │   (unless "Ignore app version" = Yes → presence only)
    └── Install succeeded
        ├── PKG: `installer -pkg` exits 0 as root; pre-install script (if any) exits 0
        ├── DMG: image mounts, contains ≥1 .app, copied to /Applications
        ├── Disk space, write access to /Applications (FDA for DMG update/delete, macOS 13+)
        └── Package downloaded (≤ 8 GB) from Intune CDN
            └── Minimum OS requirement met
                └── Intune agent installed (PKG ≥ 2308.006, scripts ≥ 2309.007, DMG update ≥ 2304.039)
                    └── Agent checks in (IntuneMdmDaemon running; ~8 h cadence, or on Company Portal "Check status")
                        └── Device MDM-enrolled + app assigned (Required / Available; Uninstall = DMG only)
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm the app type in the portal.** Apps → macOS → the app → Properties. **macOS app (PKG)** and **macOS app (DMG)** are agent-delivered. **Line-of-business app** is MDM-delivered, so this runbook doesn't apply. Use `VPP-App-Deployment-A.md` for the MDM path, or check `log show --predicate 'subsystem == "com.apple.ManagedClient"'`.

2. **Confirm the agent is present.**
   ```bash
   pgrep -il "^IntuneMdm"
   ```
   *Good:* `IntuneMdmDaemon` is listed, plus `IntuneMdmAgent` when a user is signed in. *Bad:* nothing is listed. Go to Fix 1.

3. **Find the app's transaction in the log.** Daemon logs are pipe-delimited. Search for the app name or bundle ID:
   ```bash
   sudo grep -h "<bundle.id>\|<App Name>" /Library/Logs/Microsoft/Intune/IntuneMDMDaemon*.log | tail -20
   ```
   *Good:* download, install, then a detection result. *Bad:* no lines at all, which means the app wasn't received. Force a check-in (Fix 1).

4. **Compare detection with reality.** Intune's **Included apps** list (Detection rules tab) has to match what `defaults read …/Info CFBundleIdentifier` and `CFBundleShortVersionString` return on the Mac. **Every** listed app must be present, and only apps may be listed. The first entry is the one used for reporting.

5. **Reproduce the install.** Test on a lab Mac:
   ```bash
   sudo installer -pkg /path/to/app.pkg -target / -verboseR     # PKG: must exit 0 (a Learn prerequisite)
   hdiutil attach -nobrowse /path/to/app.dmg && ls /Volumes/*/  # DMG: must mount and contain a .app
   ```

---
## Common Fix Paths

<details><summary>Fix 1 — Agent missing, stalled, or not checking in</summary>

```bash
# Force a check-in: Company Portal → Devices → this Mac → "Check status"
# Restart the agent (launchd relaunches it)
sudo killall IntuneMdmDaemon 2>/dev/null; killall IntuneMdmAgent 2>/dev/null
sleep 10; pgrep -il "^IntuneMdm"
```
- If the agent app is missing entirely, it installs automatically once a shell script, custom attribute, PKG or DMG app is assigned to the device or user. Check the assignment, then check-in.
- If the agent crashes repeatedly, collect `/Library/Logs/Microsoft/Intune/` and escalate.
</details>

<details><summary>Fix 2 — Installed but Intune reports Failed / Not detected (Included apps mismatch)</summary>

```bash
APP="/Applications/<App Name>.app"
defaults read "$APP/Contents/Info" CFBundleIdentifier
defaults read "$APP/Contents/Info" CFBundleShortVersionString
```
- Edit the app → **Detection rules** → **Included apps**: remove anything that isn't an app (helpers, frameworks, plug-ins), and remove apps installed outside `/Applications` (for DMG).
- For self-updating apps (browsers, Zoom, and similar), set **Ignore app version = Yes**. Otherwise Intune sees a version drift and reinstalls the old version.
- Example: the Company Portal PKG lists many libraries. Keep only `com.microsoft.CompanyPortalMac`.

No rollback needed. Detection changes apply at the next check-in.
</details>

<details><summary>Fix 3 — PKG pre-install script failure (2016214710)</summary>

The PKG install **only proceeds when the pre-install script exits 0**. A non-zero exit is reported as failed and retried at the next check-in. That may be intentional, for example a gating script waiting for a condition.
- Run the script locally as root: `sudo zsh /path/preinstall.sh; echo $?`
- Keep each script under 15,360 characters and make it return an explicit `exit 0` on success.
- **Post-install script failures are NOT reported.** The app still shows *Installed*. Check the daemon log if post-install work seems to be missing.
</details>

<details><summary>Fix 4 — DMG won't mount or has no app (0x87D30139 / 0x87D3013E)</summary>

```bash
hdiutil verify /path/to/app.dmg
hdiutil attach -nobrowse /path/to/app.dmg; ls /Volumes/
```
- A DMG with a `.pkg` inside isn't supported, because the DMG type only copies `.app` bundles. Extract the PKG and deploy it as **macOS app (PKG)** instead.
- DMGs with a licence agreement (SLA) or that need interactive mounting can fail. Repackage them with `hdiutil create -srcfolder <App>.app -format UDZO out.dmg`.
- Don't bundle independent apps in one DMG. If one fails, the others are reinstalled and the whole app reports failure.
</details>

<details><summary>Fix 5 — Disk, write-access, or download failures (0x87D3013A/35/3B, 0x87D30131/32)</summary>

```bash
df -h /
ls -ld /Applications                          # expect drwxrwxr-x root admin
```
- Free up disk space, then restart the agent (Fix 1).
- For DMG **updates or uninstalls** on macOS 13+, the agent needs **Full Disk Access**. Intune requests it automatically, but if a conflicting PPPC profile denies it, updates fail. See `PPPC-B.md`.
- For downloads, check proxy/SSL inspection for the Intune CDN endpoints, and whether large packages time out on slow links.
</details>

<details><summary>Fix 6 — Company Portal shows "Pending" after a successful install</summary>

This is a documented known issue for Available PKG and DMG apps. The admin-center report is correct. Tell the user to open Company Portal → **Devices** → this Mac → **Check status**. No other fix exists.
</details>

---
## Escalation Evidence
```
Tenant: <tenantName>     Device: <deviceName>     Intune Device ID: <deviceId>     macOS: ____
App: <appName>     Type: macOS app (PKG) / macOS app (DMG)     Assignment: Required / Available / Uninstall
Included apps (portal): <bundle.id> <version> ; ...        Ignore app version: Yes / No
On-device bundle ID / version: ______ / ______   Path: ______
Agent version: ______    pgrep IntuneMdm: ______
Error code (portal): ______   Daemon log excerpt (timestamp + lines): ______
Manual `installer -pkg` / `hdiutil attach` result: ______
Free disk: ______    FDA/PPPC profiles affecting the Intune agent: ______
Script output attached: Get-MacAgentAppStatus CSV  [ ]
```

---
## 🎓 Learning Pointers
- The PKG/DMG types are **agent** workloads, not MDM commands. If a shell script on the same Mac is also failing, fix the agent first. See `Shell-Script-Failures-B.md` and the [Intune Customer Success agent support tip](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-troubleshooting-microsoft-intune-management-agent-on-macos/4431810).
- Most "Failed but installed" tickets are **Included apps** hygiene problems. The [unmanaged PKG doc](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-unmanaged-pkg-macos) explains why every listed app must be present and why non-apps must be removed.
- The [DMG doc](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-dmg-macos) has the full 0x87D301xx error table. Bookmark it, because the admin center often shows only the code.
- Use **Ignore app version = Yes** for any app that updates itself. Otherwise Intune and the vendor's updater fight each other.
- Retiring a Mac does **not** remove agent-installed apps. Assign Uninstall (DMG) or run a removal script before you retire it.
- Deep dive: `PKG-DMG-Apps-A.md`. Collector: `Scripts/Get-MacAgentAppStatus.sh`.
