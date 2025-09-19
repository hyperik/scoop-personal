<#
.SYNOPSIS
  Checks for and applies updates for Scoop manifests, with advanced change tracking and an interactive mode.

.DESCRIPTION
  This script tracks changes using two timestamps: 'sourceLastUpdated' and 'sourceLastChangeFound'. It prevents downgrades by performing a semantic version check before applying updates.

  The path to the 'bucket' directory defaults to a 'bucket' folder in the script's directory, falling back to a hard-coded path if not found.

  The script can run in three modes:
  1. Default (Automatic): Auto-applies simple updates (including multi-architecture changes) and flags complex changes.
  2. Interactive Mode: Prompts the user to accept or skip complex changes for manifests where a pending change has been detected.
  3. List Pending Mode: Lists all manifests that have a pending change.

.PARAMETER PersonalBucketPath
  The full path to the 'bucket' directory of your personal Scoop repository. Overrides the default behavior.

.PARAMETER ListPending
  Lists all manifests with detected changes that have not yet been applied.

.PARAMETER Interactive
  Starts an interactive session to review and apply pending complex changes one by one.
#>
[CmdletBinding(DefaultParameterSetName = 'Automatic')]
param(
    [Parameter()]
    [string]$PersonalBucketPath = $null,

    [Parameter(ParameterSetName = 'List')]
    [switch]$ListPending,

    [Parameter(ParameterSetName = 'Interactive')]
    [switch]$Interactive
)

# --- Initial Setup ---
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($PersonalBucketPath)) {
    $localBucketPath = Join-Path -Path $scriptDir -ChildPath 'bucket'
    if (Test-Path -Path $localBucketPath) {
        $PersonalBucketPath = $localBucketPath
    } else {
        $PersonalBucketPath = 'D:\dev\src\hyperik\scoop-personal\bucket' # Fallback default
    }
}

# =================================================================================
# Helper Functions
# =================================================================================
function Test-IsNewerVersion { param ($RemoteVersion, $LocalVersion); try { return [version]$RemoteVersion -ge [version]$LocalVersion } catch { return $true } }
function Compare-ManifestObjects { param([PsCustomObject]$ReferenceObject, [PsCustomObject]$DifferenceObject); $localNorm = $ReferenceObject | ConvertTo-Json -Depth 10 | ConvertFrom-Json; $remoteNorm = $DifferenceObject | ConvertTo-Json -Depth 10 | ConvertFrom-Json; $topLevelIgnorable = @('version', 'url', 'hash', 'source', 'sourceUrl', 'sourceLastUpdated', 'sourceLastChangeFound'); foreach ($key in $topLevelIgnorable) { if ($localNorm.PSObject.Properties[$key]) { $localNorm.PSObject.Properties.Remove($key) }; if ($remoteNorm.PSObject.Properties[$key]) { $remoteNorm.PSObject.Properties.Remove($key) } }; if ($localNorm.PSObject.Properties['architecture']) { foreach ($arch in $localNorm.architecture.PSObject.Properties) { if ($arch.Value.PSObject.Properties['url']) { $arch.Value.PSObject.Properties.Remove('url') }; if ($arch.Value.PSObject.Properties['hash']) { $arch.Value.PSObject.Properties.Remove('hash') } } }; if ($remoteNorm.PSObject.Properties['architecture']) { foreach ($arch in $remoteNorm.architecture.PSObject.Properties) { if ($arch.Value.PSObject.Properties['url']) { $arch.Value.PSObject.Properties.Remove('url') }; if ($arch.Value.PSObject.Properties['hash']) { $arch.Value.PSObject.Properties.Remove('hash') } } }; $localString = $localNorm | ConvertTo-Json -Depth 10 -Compress; $remoteString = $remoteNorm | ConvertTo-Json -Depth 10 -Compress; return $localString -eq $remoteString }
function Show-ManifestDiff { param([PsCustomObject]$LocalJson, [PsCustomObject]$RemoteJson); $localCopy = $LocalJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json; $remoteCopy = $RemoteJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json; $sourceKeys = $localCopy.PSObject.Properties.Name | Where-Object { $_ -like 'source*' }; foreach ($key in $sourceKeys) { $localCopy.PSObject.Properties.Remove($key) }; $localString = $localCopy | ConvertTo-Json -Depth 10; $remoteString = $remoteCopy | ConvertTo-Json -Depth 10; $diff = Compare-Object -ReferenceObject ($localString -split '\r?\n') -DifferenceObject ($remoteString -split '\r?\n'); if ($null -eq $diff) { return }; Write-Host "`n    --- Diff ---"; foreach ($change in $diff) { if ($change.SideIndicator -eq '<=') { Write-Host ("- " + $change.InputObject) -ForegroundColor Red } elseif ($change.SideIndicator -eq '=>') { Write-Host ("+ " + $change.InputObject) -ForegroundColor Green } }; Write-Host "    --- End Diff ---`n" }

# =================================================================================
# Main Script Logic
# =================================================================================
$runTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$manifests = Get-ChildItem -Path $PersonalBucketPath -Filter *.json
$allManifestData = @()

