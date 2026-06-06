# Windows Hello for Business — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Trust Model Comparison](#trust-model-comparison)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- **Applies to:** Windows 10 21H2+ / Windows 11, Entra ID Joined and Hybrid Entra ID Joined devices
- **Trust models covered:** Cloud Kerberos Trust, Key Trust, Certificate Trust
- **Does not cover:** FIDO2 security keys, Phone Sign-in, on-premises only deployments without Entra
- **Assumes:** At least one of the following: Entra ID P1, Microsoft 365 Business Premium, or equivalent licensing
- **Run As:** Domain Admin + Entra Global Admin, or Intune Administrator (for Intune-managed scenarios)

---

## How It Works

<details><summary>Full architecture — provisioning, authentication, and trust flows</summary>

### What WHfB Is

Windows Hello for Business replaces password authentication with a **public/private key pair** (or certificate) tied to the device TPM. The private key never leaves the device. Authentication proves possession of the device + a gesture (PIN/biometric).

### Provisioning Flow

```
User logs in → WHfB registration triggered →
  1. Device generates key pair in TPM
  2. Public key registered to Entra ID (via WHfB key registration endpoint)
  3. Key written to: user's msDS-KeyCredentialLink (hybrid) or Entra user object (cloud)
  4. Provisioning ceremony: user sets PIN/biometric
  5. PRT (Primary Refresh Token) updated to include WHfB claim (ngcmfa=1)
```

### Authentication Flow (Cloud Kerberos Trust)

```
User gestures (PIN/bio) →
  Windows unlocks TPM-bound private key →
  Sends assertion to Entra ID →
  Entra issues new PRT with MFA claim →
  For on-prem resources: Kerberos TGT obtained via Entra Kerberos (cloud TGT) →
  TGT exchanged for service tickets against on-prem DC →
  Access granted
```

### Authentication Flow (Key Trust / Cert Trust)

```
Key Trust:
  Gesture unlocks key → DC validates WHfB public key (from AD msDS-KeyCredentialLink) →
  Kerberos TGT issued from on-prem DC directly

Certificate Trust:
  Gesture unlocks key → NDES/ADCS issues certificate at provisioning time →
  DC validates certificate → Kerberos TGT issued
```

### Why Cloud Kerberos Trust Is Preferred

Cloud Kerberos Trust eliminates the need for DC certificate issuance (removing ADCS dependency for WHfB) and has simpler deployment. It requires Entra Kerberos (formerly AzureAD Kerberos) to be configured on your forest.

### Key Objects

| Object | Location | Purpose |
|--------|----------|---------|
| `msDS-KeyCredentialLink` | AD user attribute | Stores WHfB public key (Key/Cert Trust) |
| NGC container | `C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc` | On-device key storage |
| WHfB key in Entra | User > Authentication Methods | Entra-side key registration |
| PRT (ngcmfa claim) | LSASS / Browser SSO extension | Proves WHfB was used |

</details>

---

## Dependency Stack

```
[User Gesture — PIN / Biometric]
         │
[TPM 2.0 — private key locked]
         │
[Windows Hello for Business Policy]
    ├── Intune / GPO delivery
    └── RequireSecurityDevice = TRUE
         │
[Entra ID — Key Registration]
    ├── WHfB license check (AAD P1 or M365 BP+)
    ├── MFA satisfied at provisioning time
    └── Entra Kerberos configured (Cloud Kerberos Trust)
         │
[AD Forest — Entra Kerberos Server Object]        [ADCS — only Cert Trust]
    └── msDS-KeyCredentialLink sync (hybrid)
         │
[Domain Controller — Windows Server 2016+]
    └── DC has "Read keyCredentialLink" permission
         │
[Network — Line of Sight for Kerberos]
    ├── UDP/TCP 88 to DC
    └── TCP 443 to *.microsoftonline.com, *.windows.net
```

---

## Trust Model Comparison

