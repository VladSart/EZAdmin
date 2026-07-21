# Legacy LAPS → Windows LAPS Migration — Reference Runbook (Mode A: Deep Dive)
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

- **Applies to:** Devices previously managed by legacy Microsoft LAPS (the .msi-based product, AD-only, plaintext `ms-Mcs-AdmPwd`) that are being moved to Windows LAPS (built into Windows 10 22H2+ KB5025221 / Windows 11 22H2+), whether AD-backed or Entra-backed.
- **Distinct from:** `LAPS-A.md`/`LAPS-B.md`, which cover steady-state Windows LAPS operation via Intune (rotation, retrieval, policy delivery) and explicitly exclude legacy LAPS. This runbook covers **the transition itself** — the migration mechanics, the legacy emulation-mode behavior that operates in the gap, and safe removal of the old product.
- **Does not cover:** macOS LAPS, third-party local-admin-password tools, or Entra-only tenants that never had legacy LAPS deployed (nothing to migrate).
- **Admin roles needed:** Domain Admin or delegated GPO-edit rights (legacy side); Intune Administrator or Device Configuration Administrator (Windows LAPS via Intune); local admin on target devices for direct verification.

---

## How It Works

<details><summary>Full architecture — precedence, emulation mode, and attribute coexistence</summary>

### The core architectural fact that drives everything else

Windows LAPS is **built into the operating system** on Windows 10 22H2+ (with KB5025221) and Windows 11 22H2+. It is not a separately-installed agent that is either present or absent — the engine is always there, always evaluating, the moment a device is joined to either Microsoft Entra ID or Windows Server Active Directory. This is the single fact every migration mistake in this domain traces back to: teams reason about Windows LAPS as if it were an opt-in feature they "haven't turned on yet," when in reality it is already running and making a decision about what to do.

### The precedence order Windows LAPS evaluates, in exact order

```
1. Is a real Windows LAPS policy present on this device?
   (Delivered via CSP/MDM, Group Policy Object, or even raw registry edit —
    the delivery mechanism does not matter to this check.)

   → YES: This policy is used. Full stop. A legacy Microsoft LAPS GPO,
          if also present, is ignored unconditionally. This is true even
          on a domain controller.

   → NO: proceed to step 2.

2. Is the legacy Microsoft LAPS Group Policy Client-Side Extension (CSE)
   — AdmPwd.dll — installed on this device?

   → YES: Legacy Microsoft LAPS governs the managed account exactly as
          it always has. Windows LAPS remains dormant for this account.

   → NO: proceed to step 3.

3. Windows LAPS automatically enters LEGACY MICROSOFT LAPS EMULATION MODE.
   It reads the legacy-shaped GPO settings (if any legacy GPO is still
   linked and applicable) and manages the specified account under the
   legacy attribute (ms-Mcs-AdmPwd, cleartext), with all Windows-LAPS-only
   features (encryption, Entra backup, custom account creation flags not
   present in legacy LAPS) forced to their disabled/default state.
```

Step 3 is the surprising one. It means: uninstalling the legacy CSE (a common first "cleanup" instinct) *without* first putting a Windows LAPS policy in place does not stop password management — it silently hands control to Windows LAPS's own emulation of the legacy behavior. The account keeps getting managed, using the old plaintext attribute, exactly as before, except now via a different code path that most engineers don't know exists. Emulation mode is detectable — it logs a **10023** event to the `Microsoft-Windows-LAPS/Operational` log detailing the active configuration — but nobody looks for it if they don't know to.

### How the CSE presence check actually works

Windows LAPS does not check "is the LAPS.msi package installed" in any registry uninstall-key sense. It specifically checks for the legacy CSE's Group Policy Client-Side Extension registration:

```
HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}
    DllName = <path to AdmPwd.dll>
```

