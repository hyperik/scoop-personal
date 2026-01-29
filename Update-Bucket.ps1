<#
.SYNOPSIS
  Checks for and applies updates for Scoop manifests, with advanced change tracking and an interactive mode.

.DESCRIPTION
  This script tracks changes using metadata stored within the schema-conformant "##" property.
  It respects the 'sourceState' metadata field ('active', 'frozen', 'dead', 'manual') to control update behavior.
  It also supports 'sourceDelayDays' to delay updates, 'sourceUpdateMinimumDays' to throttle update frequency,
  a 'sourceDeferredUpdateFound' field to track deferred updates, and a 'sourceComment' field for arbitrary user notes.

    The script can run in seven modes:
    1. Default (Automatic): Auto-applies simple updates and flags complex changes.
    2. Interactive Mode: Prompts the user to accept or skip complex changes.
    3. List Pending Mode: Lists manifests with pending changes and their relevant timestamps.
    4. List Manual Mode: Lists all manifests configured as MANUAL.
    5. List Locks Mode: Lists manifests that are frozen or domain-change-lock.
    6. Process Locks Mode: Interactively reviews locked manifests and allows unlocking with updates.
    7. Verbose List Mode: When used with -ListPending, shows all non-manual files and explains their status.

.PARAMETER BucketPath
  The full path to the 'bucket' directory of your personal Scoop repository. Overrides the default behavior.

.PARAMETER ListPending
  Lists all manifests with detected changes that have not yet been applied.

.PARAMETER ListManual
  Lists all manifests that are configured with a source of 'MANUAL' or a state of 'manual'.

.PARAMETER ListLocks
  Lists all manifests that are configured with a state of 'frozen' or 'domain-change-lock'.

.PARAMETER ProcessLocks
  Interactively processes locked manifests (frozen or explicit lock states) and allows unlocking with updates.

.PARAMETER ExcludeFrozen
  When used with -ProcessLocks, ignores manifests with a 'frozen' state.

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

.PARAMETER AutoComplex
  In the default automatic mode, logs complex changes, dumps the diff, and still applies the changes.

.PARAMETER InteractiveComplex
  In the default automatic mode, prompts for whether to accept complex changes instead of auto-applying.

.PARAMETER DefaultDelayDays
  Default number of days to delay updates when sourceDelayDays is not explicitly set in a manifest.

.PARAMETER DefaultMinimumDays
  Default minimum number of days between updates when sourceUpdateMinimumDays is not explicitly set in a manifest.

.PARAMETER DeepComparison
  Determines whether to compare all JSON fields (except the '##' comment node) to decide if an update is needed.

.PARAMETER FullUpdate
  Forces a full update run: ignores delay/minimum-day windows, auto-accepts complex changes,
  and enables deep comparison to detect any JSON changes (excluding the '##' comment node).

.PARAMETER PullSources
    Pulls each repository listed in local-repos.cfg before processing any manifests.

.EXAMPLE
  # Runs automatically to check for and apply updates in the default bucket path without user interaction.
  .\Update-Bucket.ps1

.EXAMPLE
  # Lists all the pending changes to be made and verbosely outputs the status of all manifests assessed.
  .\Update-Bucket.ps1 -ListPending -VerboseProcessing

.EXAMPLE
  # Interactively processes only the manifests beginning with characters 'ag' or 'bi'; all others have processing skipped.
  .\Update-Bucket.ps1 -Interactive -VerboseProcessing -HideSkipped -Scope '^(ag|bi).*'

.EXAMPLE
  # Trace mode with extra timing detail on interactively processing only the manifests beginning with characters 'ag' or 'bi'; all others have processing skipped.
  .\Update-Bucket.ps1 -Interactive -VerboseProcessing -HideSkipped -Trace -Scope '^(ag|bi).*'

.EXAMPLE
  # Fully updates all non-locked active manifests, including re-pulling all local source repositories.
  .\Update-Bucket.ps1 -FullUpdate

.EXAMPLE
  # Interactively processes all locked manifests, excluding those that are frozen.
  .\Update-Bucket.ps1 -ProcessLocks -ExcludeFrozen

#>
[CmdletBinding(DefaultParameterSetName = 'Automatic')]
param(
    [Parameter(ParameterSetName = 'Automatic')]
    [string]$BucketPath = $null,

    [Parameter(ParameterSetName = 'ListPending')]
    [switch]$ListPending,

    [Parameter(ParameterSetName = 'ListManual')]
    [switch]$ListManual,

    [Parameter(ParameterSetName = 'ListLocks')]
    [switch]$ListLocks,

    [Parameter(ParameterSetName = 'ProcessLocks')]
    [switch]$ProcessLocks,

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
    [switch]$SkipFrozen,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$AutoComplex,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$InteractiveComplex,

    [Parameter()]
    [int]$DefaultDelayDays = 7,

    [Parameter()]
    [int]$DefaultMinimumDays = 2,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$DeepComparison,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$FullUpdate,

    [Parameter()]
    [switch]$PullSources,

    [Parameter(ParameterSetName = 'ProcessLocks')]
    [switch]$ExcludeFrozen
)

# --- Initial Setup ---
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($BucketPath)) {
    $localBucketPath = Join-Path -Path $scriptDir -ChildPath 'bucket'
    if (Test-Path -Path $localBucketPath) {
        $BucketPath = $localBucketPath
    }
    else {
        $BucketPath = 'D:\dev\src\hyperik\scoop-personal\bucket' # Fallback default
    }
}

