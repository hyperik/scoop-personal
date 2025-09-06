<#
.SYNOPSIS
  Seeds Scoop manifests with source info and initializes timestamp fields.

.DESCRIPTION
  This script inspects 'local-repos.cfg' and finds the source for each manifest in your personal bucket.
  It adds 'source' (local path) and 'sourceUrl' (remote URL) fields.
  It also initializes 'sourceLastUpdated' and 'sourceLastChangeFound' with empty strings, to be populated by the update script.

.PARAMETER PersonalBucketPath
  The full path to the 'bucket' directory of your personal Scoop repository.

.PARAMETER Force
  Forces recalculation for ALL manifests, ignoring their current state.

.PARAMETER RecalculateManual
  Recalculates only for manifests currently marked as 'MANUAL'.

.PARAMETER ListManual
  Lists all manifests marked as 'MANUAL' and exits without taking any other action.
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$PersonalBucketPath = "D:\dev\src\hyperik\scoop-personal\bucket",

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$RecalculateManual,

    [Parameter(Mandatory = $false)]
    [switch]$ListManual
)

# --- Initial Setup ---
$ConfigFile = "local-repos.cfg"
if (-not (Test-Path $PersonalBucketPath)) { Write-Error "Invalid PersonalBucketPath: $PersonalBucketPath"; return }
$personalManifests = Get-ChildItem -Path $PersonalBucketPath -Filter *.json
if ($null -eq $personalManifests) { Write-Warning "No manifest files found in '$PersonalBucketPath'."; return }


# =================================================================================
# Mode 1: Handle -ListManual and Exit
# =================================================================================
if ($ListManual) {
    Write-Host "📜 Listing applications marked as MANUAL in '$PersonalBucketPath'..." -ForegroundColor Cyan
    $manualApps = @()
    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($null -ne $json -and $json.PSObject.Properties['source'] -and $json.source -eq 'MANUAL') {
            $manualApps += $manifestFile.Name
        }
    }
    if ($manualApps.Count -gt 0) { $manualApps | ForEach-Object { Write-Host "  - $_" } } else { Write-Host "  ✅ No applications are marked as MANUAL." }
    return
}


# =================================================================================
# Mode 2: Full Seeding Operation
# =================================================================================

# --- Step 1: Read, Inspect, and Update local-repos.cfg ---
if (-not (Test-Path $ConfigFile)) { Write-Error "Config file not found: $ConfigFile"; return }
Write-Host "🔍 Reading and verifying repository configuration from '$ConfigFile'..."
$repos = Import-Csv -Path $ConfigFile -Delimiter ';' -Header 'Path', 'Url'
$configUpdated = $false
foreach ($repo in $repos) {
    if ([string]::IsNullOrWhiteSpace($repo.Url)) {
        Write-Host "  - URL is missing for path '$($repo.Path)'. Attempting to detect..." -ForegroundColor Yellow
        $gitConfigPath = Join-Path $repo.Path ".git\config"
        if (Test-Path $gitConfigPath) {
            # ... Git parsing logic ...
            $originUrl = $null; try { $configFileContent = Get-Content $gitConfigPath; $inRemoteOrigin = $false; foreach ($line in $configFileContent) { if ($line.Trim() -eq '[remote "origin"]') { $inRemoteOrigin = $true; continue }; if ($inRemoteOrigin) { if ($line.Trim().StartsWith('[')) { break }; if ($line.Trim().StartsWith('url')) { $originUrl = ($line.Split('=', 2))[1].Trim(); break } } } } catch {}; if ($originUrl) { $repo.Url = $originUrl; $configUpdated = $true; Write-Host "    ✅ Success! Found remote URL: $($repo.Url)" -ForegroundColor Green } else { Write-Warning "    ⚠️ Failed to parse the remote URL from '$gitConfigPath'."}
        } else { Write-Warning "    ⚠️ Could not find .git/config at '$($repo.Path)'. Please verify the path."}
    }
}
if ($configUpdated) { Write-Host "💾 Saving updated URLs back to '$ConfigFile'..." -ForegroundColor Cyan; ($repos | ForEach-Object { "$($_.Path);$($_.Url)" }) | Set-Content -Path $ConfigFile }
Write-Host "  - Repository configuration is ready."

