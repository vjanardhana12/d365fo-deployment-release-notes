<#
.SYNOPSIS
    Updates the release-notes wiki page for a deployment stage and (optionally)
    auto-tags the build commit.

.DESCRIPTION
    Called by a Classic Release pipeline as a POST-deployment task on every
    stage. Responsibilities:

      1. Clone the project wiki repo using System.AccessToken (or a PAT).
      2. Locate the build's wiki release-note page (Build-<BuildNumber>.md)
         under the per-branch sub-folder (Main-branch / Prod-branch /
         Hotfix-branch / Release-branch).
      3. Replace the <!-- ENV-PROGRESS-BLOCK --> placeholder (first run) or
         the existing sentinel-bounded block (subsequent runs) with a fresh
         compact deployment-status strip built from the LIVE release stages
         queried via Azure DevOps REST API.
      4. Inject Tag / Compare cells into the metadata table.
      5. Inject a "Post-Deployment Actions" section listing manual-action
         categories (security, data entities, workflows, number sequences,
         financial dimensions, configuration keys, business events, batch jobs).
      6. Inject a "Priority Test Items" callout when S1/S2 bug fixes ship.
      7. Sort the Bugs table by Severity then Priority.
      8. Collapse empty-state placeholder tables to single italic lines.
      9. Re-attribute cherry-picked PRs to their original authors.
     10. Strip "(EXT)" suffix from author/reviewer cells.
     11. Substitute the "Awaiting deployment" placeholder with a link to the
         running release plus a "_Deployed_" suffix.
     12. Optionally create an annotated git tag on the build's source commit
         when a tag-triggering environment succeeds (UAT for release branch,
         SemVer for prod).
     13. Stage the file for the subsequent "Git based WIKI File Updater" task.

    Visual style:
        - Compact strip:  [DevTest](url) 🟢 -> [UAT](url) 🟢 -> [PROD](url) ⚪
        - Traffic-light icons:  🟢 succeeded  🟠 partiallySucceeded
                                🔴 failed     ⚪ pending
        - Sentinel markers used for safe re-replacement on subsequent stages:
            <!-- ENV-PROGRESS-START -->
            ...content...
            <!-- ENV-PROGRESS-END -->

    All emoji output uses [char]::ConvertFromUtf32 so the script is safe under
    Windows PowerShell 5.1 default encoding.

    Failure-tolerant: any unhandled exception is logged as a pipeline warning
    and the script exits 0 - a transient wiki/notes problem will NOT fail the
    deployment stage.

.PARAMETER Environment
    Environment name (fallback label when the release REST query fails).

.PARAMETER BuildNumber
    Build number to locate the wiki page. Default: $env:BUILD_BUILDNUMBER.

.PARAMETER SourceBranchName
    Branch of the triggering build. Default: $env:BUILD_SOURCEBRANCHNAME.

.PARAMETER WikiRepoUrlBase
    Wiki repo URL. Required. e.g.
    https://dev.azure.com/myorg/MyProject/_git/MyProject.wiki

.PARAMETER WikiBranch
    Wiki branch. Default: wikiMaster.

.PARAMETER TargetDir
    Clone directory. Default: $(System.DefaultWorkingDirectory)\wiki.

.PARAMETER Token
    Auth token. Default: $env:SYSTEM_ACCESSTOKEN.

.PARAMETER RepoName
    Name of the source code repository (NOT the wiki repo). Used to build the
    Compare / commit / diff URLs. e.g. "MyApp" for
    https://dev.azure.com/myorg/MyProject/_git/MyApp.
    Default: $env:BUILD_REPOSITORY_NAME.

.PARAMETER EnvUrlMapJson
    Optional JSON object mapping environment names to D365 URLs. Each strip
    entry becomes a clickable link if a URL is found.
    Example: '{"DEV":"https://myenv-dev.sandbox.operations.eu.dynamics.com/"}'

.PARAMETER CreateTag
    If $true, create an annotated tag on the build's source commit when this
    stage matches the per-branch tag-trigger. Default: $false.

.PARAMETER TagTriggerJson
    JSON object mapping branch -> stage that triggers tag creation.
    Default: '{"release":"UAT","prod":"PROD"}'
    Tag formats per branch:
        release -> uat-<buildNumber>
        prod    -> v<MAJOR.MINOR.PATCH> (SemVer; bump driven by $env:RELEASETYPE)
        other   -> build-<buildNumber>

.PARAMETER GitUserEmail
    Email used for the tag-creation git commits. Default: ado-pipeline@noreply.local.

.PARAMETER GitUserName
    Name used for the tag-creation git commits. Default: 'Azure DevOps Pipeline'.

