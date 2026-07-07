# Group Policy Processing & Replication — Hotfix Runbook (Mode B: Ops)
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

Run these on the affected client (or a DC if the issue is domain-wide) first.

```powershell
# 1. What actually applied, and why did anything get filtered out?
gpresult /h "$env:TEMP\gpresult.html" /f; Invoke-Item "$env:TEMP\gpresult.html"

# 2. Force a refresh and watch it fail live (don't skip this — half of "GPO not applying" tickets are stale cache)
gpupdate /force /wait:120

# 3. Pull the last 20 Group Policy Operational log errors/warnings
Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" -MaxEvents 200 |
    Where-Object LevelDisplayName -in 'Error','Warning' | Select-Object -First 20 TimeCreated, Id, Message

# 4. Is SYSVOL even reachable and readable from this box?
Test-Path "\\$env:USERDNSDOMAIN\SysVol\$env:USERDNSDOMAIN\Policies"
Get-ChildItem "\\$env:USERDNSDOMAIN\SysVol\$env:USERDNSDOMAIN\Policies" -ErrorAction SilentlyContinue | Select-Object -First 5

# 5. Do the AD (GPC) and SYSVOL (GPT) version numbers agree for the GPO in question?
$gpoName = "<GPO-Display-Name>"
Get-GPO -Name $gpoName | Select-Object DisplayName, Id, @{n='ADVersion';e={$_.User.DSVersion + $_.Computer.DSVersion}}
Get-Content "\\$env:USERDNSDOMAIN\SysVol\$env:USERDNSDOMAIN\Policies\{$((Get-GPO -Name $gpoName).Id)}\gpt.ini"
```

| Result | Interpretation |
|---|---|
| Event ID 1058 ("could not access gpt.ini") | SYSVOL path unreachable, permissions issue, or corrupt/missing GPT — see Fix 1 |
| Event ID 1030 ("could not query the list of GPOs") | Usually downstream of 1058 — fix that first, 1030 often clears itself |
| Event ID 1096 ("could not apply registry-based policy settings") | Registry.pol corrupt or locked — see Fix 2 |
| `gpresult` shows GPO under "Denied (Security)" | Security filtering excludes this user/computer — see Fix 3 |
| `gpresult` shows GPO under "Filtered (WMI Filter)" | WMI filter evaluated false on this machine — see Fix 4 |
| GPO missing entirely from `gpresult`, no error | Link disabled, wrong OU, or enforced/blocked inheritance elsewhere — see Fix 5 |
| "AD / SYSVOL Version Mismatch" in `gpresult /h` | GPC (AD) and GPT (SYSVOL) version numbers disagree — see Fix 6, check DFSR replication first |
| Slow logons only, no errors | Slow-link detection or CSE taking too long — see Fix 7 |
| Works for some users/computers, not others, on the exact same OU | Loopback processing or per-object security filtering — see Fix 3/Fix 8 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Group Policy successfully applies on a client
│
├─ 1. Network stack up before logon (fast boot / driver timing)
│      └─ if not: policy applies late as "background" refresh only, some CSEs skipped
│
├─ 2. DNS resolves DC + finds correct AD Site (SRV records, Sites & Services subnets)
│      └─ if not: client talks to a distant DC → slow link detection kicks in
│
├─ 3. Kerberos auth to DC succeeds (client trusts DC, time skew < 5 min)
│      └─ if not: SYSVOL access denied → Event 1058
│
├─ 4. SYSVOL share reachable + GPT.ini readable (SMB, NTFS/share perms)
│      └─ if not: Event 1058 → cascades to 1030
│
├─ 5. GPC (AD) object and GPT (SYSVOL) version numbers match
│      └─ if not: "version mismatch" warning; underlying cause is DFSR replication lag
│      └─ depends on: DFS/Troubleshooting/Replication (SYSVOL is a DFSR replicated folder)
│
├─ 6. GPO scope: linked at reachable OU/domain/site, not disabled, block inheritance / enforced flags correct
│
├─ 7. Security filtering: object has Read + Apply Group Policy on the GPO ACL
│
├─ 8. WMI filter (if any) evaluates true on this machine
│
├─ 9. Loopback mode (if configured) merging/replacing as expected
│
└─ 10. Client-Side Extensions (CSE) apply their settings (Registry.pol, Group Policy Preferences, Scripts, etc.)
       └─ if not: Event 1096 or CSE-specific error, often a corrupt local cache
