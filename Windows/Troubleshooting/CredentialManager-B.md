# Windows Credential Manager — Hotfix Runbook (Mode B: Ops)
> Fix cached credential failures, token poisoning, and Credential Manager corruption in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run these as the affected user (or SYSTEM for service account issues). No elevation required for reading.

```powershell
# 1. List all stored credentials (Windows + Generic + Certificates)
cmdkey /list

# 2. List via PowerShell with more detail (type, persistence, last modified)
[void][Windows.Security.Credentials.PasswordVault, Windows.Security.Credentials, ContentType=WindowsRuntime]
$vault = New-Object Windows.Security.Credentials.PasswordVault
# Note: Above lists Windows RT vault. For Win32 credentials use:
Get-StoredCredential -Type Generic | Select-Object TargetName, UserName, Type, Persist
# If Get-StoredCredential not available:
cmdkey /list 2>&1

# 3. Check for duplicate/conflicting entries for the same target
cmdkey /list | Select-String "Target:" | Group-Object { ($_ -replace ".*Target:\s+","").Trim() } |
  Where-Object {$_.Count -gt 1}

# 4. Check if WinHTTP/NTLM cached tokens are stale (sign of token reuse issue)
klist
# If tickets show expired TGT alongside valid TGTs, purge needed

# 5. Check Credential Manager service health
Get-Service -Name VaultSvc | Select-Object Status, StartType
```

**Interpretation table:**

| What you see | Most likely cause | Go to |
|---|---|---|
| Duplicate entries for same target | Stale credential causing auth loop | Fix 1 |
| `klist` shows expired TGT | Kerberos ticket not purged after password change | Fix 2 |
| `VaultSvc` Stopped | Credential Manager vault service not running | Fix 3 |
| User prompted for creds every login | Credentials stored as `Session` not `Enterprise` | Fix 4 |
| "Logon failure: unknown user / bad password" despite correct creds | Old password cached and blocking new auth | Fix 5 |
| Credentials present but connection still fails | Certificate/NTLM downgrade, not a Credential Manager issue | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for Credential Manager to supply credentials successfully</summary>

```
Windows Credential Manager (VaultSvc must be Running)
 ├── Windows Vault (Generic credentials — websites, apps, mapped drives)
 │    └── Stored as: Session / Local Machine / Enterprise (roaming via domain)
 ├── Windows Certificate Store (certificate-backed credentials)
 │    └── Requires cert in Personal store → valid chain → OCSP/CRL accessible
 ├── Kerberos Ticket Cache (domain accounts)
 │    └── Valid TGT from DC → service tickets per resource
 │         └── DC reachable + time skew < 5 minutes
 └── NTLM Credential Cache (fallback when Kerberos fails)
      └── LSASS stores NTLM hashes → used when DC unreachable
           └── If password changed on another device: hash mismatch = lockout risk
```

**Key nuance:** "Credential Manager" in the Control Panel only shows **Generic** and **Windows** credentials. It does NOT show Kerberos tickets (managed by LSASS) or DPAPI-protected secrets (managed per-user on disk). All three can independently cause "wrong password" symptoms.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the service is running:**
   ```powershell
   Get-Service VaultSvc | Select-Object Status
   # Expected: Running
   Start-Service VaultSvc  # if Stopped
   ```

2. **List all credentials to spot stale entries:**
   ```powershell
   cmdkey /list
   # Look for: MicrosoftOffice*, domain\username, *.sharepoint.com, TERMSRV/* entries
   # Any entry with an old username or pre-password-change timestamp is suspect
   ```

3. **Check Kerberos ticket health:**
   ```powershell
   klist
   # Expected: One valid TGT, service tickets for resources accessed
   # Bad: Expired tickets, tickets for wrong KDC, mixed-version TGTs
   klist tgt   # Show TGT details only
   ```
   Good TGT: `StartTime` ≤ now ≤ `EndTime`, server = `krbtgt/<DOMAIN>`.

4. **Test credential resolution for a specific target:**
   ```powershell
   # Test if stored credential is being offered for a UNC path
   net use \\<server>\<share> /user:<domain\username>
   # If prompted for password: credential not stored or wrong target name
   # If "Access denied": credential stored but wrong (old password)
   ```

5. **Check for DPAPI key accessibility (roaming profile users):**
   ```powershell
   # DPAPI master keys stored here - if missing, stored creds become unreadable
   Get-ChildItem "$env:APPDATA\Microsoft\Protect\$([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)" |
     Select-Object Name, LastWriteTime
   # Expected: Files present. Empty folder = DPAPI keys lost (roaming profile problem)
   ```

6. **For mapped drive / file share failures, check if the wrong credential is being sent:**
   ```powershell
   # Capture what credential Windows is attempting to use
   $cred = Get-StoredCredential -TargetName "\\<server>"
   $cred | Select-Object UserName, Type, Persist
   # If UserName shows an old/wrong account: that's your problem
   ```

---
## Common Fix Paths

<details><summary>Fix 1 — Remove stale/duplicate credentials for a target</summary>

