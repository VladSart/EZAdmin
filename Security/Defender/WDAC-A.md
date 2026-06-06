# WDAC / App Control for Business — Reference Runbook (Mode A: Deep Dive)
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
- Windows Defender Application Control (WDAC), now officially named **App Control for Business** in Windows 11 22H2+
- AppLocker (legacy, supported alongside WDAC on Windows 11 22H2+)
- Policy deployment via Microsoft Intune (OMA-URI and Application Control profile type)
- Policy deployment via Group Policy (GPO)
- Supplemental policies, base policies, and Managed Installer configuration
- Windows 10 20H2+ and Windows 11 clients; Windows Server 2019+

**Out of scope:**
- Device Guard (branding retired — WDAC is the component that remains)
- Smart App Control (consumer Windows feature — separate enforcement layer, not enterprise-managed)
- Code signing infrastructure setup (PKI, code signing certificates)

**Assumptions:**
- You have local admin rights on the affected device (or Intune remediation script access)
- You have access to the source policy XML (not just the compiled .cip)
- You understand the organization's intended policy scope (base policy, supplemental policies, etc.)

---
## How It Works

<details><summary>Full architecture — kernel enforcement, policy model, and evaluation pipeline</summary>

### Fundamental Architecture

WDAC operates at the kernel level through the **Code Integrity (CI) subsystem** (`ci.dll`). Unlike AppLocker (which is a user-mode service), CI is loaded during the Windows boot process before any user-mode code runs. This means:

1. **WDAC cannot be disabled by a local admin** — the policy is enforced at a level below the administrator's control
2. **WDAC survives Safe Mode** (partially — some kernel-mode enforcement persists)
3. **WDAC cannot be bypassed by disabling a service** — there is no service to disable

```
Boot Process:
  UEFI → Boot Loader → Windows Kernel
                             │
                             └── ci.dll loaded (Code Integrity)
                                    │
                                    ├── Reads policy from: C:\Windows\System32\CodeIntegrity\CiPolicies\Active\{GUID}.cip
                                    ├── Policy format: compiled binary (XML → ConvertFrom-CIPolicyFormat → .cip)
                                    └── Enforcement begins before any user-space code runs
```

### Policy Types

**Base Policy:**
- Defines the foundational allow/deny rules
- Must include a signer rule for Microsoft itself (all base policies must allow Windows)
- Identified by a unique PolicyID GUID
- Can reference a GUID for supplemental policies to extend it

**Supplemental Policy:**
- Extends a base policy — can only ADD permissions, never remove them
- Identified by its own GUID, linked to base policy by `BasePolicyID`
- Used for LOB apps, ISV software, or per-department exceptions
- Deployed independently from the base policy

**Microsoft Recommended Block Rules / Allow Rules:**
Microsoft publishes two maintained policy XML files:
- **Recommended Block Rules:** Known vulnerable/malicious binaries to explicitly deny
- **Recommended Driver Block Rules:** Known vulnerable WHQL-signed drivers (BYOVD attacks)
Both are versioned and updated quarterly. They should be merged into any production policy.

### Rule Levels (ordered best-to-worst trust)

| Level | What it trusts | Use case |
|---|---|---|
| `PCACertificate` | Root CA that signed the file | Broadest — trust all from a CA |
| `Publisher` | Specific publisher (CN) + product + version | Vendor-specific allow |
| `SignedVersion` | Specific publisher + minimum version | Allows updates automatically |
| `FilePublisher` | Specific file + publisher | Precise control per binary |
| `Hash` | SHA256 hash of the exact binary | Unsigned files; breaks on updates |
| `FilePath` | Path-based | Weakest — local admins can place files at paths |

**Rule evaluation order:** Deny rules always win over Allow rules. If a binary matches both an Allow rule and a Deny rule, it is blocked.

### Enforcement Modes

**Audit Mode:**
- Code Integrity evaluates every binary against the policy
- Blocks are logged as Event ID 3076 but execution is **allowed**
- No production impact — safe for piloting
- Essential before switching to Enforce mode

**Enforce Mode:**
- Event ID 3077 = blocked execution
- Kernel returns ACCESS_DENIED to the calling process
- The blocked binary never runs

### Managed Installer

Managed Installer (MI) is a mechanism that automatically trusts any binary deployed by a designated installer. In Intune environments:

