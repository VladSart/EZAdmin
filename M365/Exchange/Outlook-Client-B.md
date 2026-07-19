# Outlook Desktop Client — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers profile/Autodiscover failures, connection status loops, and OST corruption.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

```powershell
# 1. Which Outlook is this? (fix paths differ completely between the two)
Get-AppxPackage -Name "Microsoft.OutlookForWindows" -EA SilentlyContinue | Select Name, Version
# Output present = New Outlook installed. Ask the user to check the top-right
# toggle switch to confirm which one is actually in use right now.

# 2. Status bar state (classic Outlook — bottom of window or Send/Receive tab)
# Connected to: Microsoft Exchange   → not a connectivity issue, look elsewhere
# Trying to connect...               → auth token issue
# Disconnected                       → credential identity mismatch
# Needs Password (loops on retry)    → stale token OR Conditional Access block

# 3. Quick Autodiscover DNS check
Resolve-DnsName -Name "autodiscover.<domain>" -Type CNAME -EA SilentlyContinue

# 4. Is the .ost file actually updating?
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook\*.ost" | Select Name, LastWriteTime, Length

# 5. Does it work in Outlook on the web? (isolates client vs. server/mailbox issue)
# Ask user to try https://outlook.office.com directly
```

**Interpret immediately:**