| Feature | Cloud Kerberos Trust | Key Trust | Certificate Trust |
|---------|---------------------|-----------|------------------|
| ADCS required | ❌ No | ❌ No | ✅ Yes |
| Entra Kerberos required | ✅ Yes | ❌ No | ❌ No |
| DC min version | 2016 (read KCL) | 2016 | 2008R2 |
| Smart card emulation | ✅ Yes (Entra-issued cert) | ❌ No | ✅ Yes |
| RDP into legacy DCs | ✅ | ❌ | ✅ |
| Complexity | Low | Medium | High |
| MSP recommendation | ✅ Preferred | Legacy | ADCS-heavy envs |

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| "Something went wrong" during PIN setup | TPM not available or not enabled | `Get-Tpm` — check `TpmPresent`, `TpmReady` |
| Provisioning stuck at "Setting up your PIN" | Policy not delivered, or MFA not satisfied | Check Event ID 360 in Microsoft-Windows-User Device Registration |
| WHfB registered but can't get Kerberos tickets on-prem | Entra Kerberos not configured / DC too old | `klist get krbtgt` — look for AzureAD-issued TGT |
| "Your PIN is no longer available" after reset | NGC container corrupted or TPM cleared | Check NGC folder; re-provision via Intune |
| Provisioning fails with error 0x801c0451 | Device not compliant / not joined properly | Verify Entra join state via `dsregcmd /status` |
| PIN works locally, not for RDP | RDP credential provider not using WHfB | Check `AllowRemoteDesktopAuthWithBiometric` policy |
| WHfB policy shows "Not configured" in Intune | Policy not scoped to device/user group | Verify assignment; check MDM enrollment |
| `msDS-KeyCredentialLink` empty in AD | Entra Connect not syncing WHfB keys | Check Entra Connect version (must be 1.4.x+) |
| Event ID 5140 — NGC key not found | Key deleted or TPM ownership changed | Re-register: delete NGC folder + re-provision |
| Provisioning error 0x80090016 | TPM attestation failed or key storage full | `Clear-Tpm` (only after backup!), check TPM firmware |

---

## Validation Steps

**1. Verify Entra join state and WHfB registration**
```powershell
dsregcmd /status
```
Expected in output:
```
AzureAdJoined : YES
EnterpriseJoined : NO          # (for pure cloud-joined)
DomainJoined : YES             # (for hybrid)
NgcSet : YES                   # WHfB key provisioned
NgcKeyId : {GUID}
MfaAuthenticated : YES
```
Bad: `NgcSet : NO` → provisioning failed or not yet attempted.

**2. Verify TPM readiness**
```powershell
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmActivated, TpmOwned
```
Expected: all values `True`. If `TpmReady : False`, check UEFI TPM settings.

**3. Verify WHfB policy delivery**
```powershell
# Check MDM policy
Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" |
    Where-Object { $_.Id -in 360,362,364 } | Select-Object -First 10 TimeCreated, Id, Message
```
- Event 360: provisioning started
- Event 362: provisioning succeeded
- Event 364: provisioning failed (includes error code)

**4. Verify Entra Kerberos is configured (Cloud Kerberos Trust)**
```powershell
# Run on DC or machine with AD module
Import-Module ActiveDirectory
Get-ADObject -Filter {ObjectClass -eq "msAzureADKerberos"} -SearchBase "CN=AzureAD,CN=System,DC=<domain>,DC=<com>" -Properties *
```
Expected: object exists with `msDS-KeyVersionNumber` populated.
Bad: "Cannot find object" → Entra Kerberos not configured.

**5. Verify Kerberos tickets include cloud TGT**
```powershell
klist
```
Look for a TGT from `AzureAD\<tenant>` in addition to the on-prem domain TGT.

**6. Verify policy in registry**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Policies\PassportForWork\<TenantID>\Device\Policies" -ErrorAction SilentlyContinue
```
`Enabled : 1` and `RequireSecurityDevice : 1` expected.

**7. Check Intune WHfB policy status**
```powershell
# Check IME log for WHfB policy delivery
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" |
    Where-Object { $_.Message -match "PassportForWork" } | Select-Object -First 10 TimeCreated, Message
```

---

## Troubleshooting Steps by Phase

### Phase 1 — Policy Not Delivered

1. Check Intune assignment — device must be in scope of WHfB configuration profile
2. Verify device enrollment status: `Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" | Where-Object Id -eq 813`
3. Trigger sync: `Start-Process -FilePath "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o"`
4. Re-check registry keys listed in Validation Step 6

### Phase 2 — Provisioning Fails

