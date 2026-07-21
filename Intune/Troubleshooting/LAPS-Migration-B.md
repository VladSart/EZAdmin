# Legacy LAPS → Windows LAPS Migration — Hotfix Runbook (Mode B: Ops)
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

```powershell
# 1. Is the legacy LAPS CSE (.dll) installed on this device?
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}" -Name "DllName" -ErrorAction SilentlyContinue

# 2. What is the current Windows LAPS BackupDirectory config? (0=emulation disabled, 1=AD, 2=Entra ID, absent=default)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config" -Name "BackupDirectory" -ErrorAction SilentlyContinue

# 3. Is Windows LAPS currently running in legacy emulation mode? (Event 10023 = policy config detail, logged specifically when emulating)
Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue |
    Where-Object Id -eq 10023 | Select-Object -First 1 TimeCreated, Message

# 4. How many local admin accounts exist? (coexistence migration requires a SECOND account)
Get-LocalGroupMember -Group "Administrators" | Select-Object Name, ObjectClass

# 5. Which attribute set does this device's AD computer object have? (requires RSAT AD module + AD reachability)
Get-ADComputer $env:COMPUTERNAME -Properties ms-Mcs-AdmPwd, msLAPS-Password, msLAPS-EncryptedPassword -ErrorAction SilentlyContinue |
    Select-Object Name, @{N='HasLegacyAttr';E={[bool]$_.'ms-Mcs-AdmPwd'}}, @{N='HasModernAttr';E={[bool]($_.'msLAPS-Password' -or $_.'msLAPS-EncryptedPassword')}}
```

| What you see | What it means |
|---|---|
| Step 1 returns a `DllName` value pointing to a real file on disk | Legacy LAPS CSE **is** installed → Windows LAPS will never enter emulation mode on this device, and legacy GPO governs the account directly |
| Step 1 returns nothing | Legacy CSE not installed. If no Windows LAPS policy is present either, the device is a candidate for **silent emulation mode** |
| Step 2 = `0` | Emulation mode explicitly disabled — safe against surprise legacy-GPO enforcement during imaging/OOBE |
| Step 2 = `1` or `2`, or a full Windows LAPS policy is otherwise present | A real Windows LAPS policy is active — it **always** takes precedence, legacy GPO is ignored entirely, no emulation |
| Step 2 returns nothing at all, no policy present, no CSE (step 1 empty) | Device is silently running Windows LAPS in **legacy emulation mode**, honoring old GPO settings against `ms-Mcs-AdmPwd` in cleartext — likely undiagnosed by the team |
| Step 3 shows a 10023 event | Confirms emulation mode is (or recently was) active — cross-reference with steps 1 & 2 |
| Step 4 shows only 1 managed account | Only immediate-transition migration is possible right now; coexistence requires creating a second account first |
| Step 5 shows both attribute sets populated | Device is mid-migration (transient coexistence state) — expected during a gradual rollout, not itself an error |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Device joined to Microsoft Entra ID or Windows Server Active Directory
    │
    └── Windows LAPS engine is built into the OS — ALWAYS present and active
        (Win10 22H2+ KB5025221 / Win11 22H2+; no separate install, cannot be "not there")
            │
            └── Is a Windows LAPS policy currently present on the device?
                (via CSP / GPO / raw registry — delivery method is irrelevant)
                    │
                    ├── YES → Windows LAPS policy ALWAYS wins.
                    │         Legacy Microsoft LAPS GPO is ignored completely, unconditionally.
                    │         (Even on a domain controller — DCs ignore legacy LAPS GPO too.)
                    │
                    └── NO  → Is the legacy LAPS CSE (AdmPwd.dll) installed on this device?
                                  │
                                  ├── YES → Legacy Microsoft LAPS governs the account as designed.
                                  │         Windows LAPS stays dormant — this is the supported
                                  │         "not migrated yet" steady state.
                                  │
                                  └── NO  → Windows LAPS AUTOMATICALLY enters
                                            LEGACY MICROSOFT LAPS EMULATION MODE
                                                │
                                                ├── Honors the existing legacy GPO settings
                                                ├── Manages the SAME account legacy LAPS would have
                                                ├── Stores password in ms-Mcs-AdmPwd — CLEARTEXT
                                                ├── Logs Event 10023 with the active config
                                                └── Can be suppressed only via:
                                                    BackupDirectory=0 (REG_DWORD) under
                                                    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config
```

Key failure points:
- Assuming "no Windows LAPS policy configured" means "nothing is managing this account" — it doesn't; emulation mode fills the gap silently
- Configuring a Windows LAPS policy targeting the SAME account the legacy policy still targets during a coexistence migration — unsupported, causes management conflict
- Removing the legacy CSE before confirming a Windows LAPS policy is fully applied and verified — momentarily leaves the account managed by nothing but emulation mode against whatever GPO remnants exist
- Forgetting the second local account required for coexistence, then wondering why the Windows LAPS policy silently does nothing to the original account

</details>

---
## Diagnosis & Validation Flow

**1. Confirm current management state (run Triage steps 1–3 above).**
Classify the device into one of: *legacy-only*, *emulation-mode*, *Windows-LAPS-managed*, or *mid-migration (coexistence)*.

**2. If emulation mode is suspected but unconfirmed, check for the 10023 event body text:**
```powershell
(Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 50 |
    Where-Object Id -eq 10023 | Select-Object -First 1).Message
