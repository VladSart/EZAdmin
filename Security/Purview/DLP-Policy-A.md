# Microsoft Purview DLP — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Workload Coverage Map](#workload-coverage-map)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- **Applies to:** Microsoft Purview DLP (formerly Microsoft 365 Compliance DLP)
- **Workloads covered:** Exchange Online, SharePoint Online, OneDrive, Teams, Endpoint DLP (Windows), Power BI
- **Does not cover:** On-premises DLP scanner (separate product), third-party DLP integrations, Insider Risk Management (different engine)
- **Licensing required:** Microsoft 365 E3 (Exchange/SPO/OD/Teams DLP); Microsoft 365 E5 Compliance or E5 (Endpoint DLP, advanced classifiers)
- **Admin roles needed:** Compliance Administrator, DLP Compliance Management (custom role), or Global Admin

---

## How It Works

<details><summary>Full architecture — policy evaluation, SIT matching, enforcement engine</summary>

### The Policy Evaluation Engine

DLP policies are not real-time content scanners — they are **event-driven evaluation engines**. An event (file upload, email send, paste, print, etc.) triggers evaluation against applicable policies for that workload.

```
Event occurs (e.g., file uploaded to SharePoint)
    │
    ▼
Workload DLP agent evaluates:
  1. Does this event match a location in any enabled DLP policy?
  2. Does the content match any conditions in those policies?
  3. Does the context match (user, group, sensitivity label, etc.)?
    │
    ▼
If conditions matched:
  4. Evaluate action(s): audit, alert, block, notify, restrict
  5. Apply least-restrictive action first (if multiple rules match)
  6. Incident report sent to Compliance portal
```

### Sensitive Information Types (SITs)

SITs are the detection units. Each SIT uses a combination of:
- **Primary element:** regex pattern (e.g., credit card number format)
- **Supporting elements (optional):** keywords near the pattern, checksum validation
- **Confidence level:** High (90%+), Medium (75%), Low (65%) — determines how many elements must match

Custom SITs can use regex, exact data match (EDM), or trainable classifiers.

### Exact Data Match (EDM)

EDM is a SIT type that matches against a hash of actual sensitive data (e.g., a list of real SSNs or patient IDs). It prevents false positives by matching the exact value rather than a pattern. EDM requires:
1. A schema defining the fields
2. A data source (CSV) that gets hashed and uploaded
3. Regular refresh (data store expires after 60 days)

### Policy Priority and Rule Order

Within a policy, rules are evaluated in priority order. The **most restrictive matching rule wins** when rules conflict. Across policies, lower priority number = evaluated first. A block action in a high-priority policy overrides an audit-only action in a lower-priority policy.

### Endpoint DLP Architecture

For Windows endpoints, the DLP engine runs as part of the **Microsoft Defender for Endpoint** (MDE) service and the **Microsoft Compliance Extension** (for browsers). Actions available only on endpoints (not cloud workloads):
- Block copy to USB
- Block print
- Block upload to unallowed cloud services
- Block copy to clipboard from restricted apps
- Block screen capture

Endpoint DLP requires devices to be onboarded to MDE and enrolled in Intune (or co-managed).

</details>

---

## Dependency Stack

```
[Purview Compliance Portal — DLP Policy Definition]
    ├── Sensitive Information Types (built-in or custom)
    ├── Trainable Classifiers (ML-based)
    └── Exact Data Match (EDM) schemas
         │
[Policy Sync — per workload]
    ├── Exchange Transport Rules engine → Exchange DLP
    ├── SharePoint/OneDrive crawler + upload intercept → SPO/OD DLP
    ├── Teams message policy service → Teams DLP
    └── MDE + Compliance Extension → Endpoint DLP
         │
[Audit Log — Unified Audit Log]
    ├── DLP rule matches written as DLPRuleMatch events
    └── Activity Explorer in Compliance portal reads these events
         │
[User Experience Layer]
    ├── Policy tips (browser, Outlook)
    ├── Block notifications
    └── Incident email alerts → Compliance team
         │
[Licensing Check]
    └── M365 E3 (cloud workloads) / E5 Compliance (Endpoint DLP, advanced SITs)
```

---

## Workload Coverage Map

