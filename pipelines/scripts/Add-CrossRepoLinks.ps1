<#
.SYNOPSIS
    Appends a "Cross-repo linked changes" section to the release notes markdown.

.DESCRIPTION
    For each work item closed/updated between the previous successful build of
    this pipeline and the current build, looks up associated PRs across ALL
    repos in the project. If any PR lives in a repo OTHER than the current
    build's repo, that work item + its cross-repo PRs are added to the notes.
    This surfaces SCF/ISV/foundation PRs in the HUB release notes (or vice-versa).

.PARAMETER ReleaseNotesPath
    Full path to the releaseNotes.md file to append to.

.PARAMETER OrgUrl
    e.g. https://dev.azure.com/carlsberggroup

.PARAMETER Project
    Azure DevOps project name, e.g. 1760-SmartCore-HUB

.PARAMETER CurrentRepoName
    Name of the repo the current build was sourced from (used to filter
    "other" repo PRs). Pass $(Build.Repository.Name) from the pipeline.

.PARAMETER DefinitionId
    The build definition id of THIS pipeline. Pass $(System.DefinitionId).

.PARAMETER CurrentBuildId
    The current build id. Pass $(Build.BuildId).

.PARAMETER AccessToken
    OAuth System.AccessToken from the pipeline.

.PARAMETER AreaPathFilter
    Optional WIQL filter on [System.AreaPath] UNDER. Defaults to project name.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ReleaseNotesPath,
    [Parameter(Mandatory=$true)][string]$OrgUrl,
    [Parameter(Mandatory=$true)][string]$Project,
    [Parameter(Mandatory=$true)][string]$CurrentRepoName,
    [Parameter(Mandatory=$true)][int]$DefinitionId,
    [Parameter(Mandatory=$true)][int]$CurrentBuildId,
    [Parameter(Mandatory=$true)][string]$AccessToken,
    [string]$AreaPathFilter
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path $ReleaseNotesPath)) {
    Write-Warning "Release notes file not found: $ReleaseNotesPath"
    return
}

# Normalize OrgUrl (Azure DevOps' System.CollectionUri has trailing slash)
$OrgUrl = $OrgUrl.TrimEnd('/')

$headers = @{ Authorization = "Bearer $AccessToken"; 'Content-Type' = 'application/json' }
$apiVer  = 'api-version=7.0'
$encProj = [System.Uri]::EscapeDataString($Project)

# --- 1. Find previous successful build of this pipeline ---
$prevBuildUrl = "$OrgUrl/$encProj/_apis/build/builds?definitions=$DefinitionId&statusFilter=completed&resultFilter=succeeded&`$top=2&queryOrder=finishTimeDescending&$apiVer"
try {
    $prevResp = Invoke-RestMethod -Uri $prevBuildUrl -Headers $headers -Method Get -ErrorAction Stop
} catch {
    Write-Warning "Failed to query previous builds: $($_.Exception.Message)"
    return
}

# Skip the current build (which may already be in the list if mid-run finished)
$prevBuild = $prevResp.value | Where-Object { $_.id -ne $CurrentBuildId } | Select-Object -First 1
if (-not $prevBuild) {
    Write-Host "No previous successful build found for definition $DefinitionId. Skipping cross-repo section."
    return
}
$sinceIso = $prevBuild.finishTime
Write-Host "Cross-repo window: since $sinceIso (build #$($prevBuild.id))"

# --- 2. WIQL: work items changed since previous build ---
# Note: NO state filter. Devs sometimes leave a WI in Active even after the SCF
# fix is merged; the fix has still shipped into HUB via NuGet bump, so we want
# the WI to surface in release notes regardless of state.
if (-not $AreaPathFilter) { $AreaPathFilter = $Project }
$wiql = @{
    query = "SELECT [System.Id] FROM WorkItems " +
            "WHERE [System.TeamProject] = '$Project' " +
            "AND [System.AreaPath] UNDER '$AreaPathFilter' " +
            "AND [System.ChangedDate] >= '$sinceIso' " +
            "AND [System.WorkItemType] IN ('Bug','Task','User Story','Product Backlog Item')"
} | ConvertTo-Json -Compress

