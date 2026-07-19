# Outlook Desktop Client — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Profile creation and Autodiscover resolution (v2 JSON, v1 XML, SCP, DNS fallback chain)
- Connection status states (Connected / Trying to connect / Disconnected / Needs Password)
- Modern Authentication token/credential issues (Credential Manager cache, ADAL/MSAL token corruption)
- OST file corruption, cached mode resync, and profile rebuild
- The classic Outlook vs. New Outlook for Windows architectural split, and what breaks when a device silently switches
- Add-in interference (COM add-ins, Safe Mode isolation)
- Client-side symptoms that are actually server/tenant-side (CA blocking legacy auth, mailbox move, licensing)

**Does not cover:**
- Mailbox-side mail flow, NDRs, transport rules — see `Mail-Flow-A.md`
- Shared mailbox permissions/AutoMapping mechanics — see `SharedMailbox-A.md` (this runbook covers the client connectivity layer AutoMapping depends on)
- Hybrid on-prem Exchange server administration — see `Hybrid-Coexistence-A.md`
- Outlook on the web (OWA), Outlook Mobile (iOS/Android) — different clients, different failure domains
- Conditional Access policy design — see `Security/ConditionalAccess/CA-Design-A.md` (this runbook covers what CA-blocked legacy auth *looks like* client-side)

**Assumed role:** L2/L3 desktop support or Exchange administrator. Local admin access to the affected device for most fixes; Exchange Online admin access (`Connect-ExchangeOnline`) for server-side confirmation steps.

**Versions:** Classic Outlook for Windows (Microsoft 365 Apps, Current/Monthly Enterprise/Semi-Annual Channel) and New Outlook for Windows. Exchange Online mailboxes only — on-premises Exchange/hybrid connectivity notes are called out explicitly where they diverge.

---

## How It Works

<details><summary>Full architecture</summary>

### Two clients, two architectures — the split that drives every triage decision

As of 2026, "Outlook for Windows" is not one product. There are two, and confusing which one a user is running is the single most common reason a fix path fails:

| | Classic Outlook | New Outlook for Windows |
|---|---|---|
| Runtime | Native Win32 (MAPI/RPC, local rendering) | WebView2 — a wrapped instance of the Outlook on the web engine running in a native window |
| Local cache | `.ost` file in Cached Exchange Mode; `.pst` import/export supported | Cloud-based cache; no `.ost`, no `.pst` import support |
| Add-ins | COM add-ins (VSTO, legacy) + web add-ins | Web add-ins only — **COM add-ins are not supported at any level** |
| Profile model | Windows Mail profile (registry-based, `Show Profiles`) | No profile concept — account list managed inside the app itself |
| Non-EXO mailboxes (on-prem Exchange, hosted Exchange, hybrid) | Full MAPI feature set — delegates, shared mailboxes, calendar free/busy, public folders | Treated as a **generic IMAP account** — no calendar integration, no shared mailbox handling, no delegate access, no Copilot |
| Authentication | Classic Windows auth broker (WAM) + ADAL/MSAL token cache in Credential Manager | Cloud-native OAuth via Microsoft's identity platform, tokens managed server-side |

**Why this matters for triage:** a fix that's correct for classic Outlook — clearing Credential Manager entries, rebuilding a `.ost` file, running Outlook in Safe Mode to isolate a COM add-in — does nothing for New Outlook, because none of those mechanisms exist in it. Conversely, "reinstall/repair the app via Windows Settings" is the primary New Outlook fix path and is largely irrelevant for classic Outlook profile corruption. **Always establish which client is in play before touching anything** (see Validation Step 1).

**Retirement timeline (why both still matter in 2026):** Microsoft's plan to make New Outlook the default has slipped repeatedly — the opt-out phase for classic Outlook (where it stops being offered by default to new profiles) has moved to March 2027, and classic Outlook continues to be supported through 2029 for Microsoft 365 Apps subscription channels and perpetual/LTSC licensing. **Any customer running hybrid Exchange, on-premises Exchange, or a third-party-hosted Exchange mailbox should not be moved to New Outlook** — it silently degrades those mailboxes to generic IMAP with no calendar, delegate, or shared mailbox support. This is a support-ticket generator disguised as a feature migration; flag it proactively for hybrid customers.

### Autodiscover — the profile-creation dependency