| Workload | What's Evaluated | Actions Available | Policy Tip |
|----------|-----------------|-------------------|------------|
| Exchange Online | Email body, attachments, subject | Audit, block send, encrypt, notify | ✅ Outlook (classic + new) |
| SharePoint Online | File content at upload + scan | Audit, block external share, restrict | ✅ Web |
| OneDrive | File content at upload + sync | Audit, block share, quarantine | ✅ Web, sync client |
| Teams | Chat/channel messages, files | Audit, block message, notify | ✅ Teams app |
| Endpoint DLP | File operations on device | Audit, block, warn, allow with justification | ❌ (toast notification) |
| Power BI | Dataset and report content | Audit, restrict, alert | ❌ |

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| DLP policy not triggering on known sensitive content | Policy in test/simulation mode | Compliance portal > DLP > Policy > Status column |
| Policy tips not showing in Outlook | Policy tip action not configured, or Outlook not supported version | Check rule → User notifications → Policy tips enabled |
| Endpoint DLP not blocking | Device not onboarded to MDE, or Endpoint DLP not in policy locations | `MdeCli.exe status` on device; check MDE onboarding |
| High false positive rate on SITs | Low confidence level set, or overly broad regex in custom SIT | Review SIT confidence thresholds; use Activity Explorer to sample matches |
| DLP events not appearing in Activity Explorer | Unified Audit Log not enabled, or delay (up to 24h) | Compliance portal > Audit > Search; verify UAL enabled |
| Users can override block with justification | "Allow override with justification" is enabled in rule | Review rule actions — override settings |
| SharePoint file scanned but no match | File type not supported or content extraction failed | Check supported file types list; .msg files need Exchange workload |
| EDM not matching known values | EDM data store expired (60-day limit) or schema mismatch | Check EDM upload timestamp in compliance portal |
| Policy applies to wrong users | Location scoping or user/group exception misconfigured | Review policy > Edit > Locations and exceptions |
| Teams DLP blocking internal messages unexpectedly | Policy scoped to all locations including Teams | Scope policy to specific teams or exclude internal senders |

---

## Validation Steps

**1. Verify DLP policy status and mode**
```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# List all DLP policies with status
Get-DlpCompliancePolicy | Select-Object Name, Mode, IsValid, ExchangeLocation, SharePointLocation, EndpointDlpLocation |
    Format-Table -AutoSize
```
- `Mode: Enforce` — active enforcement
- `Mode: TestWithNotifications` — test mode with user notifications
- `Mode: TestWithoutNotifications` — silent test mode (audit only, no tips)

**2. Verify DLP rules within a policy**
```powershell
Get-DlpComplianceRule -Policy "<PolicyName>" |
    Select-Object Name, Priority, Disabled, ContentContainsSensitiveInformation, NotifyUser, BlockAccess, GenerateAlert |
    Format-Table -AutoSize
```

**3. Check SIT detection capability (test content)**
```powershell
# Test whether a SIT would match sample text
$testContent = "SSN: 123-45-6789"
$sitName = "U.S. Social Security Number (SSN)"

# Via compliance cmdlets
Test-DataClassification -TextToClassify $testContent -SensitiveType $sitName
```

**4. Verify Endpoint DLP onboarding**
```powershell
# On the endpoint — check MDE service
Get-Service -Name "Sense" | Select-Object Name, Status, StartType

# Check onboarding state
Get-Item "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -ErrorAction SilentlyContinue |
    Get-ItemProperty | Select-Object OnboardingState, OrgId
# OnboardingState: 1 = onboarded
```

**5. Verify Unified Audit Log is enabled**
```powershell
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
# Must be: True
```

**6. Search for recent DLP matches**
```powershell
$startDate = (Get-Date).AddDays(-7)
$endDate = Get-Date

Search-UnifiedAuditLog -StartDate $startDate -EndDate $endDate -RecordType DLPRuleMatch -ResultSize 100 |
    Select-Object CreationDate, UserIds, Operations,
        @{N="PolicyName";E={($_.AuditData | ConvertFrom-Json).PolicyName}},
        @{N="RuleName";E={($_.AuditData | ConvertFrom-Json).RuleName}},
        @{N="SensitiveTypes";E={($_.AuditData | ConvertFrom-Json).SensitiveInfoDetectionIsIncluded}} |
    Export-Csv "$env:TEMP\DLP-Matches.csv" -NoTypeInformation
```

