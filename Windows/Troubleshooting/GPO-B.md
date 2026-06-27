# Group Policy — Hotfix Runbook (Mode B: Ops)
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

Run these immediately. Each result tells you where to go next.

```powershell
# 1 — Check if GP processing succeeded in the last cycle
Get-WinEvent -LogName "System" -FilterXPath "*[System[Provider[@Name='Microsoft-Windows-GroupPolicy']]]" |
    Select-Object TimeCreated, Id, Message | Select-Object -First 5

# 2 — Check effective policy application (RSoP snapshot)
gpresult /r /scope computer

# 3 — Check DC connectivity and SysVol accessibility
nltest /dsgetdc:<domain.com> /force
Test-Path "\\<domain.com>\SYSVOL\<domain.com>\Policies"

# 4 — Force GP update and capture output
gpupdate /force 2>&1

# 5 — Check GP processing time (slow processing = WMI/network issue)
Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" |
    Where-Object {$_.Id -in @(4000, 4001, 5312, 5313)} |
    Select-Object TimeCreated, Id, Message | Select-Object -First 10
```

**Interpretation:**
| Result | Action |
|--------|--------|
| Event ID 1085 / 1096 in System log | CSE (Client-Side Extension) failed — go to Fix 2 |
| `gpresult /r` shows no GPOs applied | DC not reachable or SysVol inaccessible — go to Fix 1 |
| `nltest` returns "ERROR_NO_SUCH_DOMAIN" | DNS resolution failure — check DNS first |
| `gpupdate /force` hangs >60 seconds | Network/firewall blocking SMB to DC — go to Fix 1 |
| GP events show 5312/5313 with high duration (>30s) | Slow logon, WMI filter issue or large GPO — go to Fix 3 |
| Specific settings not applying despite GPO | Check RSoP / resultant set, WMI filter, security filtering — Fix 4 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Active Directory Domain
└── Domain Controller reachable (TCP 389/636, UDP 88, TCP 445)
    └── SYSVOL accessible (SMB \\domain\SYSVOL)
        └── NETLOGON share accessible (\\domain\NETLOGON)
            └── DNS resolving domain controllers (_ldap._tcp.dc._msdcs.<domain>)
                └── Kerberos authentication working (UDP/TCP 88)
                    └── Group Policy Client Service (gpsvc) — running
                        └── WMI Service (winmgmt) — running (for WMI filters)
                            └── RSoP / GP CSEs execute in order
                                └── Settings applied to registry/filesystem
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Check GP event log for errors**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" -MaxEvents 50 |
    Where-Object {$_.LevelDisplayName -in @("Error", "Warning")} |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Format-List
```
Expected: No errors. Events 4001 (start) and 4004 (success) for each cycle.  
Bad: Event 7016, 1085, or CSE-specific errors — note the CSE GUID in the message.

**Step 2 — Run RSoP for a specific user/computer**
```powershell
# HTML report (most useful)
gpresult /h "$env:TEMP\gpresult.html" /f
# Open in browser:
Start-Process "$env:TEMP\gpresult.html"

# Text summary
gpresult /r /scope computer
gpresult /r /scope user
```
Expected: Applied GPOs listed with "success," settings visible under each extension.  
Bad: GPO listed as "Denied" (security filtering), "Inaccessible" (SYSVOL), or missing entirely.

**Step 3 — Verify DC and SysVol reachability**
```powershell
$domain = $env:USERDNSDOMAIN
$dc = (nltest /dsgetdc:$domain /force 2>&1 | Select-String "DC:").ToString().Trim()
Write-Host "DC: $dc"

# Test SysVol
$sysvolPath = "\\$domain\SYSVOL\$domain\Policies"
Test-Path $sysvolPath

# List policies in SysVol (should match GPMC count)
(Get-ChildItem $sysvolPath).Count
```
Expected: SysVol accessible, policy count matches what's in GPMC.  
Bad: `Test-Path` returns False or count mismatch — DFS-R replication issue or SYSVOL not initialized.

**Step 4 — Check Group Policy Client Service**
```powershell
Get-Service gpsvc | Select-Object Name, Status, StartType
```
Expected: `Running`, `Automatic`.  
Bad: Stopped — restart it: `Start-Service gpsvc`

**Step 5 — Check WMI filter evaluation (if filters used)**
```powershell
# List GPOs with WMI filters from GP event log
Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" |
    Where-Object {$_.Message -like "*WMI*"} |
    Select-Object TimeCreated, Message | Select-Object -First 5
```
Expected: WMI filter evaluated and matched/not-matched cleanly.  
Bad: WMI filter evaluation errors — check `winmgmt` service and run `winmgmt /verifyrepository`

---

## Common Fix Paths

<details><summary>Fix 1 — DC/SysVol Unreachable</summary>

```powershell
$domain = $env:USERDNSDOMAIN

