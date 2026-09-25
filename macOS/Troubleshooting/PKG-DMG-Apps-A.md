# macOS PKG / DMG App Deployment (Intune Agent) — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** the Intune app types **macOS app (PKG)** (unmanaged PKG) and **macOS app (DMG)**, both installed by the Microsoft Intune management agent for macOS. Also covered: choosing between these and the managed **macOS LOB app** type.
- **Out of scope:** VPP/App Store apps (`VPP-App-Deployment-A.md`, `VPP-DDM-A.md`), the Microsoft 365 Apps suite (`M365AppsMac-A.md`), shell-script failures (`Shell-Script-Failures-A.md`), and packaging or notarization itself (`Gatekeeper-Notarization-A.md`).
- **Assumes:** Intune-enrolled Macs (ADE or user-approved), admin rights in Intune, and `sudo` access on a test Mac.
- **Sources:** [Add an unmanaged macOS PKG app](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-unmanaged-pkg-macos) and [Add a macOS DMG app](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-dmg-macos) (both ms.date 2026-04-14); [Troubleshooting the Intune management agent on macOS](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-troubleshooting-microsoft-intune-management-agent-on-macos/4431810) (Intune Customer Success, July 2025).

---
## How It Works
<details><summary>Full architecture</summary>

**1. Three package paths, two delivery engines.**

| Intune app type | Delivered by | Package rules | Uninstall assignment | Typical use |
|---|---|---|---|---|
| macOS LOB app (managed PKG) | **MDM protocol** (`InstallEnterpriseApplication`, run by macOS `mdmclient`) | Signed (Developer ID Installer) distribution PKG, payload in `/Applications` | Yes (managed) | Clean, vendor-signed single-app PKGs |
| **macOS app (PKG)** (unmanaged) | **Intune agent** (`IntuneMdmDaemon`, root) | Anything `installer -pkg` accepts: unsigned, component, non-flat, payload-free, scripted, outside `/Applications` | **No** (Required/Available only) | Complex vendor installers, agents, drivers, security tools |
| **macOS app (DMG)** | **Intune agent** | DMG containing ≥1 `.app`; the app is copied to `/Applications` | Yes | Drag-to-install apps (Chrome, Zoom, Slack builds) |

Both agent types allow up to **8 GB** per package.

**2. The agent.** The management agent (`/Library/Intune/Microsoft Intune Agent.app`) installs automatically when the Mac receives its first agent workload: a shell script, custom compliance or attribute script, PKG, or DMG. It runs two processes:
- `IntuneMdmDaemon` runs as root. It downloads and installs apps and runs root scripts. Its logs are `/Library/Logs/Microsoft/Intune/IntuneMDMDaemon*.log`.
- `IntuneMdmAgent` runs in the user session for user-context scripts. Its logs are `~/Library/Logs/Microsoft/Intune/IntuneMDMAgent*.log`.

The agent checks in with the Intune service on its own schedule, roughly every 8 hours. It also checks in when it starts and when the user selects **Check status** in Company Portal. Failed installs are retried at the next check-in while the assignment remains. Daemon log lines are **pipe-delimited into 6 columns**, so `awk -F'|'` is the fastest way to slice them.

**3. The install pipeline, agent types.**
```
check-in → policy (app list + detection rules + requirements)
   │
   ├─ Requirements: Minimum OS ─── fail → 0x87D30137
   ├─ Detection (pre-check): Included apps present at version? ── yes → report Installed, stop
   ├─ Download from Intune CDN ─── fail → 0x87D30131/32
   ├─ PKG: pre-install script ── non-zero → 2016214710 (retry next check-in)
   │       installer -pkg <file> -target /
   │       post-install script (result NOT reported)
   ├─ DMG: hdiutil attach ── fail → 0x87D30139 ; no .app → 0x87D3013E
   │       copy .app → /Applications ── fail → 0x87D3013B / 0x87D30135 / 0x87D3013A
   └─ Detection (post-check): ALL Included apps found → Installed ; else Failed
```