**7. Check policy sync latency**
```powershell
# New or modified policies can take up to 1 hour to sync to workloads
# Check when policy was last modified
Get-DlpCompliancePolicy -Identity "<PolicyName>" | Select-Object Name, WhenChanged, WhenCreated
```

---

## Troubleshooting Steps by Phase

### Phase 1 — Policy Not Triggering

1. Confirm policy `Mode` is `Enforce` (not test mode)
2. Confirm the workload location is included — Exchange, SharePoint, Teams, Endpoint must be explicitly listed
3. Confirm the rule is not `Disabled: True`
4. Wait for sync — new policies take up to 1 hour; Exchange DLP can take 60-90 minutes
5. For Endpoint DLP: verify device onboarding (`OnboardingState = 1`) and that the Compliance Extension is installed in Chrome/Edge

### Phase 2 — SIT Not Matching Expected Content

1. Test the SIT directly: `Test-DataClassification`
2. Check **confidence level** — a High confidence match requires both primary element AND supporting elements (e.g., keyword near the pattern). If content has the number but not a nearby keyword, it won't hit High confidence
3. Review the rule's `ContentContainsSensitiveInformation` — check `minCount` and `minConfidence` values
4. For custom SITs: validate regex in a regex tester first; Purview regex uses .NET syntax
5. Check file type — DLP cannot extract content from password-protected files, some encrypted containers, or certain binary formats

### Phase 3 — High False Positives

1. Run Activity Explorer (Compliance portal > Data classification > Activity explorer) — filter by `DLP rule matched`
2. Sample actual match context — does the trigger make sense?
3. Increase confidence threshold: change rule's `minConfidence` from `65` to `85` or `75` to reduce low-confidence matches
4. Add exclusions: use `ExceptIfContentContainsSensitiveInformation` with specific contexts, or add user/group exceptions
5. For custom SITs: tighten the regex or add mandatory keyword proximity requirements

### Phase 4 — Endpoint DLP Not Enforcing

1. Verify device appears in MDE device inventory
2. Check Endpoint DLP audit events: `Event Viewer > Applications and Services Logs > Microsoft > Windows > Microsoft DLP > Operational`
3. Verify `EndpointDlpEnabled` in policy: `Get-DlpCompliancePolicy | Where EndpointDlpEnabled -eq $true`
4. For browser actions: verify Compliance Extension is installed and enabled in Chrome/Edge
5. Check Windows 10/11 version — Endpoint DLP requires Windows 10 1809+ (full features require 21H1+)
6. Verify no conflicting Defender policies are disabling the DLP component

### Phase 5 — EDM Not Matching

1. Check EDM data store upload date — expires after 60 days
2. Verify schema column names match the CSV headers exactly (case-sensitive)
3. Verify the EDM SIT is included in the DLP rule's conditions
4. EDM matching is case-insensitive but whitespace-sensitive — check for trailing spaces in CSV data
5. Re-upload the EDM data if more than 55 days old (give buffer before expiry)

---

## Remediation Playbooks

<details><summary>Playbook 1 — Create a scoped DLP policy for credit card data in Exchange</summary>

```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# Create the policy
New-DlpCompliancePolicy -Name "PCI-DSS-Email-Protection" `
    -ExchangeLocation All `
    -Mode Enforce `
    -Comment "Blocks external email with credit card data"

# Add rule: block external send with high-confidence CC detection
New-DlpComplianceRule -Name "Block-CC-External-Email" `
    -Policy "PCI-DSS-Email-Protection" `
    -ContentContainsSensitiveInformation @{Name="Credit Card Number"; minCount=1; minConfidence=85} `
    -SentToScope NotInOrganization `
    -BlockAccess $true `
    -NotifyUser Owner `
    -NotifyPolicyTipCustomText "This email appears to contain credit card data. External sending has been blocked." `
    -GenerateAlert $true `
    -AlertProperties @{AggregationType="None"} `
    -Priority 0

Write-Host "Policy created. Allow up to 60 minutes for Exchange sync." -ForegroundColor Green
```

