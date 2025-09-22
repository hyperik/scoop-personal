<#
.SYNOPSIS
  Seeds Scoop manifests with source info and initializes tracking fields using the schema-conformant "##" property.

.DESCRIPTION
  This script inspects 'local-repos.cfg' and finds the source for each manifest in your personal bucket.
  It adds source metadata as an array of "key: value" strings under the "##" property, including:
  - source: The local file path of the original manifest.
  - sourceUrl: The remote raw GitHub URL.
  - sourceLastUpdated: Timestamp for the last check.
  - sourceLastChangeFound: Timestamp for the last detected change.

.PARAMETER PersonalBucketPath
  The full path to the 'bucket' directory of your personal Scoop repository. Overrides the default behavior.

.PARAMETER Force
  Forces recalculation for ALL manifests, ignoring their current state.

.PARAMETER RecalculateManual
  Recalculates only for manifests currently marked as 'MANUAL'.

.PARAMETER ReprocessIncomplete
  Re-evaluates and seeds any manifest that is missing the 'source' or 'sourceUrl' key.

.PARAMETER ListManual
  Lists all manifests marked as 'MANUAL' and exits without taking any other action.

.PARAMETER MigrateFormat
  Performs a one-time migration, converting old top-level 'source*' keys to the new "##" format in all manifests.

.PARAMETER FixUnsplitComments
  Repairs manifests where a previous migration incorrectly concatenated all metadata into a single comment string.

.PARAMETER CleanComments
  Removes duplicate standalone metadata keys (e.g., "source") from the "##" array, which may have been created during repair.
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$PersonalBucketPath = $null,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$RecalculateManual,

    [Parameter(Mandatory = $false)]
    [switch]$ReprocessIncomplete,

    [Parameter(Mandatory = $false)]
    [switch]$ListManual,

    [Parameter(Mandatory = $false)]
    [switch]$MigrateFormat,

    [Parameter(Mandatory = $false)]
    [switch]$FixUnsplitComments,

    [Parameter(Mandatory = $false)]
    [switch]$CleanComments
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

$ConfigFile = "local-repos.cfg"
if (-not (Test-Path $PersonalBucketPath)) { Write-Error "Personal bucket path not found: $PersonalBucketPath"; return }
$personalManifests = Get-ChildItem -Path $PersonalBucketPath -Filter *.json
if ($null -eq $personalManifests) { Write-Warning "No manifest files found in '$PersonalBucketPath'."; return }

# --- Helper Functions ---
$MetadataKeys = 'source', 'sourceUrl', 'sourceLastUpdated', 'sourceLastChangeFound'

function Get-CustomMetadata($JSONObject) {
    $metadata = @{}
    if ($JSONObject.PSObject.Properties['##']) {
        foreach ($line in $JSONObject.'##') {
            if ($line -match "^($($MetadataKeys -join '|'))\s*:") {
                $key, $value = $line -split ':', 2
                $metadata[$key.Trim()] = $value.Trim()
            }
        }
    }
    return $metadata
}

function Set-CustomMetadata($JSONObject, $MetadataToWrite) {
    if (-not $JSONObject.PSObject.Properties['##']) {
        $JSONObject | Add-Member -MemberType NoteProperty -Name '##' -Value @()
    } elseif ($JSONObject.'##' -isnot [array]) {
        $JSONObject.'##' = @($JSONObject.'##')
    }
    $newComments = @($JSONObject.'##' | Where-Object { $_ -notmatch "^($($MetadataKeys -join '|'))\s*:" })
    foreach ($entry in $MetadataToWrite.GetEnumerator()) {
        $newComments += "$($entry.Key): $($entry.Value)"
    }
    $JSONObject.'##' = $newComments
    return $JSONObject
}

# =================================================================================
# Mode 1: Handle -CleanComments and Exit
# =================================================================================
if ($CleanComments) {
    Write-Host "🧹 Cleaning duplicate standalone keys from manifest comments..." -ForegroundColor Cyan
    $cleanedCount = 0
    $keySet = [System.Collections.Generic.HashSet[string]]$MetadataKeys

    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
        if ($json.PSObject.Properties['##'] -and $json.'##' -is [array]) {
            $originalComments = $json.'##'
            $commentsToKeep = @()

            foreach ($line in $originalComments) {
                if (($line -like '*:*') -or (-not $keySet.Contains($line))) {
                    $commentsToKeep += $line
                }
            }

            if ($commentsToKeep.Count -lt $originalComments.Count) {
                Write-Host "  - Cleaning '$($manifestFile.Name)'..."
                $json.'##' = $commentsToKeep
                $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
                $cleanedCount++
            }
        }
    }
    Write-Host "✨ Cleaning complete. Cleaned $cleanedCount manifest(s)." -ForegroundColor Green
    return
}

