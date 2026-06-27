# Group Policy — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- Applies to Windows 10/11 domain-joined machines in an AD DS environment
- Covers both user and computer policy processing
- Includes GPO preferences, security settings, scripts, and WMI filters
- Does **not** cover Intune MDM policies (see `Intune/Troubleshooting/GP-to-CSP-A.md`)
- Assumes SYSVOL is replicated via DFSR (not FRS — which is deprecated)
- Engineers need RSAT Tools installed for GPMC/gpresult on client

---

## How It Works

<details><summary>Full architecture — Group Policy processing pipeline</summary>

Group Policy flows from **LDAP (AD) + SYSVOL (file share)** to the client via the **Group Policy Client service** (`gpsvc`). It is a two-plane system:

```
Active Directory (LDAP)
  └── GPO Objects (stored in CN=Policies,CN=System,DC=domain,DC=com)
        - GPC (Group Policy Container) — metadata, links, version numbers
        - Links on: Sites / Domains / OUs

SYSVOL Share (\\domain\SYSVOL\domain\Policies\{GUID}\)
  └── GPT (Group Policy Template) — actual settings files
        - Machine\registry.pol — registry-based settings
        - User\registry.pol
        - Machine\Scripts\ / User\Scripts\
        - Machine\Applications\ (software deployment)
        - GPT.ini — version number must match GPC
```

### Processing Order — LSDOU
Policy is applied in this order. **Last writer wins** for conflicts:

```
Local GPO (C:\Windows\System32\GroupPolicy)
  └── Site GPOs (rarely used)
        └── Domain GPOs (Default Domain Policy lives here)
              └── OU GPOs (most specific — usually wins)
                    └── Child OU GPOs
```

**Enforcement** (`Enforced` / `No Override`): An enforced GPO cannot be blocked by a child OU's Block Inheritance. Enforced wins even when out of LSDOU order.

### Client-Side Extensions (CSEs)
CSEs are DLLs registered in the registry that process each policy area. Each CSE decides **when to re-apply** — not all re-apply every cycle:

| CSE | DLL | Re-apply condition |
|-----|-----|-------------------|
| Registry | userenv.dll | Version change or force |
| Security Settings | scecli.dll | Every ~16 hours regardless |
| Scripts | gpscript.dll | Only at startup/logon |
| Folder Redirection | fdeploy.dll | Version change |
| Software Installation | appmgmts.dll | Version change |
| Preferences | gpprefcl.dll | Every cycle (by default) |
| AppLocker | AppIdPolicyCsp.dll | Version change |

### Refresh Intervals
- **Computer policy**: Applied at startup, then every 90 minutes ± 0-30 min jitter
- **User policy**: Applied at logon, then every 90 minutes ± 0-30 min jitter  
- **Security settings**: Every 16 hours even without version change
- **DC-specific**: Every 5 minutes on domain controllers

### Loopback Processing
When a computer GPO sets loopback mode, user GPOs are processed differently:

- **Merge mode**: Computer's user GPOs are appended to user's own GPOs (computer wins conflicts)
- **Replace mode**: User's own GPOs are discarded; only computer's user GPOs apply

This is how kiosk/terminal environments enforce user settings regardless of which user logs in.

### WMI Filters
A GPO can be linked to a WMI query. If the query returns FALSE on the client, the **entire GPO is skipped** for that client. WMI filters add processing time — keep queries efficient.

### Security Filtering
By default, "Authenticated Users" is in the security filter = all domain objects get the GPO.
Removing Authenticated Users and adding specific groups/computers allows targeted application. The computer account needs both **Read** and **Apply Group Policy** permissions.

### Slow Link Detection
If the DC link is detected as slow (default <500 kbps), some CSEs skip processing:
- Software Installation skips
- Folder Redirection skips
- Scripts skip
- Registry settings process regardless

Threshold is set by: `Computer\System\Group Policy\Group Policy slow link detection`

</details>

---

## Dependency Stack

```
[Group Policy Console / GPMC]
        │
        ▼
[Active Directory LDAP]               [SYSVOL Share via DFS-R]
 GPC: {GUID} version=N                 GPT: {GUID}\GPT.ini version=N
        │                                       │
        └──────────────────┬────────────────────┘
                           ▼
                [Group Policy Client Service (gpsvc)]
                 - Runs as SYSTEM
                 - Reads GPC version from LDAP
                 - Compares with cached version
                 - Downloads GPT from SYSVOL if newer
                           │
                           ▼
                [Client-Side Extensions (CSEs)]
                 - Registry, Security, Scripts, etc.
                           │
                           ▼
               [Registry / File system / Services]
                 Applied settings on the endpoint
```

