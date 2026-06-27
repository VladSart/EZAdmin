# Windows Credential Manager — Reference Runbook (Mode A: Deep Dive)
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

Covers Windows Credential Manager (WCM) for Windows 10/11 and Windows Server 2019/2022 in both on-premises AD and Entra ID / Hybrid join environments. Applies to:

- **Windows Credentials** (NTLM cached credentials, Kerberos tickets, certificate-based credentials)
- **Web Credentials** (stored by IE/Edge legacy and apps using WinInet)
- **Generic Credentials** (apps using CredentialUI, DPAPI-backed secrets)
- **Certificate-based credentials** (smart card PINs, WHfB vault entries)

Assumes L2/L3 engineer access. Some repairs require local admin. Credential vault contents are user-scoped — even admins cannot read another user's vault without tooling like Mimikatz (which is a red-team concern, not a remediation tool).

---

## How It Works

<details><summary>Full architecture</summary>

### Storage Layers

Windows Credential Manager is a credential broker with three distinct storage layers:

```
User requests resource (e.g., \\server\share)
         │
         ▼
  Security Support Provider Interface (SSPI)
         │
         ├─► Kerberos SSP   ──► KDC / AD  (tickets cached in LSASS)
         ├─► NTLM SSP       ──► Challenge/Response (no local cache)
         └─► Credential Manager Vault
                   │
                   ├─► Windows Credentials  (VaultSvc)
                   │        └─► %LOCALAPPDATA%\Microsoft\Vault\
                   ├─► Web Credentials      (WinInet/HTTP auth cache)
                   │        └─► %APPDATA%\Microsoft\Credentials\
                   └─► Generic Credentials  (CredMan API)
                            └─► %LOCALAPPDATA%\Microsoft\Credentials\
```

### DPAPI Encryption

All vault blobs are encrypted by DPAPI (Data Protection API):

```
MasterKey ──► derived from user password (+ domain backup key if domain-joined)
     │
     └─► encrypts credential blob
              └─► stored in %APPDATA%\Microsoft\Protect\<SID>\
```

On domain-joined machines, DPAPI can recover credentials even after a password reset because the domain backup key (held by a DC) can decrypt the master key. On standalone/Entra-only machines, a password reset without recovery key = permanent vault loss.

### Vault Service (VaultSvc)

`VaultSvc` (Windows Vault) runs as `NETWORK SERVICE` and brokers reads/writes to vault files. Applications call `CredRead` / `CredWrite` Win32 APIs. The WCM UI in Control Panel and `cmdkey.exe` are wrappers around these APIs.

### Entra ID & WHfB Integration

Windows Hello for Business uses the NGC (Next Generation Credentials) vault:
- Stored in `%LOCALAPPDATA%\Microsoft\Vault\<GUID>\`
- Protected by TPM-backed keys, not DPAPI password derivation
- Managed separately from classic Credential Manager — `cmdkey` cannot list or remove NGC entries

### Profile-Level Isolation

Each user has their own vault namespace under their profile. Credential Manager credentials do NOT roam by default (unlike IE favorites or some browser data). Enterprise State Roaming does NOT include classic vault credentials. This means:
- New device = empty Credential Manager
- Profile migration tools (USMT) can optionally migrate credentials, but encrypted blobs may not decrypt on a new machine without the domain backup key

</details>

---

## Dependency Stack

```
Application (e.g., Outlook, mapped drive, RDP)
        │
        ▼
  Win32 Credential APIs (CredRead/CredWrite/CredEnumerate)
        │
        ▼
  VaultSvc (Windows Vault Service)
        │
        ├─► DPAPI (CryptProtectData / CryptUnprotectData)
        │        │
        │        ├─► User Master Key  (%APPDATA%\Microsoft\Protect\<SID>\)
        │        └─► Domain Backup Key (DC via MS-BKRP protocol) [domain only]
        │
        └─► Vault Files
                 ├─► Windows Credentials  (%LOCALAPPDATA%\Microsoft\Vault\)
                 ├─► Web Credentials      (%APPDATA%\Microsoft\Credentials\)
                 └─► Generic Credentials  (%LOCALAPPDATA%\Microsoft\Credentials\)

