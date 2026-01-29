<#
.SYNOPSIS
  Creates a new manifest in the local bucket by copying from a source Scoop bucket.

.DESCRIPTION
  Looks up the source bucket path using local-repos.cfg and copies the manifest into this repo's bucket.
  Adds the standard "##" metadata comments with updated timestamps, hashes, and source URLs.
  Copies matching scripts from the source repo's top-level scripts directory into the local scripts directory,
  rewriting the target manifest name to the destination manifest name in filenames.

.PARAMETER SourceBucket
  A partial or full identifier for the source bucket path listed in local-repos.cfg.
  Partial matches are accepted only when unambiguous.

.PARAMETER TargetManifestName
  The manifest name in the source bucket (without .json).

.PARAMETER NewManifestName
  Optional destination manifest name (without .json). If omitted, uses TargetManifestName.

.EXAMPLE
  .\Add-Manifest.ps1 -SourceBucket scoop-main -TargetManifestName ffmpeg-shared -NewManifestName ffmpeg-shared-ng

.EXAMPLE
  .\Add-Manifest.ps1 -SourceBucket third-party\scoop-main -TargetManifestName ffmpeg-shared
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceBucket,

    [Parameter(Mandatory = $true)]
    [string]$TargetManifestName,

    [Parameter()]
    [string]$NewManifestName
)

# --- Initial Setup ---
$scriptDir = $PSScriptRoot
$localBucketPath = Join-Path -Path $scriptDir -ChildPath 'bucket'
$localScriptsPath = Join-Path -Path $scriptDir -ChildPath 'scripts'
$localReposPath = Join-Path -Path $scriptDir -ChildPath 'local-repos.cfg'

$timestampFormat = "yyMMdd HH:mm:ss"
$logTimestamp = $true
$MetadataKeys = 'source', 'sourceUrl', 'sourceLastUpdated', 'sourceLastChangeFound', 'sourceState', 'sourceHash'

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
        [string]$Message
    )
    if ($logTimestamp) {
        Write-Warning "$(Get-Date -format o) - $Message"
    }
    else {
        Write-Warning "$Message"
    }
}

Function Get-FormattedDate {
    param([datetime]$DateTime = ([datetime]::UtcNow))
    return $DateTime.ToString($timestampFormat)
}

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