1. Intune/SCCM is designated as a Managed Installer in the policy
2. Any file written by the IntuneManagementExtension process gets a kernel-level tag (`MI Tag`) written to its extended attributes
3. WDAC sees the MI tag and trusts the file without needing an explicit Allow rule
4. This eliminates the need to enumerate every managed app in the policy

**Critical detail:** The MI tag is set at write time. Files copied to a device before MI was configured do NOT have the tag and will be blocked. Re-deploying apps via Intune sets the tag retroactively.

### WDAC + AppLocker Coexistence (Windows 11 22H2+)

On Windows 11 22H2 and later, both can run simultaneously:
- WDAC handles EXE, DLL, OCX, and drivers
- AppLocker handles scripts (.ps1, .vbs, .js, .cmd) and MSI
- On earlier builds: WDAC silently supersedes AppLocker for all rule types where both apply

### Script Control and PowerShell Constrained Language Mode (CLM)

When WDAC is in enforce mode and the policy does NOT include an explicit Allow rule for PowerShell scripts:
- PowerShell automatically enters **Constrained Language Mode**
- In CLM: no `Add-Type`, no direct .NET method calls (`[System.Net.WebClient]::new()`), no COM object creation, no `Invoke-Expression`
- Scripts that were working before a WDAC policy deployment may silently fail in CLM
- Test scripts with `$ExecutionContext.SessionState.LanguageMode` — returns `ConstrainedLanguage` or `FullLanguage`

</details>

---
## Dependency Stack

```
Intune / GPO policy delivery
  ├── Intune: OMA-URI → WMI bridge → .cip file written to disk
  └── GPO: HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard
        │
        ▼
Policy file on disk
  WDAC:     C:\Windows\System32\CodeIntegrity\CiPolicies\Active\{PolicyGUID}.cip
  AppLocker: HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2\{RuleCollections}
        │
        ▼
Code Integrity subsystem (ci.dll) — loaded at kernel init
  [Reads all .cip files at boot; policy changes require reboot or citool refresh on Win11]
        │
        ├── Hash Database (WHQL drivers, Windows binaries — always allowed regardless of policy)
        │
        ├── Policy Rule Evaluation
        │     ├── Is file in Deny list? → BLOCK (event 3077)
        │     ├── Is file in Allow list? → ALLOW
        │     ├── Does file have Managed Installer tag? → ALLOW (if MI policy option set)
        │     ├── Is file a Windows/WHQL-signed component? → ALLOW (if policy allows)
        │     └── None of the above → BLOCK (in Enforce) or LOG (in Audit)
        │
        └── AppLocker service (AppIDSvc) — user-mode, script/MSI rules only
              [Checks SrpV2 registry rules on every process launch in its scope]
                    │
                    └── Application execution allowed or blocked
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Key Check |
|---|---|---|
| Application blocked after Intune policy push | New WDAC policy in Enforce mode; app not in allow-list | CI event 3077; `citool --list-policies` |
| Application blocked but policy was supposed to be Audit | Policy compiled with Enforce option; Audit flag not set in XML | Check `<Rule><Option>Enabled:Audit Mode</Option></Rule>` in XML |
| Application blocked with no CI events | AppLocker blocking (separate log path) | `Get-WinEvent -LogName "Microsoft-Windows-AppLocker/EXE and DLL"` |
| PowerShell scripts fail with `is not allowed to run` | CLM active due to WDAC enforce; script unsigned | `$ExecutionContext.SessionState.LanguageMode` |
| Policy deployed via Intune but no .cip file on disk | WMI bridge delivery failed; policy >4MB; OMA-URI path wrong | MDM diag log; `Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_AppLocker` |
| `citool` shows policy but binary still blocked | Policy not yet refreshed after deploy (reboot required on older builds) | Reboot client; or use `citool --update-policy` on Win11 |
| Supplemental policy not taking effect | BasePolicyID in supplemental doesn't match the active base policy GUID | `citool --list-policies` to compare GUIDs |
| Managed Installer not trusting Intune-deployed apps | MI policy option not enabled in base policy; old file pre-dates MI configuration | Check `<Rule><Option>Enabled:Managed Installer</Option>` in policy XML |
| WDAC blocks DLL but not EXE | Script enforcement or DLL enforcement not enabled in policy | Check `<Rule><Option>Enabled:UMCI</Option>` (User Mode Code Integrity) in policy |
| Policy applied in VMs but not physical machines | Hypervisor-Protected Code Integrity (HVCI) not enabled on physical; separate policy needed | Check HVCI status: `Get-ComputerInfo \| Select-Object HyperVRequirementVirtualizationFirmwareEnabled` |
| App works for admins but not standard users | Per-user AppLocker rules or User Mode vs Kernel Mode enforcement difference | Check if policy uses UMCI vs KMCI only |

---
## Validation Steps

**Step 1 — List all active WDAC policies**
```powershell
# Windows 11 22H2+ (preferred)
citool --list-policies

