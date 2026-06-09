# AppLocker — Hotfix Runbook (Mode B: Ops)
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

Run these first on the affected device (PowerShell as Administrator):

```powershell
# 1. Is AppLocker enforced?
Get-AppLockerPolicy -Effective | Select-Object -ExpandProperty RuleCollections | 
    Select-Object RuleCollectionType, EnforcementMode

# 2. What rules apply to this user/app?
Get-AppLockerFileInformation -Path "C:\Path\To\Blocked.exe" | 
    Test-AppLockerPolicy -User "DOMAIN\username"

# 3. Recent AppLocker blocks (last 30 events)
Get-WinEvent -LogName "Microsoft-Windows-AppLocker/EXE and DLL" -MaxEvents 30 |
    Where-Object { $_.Level -eq 2 -or $_.Id -in 8004, 8007 } |
    Select-Object TimeCreated, Message | Format-List

# 4. AppID service (required for AppLocker)
Get-Service -Name AppIDSvc | Select-Object Status, StartType

# 5. Effective policy source
Get-AppLockerPolicy -Effective -Xml | Select-String "EnforcementMode" | Select-Object -First 5
```

**Interpretation:**

| Result | Meaning | Action |
|--------|---------|--------|
| `EnforcementMode: Enabled` | AppLocker is actively blocking | Check Fix Paths 1–3 |
| `EnforcementMode: AuditOnly` | Logging only, not blocking | AppLocker not the cause of block; check other controls |
| `AppIDSvc` is Stopped | AppLocker won't enforce; silently fails | Fix Path 4 |
| Event ID **8004** | EXE/DLL blocked by AppLocker | Fix Path 1 or 2 |
| Event ID **8007** | Script blocked by AppLocker | Fix Path 1 or 2 |
| Event ID **8003** | File was audited (AuditOnly mode) | Rule exists; in prod this would block |
| `Test-AppLockerPolicy` returns `Denied` | Specific rule is catching this file | Fix Path 2 |
| No events, app still won't run | AppLocker may not be the blocker — check WDAC, AV, SRP | Fix Path 5 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Group Policy / Intune CSP
        │  delivers AppLocker XML policy
        ▼
AppLocker Policy (HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2)
        │
        ▼
AppID Service (AppIDSvc) — MUST be running
        │  evaluates file identity attributes
        ▼
AppID Policy Engine (appid.sys kernel driver)
        │  intercepts process creation events
        ▼
File Identity Checks
        ├── Publisher rule → checks Authenticode signature
        ├── Hash rule → SHA256 hash of file
        └── Path rule → filesystem path match
        │
        ▼
Decision: Allow / Deny / Audit
        │
        ▼
Event Log: Microsoft-Windows-AppLocker/EXE and DLL
           Microsoft-Windows-AppLocker/MSI and Script
           Microsoft-Windows-AppLocker/Packaged app-Deployment
```

**Common failure modes:**
- AppIDSvc stopped → rules silently not enforced (files run unchecked)
- Hash rule → app updated → hash mismatch → blocked
- Publisher rule → app loses signature (corrupt install) → falls to hash/path rule → may block
- Path rule too broad → blocks unintended files in same directory

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm AppLocker is the blocker**
```powershell
# Check event logs for the blocked file name
Get-WinEvent -LogName "Microsoft-Windows-AppLocker/EXE and DLL" -MaxEvents 100 |
    Where-Object { $_.Id -eq 8004 } |
    Select-Object TimeCreated, @{n='Details';e={$_.Message}} |
    Format-List
```
If no Event ID 8004/8007: AppLocker is not the blocker. Check WDAC, AV exclusions, or permissions.

**Step 2 — Identify which rule is blocking**
```powershell
# Get file info to understand what rule could match
Get-AppLockerFileInformation -Path "<C:\Path\To\App.exe>"
# Look at: Publisher, Hash, Path attributes
```

**Step 3 — Test policy against specific user**
```powershell
Get-AppLockerPolicy -Effective | 
    Test-AppLockerPolicy -Path "<C:\Path\To\App.exe>" -User "<DOMAIN\Username>"
```
Output will show `Allowed` or `Denied` and which rule is responsible.

**Step 4 — Check if AppIDSvc is running**
```powershell
Get-Service AppIDSvc
```
If stopped: `Start-Service AppIDSvc` — then re-test.

**Step 5 — Review effective policy**
```powershell
Get-AppLockerPolicy -Effective | 
    ForEach-Object { $_.RuleCollections } |
    Select-Object RuleCollectionType, EnforcementMode, @{n='Rules';e={$_.Count}}