# =================================================================================
# Global Defaults
# =================================================================================

$MetadataKeys = 'source', 'sourceUrl', 'sourceLastUpdated', 'sourceLastChangeFound', 'sourceState', 'sourceDelayDays', 'sourceUpdateMinimumDays', 'sourceDeferredUpdateFound', 'sourceComment', 'sourceHash'
$timestampFormat = "yyMMdd HH:mm:ss"
$logTimestamp = $true

# =================================================================================
# Helper Functions
# =================================================================================

Function Write-Log {
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

Function Write-LogWarning {
    param(
        [string]$Message,
        [String]$Colour = "DarkRed"
    )
    if ($logTimestamp) {
        Write-Warning "$(Get-Date -format o) - $Message"
    }
    else {
        Write-Warning "$Message"
    }
}

Function Write-Highlight {
    param([string]$Message)
    Write-Log -Message $Message -Colour Yellow
}

Function Write-Concern {
    param([string]$Message)
    Write-Log -Message $Message -Colour Magenta
}


Function Write-LogVerbose {
    param([string]$Message)
    if ($VerboseProcessing) {
        Write-Log -Message $Message -Colour DarkYellow
    }
}

Function Write-Trace {
    param([string]$Message)
    if ($Trace) {
        Write-Log -Message $Message -Colour Blue
    }
}

Function Invoke-PullSourceRepos {
    param(
        [string]$ConfigPath,
        [switch]$VerboseOutput
    )

    if (-Not (Test-Path $ConfigPath)) {
        Write-LogWarning "local-repos.cfg not found at '$ConfigPath'. Skipping source pulls."
        return
    }

    $entries = Get-Content -Path $ConfigPath | Where-Object { $_ -match ';' }
    if (-Not $entries -or $entries.Count -eq 0) {
        Write-LogWarning "No repository entries found in '$ConfigPath'. Skipping source pulls."
        return
    }

    Write-Log "🔄 Pulling source repositories listed in '$ConfigPath'..."
    foreach ($entry in $entries) {
        $parts = $entry -split ';', 2
        $repoPath = $parts[0].Trim()
        if ([string]::IsNullOrWhiteSpace($repoPath)) { continue }

        if (-Not (Test-Path $repoPath)) {
            Write-LogWarning "Source repo path not found: '$repoPath'"
            continue
        }

        if (-Not (Test-Path (Join-Path $repoPath '.git'))) {
            Write-LogWarning "Skipping non-git repo path: '$repoPath'"
            continue
        }

        try {
            if ($VerboseOutput) {
                Write-Log "  -> Pulling '$repoPath'"
            }
            git -C $repoPath pull | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-LogWarning "Pull failed for '$repoPath' (exit code $LASTEXITCODE)."
            }
            elseif ($VerboseOutput) {
                Write-Log "  ✅ Pulled '$repoPath'" "Green"
            }
        }
        catch {
            Write-LogWarning "Pull failed for '$repoPath': $($_.Exception.Message)"
        }
    }
}

Function Get-ChangeDecision {
    param(
        [string]$Prompt = "Apply this change? (A)ccept / (F)reeze / (S)kip / (Q)uit"
    )
    $choice = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($choice)) {
        return 's'
    }
    return $choice.ToLower()
}

