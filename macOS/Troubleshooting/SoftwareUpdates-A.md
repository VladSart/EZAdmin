# macOS Managed Software Updates — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

Covers macOS **Managed Software Updates (MSU)** as delivered through **Microsoft Intune** using the declarative device management (DDM) Software Update configuration. Applies to:

- macOS 13 (Ventura) and later — full DDM update enforcement
- macOS 12 (Monterey) — MDM `softwareupdate` commands only (no DDM)
- Supervised devices enrolled via ADE (Automated Device Enrollment)

**Out of scope:** App Store updates, third-party app patching (Munki, Patch My Mac), and manually triggered system updates.

**Assumptions:**
- Devices are enrolled in Intune and MDM-supervised
- Apple Software Lookup Service (ASLS) is reachable
- macOS DDM is used for enforcement (Intune portal → Devices → macOS → Update policies)

---

## How It Works

<details><summary>Full architecture — macOS update enforcement pipeline</summary>

### Pre-DDM (macOS ≤ 12): MDM Command Approach

```
Intune Service
    │
    ▼
APNs Push Notification
    │
    ▼
MDM Agent (mdmclient) on device
    │
    ├── ScheduleOSUpdate command → softwareupdate daemon
    ├── AvailableOSUpdates query → reports available updates
    └── InstallApplication / InstallUpdate
                │
                ▼
        softwareupdate (CLI)
                │
                ▼
        Apple Software Update CDN
                │
                ▼
        /Library/Updates (staged)
                │
                ▼
        Reboot → macOS Installer
```

### DDM (macOS ≥ 13): Declarative Approach

```
Intune Service (Graph API)
    │
    ▼
DDM Configuration (com.apple.configuration.softwareupdate.enforcement.specific)
    │
    ▼
APNs → mdmclient → Declarative Management daemon (ddmd)
    │
    ▼
Software Update daemon (softwareupdated)
    │
    ├── Contacts Apple Software Lookup Service (ASLS)
    │       URL: https://gdmf.apple.com/v2/pmv (Product Metadata Validation)
    ├── Downloads update from Apple CDN
    ├── Stages to /Library/Updates
    └── Enforces install deadline (LocalDateTime from DDM config)
                │
                ▼
        User notification (macOS Notifications)
                │
                ▼
        Forced reboot at deadline if user defers
                │
                ▼
        macOS Installer → version upgrade/update
```

### Key Components

| Component | Role | Logs |
|-----------|------|------|
| `mdmclient` | MDM command processing, DDM sync | `/var/log/mdmclient.log` |
| `ddmd` | Declarative device management daemon | `log show --predicate 'subsystem == "com.apple.managedclient.ddm"'` |
| `softwareupdated` | Software update orchestration | `/var/log/install.log`, unified log |
| `nsurlsessiond` | Network download sessions | unified log |
| APNs | Push delivery for MDM commands | N/A (Apple infrastructure) |
| ASLS | Update metadata validation | `https://gdmf.apple.com/v2/pmv` |

### DDM Configuration Payload (what Intune sends)

```json
{
  "Type": "com.apple.configuration.softwareupdate.enforcement.specific",
  "Identifier": "com.microsoft.intune.softwareupdate",
  "Payload": {
    "TargetOSVersion": "14.5",
    "TargetBuildVersion": "23F79",
    "TargetLocalDateTime": "2024-11-15T23:00:00",
    "DetailsURL": "https://support.apple.com/en-us/111900"
  }
}
```

### Deferral Mechanics (Supervised devices)

- Intune can enforce deferral of **major** (0–90 days) and **minor** (0–30 days) updates
- Deferral prevents the update from **appearing** in System Settings — not just from installing
- Managed deferral profile key: `enforcedSoftwareUpdateMajorOSDeferredInstallDelay`
- At deadline: system forces reboot even if user is active (DDM enforcement)

</details>

---

## Dependency Stack

```
Apple Software Update CDN (content delivery)
        │
Apple ASLS — gdmf.apple.com (metadata / product validation)
        │
APNs — push delivery (17.0.0.0/8, port 443/5223)
        │
Intune MDM Service (graph.microsoft.com)
        │
mdmclient / ddmd on-device
        │
softwareupdated
        │
macOS update package (staged in /Library/Updates)
        │
macOS Installer (reboot)
        │
Updated macOS version
```