Autodiscover is how Outlook turns an email address into a working profile without the user typing server names. For Exchange Online, resolution is attempted in roughly this order (Outlook stops at the first success):

1. **Autodiscover v2 (JSON)** — a direct REST-style query to the Exchange Online Autodiscover v2 endpoint (`autodiscover-s.outlook.com/autodiscover/autodiscover.json?Email=<address>`). This is the primary path for cloud-only mailboxes and does not strictly require a customer-side DNS record if the domain is a verified Microsoft 365 accepted domain — Microsoft's own directory resolves it.
2. **Autodiscover v1 (XML) via the domain's own namespace** — `https://autodiscover.<domain>/autodiscover/autodiscover.xml`, which requires the `autodiscover` CNAME record pointing at `autodiscover.outlook.com` (or the hybrid on-prem endpoint, if federated).
3. **Root domain XML probe** — `https://<domain>/autodiscover/autodiscover.xml`. This step is the source of the classic "third-party web host answers first" failure (KB3049615, see Symptom → Cause Map) — if the domain's own website responds instead of failing cleanly, Outlook misinterprets that response as an Autodiscover answer and tries to build an IMAP/POP profile instead of Exchange.
4. **Service Connection Point (SCP)** — on-premises/hybrid, domain-joined machines only. AD holds a published SCP object pointing at the on-prem Autodiscover endpoint; irrelevant for cloud-only, non-domain-joined machines.
5. **DNS SRV record fallback** — `_autodiscover._tcp.<domain>`, a last-resort path rarely needed once the CNAME is correctly published.

Once Autodiscover succeeds, it returns the mailbox's actual service endpoint (which may differ from the domain used to sign in, especially after a cross-forest/tenant-to-tenant mailbox move) and the protocol to use (EWS/REST for modern Outlook, never POP/IMAP for a genuine Exchange Online mailbox).

### Cached Exchange Mode and the OST file

By default, classic Outlook operates in **Cached Exchange Mode**: a local `.ost` file (Offline Storage Table) at `%LOCALAPPDATA%\Microsoft\Outlook\<mailbox>.ost` holds a synchronized copy of the mailbox, so the client can render folders instantly and work offline. The OST is a cache, not a source of truth — the mailbox on the server is authoritative. This is the single most important fact for OST troubleshooting: **the OST can always be safely deleted and rebuilt from the server**, with the caveat that anything not yet synced upward (very recent drafts, just-sent items in a slow-sync scenario) can be lost. Corruption symptoms — folders that won't expand, search returning stale or no results, "the file <mailbox>.ost is not an Outlook data file", repeated crash-on-launch — are almost always resolved by closing Outlook, renaming or deleting the OST, and letting Outlook rebuild it on next launch. `SCANPST.EXE` (the Inbox Repair Tool) exists and can technically run against an OST, but it was designed for PST structural repair; for an Exchange-connected mailbox, resyncing from the server is faster and more reliable than attempting a structural repair of a file that's disposable by design.

### Credential Manager and the modern-auth token cache

Modern Authentication (OAuth 2.0 via the Microsoft identity platform) replaced Basic Auth for Exchange Online mailbox access; Basic Auth for MAPI/EWS/RPC-over-HTTP has been fully retired tenant-wide, meaning **any client still attempting Basic Auth will fail outright**, not just show a warning. On successful sign-in, classic Outlook's Windows Account Manager (WAM) broker stores a refresh token via **Windows Credential Manager**, under entries generally named `MicrosoftOffice16_Data:SSPI:<GUID>` or similar. When this cached token becomes invalid — password changed elsewhere, admin revoked sessions, Conditional Access session/sign-in-frequency policy expired it, or the token is simply corrupted — Outlook enters a **"Trying to connect…" / repeated password prompt** loop, because it keeps presenting the same stale cached credential instead of forcing a fresh interactive sign-in. Clearing the relevant Credential Manager entries (not all of them — scope to Outlook/Office entries) forces a clean re-authentication.

### "Disconnected" status specifically

"Disconnected" in the Outlook status bar most often means the *cached credential's account identity doesn't match the account Windows thinks is signed in* — this is a documented issue when more than one mailbox is added to a profile and at least one uses a sign-in account different from the user's Windows sign-in account. Office miscommunicates with Windows and Windows silently substitutes the default credential, which then fails silently against the non-default mailbox. The supported fix is profile recreation, not credential clearing (though clearing credentials is worth trying first since it's non-destructive and faster).