**Critical dependency chain:**
1. DC must be reachable (TCP 445, 389, 88)
2. SYSVOL must be accessible (`\\domain\SYSVOL`)
3. `gpsvc` service must be running
4. GPC version in AD must match GPT version in SYSVOL
5. Computer/user must pass security filter + WMI filter
6. OU structure must place object in correct policy scope

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Settings not applied, no errors in event log | Security filter excludes object | `gpresult /r` — check "Applied GPOs" vs "Denied GPOs" |
| GPO shows "Filtered (Denied)" in gpresult | Missing "Apply Group Policy" permission or WMI filter returned false | Check GPO security filtering in GPMC; test WMI filter manually |
| Settings applied but keep reverting | Another GPO with higher precedence conflicts | `gpresult /h` HTML report — check precedence column |
| Event 1030 or 1058 on client | SYSVOL unreachable or access denied | `net use \\<DC>\sysvol`, check firewall |
| Event 1129 | No DC available during policy processing | Check DNS, LDAP connectivity to DCs |
| User policy not applying | "Process even if the GPO has not changed" not enabled for CSE | Force with `gpupdate /force` or check CSE behavior |
| GPO applies but preference reverts every refresh | GPP item mode is "Update" not "Replace" | Check GPP item action setting |
| Loopback settings not working | Computer policy not applying, or loopback not configured | Check computer GPO loopback setting is enabled |
| Slow GPO processing at logon | WMI filters with complex queries, or many GPOs | Use `gpresult /h` timing info; reduce WMI filter complexity |
| Scripts not running | Scripts run only at startup/logon, not background refresh | Reboot/logoff required; check event 4018/4020 |
| Version mismatch: GPC vs GPT | SYSVOL replication issue | Compare with `Get-GPO` cmdlet vs GPT.ini |

---

## Validation Steps

**Step 1 — Confirm GPO client service is healthy**
```powershell
Get-Service gpsvc | Select-Object Name, Status, StartType
```
Expected good: `Status: Running`, `StartType: Automatic`
Bad: Stopped — restart with `Start-Service gpsvc`

---

**Step 2 — Check which GPOs are applied (quick)**
```powershell
gpresult /r
```
Expected good: Lists GPOs under "Applied Group Policy Objects" for both Computer and User
Bad: "The user does not have RSOP data" or empty applied list

---

**Step 3 — Full HTML report with precedence and reasons**
```powershell
gpresult /h C:\Temp\gpo-report.html /f
Start-Process C:\Temp\gpo-report.html
```
Look at: Applied GPOs, Denied GPOs, and the "Winning GPO" column in settings detail.

---

**Step 4 — Verify SYSVOL reachability**
```powershell
$dc = (Get-ADDomainController -Discover).HostName[0]
Test-Path "\\$dc\SYSVOL"
Get-ChildItem "\\$dc\SYSVOL\$(([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).Name)\Policies\" | Measure-Object
```
Expected good: `True`, and count matches number of GPOs in GPMC
Bad: `False` or access denied — firewall or DFS-R issue

---

**Step 5 — Check GPC vs GPT version consistency**
```powershell
# Pick a GPO GUID from gpresult output
$GPOGuid = "{PASTE-GPO-GUID-HERE}"
$domain = $env:USERDNSDOMAIN
$gpcPath = "LDAP://CN=$GPOGuid,CN=Policies,CN=System,DC=$($domain.Replace('.',',DC='))"
$gpc = [ADSI]$gpcPath
Write-Host "GPC version: $($gpc.versionNumber)"
$gptPath = "\\$domain\SYSVOL\$domain\Policies\$GPOGuid\GPT.INI"
Get-Content $gptPath
```
Expected good: Version numbers match between GPC (LDAP) and GPT (SYSVOL)
Bad: Mismatch — SYSVOL replication is lagging

---

**Step 6 — Check event log for policy errors**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" -MaxEvents 50 |
    Where-Object { $_.Level -le 3 } |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Format-List