```

Cross-reference: `DFS/Troubleshooting/Replication/` for SYSVOL/DFSR itself, `ActiveDirectory/Troubleshooting/Replication/` for the AD DS replication that carries the GPC object, `Windows/Troubleshooting/Time/` for Kerberos clock skew.
</details>

---
## Diagnosis & Validation Flow

1. **Confirm scope of the failure.**
   ```powershell
   # Is it one machine or many? Check a second, unaffected machine's gpresult for comparison.
   gpresult /r
   ```
   One machine → client-side problem (steps 2-4 below). Many machines / whole OU → DC or SYSVOL problem (jump to step 5).

2. **Check the Group Policy Operational log for the specific CSE that failed.**
   ```powershell
   Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" -MaxEvents 500 |
       Where-Object { $_.Id -in 1058,1030,1096,1129 } | Format-List TimeCreated, Id, Message
   ```
   Expected good output: no matches in the last logon cycle. Bad: repeated 1058/1096 tied to the same GPO GUID.

3. **Validate SYSVOL reachability and DFS client state.**
   ```powershell
   Get-Service DFS | Select-Object Status, StartType
   nltest /dsgetdc:$env:USERDNSDOMAIN
   ```
   Expected: `DFS` service Running/Automatic; `dsgetdc` returns a reachable, correctly-sited DC.

4. **Validate time sync (Kerberos tolerance is 5 minutes by default).**
   ```powershell
   w32tm /stripchart /computer:<DC-FQDN> /samples:1 /dataonly
   ```
   Expected: offset under a few seconds. Anything over ~300s will start breaking Kerberos and therefore SYSVOL access.

5. **If the whole OU/domain is affected, check SYSVOL replication health on the DCs.**
   ```powershell
   dfsrdiag replicationstate
   Get-WinEvent -LogName "DFS Replication" -MaxEvents 50 | Where-Object LevelDisplayName -eq 'Error'
   ```
   Expected: no backlogged/errored connections. If DFSR is broken, this is a `DFS/` issue wearing a Group Policy costume — go there first.

6. **Confirm GPO scope, security filtering, and WMI filter from the management side.**
   ```powershell
   Get-GPPermission -Name "<GPO-Display-Name>" -All
   (Get-GPO -Name "<GPO-Display-Name>").WmiFilter
   ```
   Expected: target user/computer/group present with Read + Apply Group Policy allow ACE; WMI filter (if any) matches the target hardware/OS.

---
## Common Fix Paths

<details><summary>Fix 1 — Event 1058, SYSVOL/gpt.ini unreachable</summary>

```powershell
# Confirm the exact failing path from the event detail, then test it directly
Test-NetConnection <DC-FQDN> -Port 445
Test-Path "\\<DC-FQDN>\SysVol\$env:USERDNSDOMAIN\Policies\{<GPO-GUID>}\gpt.ini"

# If unreachable: check DFS Namespace + DFSR service on that DC
Invoke-Command -ComputerName <DC-FQDN> -ScriptBlock { Get-Service DFSR, DFS | Select Name, Status }

# If reachable but gpt.ini missing/corrupt on ONE DC but fine on others, force a resync:
dfsrdiag PollAD /Member:<DC-FQDN>
```
Rollback: none needed — this is read/diagnostic only until you touch DFSR (see `DFS/Troubleshooting/Replication/` for backlog remediation, which is destructive-adjacent and has its own rollback notes).
</details>

<details><summary>Fix 2 — Event 1096, registry-based policy failed to apply</summary>

```powershell
# Clear the client-side Group Policy cache for this GPO and re-pull
Remove-Item "$env:WinDir\System32\GroupPolicy\Machine\Registry.pol" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:WinDir\System32\GroupPolicy\User\Registry.pol" -Force -ErrorAction SilentlyContinue
gpupdate /force
```
Rollback: none — these files regenerate automatically on next successful processing cycle. If gpupdate fails to regenerate them, escalate; do not leave a client with deleted Registry.pol unresolved.
</details>

<details><summary>Fix 3 — Denied by security filtering</summary>

```powershell
# Check current ACL
Get-GPPermission -Name "<GPO-Display-Name>" -All | Where-Object Trustee -like "*<user-or-computer>*"

# Grant Read + Apply Group Policy to the target (group preferred over individual objects)
Set-GPPermission -Name "<GPO-Display-Name>" -TargetName "<Group-Name>" -TargetType Group -PermissionLevel GpoApply
```
Rollback: `Set-GPPermission -Name "<GPO-Display-Name>" -TargetName "<Group-Name>" -TargetType Group -PermissionLevel None` to revert.
</details>

<details><summary>Fix 4 — Filtered by WMI filter</summary>

```powershell
# See what filter is attached and what it queries
(Get-GPO -Name "<GPO-Display-Name>").WmiFilter

# Test the WQL query directly against the affected machine to see if it's evaluating as expected
Get-CimInstance -Query "<WQL-query-from-filter>"
```
If the filter is wrong (e.g., targets `Win32_OperatingSystem` version strings that don't match current OS builds after a feature update), fix the WQL query in GPMC — this is a management-side edit, not a client-side one. Rollback: WMI filters are versioned in GPMC; use "Restore" if a prior version is available, or manually revert the WQL text.
</details>

<details><summary>Fix 5 — GPO missing from gpresult, no error at all</summary>

```powershell
# Confirm link state and enforcement/blocking
Get-GPInheritance -Target "<OU-DistinguishedName>"
Get-GPLink -Target "<OU-DistinguishedName>" 2>$null  # or check in GPMC directly if this cmdlet isn't available in your RSAT version