| Symptom | Quick check | Go to |
|---------|-------------|-------|
| Can't create profile at all / new profile builds as IMAP | Autodiscover CNAME missing, or root-domain webhost hijack | [Fix 1](#fix-1--cant-create-profile--profile-builds-as-imap) |
| Status = Disconnected | Multiple mailboxes in profile, credential identity mismatch | [Fix 2](#fix-2--status-shows-disconnected) |
| Status = Trying to connect / repeated password prompt | Stale OAuth token in Credential Manager | [Fix 3](#fix-3--trying-to-connect--repeated-password-prompt) |
| Needs Password but correct password loops | Conditional Access blocking the sign-in | [Fix 4](#fix-4--conditional-access-blocking-sign-in) |
| Folders won't expand, search broken, random crashes | `.ost` corruption | [Fix 5](#fix-5--ost-corruption) |
| Hangs on launch or a specific action (send/print/invite) | COM add-in conflict | [Fix 6](#fix-6--com-add-in-conflict) |
| New Outlook: broken UI, blank panes, or on-prem/hosted mailbox missing calendar/delegates | WebView2/cache corruption, or expected New-Outlook IMAP degradation for non-EXO mailboxes | [Fix 7](#fix-7--new-outlook-specific-issues) |
| Works in OWA, fails only in desktop Outlook | Confirmed client-layer issue — proceed through fixes above | — |
| Fails in OWA too | Not a desktop client issue — check mailbox/licensing/CA, not this runbook | Escalate to `Mail-Flow-B.md` / licensing checks |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Correct client identified: classic Outlook vs New Outlook]
  ✗ These share NO troubleshooting mechanisms — confirm before proceeding
        │
        ▼
[Autodiscover resolves the mailbox endpoint]
  v2 JSON → v1 XML (autodiscover CNAME) → root domain probe → SCP (hybrid) → SRV
  ✗ Missing/wrong CNAME → profile creation fails
  ✗ Root domain answered by a third-party web host → profile builds as IMAP/POP
        │
        ▼
[Modern Auth token obtained and cached]
  Classic: Windows Credential Manager (WAM broker)
  New Outlook: managed server-side, no local Credential Manager entry
  ✗ Conditional Access blocks the sign-in outright (legacy auth, risky sign-in, location)
  ✗ Stale/corrupted cached token → connect loop
        │
        ▼
[Local cache layer — classic Outlook only]
  .ost file (Cached Exchange Mode) — disposable, rebuilds from server
  ✗ Corruption → folders won't expand, search broken, crashes
        │
        ▼
[Add-ins load (classic Outlook only)]
  ✗ A hung/incompatible COM add-in can block startup or a specific action entirely
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm client type**
```powershell
Get-AppxPackage -Name "Microsoft.OutlookForWindows" -EA SilentlyContinue
```
Good: clear answer either way before touching any fix. Bad: guessing — New Outlook and classic Outlook fixes do not overlap.

**Step 2 — Isolate client vs. server**
Ask the user to sign into `https://outlook.office.com`. If OWA also fails, stop — this is not a desktop client issue.

**Step 3 — Autodiscover test (no admin rights needed, browser-based)**
```
https://testconnectivity.microsoft.com/tests/o365 → Microsoft 365 tab → Outlook Autodiscover
```
Good: "Connectivity Test Successful," endpoint is `outlook.office365.com` or tenant-specific. Bad: test fails, or results contain `<Type>IMAP</Type>` for a domain that should be pure Exchange Online.

**Step 4 — Check Conditional Access sign-in result (admin, if auth loop suspected)**
```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<upn>' and appDisplayName eq 'Microsoft Office'" -Top 10 |
  Select CreatedDateTime, Status, ConditionalAccessStatus, ClientAppUsed
```
Good: recent successes, `ConditionalAccessStatus = success` or `notApplied`. Bad: `failure`, especially with a legacy `ClientAppUsed` value.

**Step 5 — Check the OST file freshness**
```powershell
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook\*.ost" | Select Name, LastWriteTime, Length
```
Good: `LastWriteTime` recent relative to active use. Bad: stale timestamp, zero-byte file, or Outlook itself flags it unreadable.

---
## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — Can't create profile / profile builds as IMAP</summary>

```powershell
# Confirm the CNAME
Resolve-DnsName -Name "autodiscover.<domain>" -Type CNAME -EA SilentlyContinue
# Expected: points to autodiscover.outlook.com (cloud-only) or the hybrid endpoint
```

If the CNAME is missing/wrong: correct it at the DNS host. Propagation up to 48h, usually much faster.

If the CNAME is correct but the Remote Connectivity Analyzer test showed `<Type>IMAP</Type>`: this is the root-domain webhost-hijack pattern (KB3049615). Interim-only workaround (must be removed once the hosting side is fixed):

```powershell
$regPath = "HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover"
New-Item -Path $regPath -Force | Out-Null
New-ItemProperty -Path $regPath -Name "ExcludeHttpsRootDomain" -PropertyType DWord -Value 1 -Force
Write-Host "Restart Outlook. Remove this key once the hosting provider stops answering Autodiscover at the root domain." -ForegroundColor Yellow
```

⚠️ Not a permanent fix — the real resolution is on the web hosting provider's side. Escalate.

</details>

<details id="fix-2"><summary>Fix 2 — Status shows Disconnected</summary>

**Symptom:** Status bar reads "Disconnected"; usually a profile with more than one mailbox where at least one uses a different sign-in account than the user's Windows identity.

```powershell
Get-Process OUTLOOK -EA SilentlyContinue | Stop-Process -Force
Get-ChildItem "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles" | Select PSChildName
```

Fastest reliable fix — **recreate the profile** (this is Microsoft's documented resolution for this specific symptom, not a workaround):

```
Control Panel → Mail (32-bit) → Show Profiles → Add → create new profile,
add the mailbox, set as default → confirm Connected status → remove old profile
```

Try clearing credentials first if you want a non-destructive attempt before rebuilding (see Fix 3) — it resolves this in some but not most Disconnected cases.

</details>

<details id="fix-3"><summary>Fix 3 — Trying to connect / repeated password prompt</summary>

```powershell
Get-Process OUTLOOK -EA SilentlyContinue | Stop-Process -Force

# List Office-related cached credentials
cmdkey /list | Select-String -Pattern "MicrosoftOffice|SSPI|OUTLOOK"

# Remove the stale entry (repeat per match)
cmdkey /delete:"MicrosoftOffice16_Data:SSPI:<GUID-from-listing>"
```

Relaunch Outlook — it will prompt for a fresh sign-in and cache a new valid token.

If a VPN is in use: disconnect fully, close Outlook, cycle Wi-Fi/network adapter, reconnect, relaunch — rule out a transport issue before concluding this is purely an auth-cache problem.

If clearing credentials doesn't resolve it after two attempts, go to Fix 2 (profile recreation) — some token-cache corruption survives a Credential Manager clear.

Microsoft's own diagnostic tool for this exact symptom: `aka.ms/SaRA-OutlookPwdPrompt` (Support and Recovery Assistant).

</details>

<details id="fix-4"><summary>Fix 4 — Conditional Access blocking sign-in</summary>

**Symptom:** Password is correct, prompt keeps reappearing, or user gets an access-denied page instead of a password box.

```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<upn>'" -Top 5 |
  Select CreatedDateTime, ConditionalAccessStatus, AppliedConditionalAccessPolicies, ClientAppUsed
```

If `ClientAppUsed` shows a legacy value (`Other clients`, `Exchange ActiveSync`, `POP3`, `IMAP4`, `SMTP`) against a tenant that blocks legacy authentication: the client (often an old Outlook build, or a phone/third-party app on the same mailbox) is attempting a blocked protocol. Confirm Outlook build is current — legacy Outlook 2013/earlier without modern auth cannot satisfy CA-gated sign-in.

If a specific named CA policy shows `Failure` in `AppliedConditionalAccessPolicies`: this is a policy design/scope question, not a client fix — escalate to `Security/ConditionalAccess/CA-Troubleshooting-B.md`.

</details>

<details id="fix-5"><summary>Fix 5 — OST corruption</summary>

```powershell
Get-Process OUTLOOK -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

$ostFiles = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook\*.ost"
foreach ($ost in $ostFiles) {
    Rename-Item -Path $ost.FullName -NewName "$($ost.Name).old" -Force
    Write-Host "Renamed: $($ost.Name)" -ForegroundColor Green
}
Write-Host "Relaunch Outlook — it rebuilds the .ost from the server." -ForegroundColor Yellow
```

⚠️ Warn the user first if they have unsent drafts that only exist locally — anything not yet synced to the server at close time can be lost. Large mailboxes (10+ GB) can take 30-60+ minutes to fully resync.

Do not bother with `SCANPST.EXE` for OST corruption on an Exchange-connected mailbox — the mailbox on the server is authoritative; rebuild is faster and more reliable than structural repair.

</details>

<details id="fix-6"><summary>Fix 6 — COM add-in conflict</summary>

```powershell
Start-Process "outlook.exe" -ArgumentList "/safe"
```

If the issue disappears in Safe Mode, isolate via **File → Options → Add-ins → Manage: COM Add-ins → Go...** — disable add-ins one at a time, restarting normally (not `/safe`) between each, until the issue returns.

```powershell
# List installed COM add-ins and load behavior for reference
Get-ItemProperty "HKCU:\Software\Microsoft\Office\Outlook\Addins\*" -EA SilentlyContinue |
  Select @{N='AddinName';E={$_.PSChildName}}, LoadBehavior, FriendlyName
```

Check the vendor for an updated build before assuming the add-in is simply broken — business-critical add-ins (CRM, e-signature, compliance archivers) are frequently just behind on Outlook compatibility updates.

</details>

<details id="fix-7"><summary>Fix 7 — New Outlook specific issues</summary>

**First, rule out expected behavior:** if the affected mailbox is on-premises Exchange, hosted/third-party Exchange, or hybrid and not yet migrated to Exchange Online, New Outlook treats it as generic IMAP by design — no calendar, no delegate access, no shared mailbox support. This is not a bug. Fix: have the user switch back to classic Outlook (toggle, top-right corner) for that mailbox.

For a genuine EXO mailbox with a broken New Outlook UI or sync:

```powershell
# Repair first (least destructive)
Start-Process "ms-settings:appsfeatures-app" -ArgumentList "Microsoft.OutlookForWindows"
# Settings > Apps > Installed apps > Outlook (New) > ... > Advanced options > Repair
# If Repair fails, use Reset from the same page (clears local app data)
```

If repair/reset doesn't resolve it, clear the local cache folders directly:

```powershell
Get-Process olk -EA SilentlyContinue | Stop-Process -Force
foreach ($p in @("$env:LOCALAPPDATA\Microsoft\Olk", "$env:LOCALAPPDATA\Microsoft\OneAuth")) {
    if (Test-Path $p) { Rename-Item -Path $p -NewName "$(Split-Path $p -Leaf).old" -Force }
}
Write-Host "Relaunch New Outlook — it rebuilds config and re-prompts for sign-in." -ForegroundColor Yellow
```

No local mailbox data is lost — New Outlook's cache is cloud-backed, not a local source of truth.

</details>

---
## Escalation Evidence

```
Outlook Client Issue — Evidence Pack
=====================================
Tenant:
Affected user (UPN):
Client type:                   [Classic Outlook / New Outlook — from Get-AppxPackage check]
Outlook build:                 [Help/Account > About Outlook, or Settings > About for New Outlook]
Status bar state:               [Connected / Trying to connect / Disconnected / Needs Password]
Fails in OWA too?:             [Y/N — if Y, this is not a client issue]
Autodiscover CNAME result:     [Resolve-DnsName output]
Remote Connectivity Analyzer:  [pass/fail, any <Type>IMAP</Type> hit]
Conditional Access sign-in:    [ConditionalAccessStatus + ClientAppUsed from Get-MgAuditLogSignIn]
.ost LastWriteTime:            [timestamp + size]
COM add-ins installed:         [list, if add-in conflict suspected]
Steps already tried:
```

---
## 🎓 Learning Pointers

- **Classic Outlook and New Outlook share zero troubleshooting mechanisms.** No Credential Manager entries, no `.ost`, no COM add-ins, no Windows Mail profile for New Outlook — confirm which client you're looking at in the first 30 seconds or you'll waste the whole ticket. [MS Support — Feature comparison](https://support.microsoft.com/en-us/office/feature-comparison-between-new-outlook-and-classic-outlook-de453583-1e76-48bf-975a-2e9cd2ee16dd)
- **The `.ost` file is meant to be thrown away.** It's a disposable cache of the authoritative server-side mailbox. Rename-and-relaunch beats structural repair every time for an Exchange-connected mailbox.
- **"Disconnected" ≠ "Needs Password."** Disconnected is a credential-identity mismatch (fix: recreate the profile). Needs Password looping is a stale token or a Conditional Access block (fix: clear credentials, or check sign-in logs) — don't jump straight to a profile rebuild for the wrong symptom.
- **New Outlook degrading a hybrid/on-prem mailbox to generic IMAP is expected, not a defect.** Don't spend a ticket "fixing" it — switch the user back to classic Outlook for that mailbox. Full detail in `Outlook-Client-A.md`'s How It Works section.
- **KB3049615 (root-domain Autodiscover hijack) is a DNS/hosting-provider problem, not an Outlook bug** — the registry workaround is explicitly temporary per Microsoft. Escalate the actual fix rather than leaving the workaround in place indefinitely. [MS Learn — Issues when using Autodiscover service](https://learn.microsoft.com/en-us/troubleshoot/exchange/outlook-issues/issues-when-using-autodiscover-service)
