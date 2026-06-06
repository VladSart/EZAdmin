# Sensitivity Labels — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Microsoft Purview Sensitivity Labels (formerly AIP unified labeling)
- Label policy publishing, auto-labeling, mandatory labeling
- Office apps (Word, Excel, PowerPoint, Outlook) — both desktop and web
- SharePoint Online and OneDrive document libraries
- Email labeling via Exchange transport rules
- MIP SDK / custom app integration basics

**Out of scope:**
- Azure Information Protection classic client (deprecated March 2024)
- Physical document classification
- Third-party DRM systems

**Assumptions:**
- Tenant has Microsoft 365 E3/E5 or equivalent licensing
- Labels are created and managed in Microsoft Purview compliance portal
- Azure AD P1/P2 available for group-based policy targeting
- Global Reader or Compliance Administrator role for troubleshooting

---

## How It Works

<details><summary>Full architecture — label lifecycle and enforcement</summary>

### Label Creation and Storage
Sensitivity labels are defined in the **Microsoft Purview compliance portal** (`compliance.microsoft.com`) and stored in the **Exchange Online Protection (EOP)** backend — not in Azure AD. This is why label policies are delivered via the same mechanism as mail flow rules.

```
Microsoft Purview Portal
        │
        ▼
  Label Metadata Store (EOP backend)
        │
        ├── Label Policy Engine ──────────────────────┐
        │   (scope: users/groups, settings)            │
        │                                              ▼
        ├── Office Apps (MAPI/WebDAV)        Exchange Transport
        │   - Word, Excel, PPT, Outlook       (auto-label on send)
        │   - Read policy at app open
        │
        ├── SharePoint Online
        │   - Library-level default label
        │   - Mandatory label enforcement
        │   - Auto-label via sensitive info types
        │
        └── MIP SDK (custom apps, M365 apps)
```

### Label Application Flow (Office Desktop)
1. User opens an Office app → app authenticates to Microsoft 365
2. App calls **labeling service endpoint** (`api.aadrm.com`, `*.aadrmservice.net`) to fetch policy
3. Policy cached locally in `%localappdata%\Microsoft\MSIP\`
4. User applies label manually OR auto-label rule fires
5. Label metadata written to Office document XML (`[Content_Types].xml`, custom properties)
6. If label has protection: RMS encryption applied via Azure Rights Management Service (ARMS)
7. On save/upload to SharePoint: SPO reads label metadata, enforces library settings

### Label Metadata in Documents
Labels are stored in document custom XML properties:
```xml
<cp:customXml>
  <Item Key="MSIP_Label_{GUID}_Enabled" Value="True"/>
  <Item Key="MSIP_Label_{GUID}_SetDate" Value="2026-01-15T10:30:00Z"/>
  <Item Key="MSIP_Label_{GUID}_Method" Value="Manual"/>
  <Item Key="MSIP_Label_{GUID}_Name" Value="Confidential"/>
  <Item Key="MSIP_Label_{GUID}_SiteId" Value="{TenantID}"/>
  <Item Key="MSIP_Label_{GUID}_ActionId" Value="{ActionGUID}"/>
  <Item Key="MSIP_Label_{GUID}_ContentBits" Value="3"/>
</Item>
```

### Auto-Labeling
Two distinct auto-labeling mechanisms with different behavior:

| Mechanism | Where | When | Overwrites Manual? |
|-----------|-------|------|--------------------|
| **Client-side** (Office apps) | Desktop/Web app | On open/save | No (by default) |
| **Service-side** (Purview) | SharePoint/Exchange | Background scan | Configurable |

Service-side auto-labeling runs in **simulation mode first** — check the auto-label policy dashboard before expecting live enforcement.

### Mandatory Labeling
When enabled in label policy:
- Office apps: user must select label before saving/sending
- SharePoint: prevents upload of unlabeled files (via SPO enforcement)
- Outlook: user must label before sending

</details>

---

## Dependency Stack

```
Microsoft Purview Compliance Portal
        │
        ▼
