# Defender for Endpoint on Linux — Offline Security Intelligence Updates — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the mirror-server architecture and engine signature verification model, not just what to click.

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

**In scope:**
- The mirror-server architecture for delivering security intelligence (definition) updates to Linux devices with limited or no direct internet connectivity
- Configuration via Intune endpoint security Antivirus policy, the Microsoft Defender portal's own endpoint security policies, and direct managed-JSON configuration
- The engine digital-signature verification behavior introduced with engine build `101.26062.0005` (August 2026) and the resulting deprecation of `offlineDefinitionUpdateVerifySig`
- Deployment planning: mirror server sizing, supported hosting OSes, bandwidth/update-cadence tuning

**Out of scope:**
- Defender for Endpoint on Linux onboarding/enrollment itself (assumed already deployed and reporting)
- Defender for Endpoint on WSL (a distinct topic — see `MDE-WSL-A.md`/`MDE-WSL-B.md` in this same folder)
- General Linux antivirus engine tuning (exclusions, real-time protection performance) unrelated to the update mechanism specifically

**Assumptions:**
- Defender for Endpoint version `101.24022.0001` (March 2024) or later already installed on target Linux endpoints — this is the minimum version supporting offline updates at all
- Reader has rights to create/modify endpoint security policies in either Intune or the Microsoft Defender portal, and/or shell access to configure `mdatp_managed.json` directly for non-MDM-managed hosts
- **Source-confidence note:** built directly from the primary Microsoft Learn conceptual page (`linux-support-offline-security-intelligence-update`, `ms.date` 2026-09-08, `updated_at` 2026-09-11) — a genuinely current, actively-maintained source rather than a Message Center-only or community-sourced topic.

---
## How It Works

<details><summary>Full architecture</summary>

### Why a mirror server model exists

Most Defender for Endpoint deployments pull security intelligence updates directly from Microsoft's cloud on a rolling basis. Linux servers in isolated network segments, air-gapped environments, or bandwidth-constrained sites often cannot (or should not, for change-control reasons) reach Microsoft's update endpoints directly from every device. The offline update model solves this with a **mirror server**: a single host that downloads updates from Microsoft once, and then serves them to the rest of the Linux fleet over an internal path.

```
                     Microsoft update infrastructure
                     (github.com/microsoft/mdatp-xplat,
                      go.microsoft.com fwlink)
                              │
                              │  downloader script (cron/scheduled task)
                              ▼
                    ┌───────────────────────┐
                    │     Mirror server       │  ← Linux, Windows, OR macOS
                    │ (NO Defender for        │     No MDE agent required here —
                    │  Endpoint install        │     it's a plain file host
                    │  required)               │
                    └───────────┬───────────┘
                                │  HTTP / HTTPS / NFS / local-or-remote mount
                    ┌───────────┼───────────┬─────────────┐
                    ▼           ▼           ▼             ▼
              Linux endpoint  Linux endpoint  ...    Linux endpoint
              (mdatp pulls   (mdatp pulls           (mdatp pulls
               on configured  on configured           on configured
               interval)      interval)               interval)
```

The mirror server is intentionally decoupled from Defender for Endpoint itself — it only needs outbound reachability to two specific Microsoft URLs and enough disk/CPU to run a downloader script on a schedule. This makes it easy to host on infrastructure that already exists for other internal mirroring purposes (e.g., an existing internal package/yum/apt mirror host).

### The downloader script and file layout

Microsoft publishes the downloader as both a Bash and a PowerShell script in the public `microsoft/mdatp-xplat` GitHub repository (`linux/definition_downloader/`). Whichever shell is used, the script reads a shared `settings.json` controlling the download folder, whether to also fetch macOS updates from the same mirror, whether to fetch preview-ring updates, and whether to retain the previous update in a `_back` folder for rollback purposes.

When run, it downloads `updates.zip` and `manifest.json` into a folder structure organized by OS, release ring, and CPU architecture — for example `linux/production/arch_x86_64`. The path handed to endpoints (`offlineDefinitionUpdateUrl`) must point at the release-ring folder (e.g. `.../linux/production/`) and must **not** include the `arch_*` subfolder itself — `mdatp` appends the architecture-specific path automatically. This is the single most common misconfiguration: an admin who copies the full download path including `arch_x86_64` into the endpoint config breaks resolution for every architecture.

### Configuration surfaces

Three equivalent ways to configure an endpoint, in order of typical enterprise preference:

