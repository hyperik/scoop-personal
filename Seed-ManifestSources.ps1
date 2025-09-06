<#
.SYNOPSIS
  Seeds Scoop manifests with a local 'source' path and a remote 'sourceUrl', now with a check for deprecated apps.

.DESCRIPTION
  This script first searches for manifests in the 'bucket' folder of source repositories.
  If not found, it performs a second search in the 'deprecated' folder.
  - If found in 'deprecated', the source is marked as 'DEPRECATED'.
  - If not found in either, it is marked as 'MANUAL'.
  It also auto-detects and saves missing Git remote URLs in 'local-repos.cfg'.

.PARAMETER PersonalBucketPath
  The full path to the 'bucket' directory of your personal Scoop repository.

.PARAMETER Force
  Forces recalculation for ALL manifests.

.PARAMETER RecalculateManual
  Recalculates only for manifests currently marked as 'MANUAL'.

.PARAMETER ListManual
  Lists all manifests marked as 'MANUAL' and exits.
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

# --- Initial Setup & -ListManual handler (unchanged) ---
$ConfigFile = "local-repos.cfg"
if (-not (Test-Path $PersonalBucketPath)) { Write-Error "Invalid PersonalBucketPath: $PersonalBucketPath"; return }
$personalManifests = Get-ChildItem -Path $PersonalBucketPath -Filter *.json
if ($null -eq $personalManifests) { Write-Warning "No manifest files found in '$PersonalBucketPath'."; return }
if ($ListManual) {
    Write-Host "📜 Listing applications marked as MANUAL in '$PersonalBucketPath'..." -ForegroundColor Cyan
    $manualApps = @()
    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($null -ne $json -and $json.PSObject.Properties['source'] -and $json.source -eq 'MANUAL') {
            $manualApps += $manifestFile.Name
        }
    }
    if ($manualApps.Count -gt 0) { $manualApps | ForEach-Object { Write-Host "  - $_" } }
    else { Write-Host "  ✅ No applications are marked as MANUAL." }
    return
}

# --- local-repos.cfg processing (unchanged) ---
if (-not (Test-Path $ConfigFile)) { Write-Error "Config file not found: $ConfigFile"; return }
Write-Host "🔍 Reading and verifying repository configuration from '$ConfigFile'..."
# ... (This logic for reading the config and finding Git URLs is unchanged) ...
$repos = Import-Csv -Path $ConfigFile -Delimiter ';' -Header 'Path', 'Url'
$configUpdated = $false; foreach ($repo in $repos) { if ([string]::IsNullOrWhiteSpace($repo.Url)) { $gitConfigPath = Join-Path $repo.Path ".git\config"; if (Test-Path $gitConfigPath) { $originUrl = $null; try { $configFileContent = Get-Content $gitConfigPath; $inRemoteOrigin = $false; foreach ($line in $configFileContent) { if ($line.Trim() -eq '[remote "origin"]') { $inRemoteOrigin = $true; continue }; if ($inRemoteOrigin) { if ($line.Trim().StartsWith('[')) { break }; if ($line.Trim().StartsWith('url')) { $originUrl = ($line.Split('=', 2))[1].Trim(); break } } } } catch {}; if ($originUrl) { $repo.Url = $originUrl; $configUpdated = $true } } } }; if ($configUpdated) { Write-Host "💾 Saving updated URLs back to '$ConfigFile'..." -ForegroundColor Cyan; ($repos | ForEach-Object { "$($_.Path);$($_.Url)" }) | Set-Content -Path $ConfigFile }; Write-Host "  - Repository configuration is ready."


# =================================================================================
# Section 3: Process Manifests (Logic Updated for Deprecated Check)
# =================================================================================
Write-Host "`n🌱 Seeding source information for manifests in '$PersonalBucketPath'..."
if ($Force) { Write-Host "  -Force switch detected. All existing source values will be recalculated." -ForegroundColor Yellow }
if ($RecalculateManual) { Write-Host "  -RecalculateManual switch detected. Only 'MANUAL' entries will be recalculated." -ForegroundColor Yellow }

foreach ($manifestFile in $personalManifests) {
    $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
    $sourceExists = $null -ne $json.PSObject.Properties['source']
    $sourceValue = if ($sourceExists) { $json.source } else { $null }

    $shouldProcess = !$sourceExists `
                     -or $Force `
                     -or ($RecalculateManual -and $sourceValue -eq 'MANUAL')

    if (-not $shouldProcess) {
        Write-Host "  - Skipping '$($manifestFile.Name)' (source already exists)."
        continue
    }

    Write-Host "  - Processing '$($manifestFile.Name)'..."
    $sourceFound = $false
    $deprecatedFound = $false

    # --- Pass 1: Search in 'bucket' folders ---
    foreach ($repo in $repos) {
        $sourceManifestPath = Join-Path $repo.Path "bucket\$($manifestFile.Name)"
        if ((Test-Path $sourceManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
            $baseUrl = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/")
            $rawUrl = "$baseUrl/raw/master/bucket/$($manifestFile.Name)".Replace("github.com/", "raw.githubusercontent.com/")
            $json | Add-Member -MemberType NoteProperty -Name 'source' -Value $sourceManifestPath -Force
            $json | Add-Member -MemberType NoteProperty -Name 'sourceUrl' -Value $rawUrl -Force
            $json | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
            Write-Host "    ✅ Source found in bucket: $($repo.Path)"
            $sourceFound = $true
            break
        }
    }

    # --- Pass 2: If not found, search in 'deprecated' folders ---
    if (-not $sourceFound) {
        foreach ($repo in $repos) {
            $deprecatedManifestPath = Join-Path $repo.Path "deprecated\$($manifestFile.Name)"
            if ((Test-Path $deprecatedManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
                $baseUrl = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/")
                $rawUrl = "$baseUrl/raw/master/deprecated/$($manifestFile.Name)".Replace("github.com/", "raw.githubusercontent.com/")
                $json | Add-Member -MemberType NoteProperty -Name 'source' -Value 'DEPRECATED' -Force
                $json | Add-Member -MemberType NoteProperty -Name 'sourceUrl' -Value $rawUrl -Force
                $json | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
                Write-Host "    ⚠️  Source found in deprecated folder. Marked as 'DEPRECATED'." -ForegroundColor Yellow
                $deprecatedFound = $true
                break
            }
        }
    }

    # --- Pass 3: If still not found, mark as MANUAL ---
    if (-not $sourceFound -and -not $deprecatedFound) {
        $json | Add-Member -MemberType NoteProperty -Name 'source' -Value 'MANUAL' -Force
        if ($json.PSObject.Properties['sourceUrl']) {
            $json.PSObject.Properties.Remove('sourceUrl')
        }
        $json | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
        Write-Host "    ➡️  Not found in any bucket or deprecated folder. Marked as 'MANUAL'."
    }
}
Write-Host "`n✨ Seeding process complete."