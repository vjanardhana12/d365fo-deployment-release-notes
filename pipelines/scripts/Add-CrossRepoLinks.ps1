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
$rows = @()
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
        $wiState = $wi.fields.'System.State'
        $wiUrl   = "$OrgUrl/$encProj/_workitems/edit/$($wi.id)"
        $prList  = ($otherRepoPrs | ForEach-Object {
            # If PR lives in a different project, show project/repo to disambiguate
            if ($_.ProjectName -ne $Project) {
                "[$($_.ProjectName)/$($_.RepoName) #$($_.PrId)]($($_.PrUrl))"
            } else {
                "[$($_.RepoName) #$($_.PrId)]($($_.PrUrl))"
            }
        }) -join '<br>'
        $rows += "| [$wiType #$($wi.id)]($wiUrl) | $wiTitle | **$wiState** | $prList |"
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No externally-fixed work items found. Skipping section."
    return
}

# --- 4. Append section to release notes (before "## Package Versions" if present, else at end) ---
$utf8 = New-Object System.Text.UTF8Encoding($false)
$content = [System.IO.File]::ReadAllText($ReleaseNotesPath, $utf8)

$section  = "## Externally-fixed Work Items`r`n`r`n"
$section += "> HUB work items resolved in this window whose code fix lives OUTSIDE this repo (typically Smartcore Foundation or an ISV). These changes feed into this build via NuGet auto-updates. PR column shows the originating PR when discoverable.`r`n`r`n"
$section += "| **Work Item** | **Title** | **State** | **Originating PR** |`r`n"
$section += "|---|---|---|---|`r`n"
$section += ($rows -join "`r`n") + "`r`n`r`n"

$pkgPattern = '(?m)^## Package Versions'
if ($content -match $pkgPattern) {
    $content = [regex]::Replace($content, $pkgPattern, ($section + '## Package Versions'), 1)
} else {
    $content += "`r`n" + $section
}

[System.IO.File]::WriteAllText($ReleaseNotesPath, $content, $utf8)
Write-Host "Added Externally-fixed Work Items section with $($rows.Count) row(s)."