# All Windows versions — check physical files
Get-ChildItem "C:\Windows\System32\CodeIntegrity\CiPolicies\Active" -Filter "*.cip" |
    Select-Object Name, LastWriteTime, Length
```
Expected: see your deployed policy GUID(s). Each .cip file = one active policy.

**Step 2 — Identify enforcement mode of each policy**
```powershell
# Use citool on Win11
citool --list-policies
# Look for: "Audit Mode" vs "Enforce" in the output

# On older builds — decompile and check XML
$cipPath = "C:\Windows\System32\CodeIntegrity\CiPolicies\Active\<PolicyGUID>.cip"
$xmlOut = "C:\Temp\ActivePolicy.xml"
ConvertFrom-CIBinaryPolicy -BinaryFilePath $cipPath -XmlFilePath $xmlOut
Select-Xml -Path $xmlOut -XPath "//Rule/Option" | ForEach-Object { $_.Node.InnerText }
# Look for "Enabled:Audit Mode" or absence (= Enforce)
```

**Step 3 — Check recent CI events (blocks and audit hits)**
```powershell
$since = (Get-Date).AddHours(-24)
Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -ErrorAction SilentlyContinue |
    Where-Object { $_.TimeCreated -gt $since -and $_.Id -in @(3076, 3077, 3089) } |
    Select-Object TimeCreated, Id,
        @{N="File"; E={ $_.Properties[1].Value }},
        @{N="SHA256"; E={ $_.Properties[8].Value }},
        @{N="PolicyName"; E={ $_.Properties[6].Value }} |
    Sort-Object TimeCreated -Descending | Format-Table -AutoSize
```
Event IDs:
- **3076:** Audit mode — would have been blocked (enforcement not active)
- **3077:** Enforce mode — blocked
- **3089:** DLL blocked (UMCI enabled)

**Step 4 — Check AppLocker enforcement and events**
```powershell
# Get effective AppLocker policy enforcement mode
Get-AppLockerPolicy -Effective | ForEach-Object {
    $_.RuleCollections | Select-Object RuleCollectionType, EnforcementMode
}

# Get recent AppLocker block events
Get-WinEvent -LogName "Microsoft-Windows-AppLocker/EXE and DLL" -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message | Format-List
```

**Step 5 — Verify Managed Installer is active (Intune shops)**
```powershell
# Check if MI option is in the active policy
$cipPath = "C:\Windows\System32\CodeIntegrity\CiPolicies\Active\<PolicyGUID>.cip"
$xmlOut = "C:\Temp\PolicyCheck.xml"
ConvertFrom-CIBinaryPolicy -BinaryFilePath $cipPath -XmlFilePath $xmlOut -ErrorAction SilentlyContinue
if (Test-Path $xmlOut) {
    [xml]$policy = Get-Content $xmlOut
    $miRule = $policy.SiPolicy.Rules.Rule | Where-Object { $_.Option -like "*Managed Installer*" }
    if ($miRule) { Write-Host "Managed Installer: ENABLED" -ForegroundColor Green }
    else { Write-Host "Managed Installer: NOT ENABLED" -ForegroundColor Yellow }
}
```

**Step 6 — Check PowerShell language mode**
```powershell
$ExecutionContext.SessionState.LanguageMode
# FullLanguage = unrestricted (WDAC not in enforce or policy permits PS)
# ConstrainedLanguage = WDAC enforce mode active, PowerShell restricted
```

**Step 7 — Verify Intune policy delivery**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 50 |
    Where-Object { $_.Message -like "*ApplicationControl*" -or $_.Message -like "*CodeIntegrity*" } |
    Select-Object TimeCreated, Id, Message | Format-List
```

---
## Troubleshooting Steps (by phase)

### Phase 1 — Policy Not Arriving on Device

Policy deployed in Intune but no .cip file on disk:

1. Verify Intune OMA-URI path exactly:
   - `./Vendor/MSFT/ApplicationControl/Policies/{PolicyGUID}/Policy` — for App Control profile type
   - `./Device/Vendor/MSFT/ApplicationControl/Policies/{PolicyGUID}/Policy` — note the /Device/ prefix matters
