# Windows Network Adapters — Hotfix Runbook (Mode B: Ops)
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

Run these first. Each takes under 30 seconds.

```powershell
# 1. Adapter status overview
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress |
    Format-Table -AutoSize

# 2. IP configuration (incl. missing/APIPA)
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixOrigin |
    Format-Table -AutoSize

# 3. DNS servers assigned
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } |
    Format-Table -AutoSize

# 4. Default gateway
Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Select-Object InterfaceAlias, NextHop, RouteMetric |
    Format-Table -AutoSize

# 5. Driver & last error
Get-NetAdapter | ForEach-Object {
    $driver = Get-NetAdapterAdvancedProperty -Name $_.Name -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Adapter = $_.Name
        Status  = $_.Status
        Driver  = $_.DriverVersion
        DriverDate = $_.DriverDate
    }
} | Format-Table -AutoSize
```

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| Status = `Up`, IP = `169.254.x.x` (APIPA) | Adapter up but no DHCP lease | → Fix 1 (DHCP) |
| Status = `Disabled` | Adapter manually/policy disabled | → Fix 2 |
| Status = `Not Present` | Driver missing or hardware fault | → Fix 3 |
| Status = `Up`, IP correct, no internet | Routing/DNS/firewall issue | → Fix 4 |
| `LinkSpeed = 0 bps` with Status `Up` | Driver crash or NIC failure | → Fix 5 |
| Multiple adapters all failed after update | Driver rollback needed | → Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Physical/Virtual NIC
│
├── Driver (correct, signed, installed)
│   └─ Managed via: Device Manager / PnP / Windows Update / Intune driver policy
│
├── Adapter enabled in Windows
│   └─ ncpa.cpl, netsh, or Group Policy (BlockNonDomain adapters etc.)
│
├── IP Configuration
│   ├─ DHCP: DHCP server reachable on broadcast domain
│   └─ Static: correct address/mask/gateway manually assigned
│
├── DNS
│   └─ DNS servers reachable + responding + NRPT rules not blocking
│
├── Routing
│   └─ Default gateway set + reachable via ARP
│
├── Windows Firewall
│   └─ Outbound rules not blocking required ports
│
└── VPN / overlay adapter
    └─ WireGuard/Always On VPN/Cisco AnyConnect may create competing routes
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm physical/virtual layer**

```powershell
Get-NetAdapter -IncludeHidden | Select-Object Name, InterfaceDescription, Status, HardwareInterface |
    Format-Table -AutoSize
```

Expected: target adapter shows `HardwareInterface = True` (physical) or known virtual adapter name. Hidden adapters appearing as `Not Present` indicate a driver mismatch.

---

**Step 2 — Check for IP address assignment**

```powershell
ipconfig /all
```

Expected: adapter shows a routable IP (10.x, 192.168.x, 172.16-31.x) with correct subnet, gateway, and DNS.

Bad: `Autoconfiguration IPv4 Address: 169.254.x.x` → APIPA = DHCP failure.

---

**Step 3 — Test gateway reachability**

```powershell
$gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1).NextHop
Test-NetConnection -ComputerName $gw -InformationLevel Detailed
```

Expected: `PingSucceeded : True`. If false, the problem is between the NIC and the upstream switch/router — not Windows.

---

**Step 4 — Test DNS resolution**

```powershell
Resolve-DnsName -Name "google.com" -Server "8.8.8.8"   # external test
Resolve-DnsName -Name "dc01.contoso.com"                 # internal test
```

Expected: returns IP addresses. Failure on external but success on internal = split DNS / NRPT rule issue. Failure on both = DNS service problem.

---

**Step 5 — Check for competing routes (VPN conflict)**

```powershell
Get-NetRoute | Sort-Object RouteMetric | Format-Table DestinationPrefix, NextHop, InterfaceAlias, RouteMetric -AutoSize
```

Look for multiple `0.0.0.0/0` entries — a VPN adapter taking a lower metric than the physical NIC will steal all traffic. See Fix 4.

---

**Step 6 — Check recent driver events**

```powershell
Get-WinEvent -LogName "System" -MaxEvents 200 |
    Where-Object { $_.ProviderName -match "NDIS|tcpip|netio" } |
    Select-Object TimeCreated, Id, Message |
    Format-List
```