Supporting infrastructure:
  ├─► LSASS (Kerberos/NTLM tickets — separate from WCM vault)
  ├─► NetLogon (domain trust for DPAPI backup key retrieval)
  └─► TPM (WHfB NGC credentials — separate from classic vault)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Repeated password prompts for mapped drive | Stale/wrong credential stored in vault | `cmdkey /list` — check target name and domain |
| "The stored credentials are invalid" on RDP | Password changed on server, old credential cached | `cmdkey /list` + remove matching entry |
| Credential Manager shows blank / won't open | VaultSvc stopped or profile corruption | `Get-Service VaultSvc` + vault file permissions |
| Can't save credentials (checkbox greyed out) | Group Policy restricting credential delegation | `gpresult /h` — check `Network access: Do not allow storage of passwords` |
| DPAPI errors in application event log | Master key corruption or domain backup key unreachable | Check Event ID 8198/8199 in System log |
| Outlook keeps asking for password (Modern Auth) | OAuth token expired/invalid in credential vault | Remove `MicrosoftOffice*` entries from WCM |
| SSO not working after password reset | DPAPI master key re-keyed, old encrypted blobs invalid | Re-add credentials manually after password sync |
| "Access denied" reading credential vault | Profile permission issue or VaultSvc not running | Check `%LOCALAPPDATA%\Microsoft\Vault` ACLs |
| Credentials lost after profile rebuild | DPAPI blobs unrecoverable without domain backup key | Expected behaviour on non-domain / new profile |
| RDS/session host credential loop | Per-user vs. per-session vault isolation | Check if using Remote Desktop Services per-session profiles |

---

## Validation Steps

### 1. List all stored credentials
```powershell
cmdkey /list
```
**Good:** Returns list with `Target:`, `Type:`, `User:` for each entry.  
**Bad:** "No credentials are stored" when user reports saved credentials — vault may be corrupted or pointing to wrong profile.

### 2. Verify VaultSvc is running
```powershell
Get-Service VaultSvc | Select-Object Name, Status, StartType
```
**Good:** `Status = Running`, `StartType = Automatic`  
**Bad:** `Status = Stopped` — restart it and check if credentials become accessible.

### 3. Check DPAPI master key health
```powershell
$protect = "$env:APPDATA\Microsoft\Protect\$([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
Get-ChildItem $protect -ErrorAction SilentlyContinue | Select-Object Name, LastWriteTime
```
**Good:** One or more GUID-named files, recently accessed (within last few months).  
**Bad:** Empty directory or access denied — DPAPI master key missing.

### 4. Check Group Policy credential storage restrictions
```powershell
# Check if "Do not allow storage of passwords and credentials" is enabled
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -ErrorAction SilentlyContinue).DisableDomainCreds
```
**Good:** `0` or key not present (storage allowed).  
**Bad:** `1` — GPO is blocking credential storage. UI will grey out the "Remember my credentials" checkbox.

### 5. Verify vault file permissions
```powershell
$vaultPath = "$env:LOCALAPPDATA\Microsoft\Vault"
icacls $vaultPath
```
**Good:** Current user has `(F)` (Full Control) on their vault directory.  
**Bad:** Missing or restricted permissions — repair with `icacls` (see Remediation Playbooks).

### 6. Check application event log for DPAPI errors
```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; Id=8198,8199; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message | Format-List
```
**Good:** No results.  
**Bad:** Event 8198 (key decryption failure) or 8199 (key not available) — DPAPI master key problem.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify the credential type and target

```powershell
# Full credential audit
cmdkey /list | Out-String | Write-Host

# Check via .NET CredentialManager (more detail)
[void][Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime]
$vault = New-Object Windows.Security.Credentials.PasswordVault
try { $vault.RetrieveAll() | Select-Object UserName, Resource } catch { "Web credentials vault: $($_.Exception.Message)" }
```

Identify whether the problematic credential is:
- **Windows credential** (for AD resources, mapped drives, RDP)
- **Web credential** (stored by browser or WinInet apps)
- **Generic credential** (Office 365 OAuth tokens, app-specific)

### Phase 2 — Check for GPO restrictions

```powershell
gpresult /h "$env:TEMP\gp-report.html" /f
Start-Process "$env:TEMP\gp-report.html"
# Search for: "Network access: Do not allow storage of passwords"
# And: "Credential delegation" policies under Computer Config > Windows Settings > Security Settings
```