$wiqlUrl = "$OrgUrl/$encProj/_apis/wit/wiql?$apiVer"
try {
    $wiqlResp = Invoke-RestMethod -Uri $wiqlUrl -Headers $headers -Method Post -Body $wiql -ErrorAction Stop
} catch {
    Write-Warning "WIQL query failed: $($_.Exception.Message)"
    return
}

if (-not $wiqlResp.workItems -or $wiqlResp.workItems.Count -eq 0) {
    Write-Host "No work items closed since previous build. Skipping cross-repo section."
    return
}

# --- 3. Batch-fetch work items WITH relations ---
$ids = $wiqlResp.workItems | ForEach-Object { $_.id }
$candidates = @()
$batchSize = 200
for ($i = 0; $i -lt $ids.Count; $i += $batchSize) {
    $chunk = $ids[$i..([Math]::Min($i + $batchSize - 1, $ids.Count - 1))]
    $body = @{ ids = $chunk; '$expand' = 'relations' } | ConvertTo-Json -Compress
    $batchUrl = "$OrgUrl/$encProj/_apis/wit/workitemsbatch?$apiVer"
    try {
        $batchResp = Invoke-RestMethod -Uri $batchUrl -Headers $headers -Method Post -Body $body -ErrorAction Stop
    } catch {
        Write-Warning "Work item batch fetch failed: $($_.Exception.Message)"
        continue
    }

    foreach ($wi in $batchResp.value) {
        $prRelations = @($wi.relations | Where-Object { $_.rel -eq 'ArtifactLink' -and $_.url -like '*PullRequestId*' })
        if (-not $prRelations) { continue }

        $otherRepoPrs = @()
        foreach ($rel in $prRelations) {
            # Only consider PR links attached recently enough to be relevant. A strict
            # "link must post-date previous build" filter dropped fixes whose PR was linked
            # in the hours just BEFORE a build cut-off but whose WI was only state-updated
            # AFTER (so the WI passed the WIQL ChangedDate filter, but every PR link was
            # older than sinceIso). Use a 14-day grace window: catches near-miss links while
            # still keeping ancient PRs out of the list when someone state-nudges an old WI.
            $relDate = $null
            if ($rel.attributes) {
                if ($rel.attributes.authorizedDate)        { $relDate = $rel.attributes.authorizedDate }
                elseif ($rel.attributes.resourceCreatedDate) { $relDate = $rel.attributes.resourceCreatedDate }
            }
            if ($relDate) {
                try { if ([datetime]$relDate -lt ([datetime]$sinceIso).AddDays(-14)) { continue } } catch { }
            }

            # url format: vstfs:///Git/PullRequestId/{projectId}%2F{repoId}%2F{prId}
            if ($rel.url -match 'vstfs:///Git/PullRequestId/([^/]+)') {
                $parts = $Matches[1] -split '%2F'
                if ($parts.Count -eq 3) {
                    $projectGuid = $parts[0]; $repoGuid = $parts[1]; $prId = $parts[2]
                    # Resolve repo name + owning project name (PR may live in a different ADO project, e.g. SCF)
                    $repoUrl = "$OrgUrl/_apis/git/repositories/$repoGuid`?$apiVer"
                    $repoName = $repoGuid
                    $prProjectName = $Project
                    try {
                        $repoResp = Invoke-RestMethod -Uri $repoUrl -Headers $headers -Method Get -ErrorAction Stop
                        $repoName      = $repoResp.name
                        if ($repoResp.project -and $repoResp.project.name) { $prProjectName = $repoResp.project.name }
                    } catch { }
                    if ($repoName -ne $CurrentRepoName) {
                        $encPrProj = [System.Uri]::EscapeDataString($prProjectName)
                        $prUrl     = "$OrgUrl/$encPrProj/_git/$repoName/pullrequest/$prId"
                        $otherRepoPrs += [pscustomobject]@{ ProjectName = $prProjectName; RepoName = $repoName; PrId = $prId; PrUrl = $prUrl }
                    }
                }
            }
        }

        # Only list HUB WIs that were fixed by a non-HUB-repo PR merged in this window.
        # HUB-only PRs are already covered by built-in sections, so skip them here.
        if ($otherRepoPrs.Count -eq 0) { continue }

        $wiType  = $wi.fields.'System.WorkItemType'
        $wiTitle = $wi.fields.'System.Title' -replace '\|','\|'
        $wiUrl   = "$OrgUrl/$encProj/_workitems/edit/$($wi.id)"
        # Pretty PR list: "[SCF #21974](url), [SCF #21983](url)"
        $prList  = ($otherRepoPrs | Sort-Object PrId -Unique | ForEach-Object {
            $shortRepo = if ($_.RepoName -match '^\d+-?[Ss]martcore-?[Ff]oundation$') { 'SCF' } else { $_.RepoName }
            "[$shortRepo #$($_.PrId)]($($_.PrUrl))"
        }) -join ', '
        # Title cell suffixed with an italic "fix in" note so the cross-repo PRs are visible
        # without needing a separate section.
        $titleCell = "$wiTitle<br>_(fix in $prList)_"
        $candidates += [pscustomobject]@{
            Id        = $wi.id
            Type      = $wiType
            Url       = $wiUrl
            TitleCell = $titleCell
            Fields    = $wi.fields
        }
    }
}

