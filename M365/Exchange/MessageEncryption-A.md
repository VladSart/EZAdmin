# Microsoft Purview Message Encryption (OME) — Reference Runbook (Mode A: Deep Dive)
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

**Applies to:** Microsoft 365 tenants with Exchange Online; Microsoft Purview Message Encryption (formerly OME — Office Message Encryption)  
**Licence required:** Azure Information Protection Plan 1 (included in Microsoft 365 E3, Business Premium, F3) or higher  
**Does not cover:** S/MIME encryption, on-premises Exchange encryption, third-party DLP email encryption

Microsoft Purview Message Encryption (PME) is the successor to legacy OME and Azure RMS-based email encryption. Understanding which generation a tenant is running is the first diagnostic step — the troubleshooting paths diverge significantly between legacy OME and the modern PME (which uses sensitivity labels and Azure RMS templates directly).

---

## How It Works

<details><summary>Full architecture</summary>

### Encryption Flow

```
Sender (Exchange Online / Outlook Client)
    │
    │  Mail Transport Rule evaluates message
    │  (or Sensitivity Label applied in Outlook client)
    │
    ▼
Exchange Online Transport Service
    │
    ├── Applies IRM/AIP Protection:
    │   └── Calls Azure Rights Management Service (Azure RMS)
    │       ├── Tenant RMS key retrieved (from BYOK or Microsoft-managed key vault)
    │       └── Protection policy (template) applied to message body + attachments
    │
    ▼
Encrypted Message in Transit (TLS + RMS double-encryption)
    │
    ▼
Recipient Mail System
    ├── [M365 Recipient] — Direct IRM decryption via tenant trust
    ├── [External Recipient with OME Portal] — HTML wrapper with portal link
    │       └── Recipient authenticates (MSA, Google, OTP)
    │           └── RMS key fetched from Azure Key Vault via OME portal service
    └── [External with direct decryption] — If S/MIME or federated trust established
```

### Template & Policy Hierarchy
```
Microsoft 365 Admin
    └── Purview Compliance Portal
            └── Sensitivity Labels  ──────────────────────────────┐
                    └── Label defines: encryption, scope,          │
                        permissions (who can read, forward, etc.)  │
                                                                   ▼
Microsoft Purview / Azure Information Protection              Azure RMS
    └── OME Configuration (branding)                              └── Rights Templates
            └── Applied by mail transport rule                          └── Define
                or client-side label                                        permission sets
```

### OME Portal Flow (External Recipients)
1. Sender applies encryption (transport rule or label).
2. Exchange Online wraps the encrypted message in an HTML attachment.
3. Recipient receives wrapper email with a "Read the message" link.
4. Link opens `https://nam.to.osi.office365.com` (OME portal — Microsoft-hosted).
5. Recipient authenticates (Microsoft Account, Google, Yahoo, or one-time passcode).
6. Portal fetches decryption key from Azure RMS using recipient's authenticated identity.
7. Message is decrypted and rendered in the portal browser session.

### Modern PME vs. Legacy OME

| Feature | Legacy OME | Modern PME (current) |
|---------|-----------|---------------------|
| Encryption basis | Azure RMS templates | Sensitivity Labels + AIP/RMS |
| Admin configuration | `Set-IRMConfiguration` | Sensitivity Labels in Purview |
| Branding | `Set-OMEConfiguration` | Custom branding templates |
| Revoke message | No | Yes (via `Set-AipServiceDocumentRevoked`) |
| External auth | MSA, OTP | MSA, Google, OTP, or federated |
| Audit | Basic | Full Purview audit trail |

</details>

---

## Dependency Stack

```
User / Outlook Client
        │
        ▼
Sensitivity Label policy (Purview) / Mail Transport Rule (EXO)
        │
        ▼
Exchange Online Transport Service
        │
        ▼
Azure Information Protection Service (IRM)
        │
        ├──► Azure Rights Management Service (Azure RMS)
        │       └── Microsoft-managed or BYOK key in Azure Key Vault
        │
        └──► OME Configuration (branding templates)
                └── Stored in Exchange Online, applied at delivery

Recipient Decryption:
    M365-to-M365: Direct RMS decryption (no portal needed)
    External: OME Portal (office365.com) + authentication
```