Also check:
```powershell
Get-GPResultantSetOfPolicy -ReportType Html -Path "$env:TEMP\rsop.html" 2>$null
# Or for local only:
secedit /export /cfg "$env:TEMP\secedit.cfg" /quiet
Select-String "DisableDomainCreds" "$env:TEMP\secedit.cfg"
```

### Phase 3 — Test credential write/read programmatically

```powershell
# Test: write a test credential
cmdkey /add:TEST_CRED_HEALTHCHECK /user:testuser /pass:TestPass123!
# Test: verify it was saved
cmdkey /list | Select-String "TEST_CRED_HEALTHCHECK"
# Clean up
cmdkey /delete:TEST_CRED_HEALTHCHECK
```

If write succeeds but read fails, suspect vault file corruption. If write fails, suspect GPO or VaultSvc issue.

### Phase 4 — Check DPAPI and master key

```powershell
# Test DPAPI round-trip
$testData = [System.Text.Encoding]::UTF8.GetBytes("DPAPITest")
$encrypted = [System.Security.Cryptography.ProtectedData]::Protect($testData, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
$decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
[System.Text.Encoding]::UTF8.GetString($decrypted)
```

**Expected output:** `DPAPITest`  
**If it throws:** DPAPI is broken for this user — usually requires master key recovery or profile recreation.

### Phase 5 — Check for Outlook/Office token issues

Modern authentication tokens for Office 365 are stored as Generic credentials:
```powershell
cmdkey /list | Select-String "MicrosoftOffice|office365|microsoftoffice16|WindowsLive"
```

If stale tokens are present and causing authentication loops:
```powershell
# Remove Office credentials (sign user out of Office first)
cmdkey /list | Select-String "MicrosoftOffice" | ForEach-Object {
    $target = ($_ -split "Target: ")[1].Trim()
    cmdkey /delete:$target
}
```

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Remove stale/wrong credential and re-add</summary>

**Scenario:** User gets repeated prompts for a network resource because a wrong password was saved.

```powershell
# Step 1: Identify the target name
cmdkey /list

# Step 2: Remove the stale credential (use exact target name from list)
cmdkey /delete:<TargetName>
# Example: cmdkey /delete:TERMSRV/fileserver01.contoso.com

# Step 3: Re-add with correct credentials
cmdkey /add:<TargetName> /user:<DOMAIN\Username> /pass:<Password>
# Example: cmdkey /add:TERMSRV/fileserver01.contoso.com /user:CONTOSO\jsmith /pass:NewPassword123!

# Step 4: Verify
cmdkey /list | Select-String "<TargetName>"
```

**Rollback:** Not applicable (credential was wrong — no rollback needed). If the user can't remember their password, have them reset it via SSPR or helpdesk first.

**Note on RDP targets:** RDP credentials use the `TERMSRV/<hostname>` target naming convention. Mapped drives use `\\<server>\<share>` or just `<server>`.

</details>

<details>
<summary>Fix 2 — Repair vault file permissions</summary>

**Scenario:** Credential Manager UI opens blank or `cmdkey /list` returns nothing despite credentials having been saved.

```powershell
# Run as the affected user (not as admin on their behalf)
$vaultPath = "$env:LOCALAPPDATA\Microsoft\Vault"
$credPath  = "$env:APPDATA\Microsoft\Credentials"
$localCredPath = "$env:LOCALAPPDATA\Microsoft\Credentials"

# Check current permissions
icacls $vaultPath
icacls $credPath

# Repair: grant current user full control
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
icacls $vaultPath /grant "${currentUser}:(OI)(CI)F" /T
icacls $credPath  /grant "${currentUser}:(OI)(CI)F" /T
icacls $localCredPath /grant "${currentUser}:(OI)(CI)F" /T

# Restart VaultSvc
Restart-Service VaultSvc -Force
```

**Rollback:** If permission changes break something, reset to defaults:
```powershell
icacls $vaultPath /reset /T
```

**Caution:** If the vault files themselves are corrupted (zero-byte files), delete them and have the user re-enter credentials. There is no way to recover encrypted vault blobs without the corresponding DPAPI master key.

</details>

<details>
<summary>Fix 3 — Clear all credentials and rebuild (nuclear option)</summary>