</details>

---

## Dependency Stack

```
User opens Outlook / adds an account
        │
        ▼
[Which client? classic Outlook (Win32/MAPI) vs New Outlook (WebView2)]
        │  ← establishes which fix-path universe applies (see How It Works table)
        ▼
[Autodiscover resolution]
  v2 JSON (cloud) → v1 XML (autodiscover.<domain> CNAME) → root domain probe →
  SCP (domain-joined + on-prem/hybrid only) → DNS SRV fallback
        │  ✗ CNAME missing/wrong, root domain webhost hijack, SCP tenant mismatch
        ▼
[Modern Authentication / OAuth token]
  WAM broker → Microsoft identity platform → refresh token cached in
  Windows Credential Manager (classic) or managed server-side (New Outlook)
        │  ✗ Conditional Access blocks legacy/basic auth outright
        │  ✗ Stale/corrupted cached token → repeated password prompt or Disconnected
        ▼
[Exchange Online mailbox endpoint]
  Returned by Autodiscover; may differ from sign-in domain after a mailbox move
        │
        ▼
[Local profile / cache layer — classic Outlook only]
  Windows Mail profile (registry) ──► .ost file (Cached Exchange Mode)
        │  ✗ Profile registry corruption → won't launch / settings won't save
        │  ✗ .ost corruption → folders won't expand, search broken, crash-on-launch
        ▼
[Add-ins]
  COM add-ins (classic only) can hang startup, break send, corrupt the UI
        │  ✗ Isolate via Safe Mode (outlook.exe /safe)
        ▼
Mail renders / sync completes
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Can't create a new profile at all; wizard fails immediately | Autodiscover failure — CNAME missing or root-domain webhost hijack | Test Autodiscover via `testconnectivity.microsoft.com` → Outlook Connectivity |
| New profile created as **IMAP** instead of Exchange | Root domain Autodiscover probe hijacked by third-party web host (KB3049615) | Search the connectivity test results for `<Type>IMAP</Type>` |
| Status bar shows **"Disconnected"** | Mismatched cached credential vs. Windows sign-in identity (multi-mailbox profile) | Recreate the Outlook profile |
| Status bar shows **"Trying to connect…"** indefinitely, repeated password prompts | Stale/corrupted OAuth token in Credential Manager | Clear Outlook/Office entries in Windows Credential Manager |
| **"Needs Password"** appears but entering the correct password loops | Conditional Access blocking the auth flow (legacy auth attempt, blocked location/device) | Check Entra sign-in logs for this UPN — look for a CA `Failure` with the interrupted-flow reason |
| Folders won't expand / search returns nothing or stale results / random crashes | `.ost` file corruption | Close Outlook, rename/delete the `.ost`, relaunch to rebuild |
| Outlook hangs on launch, or a specific action (send, print, meeting invite) always hangs | COM add-in conflict (classic Outlook only) | Launch `outlook.exe /safe` — if it launches clean, isolate the add-in |
| Shared/on-prem/hosted-Exchange mailbox has no calendar, no delegate access, behaves like a plain inbox | User is on **New Outlook** connecting to a non-EXO mailbox — treated as generic IMAP | Confirm client type (toggle top-right, or `HKCU...\Outlook\IsNewOutlook` equivalent registry check) |
| New Outlook UI broken, blank panes, won't render | WebView2 runtime or cached New Outlook state corrupted | Repair/Reset via Windows Settings → Apps; clear `%localappdata%\Microsoft\Olk` and `OneAuth` |
| Works fine in OWA, fails only in Outlook desktop | Client-specific issue (Autodiscover, token, OST, add-in) — not a mailbox/server problem | Isolate to desktop client before going further |
| User was recently migrated (tenant-to-tenant, cross-forest, on-prem→cloud) and profile suddenly fails | Autodiscover now resolves to a new mailbox endpoint; old cached profile pointer is stale | Delete and recreate the profile — do not attempt to "repair" a post-migration profile |
| Free/busy fails for one mailbox only, everything else fine | That mailbox not yet reachable via current Autodiscover chain (e.g. still transitioning off/onto hybrid) | Retest Autodiscover for that specific SMTP address |

---

## Validation Steps

**1. Identify which Outlook client is actually running**
```powershell
# Classic Outlook: check installed build via registry
Get-ItemProperty "HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\General" -EA SilentlyContinue