</details>

<details><summary>Playbook 2 — Enable Endpoint DLP for USB block on sensitive files</summary>

```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# Add endpoint location to existing policy (or create new)
Set-DlpCompliancePolicy -Identity "PCI-DSS-Email-Protection" `
    -AddEndpointDlpLocation All

# Add Endpoint DLP rule — block copy to USB for SIT matches
New-DlpComplianceRule -Name "Block-CC-USB-Copy" `
    -Policy "PCI-DSS-Email-Protection" `
    -ContentContainsSensitiveInformation @{Name="Credit Card Number"; minCount=1; minConfidence=85} `
    -EndpointDlpRestrictions @(
        @{Setting="CopyToRemovableMedia"; Value="Block"}
        @{Setting="Print"; Value="Audit"}
    ) `
    -NotifyUser Owner `
    -Priority 1

Write-Host "Endpoint DLP rule added. Device must be MDE-onboarded." -ForegroundColor Green
```

</details>

<details><summary>Playbook 3 — Switch policy from test mode to enforce</summary>

```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

$policyName = "<PolicyName>"

# Check current mode
$policy = Get-DlpCompliancePolicy -Identity $policyName
Write-Host "Current mode: $($policy.Mode)" -ForegroundColor Cyan

# Switch to enforce
Set-DlpCompliancePolicy -Identity $policyName -Mode Enforce

Write-Host "Policy switched to Enforce mode. Monitor Activity Explorer for false positives." -ForegroundColor Yellow
```

**Rollback:**
```powershell
Set-DlpCompliancePolicy -Identity $policyName -Mode TestWithNotifications
```

</details>

<details><summary>Playbook 4 — Create a custom SIT with regex + keyword proximity</summary>

```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# Example: detect employee IDs (format: EMP-XXXXXXXX)
$newSIT = New-DlpSensitiveInformationType -Name "Contoso Employee ID" `
    -Description "Detects Contoso employee ID numbers in format EMP-XXXXXXXX"

# Add primary regex element
New-DlpSensitiveInformationTypeRulePackage # Use XML approach for complex SITs

# For simple custom SITs, use the Compliance portal UI:
# Data Classification > Classifiers > Sensitive info types > Create
# Pattern: regex EMP-\d{8}
# Supporting element: keyword "Employee" within 300 characters
# Confidence: Medium (75%) — primary + no supporting; High (85%) — primary + supporting

Write-Host "Complex custom SITs are best created via Compliance portal XML upload or UI wizard." -ForegroundColor Yellow
```

</details>

---

## Evidence Pack

```powershell
# Purview DLP Evidence Collector
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>
$out = "$env:TEMP\DLP-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

# 1. All DLP policies and modes
Get-DlpCompliancePolicy | Select-Object Name, Mode, IsValid, WhenChanged,
    ExchangeLocation, SharePointLocation, OneDriveLocation, TeamsLocation, EndpointDlpEnabled |
    Export-Csv "$out\dlp-policies.csv" -NoTypeInformation

# 2. All DLP rules
Get-DlpCompliancePolicy | ForEach-Object {
    $pName = $_.Name
    Get-DlpComplianceRule -Policy $pName | Select-Object Name, Priority, Disabled,
        @{N="Policy";E={$pName}},
        @{N="SITs";E={$_.ContentContainsSensitiveInformation | ConvertTo-Json -Compress}},
        BlockAccess, NotifyUser, GenerateAlert
} | Export-Csv "$out\dlp-rules.csv" -NoTypeInformation

# 3. Recent DLP matches (last 7 days)
$startDate = (Get-Date).AddDays(-7)
Search-UnifiedAuditLog -StartDate $startDate -EndDate (Get-Date) -RecordType DLPRuleMatch -ResultSize 500 |
    Select-Object CreationDate, UserIds, Operations,
        @{N="PolicyName";E={($_.AuditData | ConvertFrom-Json).PolicyName}},
        @{N="RuleName";E={($_.AuditData | ConvertFrom-Json).RuleName}} |
    Export-Csv "$out\dlp-recent-matches.csv" -NoTypeInformation

# 4. Audit log status
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled |
    Out-File "$out\audit-log-status.txt"