2. Policy file must be Base64-encoded .cip content; XML alone is rejected
3. Check size: `(Get-Item <path-to-policy.cip>).Length` — must be under ~3.5 MB for WMI delivery
4. If over size limit: split into base + supplemental policies or remove verbose block rules
5. Check MDM enrollment health: `dsregcmd /status` → look for `MdmEnrollmentState: Enrolled`
6. Force sync: `Invoke-CimMethod -Namespace root\cimv2\mdm\dmmap -ClassName MDM_DMClient -MethodName TriggerSync -Arguments @{ commandID = 1 }`

### Phase 2 — Policy Arrives But Applications Still Blocked

Policy is on disk and citool shows it active, but apps are still being blocked:

1. Check if policy requires a reboot to fully take effect: older Windows builds require reboot; Win11 can use `citool --update-policy`
2. Check enforcement mode — policy may be in Enforce when you expected Audit
3. Check if the blocked binary is in a supplemental policy that hasn't deployed yet
4. Verify the Allow rule level matches the binary's signature:
   - If rule is at `Publisher` level: binary must be signed by that publisher
   - If rule is at `Hash` level: binary must exactly match the SHA256
   - Run: `Get-AuthenticodeSignature -FilePath <blocked-exe>` to see actual signer
5. Check if Deny rule is overriding an Allow rule — Deny always wins

### Phase 3 — Managed Installer Not Working

Apps deployed via Intune are blocked despite MI being enabled:

1. Confirm MI option is in the base policy XML (Step 5 above)
2. Check if the file pre-dates the MI configuration — MI tag is set at file write time
3. Re-deploy the app through Intune to force IME to write it again (sets the MI tag)
4. Check IntuneManagementExtension is listed as an authorized MI:
   ```powershell
   # Check AppLocker managed installer rules (MI uses AppLocker infrastructure)
   Get-AppLockerPolicy -Local | ForEach-Object {
       $_.RuleCollections | Where-Object { $_.RuleCollectionType -eq "ManagedInstaller" } |
       Select-Object -ExpandProperty RuleCollection
   }
   ```
5. Ensure AppIDSvc is running — Managed Installer relies on AppLocker's EKU tag infrastructure even though it's not "AppLocker"

### Phase 4 — Supplemental Policy Issues

Supplemental policy deployed but apps still blocked:

1. Verify BasePolicyID in supplemental matches the running base policy's PolicyID:
   ```powershell
   # Get base policy ID
   citool --list-policies  # note PolicyID of base policy
   
   # Decompile supplemental and check BasePolicyID
   ConvertFrom-CIBinaryPolicy -BinaryFilePath "<supp.cip>" -XmlFilePath "C:\Temp\supp.xml"
   ([xml](Get-Content "C:\Temp\supp.xml")).SiPolicy.BasePolicyID
   # Must match base policy's PolicyID exactly
   ```
2. Supplemental policy must itself be signed (if base policy requires signature verification) — or base policy must include `Unsigned System Integrity Policy` option
3. Check supplemental .cip exists in the Active folder alongside the base policy .cip

---
## Remediation Playbooks

<details><summary>Playbook 1 — Collect blocked applications and build a supplemental allow policy</summary>

**Scenario:** WDAC is in Enforce mode (or recently switched from Audit). A list of blocked applications needs to be allowed without modifying the base policy.

**Step 1 — Collect all blocked binary paths from event log (run in Audit first)**
```powershell
$blockedFiles = Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in @(3076, 3077) } |
    ForEach-Object {
        [PSCustomObject]@{
            TimeCreated = $_.TimeCreated
            FilePath    = $_.Properties[1].Value
            SHA256      = $_.Properties[8].Value
            PolicyName  = $_.Properties[6].Value
        }
    } | Sort-Object FilePath -Unique

$blockedFiles | Export-Csv "C:\Temp\BlockedFiles.csv" -NoTypeInformation
Write-Host "Exported $($blockedFiles.Count) unique blocked files."
$blockedFiles | Format-Table -AutoSize
```

