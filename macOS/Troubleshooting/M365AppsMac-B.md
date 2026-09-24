# Microsoft 365 Apps for Mac (Install, Activation & MAU Updates) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "Office won't install / keeps asking to activate / stuck on an old build" on a managed Mac in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Almost every Microsoft 365 for Mac ticket falls into one of three buckets — **install** (Intune suite
never lands), **activation** (apps open in read-only / "Unlicensed Product" / endless sign-in loop), or
**updates** (Microsoft AutoUpdate, "MAU", not moving the build forward). Identify the bucket first —
run on the Mac (Terminal, or via a remote shell/Intune script):

```bash
# 1. Which Office apps are installed, and what build?
for a in "Microsoft Word" "Microsoft Excel" "Microsoft PowerPoint" "Microsoft Outlook" "Microsoft OneNote" "OneDrive"; do
  p="/Applications/$a.app/Contents/Info.plist"
  [ -f "$p" ] && echo "$a: $(defaults read "$p" CFBundleShortVersionString 2>/dev/null) ($(defaults read "$p" CFBundleVersion 2>/dev/null))" || echo "$a: NOT INSTALLED"
done

# 2. Is MAU present, and how is it configured?
MSU="/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"
[ -x "$MSU" ] && "$MSU" --config || echo "MAU / msupdate NOT FOUND"

# 3. Which licence type is the device carrying? (volume licence file = LTSC, not subscription)
ls -l /Library/Preferences/com.microsoft.office.licensingV2.plist 2>/dev/null || echo "No volume licence file (expected for Microsoft 365 subscription)"

# 4. macOS version (Office for Mac only receives updates on currently-supported macOS releases)
sw_vers -productVersion
```

**Interpretation table:**

| Finding | Action |
|---|---|
| All apps "NOT INSTALLED" and Intune shows the suite as Failed/Pending | Fix 1 — Intune suite delivery problem |
| Some apps installed, others missing | Fix 1 — suite assignment may be fine; check for an older standalone app package conflicting, or a user having dragged apps to Trash |
| Apps present, open in read-only / "Unlicensed Product" / "Activate Office" banner | Fix 2 — activation reset (licence removal + re-sign-in) |
| `com.microsoft.office.licensingV2.plist` exists on a device that should be **subscription** | Fix 3 — stale LTSC/volume licence is overriding the subscription licence |
| Sign-in window loops or closes immediately | Fix 4 — identity cache/keychain + SSO plug-in check |
| `msupdate --config` shows `HowToCheck = Manual` and nobody is deploying updates | Fix 5 — MAU is intentionally switched off; restore automatic checking or push updates with `msupdate --install` |
| `msupdate` errors with a privacy/XPC permission failure when run from a management tool | Fix 6 — missing PPPC pre-approval for msupdate |
| Builds are current but users complain apps were force-closed mid-work | Informational — an `UpdateDeadline.*` policy is working as designed; see Fix 7 |
| macOS version is below Microsoft's currently-supported floor | Not an Office fault — apps keep working but stop receiving updates; escalate as an OS-upgrade requirement |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Mac enrolled in Intune (MDM profile present, device checking in)
 └─ Microsoft 365 Apps for macOS suite assigned (Required / Available) to the user or device
     └─ Suite package delivered + installed into /Applications (Word, Excel, PowerPoint,
        Outlook, OneNote, OneDrive, Teams + Microsoft AutoUpdate)
         ├─ LICENSING
         │   └─ User has a Microsoft 365 licence that includes the desktop apps
         │       └─ No stale volume licence (com.microsoft.office.licensingV2.plist) overriding it
         │           └─ User signs in with work account → licence token cached per user
         │               └─ (Optional) Microsoft Enterprise SSO plug-in / Platform SSO
         │                   supplies the token silently
         └─ UPDATES
             └─ Microsoft AutoUpdate (MAU) installed, itself up to date
                 └─ com.microsoft.autoupdate2 preferences (HowToCheck, ChannelName,
                    UpdateCache, UpdateDeadline.*) as intended
                     └─ Reachability to the Office CDN (or the configured UpdateCache server)
                         └─ macOS within Microsoft's supported range for current builds
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm Intune delivery status.** Intune admin center → Apps → macOS → *Microsoft 365 Apps for macOS* → Device install status.
   - Good: *Installed* for the device.
   - Bad: *Failed* / *Not installed* with an error code → go to Fix 1.

2. **Confirm the apps on disk are Microsoft-signed and intact.**
   ```bash
   codesign -dv --verbose=2 "/Applications/Microsoft Word.app" 2>&1 | grep -E "Authority=|TeamIdentifier"
   ```
   - Good: `Authority=Developer ID Application: Microsoft Corporation (UBF8T346G9)` and `TeamIdentifier=UBF8T346G9`.
   - Bad: no signature / different team → app is damaged or not a genuine Microsoft build; reinstall (Fix 1).

