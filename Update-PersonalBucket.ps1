<#
.SYNOPSIS
  Checks for and applies updates for Scoop manifests, with advanced change tracking and an interactive mode.

.DESCRIPTION
  This script tracks changes using metadata stored within the schema-conformant "##" property.
  It respects the 'sourceState' metadata field ('active', 'frozen', 'dead', 'manual') to control update behavior.
  It also supports 'sourceDelayDays' to delay updates, 'sourceUpdateMinimumDays' to throttle update frequency, and a 'sourceComment' field for arbitrary user notes.

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

.PARAMETER VerboseProcessing
  More detailed output during processing in all modes including the pre-processing steps common to all.

.PARAMETER Trace
  Trace mode, the maximum level of logged output detail.

.PARAMETER ChangesOnly
  In the default automatic mode, only outputs information for manifests that have updates or changes.

.PARAMETER Scope
  Restricts the scope of the manifests to only those matching the provided regex name pattern

.PARAMETER HideSkipped
    Under verbose processing, will nevertheless hide manifests that are skipped due to scope filtering.

.PARAMETER SkipFrozen
  In the default automatic mode, prevents showing the diff for frozen packages that have updates.

.EXAMPLE
  # Runs automatically to check for and apply updates in the default bucket path without user interaction.
  .\Update-PersonalBucket.ps1

.EXAMPLE
  # Lists all the pending changes to be made and verbosely outputs the status of all manifests assessed.
  .\Update-PersonalBucket.ps1 -ListPending -VerboseProcessing

.EXAMPLE
  # Interactively processes only the manifests beginning with characters 'ag' or 'bi'; all others have processing skipped.
  .\Update-PersonalBucket.ps1 -Interactive -VerboseProcessing -HideSkipped -Scope '^(ag|bi).*'

.EXAMPLE
  # Trace mode with extra timing detail on interactively processing only the manifests beginning with characters 'ag' or 'bi'; all others have processing skipped.
  .\Update-PersonalBucket.ps1 -Interactive -VerboseProcessing -HideSkipped -Trace -Scope '^(ag|bi).*'

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

    [Parameter(ParameterSetName = 'ListPending')]
    [switch]$VerboseList,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$ChangesOnly,

    [Parameter()]
    [switch]$VerboseProcessing,

    [Parameter()]
    [switch]$Trace,

    [Parameter()]
    [string]$Scope = '.*',

    [Parameter()]
    [switch]$HideSkipped,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$SkipFrozen
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
# Global Defaults
# =================================================================================

$MetadataKeys = 'source', 'sourceUrl', 'sourceLastUpdated', 'sourceLastChangeFound', 'sourceState', 'sourceDelayDays', 'sourceUpdateMinimumDays', 'sourceComment', 'sourceHash'
$timestampFormat = "yyMMdd HH:mm:ss"
$logTimestamp = $true

# =================================================================================
# Helper Functions
# =================================================================================

Function Log-It {
    param(
        [string]$Message,
        [String]$Colour = "DarkGray"
    )
    if ($logTimestamp) {
        Write-Host "$(Get-Date -Format $timestampFormat) - $Message" -ForegroundColor $Colour
    }
    else {
        Write-Host "$Message" -ForegroundColor $Colour
    }
}

Function Log-Warning {
    param(
        [string]$Message,
        [String]$Colour = "DarkRed"
    )
    if ($logTimestamp) {
        Write-Warning "$(Get-Date -format o) - $Message" -ForegroundColor $Colour
    }
    else {
        Write-Warning "$Message" -ForegroundColor $Colour
    }
}

Function Log-Highlight {
    param([string]$Message)
    Log-It -Message $Message -Colour Yellow
}

Function Log-Verbose {
    param([string]$Message)
    if ($VerboseProcessing) {
        Log-It -Message $Message -Colour DarkYellow
    }
}

Function Log-Trace {
    param([string]$Message)
    if ($Trace) {
        Log-It -Message $Message -Colour Blue
    }
}

# Returns the formatted date in our default global format. Takes an input DateTime otherwise defaults to `now` in UTC
Function Get-FormattedDate {
    param([datetime]$DateTime = ([datetime]::UtcNow))
    return $DateTime.ToString($timestampFormat)
}

