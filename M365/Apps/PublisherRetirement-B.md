# Microsoft Publisher Retirement (1 Oct 2026 / 13 Oct 2026) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

> **Source-confidence note (September 2026):** Microsoft Support article *Microsoft Publisher will no longer be supported after October 2026* (KB 5035623, updated 16 Sept 2026).
> - **1 October 2026:** Microsoft 365 subscribers can no longer access Publisher and can't open or edit `.pub` files in it. It stops being installable or downloadable from Microsoft 365.
> - **13 October 2026:** support ends for perpetual Publisher (2021 and earlier), alongside Office LTSC 2021 / Office 2021. Perpetual installs **keep working** unsupported.
> - **No Microsoft 365 app opens `.pub` files.** Microsoft's supported conversion path is Publisher → PDF (view), or PDF → Word (edit). Conversion needs a **working, licensed Publisher**, so it must be done **before 1 Oct** on subscription devices.
> - Microsoft publishes a sample bulk-conversion script (`Convert-PubFileToPDF.ps1`, COM automation of `Publisher.Application`).

---

## Triage

```powershell
# 1. Is Publisher installed, and is it subscription (C2R) or perpetual?
$c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
$c2r | Select-Object VersionToReport, ProductReleaseIds, UpdateChannel
Test-Path "$env:ProgramFiles\Microsoft Office\root\Office16\MSPUB.EXE"         # C2R x64
Test-Path "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\MSPUB.EXE"  # C2R x86

# 2. Is Publisher excluded in the C2R config (i.e. deliberately not installed)?
$c2r.PSObject.Properties | Where-Object Name -like '*ExcludedApps' | Select-Object Name, Value

# 3. Can Publisher still be automated here (needed for conversion)?
try { $p = New-Object -ComObject Publisher.Application; "COM OK: $($p.Version)"; $p.Quit() } catch { "COM FAIL: $($_.Exception.Message)" }

# 4. How many .pub files are on this device / share?
Get-ChildItem -Path "<path or \\server\share>" -Filter *.pub -File -Recurse -ErrorAction SilentlyContinue |
    Measure-Object Length -Sum | Select-Object Count, @{n='MB';e={[math]::Round($_.Sum/1MB,1)}}
```

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| `ProductReleaseIds` contains `O365ProPlusRetail` / `O365BusinessRetail` and MSPUB.EXE exists, **before 1 Oct** | Subscription Publisher still works — conversion window open | Fix 1 (inventory) → Fix 2 (convert) **now** |
| Same, **after 1 Oct** | Publisher gone or refuses to open files on the subscription device | Fix 4 (convert on a perpetual install) or Fix 5 (third-party) |
| `ProductReleaseIds` contains `ProPlus2021Volume`, `ProPlus2019Volume`, `Publisher2021Volume` etc. | Perpetual — keeps working after 13 Oct, unsupported | Use this device as the **conversion station** (Fix 4); plan exit |
| `ExcludedApps` includes `publisher` | Publisher deliberately never deployed | Only user files matter → Fix 1 |
| COM FAIL "class not registered" | Publisher not installed on this device | Run conversion elsewhere |
| User reports "Publisher won't open my flyer" after 1 Oct | Expected retirement behaviour — not a fault | Fix 3 (user comms + alternatives) and Fix 4 |
| Word shows garbled/rasterised layout after PDF → Word | Expected fidelity loss with graphics-heavy layouts | Keep PDF as the record copy; rebuild in Word/PowerPoint |
| Ticket asks to re-add Publisher to M365 Apps | Not possible for subscription after 1 Oct | Close with alternatives; perpetual licence only if business-critical |

---

## Dependency Cascade

<details><summary>What must be true to preserve a .pub file</summary>

```
.pub file located  (endpoint / file share / OneDrive / SharePoint / Teams files / email attachment)
    │
Working Publisher binary on the conversion machine
    ├── Subscription (M365 Apps C2R) ........ works until 30 Sept 2026 only
    └── Perpetual (2021/2019/2016 MSI or C2R-volume) ... keeps working, unsupported after 13 Oct 2026
        │
Windows PowerShell 5.1 (COM interop via GAC — PowerShell 7 fails to load Office interop by name)
        │
Publisher.Application COM → Document.ExportAsFixedFormat(pbFixedFormatTypePDF)
        │
PDF produced  ─── view/print forever (record copy)
        │
   (optional) Word opens PDF → .docx  ─── editable, layout fidelity NOT guaranteed
        │
Converted file written back next to the original / uploaded to SharePoint
```
</details>

---

## Diagnosis & Validation Flow

1. **Determine the Publisher licence type on the device**
   ```powershell
   (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue).ProductReleaseIds
   ```
   *Expected:* `O365...Retail` = subscription (loses Publisher 1 Oct). `...2021Volume`/`...2019Volume` = perpetual (keeps it). Empty = MSI Office or no Office. Check `HKLM:\SOFTWARE\Microsoft\Office\16.0\Registration` or Programs and Features.

2. **Inventory files** — run `Scripts/Get-PublisherRetirementReadiness.ps1 -Path <paths> [-IncludeM365Search]`.
   *Expected:* CSV of every `.pub` with path, size, modified date and owner. Zero rows = done.

3. **Test COM automation on the conversion station**
   ```powershell
   $pub = New-Object -ComObject Publisher.Application
   $doc = $pub.Open('C:\Temp\test.pub', $true)   # read-only
   $doc.ExportAsFixedFormat(2, 'C:\Temp\test.pdf')  # 2 = pbFixedFormatTypePDF
   $doc.Close(); $pub.Quit()
   Test-Path 'C:\Temp\test.pdf'
   ```
   *Expected:* `True`. Failure means licensing, activation or PowerShell edition. Use Windows PowerShell 5.1, not pwsh 7.