```
Expected in emulation mode: message references the legacy-compatible policy shape (cleartext-only, AD-only, no encryption/Entra options). If message instead shows a full modern policy (encryption enabled, Entra backup target), this is **not** emulation — it's a real Windows LAPS policy.

**3. Confirm which local account(s) are actually being managed:**
```powershell
Get-LapsDiagnostics -ErrorAction SilentlyContinue    # Windows LAPS module, ships with OS 22H2+
```
If unavailable, fall back to `lapschecker.exe` (see LAPS-B.md Triage). Cross-check the managed account name against both the legacy GPO's configured account and any Windows LAPS policy's `AccountName`.

**4. If migrating, confirm the target migration path chosen matches reality:**
- *Immediate transition* → legacy policy should already be disabled/removed, Windows LAPS policy applied to the **same** account
- *Coexistence* → a **second**, distinct local account must exist and be the one targeted by the new Windows LAPS policy

**5. Verify AD attribute state (AD-backed only):**
```powershell
Get-ADComputer $env:COMPUTERNAME -Properties ms-Mcs-AdmPwd, ms-Mcs-AdmPwdExpirationTime, msLAPS-Password, msLAPS-PasswordExpirationTime, msLAPS-EncryptedPassword
```
Expected post-migration: `msLAPS-*` populated and current; `ms-Mcs-AdmPwd*` either absent, stale, or explicitly retired.

**6. Verify no stale legacy artifacts remain (post-migration only):**
```powershell
Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}"
Get-Package -Name "*LAPS*" -ErrorAction SilentlyContinue
```
Expected: both empty/false once cleanup is complete.

---
## Common Fix Paths

<details><summary>Fix 1 — Execute immediate transition (single account, cutover)</summary>

**Use when:** No need to run both side by side; a short window of no active management is acceptable.

```powershell
# Step 1 — Disable/remove the legacy GPO assignment for this OU/device FIRST
#          (do this in Group Policy Management Console — no PowerShell equivalent
#           for unlinking a GPO from here; unlink or disable the GPO link)

# Step 2 — Apply Windows LAPS policy targeting the SAME account name the legacy
#          policy managed (do this as close to simultaneously as possible)
# Example CSP-equivalent local verification after policy delivery:
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config" -ErrorAction SilentlyContinue

# Step 3 — Force an immediate rotation to confirm Windows LAPS has taken over
Reset-LapsPassword -ErrorAction SilentlyContinue
# or via Intune: Devices > [device] > Rotate local admin password

# Step 4 — Confirm the modern attribute populated
Get-ADComputer $env:COMPUTERNAME -Properties msLAPS-PasswordExpirationTime |
    Select-Object Name, msLAPS-PasswordExpirationTime
```

**Rollback note:** Re-link the disabled legacy GPO and remove the Windows LAPS policy assignment to revert. The local account itself is untouched by either policy engine — only which entity manages its password changes.

</details>

<details><summary>Fix 2 — Execute side-by-side coexistence (dual account)</summary>

**Use when:** You want to validate Windows LAPS works correctly before fully cutting over.

```powershell
# Step 1 — Create the second local account (must be distinct from the legacy-managed one)
$secondAccount = "<newLapsAccountName>"
New-LocalUser -Name $secondAccount -NoPassword -AccountNeverExpires
Add-LocalGroupMember -Group "Administrators" -Member $secondAccount

# Step 2 — Apply a Windows LAPS policy targeting $secondAccount specifically
#          (AccountName = $secondAccount, AccountManageMode = CreateOrManage or Manage)

# Step 3 — Confirm Windows LAPS took over the NEW account without touching the old one
Get-LocalUser -Name $secondAccount | Select-Object Name, Enabled, PasswordLastSet
Get-ADComputer $env:COMPUTERNAME -Properties msLAPS-PasswordExpirationTime

# Step 4 — Once confident, disable/remove legacy GPO and legacy CSE (see Fix 4),
#          then optionally remove the original legacy-managed account if unneeded
```

**⚠️ Do not** target the second Windows LAPS policy at the SAME account the legacy policy still manages — having both a Windows LAPS policy and a legacy LAPS policy target one account is unsupported and causes a management conflict.

**Rollback note:** Remove the Windows LAPS policy assignment and delete `$secondAccount`; the original legacy-managed account and its GPO are untouched throughout this entire path — this is the safest migration option for risk-averse changes.

</details>

<details><summary>Fix 3 — Suppress unwanted emulation mode (e.g., during imaging/OOBE)</summary>

**Cause:** A freshly imaged or newly domain-joined device has no Windows LAPS policy and no legacy CSE yet — Windows LAPS silently starts enforcing whatever legacy-shaped GPO settings it can see, mid-provisioning, which can be disruptive.

```powershell
# Explicitly disable emulation mode until real policy is ready
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config" -Name "BackupDirectory" -Value 0 -PropertyType DWord -Force

