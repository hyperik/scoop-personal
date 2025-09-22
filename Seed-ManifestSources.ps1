<#
.SYNOPSIS
  Seeds Scoop manifests with source info and initializes tracking fields using the schema-conformant "##" property.

.DESCRIPTION
  This script inspects 'local-repos.cfg' and finds the source for each manifest in your personal bucket.
  It adds source metadata as an array of "key: value" strings under the "##" property, including:
  - source: The local file path of the original manifest.
  - sourceUrl: The remote raw GitHub URL.
  - sourceLastUpdated: Timestamp of the source file's last modification.
  - sourceLastChangeFound: Timestamp when a change was last detected by the update script.

.PARAMETER PersonalBucketPath
  The full path to the 'bucket' directory of your personal Scoop repository. Overrides the default behavior.

.PARAMETER Force
  Forces recalculation for ALL manifests, ignoring their current state.

.PARAMETER RecalculateManual
  Recalculates only for manifests currently marked as 'MANUAL'.

.PARAMETER ReprocessIncomplete
  Re-evaluates any manifest missing 'source'/'sourceUrl', with empty timestamps, or where the source file is newer than the stored 'sourceLastUpdated' timestamp.

.PARAMETER ListManual
  Lists all manifests marked as 'MANUAL' and exits without taking any other action.

.PARAMETER MigrateTimestampFormat
  Performs a one-time migration of 'sourceLastUpdated' and 'sourceLastChangeFound' from "MM/dd/yyyy HH:mm:ss" to "yyMMdd HH:mm:ss" format.

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
    [switch]$MigrateTimestampFormat,

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
# Mode 1: Handle -MigrateTimestampFormat and Exit
# =================================================================================
if ($MigrateTimestampFormat) {
    Write-Host "🕰️  Migrating timestamp formats in manifest comments..." -ForegroundColor Cyan
    $migratedCount = 0
    $oldFormat = "MM/dd/yyyy HH:mm:ss"
    $newFormat = "yyMMdd HH:mm:ss"

    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
        $metadata = Get-CustomMetadata -JSONObject $json
        $wasModified = $false

        foreach ($key in @('sourceLastUpdated', 'sourceLastChangeFound')) {
            if ($metadata.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($metadata[$key])) {
                try {
                    $dateObject = [datetime]::ParseExact($metadata[$key], $oldFormat, $null)
                    $newTimestamp = $dateObject.ToString($newFormat)
                    if ($metadata[$key] -ne $newTimestamp) {
                        $metadata[$key] = $newTimestamp
                        $wasModified = $true
                    }
                } catch {
                    # Ignore if it doesn't parse; it's likely already in the new format or some other format.
                }
            }
        }

        if ($wasModified) {
            Write-Host "  - Updating timestamps in '$($manifestFile.Name)'..."
            $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadata
            $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
            $migratedCount++
        }
    }
    Write-Host "✨ Timestamp migration complete. Updated $migratedCount manifest(s)." -ForegroundColor Green
    return
}

# =================================================================================
# Other Corrective Modes (Clean, Fix, Migrate)
# =================================================================================
if ($CleanComments) {
    Write-Host "🧹 Cleaning duplicate standalone keys from manifest comments..." -ForegroundColor Cyan
    $cleanedCount = 0
    $keySet = [System.Collections.Generic.HashSet[string]]$MetadataKeys
    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
        if ($json.PSObject.Properties['##'] -and $json.'##' -is [array]) {
            $originalComments = $json.'##'; $commentsToKeep = @()
            foreach ($line in $originalComments) { if (($line -like '*:*') -or (-not $keySet.Contains($line))) { $commentsToKeep += $line } }
            if ($commentsToKeep.Count -lt $originalComments.Count) {
                Write-Host "  - Cleaning '$($manifestFile.Name)'..."; $json.'##' = $commentsToKeep
                $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8; $cleanedCount++
            }
        }
    }
    Write-Host "✨ Cleaning complete. Cleaned $cleanedCount manifest(s)." -ForegroundColor Green; return
}

if ($FixUnsplitComments) {
    Write-Host "🔧 Repairing manifests with unsplit comment strings..." -ForegroundColor Cyan
    $repairedCount = 0; $splitKeys = 'sourceUrl|sourceLastUpdated|sourceLastChangeFound|source'
    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
        if ($json.PSObject.Properties['##'] -and $json.'##' -is [string]) {
            Write-Host "  - Repairing '$($manifestFile.Name)'..."
            $commentString = $json.'##'
            $repairedArray = $commentString -split "(?=($splitKeys)\s*:)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
            if ($repairedArray.Count -gt 1) {
                $json.'##' = $repairedArray; $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8; $repairedCount++
            } else { Write-Warning "    - Could not parse '$($manifestFile.Name)'. Skipping." }
        }
    }
    Write-Host "✨ Repair complete. Repaired $repairedCount manifest(s)." -ForegroundColor Green; return
}