.EXAMPLE
    .\Update-WikiReleaseNotes.ps1 -Environment "DEV" `
        -WikiRepoUrlBase "https://dev.azure.com/myorg/MyProject/_git/MyProject.wiki" `
        -RepoName "MyApp" `
        -EnvUrlMapJson '{"DEV":"https://myenv-dev.sandbox.operations.eu.dynamics.com/"}'

.NOTES
    Repository: https://github.com/vjanardhana12/d365fo-deployment-release-notes
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Environment,

    [string]$BuildNumber       = $env:BUILD_BUILDNUMBER,
    [string]$SourceBranchName  = $env:BUILD_SOURCEBRANCHNAME,
    [Parameter(Mandatory = $true)]
    [string]$WikiRepoUrlBase,
    [string]$WikiBranch        = "wikiMaster",
    [string]$TargetDir         = (Join-Path $env:SYSTEM_DEFAULTWORKINGDIRECTORY 'wiki'),
    [string]$Token             = $env:SYSTEM_ACCESSTOKEN,
    [string]$RepoName          = $env:BUILD_REPOSITORY_NAME,
    [string]$EnvUrlMapJson     = '',
    [bool]  $CreateTag         = $false,
    [string]$TagTriggerJson    = '{"release":"UAT","prod":"PROD"}',
    [string]$GitUserEmail      = 'ado-pipeline@noreply.local',
    [string]$GitUserName       = 'Azure DevOps Pipeline'
)

$ErrorActionPreference = 'Stop'

# Failure-tolerance: any unhandled exception is logged as a pipeline warning and
# the script exits 0 so a transient wiki problem does NOT fail the deployment.
trap {
    Write-Host "##vso[task.logissue type=warning]Update-WikiReleaseNotes failed (non-fatal): $($_.Exception.Message)"
    $placeholderDir = Join-Path $env:AGENT_TEMPDIRECTORY 'wiki-noop'
    if (-not (Test-Path $placeholderDir)) { New-Item -ItemType Directory -Path $placeholderDir -Force | Out-Null }
    $placeholderFile = Join-Path $placeholderDir 'noop.md'
    Set-Content -Path $placeholderFile -Value '# wiki update skipped' -Encoding UTF8
    Write-Host "##vso[task.setvariable variable=wikiFilePath]$placeholderFile"
    Write-Host "##vso[task.setvariable variable=wikiPagePath]noop.md"
    Write-Host "##vso[task.complete result=Succeeded;]Wiki update skipped due to non-fatal error - deployment is unaffected."
    exit 0
}

if ([string]::IsNullOrWhiteSpace($BuildNumber))      { throw "BuildNumber is required (env BUILD_BUILDNUMBER not set)." }
if ([string]::IsNullOrWhiteSpace($SourceBranchName)) { throw "SourceBranchName is required (env BUILD_SOURCEBRANCHNAME not set)." }
if ([string]::IsNullOrWhiteSpace($Token))            { throw "Token is required (enable System.AccessToken on the agent job)." }

Write-Host "=== Update-WikiReleaseNotes.ps1 ==="
Write-Host "Environment        : $Environment"
Write-Host "BuildNumber        : $BuildNumber"
Write-Host "SourceBranchName   : $SourceBranchName"
Write-Host "RepoName           : $RepoName"
Write-Host "CreateTag          : $CreateTag"

# --- Derive collection / project base URLs from pipeline env vars ------------
$collectionUri = if ($env:SYSTEM_COLLECTIONURI) { $env:SYSTEM_COLLECTIONURI.TrimEnd('/') } else { '' }
$projectName   = $env:SYSTEM_TEAMPROJECT
if ([string]::IsNullOrWhiteSpace($collectionUri) -or [string]::IsNullOrWhiteSpace($projectName)) {
    throw "SYSTEM_COLLECTIONURI / SYSTEM_TEAMPROJECT env vars must be set."
}
$projectBaseUri = "$collectionUri/$projectName"
$repoUriBase   = if ($RepoName) { "$projectBaseUri/_git/$RepoName" } else { $null }
$repoApiBase   = if ($RepoName) { "$projectBaseUri/_apis/git/repositories/$RepoName" } else { $null }

# --- Icons (encoding-safe via UTF-32 codepoints) -----------------------------
$IconDone    = [char]::ConvertFromUtf32(0x1F7E2)   # green circle
$IconPartial = [char]::ConvertFromUtf32(0x1F7E0)   # orange circle
$IconFailed  = [char]::ConvertFromUtf32(0x1F534)   # red circle
$IconPending = [char]::ConvertFromUtf32(0x26AA)    # white circle
$Arrow       = [char]::ConvertFromUtf32(0x2192)    # right arrow
$MidDot      = [char]::ConvertFromUtf32(0x00B7)    # middle dot

$BlockStart  = '<!-- ENV-PROGRESS-START -->'
$BlockEnd    = '<!-- ENV-PROGRESS-END -->'
$Placeholder = '<!-- ENV-PROGRESS-BLOCK -->'

# Parse env URL map
$script:EnvUrlMap = @{}
if (-not [string]::IsNullOrWhiteSpace($EnvUrlMapJson)) {
    try {
        $obj = $EnvUrlMapJson | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $script:EnvUrlMap[$p.Name.ToUpper()] = [string]$p.Value }
    } catch {
        Write-Host "WARN: EnvUrlMapJson could not be parsed: $($_.Exception.Message)"
    }
}

function Get-EnvUrl {
    param([string]$EnvName)
    if (-not $EnvName) { return $null }
    return $script:EnvUrlMap[$EnvName.ToUpper()]
}

function Get-StageIcon {
    param([string]$Status)
    switch -Wildcard ($Status) {
        'succeeded'          { return $IconDone }
        'partiallySucceeded' { return $IconPartial }
        'rejected'           { return $IconFailed }
        'canceled'           { return $IconFailed }
        'cancelled'          { return $IconFailed }
        'inProgress'         { return $IconPending }
        'queued'             { return $IconPending }
        'scheduled'          { return $IconPending }
        'notStarted'         { return $IconPending }
        default              { return $IconPending }
    }
}

# Parse tag-trigger map
$script:TagTriggers = @{}
try {
    $tt = $TagTriggerJson | ConvertFrom-Json
    foreach ($p in $tt.PSObject.Properties) { $script:TagTriggers[$p.Name.ToLower()] = [string]$p.Value }
} catch {
    Write-Host "WARN: TagTriggerJson could not be parsed: $($_.Exception.Message)"
}

# --- Derive wiki sub-folder from the triggering build's branch ----------------
switch -Wildcard ($SourceBranchName) {
    'prod'    { $wikiPath = 'Deployment-release-notes\Prod-branch\' }
    'main'    { $wikiPath = 'Deployment-release-notes\Main-branch\' }
    'hotfix*' { $wikiPath = 'Deployment-release-notes\Hotfix-branch\' }
    default   { $wikiPath = 'Deployment-release-notes\Release-branch\' }
}
Write-Host "Resolved wikiPath  : $wikiPath"

# --- Clone the wiki repo ------------------------------------------------------
$wikiCloneUrl = $WikiRepoUrlBase -replace '^https://', "https://buildagent:$Token@"

git --version | Out-Host
git config --global core.longpaths true | Out-Host

if (Test-Path $TargetDir) {
    Write-Host "Removing existing $TargetDir before fresh clone."
    Remove-Item -Path $TargetDir -Recurse -Force -ErrorAction SilentlyContinue
}

git clone --depth 1 --branch $WikiBranch $wikiCloneUrl $TargetDir
if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE." }

# --- Locate the wiki page -----------------------------------------------------
$relPath  = Join-Path $wikiPath ("Build-{0}.md" -f $BuildNumber)
$filePath = Join-Path $TargetDir $relPath
Write-Host "Looking for file   : $filePath"

if (-not (Test-Path $filePath)) {
    throw ("Wiki file not found: '{0}'. Check that the build's 'Publish release notes' step wrote 'Build-{1}.md' under '{2}'." -f $filePath, $BuildNumber, $wikiPath)
}

# --- Tag helpers --------------------------------------------------------------
function Should-CreateTag {
    param([string]$Branch, [string]$StageName)
    if (-not $StageName) { return $false }
    $expected = $script:TagTriggers[$Branch.ToLower()]
    if (-not $expected) {
        # Wildcard match for hotfix*
        foreach ($k in $script:TagTriggers.Keys) {
            if ($k.EndsWith('*') -and $Branch -like $k) { $expected = $script:TagTriggers[$k]; break }
        }
    }
    if (-not $expected) { return $false }
    return ($StageName.ToUpper() -eq $expected.ToUpper())
}

function Get-NextSemVer {
    param([string]$Token, [string]$RepoApiBase, [string]$RepoUriBase)
    # Records the previous v*.*.* tag in $script:PreviousSemVer for inclusion in tag message.
    $script:PreviousSemVer = '(none)'
    if (-not $RepoUriBase) { return 'v1.0.0' }

    $cloneUrlAuth = $RepoUriBase -replace '^https://', "https://buildagent:$Token@"
    $latest = $null
    try {
        $tagsRaw = git ls-remote --tags --refs $cloneUrlAuth 'refs/tags/v*' 2>$null
        if ($LASTEXITCODE -eq 0 -and $tagsRaw) {
            $semvers = $tagsRaw |
                ForEach-Object { ($_ -split "`t")[1] } |
                ForEach-Object { $_ -replace '^refs/tags/','' } |
                Where-Object { $_ -match '^v(\d+)\.(\d+)\.(\d+)$' } |
                ForEach-Object {
                    [pscustomobject]@{
                        Tag   = $_
                        Major = [int]$Matches[1]
                        Minor = [int]$Matches[2]
                        Patch = [int]$Matches[3]
                    }
                }
            if ($semvers) {
                $latest = $semvers | Sort-Object Major,Minor,Patch | Select-Object -Last 1
                $script:PreviousSemVer = $latest.Tag
            }
        }
    } catch {
        Write-Host "WARN: Get-NextSemVer ls-remote failed: $($_.Exception.Message). Falling back."
    }

    if (-not $latest) {
        Write-Host "Get-NextSemVer: no prior v*.*.* tag found - seeding v1.0.0."
        return 'v1.0.0'
    }

    # Map RELEASE_TYPE -> bump component (case-insensitive). Default = Sprint.
    $rt = $env:RELEASETYPE
    if ([string]::IsNullOrWhiteSpace($rt)) { $rt = 'Sprint' }
    $rt = $rt.Trim()

    switch -Regex ($rt) {
        '^(?i:sprint)$'  { $next = "v$($latest.Major).$($latest.Minor + 1).0";              $bumped = 'MINOR (Sprint)' }
        '^(?i:hotfix)$'  { $next = "v$($latest.Major).$($latest.Minor).$($latest.Patch + 1)"; $bumped = 'PATCH (Hotfix)' }
        '^(?i:country)$' { $next = "v$($latest.Major + 1).0.0";                              $bumped = 'MAJOR (Country)' }
        default {
            throw "RELEASETYPE '$rt' invalid - expected 'Sprint' | 'Hotfix' | 'Country'."
        }
    }
    Write-Host "Get-NextSemVer: latest='$($latest.Tag)' RELEASETYPE='$rt' bump=$bumped next='$next'."
    return $next
}

function Get-TagName {
    param([string]$Branch, [string]$BuildNumber, [string]$Token, [string]$RepoApiBase, [string]$RepoUriBase)
    switch -Wildcard ($Branch) {
        'release' { return "uat-$BuildNumber" }
        'prod'    { return (Get-NextSemVer -Token $Token -RepoApiBase $RepoApiBase -RepoUriBase $RepoUriBase) }
        default   { return "build-$BuildNumber" }
    }
}

function Build-EnvBlock {
    param(
        [string]$CollectionUri,
        [string]$ProjectName,
        [string]$ReleaseId,
        [string]$Token,
        [string]$CurrentStageEnv,
        [string]$CurrentStageOverride,
        [string]$PriorContent = ''
    )

    $excludedNamePatterns = @('Upload to Asset Library')

    if ([string]::IsNullOrWhiteSpace($CollectionUri) -or [string]::IsNullOrWhiteSpace($ReleaseId)) {
        Write-Host "WARN: SYSTEM_COLLECTIONURI or RELEASE_RELEASEID not set; emitting single-env fallback block."
        $line   = "[$CurrentStageEnv]($([string](Get-EnvUrl $CurrentStageEnv))) $IconDone"
        $legend = "<sub>**Legend**: $IconDone Deployed $MidDot $IconPartial Partial $MidDot $IconFailed Failed $MidDot $IconPending Pending</sub>"
        return ($line + "`r`n`r`n" + $legend), @()
    }

    $vsrmBase = $CollectionUri.TrimEnd('/').Replace('https://dev.azure.com/', 'https://vsrm.dev.azure.com/')
    $url      = "$vsrmBase/$ProjectName/_apis/release/releases/$ReleaseId" + '?api-version=7.1-preview.8'
    $headers  = @{ Authorization = "Bearer $Token" }

    try {
        $release = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
    } catch {
        Write-Host "WARN: Could not query release $ReleaseId. $($_.Exception.Message). Emitting single-env fallback."
        $line   = "[$CurrentStageEnv]($([string](Get-EnvUrl $CurrentStageEnv))) $IconDone"
        $legend = "<sub>**Legend**: $IconDone Deployed $MidDot $IconPartial Partial $MidDot $IconFailed Failed $MidDot $IconPending Pending</sub>"
        return ($line + "`r`n`r`n" + $legend), @()
    }

    $envs = @($release.environments | Sort-Object rank | Where-Object {
        $n = $_.name
        -not ($excludedNamePatterns | Where-Object { $n -like "*$_*" })
    })

    $parts = @(foreach ($e in $envs) {
        $status = if ($CurrentStageOverride -and $e.name -eq $CurrentStageOverride) { 'succeeded' } else { $e.status }
        $icon   = Get-StageIcon $status
        $envUrl = Get-EnvUrl $e.name
        if ($envUrl) { "[$($e.name)]($envUrl) $icon" } else { "$($e.name) $icon" }
    })

    # --- Monotonic-forward: never downgrade a previously-completed stage ----
    # ADO release REST snapshots can lag by several seconds across rapid stage
    # transitions, so a stage that just finished may briefly show as
    # `inProgress` / `notStarted` when a sibling stage's post-deploy task fires
    # moments later, causing the icon to flicker done -> pending. Carry forward
    # any prior done/partial/failed if the new render says pending.
    if ($PriorContent) {
        $sentinelRx = "(?s)$([regex]::Escape($BlockStart)).*?$([regex]::Escape($BlockEnd))"
        if ($PriorContent -match $sentinelRx) {
            $oldStrip = $Matches[0]
            $iconAlt  = (@($IconDone, $IconPartial, $IconFailed) | ForEach-Object { [regex]::Escape($_) }) -join '|'
            for ($i = 0; $i -lt $envs.Count; $i++) {
                $nm    = [regex]::Escape($envs[$i].name)
                $rxOld = "\[$nm\][^\r\n]*?\s+($iconAlt)"
                if (($oldStrip -match $rxOld) -and ($parts[$i] -like "*$IconPending*")) {
                    $oldIcon   = $Matches[1]
                    $parts[$i] = $parts[$i] -replace [regex]::Escape($IconPending), $oldIcon
                    Write-Host "Carry-forward: kept '$($envs[$i].name)' as $oldIcon (prior render was definite; current REST snapshot is stale)."
                }
            }
        }
    }

    $strip  = ($parts -join " $Arrow ")
    $legend = "<sub>**Legend**: $IconDone Deployed $MidDot $IconPartial Partial $MidDot $IconFailed Failed $MidDot $IconPending Pending</sub>"
    return ($strip + "`r`n`r`n" + $legend), $envs
}