3. **Confirm licence type in-app.** Open Word → *Word* menu → *About Microsoft Word*.
   - Good: "Microsoft 365 Subscription" (or "Office LTSC… Volume License" if that is intended).
   - Bad: "Volume License" on a subscription device → Fix 3. "Unlicensed Product" → Fix 2.

4. **Check MAU configuration and pending updates.**
   ```bash
   MSU="/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"
   "$MSU" --config --format plist | plutil -p - | grep -Ei "HowToCheck|ChannelName|UpdateCache|Deadline"
   "$MSU" --list
   ```
   - Good: `HowToCheck` = `AutomaticDownload` (or `AutomaticCheck`), `--list` returns nothing or updates that install cleanly.
   - Bad: `Manual` with no deployment process behind it (Fix 5); `UpdateCache` pointing at a dead internal server (Fix 5); MAU itself listed as needing an update (install MAU first — pending MAU updates block all other app updates).

5. **Check CDN reachability.**
   ```bash
   curl -sI https://officecdnmac.microsoft.com | head -1
   ```
   - Good: an `HTTP/… 200`/`3xx` response line.
   - Bad: timeout / TLS error → proxy, SSL inspection, or content filter blocking the Office CDN.

---
## Common Fix Paths

<details><summary>Fix 1 — Intune suite not installing / partially installed</summary>

1. Confirm the suite assignment targets the right user/device group and the Mac is checking in:
   ```bash
   sudo profiles status -type enrollment
   ```
2. Remove leftover partial installs that can block the suite (quit the apps first — **the Intune suite install can close open Office apps and users may lose unsaved work**):
   ```bash
   # Only if a specific app bundle is visibly broken/damaged
   sudo rm -rf "/Applications/Microsoft Excel.app"
   ```
3. Force a device check-in from Company Portal (*Check Settings* / *Sync*) or from Intune (Devices → device → *Sync*).
4. If Intune still reports failure, install the suite manually from the Microsoft-hosted package (Microsoft 365 portal → Install apps) to prove the device can install it at all, then re-sync.

Rollback: removing an `.app` only removes the app bundle; user data lives in `~/Library/Containers` and `~/Library/Group Containers/UBF8T346G9.*` and is untouched. Note that **Intune cannot uninstall the Microsoft 365 Apps for macOS suite** — removal is a manual or scripted task.
</details>

<details><summary>Fix 2 — "Unlicensed Product" / activation loop (licence reset)</summary>

1. Quit every Office app.
2. Run Microsoft's **License Removal Tool** (`https://go.microsoft.com/fwlink/?linkid=849815`) — it removes *all* Office for Mac licences on the device. Requires local admin password.
3. Reopen Word and sign in with the user's work account. If prompted to choose between a subscription and a one-time-purchase licence, choose Microsoft 365.
4. Restart the Mac after successful activation.

Scripted equivalent of the key step for a volume licence file (see Fix 3). For subscription tokens, prefer the tool/sign-out path rather than hand-deleting cache folders.

Rollback: none needed — the user simply signs in again. Make sure the user knows their credentials **before** you run the tool.
</details>

<details><summary>Fix 3 — Stale volume (LTSC) licence overriding a Microsoft 365 subscription</summary>

A device previously serialised with the Office LTSC Volume License Serializer keeps
`/Library/Preferences/com.microsoft.office.licensingV2.plist`, which takes precedence — users then miss
subscription-only features, or see volume licence wording in *About*.

```bash
# Back up, then remove the machine-wide volume licence file
sudo cp /Library/Preferences/com.microsoft.office.licensingV2.plist /tmp/licensingV2.plist.bak
sudo rm /Library/Preferences/com.microsoft.office.licensingV2.plist
```
Then reopen an Office app and sign in (or run the License Removal Tool from Fix 2 for a full reset).

Rollback: `sudo cp /tmp/licensingV2.plist.bak /Library/Preferences/com.microsoft.office.licensingV2.plist` — only if this device is genuinely meant to be LTSC.
</details>

<details><summary>Fix 4 — Sign-in window loops or closes immediately</summary>

1. Check whether the Microsoft Enterprise SSO plug-in / Platform SSO is in play and healthy (see `Platform-SSO-B.md`):
   ```bash
   app-sso platform -s 2>/dev/null | head -20
   ```
2. In Word → *Word* menu → *Sign Out*, then quit all Office apps.
3. Open **Keychain Access**, search for `Office`, and remove the cached Office identity entries for the affected user only (entries such as *Microsoft Office Identities Cache* / *Microsoft Office Identities Settings*). Do not touch unrelated keychain items.
4. Reopen Word and sign in again.

Rollback: keychain entries are rebuilt on next successful sign-in.
</details>

<details><summary>Fix 5 — MAU not updating (Manual mode, dead cache server, wrong channel)</summary>