Function Invoke-ChangeDecision {
    param(
        [string]$Choice,
        [pscustomobject]$Data,
        [pscustomobject]$RemoteJson,
        [string]$RunTimestamp,
        [pscustomobject]$SourceInfo,
        [switch]$RecordDeferredOnSkipOrFreeze
    )

    if (-Not $SourceInfo) {
        $SourceInfo = Get-GitCommitDate -FilePath $Data.Metadata.source -StoredHash $Data.Metadata.sourceHash -StoredDate $Data.Metadata.sourceLastUpdated
    }

    switch ($Choice) {
        'a' {
            $newMetadata = $Data.Metadata.Clone()
            $newMetadata.sourceLastUpdated = $SourceInfo.Date
            $newMetadata.sourceHash = $SourceInfo.Hash
            $newMetadata.sourceLastChangeFound = $RunTimestamp
            if ($newMetadata.ContainsKey('sourceDeferredUpdateFound')) {
                $newMetadata.Remove('sourceDeferredUpdateFound')
            }
            $newJson = Set-CustomMetadata -JSONObject $RemoteJson -MetadataToWrite $newMetadata
            Write-Log "    -> Writing accepted changes to '$($Data.File.Name)'..."
            Write-Manifest -MetadataToWrite $newJson -FilePath $Data.File.FullName
            Write-Log "  ✅ Accepted. Manifest '$($Data.File.Name)' has been updated" Green
            return $true
        }
        'f' {
            Write-Log "  -> ❄️ Freezing package '$($Data.File.Name)' at current version"
            $newMetadata = $Data.Metadata.Clone()
            $newMetadata.sourceState = 'frozen'
            $newMetadata.sourceLastUpdated = $SourceInfo.Date
            $newMetadata.sourceHash = $SourceInfo.Hash
            $newMetadata.sourceLastChangeFound = $RunTimestamp
            if ($RecordDeferredOnSkipOrFreeze) {
                $newMetadata.sourceDeferredUpdateFound = $RunTimestamp
            }
            $updatedJson = Set-CustomMetadata -JSONObject $Data.Local -MetadataToWrite $newMetadata
            Write-Log "    -> Writing updated state to manifest..."
            Write-Manifest -MetadataToWrite $updatedJson -FilePath $Data.File.FullName
            return $true
        }
        's' {
            Write-Log "  ⏩ Skipped '$($Data.File.Name)'."
            if ($RecordDeferredOnSkipOrFreeze) {
                Set-DeferredUpdateFound -Data $Data -RunTimestamp $RunTimestamp | Out-Null
            }
            return $true
        }
        'q' {
            Write-Log "🛑 Aborting update run."
            return $false
        }
        default {
            Write-Log "  ⏩ Invalid choice. Skipping '$($Data.File.Name)'"
            return $true
        }
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

Function Get-DeferredUpdateDate {
    param([hashtable]$Metadata)

    if (-Not $Metadata -Or -Not $Metadata.sourceDeferredUpdateFound) { return $null }
    try {
        return [datetime]::ParseExact($Metadata.sourceDeferredUpdateFound, $timestampFormat, $null)
    }
    catch {
        return $null
    }
}

Function Set-DeferredUpdateFound {
    param(
        [pscustomobject]$Data,
        [string]$RunTimestamp
    )

    if ($Data.Metadata.sourceDeferredUpdateFound) { return $false }
    $newMetadata = $Data.Metadata.Clone()
    $newMetadata.sourceDeferredUpdateFound = $RunTimestamp
    $updatedJson = Set-CustomMetadata -JSONObject $Data.Local -MetadataToWrite $newMetadata
    Write-Log "      -> Recording deferred update timestamp in '$($Data.File.Name)'"
    Write-Manifest -MetadataToWrite $updatedJson -FilePath $Data.File.FullName
    return $true
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
            Write-Trace "      -> Hash matches stored value ($currentHash). Skipping slow git walk."
            return [pscustomobject]@{ Date = $StoredDate; Hash = $currentHash; Match = $true }
        }

        Write-Trace "      -> Hash changed or missing. Getting last commit date for '$FilePath'"
        $gitDate = git -C $repoDir --no-pager log -1 --format=%cI -- $FilePath 2>$null
        Write-Trace "      -> Git last commit date for file '$FilePath' is '$gitDate'"
        if ($gitDate) {
            $finalDate = ([datetime]$gitDate).ToUniversalTime().ToString($timestampFormat)
        }
        else {
            $finalDate = (Get-Item $FilePath).LastWriteTime.ToUniversalTime().ToString($timestampFormat)
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
    $baseComments = @($JSONObject.'##' | Where-Object { $_ -Notmatch "^($($MetadataKeys -join '|'))\s*:" })
    $metadataLines = @(
        $MetadataToWrite.GetEnumerator() |
        Sort-Object -Property Key |
        ForEach-Object { "$($_.Key): $($_.Value)" }
    )
    $JSONObject.'##' = @($baseComments + $metadataLines)
    return $JSONObject
}

Function Get-ManifestUrlDomains {
    param([PsCustomObject]$Object)

    $urls = @()
    if ($Object.PSObject.Properties['url']) { $urls += $Object.url }
    if ($Object.PSObject.Properties['architecture']) {
        foreach ($arch in $Object.architecture.PSObject.Properties) {
            if ($arch.Value.PSObject.Properties['url']) { $urls += $arch.Value.url }
        }
    }

    $domains = @()
    foreach ($url in $urls) {
        try {
            $uri = [Uri]::new($url)
            if ($uri.Host) { $domains += $uri.Host.ToLower() }
        }
        catch {
            continue
        }
    }
    return $domains | Sort-Object -Unique
}

Function Test-UrlDomainChange {
    param([PsCustomObject]$LocalJson, [PsCustomObject]$RemoteJson)

    $localUrls = @()
    $remoteUrls = @()
    if ($LocalJson.PSObject.Properties['url']) { $localUrls += $LocalJson.url }
    if ($RemoteJson.PSObject.Properties['url']) { $remoteUrls += $RemoteJson.url }
    if ($LocalJson.PSObject.Properties['homepage']) { $localUrls += $LocalJson.homepage }
    if ($RemoteJson.PSObject.Properties['homepage']) { $remoteUrls += $RemoteJson.homepage }

    $localDomains = $localUrls | ForEach-Object { try { ([uri]$_).Host } catch { $null } } | Where-Object { $_ }
    $remoteDomains = $remoteUrls | ForEach-Object { try { ([uri]$_).Host } catch { $null } } | Where-Object { $_ }

    # Check for domain changes
    $domainDiff = Compare-Object -ReferenceObject $localDomains -DifferenceObject $remoteDomains
    if ($null -ne $domainDiff) { return $true }

    # Special handling for github.com: check first two path segments (account/repo)
    $githubUrlsLocal = $localUrls | Where-Object { $_ -match 'github' }
    $githubUrlsRemote = $remoteUrls | Where-Object { $_ -match 'github' }
    if ($githubUrlsLocal -and $githubUrlsRemote) {
        $getRepoId = {
            param($url)
            try {
                $uri = [uri]$url
                $segments = $uri.AbsolutePath.Trim('/').Split('/')
                if ($segments.Length -ge 2) {
                    return ($segments[0] + '/' + $segments[1])
                }
            }
            catch { }
            return $null
        }
        $localRepos = $githubUrlsLocal | ForEach-Object { & $getRepoId $_ } | Where-Object { $_ }
        $remoteRepos = $githubUrlsRemote | ForEach-Object { & $getRepoId $_ } | Where-Object { $_ }
        $repoDiff = Compare-Object -ReferenceObject $localRepos -DifferenceObject $remoteRepos
        if ($null -ne $repoDiff) { return $true }
    }

    return $false
}

Function Test-LicenseChange {
    param([PsCustomObject]$LocalJson, [PsCustomObject]$RemoteJson)

    $localLicense = $null
    $remoteLicense = $null
    if ($LocalJson.PSObject.Properties['license']) { $localLicense = $LocalJson.license }
    if ($RemoteJson.PSObject.Properties['license']) { $remoteLicense = $RemoteJson.license }

    if ($null -eq $localLicense -And $null -eq $remoteLicense) { return $false }
    if ($null -eq $localLicense -Or $null -eq $remoteLicense) { return $true }

    $localSig = $localLicense | ConvertTo-Json -Depth 10 -Compress
    $remoteSig = $remoteLicense | ConvertTo-Json -Depth 10 -Compress
    return $localSig -ne $remoteSig
}

Function Test-DeepManifestChange {
    param([PsCustomObject]$LocalJson, [PsCustomObject]$RemoteJson)

    $localCopy = $LocalJson | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $remoteCopy = $RemoteJson | ConvertTo-Json -Depth 20 | ConvertFrom-Json

    if ($localCopy.PSObject.Properties['##']) { $localCopy.PSObject.Properties.Remove('##') }
    if ($remoteCopy.PSObject.Properties['##']) { $remoteCopy.PSObject.Properties.Remove('##') }

    $localString = $localCopy | ConvertTo-Json -Depth 20 -Compress
    $remoteString = $remoteCopy | ConvertTo-Json -Depth 20 -Compress
    return $localString -ne $remoteString
}

# Version comparison test using [version] type casting to check for ordering. Relies on versions being castable to [version].
Function Test-IsNewerVersion { param ($RemoteVersion, $LocalVersion); try { return [version]$RemoteVersion -ge [version]$LocalVersion } catch { return $true } }

# Compares two manifest objects for significant differences, ignoring version, URL, hash, and extract_dir fields.
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
            Write-Highlight "    -> Complex change detected: URL project changed from '$localBase' to '$remoteBase'"
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
    Write-Log "    --- Diff ---"
    foreach ($change in $diff) {
        if ($change.SideIndicator -eq '<=') { Write-Log ("- " + $change.InputObject) "Red" }
        elseif ($change.SideIndicator -eq '=>') { Write-Log ("+ " + $change.InputObject) "Green" }
    }
    Write-Log "    --- End Diff ---`n"
}

# Writes the in-memory data structure to the given file path.
Function Write-Manifest {
    param([PsCustomObject]$MetadataToWrite, [String]$FilePath)
    Write-Trace "Writing updated metadata to manifest at '$FilePath'"
    $MetadataToWrite | ConvertTo-Json -Depth 10 | Set-Content -Path $FilePath -Encoding UTF8
}

# =================================================================================================
# Main Script Logic
# =================================================================================================

$runTimestamp = Get-FormattedDate
$manifests = Get-ChildItem -Path $BucketPath -Filter *.json
$allManifestData = @()

$effectiveDeepComparison = $DeepComparison -or $FullUpdate
$effectiveAutoComplex = $AutoComplex -or $FullUpdate
$effectiveDefaultDelayDays = $DefaultDelayDays
$effectiveDefaultMinimumDays = $DefaultMinimumDays
if ($FullUpdate) {
    $effectiveDefaultDelayDays = 0
    $effectiveDefaultMinimumDays = 0
}

$effectivePullSources = $PullSources -or $FullUpdate
if ($effectivePullSources) {
    $localReposPath = Join-Path -Path $scriptDir -ChildPath 'local-repos.cfg'
    Invoke-PullSourceRepos -ConfigPath $localReposPath -VerboseOutput:$VerboseProcessing
}

# This iterates through all the manifests and gathers their metadata and pending status.
Write-Log "🔍 Gathering manifest data from '$BucketPath'..."
foreach ($localManifestFile in $manifests) {
    # Scope filter
    if ($localManifestFile.BaseName -Notmatch $Scope) {
        if ($VerboseProcessing -And -Not $HideSkipped) {
            Write-Log "  -> Skipping '$($localManifestFile.Name)' (does not match scope pattern '$Scope')"
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
            Write-Trace "    -> Checking source date for '$($localManifestFile.Name)' at source path '$sourcePath'"
            $sourceInfo = Get-GitCommitDate -FilePath $sourcePath -StoredHash $storedHash -StoredDate $lastUpdateStr
            $fileUpdateStr = $sourceInfo.Date
            $data.CurrentHash = $sourceInfo.Hash

            # If hash is missing, normalize it now to save future time
            if ([string]::IsNullOrEmpty($storedHash)) {
                Write-LogVerbose "  -> Uninitialized hash for '$($localManifestFile.Name)'. Performing one-off sync..."
                $newMetadata = $data.Metadata.Clone()
                $newMetadata.sourceLastUpdated = $fileUpdateStr
                $newMetadata.sourceHash = $data.CurrentHash
                $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
                Write-Manifest -MetadataToWrite $updatedJson -FilePath $localManifestFile.FullName
                $data.Metadata = $newMetadata # Keep object current in memory
            }

            if ($sourceInfo.Match) {
                if ($VerboseProcessing) {
                    Write-Log "  -> Source check for '$($localManifestFile.Name)' shows no update needed (blob hash is unchanged)"
                }
            }
            elseif ($fileUpdateStr -gt $lastUpdateStr) {
                $data.IsPending = $true
                $data.PendingReason = "upstream source updated to $fileUpdateStr after last recorded update on $lastUpdateStr"
                if ($VerboseProcessing) {
                    Write-Highlight "  -> Marking '$($localManifestFile.Name)' as pending because the upstream source was updated to $fileUpdateStr which is after the last recorded update on $lastUpdateStr"
                }
            }
            else {
                if ($VerboseProcessing) {
                    Write-Log "  -> Source date check for '$($localManifestFile.Name)' shows no update needed (source date $fileUpdateStr is not after last recorded update on $lastUpdateStr)"
                }
            }
        }
        catch {
            Write-LogVerbose "  -> Warning: Failed to check source date for '$($localManifestFile.Name)'. Error: $($_.Exception.Message)"
        }
    }
    else {
        Write-LogVerbose "  -> Skipping source date check for '$($localManifestFile.Name)' (source path is missing or non-standard or it's a manual or deprecated source)."
    }

    $allManifestData += $data
}

$updateableManifests = $allManifestData | Where-Object { $_.Metadata.sourceState -ne 'dead' -And $_.Metadata.sourceState -ne 'manual' }

# --- Mode: List Manual ---
if ($ListManual) {
    Write-Host
    Write-Log "📜 Listing manifests marked as MANUAL..." Cyan
    $manualFiles = $allManifestData | Where-Object { $_.Metadata.sourceState -eq 'manual' -Or $_.Metadata.source -eq 'MANUAL' }
    if ($manualFiles) {
        $manualFiles | ForEach-Object { Write-Log "  - $($_.File.Name)" }
    }
    else {
        Write-Log "  ✅ No manifests are marked as MANUAL"
    }
    return
}

# --- Mode: List Locks ---
if ($ListLocks) {
    Write-Host
    Write-Log "📜 Listing manifests marked as locks (frozen or domain-change-lock)..." Cyan
    $lockFiles = $allManifestData | Where-Object { $_.Metadata.sourceState -in @('frozen', 'domain-change-lock', 'license-change-lock') }
    if ($lockFiles) {
        $lockFiles | ForEach-Object { Write-Log "  - $($_.File.Name) [$($_.Metadata.sourceState)]" }
    }
    else {
        Write-Log "  ✅ No manifests are marked as locks"
    }
    return
}

# --- Mode: List Pending ---
if ($ListPending) {
    Write-Host
    Write-Log "📜 Listing manifests with pending changes..." Cyan
    $pendingCount = 0
    foreach ($data in $updateableManifests) {
        if ($data.IsPending) {
            $pendingCount++
            Write-Highlight "  - $($data.File.Name) ($($data.PendingReason))"
        }
        elseif ($VerboseList) {
            $updateDate = $data.Metadata.sourceLastUpdated
            Write-Log "  - $($data.File.Name) (authentic source date is $updateDate, skipping)"
        }
    }
    if ($pendingCount -eq 0) { Write-Log "  ✅ No non-manual manifests have pending changes" }
    return
}

# --- Mode: Process Locks ---
if ($ProcessLocks) {
    Write-Host
    Write-Log "🔒 Starting locked manifest processing..." Cyan

    $lockedStates = @('frozen', 'domain-change-lock', 'license-change-lock')
    $lockedManifests = $allManifestData | Where-Object { $_.Metadata.sourceState -in $lockedStates }
    if ($ExcludeFrozen) {
        $lockedManifests = $lockedManifests | Where-Object { $_.Metadata.sourceState -ne 'frozen' }
    }

    if (-Not $lockedManifests -or $lockedManifests.Count -eq 0) {
        Write-Log "  ✅ No locked manifests found to process"
        return
    }

    foreach ($data in $lockedManifests) {
        $sourceUrl = $data.Metadata.sourceUrl
        if (([string]::IsNullOrWhiteSpace($sourceUrl)) -Or ($sourceUrl -Notlike 'http*')) {
            Write-Log "  -> Skipping '$($data.File.Name)' (no valid source URL)" DarkYellow
            continue
        }

        Write-Host
        Write-Log "- Checking locked manifest '$($data.File.Name)' [$($data.Metadata.sourceState)]..."
        $remoteJson = $null
        try { $remoteJson = Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing | ConvertFrom-Json } catch {
            Write-LogWarning "  ⚠️ Failed to download source for '$($data.File.Name)': $($_.Exception.Message)"
            continue
        }

        $deepChanged = $false
        if ($effectiveDeepComparison) {
            $deepChanged = Test-DeepManifestChange -LocalJson $data.Local -RemoteJson $remoteJson
        }

        $hasUpdate = $deepChanged -or ($data.Local.version -ne $remoteJson.version)
        if (-Not $hasUpdate -And -Not $data.IsPending) {
            Write-Log "  ✅ No update found for '$($data.File.Name)'; keeping lock state" DarkYellow
            continue
        }

        Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        $choice = Read-Host "-> 🔒 This package is locked ($($data.Metadata.sourceState)). Process and unlock? (A)ccept / (S)kip / (Q)uit"
        switch ($choice.ToLower()) {
            'a' {
                $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
                $newMetadata = $data.Metadata.Clone()
                $newMetadata.sourceState = 'active'
                $newMetadata.sourceLastUpdated = $sourceInfo.Date
                $newMetadata.sourceHash = $sourceInfo.Hash
                $newMetadata.sourceLastChangeFound = $runTimestamp
                if ($newMetadata.ContainsKey('sourceDeferredUpdateFound')) {
                    $newMetadata.Remove('sourceDeferredUpdateFound')
                }
                $updatedJson = Set-CustomMetadata -JSONObject $remoteJson -MetadataToWrite $newMetadata
                Write-Log "    -> Writing updated state to manifest..."
                Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
                Write-Log "  ✅ Accepted and unlocked '$($data.File.Name)'" Green
            }
            'q' {
                Write-Log "🛑 Aborting lock processing session"
                return
            }
            default {
                Write-LogWarning "  ⏩ Skipped '$($data.File.Name)'; keeping lock state"
            }
        }
    }

    Write-Host
    Write-Log "✨ Locked manifest processing complete"
    return
}

# --- Mode: Interactive ---
if ($Interactive) {
    Write-Host
    Write-Log "👋 Starting interactive update session..." Cyan
    $updateCandidates = 0
    foreach ($data in $updateableManifests) {
        $sourceUrl = $data.Metadata.sourceUrl
        if (([string]::IsNullOrWhiteSpace($sourceUrl)) -Or ($sourceUrl -Notlike 'http*')) { continue }
        Write-Host
        Write-Log "- Checking '$($data.File.Name)'..."
        $remoteJson = $null
        try { $remoteJson = Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing | ConvertFrom-Json } catch { continue }

        $deepChanged = $false
        if ($effectiveDeepComparison) {
            $deepChanged = Test-DeepManifestChange -LocalJson $data.Local -RemoteJson $remoteJson
        }

        if (-Not $deepChanged -And $data.Local.version -eq $remoteJson.version -And -Not $data.IsPending) { continue }
        if (-Not $deepChanged -And $data.Local.version -ne $remoteJson.version -And -Not (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)) { continue }

        $updateCandidates++
        Write-Highlight "--- Reviewing '$($data.File.Name)' ---"

        $proceedToStandardPrompt = $false
        if ($data.Metadata.sourceState -eq 'domain-change-lock') {
            Write-Log "  -> 🔒 Skipping package due to domain-change-lock" Cyan
            continue
        }
        if ($data.Metadata.sourceState -eq 'license-change-lock') {
            Write-Log "  -> 🔒 Skipping package due to license-change-lock" Cyan
            continue
        }
        if ($data.Metadata.sourceState -eq 'frozen') {
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
            $frozenChoice = Read-Host "-> ❄️ This package is FROZEN. Skip this update? (Y)es / (N)o"
            if ($frozenChoice.ToLower() -eq 'n') {
                $proceedToStandardPrompt = $true
            }
            else {
                Write-Log "  -> ❄️ Skipping frozen package as requested" Cyan
                Set-DeferredUpdateFound -Data $data -RunTimestamp $runTimestamp | Out-Null
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

            if (Test-LicenseChange -LocalJson $data.Local -RemoteJson $remoteJson) {
                Write-Concern "    🔒 License change detected. Locking package for manual review (license-change-lock)."
                $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
                $newMetadata = $data.Metadata.Clone()
                $newMetadata.sourceState = 'license-change-lock'
                $newMetadata.sourceLastUpdated = $sourceInfo.Date
                $newMetadata.sourceHash = $sourceInfo.Hash
                $newMetadata.sourceLastChangeFound = $runTimestamp
                $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
                Write-Log "    -> Writing updated state to manifest..."
                Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
                continue
            }

            if (Test-UrlDomainChange -LocalJson $data.Local -RemoteJson $remoteJson) {
                Write-Concern "    🔒 URL domain change detected. Locking package for manual review (domain-change-lock)."
                $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
                $newMetadata = $data.Metadata.Clone()
                $newMetadata.sourceState = 'domain-change-lock'
                $newMetadata.sourceLastUpdated = $sourceInfo.Date
                $newMetadata.sourceHash = $sourceInfo.Hash
                $newMetadata.sourceLastChangeFound = $runTimestamp
                $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
                Write-Log "    -> Writing updated state to manifest..."
                Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
                continue
            }

            $delayDays = $effectiveDefaultDelayDays
            if (-Not $FullUpdate -And $data.Metadata.sourceDelayDays -match '^\d+$') { $delayDays = [int]$data.Metadata.sourceDelayDays }
            if ($delayDays -gt 0) {
                try {
                    $updateDate = [datetime]::ParseExact($data.Metadata.sourceLastUpdated, $timestampFormat, $null)
                    $updateAge = (Get-Now) - $updateDate
                    if ($updateAge.TotalDays -lt $delayDays) {
                        Write-LogWarning "This source update is only $($updateAge.TotalDays.ToString('F0')) days old, which is within the $($delayDays)-day delay period"
                    }
                }
                catch {
                    Write-LogWarning "Manifest $($data.File.Name) has no recorded last update date or other problem reading; cannot enforce delay days"
                }
            }
            $minDays = $effectiveDefaultMinimumDays
            if (-Not $FullUpdate -And $data.Metadata.sourceUpdateMinimumDays -match '^\d+$') { $minDays = [int]$data.Metadata.sourceUpdateMinimumDays }
            if ($minDays -gt 0) {
                try {
                    $changeDate = [datetime]::ParseExact($data.Metadata.sourceLastChangeFound, $timestampFormat, $null)
                    $lastChangeAge = (Get-Now) - $changeDate
                    if ($lastChangeAge.TotalDays -lt $minDays) {
                        Write-LogWarning "This manifest was last updated only $($lastChangeAge.TotalDays.ToString('F0')) day(s) ago (minimum is $($minDays))"
                    }
                }
                catch {
                    Write-LogWarning "Manifest $($data.File.Name) has no recorded last change date or other problem reading; cannot enforce minimum update days"
                }
            }

            $choice = Get-ChangeDecision
            if (-Not (Invoke-ChangeDecision -Choice $choice -Data $data -RemoteJson $remoteJson -RunTimestamp $runTimestamp -RecordDeferredOnSkipOrFreeze)) {
                return
            }
        }
    }
    if ($updateCandidates -eq 0) {
        Write-Host
        Write-Log "  ✅ No manifests have pending changes to review"
    }
    Write-Host
    Write-Log "✨ Interactive session complete"
    return
}

# --- Mode: Default Automatic Update ---
Write-Host
Write-Log "🔄 Checking for updates in '$BucketPath'..."
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
            Write-Log "  - Checking '$($data.File.Name)'..."
            Write-LogWarning "    ⚠️ Failed to download source. Error: $($_.Exception.Message)"
        }
        continue
    }

    $deepChanged = $false
    if ($effectiveDeepComparison) {
        $deepChanged = Test-DeepManifestChange -LocalJson $data.Local -RemoteJson $remoteJson
    }

    $hasUpdate = $deepChanged -or (($data.Local.version -ne $remoteJson.version) -And (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version))
    $sourceFileChanged = ($authenticSourceDate -gt $data.Metadata.sourceLastUpdated)

    # If no version jump AND the source file is exactly where we last left it, skip the manifest.
    if (-Not $hasUpdate -And -Not $sourceFileChanged) {
        if (-Not $ChangesOnly) {
            Write-Host
            Write-Log "  - Checking '$($data.File.Name)'..."
            Write-Log "    👍 Already up to date (version $($data.Local.version))"
        }
        continue
    }

    Write-Host
    Write-Log "  - Checking '$($data.File.Name)'..."

    if (-Not $hasUpdate -And $sourceFileChanged) {
        Write-Log "    👍 Already up to date (version $($data.Local.version))"
        $newMetadata = $data.Metadata.Clone();
        $newMetadata.sourceLastUpdated = $authenticSourceDate
        $newMetadata.sourceHash = $currentHash
        $newMetadata.sourceLastChangeFound = $runTimestamp
        Write-Log "      -> Syncing timestamps: authentic date is $authenticSourceDate"
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
        Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
        continue
    }

    if (-Not $deepChanged -And $data.Local.version -ne $remoteJson.version -And -Not (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)) {
        Write-Concern "    Halted; remote version ($($remoteJson.version)) is older than local version ($($data.Local.version))"
        continue
    }

    Write-Log "    - Local version: $($data.Local.version), Remote version: $($remoteJson.version); update available"

    if ($data.Metadata.sourceState -in @('frozen', 'domain-change-lock', 'license-change-lock')) {
        $stateLabel = $data.Metadata.sourceState
        Write-Log "    -> ❄️ Update found for locked package (${stateLabel}); no action will be taken" Cyan
        if (-Not $SkipFrozen) {
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        }
        continue
    }

    $deferredDate = Get-DeferredUpdateDate -Metadata $data.Metadata

    $minDays = $effectiveDefaultMinimumDays
    if (-Not $FullUpdate -And $data.Metadata.sourceUpdateMinimumDays -match '^\d+$') { $minDays = [int]$data.Metadata.sourceUpdateMinimumDays }
    if ($minDays -gt 0) {
        try {
            $changeDate = [datetime]::ParseExact($data.Metadata.sourceLastChangeFound, $timestampFormat, $null)
            $lastChangeAge = (Get-Now) - $changeDate
            if ($lastChangeAge.TotalDays -lt $minDays) {
                Write-Concern "    -> 🕰️  Update found, but logging only; manifest was updated $($lastChangeAge.TotalDays.ToString('F0')) day(s) ago (minimum is $($minDays))"
                Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
                continue
            }
        }
        catch {}
    }

    $delayDays = $effectiveDefaultDelayDays
    if (-Not $FullUpdate -And $data.Metadata.sourceDelayDays -match '^\d+$') { $delayDays = [int]$data.Metadata.sourceDelayDays }
    if ($delayDays -gt 0) {
        try {
            $updateDate = [datetime]::ParseExact($data.Metadata.sourceLastUpdated, $timestampFormat, $null)
            $updateAge = (Get-Now) - $updateDate
            if ($updateAge.TotalDays -lt $delayDays) {
                $deferredAge = $null
                if ($deferredDate) { $deferredAge = (Get-Now) - $deferredDate }
                if ($deferredAge -And $deferredAge.TotalDays -ge $delayDays) {
                    Write-LogVerbose "    -> Deferred update exceeds delay window; proceeding with update."
                }
                else {
                    Write-Concern "    -> 🕰️  Update found, but source change is too recent to apply (within $($delayDays)-day delay period); skipping..."
                    Set-DeferredUpdateFound -Data $data -RunTimestamp $runTimestamp | Out-Null
                    continue
                }
            }
        }
        catch {}
    }

    if (Test-LicenseChange -LocalJson $data.Local -RemoteJson $remoteJson) {
        Write-Concern "    🔒 License change detected. Locking package for manual review (license-change-lock)"
        $newMetadata = $data.Metadata.Clone()
        $newMetadata.sourceState = 'license-change-lock'
        $newMetadata.sourceLastUpdated = $authenticSourceDate
        $newMetadata.sourceHash = $currentHash
        $newMetadata.sourceLastChangeFound = $runTimestamp
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
        Write-Log "      -> Writing updated state to manifest..."
        Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
        continue
    }

    if (Test-UrlDomainChange -LocalJson $data.Local -RemoteJson $remoteJson) {
        Write-Concern "    🔒 URL domain change detected. Locking package for manual review (domain-change-lock)"
        $newMetadata = $data.Metadata.Clone()
        $newMetadata.sourceState = 'domain-change-lock'
        $newMetadata.sourceLastUpdated = $authenticSourceDate
        $newMetadata.sourceHash = $currentHash
        $newMetadata.sourceLastChangeFound = $runTimestamp
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
        Write-Log "      -> Writing updated state to manifest..."
        Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
        continue
    }

    if (Compare-ManifestObjects -ReferenceObject $data.Local -DifferenceObject $remoteJson) {
        Write-Log "    ✅ Simple version change detected in $($data.File.Name); auto-updating..."
        $data.Local.version = $remoteJson.version
        # These fields may or may not exist; update or remove as needed
        if ($remoteJson.PSObject.Properties['url']) { $data.Local.url = $remoteJson.url } elseif ($data.Local.PSObject.Properties['url']) { $data.Local.PSObject.Properties.Remove('url') }
        if ($remoteJson.PSObject.Properties['hash']) { $data.Local.hash = $remoteJson.hash } elseif ($data.Local.PSObject.Properties['hash']) { $data.Local.PSObject.Properties.Remove('hash') }
        if ($remoteJson.PSObject.Properties['extract_dir']) { $data.Local.extract_dir = $remoteJson.extract_dir } elseif ($data.Local.PSObject.Properties['extract_dir']) { $data.Local.PSObject.Properties.Remove('extract_dir') }
        if ($remoteJson.PSObject.Properties['architecture']) { $data.Local.architecture = $remoteJson.architecture } elseif ($data.Local.PSObject.Properties['architecture']) { $data.Local.PSObject.Properties.Remove('architecture') }
        if ($remoteJson.PSObject.Properties['autoupdate']) { $data.Local.autoupdate = $remoteJson.autoupdate } elseif ($data.Local.PSObject.Properties['autoupdate']) { $data.Local.PSObject.Properties.Remove('autoupdate') }

        $newMetadata = $data.Metadata.Clone();
        $newMetadata.sourceLastUpdated = $authenticSourceDate
        $newMetadata.sourceHash = $currentHash
        $newMetadata.sourceLastChangeFound = $runTimestamp
        if ($newMetadata.ContainsKey('sourceDeferredUpdateFound')) {
            $newMetadata.Remove('sourceDeferredUpdateFound')
        }
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata

        Write-Log "      -> Writing updated version and timestamps to '$($data.File.Name)'"
        Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
    }
    else {

        if ($InteractiveComplex) {
            Write-Concern "    ⚠️ Manifest $($data.File.Name) has complex changes; interactive review enabled"
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
            $choice = Get-ChangeDecision
            $sourceInfo = [pscustomobject]@{ Date = $authenticSourceDate; Hash = $currentHash }
            if (-Not (Invoke-ChangeDecision -Choice $choice -Data $data -RemoteJson $remoteJson -RunTimestamp $runTimestamp -SourceInfo $sourceInfo)) {
                return
            }
        }
        elseif ($effectiveAutoComplex) {
            Write-Concern "    ⚠️ Manifest $($data.File.Name) has complex changes. AutoComplex enabled; applying changes"
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
            $newMetadata = $data.Metadata.Clone()
            $newMetadata.sourceLastUpdated = $authenticSourceDate
            $newMetadata.sourceHash = $currentHash
            $newMetadata.sourceLastChangeFound = $runTimestamp
            if ($newMetadata.ContainsKey('sourceDeferredUpdateFound')) {
                $newMetadata.Remove('sourceDeferredUpdateFound')
            }
            $newJson = Set-CustomMetadata -JSONObject $remoteJson -MetadataToWrite $newMetadata
            Write-Log "      -> Writing complex changes to '$($data.File.Name)'"
            Write-Manifest -MetadataToWrite $newJson -FilePath $data.File.FullName
        }
        else {
            Write-Concern "    ⚠️ Manifest $($data.File.Name) has complex changes; manual review required"
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        }
    }
}
Write-Host
Write-Log "✨ Update check complete"