**Scenario:** Credential Manager is in a persistent broken state — prompts continue, vault can't be read, VaultSvc errors.

```powershell
# Step 1: Export credential list for manual recreation reference
cmdkey /list | Out-File "$env:DESKTOP\creds-before-clear.txt"

# Step 2: Stop VaultSvc
Stop-Service VaultSvc -Force

# Step 3: Clear vault files
$vaultFiles = @(
    "$env:LOCALAPPDATA\Microsoft\Vault\",
    "$env:APPDATA\Microsoft\Credentials\",
    "$env:LOCALAPPDATA\Microsoft\Credentials\"
)
foreach ($path in $vaultFiles) {
    if (Test-Path $path) {
        Get-ChildItem $path -Recurse -File | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# Step 4: Restart VaultSvc
Start-Service VaultSvc

# Step 5: Verify clean state
cmdkey /list  # Should return "No credentials are stored"
```

**Rollback:** Not possible — credentials are cleared. User must re-enter all saved credentials manually. Warn user beforehand.

**Do NOT delete:** `%APPDATA%\Microsoft\Protect\<SID>\` — this is the DPAPI master key store. Deleting it will break DPAPI for all applications and cannot be recovered without the domain backup key.

</details>

<details>
<summary>Fix 4 — Recover DPAPI master key from domain backup</summary>

**Scenario:** User password was reset forcibly (not changed by user), DPAPI blobs encrypted with old key are now inaccessible. Machine is domain-joined.

This uses the MS-BKRP (BackupKey Remote Protocol) to retrieve the domain backup key from a DC.

```powershell
# Check if DPAPI can contact the DC for key backup/recovery
# Event ID 8196 in System log = successful backup key use
Get-WinEvent -FilterHashtable @{LogName='System'; Id=8196; StartTime=(Get-Date).AddDays(-30)} -ErrorAction SilentlyContinue

# Attempt to re-encrypt master key using current credentials
# This happens automatically when user logs on with correct password while DC is reachable
# Trigger: ensure machine has DC line-of-sight and user logs on interactively (not cached)

# If automated recovery fails, use dpapi.exe from Sysinternals or Microsoft PSS tooling
# (requires escalation to Tier 3 or Microsoft support for advanced DPAPI recovery)
```

**Important:** If the machine is Entra-only (no on-premises domain), there is no domain backup key. DPAPI recovery requires:
1. The user's previous password (if known), OR
2. Microsoft account recovery (consumer), OR
3. Accept data loss and rebuild credentials

**Rollback:** N/A — this is a recovery procedure.

</details>

<details>
<summary>Fix 5 — Remove Office 365 cached tokens causing auth loops</summary>

**Scenario:** Outlook or Office apps repeatedly prompt for credentials despite correct password. Modern auth tokens are stale or revoked (e.g., after Conditional Access change, MFA enforcement, or tenant migration).

```powershell
# Step 1: Close all Office applications
Get-Process | Where-Object { $_.Name -match "OUTLOOK|WINWORD|EXCEL|POWERPNT|TEAMS" } | Stop-Process -Force

# Step 2: Remove Office credentials from Credential Manager
$officeTargets = cmdkey /list | Select-String "MicrosoftOffice|office365|windowslive|microsoftonline" 
$officeTargets | ForEach-Object {
    if ($_ -match "Target:\s*(.+)") {
        $target = $Matches[1].Trim()
        Write-Host "Removing: $target"
        cmdkey /delete:$target
    }
}

# Step 3: Clear MSAL/ADAL token cache
$tokenCachePaths = @(
    "$env:LOCALAPPDATA\Microsoft\Office\16.0\",
    "$env:APPDATA\Microsoft\Office\16.0\",
    "$env:LOCALAPPDATA\Microsoft\IdentityCache\"
)
# Note: clearing identity cache signs user out of all Microsoft apps
# Do NOT do this without warning the user
foreach ($path in $tokenCachePaths) {
    if (Test-Path "$path\TokenCache.dat") {
        Remove-Item "$path\TokenCache.dat" -Force -ErrorAction SilentlyContinue
        Write-Host "Cleared: $path\TokenCache.dat"
    }
}