# =================================================================================
# Mode 2: Handle -FixUnsplitComments and Exit
# =================================================================================
if ($FixUnsplitComments) {
    Write-Host "🔧 Repairing manifests with unsplit comment strings..." -ForegroundColor Cyan
    $repairedCount = 0
    $splitKeys = 'sourceUrl|sourceLastUpdated|sourceLastChangeFound|source'

    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
        if ($json.PSObject.Properties['##'] -and $json.'##' -is [string]) {
            Write-Host "  - Repairing '$($manifestFile.Name)'..."
            $commentString = $json.'##'
            $repairedArray = $commentString -split "(?=($splitKeys)\s*:)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }

            if ($repairedArray.Count -gt 1) {
                $json.'##' = $repairedArray
                $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
                $repairedCount++
            } else {
                 Write-Warning "    - Could not parse '$($manifestFile.Name)'. Skipping."
            }
        }
    }
    Write-Host "✨ Repair complete. Repaired $repairedCount manifest(s)." -ForegroundColor Green
    return
}


# =================================================================================
# Mode 3: Handle -MigrateFormat and Exit
# =================================================================================
if ($MigrateFormat) {
    Write-Host "🚀 Migrating manifest formats to use the '##' property..." -ForegroundColor Cyan
    $migratedCount = 0
    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
        $oldKeys = $json.PSObject.Properties.Name | Where-Object { $MetadataKeys -contains $_ }

        if ($oldKeys.Count -gt 0) {
            Write-Host "  - Migrating '$($manifestFile.Name)'..."
            $metadataToMigrate = @{}
            foreach ($key in $oldKeys) { $metadataToMigrate[$key] = $json.$key }

            $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadataToMigrate
            foreach ($key in $oldKeys) { $json.PSObject.Properties.Remove($key) }

            $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
            $migratedCount++
        }
    }
    Write-Host "✨ Migration complete. Migrated $migratedCount manifest(s)." -ForegroundColor Green
    return
}


# =================================================================================
# Mode 4: Handle -ListManual and Exit
# =================================================================================
if ($ListManual) {
    Write-Host "📜 Listing applications marked as MANUAL in '$PersonalBucketPath'..." -ForegroundColor Cyan
    $manualApps = @()
    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($null -ne $json) {
            $metadata = Get-CustomMetadata -JSONObject $json
            if ($metadata.source -eq 'MANUAL') {
                $manualApps += $manifestFile.Name
            }
        }
    }
    if ($manualApps.Count -gt 0) { $manualApps | ForEach-Object { Write-Host "  - $_" } } else { Write-Host "  ✅ No applications are marked as MANUAL." }
    return
}


# =================================================================================
# Mode 5: Full Seeding Operation
# =================================================================================

# --- Step 1: Read, Inspect, and Update local-repos.cfg ---
$configFilePath = Join-Path -Path $scriptDir -ChildPath $ConfigFile
if (-not (Test-Path $configFilePath)) { Write-Error "Config file not found: $configFilePath"; return }
Write-Host "🔍 Reading and verifying repository configuration from '$configFilePath'..."
$repos = Import-Csv -Path $configFilePath -Delimiter ';' -Header 'Path', 'Url'

# (The rest of Step 1 is unchanged)
foreach ($repo in $repos) {
    if (-not ([System.IO.Path]::IsPathRooted($repo.Path))) {
        $repo.Path = Resolve-Path -Path (Join-Path -Path $scriptDir -ChildPath $repo.Path) -ErrorAction SilentlyContinue
    }
}
$configUpdated = $false
foreach ($repo in $repos) {
    if ([string]::IsNullOrWhiteSpace($repo.Url)) {
        Write-Host "  - URL is missing for path '$($repo.Path)'. Attempting to detect..." -ForegroundColor Yellow
        $gitConfigPath = Join-Path $repo.Path ".git\config"
        if (Test-Path $gitConfigPath) {
            $originUrl = $null; try { $configFileContent = Get-Content $gitConfigPath; $inRemoteOrigin = $false; foreach ($line in $configFileContent) { if ($line.Trim() -eq '[remote "origin"]') { $inRemoteOrigin = $true; continue }; if ($inRemoteOrigin) { if ($line.Trim().StartsWith('[')) { break }; if ($line.Trim().StartsWith('url')) { $originUrl = ($line.Split('=', 2))[1].Trim(); break } } } } catch {}; if ($originUrl) { $repo.Url = $originUrl; $configUpdated = $true; Write-Host "    ✅ Success! Found remote URL: $($repo.Url)" -ForegroundColor Green } else { Write-Warning "    ⚠️ Failed to parse the remote URL from '$gitConfigPath'."}
        } else { Write-Warning "    ⚠️ Could not find .git/config at '$($repo.Path)'. Please verify the path."}
    }
}
if ($configUpdated) { Write-Host "💾 Saving updated URLs back to '$configFilePath'..." -ForegroundColor Cyan; ($repos | ForEach-Object { "$($_.Path);$($_.Url)" }) | Set-Content -Path $configFilePath }
Write-Host "  - Repository configuration is ready."