# Confirm the GPO itself isn't disabled
Get-GPO -Name "<GPO-Display-Name>" | Select-Object DisplayName, GpoStatus
```
Common causes: `GpoStatus` set to `UserSettingsDisabled`/`ComputerSettingsDisabled`/`AllSettingsDisabled`; link disabled at the OU; a higher OU has "Block Inheritance" and this GPO isn't marked "Enforced." Rollback: re-enable via `Set-GPLink -Enabled Yes` or `(Get-GPO ...).GpoStatus = 'AllSettingsEnabled'`.
</details>

<details><summary>Fix 6 — AD/SYSVOL version mismatch</summary>

```powershell
# Trigger a no-op edit to force AD (GPC) version to increment and re-sync, OR wait out DFSR replication
# Safer: confirm DFSR isn't actually broken before assuming this will self-heal
dfsrdiag replicationstate
```
If DFSR is healthy, the mismatch is transient (replication lag) and self-heals within the normal DFSR polling interval. If DFSR shows backlog or errors, this is a `DFS/Troubleshooting/Replication/` issue — fix DFSR, do not "fix" GPO version numbers manually. Rollback: N/A, no destructive action taken here.
</details>

<details><summary>Fix 7 — Slow logons from slow-link detection</summary>

```powershell
# Check current connection speed threshold (Computer Config > Admin Templates > System > Group Policy > Configure Group Policy Slow Link Detection)
# Verify what the client actually measured
Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" | Where-Object Id -eq 5312 | Select -First 5 Message
```
If the client is over VPN/WAN and legitimately slow, this is by design (some CSEs skip on slow links, notably Software Installation and Folder Redirection full sync). To change behavior, adjust the "Configure Group Policy Slow Link Detection" policy threshold — do not disable it globally without checking why bandwidth is low first. Rollback: revert the GPO setting to its prior configured value (default: not configured, 500 Kbps effective threshold).
</details>

<details><summary>Fix 8 — Loopback processing not behaving as expected</summary>

```powershell
(Get-GPO -Name "<GPO-Display-Name>")  # confirm loopback mode is set on the correct GPO (computer side)
gpresult /r  # check "Applied Group Policy Objects" list order under both Computer and User sections
```
Merge mode appends computer GPOs after user GPOs (computer wins conflicts); Replace mode discards user GPOs entirely and uses only computer-side user settings. Most "loopback isn't working" tickets are actually security filtering excluding the computer object from the user-targeted GPOs it's supposed to merge/replace. Check Fix 3 first. Rollback: revert loopback mode setting to Not Configured.
</details>

---
## Escalation Evidence

```
GROUP POLICY ESCALATION — [ticket #]
GPO name/GUID affected: ____________________
Affected scope: [ ] Single machine  [ ] Single OU  [ ] Domain-wide
Client OS/build: ____________________
gpresult /h output attached: [ ] Yes
Event IDs observed (with timestamps): ____________________
DFSR replication state (dfsrdiag replicationstate): ____________________
GPC/GPT version numbers (AD vs SYSVOL): ____________________ / ____________________
Time sync offset to DC: ____________________
Security filtering ACL confirmed correct: [ ] Yes  [ ] No
WMI filter present and evaluated: [ ] N/A  [ ] True  [ ] False
Steps already attempted: ____________________
```

---
## 🎓 Learning Pointers
- The 1058 → 1030 cascade is one of the most misdiagnosed pairs in Group Policy — engineers chase 1030 (the symptom) instead of 1058 (the cause). Fix the file-access error first and 1030 usually disappears on its own. See [Applying Group Policy troubleshooting guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/group-policy/applying-group-policy-troubleshooting-guidance).
- "AD/SYSVOL version mismatch" is a symptom, not a root cause — it almost always traces back to DFSR replication lag or an interrupted FRS-to-DFSR migration. Never try to manually force version numbers; fix replication instead. See [DFSR SYSVOL fails to migrate or replicate](https://learn.microsoft.com/en-us/troubleshoot/windows-server/group-policy/dfsr-sysvol-fails-migrate-replicate) and this repo's `DFS/Troubleshooting/FRS-Migration/`.
- Loopback processing tickets are usually security-filtering tickets in disguise — the loopback mechanism itself rarely misbehaves; what fails is the computer object having Apply Group Policy rights on the user-targeted GPO it's supposed to merge or replace.
- Keep WMI filters simple and few. Every WMI filter is evaluated synchronously during policy processing and adds measurable delay to boot/logon — a complex filter estate is a common, self-inflicted cause of "slow logons" tickets.
- The Group Policy Operational log (not the System or Application log) is the single most useful log for this domain — always start there before `gpresult`.