**Symptom:** User can't access a resource despite knowing the correct password. `cmdkey /list` shows an entry for the target.

```powershell
# Remove a specific credential
cmdkey /delete:<TargetName>
# Examples:
cmdkey /delete:domain.com
cmdkey /delete:"MicrosoftOffice16_Data:SSPI:<UPN>"
cmdkey /delete:TERMSRV/<hostname>

# Remove ALL stored credentials (nuclear — user will be prompted to re-enter)
cmdkey /list | Select-String "Target:" | ForEach-Object {
    $target = ($_ -replace ".*Target:\s+","").Trim()
    cmdkey /delete:$target
}
```

Then re-add correct credential:
```powershell
cmdkey /add:<TargetName> /user:<domain\username> /pass:<password>
# Example for file share:
cmdkey /add:\\fileserver\share /user:CORP\jsmith /pass:CorrectPassword123
```

**Rollback:** Credentials can be re-added via `cmdkey /add` or via Control Panel → Credential Manager.

</details>

<details><summary>Fix 2 — Purge stale Kerberos tickets after password change</summary>

**Symptom:** User changed their password on another device/session. Old Kerberos tickets still in cache. Resources return "Access Denied" or auth prompts despite correct new credentials.

```powershell
# Purge all Kerberos tickets for current session
klist purge

# Verify tickets cleared
klist
# Expected: No tickets listed

# Force new TGT acquisition (triggers DC auth with new password)
gpupdate /force
# Or simply lock and unlock the workstation — triggers fresh Kerberos auth
```

**If tickets return with old credentials:**
- The old password is still cached in Credential Manager
- Also remove Generic/Windows credentials for the domain in `cmdkey /list`

```powershell
# Remove all domain-related stored credentials
cmdkey /list | Select-String "Target:" | ForEach-Object {
    $t = ($_ -replace ".*Target:\s+","").Trim()
    if ($t -match "<DomainName>|MicrosoftOffice|OneDrive") { cmdkey /delete:$t }
}
klist purge
```

</details>

<details><summary>Fix 3 — VaultSvc (Credential Manager service) stopped</summary>

**Symptom:** Apps fail to store or retrieve credentials. Credential Manager in Control Panel shows blank or "Access denied." `Get-Service VaultSvc` shows Stopped.

```powershell
# Start the service
Start-Service VaultSvc

# If it fails to start, check dependencies
Get-Service VaultSvc | Select-Object -ExpandProperty DependentServices
# Depends on: CryptSvc (Cryptographic Services) - start that first

Start-Service CryptSvc
Start-Service VaultSvc

# Set to automatic if it was Manual
Set-Service VaultSvc -StartupType Automatic

# Verify
Get-Service VaultSvc | Select-Object Status, StartType
```

**If VaultSvc is disabled by policy (GPO):**
```powershell
# Check if a GPO is disabling it
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\VaultSvc" -Name Start
# 4 = Disabled by GPO or config; 2 = Auto; 3 = Manual
```
Check GPO: Computer Configuration → Windows Settings → Security Settings → System Services → Credential Manager.

**Rollback:** Not applicable — enabling a service is non-destructive.

</details>

<details><summary>Fix 4 — Credentials stored as Session (not persisting across reboots)</summary>

**Symptom:** User re-enters credentials every login. `cmdkey /list` shows entries as `Persistence: Session` instead of `Enterprise` or `Local`.

**Cause:** Application or script stored the credential with session persistence, or user is on a shared/temporary profile.

```powershell
# Remove the session credential and re-add with Enterprise persistence
cmdkey /delete:<TargetName>

# Re-add with Enterprise (persists across reboots, roams with domain profile)
cmdkey /add:<TargetName> /user:<username> /pass:<password>
# cmdkey /add always stores as Enterprise when called from a normal user session
# Session persistence is typically set by the application, not cmdkey
```

**For mapped drives — make them persistent:**
```powershell
# Remove transient mapping
net use Z: /delete

# Re-add as persistent
net use Z: \\<server>\<share> /user:<domain\username> <password> /persistent:yes
```

**Roaming credential issue (domain users):** Enterprise credentials roam via Domain Credential Roaming (if configured) or stay local. If profile is mandatory/temporary, credentials will never persist — fix the profile policy, not the credential.

</details>

<details><summary>Fix 5 — Old cached password causing account lockout risk</summary>

**Symptom:** User changed their password. Network resources repeatedly deny access and may trigger lockout. Multiple stale credential entries visible.

**CAUTION:** If the account is already locked, unlock in AD/Entra before clearing credentials — clearing creds won't unlock.

```powershell
# Step 1: Identify all stale entries
cmdkey /list | Select-String "Target:|User:"

# Step 2: Purge Kerberos tickets first (stops active retry with old hash)
klist purge

# Step 3: Remove all credential entries for the domain/resources
cmdkey /list | Select-String "Target:" | ForEach-Object {
    $t = ($_ -replace ".*Target:\s+","").Trim()
    cmdkey /delete:$t 2>$null
}

# Step 4: Also clear Office credential cache (common lockout source)
# Close all Office apps first, then:
cmdkey /list | Select-String "MicrosoftOffice|OneDrive|SharePoint" | ForEach-Object {
    $t = ($_ -replace ".*Target:\s+","").Trim()
    cmdkey /delete:$t 2>$null
}

# Step 5: Sign out of OneDrive (GUI) or:
Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
# Reopen OneDrive — it will prompt for fresh credentials

# Step 6: Re-authenticate via Office app (opens MSAL/browser flow)
# This refreshes the OAuth token stack for M365 services
```

