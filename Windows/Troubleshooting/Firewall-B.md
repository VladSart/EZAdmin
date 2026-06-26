# Windows Firewall — Hotfix Runbook (Mode B: Ops)
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

Run these first — results dictate which fix path to follow.

```powershell
# 1 — Firewall service state
Get-Service -Name mpssvc | Select-Object Name, Status, StartType

# 2 — Firewall profile states
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction

# 3 — Active firewall rules blocking the affected app/port
$port = 443   # change to the affected port
Get-NetFirewallRule -Enabled True -Direction Inbound -Action Block |
    Get-NetFirewallPortFilter | Where-Object LocalPort -eq $port

# 4 — Check if Base Filtering Engine (BFE) is running (required by WFP/Firewall)
Get-Service -Name BFE | Select-Object Status, StartType

# 5 — Recent firewall drop events (requires Firewall Logging or Audit enabled)
Get-WinEvent -LogName "Security" -FilterXPath "*[System[EventID=5152 or EventID=5157]]" -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Message | Format-Table -Wrap
```

**Interpretation table:**

| Result | Meaning | Action |
|--------|---------|--------|
| `mpssvc` stopped | Firewall service dead | Go to Fix 1 |
| `BFE` stopped | Platform engine down; mpssvc will fail too | Go to Fix 1, start BFE first |
| Profile `Enabled = False` | Firewall entirely off on that profile | Go to Fix 2 to re-enable safely |
| Block rule found for the port | Explicit deny rule in place | Go to Fix 3 |
| No block rule, but traffic dropping | Stealth mode or policy overriding | Go to Fix 4 |
| EventID 5157 flooded | Application-layer drops; probably no allow rule | Go to Fix 3, create allow rule |

---

## Dependency Cascade

<details><summary>What must be true for Windows Firewall to function</summary>

```
Windows Filtering Platform (WFP)  ← kernel driver, always loaded
        │
        ▼
Base Filtering Engine (BFE)  ← svchost service; manages WFP policies
        │
        ▼
Windows Firewall (mpssvc)  ← svchost service; reads rules, applies via BFE
        │
        ├── Local Policy (GPO, WLAN, wf.msc)
        ├── Intune / MDM Firewall Policy  ← can conflict with local rules
        ├── Group Policy (Computer Config → Windows Firewall with Advanced Security)
        └── Windows Defender Firewall CSP (via Intune)
                │
                ▼
        Active profiles (Domain / Private / Public)
                │ applied based on network interface NLA classification
                ▼
        Per-interface effective rules
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Is the firewall service healthy?**
```powershell
Get-Service mpssvc, BFE | Select-Object Name, Status
```
- Both Running → proceed to Step 2.
- Either stopped → Fix 1 before anything else.

**Step 2 — Which profile is active on the affected interface?**
```powershell
Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory, IPv4Connectivity
```
- Note whether it's `DomainAuthenticated`, `Private`, or `Public` — this determines which firewall profile applies.
- `Public` on a corporate machine = NLA failed to detect the domain. Network issue, not firewall.

**Step 3 — Is the expected allow rule present?**
```powershell
# Check if an allow rule exists for the application
$app = "C:\Program Files\YourApp\app.exe"  # or the affected executable
Get-NetFirewallRule -Enabled True -Direction Inbound |
    Get-NetFirewallApplicationFilter |
    Where-Object Program -like "*YourApp*"
```
- Rule found and Enabled → rule exists; check if profile matches (Step 4).
- No rule → create one (Fix 3).

**Step 4 — Does the rule apply to the active profile?**
```powershell
Get-NetFirewallRule -DisplayName "<RuleName>" | Select-Object DisplayName, Profile, Enabled, Direction, Action
```
- `Profile = Domain` but machine is on `Public` profile → rule won't fire. Fix 3 to adjust profile scope.

**Step 5 — Is GPO/Intune overriding local rules?**
```powershell
# GPO-delivered rules can override or merge with local rules
# Check PolicyStore
Get-NetFirewallRule -PolicyStore "RSOP" | Where-Object DisplayName -like "*<keyword>*" | Select-Object DisplayName, Profile, Action, Enabled
```
- If a GPO rule is blocking: change must be made at policy level (Fix 4), not locally.

---

## Common Fix Paths

<details><summary>Fix 1 — Restart Windows Firewall and BFE services</summary>

**Use when:** `mpssvc` or `BFE` stopped.

```powershell
# Start BFE first — mpssvc depends on it
Set-Service -Name BFE -StartupType Automatic
Start-Service -Name BFE
Start-Sleep -Seconds 3

