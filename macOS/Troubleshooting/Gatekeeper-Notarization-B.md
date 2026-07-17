# macOS Gatekeeper / Notarization — Hotfix Runbook (Mode B: Ops)
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

This runbook covers **custom/internally-packaged `.pkg` and `.app` deployments blocked by Gatekeeper** — "can't be opened because it is from an unidentified developer," "the application is damaged," or the app installs via Intune but refuses to launch. This is distinct from `Compliance-Policies-A.md`'s use of `spctl --status` as a pass/fail compliance signal, and from general Intune app-deployment failures unrelated to code signing — this file is specifically about **why macOS itself refuses to run something Intune successfully delivered.**

```bash
# 1. Is Gatekeeper globally enabled, and what policy is it enforcing?
spctl --status
spctl --status --verbose 2>&1

# 2. Assess the specific app/package Gatekeeper is blocking
spctl -a -vvv /Applications/<YourApp>.app
# or for a .pkg before/after install
spctl -a -vvv -t install /path/to/YourInstaller.pkg

# 3. Check code signature validity
codesign -dv --verbose=4 /Applications/<YourApp>.app 2>&1

# 4. Check package signature (installer packages specifically)
pkgutil --check-signature /path/to/YourInstaller.pkg

# 5. Check whether the quarantine attribute is present (only set on files that
#    crossed a "trust boundary" — browser download, AirDrop, email attachment;
#    MDM-delivered installs from Intune's own agent typically do NOT set this)
xattr -p com.apple.quarantine /Applications/<YourApp>.app 2>&1
```

| Result | Interpretation |
|---|---|
| `spctl --status` reports "assessments disabled" | Gatekeeper is fully off — this device won't block anything, so a "Gatekeeper blocked my app" report from this device is describing something else (a different error) |
| `spctl -a -vvv` returns `rejected` with `source=Unnotarized Developer ID` or `source=No Usable Signature` | Confirms Gatekeeper is the actual blocker — go to Fix 1 (unsigned) or Fix 2 (unnotarized) below |
| `codesign -dv` errors with "code object is not signed at all" | Package/app has no signature whatsoever — Fix 1 |
| `pkgutil --check-signature` reports "Status: no signature" on an installer that DID install successfully via Intune | The install itself can still succeed (MDM-pushed installs largely bypass the interactive Gatekeeper prompt), but the app will be blocked the moment a user tries to open it manually or macOS re-evaluates it — Fix 1 |
| `xattr -p com.apple.quarantine` shows a value on a file delivered via Intune's own LOB app mechanism | Unusual — Intune-delivered LOB installs typically do not carry quarantine, since they don't cross a browser/AirDrop trust boundary; if present, something else (a script, a manual copy step) touched the file after delivery — investigate the deployment script, not Gatekeeper policy |
| App opens fine when double-clicked by an admin locally but is blocked for standard users | Gatekeeper evaluation and the resulting "remembered as trusted" state is **per-user**, not system-wide, for the interactive override path — see Fix 3 |
| Intune reports the install itself as failed (not just "won't open") | This is a packaging/signing problem at install time, not a Gatekeeper-at-launch problem — see `pkgutil --check-signature` first and cross-reference general Intune macOS app deployment error codes before assuming Gatekeeper |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
System-wide Gatekeeper policy allows the app's trust category
(configured via Settings Catalog "System Policy" — Allow Identified
Developers + Enable Assessment; NOT disabled fleet-wide)
        │
Package/app is signed with a valid, non-revoked Apple Developer ID
        │      (Developer ID INSTALLER cert signs .pkg files;
        │       Developer ID APPLICATION cert signs .app bundles —
        │       these are two different certificate types, a common
        │       source of "it's signed but still blocked" confusion)
        │
Package/app is notarized by Apple (submitted, scanned, ticket issued)
        │      (MDM-delivered installs can often complete WITHOUT
        │       notarization since the interactive Gatekeeper prompt
        │       is bypassed at install time — but the app can still
        │       be blocked the moment it's launched or re-evaluated,
        │       especially after being moved, re-copied, or if it
        │       later acquires a quarantine attribute)
        │
Notarization ticket is either stapled to the app/pkg, or reachable
via Apple's online notarization-check service at evaluation time
        │