**4. Detection is the contract.** The **Included apps** list (bundle ID + version) is the only detection mechanism. Rules to follow:
- List **only applications** that the package installs. Exclude frameworks, helpers and plug-ins. For DMG, exclude anything not installed in `/Applications`.
- **All** listed apps must be present, or the status is *Failed* even though the package installed.
- The **first** listed app is the one reports use. The list can be reordered.
- **Ignore app version = Yes** checks bundle ID presence only. Use it for any self-updating app. **No** means Intune reinstalls whenever the on-disk version doesn't match the uploaded version, which is how a vendor auto-update gets "downgraded".
- For DMG **Uninstall** assignments, *Ignore app version* also decides the match. **No** requires both bundle ID and version to match before removal.

**5. Updates.**
- **DMG:** edit the app and upload a new DMG with the **same bundle ID**. This needs agent 2304.039+. Required assignments update automatically. For Available, the user selects Reinstall in Company Portal.
- **PKG:** upload the new version. Available apps update without any user action, per the PKG documentation. With *Ignore app version = No*, Required devices converge on the uploaded version.
- **Permissions:** on macOS 13+, updating or deleting DMG apps needs **Full Disk Access**. Intune requests it automatically when a DMG policy is assigned.

**6. Lifecycle gaps.** Retiring a device does **not** remove agent-installed apps. PKG apps can't be uninstalled through an assignment. Use a script or a DMG Uninstall assignment before you retire the device.

**7. Known issues (Learn, as of Sept 2026).** Company Portal shows *Pending* for Available PKG/DMG apps after a successful install; *Check status* clears it. Some DMG apps trigger a Gatekeeper "downloaded from the internet" prompt on first launch. DMG failure reports may show only the error code until you refresh the page. The *Collect logs* action isn't available for DMG apps.
</details>

