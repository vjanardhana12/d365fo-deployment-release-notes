<#
.SYNOPSIS
    Updates the release-notes wiki page for a deployment.

.DESCRIPTION
    Called by the Classic Release pipeline (1760-Smartcore-HUB-RELEASE) as a
    POST-deployment task on every stage. Responsibilities:

      1. Clone the Wiki repo using System.AccessToken.
      2. Locate the build's wiki release-note page (Build-<BuildNumber>.md)
         under the per-branch sub-folder (Main-branch / Prod-branch /
         Hotfix-branch / Release-branch).
      3. Replace the <!-- ENV-PROGRESS-BLOCK --> placeholder (first run) or the
         existing sentinel-bounded block (subsequent runs) with a fresh
         compact deployment-status strip built from the LIVE release stages
         queried via Azure DevOps REST API.
      4. Substitute the "Awaiting deployment" placeholder with a link back to
         the running release.
      5. (Optional) Create an annotated git tag on the build's source commit
         when a tag-triggering environment succeeds (UAT for release branch,
         PROD for prod / hotfix branches).
      6. Stage the file for the subsequent "Git based WIKI File Updater" task.

    Visual style:
        - Compact strip:  [DevTest](url) 🟢 -> [UAT](url) 🟢 -> [PREPROD](url) 🟢
        - Traffic-light icons:  🟢 succeeded  � partial
                                🔴 failed     ⚪ pending
          (in-progress stages render as ⚪ pending; the post-deploy task flips
           the current stage to 🟢 on completion.)
        - Sentinel markers used for safe re-replacement on subsequent stages:
            <!-- ENV-PROGRESS-START -->
            ...content...
            <!-- ENV-PROGRESS-END -->

    All emoji output uses [char]::ConvertFromUtf32 so the script is safe under
    Windows PowerShell 5.1 default encoding.

.PARAMETER Environment
    LCS environment name (e.g. cbhub-devtest, cbhub-uat). Used only as a
    fallback label when the live release REST query fails.

.PARAMETER BuildNumber
    Build number of the triggering build. Default: $env:BUILD_BUILDNUMBER.

.PARAMETER SourceBranchName
    Branch of the triggering build, used to pick the wiki sub-folder.
    Default: $env:BUILD_SOURCEBRANCHNAME.

.PARAMETER WikiRepoUrlBase
    Wiki repo URL. Default: carlsberggroup/1760-SmartCore-HUB wiki.

.PARAMETER TargetDir
    Where to clone the wiki. Default: $(System.DefaultWorkingDirectory)\wiki.

.PARAMETER Token
    PAT or System.AccessToken for git auth. Default: $env:SYSTEM_ACCESSTOKEN.

.PARAMETER CreateTag
    If $true, create an annotated tag on the build's source commit when this
    stage matches the per-branch tag-trigger (UAT for release, PROD for
    prod / hotfix). Default: $true.

.NOTES
    Owner   : MS team (Vinod Kumar K J)
    Updated : 2026-05-16  -  switched mermaid -> compact strip; added tagging.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Environment,

    [string]$BuildNumber       = $env:BUILD_BUILDNUMBER,
    [string]$SourceBranchName  = $env:BUILD_SOURCEBRANCHNAME,
    [string]$WikiRepoUrlBase   = "https://dev.azure.com/carlsberggroup/1760-SmartCore-HUB/_git/1760-SmartCore-HUB.wiki",
    [string]$WikiBranch        = "wikiMaster",
    [string]$TargetDir         = (Join-Path $env:SYSTEM_DEFAULTWORKINGDIRECTORY 'wiki'),
    [string]$Token             = $env:SYSTEM_ACCESSTOKEN,
    [bool]  $CreateTag         = $true
)

$ErrorActionPreference = 'Stop'