if ($candidates.Count -eq 0) {
    Write-Host "No externally-fixed work items found. Nothing to merge."
    return
}

# --- 4. Merge candidates into existing sections of the release notes ---------
# Strategy: each WI is appended into the section that matches its WorkItemType
# (Bug -> Bugs, Task -> Tasks, etc.). Avoids a separate "Externally-fixed"
# section -- developers see the SCF/ISV PR right next to the WI in its natural
# section. If the section currently contains only the italic empty-state line
# (collapsed by the CI cleanup pass), the table is rebuilt from the per-type
# schema below.

$utf8    = New-Object System.Text.UTF8Encoding($false)
$content = [System.IO.File]::ReadAllText($ReleaseNotesPath, $utf8)

# Per-type section heading + column schema. Cell builder receives the WI fields
# hash; returns an ordered array of cell values (ID + Title prepended by render).
$sectionSpec = @{
    'Bug' = @{
        Heading = '## Bugs'
        Header  = '| **ID** | **Title** | **Severity** | **Priority** | **Originated From** | **Found in environment** |'
        Sep     = '|--------|-----------|--------------|--------------|---------------------|--------------------------|'
        Cells   = { param($f) @(
            ($f.'Microsoft.VSTS.Common.Severity'),
            ($f.'Microsoft.VSTS.Common.Priority'),
            ($f.'Custom.OriginatedFrom'),
            ($f.'Custom.FoundInEnvironment_MicrosoftServices')
        ) }
    }
    'Task' = @{
        Heading = '## Tasks'
        Header  = '| **ID** | **Title** | **Area** | **Iteration** | **Tags** |'
        Sep     = '|--------|-----------|----------|---------------|----------|'
        Cells   = { param($f) @(
            ($f.'System.AreaPath' -replace '^[^\\]+\\',''),
            ($f.'System.IterationPath' -replace '^[^\\]+\\',''),
            ($f.'System.Tags')
        ) }
    }
    'User Story' = @{
        Heading = '## User Stories'
        Header  = '| **ID** | **Title** | **Area** | **Iteration** | **Tags** |'
        Sep     = '|--------|-----------|----------|---------------|----------|'
        Cells   = { param($f) @(
            ($f.'System.AreaPath' -replace '^[^\\]+\\',''),
            ($f.'System.IterationPath' -replace '^[^\\]+\\',''),
            ($f.'System.Tags')
        ) }
    }
    'Product Backlog Item' = @{
        Heading = '## User Stories'
        Header  = '| **ID** | **Title** | **Area** | **Iteration** | **Tags** |'
        Sep     = '|--------|-----------|----------|---------------|----------|'
        Cells   = { param($f) @(
            ($f.'System.AreaPath' -replace '^[^\\]+\\',''),
            ($f.'System.IterationPath' -replace '^[^\\]+\\',''),
            ($f.'System.Tags')
        ) }
    }
    'Document Deliverable' = @{
        Heading = '## Document Deliverables'
        Header  = '| **ID** | **Title** | **Area** | **Iteration** | **Tags** |'
        Sep     = '|--------|-----------|----------|---------------|----------|'
        Cells   = { param($f) @(
            ($f.'System.AreaPath' -replace '^[^\\]+\\',''),
            ($f.'System.IterationPath' -replace '^[^\\]+\\',''),
            ($f.'System.Tags')
        ) }
    }
}