# Test required ports to DC
$dc = (Resolve-DnsName "_ldap._tcp.dc._msdcs.$domain" -Type SRV | Select-Object -First 1).NameTarget
Write-Host "Testing connectivity to DC: $dc"

# Kerberos
Test-NetConnection -ComputerName $dc -Port 88
# LDAP
Test-NetConnection -ComputerName $dc -Port 389
# SMB (SysVol)
Test-NetConnection -ComputerName $dc -Port 445

# If SMB blocked — check firewall
Get-NetFirewallRule | Where-Object {$_.DisplayName -like "*File*" -and $_.Action -eq "Block"} |
    Select-Object DisplayName, Direction, Enabled

# Flush DNS and re-register
ipconfig /flushdns
ipconfig /registerdns

# Re-join if domain trust is broken (last resort)
# Test-ComputerSecureChannel -Repair -Credential (Get-Credential)
```

**Rollback:** DNS flush is non-destructive. Secure channel repair requires domain admin credentials.
</details>

<details><summary>Fix 2 — CSE (Client-Side Extension) Failure</summary>

Identify the failing CSE from event log message (look for GUID), then:

```powershell
# Common CSE GUID → Name mapping
$cseMap = @{
    "{00000000-0000-0000-0000-000000000000}" = "Core GP processing"
    "{35378EAC-683F-11D2-A89A-00C04FBBCFA2}" = "Registry (Administrative Templates)"
    "{827D319E-6EAC-11D2-A4EA-00C04F79F83A}" = "Security Settings"
    "{e437bc1c-aa7d-11d2-a382-00c04f991e27}" = "IP Security"
    "{42B5FAAE-6536-11d2-AE5A-0000F87571E3}" = "Scripts (Startup/Shutdown)"
    "{827D319E-6EAC-11D2-A4EA-00C04F79F83A}" = "Security Settings"
    "{0ACDD3F7-4F01-4EFA-8102-28E4ABB36D7E}" = "Wireless (802.11)"
}

# For Registry/AdmX CSE failures — check ADMX template availability
$sysvolPolicies = "\\$env:USERDNSDOMAIN\SYSVOL\$env:USERDNSDOMAIN\Policies"
Test-Path "$sysvolPolicies\PolicyDefinitions"

# For Security Settings CSE failure — rebuild secedit database
secedit /configure /db secedit.sdb /cfg "$env:windir\inf\defltbase.inf" /overwrite /quiet

# For Script CSE failure — check SYSVOL\Scripts share
Test-Path "\\$env:USERDNSDOMAIN\NETLOGON"
```

**Rollback:** The `secedit /configure` command resets local security policy to defaults — only use if security settings CSE is the failure and you have a backup.
</details>

<details><summary>Fix 3 — Slow Group Policy Processing / Long Logon</summary>

```powershell
# Identify the slow CSE from GP Operational log
$slowEvents = Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" |
    Where-Object {$_.Id -eq 5312 -or $_.Id -eq 5313} |
    Select-Object TimeCreated, Message

# Parse duration from message (look for milliseconds)
$slowEvents | ForEach-Object {
    if ($_.Message -match "Duration\s+(\d+)\s+ms") {
        [PSCustomObject]@{Time = $_.TimeCreated; Duration_ms = [int]$Matches[1]; Msg = $_.Message.Substring(0,80)}
    }
} | Sort-Object Duration_ms -Descending | Select-Object -First 10

# Check for DNS-related slowness (reverse lookup failures)
Resolve-DnsName $env:COMPUTERNAME -Type PTR -ErrorAction SilentlyContinue

# Disable slow link detection if on fast network (GPO setting that may trigger)
# Computer Config > Admin Templates > System > Group Policy > "Configure slow link detection" — set threshold