# --- Step 2: Process Manifests ---
Write-Host "`n🌱 Seeding source information for manifests in '$PersonalBucketPath'..."
if ($Force) { Write-Host "  -Force switch detected. All existing source values will be recalculated." -ForegroundColor Yellow }
if ($RecalculateManual) { Write-Host "  -RecalculateManual switch detected. Only 'MANUAL' entries will be recalculated." -ForegroundColor Yellow }

foreach ($manifestFile in $personalManifests) {
    $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
    $sourceExists = $null -ne $json.PSObject.Properties['source']; $sourceValue = if ($sourceExists) { $json.source } else { $null }
    $shouldProcess = !$sourceExists -or $Force -or ($RecalculateManual -and $sourceValue -eq 'MANUAL')
    if (-not $shouldProcess) { Write-Host "  - Skipping '$($manifestFile.Name)' (source already exists)."; continue }

    Write-Host "  - Processing '$($manifestFile.Name)'..."
    $sourceFound = $false; $deprecatedFound = $false

    # Pass 1: Search in 'bucket' folders
    foreach ($repo in $repos) {
        $sourceManifestPath = Join-Path $repo.Path "bucket\$($manifestFile.Name)"
        if ((Test-Path $sourceManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
            $repoBase = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/"); $userRepo = $repoBase.Replace("https://github.com/", "")
            $rawUrl = "https://raw.githubusercontent.com/$userRepo/master/bucket/$($manifestFile.Name)"
            $json | Add-Member -MemberType NoteProperty -Name 'source' -Value $sourceManifestPath -Force
            $json | Add-Member -MemberType NoteProperty -Name 'sourceUrl' -Value $rawUrl -Force
            # MODIFIED: Initialize timestamp fields with empty strings
            $json | Add-Member -MemberType NoteProperty -Name 'sourceLastUpdated' -Value '' -Force
            $json | Add-Member -MemberType NoteProperty -Name 'sourceLastChangeFound' -Value '' -Force
            $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
            Write-Host "    ✅ Source found in bucket: $($repo.Path)"; $sourceFound = $true; break
        }
    }

    # Pass 2: If not found, search in 'deprecated' folders
    if (-not $sourceFound) {
        foreach ($repo in $repos) {
            $deprecatedManifestPath = Join-Path $repo.Path "deprecated\$($manifestFile.Name)"
            if ((Test-Path $deprecatedManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
                $repoBase = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/"); $userRepo = $repoBase.Replace("https://github.com/", "")
                $rawUrl = "https://raw.githubusercontent.com/$userRepo/master/deprecated/$($manifestFile.Name)"
                $json | Add-Member -MemberType NoteProperty -Name 'source' -Value 'DEPRECATED' -Force
                $json | Add-Member -MemberType NoteProperty -Name 'sourceUrl' -Value $rawUrl -Force
                # MODIFIED: Initialize timestamp fields with empty strings
                $json | Add-Member -MemberType NoteProperty -Name 'sourceLastUpdated' -Value '' -Force
                $json | Add-Member -MemberType NoteProperty -Name 'sourceLastChangeFound' -Value '' -Force
                $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
                Write-Host "    ⚠️  Source found in deprecated folder. Marked as 'DEPRECATED'." -ForegroundColor Yellow; $deprecatedFound = $true; break
            }
        }
    }

    # Pass 3: If still not found, mark as MANUAL
    if (-not $sourceFound -and -not $deprecatedFound) {
        $json | Add-Member -MemberType NoteProperty -Name 'source' -Value 'MANUAL' -Force
        if ($json.PSObject.Properties['sourceUrl']) { $json.PSObject.Properties.Remove('sourceUrl') }
        if ($json.PSObject.Properties['sourceLastUpdated']) { $json.PSObject.Properties.Remove('sourceLastUpdated') }
        if ($json.PSObject.Properties['sourceLastChangeFound']) { $json.PSObject.Properties.Remove('sourceLastChangeFound') }
        $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
        Write-Host "    ➡️  Not found in any bucket or deprecated folder. Marked as 'MANUAL'."
    }
}
Write-Host "`n✨ Seeding process complete."