---
## Dependency Stack
```
L8  Reporting: Included apps detected (first entry = report identity)
L7  Post-install (PKG script; not reported)
L6  Install: installer -pkg (PKG) | hdiutil + copy to /Applications (DMG)
L5  Pre-install script exit 0 (PKG, agent ≥ 2309.007)
L4  Local resources: disk space, /Applications writable, FDA for DMG update/delete (macOS 13+)
L3  Download from Intune CDN (≤ 8 GB), network/proxy
L2  Requirements: Minimum OS
L1  Intune agent installed & checking in (PKG ≥ 2308.006; DMG update ≥ 2304.039)
L0  MDM enrollment + assignment (group targeting, filters)
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| App never installs, no log lines | Agent absent/not checking in, or assignment not targeted | `pgrep -il "^IntuneMdm"`; group membership; Check status |
| Installed on disk, Intune says Failed | Included apps lists a non-app or an app that isn't installed, or version mismatch | `defaults read …/Info CFBundleIdentifier / CFBundleShortVersionString` |
| App keeps reinstalling / reverting version | Ignore app version = No on a self-updating app | Detection rules tab |
| 2016214710 | PKG pre-install script non-zero | Run the script as root, check `$?` |
| Post-install steps missing but status Installed | Post-install script failed (not reported) | Daemon log |
| 0x87D30137 | Below Minimum OS | `sw_vers` |
| 0x87D3013E | DMG has no `.app` (e.g. contains a PKG) | `hdiutil attach` + `ls` |
| 0x87D30139 | DMG won't mount (corrupt, SLA, encrypted) | `hdiutil verify` |
| 0x87D3013B / 0x87D30135 | Can't write to /Applications, or device error | `ls -ld /Applications`; disk |
| 0x87D3013A | Disk full or corrupt payload | `df -h /` |
| 0x87D30131 / 0x87D30132 | Download failed (network/size) | Proxy, SSL inspection, link speed |
| 0x87D3012F/30/33/34/36 | Internal agent error | Manual install test; recreate app object; escalate |
| DMG update or uninstall fails on macOS 13+ | Full Disk Access not granted to the agent | PPPC profiles; System Settings → Privacy |
| Company Portal "Pending" forever | Known issue for Available PKG/DMG | Admin center status; Check status |
| Unmanaged PKG app not removed at retire | By design | Removal script before retire |

---
## Validation Steps
1. **Agent running.** `pgrep -il "^IntuneMdm"` lists `IntuneMdmDaemon`. Bad: nothing listed.
2. **Agent version meets the feature floor.** `defaults read "/Library/Intune/Microsoft Intune Agent.app/Contents/Info" CFBundleShortVersionString` returns ≥ 2309.007 for PKG scripts. Bad: lower, which means the agent is stale (it self-updates on check-in).
3. **Package installs by hand.** `sudo installer -pkg app.pkg -target /` prints `installer: The install was successful.` Bad: any error, which means the package itself is broken regardless of Intune.
4. **DMG mounts and contains an app.** `hdiutil attach -nobrowse app.dmg` followed by `ls /Volumes/<vol>/*.app` returns a path. Bad: no `.app`, or a mount error.
5. **Detection matches.** Every Included apps entry resolves with `mdfind "kMDItemCFBundleIdentifier == '<id>'"`, and the version matches or *Ignore app version* is set. Bad: any entry missing.
6. **Log outcome.** The daemon log shows the install followed by a success/detected state for the app. Bad: an error code line (see the map above).

---
## Troubleshooting Steps (by phase)
**Phase 1: Targeting and check-in.** In the portal, check that Device → Managed apps lists the app. On the Mac, run Company Portal → Check status, then watch the log with `tail -f` on the newest IntuneMDMDaemon log.

**Phase 2: Agent health.** Check that the processes are running and the version is current. Restart them with `sudo killall IntuneMdmDaemon` (launchd relaunches it). If shell scripts are also failing, treat it as an agent problem first.

**Phase 3: Requirements and download.** Check Minimum OS, then network reachability to the Intune CDN, including large-file timeouts on Wi-Fi and SSL inspection.

**Phase 4: Install mechanics.** For PKG, run the pre-install script manually and then `installer -pkg -verboseR`, and check `/var/log/install.log` for the package's own errors. For DMG, run `hdiutil verify` and `hdiutil attach`, check for the `.app`, and check write access to `/Applications`.

**Phase 5: Detection.** Compare the Included apps list against the on-disk Info.plist values. Remove non-apps, fix the versions, and consider *Ignore app version*.

**Phase 6: Lifecycle.** For updates, check the same bundle ID and the agent ≥ 2304.039 (DMG). Check FDA on macOS 13+. For removal, PKG can't be uninstalled through Intune, so script it.

---
## Remediation Playbooks
<details><summary>Playbook 1 — Choose the right app type</summary>

- **Signed distribution PKG, single app into /Applications** → **LOB (managed)**. This gives native MDM tracking and managed removal.
- **Unsigned, component, or scripted PKG, or payload outside /Applications** (security agents, printer drivers, VPN clients) → **macOS app (PKG)**.
- **Drag-install DMG** → **macOS app (DMG)**. If the DMG wraps a PKG, extract it: `hdiutil attach x.dmg && cp /Volumes/X/*.pkg ~/Desktop/`, then use the PKG type.
- Check your tooling first. Some community packagers (for example IntuneBrew) and the Enterprise App Catalog already ship detection metadata that has been checked.
</details>

<details><summary>Playbook 2 — Build a correct Included apps list</summary>

```bash
# From a Mac where the package has been installed:
for APP in "/Applications/<App One>.app" "/Applications/<App Two>.app"; do
  printf "%s | %s | %s\n" "$APP" \
    "$(defaults read "$APP/Contents/Info" CFBundleIdentifier)" \
    "$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
done
# List what a PKG will lay down, before installing:
pkgutil --payload-files /path/to/app.pkg | grep -E '\.app/Contents/Info\.plist$'
```
Enter the parent app first. Remove every non-`.app` entry. Set *Ignore app version = Yes* if the vendor auto-updates.
</details>

<details><summary>Playbook 3 — Gate installs with a pre-install script (PKG)</summary>

```zsh
#!/bin/zsh
# Exit non-zero to defer install until a condition is met; Intune retries at next check-in.
# Example: wait until no user has the app open.
if pgrep -xq "<ProcessName>"; then
  echo "App running - deferring install"; exit 1
fi
exit 0
```
Keep it under 15,360 characters (agent ≥ 2309.007). Note that this deferral shows up as **2016214710** in reports. Tell the service desk that this is expected.
</details>

<details><summary>Playbook 4 — Recover a stuck agent (destructive only to agent state)</summary>

```bash
sudo killall IntuneMdmDaemon 2>/dev/null; killall IntuneMdmAgent 2>/dev/null
sleep 10; pgrep -il "^IntuneMdm"
# Last resort: remove the agent app so it is re-pushed on next MDM check-in (requires an agent workload assignment)
# sudo rm -rf "/Library/Intune/Microsoft Intune Agent.app"
```
Rollback: the agent reinstalls automatically. Scripts and apps are re-evaluated, so scripts set to run once may run again. Check script frequency settings before you remove the agent.
</details>

<details><summary>Playbook 5 — Remove agent-installed apps before retire</summary>

- **DMG:** assign **Uninstall**, which removes the app from `/Applications`. Wait for it to report, then retire.
- **PKG:** deploy a shell script that removes the payload (`pkgutil --files <pkg-id>` shows what to delete) and runs `pkgutil --forget <pkg-id>`. Test it on a lab Mac first, because the deletion is irreversible.
</details>

---
## Evidence Pack
Run `sudo bash macOS/Scripts/Get-MacAgentAppStatus.sh --bundle-id <bundle.id>`. It writes a CSV to `/tmp` and prints a tarball path containing the Intune agent logs. To collect by hand:
```bash
OUT=/tmp/MacAgentEvidence_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
cp /Library/Logs/Microsoft/Intune/*.log "$OUT/" 2>/dev/null
cp /var/log/install.log "$OUT/" 2>/dev/null
sw_vers > "$OUT/sw_vers.txt"; df -h / > "$OUT/df.txt"
pgrep -il "^IntuneMdm" > "$OUT/processes.txt"
profiles show -type configuration > "$OUT/profiles.txt" 2>&1
tar -czf "$OUT.tgz" -C /tmp "$(basename "$OUT")" && echo "$OUT.tgz"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Agent processes | `pgrep -il "^IntuneMdm"` |
| Agent version | `defaults read "/Library/Intune/Microsoft Intune Agent.app/Contents/Info" CFBundleShortVersionString` |
| Restart agent | `sudo killall IntuneMdmDaemon` |
| Live daemon log | `sudo tail -f "$(ls -t /Library/Logs/Microsoft/Intune/IntuneMDMDaemon*.log \| head -1)"` |
| Error codes in logs | `sudo grep -h "0x87D30" /Library/Logs/Microsoft/Intune/IntuneMDMDaemon*.log` |
| Bundle ID of installed app | `defaults read "/Applications/X.app/Contents/Info" CFBundleIdentifier` |
| Version of installed app | `defaults read "/Applications/X.app/Contents/Info" CFBundleShortVersionString` |
| Find app anywhere by bundle ID | `mdfind "kMDItemCFBundleIdentifier == '<id>'"` |
| Test PKG install | `sudo installer -pkg app.pkg -target / -verboseR` |
| Apps inside a PKG | `pkgutil --payload-files app.pkg \| grep '\.app/Contents/Info.plist$'` |
| Installed receipts | `pkgutil --pkgs \| grep -i <vendor>` |
| Test DMG | `hdiutil verify app.dmg; hdiutil attach -nobrowse app.dmg` |
| Installer log | `tail -100 /var/log/install.log` |
| Disk / OS | `df -h /; sw_vers` |

---
## 🎓 Learning Pointers
- [Add an unmanaged macOS PKG app](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-unmanaged-pkg-macos) covers exactly which package shapes need the PKG type rather than LOB, plus the pre/post-install script semantics (only pre-install can fail the install).
- [Add a macOS DMG app](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-dmg-macos) has the complete 0x87D301xx troubleshooting table and the FDA and update-agent version requirements.
- [macOS LOB apps aren't deployed (Learn troubleshooting)](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/macos-lob-apps-not-deployed) is the counterpart for the MDM-delivered path.
- [Support tip: Troubleshooting the Intune management agent on macOS](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-troubleshooting-microsoft-intune-management-agent-on-macos/4431810) explains the 6-column pipe-delimited log format and how to watch it live.
- Community: [IntuneBrew docs: Troubleshooting common macOS app deployment issues](https://docs.intunebrew.com/docs/Troubleshooting-Common-macOS-App-Deployment-Issues-in-Intune). It's useful for real-world detection patterns.
- Related: `Shell-Script-Failures-A.md` (same agent), `PPPC-A.md` (FDA), `Gatekeeper-Notarization-A.md` (first-launch prompts).