**Every layer must function.** A firewall blocking ASLS means the device cannot validate update metadata, and the update will not proceed even if staged.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Update policy shows "Pending" in Intune for >24h | APNs not delivering DDM sync | `mdmclient QueryDeviceInformation` — check APNs connectivity |
| Device not seeing update in System Settings | Deferral policy blocking it | Check enforced deferral MDM profile |
| Update downloads but never installs | macOS Installer validation failure, or MDM deadline not yet hit | `/var/log/install.log` for PKG errors |
| "Software Update is not available" | ASLS unreachable or device not supervised | `curl -I https://gdmf.apple.com/v2/pmv` |
| Deadline passes, device not updated | Deferral overlap, or DDM config not received | Check DDM declarations on device |
| Device shows older build than target | Partial update applied or incremental update only downloaded | `sw_vers` + `system_profiler SPSoftwareDataType` |
| Repeated failed installs in logs | Insufficient disk space or corrupt staged update | Check disk space + purge `/Library/Updates` |
| Policy reports "Not applicable" | Device OS below minimum, or non-supervised | Check supervision status + OS version |
| Update installs but immediately downgraded | Conflicting MDM policy pinning OS version | Check for competing update profiles |

---

## Validation Steps

**1. Confirm supervision and MDM enrollment**
```bash
profiles status -type enrollment
# Expected: MDM enrollment: Yes (supervised)
sudo profiles -P | grep -i supervision
```
Bad: `MDM enrollment: Yes (not supervised)` → update enforcement limited

**2. Confirm DDM declarations received**
```bash
sudo mdmclient QueryDeclarations 2>&1 | head -60
# Expected: SoftwareUpdate configuration present
```
Bad: Empty output or missing softwareupdate declaration → MDM push not delivered

**3. Check current OS and build**
```bash
sw_vers
system_profiler SPSoftwareDataType | grep -E "System Version|Kernel Version"
```

**4. Verify ASLS connectivity**
```bash
curl -s -o /dev/null -w "%{http_code}" https://gdmf.apple.com/v2/pmv
# Expected: 200
```
Bad: `000` (no connectivity) or `403` (IP-based block) → proxy/firewall issue

**5. Check APNs reachability**
```bash
# Test APNs feedback server
nc -zv 17.57.145.132 443
# Or use Apple's connectivity test
curl -s https://api.push.apple.com
```

**6. Review software update daemon status**
```bash
log show --predicate 'subsystem == "com.apple.MobileSoftwareUpdate"' --last 2h --info 2>/dev/null | tail -50
```

**7. Inspect staged updates**
```bash
ls -lh /Library/Updates/ 2>/dev/null
softwareupdate --list
```

**8. Check available disk space**
```bash
df -h /
# Major updates require 12-20 GB free; minor updates 5-8 GB
```

**9. MDM command status**
```bash
sudo mdmclient QueryDeviceInformation 2>&1 | grep -i update
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Policy not reaching the device

1. Confirm APNs push is working — check for connectivity to `17.0.0.0/8:443` and `17.0.0.0/8:5223`
2. Trigger a manual MDM sync: **System Settings → Privacy & Security → Profiles → (select MDM profile) → Refresh**
3. Or via terminal: `sudo mdmclient Poll`
4. Check `mdmclient.log` for push errors:
   ```bash
   tail -100 /var/log/mdmclient.log | grep -iE "error|failed|push"
   ```
5. If push fails consistently, verify device's APNS token registration in Intune (device → Hardware → APNS Token)

### Phase 2: Device receives policy but update not downloading

1. Check ASLS reachability: `curl https://gdmf.apple.com/v2/pmv`
2. If blocked: add ASLS to proxy/firewall allowlist — Apple requires this for all supervised devices
3. Check if deferral policies are conflicting:
   ```bash
   sudo profiles -P | grep -A5 -i "defer"
   sudo defaults read /Library/Managed\ Preferences/com.apple.applicationaccess.new
   ```
4. Check `softwareupdate` for manual listing:
   ```bash
   sudo softwareupdate --list --verbose
   ```
5. Review unified log for download errors:
   ```bash
   log show --predicate 'subsystem == "com.apple.MobileSoftwareUpdate" AND category == "SUDownloadController"' --last 4h 2>/dev/null | grep -iE "error|fail|retry"
   ```

### Phase 3: Update downloaded but not installing

1. Inspect install log:
   ```bash
   tail -200 /var/log/install.log | grep -iE "error|fail|abort"
   ```
2. Check if deadline has been reached (DDM enforcement):
   ```bash
   sudo mdmclient QueryDeclarations 2>&1 | grep -A10 "softwareupdate"
   # Look for TargetLocalDateTime
   ```
