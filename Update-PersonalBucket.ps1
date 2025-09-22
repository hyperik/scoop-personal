<#
.SYNOPSIS
  Checks for and applies updates for Scoop manifests, with advanced change tracking and an interactive mode.

.DESCRIPTION
  This script tracks changes using metadata stored within the schema-conformant "##" property.
  It respects the 'sourceState' metadata field ('active', 'frozen', 'dead', 'manual') to control update behavior.

  The script can run in five modes:
    1. Default (Automatic): Auto-applies simple updates and flags complex changes.
    2. Interactive Mode: Prompts the user to accept or skip complex changes.
    3. List Pending Mode: Lists manifests with pending changes and their relevant timestamps.
    4. List Manual Mode: Lists all manifests configured as MANUAL.
    5. Verbose List Mode: When used with -ListPending, shows all non-manual files and explains their status.

.PARAMETER PersonalBucketPath
  The full path to the 'bucket' directory of your personal Scoop repository. Overrides the default behavior.

.PARAMETER ListPending
  Lists all manifests with detected changes that have not yet been applied.

.PARAMETER ListManual
  Lists all manifests that are configured with a source of 'MANUAL' or a state of 'manual'.

.PARAMETER Interactive
  Starts an interactive session to review and apply pending complex changes one by one.

.PARAMETER VerboseList
  When used with -ListPending, outputs status for all non-pending manifests as well.

.PARAMETER ChangesOnly
  In the default automatic mode, only outputs information for manifests that have updates or changes.
#>
[CmdletBinding(DefaultParameterSetName = 'Automatic')]
param(
    [Parameter(ParameterSetName = 'Automatic')]
    [string]$PersonalBucketPath = $null,

    [Parameter(ParameterSetName = 'ListPending')]
    [switch]$ListPending,

    [Parameter(ParameterSetName = 'ListManual')]
    [switch]$ListManual,

    [Parameter(ParameterSetName = 'Interactive')]
    [switch]$Interactive,

    [Parameter(ParameterSetName = 'ListPending')] # VerboseList is only valid with ListPending
    [switch]$VerboseList,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$ChangesOnly
)

# --- Initial Setup ---
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($PersonalBucketPath)) {
    $localBucketPath = Join-Path -Path $scriptDir -ChildPath 'bucket'
    if (Test-Path -Path $localBucketPath) {
        $PersonalBucketPath = $localBucketPath
    }
    else {
        $PersonalBucketPath = 'D:\dev\src\hyperik\scoop-personal\bucket' # Fallback default
    }
}

# =================================================================================
# Helper Functions
# =================================================================================
$MetadataKeys = 'source', 'sourceUrl', 'sourceLastUpdated', 'sourceLastChangeFound', 'sourceState'

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
    }
    elseif ($JSONObject.'##' -isnot [array]) {
        $JSONObject.'##' = @($JSONObject.'##')
    }
    $newComments = @($JSONObject.'##' | Where-Object { $_ -notmatch "^($($MetadataKeys -join '|'))\s*:" })
    foreach ($entry in $MetadataToWrite.GetEnumerator()) {
        $newComments += "$($entry.Key): $($entry.Value)"
    }
    $JSONObject.'##' = $newComments
    return $JSONObject
}

function Test-IsNewerVersion { param ($RemoteVersion, $LocalVersion); try { return [version]$RemoteVersion -ge [version]$LocalVersion } catch { return $true } }