**Critical licensing dependencies:**
- Azure Information Protection Plan 1 (minimum) — included in E3/Business Premium
- Exchange Online Plan 1 or 2 (IRM must be enabled)
- RMS service principal must be provisioned in tenant AAD

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Encrypted emails not being sent (transport rule not triggering) | Transport rule condition wrong; label not applied | `Get-TransportRule | Where {$_.MessageContainsDataClassifications -or $_.ApplyRightsProtectionTemplate}` |
| Recipients see "Action Required" wrapper but can't open | OME portal auth failure; recipient blocked by Conditional Access | Test OTP flow in browser; check CA sign-in logs |
| Internal M365 recipients can't decrypt | IRM not enabled in tenant or mailbox; RMS tenant key issue | `Get-IRMConfiguration` → check `InternalLicensingEnabled` |
| `The certificate is not trusted` error in Outlook | Outlook RMS certificate cache stale | Clear `%LOCALAPPDATA%\Microsoft\MSOIDSVC.MSA` and Office RMS cache |
| Encryption applied but no branding (plain OME wrapper) | Default OME template in use; custom branding not configured | `Get-OMEConfiguration | Select-Object Identity, OTPEnabled` |
| External recipient one-time passcode not arriving | OTP email going to spam; OTP not enabled in OME config | Check recipient spam; `Get-OMEConfiguration \| Select OTPEnabled` |
| Sensitivity label not encrypting when applied in Outlook | Label encryption scope misconfigured; AIP unified labelling client issue | `Get-Label | Where {$_.ContentType -match "Email"}` |
| Revocation not working | Document revocation requires Azure RMS P2 licence | Check licence; use `Set-AipServiceDocumentRevoked` |
| `MSIP_Label` headers missing from received encrypted message | Client-side labelling not publishing to header | Check Outlook AIP client version; toggle `EnableOutlookDistributionListExpansion` |
| IRM features greyed out in Outlook/OWA | IRM not enabled for user's mailbox or organisation | `Get-IRMConfiguration`, `Set-IRMConfiguration -InternalLicensingEnabled $true` |

---

## Validation Steps

**1. Check IRM is enabled globally**
```powershell
Connect-ExchangeOnline
Get-IRMConfiguration | Select-Object InternalLicensingEnabled, ExternalLicensingEnabled, AzureRMSLicensingEnabled
```
Expected: All `True`  
Bad: Any `False` → encryption will not work

**2. Verify RMS service is reachable from the tenant**
```powershell
Test-IRMConfiguration -Sender <admin@yourdomain.com>
```
Expected: All tests `PASS`  
Bad: Any `FAIL` with RMS connectivity → check Azure RMS provisioning

**3. Check OME configuration**
```powershell
Get-OMEConfiguration | Select-Object Identity, OTPEnabled, SocialIdSignIn, EmailText
```
Expected: At least one OME config; `OTPEnabled = True` for external recipients  
Bad: No OME config; `OTPEnabled = False` means external users with no MSA cannot authenticate

**4. Verify transport rules for encryption**
```powershell
Get-TransportRule | Where-Object { $_.ApplyRightsProtectionTemplate -or $_.ApplyOMETemplate } |
    Select-Object Name, State, Priority, ApplyRightsProtectionTemplate
```
Expected: Rules `Enabled` with correct priority (lower = higher priority)  
Bad: Rule disabled, wrong priority order, or condition mismatch

**5. Test encryption end-to-end**
```powershell
# Send a test encrypted message
Send-MailMessage -To "<external@example.com>" -From "<sender@yourdomain.com>" `
    -Subject "OME Test" -Body "This is an encrypted test message." `
    -SmtpServer smtp.office365.com -Port 587 -UseSSL `
    -Credential (Get-Credential)
