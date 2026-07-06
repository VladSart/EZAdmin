# macOS — Agent Instructions

## What's in this folder

macOS device management via Microsoft Intune — enrollment, configuration profiles, shell scripts, and compliance.

Covers:
- **ADE (Automated Device Enrollment)** — Apple Business Manager + Intune + DEP profile
- **BYOD enrollment** — Company Portal, manual MDM enrollment
- **Configuration profiles** — password policy, FileVault, firewall, restrictions
- **Shell scripts** — deploying and troubleshooting Intune shell scripts on macOS
- **Compliance** — macOS compliance policies, FileVault encryption reporting
- **Company Portal** — app visibility, install failures

---

## Before responding, also check

- `Intune/` — macOS management is a sub-domain of Intune; enrollment architecture is the same
- `EntraID/` — Entra join for macOS (platform SSO) and token issues

---

## Key diagnostic commands

```bash
# On the Mac — MDM enrollment state
sudo profiles status -type enrollment

# List all installed MDM profiles
sudo profiles list -all

# Check Intune agent logs
log show --predicate 'subsystem == "com.microsoft.intune"' --last 1h

# Company Portal logs
~/Library/Logs/Company\ Portal/

# Check MDM push notification token (required for remote actions)
sudo profiles -e /tmp/MDMProfile.plist
```

---

## Common entry points

- "Mac not enrolling via ADE" → check ABM token in Intune + DEP profile assignment
- "New Macs stopped appearing for ADE sync" or "VPP app licenses failing" (existing Macs check in fine) → `Troubleshooting/ABM-Token-Renewal-B.md` (hotfix) / `Troubleshooting/ABM-Token-Renewal-A.md` (deep dive — token architecture, VPP vs. device sync split) — do not confuse with MDM push cert expiry, see comparison table in that file
- "Shell script not running / showing as failed" → check script output in Intune + macOS log
- "FileVault not being reported to Intune" → compliance profile + FileVault escrow settings
- "Company Portal shows no apps" → check app assignment + device group membership
- "Platform SSO not working" → `EntraID/` — Entra ID macOS SSO extension

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — `sudo profiles status` → identify the broken layer → fix → validate
2. **Deep Dive** — macOS MDM architecture, Apple MDM protocol, ADE flow
3. **Learning Pointers** — Apple + Microsoft documentation resources