function Compare-ManifestObjects {
    param([PsCustomObject]$ReferenceObject, [PsCustomObject]$DifferenceObject)

    $githubProjectRegex = '^https://github\.com/[^/]+/[^/]+/'
    function Get-Urls($Object) {
        $urls = @()
        if ($Object.PSObject.Properties['url']) { $urls += $Object.url }
        if ($Object.PSObject.Properties['architecture']) {
            foreach ($arch in $Object.architecture.PSObject.Properties) {
                if ($arch.Value.PSObject.Properties['url']) { $urls += $arch.Value.url }
            }
        }
        return $urls
    }
    $localUrls = Get-Urls -Object $ReferenceObject
    $remoteUrls = Get-Urls -Object $DifferenceObject
    if ($localUrls.Count -gt 0 -and $remoteUrls.Count -gt 0) {
        $localBase = ($localUrls[0] | Select-String -Pattern $githubProjectRegex).Matches.Value
        $remoteBase = ($remoteUrls[0] | Select-String -Pattern $githubProjectRegex).Matches.Value
        if ($localBase -and $remoteBase -and $localBase -ne $remoteBase) {
            Write-Host "    -> Complex change detected: URL project changed from '$localBase' to '$remoteBase'." -ForegroundColor Yellow
            return $false
        }
    }

    $localNorm = $ReferenceObject | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $remoteNorm = $DifferenceObject | ConvertTo-Json -Depth 10 | ConvertFrom-Json

    $localNorm = Set-CustomMetadata -JSONObject $localNorm -MetadataToWrite @{}
    $remoteNorm = Set-CustomMetadata -JSONObject $remoteNorm -MetadataToWrite @{}

    $topLevelIgnorable = @('version', 'url', 'hash', 'extract_dir')
    foreach ($key in $topLevelIgnorable) { if ($localNorm.PSObject.Properties[$key]) { $localNorm.PSObject.Properties.Remove($key) }; if ($remoteNorm.PSObject.Properties[$key]) { $remoteNorm.PSObject.Properties.Remove($key) } }

    $propsToClean = @('url', 'hash', 'extract_dir')
    if ($localNorm.PSObject.Properties['architecture']) { foreach ($arch in $localNorm.architecture.PSObject.Properties) { foreach ($prop in $propsToClean) { if ($arch.Value.PSObject.Properties[$prop]) { $arch.Value.PSObject.Properties.Remove($prop) } } } }
    if ($remoteNorm.PSObject.Properties['architecture']) { foreach ($arch in $remoteNorm.architecture.PSObject.Properties) { foreach ($prop in $propsToClean) { if ($arch.Value.PSObject.Properties[$prop]) { $arch.Value.PSObject.Properties.Remove($prop) } } } }

    if ($localNorm.PSObject.Properties['autoupdate']) { if ($localNorm.autoupdate.PSObject.Properties['architecture']) { foreach ($arch in $localNorm.autoupdate.architecture.PSObject.Properties) { if ($arch.Value.PSObject.Properties['url']) { $arch.Value.PSObject.Properties.Remove('url') }; if ($arch.Value.PSObject.Properties['hash']) { $arch.Value.PSObject.Properties.Remove('hash') } } } }
    if ($remoteNorm.PSObject.Properties['autoupdate']) { if ($remoteNorm.autoupdate.PSObject.Properties['architecture']) { foreach ($arch in $remoteNorm.autoupdate.architecture.PSObject.Properties) { if ($arch.Value.PSObject.Properties['url']) { $arch.Value.PSObject.Properties.Remove('url') }; if ($arch.Value.PSObject.Properties['hash']) { $arch.Value.PSObject.Properties.Remove('hash') } } } }

    $localString = $localNorm | ConvertTo-Json -Depth 10 -Compress
    $remoteString = $remoteNorm | ConvertTo-Json -Depth 10 -Compress
    return $localString -eq $remoteString
}

function Show-ManifestDiff {
    param([PsCustomObject]$LocalJson, [PsCustomObject]$RemoteJson)
    $localCopy = $LocalJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json; $remoteCopy = $RemoteJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $localCopy = Set-CustomMetadata -JSONObject $localCopy -MetadataToWrite @{}
    $localString = $localCopy | ConvertTo-Json -Depth 10; $remoteString = $remoteCopy | ConvertTo-Json -Depth 10
    $diff = Compare-Object -ReferenceObject ($localString -split '\r?\n') -DifferenceObject ($remoteString -split '\r?\n')
    if ($null -eq $diff) { return }; Write-Host "`n    --- Diff ---"
    foreach ($change in $diff) {
        if ($change.SideIndicator -eq '<=') { Write-Host ("- " + $change.InputObject) -ForegroundColor Red }
        elseif ($change.SideIndicator -eq '=>') { Write-Host ("+ " + $change.InputObject) -ForegroundColor Green }
    }
    Write-Host "    --- End Diff ---`n"
}

# =================================================================================
# Main Script Logic
# =================================================================================
$runTimestamp = (Get-Date).ToString("yyMMdd HH:mm:ss")
$timestampFormat = "yyMMdd HH:mm:ss"
$manifests = Get-ChildItem -Path $PersonalBucketPath -Filter *.json
$allManifestData = @()