```
Key event IDs: 1030, 1058 (SYSVOL access), 1129 (no DC), 7016 (CSE error), 8004 (WMI filter)

---

**Step 7 — Force refresh and capture timing**
```powershell
$start = Get-Date
gpupdate /force
$elapsed = (Get-Date) - $start
Write-Host "GPupdate completed in $($elapsed.TotalSeconds) seconds"
```
Normal: Under 30 seconds on a healthy domain
Slow (>120s): SYSVOL issue, DC unreachability, or complex WMI filters

---

## Troubleshooting Steps (by phase)

### Phase 1 — Policy not applying at all

1. Run `gpresult /r` — is the target GPO in "Applied" or "Denied" list?
2. If **Denied**: Check security filtering in GPMC. Ensure the computer/user account has **Read** + **Apply Group Policy** permission on the GPO.
3. If **not listed**: Check OU location of the object vs. GPO link location in GPMC.
4. Check Block Inheritance: right-click the OU in GPMC — if "Block Inheritance" is set, no parent GPOs apply unless "Enforced".
5. Check WMI filter on the GPO: test the WMI query manually: `Get-WmiObject -Query "<paste WMI query here>"`

### Phase 2 — Policy applies but wrong setting wins

1. Run `gpresult /h C:\Temp\report.html /f` and open it.
2. Find the specific setting under "Computer Configuration" or "User Configuration".
3. The "Winning GPO" column shows which GPO's value is active.
4. Check the "Precedence" column — lower number wins (1 = highest precedence = applied last).
5. If an Enforced GPO is winning unexpectedly, look for the shield icon in GPMC.

### Phase 3 — SYSVOL / version mismatch errors

1. Check DFS-R service on DCs: `Get-Service DFSR -ComputerName <DC>`
2. Check DFS-R replication health: `dfsrdiag ReplicationState`
3. Check for journal wrap or other DFS-R errors in `DFS Replication` event log on DCs.
4. If version mismatch confirmed: force SYSVOL sync or use GPMC "Save" on the GPO to increment version.

### Phase 4 — User policy not applying / loop issues

1. Confirm group policy is applying to users (not just computers): `gpresult /r /scope user`
2. Check "User Configuration" is enabled in GPO properties.
3. For loopback issues: verify the **computer** GPO (not user GPO) has loopback configured.
4. Test with `gpupdate /force /target:user`

### Phase 5 — Scripts not running

1. Verify script path in GPO: `Computer/User Configuration > Windows Settings > Scripts`
2. Scripts only run at startup/logon, not background refresh — reboot/logoff required.
3. Check PowerShell execution policy: script GPOs run in the policy execution context.
4. Event 4018 / 4020 in System log = script policy error.
5. Check if scripts are on SYSVOL (`\\domain\SYSVOL\domain\Policies\{GUID}\Scripts\`)

---

## Remediation Playbooks

<details><summary>Playbook 1 — Fix security filtering (Denied GPO)</summary>

**When:** `gpresult /r` shows GPO as "Denied" — Access Denied

```powershell
# Find the GPO
$GPOName = "<GPO Name>"
$GPO = Get-GPO -Name $GPOName

# Check current permissions
Get-GPPermission -Name $GPOName -All | 
    Select-Object Trustee, Permission, Denied

# Add Apply Group Policy permission for a group
Set-GPPermission -Name $GPOName -TargetName "<GroupName>" `
    -TargetType Group -PermissionLevel GpoApply

# Add for a specific computer
$computerName = "<ComputerName$>"  # note the $
Set-GPPermission -Name $GPOName -TargetName $computerName `
    -TargetType Computer -PermissionLevel GpoApply
```

**Rollback:** Remove the permission addition with `Set-GPPermission -PermissionLevel None`

**Note:** If "Authenticated Users" was removed from security filtering (common for computer-targeted GPOs), ensure the group/computer that should get the policy is explicitly added.

</details>

<details><summary>Playbook 2 — Fix version mismatch (GPC/GPT out of sync)</summary>

**When:** Event 1030 or 1058 with version mismatch detected

```powershell
# Identify affected GPO
$GPOName = "<GPO Name>"
$GPO = Get-GPO -Name $GPOName
Write-Host "GPO ID: $($GPO.Id)"

# Get GPC version from AD
$domain = $env:USERDNSDOMAIN
$gpcPath = "LDAP://CN={$($GPO.Id)},CN=Policies,CN=System,DC=$($domain.Replace('.',',DC='))"
$gpc = [ADSI]$gpcPath
Write-Host "GPC version in AD: $($gpc.versionNumber)"

# Get GPT version from SYSVOL
$gptPath = "\\$domain\SYSVOL\$domain\Policies\{$($GPO.Id)}\GPT.INI"
Write-Host "GPT.ini content:"
Get-Content $gptPath