# Step 4: Re-launch Outlook and re-authenticate
Start-Process outlook.exe
```

**Rollback:** User will need to re-authenticate to all Office apps. Save any unsent drafts before proceeding.

</details>

<details>
<summary>Fix 6 — GPO blocking credential storage — document and escalate</summary>

**Scenario:** "Network access: Do not allow storage of passwords and credentials for network authentication" is enabled by GPO. This is a security policy decision — do not override without authorization.

```powershell
# Document which GPO is enforcing this
gpresult /scope user /v 2>$null | Select-String -Context 5,0 "DisableDomainCreds|Do not allow storage"

# Identify the GPO by name
Get-GPResultantSetOfPolicy -ReportType Html -Path "$env:TEMP\rsop-$env:USERNAME.html" 2>$null
```

**Escalation path:** Raise with security/GPO team with business justification. Alternatives to consider:
- Use Windows Hello for Business (PIN/biometric — not affected by this policy)
- Use certificate-based authentication (smart card)
- Configure Kerberos constrained delegation so credentials aren't needed interactively

**Do NOT:** Modify the registry directly to bypass this policy. It will be re-applied at next GPO refresh and may trigger security alerts.

</details>

---

## Evidence Pack

```powershell
<#
  Credential Manager Evidence Collector
  Run as the affected user. Collects vault state, DPAPI health, GPO restrictions, and event logs.
  Output: $env:TEMP\CredentialManager-Evidence-<timestamp>.txt
#>

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile   = "$env:TEMP\CredentialManager-Evidence-$timestamp.txt"
$separator = "`n" + ("=" * 70) + "`n"

function Write-Section {
    param([string]$Title, [scriptblock]$Block)
    $result = try { & $Block | Out-String } catch { "ERROR: $($_.Exception.Message)" }
    Add-Content $outFile "$separator### $Title ###$separator$result"
}

# Header
Set-Content $outFile "=== Credential Manager Evidence Pack === Generated: $(Get-Date) ==="
Add-Content $outFile "User: $env:USERDOMAIN\$env:USERNAME  |  Computer: $env:COMPUTERNAME  |  OS: $(Get-WmiObject Win32_OperatingSystem | Select-Object -Expand Caption)"