1. Collect Event ID 364 from `Microsoft-Windows-User Device Registration/Admin` — note hex error code
2. Common error codes:
   - `0x801c0451` — device not compliant (check Intune compliance) or CA blocks provisioning
   - `0x801c044d` — MFA not satisfied at provisioning time (user must MFA during OOBE/first login)
   - `0x80090016` — TPM key storage provider error (clear TPM or check firmware)
   - `0x80090030` — No suitable TPM found (enable in UEFI, or set `RequireSecurityDevice = 0` for software key fallback)
3. Verify MFA registration: user must have MFA method registered in Entra before provisioning
4. Check Conditional Access: a CA policy may be blocking the `Windows Sign In` or `Device Registration Service` app

### Phase 3 — Provisioned but On-Prem Resources Fail

1. Confirm Cloud Kerberos Trust: `klist` — look for AzureAD TGT
2. If no AzureAD TGT: check Entra Kerberos server object (Validation Step 4)
3. DC must be Windows Server 2016+ for Cloud Kerberos Trust decryption
4. Check DC event log for Kerberos errors: `Get-WinEvent -LogName System | Where-Object { $_.Id -in 4, 14, 42 }`
5. Verify `msDS-KeyCredentialLink` on AD user object (Key Trust only): `Get-ADUser <user> -Properties msDS-KeyCredentialLink | Select-Object -ExpandProperty msDS-KeyCredentialLink`

### Phase 4 — PIN Corrupted / "No Longer Available"

1. Check NGC folder: `Get-ChildItem "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc" -Recurse -ErrorAction SilentlyContinue`
2. If folder is empty or corrupt → re-provision:
   - Remove WHfB method from Entra: `Entra Portal > Users > [User] > Authentication Methods > delete WHfB key`
   - Clear NGC: `icacls "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc" /T /Q /C /RESET` then `Remove-Item "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc\*" -Recurse -Force`
   - User re-provisions on next login
3. If TPM was cleared: user must complete full provisioning ceremony again

---

## Remediation Playbooks

<details><summary>Playbook 1 — Configure Entra Kerberos for Cloud Kerberos Trust</summary>

**Run on a DC or machine with AD PowerShell module + AzureAD/Graph access**

```powershell
# Install module if needed
Install-Module -Name AzureADHybridAuthenticationManagement -Force

# Connect to Entra and AD
Import-Module AzureADHybridAuthenticationManagement

# Create/verify Entra Kerberos server object in AD
$domain = (Get-ADDomain).DNSRoot
Set-AzureADKerberosServer -Domain $domain -UserPrincipalName "<GlobalAdmin@tenant.onmicrosoft.com>"

# Verify
Get-AzureADKerberosServer -Domain $domain -UserPrincipalName "<GlobalAdmin@tenant.onmicrosoft.com>"
```

Expected output: `Id`, `UserAccount`, `ComputerAccount`, `DisplayName`, `DomainDnsName` all populated.

**Rollback:** To remove, use `Remove-AzureADKerberosServer`. This will break Cloud Kerberos Trust for all users — only do this intentionally.

</details>

<details><summary>Playbook 2 — Deploy WHfB policy via Intune</summary>

```powershell
# Verify current Intune WHfB policy via Graph
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"

$policies = Get-MgDeviceManagementDeviceConfiguration | Where-Object { $_.DisplayName -match "Hello" -or $_.ODataType -match "windowsIdentityProtection" }
$policies | Select-Object DisplayName, Id, ODataType

# Check assignments
foreach ($p in $policies) {
    $assignments = Get-MgDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId $p.Id
    Write-Host "Policy: $($p.DisplayName)" -ForegroundColor Cyan
    $assignments | Select-Object -ExpandProperty Target | Format-Table
}
```

**Intune portal path:** Devices > Configuration > Create > Windows 10+ > Identity Protection  
Key settings:
- Configure Windows Hello for Business: **Enabled**
- Use a Trusted Platform Module (TPM): **Required**
- Minimum PIN length: **6** (recommended)
- Use enhanced anti-spoofing: **Enabled** (if hardware supports)
- Use certificate for on-premises resources: **Disabled** (Cloud Kerberos Trust)

</details>

<details><summary>Playbook 3 — Force re-provisioning for a user (NGC reset)</summary>