Write-Host "🔍 Gathering manifest data from '$PersonalBucketPath'..."
foreach ($localManifestFile in $manifests) {
    $localJson = Get-Content -Path $localManifestFile.FullName -Raw | ConvertFrom-Json
    $metadata = Get-CustomMetadata -JSONObject $localJson
    $data = [pscustomobject]@{ File = $localManifestFile; Local = $localJson; Metadata = $metadata; IsPending = $false; PendingReason = '' }

    $lastChangeStr = $data.Metadata.sourceLastChangeFound
    $lastUpdateStr = $data.Metadata.sourceLastUpdated

    if ((-not [string]::IsNullOrEmpty($lastChangeStr)) -and (-not [string]::IsNullOrEmpty($lastUpdateStr))) {
        try {
            $updateDate = [datetime]::ParseExact($lastUpdateStr, $timestampFormat, $null)
            $changeDate = [datetime]::ParseExact($lastChangeStr, $timestampFormat, $null)
            if ($updateDate -gt $changeDate) { $data.IsPending = $true; $data.PendingReason = "source updated on $lastUpdateStr after last check on $lastChangeStr" }
        }
        catch {}
    }

    if (-not $data.IsPending) {
        $sourcePath = $data.Metadata.source
        if ($sourcePath -and $sourcePath -ne 'MANUAL' -and $sourcePath -ne 'DEPRECATED' -and (Test-Path $sourcePath)) {
            try {
                $fileUpdateStr = (Get-Item $sourcePath).LastWriteTime.ToString($timestampFormat)
                if ($fileUpdateStr -gt $lastUpdateStr) { $data.IsPending = $true; $data.PendingReason = "source file modified on $fileUpdateStr after last recorded update on $lastUpdateStr" }
            }
            catch {}
        }
    }
    $allManifestData += $data
}

$updateableManifests = $allManifestData | Where-Object { $_.Metadata.sourceState -ne 'dead' -and $_.Metadata.sourceState -ne 'manual' }

# --- Mode: List Manual ---
if ($ListManual) {
    Write-Host "`n📜 Listing manifests marked as MANUAL..." -ForegroundColor Cyan
    $manualFiles = $allManifestData | Where-Object { $_.Metadata.sourceState -eq 'manual' -or $_.Metadata.source -eq 'MANUAL' }
    if ($manualFiles) { $manualFiles | ForEach-Object { Write-Host "  - $($_.File.Name)" } } else { Write-Host "  ✅ No manifests are marked as MANUAL." }
    return
}

# --- Mode: List Pending ---
if ($ListPending) {
    Write-Host "`n📜 Listing manifests with pending changes..." -ForegroundColor Cyan
    $pendingCount = 0
    foreach ($data in $updateableManifests) {
        if ($data.IsPending) {
            $pendingCount++; Write-Host "  - $($data.File.Name) ($($data.PendingReason))" -ForegroundColor Yellow
        }
        elseif ($VerboseList) {
            $changeDate = $data.Metadata.sourceLastChangeFound; $updateDate = $data.Metadata.sourceLastUpdated
            Write-Host "  - $($data.File.Name) (source last changed on $updateDate before last manifest update on $changeDate, so skipping)" -ForegroundColor DarkGray
        }
    }
    if ($pendingCount -eq 0) { Write-Host "  ✅ No non-manual manifests have pending changes." }
    return
}

# --- Mode: Interactive ---
if ($Interactive) {
    Write-Host "`n👋 Starting interactive update session for pending changes..." -ForegroundColor Cyan
    $pendingFiles = $updateableManifests | Where-Object { $_.IsPending }
    if (-not $pendingFiles) { Write-Host "  ✅ No manifests have pending changes to review."; return }
    foreach ($data in $pendingFiles) {
        Write-Host "`n--- Reviewing '$($data.File.Name)' ---"; Write-Host "    Reason: $($data.PendingReason)" -ForegroundColor Cyan
        try { $remoteJson = Invoke-WebRequest -Uri $data.Metadata.sourceUrl -UseBasicParsing | ConvertFrom-Json } catch { Write-Warning "Could not fetch remote for '$($data.File.Name)'. Skipping."; continue }
        if (-not (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)) { Write-Host "    Remote version ($($remoteJson.version)) is older than local version ($($data.Local.version)). Skipping." -ForegroundColor Magenta; continue }

        Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        $choice = Read-Host "Apply this change? (A)ccept / (S)kip / (Q)uit"
        switch ($choice.ToLower()) {
            'a' {
                $newMetadata = $data.Metadata.Clone(); $newMetadata.sourceLastUpdated = $runTimestamp; $newMetadata.sourceLastChangeFound = $runTimestamp
                $newJson = Set-CustomMetadata -JSONObject $remoteJson -MetadataToWrite $newMetadata
                Write-Host "    -> Writing accepted changes to '$($data.File.Name)'..." -ForegroundColor DarkGray
                $newJson | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
                Write-Host "  ✅ Accepted. Manifest '$($data.File.Name)' has been updated." -ForegroundColor Green
            }
            's' { Write-Host "  ⏩ Skipped '$($data.File.Name)'." }
            'q' { Write-Host "🛑 Aborting interactive session."; return }
            default { Write-Host "  ⏩ Invalid choice. Skipping '$($data.File.Name)'." }
        }
    }
    Write-Host "`n✨ Interactive session complete."; return
}

