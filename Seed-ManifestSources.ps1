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
  Corrects any manifest missing 'source'/'sourceUrl', with empty timestamps, or where the 'sourceLastUpdated' timestamp does not match the source file's modification time.

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
# Corrective/Migration Modes (These run exclusively)
# =================================================================================
if ($MigrateTimestampFormat) {
    Write-Host "🕰️  Migrating timestamp formats in manifest comments..." -ForegroundColor Cyan
    $migratedCount = 0; $oldFormat = "MM/dd/yyyy HH:mm:ss"; $newFormat = "yyMMdd HH:mm:ss"
    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json; $metadata = Get-CustomMetadata -JSONObject $json; $wasModified = $false
        foreach ($key in @('sourceLastUpdated', 'sourceLastChangeFound')) {
            if ($metadata.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($metadata[$key])) {
                try {
                    $dateObject = [datetime]::ParseExact($metadata[$key], $oldFormat, $null); $newTimestamp = $dateObject.ToString($newFormat)
                    if ($metadata[$key] -ne $newTimestamp) { $metadata[$key] = $newTimestamp; $wasModified = $true }
                } catch {}
            }
        }
        if ($wasModified) {
            Write-Host "  - Updating timestamps in '$($manifestFile.Name)'..."; $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadata
            $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8; $migratedCount++
        }
    }
    Write-Host "✨ Timestamp migration complete. Updated $migratedCount manifest(s)." -ForegroundColor Green; return
}

if ($CleanComments) {
    Write-Host "🧹 Cleaning duplicate standalone keys from manifest comments..." -ForegroundColor Cyan
    $cleanedCount = 0; $keySet = [System.Collections.Generic.HashSet[string]]$MetadataKeys
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
            $commentString = $json.'##'; $repairedArray = $commentString -split "(?=($splitKeys)\s*:)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
            if ($repairedArray.Count -gt 1) {
                Write-Host "  - Repairing '$($manifestFile.Name)'..."; $json.'##' = $repairedArray
                $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8; $repairedCount++
            } else { Write-Warning "    - Could not parse '$($manifestFile.Name)'. Skipping." }
        }
    }
    Write-Host "✨ Repair complete. Repaired $repairedCount manifest(s)." -ForegroundColor Green; return
}

if ($MigrateFormat) {
    Write-Host "🚀 Migrating manifest formats to use the '##' property..." -ForegroundColor Cyan
    $migratedCount = 0
    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json; $oldKeys = $json.PSObject.Properties.Name | Where-Object { $MetadataKeys -contains $_ }
        if ($oldKeys.Count -gt 0) {
            Write-Host "  - Migrating '$($manifestFile.Name)'..."; $metadataToMigrate = @{}; foreach ($key in $oldKeys) { $metadataToMigrate[$key] = $json.$key }
            $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadataToMigrate; foreach ($key in $oldKeys) { $json.PSObject.Properties.Remove($key) }
            $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8; $migratedCount++
        }
    }
    Write-Host "✨ Migration complete. Migrated $migratedCount manifest(s)." -ForegroundColor Green; return
}

if ($ListManual) {
    Write-Host "📜 Listing applications marked as MANUAL in '$PersonalBucketPath'..." -ForegroundColor Cyan; $manualApps = @()
    foreach ($manifestFile in $personalManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($null -ne $json) { $metadata = Get-CustomMetadata -JSONObject $json; if ($metadata.source -eq 'MANUAL') { $manualApps += $manifestFile.Name } }
    }
    if ($manualApps.Count -gt 0) { $manualApps | ForEach-Object { Write-Host "  - $_" } } else { Write-Host "  ✅ No applications are marked as MANUAL." }; return
}

# =================================================================================
# Main Seeding Operation
# =================================================================================
$configFilePath = Join-Path -Path $scriptDir -ChildPath $ConfigFile
if (-not (Test-Path $configFilePath)) { Write-Error "Config file not found: $configFilePath"; return }
Write-Host "🔍 Reading and verifying repository configuration from '$configFilePath'..."
$repos = Import-Csv -Path $configFilePath -Delimiter ';' -Header 'Path', 'Url'
foreach ($repo in $repos) { if (-not ([System.IO.Path]::IsPathRooted($repo.Path))) { $repo.Path = Resolve-Path -Path (Join-Path -Path $scriptDir -ChildPath $repo.Path) -ErrorAction SilentlyContinue } }
# Configuration auto-update logic can be added here if desired

$runTimestamp = (Get-Date).ToString("yyMMdd HH:mm:ss")
$modifiedFileCount = 0
Write-Host "`n🌱 Seeding source information for manifests in '$PersonalBucketPath'..."
if ($Force) { Write-Host "  -Force switch detected. All existing source values will be recalculated." -ForegroundColor Yellow }
if ($RecalculateManual) { Write-Host "  -RecalculateManual switch detected. Only 'MANUAL' entries will be recalculated." -ForegroundColor Yellow }
if ($ReprocessIncomplete) { Write-Host "  -ReprocessIncomplete switch detected. Incomplete manifests will be corrected." -ForegroundColor Yellow }