# Start Windows Firewall
Set-Service -Name mpssvc -StartupType Automatic
Start-Service -Name mpssvc

# Verify
Get-Service mpssvc, BFE | Select-Object Name, Status, StartType

# If mpssvc fails to start: reset the service config
sc.exe config mpssvc start= demand
sc.exe start mpssvc
```

**Rollback:** Not required — starting a stopped service is safe.

**If service won't start after above:**
```powershell
# Reset WFP filters (clears corrupt filter state)
# WARNING: This briefly removes ALL firewall filtering — do on a test machine first
netsh wfp show filters
netsh advfirewall reset
# Then retry service start
```

</details>

<details><summary>Fix 2 — Re-enable a disabled firewall profile</summary>

**Use when:** `Get-NetFirewallProfile` shows `Enabled = False`.

```powershell
# Enable all profiles
Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True

# Or enable a specific profile
Set-NetFirewallProfile -Profile Domain -Enabled True

# Verify
Get-NetFirewallProfile | Select-Object Name, Enabled
```

**Rollback:**
```powershell
Set-NetFirewallProfile -Profile Domain -Enabled False
```

**Note:** If re-enabling causes application breakage, the app likely relied on the firewall being off. Use Fix 3 to add a proper allow rule, then re-enable.

**If GPO is forcing the profile off:** Policy wins over local setting. Must be changed in Group Policy or Intune firewall policy.

</details>

<details><summary>Fix 3 — Create or correct a missing allow rule</summary>

**Use when:** Traffic is being dropped, no allow rule exists for the app or port.

```powershell
# Allow by port (e.g. custom app on TCP 8080, inbound)
New-NetFirewallRule `
    -DisplayName "Allow Custom App TCP 8080 Inbound" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 8080 `
    -Action Allow `
    -Profile Domain, Private `
    -Enabled True

# Allow by executable (more secure — only allows this specific binary)
New-NetFirewallRule `
    -DisplayName "Allow MyApp.exe Inbound" `
    -Direction Inbound `
    -Program "C:\Program Files\MyApp\MyApp.exe" `
    -Action Allow `
    -Profile Any `
    -Enabled True

# Fix an existing rule that has wrong profile
Set-NetFirewallRule -DisplayName "Allow MyApp.exe Inbound" -Profile Domain, Private, Public
```

**Rollback:**
```powershell
Remove-NetFirewallRule -DisplayName "Allow Custom App TCP 8080 Inbound"
```

</details>

<details><summary>Fix 4 — Remove or override a blocking GPO/Intune firewall rule</summary>

**Use when:** A block rule is being pushed by Group Policy or Intune and you need to investigate/remove it.

```powershell
# Identify GPO rules (read-only — don't modify PolicyStore RSOP directly)
Get-NetFirewallRule -PolicyStore "RSOP" |
    Where-Object Action -eq Block |
    Select-Object DisplayName, Profile, Direction, PolicyStoreSourceType

# For GPO-sourced block rules:
# 1. Open GPMC on the domain controller
# 2. Locate the GPO shown in PolicyStoreSourceType
# 3. Navigate to: Computer Configuration → Policies → Windows Settings →
#    Security Settings → Windows Defender Firewall with Advanced Security
# 4. Identify and remove/modify the block rule

# For Intune-sourced rules (Endpoint Security → Firewall):
# 1. Find the policy in Intune Admin Center → Endpoint Security → Firewall
# 2. Edit the policy or exclude the device from the assignment