1. **Intune endpoint security Antivirus policy** (Linux platform, Microsoft Defender Antivirus profile template) — the Microsoft-recommended path when Intune is licensed and deployed. Configures `Cloud delivered protection preferences` (update interval) and `Antivirus engine` (offline update enable/URL/fallback) settings, which Intune translates into the managed JSON on the device.
2. **Microsoft Defender portal endpoint security policies** — functionally identical settings surface, for organizations managing Defender security settings directly in the Defender portal rather than through Intune (subject to the same assignment-group limitations as Intune-managed policies for devices under Defender security settings management).
3. **Direct managed JSON** (`/etc/opt/microsoft/mdatp/managed/mdatp_managed.json`) — for hosts not under MDM management, or managed via a third-party configuration tool (Chef, Ansible, Puppet). This is the file both Intune and the Defender portal ultimately populate under the hood; editing it directly is fully supported for non-MDM hosts.

### Engine signature verification (new, August 2026)

Starting with Defender for Endpoint on Linux engine release `101.26062.0005` (August 2026), the agent verifies the antivirus engine's digital signature **before loading it** — a default-on, non-optional behavior intended to prevent a tampered or unofficial engine file (whether from a compromised mirror server or a manual file substitution) from ever being loaded into the running antivirus process.

This directly supersedes the older `offlineDefinitionUpdateVerifySig` managed-configuration setting, which is now deprecated and has no effect — engine signature verification runs unconditionally regardless of what that setting is configured to. Both `mdatp health --details definitions` and `mdatp health --details features` surface the deprecated setting's now-inert value (`"DEPRECATED"`) alongside the real, always-on `engine_signature_verification` state, which is a useful tell for identifying stale internal documentation that still references the old setting as meaningful.

If an engine file fails signature verification, Defender for Endpoint simply does not load it — there's no separate alerting behavior documented for this specific failure mode, meaning a corrupted or tampered mirror-hosted engine file could silently leave a device running an older engine version rather than throwing an obvious error. This makes periodic engine-version drift checking across a fleet (see the Evidence Pack script) worth building into routine hygiene rather than relying solely on per-device alerting.

</details>

---
## Dependency Stack

