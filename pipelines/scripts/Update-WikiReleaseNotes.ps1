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