Write-Section "Stored Credentials (cmdkey)" { cmdkey /list }
Write-Section "VaultSvc Status" { Get-Service VaultSvc | Select-Object Name, Status, StartType, DisplayName }
Write-Section "DPAPI Master Key Files" {
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $path = "$env:APPDATA\Microsoft\Protect\$sid"
    if (Test-Path $path) { Get-ChildItem $path | Select-Object Name, LastWriteTime, Length }
    else { "Master key directory not found: $path" }
}
Write-Section "Vault Directory Contents" {
    @("$env:LOCALAPPDATA\Microsoft\Vault", "$env:APPDATA\Microsoft\Credentials", "$env:LOCALAPPDATA\Microsoft\Credentials") | ForEach-Object {
        Write-Output "`n[$_]"
        if (Test-Path $_) { Get-ChildItem $_ -Recurse | Select-Object FullName, LastWriteTime, Length }
        else { "Not found" }
    }
}
Write-Section "GPO: Credential Storage Restriction" {
    $val = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -ErrorAction SilentlyContinue).DisableDomainCreds
    "DisableDomainCreds (HKLM): $val (0=allowed, 1=blocked)"
}
Write-Section "DPAPI Round-Trip Test" {
    try {
        Add-Type -AssemblyName System.Security
        $data = [System.Text.Encoding]::UTF8.GetBytes("DPAPIHealthCheck")
        $enc  = [System.Security.Cryptography.ProtectedData]::Protect($data, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $dec  = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        "RESULT: $(if ([System.Text.Encoding]::UTF8.GetString($dec) -eq 'DPAPIHealthCheck') {'PASS'} else {'FAIL (data mismatch)'})"
    } catch {
        "RESULT: FAIL - $($_.Exception.Message)"
    }
}
Write-Section "DPAPI Error Events (last 30 days)" {
    Get-WinEvent -FilterHashtable @{LogName='Application'; Id=8198,8199; StartTime=(Get-Date).AddDays(-30)} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, Message | Format-List
}
Write-Section "System Events (Credential/DPAPI, last 30 days)" {
    Get-WinEvent -FilterHashtable @{LogName='System'; Id=8196,6281; StartTime=(Get-Date).AddDays(-30)} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, Message | Format-List
}

Write-Host "Evidence saved to: $outFile" -ForegroundColor Green
Invoke-Item (Split-Path $outFile)
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List all credentials | `cmdkey /list` |
| Add Windows credential | `cmdkey /add:<target> /user:<domain\user> /pass:<password>` |
| Add generic credential | `cmdkey /generic:<target> /user:<user> /pass:<password>` |
| Remove credential | `cmdkey /delete:<target>` |
| Remove all credentials | `cmdkey /list \| Select-String "Target:" \| % { cmdkey /delete:($_ -split "Target: ")[1].Trim() }` |
| Check VaultSvc | `Get-Service VaultSvc` |
| Restart VaultSvc | `Restart-Service VaultSvc -Force` |
| Check DPAPI master key | `dir "$env:APPDATA\Microsoft\Protect\$([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"` |
| Check GPO restriction | `(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa").DisableDomainCreds` |
| Export GPO report | `gpresult /h $env:TEMP\gp.html /f && start $env:TEMP\gp.html` |
| Check DPAPI event errors | `Get-WinEvent -FilterHashtable @{LogName='Application';Id=8198,8199} -MaxEvents 20` |
| Find Office tokens | `cmdkey /list \| Select-String "MicrosoftOffice"` |
| Test DPAPI round-trip | See Validation Steps §4 |
| Check vault file permissions | `icacls "$env:LOCALAPPDATA\Microsoft\Vault"` |

---

## 🎓 Learning Pointers

- **DPAPI is tied to the user identity, not the machine.** When a user's password is force-reset by an admin without the user knowing the old password, DPAPI blobs encrypted with the old key become unrecoverable unless the machine has DC line-of-sight and MS-BKRP can retrieve the domain backup key. This is a common trap in "emergency access" scenarios. See: [DPAPI Overview — Microsoft Docs](https://learn.microsoft.com/en-us/windows/win32/seccng/cng-dpapi)

- **The "Remember my credentials" checkbox is controlled by security policy**, not just the application. The `DisableDomainCreds` setting (`Network access: Do not allow storage of passwords and credentials for network authentication`) globally suppresses this for network authentication. Many engineers waste time debugging "why won't it save" before checking this GPO. See: [CIS Benchmark for Windows — Domain Credential Storage](https://www.cisecurity.org/benchmark/microsoft_windows_desktop)

- **Entra-only devices have no DPAPI recovery path.** On Microsoft Entra-joined (cloud-only) devices, there is no domain backup key. If a user's profile is recreated or their local password changes (via Reset This PC), DPAPI vault data is permanently lost. Design your migration and profile refresh processes with this in mind. See: [DPAPI in an Azure AD environment](https://learn.microsoft.com/en-us/azure/active-directory/devices/concept-primary-refresh-token#dpapi)

- **Outlook Modern Auth tokens live in Credential Manager.** Since Office 365 moved to OAuth2/MSAL, authentication tokens are stored as Generic credentials in WCM under `MicrosoftOffice16_*` or `WindowsLive:*` targets. Stale tokens after Conditional Access policy changes, MFA enforcement, or token revocation cause persistent auth loops. Clearing these entries (after closing Office apps) forces re-authentication and resolves the loop. See: [Modern Authentication in Office clients](https://learn.microsoft.com/en-us/microsoft-365/enterprise/modern-auth-for-office-2013-and-2016)

- **Windows Hello for Business uses a separate NGC vault** that is NOT visible in Credential Manager UI and cannot be managed via `cmdkey`. NGC credentials are TPM-bound and managed through Intune / Group Policy WHfB settings. Don't confuse WHfB PIN issues with classic Credential Manager issues — they require entirely different diagnostic paths. See: [WHfB Technical Deep Dive](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/hello-how-it-works-technology)

- **Credential Manager is a common lateral movement target.** Security tools like Mimikatz specifically target WCM vault and DPAPI to extract plaintext credentials. In a post-breach scenario, any credentials stored in WCM on compromised machines should be treated as exposed. Rotate all secrets found there. Defender for Endpoint (MDE) includes detections for credential dumping from WCM. See: [MITRE ATT&CK T1555.004 — Credentials from Windows Credential Manager](https://attack.mitre.org/techniques/T1555/004/)