# Note: transport rule must trigger on this message
```

**6. Check RMS templates available to the tenant**
```powershell
Get-RMSTemplate -TrustedEmailDomain "*" | Select-Object TemplateId, TemplateDescription
```
Expected: At least `Encrypt`, `Do Not Forward`, `Confidential` templates present  
Bad: No templates → RMS provisioning issue

**7. Verify sensitivity labels with encryption**
```powershell
Connect-IPPSSession
Get-Label | Where-Object { $_.EncryptionEnabled -eq $true } |
    Select-Object DisplayName, EncryptionEnabled, EncryptionProtectionType
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Confirm Generation (Legacy OME vs Modern PME)
1. Run `Get-IRMConfiguration`. If `AzureRMSLicensingEnabled = True` and you have sensitivity labels in Purview → Modern PME.
2. If using `Set-OMEConfiguration` only without sensitivity labels → Legacy OME.
3. Legacy OME migration to modern PME is done via sensitivity labels + disabling old transport-rule-only flows.

### Phase 2: Transport Rule vs Client Label
1. Is encryption applied by a **transport rule** (server-side, automatic) or a **sensitivity label** (user-applied or auto-labelling)?
2. Transport rule path: check `Get-TransportRule`, verify conditions match test message, check message trace (`Get-MessageTrace`).
3. Sensitivity label path: check label policy is published to the user; check AIP client version; check label encryption settings.

### Phase 3: Recipient Experience Failure
1. **Internal M365 user can't open** → IRM issue (Step 1 validation).
2. **External user, no portal link** → OME wrapper not being applied; check transport rule.
3. **External user, portal link but auth fails** → OTP not enabled; social ID sign-in disabled; or the portal URL is blocked by recipient firewall.
4. **External user authenticated but "access denied"** → Permissions in the RMS template don't include external recipients.

### Phase 4: Outlook Client Issues
1. Clear Office RMS cache:
```powershell
# Remove cached Office RMS tokens
Remove-Item "$env:LOCALAPPDATA\Microsoft\Office\16.0\IRM\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Microsoft\MSOIDSVC.MSA" -Force -ErrorAction SilentlyContinue
```
2. Check if the user's Outlook is connected to the correct tenant (relevant in multi-tenant environments).
3. Verify AIP unified labelling client version ≥ 2.9 for full sensitivity label support.

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Enable IRM / Azure RMS in Exchange Online</summary>

Use when: `Get-IRMConfiguration` shows any `False` values; encryption doesn't work at all.

```powershell
Connect-ExchangeOnline
Set-IRMConfiguration -InternalLicensingEnabled $true
Set-IRMConfiguration -ExternalLicensingEnabled $true
Set-IRMConfiguration -AzureRMSLicensingEnabled $true

# Force RMS template refresh
Set-IRMConfiguration -RefreshServerCertificates
Import-RMSTrustedPublishingDomain -RMSOnline -Name "RMS Online"

# Verify
Test-IRMConfiguration -Sender <admin@yourdomain.com>
```

</details>

<details>
<summary>Fix 2 — Configure or fix OME branding and OTP</summary>

Use when: External recipients getting plain/unbranded wrapper; OTP not arriving.

```powershell
Connect-ExchangeOnline

# Check existing configs
Get-OMEConfiguration | Select-Object Identity, OTPEnabled, SocialIdSignIn

# Enable OTP if disabled
Set-OMEConfiguration -Identity "OME Configuration" -OTPEnabled $true

# Create a custom branded OME configuration
New-OMEConfiguration -Identity "Contoso OME" `
    -EmailText "You have received a confidential message from Contoso." `
    -PortalText "Contoso Secure Message Portal" `
    -DisclaimerText "This message is intended only for the addressee." `
    -BackgroundColor "#0078D4" `
    -OTPEnabled $true `
    -SocialIdSignIn $true

# Apply to a transport rule
Set-TransportRule -Identity "<RuleName>" -ApplyOMETemplate "Contoso OME"
```

**Rollback:** `Remove-OMEConfiguration -Identity "Contoso OME"` (reverts to default OME)

</details>

<details>
<summary>Fix 3 — Create or fix mail transport rule for encryption</summary>

Use when: Encryption not triggering automatically; rule conditions wrong.