Events 5719, 4202, 4201: NIC connectivity state changes. Event 10400/10401: NDIS protocol driver issues.

---

## Common Fix Paths

<details><summary>Fix 1 — Renew DHCP lease / reset IP stack</summary>

```powershell
$adapterName = "<adapter-name>"   # from Get-NetAdapter

# Release and renew
ipconfig /release $adapterName
ipconfig /renew $adapterName

# If still APIPA — flush and reset
ipconfig /flushdns
netsh winsock reset
netsh int ip reset C:\Windows\Temp\ip-reset.log

# Confirm new address
Get-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4
```

**Rollback:** Not destructive — `winsock reset` and `ip reset` require a reboot but revert to a clean state.

**When it doesn't work:** DHCP server unreachable (check VLAN, switch port, DHCP relay). Device in wrong VLAN. DHCP pool exhausted.

</details>

<details><summary>Fix 2 — Enable a disabled adapter</summary>

```powershell
$adapterName = "<adapter-name>"

# Check if disabled
Get-NetAdapter -Name $adapterName | Select-Object Status

# Enable
Enable-NetAdapter -Name $adapterName -Confirm:$false

# Verify
Start-Sleep -Seconds 3
Get-NetAdapter -Name $adapterName | Select-Object Name, Status, LinkSpeed
```

**If re-disabled automatically:** A Group Policy or Intune CSP is forcing it disabled. Check GP: `Computer Configuration → Windows Settings → Network → Network Connections`. Check Intune Device Configuration → Templates → Network Boundary or custom OMA-URI.

**Rollback:** `Disable-NetAdapter -Name $adapterName -Confirm:$false`

</details>

<details><summary>Fix 3 — Reinstall / update NIC driver</summary>

```powershell
# Get current driver info
Get-NetAdapter | Select-Object Name, DriverProvider, DriverVersion, DriverDate

# Option A: Update via Windows Update (safe, signed)
# Run from elevated session:
$session = New-CimInstance -Namespace root/Microsoft/Windows/WindowsUpdate `
    -ClassName MSFT_WUOperationsSession
Invoke-CimMethod -InputObject $session -MethodName ScanForUpdates -Arguments @{SearchCriteria="IsInstalled=0 and Type='Driver'"; OnlineScan=$true}

# Option B: Uninstall and let PnP reinstall
$adapter = Get-PnpDevice | Where-Object { $_.FriendlyName -like "*<NIC name>*" }
Disable-PnpDevice -InstanceId $adapter.InstanceId -Confirm:$false
Enable-PnpDevice -InstanceId $adapter.InstanceId -Confirm:$false

# Option C: Force PnP scan for new hardware
pnputil /scan-devices
```

**If driver is corrupt:** Download OEM driver from manufacturer. Use `pnputil /add-driver <inf path> /install` to inject. Avoid unsigned drivers on Secure Boot / WDAC-enrolled devices.

**Rollback:** Device Manager → NIC → Properties → Driver → Roll Back Driver. Or via `pnputil /enum-drivers` to find previous version.

</details>

<details><summary>Fix 4 — Fix routing conflict (VPN eating all traffic)</summary>

```powershell
# Identify competing default routes
Get-NetRoute -DestinationPrefix "0.0.0.0/0" |
    Sort-Object RouteMetric |
    Select-Object InterfaceAlias, NextHop, RouteMetric |
    Format-Table -AutoSize

# Raise metric on VPN route (temporary — survives until VPN reconnect)
$vpnAdapter = "<vpn-adapter-name>"
$ifIndex = (Get-NetAdapter -Name $vpnAdapter).InterfaceIndex
Set-NetIPInterface -InterfaceIndex $ifIndex -InterfaceMetric 9000

# Verify physical NIC is now preferred
Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1
```

**Permanent fix:** Configure VPN client to use split tunnelling. For Always On VPN: set `<DisableClassBasedDefaultRoute>true</DisableClassBasedDefaultRoute>` in the VPN profile XML. For Cisco AnyConnect: modify split include/exclude lists in the ASA/FTD group policy.

**Rollback:** Disconnect/reconnect VPN — metric resets. Or `Set-NetIPInterface -InterfaceIndex $ifIndex -AutomaticMetric Enabled`.

</details>

<details><summary>Fix 5 — Roll back driver after Windows Update break</summary>

```powershell
# Find the adapter's PnP instance
$nic = Get-PnpDevice | Where-Object {
    $_.Class -eq "Net" -and $_.Status -eq "OK" -and $_.FriendlyName -like "*<partial NIC name>*"
}
$nic | Select-Object InstanceId, FriendlyName, Status