# If mismatch: force version bump by opening and saving the GPO in GPMC
# OR use PowerShell to touch a setting:
# This forces a version increment and new replication cycle
```

**If SYSVOL is behind:** Check DFS-R status on DCs:
```powershell
Get-WinEvent -LogName "DFS Replication" -MaxEvents 20 -ComputerName <DC> |
    Where-Object { $_.Level -le 3 } | Select-Object TimeCreated, Id, Message
```

**Rollback:** Not needed — version sync is safe.

</details>

<details><summary>Playbook 3 — Fix Block Inheritance blocking critical GPOs</summary>

**When:** Domain-level GPO not reaching a specific OU

```powershell
# Check block inheritance on an OU
$OUPath = "OU=<OUName>,DC=<domain>,DC=<com>"
$OU = [ADSI]"LDAP://$OUPath"
$GPFlags = $OU.gpOptions
Write-Host "gpOptions value: $GPFlags"
# 1 = Block Inheritance enabled; 0 = not blocked

# Remove block inheritance via PowerShell (requires RSAT)
# In GPMC: right-click OU > uncheck Block Inheritance
# OR enforce the GPO at domain level (shield icon in GPMC)
```

**Safer alternative:** Set the critical GPO to "Enforced" at the domain level so Block Inheritance cannot block it. Use sparingly — enforced GPOs can surprise administrators.

**Rollback:** Remove Enforced flag from the GPO link in GPMC.

</details>

<details><summary>Playbook 4 — Diagnose and fix slow GPO processing</summary>

**When:** Logon takes >60 seconds, engineers suspect GPO processing

```powershell
# Enable verbose GP logging
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Diagnostics" `
    /v GPSvcDebugLevel /t REG_DWORD /d 0x30002 /f

# Force refresh
gpupdate /force

# Read the log
Get-Content "$env:windir\debug\usermode\gpsvc.log" | 
    Select-String -Pattern "Timing|milliseconds|error|fail" | 
    Select-Object -Last 50

# Disable logging when done
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Diagnostics" /v GPSvcDebugLevel /f
```

Common causes of slow processing:
- WMI filters with complex queries (each adds 1-10+ seconds)
- Software deployment GPOs on slow links
- Many GPOs (100+) linked at domain/OU level
- SYSVOL on slow SMB link

</details>

---

## Evidence Pack

```powershell
# Run as local admin. Collects all evidence needed for escalation.
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$outDir = "C:\Temp\GPO-Evidence-$timestamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Host "[*] Collecting GPO evidence to $outDir" -ForegroundColor Cyan

# 1. RSoP summary
gpresult /r > "$outDir\gpresult-summary.txt" 2>&1
gpresult /h "$outDir\gpresult-full.html" /f 2>&1 | Out-Null
Write-Host "[OK] gpresult collected" -ForegroundColor Green

# 2. GP event log
Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" -MaxEvents 200 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$outDir\gp-events.csv" -NoTypeInformation
Write-Host "[OK] GP event log exported" -ForegroundColor Green

# 3. System event log (GP-related)
Get-WinEvent -LogName System -MaxEvents 500 | 
    Where-Object { $_.ProviderName -match "Userenv|Group Policy|GroupPolicy" } |
    Select-Object TimeCreated, Id, ProviderName, Message |
    Export-Csv "$outDir\system-gp-events.csv" -NoTypeInformation

# 4. DC connectivity
$domain = $env:USERDNSDOMAIN
$dcs = (Resolve-DnsName -Name "_ldap._tcp.$domain" -Type SRV | 
    Select-Object -ExpandProperty NameTarget -Unique)
$dcs | ForEach-Object {
    $ping = Test-Connection -ComputerName $_ -Count 2 -Quiet
    $sysvol = Test-Path "\\$_\SYSVOL"
    [PSCustomObject]@{
        DC = $_
        Ping = $ping
        SYSVOLAccessible = $sysvol
    }
} | Export-Csv "$outDir\dc-connectivity.csv" -NoTypeInformation
Write-Host "[OK] DC connectivity checked" -ForegroundColor Green

# 5. GP debug log if exists
$gpLog = "$env:windir\debug\usermode\gpsvc.log"
if (Test-Path $gpLog) {
    Copy-Item $gpLog "$outDir\gpsvc.log"
}

# 6. GP service status
Get-Service gpsvc | Select-Object Name, Status, StartType |
    Export-Csv "$outDir\gpsvc-status.csv" -NoTypeInformation

