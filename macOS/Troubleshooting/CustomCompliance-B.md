# macOS Custom Compliance Settings — Hotfix Runbook (Mode B: Ops)
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

Run these immediately to understand the problem:

```bash
# 1. On the Mac — confirm the agent is present and has recently checked in
ls -la "/Library/Intune/Microsoft Intune Agent.app"
log show --predicate 'subsystem == "com.microsoft.intune"' --last 1h | tail -50

# 2. Manually run the discovery script and capture BOTH signals
./discovery-script.sh
echo "Exit code: $?"

# 3. Validate the JSON output is actually parseable
./discovery-script.sh | python3 -m json.tool
```

**Interpretation:**

| Result | Next Action |
|---|---|
| Exit code non-zero | Script itself failed — fix the script's logic/permissions, not the JSON rules |
| Exit code `0` but JSON parse fails | Malformed JSON or a stray `echo`/`Write-Host`-equivalent line before the JSON — strip extra output |
| Exit code `0`, valid JSON, but device still shows wrong compliance state | Key-name mismatch between script output and the policy's JSON rules file |
| Script never appears to run at all | Agent not installed, or device not in the policy's assigned group |
| `file script.sh` reports a BOM | Re-save as plain UTF-8 without BOM before re-uploading |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Device enrolled in Intune (macOS — this feature also supports Windows and Linux, each with its own script language)
        │
Microsoft Intune Agent.app installed and healthy
  /Library/Intune/Microsoft Intune Agent.app
        │
Discovery Script uploaded to Intune (Bash, macOS platform, valid shebang, no BOM)
        │