```powershell
Connect-ExchangeOnline

# View existing encryption rules
Get-TransportRule | Where-Object { $_.ApplyRightsProtectionTemplate -or $_.ApplyOMETemplate } |
    Format-List Name, State, Priority, Conditions, ApplyRightsProtectionTemplate

# Create a new rule to encrypt messages sent to external recipients with sensitive content
New-TransportRule -Name "Encrypt External - Sensitive Content" `
    -SentToScope NotInOrganization `
    -HasSensitiveDataMatchedClassifications @{Name="Credit Card Number"} `
    -ApplyRightsProtectionTemplate "Encrypt" `
    -Priority 1

# Or: encrypt all external mail from a specific group
New-TransportRule -Name "Encrypt Finance Team External Mail" `
    -FromMemberOf "Finance-Team@<yourdomain>.com" `
    -SentToScope NotInOrganization `
    -ApplyRightsProtectionTemplate "Encrypt" `
    -Priority 2

# Enable the rule
Enable-TransportRule -Identity "Encrypt External - Sensitive Content"
```

**Rollback:** `Disable-TransportRule -Identity "<RuleName>"` or `Remove-TransportRule -Identity "<RuleName>"`

</details>

<details>
<summary>Fix 4 — Fix sensitivity label encryption settings</summary>

Use when: Label applied but encryption not working; label scope/permissions misconfigured.

```powershell
Connect-IPPSSession

# View label encryption config
Get-Label | Where-Object { $_.DisplayName -eq "<LabelName>" } | 
    Select-Object DisplayName, EncryptionEnabled, EncryptionProtectionType, EncryptionRightsDefinitions

# Labels must be configured in Purview Compliance Portal (GUI) for encryption rights
# Programmatic changes:
Set-Label -Identity "<LabelGuid>" -EncryptionEnabled $true `
    -EncryptionProtectionType Template `
    -EncryptionTemplateId "<RMSTemplateId>"

# Verify label is published to users
Get-LabelPolicy | Where-Object { $_.Labels -contains "<LabelGuid>" } |
    Select-Object Name, ExchangeLocation, ModifiedBy
```

</details>

<details>
<summary>Fix 5 — Clear Office RMS cache (Outlook client fix)</summary>

Use when: Outlook can't apply or read encrypted messages; "Access Denied" for a specific user.

```powershell
# Run on the affected client machine
$cacheLocations = @(
    "$env:LOCALAPPDATA\Microsoft\Office\16.0\IRM",
    "$env:LOCALAPPDATA\Microsoft\MSOIDSVC.MSA",
    "$env:APPDATA\Microsoft\Protect"
)

foreach ($path in $cacheLocations) {
    if (Test-Path $path) {
        Write-Host "Clearing: $path" -ForegroundColor Yellow
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Also clear credential manager entries for Office
cmdkey /list | Where-Object { $_ -match "MicrosoftOffice" } | ForEach-Object {
    $target = ($_ -split ":")[1].Trim()
    cmdkey /delete:$target
}

Write-Host "Restart Outlook after running this script." -ForegroundColor Cyan
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects OME/PME health evidence for escalation
.NOTES     Requires Exchange Online and Security & Compliance PowerShell
#>
$outFile = "C:\Temp\OME-Evidence-$(Get-Date -Format yyyyMMdd-HHmm).txt"
New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null

Connect-ExchangeOnline -ErrorAction Stop

{
    "=== OME/PME Evidence Pack — $(Get-Date) ==="
    
    "`n--- IRM Configuration ---"
    Get-IRMConfiguration | Format-List
    
    "`n--- OME Configurations ---"
    Get-OMEConfiguration | Format-List
    
    "`n--- Transport Rules (Encryption) ---"
    Get-TransportRule | Where-Object { $_.ApplyRightsProtectionTemplate -or $_.ApplyOMETemplate } |
        Format-List Name, State, Priority, Conditions, ApplyRightsProtectionTemplate
    
    "`n--- RMS Templates Available ---"
    Get-RMSTemplate -TrustedEmailDomain "*" -ErrorAction SilentlyContinue |
        Select-Object TemplateId, TemplateDescription | Format-Table -AutoSize
    
    "`n--- IRM Test ---"
    Test-IRMConfiguration -Sender "<REPLACE_WITH_SENDER>" 2>&1
    
    "`n--- Sensitivity Labels (Encryption) ---"
    try {
        Connect-IPPSSession -ErrorAction Stop
        Get-Label | Where-Object { $_.EncryptionEnabled -eq $true } |
            Select-Object DisplayName, EncryptionEnabled, EncryptionProtectionType | Format-Table -AutoSize
    } catch {
        "Could not connect to Security & Compliance: $_"
    }

} | ForEach-Object { $_ } | Out-File $outFile -Encoding UTF8

