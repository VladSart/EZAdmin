# Defender for Endpoint on Linux — Offline Security Intelligence Updates — Hotfix Runbook (Mode B: Ops)
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

Applies to Linux servers/endpoints running Defender for Endpoint that pull security intelligence (definition) updates from a locally hosted **mirror server** instead of directly from Microsoft — the standard pattern for isolated/air-gapped or restricted-network Linux fleets.

```bash
# 1. Current definition status, source, and last failure reason (single most useful command)
mdatp health --details definitions

# 2. Confirm the antivirus engine itself is loading (new since Aug 2026: signature verification)
mdatp health --details features

# 3. Confirm the endpoint can reach the mirror server and Defender cloud services
mdatp connectivity test

# 4. Force an immediate update attempt (safe, read-heavy, does not change config)
mdatp definitions update

# 5. Confirm the managed configuration (mirror URL, intervals) is actually what you expect
cat /etc/opt/microsoft/mdatp/managed/mdatp_managed.json 2>/dev/null || echo "No managed config file present"
```

| Result | Next Step |
|--------|-----------|
| `definitions_status` = `up_to_date`, no fail reason | No fix needed — false alarm or already resolved |
| `definitions_update_fail_reason` populated | → [Fix 1 — Update Failure with a Reason Given](#fix-1--update-failure-with-a-reason-given) |
| `mdatp connectivity test` fails to reach the mirror server | → [Fix 2 — Mirror Server Unreachable](#fix-2--mirror-server-unreachable) |
| `offline_definition_url_configured` empty/missing but device is supposed to be offline-update-enabled | → [Fix 3 — Offline Update Not Configured on This Endpoint](#fix-3--offline-update-not-configured-on-this-endpoint) |
| `engine_signature_verification` not `enabled` on an engine build ≥ `101.26062.0005` | → [Fix 4 — Engine Signature Verification Rejecting the Update](#fix-4--engine-signature-verification-rejecting-the-update) |
| `definitions_update_source_uri` shows a Microsoft cloud URL instead of the mirror server | → [Fix 5 — Silent Fallback to Cloud (Mirror Server Skipped)](#fix-5--silent-fallback-to-cloud-mirror-server-skipped) |
| Managed config file missing entirely | → [Fix 3](#fix-3--offline-update-not-configured-on-this-endpoint) — policy likely never delivered |

---
## Dependency Cascade

<details><summary>What must be true for an offline update to succeed</summary>

```
Mirror server (Linux/Windows/macOS — no MDE install required on it)
reachable from the Linux endpoint over HTTP/HTTPS/NFS/mount point
        │
        ▼
Mirror server's downloader script (xplat_offline_updates_download.sh/.ps1)
has run successfully and produced updates.zip + manifest.json under
<downloadFolder>/linux/production/arch_*
        │
        ▼
Endpoint's managed config (mdatp_managed.json, or Intune/Defender portal
Antivirus policy) points offlineDefinitionUpdateUrl at the CORRECT path —
through the release-ring folder, NOT including the arch_* subfolder
        │
        ▼
offlineDefinitionUpdate = "enabled" AND automaticDefinitionUpdateEnabled = true
AND antivirus engine enforcement level = real_time
        │
        ▼
Engine signature verification (default-on since engine 101.26062.0005,
Aug 2026) validates the downloaded engine's digital signature
        │
        ▼
mdatp definitions update succeeds → definitions_status = up_to_date
```

</details>

---
## Diagnosis & Validation Flow

1. **Read current state in one command.**
   ```bash
   mdatp health --details definitions
   ```
   Expected (healthy): `definitions_status: "up_to_date"`, `definitions_update_fail_reason: ""`, and `definitions_update_source_uri` matching `offline_definition_url_configured`. Bad: any non-empty fail reason, or a source URI that doesn't match the configured mirror URL.

2. **Confirm engine signature verification state** (new since engine build `101.26062.0005`, August 2026 — this replaces the old `offlineDefinitionUpdateVerifySig` setting, which is now deprecated and has no effect).
   ```bash
   mdatp health --details features
   ```
   Expected: `engine_signature_verification: "enabled"`. If your managed config still sets `offlineDefinitionUpdateVerifySig`, that's harmless but no longer does anything — don't waste time troubleshooting it as if it still controlled behavior.

3. **Test connectivity to both the mirror server and Microsoft's fallback cloud endpoint.**
   ```bash
   mdatp connectivity test
   ```
   Expected: mirror server reachable. If fallback-to-cloud is enabled and the mirror fails, a cloud path should also report reachable — otherwise the endpoint has no update path at all.

4. **Confirm the managed configuration matches what was intended to be deployed** (Intune Antivirus policy, Defender portal endpoint security policy, or direct `mdatp_managed.json`):
   ```bash
   cat /etc/opt/microsoft/mdatp/managed/mdatp_managed.json
   ```
   Look specifically for `offlineDefinitionUpdateUrl` (must be the release-ring folder path, not including `arch_*`), `offlineDefinitionUpdate` (`enabled`/`disabled`), and `offlineDefinitionUpdateFallbackToCloud`.

5. **Force a manual update and re-check status** to confirm the fix worked:
   ```bash
   mdatp definitions update
   mdatp health --details definitions
   ```
   Expected: `definitions_status` flips to `up_to_date` and `definitions_updated_minutes_ago` resets to near-zero.

---
## Common Fix Paths

<details><summary>Fix 1 — Update Failure with a Reason Given</summary>

`definitions_update_fail_reason` is populated directly by `mdatp` — read it first rather than guessing. Common causes and the matching action:

```bash
# Re-check the exact failure text
mdatp health --details definitions | grep definitions_update_fail_reason

# If the reason points at a network/permission issue reaching the mirror path,
# confirm the mirror share/mount is actually mounted and readable from this host
ls -la /path/to/configured/mirror/mount 2>&1

# Retry after confirming reachability
mdatp definitions update
```

**Rollback:** none — this is a diagnostic re-read, not a configuration change.

</details>

<details><summary>Fix 2 — Mirror Server Unreachable</summary>

```bash
# Confirm basic network reachability to the mirror host/share independent of mdatp
mdatp connectivity test

# For an HTTP/HTTPS mirror, confirm the endpoint can actually fetch the manifest
curl -sI "http://<mirror_server_address>/linux/production/manifest.json"

# For an NFS/mount-based mirror, confirm the mount is present and current
mount | grep <mirror-mount-point>
```

If the mirror server itself is down or its own scheduled download job has stopped running, this is a mirror-server-side problem, not an endpoint problem — verify the mirror's own cron job/scheduled task for `xplat_offline_updates_download.sh`/`.ps1` last-run status before spending more time on the endpoint.

**Rollback:** if `offlineDefinitionUpdateFallbackToCloud` is `true`, the endpoint should already be falling back to Microsoft's cloud while the mirror is down — no immediate action required beyond fixing the mirror server itself.

</details>

<details><summary>Fix 3 — Offline Update Not Configured on This Endpoint</summary>

Managed config file missing or `offlineDefinitionUpdate` not set to `enabled` — the policy was likely never delivered to this device (Intune/Defender portal assignment gap) or the device is not in scope.

```bash
# Confirm whether ANY managed policy has landed on this device at all
ls -la /etc/opt/microsoft/mdatp/managed/
cat /etc/opt/microsoft/mdatp/managed/mdatp_managed.json 2>/dev/null
```

If no managed config file exists at all, check the Intune/Defender portal **Antivirus** endpoint security policy assignment for this device's group — this is a policy-delivery gap, not something fixable from the endpoint itself. Confirm assignment, then wait for the next check-in interval or force a policy sync from the device's MDM agent.

**Rollback:** none — this is filling a configuration gap, not undoing anything.

</details>

<details><summary>Fix 4 — Engine Signature Verification Rejecting the Update</summary>

Since engine build `101.26062.0005` (August 2026), an update whose engine file fails digital signature verification is silently **not loaded** — `mdatp` will not throw an obvious error, the device will just stay on the previous engine version.

```bash
mdatp health --details features | grep engine_signature_verification
```

If this shows anything other than `enabled`, the mirror server's downloaded files may be corrupted, tampered, or from an unofficial source. Re-run the official downloader script on the mirror server against a clean download folder rather than trying to work around verification — this is a default-on security control by design, not a bug to bypass.

```bash
# On the mirror server — re-fetch clean
./xplat_offline_updates_download.sh
```

**Rollback:** none — do not disable signature verification; the `offlineDefinitionUpdateVerifySig` setting that used to control this is deprecated and has no effect regardless.

</details>

<details><summary>Fix 5 — Silent Fallback to Cloud (Mirror Server Skipped)</summary>

`definitions_update_source_uri` shows a Microsoft cloud URL even though a mirror server is configured — this means the mirror attempt failed and `offlineDefinitionUpdateFallbackToCloud` quietly picked up the slack. Functionally fine (device stays current) but defeats the purpose of an air-gapped/bandwidth-controlled deployment and means the device briefly needed direct internet access.

```bash
mdatp health --details definitions | grep -E 'definitions_update_source_uri|offline_definition_url_configured'
```

Investigate why the mirror path failed using [Fix 2](#fix-2--mirror-server-unreachable) — this fix path is really a signal to go run that one, not a separate remediation.

**Rollback:** none — no destructive change involved; this is a diagnostic signal.

</details>

---
## Escalation Evidence

```
MDE LINUX OFFLINE UPDATE FAILURE — Escalation Package
=====================================================================
Device hostname:              <hostname>
Linux distribution/version:   <output of `cat /etc/os-release`>
MDE agent version:            <output of `mdatp version`>
Engine version:               <from `mdatp health --details definitions`>
Signature verification state: <from `mdatp health --details features`>
definitions_status:           <value>
definitions_update_fail_reason: <value>
definitions_update_source_uri: <value>
offline_definition_url_configured: <value>
Managed config present:       <yes/no>
Connectivity test result:     <output>
Mirror server reachable independently (curl/mount test): <yes/no>
Policy delivery method:       <Intune / Defender portal / managed JSON directly>
Number of devices affected:   <count, if fleet-wide>
```

---
## 🎓 Learning Pointers

- The single fastest diagnostic command for this whole topic is `mdatp health --details definitions` — it surfaces the fail reason, the actual update source used, and the configured mirror URL in one call. Lead every ticket with it.
- `offlineDefinitionUpdateVerifySig` is **deprecated and no longer has any effect** as of engine `101.26062.0005` (August 2026) — signature verification is now always on. If an older runbook, script, or internal wiki page references this setting as a way to control verification behavior, it's stale; update it.
- A device silently falling back to the Microsoft cloud when the mirror fails (if `offlineDefinitionUpdateFallbackToCloud = true`) keeps definitions current but defeats the purpose of an offline/restricted-network deployment — treat repeated fallback as a mirror-server health signal worth investigating even though the device itself looks "fine."
- The mirror server does **not** need Defender for Endpoint installed on it at all — it can run Linux, Windows, or macOS and only needs to reach two specific Microsoft URLs (the `mdatp-xplat` GitHub repo and a `go.microsoft.com` fwlink) to download updates. Don't waste time troubleshooting an MDE agent issue on the mirror server itself; it's a plain file host.
- See also: [`MDE-WSL-A.md`](MDE-WSL-A.md) / [`MDE-WSL-B.md`](MDE-WSL-B.md) for the related-but-distinct Defender for Endpoint on WSL topic — offline updates as described here apply to native Linux hosts/servers, not the WSL plug-in scenario.
- Source: [Configure offline security intelligence updates for Microsoft Defender for Endpoint on Linux — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/linux-support-offline-security-intelligence-update) (ms.date 2026-09-08, updated 2026-09-11).