If the `DllName` value is present **and points to a file that exists on disk**, legacy Microsoft LAPS is considered installed (the file's contents are never validated/loaded for this check — presence is sufficient). If the value is missing, or points to a file that no longer exists, Windows LAPS treats legacy LAPS as absent and proceeds to the emulation-mode decision.

### Why emulation mode has hard limitations, not just soft ones

Because Windows LAPS doesn't literally run the old AdmPwd code — it's reimplementing legacy-compatible behavior in the new engine — several legacy-only management operations simply cannot be performed by Windows LAPS, even in emulation mode:

| Legacy operation | Who can still do it |
|---|---|
| Extend the AD schema with legacy attributes (`ms-Mcs-AdmPwd*`) | Only legacy LAPS's own `Update-AdmPwdADSchema` — Windows LAPS's `Update-LapsADSchema` only adds the **modern** `msLAPS-*` attributes |
| Install/manage the legacy GPO ADMX definitions | Only legacy LAPS installed on a management client/DC |
| Manage legacy AD ACLs (e.g., computer self-permission to write `ms-Mcs-AdmPwd`) | Only legacy LAPS's `Set-AdmPwdComputerSelfPermissions` |
| Read/write legacy attributes from ADUC's property page | Not supported by either the legacy attribute display or Windows LAPS's ADUC page |

Practically: you cannot bootstrap a *brand-new* legacy LAPS deployment using only Windows LAPS tooling. Emulation mode only works because the legacy schema/ACLs/GPO definitions **already exist** from when legacy LAPS was actually deployed and administered.

### Attribute coexistence during migration

| Attribute | Product | Encryption | Written by |
|---|---|---|---|
| `ms-Mcs-AdmPwd` | Legacy LAPS (or Windows LAPS in emulation mode) | None — cleartext | Legacy CSE, or Windows LAPS emulating it |
| `ms-Mcs-AdmPwdExpirationTime` | Legacy LAPS | N/A (timestamp) | Same as above |
| `msLAPS-Password` | Windows LAPS, AD-backed, unencrypted mode | Optional | Windows LAPS (real policy, not emulation) |
| `msLAPS-EncryptedPassword` | Windows LAPS, AD-backed, encrypted mode | Yes | Windows LAPS (real policy, not emulation) |
| `msLAPS-PasswordExpirationTime` | Windows LAPS | N/A (timestamp) | Windows LAPS (real policy, not emulation) |
| `msLAPS-EncryptedPasswordHistory` | Windows LAPS | Yes | Windows LAPS (real policy, not emulation) |

During a transient coexistence migration, it is normal and expected for a computer object to carry **both** attribute families simultaneously — one for the legacy-managed account, one for the newly Windows-LAPS-managed second account. This is not corruption; it's the documented intermediate state. It only becomes a problem if both sets are targeting the **same account name**, which is explicitly unsupported.

</details>

---

## Dependency Stack

```
[Device joined to Microsoft Entra ID or Windows Server Active Directory]
         │
[Windows LAPS engine — built into OS, ALWAYS present/active]
    Win10 22H2+ (KB5025221) / Win11 22H2+ — no install required, cannot be absent
         │
[Precedence check #1 — is a Windows LAPS policy present?]
    Delivered via: CSP (Intune) | GPO | raw registry — method irrelevant to the check
         │
    ├── YES ─────────────────────────────────────────────┐
    │                                                     │
    │                                       [Windows LAPS policy governs unconditionally]
    │                                       Legacy LAPS GPO ignored completely (even on DCs)
    │
    └── NO
         │
[Precedence check #2 — is legacy LAPS CSE (AdmPwd.dll) installed?]
    Detected via: GPExtensions\{D76B9641-...} DllName registry value + file-on-disk check
         │
    ├── YES → [Legacy Microsoft LAPS governs as designed — Windows LAPS dormant]
    │
    └── NO
         │
[Windows LAPS auto-enters LEGACY EMULATION MODE]
    ├── Honors existing legacy GPO shape (if still linked)
    ├── Writes ms-Mcs-AdmPwd (cleartext) — same attribute legacy used
    ├── Logs Event 10023 (config detail) to Microsoft-Windows-LAPS/Operational
    ├── All Windows-LAPS-only features forced off (no encryption, no Entra backup,
    │   no custom AccountManageMode beyond what legacy supported)
    └── Suppressible only via BackupDirectory=0 (REG_DWORD) under
        HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config
         │
[AD schema / GPO ADMX / ACL layer — legacy-only operations]
    Update-AdmPwdADSchema, legacy GPO ADMX install, Set-AdmPwdComputerSelfPermissions
    — all REQUIRE legacy LAPS installed somewhere; Windows LAPS cannot perform these
         │
[Migration execution — one of two supported paths]
    ├── Immediate transition: disable/remove legacy policy + apply Windows LAPS
    │   policy to the SAME account, as close to simultaneously as possible
    │
    └── Side-by-side coexistence: create a SECOND local account, apply Windows
        LAPS policy to it, validate, THEN retire legacy policy + CSE + original account
         │
[Legacy software removal — final step, method depends on install type]
    MSI install → msiexec /uninstall {97E2CA7B-B657-4FF7-A6DB-30ECC73E1E28}
    Manual CSE registration → regsvr32 /u AdmPwd.dll + delete file
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Account password is rotating and stored in plaintext even though "we never deployed LAPS on this OU" | Windows LAPS silently entered legacy emulation mode — a stale, forgotten legacy GPO is still linked and being honored | Check for legacy GPO link on the OU; check Event 10023; check `ms-Mcs-AdmPwd` last-set time |
| Windows LAPS policy configured but password never rotates / account never gets managed | Legacy LAPS CSE still installed — precedence check #2 short-circuits before Windows LAPS policy is even considered... **wait, this is backwards** — actually: Windows LAPS policy is present (check #1 = YES) so it should always win; if it isn't working, this points to a genuine policy delivery issue, not a precedence issue — see `LAPS-A.md`/`LAPS-B.md` | Confirm policy is actually present/delivered (registry `LAPS\Config` populated); if it IS present but not acting, this is a delivery problem, not a migration problem |
| Coexistence migration configured but the new account is never managed | Windows LAPS policy accidentally targets the SAME account name the legacy GPO manages — unsupported dual-management | Compare `AccountName` in the Windows LAPS policy against the account named in the legacy GPO |
| Both `ms-Mcs-AdmPwd` and `msLAPS-Password`/`msLAPS-EncryptedPassword` populated on one computer object | Expected transient coexistence state (if targeting different accounts) — OR unsupported same-account conflict (if targeting the same account) | Check which local account each attribute's timestamp correlates to via event log account names |
| `Get-LapsADPassword` returns a result with blank `Account` and `PasswordUpdateTime` fields | This is normal — the cmdlet is reading the **legacy** cleartext attribute (`Source: LegacyLapsCleartextPassword`); those two fields were never populated by legacy LAPS in the first place | Check the `Source` property on the returned object explicitly |
| New device (freshly imaged/OOBE) shows an unexpected local admin password rotation before provisioning finishes | Legacy emulation mode activated mid-provisioning because no CSE and no Windows LAPS policy are present yet, and a legacy GPO from an OU default happens to apply | Set `BackupDirectory=0` in the imaging sequence/task sequence to suppress emulation until real policy is ready |
| Legacy LAPS MSI uninstall fails or leaves the CSE registered | Uninstall attempted with the wrong GUID, or CSE was registered manually (not via MSI) so there's no MSI record to uninstall | Check `HKLM\...\Winlogon\GPExtensions\{D76B9641-...}` `DllName` value directly to find the real file path, remove via `regsvr32 /u` |
| `Update-LapsADSchema` run, but legacy attributes still don't exist for a brand-new legacy deployment attempt | Windows LAPS's schema cmdlet **only** adds modern `msLAPS-*` attributes — it does not (and will not) add legacy schema elements | Use legacy LAPS's own `Update-AdmPwdADSchema` if a genuinely new legacy deployment is required (rare — should not be needed post-migration) |
| Device is a domain controller and still appears to honor an old legacy LAPS GPO | Should not happen — Windows LAPS always ignores legacy GPO on DCs when its own policy is present, and DCs are explicitly called out as a case where legacy GPO is always ignored | Confirm a genuine Windows LAPS policy is present; if none is present, DC may be in emulation mode like any other device |

---

## Validation Steps

**1. Establish current state classification**
```powershell
$cse = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}" -Name DllName -ErrorAction SilentlyContinue
$cseFileExists = $cse -and (Test-Path $cse.DllName)
$backupDir = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config" -Name BackupDirectory -ErrorAction SilentlyContinue).BackupDirectory

