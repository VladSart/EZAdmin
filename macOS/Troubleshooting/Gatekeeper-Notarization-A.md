# macOS Gatekeeper / Notarization — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

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
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

Covers **Gatekeeper and notarization failures for internally-packaged or custom-signed `.pkg`/`.app` deployments delivered via Microsoft Intune** — code signing, notarization, quarantine, and the tenant-wide Gatekeeper policy layer configured through Intune's Settings Catalog "System Policy" category. This is the deployment-integrity layer sitting *underneath* app delivery: Intune can successfully push a package to a device and still produce a completely unusable app if this layer isn't satisfied.

**Applies to:**
- Internally-built or repackaged `.pkg`/`.app` deployments pushed as macOS LOB apps via Intune
- Fleet-wide Gatekeeper policy enforcement/relaxation via Settings Catalog System Policy settings
- Diagnosing "installed successfully but won't open" and "the application is damaged" reports

**Out of scope:** vendor-provided, already-signed-and-notarized software (Chrome, Zoom, Adobe, etc. — these rarely hit this topic at all, since the vendor has already done the signing/notarization work); Gatekeeper's use as a **compliance-check signal** via `spctl --status` pass/fail, which is covered in `Compliance-Policies-A.md`; System Integrity Protection (SIP) and other unrelated macOS security layers; general Intune macOS app-deployment plumbing issues (agent presence, assignment scope, detection-rule mismatches) that are not signing/notarization-related.

**Explicit non-assumption:** MDM-pushed installs and interactive user launches are evaluated by **two different code paths** in macOS. A package installing "successfully" through Intune's agent is not proof that Gatekeeper will permit a user to subsequently open the resulting app — treat these as two separate checkpoints throughout this document, not one.

---
## How It Works

<details><summary>Full architecture — signing, notarization, and Gatekeeper evaluation</summary>

### Three independent-but-related concepts

| Concept | What it proves | Who checks it |
|---|---|---|
| **Code signing** | The binary/package hasn't been altered since a specific identity (a Developer ID cert tied to an Apple Developer account) signed it | `codesign` (apps), `pkgutil --check-signature` (installer packages) |
| **Notarization** | Apple's automated malware-scanning pipeline examined the *specific signed build* and found no known malicious content, issuing a ticket | `spctl`, Apple's online notarization-check service, or an offline stapled ticket |
| **Gatekeeper** | The on-device policy engine that decides, at launch/open time, whether to allow execution based on signing + notarization + quarantine + the device's own policy configuration | `spctl -a` |

These are sequential and additive, not substitutes for each other: an app can be signed but not notarized (Gatekeeper will flag it as such specifically), notarized-but-improperly-signed is not a real state (notarization requires a valid signature as a prerequisite for submission), and Gatekeeper's final decision also factors in the device's own policy configuration independent of the app itself.

### The quarantine attribute and why MDM installs mostly skip it

`com.apple.quarantine` is an extended file attribute the OS sets on files that cross a **trust boundary** — a browser download, an AirDrop transfer, a Mail attachment. It's what triggers the familiar "downloaded from the internet, are you sure you want to open it?" first-launch prompt, and it's the trigger for Gatekeeper's *interactive* assessment path.