# Compute the tag link up-front so we can also inject it into the metadata
# table on the same pipeline run that creates the tag.
$plannedTag = ''
if ($CreateTag -and (Should-CreateTag -Branch $SourceBranchName -StageName $env:RELEASE_ENVIRONMENTNAME)) {
    $plannedTag = Get-TagName -Branch $SourceBranchName -BuildNumber $BuildNumber -Token $Token -RepoApiBase $repoApiBase -RepoUriBase $repoUriBase
}

$utf8    = New-Object System.Text.UTF8Encoding($false)
$content = if (Test-Path $filePath) { [System.IO.File]::ReadAllText($filePath, $utf8) } else { '' }

$blockContent, $allEnvs = Build-EnvBlock `
    -CollectionUri        $collectionUri `
    -ProjectName          $projectName `
    -ReleaseId            $env:RELEASE_RELEASEID `
    -Token                $Token `
    -CurrentStageEnv      $Environment `
    -CurrentStageOverride $env:RELEASE_ENVIRONMENTNAME `
    -PriorContent         $content

$newBlock = @($BlockStart, $blockContent, $BlockEnd) -join "`r`n"

$sentinelPattern = "(?s)$([regex]::Escape($BlockStart)).*?$([regex]::Escape($BlockEnd))"

if ($content -match $sentinelPattern) {
    $content = [regex]::Replace($content, $sentinelPattern, { param($m) $newBlock }, 1)
    Write-Host "Replaced existing sentinel-bounded deployment-status block."
} elseif ($content.Contains($Placeholder)) {
    $content = $content.Replace($Placeholder, $newBlock)
    Write-Host "Injected fresh deployment-status block into placeholder."
} else {
    Write-Host "WARN: Neither sentinels nor placeholder found in $filePath; appending."
    $content = $content.TrimEnd() + "`r`n`r`n## Deployment status`r`n`r`n" + $newBlock + "`r`n"
}

[System.IO.File]::WriteAllText($filePath, $content, $utf8)

# --- Shorten 40-char commit SHA inside `[`<sha>`](.../commit/<sha>)` to 8 chars
$content = [System.IO.File]::ReadAllText($filePath, $utf8)
$content = [regex]::Replace($content, '\[`([a-f0-9]{40})`\](\([^)]*?/commit/[a-f0-9]{40}[^)]*\))', { param($m) "[``$($m.Groups[1].Value.Substring(0,8))``]$($m.Groups[2].Value)" })
[System.IO.File]::WriteAllText($filePath, $content, $utf8)

# --- Inject Tag link into metadata table (when tag is being created) ---------
if ($plannedTag -and $repoUriBase) {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    $tagUrl  = "$repoUriBase`?version=GT$([uri]::EscapeDataString($plannedTag))"
    $tagCellLink = "[``$plannedTag``]($tagUrl)"
    $content = [regex]::Replace(
        $content,
        '(\|\s\*\*Tag\*\*\s+\|\s)(?:_Pending_|\[`[^`]+`\]\([^)]+\))(\s\|)',
        { param($m) $m.Groups[1].Value + $tagCellLink + $m.Groups[2].Value },
        1
    )
    [System.IO.File]::WriteAllText($filePath, $content, $utf8)
    Write-Host ("Injected tag '{0}' into metadata table." -f $plannedTag)
}

# --- Inject Compare link into metadata table (always, all branches) ----------
$script:PrevBuildSha     = $null
$script:CurrentBuildSha  = $env:BUILD_SOURCEVERSION
try {
    $prevBuildNum = $null
    $prevSha      = $null
    $curSha       = $env:BUILD_SOURCEVERSION
    $curBuildNum  = $env:BUILD_BUILDNUMBER
    $buildDefId = if ($env:BUILD_DEFINITIONID) { $env:BUILD_DEFINITIONID } else { $env:SYSTEM_DEFINITIONID }
    if ($buildDefId -and $env:BUILD_BUILDID -and $env:BUILD_SOURCEBRANCH -and $curSha) {
        $apiBase = "$projectBaseUri/_apis/build/builds"
        $qs = "definitions=$buildDefId&branchName=$([uri]::EscapeDataString($env:BUILD_SOURCEBRANCH))&statusFilter=completed&resultFilter=succeeded&`$top=5&queryOrder=finishTimeDescending&api-version=7.0"
        $resp = Invoke-RestMethod -Uri ("{0}?{1}" -f $apiBase, $qs) -Headers @{ Authorization = "Bearer $Token" }
        $prevBld = $resp.value | Where-Object { $_.id -lt [int]$env:BUILD_BUILDID -and $_.sourceVersion -and $_.sourceVersion -ne $curSha } | Select-Object -First 1
        if ($prevBld) {
            $prevBuildNum          = $prevBld.buildNumber
            $prevSha               = $prevBld.sourceVersion
            $script:PrevBuildSha   = $prevBld.sourceVersion
        }
    }

    if ($prevSha -and $curSha -and $repoUriBase) {
        $compareUrl  = "$repoUriBase/branchCompare?baseVersion=GC$prevSha&targetVersion=GC$curSha&_a=files"
        $compareCell = "[``$prevBuildNum`` -> ``$curBuildNum``]($compareUrl)"
    } else {
        $compareCell = $null
    }

    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    if ($compareCell) {
        $content = [regex]::Replace(
            $content,
            '(\|\s\*\*Compare\*\*\s+\|\s)(?:_Pending_|\[[^\]]+\]\([^)]+\)|_n/a[^|]*)(\s\|)',
            { param($m) $m.Groups[1].Value + $compareCell + $m.Groups[2].Value },
            1
        )
        [System.IO.File]::WriteAllText($filePath, $content, $utf8)
        Write-Host ("Injected compare ('{0}' -> '{1}') into metadata table." -f $(if ($prevBuildNum) { $prevBuildNum } else { '(none)' }), $curBuildNum)
    } else {
        $content = [regex]::Replace(
            $content,
            '(\|\s\*\*Compare\*\*\s+\|\s)_Pending_(\s\|)',
            { param($m) $m.Groups[1].Value + '_n/a (first build)_' + $m.Groups[2].Value },
            1
        )
        [System.IO.File]::WriteAllText($filePath, $content, $utf8)
        Write-Host "No previous build found - Compare cell set to 'n/a (first build)'."
    }
} catch {
    Write-Host "WARN: Could not inject compare link: $($_.Exception.Message)."
}

