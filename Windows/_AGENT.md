# Windows — Agent Instructions

## What's in this folder

Windows OS-level issues — update management, security features, performance, networking, and peripheral management.

Covers:
- **Windows Update / WfUB** — WSUS conflicts, dual-scan, update rings, stuck updates, 24H2 upgrade issues
- **BitLocker** — key escrow to Entra, recovery, policy enforcement, suspension
- **VBS / Credential Guard / HVCI** — enabling, conflicts with legacy apps/hypervisors
- **AppLocker / WDAC** — application control, policy audit mode, blocking legitimate apps
- **Networking** — DNS, proxy, time sync, VPN coexistence
- **USB / Peripherals** — policy-driven control, driver management
- **Performance** — boot times, CPU/memory issues, storage health
- **Event log analysis** — systematic log collection and interpretation

---

## Before responding, also check

- `Intune/` — if the Windows setting is being managed via MDM policy
- `EntraID/` — if the issue is authentication or device join related
- `Security/Defender/` — if Windows security features (ASR, Tamper Protection) are involved

---

## Key first commands

```powershell
# System health baseline — run first on any Windows issue
Get-ComputerInfo | Select WindowsProductName, WindowsVersion, OsArchitecture, TotalPhysicalMemory

# Windows Update status
Get-WindowsUpdateLog
(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().GetTotalHistoryCount()

# Check what MDM policies are applied
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" |
  Where-Object { $_.Level -le 3 } | Select TimeCreated, Id, Message -First 10

# System event errors last 24h
Get-WinEvent -LogName System |
  Where-Object { $_.LevelDisplayName -in "Error","Critical" -and $_.TimeCreated -gt (Get-Date).AddHours(-24) } |
  Select TimeCreated, Id, ProviderName, Message | Format-Table -Wrap
```

---

## Common entry points

- "Windows Update stuck / won't install" → `Troubleshooting/Windows Update/`
- "WSUS conflict after moving to WfUB / Intune" → `Troubleshooting/Windows Update/WSUS to WfUB B.md`
- "BitLocker recovery key not in Entra" → check Intune BitLocker policy + device escrow
- "App blocked after WDAC/AppLocker deployed" → audit logs, policy mode check
- "Time sync failing" → `Troubleshooting/Time/`
- "USB device being blocked by policy" → Intune Device Control policy + Windows event log
- "VBS breaking a VM or application" → `Scripts/Enable-VBS.ps1` context + registry check

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — isolate to OS layer vs policy layer → apply fix → validate
2. **Deep Dive** — Windows architecture context, MDM vs GPO interaction, registry paths
3. **Learning Pointers** — what to explore to understand the system better
