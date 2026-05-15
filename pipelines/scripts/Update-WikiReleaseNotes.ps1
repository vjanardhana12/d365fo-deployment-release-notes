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