```

---

## Common Fix Paths

<details><summary>Fix 1 — Emergency: Switch rule collection to AuditOnly</summary>

**When to use:** Urgent business blocker; need to restore access immediately while permanent fix is prepared.

⚠️ Only do this if the blockage is confirmed business-critical. AuditOnly disables enforcement for that rule collection.

```powershell
# Get current effective policy as XML
$policy = Get-AppLockerPolicy -Effective -Xml

# Switch EXE enforcement to AuditOnly in the XML
$policyModified = $policy -replace 'Type="Exe" EnforcementMode="Enabled"', 'Type="Exe" EnforcementMode="AuditOnly"'

# Apply modified policy (local override — GPO will re-enforce at next refresh)
Set-AppLockerPolicy -XmlPolicy $policyModified

Write-Warning "AppLocker EXE enforcement set to AuditOnly — this will revert on next Group Policy refresh"
```

**Revert:**
```powershell
# Force GP refresh to restore enforced state
gpupdate /force
```

**Note:** If policy comes from Intune, it will re-enforce on next check-in (typically within 30 min).

</details>

<details><summary>Fix 2 — Add Publisher or Hash rule for blocked application</summary>

**When to use:** Legitimate application blocked by AppLocker; need to create a permanent allow rule.

**Step 1 — Get file information to build the rule**
```powershell
$FileInfo = Get-AppLockerFileInformation -Path "C:\Program Files\App\App.exe"
$FileInfo | Format-List *
```

**Step 2 — Generate a publisher-based rule (preferred — survives updates)**
```powershell
# Generate rule XML from the file
New-AppLockerPolicy -FileInformation $FileInfo -RuleType Publisher -User "Everyone" -Xml |
    Out-File "C:\Temp\NewRule.xml"

# Review the generated XML before applying
Get-Content "C:\Temp\NewRule.xml"
```

**Step 3 — Merge into existing policy**
```powershell
# Get current effective policy
Get-AppLockerPolicy -Effective -Xml | Out-File "C:\Temp\CurrentPolicy.xml"

# Merge new rule into current policy
$merged = Merge-AppLockerPolicy -PolicyToMerge "C:\Temp\NewRule.xml" -Policy (Get-AppLockerPolicy -Effective)
Set-AppLockerPolicy -PolicyObject $merged
```

**Important:** For domain-joined devices, the definitive fix is adding the rule to the GPO, not locally on the device. Local changes are overwritten at next GP refresh.

**If file is unsigned (no publisher info):** Use hash rule instead:
```powershell
New-AppLockerPolicy -FileInformation $FileInfo -RuleType Hash -User "Everyone" -Xml |
    Out-File "C:\Temp\HashRule.xml"
```
⚠️ Hash rules break when the file is updated — rebuild after every update.

</details>

<details><summary>Fix 3 — Packaged App (MSIX/Store app) blocked</summary>

**When to use:** Windows Store / MSIX app blocked; check `Microsoft-Windows-AppLocker/Packaged app-Deployment` log.

```powershell
# Check packaged app AppLocker events
Get-WinEvent -LogName "Microsoft-Windows-AppLocker/Packaged app-Deployment" -MaxEvents 50 |
    Where-Object { $_.Id -eq 8024 } |
    Select-Object TimeCreated, Message

# Get packaged app info for rule creation
$appxInfo = Get-AppxPackage -Name "*AppName*"
$appxInfo | Format-List Name, Publisher, PackageFamilyName

# Generate allow rule for packaged app
New-AppLockerPolicy -FileInformation (Get-AppLockerFileInformation -Packages $appxInfo) `
    -RuleType Publisher -User "Everyone" -Xml | Out-File "C:\Temp\PackagedAppRule.xml"
```

</details>

<details><summary>Fix 4 — AppIDSvc stopped (AppLocker not enforcing)</summary>

**When to use:** AppIDSvc is stopped — this means AppLocker policy exists but nothing is being enforced (security gap).

```powershell
# Start the service
Start-Service -Name AppIDSvc

# Set to Automatic start
Set-Service -Name AppIDSvc -StartupType Automatic

# Verify
Get-Service AppIDSvc | Select-Object Status, StartType
```

**If AppIDSvc fails to start:**
```powershell
# Check for dependency failures
sc.exe qc AppIDSvc
# Dependencies: RpcSs (Remote Procedure Call), CryptSvc (Cryptographic Services)
Get-Service RpcSs, CryptSvc | Select-Object Name, Status

# Check System event log for AppIDSvc errors
Get-WinEvent -LogName System | 
    Where-Object { $_.ProviderName -eq "Service Control Manager" -and $_.Message -like "*AppIDSvc*" } |
    Select-Object -Last 10 | Format-List
```