EOP Backend (label storage + policy engine)
        │
        ├──── Azure Rights Management Service (ARMS)
        │     └── Required for encryption-based labels
        │         Endpoint: *.aadrmservice.net / api.aadrm.com
        │
        ├──── Exchange Online
        │     └── Email auto-labeling transport rules
        │         Email DLP enforcement
        │
        ├──── SharePoint Online
        │     └── Document library label enforcement
        │         Auto-label policies (service-side)
        │         Site sensitivity label (container label)
        │
        ├──── OneDrive for Business
        │     └── Inherits SPO enforcement rules
        │
        ├──── Office Apps (desktop / web)
        │     └── Label policy cache (%localappdata%\Microsoft\MSIP\)
        │         MIP SDK DLL (built into M365 Apps 2008+)
        │         Requires: Microsoft 365 Apps for Enterprise
        │
        └──── Azure AD
              └── Group targeting for label policies
                  RMS super user / service accounts
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Sensitivity bar missing in Office | Label policy not published to user; outdated Office build | `Get-Label`; Office build ≥ 16.0.11629 |
| Label applied but no encryption | Label not configured with protection; RMS not activated | Label settings in portal; `Get-AipServiceConfiguration` |
| Auto-label not firing | Policy still in simulation mode; wrong sensitive info type | Auto-label policy status dashboard |
| Users can't downgrade label | Label policy: mandatory downgrade justification OR no permission | Label policy "Require justification" setting |
| Label disappears after upload to SPO | SPO library overriding with default label | SPO library label settings |
| Encrypted file can't be opened | RMS permissions not granted; external user without Azure AD | `Get-AipServiceRightsDefinition`; check user licensing |
| Label policy not updating in Office | Stale local cache; policy change takes up to 24 h | Clear MSIP cache; force policy refresh |
| Container labels not applying to Teams | Teams/Groups feature not enabled in label policy | `Set-LabelPolicy -AdvancedSettings @{EnableGroupLabels='true'}` |
| Auto-label simulation never completes | Large library; >25k items per run limit | Check auto-label dashboard; stage the policy |
| "Access denied" opening labeled file | Label uses AD RMS instead of Azure RMS | Verify ARMS activation; no on-prem RMS conflicts |

---

## Validation Steps

**1. Confirm labels exist and are published**
```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>
Get-Label | Select-Object Name, Guid, IsActive, Priority | Sort-Object Priority
Get-LabelPolicy | Select-Object Name, Labels, ExchangeLocation, ModernGroupLocation
```
*Good:* Labels shown as `IsActive: True`; policy scoped to correct users/groups  
*Bad:* No labels returned = creation issue; empty `Labels` field = policy has no labels

**2. Verify policy is scoped to the affected user**
```powershell
$policy = Get-LabelPolicy -Identity "<PolicyName>"
$policy.ExchangeLocation        # should include user or group
$policy.ModernGroupLocation     # for Teams/M365 Groups
```

**3. Check RMS / ARMS activation**
```powershell
Connect-AipService
Get-AipServiceConfiguration | Select-Object FunctionalState, LicensingIntranetDistributionPointUrl
```
*Good:* `FunctionalState: Enabled`  
*Bad:* `Disabled` = protection labels will fail silently

**4. Check Office build supports unified labeling**
```powershell
# On client machine:
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration").VersionToReport
# Minimum: 16.0.11629.20196 (M365 Apps, Semi-Annual Channel)
```

**5. Validate local label policy cache**
```powershell
# On client machine — check cache age
$cacheFile = "$env:LOCALAPPDATA\Microsoft\MSIP\mip\*\mip.policies.sqlite3"
Get-Item $cacheFile | Select-Object LastWriteTime, Length
```
*If LastWriteTime > 4 hours old and user reports stale labels — clear cache*