Gatekeeper's on-device assessment (spctl) evaluates the above and
allows execution — result may be cached per-user after a manual
override ("Open Anyway")
```

**MDM-pushed installs and manual user launches evaluate differently.** Intune's macOS agent installing a `.pkg` via MDM largely sidesteps the interactive "unidentified developer" prompt a user would see double-clicking the same file from Finder — this is why an unsigned/unnotarized package can appear to "work" during Intune deployment testing, then generate a wave of tickets once real users try to open the resulting app themselves.

</details>

---
## Diagnosis & Validation Flow

**1. Confirm Gatekeeper's system-wide policy state**
```bash
spctl --status
```
Expected: `assessments enabled`. If disabled, Gatekeeper isn't the blocker for anything on this device right now — look elsewhere for the reported symptom.

**2. Assess the specific blocked item**
```bash
spctl -a -vvv /Applications/<YourApp>.app
```
Expected on a healthy app: `accepted`, `source=Notarized Developer ID` (or `source=Apple System` / `source=Mac App Store` for Apple/MAS-distributed software). Bad: `rejected`, with a `source=` value indicating why — this is the authoritative answer to "what exactly is Gatekeeper unhappy about."

**3. Confirm code signature validity independent of Gatekeeper's opinion**
```bash
codesign -dv --verbose=4 /Applications/<YourApp>.app 2>&1
```
Expected: `Authority=Developer ID Application: <Org Name> (<TeamID>)` chain, with `TeamIdentifier=` populated. Bad: "code object is not signed at all," or a broken/adhoc signature.

**4. Confirm installer package signature (if the failure is at install time, not launch time)**
```bash
pkgutil --check-signature /path/to/YourInstaller.pkg
```
Expected: `Status: signed by a certificate trusted by macOS` with `Developer ID Installer` in the chain. Bad: `Status: no signature`, or a chain that doesn't include a currently-valid Developer ID Installer certificate.

**5. Check for a quarantine attribute and its origin**
```bash
xattr -p com.apple.quarantine /Applications/<YourApp>.app 2>&1
mdls -name kMDItemWhereFroms /Applications/<YourApp>.app 2>&1
```
Interpretation: a quarantine flag records where the file crossed a trust boundary (browser download URL, AirDrop, Mail). Its *presence* on an Intune-delivered app is the actual signal worth chasing — it means something other than Intune's own install mechanism touched the file.

**6. Confirm notarization status directly**
```bash
spctl -a -vvv -t install /path/to/YourInstaller.pkg
# "source=Notarized Developer ID" = notarized and stapled/verified online
# "source=Unnotarized Developer ID" = signed correctly, but NOT notarized
```

---
## Common Fix Paths

<details>
<summary>Fix 1 — Package/app has no valid Developer ID signature</summary>

**Scenario:** `codesign -dv` or `pkgutil --check-signature` reports no signature, or an untrusted/expired one.

```bash
# Confirm current state
codesign -dv --verbose=4 /Applications/<YourApp>.app 2>&1
pkgutil --check-signature /path/to/YourInstaller.pkg
```

Two distinct certificate types are required and are frequently confused:
- **Developer ID Application** — signs the `.app` bundle itself.
- **Developer ID Installer** — signs the `.pkg` installer wrapping it.

If the package is unsigned, sign it with the correct Installer certificate:
```bash
productsign --sign "Developer ID Installer: <Org Name> (<TeamID>)" Unsigned.pkg Signed.pkg
pkgutil --check-signature Signed.pkg   # confirm before redeploying
```

If the underlying `.app` itself is unsigned (common when repackaging a third-party tool that ships without one), that requires re-signing the app bundle with a Developer ID Application certificate — a build/packaging-pipeline fix, not something correctable at the `.pkg` layer alone.

**Rollback:** N/A — signing is additive; re-upload the newly-signed package to Intune as a new app version.

</details>

<details>
<summary>Fix 2 — Signed but not notarized (blocked on user launch, not on MDM install)</summary>

**Scenario:** `spctl -a -vvv` reports `source=Unnotarized Developer ID` — correctly signed, but Apple never scanned and issued a notarization ticket.

MDM-pushed installs can frequently complete even without notarization, which is why this often surfaces as "Intune says it installed fine, but users can't open it" rather than as an install failure.

```bash
# Submit for notarization (requires an App Store Connect API key or Apple ID app-specific
# password configured in your build environment — outside Intune's scope)
xcrun notarytool submit YourInstaller.pkg --keychain-profile "<profile-name>" --wait

# Once notarization succeeds, staple the ticket so offline/first-launch checks succeed
# without needing to reach Apple's servers
xcrun stapler staple YourInstaller.pkg