**⚠️ Destructive — user will need to re-enroll PIN/biometric**

```powershell
# Step 1: Remove WHfB key from Entra (run as admin with Graph permissions)
Connect-MgGraph -Scopes "UserAuthenticationMethod.ReadWrite.All"
$userId = (Get-MgUser -Filter "userPrincipalName eq '<user@domain.com>'").Id
$methods = Get-MgUserAuthenticationWindowsHelloForBusinessMethod -UserId $userId
foreach ($m in $methods) {
    Remove-MgUserAuthenticationWindowsHelloForBusinessMethod -UserId $userId -WindowsHelloForBusinessAuthenticationMethodId $m.Id
    Write-Host "Removed WHfB key: $($m.Id)" -ForegroundColor Yellow
}

# Step 2: Reset NGC folder on device (run locally as SYSTEM or via Intune script)
$ngcPath = "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"
if (Test-Path $ngcPath) {
    icacls $ngcPath /T /Q /C /RESET
    Remove-Item "$ngcPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "NGC folder cleared" -ForegroundColor Green
} else {
    Write-Host "NGC folder not found" -ForegroundColor Yellow
}

# Step 3: Trigger device sync to re-deliver WHfB policy
Start-Process -FilePath "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o"
Write-Host "User will be prompted to set up PIN on next login" -ForegroundColor Cyan
```

</details>

<details><summary>Playbook 4 — Audit WHfB registration status across tenant</summary>

```powershell
# Report all users with/without WHfB registered
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All", "User.Read.All"

$users = Get-MgUser -All -Filter "accountEnabled eq true" -Property DisplayName,UserPrincipalName,Id

$report = foreach ($user in $users) {
    $methods = @()
    try {
        $methods = Get-MgUserAuthenticationWindowsHelloForBusinessMethod -UserId $user.Id -ErrorAction Stop
    } catch {}
    
    [PSCustomObject]@{
        DisplayName       = $user.DisplayName
        UPN               = $user.UserPrincipalName
        WHfBRegistered    = ($methods.Count -gt 0)
        KeyCount          = $methods.Count
        DeviceNames       = ($methods | Select-Object -ExpandProperty DisplayName) -join "; "
    }
}

$report | Sort-Object WHfBRegistered | Export-Csv "$env:TEMP\WHfB-Registration-Report.csv" -NoTypeInformation
Write-Host "Report saved to $env:TEMP\WHfB-Registration-Report.csv"

# Summary
$registered = ($report | Where-Object WHfBRegistered).Count
$total = $report.Count
Write-Host "Registered: $registered / $total ($([math]::Round($registered/$total*100,1))%)" -ForegroundColor Cyan
```

</details>

---

## Evidence Pack