# --- Inject Post-Deployment Actions section ---------------------------------
# Surface only categories where deployers must act manually:
#   - Security objects     -> verify role/duty assignments
#   - Data entities        -> refresh entity list in Data Management
#   - Workflows            -> activate/configure in module
#   - Number sequences     -> run Generate wizard
#   - Financial dimensions -> activate under GL > COA > Dimensions
#   - Configuration keys   -> review under System administration > Licensing
#   - Business events      -> activate/configure under System administration
# Plus a "New objects introduced" summary (counts only, added-only) for the
# same categories plus batch jobs (new Action menu items pointing to *Controller
# / *Batch / *Batchable classes).
# Note: D365FO metadata layout is .../<AxObjectType>/<Name>.xml - detection
# uses the *parent folder* (object type), not file extension.
try {
    $pPrev = $script:PrevBuildSha
    $pCur  = $script:CurrentBuildSha
    if ($pPrev -and $pCur -and $pPrev -ne $pCur -and $repoApiBase) {
        $diffUri = "$repoApiBase/diffs/commits?baseVersion=$pPrev&baseVersionType=commit&targetVersion=$pCur&targetVersionType=commit&`$top=2000&api-version=7.0"
        $diffResp = Invoke-RestMethod -Uri $diffUri -Headers @{ Authorization = "Bearer $Token" }
        $changes = @()
        if ($diffResp.changes) {
            $changes = $diffResp.changes | Where-Object { $_.item -and -not $_.item.isFolder -and $_.item.path -like '*.xml' }
        }
        Write-Host "Diff: $($changes.Count) AOT file(s) between $pPrev..$pCur"

        $secTypes    = @('AxSecurityRole','AxSecurityDuty','AxSecurityPrivilege','AxSecurityPolicy')
        $entityTypes = @('AxDataEntityView','AxCompositeDataEntityView','AxAggregateDataEntity')
        $wfTypes     = @('AxWorkflowType','AxWorkflowCategory','AxWorkflowApproval','AxWorkflowTask')
        $numSeqTypes = @('AxNumberSequenceReference','AxNumberSequenceScope','AxNumberSequenceGroup')
        $dimTypes    = @('AxDimensionAttribute')
        $cfgTypes    = @('AxConfigurationKey','AxLicenseCode')
        $bizEvtTypes = @('AxBusinessEventsCatalog')

        function _ParentType($p) { return ($p -split '/')[-2] }
        $secChanges    = $changes | Where-Object { $secTypes    -contains (_ParentType $_.item.path) }
        $entChanges    = $changes | Where-Object { $entityTypes -contains (_ParentType $_.item.path) }
        $wfChanges     = $changes | Where-Object { $wfTypes     -contains (_ParentType $_.item.path) }
        $numSeqChanges = $changes | Where-Object { $numSeqTypes -contains (_ParentType $_.item.path) }
        $dimChanges    = $changes | Where-Object { $dimTypes    -contains (_ParentType $_.item.path) }
        $cfgChanges    = $changes | Where-Object { $cfgTypes    -contains (_ParentType $_.item.path) }
        $bizEvtChanges = $changes | Where-Object { $bizEvtTypes -contains (_ParentType $_.item.path) }

        $reminders = @()
        if ($secChanges)    { $reminders += ([char]::ConvertFromUtf32(0x1F510) + " **Security objects changed** $([char]::ConvertFromUtf32(0x2014)) verify role/duty assignments in target environment.") }
        if ($entChanges)    { $reminders += ([char]::ConvertFromUtf32(0x1F5C2) + " **Data entities changed** $([char]::ConvertFromUtf32(0x2014)) refresh entity list in Data Management > Framework parameters.") }
        if ($wfChanges)     { $reminders += ([char]::ConvertFromUtf32(0x1F501) + " **Workflow objects changed** $([char]::ConvertFromUtf32(0x2014)) activate/configure workflow under the relevant module > Setup > Workflows.") }
        if ($numSeqChanges) { $reminders += ([char]::ConvertFromUtf32(0x1F522) + " **Number sequences changed** $([char]::ConvertFromUtf32(0x2014)) run the Generate wizard under Organization administration > Number sequences.") }
        if ($dimChanges)    { $reminders += ([char]::ConvertFromUtf32(0x1F3F7) + " **Financial dimensions changed** $([char]::ConvertFromUtf32(0x2014)) activate under General ledger > Chart of accounts > Dimensions > Financial dimensions.") }
        if ($cfgChanges)    { $reminders += ([char]::ConvertFromUtf32(0x2699)  + " **Configuration keys changed** $([char]::ConvertFromUtf32(0x2014)) review under System administration > Setup > Licensing > License configuration.") }
        if ($bizEvtChanges) { $reminders += ([char]::ConvertFromUtf32(0x1F4E1) + " **Business events changed** $([char]::ConvertFromUtf32(0x2014)) activate/configure under System administration > Setup > Business events.") }

        # New-objects counts (added only)
        $secAdded    = $secChanges    | Where-Object { $_.changeType -match '(?i)add' }
        $entAdded    = $entChanges    | Where-Object { $_.changeType -match '(?i)add' }
        $wfAdded     = $wfChanges     | Where-Object { $_.changeType -match '(?i)add' }
        $numSeqAdded = $numSeqChanges | Where-Object { $_.changeType -match '(?i)add' }
        $dimAdded    = $dimChanges    | Where-Object { $_.changeType -match '(?i)add' }
        $cfgAdded    = $cfgChanges    | Where-Object { $_.changeType -match '(?i)add' }
        $bizEvtAdded = $bizEvtChanges | Where-Object { $_.changeType -match '(?i)add' }

        # Batch jobs: added Action menu items whose <Object> references an added
        # *Controller / *Batch / *Batchable class.
        $batchJobCount = 0
        $addedClassNames = @($changes | Where-Object {
            $_.changeType -match '(?i)add' -and (_ParentType $_.item.path) -eq 'AxClass'
        } | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.item.path) })
        $candidateClasses = $addedClassNames | Where-Object { $_ -match '(?i)(Controller|Batch|Batchable)$' }
        if ($candidateClasses.Count -gt 0) {
            $addedMenuItems = $changes | Where-Object {
                $_.changeType -match '(?i)add' -and (_ParentType $_.item.path) -eq 'AxMenuItemAction'
            }
            foreach ($mi in $addedMenuItems) {
                try {
                    $itemUri = "$repoApiBase/items?path=$([uri]::EscapeDataString($mi.item.path))&versionDescriptor.version=$pCur&versionDescriptor.versionType=commit&includeContent=true&api-version=7.0"
                    $miResp = Invoke-RestMethod -Uri $itemUri -Headers @{ Authorization = "Bearer $Token" }
                    if ($miResp.content -match '<Object>([^<]+)</Object>') {
                        $obj = $matches[1]
                        if ($candidateClasses -contains $obj) { $batchJobCount++ }
                    }
                } catch {
                    Write-Host "WARN: Could not read menu item $($mi.item.path): $($_.Exception.Message)"
                }
            }
        }

        $newLines = @()
        if ($secAdded) {
            $byType = $secAdded | Group-Object { _ParentType $_.item.path }
            $parts = @()
            foreach ($t in $secTypes) {
                $g = $byType | Where-Object { $_.Name -eq $t }
                if ($g) {
                    $label = switch ($t) {
                        'AxSecurityRole'      { if ($g.Count -eq 1) { 'role' }      else { 'roles' } }
                        'AxSecurityDuty'      { if ($g.Count -eq 1) { 'duty' }      else { 'duties' } }
                        'AxSecurityPrivilege' { if ($g.Count -eq 1) { 'privilege' } else { 'privileges' } }
                        'AxSecurityPolicy'    { if ($g.Count -eq 1) { 'policy' }    else { 'policies' } }
                    }
                    $parts += "$($g.Count) $label"
                }
            }
            if ($parts) { $newLines += ([char]::ConvertFromUtf32(0x1F510) + " Security: " + ($parts -join ', ')) }
        }
        if ($entAdded)    { $w = if ($entAdded.Count -eq 1)    { 'data entity' }                else { 'data entities' };           $newLines += ([char]::ConvertFromUtf32(0x1F5C2) + " Data entities: $($entAdded.Count) new $w") }
        if ($wfAdded)     { $w = if ($wfAdded.Count -eq 1)     { 'workflow object' }            else { 'workflow objects' };       $newLines += ([char]::ConvertFromUtf32(0x1F501) + " Workflows: $($wfAdded.Count) new $w") }
        if ($numSeqAdded) { $w = if ($numSeqAdded.Count -eq 1) { 'reference/scope/group' }      else { 'references/scopes/groups' };$newLines += ([char]::ConvertFromUtf32(0x1F522) + " Number sequences: $($numSeqAdded.Count) new $w") }
        if ($dimAdded)    { $w = if ($dimAdded.Count -eq 1)    { 'dimension' }                  else { 'dimensions' };             $newLines += ([char]::ConvertFromUtf32(0x1F3F7) + " Financial dimensions: $($dimAdded.Count) new $w") }
        if ($cfgAdded)    { $w = if ($cfgAdded.Count -eq 1)    { 'key' }                        else { 'keys' };                   $newLines += ([char]::ConvertFromUtf32(0x2699)  + " Configuration keys: $($cfgAdded.Count) new $w") }
        if ($bizEvtAdded) { $w = if ($bizEvtAdded.Count -eq 1) { 'business event' }             else { 'business events' };        $newLines += ([char]::ConvertFromUtf32(0x1F4E1) + " Business events: $($bizEvtAdded.Count) new $w") }
        if ($batchJobCount -gt 0) {
            $w = if ($batchJobCount -eq 1) { 'batch job' } else { 'batch jobs' }
            $newLines += ([char]::ConvertFromUtf32(0x23F0) + " Batch jobs: $batchJobCount new $w (schedule under System administration > Inquiries > Batch jobs)")
        }

        if ($reminders.Count -gt 0 -or $newLines.Count -gt 0) {
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("`r`n## Post-Deployment Actions")
            [void]$sb.AppendLine("")
            foreach ($r in $reminders) { [void]$sb.AppendLine("- $r") }
            if ($newLines.Count -gt 0) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("**New objects introduced in this build:**")
                [void]$sb.AppendLine("")
                foreach ($n in $newLines) { [void]$sb.AppendLine("- $n") }
            }
            [void]$sb.AppendLine("")
            $section = $sb.ToString()

            $content = [System.IO.File]::ReadAllText($filePath, $utf8)
            if ($content -notmatch '(?m)^## Post-Deployment Actions' -and $content -match '(?m)^## User Stories') {
                $content = $content -replace '(?m)(^## User Stories)', ($section.Replace('$','$$') + '$1')
                [System.IO.File]::WriteAllText($filePath, $content, $utf8)
                Write-Host "Injected Post-Deployment Actions section ($($reminders.Count) reminder(s), $($newLines.Count) new-object line(s))."
            }
        } else {
            # No qualifying changes detected, but still emit the heading so the
            # page shape is consistent with every other section.
            $content = [System.IO.File]::ReadAllText($filePath, $utf8)
            if ($content -notmatch '(?m)^## Post-Deployment Actions' -and $content -match '(?m)^## User Stories') {
                $section = "`r`n## Post-Deployment Actions`r`n`r`n_No post-deployment actions required for this build._`r`n`r`n"
                $content = $content -replace '(?m)(^## User Stories)', ($section.Replace('$','$$') + '$1')
                [System.IO.File]::WriteAllText($filePath, $content, $utf8)
                Write-Host "Injected empty Post-Deployment Actions section (no relevant changes)."
            }
        }
    } else {
        # No prev SHA -> still emit the heading with a placeholder so the page
        # shape is consistent across builds.
        $content = [System.IO.File]::ReadAllText($filePath, $utf8)
        if ($content -notmatch '(?m)^## Post-Deployment Actions' -and $content -match '(?m)^## User Stories') {
            $section = "`r`n## Post-Deployment Actions`r`n`r`n_No post-deployment actions required for this build._`r`n`r`n"
            $content = $content -replace '(?m)(^## User Stories)', ($section.Replace('$','$$') + '$1')
            [System.IO.File]::WriteAllText($filePath, $content, $utf8)
            Write-Host "Injected empty Post-Deployment Actions section (no prev SHA or RepoName)."
        }
    }
} catch {
    Write-Host "WARN: Could not generate Post-Deployment Actions: $($_.Exception.Message)."
}

