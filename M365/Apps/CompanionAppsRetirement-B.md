# Microsoft 365 Companion Apps Retirement (Calendar, People, Files) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

> **Source-confidence note (September 2026):** **MC1474111** (published 18 Sept 2026, Major change / Retirement) and the Learn article *Microsoft 365 companion apps retirement* (updated 17 Sept 2026).
> - Microsoft has **stopped auto-installing** the companion apps via Microsoft 365 Apps updates and has **stopped shipping updates and security fixes** for them, effective at publication.
> - **16 December 2026:** remaining installs stop working. Microsoft does **not** uninstall them for you — tenant admins are expected to remove them.
> - The apps are a single MSIX/AppX package, **`Microsoft.M365Companions`** (publisher ID `8wekyb3d8bbwe`). Uninstalling one removes all three.
> - Removing them deletes no data: calendar, contacts and files live in Exchange/SharePoint/OneDrive.

---

## Triage

Run elevated (`-AllUsers` needs admin to see every profile).

```powershell
# 1. Is the package on this device, and for whom?
Get-AppxPackage -AllUsers -Name 'Microsoft.M365Companions' |
    Select-Object Name, Version, PackageFullName, @{n='Users';e={($_.PackageUserInformation | ForEach-Object { "$($_.UserSecurityId.Username):$($_.InstallState)" }) -join '; '}}

# 2. Is it provisioned (will it land for NEW profiles)?
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.M365Companions' |
    Select-Object DisplayName, Version, PackageName

# 3. Leftover per-user data folders
Get-ChildItem "$env:SystemDrive\Users\*\AppData\Local\Packages\Microsoft.M365Companions_8wekyb3d8bbwe" -Directory -ErrorAction SilentlyContinue |
    Select-Object FullName, LastWriteTime

# 4. Is this a Click-to-Run M365 Apps device on Windows 11 (the auto-install population)?
(Get-CimInstance Win32_OperatingSystem).Caption
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue |
    Select-Object VersionToReport, UpdateChannel
```

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| No package, no provisioned package, no data folders | Clean — nothing to do on this device | Close; check fleet-wide coverage (Fix 4) |
| Package present, no Intune app entry for companions in tenant | Auto-installed via M365 Apps updates (Windows 11 + C2R) | Fix 1 (clear admin-center toggle) → Fix 3 (remove) |
| Package present **and** an Intune "Microsoft 365 companion apps" Win32 app with a **Required** assignment | Intune will reinstall after removal | Fix 2 **first**, then Fix 3 |
| Package removed yesterday, back today | Required assignment still live, or someone reinstalled from Company Portal (Available) | Fix 2, then Fix 3 again |
| Provisioned package present | Will appear for every new user profile | Fix 3 (includes `Remove-AppxProvisionedPackage`) |
| Package gone, data folder remains | Cosmetic leftover | Fix 3 clean-up step, or ignore |
| `Remove-AppxPackage` fails with 0x80073CFA / "in use" | App still running in a user session | Sign the user out or reboot, then re-run Fix 3 |
| Windows 10 device | Never auto-installed on Win10 — only present if deployed/manually installed | Fix 3 if found |

---

## Dependency Cascade

<details><summary>What must be true for the apps to be gone and STAY gone</summary>

```
Every install vector is closed
    ├── M365 Apps auto-install (Windows 11 + C2R)
    │       Microsoft stopped this at MC1474111 publication
    │       └── Admin toggle "Enable automatic installation of Microsoft 365 companion apps"
    │           (M365 Apps admin center > Device Configuration > Modern App settings)
    │           NOT auto-cleared by Microsoft → clear it yourself
    ├── Intune "Microsoft 365 companion apps" Win32 app
    │       ├── Required assignment ............ reinstalls on next check-in → delete
    │       └── Available for enrolled devices . Company Portal self-install → delete
    ├── Other ESD (ConfigMgr, RMM, golden image) → remove from package/task sequence/image
    └── User self-install ................... post-retirement, no supported source
        │
Existing installs removed
    ├── Per-user registrations ............. Remove-AppxPackage -AllUsers
    ├── Provisioned package ................ Remove-AppxProvisionedPackage -Online
    └── Running process ................... needs sign-out/restart to fully release
        │
Reporting confirms zero
    └── Intune device/user install status  OR  detection script exit 0 fleet-wide
        │
16 Dec 2026 — anything left is dead weight (unpatched since 18 Sept 2026)
```
</details>