# --- Mode: Default Automatic Update ---
Write-Host "`n🔄 Checking for updates in '$PersonalBucketPath'..."
foreach ($data in $updateableManifests) {
    $sourceUrl = $data.Metadata.sourceUrl
    if (([string]::IsNullOrWhiteSpace($sourceUrl)) -or ($sourceUrl -notlike 'http*')) { continue }

    $remoteJson = $null
    try { $remoteJson = Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing | ConvertFrom-Json } catch {
        if (-not $ChangesOnly) {
            Write-Host "`n  - Checking '$($data.File.Name)'..."
            Write-Warning "    ⚠️ Failed to download source. Error: $($_.Exception.Message)"
        }
        continue
    }

    $hasUpdate = ($data.Local.version -ne $remoteJson.version) -and (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)
    $hasStaleTimestamp = $data.IsPending

    if (-not $hasUpdate -and -not $hasStaleTimestamp) {
        if (-not $ChangesOnly) {
            Write-Host "`n  - Checking '$($data.File.Name)'..."
            Write-Host "    👍 Already up to date (version $($data.Local.version))."
        }
        continue
    }

    Write-Host "`n  - Checking '$($data.File.Name)'..."

    if (-not $hasUpdate -and $hasStaleTimestamp) {
        Write-Host "    👍 Already up to date (version $($data.Local.version))."
        $newMetadata = $data.Metadata.Clone(); $newMetadata.sourceLastUpdated = $runTimestamp
        Write-Host "      -> Correcting source timestamp due to file change: $($data.PendingReason)" -ForegroundColor DarkGray
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
        $updatedJson | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
        continue
    }

    if ($data.Local.version -ne $remoteJson.version -and -not (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)) {
        Write-Host "    Halted. Remote version ($($remoteJson.version)) is older than local version ($($data.Local.version))." -ForegroundColor Magenta
        continue
    }

    Write-Host "    - Local version: $($data.Local.version), Remote version: $($remoteJson.version)."

    if ($data.Metadata.sourceState -eq 'frozen') {
        Write-Host "    -> ❄️ Update found for FROZEN package. No action will be taken." -ForegroundColor Cyan
        Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        continue
    }

    if (Compare-ManifestObjects -ReferenceObject $data.Local -DifferenceObject $remoteJson) {
        Write-Host "    ✅ Simple version change detected. Auto-updating..."
        $data.Local.version = $remoteJson.version
        if ($remoteJson.PSObject.Properties['url']) { $data.Local.url = $remoteJson.url } elseif ($data.Local.PSObject.Properties['url']) { $data.Local.PSObject.Properties.Remove('url') }
        if ($remoteJson.PSObject.Properties['hash']) { $data.Local.hash = $remoteJson.hash } elseif ($data.Local.PSObject.Properties['hash']) { $data.Local.PSObject.Properties.Remove('hash') }
        if ($remoteJson.PSObject.Properties['extract_dir']) { $data.Local.extract_dir = $remoteJson.extract_dir } elseif ($data.Local.PSObject.Properties['extract_dir']) { $data.Local.PSObject.Properties.Remove('extract_dir') }
        if ($remoteJson.PSObject.Properties['architecture']) { $data.Local.architecture = $remoteJson.architecture } elseif ($data.Local.PSObject.Properties['architecture']) { $data.Local.PSObject.Properties.Remove('architecture') }
        if ($remoteJson.PSObject.Properties['autoupdate']) { $data.Local.autoupdate = $remoteJson.autoupdate } elseif ($data.Local.PSObject.Properties['autoupdate']) { $data.Local.PSObject.Properties.Remove('autoupdate') }

        $newMetadata = $data.Metadata.Clone(); $newMetadata.sourceLastUpdated = $runTimestamp; $newMetadata.sourceLastChangeFound = $runTimestamp
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata

        Write-Host "      -> Writing updated version and timestamps to '$($data.File.Name)'." -ForegroundColor DarkGray
        $updatedJson | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
    }
    else {
        Write-Warning "    ⚠️ Manifest has complex changes. Flagging for manual review."
        Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson

        $newMetadata = $data.Metadata.Clone(); $newMetadata.sourceLastChangeFound = $runTimestamp
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata

        Write-Host "      -> Updating 'sourceLastChangeFound' timestamp in '$($data.File.Name)'." -ForegroundColor DarkGray
        $updatedJson | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
    }
}
Write-Host "`n✨ Update check complete."