# --- Inject Priority Test Items callout (S1 / S2 bugs) -----------------------
try {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    if ($content -notmatch '(?m)^## Priority Test Items') {
        $bugsMatch = [regex]::Match($content, '(?ms)^## Bugs\s*(.+?)(?=^## )')
        $priorityBugs = @()
        if ($bugsMatch.Success) {
            $bugsBlock = $bugsMatch.Groups[1].Value
            $rows = $bugsBlock -split "`n" | Where-Object {
                $_ -match '^\s*\|' -and
                $_ -notmatch '^\s*\|\s*\*\*ID' -and
                $_ -notmatch '^\s*\|[-\s|]+\|\s*$' -and
                $_ -notmatch '_No bugs linked'
            }
            foreach ($row in $rows) {
                $cells = $row.Trim().TrimStart('|').TrimEnd('|') -split '\|'
                if ($cells.Count -lt 4) { continue }
                $idCell  = $cells[0].Trim()
                $title   = $cells[1].Trim()
                $sev     = $cells[2].Trim()
                $pri     = $cells[3].Trim()
                if ($sev -match '^\s*[12](\s|-|$)') {
                    $priorityBugs += [pscustomobject]@{
                        IdCell   = $idCell
                        Title    = $title
                        Severity = $sev
                        Priority = $pri
                    }
                }
            }
        }
        if ($priorityBugs.Count -gt 0) {
            $iconAlert = [char]::ConvertFromUtf32(0x1F6A8)
            $iconFire  = [char]::ConvertFromUtf32(0x1F525)
            $items = foreach ($b in $priorityBugs) {
                $icon = if ($b.Severity -match '^\s*1') { $iconFire } else { $iconAlert }
                "$icon $($b.IdCell) **$($b.Title)** _(Sev: $($b.Severity), Pri: $($b.Priority))_"
            }
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("`r`n## Priority Test Items")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("> [!WARNING]")
            [void]$sb.AppendLine("> $iconAlert **$($priorityBugs.Count) high-severity bug fix(es) (S1/S2) in this build** - please test on priority. Full details in the [Bugs](#bugs) table below.")
            [void]$sb.AppendLine(">")
            foreach ($i in $items) { [void]$sb.AppendLine("> - $i") }
            [void]$sb.AppendLine("")
            $callout = $sb.ToString()

            if ($content -match '(?m)^## Post-Deployment Actions') {
                $content = $content -replace '(?m)(^## Post-Deployment Actions)', ($callout + '$1')
            } elseif ($content -match '(?m)^## User Stories') {
                $content = $content -replace '(?m)(^## User Stories)', ($callout + '$1')
            } else {
                $content = $content + $callout
            }
            [System.IO.File]::WriteAllText($filePath, $content, $utf8)
            Write-Host "Injected Priority Test Items callout ($($priorityBugs.Count) S1/S2 bug(s))."
        } else {
            # No S1/S2 bugs, but still emit the heading so the page shape is
            # consistent and deployers can see 'no high-priority items' at a glance.
            $section = "`r`n## Priority Test Items`r`n`r`n_No S1/S2 priority bugs in this build._`r`n`r`n"
            if ($content -match '(?m)^## Post-Deployment Actions') {
                $content = $content -replace '(?m)(^## Post-Deployment Actions)', ($section.Replace('$','$$') + '$1')
            } elseif ($content -match '(?m)^## User Stories') {
                $content = $content -replace '(?m)(^## User Stories)', ($section.Replace('$','$$') + '$1')
            } else {
                $content = $content + $section
            }
            [System.IO.File]::WriteAllText($filePath, $content, $utf8)
            Write-Host "Injected empty Priority Test Items section (no S1/S2 bugs)."
        }
    }
} catch {
    Write-Host "WARN: Could not generate Priority Test Items: $($_.Exception.Message)."
}

# --- Sort Bugs table by Severity then Priority (S1 first) --------------------
try {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    $bugsRx = [regex]'(?ms)(^## Bugs\s*\r?\n)(\|\s\*\*ID[^\r\n]+\r?\n\|[-\s|]+\|\s*\r?\n)((?:\|[^\r\n]+\r?\n)+)'
    $m = $bugsRx.Match($content)
    if ($m.Success) {
        $header = $m.Groups[2].Value
        $rowsBlock = $m.Groups[3].Value
        $rows = $rowsBlock -split "`r?`n" | Where-Object { $_ -match '^\|' }
        $dataRows = $rows | Where-Object { $_ -notmatch '_No bugs linked' }
        if ($dataRows.Count -gt 1) {
            $sorted = $dataRows | Sort-Object @{
                Expression = {
                    $cells = $_.Trim().TrimStart('|').TrimEnd('|') -split '\|'
                    $sev = if ($cells.Count -ge 3) { $cells[2].Trim() } else { '' }
                    if ($sev -match '^\s*(\d+)') { [int]$matches[1] } else { 99 }
                }
            }, @{
                Expression = {
                    $cells = $_.Trim().TrimStart('|').TrimEnd('|') -split '\|'
                    $pri = if ($cells.Count -ge 4) { $cells[3].Trim() } else { '' }
                    if ($pri -match '^\s*(\d+)') { [int]$matches[1] } else { 99 }
                }
            }
            $newRows = ($sorted -join "`r`n") + "`r`n"
            $content = $bugsRx.Replace($content, ($m.Groups[1].Value + $header + $newRows), 1)
            [System.IO.File]::WriteAllText($filePath, $content, $utf8)
            Write-Host "Sorted Bugs table by Severity, Priority ($($dataRows.Count) row(s))."
        }
    }
} catch {
    Write-Host "WARN: Could not sort Bugs table: $($_.Exception.Message)."
}

# --- Collapse empty-state tables to single italic line -----------------------
try {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    $emptyRx = [regex]'(?ms)^\|\s\*\*[^\r\n]+\|\s*\r?\n\|[-\s|]+\|\s*\r?\n\|(?:\s-\s\|)+\s_([^_]+)_\s\|(?:[^\r\n|]*\|)*\s*\r?\n'
    $new = $emptyRx.Replace($content, { param($m) "_" + $m.Groups[1].Value + "_`r`n" })
    if ($new -ne $content) {
        $trimmed = ($content -split "`n").Count - ($new -split "`n").Count
        [System.IO.File]::WriteAllText($filePath, $new, $utf8)
        Write-Host "Collapsed $trimmed empty-state table line(s) to italic lines."
    }
} catch {
    Write-Host "WARN: Could not collapse empty-state tables: $($_.Exception.Message)."
}

# --- Attribute cherry-picked PRs to the original author ----------------------
try {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    if ($repoApiBase) {
        $hdrs = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
        $prRowRx = [regex]'(?m)^(\|\s\[!(\d+)\]\([^)]+\)\s\|\s[^|]+\|\s)([^|]+?)(\s\|)'
        $script:swapped = 0
        $newContent = $prRowRx.Replace($content, {
            param($m)
            $prId = $m.Groups[2].Value
            $raisedBy = $m.Groups[3].Value.Trim()
            try {
                $commits = Invoke-RestMethod -Uri "$repoApiBase/pullRequests/$prId/commits?api-version=7.0" -Headers $hdrs -ErrorAction Stop
                foreach ($c in $commits.value) {
                    if ($c.comment -match '\(cherry picked from commit ([0-9a-f]{7,40})\)') {
                        $origSha = $matches[1]
                        $origCommit = Invoke-RestMethod -Uri "$repoApiBase/commits/$($origSha)?api-version=7.0" -Headers $hdrs -ErrorAction Stop
                        $origAuthor = $origCommit.author.name
                        if ($origAuthor -and $origAuthor -ne $raisedBy) {
                            $script:swapped++
                            return $m.Groups[1].Value + "$origAuthor _(cherry-picked by $raisedBy)_" + $m.Groups[4].Value
                        }
                        break
                    }
                }
            } catch { }
            return $m.Value
        })
        if ($newContent -ne $content) {
            [System.IO.File]::WriteAllText($filePath, $newContent, $utf8)
            Write-Host "Re-attributed $($script:swapped) cherry-picked PR row(s) to original author."
        }
    }
} catch {
    Write-Host "WARN: Could not re-attribute cherry-picked PRs: $($_.Exception.Message)."
}

# --- Strip "(EXT)" suffix from author/reviewer cells -------------------------
try {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    $new = $content -replace '\s*\(EXT\)', ''
    if ($new -ne $content) {
        $count = ([regex]'\(EXT\)').Matches($content).Count
        [System.IO.File]::WriteAllText($filePath, $new, $utf8)
        Write-Host "Stripped $count '(EXT)' suffix(es)."
    }
} catch {
    Write-Host "WARN: Could not strip (EXT) suffixes: $($_.Exception.Message)."
}

# --- Replace pending-release placeholder with live release link --------------
$hourglass        = [char]0x23F3
$content          = [System.IO.File]::ReadAllText($filePath, $utf8)
$pendingInline    = "$hourglass _**Awaiting deployment**_"
$pendingCallout   = "> [!CAUTION]`r`n> $hourglass **Awaiting deployment**"
$pendingCalloutLF = "> [!CAUTION]`n> $hourglass **Awaiting deployment**"
$releaseLink      = "[$env:RELEASE_RELEASENAME]($env:RELEASE_RELEASEWEBURL) $IconDone _Deployed_"

