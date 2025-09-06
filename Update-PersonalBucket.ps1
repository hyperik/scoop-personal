<#
.SYNOPSIS
  Checks for updates for Scoop manifests based on their remote 'sourceUrl'.

.DESCRIPTION
  This script iterates through manifests in a personal Scoop bucket. If a manifest has a valid 'sourceUrl' key, it fetches the original manifest from that URL.
  If only the version and hash have changed, it automatically updates the local manifest.
  Otherwise, it issues a warning for manual review.

.PARAMETER PersonalBucketPath
  The full path to the 'bucket' directory of your personal Scoop repository.
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$PersonalBucketPath = "D:\dev\src\hyperik\scoop-personal\bucket"
)

# MODIFIED: Added sourceUrl to the list of ignorable properties
function Compare-ManifestObjects {
    param([PsCustomObject]$ReferenceObject, [PsCustomObject]$DifferenceObject)
    $ignorableProperties = @('version', 'hash', 'url', 'source', 'sourceUrl')
    $refCopy = $ReferenceObject | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $diffCopy = $DifferenceObject | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    foreach ($prop in ($refCopy.PSObject.Properties.Name)) { if ($prop -in $ignorableProperties) { $refCopy.PSObject.Properties.Remove($prop) } }
    foreach ($prop in ($diffCopy.PSObject.Properties.Name)) { if ($prop -in $ignorableProperties) { $diffCopy.PSObject.Properties.Remove($prop) } }
    $refString = $refCopy | ConvertTo-Json -Depth 10 -Compress
    $diffString = $diffCopy | ConvertTo-Json -Depth 10 -Compress
    return $refString -eq $diffString
}

Write-Host "🔄 Checking for updates in '$PersonalBucketPath'..."
$manifests = Get-ChildItem -Path $PersonalBucketPath -Filter *.json -Recurse

foreach ($localManifestFile in $manifests) {
    $localJson = Get-Content -Path $localManifestFile.FullName -Raw | ConvertFrom-Json
    
    # MODIFIED: Prioritize 'sourceUrl' for checking updates
    if ((-not $localJson.PSObject.Properties['sourceUrl']) -or ([string]::IsNullOrWhiteSpace($localJson.sourceUrl)) -or ($localJson.sourceUrl -notlike 'http*')) {
        continue
    }

    $sourceUrl = $localJson.sourceUrl
    Write-Host "`n  - Checking '$($localManifestFile.Name)' from $sourceUrl"

    try {
        # MODIFIED: Reverted to using Invoke-WebRequest with the URL
        $remoteContent = Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing -ErrorAction Stop
        $remoteJson = $remoteContent.Content | ConvertFrom-Json
    }
    catch {
        Write-Warning "    ⚠️ Failed to download source for '$($localManifestFile.Name)'. Error: $($_.Exception.Message)"
        continue
    }
    
    if ($localJson.version -eq $remoteJson.version) {
        Write-Host "    👍 Already up to date (version $($localJson.version))."
        continue
    }

    Write-Host "    - Local version: $($localJson.version), Remote version: $($remoteJson.version)."

    if (Compare-ManifestObjects -ReferenceObject $localJson -DifferenceObject $remoteJson) {
        Write-Host "    ✅ Simple version change detected. Auto-updating..."
        $localJson.version = $remoteJson.version
        $localJson.hash = $remoteJson.hash
        if ($remoteJson.PSObject.Properties['url']) {
            $localJson.url = $remoteJson.url
        }
        $localJson | ConvertTo-Json -Depth 5 | Set-Content -Path $localManifestFile.FullName -Encoding UTF8
        Write-Host "    - '$($localManifestFile.Name)' updated to version $($remoteJson.version)."
    }
    else {
        Write-Warning "    ⚠️ Manifest for '$($localManifestFile.Name)' has changed beyond version and hash. Please review and update manually."
    }
}

Write-Host "`n✨ Update check complete."