**6. Test auto-label policy status**
```powershell
Get-AutoSensitivityLabelPolicy | Select-Object Name, Mode, AutoApplyType, Workload
# Mode: TestWithoutNotifications = simulation
# Mode: Enable = live enforcement
```

**7. Verify SharePoint label enforcement**
```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
Get-SPOTenant | Select-Object EnableAIPIntegration, SensitivityLabelAdminSite
# EnableAIPIntegration should be True
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Label Policy Delivery

**1a. Confirm the label exists in Security & Compliance**
```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>
Get-Label -Identity "<LabelName>" | Format-List Name, Guid, IsActive, Settings
```

**1b. Confirm policy includes the label and targets the user**
```powershell
Get-LabelPolicy | Where-Object { $_.Labels -contains "<LabelGuid>" } | 
    Select-Object Name, ExchangeLocation, ExchangeLocationException
```

**1c. Check for policy conflicts (multiple policies, priority)**
```powershell
Get-LabelPolicy | Select-Object Name, Priority, Labels | Sort-Object Priority
```
The highest priority policy (lowest number) wins. If a user is in two policies, settings from the higher-priority policy apply.

### Phase 2: Office App Label Experience

**2a. Force a policy refresh on the client**
```powershell
# On the affected client machine:
Start-Process "outlook.exe" -ArgumentList "/resetfolders"
# Or for all Office apps — remove the MSIP cache:
Stop-Process -Name WINWORD, EXCEL, POWERPNT, OUTLOOK -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Microsoft\MSIP\mip" -Recurse -Force
```
Re-open Office — it will re-download the policy (allow 2–5 minutes).

**2b. Check the ULS / diagnostic log**
```powershell
# Enable enhanced MIP logging:
Set-ItemProperty -Path "HKCU:\Software\Microsoft\MSIP" -Name "EnableLog" -Value 1 -Type DWORD
# Logs written to: %localappdata%\Microsoft\MSIP\Logs\
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\MSIP\Logs\" | Sort-Object LastWriteTime -Descending | Select-Object -First 5
```

### Phase 3: Encryption / RMS Issues

**3a. Verify RMS service connectivity**
```powershell
# Test endpoints from client:
Test-NetConnection -ComputerName "api.aadrm.com" -Port 443
Test-NetConnection -ComputerName "*.aadrmservice.net" -Port 443
Invoke-WebRequest -Uri "https://api.aadrm.com/autodiscover/autodiscoverservice.svc/root" -UseBasicParsing
```

**3b. Check user's RMS license**
```powershell
Connect-MgGraph -Scopes "User.Read.All"
$user = Get-MgUser -UserId <UPN> -Property AssignedLicenses
# Must have AZURE_RIGHTS_MANAGEMENT or MIP_S_CLP service plan enabled
```

**3c. Inspect RMS rights on a labeled document**
```powershell
# Install AIP client or use PowerShell module:
Install-Module -Name AIPService -Force
Connect-AipService
Get-AipServiceUserLog -Path C:\Temp\RMSLog.log -FromDate (Get-Date).AddDays(-1)
```

### Phase 4: Auto-Labeling Issues

**4a. Check auto-label policy mode**
```powershell
Get-AutoSensitivityLabelPolicy -Identity "<PolicyName>" | 
    Select-Object Name, Mode, AutoApplyType, Workload, SimulationStatus
```
If `Mode` is `TestWithoutNotifications`, the policy is **simulating only** — no labels are applied. Change to `Enable` when ready.

**4b. Advance auto-label policy from simulation to enforcement**
```powershell
Set-AutoSensitivityLabelPolicy -Identity "<PolicyName>" -Mode Enable
```

**4c. Review simulation results**
```powershell
Get-AutoSensitivityLabelPolicyRule -Policy "<PolicyName>" | 
    Select-Object Name, ContentContainsSensitiveInformation, ApplySensitivityLabel