3. Verify free disk space (minimum 15 GB recommended for major upgrades)
4. Clear corrupt staged update:
   ```bash
   sudo rm -rf /Library/Updates/*
   sudo softwareupdate --clear-catalog
   # Then re-trigger download via MDM sync
   ```
5. Check for blocking processes (Gatekeeper, SIP issues):
   ```bash
   csrutil status
   spctl --status
   ```

### Phase 4: Install attempted but failed mid-way

1. Review `/var/log/install.log` — look for "FAILED" or "PKG FAILED" lines
2. Check for macOS Installer crash: `log show --predicate 'process == "macOSBigSurInstaller" OR process == "macOSInstaller"' --last 24h 2>/dev/null | tail -100`
3. Run First Aid on the boot volume:
   ```bash
   diskutil verifyVolume /
   ```
4. If disk errors found, escalate — update cannot complete on a compromised volume
5. Consider MDM command to force re-download: trigger from Intune portal → Device → Sync

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Force DDM declaration sync</summary>

**Scenario:** Policy shows "Pending" in Intune, device not receiving DDM update configuration.

```bash
# Step 1: Force MDM poll
sudo mdmclient Poll

# Step 2: Verify DDM declarations
sudo mdmclient QueryDeclarations 2>&1 | grep -i softwareupdate

# Step 3: Force DDM sync specifically
sudo mdmclient ddm sync 2>/dev/null || echo "DDM sync command not available on this OS version"

# Step 4: Review declaration content
sudo mdmclient QueryDeclarations 2>&1
```

**Rollback:** N/A — read-only diagnostic. No changes made.

Expected after fix: DDM declaration with `com.apple.configuration.softwareupdate.enforcement.specific` appears in output.

</details>

<details>
<summary>Playbook 2 — Clear staged update and re-trigger download</summary>

**Scenario:** Update stuck in /Library/Updates, install not proceeding.

```bash
# Step 1: Stop softwareupdated
sudo pkill -x softwareupdated

# Step 2: Clear staged updates
sudo rm -rf /Library/Updates/*

# Step 3: Clear update catalog cache
sudo defaults delete /Library/Preferences/com.apple.SoftwareUpdate.plist 2>/dev/null
sudo defaults delete /Library/Preferences/com.apple.commerce.plist 2>/dev/null

# Step 4: Restart softwareupdated
sudo launchctl kickstart -k system/com.apple.softwareupdated

# Step 5: Force check
sudo softwareupdate --list --verbose

# Step 6: Trigger MDM sync to re-push DDM config
sudo mdmclient Poll
```

**Rollback:** Nothing destructive — only cached files removed. Re-download will happen automatically.

</details>

<details>
<summary>Playbook 3 — Remove conflicting deferral policy</summary>

**Scenario:** Deferral profile is blocking the targeted update from appearing.

```bash
# Step 1: Identify conflicting profiles
sudo profiles -P | grep -iB2 -A10 "SoftwareUpdate\|enforce\|defer"

# Step 2: Note the profile identifier
sudo profiles -P | grep -A2 "profileIdentifier"

# Step 3: If a non-Intune profile is present, remove it
# (Only if you know this profile was not intentionally deployed)
sudo profiles -R -p <ProfileIdentifier>

# Step 4: Verify removal
sudo profiles -P | grep -i defer

# Step 5: Force MDM sync
sudo mdmclient Poll
```

**Rollback:** Reinstall the profile via Intune if needed.

</details>

<details>
<summary>Playbook 4 — Disk space remediation for large updates</summary>

**Scenario:** Major macOS upgrade failing due to insufficient disk space.

```bash
# Step 1: Check current space
df -h / | tail -1

# Step 2: Find large user cache items (run as the user, not root)
du -sh ~/Library/Caches/* 2>/dev/null | sort -rh | head -20

# Step 3: Clear Xcode derived data (if present)
rm -rf ~/Library/Developer/Xcode/DerivedData/* 2>/dev/null

# Step 4: Empty Trash
osascript -e 'tell app "Finder" to empty trash' 2>/dev/null

# Step 5: Clear system caches (root)
sudo rm -rf /Library/Caches/com.apple.appstore/* 2>/dev/null
sudo rm -rf /var/folders/*/* 2>/dev/null

# Step 6: Re-check space
df -h /

# Target: ≥ 20 GB free for major upgrade, ≥ 8 GB for minor update
```

**Rollback:** N/A — cache files only. System will regenerate them.

</details>

---

## Evidence Pack