# New Outlook: presence of the package (WebView2-based app)
Get-AppxPackage -Name "Microsoft.OutlookForWindows" -EA SilentlyContinue | Select Name, Version, InstallLocation

# Fastest field method: ask the user to look at the top-right toggle switch —
# only New Outlook has a "Try/Toggle New/Classic Outlook" switch
```
_Good:_ You know definitively which client is affected before choosing a fix path.
_Bad:_ Applying a classic-Outlook OST/profile fix to a WebView2-based New Outlook install — it will do nothing.

**2. Check Outlook status bar / connection state (classic Outlook)**
Bottom of the Outlook window, or **Send/Receive** tab. Look for: `Connected to: Microsoft Exchange`, `Trying to connect...`, `Disconnected`, or `Needs Password`.
_Good:_ `Connected to: Microsoft Exchange`
_Bad:_ Any other state — map it in the Symptom → Cause Map above.

**3. Test Autodiscover independently of the client**
```
https://testconnectivity.microsoft.com/tests/o365 → Microsoft 365 tab →
Outlook Autodiscover test → supply SMTP address + UPN (real password not required
for this test — no authentication against M365 occurs)
```
_Good:_ "Connectivity Test Successful", endpoint returned is an `outlook.office365.com` / tenant-specific EXO endpoint.
_Bad:_ Test fails outright, or results contain `<Type>IMAP</Type>` (root-domain webhost hijack) or `<Type>POP3</Type>`.

**4. Check the `autodiscover` DNS CNAME for the domain**
```powershell
Resolve-DnsName -Name "autodiscover.contoso.com" -Type CNAME
```
_Good:_ Resolves to `autodiscover.outlook.com` (cloud-only) or the correct hybrid endpoint.
_Bad:_ NXDOMAIN, or resolves to an unrelated third-party host (webhosting/parking page provider) — root-domain hijack risk.

**5. Confirm Modern Authentication is enabled tenant-wide (admin-side)**
```powershell
Connect-ExchangeOnline -UserPrincipalName <adminUPN>
Get-OrganizationConfig | Select OAuth2ClientProfileEnabled
```
_Good:_ `True` — this has been the default/required state for years; `False` indicates an unusual legacy override.
_Bad:_ `False`, or the mailbox/user is caught by a Conditional Access policy blocking modern auth clients unexpectedly.

**6. Check Windows Credential Manager for stale Office entries**
```
Control Panel → Credential Manager → Windows Credentials →
look for entries starting with "MicrosoftOffice16_Data:SSPI:" or containing the affected UPN
```
_Good:_ Entries present and recent; if the user just re-authenticated successfully, timestamps are fresh.
_Bad:_ Entries reference an old/incorrect UPN, or removing and letting Outlook recreate them resolves the loop — confirms this was the cause.

**7. Check the `.ost` file (classic Outlook, Cached Exchange Mode only)**
```powershell
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook\*.ost" | Select Name, Length, LastWriteTime
```
_Good:_ File exists, `LastWriteTime` is recent (actively syncing), size is reasonable for mailbox content.
_Bad:_ File is stale (`LastWriteTime` far in the past despite active use), zero bytes, or Outlook itself reports it as unreadable.

**8. Check for Conditional Access interference (server-side)**
```powershell
# Requires Microsoft Graph PowerShell + AuditLog.Read.All
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<upn>' and appDisplayName eq 'Microsoft Office'" -Top 10 |
  Select CreatedDateTime, Status, ConditionalAccessStatus, AppDisplayName, ClientAppUsed