if ($content.Contains($pendingInline)) {
    $content = $content.Replace($pendingInline, $releaseLink)
    Write-Host "Replaced pending placeholder with: $releaseLink"
} elseif ($content.Contains($pendingCallout)) {
    $content = $content.Replace($pendingCallout, "**Release information**: $releaseLink")
    Write-Host "Replaced callout placeholder with: $releaseLink"
} elseif ($content.Contains($pendingCalloutLF)) {
    $content = $content.Replace($pendingCalloutLF, "**Release information**: $releaseLink")
    Write-Host "Replaced callout (LF) placeholder with: $releaseLink"
} elseif ($content.Contains('RELEASENOPLACEHOLDER')) {
    $content = $content.Replace('RELEASENOPLACEHOLDER', $releaseLink)
    Write-Host "Replaced legacy RELEASENOPLACEHOLDER with: $releaseLink"
} else {
    Write-Host "No release placeholder present (already substituted in an earlier stage?)."
}

[System.IO.File]::WriteAllText($filePath, $content, $utf8)

# --- Optional: auto-tag the build's source commit ----------------------------
if ($CreateTag -and (Should-CreateTag -Branch $SourceBranchName -StageName $env:RELEASE_ENVIRONMENTNAME) -and $repoUriBase) {
    $tagName = Get-TagName -Branch $SourceBranchName -BuildNumber $BuildNumber -Token $Token -RepoApiBase $repoApiBase -RepoUriBase $repoUriBase
    $commit  = $env:BUILD_SOURCEVERSION
    if (-not $commit) { Write-Host "WARN: BUILD_SOURCEVERSION not set; skipping tag."; }
    else {
        Write-Host "Tagging commit $commit as $tagName ..."

        $tagDir   = Join-Path $env:AGENT_TEMPDIRECTORY ("srcrepo-" + [guid]::NewGuid())
        $cloneUrlAuth = $repoUriBase -replace '^https://', "https://buildagent:$Token@"
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE     = 'Never'

        $stage   = $env:RELEASE_ENVIRONMENTNAME
        $baseMsg = "Build $BuildNumber deployed to $stage on $([datetime]::UtcNow.ToString('yyyy-MM-dd')) (branch: $SourceBranchName)."
        if ($tagName -match '^v\d+\.\d+\.\d+$') {
            $prev   = if ($script:PreviousSemVer) { $script:PreviousSemVer } else { '(none)' }
            $tagMsg = "$tagName - $baseMsg Previous: $prev."
        } else {
            $tagMsg = $baseMsg
        }

        try {
            git -c core.longpaths=true clone --depth 1 --no-checkout $cloneUrlAuth $tagDir
            if ($LASTEXITCODE -ne 0) { throw "Clone failed." }
            Push-Location $tagDir
            try {
                $existing = git ls-remote --tags origin "refs/tags/$tagName" 2>$null
                if ($existing) {
                    Write-Host "Tag '$tagName' already exists on origin - skipping."
                } else {
                    git config user.email $GitUserEmail
                    git config user.name  $GitUserName
                    git fetch --depth 1 origin $commit | Out-Host
                    git tag -a $tagName $commit -m $tagMsg
                    if ($LASTEXITCODE -ne 0) { throw "git tag failed." }
                    git push origin "refs/tags/$tagName" | Out-Host
                    if ($LASTEXITCODE -ne 0) { throw "git push tag failed." }
                    Write-Host "Pushed tag '$tagName' -> commit $commit."
                }
            } finally {
                Pop-Location
            }
        } catch {
            Write-Host "WARN: Tag creation failed: $($_.Exception.Message). Wiki update is not affected."
        } finally {
            Remove-Item -Path $tagDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} elseif ($CreateTag) {
    Write-Host "No tag trigger for branch='$SourceBranchName' stage='$($env:RELEASE_ENVIRONMENTNAME)'."
}

# --- Hand off file paths to subsequent tasks ---------------------------------
Write-Host "##vso[task.setvariable variable=wikiFilePath]$filePath"
Write-Host "##vso[task.setvariable variable=wikiPagePath]$relPath"
Write-Host "=== Update-WikiReleaseNotes.ps1 complete ==="
<#
.SYNOPSIS
    Updates the release-notes wiki page for a deployment stage.

.DESCRIPTION
    Called by a Classic Release pipeline as a POST-deployment task on every
    stage. Responsibilities:

      1. Clone the project Wiki repo using System.AccessToken.
      2. Locate the build's wiki release-note page (Build-<BuildNumber>.md)
         under the per-branch sub-folder (Main-branch / Prod-branch /
         Hotfix-branch / Release-branch).
      3. Replace the <!-- ENV-PROGRESS-BLOCK --> placeholder (first run) or
         the existing sentinel-bounded block (subsequent runs) with a fresh
         compact deployment-status strip built from the LIVE release stages
         queried via Azure DevOps REST API.
      4. Substitute the "Awaiting deployment" placeholder with a link back to
         the running release plus a "_Deployed_" suffix.
      5. Stage the file for the subsequent "Git based WIKI File Updater" task.

    Visual style:
        - Compact strip:  [DevTest](url) 🟢 -> [UAT](url) 🟢 -> [PROD](url) ⚪
        - Traffic-light icons:  🟢 succeeded  🟠 partiallySucceeded
                                🔴 failed     ⚪ pending
        - Sentinel markers used for safe re-replacement on subsequent stages:
            <!-- ENV-PROGRESS-START -->
            ...content...
            <!-- ENV-PROGRESS-END -->

    All emoji output uses [char]::ConvertFromUtf32 so the script is safe under
    Windows PowerShell 5.1 default encoding.

.PARAMETER Environment
    Environment name (fallback label when release REST query fails).

.PARAMETER BuildNumber
    Build number to locate the wiki page. Default: $env:BUILD_BUILDNUMBER.

.PARAMETER SourceBranchName
    Branch of the triggering build. Default: $env:BUILD_SOURCEBRANCHNAME.

.PARAMETER WikiRepoUrlBase
    Wiki repo URL. Required.

.PARAMETER WikiBranch
    Wiki branch. Default: wikiMaster.

.PARAMETER TargetDir
    Clone directory. Default: $(System.DefaultWorkingDirectory)\wiki.

.PARAMETER Token
    Auth token. Default: $env:SYSTEM_ACCESSTOKEN.

.PARAMETER EnvUrlMapJson
    Optional JSON object mapping environment names to D365 URLs. Each strip
    entry becomes a clickable link if a URL is found.
    Example: '{"DEV":"https://myenv-dev.sandbox.operations.eu.dynamics.com/"}'

.EXAMPLE
    .\Update-WikiReleaseNotes.ps1 -Environment "DEV" `
        -WikiRepoUrlBase "https://dev.azure.com/myorg/MyProject/_git/MyProject.wiki" `
        -EnvUrlMapJson '{"DEV":"https://myenv-dev.sandbox.operations.eu.dynamics.com/"}'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Environment,

    [string]$BuildNumber       = $env:BUILD_BUILDNUMBER,
    [string]$SourceBranchName  = $env:BUILD_SOURCEBRANCHNAME,
    [Parameter(Mandatory = $true)]
    [string]$WikiRepoUrlBase,
    [string]$WikiBranch        = "wikiMaster",
    [string]$TargetDir         = (Join-Path $env:SYSTEM_DEFAULTWORKINGDIRECTORY 'wiki'),
    [string]$Token             = $env:SYSTEM_ACCESSTOKEN,
    [string]$EnvUrlMapJson     = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BuildNumber))      { throw "BuildNumber is required (env BUILD_BUILDNUMBER not set)." }
if ([string]::IsNullOrWhiteSpace($SourceBranchName)) { throw "SourceBranchName is required (env BUILD_SOURCEBRANCHNAME not set)." }
if ([string]::IsNullOrWhiteSpace($Token))            { throw "Token is required (enable System.AccessToken on the agent job)." }

Write-Host "=== Update-WikiReleaseNotes.ps1 ==="
Write-Host "Environment        : $Environment"
Write-Host "BuildNumber        : $BuildNumber"
Write-Host "SourceBranchName   : $SourceBranchName"

# --- Icons (encoding-safe via UTF-32 codepoints) -----------------------------
$IconDone    = [char]::ConvertFromUtf32(0x1F7E2)   # green circle
$IconPartial = [char]::ConvertFromUtf32(0x1F7E0)   # orange circle
$IconFailed  = [char]::ConvertFromUtf32(0x1F534)   # red circle
$IconPending = [char]::ConvertFromUtf32(0x26AA)    # white circle
$Arrow       = [char]::ConvertFromUtf32(0x2192)    # right arrow
$MidDot      = [char]::ConvertFromUtf32(0x00B7)    # middle dot

$BlockStart  = '<!-- ENV-PROGRESS-START -->'
$BlockEnd    = '<!-- ENV-PROGRESS-END -->'
$Placeholder = '<!-- ENV-PROGRESS-BLOCK -->'
$Legend      = "<sub>**Legend**: $IconDone Deployed $MidDot $IconPartial Partial $MidDot $IconFailed Failed $MidDot $IconPending Pending</sub>"

# --- Parse optional env URL map ----------------------------------------------
$script:EnvUrlMap = @{}
if ($EnvUrlMapJson) {
    try {
        $obj = $EnvUrlMapJson | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $script:EnvUrlMap[$p.Name.ToUpper()] = [string]$p.Value }
    } catch {
        Write-Host "WARN: Could not parse EnvUrlMapJson - skipping env links."
    }
}