```
Microsoft update infrastructure (github.com/microsoft/mdatp-xplat,
go.microsoft.com/fwlink/?linkid=2144709) — mirror server needs outbound
reachability to these two URLs only
        ▲
Mirror server: HTTP/HTTPS/NFS host, Linux/Windows/macOS, no MDE agent
required; downloader script + cron/scheduled task producing
updates.zip + manifest.json under <downloadFolder>/<os>/<ring>/arch_*
        ▲
Endpoint reachability to the mirror server (network path, mount,
or share — NOT internet reachability, by design)
        ▲
Endpoint managed configuration: offlineDefinitionUpdateUrl (release-ring
folder, no arch_* suffix), offlineDefinitionUpdate = "enabled",
automaticDefinitionUpdateEnabled = true
        ▲
Antivirus engine enforcement level = real_time (offline updates only
trigger automatically under this enforcement mode)
        ▲
Engine digital signature verification (default-on since 101.26062.0005,
Aug 2026) — final gate before an update is actually loaded
        ▲
definitions_status = up_to_date
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| `definitions_status` stuck on an old date, no fail reason given | Cron job on the mirror server has stopped running — endpoint config is fine, upstream source is stale | Check mirror server's scheduled task/cron last-run timestamp, not the endpoint |
| `definitions_update_fail_reason` mentions connectivity | Network path to mirror server blocked (firewall, mount unmounted, DNS) | `mdatp connectivity test`; independent `curl`/`mount` check from the endpoint |
| Endpoint pulling updates from a Microsoft cloud URL despite a mirror being configured | Mirror attempt failed and `offlineDefinitionUpdateFallbackToCloud = true` silently covered it | Compare `definitions_update_source_uri` against `offline_definition_url_configured` |
| Update path configured but every endpoint of one CPU architecture fails while others succeed | `offlineDefinitionUpdateUrl` incorrectly includes the `arch_*` subfolder, breaking architecture-specific path resolution for everything except a coincidentally-matching arch | Inspect the exact configured URL string against the mirror's actual folder layout |
| Engine version not advancing despite `definitions_status = up_to_date` | Engine signature verification silently rejecting a tampered/corrupted engine file while still successfully updating unrelated definition data | `mdatp health --details features`; re-run the mirror's downloader script against a clean folder |
| Managed config file completely absent on an MDM-managed device | Intune/Defender portal Antivirus policy not assigned to this device's group, or assignment sync hasn't landed yet | Confirm policy assignment scope in Intune/Defender portal; check device's last policy sync time |
| `offlineDefinitionUpdateVerifySig` set in managed config, but engineers assume it's controlling verification behavior | Stale assumption — this setting was deprecated by the always-on verification introduced in engine `101.26062.0005` | `mdatp health --details definitions` shows the value as `"DEPRECATED"` |

---
## Validation Steps

1. **Confirm the endpoint's MDE version supports offline updates at all.**
   ```bash
   mdatp version
   ```
   Good: `101.24022.0001` or later. Bad: older — offline updates are not supported; upgrade the agent first.

2. **Confirm the managed configuration matches intent.**
   ```bash
   cat /etc/opt/microsoft/mdatp/managed/mdatp_managed.json
   ```
   Good: `offlineDefinitionUpdateUrl` points at the release-ring folder (no `arch_*` suffix), `offlineDefinitionUpdate: "enabled"`. Bad: file missing entirely, or URL includes an `arch_*` path segment.

3. **Confirm the mirror server itself is current**, independent of any single endpoint:
   ```bash
   # On the mirror server
   ls -la <downloadFolder>/linux/production/arch_x86_64/
   cat <downloadFolder>/linux/production/arch_x86_64/manifest.json
   ```
   Good: `manifest.json` timestamp/version consistent with a recent successful downloader run. Bad: stale files — the mirror's own scheduled job has stopped running.

4. **Confirm engine signature verification is active** (expected on all supported builds since August 2026):
   ```bash
   mdatp health --details features
   ```
   Good: `engine_signature_verification: "enabled"`. This should be true regardless of any legacy `offlineDefinitionUpdateVerifySig` setting.

5. **Trigger and confirm an end-to-end update.**
   ```bash
   mdatp definitions update
   mdatp health --details definitions
   ```
   Good: `definitions_status: "up_to_date"`, `definitions_update_source_uri` matches the configured mirror URL (not a Microsoft cloud fallback URL, unless that's expected), `definitions_update_fail_reason` empty.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Isolate mirror-side vs. endpoint-side.** Check the mirror server's own download folder/manifest timestamp before touching any endpoint. A stale mirror affects the entire fleet identically; an endpoint-specific problem affects one device while others succeed.

**Phase 2 — If mirror-side: fix the downloader job.** Confirm the mirror server can still reach `github.com/microsoft/mdatp-xplat` and the `go.microsoft.com` fwlink, then re-run the downloader script manually and inspect its log output (`logFilePath` in `settings.json`) before re-enabling the scheduled job.

**Phase 3 — If endpoint-side: confirm configuration, then connectivity, then verification, in that order.** Configuration mistakes (wrong URL path, `offlineDefinitionUpdate` not enabled) are both more common and faster to check than connectivity issues; connectivity is faster to check than engine-level signature problems. Work through Validation Steps 2 → 3 → 4 in sequence rather than jumping to the least likely cause first.

**Phase 4 — If fleet-wide and configuration-driven, fix at the policy layer, not per-device.** A misconfigured `offlineDefinitionUpdateUrl` affecting every endpoint should be fixed once in the Intune/Defender portal Antivirus policy (or the shared managed JSON template for non-MDM hosts) rather than patched device-by-device.

**Phase 5 — For engine-version drift specifically, don't assume "up_to_date" means fully current.** `definitions_status` reflects definition data, not necessarily engine binary currency if signature verification has been silently rejecting engine updates — cross-check actual engine version against the mirror's latest available version as a separate check.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fix Mirror Server Path Misconfiguration (fleet-wide)</summary>

```bash
# Confirm the ACTUAL correct release-ring path on the mirror (excludes arch_* suffix)
ls -la <downloadFolder>/linux/
# e.g. correct value to deploy: http://updates.contoso.com:8000/linux/production/
```

Update the source policy (Intune Antivirus policy's "Offline security intelligence update URL or directory" setting, the equivalent Defender portal policy field, or the shared `mdatp_managed.json` template for non-MDM hosts) to the corrected path, then allow normal policy sync/check-in to propagate it — do not hand-edit `mdatp_managed.json` on individual MDM-managed endpoints, as policy sync will simply overwrite it.

**Rollback:** revert the policy setting to its previous value if the corrected path causes unexpected behavior; no device-side state is destructively changed by this fix.

</details>

<details><summary>Playbook 2 — Rebuild a Corrupted Mirror Download</summary>

```bash
# On the mirror server: re-clone/re-download a clean copy of the downloader tooling
git clone https://github.com/microsoft/mdatp-xplat.git mdatp-xplat-clean
cd mdatp-xplat-clean/linux/definition_downloader/