# Verify
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config" -Name "BackupDirectory"
```

**Rollback note:** Fully reversible — once a real Windows LAPS policy is delivered, that policy takes precedence automatically regardless of this value; you can leave `BackupDirectory=0` in place permanently or remove it, either is safe.

</details>

<details><summary>Fix 4 — Remove legacy LAPS software cleanly</summary>

**Cause:** Migration is confirmed successful; legacy software is now dead weight and a residual security surface (plaintext `ms-Mcs-AdmPwd`).

```powershell
# If installed via the legacy LAPS MSI:
msiexec.exe /q /uninstall {97E2CA7B-B657-4FF7-A6DB-30ECC73E1E28}

# If installed by manually registering the CSE (no MSI):
# First find the actual DLL path:
$dllPath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}" -Name DllName -ErrorAction SilentlyContinue).DllName
if ($dllPath) {
    regsvr32.exe /s /u $dllPath
    Remove-Item $dllPath -Force -ErrorAction SilentlyContinue
}
```

**Rollback note:** Re-running the original legacy LAPS MSI installer restores it if removed in error. Confirm the Windows LAPS policy is fully working (Fix 1 Step 4, or Fix 2 Step 3) **before** running this — removing the CSE is the point of no return for that device's legacy management path.

</details>

<details><summary>Fix 5 — Both policies unexpectedly targeting the same account</summary>

**Cause:** Someone configured a Windows LAPS policy without checking what account the legacy GPO already manages — unsupported dual-management configuration.

```powershell
# Identify the account each side thinks it owns
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd" -Name "AdmPwdEnabled" -ErrorAction SilentlyContinue
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State" -ErrorAction SilentlyContinue
```

**Fix:** Change the Windows LAPS policy's `AccountName` to a distinct second account (go to Fix 2), OR fully retire the legacy GPO for this OU (go to Fix 1) — never leave both targeting the same name.

**Rollback note:** No destructive action here — this fix is purely a policy retarget; back out by reverting the `AccountName` change if needed.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Legacy LAPS → Windows LAPS Migration Issue

Device name: _____________________
Domain / Entra joined: ____________
Windows build: ____________________

Legacy LAPS CSE installed (Y/N): __________
BackupDirectory registry value: __________ (blank/0/1/2)
Emulation mode suspected (Y/N), based on Event 10023: __________

Local admin accounts present: _____________________________
Account targeted by legacy GPO: ___________________________
Account targeted by Windows LAPS policy (if any): _________
Same account on both sides? (Y/N — unsupported if Y): _____

AD attribute state:
  ms-Mcs-AdmPwd present (Y/N): ______  Last set: __________
  msLAPS-Password / EncryptedPassword present (Y/N): ______  Last set: __________

Migration path chosen: (Immediate cutover / Side-by-side coexistence / Undecided)
Current migration step: ___________________________________

Steps already attempted:
[ ] Confirmed CSE/emulation state (Triage 1–3)
[ ] Verified local account count/targets (Triage 4)
[ ] Checked AD attribute dual-state (Triage 5)
[ ] Applied Fix 1 / Fix 2 as appropriate
[ ] Forced rotation to confirm cutover
[ ] Removed legacy software (Fix 4)
```

---
## 🎓 Learning Pointers

- **Windows LAPS is never "off."** Once a device is Entra- or AD-joined, the Windows LAPS engine is always present and active — there is no "not installed" state to fall back to. The only way to avoid it acting is either a real Windows LAPS policy, an installed legacy CSE, or the explicit `BackupDirectory=0` override. [Windows LAPS FAQ](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-faq)
- **Emulation mode is a trap for the unwary.** A device with no CSE and no Windows LAPS policy doesn't sit idle — it silently starts honoring the legacy GPO shape against `ms-Mcs-AdmPwd` in cleartext. Teams that assume "we haven't touched LAPS on that OU yet" can be wrong. [Legacy Microsoft LAPS emulation mode](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-scenarios-legacy)
- **Coexistence requires two different accounts — this is not optional.** Microsoft's documented gradual-migration path explicitly requires a second local account because a Windows LAPS policy and a legacy LAPS policy cannot both target the same account. [Migrate to Windows LAPS from legacy LAPS](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-scenarios-migration)
- **Removal method depends on install method.** MSI-installed legacy LAPS uses `msiexec /uninstall {GUID}`; manually-registered CSE installs need `regsvr32 /u` plus manual file deletion. Guessing wrong leaves orphaned files or a broken uninstall.
- **`Get-LapsADPassword` can read the legacy attribute too** — when it returns a result with `Source: LegacyLapsCleartextPassword` and blank `Account`/`PasswordUpdateTime` fields, that's the modern cmdlet reading the *old* plaintext attribute, not a bug. Don't mistake it for a migration having already completed.
- **Monitor the transition, don't just trust it happened.** Watch for the `msLAPS-PasswordExpirationTime` attribute appearing/updating on the AD computer object (AD-backed) or the Entra/Intune portal showing an updated password timestamp (cloud-backed) as the definitive signal a device has actually cut over. [Monitor a successful transition](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-scenarios-migration#monitor-a-successful-transition)
