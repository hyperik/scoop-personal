<#
.SYNOPSIS
  Checks for and applies updates for Scoop manifests, with advanced change tracking and an interactive mode.

.DESCRIPTION
  This script introduces two timestamps: 'sourceLastUpdated' (when changes were last applied) and 'sourceLastChangeFound' (when changes were last detected).
  It can run in three modes:
  1. Default: Auto-applies simple version/hash updates and flags complex changes by updating 'sourceLastChangeFound'.
  2. Interactive: Prompts the user to accept or skip complex changes for manifests where a pending change has been detected.
  3. ListPending: Lists all manifests that have a pending change.

.PARAMETER PersonalBucketPath
  The full path to the 'bucket' directory of your personal Scoop repository.

.PARAMETER ListPending
  Lists all manifests with detected changes that have not yet been applied.

.PARAMETER Interactive
  Starts an interactive session to review and apply pending complex changes one by one.
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$PersonalBucketPath = "D:\dev\src\hyperik\scoop-personal\bucket",

    [Parameter(Mandatory = $false, ParameterSetName = 'List')]
    [switch]$ListPending,

    [Parameter(Mandatory = $false, ParameterSetName = 'Interactive')]
    [switch]$Interactive
)

# =================================================================================
# Helper Functions
# =================================================================================
function Compare-ManifestObjects { param([PsCustomObject]$ReferenceObject, [PsCustomObject]$DifferenceObject); $ignorableProperties = @('version', 'hash', 'url', 'source', 'sourceUrl', 'sourceLastUpdated', 'sourceLastChangeFound'); $refCopy = $ReferenceObject | ConvertTo-Json -Depth 10 | ConvertFrom-Json; $diffCopy = $DifferenceObject | ConvertTo-Json -Depth 10 | ConvertFrom-Json; foreach ($prop in ($refCopy.PSObject.Properties.Name)) { if ($prop -in $ignorableProperties) { $refCopy.PSObject.Properties.Remove($prop) } }; foreach ($prop in ($diffCopy.PSObject.Properties.Name)) { if ($prop -in $ignorableProperties) { $diffCopy.PSObject.Properties.Remove($prop) } }; $refString = $refCopy | ConvertTo-Json -Depth 10 -Compress; $diffString = $diffCopy | ConvertTo-Json -Depth 10 -Compress; return $refString -eq $diffString }
function Show-ManifestDiff { param([PsCustomObject]$LocalJson, [PsCustomObject]$RemoteJson); $localString = $LocalJson | ConvertTo-Json -Depth 10; $remoteString = $RemoteJson | ConvertTo-Json -Depth 10; $diff = Compare-Object -ReferenceObject ($localString -split '\r?\n') -DifferenceObject ($remoteString -split '\r?\n'); if ($null -eq $diff) { return }; Write-Host "`n    --- Diff ---"; foreach ($change in $diff) { if ($change.SideIndicator -eq '<=') { Write-Host ("- " + $change.InputObject) -ForegroundColor Red } elseif ($change.SideIndicator -eq '=>') { Write-Host ("+ " + $change.InputObject) -ForegroundColor Green } }; Write-Host "    --- End Diff ---`n" }

# =================================================================================
# Main Script Logic
# =================================================================================

# MODIFIED: Generate one single GMT/UTC timestamp with second-precision for the entire run.
$runTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$manifests = Get-ChildItem -Path $PersonalBucketPath -Filter *.json
$allManifestData = @()

# --- Pre-flight data gathering ---
Write-Host "🔍 Gathering manifest data..."
foreach ($localManifestFile in $manifests) {
    $localJson = Get-Content -Path $localManifestFile.FullName -Raw | ConvertFrom-Json
    $data = [pscustomobject]@{ File = $localManifestFile; Local = $localJson; IsPending = $false }
    # MODIFIED: Logic to detect pending changes, handles empty strings.
    $lastChange = $data.Local.sourceLastChangeFound
    $lastUpdate = $data.Local.sourceLastUpdated
    if ((-not [string]::IsNullOrEmpty($lastChange)) -and $lastChange -gt $lastUpdate) {
        $data.IsPending = $true
    }
    $allManifestData += $data
}

