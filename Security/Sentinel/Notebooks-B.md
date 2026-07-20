# Sentinel Notebooks (Jupyter / MSTICPy) — Hotfix Runbook (Mode B: Ops)
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

Notebooks run on an **Azure Machine Learning (AML) workspace** — a separate Azure resource from the Sentinel/Log Analytics workspace, with its own RBAC and network settings. Most "notebook won't launch" tickets are a permission or network gap on the AML side, not a Sentinel-side problem. Run these first.

```powershell
# 1. Confirm the user has a Sentinel role (Reader/Responder/Contributor — Contributor needed to save/launch)
$sentinelWs = Get-AzOperationalInsightsWorkspace -ResourceGroupName <SentinelRG> -Name <SentinelWorkspaceName>
Get-AzRoleAssignment -Scope $sentinelWs.ResourceId -SignInName <user@domain.com> |
    Where-Object { $_.RoleDefinitionName -like "*Sentinel*" }

# 2. Confirm the AML workspace exists and is provisioned
Get-AzResource -ResourceType "Microsoft.MachineLearningServices/workspaces" -ResourceGroupName <AMLResourceGroup> |
    Select-Object Name, ResourceGroupName, Location

# 3. Confirm the user has Contributor (or higher) on the AML workspace itself — separate grant from #1
$amlWs = Get-AzResource -ResourceType "Microsoft.MachineLearningServices/workspaces" -Name <AMLWorkspaceName> -ResourceGroupName <AMLResourceGroup>
Get-AzRoleAssignment -Scope $amlWs.ResourceId -SignInName <user@domain.com>

# 4. Check the AML workspace's default storage account for public network restrictions
#    (this is what actually blocks "Launch notebook" working directly from Sentinel)
$amlStorageId = (Get-AzResource -ResourceId $amlWs.ResourceId).Properties.storageAccount
Get-AzStorageAccount -ResourceId $amlStorageId | Select-Object StorageAccountName, PublicNetworkAccess, NetworkRuleSet

# 5. Confirm a compute instance exists and is running (notebooks won't execute without one)
Get-AzResource -ResourceType "Microsoft.MachineLearningServices/workspaces/computes" -ResourceGroupName <AMLResourceGroup> |
    Where-Object { $_.Name -like "$AMLWorkspaceName/*" }
```

| Result | Meaning | Action |
|---|---|---|
| #1 shows no Sentinel role, or only Reader | User can't save/launch notebooks | Grant **Microsoft Sentinel Contributor** at the workspace scope |
| #2 returns nothing | No AML workspace linked yet | Walk user through **Notebooks > Configure Azure Machine Learning > Create a new AML workspace** in Sentinel/Defender portal |
| #3 shows no role assignment | AML-side RBAC missing — Sentinel role alone is NOT sufficient | Grant **Contributor** on the AML workspace (RG-level Owner/Contributor needed only to *create* a new workspace) |
| #4 `PublicNetworkAccess = Disabled` or a restrictive `NetworkRuleSet` | Direct in-portal launch from Sentinel will fail or be greyed out | Go to [Fix 3](#fix-3--private-endpointrestricted-storage-blocks-direct-launch) — manual template copy/upload workaround |
| #5 returns nothing, or state is `Stopped` | No compute to run cells on | User must create/start a compute instance inside AML Studio before running any cell |
| All four pass but notebook still won't run | Root cause is inside the notebook/kernel, not access | Continue to [Diagnosis & Validation Flow](#diagnosis--validation-flow) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Sentinel workspace (Log Analytics)
  │
  ├─ Sentinel RBAC role (Reader/Responder/Contributor)  ◄── gates: see/save/launch notebook templates
  │
  └─ Azure Machine Learning workspace (SEPARATE Azure resource, own resource group/subscription possible)
       │
       ├─ AML-workspace RBAC (Contributor to run; RG Owner/Contributor to create the workspace)  ◄── independent grant from Sentinel RBAC
       │
       ├─ Default storage account
       │    └─ PublicNetworkAccess / private endpoint config  ◄── gates: direct "Launch notebook" from Sentinel
       │         (if restricted → must manually copy template + upload in AML Studio instead)
       │
       ├─ Compute instance (Azure VM)  ◄── gates: any cell execution at all
       │    └─ Personal to the creator — other users need their own compute instance
       │
       └─ Kernel (Python 3.8 recommended, or 3.6)
            └─ MSTICPy package + msticpyconfig.yaml
                 ├─ Auth to the Microsoft Sentinel API (AzureCLI / AzureSentinelAPI provider)  ◄── gates: any KQL query from the notebook
                 └─ External data providers (VirusTotal, MaxMind GeoLite2, etc.)  ◄── gates: enrichment only, not core queries
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm which notebook type is in use.** Not every Sentinel notebook uses MSTICPy — the Credential Scanner notebooks and some PowerShell/C# examples don't. If the failing notebook doesn't use MSTICPy, skip straight to kernel/compute troubleshooting; MSTICPy config fixes won't apply.
   - Expected: title cell or first markdown cell states the notebook's purpose and dependencies.

