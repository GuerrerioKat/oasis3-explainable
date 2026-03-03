@'
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$InputCsv,
  [Parameter(Mandatory=$true)][string]$OutputDir,
  [Parameter(Mandatory=$true)][string]$Username,
  [Parameter(Mandatory=$false)][string]$ScanType = "ALL",
  [Parameter(Mandatory=$false)][ValidateSet("OASIS3_AV1451","OASIS3_AV1451L")][string]$TauProjectId
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-Dir([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}

function Detect-IdColumn($rows) {
  $first = $rows | Select-Object -First 1
  if (-not $first) { throw "CSV has no rows." }
  $headers = $first.PSObject.Properties.Name
  foreach ($c in @("experiment_id","MR ID","MR_ID","mr_id","Experiment ID","EXPERIMENT_ID")) {
    if ($headers -contains $c) { return $c }
  }
  throw ("Could not find an ID column. Headers: " + ($headers -join ", "))
}

function Normalize-Id([string]$raw) {
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $id = $raw.Trim().Trim('"').Trim("'") -replace '\s+', '_'
  return $id
}

function Guess-Project([string]$experimentId) {
  $p = "OASIS3"
  if ($experimentId.StartsWith("OAS4")) { $p = "OASIS4" }
  if ($experimentId -match "_AV1451") {
    if ($TauProjectId -eq "OASIS3_AV1451" -or $TauProjectId -eq "OASIS3_AV1451L") { $p = $TauProjectId }
    else { $p = "OASIS3_AV1451" }
  }
  return $p
}

function Zip-Looks-Bad([string]$zipPath) {
  if (-not (Test-Path -LiteralPath $zipPath)) { return $true }
  $len = (Get-Item -LiteralPath $zipPath).Length
  if ($len -lt 10240) { return $true }
  return $false
}

Ensure-Dir $OutputDir

$securePassword = Read-Host "Enter your NITRC password" -AsSecureString
$cred = New-Object System.Management.Automation.PSCredential($Username, $securePassword)
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

$jsessionUrl = "https://www.nitrc.org/ir/data/JSESSION"
Invoke-WebRequest -Uri $jsessionUrl -Method GET -WebSession $session -Credential $cred -Headers @{Expect=""} | Out-Null
Write-Host "Login successful."

$rows = Import-Csv -LiteralPath $InputCsv
$idCol = Detect-IdColumn $rows
Write-Host ("Using ID column: " + $idCol)

foreach ($row in $rows) {
  $experimentId = Normalize-Id ($row.$idCol)
  if (-not $experimentId) { continue }

  if ($experimentId -notmatch '^OAS\d+_MR_d\d+$' -and $experimentId -notmatch '^OAS4\d+_MR_d\d+$') {
    Write-Warning ("Skipping invalid experiment id: " + $experimentId)
    continue
  }

  $subjectId = $experimentId.Split("_")[0]
  $projectId = Guess-Project $experimentId

  if ($ScanType -ne "ALL") { Write-Host ("Checking for " + $ScanType + " scan for " + $experimentId) }
  else { Write-Host ("Downloading all scans for " + $experimentId) }

  $expDir = Join-Path $OutputDir $experimentId
  Ensure-Dir $expDir

  $existing = Get-ChildItem -LiteralPath $expDir -Recurse -Filter "*.nii.gz" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($existing) {
    Write-Host ("Already have NIfTI for " + $experimentId + " - skipping.")
    continue
  }

  $url = "https://www.nitrc.org/ir/data/archive/projects/$projectId/subjects/$subjectId/experiments/$experimentId/scans/$ScanType/files?format=zip"
  $url = [Uri]::EscapeUriString($url)
  Write-Host $url

  $zipPath = Join-Path $OutputDir ($experimentId + ".zip")

  try {
    Invoke-WebRequest -Uri $url -Method GET -WebSession $session -OutFile $zipPath -Headers @{Expect=""} | Out-Null
  } catch {
    Write-Warning ("Failed to download " + $experimentId + ": " + $_.Exception.Message)
    continue
  }

  if (Zip-Looks-Bad $zipPath) {
    Write-Warning ("Download did not look like a scan zip. Removing: " + $zipPath)
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    continue
  }

  Expand-Archive -LiteralPath $zipPath -DestinationPath $OutputDir -Force

  $scanRoot = Join-Path $OutputDir $experimentId
  $scansPath = Join-Path $scanRoot "scans"

  if (Test-Path -LiteralPath $scansPath) {
    Get-ChildItem -LiteralPath $scansPath -Directory | ForEach-Object {
      $scanNameAll = $_.Name
      $scanName = ($scanNameAll -split "-")[0]
      $dest = Join-Path $scanRoot $scanName
      Ensure-Dir $dest

      Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\resources\\[^\\]+\\files\\" } |
        ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction SilentlyContinue }
    }

    Remove-Item -LiteralPath $scansPath -Recurse -Force -ErrorAction SilentlyContinue
  }

  Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

  $nii = Get-ChildItem -LiteralPath $scanRoot -Recurse -Filter "*.nii.gz" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($nii) { Write-Host ("Done with " + $experimentId) }
  else { Write-Warning ("No .nii.gz found after extraction for " + $experimentId) }
}

try { Invoke-WebRequest -Uri $jsessionUrl -Method DELETE -WebSession $session -Headers @{Expect=""} | Out-Null } catch {}
Write-Host "Session ended."
'@ | Set-Content -Encoding UTF8 -NoNewline .\download_oasis_scans.ps1