# Temporary local workaround (only works if GPO doesn't enforce "apply local rules" block):
New-NetFirewallRule `
    -DisplayName "TEMP Override Block Rule" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 443 `
    -Action Allow `
    -Profile Any `
    -Enabled True `
    -Priority 0    # Lower number = higher priority in local store only

# Note: GPO/Intune rules in the Group Policy store ALWAYS take precedence over local rules.
# The workaround above only helps if the GPO sets a BLOCK with "apply local rules = yes"
```

**Rollback:** Remove the temp override rule after the policy is corrected.

</details>

<details><summary>Fix 5 — Reset all Windows Firewall rules to default</summary>

**Use when:** Firewall rule set is corrupt or massively misconfigured; starting fresh is faster than debugging.

```powershell
# DESTRUCTIVE — removes ALL custom firewall rules
# Confirm with user before running

# Option A: Using netsh (quickest)
netsh advfirewall reset

# Option B: Using PowerShell (same result)
(New-Object -ComObject HNetCfg.FwPolicy2).RestoreLocalFirewallDefaults()

# Verify reset
Get-NetFirewallRule | Measure-Object  # Will show only built-in rules (~300)
```

**Rollback:** No automated rollback. Export rules before resetting:
```powershell
# Export BEFORE resetting
netsh advfirewall export "C:\Temp\firewall-backup-$(Get-Date -Format yyyyMMdd).wfw"

# Restore from backup
netsh advfirewall import "C:\Temp\firewall-backup-20260101.wfw"
```

</details>

---

## Escalation Evidence

```
=== Windows Firewall Escalation Pack ===
Date/Time:          ___________________
Technician:         ___________________
Affected Device:    ___________________
Affected App/Port:  ___________________

--- Firewall Service State ---
mpssvc status:      ___________________
BFE status:         ___________________

--- Active Profile ---
Interface:          ___________________
Network Category:   ___________________
Active Profile:     ___________________

--- Rule Findings ---
Block rule found:   [ ] Yes  [ ] No
Rule name:          ___________________
PolicyStore source: ___________________  (local / GPO / Intune)

--- Connectivity Test ---
Test-NetConnection <host> -Port <port>: TcpTestSucceeded = ___

--- Event Log Entries ---
EventID 5152/5157 seen: [ ] Yes  [ ] No
Sample event timestamp: ___________________
Dropped process/direction: ___________________

--- Actions Taken ---
1. ___________________
2. ___________________
3. ___________________

--- Outcome ---
[ ] Resolved — Root cause: ___________________
[ ] Escalating — Blocker: ___________________
```

---

## 🎓 Learning Pointers

- **BFE is the foundation:** Windows Filtering Platform (WFP) and Base Filtering Engine (BFE) underpin not just Windows Firewall but also IPsec, network QoS, and some EDR tools. If BFE is stopped, resetting mpssvc alone won't help — always fix BFE first. [WFP architecture](https://learn.microsoft.com/en-us/windows/win32/fwp/windows-filtering-platform-start-page)

- **GPO beats local — always:** If a firewall rule is being pushed by Group Policy, a local override via `New-NetFirewallRule` will have no effect on that traffic. You MUST go to the source policy. `PolicyStoreSourceType` in `Get-NetFirewallRule` output tells you where a rule originated.

- **Network profile matters enormously:** A rule set to apply to `Domain` profile silently does nothing when a machine is classified as `Public` (which happens when NLA can't reach a DC). Fix the NLA classification first, not the firewall rule. `Get-NetConnectionProfile` is your first check.

- **Audit logging is off by default:** Windows Firewall drop auditing (EventID 5152/5157) requires enabling: `auditpol /set /subcategory:"Filtering Platform Packet Drop" /success:enable /failure:enable`. Without this, you're flying blind. Enable it at the start of a troubleshooting session.

- **Intune vs GPO conflicts:** Intune Endpoint Security firewall policies and Group Policy firewall policies can both be in effect simultaneously. The most restrictive rule wins. Use `Get-NetFirewallRule -PolicyStore "RSOP"` to see the merged result as the OS sees it. [Intune firewall policy](https://learn.microsoft.com/en-us/mem/intune/protect/endpoint-security-firewall-policy)