```

### Phase 5: SharePoint / Container Labels

**5a. Enable AIP integration in SPO tenant**
```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
Set-SPOTenant -EnableAIPIntegration $true
```
*Note: Takes up to 24 hours to propagate to all libraries.*

**5b. Enable container labels for Microsoft 365 Groups and Teams**
```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>
# Enable groups feature for all label policies:
Get-LabelPolicy | ForEach-Object {
    Set-LabelPolicy -Identity $_.Name -AdvancedSettings @{EnableGroupLabels='true'}
}
```

**5c. Check library-level label override**
```powershell
Connect-PnPOnline -Url https://<tenant>.sharepoint.com/sites/<site> -Interactive
Get-PnPList -Identity "Documents" | Select-Object Title, DefaultSensitivityLabelForLibrary
```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Sensitivity bar missing for users</summary>

**Symptoms:** Users report no sensitivity label bar in Office apps.

**Steps:**
1. Confirm policy exists and is published:
   ```powershell
   Connect-IPPSSession -UserPrincipalName <adminUPN>
   Get-LabelPolicy | Select-Object Name, ExchangeLocation
   ```

2. Check Office build (minimum 16.0.11629):
   ```powershell
   # On client:
   winver
   (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration").VersionToReport
   ```

3. Force Office update if build is old:
   ```powershell
   & "C:\Program Files\Common Files\microsoft shared\ClickToRun\OfficeC2RClient.exe" /update user
   ```

4. Clear MIP cache and restart Office:
   ```powershell
   Stop-Process -Name WINWORD, EXCEL, POWERPNT, OUTLOOK -Force -ErrorAction SilentlyContinue
   Remove-Item "$env:LOCALAPPDATA\Microsoft\MSIP\mip" -Recurse -Force
   ```

5. Wait 5 minutes for policy re-download, reopen Office, check sensitivity bar.

**Rollback:** N/A — clearing cache is non-destructive.

</details>

<details><summary>Playbook 2 — Label applied but file has no encryption</summary>

**Symptoms:** Label shows in document but external recipients can open without RMS decryption.

**Steps:**
1. Verify label is configured with protection in Purview portal:
   ```powershell
   Connect-IPPSSession -UserPrincipalName <adminUPN>
   Get-Label -Identity "<LabelGUID>" | Select-Object Name, EncryptionEnabled, EncryptionProtectionType
   ```

2. Confirm ARMS is activated:
   ```powershell
   Connect-AipService
   Get-AipServiceConfiguration | Select-Object FunctionalState
   ```
   If `Disabled`: `Enable-AipService`

3. Check if there are conflicting AIP settings:
   ```powershell
   Get-AipServiceOnboardingControlPolicy
   # If enabled, only users in SecurityGroupObjectId can apply protection
   ```

4. If label was recently modified, clear client cache (Playbook 1, step 4) and re-apply label.

**Rollback:** Do not disable ARMS without thorough impact analysis — affects all RMS-protected content in the tenant.

</details>

<details><summary>Playbook 3 — Auto-labeling not applying to SharePoint library</summary>

**Symptoms:** Auto-label policy is enabled but documents in SPO remain unlabeled.

**Steps:**
1. Check AIP integration in SPO:
   ```powershell
   Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
   (Get-SPOTenant).EnableAIPIntegration
   ```
   If `False`: `Set-SPOTenant -EnableAIPIntegration $true` — wait 24 hours.

2. Confirm auto-label policy mode:
   ```powershell
   Connect-IPPSSession -UserPrincipalName <adminUPN>
   Get-AutoSensitivityLabelPolicy | Where-Object { $_.Workload -like "*SharePoint*" } |
       Select-Object Name, Mode, SimulationStatus
   ```

3. If in simulation: move to enforcement:
   ```powershell
   Set-AutoSensitivityLabelPolicy -Identity "<PolicyName>" -Mode Enable
   ```

4. Check library exclusions:
   ```powershell
   Get-AutoSensitivityLabelPolicyRule -Policy "<PolicyName>" | 
       Select-Object ExceptIfContentContainsSensitiveInformation, ExceptIfDocumentIsPasswordProtected
   ```

5. Verify the library is within scope (check ExchangeLocation / SharePointLocation in policy).

**Note:** Auto-labeling processes up to 25,000 documents per day per policy. Large libraries require multiple days to fully label.

</details>

<details><summary>Playbook 4 — External users can't open encrypted file</summary>

**Symptoms:** Partner/customer receives labeled encrypted document and gets "Access Denied".

**Steps:**
1. Check if external access is permitted in the label:
   ```powershell
   Connect-IPPSSession -UserPrincipalName <adminUPN>
   Get-Label -Identity "<LabelGUID>" | Select-Object EncryptionRightsDefinitions, EncryptionDoNotForward
   ```

2. Verify external user has an identity compatible with ARMS:
   - Azure AD account (any tenant) ✅
   - Microsoft Account (personal) ✅ if label allows
   - No Azure AD account ❌ — cannot open RMS-protected content

3. If external user doesn't have Azure AD: use **co-authoring workaround** or remove protection from that label for external sharing scenarios.

4. Check ARMS super user configuration:
   ```powershell
   Connect-AipService
   Get-AipServiceSuperUser
   Get-AipServiceSuperUserGroup
   ```

5. To grant temporary access (admin override):
   ```powershell
   # Add admin as super user to decrypt for re-sharing:
   Add-AipServiceSuperUser -EmailAddress <adminUPN>
   ```

**Rollback:** Remove super user access after use:
```powershell
Remove-AipServiceSuperUser -EmailAddress <adminUPN>
```

</details>

---

## Evidence Pack

```powershell
<#
  EZAdmin — Purview Sensitivity Labels Evidence Collector
  Collects full label configuration evidence for escalation to Microsoft Support
  Run as: Global Reader or Compliance Administrator
#>

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$output    = @{}

# 1. Connect
Connect-IPPSSession -UserPrincipalName $env:USERNAME
Connect-AipService

# 2. All labels
$output.Labels = Get-Label | Select-Object Name, Guid, IsActive, Priority,
    EncryptionEnabled, EncryptionProtectionType, LabelActions, Settings

# 3. All label policies
$output.LabelPolicies = Get-LabelPolicy | Select-Object Name, Priority, Labels,
    ExchangeLocation, ExchangeLocationException, ModernGroupLocation, Settings

# 4. Auto-label policies
$output.AutoLabelPolicies = Get-AutoSensitivityLabelPolicy | Select-Object Name,
    Mode, AutoApplyType, Workload, SimulationStatus

# 5. Auto-label policy rules
$output.AutoLabelRules = Get-AutoSensitivityLabelPolicyRule | Select-Object Name,
    Policy, ContentContainsSensitiveInformation, ApplySensitivityLabel

# 6. RMS configuration
$output.RMSConfig = Get-AipServiceConfiguration | Select-Object FunctionalState,
    AdminConnectionUrl, LicensingIntranetDistributionPointUrl, RightsManagementServiceId

# 7. RMS onboarding control
$output.OnboardingControl = Get-AipServiceOnboardingControlPolicy

# 8. Super users
$output.SuperUsers = Get-AipServiceSuperUser

# 9. SPO AIP integration status
Connect-SPOService -Url "https://$(Read-Host 'Tenant name (no .sharepoint.com)')-admin.sharepoint.com"
$output.SPOAIPIntegration = (Get-SPOTenant | Select-Object EnableAIPIntegration, SensitivityLabelAdminSite)

# 10. Export
$output | ConvertTo-Json -Depth 5 | Out-File "C:\Temp\SensitivityLabels-Evidence-$timestamp.json" -Encoding utf8
Write-Host "[OK] Evidence saved to C:\Temp\SensitivityLabels-Evidence-$timestamp.json" -ForegroundColor Green

# 11. Client-side cache info (run separately on affected client)
Write-Host "`n[INFO] Run on affected client machine:" -ForegroundColor Cyan
Write-Host '  Get-ChildItem "$env:LOCALAPPDATA\Microsoft\MSIP\mip" -Recurse | Select-Object FullName, LastWriteTime, Length | Export-Csv C:\Temp\MIPCache.csv'
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List all labels | `Get-Label \| Select-Object Name, Guid, IsActive` |
| List all label policies | `Get-LabelPolicy \| Select-Object Name, Priority` |
| Check auto-label policy mode | `Get-AutoSensitivityLabelPolicy \| Select-Object Name, Mode` |
| Enable auto-label enforcement | `Set-AutoSensitivityLabelPolicy -Identity <name> -Mode Enable` |
| Check RMS status | `Get-AipServiceConfiguration \| Select-Object FunctionalState` |
| Enable RMS | `Enable-AipService` |
| Add super user | `Add-AipServiceSuperUser -EmailAddress <UPN>` |
| Remove super user | `Remove-AipServiceSuperUser -EmailAddress <UPN>` |
| Enable SPO AIP integration | `Set-SPOTenant -EnableAIPIntegration $true` |
| Enable container labels in policy | `Set-LabelPolicy -Identity <name> -AdvancedSettings @{EnableGroupLabels='true'}` |
| Clear MIP cache (client) | `Remove-Item "$env:LOCALAPPDATA\Microsoft\MSIP\mip" -Recurse -Force` |
| Force Office update | `& "C:\Program Files\Common Files\microsoft shared\ClickToRun\OfficeC2RClient.exe" /update user` |
| Get label policy for specific user | `Get-LabelPolicy \| Where-Object { $_.ExchangeLocation -contains <UPN> }` |
| Check label on document | PowerShell + `Get-Item <file>.docx` custom XML properties |

---

## 🎓 Learning Pointers

- **Labels vs. AIP classic:** The Azure Information Protection *classic* client was retired in March 2024. Any environment still using it will have labeling failures. Always verify the tenant uses the **unified labeling platform** (Purview portal). [Migration guide](https://learn.microsoft.com/en-us/azure/information-protection/tutorial-migrating-to-ul)

- **Policy propagation delay:** Label policy changes take **up to 24 hours** to reach clients via the EOP-backed service. Clearing the local MSIP cache forces an immediate refresh — this is the fastest fix for stale policy issues. [Policy caching docs](https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#how-sensitivity-labels-are-applied-to-email-and-documents)

- **Auto-labeling modes matter:** Service-side auto-labeling starts in **simulation mode** — it never applies labels until explicitly set to `Enable`. Many admins deploy a policy and wait for labels to appear, unaware simulation is still running. Always check `Mode` first. [Auto-labeling overview](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically)

- **Container labels ≠ document labels:** Sensitivity labels on Teams/Groups (container labels) control *site settings* (privacy, guest access, external sharing) — not the sensitivity classification of documents inside. Both label types must be configured and enabled separately. [Container labels](https://learn.microsoft.com/en-us/purview/sensitivity-labels-teams-groups-sites)

- **RMS super user — use carefully:** The `Add-AipServiceSuperUser` cmdlet grants full decryption rights to any protected content in the tenant. Always remove it immediately after use. Log all super user additions to a SIEM. [Super user docs](https://learn.microsoft.com/en-us/azure/information-protection/configure-super-users)

- **The 25k document limit:** Auto-labeling service-side processes a maximum of ~25,000 items per day per policy across all included locations. For large migrations, plan for multi-day rollouts and monitor progress in the auto-label policy dashboard. [Capacity limits](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically#more-information-about-auto-labeling-policies)