Write-Host "Evidence saved: $outFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Check IRM configuration | `Get-IRMConfiguration \| Format-List` |
| Test IRM end-to-end | `Test-IRMConfiguration -Sender <admin@domain>` |
| List OME configurations | `Get-OMEConfiguration` |
| Enable OTP for OME | `Set-OMEConfiguration -Identity "OME Configuration" -OTPEnabled $true` |
| List transport encryption rules | `Get-TransportRule \| Where { $_.ApplyRightsProtectionTemplate }` |
| List available RMS templates | `Get-RMSTemplate -TrustedEmailDomain "*"` |
| List sensitivity labels with encryption | `Get-Label \| Where { $_.EncryptionEnabled -eq $true }` |
| Enable internal IRM licensing | `Set-IRMConfiguration -InternalLicensingEnabled $true` |
| Enable external IRM licensing | `Set-IRMConfiguration -ExternalLicensingEnabled $true` |
| Refresh RMS templates | `Set-IRMConfiguration -RefreshServerCertificates` |
| Check label policies | `Get-LabelPolicy` |
| Message trace for encrypted mail | `Get-MessageTrace -SenderAddress <sender> -RecipientAddress <rcpt>` |
| Revoke an encrypted document | `Set-AipServiceDocumentRevoked -ContentId <id>` |

---

## 🎓 Learning Pointers

- **Legacy OME vs. Modern PME:** Many tenants are running a mix. Legacy OME uses `Set-OMEConfiguration` and transport rules only. Modern PME integrates with sensitivity labels and offers revocation, expiry, and richer permissions. Microsoft's guidance is to migrate to Modern PME — if `AzureRMSLicensingEnabled` is `True` and you have sensitivity labels, you're already on the modern path. [Microsoft: Set up new OME capabilities](https://docs.microsoft.com/en-us/purview/ome)

- **The OME portal is Microsoft-hosted:** External recipients authenticate at `*.protection.outlook.com`. If a recipient's IT security team blocks that domain or the OTP email gets spam-filtered, they cannot decrypt. The fix is either whitelisting the domain or switching to a federated trust (for business-to-business scenarios). [OME portal URLs for firewall whitelisting](https://docs.microsoft.com/en-us/microsoft-365/compliance/encryption-office-365-tls-certificates-changes)

- **"Encrypt-Only" vs "Do Not Forward":** These are the two most-used built-in RMS templates. `Encrypt-Only` encrypts but allows forwarding/copying. `Do Not Forward` prevents forwarding, printing, and screen capture via IRM. Understanding which to apply in transport rules prevents both over-restriction and under-restriction. [Microsoft: Email encryption options](https://docs.microsoft.com/en-us/purview/email-encryption)

- **BYOK key management adds complexity:** Tenants using Bring Your Own Key (BYOK) in Azure Key Vault add an extra dependency — if the key vault is unavailable (soft-deleted, access policy broken), all encrypted messages become unreadable tenant-wide. For BYOK tenants, include Key Vault health in your IRM monitoring. [Azure RMS BYOK overview](https://docs.microsoft.com/en-us/azure/information-protection/plan-implement-tenant-key)

- **Sensitivity label encryption and external sharing:** A label with encryption restricts who can open the file/email. If a label is misconfigured to allow only specific users and not "Authenticated users," external recipients with OTP will be denied even after portal authentication. Always include "All authenticated users" or specific external domains in the label's encryption rights for external-facing scenarios.

- **AIP Unified Label Client vs built-in Office labelling:** Modern Microsoft 365 Apps (2021+) have labelling built-in without the AIP add-in. The AIP client is only needed for File Explorer integration and advanced classification. If Outlook labels aren't encrypting, check whether the AIP add-in is conflicting with the native labelling — disabling the add-in often resolves it. [Microsoft: AIP unified labelling client vs built-in labelling](https://docs.microsoft.com/en-us/azure/information-protection/rms-client/use-client)
