# Microsoft Publisher Retirement (1 Oct 2026 / 13 Oct 2026) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:** end of life for Microsoft Publisher in every form: Publisher for Microsoft 365 (subscription, Click-to-Run) and perpetual Publisher 2021/2019/2016/2013/2010. Also covers finding `.pub` content across an MSP client estate, bulk conversion through Publisher's COM object model, and what's left when conversion is no longer possible.

**Out of scope:** general Click-to-Run servicing (`Deployment-UpdateChannels-A.md`), Office LTSC 2024 (doesn't include Publisher), and Microsoft 365 Apps for Mac (Publisher was never available on macOS).

**Authoritative source:** Microsoft Support KB 5035623, *Microsoft Publisher will no longer be supported after October 2026* (updated 16 Sept 2026).

| Date | What changes |
|------|-------------|
| Feb 2024 | Retirement announced |
| 14 Oct 2025 | Office 2016 / 2019 (incl. Publisher 2016/2019) already out of support |
| **1 Oct 2026** | Publisher removed from Microsoft 365. Subscribers **can't access Publisher** or open/edit `.pub` in it. No longer installable/downloadable via M365 |
| **13 Oct 2026** | Perpetual Publisher support ends with Office LTSC 2021 / Office 2021. Perpetual installs **keep running**, unsupported |

---

## How It Works

<details><summary>Full architecture</summary>

### Why this is a data problem, not an app problem

`.pub` is a proprietary compound-document format. **Nothing else in Microsoft 365 reads it**: not Word, PowerPoint, Office for the web, OneDrive preview, SharePoint or Copilot. Once Publisher is gone the files become opaque blobs. They stay stored, synced, retained and discoverable, but nobody can render them. The retirement is really a **format-extinction event**. What you need to fix is the content, not the install.

### Subscription vs perpetual

```
Microsoft 365 Apps (C2R, ProductReleaseIds = O365ProPlusRetail / O365BusinessRetail / ...)
   └── Publisher delivered as part of the suite, licence evaluated against the M365 subscription
         └── 1 Oct 2026: removed / blocked  → conversion capability GONE on these devices

Perpetual (MSI or C2R-volume: ProPlus2021Volume, Standard2021Volume, Publisher2021Retail, ...)
   └── Publisher licensed by a perpetual key
         └── 13 Oct 2026: support ends, binary keeps working  → the ONLY post-1-Oct conversion engine
```

For most MSP clients on Business Premium / E3 / E5, **every** Publisher install is subscription. So the conversion window closes on 30 Sept 2026 unless somewhere in the estate has a perpetual copy.

### Conversion mechanics

Microsoft's sample `Convert-PubFileToPDF.ps1` and the EZAdmin script both drive the Publisher object model:

```
New-Object -ComObject Publisher.Application
   └── .Open(<path>, ReadOnly=$true)                → Publisher.Document
         └── .ExportAsFixedFormat(Format=2 [PDF], <out.pdf>)   (1 = XPS)
               └── .Close()
Word.Application
   └── .Documents.Open(<out.pdf>, ConfirmConversions=$false, ReadOnly=$true)   → PDF Reflow
         └── .SaveAs2(<out.docx>, 16)   (wdFormatDocumentDefault)
```

- **PDF** is high-fidelity: fixed layout, fonts embedded by default. Use it as the record copy.
- **PDF → Word** uses Word's PDF Reflow. Text and simple layout survive. Layered graphics, text wrapping and multi-column/linked text frames often don't. Microsoft says so explicitly.
- `Document.SaveAs` with `PbFileFormat` can also emit other formats (e.g. older `.pub` versions or image formats), but no PowerPoint or Word format exists natively.
- COM automation needs an **interactive-capable desktop session** and a licensed, activated Publisher. It won't run as SYSTEM through Intune in any reliable way. Run it on a conversion workstation as a user.
- **Windows PowerShell 5.1** resolves Office interop assemblies from the GAC. PowerShell 7 (.NET Core) generally can't load `Microsoft.Office.Interop.Publisher` by name. Pass raw enum integers and use 5.1.

### Where .pub files hide in an MSP estate

| Location | Discovery method | Notes |
|----------|------------------|-------|
| Local profiles (Desktop/Documents not redirected) | Endpoint scan (RMM / Remediation detection) | Often the last copies |
| On-prem file shares | `Get-ChildItem -Recurse -Filter *.pub` | Fast; NTFS owner ≈ creator |
| OneDrive / SharePoint / Teams files | Microsoft Search (`filetype:pub`), Purview content search | Search is permission-trimmed and index-dependent. Purview is exhaustive |
| Exchange attachments | Purview content search (`filetype:pub` in mailboxes) | Rarely worth converting; report only |
| Backups / archives | Out of scope for conversion | Record that restores will yield unreadable files |

</details>

---

## Dependency Stack

```
Layer 6  Business decision .... which files matter · record copy (PDF) vs editable (DOCX) vs rebuild
Layer 5  Output validation .... PDF opens, page count, fonts · DOCX spot-check
Layer 4  Conversion ........... Publisher COM ExportAsFixedFormat → PDF  (→ Word PDF Reflow → DOCX)
Layer 3  Runtime .............. Windows PowerShell 5.1 · interactive user session · file access
Layer 2  Engine ............... working licensed Publisher: subscription (≤ 30 Sept 2026) or perpetual
Layer 1  Inventory ............ every .pub located (shares, endpoints, SPO/OD, Teams)
```

If Layer 2 is missing, everything above it is impossible with Microsoft tooling.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Publisher missing from Start menu after 1 Oct | Retired from M365 build | `ProductReleaseIds` = O365* → expected |
| Publisher opens but says it can't be used / unlicensed after 1 Oct | Subscription licence no longer entitles Publisher | Expected; use a perpetual install for conversion |
| Double-clicking `.pub` opens nothing / "choose an app" | No handler after retirement | Expected; convert elsewhere or use PDF copy |
| `New-Object -ComObject Publisher.Application` → 80040154 class not registered | Publisher not installed on this machine | Test-Path MSPUB.EXE |
| COM works in 5.1 but fails in pwsh 7 | .NET Core interop resolution | Use `powershell.exe` |
| `ExportAsFixedFormat` → type mismatch | Enum passed by name without interop assembly | Pass integer `2` |
| Script hangs on a file | Publisher modal dialog (missing fonts, repair prompt, macro warning) hidden in background | Run with Publisher visible for that file; convert manually |
| Word asks "convert PDF to editable Word document?" and stalls | `DisplayAlerts` not suppressed / `ConfirmConversions` true | `$word.DisplayAlerts = 0`; `Documents.Open($pdf,$false,$true)` |
| DOCX looks wrong | PDF Reflow limitations | Expected; keep PDF; rebuild if editing is needed |
| Microsoft Search finds far fewer files than the share scan | Search is permission-trimmed/index-limited, or files aren't in M365 | Use Purview content search for completeness |
| Previews in SharePoint don't render `.pub` | Never supported | Convert |

---

## Validation Steps

1. **Install type**
   ```powershell
   (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue).ProductReleaseIds
   ```
   Good (for a conversion station): contains `2021`, `2019` or `2016` volume/retail IDs. Bad (after 1 Oct): only `O365*`.

2. **COM availability**
   ```powershell
   $p = New-Object -ComObject Publisher.Application; $p.Version; $p.Quit()
   ```
   Good: `16.0`. Bad: 80040154.

3. **PowerShell edition**
   ```powershell
   $PSVersionTable.PSEdition   # must be 'Desktop'
   ```

4. **Inventory completeness** — run `Get-PublisherRetirementReadiness.ps1` against every share and with `-IncludeM365Search`. Compare with a Purview content search count.

5. **Conversion result**
   ```powershell
   Import-Csv .\PublisherConversionLog_*.csv | Group-Object Status | Select-Object Name, Count
   ```
   Good: no `Failed`. Bad: any `Failed` row. Retry those manually with Publisher visible.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Scope (before 1 Oct).** Identify which clients have Publisher users at all. M365 usage reports don't break Publisher out, so use file inventory. Identify any perpetual Office installs; they're your post-deadline conversion engines.

**Phase 2 — Inventory.** Run the script against shares and M365 search. For SharePoint completeness, run a Purview **Content search** with the KQL `filetype:pub` across SharePoint and OneDrive, then export the report (not the content) to get locations.

**Phase 3 — Triage with the business.** Most hits are years-old one-off flyers. Get the client to mark each file keep-as-PDF, keep-editable (DOCX), or ignore. Don't bulk-convert 10,000 files nobody wants.

**Phase 4 — Convert.** On a conversion workstation with a working Publisher: `-Convert` (PDF) or `-Convert -AlsoWord`. For SharePoint content, sync the library with OneDrive and point `-Path` at the synced folder. Watch for files-on-demand hydration; files must download first, which takes time and disk space.

**Phase 5 — Stragglers after 1 Oct.** Route through a perpetual-Publisher workstation. If there isn't one, go to third-party/LibreOffice (see Playbook 4).

**Phase 6 — Close-out.** Remove Publisher from ODT `config.xml`, Intune M365 Apps definitions, onboarding documentation and software catalogues. Record that backups older than the conversion date contain `.pub` files that need a Publisher-capable machine to read.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Share-wide inventory and PDF conversion</summary>

```powershell
# Windows PowerShell 5.1, on a workstation with working Publisher, as a user with modify rights on the share
powershell.exe -NoProfile -File .\Get-PublisherRetirementReadiness.ps1 -Path '\\fs01\Marketing','\\fs01\Admin' -OutputPath C:\Temp\Pub
powershell.exe -NoProfile -File .\Get-PublisherRetirementReadiness.ps1 -Path '\\fs01\Marketing' -Convert -OutputPath C:\Temp\Pub
```
**Rollback:** outputs are new files. Remove them by feeding the `Pdf`/`Docx` columns of the conversion log to `Remove-Item`.
</details>

<details><summary>Playbook 2 — SharePoint / OneDrive content</summary>

1. Search: `-IncludeM365Search` (quick) or Purview content search `filetype:pub` (complete).
2. For each library that has hits, **Sync** it on the conversion workstation. Make the relevant folders *Always keep on this device*.
3. Run Playbook 1 against the synced path. The OneDrive client uploads the PDFs/DOCX next to the originals.
4. Optional: after sign-off, move the originals to an archive library instead of deleting them. Retention may block deletion anyway.
</details>

<details><summary>Playbook 3 — Endpoint discovery via Intune Remediation (detect-only)</summary>

Detection script (runs as user; exit 1 if any `.pub` under the profile):

```powershell
$hits = Get-ChildItem -Path $env:USERPROFILE -Filter *.pub -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\AppData\\' }
if ($hits) { Write-Output ("{0} .pub file(s): {1}" -f @($hits).Count, (($hits | Select-Object -First 5).Name -join '; ')); exit 1 }
Write-Output 'No .pub files'; exit 0
```
Set **Run this script using the logged-on credentials = Yes**. Don't attach a remediation script; the output column in the report is the inventory. Users then save files to OneDrive, where Playbook 2 picks them up.
</details>

<details><summary>Playbook 4 — No Publisher engine available</summary>

- **LibreOffice Draw** imports `.pub` (via libmspub). Open-source and local, so there are no data-residency concerns. Batch conversion: `soffice --headless --convert-to pdf --outdir <out> <file>.pub`. Fidelity is variable, so check the output visually.
- **Online converters:** Microsoft doesn't support them. Treat them as a data-sharing decision and get client sign-off before uploading anything with PII.
- **Rebuild:** use a PDF or printed copy and a Microsoft Create template in Word/PowerPoint.
</details>

<details><summary>Playbook 5 — Stop referencing Publisher in deployment config</summary>

```xml
<!-- ODT config.xml -->
<Product ID="O365ProPlusRetail">
  <Language ID="en-gb" />
  <ExcludeApp ID="Publisher" />
</Product>
```
Update the Intune *Microsoft 365 Apps for Windows 10 and later* app's excluded-apps list to match. **Rollback:** not applicable after retirement.
</details>

---

## Evidence Pack

```powershell
# Collect-PublisherEvidence.ps1 — run in Windows PowerShell 5.1 on the conversion workstation
$out = Join-Path $env:TEMP ("PublisherEvidence_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -f yyyyMMdd_HHmm))
New-Item $out -ItemType Directory -Force | Out-Null
$PSVersionTable | Out-String | Set-Content "$out\psversion.txt"
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue |
    Select-Object VersionToReport, ProductReleaseIds, UpdateChannel, Platform | Export-Csv "$out\c2r.csv" -NoTypeInformation
Get-ChildItem "$env:ProgramFiles\Microsoft Office","${env:ProgramFiles(x86)}\Microsoft Office" -Filter MSPUB.EXE -Recurse -ErrorAction SilentlyContinue |
    Select-Object FullName, @{n='Version';e={$_.VersionInfo.FileVersion}} | Export-Csv "$out\mspub.csv" -NoTypeInformation
try { $p = New-Object -ComObject Publisher.Application; "COM OK $($p.Version)" | Set-Content "$out\com.txt"; $p.Quit() }
catch { "COM FAIL $($_.Exception.Message)" | Set-Content "$out\com.txt" }
Get-WinEvent -LogName 'OAlerts' -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message | Export-Csv "$out\office-alerts.csv" -NoTypeInformation
Copy-Item .\PublisherInventory_*.csv, .\PublisherConversionLog_*.csv -Destination $out -ErrorAction SilentlyContinue
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Subscription or perpetual? | `(gp HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration).ProductReleaseIds` |
| Publisher binary | `Test-Path "$env:ProgramFiles\Microsoft Office\root\Office16\MSPUB.EXE"` |
| COM test | `$p = New-Object -ComObject Publisher.Application; $p.Version; $p.Quit()` |
| PS edition | `$PSVersionTable.PSEdition` (need `Desktop`) |
| Count .pub on a share | `gci \\srv\share -Filter *.pub -File -Recurse \| Measure-Object` |
| Single file → PDF | `$d=$p.Open('C:\f.pub',$true); $d.ExportAsFixedFormat(2,'C:\f.pdf'); $d.Close()` |
| Inventory | `.\Get-PublisherRetirementReadiness.ps1 -Path <paths> [-IncludeM365Search]` |
| Bulk convert | `.\Get-PublisherRetirementReadiness.ps1 -Path <paths> -Convert [-AlsoWord]` |
| Purview KQL | `filetype:pub` |
| LibreOffice fallback | `soffice --headless --convert-to pdf --outdir C:\out C:\in\f.pub` |
| ODT exclusion | `<ExcludeApp ID="Publisher" />` |

---

## 🎓 Learning Pointers

- **Format extinction beats app retirement.** Once no supported engine can read `.pub`, retention and backups just keep unreadable data. Converting the content is the real deliverable. [KB 5035623](https://support.microsoft.com/en-us/publisher/microsoft-publisher-will-no-longer-be-supported-after-october-2026)
- **Perpetual licences are your post-deadline safety net.** Find one and keep a single isolated conversion workstation until the client signs off that everything is converted.
- **The object model is small:** `Application.Open` → `Document.ExportAsFixedFormat` → `Close`. [Document.ExportAsFixedFormat](https://learn.microsoft.com/office/vba/api/publisher.document.exportasfixedformat) · [Document.SaveAs](https://learn.microsoft.com/office/vba/api/publisher.document.saveas)
- **Search vs Purview:** Microsoft Search is permission-trimmed and fast. A Purview content search is tenant-wide and complete. Use Purview when a client needs assurance. [Content search](https://learn.microsoft.com/en-us/purview/ediscovery-content-search)
- **13 Oct 2026 also ends Office LTSC 2021.** Use this project to find and plan the remaining perpetual Office installs. Community walkthrough: [LazyAdmin](https://lazyadmin.nl/office-365/microsoft-publisher-retires-october-1-do-this-final-file-check/).