Files delivered via Intune's macOS Management Agent (LOB app installs) are generally **not** quarantined — the delivery mechanism doesn't cross the same trust boundary a browser download does. This is precisely why an unsigned or unnotarized package can appear to install cleanly via Intune (no interactive prompt is ever shown, because there's no quarantine flag to trigger one) and then fail the moment a user later moves, re-copies, or otherwise causes the file to be re-evaluated — or simply attempts to launch an app whose underlying signature Gatekeeper still independently validates regardless of quarantine state.

```
Package built and signed
(Developer ID Installer cert → .pkg; Developer ID Application cert → .app)
    │
    ▼
[Optional but strongly recommended] Submitted to Apple notarization service
    │
    ▼
Apple scans for known malicious content → issues notarization ticket
    │
    ▼
Ticket stapled to the package/app (offline-verifiable), OR left
retrievable online via Apple's notarization-check service at
evaluation time
    │
    ▼
Delivered via Intune macOS LOB app mechanism
(generally does NOT set com.apple.quarantine — different trust
boundary than a browser/AirDrop/Mail delivery path)
    │
    ▼
Gatekeeper evaluates at launch (spctl -a):
  - Is there a valid, non-revoked Developer ID signature?
  - Is there a notarization ticket (stapled or verifiable online)?
  - Is quarantine present, and if so, has the user already
    overridden it for their own session ("Open Anyway")?
  - What does the device's own System Policy configuration allow?
    │
    ▼
Allow execution, or block with a specific reason
(surfaced to the user as "unidentified developer" / "damaged" /
silently in scripted/non-interactive contexts)
```

### The Settings Catalog "System Policy" (Gatekeeper) layer

Independent of any individual app's signing state, Intune can configure the device's own Gatekeeper policy via Settings Catalog System Policy settings, corresponding to the legacy `systempolicy.control` payload:

| Setting | Effect |
|---|---|
| `AllowIdentifiedDevelopers` | `true` = Gatekeeper's "App Store and identified developers" mode (the modern default). `false` = "App Store only" — blocks ALL non-MAS software including internally signed-and-notarized apps |
| `EnableAssessment` | `true` = Gatekeeper actively evaluates apps per policy. `false` = Gatekeeper accepts everything, effectively disabled fleet-wide |
| System Policy Managed → Disable Override | Prevents users from using "Open Anyway" to manually override a Gatekeeper block — removes the per-user escape hatch entirely, which changes how strictly a signing/notarization gap needs to be treated operationally |

A fleet-wide policy misconfiguration at this layer can make even a perfectly signed-and-notarized internal app unusable — always rule this layer out early, since it changes the diagnosis from "fix the package" to "fix the policy."

</details>

---
## Dependency Stack

```
Device's Gatekeeper policy allows non-MAS software at all
(Settings Catalog System Policy: AllowIdentifiedDevelopers = true,
EnableAssessment = true)
        │
Package/app signed with a valid, non-revoked Developer ID certificate
        │      (Installer cert for .pkg, Application cert for .app —
        │       two distinct certificate types, both required for a
        │       full pkg-wrapping-an-app deployment)
        │
[Recommended, not always MDM-install-blocking] App submitted for and
granted Apple notarization; ticket stapled or online-verifiable
        │
Delivery mechanism's trust-boundary status
(MDM/LOB install: typically no quarantine flag set, interactive
prompt bypassed — vs. browser/AirDrop/Mail: quarantine set,
interactive prompt triggered on first open)
        │
Gatekeeper's on-device assessment (spctl -a) evaluates all of the
above at launch/open time — NOT only at install time
        │
Any prior per-user "Open Anyway" override state
(scoped to that user only, not the whole device — irrelevant if
System Policy Managed → Disable Override is set)
        │
Execution allowed, or blocked with a specific reason surfaced to
the user (unidentified developer / damaged / silent failure in
non-interactive/scripted contexts)
```

**The critical distinction driving most real-world tickets: install-time evaluation and launch-time evaluation are not the same check.** A package can clear Intune's install pipeline entirely while still being doomed to fail the moment a user opens it — diagnosing "Intune says installed, app won't run" always requires running `spctl -a` against the actual delivered file, not re-trusting the Intune deployment status alone.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Can't be opened because it is from an unidentified developer" | No valid Developer ID signature at all | `codesign -dv` / `pkgutil --check-signature` |
| "Apple could not verify... is free of malware" / `source=Unnotarized Developer ID` | Signed correctly, but never notarized | `spctl -a -vvv` |
| "The application is damaged and can't be opened" | Signature verification failure — corrupted transfer, or a since-revoked certificate | `codesign --verify --deep --strict` |
| Installs fine via Intune, fails to open for end users | MDM install bypassed the interactive Gatekeeper prompt (no quarantine set); underlying signing/notarization gap only surfaces at launch | `spctl -a -vvv` against the installed app, independent of Intune's own status |
| Works when an admin tests it locally, fails for standard users | Per-user "Open Anyway" override state, not a real fix | Re-test with `spctl -a -vvv`, ignore the admin's manual override history |
| Every non-App-Store app is blocked fleet-wide, including known-good internal tools | Settings Catalog System Policy set to App Store-only (`AllowIdentifiedDevelopers = false`) or Gatekeeper otherwise over-restricted | `sudo profiles -P` for the System Policy payload; `spctl --status --verbose` |
| No apps are ever blocked, even obviously-unsigned ones | `EnableAssessment = false` — Gatekeeper effectively disabled fleet-wide | Same as above; confirm this is intentional, not an accidental over-permissive policy |
| Quarantine attribute present on an Intune-delivered file | Something other than the LOB install mechanism touched the file post-delivery (a script, a manual copy step) | `xattr -p com.apple.quarantine`, review the deployment script/pipeline |
| `pkgutil --check-signature` shows signed, but `codesign -dv` on the extracted `.app` shows unsigned | Only the installer wrapper was signed, not the app bundle inside it — both layers need independent signatures | Check both layers separately, never assume one implies the other |
| Notarization submission fails or times out during build | Apple-side notarization service issue, invalid API key/app-specific password, or a genuine flagged-content finding in the submission | `xcrun notarytool log <submission-id>` for the specific rejection reason |

---
## Validation Steps

**1. Confirm Gatekeeper's system-wide policy state**
```bash
spctl --status --verbose
```

**2. Confirm the Settings Catalog System Policy configuration delivered to this device**
```bash
sudo profiles -P | grep -iB2 -A15 "SystemPolicy\|systempolicy.control"
```
Good: values consistent with intended fleet policy. Bad: unexpectedly restrictive (App Store-only) or unexpectedly permissive (assessment disabled) relative to what's actually needed.

**3. Assess the specific app**
```bash
spctl -a -vvv /Applications/<YourApp>.app
```
Good: `accepted`, `source=Notarized Developer ID`. Bad: `rejected`, note the exact `source=` value.

**4. Verify app-bundle signature independently**
```bash
codesign -dv --verbose=4 /Applications/<YourApp>.app 2>&1
codesign --verify --deep --strict /Applications/<YourApp>.app 2>&1
```

**5. Verify installer package signature independently**
```bash
pkgutil --check-signature /path/to/YourInstaller.pkg
```

**6. Assess the installer package's notarization status directly**
```bash
spctl -a -vvv -t install /path/to/YourInstaller.pkg
```

**7. Check for quarantine and its recorded origin**
```bash
xattr -p com.apple.quarantine /Applications/<YourApp>.app 2>&1
mdls -name kMDItemWhereFroms /Applications/<YourApp>.app 2>&1
```

**8. Confirm Intune's own install-status view for cross-reference**
Check the app's Device install status in the Intune admin center (Apps > macOS) — status detail codes here diagnose *install-time* failures, not the launch-time Gatekeeper questions this runbook otherwise focuses on. A generic install failure (e.g. `0x87D13B64`) with a `pkgutil --check-signature` showing "no signature" points to the same root cause surfacing at a different stage.

---
## Troubleshooting Steps (by phase)

### Phase 1: Rule out the fleet-wide policy layer first

1. Check `spctl --status --verbose` and the device's Settings Catalog System Policy assignment.
2. If Gatekeeper is disabled fleet-wide or restricted to App Store-only in a way that wasn't intended, fix the policy assignment before investigating any individual app — this single layer can explain symptoms across many apps simultaneously and should always be ruled out before chasing individual package signatures.

### Phase 2: Confirm signing at both layers independently

1. `codesign -dv` on the `.app` bundle.
2. `pkgutil --check-signature` on the `.pkg` installer.
3. Do not assume one implies the other — a signed installer wrapping an unsigned app is a real and common misconfiguration in internally-built packaging pipelines.

### Phase 3: Confirm notarization

1. `spctl -a -vvv -t install` against the installer package.
2. If unnotarized, decide whether this is acceptable for the deployment's risk profile (MDM install may still succeed) or needs remediation before users start manually launching the app.

### Phase 4: Distinguish install-time from launch-time failure

1. Check Intune's own Device install status — did the install itself fail, or succeed?
2. If installed successfully but launch fails, run `spctl -a -vvv` against the actual on-device `.app`, not just the source package — a corrupted or partially-written copy can differ from the source file's signature state.

### Phase 5: Investigate anomalous quarantine or damaged-file reports

1. Check for `com.apple.quarantine` presence on a file that should have arrived via a non-quarantining path.
2. If present, trace the deployment pipeline for any step (a wrapping script, a manual copy, a re-download) that could have introduced it.
3. If `codesign --verify --deep --strict` fails outright (not just an untrusted-but-intact signature), treat the file as corrupted in transit and re-deploy from source rather than attempting in-place repair.

---
## Remediation Playbooks

<details>
<summary>Playbook 1 — Standing up a signing and notarization pipeline for internally-packaged apps</summary>

**Scenario:** An organization has been deploying unsigned or ad-hoc-signed internal `.pkg` files via Intune and is now hitting Gatekeeper friction at scale.

1. Obtain (or confirm existing) Apple Developer Program membership and generate both a **Developer ID Application** certificate (signs `.app` bundles) and a **Developer ID Installer** certificate (signs `.pkg` files) — these are separate certificate types and both are needed for a full app-in-a-package deployment.
2. Integrate signing into the build/packaging pipeline as the final step before upload to Intune: sign the `.app` first, then build and sign the `.pkg` wrapper (`productsign`).
3. Integrate notarization as a subsequent pipeline step: `xcrun notarytool submit ... --wait`, then `xcrun stapler staple` on success. Treat a failed/rejected notarization submission as a build-blocking failure, not a warning to ignore — investigate via `xcrun notarytool log <submission-id>` rather than shipping an unnotarized package "for now."
4. Re-upload the signed-and-notarized package to Intune as a new app version, and validate via `spctl -a -vvv` against a freshly-installed copy on a pilot device before wide rollout.
5. Retire any standing "just tell users to click Open Anyway" guidance once the pipeline is in place — that guidance is a symptom of the gap this playbook closes, not a sustainable practice.

**Rollback:** N/A — signing/notarization is purely additive to the existing packaging process; no destructive change to roll back.

</details>

<details>
<summary>Playbook 2 — Diagnosing a fleet-wide Gatekeeper policy regression</summary>

**Scenario:** Multiple, previously-working internal apps suddenly report Gatekeeper blocks across many devices simultaneously — pointing at a policy change rather than individual app issues.

1. Confirm the pattern is genuinely fleet-wide via `spctl --status --verbose` across a sample of affected devices, not just one.
2. Check Intune's Settings Catalog System Policy profile change history / recent modifications for the affected device scope.
3. If a recent change tightened `AllowIdentifiedDevelopers` to `false` or otherwise restricted assessment, this is the root cause — correct the policy value and reassign.
4. After correcting policy, re-test previously-blocked apps with `spctl -a -vvv` on affected devices post-sync to confirm resolution, rather than assuming the policy fix alone is sufficient without device-side confirmation.

**Rollback:** Revert the System Policy profile to its prior configuration if the tightened policy was applied in error and has no legitimate security justification; if the tightening was intentional (e.g. a genuine App-Store-only security requirement), the correct fix is signing/notarizing affected apps or explicitly exempting them, not reverting the policy.

</details>

<details>
<summary>Playbook 3 — Investigating a "damaged" report that turns out to be certificate revocation, not corruption</summary>

**Scenario:** A previously-working, properly signed-and-notarized internal app suddenly starts reporting as "damaged" across the fleet with no packaging change on record.

1. Confirm the signature chain is intact structurally (`codesign --verify --deep --strict` passes) but Gatekeeper still rejects it (`spctl -a -vvv` returns `rejected`) — this combination points at certificate trust, not file corruption.
2. Check whether the signing certificate has expired or was revoked (an Apple Developer account lapse, a compromised-key response, or a certificate rotation that wasn't reflected in the deployed build).
3. If revocation/expiry is confirmed, this requires re-signing with a currently valid certificate and re-notarizing — there is no device-side fix, since the certificate's trust status is evaluated against Apple's own revocation infrastructure, not anything local.
4. Re-deploy the newly-signed-and-notarized build as a new Intune app version; existing installed copies will continue to fail Gatekeeper evaluation until replaced.

**Rollback:** N/A — re-signing with a valid certificate is the only forward path; there is no meaningful rollback for an app signed with a certificate that is no longer trusted.

</details>

---
## Evidence Pack

```bash
# Run this on the AFFECTED device via macOS shell (remote session, Intune Shell Script, or SSH)
# Collects Gatekeeper/notarization/signing evidence for a specific app for escalation.
# Usage: bash gatekeeper-evidence.sh /Applications/YourApp.app [/path/to/Installer.pkg]

APP_PATH="${1:?Usage: $0 /Applications/YourApp.app [/path/to/Installer.pkg]}"
PKG_PATH="${2:-}"
OutputPath="/tmp/gk-evidence-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OutputPath"

spctl --status --verbose > "$OutputPath/gatekeeper_status.txt" 2>&1
sudo profiles -P > "$OutputPath/all_profiles.txt" 2>&1

spctl -a -vvv "$APP_PATH" > "$OutputPath/spctl_app.txt" 2>&1
codesign -dv --verbose=4 "$APP_PATH" > "$OutputPath/codesign_app.txt" 2>&1
codesign --verify --deep --strict "$APP_PATH" > "$OutputPath/codesign_verify.txt" 2>&1
xattr -p com.apple.quarantine "$APP_PATH" > "$OutputPath/quarantine_attr.txt" 2>&1
mdls -name kMDItemWhereFroms "$APP_PATH" > "$OutputPath/where_froms.txt" 2>&1

if [[ -n "$PKG_PATH" ]]; then
    pkgutil --check-signature "$PKG_PATH" > "$OutputPath/pkg_signature.txt" 2>&1
    spctl -a -vvv -t install "$PKG_PATH" > "$OutputPath/spctl_pkg.txt" 2>&1
fi

tar czf /tmp/gk-evidence.tar.gz -C /tmp "$(basename "$OutputPath")"
echo "Evidence pack: /tmp/gk-evidence.tar.gz"
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check Gatekeeper policy state | `spctl --status --verbose` |
| Assess an installed app | `spctl -a -vvv /Applications/<App>.app` |
| Assess an installer package (pre/post-install) | `spctl -a -vvv -t install /path/to/Installer.pkg` |
| Check app bundle signature | `codesign -dv --verbose=4 /Applications/<App>.app` |
| Verify signature integrity | `codesign --verify --deep --strict /Applications/<App>.app` |
| Check installer package signature | `pkgutil --check-signature /path/to/Installer.pkg` |
| Sign an installer package | `productsign --sign "Developer ID Installer: <Name> (<TeamID>)" In.pkg Out.pkg` |
| Submit for notarization | `xcrun notarytool submit Installer.pkg --keychain-profile "<profile>" --wait` |
| Check notarization submission log/reason | `xcrun notarytool log <submission-id>` |
| Staple a notarization ticket | `xcrun stapler staple Installer.pkg` |
| Check quarantine attribute | `xattr -p com.apple.quarantine /Applications/<App>.app` |
| Check recorded download/transfer origin | `mdls -name kMDItemWhereFroms /Applications/<App>.app` |
| List Gatekeeper/System Policy profile on device | `sudo profiles -P \| grep -iB2 -A15 "SystemPolicy"` |
| Manually query installed-app inventory (cross-check Intune detection) | `sudo /usr/libexec/mdmclient QueryInstalledApps` |

---
## 🎓 Learning Pointers

- **Install-time and launch-time are different Gatekeeper checkpoints.** Intune's MDM install path largely bypasses the interactive prompt that would normally catch a signing/notarization gap, because LOB app delivery doesn't set the quarantine attribute the way a browser download does. "Intune shows Installed" is never sufficient evidence that Gatekeeper will permit a user to open the app — always independently run `spctl -a -vvv` against the actual delivered file. See: [Apple — Gatekeeper and runtime protection in macOS](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)

- **Two certificate types, evaluated independently.** Developer ID Application (app bundle) and Developer ID Installer (pkg wrapper) are separate signatures over separate artifacts — a signed installer wrapping an unsigned app is a real, common gap in home-grown packaging pipelines, and neither `codesign` nor `pkgutil --check-signature` alone tells the whole story. Check both. See: [Apple Developer — Developer ID](https://developer.apple.com/developer-id/)

- **Notarization is a scan-and-ticket system, not a signature.** It requires a valid signature as a prerequisite, then adds Apple's own malware-scan attestation on top. Skipping it doesn't always block an MDM install, but it reliably relocates the failure to first-launch, where it becomes a confusing end-user ticket instead of a clean build-pipeline error. See: [Apple Developer — Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

- **The Settings Catalog System Policy layer can mask or mimic an app-level problem.** A fleet-wide Gatekeeper policy change (accidental App Store-only restriction, or assessment disabled) produces symptoms that look exactly like a packaging failure but affect every non-MAS app simultaneously — always check `spctl --status` and the device's System Policy profile before deep-diving into one specific package's signature.

- **`xattr -d com.apple.quarantine` and `xattr -cr` are diagnostic-only, never end-user guidance.** If stripping quarantine "fixes" the problem, that's confirmation of the real gap (missing/invalid signature or notarization) — the fix is closing that gap in the build pipeline, not normalizing a Gatekeeper bypass across the fleet.