[PSCustomObject]@{
    LegacyCSEInstalled     = $cseFileExists
    BackupDirectoryValue   = $backupDir
    LikelyState            = if ($backupDir -in 1,2) { "Windows LAPS policy active" }
                              elseif ($cseFileExists) { "Legacy LAPS governs" }
                              elseif ($backupDir -eq 0) { "Emulation explicitly suppressed" }
                              else { "Emulation mode likely active" }
}
```
Good: `LikelyState` matches what you expect for this device's migration stage. Bad: device shows "Emulation mode likely active" when the team believed it was untouched by any LAPS product.

**2. Confirm emulation mode via event log, not inference alone**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object Id -eq 10023 | Select-Object -First 1 TimeCreated, Message
```
Good: no 10023 event, or a 10023 event whose message shows a fully modern policy shape (not the reduced legacy-compatible one). Bad: 10023 present with a legacy-shaped policy body — confirms real emulation-mode activity.

**3. Verify account-name alignment before/during coexistence migration**
```powershell
# Legacy GPO's configured account (read from the linked GPO's registry.pol, or GPMC UI)
# Windows LAPS policy's AccountName (read from delivered CSP/registry)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State" -ErrorAction SilentlyContinue |
    Select-Object AdminAccountName
```
Good: two distinct account names during coexistence, or one identical name during a clean immediate-transition cutover (never a mismatch mid-immediate-transition). Bad: identical account name while a legacy GPO is still linked and a Windows LAPS policy is also present — unsupported dual-management.