```
_Good:_ `ConditionalAccessStatus = notApplied` or `success`, recent successful sign-ins present.
_Bad:_ `ConditionalAccessStatus = failure`, especially with `ClientAppUsed` showing a legacy protocol (`Other clients`, `Exchange ActiveSync`) — the client is attempting an auth method CA blocks.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm client type and isolate to desktop vs. server

1. Run Validation Step 1 to confirm classic vs. New Outlook.
2. Confirm the same mailbox works correctly in Outlook on the web (OWA). If OWA also fails, this is **not** a desktop-client issue — redirect to `Mail-Flow-A.md` (delivery) or mailbox/licensing checks, not this runbook.
3. If OWA works but desktop doesn't, continue below — the problem is isolated to the client layer.

### Phase 2 — Autodiscover failures (can't create profile, or profile builds as IMAP/POP)

1. Run Validation Steps 3 and 4.
2. If the connectivity test shows an IMAP/POP response from the root domain: this is the KB3049615 hijack pattern. The permanent fix is on the web-hosting side (the third-party host must stop answering Autodiscover requests at the root domain) — see Remediation Playbook 1 for the interim registry workaround.
3. If the CNAME is simply missing or wrong, correct the DNS record with the domain registrar/DNS host — propagation can take up to 48 hours, though typically much faster.
4. If domain-joined and using SCP-based hybrid discovery, verify the SCP object's tenant/endpoint matches current configuration (cross-reference `EntraID/Troubleshooting/HybridJoin-A.md` for SCP validation mechanics — the SCP object is shared infrastructure between HAADJ and hybrid Autodiscover).

### Phase 3 — Authentication loops (Trying to connect / Needs Password / Disconnected)

1. Run Validation Steps 5, 6, and 8 in order — confirm it's not a tenant-side Conditional Access block before touching the client.
2. If CA is not the cause, clear the relevant Windows Credential Manager entries (Remediation Playbook 2) — this is non-destructive and the fastest fix for a stale token.
3. If clearing credentials doesn't resolve it, or the status is specifically **"Disconnected"** (not "Needs Password"), go straight to profile recreation (Remediation Playbook 3) — this is the Microsoft-documented fix for the credential-identity-mismatch cause of Disconnected status.
4. If a VPN is in use, disconnect it fully, close Outlook, cycle the network adapter, and relaunch before concluding this is an auth issue rather than a transport issue.

### Phase 4 — OST corruption (folders won't expand, search broken, crashes)

1. Run Validation Step 7.
2. Close Outlook completely (confirm via Task Manager — `OUTLOOK.EXE` fully exited, not just window closed).
3. Rename (don't delete outright, in case rollback is needed) the `.ost` file per Remediation Playbook 4.
4. Relaunch Outlook — it rebuilds the OST from the server. Resync time scales with mailbox size; large mailboxes (10+ GB) can take 30-60+ minutes on first resync.

### Phase 5 — Add-in interference (classic Outlook only)

1. Launch `outlook.exe /safe` (Remediation Playbook 5).
2. If the issue disappears in Safe Mode, re-enable add-ins one at a time via **File → Options → Add-ins → COM Add-ins → Go...** to isolate the culprit.
3. Disable or update the offending add-in; if it's a business-critical add-in (CRM, e-signature, compliance archiver), check the vendor for a build compatible with the current Outlook version before assuming it's simply broken.

### Phase 6 — New Outlook specific issues

1. Confirm the affected mailbox type — if it's on-premises Exchange, a hosted-Exchange reseller, or a hybrid mailbox not yet migrated to EXO, **New Outlook's IMAP-style treatment is expected behavior, not a bug**. The fix is to have the user switch back to classic Outlook (toggle, top-right) rather than troubleshoot New Outlook further.
2. For genuine EXO mailboxes with a broken New Outlook UI/sync: repair via Windows Settings (Remediation Playbook 6) before attempting cache clearing.
3. If repair doesn't resolve it, clear the New Outlook cache folders (`Olk`, `OneAuth`) per Remediation Playbook 6 — this forces a full reconfiguration on next launch.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Root domain Autodiscover hijack workaround (interim only)</summary>

**Use only as a stopgap while the actual fix (web host stops answering root-domain Autodiscover requests) is in progress.**

```powershell
# Exclude the HTTPS root domain from the Autodiscover lookup chain
# Run in the affected user's context (HKCU), not HKLM
$regPath = "HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover"
New-Item -Path $regPath -Force | Out-Null
New-ItemProperty -Path $regPath -Name "ExcludeHttpsRootDomain" -PropertyType DWord -Value 1 -Force
New-ItemProperty -Path $regPath -Name "ExcludeHttpRedirect"     -PropertyType DWord -Value 1 -Force
New-ItemProperty -Path $regPath -Name "ExcludeSrvRecord"        -PropertyType DWord -Value 1 -Force