# --- Mode: List Pending ---
if ($ListPending) {
    Write-Host "`n📜 Listing manifests with pending changes..." -ForegroundColor Cyan
    $pendingFiles = $allManifestData | Where-Object { $_.IsPending }
    if ($pendingFiles) { $pendingFiles | ForEach-Object { Write-Host "  - $($_.File.Name)" } } else { Write-Host "  ✅ No manifests have pending changes." }
    return
}

# --- Mode: Interactive ---
if ($Interactive) {
    Write-Host "`n👋 Starting interactive update session for pending changes..." -ForegroundColor Cyan
    $pendingFiles = $allManifestData | Where-Object { $_.IsPending }
    if (-not $pendingFiles) { Write-Host "  ✅ No manifests have pending changes to review."; return }

    foreach ($data in $pendingFiles) {
        Write-Host "`n--- Reviewing '$($data.File.Name)' ---" -ForegroundColor Yellow
        try { $remoteJson = Invoke-WebRequest -Uri $data.Local.sourceUrl -UseBasicParsing | ConvertFrom-Json } catch { Write-Warning "Could not fetch remote for '$($data.File.Name)'. Skipping."; continue }
        Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        $choice = Read-Host "Apply this change? (A)ccept / (S)kip / (Q)uit"
        switch ($choice.ToLower()) {
            'a' {
                $originalSourcePath = $data.Local.source
                $newJson = $remoteJson
                $newJson | Add-Member -MemberType NoteProperty -Name 'source' -Value $originalSourcePath -Force
                $newJson | Add-Member -MemberType NoteProperty -Name 'sourceLastUpdated' -Value $runTimestamp -Force
                $newJson | Add-Member -MemberType NoteProperty -Name 'sourceLastChangeFound' -Value $runTimestamp -Force
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
foreach ($data in $allManifestData) {
    if ((-not $data.Local.PSObject.Properties['sourceUrl']) -or ([string]::IsNullOrWhiteSpace($data.Local.sourceUrl)) -or ($data.Local.sourceUrl -notlike 'http*')) { continue }
    Write-Host "`n  - Checking '$($data.File.Name)'..."
    try { $remoteJson = Invoke-WebRequest -Uri $data.Local.sourceUrl -UseBasicParsing | ConvertFrom-Json } catch { Write-Warning "    ⚠️ Failed to download source. Error: $($_.Exception.Message)"; continue }
    if ($data.Local.version -eq $remoteJson.version) { Write-Host "    👍 Already up to date."; continue }
    Write-Host "    - Local version: $($data.Local.version), Remote version: $($remoteJson.version)."

    if (Compare-ManifestObjects -ReferenceObject $data.Local -DifferenceObject $remoteJson) {
        Write-Host "    ✅ Simple version change detected. Auto-updating..."
        $data.Local.version = $remoteJson.version; $data.Local.hash = $remoteJson.hash
        if ($remoteJson.PSObject.Properties['url']) { $data.Local.url = $remoteJson.url }
        $data.Local | Add-Member -MemberType NoteProperty -Name 'sourceLastUpdated' -Value $runTimestamp -Force
        $data.Local | Add-Member -MemberType NoteProperty -Name 'sourceLastChangeFound' -Value $runTimestamp -Force
        $data.Local | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
    } else {
        Write-Warning "    ⚠️ Manifest has complex changes. Flagging for manual review."
        Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        $data.Local | Add-Member -MemberType NoteProperty -Name 'sourceLastChangeFound' -Value $runTimestamp -Force
        $data.Local | ConvertTo-Json -Depth 10 | Set-Content -Path $data.File.FullName -Encoding UTF8
    }
}
Write-Host "`n✨ Update check complete."