**4. Confirm modern attribute population post-cutover**
```powershell
Get-ADComputer $env:COMPUTERNAME -Properties msLAPS-Password, msLAPS-EncryptedPassword, msLAPS-PasswordExpirationTime |
    Select-Object Name, msLAPS-PasswordExpirationTime, @{N='Encrypted';E={[bool]$_.'msLAPS-EncryptedPassword'}}
```
Good: a recent, advancing `msLAPS-PasswordExpirationTime`. Bad: null/stale value well past when migration was believed complete.

**5. Confirm legacy attribute is aging out (not still being actively written)**
```powershell
Get-ADComputer $env:COMPUTERNAME -Properties ms-Mcs-AdmPwdExpirationTime |
    Select-Object Name, ms-Mcs-AdmPwdExpirationTime
```
Good: timestamp frozen at (or before) the migration cutover date — nothing is still writing to it. Bad: timestamp continuing to advance after cutover — something (emulation mode, a forgotten GPO) is still actively managing the legacy attribute.

**6. Confirm legacy software fully removed (final validation)**
```powershell
$cseStillThere = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}"
$legacyPkg = Get-Package -Name "*LAPS*" -ErrorAction SilentlyContinue
[PSCustomObject]@{ CSEKeyPresent = $cseStillThere; LegacyPackagePresent = [bool]$legacyPkg }
```
Good: both `$false`. Bad: either `$true` after removal is believed complete — re-run Playbook 3 (removal).

**7. Fleet-wide migration progress (AD-backed, requires RSAT AD module)**
```powershell
$computers = Get-ADComputer -Filter * -Properties ms-Mcs-AdmPwd, msLAPS-Password, msLAPS-EncryptedPassword
$computers | ForEach-Object {
    [PSCustomObject]@{
        Name        = $_.Name
        HasLegacy   = [bool]$_.'ms-Mcs-AdmPwd'
        HasModern   = [bool]($_.'msLAPS-Password' -or $_.'msLAPS-EncryptedPassword')
    }
} | Group-Object HasLegacy, HasModern | Select-Object Name, Count
```
Good: the "modern only" bucket grows over time and the "legacy only" bucket shrinks toward zero. Bad: a large, static "legacy only" population well past the planned migration deadline.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Pre-migration state assessment