# Group candidates by destination section
$byHeading = @{}
$unhandled = @()
foreach ($c in $candidates) {
    if ($sectionSpec.ContainsKey($c.Type)) {
        $spec = $sectionSpec[$c.Type]
        if (-not $byHeading.ContainsKey($spec.Heading)) { $byHeading[$spec.Heading] = @() }
        $byHeading[$spec.Heading] += [pscustomobject]@{ Candidate = $c; Spec = $spec }
    } else {
        $unhandled += $c
    }
}

$mergedCount = 0
foreach ($heading in $byHeading.Keys) {
    $entries = $byHeading[$heading]
    $spec    = $entries[0].Spec
    # Build the new row strings (skip WIs whose ID is already present in the section to avoid dupes)
    $rxHeading = [regex]::Escape($heading)
    if ($content -notmatch "(?ms)^$rxHeading\s*\r?\n") {
        Write-Host "Section '$heading' not found in release notes -- skipping $($entries.Count) cross-repo WI(s)."
        $unhandled += ($entries | ForEach-Object { $_.Candidate })
        continue
    }

    # Extract the section block (heading to next "## " or EOF)
    $sectionRx = [regex]"(?ms)(^$rxHeading\s*\r?\n)(.*?)(?=\r?\n## |\z)"
    $m = $sectionRx.Match($content)
    if (-not $m.Success) { continue }
    $sectionBody = $m.Groups[2].Value

    $newRows = @()
    foreach ($e in $entries) {
        $c = $e.Candidate
        # Skip if WI ID already present in this section (avoid duplicate row)
        if ($sectionBody -match "\[$($c.Id)\]\(") {
            Write-Host "  WI $($c.Id) already in $heading -- skipping (avoid dupe)."
            continue
        }
        $extraCells = & $spec.Cells $c.Fields
        $extraStr   = ($extraCells | ForEach-Object { if ($null -ne $_ -and "$_".Trim()) { "$_" } else { '-' } }) -join ' | '
        $newRows   += "| [$($c.Id)]($($c.Url)) | $($c.TitleCell) | $extraStr |"
    }
    if ($newRows.Count -eq 0) { continue }

    # Detect whether section currently has a real table (find separator line) or only the italic placeholder
    if ($sectionBody -match '(?m)^\|[\s\-:|]+\|\s*$') {
        # Real table exists -- append rows at end of body (just before the section terminator)
        $trimmed = $sectionBody.TrimEnd("`r","`n"," ","`t")
        $newBody = $trimmed + "`r`n" + ($newRows -join "`r`n") + "`r`n`r`n"
    } else {
        # Section is the collapsed italic placeholder -- rebuild as a fresh table
        $newBody = "`r`n" + $spec.Header + "`r`n" + $spec.Sep + "`r`n" + ($newRows -join "`r`n") + "`r`n`r`n"
    }
    $content = $content.Substring(0,$m.Index) + $m.Groups[1].Value + $newBody + $content.Substring($m.Index + $m.Length)
    $mergedCount += $newRows.Count
    Write-Host "Merged $($newRows.Count) cross-repo WI(s) into '$heading'."
}

# Catch-all section for any unhandled WI types (Feature, Epic, Issue, etc.)
if ($unhandled.Count -gt 0) {
    $fallbackRows = $unhandled | ForEach-Object {
        "| [$($_.Type) #$($_.Id)]($($_.Url)) | $($_.TitleCell) |"
    }
    $fb  = "`r`n## Externally-fixed Work Items (other types)`r`n`r`n"
    $fb += "| **Work Item** | **Title** |`r`n|---|---|`r`n"
    $fb += ($fallbackRows -join "`r`n") + "`r`n`r`n"
    $pkgPattern = '(?m)^## Package Versions'
    if ($content -match $pkgPattern) {
        $content = [regex]::Replace($content, $pkgPattern, ($fb + '## Package Versions'), 1)
    } else {
        $content += $fb
    }
    Write-Host "Added fallback section with $($unhandled.Count) other-type WI(s)."
}

[System.IO.File]::WriteAllText($ReleaseNotesPath, $content, $utf8)
Write-Host "Cross-repo merge complete: $mergedCount inline row(s) merged into typed sections."
