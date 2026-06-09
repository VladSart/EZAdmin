# Microsoft Purview Message Encryption (OME) — Hotfix Runbook (Mode B: Ops)
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

Run these on the affected tenant (Exchange Online PowerShell connected):

```powershell
# 1. Check OME configuration exists
Get-OMEConfiguration | Select-Object Identity, OTPEnabled, ExternalMailExpiryEnabled

# 2. Check IRM (Information Rights Management) is enabled
Get-IRMConfiguration | Select-Object InternalLicensingEnabled, AzureRMSLicensingEnabled, SimplifiedClientAccessEnabled

# 3. Check Azure RMS (AIP/Purview) is provisioned
Test-IRMConfiguration -Sender <admin@yourdomain.com>

# 4. Check mail flow rules applying encryption
Get-TransportRule | Where-Object { $_.ApplyOME -eq $true -or $_.RemoveOMEv2 -eq $true } |
    Select-Object Name, State, Priority, ApplyOME, RemoveOMEv2

# 5. Check user's assigned licenses include Azure Information Protection
Get-MgUserLicenseDetail -UserId <user@domain.com> |
    Select-Object -ExpandProperty ServicePlans |
    Where-Object { $_.ServicePlanName -match "RMS|AIP|MIP" }
```

**Interpretation:**

| Result | Meaning | Action |
|---|---|---|
| `Get-OMEConfiguration` returns nothing | OME not initialised | Run `Set-IRMConfiguration -AzureRMSLicensingEnabled $true` then re-check |
| `Test-IRMConfiguration` fails with `MSOLE2` | AIP service not provisioned | Check AAD tenant has AIP provisioned (requires M365 E3/E5 or AIP P1/P2) |
| Transport rule exists but `State: Disabled` | Rule not active | Enable rule: `Enable-TransportRule -Identity "<RuleName>"` |
| User missing `RMS_S_PREMIUM` service plan | License not assigned or disabled | Assign M365 E3/E5 or EMS E3/E5 |
| `SimplifiedClientAccessEnabled: False` | New OME features disabled | Enable: `Set-IRMConfiguration -SimplifiedClientAccessEnabled $true` |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft 365 Tenant
    │
    ├── Azure Information Protection (AIP) / Microsoft Purview
    │       └── Azure RMS service provisioned (automatic with qualifying license)
    │
    ├── Exchange Online
    │       ├── IRM enabled (InternalLicensingEnabled: True)
    │       ├── AzureRMSLicensingEnabled: True
    │       └── SimplifiedClientAccessEnabled: True (for new OME)
    │
    ├── Mail Flow Rules (Transport Rules)
    │       └── ApplyOME: True OR ApplyRMSTemplate: True
    │           triggered by condition (e.g. recipient outside org, keyword, label)
    │
    └── User License
            └── Must include: Azure RMS / AIP Plan 1 or 2
                (Included in: M365 E3, M365 E5, EMS E3, EMS E5, AIP standalone)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm IRM/OME is functional**
```powershell
Test-IRMConfiguration -Sender <admin@yourdomain.com>
```
- **Good:** `OVERALL RESULT: PASS`
- **Bad:** Any `FAIL` — note the failing test name for fix paths below

**Step 2 — Check mail flow rule targeting**
```powershell
Get-TransportRule | Where-Object { $_.ApplyOME -eq $true } |
    Select-Object Name, State, Conditions, Exceptions | Format-List
```
- **Good:** Rule exists, State = `Enabled`, conditions match your intended use case
- **Bad:** Rule missing or disabled — see Fix 1

**Step 3 — Test send with message trace**
```powershell
# After sending a test encrypted message, check trace:
Get-MessageTrace -SenderAddress <sender@domain.com> -RecipientAddress <recipient@external.com> -StartDate (Get-Date).AddHours(-1) |
    Select-Object Received, Status, MessageId | Sort-Object Received -Descending | Select-Object -First 5
```
- **Good:** `Status: Delivered`
- **Bad:** `Status: Failed` or `FilteredAsSpam` — check EOP policy

**Step 4 — Confirm recipient can open encrypted message**
- External recipients (non-Microsoft) access via OTP (one-time passcode) or Google/Microsoft sign-in
- Check OTP is enabled: `(Get-OMEConfiguration).OTPEnabled` should be `True`

**Step 5 — Check branding/template if custom OME branding used**
```powershell
Get-OMEConfiguration | Select-Object Identity, PortalText, DisclaimerText, BackgroundColor
```

---

## Common Fix Paths

<details><summary>Fix 1 — Create or fix OME mail flow rule</summary>

```powershell
# Create a new rule to encrypt all mail to external recipients
New-TransportRule -Name "Encrypt outbound to external" `
    -SentToScope NotInOrganization `
    -ApplyOME $true `
    -Enabled $true

# Or enable an existing disabled rule
Enable-TransportRule -Identity "<RuleName>"

# Verify
Get-TransportRule -Identity "<RuleName>" | Select-Object Name, State, ApplyOME
```

**Rollback:**
```powershell
Disable-TransportRule -Identity "<RuleName>"
# or
Remove-TransportRule -Identity "<RuleName>" -Confirm:$false
```

</details>

<details><summary>Fix 2 — Enable IRM and AzureRMS licensing</summary>

```powershell
# Enable IRM for Exchange Online
Set-IRMConfiguration -InternalLicensingEnabled $true
Set-IRMConfiguration -AzureRMSLicensingEnabled $true
Set-IRMConfiguration -SimplifiedClientAccessEnabled $true

