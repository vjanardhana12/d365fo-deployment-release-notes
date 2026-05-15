<#
.SYNOPSIS
    Creates the wiki folder structure for deployment release notes.

.DESCRIPTION
    One-time setup script. Creates parent pages and .order files in the
    Azure DevOps project wiki so the pipeline can publish release notes
    under a clean folder hierarchy:
        Deployment-release-notes/
            Main-branch/
            Prod-branch/
            Hotfix-branch/
            Release-branch/

.PARAMETER Organization
    Azure DevOps organization URL (e.g., https://dev.azure.com/myorg)

.PARAMETER Project
    Azure DevOps project name

.PARAMETER WikiName
    Project wiki name (usually "<ProjectName>.wiki")

.PARAMETER PAT
    Personal Access Token with Code (Read & Write) permission on the wiki repo.
    If omitted, the script will prompt.

.EXAMPLE
    .\Setup-WikiStructure.ps1 -Organization "https://dev.azure.com/myorg" -Project "MyProject" -WikiName "MyProject.wiki"
#>
param(
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$WikiName,
    [string]$PAT
)

$ErrorActionPreference = 'Stop'

if (-not $PAT) {
    $PAT = Read-Host -Prompt 'Enter PAT with Code Read+Write permission' -AsSecureString |
           ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
}

$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT"))
$headers = @{ Authorization = "Basic $base64Auth"; 'Content-Type' = 'application/json' }

$wikiRepoUrl = "$Organization/$Project/_git/$WikiName"
$work = Join-Path $env:TEMP "wiki-setup-$([guid]::NewGuid())"

Write-Host "`n=== Cloning wiki repo ===" -ForegroundColor Cyan
$cloneUrl = $wikiRepoUrl -replace 'https://', "https://x-pat:$PAT@"
git clone --depth 1 --branch wikiMaster $cloneUrl $work
if ($LASTEXITCODE -ne 0) { throw "Failed to clone wiki repo. Check PAT permissions and wiki URL." }

Push-Location $work
git config user.email 'release-notes-setup@local'
git config user.name  'Release Notes Setup'

# --- Create parent page ---
$parentPage = 'Deployment-release-notes.md'
if (-not (Test-Path $parentPage)) {
    @"
# Deployment release notes

Automated release notes for D365 F&O builds. Pages are organized by branch.
"@ | Set-Content $parentPage -Encoding UTF8
    Write-Host "  Created $parentPage" -ForegroundColor Green
}

# --- Create branch sub-pages ---
$folder = 'Deployment-release-notes'
if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }

$branches = @('Main-branch', 'Prod-branch', 'Hotfix-branch', 'Release-branch')
foreach ($b in $branches) {
    $pagePath = "$folder\$b.md"
    if (-not (Test-Path $pagePath)) {
        "# $($b -replace '-', ' ')`n`nRelease notes for the **$($b -replace '-branch','')** branch." |
            Set-Content $pagePath -Encoding UTF8
        Write-Host "  Created $pagePath" -ForegroundColor Green
    }
}

# --- Create .order files ---
$rootOrder = @()
if (Test-Path '.order') { $rootOrder = Get-Content '.order' }
if ('Deployment-release-notes' -notin $rootOrder) {
    $rootOrder += 'Deployment-release-notes'
    $rootOrder | Set-Content '.order' -Encoding UTF8
    Write-Host "  Updated root .order" -ForegroundColor Green
}

$branchOrder = $branches | ForEach-Object { $_ }
$branchOrder | Set-Content "$folder\.order" -Encoding UTF8
Write-Host "  Created $folder\.order" -ForegroundColor Green

# --- Commit and push ---
git add -A
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    git commit -m "Setup: deployment release notes folder structure"
    git push origin wikiMaster
    Write-Host "`nWiki structure created and pushed." -ForegroundColor Green
} else {
    Write-Host "`nWiki structure already exists. Nothing to push." -ForegroundColor Yellow
}

Pop-Location
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host @"

Next step: Run Grant-BuildPermission.ps1 to allow the build service
           to push to the wiki repo.
"@ -ForegroundColor Cyan