# A helper to get 'now' in the context of operation. Currently in UTC but provides a shim to change this in the future if needed.
Function Get-Now {
    return [datetime]::UtcNow
}

Function Get-GitCommitDate {
    param([string]$FilePath, [string]$StoredHash, [string]$StoredDate)
    if (-Not (Test-Path $FilePath)) { return $null }
    $dir = Split-Path $FilePath
    $repoDir = $dir
    while ($repoDir -And !(Test-Path (Join-Path $repoDir ".git"))) {
        $parent = Split-Path $repoDir
        if ($parent -eq $repoDir) { $repoDir = $null; break }
        $repoDir = $parent
    }
    if ($repoDir) {
        $repoRelativePath = $FilePath.Replace($repoDir, "").TrimStart("\").Replace("\", "/")

        # Resolve the current blob hash (instant metadata lookup)
        $currentHash = git -C $repoDir rev-parse "HEAD:$repoRelativePath" 2>$null

        # If we have a hash and it matches the stored one, skip the slow history walk
        if ($currentHash -And $StoredHash -And ($currentHash -eq $StoredHash) -And $StoredDate) {
            Log-Trace "      -> Hash matches stored value ($currentHash). Skipping slow git walk."
            return [pscustomobject]@{ Date = $StoredDate; Hash = $currentHash; Match = $true }
        }

        Log-Trace "      -> Hash changed or missing. Getting last commit date for '$FilePath'"
        $gitDate = git -C $repoDir --no-pager log -1 --format=%cI -- $FilePath 2>$null
        Log-Trace "      -> Git last commit date for file '$FilePath' is '$gitDate'"
        $finalDate = if ($gitDate) {
            ([datetime]$gitDate).ToUniversalTime().ToString($timestampFormat)
        }
        else {
            (Get-Item $FilePath).LastWriteTime.ToUniversalTime().ToString($timestampFormat)
        }
        return [pscustomobject]@{ Date = $finalDate; Hash = $currentHash; Match = $false }
    }
    return [pscustomobject]@{ Date = (Get-Item $FilePath).LastWriteTime.ToUniversalTime().ToString($timestampFormat); Hash = "LWT"; Match = $false }
}

Function Get-CustomMetadata($JSONObject) {
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

# Sets the custom metadata fields in the '##' property of the given JSON object.
# This is the only safe place we can modify in the manifest without breaking schema compliance.
# A little at risk of change by Scoop in the future but have to live with it.
Function Set-CustomMetadata($JSONObject, $MetadataToWrite) {
    if (-Not $JSONObject.PSObject.Properties['##']) {
        $JSONObject | Add-Member -MemberType NoteProperty -Name '##' -Value @()
    }
    elseif ($JSONObject.'##' -isnot [array]) {
        $JSONObject.'##' = @($JSONObject.'##')
    }
    $newComments = @($JSONObject.'##' | Where-Object { $_ -Notmatch "^($($MetadataKeys -join '|'))\s*:" })
    foreach ($entry in $MetadataToWrite.GetEnumerator()) {
        $newComments += "$($entry.Key): $($entry.Value)"
    }
    $JSONObject.'##' = $newComments
    return $JSONObject
}

# Version comparison test using [version] type casting to check for ordering. Relies on versions being castable to [version].
Function Test-IsNewerVersion { param ($RemoteVersion, $LocalVersion); try { return [version]$RemoteVersion -ge [version]$LocalVersion } catch { return $true } }

Function Compare-ManifestObjects {
    param([PsCustomObject]$ReferenceObject, [PsCustomObject]$DifferenceObject)

    $githubProjectRegex = '^https://github\.com/[^/]+/[^/]+/'
    Function Get-Urls($Object) {
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
    if ($localUrls.Count -gt 0 -And $remoteUrls.Count -gt 0) {
        $localBase = ($localUrls[0] | Select-String -Pattern $githubProjectRegex).Matches.Value
        $remoteBase = ($remoteUrls[0] | Select-String -Pattern $githubProjectRegex).Matches.Value
        if ($localBase -And $remoteBase -And $localBase -ne $remoteBase) {
            Log-Highlight "    -> Complex change detected: URL project changed from '$localBase' to '$remoteBase'."
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

Function Show-ManifestDiff {
    param([PsCustomObject]$LocalJson, [PsCustomObject]$RemoteJson)
    $localCopy = $LocalJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json; $remoteCopy = $RemoteJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $localCopy = Set-CustomMetadata -JSONObject $localCopy -MetadataToWrite @{}
    $localString = $localCopy | ConvertTo-Json -Depth 10; $remoteString = $remoteCopy | ConvertTo-Json -Depth 10
    $diff = Compare-Object -ReferenceObject ($localString -split '\r?\n') -DifferenceObject ($remoteString -split '\r?\n')
    if ($null -eq $diff) { return }
    Write-Host
    Log-It "    --- Diff ---"
    foreach ($change in $diff) {
        if ($change.SideIndicator -eq '<=') { Log-It ("- " + $change.InputObject) "Red" }
        elseif ($change.SideIndicator -eq '=>') { Log-It ("+ " + $change.InputObject) "Green" }
    }
    Log-It "    --- End Diff ---`n"
}

# =================================================================================================
# Main Script Logic
# =================================================================================================

$runTimestamp = Get-FormattedDate
$manifests = Get-ChildItem -Path $PersonalBucketPath -Filter *.json
$allManifestData = @()

# This iterates through all the manifests and gathers their metadata and pending status.
Log-It "🔍 Gathering manifest data from '$PersonalBucketPath'..."
foreach ($localManifestFile in $manifests) {
    # Scope filter
    if ($localManifestFile.BaseName -Notmatch $Scope) {
        if ($VerboseProcessing -And -Not $HideSkipped) {
            Log-It "  -> Skipping '$($localManifestFile.Name)' (does not match scope pattern '$Scope')"
        }
        continue
    }
    $localJson = Get-Content -Path $localManifestFile.FullName -Raw | ConvertFrom-Json
    $metadata = Get-CustomMetadata -JSONObject $localJson
    $data = [pscustomobject]@{ File = $localManifestFile; Local = $localJson; Metadata = $metadata; IsPending = $false; PendingReason = ''; CurrentHash = '' }

    #$lastChangeStr = $data.Metadata.sourceLastChangeFound
    $lastUpdateStr = $data.Metadata.sourceLastUpdated
    $storedHash = $data.Metadata.sourceHash

    $sourcePath = $data.Metadata.source
    if ($sourcePath -And $sourcePath -ne 'MANUAL' -And $sourcePath -ne 'DEPRECATED' -And (Test-Path $sourcePath)) {
        try {
            Log-Trace "    -> Checking source date for '$($localManifestFile.Name)' at source path '$sourcePath'"
            $sourceInfo = Get-GitCommitDate -FilePath $sourcePath -StoredHash $storedHash -StoredDate $lastUpdateStr
            $fileUpdateStr = $sourceInfo.Date
            $data.CurrentHash = $sourceInfo.Hash

            # If hash is missing, normalize it now to save future time
            if ([string]::IsNullOrEmpty($storedHash)) {
                Log-Verbose "  -> Uninitialized hash for '$($localManifestFile.Name)'. Performing one-off sync..."
                $newMetadata = $data.Metadata.Clone()
                $newMetadata.sourceLastUpdated = $fileUpdateStr
                $newMetadata.sourceHash = $data.CurrentHash
                $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
                $updatedJson | ConvertTo-Json -Depth 10 | Set-Content -Path $localManifestFile.FullName -Encoding UTF8
                $data.Metadata = $newMetadata # Keep object current in memory
            }

            if ($sourceInfo.Match) {
                if ($VerboseProcessing) {
                    Log-It "  -> Source check for '$($localManifestFile.Name)' shows no update needed (blob hash is unchanged)"
                }
            }
            elseif ($fileUpdateStr -gt $lastUpdateStr) {
                $data.IsPending = $true
                $data.PendingReason = "upstream source updated to $fileUpdateStr after last recorded update on $lastUpdateStr"
                if ($VerboseProcessing) {
                    Log-Highlight "  -> Marking '$($localManifestFile.Name)' as pending because the upstream source was updated to $fileUpdateStr which is after the last recorded update on $lastUpdateStr"
                }
            }
            else {
                if ($VerboseProcessing) {
                    Log-It "  -> Source date check for '$($localManifestFile.Name)' shows no update needed (source date $fileUpdateStr is not after last recorded update on $lastUpdateStr)"
                }
            }
        }
        catch {
            Log-Verbose "  -> Warning: Failed to check source date for '$($localManifestFile.Name)'. Error: $($_.Exception.Message)"
        }
    }
    else {
        Log-Verbose "  -> Skipping source date check for '$($localManifestFile.Name)' (source path is missing or non-standard or it's a manual or deprecated source)."
    }

    $allManifestData += $data
}

$updateableManifests = $allManifestData | Where-Object { $_.Metadata.sourceState -ne 'dead' -And $_.Metadata.sourceState -ne 'manual' }

# --- Mode: List Manual ---
if ($ListManual) {
    Write-Host
    Log-It "📜 Listing manifests marked as MANUAL..." Cyan
    $manualFiles = $allManifestData | Where-Object { $_.Metadata.sourceState -eq 'manual' -Or $_.Metadata.source -eq 'MANUAL' }
    if ($manualFiles) {
        $manualFiles | ForEach-Object { Log-It "  - $($_.File.Name)" }
    }
    else {
        Log-It "  ✅ No manifests are marked as MANUAL"
    }
    return
}

# --- Mode: List Pending ---
if ($ListPending) {
    Write-Host
    Log-It "📜 Listing manifests with pending changes..." Cyan
    $pendingCount = 0
    foreach ($data in $updateableManifests) {
        if ($data.IsPending) {
            $pendingCount++
            Log-Highlight "  - $($data.File.Name) ($($data.PendingReason))"
        }
        elseif ($VerboseList) {
            $updateDate = $data.Metadata.sourceLastUpdated
            Log-It "  - $($data.File.Name) (authentic source date is $updateDate, skipping)"
        }
    }
    if ($pendingCount -eq 0) { Log-It "  ✅ No non-manual manifests have pending changes" }
    return
}

# --- Mode: Interactive ---
if ($Interactive) {
    Write-Host
    Log-It "👋 Starting interactive update session..." Cyan
    $updateCandidates = 0
    foreach ($data in $updateableManifests) {
        $sourceUrl = $data.Metadata.sourceUrl
        if (([string]::IsNullOrWhiteSpace($sourceUrl)) -Or ($sourceUrl -Notlike 'http*')) { continue }
        Write-Host
        Log-It "- Checking '$($data.File.Name)'..."
        $remoteJson = $null
        try { $remoteJson = Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing | ConvertFrom-Json } catch { continue }

        if ($data.Local.version -eq $remoteJson.version -And -Not $data.IsPending) { continue }
        if ($data.Local.version -ne $remoteJson.version -And -Not (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)) { continue }

        $updateCandidates++
        Log-Highlight "--- Reviewing '$($data.File.Name)' ---"

        $proceedToStandardPrompt = $false
        if ($data.Metadata.sourceState -eq 'frozen') {
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
            $frozenChoice = Read-Host "-> ❄️ This package is FROZEN. Skip this update? (Y)es / (N)o"
            if ($frozenChoice.ToLower() -eq 'n') {
                $proceedToStandardPrompt = $true
            }
            else {
                Log-It "  -> ❄️ Skipping frozen package as requested" Cyan
                continue
            }
        }
        else {
            $proceedToStandardPrompt = $true
        }

        if ($proceedToStandardPrompt) {
            if ($data.Metadata.sourceState -ne 'frozen') {
                Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
            }

            $delayDays = 0; if ($data.Metadata.sourceDelayDays -match '^\d+$') { $delayDays = [int]$data.Metadata.sourceDelayDays }
            if ($delayDays -gt 0) {
                try {
                    $updateDate = [datetime]::ParseExact($data.Metadata.sourceLastUpdated, $timestampFormat, $null)
                    $updateAge = (Get-Now) - $updateDate
                    if ($updateAge.TotalDays -lt $delayDays) {
                        Log-Warning "This source update is only $($updateAge.TotalDays.ToString('F0')) days old, which is within the $($delayDays)-day delay period"
                    }
                }
                catch {}
            }
            $minDays = 0; if ($data.Metadata.sourceUpdateMinimumDays -match '^\d+$') { $minDays = [int]$data.Metadata.sourceUpdateMinimumDays }
            if ($minDays -gt 0) {
                try {
                    $changeDate = [datetime]::ParseExact($data.Metadata.sourceLastChangeFound, $timestampFormat, $null)
                    $lastChangeAge = (Get-Now) - $changeDate
                    if ($lastChangeAge.TotalDays -lt $minDays) {
                        Log-Warning "This manifest was last updated only $($lastChangeAge.TotalDays.ToString('F0')) days ago (minimum is $($minDays))"
                    }
                }
                catch {}
            }

            $choice = Read-Host "Apply this change? (A)ccept / (F)reeze / (S)kip / (Q)uit"
            switch ($choice.ToLower()) {
                'a' {
                    $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
                    $newMetadata = $data.Metadata.Clone()
                    $newMetadata.sourceLastUpdated = $sourceInfo.Date
                    $newMetadata.sourceHash = $sourceInfo.Hash
                    $newMetadata.sourceLastChangeFound = $runTimestamp
                    $newJson = Set-CustomMetadata -JSONObject $remoteJson -MetadataToWrite $newMetadata
                    Log-It "    -> Writing accepted changes to '$($data.File.Name)'..."
                    $newJson | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
                    Log-It "  ✅ Accepted. Manifest '$($data.File.Name)' has been updated" Green
                }
                'f' {
                    Log-It "  -> ❄️ Freezing package '$($data.File.Name)' at current version"
                    $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
                    $newMetadata = $data.Metadata.Clone()
                    $newMetadata.sourceState = 'frozen'
                    $newMetadata.sourceLastUpdated = $sourceInfo.Date
                    $newMetadata.sourceHash = $sourceInfo.Hash
                    $newMetadata.sourceLastChangeFound = $runTimestamp
                    $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
                    Log-It "    -> Writing updated state to manifest..."
                    $updatedJson | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
                }
                's' { Log-It "  ⏩ Skipped '$($data.File.Name)'." }
                'q' { Log-It "🛑 Aborting interactive session."; return }
                default { Log-It "  ⏩ Invalid choice. Skipping '$($data.File.Name)'" }
            }
        }
    }
    if ($updateCandidates -eq 0) {
        Write-Host
        Log-It "  ✅ No manifests have pending changes to review"
    }
    Write-Host
    Log-It "✨ Interactive session complete"
    return
}

# --- Mode: Default Automatic Update ---
Write-Host
Log-It "🔄 Checking for updates in '$PersonalBucketPath'..."
foreach ($data in $updateableManifests) {
    $sourceUrl = $data.Metadata.sourceUrl
    if (([string]::IsNullOrWhiteSpace($sourceUrl)) -Or ($sourceUrl -Notlike 'http*')) { continue }

    # CHURN GUARD: Determine the authentic status of the source file BEFORE doing anything else
    $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
    $authenticSourceDate = $sourceInfo.Date
    $currentHash = $sourceInfo.Hash

    $remoteJson = $null
    try { $remoteJson = Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing | ConvertFrom-Json } catch {
        if (-Not $ChangesOnly) {
            Write-Host
            Log-It "  - Checking '$($data.File.Name)'..."
            Log-Warning "    ⚠️ Failed to download source. Error: $($_.Exception.Message)"
        }
        continue
    }

    $hasUpdate = ($data.Local.version -ne $remoteJson.version) -And (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)
    $sourceFileChanged = ($authenticSourceDate -gt $data.Metadata.sourceLastUpdated)

    # FINAL CHURN GUARD: If no version jump AND the source file is exactly where we last left it, skip the manifest.
    if (-Not $hasUpdate -And -Not $sourceFileChanged) {
        if (-Not $ChangesOnly) {
            Write-Host
            Log-It "  - Checking '$($data.File.Name)'..."
            Log-It "    👍 Already up to date (version $($data.Local.version))"
        }
        continue
    }

    Write-Host
    Log-It "  - Checking '$($data.File.Name)'..."

    if (-Not $hasUpdate -And $sourceFileChanged) {
        Log-It "    👍 Already up to date (version $($data.Local.version))"
        $newMetadata = $data.Metadata.Clone();
        $newMetadata.sourceLastUpdated = $authenticSourceDate
        $newMetadata.sourceHash = $currentHash
        $newMetadata.sourceLastChangeFound = $runTimestamp
        Log-It "      -> Syncing timestamps: authentic date is $authenticSourceDate"
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
        $updatedJson | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
        continue
    }

    if ($data.Local.version -ne $remoteJson.version -And -Not (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)) {
        Log-It "    Halted; remote version ($($remoteJson.version)) is older than local version ($($data.Local.version))" Magenta
        continue
    }

    Log-It "    - Local version: $($data.Local.version), Remote version: $($remoteJson.version)"

    if ($data.Metadata.sourceState -eq 'frozen') {
        Log-It "    -> ❄️ Update found for FROZEN package; no action will be taken" Cyan
        if (-Not $SkipFrozen) {
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        }
        continue
    }

    $minDays = 0; if ($data.Metadata.sourceUpdateMinimumDays -match '^\d+$') { $minDays = [int]$data.Metadata.sourceUpdateMinimumDays }
    if ($minDays -gt 0) {
        try {
            $changeDate = [datetime]::ParseExact($data.Metadata.sourceLastChangeFound, $timestampFormat, $null)
            $lastChangeAge = (Get-Now) - $changeDate
            if ($lastChangeAge.TotalDays -lt $minDays) {
                Log-It "    -> 🕰️  Update found, but logging only; manifest was updated $($lastChangeAge.TotalDays.ToString('F0')) days ago (minimum is $($minDays))" Magenta
                Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
                continue
            }
        }
        catch {}
    }

    $delayDays = 0; if ($data.Metadata.sourceDelayDays -match '^\d+$') { $delayDays = [int]$data.Metadata.sourceDelayDays }
    if ($delayDays -gt 0) {
        try {
            $updateDate = [datetime]::ParseExact($data.Metadata.sourceLastUpdated, $timestampFormat, $null)
            $updateAge = (Get-Now) - $updateDate
            if ($updateAge.TotalDays -lt $delayDays) {
                Log-It "    -> 🕰️  Update found, but source change is too recent to apply (within $($delayDays)-day delay period); skipping..." Magenta
                continue
            }
        }
        catch {}
    }

    if (Compare-ManifestObjects -ReferenceObject $data.Local -DifferenceObject $remoteJson) {
        Log-It "    ✅ Simple version change detected. Auto-updating..."
        $data.Local.version = $remoteJson.version
        if ($remoteJson.PSObject.Properties['url']) { $data.Local.url = $remoteJson.url } elseif ($data.Local.PSObject.Properties['url']) { $data.Local.PSObject.Properties.Remove('url') }
        if ($remoteJson.PSObject.Properties['hash']) { $data.Local.hash = $remoteJson.hash } elseif ($data.Local.PSObject.Properties['hash']) { $data.Local.PSObject.Properties.Remove('hash') }
        if ($remoteJson.PSObject.Properties['extract_dir']) { $data.Local.extract_dir = $remoteJson.extract_dir } elseif ($data.Local.PSObject.Properties['extract_dir']) { $data.Local.PSObject.Properties.Remove('extract_dir') }
        if ($remoteJson.PSObject.Properties['architecture']) { $data.Local.architecture = $remoteJson.architecture } elseif ($data.Local.PSObject.Properties['architecture']) { $data.Local.PSObject.Properties.Remove('architecture') }
        if ($remoteJson.PSObject.Properties['autoupdate']) { $data.Local.autoupdate = $remoteJson.autoupdate } elseif ($data.Local.PSObject.Properties['autoupdate']) { $data.Local.PSObject.Properties.Remove('autoupdate') }

        $newMetadata = $data.Metadata.Clone();
        $newMetadata.sourceLastUpdated = $authenticSourceDate
        $newMetadata.sourceHash = $currentHash
        $newMetadata.sourceLastChangeFound = $runTimestamp
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata

        Log-It "      -> Writing updated version and timestamps to '$($data.File.Name)'"
        $updatedJson | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
    }
    else {
        # IMPORTANT: Flag only if we haven't already flagged it.
        if ($data.Metadata.sourceLastChangeFound -le $data.Metadata.sourceLastUpdated) {
            Log-Warning "    ⚠️ Manifest has complex changes. Flagging for manual review"
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
            $newMetadata = $data.Metadata.Clone()
            $newMetadata.sourceLastChangeFound = $runTimestamp
            $newMetadata.sourceHash = $currentHash
            $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
            Log-It "      -> Updating 'sourceLastChangeFound' and hash in '$($data.File.Name)'"
            $updatedJson | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
        }
    }
}
Write-Host
Log-It "✨ Update check complete"