Function Write-Manifest {
    param([PsCustomObject]$MetadataToWrite, [String]$FilePath)
    $MetadataToWrite | ConvertTo-Json -Depth 10 | Set-Content -Path $FilePath -Encoding UTF8
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
        $currentHash = git -C $repoDir rev-parse "HEAD:$repoRelativePath" 2>$null
        if ($currentHash -And $StoredHash -And ($currentHash -eq $StoredHash) -And $StoredDate) {
            return [pscustomobject]@{ Date = $StoredDate; Hash = $currentHash; Match = $true }
        }
        $gitDate = git -C $repoDir --no-pager log -1 --format=%cI -- $FilePath 2>$null
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

Function Get-RepoBranch {
    param([string]$RepoPath)
    if (-Not (Test-Path (Join-Path $RepoPath ".git"))) { return $null }
    $branch = git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null
    if ([string]::IsNullOrWhiteSpace($branch)) { return $null }
    return $branch.Trim()
}

Function Normalize-RepoUrl {
    param([string]$RepoUrl)
    if ([string]::IsNullOrWhiteSpace($RepoUrl)) { return $null }
    $url = $RepoUrl.Trim()

    if ($url -match '^git@') {
        $url = $url -replace '^git@', ''
        $url = $url -replace ':', '/'
        $url = "https://$url"
    }
    elseif ($url -notmatch '^https?://') {
        $url = "https://$url"
    }

    if ($url.EndsWith('.git')) {
        $url = $url.Substring(0, $url.Length - 4)
    }
    return $url
}

Function Build-SourceUrl {
    param(
        [string]$RepoUrl,
        [string]$Branch,
        [string]$RelativePath
    )
    $normalized = Normalize-RepoUrl -RepoUrl $RepoUrl
    if (-Not $normalized) { return $null }

    $uri = [Uri]$normalized
    $host = $uri.Host.ToLower()
    $path = $uri.AbsolutePath.Trim('/').TrimEnd('/')
    $relative = $RelativePath.TrimStart('/').Replace("\", "/")

    if ($host -eq 'github.com') {
        return "https://raw.githubusercontent.com/$path/$Branch/$relative"
    }

    return "$($uri.Scheme)://$host/$path/raw/branch/$Branch/$relative"
}

Function Resolve-SourceRepo {
    param(
        [string]$SourceBucketPattern,
        [string]$ReposConfigPath
    )
    if (-Not (Test-Path $ReposConfigPath)) {
        throw "local-repos.cfg not found at '$ReposConfigPath'."
    }

    $pattern = [Regex]::Escape($SourceBucketPattern.Trim())
    $entries = Get-Content -Path $ReposConfigPath | Where-Object { $_ -match ';' }
    $matches = @()

    foreach ($entry in $entries) {
        $parts = $entry -split ';', 2
        $repoPath = $parts[0].Trim()
        $repoUrl = $parts[1].Trim()
        if ($repoPath -match "(?i)$pattern") {
            $matches += [pscustomobject]@{ Path = $repoPath; Url = $repoUrl }
        }
    }

    if ($matches.Count -eq 0) {
        throw "No local-repos.cfg entries matched '$SourceBucketPattern'."
    }
    if ($matches.Count -gt 1) {
        $matchList = ($matches | ForEach-Object { $_.Path }) -join '; '
        throw "Source bucket match is ambiguous for '$SourceBucketPattern'. Matches: $matchList"
    }

    return $matches[0]
}

Function Replace-First {
    param(
        [string]$Input,
        [string]$Pattern,
        [string]$Replacement
    )
    $regex = [Regex]::new([Regex]::Escape($Pattern), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $regex.Replace($Input, $Replacement, 1)
}

# --- Resolve Inputs ---
$destinationName = if ([string]::IsNullOrWhiteSpace($NewManifestName)) { $TargetManifestName } else { $NewManifestName }

if (-Not (Test-Path $localBucketPath)) {
    throw "Local bucket path not found at '$localBucketPath'."
}

$sourceRepo = Resolve-SourceRepo -SourceBucketPattern $SourceBucket -ReposConfigPath $localReposPath
$sourceRepoPath = $sourceRepo.Path
$sourceRepoUrl = $sourceRepo.Url

if (-Not (Test-Path $sourceRepoPath)) {
    throw "Source repo path not found at '$sourceRepoPath'."
}

$sourceManifestPath = Join-Path -Path $sourceRepoPath -ChildPath (Join-Path -Path 'bucket' -ChildPath "$TargetManifestName.json")
if (-Not (Test-Path $sourceManifestPath)) {
    throw "Source manifest not found at '$sourceManifestPath'."
}

$destinationManifestPath = Join-Path -Path $localBucketPath -ChildPath "$destinationName.json"
if (Test-Path $destinationManifestPath) {
    throw "Destination manifest already exists at '$destinationManifestPath'."
}

$branch = Get-RepoBranch -RepoPath $sourceRepoPath
if ([string]::IsNullOrWhiteSpace($branch)) {
    throw "Unable to determine active branch for repo '$sourceRepoPath'."
}

$sourceRelativePath = "bucket/$TargetManifestName.json"
$sourceUrl = Build-SourceUrl -RepoUrl $sourceRepoUrl -Branch $branch -RelativePath $sourceRelativePath
if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
    throw "Unable to build sourceUrl for repo '$sourceRepoUrl'."
}

$sourceInfo = Get-GitCommitDate -FilePath $sourceManifestPath -StoredHash $null -StoredDate $null
if (-Not $sourceInfo) {
    throw "Unable to retrieve source metadata for '$sourceManifestPath'."
}

$runTimestamp = Get-FormattedDate

# --- Create Manifest ---
$sourceJson = Get-Content -Path $sourceManifestPath -Raw | ConvertFrom-Json
$metadata = @{
    source                = $sourceManifestPath
    sourceLastUpdated     = $sourceInfo.Date
    sourceState           = 'active'
    sourceHash            = $sourceInfo.Hash
    sourceUrl             = $sourceUrl
    sourceLastChangeFound = $runTimestamp
}

$updatedJson = Set-CustomMetadata -JSONObject $sourceJson -MetadataToWrite $metadata
Write-Manifest -MetadataToWrite $updatedJson -FilePath $destinationManifestPath
Write-Log "Created manifest '$destinationManifestPath'" "Green"

# --- Copy Scripts ---
$sourceScriptsPath = Join-Path -Path $sourceRepoPath -ChildPath 'scripts'
if (Test-Path $sourceScriptsPath) {
    $scriptsToCopy = Get-ChildItem -Path $sourceScriptsPath -File | Where-Object { $_.Name -like "*$TargetManifestName*" }
    if ($scriptsToCopy.Count -gt 0) {
        if (-Not (Test-Path $localScriptsPath)) {
            New-Item -Path $localScriptsPath -ItemType Directory | Out-Null
        }

        foreach ($scriptFile in $scriptsToCopy) {
            $destName = Replace-First -Input $scriptFile.Name -Pattern $TargetManifestName -Replacement $destinationName
            $destPath = Join-Path -Path $localScriptsPath -ChildPath $destName
            if (Test-Path $destPath) {
                throw "Destination script already exists at '$destPath'."
            }
            Copy-Item -Path $scriptFile.FullName -Destination $destPath
            Write-Log "Copied script '$($scriptFile.Name)' -> '$destName'" "DarkGreen"
        }
    }
    else {
        Write-Log "No scripts found in '$sourceScriptsPath' matching '$TargetManifestName'."
    }
}
else {
    Write-Log "No scripts directory found at '$sourceScriptsPath'."
}

Write-Log "Done." "Green"