# Reduce GP processing overhead: disable loopback if not needed
# Check current loopback mode:
(Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System").UserPolicyMode 2>$null
```
</details>

<details><summary>Fix 4 — Specific Settings Not Applying (Security Filtering / Loopback)</summary>

```powershell
# Check security filtering — device/user must have "Read" + "Apply Group Policy" on the GPO
# Run from a domain-joined machine with RSAT:
# Get-GPPermissions -Name "<GPO Name>" -All

# Check if "Authenticated Users" was removed (common mistake)
# If removed, add the computer account or a group containing the computer

# Check resultant set to see why a specific setting is missing
gpresult /h "$env:TEMP\rsop.html" /f
Start-Process "$env:TEMP\rsop.html"

# Check for GPO precedence conflicts (higher-precedence GPO overriding)
# In the HTML report, check "Winning GPO" for each setting

# Check WMI filter if one is applied to the GPO
# WMI filter must return TRUE for the GPO to apply
# Test manually:
$filter = "SELECT * FROM Win32_OperatingSystem WHERE Version LIKE '10.%'"
$result = Get-WmiObject -Query $filter
if ($result) { Write-Host "WMI filter would MATCH" -ForegroundColor Green } else { Write-Host "WMI filter would NOT match" -ForegroundColor Red }

# Reset GP cache (forces full re-read from SysVol)
Remove-Item "$env:windir\System32\GroupPolicy\Machine\registry.pol" -ErrorAction SilentlyContinue
Remove-Item "$env:windir\System32\GroupPolicy\User\registry.pol" -ErrorAction SilentlyContinue
gpupdate /force
```

**Rollback:** Deleting `registry.pol` removes cached GP settings. `gpupdate /force` will reapply from SysVol within ~90 seconds.
</details>

<details><summary>Fix 5 — SysVol Replication Broken (DFS-R)</summary>

```powershell
# Check DFS-R health between DCs
# Run on each DC or use Get-DFSRBacklog from DFS runbook

# Quick check — compare GPO counts between DCs
$domain = $env:USERDNSDOMAIN
$dcs = (Get-ADDomainController -Filter * -Server $domain).HostName
foreach ($dc in $dcs) {
    $count = (Get-ChildItem "\\$dc\SYSVOL\$domain\Policies" -ErrorAction SilentlyContinue).Count
    Write-Host "$dc : $count GPOs" -ForegroundColor $(if ($count -gt 0) { "Green" } else { "Red" })
}

# If counts differ — SysVol is out of sync
# See DFS Replication runbook: Replication-B.md
# Quick fix: force DFS-R replication
Invoke-Command -ComputerName <DC-Name> -ScriptBlock {
    dfsrdiag SyncNow /Partner:<Partner-DC> /RGName:"Domain System Volume" /Full
}
```
</details>

---

## Escalation Evidence

```
TICKET: Group Policy Processing Failure
=======================================
Date/Time       : _______________
Affected Device : _______________
Domain          : _______________
User Account    : _______________

Symptoms
--------
GPO(s) not applying       : [ ] Yes  [ ] No
Settings not taking effect : [ ] Yes  [ ] No
Logon slow                : [ ] Yes  [ ] No  (~___ seconds)
gpupdate hangs            : [ ] Yes  [ ] No

Triage Results
--------------
GP Operational log errors : _______________  (Event IDs: _______)
gpresult /r output        : [ ] Attached
RSoP HTML report          : [ ] Attached
nltest /dsgetdc output    : _______________
SysVol accessible         : [ ] Yes  [ ] No
DC tested                 : _______________
Port 88 open              : [ ] Yes  [ ] No
Port 389 open             : [ ] Yes  [ ] No
Port 445 open             : [ ] Yes  [ ] No

Fixes Already Tried
-------------------
[ ] gpupdate /force
[ ] DNS flush (ipconfig /flushdns)
[ ] Restarted gpsvc
[ ] Cleared registry.pol
[ ] Netlogon/SysVol connectivity confirmed

Evidence Files Attached
-----------------------
[ ] gpresult_<hostname>.html
[ ] GP_Operational_log.evtx
[ ] nltest_output.txt
```

---

## 🎓 Learning Pointers

- **GPO processing order is LSDOU:** Local → Site → Domain → OU. Policies lower in the list (OU) win by default. Enforced GPOs override this order and always win — understanding this prevents hours of "why isn't my setting applying" confusion. See [MS Docs: Group Policy processing order](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-R2-and-2012/dn581922(v=ws.11)).

- **The GP Operational event log is your first tool, not GPResult.** `Microsoft-Windows-GroupPolicy/Operational` contains timestamped entries for every CSE execution, including which GPO was processed and how long it took. Event 7016 is a CSE failure and always contains the GUID of the failing extension.

- **Security filtering requires Read AND Apply Group Policy ACEs.** Removing "Authenticated Users" from the GPO's security filtering without adding the specific group back is the #1 cause of "GPO exists but does nothing." Always verify both permissions in GPMC → Delegation tab.

- **SysVol and DFS-R are separate problems.** SysVol replication failures manifest as GPO count mismatches between DCs and stale settings. See the DFS Replication runbook (`Replication-B.md`) for DFS-R specific remediation — the fix there (authoritative restore) is destructive and should only follow that guide.

- **Loopback processing changes GPO user scope.** When enabled (Merge or Replace mode), computer-targeted GPOs also apply user settings based on which computer the user logs into — useful for kiosks and RDS/AVD hosts but a common source of "unexpected settings" complaints. Check `HKLM:\SOFTWARE\Policies\Microsoft\Windows\System\UserPolicyMode` to see if it's active.
