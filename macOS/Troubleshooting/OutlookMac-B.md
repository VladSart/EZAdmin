# Outlook for Mac (New vs Legacy, EWS Retirement, Profiles, Managed Preferences) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "Outlook on the Mac stopped syncing / can't add my mailbox / stuck in legacy / my policy isn't applying" in under 10 minutes.

> ⚠️ **Time-critical (October 2026):** Exchange Web Services (EWS) in Exchange Online retires **1 October 2026**. **Legacy** Outlook for Mac talks to Exchange Online over EWS, so it **stops working against Exchange Online mailboxes from October 2026**. It keeps working against Exchange on-premises (SE) mailboxes (security updates only, through 9 Oct 2029). Any Mac pinned to legacy — most often by an admin `EnableNewOutlook` = `0` or `1` profile — is a ticket waiting to happen. Source: [End of support for legacy Outlook for Mac](https://support.microsoft.com/en-us/outlook/end-of-support-for-legacy-outlook-for-mac).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run on the affected Mac **as the signed-in user** (not `sudo`):

```bash
# 1. Version (legacy vs new is a runtime mode of the SAME app, not a different app)
defaults read "/Applications/Microsoft Outlook.app/Contents/Info.plist" CFBundleShortVersionString

# 2. Is an admin profile forcing legacy / the switch? (managed prefs win over user prefs)
defaults read "/Library/Managed Preferences/com.microsoft.Outlook" EnableNewOutlook 2>/dev/null \
  || echo "No managed EnableNewOutlook"
defaults read com.microsoft.Outlook EnableNewOutlook 2>/dev/null || echo "No user-level EnableNewOutlook"

# 3. Which mode is the user actually running? (community-observed key, not in MS admin docs)
defaults read com.microsoft.Outlook IsRunningNewOutlook 2>/dev/null || echo "Key not present"

# 4. Profiles on disk
ls -1 ~/Library/Group\ Containers/UBF8T346G9.Office/Outlook/Outlook\ 15\ Profiles/ 2>/dev/null
```

Tenant side (Exchange Online PowerShell, as Exchange Admin):

```powershell
Connect-ExchangeOnline
Get-CASMailbox -Identity <UPN> | Format-List MacOutlookEnabled, EwsEnabled, OutlookMobileEnabled
Get-OrganizationConfig | Format-List EwsEnabled, EwsAllowMacOutlook
```

| Result | Meaning | Go to |
|---|---|---|
| Managed `EnableNewOutlook` = `0` or `1` and mailbox is in Exchange Online | Admin profile is holding the user in legacy (or hiding the switch); legacy breaks with EWS retirement | Fix 1 |
| `IsRunningNewOutlook` = `0` and no managed key | User toggled back to legacy themselves | Fix 1 (user toggle) |
| `MacOutlookEnabled : False` on the mailbox | **New** Outlook for Mac (Microsoft sync technology) is blocked for this mailbox | Fix 2 |
| New Outlook works but a pref (e.g. `DisableExport`) is ignored | Key needs a Configuration Profile, or wrong domain (`com.microsoft.office` vs `com.microsoft.Outlook`) | Fix 3 |
| Sign-in loop / "need admin approval" / CA block | Identity layer, not Outlook | Fix 4 |
| Profile loads but mail/folders missing, crashes at launch | Corrupt profile/cache | Fix 5 |
| Version is old (switch missing entirely) | App predates the toggle or MAU is broken | Fix 6 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Outlook for Mac mail flowing (Exchange Online mailbox)
└── Outlook is running in NEW mode (legacy = EWS = dead for EXO from Oct 2026)
    ├── No admin profile pinning legacy
    │   └── com.microsoft.Outlook EnableNewOutlook ∉ {0,1}   (2 = default, 3 = forced new/hidden)
    ├── Mailbox allows Microsoft sync technology
    │   └── Get-CASMailbox MacOutlookEnabled = True (Exchange Online-only parameter)
    ├── User can authenticate (modern auth / OAuth)
    │   ├── Licence with desktop apps (or valid LTSC activation) — see M365AppsMac-B.md
    │   ├── Conditional Access satisfied (compliant device → Company Portal registered /
    │   │   Enterprise SSO plug-in / Platform SSO)
    │   └── Keychain not corrupt
    ├── Profile healthy
    │   └── ~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/<Profile>
    └── App current
        └── Microsoft AutoUpdate (com.microsoft.autoupdate2) working
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm the mailbox location** (EXO vs on-prem decides whether legacy is fatal):
   ```powershell
   Get-EXOMailbox -Identity <UPN> -ErrorAction SilentlyContinue | Select DisplayName, RecipientTypeDetails
   ```
   Returned = Exchange Online → legacy is not a supported end state. Not found → check on-prem (`Get-Mailbox` in Exchange Management Shell); legacy still works there but new Outlook is the direction of travel.

2. **Read the effective admin preference:**
   ```bash
   defaults read "/Library/Managed Preferences/com.microsoft.Outlook" 2>/dev/null
   ```
   Expected (healthy for EXO): either no `EnableNewOutlook`, or `EnableNewOutlook = 3`. `0` = switch hidden (user is locked in whatever mode the app defaults to — historically legacy); `1` = switch shown, default **off**. Microsoft states Outlook continues to respect this admin preference — so the profile, not the app, is keeping users on legacy.

3. **Find where the profile comes from** (Intune):
   ```bash
   sudo profiles show -type configuration | grep -B3 -A12 -i "com.microsoft.Outlook"
   ```
   Note the profile's `PayloadDisplayName` and find it in Intune → Devices → macOS → Configuration (Preference file or Settings Catalog → Microsoft Office → Microsoft Outlook).

4. **Check the mailbox gate:**
   ```powershell
   Get-CASMailbox -Identity <UPN> | Format-List MacOutlookEnabled, EwsEnabled, EwsAllowMacOutlook
   ```
   `MacOutlookEnabled False` → new Outlook cannot sync this mailbox. `EwsAllowMacOutlook False` / `EwsEnabled False` only matters for legacy (and is moot for EXO after the EWS retirement).

5. **Validate after the fix:** quit Outlook (`osascript -e 'quit app "Microsoft Outlook"'`), relaunch, confirm the "Legacy Outlook" toggle is off/hidden and `defaults read com.microsoft.Outlook IsRunningNewOutlook` returns `1` (community-observed indicator), and a test message arrives.

---
## Common Fix Paths

<details><summary>Fix 1 — Move the user (or fleet) off legacy Outlook</summary>

**Single user, no admin key:** in Outlook turn **off** the *Legacy Outlook* switch (Outlook menu bar / top-right toggle). If no toggle: **Help → Check for Updates**.

**Fleet, admin key present:** change the Intune profile, don't fight it on the device.
- Intune → Devices → macOS → Configuration → edit the Outlook preference profile → set `EnableNewOutlook` to **3** (new Outlook, switch hidden) or remove the key (default `2` = switch shown, default on).
- Settings Catalog path: *Microsoft Office → Microsoft Outlook → Enable new Outlook*.

Preference-file (`.plist`) payload for Intune "Preference file" profile, domain `com.microsoft.Outlook`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>EnableNewOutlook</key><integer>3</integer>
</dict></plist>
```

Force a device check-in, then verify:
```bash
# Trigger a check-in: Intune admin center → device → Sync, or Company Portal → device → Check settings
defaults read "/Library/Managed Preferences/com.microsoft.Outlook" EnableNewOutlook
```
Rollback: set the value back / remove the key. **Do not** roll back to `0`/`1` for EXO mailboxes after 1 Oct 2026 — legacy will not connect.

On-my-computer data note: items that only live in legacy "On My Computer" folders are not migrated automatically. Export them first (**File → Export → .olm**) before switching if the user depends on them.
</details>

<details><summary>Fix 2 — Mailbox or org blocks new Outlook for Mac</summary>

```powershell
Connect-ExchangeOnline
# MacOutlookEnabled is a per-mailbox, Exchange Online-only parameter (default $true)
Set-CASMailbox -Identity <UPN> -MacOutlookEnabled $true
# Find everyone who is blocked (bulk check)
Get-CASMailbox -ResultSize Unlimited | Where-Object { -not $_.MacOutlookEnabled } | Select-Object PrimarySmtpAddress
```
If many mailboxes are blocked, look for a provisioning script or CAS mailbox plan that sets it — fixing users one-by-one will regress for new hires.
Allow up to ~60 minutes for CAS setting propagation; restart Outlook.
Rollback: `Set-CASMailbox -Identity <UPN> -MacOutlookEnabled $false`.
</details>

<details><summary>Fix 3 — Managed preference not applying</summary>

1. Wrong domain: `OfficeAutoSignIn` lives in **`com.microsoft.office`**; almost everything else in **`com.microsoft.Outlook`** (capital O).
2. Some keys are **Configuration-Profile-only** (e.g. `DisableImport`, `DisableExport`, `DisableSignatures`, `DisableTeamsMeeting`, `DisableFocusedInbox`, `DisableCalendarSharingPermissionsSetup`) — `defaults write` is ignored for these.
3. Many keys **only apply to new Outlook** (e.g. `DisableEncryptOnly`, `DisableSMIMECompose`, `DisableJunkOptionsPrefKey`) — they will look "broken" on a legacy client.
4. Key availability is version-gated (e.g. `DisableBasic` 16.93+, `FailAllCertificateErrors` 16.94+, `FocusedInboxOffByDefault` 16.95+).

```bash
defaults read "/Library/Managed Preferences/com.microsoft.Outlook"
defaults read "/Library/Managed Preferences/com.microsoft.office" 2>/dev/null
```
</details>

<details><summary>Fix 4 — Sign-in / Conditional Access failures</summary>

- Check Entra sign-in logs for the user, filter **Client app = Mobile Apps and Desktop clients**, application *Microsoft Office* / *Outlook*.
- Device-compliance CA: the Mac must be registered via Company Portal (or Platform SSO) and compliant — see `Platform-SSO-B.md` and `Compliance-Policies-B.md`.
- Clear stale Office identity cache (user context; Outlook, Word etc. closed):
```bash
osascript -e 'quit app "Microsoft Outlook"'
# List first — the numeric suffix (2/3) varies by Office build
security dump-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null | grep -i '"Microsoft Office Identities' | sort -u
security delete-generic-password -l "Microsoft Office Identities Cache 3" 2>/dev/null
security delete-generic-password -l "Microsoft Office Identities Settings 3" 2>/dev/null
```
(Repeat with the suffix you found if it differs.)
User signs in again at next launch. Non-destructive to mail data.
</details>

<details><summary>Fix 5 — Corrupt profile: create a new one with Outlook Profile Manager</summary>

```bash
osascript -e 'quit app "Microsoft Outlook"'
open "/Applications/Microsoft Outlook.app/Contents/SharedSupport/Outlook Profile Manager.app"
```
Create a new profile → **Set as Default** → launch Outlook → add the account. Keep the old profile until the user confirms nothing local is missing (legacy "On My Computer" items live only there).
Rollback: set the old profile as default again.

⚠️ Do **not** delete `~/Library/Group Containers/UBF8T346G9.Office` wholesale — it holds licensing, other Office apps' state and the Outlook profiles.
</details>

<details><summary>Fix 6 — App too old / toggle missing</summary>

```bash
MSU="/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"
"$MSU" --list
"$MSU" --install --apps OPIM2019
```
If MAU itself fails, see `M365AppsMac-B.md`.
</details>

---
## Escalation Evidence

```
Ticket: Outlook for Mac — <symptom>
User UPN:                 <UPN>
Mailbox location:         [ ] Exchange Online  [ ] Exchange on-prem  [ ] Hybrid
Outlook version:          <CFBundleShortVersionString>
Running mode:             [ ] New  [ ] Legacy   (IsRunningNewOutlook = <value>)
Managed EnableNewOutlook: <value or none>   Profile name in Intune: <name>
Get-CASMailbox:           MacOutlookEnabled=<>  EwsEnabled=<>
OrgConfig:                EwsEnabled=<>  EwsAllowMacOutlook=<>
macOS version:            <sw_vers -productVersion>
Entra sign-in log ref:    <correlation ID / request ID>
Profiles on disk:         <list>
Steps already tried:      <Fix #s>
Health script CSV:        /tmp/OutlookMacHealth_<host>_<ts>.csv (attach)
```

---
## 🎓 Learning Pointers
- Legacy vs new is a **mode of one app**, and the admin key `EnableNewOutlook` decides it — which is why fixing the Intune profile beats touching devices. Reference: [Set preferences for Outlook for Mac](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/preferences-outlook).
- The legacy break is a **server-side protocol retirement** (EWS in Exchange Online), not a client bug — no Outlook update will "fix" legacy against EXO. Read the [EWS retirement announcement](https://techcommunity.microsoft.com/t5/exchange-team-blog/retirement-of-exchange-web-services-in-exchange-online/ba-p/3924440) and scan for your other EWS dependants (`M365/Exchange/CrossTenantCalendarSharing-A.md`).
- `MacOutlookEnabled` (Exchange Online only) is the mailbox switch for **new** Outlook for Mac (Microsoft sync technology); `EwsAllowMacOutlook` only ever gated EWS-based legacy clients. Mixing them up is a common reason a "block" or "unblock" does nothing. See [Set-CASMailbox](https://learn.microsoft.com/en-us/powershell/module/exchange/set-casmailbox).
- Check the "Requires Configuration Profile" column before assuming a key is broken — `defaults write` silently loses to it.
- Deep dive with architecture and fleet audit: `OutlookMac-A.md`; device script: `../Scripts/Get-OutlookMacHealth.sh`; Exchange-side client issues: `../../M365/Exchange/Outlook-Client-A.md`.