**Step 2 — Categorize by signature status**
```powershell
$categorized = foreach ($file in ($blockedFiles | Where-Object { Test-Path $_.FilePath })) {
    $sig = Get-AuthenticodeSignature -FilePath $file.FilePath
    [PSCustomObject]@{
        FilePath  = $file.FilePath
        Status    = $sig.Status
        Publisher = $sig.SignerCertificate.Subject
        Signed    = ($sig.Status -eq "Valid")
    }
}
$categorized | Format-Table -AutoSize
# Signed files → use Publisher or FilePublisher rule
# Unsigned files → must use Hash rule
```

**Step 3 — Generate supplemental policy (requires ConfigCI module)**
```powershell
# For signed files (publisher-level rules — preferred)
$signedPaths = $categorized | Where-Object { $_.Signed } | Select-Object -ExpandProperty FilePath

New-CIPolicy -FilePath "C:\Temp\Supplemental-NewApps.xml" `
    -DriverFiles (Get-SystemDriver -ScanPath "C:\Temp\ScanDir" -UserPEs -ErrorAction SilentlyContinue) `
    -Level FilePublisher -Fallback Publisher -UserPEs -ErrorAction SilentlyContinue

# For unsigned files (hash rules — will need updating on every file change)
foreach ($file in ($categorized | Where-Object { -not $_.Signed })) {
    $hash = (Get-FileHash -FilePath $file.FilePath -Algorithm SHA256).Hash
    Write-Host "Hash for $($file.FilePath): $hash"
    # Add hash to supplemental XML manually or via WDAC Wizard
}
```

**Step 4 — Mark as supplemental and link to base policy**
```powershell
$basePolicyID = "<get-from-citool>"
Set-CIPolicyIdInfo -FilePath "C:\Temp\Supplemental-NewApps.xml" `
    -SupplementsBasePolicyID $basePolicyID `
    -PolicyName "Supplemental-Approved-Apps-$(Get-Date -Format 'yyyyMMdd')"

# Compile
ConvertFrom-CIPolicyFormat -XmlFilePath "C:\Temp\Supplemental-NewApps.xml" `
    -BinaryFilePath "C:\Temp\Supplemental-NewApps.cip"

Write-Host "Deploy this .cip via Intune OMA-URI to a new policy GUID"
```

**Rollback:** Delete the supplemental .cip from `C:\Windows\System32\CodeIntegrity\CiPolicies\Active\` and run `citool --remove-policy {GUID}` on Win11, or reboot on older builds.

</details>

<details><summary>Playbook 2 — Emergency: switch policy to Audit mode (production incident)</summary>

**Scenario:** WDAC enforce mode is blocking critical production software. Immediate relief needed while an allow rule is built. You have the source policy XML.

**⚠️ Security warning:** This reduces application control enforcement. Document the change, notify security team, and re-enable enforcement ASAP.

**Step 1 — Get the active policy XML**
```powershell
# If you have the source XML in source control — use that (preferred)
# If not, decompile from the active .cip:
$cipPath = (Get-ChildItem "C:\Windows\System32\CodeIntegrity\CiPolicies\Active" -Filter "*.cip" |
    Select-Object -First 1).FullName
$xmlPath = "C:\Temp\Active_Policy_Backup.xml"
ConvertFrom-CIBinaryPolicy -BinaryFilePath $cipPath -XmlFilePath $xmlPath
Write-Host "Decompiled to: $xmlPath"
```

**Step 2 — Modify to Audit mode**
```powershell
[xml]$policy = Get-Content $xmlPath

# Find and replace Enforce with Audit
$rules = $policy.SiPolicy.Rules.Rule
foreach ($rule in $rules) {
    if ($rule.Option -eq "Enabled:Enforce") {
        $rule.Option = "Enabled:Audit Mode"
        Write-Host "Changed Enforce → Audit Mode"
    }
}

# If no "Enabled:Enforce" rule exists, add "Enabled:Audit Mode"
$existingAudit = $rules | Where-Object { $_.Option -eq "Enabled:Audit Mode" }
if (-not $existingAudit) {
    $newRule = $policy.CreateElement("Rule")
    $newOption = $policy.CreateElement("Option")
    $newOption.InnerText = "Enabled:Audit Mode"
    $newRule.AppendChild($newOption) | Out-Null
    $policy.SiPolicy.Rules.AppendChild($newRule) | Out-Null
}

$auditXmlPath = "C:\Temp\Active_Policy_AUDIT.xml"
$policy.Save($auditXmlPath)
Write-Host "Saved audit-mode policy to: $auditXmlPath"
```

**Step 3 — Compile and deploy**
```powershell
$policyGuid = $policy.SiPolicy.PolicyID.Trim("{}")
$cipOutPath = "C:\Windows\System32\CodeIntegrity\CiPolicies\Active\{$policyGuid}.cip"