if ($MigrateFormat) {
    Write-Host "🚀 Migrating manifest formats to use the '##' property..." -ForegroundColor Cyan
    $migratedCount = 0
    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
        $oldKeys = $json.PSObject.Properties.Name | Where-Object { $MetadataKeys -contains $_ }
        if ($oldKeys.Count -gt 0) {
            Write-Host "  - Migrating '$($manifestFile.Name)'..."
            $metadataToMigrate = @{}; foreach ($key in $oldKeys) { $metadataToMigrate[$key] = $json.$key }
            $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadataToMigrate
            foreach ($key in $oldKeys) { $json.PSObject.Properties.Remove($key) }
            $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8; $migratedCount++
        }
    }
    Write-Host "✨ Migration complete. Migrated $migratedCount manifest(s)." -ForegroundColor Green; return
}

if ($ListManual) {
    Write-Host "📜 Listing applications marked as MANUAL in '$PersonalBucketPath'..." -ForegroundColor Cyan
    $manualApps = @()
    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($null -ne $json) { $metadata = Get-CustomMetadata -JSONObject $json; if ($metadata.source -eq 'MANUAL') { $manualApps += $manifestFile.Name } }
    }
    if ($manualApps.Count -gt 0) { $manualApps | ForEach-Object { Write-Host "  - $_" } } else { Write-Host "  ✅ No applications are marked as MANUAL." }; return
}

# =================================================================================
# Main Seeding Operation
# =================================================================================

# --- Step 1: Read, Inspect, and Update local-repos.cfg ---
$configFilePath = Join-Path -Path $scriptDir -ChildPath $ConfigFile
if (-not (Test-Path $configFilePath)) { Write-Error "Config file not found: $configFilePath"; return }
Write-Host "🔍 Reading and verifying repository configuration from '$configFilePath'..."
$repos = Import-Csv -Path $configFilePath -Delimiter ';' -Header 'Path', 'Url'

foreach ($repo in $repos) { if (-not ([System.IO.Path]::IsPathRooted($repo.Path))) { $repo.Path = Resolve-Path -Path (Join-Path -Path $scriptDir -ChildPath $repo.Path) -ErrorAction SilentlyContinue } }
$configUpdated = $false
foreach ($repo in $repos) {
    if ([string]::IsNullOrWhiteSpace($repo.Url)) {
        Write-Host "  - URL is missing for path '$($repo.Path)'. Attempting to detect..." -ForegroundColor Yellow
        $gitConfigPath = Join-Path $repo.Path ".git\config"; if (Test-Path $gitConfigPath) {
            $originUrl = $null; try { $configFileContent = Get-Content $gitConfigPath; $inRemoteOrigin = $false; foreach ($line in $configFileContent) { if ($line.Trim() -eq '[remote "origin"]') { $inRemoteOrigin = $true; continue }; if ($inRemoteOrigin) { if ($line.Trim().StartsWith('[')) { break }; if ($line.Trim().StartsWith('url')) { $originUrl = ($line.Split('=', 2))[1].Trim(); break } } } } catch {}; if ($originUrl) { $repo.Url = $originUrl; $configUpdated = $true; Write-Host "    ✅ Success! Found remote URL: $($repo.Url)" -ForegroundColor Green } else { Write-Warning "    ⚠️ Failed to parse the remote URL from '$gitConfigPath'."}
        } else { Write-Warning "    ⚠️ Could not find .git/config at '$($repo.Path)'. Please verify the path."}
    }
}
if ($configUpdated) { Write-Host "💾 Saving updated URLs back to '$configFilePath'..." -ForegroundColor Cyan; ($repos | ForEach-Object { "$($_.Path);$($_.Url)" }) | Set-Content -Path $configFilePath }
Write-Host "  - Repository configuration is ready."

# --- Step 2: Process Manifests ---
$runTimestamp = (Get-Date).ToString("yyMMdd HH:mm:ss")
Write-Host "`n🌱 Seeding source information for manifests in '$PersonalBucketPath'..."
if ($Force) { Write-Host "  -Force switch detected. All existing source values will be recalculated." -ForegroundColor Yellow }
if ($RecalculateManual) { Write-Host "  -RecalculateManual switch detected. Only 'MANUAL' entries will be recalculated." -ForegroundColor Yellow }
if ($ReprocessIncomplete) { Write-Host "  -ReprocessIncomplete switch detected. Incomplete manifests will be re-evaluated." -ForegroundColor Yellow }