# Failure-tolerance: any unhandled exception below is logged as a pipeline
# warning and the script exits 0, so a transient wiki/notes problem does NOT
# fail the deployment stage. The wiki update is non-critical; the actual
# environment deployment (which already ran before this task) is what matters.
trap {
    Write-Host "##vso[task.logissue type=warning]Update-WikiReleaseNotes failed (non-fatal): $($_.Exception.Message)"
    # Hand a throw-away placeholder to the downstream 'Commit & push wiki update' task so
    # it doesn't error with 'Cannot find the file'. The placeholder is outside the wiki
    # clone, so no actual wiki change gets pushed.
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
if ([string]::IsNullOrWhiteSpace($Token))            { throw "Token is required (env SYSTEM_ACCESSTOKEN not set or not enabled on the agent job)." }

Write-Host "=== Update-WikiReleaseNotes.ps1 ==="
Write-Host "Environment        : $Environment"
Write-Host "BuildNumber        : $BuildNumber"
Write-Host "SourceBranchName   : $SourceBranchName"
Write-Host "TargetDir          : $TargetDir"
Write-Host "CreateTag          : $CreateTag"

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

# Environment name -> D365 URL slug
$script:EnvUrlMap = @{
    'DEV'         = 'cbhub-devtest'
    'DEVTEST'     = 'cbhub-devtest'
    'SIT'         = 'cbhub-sit-e2e'
    'SIT-E2E'     = 'cbhub-sit-e2e'
    'UAT'         = 'cbhub-uat'
    'CONSTEST'    = 'cbhub-constest'
    'DATAMIG'     = 'cbhub-datamigration'
    'DATAMIGRATION' = 'cbhub-datamigration'
    'PROCESSTEST' = 'cbhub-processtest'
    'CUSTEST'     = 'cbhub-custest'      # legacy single-t alias
    'CUSTTEST'    = 'cbhub-custtest'     # current env in release pipeline (CustTest)
    'GOLDCONFIG'  = 'cbhub-goldconfig'
    'GOLDENCONFIG'= 'cbhub-goldconfig'
    'TRAIN'       = 'cbhub-train'
    'TRAINING'    = 'cbhub-train'
    'PREPROD'     = 'cbhub-preprod'
    'PROD'        = 'cbhub'
}
$script:EnvUrlBase = 'sandbox.operations.eu.dynamics.com'

function Get-EnvUrl {
    param([string]$EnvName)
    $slug = $script:EnvUrlMap[$EnvName.ToUpper()]
    if ($slug) { return "https://$slug.$($script:EnvUrlBase)/" }
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
git config --global core.longpaths true | Out-Host

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
# Stages named "*Upload to Asset Library*" are MS-internal plumbing; hide them.
$excludedNamePatterns = @('Upload to Asset Library')

# Tag triggers per branch / stage:
#   release  -> uat-<buildNumber>    when UAT  succeeds  (date-style, sprint candidate)
#   prod     -> v<MAJOR.MINOR.PATCH> when PROD succeeds  (SemVer, production)
#   hotfix*  -> NO TAG (branch is short-lived & deleted post merge-back; the v<MAJOR.MINOR.PATCH>
#              tag created on PROD stage is the single source of truth for the deployed hotfix)
#
# SemVer (prod only):
#   - Reads the RELEASE_TYPE pipeline variable (settable at release time, default 'Sprint'):
#       Sprint  -> MINOR bump  (v1.0.0 -> v1.1.0)   normal sprint promotion
#       Hotfix  -> PATCH bump  (v1.1.0 -> v1.1.1)   hotfix to prod
#       Country -> MAJOR bump  (v1.x.y -> v2.0.0)   new country go-live
#   - A first-task validator on the PROD stage rejects any other value before deploy starts.
#   - Reads latest 'v*.*.*' tag from origin to compute next version.
#   - Falls back to 'v1.0.0' if no prior SemVer tag exists (very first PROD deploy).
function Should-CreateTag {
    param([string]$Branch, [string]$StageName)
    if (-not $StageName) { return $false }
    $upper = $StageName.ToUpper()
    switch -Wildcard ($Branch) {
        'release' { return ($upper -eq 'UAT') }
        'prod'    { return ($upper -eq 'PROD') }
        default   { return $false }   # hotfix* intentionally tag-free
    }
}

function Get-NextSemVer {
    param([string]$Token)

    # Records the previous v*.*.* tag in $script:PreviousSemVer for inclusion in tag message.
    $script:PreviousSemVer = '(none)'

    # 1. Read latest v*.*.* tag from origin.
    $cloneUrl = "https://dev.azure.com/carlsberggroup/$($env:SYSTEM_TEAMPROJECT)/_git/1760-Smartcore-HUB"
    $cloneUrlAuth = $cloneUrl -replace '^https://', "https://buildagent:$Token@"
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

    # 2. No prior SemVer tag - seed v1.0.0 (very first PROD deploy of the program).
    if (-not $latest) {
        Write-Host "Get-NextSemVer: no prior v*.*.* tag found - seeding v1.0.0."
        return 'v1.0.0'
    }

    # 3. Map RELEASE_TYPE -> bump component (case-insensitive). Default = Sprint.
    #    ADO release variable 'ReleaseType' -> env var $env:RELEASETYPE (no underscore).
    $rt = $env:RELEASETYPE
    if ([string]::IsNullOrWhiteSpace($rt)) { $rt = 'Sprint' }
    $rt = $rt.Trim()

    switch -Regex ($rt) {
        '^(?i:sprint)$'  { $next = "v$($latest.Major).$($latest.Minor + 1).0";          $bumped = 'MINOR (Sprint)' }
        '^(?i:hotfix)$'  { $next = "v$($latest.Major).$($latest.Minor).$($latest.Patch + 1)"; $bumped = 'PATCH (Hotfix)' }
        '^(?i:country)$' { $next = "v$($latest.Major + 1).0.0";                          $bumped = 'MAJOR (Country)' }
        default {
            throw "RELEASE_TYPE '$rt' invalid - expected 'Sprint' | 'Hotfix' | 'Country'. (The pre-deploy validator should have caught this.)"
        }
    }
    Write-Host "Get-NextSemVer: latest='$($latest.Tag)' RELEASE_TYPE='$rt' bump=$bumped next='$next'."
    return $next
}

function Get-TagName {
    param([string]$Branch, [string]$BuildNumber, [string]$Token)
    switch -Wildcard ($Branch) {
        'release' { return "uat-$BuildNumber" }
        'prod'    { return (Get-NextSemVer -Token $Token) }
        default   { return "build-$BuildNumber" }   # never reached - hotfix* is tag-free
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
        Write-Host "WARN: Could not query release $ReleaseId from $url. $($_.Exception.Message). Emitting single-env fallback."
        $line   = "[$CurrentStageEnv]($([string](Get-EnvUrl $CurrentStageEnv))) $IconDone"
        $legend = "<sub>**Legend**: $IconDone Deployed $MidDot $IconPartial Partial $MidDot $IconFailed Failed $MidDot $IconPending Pending</sub>"
        return ($line + "`r`n`r`n" + $legend), @()
    }

    $envs = @($release.environments | Sort-Object rank | Where-Object {
        $n = $_.name
        -not ($excludedNamePatterns | Where-Object { $n -like "*$_*" })
    })

    $parts = @(foreach ($e in $envs) {
        # The currently-deploying stage's status is still 'inProgress' when this
        # script runs as a post-deployment task; treat it as succeeded.
        $status = if ($CurrentStageOverride -and $e.name -eq $CurrentStageOverride) { 'succeeded' } else { $e.status }
        $icon   = Get-StageIcon $status
        $url    = Get-EnvUrl $e.name
        if ($url) { "[$($e.name)]($url) $icon" } else { "$($e.name) $icon" }
    })

    # --- Monotonic-forward: never downgrade a previously-completed stage ----
    # ADO release REST snapshots can lag by several seconds across rapid stage
    # transitions, so a stage that just finished may briefly show as
    # `inProgress` / `notStarted` when a sibling stage's post-deploy task fires
    # moments later, causing the icon to flicker 🟢 -> ⚪. Carry forward any
    # prior 🟢 / 🟠 / 🔴 if the new render says ⚪.
    if ($PriorContent) {
        $sentinelRx = "(?s)$([regex]::Escape($BlockStart)).*?$([regex]::Escape($BlockEnd))"
        if ($PriorContent -match $sentinelRx) {
            $oldStrip = $Matches[0]
            $iconAlt  = (@($IconDone, $IconPartial, $IconFailed) | ForEach-Object { [regex]::Escape($_) }) -join '|'
            for ($i = 0; $i -lt $envs.Count; $i++) {
                $nm     = [regex]::Escape($envs[$i].name)
                $rxOld  = "\[$nm\][^\r\n]*?\s+($iconAlt)"
                if (($oldStrip -match $rxOld) -and ($parts[$i] -like "*$IconPending*")) {
                    $oldIcon  = $Matches[1]
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

# Compute the tag link up-front so we can also inject it into the H1 subtitle
# on the same pipeline run that creates the tag. Tag URL is valid the moment
# the tag is pushed later in this script.
$plannedTag = ''
if ($CreateTag -and (Should-CreateTag -Branch $SourceBranchName -StageName $env:RELEASE_ENVIRONMENTNAME)) {
    $plannedTag = Get-TagName -Branch $SourceBranchName -BuildNumber $BuildNumber -Token $Token
}

$blockContent, $allEnvs = Build-EnvBlock `
    -CollectionUri        $env:SYSTEM_COLLECTIONURI `
    -ProjectName          $env:SYSTEM_TEAMPROJECT `
    -ReleaseId            $env:RELEASE_RELEASEID `
    -Token                $Token `
    -CurrentStageEnv      $Environment `
    -CurrentStageOverride $env:RELEASE_ENVIRONMENTNAME `
    -PriorContent         $(
        $utf8Pre = New-Object System.Text.UTF8Encoding($false)
        if (Test-Path $filePath) { [System.IO.File]::ReadAllText($filePath, $utf8Pre) } else { '' }
    )

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
    Write-Host "WARN: Neither sentinels '<!-- ENV-PROGRESS-START -->' nor placeholder '<!-- ENV-PROGRESS-BLOCK -->' found in $filePath; appending."
    $content = $content.TrimEnd() + "`r`n`r`n## Deployment status`r`n`r`n" + $newBlock + "`r`n"
}

[System.IO.File]::WriteAllText($filePath, $content, $utf8)

# --- Shorten any 40-char commit SHA shown inside `[`<sha>`](.../commit/<sha>)` to first 8 chars (link target preserved) ---
$content = [System.IO.File]::ReadAllText($filePath, $utf8)
$content = [regex]::Replace($content, '\[`([a-f0-9]{40})`\](\([^)]*?/commit/[a-f0-9]{40}[^)]*\))', { param($m) "[``$($m.Groups[1].Value.Substring(0,8))``]$($m.Groups[2].Value)" })
[System.IO.File]::WriteAllText($filePath, $content, $utf8)

# --- Inject tag link into metadata table (only when tag is being created) ---
# Template ships these two rows when sourceBranch is release/prod:
#   | **Triggered by**   | ... | **Commit** | [`<sha>`](...) |
#   | **Tag**            | _Pending_ | **Compare** | _Pending_ |
# The standalone "> **Commit** [...]" subtitle was removed from the template - commit now lives in the table only.
if ($plannedTag) {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    $tagUrl  = "https://dev.azure.com/carlsberggroup/$($env:SYSTEM_TEAMPROJECT)/_git/1760-Smartcore-HUB?version=GT$([uri]::EscapeDataString($plannedTag))"
    # Fill the metadata table's "Tag" cell: replace `_Pending_` (and any previously-injected tag link).
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

# --- Inject Compare link into metadata table (always, all branches) ---
# Find previous successful build on the same branch+definition via REST API,
# then build a commit-to-commit branchCompare URL (GC<sha>) - tag-based GT<tag>
# URLs render an empty diff in the DevOps UI.
$script:PrevBuildSha     = $null
$script:CurrentBuildSha  = $env:BUILD_SOURCEVERSION
try {
    $prevBuildNum = $null
    $prevSha      = $null
    $curSha       = $env:BUILD_SOURCEVERSION
    $curBuildNum  = $env:BUILD_BUILDNUMBER
    # Use BUILD_DEFINITIONID (always the *build* definition, in both build and
    # release pipeline contexts). SYSTEM_DEFINITIONID is the release definition
    # when this script runs from a release stage and returns 0 builds.
    $buildDefId = if ($env:BUILD_DEFINITIONID) { $env:BUILD_DEFINITIONID } else { $env:SYSTEM_DEFINITIONID }
    if ($buildDefId -and $env:BUILD_BUILDID -and $env:BUILD_SOURCEBRANCH -and $curSha) {
        $apiBase = "https://dev.azure.com/carlsberggroup/$($env:SYSTEM_TEAMPROJECT)/_apis/build/builds"
        $qs = "definitions=$buildDefId&branchName=$([uri]::EscapeDataString($env:BUILD_SOURCEBRANCH))&statusFilter=completed&resultFilter=succeeded&`$top=5&queryOrder=finishTimeDescending&api-version=7.0"
        $resp = Invoke-RestMethod -Uri ("{0}?{1}" -f $apiBase, $qs) -Headers @{ Authorization = "Bearer $Token" }
        $prevBld = $resp.value | Where-Object { $_.id -lt [int]$env:BUILD_BUILDID -and $_.sourceVersion -and $_.sourceVersion -ne $curSha } | Select-Object -First 1
        if ($prevBld) {
            $prevBuildNum          = $prevBld.buildNumber
            $prevSha               = $prevBld.sourceVersion
            $script:PrevBuildSha   = $prevBld.sourceVersion
        }
    }

    if ($prevSha -and $curSha) {
        $compareUrl  = "https://dev.azure.com/carlsberggroup/$($env:SYSTEM_TEAMPROJECT)/_git/1760-Smartcore-HUB/branchCompare?baseVersion=GC$prevSha&targetVersion=GC$curSha&_a=files"
        $compareCell = "[``$prevBuildNum`` -> ``$curBuildNum``]($compareUrl)"
    } else {
        $compareCell = $null
    }

    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    if ($compareCell) {
        # Replace whatever is currently in the Compare cell with the freshly-resolved link.
        $content = [regex]::Replace(
            $content,
            '(\|\s\*\*Compare\*\*\s+\|\s)(?:_Pending_|\[[^\]]+\]\([^)]+\)|_n/a[^|]*)(\s\|)',
            { param($m) $m.Groups[1].Value + $compareCell + $m.Groups[2].Value },
            1
        )
        [System.IO.File]::WriteAllText($filePath, $content, $utf8)
        Write-Host ("Injected compare ('{0}' -> '{1}') into metadata table." -f $(if ($prevBuildNum) { $prevBuildNum } else { '(none)' }), $curBuildNum)
    } else {
        # Only fill `_Pending_` with the first-build marker. NEVER overwrite an
        # already-populated `[...](url)` cell, otherwise a deployment-stage rerun
        # where the lookup failed would clobber the correct value written by the
        # build stage.
        $content = [regex]::Replace(
            $content,
            '(\|\s\*\*Compare\*\*\s+\|\s)_Pending_(\s\|)',
            { param($m) $m.Groups[1].Value + '_n/a (first build)_' + $m.Groups[2].Value },
            1
        )
        [System.IO.File]::WriteAllText($filePath, $content, $utf8)
        Write-Host "No previous build found - Compare cell left as 'n/a (first build)' (or unchanged if already populated)."
    }
} catch {
    Write-Host "WARN: Could not inject compare link: $($_.Exception.Message)."
}

# --- Inject Post-Deployment Actions section -------------------------------
# Surface only the few categories where deployers must act manually:
#   - Security objects changed     -> verify role/duty assignments
#   - Data entities changed        -> refresh entity list in Data Management
#   - Workflow objects changed     -> activate/configure workflow in module
#   - Number sequences changed     -> run Generate wizard
#   - Financial dimensions changed -> activate under GL > COA > Dimensions
#   - Configuration keys changed   -> review under System administration
#   - Business events changed      -> activate/configure under System admin
# Plus a "New objects introduced" summary (counts only, added-only) for the
# same categories plus batch jobs (new menu items pointing to *Controller /
# *Batch / *Batchable classes).
# Modifications of existing objects are NOT listed (DB sync + extension
# framework handle them; deployer can use Compare link for detail).
# Note: D365FO metadata layout is .../<AxObjectType>/<Name>.xml - detection
# uses the *parent folder* (object type), not file extension.
try {
    $pPrev = $script:PrevBuildSha
    $pCur  = $script:CurrentBuildSha
    if ($pPrev -and $pCur -and $pPrev -ne $pCur) {
        $diffUri = "https://dev.azure.com/carlsberggroup/$($env:SYSTEM_TEAMPROJECT)/_apis/git/repositories/1760-Smartcore-HUB/diffs/commits?baseVersion=$pPrev&baseVersionType=commit&targetVersion=$pCur&targetVersionType=commit&`$top=2000&api-version=7.0"
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
        if ($secChanges) {
            $reminders += ([char]::ConvertFromUtf32(0x1F510) + " **Security objects changed** $([char]::ConvertFromUtf32(0x2014)) verify role/duty assignments in target environment.")
        }
        if ($entChanges) {
            $reminders += ([char]::ConvertFromUtf32(0x1F5C2) + " **Data entities changed** $([char]::ConvertFromUtf32(0x2014)) refresh entity list in Data Management > Framework parameters.")
        }
        if ($wfChanges) {
            $reminders += ([char]::ConvertFromUtf32(0x1F501) + " **Workflow objects changed** $([char]::ConvertFromUtf32(0x2014)) activate/configure workflow under the relevant module > Setup > Workflows.")
        }
        if ($numSeqChanges) {
            $reminders += ([char]::ConvertFromUtf32(0x1F522) + " **Number sequences changed** $([char]::ConvertFromUtf32(0x2014)) run the Generate wizard under Organization administration > Number sequences.")
        }
        if ($dimChanges) {
            $reminders += ([char]::ConvertFromUtf32(0x1F3F7) + " **Financial dimensions changed** $([char]::ConvertFromUtf32(0x2014)) activate under General ledger > Chart of accounts > Dimensions > Financial dimensions.")
        }
        if ($cfgChanges) {
            $reminders += ([char]::ConvertFromUtf32(0x2699)  + " **Configuration keys changed** $([char]::ConvertFromUtf32(0x2014)) review under System administration > Setup > Licensing > License configuration.")
        }
        if ($bizEvtChanges) {
            $reminders += ([char]::ConvertFromUtf32(0x1F4E1) + " **Business events changed** $([char]::ConvertFromUtf32(0x2014)) activate/configure under System administration > Setup > Business events.")
        }

        # ---------- New-objects counts (added only) ----------
        $secAdded    = $secChanges    | Where-Object { $_.changeType -match '(?i)add' }
        $entAdded    = $entChanges    | Where-Object { $_.changeType -match '(?i)add' }
        $wfAdded     = $wfChanges     | Where-Object { $_.changeType -match '(?i)add' }
        $numSeqAdded = $numSeqChanges | Where-Object { $_.changeType -match '(?i)add' }
        $dimAdded    = $dimChanges    | Where-Object { $_.changeType -match '(?i)add' }
        $cfgAdded    = $cfgChanges    | Where-Object { $_.changeType -match '(?i)add' }
        $bizEvtAdded = $bizEvtChanges | Where-Object { $_.changeType -match '(?i)add' }

        # Batch jobs: added Action menu items whose <Object> references an added
        # *Controller / *Batch / *Batchable class. Requires a per-item content
        # fetch but cost is bounded by # of added menu items (usually small).
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
                    $itemUri = "https://dev.azure.com/carlsberggroup/$($env:SYSTEM_TEAMPROJECT)/_apis/git/repositories/1760-Smartcore-HUB/items?path=$([uri]::EscapeDataString($mi.item.path))&versionDescriptor.version=$pCur&versionDescriptor.versionType=commit&includeContent=true&api-version=7.0"
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
        if ($entAdded) {
            $word = if ($entAdded.Count -eq 1) { 'data entity' } else { 'data entities' }
            $newLines += ([char]::ConvertFromUtf32(0x1F5C2) + " Data entities: $($entAdded.Count) new $word")
        }
        if ($wfAdded) {
            $word = if ($wfAdded.Count -eq 1) { 'workflow object' } else { 'workflow objects' }
            $newLines += ([char]::ConvertFromUtf32(0x1F501) + " Workflows: $($wfAdded.Count) new $word")
        }
        if ($numSeqAdded) {
            $word = if ($numSeqAdded.Count -eq 1) { 'reference/scope/group' } else { 'references/scopes/groups' }
            $newLines += ([char]::ConvertFromUtf32(0x1F522) + " Number sequences: $($numSeqAdded.Count) new $word")
        }
        if ($dimAdded) {
            $word = if ($dimAdded.Count -eq 1) { 'dimension' } else { 'dimensions' }
            $newLines += ([char]::ConvertFromUtf32(0x1F3F7) + " Financial dimensions: $($dimAdded.Count) new $word")
        }
        if ($cfgAdded) {
            $word = if ($cfgAdded.Count -eq 1) { 'key' } else { 'keys' }
            $newLines += ([char]::ConvertFromUtf32(0x2699)  + " Configuration keys: $($cfgAdded.Count) new $word")
        }
        if ($bizEvtAdded) {
            $word = if ($bizEvtAdded.Count -eq 1) { 'business event' } else { 'business events' }
            $newLines += ([char]::ConvertFromUtf32(0x1F4E1) + " Business events: $($bizEvtAdded.Count) new $word")
        }
        if ($batchJobCount -gt 0) {
            $word = if ($batchJobCount -eq 1) { 'batch job' } else { 'batch jobs' }
            $newLines += ([char]::ConvertFromUtf32(0x23F0) + " Batch jobs: $batchJobCount new $word (schedule under System administration > Inquiries > Batch jobs)")
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
            Write-Host "Injected empty Post-Deployment Actions section (no prev SHA - first build or unknown baseline)."
        }
    }
} catch {
    Write-Host "WARN: Could not generate Post-Deployment Actions: $($_.Exception.Message)."
}

# --- Inject Priority Test Items callout (S1 / S2 bugs) -----------------------
# Parse the rendered Bugs table; if any row has Severity 1-Critical or 2-High,
# surface a prominent callout near the top so testers know what to validate
# first. Idempotent: skipped if the callout already exists.
try {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    if ($content -notmatch '(?m)^## Priority Test Items') {
        # Extract the Bugs section (between '## Bugs' and the next '## ' header)
        $bugsMatch = [regex]::Match($content, '(?ms)^## Bugs\s*(.+?)(?=^## )')
        $priorityBugs = @()
        if ($bugsMatch.Success) {
            $bugsBlock = $bugsMatch.Groups[1].Value
            # Skip header (| **ID** | ...) and separator (|---|---|) lines.
            # Skip the empty-state placeholder row (| - | _No bugs..._ | ...).
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
                # Severity values: "1 - Critical", "2 - High", or just "1" / "2".
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
            $iconAlert = [char]::ConvertFromUtf32(0x1F6A8)   # rotating light
            $iconFire  = [char]::ConvertFromUtf32(0x1F525)   # fire
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

            # Insert before Post-Deployment Actions if present, else before User Stories.
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
# Keep the table structure intact; only re-order data rows so S1/S2 fixes
# naturally appear at the top of the Bugs table.
try {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    $bugsRx = [regex]'(?ms)(^## Bugs\s*\r?\n)(\|\s\*\*ID[^\r\n]+\r?\n\|[-\s|]+\|\s*\r?\n)((?:\|[^\r\n]+\r?\n)+)'
    $m = $bugsRx.Match($content)
    if ($m.Success) {
        $header = $m.Groups[2].Value
        $rowsBlock = $m.Groups[3].Value
        $rows = $rowsBlock -split "`r?`n" | Where-Object { $_ -match '^\|' }
        # Keep placeholder row (no real data) untouched if it's the only row.
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
# Pattern: header row + separator row + a single placeholder row
#   `| - | _No X linked..._ | - | ... |`
# becomes a single `_No X linked..._` line. Trims 3 fat rows per empty section.
try {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    # Matches header + separator + a placeholder row with N leading "-" cells before
    # the italic placeholder cell, and any number of trailing cells (e.g. the Notes
    # table has 2 "-" cells before `_No release notes..._` and 2 "-" cells after).
    $emptyRx = [regex]'(?ms)^\|\s\*\*[^\r\n]+\|\s*\r?\n\|[-\s|]+\|\s*\r?\n\|(?:\s-\s\|)+\s_([^_]+)_\s\|(?:[^\r\n|]*\|)*\s*\r?\n'
    $new = $emptyRx.Replace($content, { param($m) "_" + $m.Groups[1].Value + "_`r`n" })
    if ($new -ne $content) {
        $trimmed = ($content -split "`n").Count - ($new -split "`n").Count
        [System.IO.File]::WriteAllText($filePath, $new, $utf8)
        $content = $new
        Write-Host "Collapsed $trimmed empty-state table line(s) to italic lines."
    }
} catch {
    Write-Host "WARN: Could not collapse empty-state tables: $($_.Exception.Message)."
}

# --- Drop trailing placeholder row from tables that DO have real data --------
# The Notes template always emits a `| - | - | _No X..._ | - | - |` trailing
# row regardless of whether real rows above it matched the Handlebars filter.
# If at least one real row exists, drop the placeholder row so the table is
# clean. We do this generically: any data table row whose only non-`-` cell is
# an italic `_...._` placeholder is removed when another data row precedes it.
try {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    # Match: a data row (starts with `| [` indicating a markdown link) followed
    # eventually by a placeholder row in the same table block (no blank line and
    # no `## ` heading between them).
    $placeholderRx = [regex]'(?m)^\|(?:\s-\s\|)+\s_[^_]+_\s\|[^\r\n]*\r?\n'
    $blocks = [regex]::Split($content, '(?m)(?=^## )')
    $changed = $false
    for ($i = 0; $i -lt $blocks.Count; $i++) {
        $b = $blocks[$i]
        # A data row is a table row containing a markdown link (heuristic: `| [`).
        if ($b -match '(?m)^\|\s*\[' -and $b -match $placeholderRx) {
            $blocks[$i] = $placeholderRx.Replace($b, '', 1)
            $changed = $true
        }
    }
    if ($changed) {
        $content = ($blocks -join '')
        [System.IO.File]::WriteAllText($filePath, $content, $utf8)
        Write-Host "Stripped trailing placeholder row(s) from non-empty tables."
    }
} catch {
    Write-Host "WARN: Could not strip trailing placeholder rows: $($_.Exception.Message)."
}

# --- Attribute cherry-picked PRs to the original author ----------------------
# When a PR is created by cherry-picking commits from another branch, attribute
# the row to the ORIGINAL author rather than the person who forwarded it.
# Detection (in order):
#   1. Commit body contains `(cherry picked from commit <sha>)` -- the explicit
#      marker added by `git cherry-pick -x`. We look up that commit's author.
#   2. Fallback: examine the PR's commits and find one whose `author.name`
#      differs from the PR's "Raised by" name. `git cherry-pick` (with or
#      without -x) and ADO's UI cherry-pick BOTH preserve the original author,
#      so this catches the common case where -x was not used.
try {
    $content = [System.IO.File]::ReadAllText($filePath, $utf8)
    $repoApi = "https://dev.azure.com/carlsberggroup/$($env:SYSTEM_TEAMPROJECT)/_apis/git/repositories/1760-Smartcore-HUB"
    $hdrs = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    # Match PR rows: | [!12345](url) | title | RaisedBy | source | target | ...
    $prRowRx = [regex]'(?m)^(\|\s\[!(\d+)\]\([^)]+\)\s\|\s[^|]+\|\s)([^|]+?)(\s\|)'
    $swapped = 0
    $newContent = $prRowRx.Replace($content, {
        param($m)
        $prId = $m.Groups[2].Value
        $raisedBy = $m.Groups[3].Value.Trim()
        try {
            $commits = Invoke-RestMethod -Uri "$repoApi/pullRequests/$prId/commits?api-version=7.0" -Headers $hdrs -ErrorAction Stop
            $origAuthor = $null
            # Strategy 1: explicit (cherry picked from commit X) marker
            foreach ($c in $commits.value) {
                if ($c.comment -match '\(cherry picked from commit ([0-9a-f]{7,40})\)') {
                    try {
                        $origCommit = Invoke-RestMethod -Uri "$repoApi/commits/$($matches[1])?api-version=7.0" -Headers $hdrs -ErrorAction Stop
                        if ($origCommit.author.name) { $origAuthor = $origCommit.author.name; break }
                    } catch { }
                }
            }
            # Strategy 2: fallback -- commit's preserved author differs from PR creator.
            # Both names come from ADO REST and include the "(EXT)" suffix uniformly,
            # so direct string comparison is reliable -- no normalization needed.
            if (-not $origAuthor) {
                foreach ($c in $commits.value) {
                    $authorName = $c.author.name
                    if ($authorName -and $authorName -ne $raisedBy) { $origAuthor = $authorName; break }
                }
            }
            if ($origAuthor -and $origAuthor -ne $raisedBy) {
                $script:swapped++
                return $m.Groups[1].Value + "$origAuthor _(cherry-picked by $raisedBy)_" + $m.Groups[4].Value
            }
        } catch {
            # Network / permission errors: leave row untouched.
        }
        return $m.Value
    })
    if ($newContent -ne $content) {
        [System.IO.File]::WriteAllText($filePath, $newContent, $utf8)
        Write-Host "Re-attributed $swapped cherry-picked PR row(s) to original author."
    }
} catch {
    Write-Host "WARN: Could not re-attribute cherry-picked PRs: $($_.Exception.Message)."
}

# NOTE: We intentionally do NOT strip the " (EXT)" suffix from author/reviewer
# cells. ADO carries the suffix for external (vendor) accounts uniformly across
# both PR JSON and git commit metadata, so keeping it everywhere is consistent.
# Earlier we stripped it for cosmetic reasons, but the strip ran AFTER cherry-pick
# re-attribution, which produced inconsistent rows when manual edits or downstream
# tooling re-introduced the suffix. Keeping the raw display name avoids that drift.

# --- Replace pending-release placeholder with live release link --------------
# Use [char]0x23F3 escape (HOURGLASS, U+23F3) so the matcher is byte-for-byte
# correct regardless of the script file's saved encoding (ANSI / UTF-8 / UTF-8-BOM).
# Template files are authored as UTF-8 (no BOM) and contain the literal U+23F3,
# but if this script gets saved by an editor in a different encoding the literal
# would silently mismatch and the "Awaiting deployment" line would never flip.
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
# (Helpers Should-CreateTag / Get-TagName are defined near the top of this
# script so we can also surface the tag link inside the deployment-status
# block before the tag is actually pushed.)
if ($CreateTag -and (Should-CreateTag -Branch $SourceBranchName -StageName $env:RELEASE_ENVIRONMENTNAME)) {
    $tagName = Get-TagName -Branch $SourceBranchName -BuildNumber $BuildNumber -Token $Token
    $commit  = $env:BUILD_SOURCEVERSION
    if (-not $commit) { Write-Host "WARN: BUILD_SOURCEVERSION not set; skipping tag."; }
    else {
        Write-Host "Tagging commit $commit as $tagName ..."

        $repoUrl  = "https://dev.azure.com/carlsberggroup/$($env:SYSTEM_TEAMPROJECT)/_apis/git/repositories/1760-Smartcore-HUB"
        $tagDir   = Join-Path $env:AGENT_TEMPDIRECTORY ("hubrepo-" + [guid]::NewGuid())
        $cloneUrl = "https://dev.azure.com/carlsberggroup/$($env:SYSTEM_TEAMPROJECT)/_git/1760-Smartcore-HUB"
        # Embed token directly in URL to avoid Git Credential Manager interactions on
        # Microsoft-hosted agents (GCM store-write 0x6f7 -> prompt -> auth failure).
        # Same pattern the wiki clone above already uses.
        $cloneUrlAuth = $cloneUrl -replace '^https://', "https://buildagent:$Token@"
        # Belt-and-suspenders: keep git non-interactive even if some sub-process tries to prompt.
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE     = 'Never'

        # Tag message - short and to the point.
        # For SemVer (prod) tags, prefix with the version and append previous version for lineage.
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
                # Check if tag already exists on remote (idempotent re-runs)
                $existing = git ls-remote --tags origin "refs/tags/$tagName" 2>$null
                if ($existing) {
                    Write-Host "Tag '$tagName' already exists on origin - skipping."
                } else {
                    git config user.email 'ado-pipeline@carlsberg.com'
                    git config user.name  'Azure DevOps Pipeline'
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
} else {
    if ($CreateTag) {
        Write-Host "No tag trigger for branch='$SourceBranchName' stage='$($env:RELEASE_ENVIRONMENTNAME)'."
    }
}

# --- Hand off file paths to subsequent tasks ---------------------------------
Write-Host "##vso[task.setvariable variable=wikiFilePath]$filePath"
Write-Host "##vso[task.setvariable variable=wikiPagePath]$relPath"
Write-Host "=== Update-WikiReleaseNotes.ps1 complete ==="

# Reset $LASTEXITCODE so a non-zero from a swallowed git operation (e.g. the
# tag-creation try/catch above) does not bubble up and fail this pipeline task.
# Any genuine fatal would have thrown and never reached this line.
$global:LASTEXITCODE = 0
exit 0