foreach ($manifestFile in $personalManifests) {
    $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
    $metadata = Get-CustomMetadata -JSONObject $json
    $metadataToUpdate = $metadata.Clone()
    $wasModified = $false
    $logMessages = @()

    $isManual = $metadata.ContainsKey('source') -and $metadata.source -eq 'MANUAL'

    # --- Destructive modes: Force or RecalculateManual ---
    if ($Force -or ($RecalculateManual -and $isManual)) {
        $sourceFound = $false; $deprecatedFound = $false; $recalculatedMeta = @{}
        foreach ($repo in $repos) {
            $sourceManifestPath = Join-Path $repo.Path "bucket\$($manifestFile.Name)"
            if ((Test-Path $sourceManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
                $repoBase = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/"); $userRepo = $repoBase.Replace("https://github.com/", ""); $rawUrl = "https://raw.githubusercontent.com/$userRepo/master/bucket/$($manifestFile.Name)"
                $recalculatedMeta = @{ source = $sourceManifestPath; sourceUrl = $rawUrl }; $sourceFound = $true; break
            }
        }
        if (-not $sourceFound) { $recalculatedMeta = @{ source = 'MANUAL' } } # Simplified for brevity
        $metadataToUpdate = $recalculatedMeta # Overwrite existing metadata completely
        $logMessages += "    -> Recalculated source due to -Force or -RecalculateManual flag."
    }
    # --- Surgical mode: ReprocessIncomplete ---
    elseif ($ReprocessIncomplete) {
        # Check 1: Missing source or sourceUrl
        if (-not $metadata.ContainsKey('source') -or -not $metadata.ContainsKey('sourceUrl')) {
            $sourceFound = $false; $deprecatedFound = $false
            foreach ($repo in $repos) {
                $sourceManifestPath = Join-Path $repo.Path "bucket\$($manifestFile.Name)"
                if ((Test-Path $sourceManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
                    $repoBase = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/"); $userRepo = $repoBase.Replace("https://github.com/", ""); $rawUrl = "https://raw.githubusercontent.com/$userRepo/master/bucket/$($manifestFile.Name)"
                    $logMessages += "    -> Found missing source: $sourceManifestPath"; $metadataToUpdate.source = $sourceManifestPath
                    $logMessages += "    -> Found missing sourceUrl: $rawUrl"; $metadataToUpdate.sourceUrl = $rawUrl; $sourceFound = $true; break
                }
            }
            if (-not $sourceFound) { $logMessages += "    -> Source not found, marking as MANUAL."; $metadataToUpdate.source = 'MANUAL'; $metadataToUpdate.Remove('sourceUrl') }
        }

        # Check 2: Timestamps
        $currentSourcePath = $metadataToUpdate.source
        if ($currentSourcePath -and $currentSourcePath -ne 'MANUAL' -and $currentSourcePath -ne 'DEPRECATED' -and (Test-Path $currentSourcePath)) {
            $actualFileTimestamp = (Get-Item $currentSourcePath).LastWriteTime.ToString("yyMMdd HH:mm:ss")
            if ($metadataToUpdate.sourceLastUpdated -ne $actualFileTimestamp) {
                $logMessages += "    -> Corrected sourceLastUpdated to '$actualFileTimestamp'"; $metadataToUpdate.sourceLastUpdated = $actualFileTimestamp
            }
        } elseif (-not $metadata.ContainsKey('sourceLastUpdated') -or [string]::IsNullOrWhiteSpace($metadata.sourceLastUpdated)) {
            $logMessages += "    -> Initialized empty sourceLastUpdated."; $metadataToUpdate.sourceLastUpdated = ""
        }

        if (-not $metadata.ContainsKey('sourceLastChangeFound') -or [string]::IsNullOrWhiteSpace($metadata.sourceLastChangeFound)) {
            $logMessages += "    -> Initialized sourceLastChangeFound to '$runTimestamp'"; $metadataToUpdate.sourceLastChangeFound = $runTimestamp
        }
    }

    # --- Determine if a write is needed by comparing original and updated metadata ---
    if ($null -ne (Compare-Object -ReferenceObject $metadata -DifferenceObject $metadataToUpdate -Property ($metadata.Keys + $metadataToUpdate.Keys | Select-Object -Unique))) {
        $wasModified = $true
    }

    if ($wasModified) {
        Write-Host "  - Updating '$($manifestFile.Name)'..." -ForegroundColor Green
        $logMessages | ForEach-Object { Write-Host $_ }
        $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadataToUpdate
        $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
        $modifiedFileCount++
    }
}
Write-Host "`n✨ Seeding process complete. Modified $modifiedFileCount file(s)."