ConvertFrom-CIPolicyFormat -XmlFilePath $auditXmlPath -BinaryFilePath $cipOutPath

# Refresh (Windows 11 22H2+ — no reboot needed)
citool --update-policy $auditXmlPath

# Older builds — reboot required
# Restart-Computer -Force
```

**Step 4 — Verify audit mode active**
```powershell
citool --list-policies
# Should show policy in Audit mode
# Test the previously-blocked application — it should now run
```

**Rollback (re-enable enforcement):**
Replace `Enabled:Audit Mode` with `Enabled:Enforce` in the XML (or remove the Audit Mode rule), recompile, and deploy.

</details>

<details><summary>Playbook 3 — Configure Managed Installer for Intune deployments</summary>

**Scenario:** Setting up WDAC for the first time in an Intune-managed environment. Want to automatically trust all software deployed through Intune without enumerating every app.

**Background:** Managed Installer uses AppLocker's infrastructure to mark files as they are written by the designated installer (IntuneManagementExtension.exe). This requires both a WDAC policy option AND an AppLocker "ManagedInstaller" rule collection.

**Step 1 — Add Managed Installer option to your WDAC base policy XML**
```powershell
[xml]$policy = Get-Content "C:\Temp\BasePolicy.xml"

# Add Managed Installer rule option
$newRule = $policy.CreateElement("Rule")
$newOption = $policy.CreateElement("Option")
$newOption.InnerText = "Enabled:Managed Installer"
$newRule.AppendChild($newOption) | Out-Null
$policy.SiPolicy.Rules.AppendChild($newRule) | Out-Null
$policy.Save("C:\Temp\BasePolicy_MI.xml")
```

**Step 2 — Create an AppLocker Managed Installer rule for IME**
```powershell
# Create AppLocker policy with Managed Installer rule for IntuneManagementExtension
$miPolicy = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="ManagedInstaller" EnforcementMode="Enabled">
    <FilePublisherRule Id="6CC9B840-B6A2-49CD-A02D-3C9E4B7E657F"
        Name="Microsoft Intune Management Extension" Description=""
        UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US"
            ProductName="MICROSOFT INTUNE MANAGEMENT EXTENSION" BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*"/>
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
  </RuleCollection>
</AppLockerPolicy>
"@

$miPolicy | Out-File "C:\Temp\MI_AppLocker.xml"

# Apply the AppLocker MI policy
Set-AppLockerPolicy -XmlPolicy "C:\Temp\MI_AppLocker.xml" -Merge
```

**Step 3 — Verify AppIDSvc is running (required for MI tagging)**
```powershell
Set-Service -Name AppIDSvc -StartupType Automatic
Start-Service -Name AppIDSvc
Get-Service AppIDSvc | Select-Object Name, Status
```

**Step 4 — Recompile and redeploy base policy with MI option, then reboot**
```powershell
ConvertFrom-CIPolicyFormat -XmlFilePath "C:\Temp\BasePolicy_MI.xml" `
    -BinaryFilePath "C:\Temp\BasePolicy_MI.cip"
# Deploy via Intune and reboot device
```

**Step 5 — Verify MI tagging is working after reboot**
```powershell
# Deploy a test app via Intune, then check if it has the MI tag
# Use the WDAC Debugging Tool or check CI events for 3090 (MI tag set)
Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -eq 3090 } |
    Select-Object TimeCreated, @{N="File"; E={$_.Properties[1].Value}} |
    Sort-Object TimeCreated -Descending | Select-Object -First 10
```

**Rollback:** Remove the `Enabled:Managed Installer` rule from the policy XML, recompile, and redeploy. Remove the AppLocker MI rule: `Set-AppLockerPolicy -XmlPolicy <policy-without-MI-rule> -Merge`

</details>

---
## Evidence Pack

Run this on the affected Windows device to collect all data needed for escalation:

