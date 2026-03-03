<#
download_oasis_scans.ps1

Native PowerShell downloader for OASIS scans on NITRC-IR (XNAT).
- Reads experiment IDs from a CSV (expects a column named "experiment_id" OR common variants like "MR ID")
- Authenticates once and reuses the session cookies
- Downloads scans (e.g., T1w) as ZIP
- Extracts and rearranges into:
    <OutputDir>\<EXPERIMENT_ID>\<anatX>\*.nii.gz / *.json
- Skips already-downloaded sessions
- Fails loudly on obvious auth/permission problems

Usage:
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
  .\download_oasis_scans.ps1 -InputCsv oasis_all_mr_ids.csv -OutputDir oasis_mri_download -Username guerreriok -ScanType T1w

Optional:
  -TauProjectId OASIS3_AV1451   (or OASIS3_AV1451L)
  -ForceHttp1               (forces TLS/HTTP stack to avoid some server quirks)
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputCsv,

  [Parameter(Mandatory = $true)]
  [string]$OutputDir,

  [Parameter(Mandatory = $true)]
  [string]$Username,

  [Parameter(Mandatory = $false)]
  [string]$ScanType = "ALL",

  [Parameter(Mandatory = $false)]
  [ValidateSet("OASIS3_AV1451","OASIS3_AV1451L")]
  [string]$TauProjectId,

  [Parameter(Mandatory = $false)]
  [switch]$ForceHttp1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Get-IdColumnName($rows) {
  $first = $rows | Select-Object -First 1
  if (-not $first) { throw "CSV appears empty (no rows)." }

  $headers = $first.PSObject.Properties.Name
  $candidates = @("experiment_id", "MR ID", "MR_ID", "mr_id", "Experiment ID", "EXPERIMENT_ID")
  foreach ($c in $candidates) {
    if ($headers -contains $c) { return $c }
  }

  throw ("Could not find an ID column. Found headers: " + ($headers -join ", "))
}

function Normalize-ExperimentId([string]$raw) {
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

  # Trim whitespace and surrounding quotes
  $id = $raw.Trim().Trim('"').Trim("'")

  # If something introduced spaces, collapse whitespace to underscores (safe)
  $id = $id -replace '\s+', '_'

  return $id
}

function Guess-ProjectId([string]$experimentId, [string]$tauProjectId) {
  # Default OASIS3
  $projectId = "OASIS3"

  if ($experimentId.StartsWith("OAS4")) {
    $projectId = "OASIS4"
  }

  # Tau projects
  if ($experimentId -match "_AV1451") {
    if ($tauProjectId -eq "OASIS3_AV1451" -or $tauProjectId -eq "OASIS3_AV1451L") {
      $projectId = $tauProjectId
    } else {
      $projectId = "OASIS3_AV1451"
    }
  }

  return $projectId
}