# 7. System info
$sysInfo = @{
    ComputerName = $env:COMPUTERNAME
    Domain = $env:USERDNSDOMAIN
    LoggedOnUser = $env:USERNAME
    OS = (Get-CimInstance Win32_OperatingSystem).Caption
    Timestamp = $timestamp
}
$sysInfo | ConvertTo-Json | Out-File "$outDir\system-info.json"

# Summary
Write-Host ""
Write-Host "Evidence collected to: $outDir" -ForegroundColor Cyan
Write-Host "Files:" -ForegroundColor Cyan
Get-ChildItem $outDir | Select-Object Name, Length | Format-Table -AutoSize
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Show applied GPOs (quick) | `gpresult /r` |
| Full HTML report | `gpresult /h C:\Temp\gpo.html /f` |
| Force immediate refresh | `gpupdate /force` |
| Force computer policy only | `gpupdate /force /target:computer` |
| Force user policy only | `gpupdate /force /target:user` |
| Show GP event log | `Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" -MaxEvents 50` |
| Check gpsvc status | `Get-Service gpsvc` |
| List all GPOs in domain | `Get-GPO -All \| Select-Object DisplayName, Id, GpoStatus` |
| Get GPO report (XML) | `Get-GPOReport -Name "<GPO>" -ReportType Xml -Path C:\Temp\gpo.xml` |
| Check GPO permissions | `Get-GPPermission -Name "<GPO>" -All` |
| Set GPO permission | `Set-GPPermission -Name "<GPO>" -TargetName "<Group>" -TargetType Group -PermissionLevel GpoApply` |
| Find GPO by setting | Use GPMC > Group Policy Results Wizard |
| Test WMI filter query | `Get-WmiObject -Query "<WMI filter query>"` |
| Check SYSVOL access | `Test-Path "\\$env:USERDNSDOMAIN\SYSVOL"` |
| Backup a GPO | `Backup-GPO -Name "<GPO>" -Path C:\Temp\GPOBackup` |
| Restore a GPO | `Restore-GPO -Name "<GPO>" -Path C:\Temp\GPOBackup` |

---

## 🎓 Learning Pointers

- **LSDOU and last-write wins**: Group Policy precedence follows the LSDOU order (Local → Site → Domain → OU), with later-applied GPOs winning. Within an OU, GPOs listed higher in GPMC are applied last (lowest link order number = applied last = wins). See: [Group Policy processing and precedence](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn581922(v=ws.11))

- **CSE re-application logic**: Not all settings re-apply every 90 minutes. Registry-based settings only re-apply when the GPO version increments — this surprises many engineers expecting live enforcement. Security settings (scecli) are the exception: they re-apply every 16 hours regardless. See: [Client-side extension processing](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn605898(v=ws.11))

- **The GPC/GPT version problem**: When SYSVOL replication lags (DFS-R issue), the version number in AD (GPC) and the file in SYSVOL (GPT.ini) can diverge. Clients see the newer GPC version, try to download the GPT, get the old one or none, and log errors 1030/1058. Always check DFS-R health when GPO processing breaks after a DC issue. See: [Troubleshooting SYSVOL replication](https://learn.microsoft.com/en-us/troubleshoot/windows-server/group-policy/sysvol-replica-set-missing)

- **Loopback processing for shared machines**: Kiosk, call centre, and lab machines often need user settings applied based on the **machine**, not the logged-in user. Loopback Replace mode (configured in a computer GPO) discards all user-targeted GPOs and applies only the user settings from GPOs linked to the machine's OU. This is a common source of confusion when admins expect per-user settings to apply on these machines. See: [Loopback processing of Group Policy](https://learn.microsoft.com/en-us/troubleshoot/windows-server/group-policy/loopback-processing-of-group-policy)

- **gpresult HTML report is underused**: Engineers often rely on `gpresult /r` (text output) when `gpresult /h` gives far more: a per-setting "Winning GPO" column, timing information, detailed security filter results, WMI filter evaluation, and a full settings dump. Make the HTML report the first tool for any GPO conflict investigation.

- **Group Policy Preferences vs. Settings**: GPP items (under "Preferences" node) have item-level targeting and four action modes (Create, Replace, Update, Delete). They are not enforced — users can typically undo them. GPO Settings (under "Policies" node) are enforced and restored on next refresh. Mixing them up causes "why does this keep reverting?" confusion. See: [Group Policy Preferences overview](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn581922(v=ws.11))