Write-Host "Registry keys set. Restart Outlook for the change to take effect." -ForegroundColor Yellow
Write-Host "IMPORTANT: remove these keys once the web host stops answering Autodiscover at the root domain." -ForegroundColor Red
```

**Rollback:**
```powershell
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover" -Name "ExcludeHttpsRootDomain" -EA SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover" -Name "ExcludeHttpRedirect" -EA SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover" -Name "ExcludeSrvRecord" -EA SilentlyContinue
```

⚠️ Not a long-term solution — Microsoft explicitly documents this as temporary relief only (KB3049615). Escalate the actual DNS/hosting fix.

</details>

<details><summary>Playbook 2 — Clear stale Windows Credential Manager entries</summary>

```powershell
# Close Outlook first — credentials in active use can't be cleared cleanly
Get-Process OUTLOOK -EA SilentlyContinue | Stop-Process -Force

# List Office/Outlook-related stored credentials (read-only listing)
cmdkey /list | Select-String -Pattern "MicrosoftOffice|SSPI|OUTLOOK"

# Remove a specific stale entry (repeat per matching entry — do not blanket-clear
# unrelated credentials on a shared/multi-user device)
cmdkey /delete:"MicrosoftOffice16_Data:SSPI:<GUID-from-listing>"
```

Relaunch Outlook — it will prompt for a fresh interactive sign-in and rebuild a valid token.

**Rollback:** None needed — this only removes cached tokens; Outlook always re-obtains them on next sign-in. No data loss.

</details>

<details><summary>Playbook 3 — Recreate the Outlook profile (classic Outlook)</summary>

```powershell
# Close Outlook first
Get-Process OUTLOOK -EA SilentlyContinue | Stop-Process -Force

# List existing profiles
Get-ChildItem "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles" | Select PSChildName

# Recommended: create a NEW profile rather than editing the broken one in place
# via Control Panel → Mail (32-bit) → Show Profiles → Add
# Set "Always use this profile" to the new one, or leave "Prompt for a profile
# to be used" if the user manages multiple mailboxes/profiles

# Once the new profile is confirmed working, the old broken profile can be removed:
# Control Panel → Mail → Show Profiles → select old profile → Remove
```

**Rollback:** Keep the old profile until the new one is confirmed stable for a few days — removing a profile does not touch server-side mailbox data, only the local profile pointer/cache.

</details>

<details><summary>Playbook 4 — Rebuild a corrupted OST file</summary>

```powershell
# Close Outlook completely first
Get-Process OUTLOOK -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

$ostFiles = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook\*.ost"
foreach ($ost in $ostFiles) {
    $renamed = "$($ost.FullName).old"
    Rename-Item -Path $ost.FullName -NewName $renamed -Force
    Write-Host "Renamed: $($ost.Name) -> $(Split-Path $renamed -Leaf)" -ForegroundColor Green
}

Write-Host "Relaunch Outlook. It will rebuild the .ost from the server automatically." -ForegroundColor Yellow
Write-Host "Once the new .ost is confirmed healthy and fully synced, the .old file can be deleted." -ForegroundColor Yellow
```

**Rollback:** If the rebuild goes wrong (e.g. wrong account context), stop Outlook, delete the newly created broken `.ost`, and rename the `.old` file back to its original name — this restores the previous (corrupted) state, which is only useful if you need to preserve it for forensic reasons; normally just let the rebuild complete.

⚠️ Anything not yet synced to the server at the moment Outlook was closed (very recent drafts held only locally) can be lost. Warn the user before proceeding if they mention unsent drafts.

</details>

<details><summary>Playbook 5 — Isolate a COM add-in via Safe Mode</summary>

```powershell
# Launch Outlook in Safe Mode (disables all COM add-ins for this session only)
Start-Process "outlook.exe" -ArgumentList "/safe"

# If the issue disappears in Safe Mode, list installed COM add-ins for triage
Get-ItemProperty "HKCU:\Software\Microsoft\Office\Outlook\Addins\*" -EA SilentlyContinue |
  Select @{N='AddinName';E={$_.PSChildName}}, LoadBehavior, FriendlyName