```powershell
<#
.SYNOPSIS  WDAC / App Control Evidence Collector
.NOTES     Run from an elevated PowerShell session on the affected device
           Requires ConfigCI module for policy decompilation (Enterprise/Education editions)
#>

$reportPath = "C:\Temp\WDAC_Evidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

Write-Host "Collecting WDAC evidence to $reportPath..." -ForegroundColor Cyan

# 1. System and OS info
"=== System Info ===" | Out-File "$reportPath\01_System.txt"
[PSCustomObject]@{
    ComputerName   = $env:COMPUTERNAME
    WindowsVersion = (Get-WmiObject Win32_OperatingSystem).Caption
    Build          = (Get-WmiObject Win32_OperatingSystem).BuildNumber
    Edition        = (Get-WmiObject Win32_OperatingSystem).OperatingSystemSKU
} | Format-List | Out-File "$reportPath\01_System.txt" -Append

# 2. Active WDAC policies
"=== Active WDAC Policies ===" | Out-File "$reportPath\02_Policies.txt"
citool --list-policies 2>$null | Out-File "$reportPath\02_Policies.txt" -Append
Get-ChildItem "C:\Windows\System32\CodeIntegrity\CiPolicies\Active" -Filter "*.cip" -ErrorAction SilentlyContinue |
    Select-Object Name, LastWriteTime, Length | Format-Table |
    Out-File "$reportPath\02_Policies.txt" -Append

# 3. Decompile all active policies
$cipFiles = Get-ChildItem "C:\Windows\System32\CodeIntegrity\CiPolicies\Active" -Filter "*.cip" -ErrorAction SilentlyContinue
foreach ($cip in $cipFiles) {
    $xmlOut = "$reportPath\Policy_$($cip.BaseName).xml"
    try {
        ConvertFrom-CIBinaryPolicy -BinaryFilePath $cip.FullName -XmlFilePath $xmlOut -ErrorAction Stop
        Write-Host "Decompiled: $($cip.Name)"
    } catch {
        "Could not decompile (requires ConfigCI): $($cip.Name)" | Out-File $xmlOut
    }
}

# 4. AppLocker effective policy
"=== AppLocker Effective Policy ===" | Out-File "$reportPath\03_AppLocker.txt"
(Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue).ToXml() |
    Out-File "$reportPath\03_AppLocker.txt" -Append

# 5. CI event log (last 48 hours)
"=== CodeIntegrity Events (48h) ===" | Out-File "$reportPath\04_CIEvents.txt"
$since = (Get-Date).AddHours(-48)
Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -ErrorAction SilentlyContinue |
    Where-Object { $_.TimeCreated -gt $since } |
    Select-Object TimeCreated, Id,
        @{N="File"; E={ $_.Properties[1].Value }},
        @{N="PolicyName"; E={ $_.Properties[6].Value }},
        @{N="PolicyID"; E={ $_.Properties[7].Value }} |
    Sort-Object TimeCreated -Descending | Format-Table -AutoSize |
    Out-File "$reportPath\04_CIEvents.txt" -Append

# 6. AppLocker event logs
"=== AppLocker Block Events ===" | Out-File "$reportPath\05_AppLockerEvents.txt"
@("Microsoft-Windows-AppLocker/EXE and DLL","Microsoft-Windows-AppLocker/MSI and Script") |
    ForEach-Object {
        "--- Log: $_ ---" | Out-File "$reportPath\05_AppLockerEvents.txt" -Append
        Get-WinEvent -LogName $_ -MaxEvents 20 -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, Id, Message | Format-List |
            Out-File "$reportPath\05_AppLockerEvents.txt" -Append
    }

# 7. PowerShell language mode
"=== PowerShell Language Mode ===" | Out-File "$reportPath\06_PSLanguageMode.txt"
"Language Mode: $($ExecutionContext.SessionState.LanguageMode)" |
    Out-File "$reportPath\06_PSLanguageMode.txt" -Append

# 8. Services
"=== Key Services ===" | Out-File "$reportPath\07_Services.txt"
Get-Service AppIDSvc, IntuneManagementExtension -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType | Format-Table |
    Out-File "$reportPath\07_Services.txt" -Append

# 9. Intune MDM delivery events
"=== MDM AppControl Delivery ===" | Out-File "$reportPath\08_MDMDelivery.txt"
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -like "*ApplicationControl*" -or $_.Message -like "*CodeIntegrity*" } |
    Select-Object TimeCreated, Id, Message | Format-List |
    Out-File "$reportPath\08_MDMDelivery.txt" -Append

# Compress
Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "`nEvidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List active policies (Win11) | `citool --list-policies` |
| List .cip files on disk | `Get-ChildItem "C:\Windows\System32\CodeIntegrity\CiPolicies\Active"` |
| Decompile .cip to XML | `ConvertFrom-CIBinaryPolicy -BinaryFilePath <.cip> -XmlFilePath <out.xml>` |
| Compile XML to .cip | `ConvertFrom-CIPolicyFormat -XmlFilePath <in.xml> -BinaryFilePath <out.cip>` |
| Refresh policy without reboot (Win11) | `citool --update-policy <policy.xml>` |
| Remove policy without reboot (Win11) | `citool --remove-policy {GUID}` |
| Check CI event blocks | `Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" \| Where-Object { $_.Id -in 3076,3077 }` |
| Check AppLocker blocks | `Get-WinEvent -LogName "Microsoft-Windows-AppLocker/EXE and DLL" -MaxEvents 20` |
| Get file signer | `Get-AuthenticodeSignature -FilePath <exe>` |
| Get file hash | `Get-FileHash -FilePath <exe> -Algorithm SHA256` |
| Check PS language mode | `$ExecutionContext.SessionState.LanguageMode` |
| Test AppLocker policy | `Get-AppLockerPolicy -Effective \| Test-AppLockerPolicy -Path <exe> -User Everyone` |
| Check AppIDSvc | `Get-Service AppIDSvc \| Select-Object Name, Status` |
| Check MI tag on file | `Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_AppLocker` |
| Create new WDAC policy | `New-CIPolicy -FilePath <out.xml> -Level Publisher -Fallback Hash -UserPEs` |
| Create supplemental policy | `Set-CIPolicyIdInfo -FilePath <supp.xml> -SupplementsBasePolicyID <base-GUID>` |
| Merge two policies | `Merge-CIPolicy -PolicyPaths <policy1.xml>,<policy2.xml> -OutputFilePath <merged.xml>` |