2. **Run the RBAC/network triage commands above.** If either the Sentinel role or the AML workspace role is missing, or the storage account is network-restricted, fix that first — nothing downstream will work until access is sorted.

3. **Open the notebook and check for the "Ready" compute indicator** before running any cell. A cold compute instance can take several minutes to start on first use.
   - Expected: green "Ready" status at the top of the notebook page.
   - Bad: notebook accepts Run clicks but cells never complete, or throw kernel-connection errors — compute is still starting or is stopped.

4. **Run the initialization cell (`nbinit.init_notebook` / the Getting Started Guide's init cell) first, in order.** Configuration warnings about missing MSTICPy settings on a first run are **expected, not an error** — the config hasn't been populated yet.
   - Expected: warnings listed, notebook continues.
   - Bad: a hard exception that stops execution — usually a missing/corrupt `msticpyconfig.yaml`, see Fix 4.

5. **If a cell references a variable from an earlier cell and throws `NameError`**, the kernel was restarted (or cells were run out of order) and in-memory state — including auth tokens — was wiped.
   - Fix: re-run from the initialization/auth cells forward, not just the failing cell.

6. **If KQL queries return empty results but the same query works in the Sentinel/Defender portal**, the query provider's auth context or target workspace alias is wrong, not the query itself.
   - Validate: `msticpy.current_providers` lists the expected workspace alias and shows a connected state.

---
## Common Fix Paths

<details><summary>Fix 1 — Sentinel role present, AML role missing (or vice versa)</summary>

These are two **independent** RBAC grants — having one does not imply the other.

```powershell
# Grant Sentinel Contributor (lets the user save/launch notebook templates from Sentinel)
New-AzRoleAssignment -SignInName <user@domain.com> -RoleDefinitionName "Microsoft Sentinel Contributor" -Scope $sentinelWs.ResourceId

# Grant Contributor on the AML workspace (lets the user actually run notebooks once launched)
New-AzRoleAssignment -SignInName <user@domain.com> -RoleDefinitionName "Contributor" -Scope $amlWs.ResourceId
```

No rollback concern — these are additive read/write grants scoped to a single workspace each. Prefer scoping to the specific AML workspace, not the resource group, unless the user needs broader AML access.

</details>

<details><summary>Fix 2 — No AML workspace exists yet</summary>

Walk the user through in-portal creation (no PowerShell equivalent is documented for the Sentinel-initiated wizard):

1. Sentinel/Defender portal → **Notebooks** → **Configure Azure Machine Learning** → **Create a new AML workspace**.
2. Fill Subscription / Resource group / Workspace name / Region / Storage account / Key Vault / Application Insights / Container registry.
3. On the **Networking** tab, select **Enable public access from all networks** unless the org has a documented reason to restrict it (see Fix 3 if they do).
4. **Review + create.** Deployment can take several minutes.
5. Back in Sentinel **Notebooks**, if multiple AML workspaces exist, set one as default.

</details>

<details><summary>Fix 3 — Private endpoint/restricted storage blocks direct launch</summary>

If the AML workspace's storage account has private endpoints or restricted public network access, **"Launch notebook" from inside Sentinel will not work** — this is documented behavior, not a bug.

Workaround (manual copy path):
1. In Sentinel **Notebooks** → **Templates**, open the desired template and copy its content (or download the `.ipynb` from the [Sentinel GitHub repo](https://github.com/Azure/Azure-Sentinel-Notebooks/)).
2. Go directly to the AML Studio for that workspace (`https://ml.azure.com`).
3. Upload the notebook file into your user folder there.
4. Attach a compute instance and run it — the notebook works identically once inside AML Studio; only the one-click launch-from-Sentinel path is blocked.

Do not disable the storage account's network restrictions purely to work around this without security sign-off — it was very likely put there deliberately.

</details>

<details><summary>Fix 4 — MSTICPy config warnings / init failures</summary>

```python
# Re-run initialization explicitly and inspect what's missing
import msticpy
from msticpy.init import nbinit
nbinit.init_notebook(namespace=globals())
```

- Warnings about unset TI/GeoIP providers on a **first run** are expected — walk through **A Getting Started Guide For Microsoft Sentinel ML Notebooks** template to populate `msticpyconfig.yaml` via the `MpConfigEdit` tool, then **Save File**.
- If `msticpyconfig.yaml` is missing or corrupted and stored in the AML user folder, MSTICPy should auto-discover it; if it's stored elsewhere (or the user copied it from another machine), set the `MSTICPYCONFIG` environment variable to its full path and restart the Jupyter kernel — env var changes do not apply without a restart.

</details>

<details><summary>Fix 5 — TI/GeoIP enrichment returns null/blank, core queries work fine</summary>

Core Sentinel/KQL queries and enrichment lookups use **separate** credentials. A working query provider does not mean VirusTotal/MaxMind are configured.

1. Open `MpConfigEdit` → **Data Providers** tab.
2. Confirm a **VirusTotal** API key and a **MaxMind GeoLite2** license key are present (both require free sign-ups if the org hasn't set up paid accounts).
3. If using a VirusTotal Enterprise key, store it in Azure Key Vault rather than in plaintext in `msticpyconfig.yaml` — see the [MSTICPy Key Vault secrets guide](https://msticpy.readthedocs.io/en/latest/getting_started/msticpyconfig.html#specifying-secrets-as-key-vault-secrets).
4. **Save File**, then re-run the initialization cell.

</details>

<details><summary>Fix 6 — Package install works, then silently breaks after switching kernels</summary>

Switching between the Python 3.6 and 3.8 kernels in the same compute instance is a documented source of "package installed but not importable" failures when `!pip install` was used.

```python
# Correct approach — use the %pip line magic, not !pip
%pip install --upgrade msticpy
```

Or from a terminal in AML Studio:
```bash
conda activate azureml_py38
pip install --upgrade msticpy
```
Close the terminal and restart the kernel afterward for the change to take effect.

</details>

<details><summary>Fix 7 — Kernel restarted / cells run out of order, downstream cells fail</summary>

Restarting the kernel wipes all in-memory state, including authenticated query provider sessions — this is expected Jupyter behavior, not a Sentinel bug.

- Re-run the notebook from the **initialization and authentication cells forward**, in order.
- Do not skip cells "to save time" on first execution — later cells frequently depend on objects (`qry_prov`, `mpedit`, entity lookups) created earlier.

</details>

<details><summary>Fix 8 — Query provider connects but a specific query returns nothing</summary>

```python
# Confirm which workspace/provider is actually active
import msticpy
msticpy.current_providers
```

- If the alias/workspace shown doesn't match the intended Sentinel workspace, the **Autoload QueryProvs** tab in `MpConfigEdit` has the wrong workspace name, or `Auto-connect` picked up a stale default.
- Re-select the correct workspace in `MpConfigEdit` → **Autoload QueryProvs**, **Save Settings**, and re-run the init cell.

</details>

---
## Escalation Evidence

```
SENTINEL NOTEBOOK ISSUE — ESCALATION TEMPLATE
================================================
Client / Tenant:
Sentinel workspace name:
AML workspace name:
Affected user (UPN):

Sentinel RBAC role for user (from triage #1):
AML workspace RBAC role for user (from triage #3):
AML storage account PublicNetworkAccess setting (from triage #4):
Compute instance name + state (from triage #5):

Notebook name/template:
Uses MSTICPy? (Y/N):
Exact error text / screenshot attached:
Cell number where failure occurs:
Was init/auth cell run successfully first? (Y/N):

Steps already attempted:
1.
2.
3.

Escalating to: [Tier 3 / Sentinel platform team]
```

---
## 🎓 Learning Pointers
- The two-workspace model (Sentinel/Log Analytics + Azure Machine Learning) is the single biggest source of "it worked for me but not for my teammate" tickets on this topic — Sentinel RBAC and AML RBAC are two independent grants, exactly like the dual-permission gates documented elsewhere in this repo (compare [[EntraID/Troubleshooting/AccessReviews-B]] and Access Reviews' resource-type-specific RBAC table). Always check both before assuming a bug.
- Private-endpoint/restricted-storage blocking direct launch is documented, deliberate Microsoft behavior, not a defect — see [Hunt for security threats with Jupyter notebooks](https://learn.microsoft.com/en-us/azure/sentinel/notebooks-hunt#launch-a-notebook-in-your-azure-machine-learning-workspace).
- MSTICPy configuration warnings on a first run are normal — the fastest way to build the wrong mental model here is to treat a first-run warning as a fault and start "fixing" a working install.
- Compute instances are personal to their creator — a colleague not seeing "your" compute instance is not a permissions bug, it's by design.
- After **March 31, 2027**, Sentinel is Defender-portal-only; the Notebooks blade and the AML workspace launch flow both exist identically in the Defender portal today (`Microsoft Sentinel > Threat management > Notebooks`) — unlike some other Sentinel surfaces (compare Hunting's Azure-portal-only bookmark creation), there is no documented portal-parity gap for notebooks specifically as of this writing.
- Community background reading: [MSTICPy documentation](https://msticpy.readthedocs.io/) and the [Azure Sentinel Notebooks GitHub wiki](https://github.com/Azure/Azure-Sentinel-Notebooks/wiki/) for real-world sample notebooks and FAQs beyond what's in the official Learn docs.