# --- Pre-flight data gathering ---
Write-Host "🔍 Gathering manifest data from '$PersonalBucketPath'..."
foreach ($localManifestFile in $manifests) {
    $localJson = Get-Content -Path $localManifestFile.FullName -Raw | ConvertFrom-Json
    $data = [pscustomobject]@{ File = $localManifestFile; Local = $localJson; IsPending = $false }
    $lastChange = $data.Local.sourceLastChangeFound; $lastUpdate = $data.Local.sourceLastUpdated
    if ((-not [string]::IsNullOrEmpty($lastChange))) { if ([string]::IsNullOrEmpty($lastUpdate)) { $data.IsPending = $true } else { try { if ([datetime]$lastChange -gt [datetime]$lastUpdate) { $data.IsPending = $true } } catch {} } }
    $allManifestData += $data
}

# --- Mode: List Pending ---
if ($ListPending) {
    Write-Host "`n📜 Listing manifests with pending changes..." -ForegroundColor Cyan
    $pendingFiles = $allManifestData | Where-Object { $_.IsPending }
    if ($pendingFiles) { $pendingFiles | ForEach-Object { Write-Host "  - $($_.File.Name)" } } else { Write-Host "  ✅ No manifests have pending changes." }
    return
}

# --- Mode: Interactive ---
if ($Interactive) {
    Write-Host "`n👋 Starting interactive update session for pending changes..." -ForegroundColor Cyan
    $pendingFiles = $allManifestData | Where-Object { $_.IsPending }
    if (-not $pendingFiles) { Write-Host "  ✅ No manifests have pending changes to review."; return }
    foreach ($data in $pendingFiles) {
        Write-Host "`n--- Reviewing '$($data.File.Name)' ---" -ForegroundColor Yellow
        try { $remoteJson = Invoke-WebRequest -Uri $data.Local.sourceUrl -UseBasicParsing | ConvertFrom-Json } catch { Write-Warning "Could not fetch remote for '$($data.File.Name)'. Skipping."; continue }
        if (-not (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)) { Write-Host "    Remote version ($($remoteJson.version)) is older than local version ($($data.Local.version)). Skipping interactive prompt." -ForegroundColor Magenta; continue }
        Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        $choice = Read-Host "Apply this change? (A)ccept / (S)kip / (Q)uit"
        switch ($choice.ToLower()) {
            'a' { $originalSourcePath = $data.Local.source; $newJson = $remoteJson; $newJson | Add-Member -MemberType NoteProperty -Name 'source' -Value $originalSourcePath -Force; $newJson | Add-Member -MemberType NoteProperty -Name 'sourceLastUpdated' -Value $runTimestamp -Force; $newJson | Add-Member -MemberType NoteProperty -Name 'sourceLastChangeFound' -Value $runTimestamp -Force; $newJson | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8; Write-Host "  ✅ Accepted. Manifest '$($data.File.Name)' has been updated." -ForegroundColor Green }
            's' { Write-Host "  ⏩ Skipped '$($data.File.Name)'." }
            'q' { Write-Host "🛑 Aborting interactive session."; return }
            default { Write-Host "  ⏩ Invalid choice. Skipping '$($data.File.Name)'." }
        }
    }
    Write-Host "`n✨ Interactive session complete."; return
}

# --- Mode: Default Automatic Update ---
Write-Host "`n🔄 Checking for updates in '$PersonalBucketPath'..."
foreach ($data in $allManifestData) {
    if ((-not $data.Local.PSObject.Properties['sourceUrl']) -or ([string]::IsNullOrWhiteSpace($data.Local.sourceUrl)) -or ($data.Local.sourceUrl -notlike 'http*')) { continue }
    Write-Host "`n  - Checking '$($data.File.Name)'..."
    try { $remoteJson = Invoke-WebRequest -Uri $data.Local.sourceUrl -UseBasicParsing | ConvertFrom-Json } catch { Write-Warning "    ⚠️ Failed to download source. Error: $($_.Exception.Message)"; continue }
    if ($data.Local.version -eq $remoteJson.version) { Write-Host "    👍 Already up to date."; continue }
    if (-not (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)) { Write-Host "    Halted. Remote version ($($remoteJson.version)) is older than local version ($($data.Local.version))." -ForegroundColor Magenta; continue }
    Write-Host "    - Local version: $($data.Local.version), Remote version: $($remoteJson.version)."
    if (Compare-ManifestObjects -ReferenceObject $data.Local -DifferenceObject $remoteJson) {
        Write-Host "    ✅ Simple version change detected. Auto-updating..."
        $data.Local.version = $remoteJson.version
        if ($remoteJson.PSObject.Properties['url']) { $data.Local.url = $remoteJson.url } elseif ($data.Local.PSObject.Properties['url']) { $data.Local.PSObject.Properties.Remove('url') }
        if ($remoteJson.PSObject.Properties['hash']) { $data.Local.hash = $remoteJson.hash } elseif ($data.Local.PSObject.Properties['hash']) { $data.Local.PSObject.Properties.Remove('hash') }
        if ($remoteJson.PSObject.Properties['architecture']) { $data.Local.architecture = $remoteJson.architecture } elseif ($data.Local.PSObject.Properties['architecture']) { $data.Local.PSObject.Properties.Remove('architecture') }
        $data.Local | Add-Member -MemberType NoteProperty -Name 'sourceLastUpdated' -Value $runTimestamp -Force
        $data.Local | Add-Member -MemberType NoteProperty -Name 'sourceLastChangeFound' -Value $runTimestamp -Force
        $data.Local | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
    } else {
        Write-Warning "    ⚠️ Manifest has complex changes. Flagging for manual review."
        Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        $data.Local | Add-Member -MemberType NoteProperty -Name 'sourceLastChangeFound' -Value $runTimestamp -Force
        $data.Local | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
    }
}
Write-Host "`n✨ Update check complete."