function Get-EnvUrl {
    param([string]$EnvName)
    if ([string]::IsNullOrWhiteSpace($EnvName)) { return $null }
    $u = $script:EnvUrlMap[$EnvName.ToUpper()]
    if ($u) { return $u }
    return $null
}

function Get-StageIcon {
    param([string]$Status)
    switch -Wildcard ($Status) {
        'succeeded'          { return $IconDone }
        'partiallySucceeded' { return $IconPartial }
        'rejected'           { return $IconFailed }
        'canceled'           { return $IconFailed }
        'cancelled'          { return $IconFailed }
        'inProgress'         { return $IconPending }
        'queued'             { return $IconPending }
        'scheduled'          { return $IconPending }
        'notStarted'         { return $IconPending }
        default              { return $IconPending }
    }
}

# --- Derive wiki sub-folder from the triggering build's branch ----------------
switch -Wildcard ($SourceBranchName) {
    'prod'    { $wikiPath = 'Deployment-release-notes\Prod-branch\' }
    'main'    { $wikiPath = 'Deployment-release-notes\Main-branch\' }
    'hotfix*' { $wikiPath = 'Deployment-release-notes\Hotfix-branch\' }
    default   { $wikiPath = 'Deployment-release-notes\Release-branch\' }
}
Write-Host "Resolved wikiPath  : $wikiPath"

# --- Clone the wiki repo ------------------------------------------------------
$repoUrl = $WikiRepoUrlBase -replace '^https://', "https://buildagent:$Token@"

git --version | Out-Host
git config --global core.longpaths true | Out-Null

if (Test-Path $TargetDir) {
    Write-Host "Removing existing $TargetDir before fresh clone."
    Remove-Item -Path $TargetDir -Recurse -Force -ErrorAction SilentlyContinue
}

git clone --depth 1 --branch $WikiBranch $repoUrl $TargetDir
if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE." }

# --- Locate the wiki page -----------------------------------------------------
$relPath  = Join-Path $wikiPath ("Build-{0}.md" -f $BuildNumber)
$filePath = Join-Path $TargetDir $relPath
Write-Host "Looking for file   : $filePath"

if (-not (Test-Path $filePath)) {
    throw ("Wiki file not found: '{0}'. Check that the build's 'Publish release notes' step wrote 'Build-{1}.md' under '{2}'." -f $filePath, $BuildNumber, $wikiPath)
}

# --- Build the deployment-status block from the live release stages ----------
function Build-EnvBlock {
    param(
        [string]$CollectionUri,
        [string]$ProjectName,
        [string]$ReleaseId,
        [string]$Token,
        [string]$CurrentStageEnv,
        [string]$CurrentStageOverride
    )

    if ([string]::IsNullOrWhiteSpace($CollectionUri) -or [string]::IsNullOrWhiteSpace($ReleaseId)) {
        Write-Host "WARN: SYSTEM_COLLECTIONURI or RELEASE_RELEASEID not set; emitting single-env fallback block."
        $u    = Get-EnvUrl $CurrentStageEnv
        $line = if ($u) { "[$CurrentStageEnv]($u) $IconDone" } else { "$CurrentStageEnv $IconDone" }
        return ($line + "`r`n`r`n" + $Legend), @()
    }

    $vsrmBase = $CollectionUri.TrimEnd('/').Replace('https://dev.azure.com/', 'https://vsrm.dev.azure.com/')
    $url      = "$vsrmBase/$ProjectName/_apis/release/releases/$ReleaseId" + '?api-version=7.1-preview.8'
    $headers  = @{ Authorization = "Bearer $Token" }

    try {
        $release = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
    } catch {
        Write-Host "WARN: Could not query release $ReleaseId from $url. $($_.Exception.Message). Emitting single-env fallback."
        $u    = Get-EnvUrl $CurrentStageEnv
        $line = if ($u) { "[$CurrentStageEnv]($u) $IconDone" } else { "$CurrentStageEnv $IconDone" }
        return ($line + "`r`n`r`n" + $Legend), @()
    }

    $envs = @($release.environments | Sort-Object rank)

    $parts = foreach ($e in $envs) {
        # The currently-deploying stage's status is still 'inProgress' when this
        # script runs as a post-deployment task; treat it as succeeded.
        $status = if ($CurrentStageOverride -and $e.name -eq $CurrentStageOverride) { 'succeeded' } else { $e.status }
        $icon   = Get-StageIcon $status
        $eu     = Get-EnvUrl $e.name
        if ($eu) { "[$($e.name)]($eu) $icon" } else { "$($e.name) $icon" }
    }

    $strip = ($parts -join " $Arrow ")
    return ($strip + "`r`n`r`n" + $Legend), $envs
}

$blockContent, $allEnvs = Build-EnvBlock `
    -CollectionUri        $env:SYSTEM_COLLECTIONURI `
    -ProjectName          $env:SYSTEM_TEAMPROJECT `
    -ReleaseId            $env:RELEASE_RELEASEID `
    -Token                $Token `
    -CurrentStageEnv      $Environment `
    -CurrentStageOverride $env:RELEASE_ENVIRONMENTNAME

$newBlock = @($BlockStart, $blockContent, $BlockEnd) -join "`r`n"

# --- Apply to file: prefer sentinel pair, fall back to placeholder -----------
$utf8    = New-Object System.Text.UTF8Encoding($false)
$content = [System.IO.File]::ReadAllText($filePath, $utf8)

$sentinelPattern = "(?s)$([regex]::Escape($BlockStart)).*?$([regex]::Escape($BlockEnd))"

if ($content -match $sentinelPattern) {
    $content = [regex]::Replace($content, $sentinelPattern, { param($m) $newBlock }, 1)
    Write-Host "Replaced existing sentinel-bounded deployment-status block."
} elseif ($content.Contains($Placeholder)) {
    $content = $content.Replace($Placeholder, $newBlock)
    Write-Host "Injected fresh deployment-status block into placeholder."
} else {
    Write-Host "WARN: Neither sentinels '$BlockStart' nor placeholder '$Placeholder' found in $filePath; appending."
    $content = $content.TrimEnd() + "`r`n`r`n## Deployment status`r`n`r`n" + $newBlock + "`r`n"
}

[System.IO.File]::WriteAllText($filePath, $content, $utf8)

# --- Replace pending-release placeholder with live release link --------------
# Use [char]0x23F3 escape (HOURGLASS, U+23F3) so the matcher is byte-for-byte
# correct regardless of the script file's saved encoding.
$hourglass     = [char]0x23F3
$content       = [System.IO.File]::ReadAllText($filePath, $utf8)
$pendingInline = "$hourglass _**Awaiting deployment**_"
$releaseLink   = "[$env:RELEASE_RELEASENAME]($env:RELEASE_RELEASEWEBURL) $IconDone _Deployed_"

if ($content.Contains($pendingInline)) {
    $content = $content.Replace($pendingInline, $releaseLink)
    Write-Host "Replaced pending placeholder with: $releaseLink"
} elseif ($content.Contains('RELEASENOPLACEHOLDER')) {
    $content = $content.Replace('RELEASENOPLACEHOLDER', $releaseLink)
    Write-Host "Replaced legacy RELEASENOPLACEHOLDER with: $releaseLink"
} else {
    Write-Host "No release placeholder present (already substituted in an earlier stage?)."
}

[System.IO.File]::WriteAllText($filePath, $content, $utf8)

# --- Hand off file paths to subsequent tasks ---------------------------------
Write-Host "##vso[task.setvariable variable=wikiFilePath]$filePath"
Write-Host "##vso[task.setvariable variable=wikiPagePath]$relPath"
Write-Host "=== Update-WikiReleaseNotes.ps1 complete ==="
<#
.SYNOPSIS
    Updates the release-notes wiki page for a deployment.

.DESCRIPTION
    Used by Classic Release pipelines to update the wiki page for each
    deployment stage:
      1. Clone the project wiki repo.
      2. Build a colored mermaid flowchart from live release stage statuses.
      3. Replace the "Awaiting deployment" placeholder with a release link.
      4. Stage the file for the subsequent WikiUpdaterTask to push.

    Branch detection: uses Build.SourceBranchName to pick the wiki folder,
    so the SAME script works for any pipeline branch.

.PARAMETER Environment
    Environment name (fallback label when release REST query fails).

.PARAMETER BuildNumber
    Build number to locate the wiki page. Default: $(Build.BuildNumber).

.PARAMETER SourceBranchName
    Branch of the triggering build. Default: $(Build.SourceBranchName).

.PARAMETER WikiRepoUrlBase
    Wiki repo URL. Default: must be set by the caller.

.PARAMETER WikiBranch
    Wiki branch. Default: wikiMaster.

.PARAMETER TargetDir
    Clone directory. Default: $(System.DefaultWorkingDirectory)\wiki.

.PARAMETER Token
    Auth token. Default: $(System.AccessToken).

.PARAMETER EnvUrlMapJson
    Optional JSON object mapping environment names to D365 URLs.
    Example: '{"DEV":"https://myenv-dev.sandbox.operations.eu.dynamics.com/"}'
    If provided, a clickable environment links line is appended below the legend.

.EXAMPLE
    .\Update-WikiReleaseNotes.ps1 -Environment "DEV" -WikiRepoUrlBase "https://dev.azure.com/myorg/myproject/_git/myproject.wiki"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Environment,

    [string]$BuildNumber       = $env:BUILD_BUILDNUMBER,
    [string]$SourceBranchName  = $env:BUILD_SOURCEBRANCHNAME,
    [Parameter(Mandatory = $true)]
    [string]$WikiRepoUrlBase,
    [string]$WikiBranch        = "wikiMaster",
    [string]$TargetDir         = (Join-Path $env:SYSTEM_DEFAULTWORKINGDIRECTORY 'wiki'),
    [string]$Token             = $env:SYSTEM_ACCESSTOKEN,
    [string]$EnvUrlMapJson     = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BuildNumber))      { throw "BuildNumber is required." }
if ([string]::IsNullOrWhiteSpace($SourceBranchName)) { throw "SourceBranchName is required." }
if ([string]::IsNullOrWhiteSpace($Token))            { throw "Token is required (enable System.AccessToken on the agent job)." }

Write-Host "=== Update-WikiReleaseNotes.ps1 ==="
Write-Host "Environment        : $Environment"
Write-Host "BuildNumber        : $BuildNumber"
Write-Host "SourceBranchName   : $SourceBranchName"

# --- Parse optional env URL map ------------------------------------------------
$script:EnvUrlMap = @{}
if ($EnvUrlMapJson) {
    try { $script:EnvUrlMap = $EnvUrlMapJson | ConvertFrom-Json -AsHashtable } catch {
        Write-Host "WARN: Could not parse EnvUrlMapJson, skipping env links."
    }
}

# --- Derive wiki sub-folder from branch ----------------------------------------
switch -Wildcard ($SourceBranchName) {
    'prod'    { $wikiPath = 'Deployment-release-notes\Prod-branch\' }
    'main'    { $wikiPath = 'Deployment-release-notes\Main-branch\' }
    'hotfix*' { $wikiPath = 'Deployment-release-notes\Hotfix-branch\' }
    default   { $wikiPath = 'Deployment-release-notes\Release-branch\' }
}
Write-Host "Resolved wikiPath  : $wikiPath"

# --- Clone wiki ----------------------------------------------------------------
$repoUrl = $WikiRepoUrlBase -replace '^https://', "https://buildagent:$Token@"
git config --global core.longpaths true | Out-Null
if (Test-Path $TargetDir) { Remove-Item $TargetDir -Recurse -Force -ErrorAction SilentlyContinue }
git clone --depth 1 --branch $WikiBranch $repoUrl $TargetDir
if ($LASTEXITCODE -ne 0) { throw "git clone failed." }

# --- Locate wiki page ----------------------------------------------------------
$relPath  = Join-Path $wikiPath ("Build-{0}.md" -f $BuildNumber)
$filePath = Join-Path $TargetDir $relPath
if (-not (Test-Path $filePath)) { throw "Wiki file not found: $filePath" }

# --- Mermaid helpers -----------------------------------------------------------
function Convert-StatusToMermaid {
    param([string]$Status)
    switch -Wildcard ($Status) {
        'inProgress'           { return @{ Class = 'inprog';  Label = 'In progress' } }
        'queued'               { return @{ Class = 'inprog';  Label = 'Queued'      } }
        'scheduled'            { return @{ Class = 'inprog';  Label = 'Scheduled'   } }
        'succeeded'            { return @{ Class = 'done';    Label = 'Deployed'    } }
        'partiallySucceeded'   { return @{ Class = 'inprog';  Label = 'Partial'     } }
        'rejected'             { return @{ Class = 'failed';  Label = 'Rejected'    } }
        'canceled'             { return @{ Class = 'failed';  Label = 'Canceled'    } }
        'cancelled'            { return @{ Class = 'failed';  Label = 'Canceled'    } }
        default                { return @{ Class = 'pending'; Label = 'Pending'     } }
    }
}

$script:MermaidHeader = @(
    'flowchart LR',
    '  classDef done    fill:#22c55e,stroke:#16a34a,color:#fff',
    '  classDef inprog  fill:#f59e0b,stroke:#d97706,color:#fff',
    '  classDef pending fill:#94a3b8,stroke:#64748b,color:#fff',
    '  classDef failed  fill:#ef4444,stroke:#b91c1c,color:#fff'
)
$script:MermaidLegend = '**Legend**: 🟢 Deployed · 🟡 In progress · ⚪ Pending · 🔴 Failed'

function Format-MermaidNode {
    param([int]$Index, [string]$EnvName, [hashtable]$Entry)
    $id = ('N{0}' -f $Index)
    return ('  {0}["{1} - {2}"]:::{3}' -f $id, $EnvName, $Entry.Label, $Entry.Class), $id
}

function Build-EnvLinksLine {
    param([array]$EnvNames)
    if (-not $script:EnvUrlMap -or $script:EnvUrlMap.Count -eq 0) { return '' }
    $parts = @()
    foreach ($name in $EnvNames) {
        $n = if ($name -is [string]) { $name } else { $name.name }
        $url = $script:EnvUrlMap[$n.ToUpper()]
        if (-not $url) { $url = $script:EnvUrlMap[$n] }
        if ($url) { $parts += "[$n]($url)" }
    }
    if (-not $parts) { return '' }
    return '**Environments**: ' + ($parts -join ' · ')
}

function Build-MermaidBlock {
    param(
        [string]$CollectionUri, [string]$ProjectName, [string]$ReleaseId,
        [string]$Token, [string]$CurrentStageEnv, [string]$CurrentStageOverride
    )

    if ([string]::IsNullOrWhiteSpace($CollectionUri) -or [string]::IsNullOrWhiteSpace($ReleaseId)) {
        $entry = Convert-StatusToMermaid 'succeeded'
        $node, $null = Format-MermaidNode -Index 0 -EnvName $CurrentStageEnv -Entry $entry
        $lines = @(':::mermaid') + $script:MermaidHeader + @($node, ':::', '', $script:MermaidLegend)
        return $lines -join "`r`n"
    }

    $vsrmBase = $CollectionUri.TrimEnd('/').Replace('https://dev.azure.com/', 'https://vsrm.dev.azure.com/')
    $url      = "$vsrmBase/$ProjectName/_apis/release/releases/$ReleaseId" + '?api-version=7.1-preview.8'
    $headers  = @{ Authorization = "Bearer $Token" }

    try {
        $release = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
    } catch {
        $entry = Convert-StatusToMermaid 'succeeded'
        $node, $null = Format-MermaidNode -Index 0 -EnvName $CurrentStageEnv -Entry $entry
        $lines = @(':::mermaid') + $script:MermaidHeader + @($node, ':::', '', $script:MermaidLegend)
        return $lines -join "`r`n"
    }

    $envs = @($release.environments | Sort-Object rank)
    $nodeLines = @(); $ids = @(); $i = 0
    foreach ($e in $envs) {
        $effectiveStatus = if ($CurrentStageOverride -and $e.name -eq $CurrentStageOverride) { 'succeeded' } else { $e.status }
        $entry         = Convert-StatusToMermaid $effectiveStatus
        $nodeLine, $id = Format-MermaidNode -Index $i -EnvName $e.name -Entry $entry
        $nodeLines    += $nodeLine; $ids += $id; $i++
    }

    $edgeLine = if ($ids.Count -ge 2) { '  ' + ($ids -join ' --> ') } else { $null }
    $body     = @($script:MermaidHeader) + $nodeLines
    if ($edgeLine) { $body += $edgeLine }
    $envLinks = Build-EnvLinksLine -EnvNames $envs
    $lines    = @(':::mermaid') + $body + @(':::', '', $script:MermaidLegend)
    if ($envLinks) { $lines += $envLinks }
    return $lines -join "`r`n"
}

# --- Update mermaid block ------------------------------------------------------
$content        = Get-Content -Path $filePath -Raw -Encoding UTF8
$mermaidPattern = '(?ms)(:::mermaid\s.*?^:::)'
$placeholder    = '<!-- ENV-PROGRESS-BLOCK -->'

$newBlock = Build-MermaidBlock `
    -CollectionUri        $env:SYSTEM_COLLECTIONURI `
    -ProjectName          $env:SYSTEM_TEAMPROJECT `
    -ReleaseId            $env:RELEASE_RELEASEID `
    -Token                $Token `
    -CurrentStageEnv      $Environment `
    -CurrentStageOverride $env:RELEASE_ENVIRONMENTNAME

if ($content.Contains($placeholder)) {
    $content = $content.Replace($placeholder, $newBlock)
    Set-Content -Path $filePath -Value $content -Encoding UTF8 -NoNewline
    Write-Host "Injected mermaid block into placeholder."
} elseif ($content -match $mermaidPattern) {
    $content = $content.Replace($matches[1], $newBlock)
    Set-Content -Path $filePath -Value $content -Encoding UTF8 -NoNewline
    Write-Host "Replaced existing mermaid block."
} else {
    Write-Host "WARN: No placeholder or mermaid block found; skipping."
}

# --- Replace deployment placeholder with release link --------------------------
$content = Get-Content -Path $filePath -Raw -Encoding UTF8
$pendingText = '⏳ _**Awaiting deployment**_'
$releaseLink = "[$env:RELEASE_RELEASENAME]($env:RELEASE_RELEASEWEBURL)"
$deployedText = "✅ **Deployed**: $releaseLink"

if ($content.Contains($pendingText)) {
    $content = $content.Replace($pendingText, $deployedText)
    Set-Content -Path $filePath -Value $content -Encoding UTF8 -NoNewline
    Write-Host "Replaced pending placeholder with: $deployedText"
} elseif ($content.Contains('RELEASENOPLACEHOLDER')) {
    $content = $content.Replace('RELEASENOPLACEHOLDER', $releaseLink)
    Set-Content -Path $filePath -Value $content -Encoding UTF8 -NoNewline
    Write-Host "Replaced legacy RELEASENOPLACEHOLDER."
} else {
    Write-Host "No release placeholder present."
}

# --- Output variables for subsequent tasks -------------------------------------
Write-Host "##vso[task.setvariable variable=wikiFilePath]$filePath"
Write-Host "##vso[task.setvariable variable=wikiPagePath]$relPath"
Write-Host "=== Update-WikiReleaseNotes.ps1 complete ==="