# LoadBehavior 3 = loads at startup. Disable a specific add-in without uninstalling it:
# File > Options > Add-ins > Manage: COM Add-ins > Go... > uncheck the add-in
```

**Rollback:** Re-check the add-in's checkbox in the COM Add-ins dialog to re-enable it — no data or configuration is lost by disabling an add-in.

</details>

<details><summary>Playbook 6 — Repair / reset New Outlook and clear its cache</summary>

```powershell
# Step 1: Repair via Windows Settings (do this first — least destructive)
Start-Process "ms-settings:appsfeatures-app" -ArgumentList "Microsoft.OutlookForWindows"
# Manually: Settings > Apps > Installed apps > "Outlook (New)" > ... > Advanced options > Repair
# If Repair doesn't resolve it, use Reset from the same page (this clears app data,
# equivalent to a fresh install — user will need to re-add accounts)

# Step 2 (if repair/reset alone doesn't fix it): clear New Outlook's local cache folders
Get-Process olk -EA SilentlyContinue | Stop-Process -Force

$olkPath     = "$env:LOCALAPPDATA\Microsoft\Olk"
$oneAuthPath = "$env:LOCALAPPDATA\Microsoft\OneAuth"

foreach ($path in @($olkPath, $oneAuthPath)) {
    if (Test-Path $path) {
        Rename-Item -Path $path -NewName "$(Split-Path $path -Leaf).old" -Force
        Write-Host "Renamed: $path" -ForegroundColor Green
    }
}

Write-Host "Relaunch New Outlook — it will rebuild configuration data and re-prompt for sign-in." -ForegroundColor Yellow
```

**Rollback:** New Outlook has no local mailbox data to lose (it's cloud-cached) — resetting only clears local app configuration/UI state, which rebuilds automatically on next sign-in.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS Collect Outlook desktop client diagnostic evidence for escalation
.NOTES Run ON the affected device. No admin rights required for most checks.
#>
param(
    [string]$OutputPath = "$env:TEMP\OutlookClient-Evidence"
)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# Client type + build
Get-AppxPackage -Name "Microsoft.OutlookForWindows" -EA SilentlyContinue |
    Select Name, Version | Export-Csv "$OutputPath\new-outlook-package.csv" -NoTypeInformation
Get-ItemProperty "HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\General" -EA SilentlyContinue |
    Out-File "$OutputPath\classic-outlook-registry.txt"

# Profiles
Get-ChildItem "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles" -EA SilentlyContinue |
    Select PSChildName | Export-Csv "$OutputPath\profiles.csv" -NoTypeInformation

# OST files
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook\*.ost" -EA SilentlyContinue |
    Select Name, Length, LastWriteTime, CreationTime |
    Export-Csv "$OutputPath\ost-files.csv" -NoTypeInformation

# Credential Manager Office entries (names only — never export secret material)
cmdkey /list | Select-String -Pattern "MicrosoftOffice|SSPI|OUTLOOK" |
    Out-File "$OutputPath\credential-manager-entries.txt"

# Installed COM add-ins
Get-ItemProperty "HKCU:\Software\Microsoft\Office\Outlook\Addins\*" -EA SilentlyContinue |
    Select @{N='AddinName';E={$_.PSChildName}}, LoadBehavior, FriendlyName |
    Export-Csv "$OutputPath\com-addins.csv" -NoTypeInformation

# DNS Autodiscover record for the primary SMTP domain
$domain = Read-Host "Enter the SMTP domain to test (e.g. contoso.com)"
try {
    Resolve-DnsName -Name "autodiscover.$domain" -Type CNAME -EA Stop |
        Out-File "$OutputPath\autodiscover-dns.txt"
} catch {
    "Resolution failed: $($_.Exception.Message)" | Out-File "$OutputPath\autodiscover-dns.txt"
}

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
Write-Host "Attach: testconnectivity.microsoft.com Autodiscover test results (manual, browser-based) alongside this pack." -ForegroundColor Yellow
Invoke-Item $OutputPath
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Confirm New Outlook installed | `Get-AppxPackage -Name "Microsoft.OutlookForWindows"` |
| List classic Outlook profiles | `Get-ChildItem "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles"` |
| Find the active `.ost` file | `Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook\*.ost"` |
| Launch classic Outlook in Safe Mode | `outlook.exe /safe` |
| List Office Credential Manager entries | `cmdkey /list \| Select-String "MicrosoftOffice\|SSPI"` |
| Remove a stale credential | `cmdkey /delete:"<TargetName>"` |
| Check tenant-wide OAuth/modern auth state | `Get-OrganizationConfig \| Select OAuth2ClientProfileEnabled` |
| Pull recent sign-ins for a user (needs Graph) | `Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<upn>'" -Top 10` |
| Resolve the Autodiscover CNAME | `Resolve-DnsName -Name "autodiscover.<domain>" -Type CNAME` |
| List COM add-ins and load behavior | `Get-ItemProperty "HKCU:\Software\Microsoft\Office\Outlook\Addins\*"` |
| Repair New Outlook | Settings → Apps → Installed apps → Outlook (New) → Advanced options → Repair |
| SaRA — password prompt loop diagnostic | `aka.ms/SaRA-OutlookPwdPrompt` |
| Remote Connectivity Analyzer (Autodiscover test) | `testconnectivity.microsoft.com/tests/o365` |