4. **Validate conversion output** — open a sample of PDFs. Confirm the page count and that fonts are embedded (PDF properties). Spot-check any Word conversions.

---

## Common Fix Paths

<details><summary>Fix 1 — Inventory every .pub file (before anything else)</summary>

```powershell
# File servers / local paths
.\Get-PublisherRetirementReadiness.ps1 -Path 'D:\Shares','\\fs01\Marketing'

# Plus SharePoint / OneDrive via Microsoft Search (needs Files.Read.All + Sites.Read.All, delegated)
.\Get-PublisherRetirementReadiness.ps1 -Path 'D:\Shares' -IncludeM365Search
```
Microsoft Search only returns files the **signed-in account can access** and that are indexed, so run it as an account with broad read access (e.g. an eDiscovery-scoped admin). For a guaranteed-complete SharePoint sweep, use a Purview content search for `filetype:pub` instead.
</details>

<details><summary>Fix 2 — Bulk convert to PDF (and optionally Word) while Publisher still works</summary>

```powershell
# Windows PowerShell 5.1 on a machine with working Publisher
.\Get-PublisherRetirementReadiness.ps1 -Path '\\fs01\Marketing' -Convert            # PDF next to each .pub
.\Get-PublisherRetirementReadiness.ps1 -Path '\\fs01\Marketing' -Convert -AlsoWord   # PDF + DOCX
```
- The script **skips** files whose target PDF already exists and never deletes the `.pub`.
- Keep the originals. A perpetual-Publisher machine can still open them later.
- For SharePoint-hosted files, sync the library with OneDrive, convert locally, and let sync upload the results.

**Rollback:** converted files are additive. Delete generated `.pdf`/`.docx` using the conversion log CSV if required.
</details>

<details><summary>Fix 3 — User communication + alternatives</summary>

Tell users: after 1 Oct Publisher is gone from Microsoft 365. Existing PDFs stay viewable. To create new material, use Word (newsletters, labels, envelopes, letterhead, forms, programs) or PowerPoint (posters, banners, signs), both backed by Microsoft Create templates. Point them to the Microsoft Support article's scenario table.
</details>

<details><summary>Fix 4 — After 1 Oct: convert on a perpetual Publisher "conversion station"</summary>

A device with perpetual Publisher 2021/2019/2016 keeps working after both dates, unsupported. Use one isolated, patched machine as a conversion station. Run Fix 2 there against files collected from users. Don't reintroduce perpetual Office fleet-wide. The whole suite goes out of support on 13 Oct 2026 (2021) or already has (2016/2019, 14 Oct 2025).
</details>

<details><summary>Fix 5 — No Publisher anywhere</summary>

Microsoft offers no in-box path. Options: third-party converters (Microsoft doesn't support them, so assess the data-handling risk before uploading client documents to any online converter), LibreOffice Draw (imports `.pub` with its own fidelity limits), or rebuild from a printed or PDF copy. Document the client's choice in the ticket.
</details>

<details><summary>Fix 6 — Remove Publisher cleanly / stop deploying it</summary>

For ODT-managed installs, add `<ExcludeApp ID="Publisher" />` to `config.xml` for new builds so images don't reference a retired app. Microsoft removes Publisher from subscription builds itself, so no uninstall is needed for C2R. Update Intune Microsoft 365 Apps app definitions (excluded apps) to match.
</details>

---

## Escalation Evidence

```
== Microsoft Publisher Retirement — Escalation ==
Tenant / client:                <name>
Device / OS build:              <hostname> / <build>
Office product IDs:             <ProductReleaseIds>
Office version / channel:       <VersionToReport> / <channel>
MSPUB.EXE present:              <path or 'no'>
COM test result:                <OK / exact error>
PowerShell edition used:        <5.1 / 7.x>
Files inventoried / converted / failed:  <n> / <n> / <n>   (attach CSV)
Sample failing file + error:    <path> — <message>
Business-critical files with no PDF copy: <list>
Ask:                            <e.g. perpetual licence approval for conversion station>
```

---

## 🎓 Learning Pointers

- **Convert while you still can.** Every supported conversion path runs through Publisher itself. Once subscription Publisher is gone on 1 Oct, only perpetual installs can do it. [Microsoft Publisher will no longer be supported after October 2026](https://support.microsoft.com/en-us/publisher/microsoft-publisher-will-no-longer-be-supported-after-october-2026)
- **PDF is the record copy, Word is a starting point.** PDF → Word reflows complex layouts, so keep both and treat the DOCX as editable-but-approximate. [Document.ExportAsFixedFormat (Publisher VBA)](https://learn.microsoft.com/office/vba/api/publisher.document.exportasfixedformat)
- **Office COM automation needs Windows PowerShell 5.1.** PowerShell 7 can't resolve the Office interop assemblies from the GAC by name (reported against the community conversion scripts). Use numeric enum values (`2` = PDF) to avoid the interop dependency entirely.
- **13 Oct 2026 is a wider date.** Office LTSC 2021 and Office 2021 leave support on the same day. Check for other perpetual-Office stragglers while you're doing this. See `Deployment-UpdateChannels-A.md`.
- Community inventory + conversion scripts: [LazyAdmin — Publisher retires October 1](https://lazyadmin.nl/office-365/microsoft-publisher-retires-october-1-do-this-final-file-check/).