# Check driver store for older version
pnputil /enum-drivers | Select-String -Pattern "oem\d+\.inf|Net|<NIC vendor>"

# Roll back via Device Manager (GUI is more reliable for driver rollback):
devmgmt.msc
# → Network Adapters → [NIC] → Properties → Driver → Roll Back Driver

# Verify after rollback
Get-NetAdapter | Select-Object Name, DriverVersion, DriverDate, Status
```

**Block the bad driver from reinstalling:**

```powershell
# Add driver exclusion via Windows Update for Business or Group Policy:
# HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions
# DeviceDenyList with the hardware ID of the bad driver package

$badHwId = "<hardware-id-from-device-manager>"   # e.g. PCI\VEN_8086&DEV_1502
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
Set-ItemProperty -Path $regPath -Name "DenyDeviceIDs" -Value 1
Set-ItemProperty -Path $regPath -Name "DenyDeviceIDsRetroactive" -Value 0
New-ItemProperty -Path "$regPath\DenyDeviceIDs" -Name "1" -Value $badHwId -PropertyType String
```

**Rollback:** Remove the registry key and re-run Windows Update.

</details>

---

## Escalation Evidence

```
ESCALATION: Windows Network Adapter Issue
==========================================
Date/Time       : [TIMESTAMP]
Affected device : [HOSTNAME / SERIAL]
OS version      : [winver output]
Adapter model   : [from Get-NetAdapter]
Driver version  : [from Get-NetAdapter DriverVersion]
Driver date     : [from Get-NetAdapter DriverDate]

Symptom         : [Adapter disabled / APIPA / no gateway / driver missing]
First noticed   : [date/time]
Change before   : [Windows Update / driver push / Intune policy]

Steps taken     :
  1. [...]
  2. [...]

Triage output   :
--- paste Get-NetAdapter output ---
--- paste ipconfig /all output ---
--- paste Get-NetRoute output ---

Event log errors (System, last 2h) :
--- paste relevant NDIS/TCPIP events ---

Still failing   : [Yes/No]
Impact          : [Single device / all devices on site / all devices post-update]
```

---

## 🎓 Learning Pointers

- **APIPA (169.254.x.x) means the adapter is working but DHCP failed** — the device issued DORA (Discover/Offer/Request/Acknowledge) broadcasts and got no response. Causes: DHCP server down, pool exhausted, device in wrong VLAN, or broadcast isolation on the switch port. Don't blame the adapter before checking the DHCP server. [DHCP troubleshooting](https://learn.microsoft.com/en-us/windows-server/networking/technologies/dhcp/dhcp-top)

- **`netsh int ip reset` changes registry keys under `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters`** — it's not destructive but requires a reboot and can feel alarming. It's the right move when `ipconfig /renew` loops without getting a lease and you've ruled out the DHCP server.

- **Windows Update silently delivers driver updates unless blocked** — driver updates are categorised separately from OS updates and can be blocked via Windows Update for Business policy (`ExcludeWUDriversInQualityUpdate`). If a batch of machines lost NIC connectivity after Patch Tuesday, a driver update is the first suspect. Check: Settings → Windows Update → Update history → Driver updates.

- **VPN adapters creating competing default routes is a classic split-tunnelling misconfiguration** — especially with Always On VPN deployed via Intune where the `DisableClassBasedDefaultRoute` XML property is commonly forgotten. The symptom is: connected to VPN, can reach internal resources, can't reach internet. [Always On VPN configuration](https://learn.microsoft.com/en-us/windows-server/remote/remote-access/vpn/always-on-vpn/deploy/vpn-deploy-client-vpn-connections)

- **Hyper-V and WSL create virtual adapters** that can appear as failed or cause routing confusion on workstations. `Get-NetAdapter -IncludeHidden` exposes them all. A common issue: WSL2 taking the default route on a developer machine. `wsl --shutdown` followed by renewing the physical adapter usually resolves it.