---

## 🎓 Learning Pointers

- **Establish the client (classic vs. New Outlook) before doing anything else.** The two are architecturally unrelated — different runtimes, different local storage models, different auth broker behavior. A ticket that starts "Outlook won't connect" without confirming which client is running wastes time applying fixes from the wrong universe. [MS Support — Feature comparison between new Outlook and classic Outlook](https://support.microsoft.com/en-us/office/feature-comparison-between-new-outlook-and-classic-outlook-de453583-1e76-48bf-975a-2e9cd2ee16dd)

- **New Outlook silently degrades non-EXO mailboxes — this is by design, not a bug to fix.** Hybrid, on-premises Exchange, and third-party-hosted Exchange mailboxes lose calendar integration, shared mailbox handling, and delegate access under New Outlook because it treats anything that isn't a native Exchange Online mailbox as generic IMAP. For MSP clients still mid-hybrid-migration or on hosted Exchange long-term, proactively keep users on classic Outlook rather than troubleshooting New Outlook's reduced feature set as if it were broken.

- **The OST file is disposable by design — stop trying to repair it structurally.** Cached Exchange Mode exists specifically so the local cache can be thrown away and rebuilt from the authoritative server copy. `SCANPST.EXE` targets PST structural issues; for OST corruption on an Exchange-connected mailbox, rename-and-resync is faster, more reliable, and lower-risk than attempting repair. [MS Learn — Outlook performance issues in Cached Exchange Mode](https://learn.microsoft.com/en-us/troubleshoot/outlook/performance/performance-issues-if-too-many-items-or-folders)

- **"Disconnected" and "Needs Password" are not the same failure and don't share a fix path.** Disconnected typically means a credential-identity mismatch in a multi-mailbox profile (Microsoft's documented fix: recreate the profile). Needs Password / Trying to connect typically means a stale or invalid cached OAuth token (fix: clear Credential Manager entries first — much less disruptive than a full profile rebuild). Diagnosing which one you're looking at before acting saves a rebuild that wasn't needed. [MS Learn — Outlook disconnected after enabling modern authentication](https://learn.microsoft.com/en-us/troubleshoot/outlook/authentication/outlook-shows-disconnected-after-enabling-modern-authentication)

- **The root-domain Autodiscover hijack (KB3049615) is a DNS/hosting problem wearing an Outlook costume.** If Remote Connectivity Analyzer results contain `<Type>IMAP</Type>` for a domain that's genuinely on Exchange Online, the real fix is getting the domain's web hosting provider to stop answering Autodiscover probes at the root domain — the registry workaround is explicitly documented by Microsoft as temporary relief, not a resolution. Don't let this one linger as a permanent registry hack. [MS Learn — Issues when using Autodiscover service](https://learn.microsoft.com/en-us/troubleshoot/exchange/outlook-issues/issues-when-using-autodiscover-service)

- **Classic Outlook isn't going away as fast as the marketing suggested — plan client-standardization projects accordingly.** The opt-out-by-default milestone has already slipped to March 2027, and classic Outlook remains supported through 2029 for Microsoft 365 Apps subscription channels and LTSC. There's no urgency to force every user onto New Outlook today, and doing so for hybrid/on-prem-Exchange users actively breaks functionality — weigh this before running a tenant-wide "switch everyone to New Outlook" rollout.