```powershell
# Run this on-device via macOS shell (remote session, Intune Shell Script, or SSH)
# Collects full evidence pack for update troubleshooting escalation

$OutputPath = "/tmp/msupdate-evidence-$(date +%Y%m%d-%H%M%S)"
mkdir -p $OutputPath

# System info
sw_vers > $OutputPath/sw_vers.txt
system_profiler SPSoftwareDataType > $OutputPath/sp_software.txt
df -h > $OutputPath/disk_space.txt

# MDM status
sudo mdmclient QueryDeviceInformation > $OutputPath/mdm_device_info.txt 2>&1
sudo mdmclient QueryDeclarations > $OutputPath/ddm_declarations.txt 2>&1
sudo profiles -P > $OutputPath/profiles.txt 2>&1
profiles status -type enrollment > $OutputPath/enrollment_status.txt 2>&1

# Update state
sudo softwareupdate --list --verbose > $OutputPath/su_list.txt 2>&1
ls -lh /Library/Updates/ > $OutputPath/library_updates.txt 2>&1

# Network checks
curl -s -o /dev/null -w "ASLS HTTP: %{http_code}\n" https://gdmf.apple.com/v2/pmv > $OutputPath/network.txt 2>&1

# Logs
tail -200 /var/log/install.log > $OutputPath/install_log_tail.txt 2>&1
log show --predicate 'subsystem == "com.apple.MobileSoftwareUpdate"' --last 4h --info > $OutputPath/msu_unified_log.txt 2>&1
tail -100 /var/log/mdmclient.log > $OutputPath/mdmclient_log_tail.txt 2>&1

tar czf /tmp/msupdate-evidence.tar.gz -C /tmp $(basename $OutputPath)
echo "Evidence pack: /tmp/msupdate-evidence.tar.gz"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check OS version | `sw_vers` |
| Check supervision | `profiles status -type enrollment` |
| List all profiles | `sudo profiles -P` |
| List available updates | `sudo softwareupdate --list --verbose` |
| Force MDM sync | `sudo mdmclient Poll` |
| Query DDM declarations | `sudo mdmclient QueryDeclarations` |
| Check ASLS reachability | `curl -I https://gdmf.apple.com/v2/pmv` |
| View install log | `tail -200 /var/log/install.log` |
| View MDM client log | `tail -100 /var/log/mdmclient.log` |
| View MobileSoftwareUpdate log | `log show --predicate 'subsystem == "com.apple.MobileSoftwareUpdate"' --last 2h --info` |
| Check disk space | `df -h /` |
| Clear staged updates | `sudo rm -rf /Library/Updates/*` |
| Restart update daemon | `sudo launchctl kickstart -k system/com.apple.softwareupdated` |
| Check SIP status | `csrutil status` |

---

## 🎓 Learning Pointers

- **DDM vs MDM commands:** On macOS 13+, Intune uses Declarative Device Management (DDM) for update enforcement — the `com.apple.configuration.softwareupdate.enforcement.specific` declaration replaces the older `ScheduleOSUpdate` MDM command. DDM is more reliable because the device self-evaluates the declaration rather than waiting for push commands. See: [Apple DDM Documentation](https://developer.apple.com/documentation/devicemanagement/using-declarative-management-with-software-updates)

- **ASLS is non-negotiable:** `gdmf.apple.com` is Apple's Product Metadata Validation service. If your web proxy or firewall blocks it, the device cannot validate that the requested update build is legitimate, and the update will silently fail. This catches many MSPs off-guard. Add it to every allowlist. Reference: [Apple MDM Protocol](https://developer.apple.com/documentation/devicemanagement)

- **Deferral ≠ suppression:** macOS deferral policies hide updates from the UI — users cannot manually install a deferred update even if they want to. This is intentional for testing windows, but can confuse users who see "No updates available" when IT has deferred an update. Document this behaviour in your user comms.

- **Deadlines are hard:** DDM `TargetLocalDateTime` is enforced at the OS level — if the deadline passes while the user is active, the device **will** reboot. Always schedule deadlines outside business hours and test in a pilot group first. Use Intune's grace period settings to give users a notification window.

- **Disk space is the silent killer:** Major macOS upgrades (e.g., Sonoma → Sequoia) require 15-20 GB free. Many managed devices have tight storage (256 GB SSDs with large user profiles). Build a pre-update disk space compliance check before deploying a major version policy. See: [Intune macOS Software Update Policy](https://learn.microsoft.com/en-us/mem/intune/protect/software-updates-macos)

- **Intune reporting lag:** Intune's "Update status" report can lag 6-12 hours behind actual device state. Don't rely on it for real-time confirmation — SSH or Intune Shell Scripts to pull `sw_vers` output for immediate verification.