1. Run Validation Step 1 across the target population to classify every device's current state
2. Identify devices already silently in emulation mode (unexpected — flag these for immediate GPO/legacy-policy review, since the team likely doesn't know they exist)
3. Confirm which migration path (immediate vs. coexistence) fits each population segment — coexistence for anything with active interactive sessions where a brief management gap is unacceptable; immediate transition for low-risk/kiosk/lab devices

### Phase 2 — Coexistence setup (if chosen)

4. Create the second local account on target devices (Fix 2 in `LAPS-Migration-B.md`)
5. Apply the Windows LAPS policy targeting ONLY the new account — verify `AccountName` in the delivered policy does not match the legacy-managed account name (Validation Step 3)
6. Force an initial rotation and confirm the new account's password populates in the correct backend (Validation Step 4)

### Phase 3 — Cutover validation

7. Run Validation Steps 4 and 5 to confirm the modern attribute is live and the legacy attribute has stopped advancing
8. For Entra-backed migrations, confirm the password appears in the Intune/Entra portal for the correct device object with an advancing timestamp
9. Monitor for at least one full rotation cycle before proceeding to removal — a single successful write is not sufficient confidence for a security-sensitive account

### Phase 4 — Legacy retirement

10. Disable or unlink the legacy GPO from the OU (do this before removing the CSE, not after, to avoid an emulation-mode window against a still-linked GPO)
11. Remove the legacy LAPS software (Playbook 3) — MSI uninstall or manual CSE deregistration depending on original install method
12. Run Validation Step 6 to confirm complete removal
13. Optionally remove the original legacy-managed local account if it's no longer needed (only after confirming nothing external still depends on it)

### Phase 5 — Fleet-wide confirmation

14. Run Validation Step 7 across the full population on a recurring cadence until the "legacy only" bucket reaches zero
15. Investigate any device that remains in the "legacy only" or "neither" bucket past the planned deadline — these are the devices most likely to be silently sitting in undiagnosed emulation mode

### Phase 6 — Post-migration hardening

16. Confirm `BackupDirectory` is explicitly set (1 or 2) fleet-wide rather than left to infer/emulation, to remove any residual ambiguity for future re-imaged or newly joined devices
17. Consider setting `BackupDirectory=0` as a baseline default in imaging/task-sequence workflows specifically to prevent emulation-mode surprises on brand-new devices before their real policy lands

---

## Remediation Playbooks

<details><summary>Playbook 1 — Immediate transition (single-account cutover) at scale</summary>

**Use for:** Low-risk device populations where a brief management gap during cutover is acceptable.

```powershell
# Run per-device after the legacy GPO link has been disabled centrally

# 1. Confirm no legacy CSE lingering (if it does, cutover to emulation could occur
#    instead of your intended Windows LAPS policy — but a real, present Windows LAPS
#    policy always wins regardless per precedence check #1, so this is a sanity check only)
Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}"

# 2. Confirm Windows LAPS policy has been delivered
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config" -ErrorAction SilentlyContinue

# 3. Force rotation to prove cutover immediately rather than waiting for schedule
Reset-LapsPassword -ErrorAction SilentlyContinue

# 4. Confirm result
Get-ADComputer $env:COMPUTERNAME -Properties msLAPS-PasswordExpirationTime |
    Select-Object Name, msLAPS-PasswordExpirationTime
```

**Rollback:** Re-link the legacy GPO and remove the Windows LAPS policy assignment. The account itself, and its historical password value in `ms-Mcs-AdmPwd`, is untouched by this playbook — only re-linking restores active legacy management.

</details>

<details><summary>Playbook 2 — Side-by-side coexistence at scale</summary>

**Use for:** Higher-risk populations (production servers, devices with active remote sessions) where validating Windows LAPS before retiring legacy is worth the temporary complexity of two managed accounts.

```powershell
param(
    [Parameter(Mandatory)][string]$NewAccountName
)

# 1. Create the second account if it doesn't already exist
if (-not (Get-LocalUser -Name $NewAccountName -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $NewAccountName -NoPassword -AccountNeverExpires
    Add-LocalGroupMember -Group "Administrators" -Member $NewAccountName
}

# 2. Confirm the legacy-managed account name is NOT the same as $NewAccountName
$legacyAccount = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State" -ErrorAction SilentlyContinue).AdminAccountName
if ($legacyAccount -eq $NewAccountName) {
    Write-Warning "CONFLICT: new account name matches the legacy-managed account. Choose a different name."
    return
}

Write-Host "Second account '$NewAccountName' ready. Apply a Windows LAPS policy targeting this account name specifically."
```

**Rollback:** Remove the Windows LAPS policy assignment, then delete `$NewAccountName`. The legacy-managed account and GPO remain fully intact and unaffected throughout — this playbook never touches them, which is the entire point of the coexistence approach.

</details>

<details><summary>Playbook 3 — Legacy software removal (both install methods)</summary>

**Use for:** Final cleanup once cutover is confirmed and validated (Validation Steps 4–6 all pass).

```powershell
# Attempt MSI uninstall first (covers the common install path)
$msiResult = Start-Process msiexec.exe -ArgumentList "/q /uninstall {97E2CA7B-B657-4FF7-A6DB-30ECC73E1E28}" -Wait -PassThru
Write-Host "MSI uninstall exit code: $($msiResult.ExitCode)"

# If the CSE is still registered after the MSI attempt (manual registration case),
# find the real DLL path and unregister/delete it directly
$cse = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}" -Name DllName -ErrorAction SilentlyContinue
if ($cse) {
    Write-Host "CSE still registered at $($cse.DllName) — unregistering manually"
    regsvr32.exe /s /u $cse.DllName
    Remove-Item $cse.DllName -Force -ErrorAction SilentlyContinue
}

# Final confirmation
$stillPresent = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}"
Write-Host "Legacy CSE key still present: $stillPresent" -ForegroundColor $(if ($stillPresent) {"Red"} else {"Green"})
```

**Rollback:** Re-run the original legacy LAPS MSI installer to restore it, or manually re-register `AdmPwd.dll` with `regsvr32` if the original file was preserved before deletion. **Do this only after** confirming Windows LAPS is genuinely managing the account correctly — this playbook is the true point of no return in the migration.

</details>

---

## Evidence Pack

```powershell
# Legacy LAPS Migration Evidence Collector — run on the affected device
$out = "$env:TEMP\LAPS-Migration-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

# 1. Legacy CSE presence check
$cse = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}" -ErrorAction SilentlyContinue
$cse | Out-File "$out\legacy-cse-state.txt"
if ($cse) { "File exists on disk: $(Test-Path $cse.DllName)" | Out-File "$out\legacy-cse-state.txt" -Append }

# 2. Windows LAPS policy config
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config" -ErrorAction SilentlyContinue |
    Out-File "$out\windows-laps-config.txt"
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State" -ErrorAction SilentlyContinue |
    Out-File "$out\windows-laps-state.txt"

# 3. LAPS event log (full — includes 10023 emulation-mode config events)
Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 200 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$out\laps-eventlog.csv" -NoTypeInformation

# 4. Local admin accounts
Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue |
    Select-Object Name, ObjectClass, PrincipalSource | Export-Csv "$out\local-admins.csv" -NoTypeInformation

# 5. AD attribute state (requires RSAT AD module + AD reachability)
try {
    Get-ADComputer $env:COMPUTERNAME -Properties ms-Mcs-AdmPwd, ms-Mcs-AdmPwdExpirationTime, msLAPS-Password, msLAPS-EncryptedPassword, msLAPS-PasswordExpirationTime -ErrorAction Stop |
        Select-Object Name, ms-Mcs-AdmPwdExpirationTime, msLAPS-PasswordExpirationTime,
            @{N='HasLegacyAttr';E={[bool]$_.'ms-Mcs-AdmPwd'}},
            @{N='HasModernAttr';E={[bool]($_.'msLAPS-Password' -or $_.'msLAPS-EncryptedPassword')}} |
        Out-File "$out\ad-attribute-state.txt"
} catch {
    "AD module unavailable or device unreachable: $_" | Out-File "$out\ad-attribute-state.txt"
}

# 6. Legacy package presence
Get-Package -Name "*LAPS*" -ErrorAction SilentlyContinue | Out-File "$out\legacy-package-check.txt"

# 7. Device join state
dsregcmd /status > "$out\dsregcmd-status.txt"
[System.Environment]::OSVersion | Out-File "$out\os-version.txt"

Compress-Archive -Path "$out\*" -DestinationPath "$out.zip"
Write-Host "Evidence pack: $out.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# 1. Check legacy CSE registration
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}" -Name DllName

# 2. Check BackupDirectory (0=emulation disabled, 1=AD, 2=Entra, absent=inferred/emulation risk)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config" -Name BackupDirectory

# 3. Check for emulation-mode config event
Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" | Where-Object Id -eq 10023 | Select-Object -First 1

# 4. Suppress emulation mode explicitly (safe, reversible)
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config" -Name "BackupDirectory" -Value 0 -PropertyType DWord -Force

# 5. Check which account Windows LAPS currently manages
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State" -Name AdminAccountName

# 6. Create second account for coexistence migration
New-LocalUser -Name "<newAccountName>" -NoPassword -AccountNeverExpires
Add-LocalGroupMember -Group "Administrators" -Member "<newAccountName>"

# 7. Force rotation to confirm cutover
Reset-LapsPassword

# 8. Read legacy AD password attribute (works even via the modern cmdlet)
Get-LapsADPassword -Identity <ComputerName> -AsPlainText

# 9. Check modern AD attribute population
Get-ADComputer <ComputerName> -Properties msLAPS-PasswordExpirationTime

# 10. Uninstall legacy LAPS MSI
msiexec.exe /q /uninstall {97E2CA7B-B657-4FF7-A6DB-30ECC73E1E28}

# 11. Manually deregister a non-MSI CSE install
regsvr32.exe /s /u <path-to-AdmPwd.dll>

# 12. Extend schema for a genuinely NEW legacy deployment (rare — legacy cmdlet only)
Update-AdmPwdADSchema

# 13. Extend schema for Windows LAPS (modern attributes only)
Update-LapsADSchema

# 14. Fleet-wide legacy-vs-modern attribute sweep (requires RSAT AD module)
Get-ADComputer -Filter * -Properties ms-Mcs-AdmPwd, msLAPS-Password |
    Select-Object Name, @{N='Legacy';E={[bool]$_.'ms-Mcs-AdmPwd'}}, @{N='Modern';E={[bool]$_.'msLAPS-Password'}}
```

---

## 🎓 Learning Pointers

- **The single fact that reframes this whole domain: Windows LAPS cannot be "not running."** It's part of the OS, active from the moment of Entra/AD join. Every migration plan should start from "what will Windows LAPS silently do in the gap," not "when do we turn Windows LAPS on." [Windows LAPS overview](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-overview)
- **Emulation mode is a deliberate compatibility feature, not a bug — but it's rarely designed for.** It exists specifically so legacy deployments aren't broken by Windows LAPS's mere presence, at the cost of being an easy-to-miss silent state. Build a fleet-wide 10023-event sweep into any migration project's monitoring from day one. [Legacy Microsoft LAPS emulation mode](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-scenarios-legacy)
- **The two documented migration paths trade risk for complexity in opposite directions.** Immediate transition is simpler but has a real (if brief) management gap; coexistence eliminates that gap but mandates a second account and a longer cleanup tail. Match the choice to the account's actual risk profile, not a blanket organizational default. [Migrate to Windows LAPS from legacy LAPS](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-scenarios-migration)
- **Schema-extension cmdlets are not interchangeable.** `Update-LapsADSchema` (modern) and `Update-AdmPwdADSchema` (legacy) each only add their own product's attributes. If you're troubleshooting "why don't the legacy attributes exist," recall that Windows LAPS was never going to create them — that's a legacy-tooling job, not a migration gap.
- **`Get-LapsADPassword`'s `Source` field is the tell.** When it returns `LegacyLapsCleartextPassword` with blank `Account`/`PasswordUpdateTime`, that's the modern cmdlet transparently reading the old attribute — not evidence the device has migrated, and not a malfunction either.
- **Sequencing matters at retirement time.** Unlink the legacy GPO before removing the CSE, not after — removing the CSE first (while a legacy GPO is still linked) opens exactly the emulation-mode window this entire runbook is built around avoiding, even if only briefly. [Windows LAPS policy settings](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-management-policy-settings)