# Configure settings.json for your environment, then re-run
./xplat_offline_updates_download.sh
```

If `backupPreviousUpdates` was enabled in `settings.json`, the previous (potentially good) version is preserved in a `_back` folder and can be manually restored as an emergency fallback while a clean update is re-fetched.

**Rollback:** restore from the `_back` folder if the fresh download also fails verification or introduces new problems — this is exactly the scenario that setting exists for.

</details>

<details><summary>Playbook 3 — Migrate Off `offlineDefinitionUpdateVerifySig` References</summary>

For organizations with legacy documentation, monitoring, or configuration templates that still reference `offlineDefinitionUpdateVerifySig` as a meaningful control:

1. Audit existing `mdatp_managed.json` templates and Intune/Defender portal policy exports for the deprecated key.
2. No functional change is required — the key can remain present harmlessly — but update internal documentation and any monitoring/alerting logic that assumes this key controls verification behavior, since it no longer does.
3. Confirm `engine_signature_verification: "enabled"` is what's actually being checked in any automated compliance/audit tooling going forward.

**Rollback:** not applicable — this is a documentation/tooling hygiene playbook, not a device configuration change.

</details>

---
## Evidence Pack

```bash
#!/usr/bin/env bash
# Read-only evidence collector for MDE Linux offline update troubleshooting.
# Run on the affected Linux endpoint. Makes no configuration changes.

OUTFILE="/tmp/mde-offline-update-evidence-$(hostname)-$(date +%Y%m%d-%H%M%S).txt"

{
    echo "=== Hostname / OS ==="
    hostname
    cat /etc/os-release 2>/dev/null

    echo -e "\n=== MDE Agent Version ==="
    mdatp version 2>&1

    echo -e "\n=== Definitions Health ==="
    mdatp health --details definitions 2>&1

    echo -e "\n=== Feature / Signature Verification Health ==="
    mdatp health --details features 2>&1

    echo -e "\n=== Connectivity Test ==="
    mdatp connectivity test 2>&1

    echo -e "\n=== Managed Configuration ==="
    cat /etc/opt/microsoft/mdatp/managed/mdatp_managed.json 2>&1 || echo "No managed config file present"

    echo -e "\n=== Manual Update Attempt ==="
    mdatp definitions update 2>&1

    echo -e "\n=== Post-Attempt Definitions Health ==="
    mdatp health --details definitions 2>&1
} > "$OUTFILE"

echo "Evidence written to $OUTFILE"
```

---
## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `mdatp health --details definitions` | Current definition status, source URI, fail reason |
| `mdatp health --details features` | Engine signature verification and other feature state |
| `mdatp connectivity test` | Confirm reachability to mirror server / Microsoft cloud |
| `mdatp definitions update` | Trigger a manual, immediate update attempt |
| `mdatp version` | Confirm agent version supports offline updates (≥ `101.24022.0001`) |
| `cat /etc/opt/microsoft/mdatp/managed/mdatp_managed.json` | Inspect current managed configuration |
| `./xplat_offline_updates_download.sh` | (Mirror server) manually run the Bash downloader script |
| `./xplat_offline_updates_download.ps1` | (Mirror server) manually run the PowerShell downloader script |
| `curl -sI http://<mirror>/linux/production/manifest.json` | Independent reachability check to an HTTP mirror |
| `mount \| grep <mirror-mount>` | Confirm an NFS/mount-based mirror path is actually mounted |
| `git clone https://github.com/microsoft/mdatp-xplat.git` | Fetch a clean copy of the downloader tooling |

---
## 🎓 Learning Pointers

- The mirror server intentionally has no Defender for Endpoint dependency — it's a plain file host reachable to only two Microsoft URLs. Treat mirror-server troubleshooting as ordinary file-hosting/network troubleshooting, not an MDE-specific problem.
- `offlineDefinitionUpdateUrl` must point at the release-ring folder, excluding the `arch_*` subfolder — this single path-construction detail is the most common source of "works for some devices, not others" tickets, since `mdatp` appends the architecture path automatically per device.
- Engine signature verification (default-on since engine `101.26062.0005`, August 2026) fails **silently** from the endpoint's perspective — no distinct alert, just an engine that doesn't advance. Build periodic engine-version drift checks into fleet hygiene rather than relying on per-device error surfacing.
- `offlineDefinitionUpdateVerifySig` is dead weight in any config authored before August 2026 — it's deprecated, has no effect, and its presence or absence should not be part of any troubleshooting decision tree going forward.
- The same mirror server can serve Linux **and** macOS offline updates from one host (`downloadMacUpdates` in `settings.json`) — worth knowing before standing up a second mirror unnecessarily for a mixed Linux/macOS fleet.
- Source: [Configure offline security intelligence updates for Microsoft Defender for Endpoint on Linux — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/linux-support-offline-security-intelligence-update) (ms.date 2026-09-08, updated_at 2026-09-11).
