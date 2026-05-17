# D365 F&O Deployment Release Notes

Automated deployment release notes for **Dynamics 365 Finance & Operations** — published to Azure DevOps project wiki on every build, with live environment progress tracking.

## What it does

On every CI build, a wiki page is created with:

- **Work items** — User Stories, Document Deliverables, Tasks, Bugs, Configuration Deliverables linked to the build (with clickable ADO links)
- **Pull Requests** — who raised, source/target branch, who approved (🟢 / ✓)
- **Data Entity Changes** — new/modified/deleted entities and extensions with field-level detail
- **Package Versions** — all NuGet packages (Platform, Foundation, ISV) with versions
- **Deployment status strip** — compact `[Env1](url) 🟢 → [Env2](url) ⚪ → [Env3](url) ⚪` strip showing live deployment status per environment, updated by the release pipeline
- **Release link** — once deployed, `⏳ Awaiting deployment` flips to `[Release N](url) 🟢 _Deployed_`
- **Section-of-record layout** — every page renders the full set of sections (User Stories, Tasks, Bugs, Config Deliverables, Data Migration, Test Notes, Known Issues, Rollback Plan, Notes, Pull Requests) so reviewers always know what to look for; empty sections render a single `_No xxx linked to this build._` placeholder row
- **Legend** — 🟢 Deployed · 🟠 Partial · 🔴 Failed · ⚪ Pending

## Prerequisites