function Invoke-IRRequest {
  param(
    [Parameter(Mandatory=$true)][string]$Uri,
    [Parameter(Mandatory=$true)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
    [Parameter(Mandatory=$false)][string]$OutFile,
    [Parameter(Mandatory=$false)][pscredential]$Credential
  )

  # Some environments behave better if we disable Expect: 100-continue equivalents
  $headers = @{ "Expect" = "" }

  $params = @{
    Uri        = $Uri
    Method     = "GET"
    WebSession = $Session
    Headers    = $headers
  }

  if ($OutFile) { $params["OutFile"] = $OutFile }
  if ($Credential) { $params["Credential"] = $Credential }

  if ($ForceHttp1) {
    # Best-effort: PowerShell doesn't expose a clean per-request HTTP/1.1 switch like curl.
    # Setting this reduces some negotiation edge cases on certain stacks.
    [System.Net.ServicePointManager]::Expect100Continue = $false
  }

  return Invoke-WebRequest @params
}

function LooksLikeAuthFailure([string]$zipPath) {
  if (-not (Test-Path -LiteralPath $zipPath)) { return $true }
  $len = (Get-Item -LiteralPath $zipPath).Length

  # Real scan zips are typically >> 10KB. Auth/permission failures often download tiny HTML.
  if ($len -lt 10KB) { return $true }

  # If it's actually HTML, also treat as auth failure
  try {
    $head = Get-Content -LiteralPath $zipPath -TotalCount 5 -ErrorAction SilentlyContinue
    if ($head -match "<html" -or $head -match "login" -or $head -match "Sign in") { return $true }
  } catch { }

  return $false
}

# --- Start ---
Ensure-Dir $OutputDir

# Prompt for password securely
$securePassword = Read-Host "Enter your NITRC password" -AsSecureString
$credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

# Create session
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

# Authenticate (creates JSESSION)
$jsessionUrl = "https://www.nitrc.org/ir/data/JSESSION"
try {
  Invoke-IRRequest -Uri $jsessionUrl -Session $session -Credential $credential | Out-Null
} catch {
  throw "Login failed (could not obtain JSESSION). Check username/password and NITRC availability. Details: $($_.Exception.Message)"
}

Write-Host "Login successful."

# Load CSV
if (-not (Test-Path -LiteralPath $InputCsv)) {
  throw "Input CSV not found: $InputCsv"
}

$rows = Import-Csv -LiteralPath $InputCsv
if (-not $rows) { throw "CSV contains no data rows: $InputCsv" }

$idColumn = Get-IdColumnName $rows
Write-Host "Using ID column: $idColumn"

# Process each experiment
foreach ($row in $rows) {
  $rawId = $row.$idColumn
  $experimentId = Normalize-ExperimentId $rawId
  if (-not $experimentId) { continue }

  # Validate expected format (MR sessions)
  if ($experimentId -notmatch '^OAS\d+_MR_d\d+$' -and $experimentId -notmatch '^OAS4\d+_MR_d\d+$') {
    Write-Warning "Skipping invalid experiment_id: '$rawId' -> '$experimentId'"
    continue
  }

  $subjectId = $experimentId.Split("_")[0]
  $projectId = Guess-ProjectId -experimentId $experimentId -tauProjectId $TauProjectId

  if ($ScanType -and $ScanType.Trim() -ne "" -and $ScanType -ne "ALL") {
    Write-Host "Checking for $ScanType scan for $experimentId"
  } else {
    $ScanType = "ALL"
    Write-Host "Downloading all scans for $experimentId"
  }

  $expDir = Join-Path $OutputDir $experimentId
  Ensure-Dir $expDir

  # Skip if we've already rearranged into anat*/func*/etc and have at least one nii.gz
  $existingNii = Get-ChildItem -LiteralPath $expDir -Recurse -Filter "*.nii.gz" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($existingNii) {
    Write-Host "Already have NIfTI for $experimentId — skipping."
    continue
  }

  $downloadUrl = "https://www.nitrc.org/ir/data/archive/projects/$projectId/subjects/$subjectId/experiments/$experimentId/scans/$ScanType/files?format=zip"
  $downloadUrl = [Uri]::EscapeUriString($downloadUrl)

  Write-Host $downloadUrl

  $zipPath = Join-Path $OutputDir "$experimentId.zip"

  try {
    Invoke-IRRequest -Uri $downloadUrl -Session $session -OutFile $zipPath | Out-Null
  } catch {
    Write-Warning "Failed to download $experimentId. Details: $($_.Exception.Message)"
    continue
  }

  # Validate zip isn't an auth/permission HTML response
  if (LooksLikeAuthFailure $zipPath) {
    Write-Warning "Download for $experimentId does not look like a valid scan zip (auth/permission issue or no scan of that type). Deleting: $zipPath"
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    continue
  }

  # Extract
  try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $OutputDir -Force
  } catch {
    Write-Warning "Failed to extract zip for $experimentId. Deleting zip and continuing. Details: $($_.Exception.Message)"
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    continue
  }

  # Rearrange files: <OutputDir>\<experimentId>\scans\<scanNameAll>\resources\<BIDS|NIFTI>\files\*  ->  <OutputDir>\<experimentId>\<scanName>\*
  $scanRoot = Join-Path $OutputDir $experimentId
  $scansPath = Join-Path $scanRoot "scans"

  if (Test-Path -LiteralPath $scansPath) {
    Get-ChildItem -LiteralPath $scansPath -Directory | ForEach-Object {
      $scanNameAll = $_.Name
      $scanName = ($scanNameAll -split "-")[0]
      $destDir = Join-Path $scanRoot $scanName
      Ensure-Dir $destDir

      # Move all files from any resource/*/files/* into dest
      $resourceFiles = Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\resources\\[^\\]+\\files\\" }

      foreach ($f in $resourceFiles) {
        try {
          Move-Item -LiteralPath $f.FullName -Destination $destDir -Force
        } catch {
          # If file already moved or locked, continue
        }
      }
    }

    # Remove empty scans tree
    try { Remove-Item -LiteralPath $scansPath -Recurse -Force } catch { }
  }

  # Clean up zip
  try { Remove-Item -LiteralPath $zipPath -Force } catch { }

  # Verify we got NIfTI
  $nii = Get-ChildItem -LiteralPath $scanRoot -Recurse -Filter "*.nii.gz" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($nii) {
    Write-Host "Done with $experimentId"
  } else {
    Write-Warning "No .nii.gz found after extraction/rearrange for $experimentId (it may truly lack $ScanType)."
  }
}

# Logout (best-effort)
try {
  Invoke-WebRequest -Uri $jsessionUrl -Method DELETE -WebSession $session -Headers @{ "Expect" = "" } | Out-Null
} catch { }

Write-Host "Session ended."