# --- Step 2: Process Manifests ---
Write-Host "`n🌱 Seeding source information for manifests in '$PersonalBucketPath'..."
if ($Force) { Write-Host "  -Force switch detected. All existing source values will be recalculated." -ForegroundColor Yellow }
if ($RecalculateManual) { Write-Host "  -RecalculateManual switch detected. Only 'MANUAL' entries will be recalculated." -ForegroundColor Yellow }
if ($ReprocessIncomplete) { Write-Host "  -ReprocessIncomplete switch detected. Manifests missing 'source' or 'sourceUrl' will be re-evaluated." -ForegroundColor Yellow }

foreach ($manifestFile in $personalManifests) {
    $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
    $metadata = Get-CustomMetadata -JSONObject $json

    $sourceExists = $metadata.ContainsKey('source')
    $sourceUrlExists = $metadata.ContainsKey('sourceUrl')
    $isManual = $sourceExists -and $metadata.source -eq 'MANUAL'

    $shouldProcess = !$sourceExists `
        -or $Force `
        -or ($RecalculateManual -and $isManual) `
        -or ($ReprocessIncomplete -and (-not $sourceExists -or -not $sourceUrlExists))

    if (-not $shouldProcess) {
        Write-Host "  - Skipping '$($manifestFile.Name)' (source already exists and is complete)." -NoNewline
        if ($isManual) { Write-Host " [MANUAL]" -ForegroundColor DarkGray } else { Write-Host "" }
        continue
    }

    Write-Host "  - Processing '$($manifestFile.Name)'..."
    $sourceFound = $false
    $deprecatedFound = $false
    $metadataToWrite = $null

    # Pass 1: Search in 'bucket' folders
    foreach ($repo in $repos) {
        if ([string]::IsNullOrEmpty($repo.Path)) { continue }
        $sourceManifestPath = Join-Path $repo.Path "bucket\$($manifestFile.Name)"
        if ((Test-Path $sourceManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
            $repoBase = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/"); $userRepo = $repoBase.Replace("https://github.com/", "")
            $rawUrl = "https://raw.githubusercontent.com/$userRepo/master/bucket/$($manifestFile.Name)"
            $metadataToWrite = @{
                source                = $sourceManifestPath
                sourceUrl             = $rawUrl
                sourceLastUpdated     = ''
                sourceLastChangeFound = ''
            }
            Write-Host "    ✅ Source found in bucket: $($repo.Path)"; $sourceFound = $true; break
        }
    }

    # Pass 2: If not found, search in 'deprecated' folders
    if (-not $sourceFound) {
        foreach ($repo in $repos) {
            if ([string]::IsNullOrEmpty($repo.Path)) { continue }
            $deprecatedManifestPath = Join-Path $repo.Path "deprecated\$($manifestFile.Name)"
            if ((Test-Path $deprecatedManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
                $repoBase = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/"); $userRepo = $repoBase.Replace("https://github.com/", "")
                $rawUrl = "https://raw.githubusercontent.com/$userRepo/master/deprecated/$($manifestFile.Name)"
                $metadataToWrite = @{
                    source                = 'DEPRECATED'
                    sourceUrl             = $rawUrl
                    sourceLastUpdated     = ''
                    sourceLastChangeFound = ''
                }
                Write-Host "    ⚠️  Source found in deprecated folder. Marked as 'DEPRECATED'." -ForegroundColor Yellow; $deprecatedFound = $true; break
            }
        }
    }

    # Pass 3: If still not found, mark as MANUAL
    if (-not $sourceFound -and -not $deprecatedFound) {
        $metadataToWrite = @{ source = 'MANUAL' }
        Write-Host "    ➡️  Not found in any bucket or deprecated folder. Marked as 'MANUAL'."
    }

    # Write the results to the manifest
    $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadataToWrite
    $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
}
Write-Host "`n✨ Seeding process complete."