Restore automatic behaviour for the current user context (for fleet-wide change, deploy the same keys as an Intune **Preference file** / custom configuration profile for domain `com.microsoft.autoupdate2`):
```bash
defaults write com.microsoft.autoupdate2 HowToCheck -string "AutomaticDownload"
defaults write com.microsoft.autoupdate2 ChannelName -string "Current"
defaults delete com.microsoft.autoupdate2 UpdateCache 2>/dev/null   # only if the internal cache server is gone
```
Push updates immediately:
```bash
MSU="/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"
"$MSU" --install --apps MSau04          # update MAU itself first
"$MSU" --install                         # then all apps
```
Note: settings in a **managed** configuration profile override `defaults write` — if values revert, fix the Intune profile, not the device.

Rollback: `defaults write com.microsoft.autoupdate2 HowToCheck -string "Manual"` if a third-party patching tool is meant to own updates.
</details>

<details><summary>Fix 6 — msupdate fails from Intune/management scripts (privacy/XPC prompt)</summary>

`msupdate` talks to the MAU daemon over XPC and can trigger a macOS privacy prompt the first time it runs.
Deploy a **PPPC** (Privacy Preferences Policy Control) profile that pre-approves it — Microsoft publishes
sample payloads at `github.com/pbowden-msft/MobileConfigs` (Jamf-MSUpdate). See `PPPC-B.md` for PPPC
delivery troubleshooting. Re-run the script after the profile lands:
```bash
sudo profiles -P | grep -i -B2 -A5 "TCC\|privacy"
```
</details>

<details><summary>Fix 7 — Users complaining apps closed unexpectedly (deadline enforcement)</summary>

This is MAU deadline enforcement working as configured. Check the keys:
```bash
defaults read com.microsoft.autoupdate2 2>/dev/null | grep -A3 -i deadline
```
To give users more notice, raise `UpdateDeadline.FinalCountDown` (minutes, 10–720, MAU 4.51+) or
`UpdateDeadline.DaysBeforeForcedQuit` in the managed profile. **To turn a deadline off, set the values to
`0` in the managed profile — deleting the profile does NOT remove the deadline**, because it was already
written into the user's preferences.
</details>

---
## Escalation Evidence

```
Ticket: ______________________   Engineer: ______________   Date: ____________
Device name / serial: __________________   macOS version: ___________
User UPN: ____________________________

Bucket:   [ ] Install   [ ] Activation   [ ] Updates

Intune suite status (Apps > macOS > Microsoft 365 Apps for macOS): ______________  Error code: ________
Installed app builds (Word/Excel/PPT/Outlook/OneNote/OneDrive): _________________________________
About Word licence line: ___________________________________________
Volume licence file present (/Library/Preferences/com.microsoft.office.licensingV2.plist)?  Y / N
Platform SSO / Enterprise SSO plug-in registered?  Y / N   (app-sso platform -s attached?  Y / N)
msupdate --config HowToCheck: __________  ChannelName: __________  UpdateCache: ______________
msupdate --list output attached?  Y / N
Office CDN reachable (curl -sI https://officecdnmac.microsoft.com)?  Y / N
Fixes attempted (numbers + result): ____________________________________________
Get-M365MacAppsHealth.sh CSV attached?  Y / N
```

---
## 🎓 Learning Pointers

- **The Intune suite is fire-and-forget.** Intune can install *Microsoft 365 Apps for macOS* but cannot uninstall it, and the suite has no configuration options — every app setting (MAU channel, deadlines, Outlook preferences) is delivered separately as preference files/configuration profiles. [Install Microsoft 365 Apps to macOS with Intune](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-microsoft-365-macos)
- **Licence precedence bites migrations.** A leftover LTSC `com.microsoft.office.licensingV2.plist` silently wins over a Microsoft 365 subscription — always check *About Word* before chasing "missing feature" tickets. [How to remove Office license files on a Mac](https://support.microsoft.com/en-us/microsoft-365-activation-licensing/how-to-remove-office-license-files-on-a-mac)
- **MAU updates itself first.** If MAU has a pending update, no other app updates apply — `msupdate --install --apps MSau04` is the first move on any "stuck build" ticket. [Update Microsoft applications for Mac by using msupdate](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/update-office-for-mac-using-msupdate)
- **Deadlines outlive their profile.** Removing a managed profile that set `UpdateDeadline.*` does not turn the deadline off — set the keys to `0` instead. [Set a deadline for updates from MAU](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/mau-deadline)
- **Teams isn't really MAU-managed.** Teams can fall back to MAU if its own updater fails, but you can't use `msupdate` to control Teams updates — Teams self-updates on its own cadence.
- For the deep-dive (licensing architecture, preference domains, patch-management design), see `M365AppsMac-A.md`; device-side evidence collection: `../Scripts/Get-M365MacAppsHealth.sh`.