| Requirement | Details |
|---|---|
| **Azure DevOps project wiki** | Must be a _project wiki_ (not a code wiki). Create one via Project Settings → Wiki → Create project wiki. |
| **XplatGenerateReleaseNotes** | Free marketplace extension: [Generate Release Notes](https://marketplace.visualstudio.com/items?itemName=richardfennellBM.BM-VSTS-XplatGenerateReleaseNotes) |
| **WikiUpdaterTask** | Free marketplace extension: [Wiki Updater](https://marketplace.visualstudio.com/items?itemName=richardfennellBM.BM-VSTS-WIKIUpdater-Tasks) |
| **Build agent** | Must have `git` available (standard on Microsoft-hosted agents) |

## Setup (one-time)

### Step 1: Install marketplace extensions

Install both extensions from the links above into your Azure DevOps organization.

### Step 2: Create wiki folder structure

```powershell
.\setup\Setup-WikiStructure.ps1 `
    -Organization "https://dev.azure.com/yourorg" `
    -Project "YourProject" `
    -WikiName "YourProject.wiki"
```

This creates:
```
Deployment-release-notes/
├── Deployment-release-notes.md    (parent page)
├── .order
├── Main-branch.md
├── Prod-branch.md
├── Hotfix-branch.md
└── Release-branch.md
```

### Step 3: Grant build service permission

```powershell
.\setup\Grant-BuildPermission.ps1 `
    -Organization "https://dev.azure.com/yourorg" `
    -Project "YourProject"
```

This fixes the `TF401027: You need GenericContribute permission` error by granting the per-project build service identity **Contribute** access on the wiki git repository.

**What it does (REST API details):**
- Security namespace: `2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87` (Git Repositories)
- Token: `repoV2/<projectId>/<wikiRepoId>`
- Identity: `Microsoft.TeamFoundation.ServiceIdentity;<instanceId>:Build:<projectId>`
- Permission: `GenericContribute` (bit 4) = Allow

### Step 4: Add to your pipeline

Copy the template files into your repo and add the stage to your pipeline:

```yaml
stages:
- stage: Build
  # ... your existing build ...

- template: pipelines/release-notes-stage.yaml
  parameters:
    wikiRepoUrl: 'https://yourorg@dev.azure.com/yourorg/YourProject/_git/YourProject.wiki'
    branchFolder: 'Main-branch'
    templateFile: 'release-notes-template/release-notes-template.md'
    packagesConfigPaths: |
      $(Build.SourcesDirectory)\path\to\packages.config
    foundationPackagePattern: ''  # regex for your foundation packages
```

See [examples/pipeline-snippet.yaml](examples/pipeline-snippet.yaml) for a complete example.

### Step 5 (optional): Environment URLs

To make the strip entries `[Env](url) 🟢` clickable, pass `EnvUrlMapJson` to `Update-WikiReleaseNotes.ps1` in your release pipeline:

```powershell
.\Update-WikiReleaseNotes.ps1 `
    -Environment "DEV" `
    -WikiRepoUrlBase "https://dev.azure.com/yourorg/YourProject/_git/YourProject.wiki" `
    -EnvUrlMapJson '{"DEV":"https://myenv-dev.sandbox.operations.eu.dynamics.com/","UAT":"https://myenv-uat.sandbox.operations.eu.dynamics.com/"}'
```

### Step 6 (optional): Release pipeline integration

Add the `Update-WikiReleaseNotes.ps1` script as a task in each release stage to:
- Refresh the deployment-status strip with live status from `RELEASE_RELEASEID`
- Replace `⏳ Awaiting deployment` with `[Release N](url) 🟢 _Deployed_`

## File structure

```
├── release-notes-template/
│   └── release-notes-template.md   # Single unified Handlebars template
│                                  # (Commit blockquote conditionally rendered
│                                  #  on release/prod/hotfix branches; omitted
│                                  #  on main via `{{#unless (eq ...) }}`)
├── pipelines/
│   ├── release-notes-stage.yaml   # Reusable YAML stage template
│   └── scripts/
│       └── Update-WikiReleaseNotes.ps1   # Release pipeline script
├── setup/
│   ├── Setup-WikiStructure.ps1    # One-time wiki folder creation
│   └── Grant-BuildPermission.ps1  # One-time permission fix
└── examples/
    ├── pipeline-snippet.yaml      # Copy-paste snippet
    └── custom-template-example.md # How to add custom fields
```

## Customization

### Adding custom ADO fields

The generic template uses only standard ADO fields. To add project-specific fields:

1. Copy `release-notes-template/release-notes-template.md`
2. Add Handlebars expressions for your custom fields (see [examples/custom-template-example.md](examples/custom-template-example.md))
3. Common custom fields to add:
   - `Custom.OriginatedFrom` (Bug origin)
   - `Custom.FoundInEnvironment` (where the bug was found)
   - `Custom.ReleaseNote` / `Custom.RootCauseNotes` (release notes text)
   - Custom work item types (Document Deliverable, Configuration Deliverable)

### Single template for all branches

The one template handles all four branches via a single Handlebars conditional:

```handlebars
{{#unless (eq (replace buildDetails.sourceBranch "refs/heads/" "") "main")}}
> **Commit** [`{{substring buildDetails.sourceVersion 0 8}}`]({{buildDetails.repository.url}}/commit/{{buildDetails.sourceVersion}})
{{/unless}}
```

- On `main` builds the Commit blockquote is omitted (commit isn't meaningful for daily CD).
- On `release` / `prod` / `hotfix` branches it renders as a callout above the metadata table.

### Package categories

The enrichment step categorizes packages as:
- **Platform** — matches `Microsoft.Dynamics.*`
- **Foundation** — matches the `foundationPackagePattern` parameter (e.g., `Smartcore`)
- **ISV** — everything else

### Changing the folder name

Replace `Deployment-release-notes` in:
- `release-notes-stage.yaml` (filename + .order script)
- `Update-WikiReleaseNotes.ps1` (switch block)
- `Setup-WikiStructure.ps1` (folder + page names)

## How it works

```
Build Pipeline                              Release Pipeline
─────────────                               ─────────────────
1. XplatGenerateReleaseNotes                5. Update-WikiReleaseNotes.ps1
   → releaseNotes.md (from ADO WIs)           → Clone wiki
                                               → Query live release stages via REST
2. Enrich (inline PS)                          → Build deployment-status strip:
   → Package versions from packages.config         [Env1](url) 🟢 → [Env2](url) ⚪
   → Entity changes from git diff              → Flip ⏳ Awaiting →
                                                   [Release N](url) 🟢 _Deployed_
3. Cleanup (inline PS)                         → Push updated page
   → HTML decode + strip raw tags
   → Keep empty section placeholders         6. (Each stage updates the same page
                                                  with fresh strip status)
4. WikiUpdaterTask
   → Push page to project wiki
   → Sort .order (newest first)
```

## Safety

- **Non-blocking**: The entire ReleaseNotes stage is independent from the Build stage. Build failures don't affect release notes; release note failures don't affect builds.
- **`continueOnError: true`** on every wiki-related task — if the wiki publish fails, the build/deployment continues.
- **No secrets**: Uses `System.AccessToken` (auto-revoked after pipeline run).

## License

MIT — see [LICENSE](LICENSE).

## Author

**Vinod Kumar K J** — [github.com/vjanardhana12](https://github.com/vjanardhana12)