# 5. Custom SITs
Get-DlpSensitiveInformationType | Where-Object Publisher -ne "Microsoft Corporation" |
    Select-Object Name, Description, RecommendedConfidence |
    Export-Csv "$out\custom-sits.csv" -NoTypeInformation

Write-Host "Evidence collected to $out" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Connect
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# 1. List all DLP policies with mode
Get-DlpCompliancePolicy | Select-Object Name, Mode, IsValid | Format-Table

# 2. List rules in a policy
Get-DlpComplianceRule -Policy "<PolicyName>" | Select-Object Name, Priority, Disabled, BlockAccess

# 3. Test SIT against sample text
Test-DataClassification -TextToClassify "SSN 123-45-6789" -SensitiveType "U.S. Social Security Number (SSN)"

# 4. Check UAL enabled
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled

# 5. Search DLP match events
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -RecordType DLPRuleMatch -ResultSize 100

# 6. Switch policy to enforce
Set-DlpCompliancePolicy -Identity "<PolicyName>" -Mode Enforce

# 7. Disable a DLP rule temporarily
Set-DlpComplianceRule -Identity "<RuleName>" -Disabled $true

# 8. Check Endpoint DLP onboarding on device
Get-Item "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" | Get-ItemProperty | Select-Object OnboardingState

# 9. List all SITs (built-in + custom)
Get-DlpSensitiveInformationType | Select-Object Name, Publisher, RecommendedConfidence | Sort-Object Publisher

# 10. Export policy to review
Get-DlpCompliancePolicy -Identity "<PolicyName>" | ConvertTo-Json -Depth 5 | Out-File "$env:TEMP\policy-export.json"

# 11. Check endpoint DLP on device (Event Viewer shortcut)
Get-WinEvent -LogName "Microsoft DLP" -MaxEvents 50 -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, Message

# 12. List EDM schemas
Get-DlpEdmSchema | Select-Object Name, Id, Description

# 13. Check EDM data store upload status
Get-DlpEdmDatastoreStatus | Select-Object DatastoreName, SchemaName, Status, LastDataUploadTimestamp
```

---

## 🎓 Learning Pointers

- **DLP is event-driven, not real-time scanning** — it triggers on file upload, email send, message post, and file operations. It does not continuously re-scan content at rest (SharePoint crawl schedules for existing content are separate). This is why a file uploaded before a policy was created may not have a DLP event.

- **Confidence levels are additive, not substitutive** — High confidence (85%) typically requires the primary pattern AND at least one supporting element (corroborating keyword or checksum). If you set `minConfidence=85` but your sample content lacks the supporting element, it won't match. Activity Explorer shows the confidence level of actual matches, helping you calibrate. [SIT entity definitions](https://learn.microsoft.com/en-us/microsoft-365/compliance/sensitive-information-type-entity-definitions)

- **Endpoint DLP is architecturally different from cloud DLP** — it runs inside the MDE agent on the device and intercepts OS-level operations (file copy, print, USB write). It does not route through the cloud for enforcement. This means it works offline but requires MDE onboarding, not just Intune enrollment. [Endpoint DLP docs](https://learn.microsoft.com/en-us/microsoft-365/compliance/endpoint-dlp-learn-about)

- **Policy tips require specific rule actions** — a rule with only `GenerateAlert` will NOT show policy tips to users. You must explicitly configure `NotifyUser` with `PolicyTip` action. Policy tips in Outlook require Outlook 2013+ (classic) or the new Outlook; OWA shows them natively.

- **EDM data stores expire** — the uploaded hash data expires after 60 days. If no refresh occurs, EDM-based SITs silently stop matching. Build a scheduled task or Power Automate flow to refresh the upload. [EDM setup guide](https://learn.microsoft.com/en-us/microsoft-365/compliance/sit-get-started-exact-data-match-based-sits-overview)

- **The priority order of rules and policies is critical** — when multiple rules match, the most restrictive action applies. But if an "allow override" rule has a lower priority number (runs first), it may satisfy the match before a block rule applies. Always audit rule priority after policy changes. [Policy precedence](https://learn.microsoft.com/en-us/microsoft-365/compliance/dlp-policy-reference#policy-evaluation-in-exchange)