JSON rules file attached to the compliance policy (references the script's output keys)
        │
Compliance Policy assigned to a group containing the device
        │
Device checks in → script runs → BOTH exit code and STDOUT JSON captured
        │
Compliance engine evaluates JSON against rules ONLY IF exit code was 0 and JSON was valid
        │
Device marked Compliant / NonCompliant / Error
        │
Conditional Access evaluates compliance state (if CA policy requires a compliant device)
```

**Critical constraints:**
- Discovery scripts must satisfy **two separate contracts**: exit code (script execution success) and STDOUT JSON (discovered values) — a script can exit `0` with bad JSON, or output perfect JSON but still exit non-zero. Either failure mode produces `Error`, not a useful compliance signal.
- Script must be UTF-8 **without a BOM** — some macOS text editors add one silently
- Script size and output size are each capped at 1 MB; run time capped at **10 minutes**
- JSON keys must **exactly match** the compliance rule's `SettingName` values
- macOS is now a genuinely documented, supported platform for this feature — do not tell a customer "custom compliance is Windows-only," that claim is stale as of the current Microsoft Learn documentation

</details>

---

## Diagnosis & Validation Flow

**Step 1: Confirm the agent is healthy**

```bash
ls -la "/Library/Intune/Microsoft Intune Agent.app"
log show --predicate 'subsystem == "com.microsoft.intune"' --last 4h | grep -i compliance
```

Expected: app present; log shows recent compliance-related activity.

---

**Step 2: Run the script manually, exactly as the upload settings configure it**

If **"Run this script using the logged on credentials"** is set to Yes, test as the logged-in user (not via `sudo`). If set to No, test in an elevated context. Mismatched test context is a very common false negative.

```bash
./discovery-script.sh
echo "Exit code: $?"
```

Expected: exit `0`.

Bad: any non-zero exit — this alone is enough to explain an `Error` state, independent of what the JSON says.

---

**Step 3: Validate JSON**

```bash
./discovery-script.sh | python3 -m json.tool
```

Expected: clean, parseable JSON with the keys your rules reference.

Bad: parse error, empty output, or extra non-JSON text mixed into STDOUT.

---

**Step 4: Check for a BOM**

```bash
file discovery-script.sh
head -c 3 discovery-script.sh | xxd
```

`EF BB BF` at the start = BOM present = will fail on-device even if the script works perfectly when run manually via some editors/terminals that silently strip it.

---

**Step 5: Confirm JSON key names against the compliance policy rules**

In the Intune portal: **Devices → Compliance policies → [Policy] → Properties → Compliance settings**. Compare each `SettingName` character-for-character against your script's JSON output keys.

---

**Step 6: Force a re-check on the device**

```
Company Portal app → Devices → select the device → Check Status
```

This is the macOS-specific manual trigger — distinct from Windows (Company Portal website sync trigger) and Linux (Intune app Refresh).

---

## Common Fix Paths

<details><summary>Fix 1 — Script exits non-zero for a "non-compliant" finding (most common)</summary>

**Symptom:** Device shows `Error`, not `NonCompliant`, even though the on-device setting is genuinely out of policy.

**Cause:** The script author conflated "the setting is non-compliant" with "the script failed," and wrote `exit 1` when a check comes back negative.

**Fix:**

```bash
# WRONG — treats a non-compliant finding as a script failure
if [[ "$FDE_ENABLED" == "false" ]]; then
    echo '{"FileVaultEnabled": false}'
    exit 1   # <-- this makes Intune report Error, not NonCompliant
fi

# CORRECT — script succeeded at discovering the state; let the JSON rules decide
echo "{\"FileVaultEnabled\": $FDE_ENABLED}"
exit 0
```

Reserve non-zero exits strictly for genuine script failures (missing command, permission denied, unexpected state the script can't evaluate at all).

</details>

<details><summary>Fix 2 — JSON keys don't match the compliance rule setting names</summary>

**Symptom:** Script runs cleanly (exit `0`, valid JSON), but device is always `NonCompliant` (or always `Compliant`) regardless of the real state.

**Cause:** Key-name mismatch between script output and the JSON rules file.

**Fix:**

1. In Intune portal → Compliance policies → Policy → Properties → Compliance settings, note the exact `SettingName` values
2. Update the discovery script to emit exactly matching key names (case-sensitive matching is safest to assume):

```bash
printf '{"FileVaultEnabled": %s}\n' "$FDE_ENABLED"
```

3. Re-upload the corrected script and reassign, or edit the linked script in place if your workflow supports it.

</details>

<details><summary>Fix 3 — BOM silently corrupting the script</summary>

**Symptom:** Script works when pasted directly into Terminal, but fails every time when uploaded to Intune.

**Cause:** The file on disk carries a UTF-8 byte-order mark, which some macOS editors add without visible indication.

**Fix:**

```bash
# Strip a BOM from a script file
sed -i '' '1s/^\xEF\xBB\xBF//' discovery-script.sh
file discovery-script.sh   # confirm it now reads plain "UTF-8 Unicode text"
```

Re-upload the cleaned file.

</details>

<details><summary>Fix 4 — Agent not installed / device stuck at Unknown</summary>

**Symptom:** Compliance policy is assigned, but the device never evaluates it — stays `Unknown`/`Not evaluated`.

**Cause:** `Microsoft Intune Agent.app` isn't installed or hasn't checked in.

**Fix:** Assign any shell script or app to the device to trigger agent installation/repair, then confirm:

```bash
ls -la "/Library/Intune/Microsoft Intune Agent.app"
```

If present but stale, see `Shell-Script-Failures-B.md` for the broader agent-health playbook — the same agent drives both Shell Scripts and Custom Compliance.

</details>

<details><summary>Fix 5 — Script exceeds the 10-minute run-time ceiling</summary>

**Symptom:** Device reports `Error`; on-device manual run of the script also takes a long time.

**Cause:** Slow or unbounded operations in the discovery script (network calls without timeouts, large file scans).

**Fix:** Add explicit timeouts around slow operations:

```bash
timeout 15 curl -s -o /dev/null -w "%{http_code}" https://internal.contoso.com/health
```

Optimize or remove checks that can't reliably complete well within the 10-minute ceiling.

</details>

---

## Escalation Evidence

Copy and fill in before raising a ticket:

```
=== macOS Custom Compliance Escalation ===

Tenant ID:                 ___________________________
Compliance Policy Name:    ___________________________
Compliance Policy ID:      ___________________________
Affected Device(s):        ___________________________
macOS Version:              ___________________________

Compliance State:          [ ] NonCompliant  [ ] Error  [ ] Unknown
Expected State:            ___________________________

Discovery Script Name:      ___________________________
Script last updated:        ___________________________
"Run using logged on credentials" setting: [ ] Yes  [ ] No

Manual run exit code:       ___________________________
Manual run JSON output:     (paste raw STDOUT from running the script locally)
BOM check result (`file script.sh`): ___________________________

Steps already taken:
[ ] Verified Intune Agent present and checked in
[ ] Ran script manually and captured exit code separately from JSON output
[ ] Validated JSON with python3/jq
[ ] Checked for BOM
[ ] Verified JSON keys match compliance rule setting names
[ ] Forced a Check Status from Company Portal

Support priority: P[1/2/3]
Business impact: ___________________________
```

---

## 🎓 Learning Pointers

- **macOS custom compliance is real and documented as of the current Microsoft Learn content** — if you've previously told anyone "custom compliance is Windows-only" (including from this repo's own `Intune/Troubleshooting/CustomCompliance-B.md`, prior to this update), that claim is stale. Correct going forward. [MS Docs: Use custom compliance settings](https://learn.microsoft.com/en-us/intune/device-security/compliance/custom-settings)

- **Two contracts, not one** — exit code and JSON output are evaluated independently. A script can "work" (produce correct JSON) and still report `Error` because of an exit-code mistake, or vice versa. Always check both separately when triaging, never assume one implies the other.

- **The BOM failure mode is invisible in most editors** — build "check for BOM" into your standard pre-upload checklist rather than treating it as a last-resort troubleshooting step once something's already broken in production.

- **Company Portal's on-device trigger differs by platform** — macOS uses **Check Status** inside the Company Portal app's Devices view; this is a different action from the Windows Company Portal *website* sync trigger and the Linux Intune app's *Refresh* button. Don't hand a Windows admin's instructions to a macOS user.

- **Microsoft's troubleshooting doc explicitly scopes itself to "Windows and Linux devices"** for the numbered error-code reference — treat any macOS-specific error code you observe as something to verify empirically in your own tenant rather than assume matches the Windows/Linux documentation 1:1.