</details>

<details><summary>Fix 5 — AppLocker not the blocker (application still failing)</summary>

**When to use:** No AppLocker events for the file; application still fails to run.

**Check WDAC (Windows Defender Application Control):**
```powershell
# WDAC is a separate, stronger control that operates below AppLocker
Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -MaxEvents 50 |
    Where-Object { $_.Id -in 3076, 3077 } |
    Select-Object TimeCreated, Message | Format-List
```
If events found: WDAC is blocking — see WDAC runbooks.

**Check Defender Exploit Protection / ASR:**
```powershell
Get-MpPreference | Select-Object AttackSurfaceReductionRules_Actions, 
    AttackSurfaceReductionRules_Ids
```

**Check file permissions:**
```powershell
Get-Acl "C:\Path\To\App.exe" | Format-List
icacls "C:\Path\To\App.exe"
```

**Check if file is blocked by ADS Zone.Identifier (downloaded from internet):**
```powershell
Get-Item "C:\Path\To\App.exe" -Stream * | Where-Object Stream -ne ':$DATA'
# If Zone.Identifier present:
Unblock-File "C:\Path\To\App.exe"
```

</details>

---

## Escalation Evidence

```
TICKET: AppLocker Block / Policy Issue
========================================================
Date/Time:            _______________
Raised by:            _______________
Affected user(s):     _______________
Device name(s):       _______________
Windows version:      _______________
Blocked application:  _______________
Full path:            _______________

AppLocker enforcement mode (EXE collection):
[ ] Enabled  [ ] AuditOnly  [ ] Not configured

AppIDSvc status:  [ ] Running  [ ] Stopped  [ ] Disabled

Event IDs found in AppLocker log:
[ ] 8004 (EXE blocked)
[ ] 8007 (Script blocked)
[ ] 8003 (Audit only)
[ ] 8024 (Packaged app)
[ ] None — AppLocker not blocking

File info (Get-AppLockerFileInformation output):
Publisher:     _______________
Hash:          _______________
Path:          _______________
Signed:        [ ] Yes  [ ] No

Test-AppLockerPolicy result:    [ ] Allowed  [ ] Denied
Rule responsible:               _______________

Policy source:   [ ] GPO  [ ] Intune  [ ] Local  [ ] Unknown

WDAC events present (CodeIntegrity log 3076/3077):  [ ] Yes  [ ] No

Fix paths attempted:
[ ] Fix 1 - AuditOnly override
[ ] Fix 2 - New allow rule added
[ ] Fix 3 - Packaged app rule
[ ] Fix 4 - AppIDSvc restarted
[ ] Fix 5 - Not AppLocker (other control)

Business impact:        _______________
Escalation required to: _______________
========================================================
```

---

## 🎓 Learning Pointers

- **AppLocker vs WDAC — know the hierarchy.** AppLocker is user-mode policy managed by AppIDSvc. WDAC (Windows Defender Application Control) operates in the kernel via Code Integrity and cannot be bypassed by a compromised AppIDSvc. For high-security environments, WDAC is the preferred control; AppLocker is a good first step. Both can coexist. [AppLocker vs WDAC](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/applocker/applocker-overview)

- **AppIDSvc stopped = no enforcement, no alerts.** If AppIDSvc is stopped (manually, by malware, or via GPO misconfiguration), AppLocker silently stops enforcing. This is a critical security gap that generates no immediate alert. Add AppIDSvc monitoring to your RMM checks. [AppLocker requirements](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/applocker/requirements-to-use-applocker)

- **Publisher rules survive app updates; hash rules don't.** A publisher rule based on the certificate chain (Publisher + ProductName) will continue to allow new versions of the same signed application. Hash rules break with every file change. Prefer publisher rules for commercially signed software, hash for unsigned in-house tools. [Understanding AppLocker rule types](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/applocker/understanding-applocker-rule-condition-types)

- **Default rules are critical for Windows functionality.** AppLocker ships with recommended default rules that allow `%PROGRAMFILES%`, `%WINDIR%`, and Microsoft-signed files. If you deploy a custom policy without these defaults, Windows itself can break. Always start from the default rules template and add restrictions. Use Audit mode for at least two weeks in a new environment.

- **The AppLocker audit logs are your rollout safety net.** Before enforcing, run in AuditOnly mode and collect Event ID 8003 logs across a representative user population for 2 weeks. This reveals every application that would be blocked. `Get-WinEvent -LogName "Microsoft-Windows-AppLocker/EXE and DLL" | Where Id -eq 8003` — build your allow rules from this output.