foreach ($manifestFile in $personalManifests) {
    $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
    $metadata = Get-CustomMetadata -JSONObject $json

    # --- Determine if processing is needed ---
    $sourceExists = $metadata.ContainsKey('source') -and -not [string]::IsNullOrWhiteSpace($metadata.source)
    $sourceUrlExists = $metadata.ContainsKey('sourceUrl') -and -not [string]::IsNullOrWhiteSpace($metadata.sourceUrl)
    $lastUpdatedExists = $metadata.ContainsKey('sourceLastUpdated') -and -not [string]::IsNullOrWhiteSpace($metadata.sourceLastUpdated)
    $lastChangeFoundExists = $metadata.ContainsKey('sourceLastChangeFound') -and -not [string]::IsNullOrWhiteSpace($metadata.sourceLastChangeFound)
    $isManual = $sourceExists -and $metadata.source -eq 'MANUAL'
    $isStale = $false
    if ($ReprocessIncomplete -and $sourceExists -and $lastUpdatedExists -and ($metadata.source -ne 'MANUAL' -and $metadata.source -ne 'DEPRECATED')) {
        if (Test-Path $metadata.source) {
            try {
                $sourceFileDate = (Get-Item $metadata.source).LastWriteTime
                $metadataDate = [datetime]::ParseExact($metadata.sourceLastUpdated, "yyMMdd HH:mm:ss", $null)
                if ($sourceFileDate -gt $metadataDate) { $isStale = $true }
            } catch { $isStale = $true } # Reprocess if date is in an unparsable format
        }
    }

    $shouldProcess = -not $sourceExists `
        -or $Force `
        -or ($RecalculateManual -and $isManual) `
        -or ($ReprocessIncomplete -and (-not $sourceExists -or -not $sourceUrlExists -or -not $lastUpdatedExists -or -not $lastChangeFoundExists -or $isStale))

    if (-not $shouldProcess) { continue }

    Write-Host "  - Processing '$($manifestFile.Name)'..."
    $metadataToUpdate = $metadata.Clone() # Start with existing metadata to preserve it

    # --- Recalculate source and sourceUrl if they are missing ---
    if (-not $sourceExists -or -not $sourceUrlExists) {
        $sourceFound = $false; $deprecatedFound = $false
        foreach ($repo in $repos) { # Pass 1: Buckets
            if ([string]::IsNullOrEmpty($repo.Path)) { continue }
            $sourceManifestPath = Join-Path $repo.Path "bucket\$($manifestFile.Name)"
            if ((Test-Path $sourceManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
                $repoBase = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/"); $userRepo = $repoBase.Replace("https://github.com/", "")
                $rawUrl = "https://raw.githubusercontent.com/$userRepo/master/bucket/$($manifestFile.Name)"
                $metadataToUpdate.source = $sourceManifestPath; $metadataToUpdate.sourceUrl = $rawUrl
                Write-Host "    ✅ Source found in bucket: $($repo.Path)"; $sourceFound = $true; break
            }
        }
        if (-not $sourceFound) { # Pass 2: Deprecated
            foreach ($repo in $repos) {
                if ([string]::IsNullOrEmpty($repo.Path)) { continue }
                $deprecatedManifestPath = Join-Path $repo.Path "deprecated\$($manifestFile.Name)"
                if ((Test-Path $deprecatedManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
                    $repoBase = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/"); $userRepo = $repoBase.Replace("https://github.com/", "")
                    $rawUrl = "https://raw.githubusercontent.com/$userRepo/master/deprecated/$($manifestFile.Name)"
                    $metadataToUpdate.source = 'DEPRECATED'; $metadataToUpdate.sourceUrl = $rawUrl
                    Write-Host "    ⚠️  Source found in deprecated folder." -ForegroundColor Yellow; $deprecatedFound = $true; break
                }
            }
        }
        if (-not $sourceFound -and -not $deprecatedFound) { # Pass 3: Manual
            $metadataToUpdate.source = 'MANUAL'; $metadataToUpdate.Remove('sourceUrl')
            Write-Host "    ➡️  Not found. Marked as 'MANUAL'."
        }
    }

    # --- Update timestamps for all processed items ---
    $currentSourcePath = $metadataToUpdate.source
    if ($currentSourcePath -and $currentSourcePath -ne 'MANUAL' -and $currentSourcePath -ne 'DEPRECATED' -and (Test-Path $currentSourcePath)) {
        $metadataToUpdate.sourceLastUpdated = (Get-Item $currentSourcePath).LastWriteTime.ToString("yyMMdd HH:mm:ss")
    } elseif (-not $metadataToUpdate.ContainsKey('sourceLastUpdated')) {
        $metadataToUpdate.sourceLastUpdated = "" # Ensure key exists but is empty for MANUAL/DEPRECATED
    }

    if (-not $lastChangeFoundExists) {
        $metadataToUpdate.sourceLastChangeFound = $runTimestamp
    }

    # --- Write the final results to the manifest ---
    $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadataToUpdate
    $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
}
Write-Host "`n✨ Seeding process complete."