```powershell
# WHfB Evidence Collector — run on affected device
$out = "$env:TEMP\WHfB-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

# 1. Device join state
dsregcmd /status > "$out\dsregcmd-status.txt"

# 2. TPM state
Get-Tpm | Out-File "$out\tpm-status.txt"
Get-TpmSupportedFeature * 2>$null | Out-File "$out\tpm-features.txt"

# 3. WHfB provisioning events
Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message | Export-Csv "$out\UDR-events.csv" -NoTypeInformation

# 4. Intune MDM events
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match "Passport|Hello|PIN" } |
    Select-Object TimeCreated, Id, Message | Export-Csv "$out\MDM-Hello-events.csv" -NoTypeInformation

# 5. Registry — WHfB policy
$regPaths = @(
    "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork",
    "HKLM:\SOFTWARE\Microsoft\Policies\PassportForWork"
)
foreach ($path in $regPaths) {
    if (Test-Path $path) {
        Get-ItemProperty -Path $path | Out-File "$out\registry-whfb-policy.txt" -Append
    }
}

# 6. NGC folder existence
$ngcPath = "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"
if (Test-Path $ngcPath) {
    Get-ChildItem $ngcPath -Recurse -ErrorAction SilentlyContinue | Out-File "$out\ngc-folder-contents.txt"
} else {
    "NGC folder not found" | Out-File "$out\ngc-folder-contents.txt"
}

# 7. Kerberos tickets
klist > "$out\klist-output.txt"

# 8. System info
$env:COMPUTERNAME | Out-File "$out\device-info.txt"
(Get-WmiObject Win32_OperatingSystem).Caption >> "$out\device-info.txt"
(Get-WmiObject Win32_ComputerSystem).Domain >> "$out\device-info.txt"

Compress-Archive -Path "$out\*" -DestinationPath "$out.zip"
Write-Host "Evidence pack: $out.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# 1. Full device join/WHfB state
dsregcmd /status

# 2. TPM readiness
Get-Tpm

# 3. WHfB provisioning events (last 20)
Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 20 | Where-Object Id -in 360,362,364

# 4. Check WHfB policy in registry
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"

# 5. List current Kerberos tickets
klist

# 6. Check Entra Kerberos server object
Get-ADObject -Filter {ObjectClass -eq "msAzureADKerberos"} -SearchBase "CN=AzureAD,CN=System,DC=domain,DC=com" -Properties *

# 7. Verify user's WHfB keys in Entra (Graph)
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All"
Get-MgUserAuthenticationWindowsHelloForBusinessMethod -UserId "<user@domain.com>"

# 8. Force Intune policy sync
Start-Process -FilePath "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o"

# 9. Check msDS-KeyCredentialLink (hybrid only)
Get-ADUser <samaccountname> -Properties msDS-KeyCredentialLink | Select-Object -ExpandProperty msDS-KeyCredentialLink

# 10. Clear NGC folder (destroys local WHfB keys — user must re-enroll)
icacls "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc" /T /Q /C /RESET
Remove-Item "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc\*" -Recurse -Force

# 11. Remove WHfB key from Entra (Graph)
Remove-MgUserAuthenticationWindowsHelloForBusinessMethod -UserId "<userId>" -WindowsHelloForBusinessAuthenticationMethodId "<methodId>"

# 12. Get all users without WHfB registered
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All", "User.Read.All"
Get-MgUser -All -Filter "accountEnabled eq true" | ForEach-Object {
    $keys = Get-MgUserAuthenticationWindowsHelloForBusinessMethod -UserId $_.Id -ErrorAction SilentlyContinue
    if (-not $keys) { $_.UserPrincipalName }
}

# 13. Configure Entra Kerberos (Cloud Kerberos Trust setup)
Set-AzureADKerberosServer -Domain (Get-ADDomain).DNSRoot -UserPrincipalName "<admin@tenant.com>"

# 14. Verify Intune WHfB policy assignment
Get-MgDeviceManagementDeviceConfiguration | Where-Object ODataType -match "windowsIdentityProtection"
```

---

## 🎓 Learning Pointers

- **Cloud Kerberos Trust eliminates ADCS** — it uses a cloud-issued Kerberos TGT converted to on-prem service tickets. If you're starting a new WHfB deployment in a hybrid environment, this is always the right choice. [MS Docs: Plan Cloud Kerberos Trust](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/deploy/hybrid-cloud-kerberos-trust)

- **The NGC folder is not directly ACL-accessible to admins** — it lives under SYSTEM's profile. To inspect or clear it, you need `icacls` to reset permissions first. Attempting `Remove-Item` directly will fail with access denied.

- **Event ID 364 is your best friend for provisioning failures** — the hex error code in this event maps to a specific failure reason. Always decode it first before chasing the wrong thread. [Error code reference](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/hello-errors-during-pin-creation)

- **WHfB satisfies MFA for Conditional Access** — once provisioned, a WHfB sign-in includes `ngcmfa=1` in the PRT, satisfying MFA claims in CA policies. This is why provisioning itself requires MFA at enrollment time: it bootstraps MFA assurance into the credential.

- **Entra Connect version matters for key sync** — versions older than 1.4.x do not sync `msDS-KeyCredentialLink`. If hybrid users' keys aren't appearing in AD (needed for Key Trust or passthrough scenarios), check the Entra Connect version first.

- **TPM firmware bugs cause key storage errors** — 0x80090016 and similar TPM errors are often firmware-related on Dell/HP/Lenovo laptops. Check the vendor's TPM firmware update and apply before clearing TPM. Clearing TPM without a firmware update may cause the same error to repeat. [TPM recommendations](https://learn.microsoft.com/en-us/windows/security/hardware-security/tpm/trusted-platform-module-overview)