# Verify
spctl -a -vvv -t install YourInstaller.pkg
```

**Rollback:** N/A — notarization/stapling is additive; redeploy the stapled package as a new app version in Intune.

</details>

<details>
<summary>Fix 3 — Works for admin/tester, blocked for standard users</summary>

**Scenario:** An admin manually approved the app once via "Open Anyway" in System Settings, masking the underlying signing/notarization gap for their own session.

Gatekeeper's manual-override "remembered trust" is scoped **per user**, not system-wide. A local admin clicking through the prompt once does not fix the experience for every other user on that Mac, or for the same app on other Macs.

```bash
# Confirm this is truly a per-user override situation vs. a genuine fix
spctl -a -vvv /Applications/<YourApp>.app
```
If this still reports `rejected` regardless of who's logged in, the underlying signing/notarization problem is unresolved — go to Fix 1/Fix 2. Don't treat one admin's successful manual launch as proof the deployment is fixed.

**Rollback:** N/A — diagnostic distinction, not a change.

</details>

<details>
<summary>Fix 4 — Fleet-wide Gatekeeper policy is more restrictive than intended</summary>

**Scenario:** A Settings Catalog "System Policy" profile has tightened Gatekeeper beyond what a legitimately signed-and-notarized internal app needs (e.g. App Store-only), or `EnableAssessment` is set in a way that unexpectedly blocks everything.

```bash
spctl --status --verbose 2>&1
sudo profiles -P | grep -iB2 -A15 "SystemPolicy\|Gatekeeper\|systempolicy.control"
```

If the tenant-wide policy is genuinely stricter than intended for a population that needs to run signed-and-notarized internal tools, this is a Settings Catalog scoping decision — narrow the restrictive profile's assignment, or confirm `AllowIdentifiedDevelopers` is `true` for the affected group, rather than trying to work around it per-device.

**Rollback:** Revert the Settings Catalog System Policy profile's assignment/values to their prior state if the tightened policy was applied in error.

</details>

<details>
<summary>Fix 5 — "The application is damaged and can't be opened" (quarantine + failed verification)</summary>

**Scenario:** macOS reports the app as damaged rather than simply untrusted — usually a quarantined file whose signature can no longer be verified (corrupted during transfer, or a since-revoked certificate).

```bash
# Confirm quarantine presence
xattr -p com.apple.quarantine /Applications/<YourApp>.app 2>&1

# Re-verify signature integrity
codesign -dv --verbose=4 /Applications/<YourApp>.app 2>&1
codesign --verify --deep --strict /Applications/<YourApp>.app 2>&1
```

If the signature itself fails `codesign --verify`, the file is genuinely corrupted or was tampered with in transit — re-deploy from a known-good source rather than attempting to repair the copy in place. **Do not** instruct end users to routinely run `xattr -d com.apple.quarantine` or `xattr -cr` as a standing workaround — this strips Gatekeeper's protection for that file entirely and should be treated as a controlled, one-time diagnostic action on a trusted, verified-source file only, never a standard fix procedure communicated broadly.

**Rollback:** N/A — re-deployment of a clean, verified package is the fix; there is nothing to roll back on the broken copy itself.

</details>

---
## Escalation Evidence

```
Device name / serial:
App/package name and version:
spctl --status output:
spctl -a -vvv result (accepted/rejected + source=):
codesign -dv output (Authority chain, TeamIdentifier):
pkgutil --check-signature output (for the installer):
Quarantine attribute present on the delivered file (Y/N):
Fails for all users or specific user(s)/admin only:
Intune app deployment status (installed successfully Y/N, error code if any):
Settings Catalog System Policy / Gatekeeper profile assigned to this device (Y/N, values):
Issue first observed:
Business impact (single app / multiple apps / fleet-wide):
```

---
## 🎓 Learning Pointers

- **MDM install success and Gatekeeper-at-launch are two separate evaluations.** Intune's macOS agent pushing a `.pkg` largely bypasses the interactive "unidentified developer" prompt a user would hit double-clicking the same file — so a genuinely unsigned or unnotarized package can install "successfully" via Intune and still be unusable the moment a real user tries to open it. Never treat "Intune shows Installed" as proof Gatekeeper won't be a problem. See: [Apple — Gatekeeper and runtime protection in macOS](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web) and [Apple — Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

- **Two certificate types, one common mix-up.** Developer ID *Application* signs `.app` bundles; Developer ID *Installer* signs `.pkg` files. Using the wrong one, or signing only one of the two layers, is one of the most frequent real-world causes of "it's signed, why is it still blocked" tickets — always check both independently with `codesign -dv` (app) and `pkgutil --check-signature` (pkg).

- **Notarization is technically optional for MDM installs, but not really optional for a good experience.** Apple's own guidance treats Developer ID signing as the hard requirement and notarization as best-practice-but-not-strictly-enforced for MDM-delivered content — in practice, skipping it just relocates the failure from "install time" (where Intune would surface an error) to "first launch time" (where a confused end user opens a ticket instead). Notarize and staple internal tooling as standard practice, not as an afterthought when tickets start arriving.

- **`xattr -d com.apple.quarantine` / `xattr -cr` are diagnostic tools, not a fix to hand to end users.** They bypass the exact protection Gatekeeper exists to provide. If removing quarantine "fixes" an app, that's confirmation of the underlying signing/notarization gap — go fix that at the source, don't operationalize the bypass.

- **Gatekeeper's manual "Open Anyway" override is per-user, not system-wide.** An admin successfully launching a flawed package once does not validate the deployment for the rest of the fleet — always re-test with `spctl -a -vvv` directly rather than trusting one person's ability to click through a warning.