---
## 🎓 Learning Pointers

- **WDAC is kernel-enforced and irreversible mid-session — test in Audit mode for at least 2 weeks before enforcing.** Unlike AppLocker, there's no "override as local admin" escape hatch in WDAC. If you push a bad Enforce policy, users are locked out until you push a fix via Intune (or reboot with a corrected .cip). The Audit → Enforce pipeline exists precisely to prevent this. Collect every 3076 event during the Audit period and build Allow rules before switching. [WDAC planning guide](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/design/plan-appcontrol-management)

- **Managed Installer is the right answer for Intune-managed fleets — not per-app hash rules.** Maintaining hash rules for every managed application means updating them on every patch cycle. MI automatically trusts anything written by IntuneManagementExtension.exe with zero manual rule maintenance. The tradeoff is that files written before MI was configured don't have the tag — you'll need to redeploy those apps through Intune. [Managed Installer documentation](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/design/configure-authorized-apps-deployed-with-a-managed-installer)

- **PowerShell Constrained Language Mode is a WDAC side effect, not a separate feature.** When WDAC is in enforce mode and a PowerShell script doesn't match an Allow rule, PowerShell auto-enters CLM. This silently breaks scripts that use `Add-Type`, COM objects, or direct .NET method calls — common in admin and automation scripts. Always test your PowerShell automation in a WDAC audit environment before enforcing. Check `$ExecutionContext.SessionState.LanguageMode` to detect CLM. [PowerShell CLM and WDAC](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/design/appcontrol-and-powershell)

- **Supplemental policies are additive only — you cannot suppress a base policy deny with a supplemental Allow.** A Deny rule in the base policy wins over any Allow rule anywhere. If a vendor is explicitly denied at the base level, a supplemental policy cannot un-deny them. You must modify the base policy. This is by design — it lets central IT set hard denies that business units cannot override.

- **The WDAC Policy Wizard (GUI) is free and dramatically reduces mistakes.** Hand-editing policy XML is error-prone — a misplaced GUID or wrong option string can result in an unbootable system in extreme cases. Microsoft's WDAC Policy Wizard generates correct XML, merges policies, and validates structure. Use it for any non-trivial policy work. [WDAC Policy Wizard](https://webapp-wdac-wizard.azurewebsites.net/)

- **Microsoft's Recommended Block Rules are not the default — you must merge them in.** The base templates (`DefaultWindows_Enforced.xml`, etc.) don't include blocks for known vulnerable drivers or LOLBins. Microsoft publishes maintained block lists that you should merge into your base policy: the Binary Block Rules and the Driver Block Rules. Without them, WDAC's Allow-list approach still permits many living-off-the-land techniques. [Block rules](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/design/applications-that-can-bypass-appcontrol)