---

## Diagnosis & Validation Flow

1. **Confirm the package on the device**
   ```powershell
   Get-AppxPackage -AllUsers -Name 'Microsoft.M365Companions' | Select-Object Version, PackageFullName
   ```
   *Expected (clean):* no output. *Present:* a row like `Microsoft.M365Companions_<ver>_x64__8wekyb3d8bbwe`. Presence on a Windows 11 C2R device with no Intune deployment = auto-install vector.

2. **Check whether Intune owns the install** (Graph, delegated, `DeviceManagementApps.Read.All`)
   ```powershell
   Connect-MgGraph -Scopes 'DeviceManagementApps.Read.All'
   $apps = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=contains(displayName,'companion')&`$expand=assignments"
   $apps.value | ForEach-Object { [pscustomobject]@{ App=$_.displayName; Type=$_.'@odata.type'; Intents=($_.assignments.intent -join ',') } }
   ```
   *Expected:* no rows, or rows with only `uninstall` intent. `required` or `available` = reinstall risk.

3. **Check the admin-center toggle** — portal only: `config.office.com` → **Device Configuration** → **Modern App settings** → **Microsoft 365 companion apps**. *Expected:* "Enable automatic installation…" **unchecked**. No Graph/PowerShell surface is documented for this setting.

4. **Check provisioning**
   ```powershell
   Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.M365Companions'
   ```
   *Expected:* no output. A row means new profiles get the app.

5. **After removal, validate**
   ```powershell
   $left = @(Get-AppxPackage -AllUsers -Name 'Microsoft.M365Companions') + @(Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.M365Companions')
   if ($left.Count -eq 0) { 'CLEAN' } else { 'STILL PRESENT'; $left }
   ```
   *Expected:* `CLEAN`. If still present, the app is running in a session — sign out/reboot and repeat.

---

## Common Fix Paths

<details><summary>Fix 1 — Clear the Microsoft 365 Apps admin center auto-install toggle</summary>

Microsoft stopped the auto-install but **did not clear the setting**. Clear it so the tenant config matches reality and nobody is confused later.

1. `https://config.office.com` → **Device Configuration** → **Modern App settings** tab.
2. Select **Microsoft 365 companion apps**.
3. Uncheck **Enable automatic installation of Microsoft 365 companion apps** → Save.

Requires Office Apps Admin or Global Admin. No rollback needed — the feature is being retired.
</details>

<details><summary>Fix 2 — Stop Intune from reinstalling (delete Required/Available assignments)</summary>

Portal: **Intune admin center → Apps → Windows → Microsoft 365 companion apps → Properties → Assignments → Edit**. Delete **Required** and **Available for enrolled devices**. If the entry doesn't exist, Intune isn't a vector.

Graph equivalent (list assignment IDs first, then delete the non-uninstall ones):

```powershell
Connect-MgGraph -Scopes 'DeviceManagementApps.ReadWrite.All'
$appId = '<companionAppId>'   # from Diagnosis step 2
$asg = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/assignments").value
$asg | Select-Object id, intent, @{n='Target';e={$_.target.'@odata.type'}}

# Delete Required / Available only
$asg | Where-Object { $_.intent -in 'required','available','availableWithoutEnrollment' } | ForEach-Object {
    Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/assignments/$($_.id)"
}
```

**Rollback:** re-add the assignment in the portal (screenshot existing groups first). Don't — the app is retiring.
</details>

<details><summary>Fix 3 — Remove from the device (all users + provisioned + leftovers)</summary>

Run elevated / as SYSTEM. This is what `Scripts/Remove-M365CompanionApps.ps1 -Remediate` does.

```powershell
$name = 'Microsoft.M365Companions'

# Per-user registrations
Get-AppxPackage -AllUsers -Name $name | ForEach-Object {
    Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
}

# Provisioned (new-profile) copy
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq $name | ForEach-Object {
    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
}

# Leftover per-user data (no M365 data lives here — cache/settings only)
Get-ChildItem "$env:SystemDrive\Users\*\AppData\Local\Packages\${name}_8wekyb3d8bbwe" -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
```

- `Remove-AppxPackage -AllUsers` requires Windows 10 1809+/Windows 11 and an elevated session.
- If a user has the app open, removal may be deferred until sign-out/restart — **expected**, not a failure (per Microsoft's guidance).

**Rollback:** none needed; the product is retired. Reinstall is not supported after retirement.
</details>

<details><summary>Fix 4 — Fleet-wide removal via Intune</summary>

**Option A — Intune app entry exists:** add an **Uninstall** assignment (All devices or All users) on the *Microsoft 365 companion apps* Win32 app, then monitor **Monitor → Device install status**.

**Option B — no Intune entry (auto-installed fleet):** deploy `Scripts/Remove-M365CompanionApps.ps1` as a **Remediation** (Devices → Scripts and remediations):

| Setting | Value |
|---------|-------|
| Detection script | `Remove-M365CompanionApps.ps1` (default mode: exits 1 if found, 0 if clean) |
| Remediation script | same file with `$Remediate` default flipped, or a one-line wrapper calling `-Remediate` |
| Run as | System, 64-bit PowerShell = Yes |
| Schedule | Daily until 16 Dec 2026 |

Remediations requires Windows Enterprise E3/E5 or equivalent licensing. Without it, use a Platform script running `-Remediate` once.
</details>

<details><summary>Fix 5 — Unmanaged / BYOD devices</summary>

Nothing you can push. Send users the steps: **Settings → Apps → Installed apps → search "Microsoft 365 companions" → … → Uninstall**, or right-click **Calendar/People/Files** in Windows Search → **Uninstall** (removing one removes all three). Microsoft's Learn article includes an email template you can adapt.
</details>

---

## Escalation Evidence

```
== M365 Companion Apps Retirement — Escalation ==
Tenant:                         <tenantName>
Device name / OS build:         <hostname> / <Win11 build>
M365 Apps version + channel:    <VersionToReport> / <channel>
Package present (Get-AppxPackage -AllUsers):   <yes/no + PackageFullName>
Provisioned package present:    <yes/no>
Intune companion app entry:     <appId or 'none'>  Assignments: <required/available/uninstall>
Admin-center auto-install toggle: <checked/unchecked>
Remove-AppxPackage error (exact): <HRESULT + message>
Reboot / sign-out attempted:    <yes/no>
Reappeared after removal?       <yes/no + timestamp>
Remediation script output CSV:  <attach>
Question for Microsoft:         <e.g. package reinstalls with no Intune/admin-center vector>
```

---

## 🎓 Learning Pointers

- **Retiring ≠ removing.** Microsoft turned off the backend and the auto-install, but left the package on devices and the admin toggle checked. Close every install vector *before* removing, or Intune puts it back. [Microsoft 365 companion apps retirement (Learn)](https://learn.microsoft.com/en-us/microsoft-365-apps/companions/companion-app-retirement)
- **It's an AppX package, not a Win32 app.** `Get-AppxPackage -AllUsers` needs elevation to see other profiles; the provisioned copy (`Get-AppxProvisionedPackage`) is a separate object and is what reinstalls it for new users. [Remove-AppxPackage](https://learn.microsoft.com/en-us/powershell/module/appx/remove-appxpackage)
- **Unpatched since 18 Sept 2026.** No security fixes ship for the remaining lifetime, so this is a hygiene item, not just UI clean-up. [MC1474111 (mc.merill.net archive)](https://mc.merill.net/message/MC1474111)
- **Remediations fit this well** — detection exits 1/0, remediation removes, daily schedule catches devices that were offline. [Remediations in Intune](https://learn.microsoft.com/en-us/intune/intune-service/fundamentals/remediations)
- Community walk-through with detection/remove scripts: [LazyAdmin — Companion apps are being retired](https://lazyadmin.nl/office-365/microsoft-365-companion-apps-are-being-retired-how-to-remove/)
- Related: Click-to-Run channel/health context in `Deployment-UpdateChannels-B.md`; the companion auto-install only ever targeted Windows 11 + C2R.