**Rollback:** User will be prompted to re-enter credentials — that is expected and correct.

</details>

<details><summary>Fix 6 — Credentials present but connection still fails (NTLM downgrade / auth mismatch)</summary>

**Symptom:** `cmdkey /list` shows the correct credential, but the connection returns "Access Denied" or "Logon Failure."

**Diagnose — check if NTLM is being blocked:**
```powershell
# Check server's LAN Manager authentication level
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name LmCompatibilityLevel
# Level 5 = NTLMv2 only (clients sending NTLMv1 will fail)

# Check client LM level (on the connecting machine)
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name LmCompatibilityLevel
```

**Fix — force NTLMv2 on client (if server requires it):**
```powershell
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name LmCompatibilityLevel -Value 3
# 3 = Send NTLMv2 only. Matches Level 5 server requirement.
```

**Fix — check if SPN mismatch is causing Kerberos to fall through to NTLM which then fails:**
```powershell
setspn -Q <serviceClass>/<hostname>   # e.g. setspn -Q HOST/fileserver
# If missing SPN: Kerberos fails, Windows falls back to NTLM, NTLM blocked by policy = auth fails
setspn -S HOST/<hostname> <domain\computerAccount>   # Add missing SPN
```

**Rollback:** LmCompatibilityLevel change can be reverted to previous value. SPN additions are additive and non-destructive.

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — Windows Credential Manager

Hostname:           _______________
OS Build:           _______________
Domain:             _______________
Affected UPN:       _______________
Profile Type:       [Local / Roaming / Mandatory / Temporary]

Symptom:            _______________
Target Resource:    _______________
Error Message:      _______________

VaultSvc Status:    _______________
cmdkey /list output (sanitised — redact passwords):
_______________________________________________

klist output (first ticket only):
_______________________________________________

LmCompatibilityLevel (client):  _______________
LmCompatibilityLevel (server):  _______________

Account locked out?  YES / NO
AD lockout source (if locked): _______________

DPAPI keys present (Y/N):  _______________
GPO forcing service state?  _______________

Steps already attempted:
- [ ] Purged Kerberos tickets (klist purge)
- [ ] Deleted stale cmdkey entries
- [ ] Restarted VaultSvc
- [ ] Cleared Office credential cache
- [ ] Signed out/back in to OneDrive
```

---
## 🎓 Learning Pointers

- **Three independent credential stores:** Windows has Credential Manager (Generic/Windows vault), Kerberos ticket cache (LSASS), and NTLM cached credentials. A password change can leave all three out of sync simultaneously — purge all three when troubleshooting post-password-change failures.

- **Office apps are the #1 lockout source:** Microsoft 365 apps have their own MSAL token cache AND use Credential Manager entries. If a user changes their password, Office apps will silently retry with cached tokens until the account locks. Always clear Office/OneDrive credential entries when troubleshooting lockouts. See: [Microsoft Account troubleshooting for Office](https://support.microsoft.com/en-us/office/sign-in-issues-with-office-on-windows-b09faf1e-8d5e-4b33-ac3e-a60e4e5be8f7)

- **`cmdkey /add` persistence behavior:** Credentials added via `cmdkey` always persist as **Enterprise** (survives reboot) for domain-joined machines, or **Local Machine** for workgroup machines. "Session" persistence is set programmatically by apps (e.g. Terminal Services). You can't force Enterprise from a script if the app enforces Session.

- **DPAPI is the hidden dependency:** Credentials stored in the Windows Vault are encrypted with DPAPI (Data Protection API) using the user's SID and a machine-bound master key. If the user's roaming profile loses its DPAPI master keys (e.g. profile copy failure), ALL stored credentials become permanently unreadable — not just stale. Check `%APPDATA%\Microsoft\Protect\<SID>` if Credential Manager appears empty after a profile migration. See: [DPAPI and credential roaming](https://learn.microsoft.com/en-us/troubleshoot/windows-server/windows-security/dpapi-masterkey-backup-secrets)

- **Credential Manager vs. Azure AD token cache:** For Entra ID / M365 resources, auth tokens are stored in the WAM (Web Account Manager) broker, not Credential Manager. If `cmdkey` shows no relevant entries but auth still fails, use `dsregcmd /status` and check the SSO/PRT section — WAM issues won't show up in Credential Manager at all.

- **Security note — don't store domain admin credentials:** `cmdkey /add` stores in plaintext-equivalent form (DPAPI-encrypted, decryptable by the user). Never use `cmdkey` to store DA/tier-0 credentials. Use LAPS, PIM, or CyberArk/BeyondTrust for privileged account management.