# Verify
Get-IRMConfiguration | Select-Object InternalLicensingEnabled, AzureRMSLicensingEnabled, SimplifiedClientAccessEnabled

# Re-test
Test-IRMConfiguration -Sender <admin@yourdomain.com>
```

**Note:** Allow up to 15 minutes after enabling for changes to propagate.

**Rollback:**
```powershell
Set-IRMConfiguration -InternalLicensingEnabled $false
Set-IRMConfiguration -AzureRMSLicensingEnabled $false
```

</details>

<details><summary>Fix 3 — Recipient cannot open encrypted message (OTP issue)</summary>

```powershell
# Ensure OTP is enabled for external recipients
Get-OMEConfiguration | Select-Object OTPEnabled

# Enable OTP if disabled
Set-OMEConfiguration -Identity "OME Configuration" -OTPEnabled $true

# If using custom OME branding template:
Get-OMEConfiguration
# Note the Identity of your custom template, then:
Set-OMEConfiguration -Identity "<CustomTemplateName>" -OTPEnabled $true
```

**Verify** by sending a test encrypted message to an external Gmail/Yahoo address and confirming the OTP prompt appears.

</details>

<details><summary>Fix 4 — Remove encryption from specific messages (revoke/remove OME)</summary>

```powershell
# Remove OME from a specific message (requires message ID from trace)
$messageId = "<messageID>"

# Remove OME from a message before delivery (via transport rule exception):
# Add the sender or recipient to an exception in the existing OME rule:
Set-TransportRule -Identity "<OME Rule Name>" `
    -ExceptIfFrom "<exception_sender@domain.com>"

# For messages already sent — revoke via Purview portal:
# compliance.microsoft.com → Information protection → Revoke access
# OR via PowerShell (requires AIPService module):
# Get-AIPServiceDocument | Revoke-AIPServiceAccess
```

</details>

<details><summary>Fix 5 — Custom OME branding not applying</summary>

```powershell
# Check custom template exists and is associated with the transport rule
Get-OMEConfiguration
# Note the Identity name

# Check the transport rule is set to use the custom template (not default)
Get-TransportRule | Where-Object { $_.ApplyOME -eq $true } |
    Select-Object Name, ApplyRMSTemplate

# If the rule uses ApplyOME ($true) it applies the DEFAULT template
# To use a custom template, use ApplyRMSTemplate instead:
Set-TransportRule -Identity "<RuleName>" `
    -ApplyOME $false `
    -ApplyRMSTemplate "<CustomOMETemplateName>"

# List available RMS templates
Get-RMSTemplate -Type All | Select-Object Name, Description
```

</details>

---

## Escalation Evidence

```
=== OME ESCALATION TICKET ===
Date/Time:
Tenant Domain:
Affected User(s):
Issue Description:

--- IRM Config ---
[Paste output of: Get-IRMConfiguration | Select-Object *]

--- OME Config ---
[Paste output of: Get-OMEConfiguration]

--- Test-IRM Result ---
[Paste output of: Test-IRMConfiguration -Sender <admin@domain.com>]

--- Transport Rules (OME) ---
[Paste output of: Get-TransportRule | Where-Object { $_.ApplyOME -eq $true } | Format-List]

--- Message Trace (last 2 hours) ---
[Paste output of: Get-MessageTrace -SenderAddress <sender> -RecipientAddress <recipient> -StartDate (Get-Date).AddHours(-2)]

--- User License (AIP/RMS plans) ---
[Paste output of: Get-MgUserLicenseDetail -UserId <user> | Select-Object -ExpandProperty ServicePlans | Where-Object { $_.ServicePlanName -match "RMS|AIP|MIP" }]

Escalation contact: Microsoft 365 Support via admin.microsoft.com
```

---

## 🎓 Learning Pointers

- **OME v1 vs. new OME (Purview Message Encryption):** The original OME (v1) required S/MIME certificates and complex recipient setup. New OME (enabled by `SimplifiedClientAccessEnabled`) uses a web portal with OTP or social identity login — no certificates required for recipients. Always confirm which version is in use. See [Compare OME versions](https://learn.microsoft.com/en-us/purview/ome-version-comparison).

- **Licensing gates OME:** OME is included in Microsoft 365 E3, E5, Business Premium, and the EMS E3/E5 suite. If a user lacks the `RMS_S_PREMIUM` service plan, encryption will fail silently — messages are sent but not encrypted. Always verify license at user level, not just tenant level.

- **Transport rule conditions are the targeting engine.** OME is applied (or removed) entirely via mail flow rules. Common patterns: encrypt all outbound, encrypt when subject contains "[Secure]", remove encryption for a trusted partner domain. Study transport rule predicates to build precise rules: [Exchange mail flow rule conditions](https://learn.microsoft.com/en-us/exchange/security-and-compliance/mail-flow-rules/conditions-and-exceptions).

- **Decryption for compliance works automatically.** Despite messages being encrypted in transit, Exchange Online's compliance features (eDiscovery, DLP, audit log, journal rules) can still inspect OME-protected message content. This is by design and requires no special configuration. See [OME and compliance](https://learn.microsoft.com/en-us/purview/ome-advanced-message-encryption).
